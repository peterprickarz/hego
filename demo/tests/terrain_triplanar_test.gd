extends "res://tests/terrain_normal_displacement_test.gd"
## Dedicated synthetic GPU fixtures, using the unchanged production vertex and
## fragment calculations. CPU references use explicit signed frames, repeated
## bilinear image sampling and shortest-arc rotations independent of shader RNM.
var checks := 0
var pattern_image: Image

func check(value: bool, message: String):
	checks += 1
	if not value: failures += 1; push_error("TRIPLANAR: " + message)

func run():
	create_timer(240.0).timeout.connect(func(): push_error("Triplanar watchdog expired"); quit(1))
	if RenderingServer.get_rendering_device() == null: push_error("Use graphical Forward+"); quit(2); return
	print("TRIPLANAR_GPU ", RenderingServer.get_video_adapter_name())
	setup_scene()
	await test_signed_normals()
	await test_uninitialized_uniform()
	await test_projection_families()
	await test_ridge_neutrality()
	world.free(); viewport.free()
	print("TERRAIN_TRIPLANAR_TEST checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func frames(normal: Vector3) -> Array[Basis]:
	var sx := -1.0 if normal.x < 0.0 else 1.0
	var sz := -1.0 if normal.z < 0.0 else 1.0
	return [Basis(Vector3(0, 0, -sx), Vector3.UP, Vector3(sx, 0, 0)), Basis(Vector3.RIGHT, Vector3.FORWARD, Vector3.UP), Basis(Vector3(sz, 0, 0), Vector3.UP, Vector3(0, 0, sz))]

func axis_weights(normal: Vector3, sharpness: float) -> Vector3:
	var n := normal.abs()
	var weights := Vector3(pow(n.x, sharpness), pow(n.y, sharpness), pow(n.z, sharpness))
	return weights / (weights.x + weights.y + weights.z)

func reference_normal(normal: Vector3, sharpness: float, detail: Vector3) -> Vector3:
	var axes := frames(normal); var weights := axis_weights(normal, sharpness); var result := Vector3.ZERO
	for axis in range(3):
		var basis := axes[axis]; var mapped := basis * detail
		var arc := basis.z.cross(normal)
		# Rodrigues shortest-arc rotation from projection axis to terrain normal.
		result += (mapped + arc.cross(mapped) + arc.cross(arc.cross(mapped)) / (1.0 + basis.z.dot(normal))) * weights[axis]
	return result.normalized()

func decoded(image: Image, pixel: Vector2i) -> Vector3:
	var c := image.get_pixelv(pixel)
	return Vector3(c.r, c.g, c.b) * 2.0 - Vector3.ONE

func test_signed_normals():
	top_view(Vector2.ZERO, 12.0)
	for gradient in [Vector2.ZERO, Vector2(4, 0), Vector2(-4, 0), Vector2(0, 4), Vector2(0, -4), Vector2(0.8, -0.6)]:
		check(configure(Rect2(-16, -16, 32, 32), func(p: Vector2) -> float: return gradient.dot(p) + 2.0, flat(Color(1, 1, 0, 0.5))), "Configure signed plane " + str(gradient))
		renderer.displacement_enabled = false
		var normal := Vector3(-gradient.x, 1.0, -gradient.y).normalized()
		override("ALBEDO = final_normal * 0.5 + 0.5;")
		for sharpness in [1.0, 4.0, 64.0]:
			material.triplanar_sharpness = sharpness
			for xy in [Vector2.ZERO, Vector2(0.6, 0), Vector2(-0.6, 0), Vector2(0, 0.6), Vector2(0, -0.6)]:
				material.normal_texture = flat(Color(xy.x * 0.5 + 0.5, xy.y * 0.5 + 0.5, 1.0))
				renderer._bind_material_pool()
				var image: Image = await render(3)
				var expected := reference_normal(normal, sharpness, Vector3(xy.x, xy.y, sqrt(1.0 - xy.length_squared())))
				var error := 0.0
				for pixel in grid(32, 48): error = maxf(error, decoded(image, pixel).distance_to(expected))
				check(error < 0.004, "Signed plane %s sharpness %s detail %s preserves flat lighting/handed detail; error=%s" % [gradient, sharpness, xy, error])
	print("TRIPLANAR signed plane normals complete")

func test_uninitialized_uniform():
	var gradient := Vector2(0.8, -0.6)
	check(configure(Rect2(-16, -16, 32, 32), func(p: Vector2) -> float: return gradient.dot(p) + 2.0, flat(Color(1, 1, 0, 0.5))), "Configure initially unbound shader uniform fixture")
	renderer.displacement_enabled = false
	var xy := Vector2(0.6, 0.2)
	material.normal_texture = flat(Color(xy.x * 0.5 + 0.5, xy.y * 0.5 + 0.5, 1))
	material.triplanar_sharpness = 4.0; renderer._bind_material_pool()
	override("ALBEDO = final_normal * 0.5 + 0.5;")
	await render(3) # Let pending resource notifications finish before overriding.
	var zeros := PackedFloat32Array(); zeros.resize(32)
	renderer._shader_material.set_shader_parameter("triplanar_sharpnesses", zeros)
	var image: Image = await render(3)
	var normal := Vector3(-gradient.x, 1, -gradient.y).normalized()
	var detail := Vector3(xy.x, xy.y, sqrt(1.0 - xy.length_squared()))
	var expected := reference_normal(normal, 4.0, detail)
	check(decoded(image, viewport.size / 2).distance_to(expected) < 0.004, "Zero/uninitialized sharpness uniform uses default four during live shader reload")
	check(expected.distance_to(reference_normal(normal, 1.0, detail)) > 0.02, "Uninitialized-uniform fixture distinguishes the default from exponent one")

func pattern() -> ImageTexture:
	pattern_image = Image.create(32, 32, false, Image.FORMAT_RGBAF)
	for y in range(32):
		for x in range(32):
			var value := 0.5 + 0.3 * sin(TAU * (x + 0.5) / 32.0) * cos(TAU * (y + 0.5) / 32.0)
			pattern_image.set_pixel(x, y, Color(value, value, value, value))
	return ImageTexture.create_from_image(pattern_image)

func repeated_bilinear(uv: Vector2) -> float:
	var p := uv * Vector2(pattern_image.get_size()) - Vector2(0.5, 0.5)
	var x := floori(p.x); var y := floori(p.y); var f := p - Vector2(x, y)
	var a := pattern_image.get_pixel(posmod(x, 32), posmod(y, 32)).r
	var b := pattern_image.get_pixel(posmod(x + 1, 32), posmod(y, 32)).r
	var c := pattern_image.get_pixel(posmod(x, 32), posmod(y + 1, 32)).r
	var d := pattern_image.get_pixel(posmod(x + 1, 32), posmod(y + 1, 32)).r
	return lerpf(lerpf(a, b, f.x), lerpf(c, d, f.x), f.y)

func projected(point: Vector3, normal: Vector3, item: StrataMaterial, far_mix: float) -> float:
	var axes := frames(normal); var weights := axis_weights(normal, item.triplanar_sharpness); var result := 0.0
	for axis in range(3):
		var uv := Vector2(axes[axis].x.dot(point), -axes[axis].y.dot(point)) * item.uv_scale
		result += lerpf(repeated_bilinear(uv), repeated_bilinear(uv * renderer.far_uv_factor), far_mix) * weights[axis]
	return result

func test_projection_families():
	var texture := pattern()
	var second := StrataMaterial.new()
	for item in [material, second]:
		item.color_texture = texture; item.ormh_texture = texture; item.normal_texture = flat(Color(0.5, 0.5, 1))
		item.displacement_strength = 1.0
	material.uv_scale = 0.125; material.triplanar_sharpness = 1.0; material.height_blend_contrast = 3.0; material.height_blend_bias = 0.1
	second.uv_scale = 0.19; second.triplanar_sharpness = 64.0; second.height_blend_contrast = 6.0; second.height_blend_bias = -0.1
	# X and Z cliffs of both signs: the vertical repeat must follow height,
	# rather than collapse to horizontal XZ projection on the cliff face.
	for gradient in [Vector2(4, 0), Vector2(-4, 0), Vector2(0, 4), Vector2(0, -4)]:
		# This fixture deliberately changes pool cardinality between configurations.
		renderer._control_ids = null; renderer._control_weights = null
		check(configure(Rect2(-16, -16, 32, 32), func(p: Vector2) -> float: return gradient.dot(p) + 2.0, texture), "Configure patterned cliff " + str(gradient))
		renderer._materials = [material, second]; renderer._bind_material_pool()
		var ids := Image.create(2, 2, false, Image.FORMAT_RGBA8); ids.fill(Color(0, 1.0 / 255.0, 0, 0))
		var weights := Image.create(2, 2, false, Image.FORMAT_RGBAF); weights.fill(Color(0.35, 0.65, 0, 0))
		check(renderer.set_control_maps(ids, weights), "Set two independently projected material IDs")
		renderer.displacement_strength = 0.2; renderer.displacement_radius = 1000.0
		fade_camera.position = Vector3(0, 4, 0)
		top_view(Vector2.ZERO, 12.0)
		var normal := Vector3(-gradient.x, 1, -gradient.y).normalized()
		for distance_uv in [false, true]:
			renderer.distance_uv_enabled = distance_uv; renderer.uv_near_distance = 0.1; renderer.uv_far_distance = 12.0; renderer.far_uv_factor = 0.37
			await render(2)
			# Fragment color/ORM and the vertex-produced displacement share the
			# same base-point phase. Two channels expose independent results.
			override("vec3 probe_local = (inverse(MODEL_MATRIX) * (INV_VIEW_MATRIX * vec4(VERTEX, 1.0))).xyz; float probe_offset = dot(probe_local - base_point, projection_normal); ALBEDO = vec3(color.r, orm.r, probe_offset + 0.5);")
			var image: Image = await render(4)
			var color_error := 0.0; var orm_error := 0.0; var offset_error := 0.0; var horizontal_difference := 0.0
			for pixel in grid(24, 48):
				var c := image.get_pixelv(pixel); var offset := c.b - 0.5
				var ray := source.to_local(view.project_ray_origin(Vector2(pixel) + Vector2(0.5, 0.5)))
				var p := Vector2(ray.x - normal.x * offset, ray.z - normal.z * offset)
				var point := Vector3(p.x, gradient.dot(p) + 2.0, p.y)
				var far_mix := smoothstep(renderer.uv_near_distance, renderer.uv_far_distance, point.distance_to(fade_camera.position)) if distance_uv else 0.0
				var a := projected(point, normal, material, far_mix); var b := projected(point, normal, second, far_mix)
				var ga := material.height_blend_contrast * (clampf(a + material.height_blend_bias, 0, 1) - 0.5)
				var gb := second.height_blend_contrast * (clampf(b + second.height_blend_bias, 0, 1) - 0.5)
				var wa := 0.35 * pow(2.0, ga); var wb := 0.65 * pow(2.0, gb)
				var expected := (a * wa + b * wb) / (wa + wb)
				color_error = maxf(color_error, absf(c.r - expected)); orm_error = maxf(orm_error, absf(c.g - expected))
				offset_error = maxf(offset_error, absf(offset - (expected - 0.5) * 0.2))
				horizontal_difference = maxf(horizontal_difference, absf(b - repeated_bilinear(Vector2(point.x, point.z) * second.uv_scale)))
			print("TRIPLANAR_PATTERN gradient=", gradient, " distance_uv=", distance_uv, " color_error=", color_error, " orm_error=", orm_error, " displacement_error=", offset_error, " xz_control_difference=", horizontal_difference)
			check(color_error < 0.007 and orm_error < 0.007, "Color and ORMH match independent per-material sharpness/physical-plane reference")
			check(offset_error < 0.004, "Vertex ORMH height and fragment height/color share the undisplaced projection phase")
			check(horizontal_difference > 0.1, "Pattern fixture distinguishes physical vertical projection from stretched XZ")
	# Restore the single-material fixture before the ridge configuration.
	renderer._materials = [material]; material.height_blend_contrast = 0; material.height_blend_bias = 0
	renderer.distance_uv_enabled = false

func test_ridge_neutrality():
	renderer._control_ids = null; renderer._control_weights = null
	material.normal_texture = flat(Color(0.5, 0.5, 1))
	check(configure(Rect2(-16, -16, 32, 32), func(p: Vector2) -> float: return 10.0 - 3.0 * absf(p.x) + 0.2 * p.y, flat(Color(1, 1, 0, 0.5))), "Configure signed ridge crossing")
	renderer.displacement_enabled = false; top_view(Vector2.ZERO, 5.0)
	for crease in [180.0, 30.0]:
		renderer.crease_angle_degrees = crease
		override("ALBEDO = final_normal * 0.5 + 0.5;", crease < 180.0)
		material.triplanar_sharpness = 1.0; renderer._bind_material_pool()
		var broad: Image = await render(4)
		material.triplanar_sharpness = 64.0; renderer._bind_material_pool()
		var sharp: Image = await render(4)
		var difference := max_image_difference(broad, sharp)
		print("TRIPLANAR_RIDGE crease=", crease, " sharpness_normal_difference=", difference)
		check(difference < 0.001, "Flat normal maps preserve lighting across a sharp ridge for all projection sharpness (crease=%s)" % crease)
