extends SceneTree
## Forward+ GPU regression for near-camera material relief along the smooth
## terrain normal. Every field and material is a synthetic in-memory fixture
## (planes, a ridge, a rolling cliff field, flat or striped RGBAF ORMH heights).
## The production vertex() runs unchanged; overrides only replace fragment output.
## No showcase asset, authoring scene or cache is read or written.

const MATERIAL_DISPLACEMENT := 2.0
const STRENGTH := 0.5
const HALF_ULP := 0.0006 # RGBA16F readback quantization near 0.5
var failures := 0
var viewport: SubViewport
var world: Node3D
var view: Camera3D
var fade_camera: Camera3D
var source: StrataTerrain3D
var renderer: StrataRenderer
var material: StrataMaterial
# Terrain-local displacement vector, offset into the readable 0..1 range.
var delta_tail := """
vec3 hego_test_local = (inverse(MODEL_MATRIX) * (INV_VIEW_MATRIX * vec4(VERTEX, 1.0))).xyz;
ALBEDO = hego_test_local - vec3(terrain_position.x, base_height(terrain_position), terrain_position.y) + vec3(0.5);
"""

func _initialize(): call_deferred("run")
func check(value: bool, message: String):
	if not value: failures += 1; push_error(message)

func run():
	create_timer(300.0).timeout.connect(func(): push_error("Normal displacement test watchdog expired"); quit(1))
	if RenderingServer.get_rendering_device() == null: push_error("Use a real graphical Forward+ device"); quit(2); return
	print("NORMAL_DISPLACEMENT_GPU ", RenderingServer.get_video_adapter_name(), " ", RenderingServer.get_video_adapter_api_version())
	setup_scene()
	await test_readback()
	await test_planes()
	await test_fade_and_disabled()
	await test_shading_modes_share_geometry()
	await test_lateral_bounds()
	await test_patch_stitching()
	print("TERRAIN_NORMAL_DISPLACEMENT_TEST failures=", failures)
	quit(0 if failures == 0 else 1)

func setup_scene():
	viewport = SubViewport.new(); viewport.size = Vector2i(256, 256); viewport.use_hdr_2d = true; viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	world = Node3D.new(); viewport.add_child(world)
	var environment := WorldEnvironment.new(); environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR; environment.environment.background_color = Color.BLACK
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world.add_child(environment)
	view = Camera3D.new(); view.projection = Camera3D.PROJECTION_ORTHOGONAL; view.near = 0.05; view.far = 2000.0; world.add_child(view); view.current = true
	fade_camera = Camera3D.new(); world.add_child(fade_camera)
	source = StrataTerrain3D.new(); world.add_child(source)
	renderer = StrataRenderer.new(); source.add_child(renderer)
	material = StrataMaterial.new(); material.color_texture = flat(Color(0.5, 0.5, 0.5)); material.normal_texture = flat(Color(0.5, 0.5, 1.0))
	material.displacement_strength = MATERIAL_DISPLACEMENT

func flat(color: Color) -> ImageTexture:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBAF); image.fill(color); return ImageTexture.create_from_image(image)

func striped_relief() -> ImageTexture:
	var image := Image.create(16, 16, false, Image.FORMAT_RGBAF)
	for z in range(16):
		for x in range(16): image.set_pixel(x, z, Color(1, 1, 0, 0.5 + 0.45 * sin(TAU * x / 16.0) * cos(TAU * z / 16.0)))
	return ImageTexture.create_from_image(image)

func configure(bounds: Rect2, height: Callable, relief: Texture2D) -> bool:
	material.ormh_texture = relief
	source.base_bounds = bounds
	var size := Vector2i(roundi(bounds.size.x) + 1, roundi(bounds.size.y) + 1)
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RF); var minimum := INF; var maximum := -INF
	for z in range(size.y):
		for x in range(size.x):
			var h: float = height.call(bounds.position + Vector2(x, z))
			image.set_pixel(x, z, Color(h, 0, 0, 1)); minimum = minf(minimum, h); maximum = maxf(maximum, h)
	var pool: Array[StrataMaterial] = [material]
	var ok := renderer.configure_compiled_field(source, pool, {"ok": true, "image": image, "bounds": bounds, "resolution": size, "sample_step_x": Vector3.RIGHT, "min": minimum, "max": maximum})
	renderer.set_camera(fade_camera)
	renderer.smooth_shading = true; renderer.crease_angle_degrees = 180.0; renderer.displacement_enabled = true; renderer.displacement_refinement_enabled = true
	renderer.displacement_strength = STRENGTH
	return ok

func override(tail: String, creases := false, replacements := {}) -> void:
	var code := FileAccess.get_file_as_string("res://addons/strata/shaders/terrain_surface.gdshader")
	for name in ["terrain_controls.gdshaderinc", "terrain_texture_dispatch.gdshaderinc", "terrain_normals.gdshaderinc", "terrain_height_blend.gdshaderinc", "terrain_triplanar.gdshaderinc"]:
		code = code.replace('#include "' + name + '"', FileAccess.get_file_as_string("res://addons/strata/shaders/" + name))
	code = code.replace("render_mode cull_back,", "render_mode unshaded, cull_back,")
	for key in replacements:
		check(code.contains(key), "Shader fixture edit target exists: " + key)
		code = code.replace(key, replacements[key])
	var end := code.rfind("}")
	var shader := Shader.new(); shader.code = ("#define HEGO_TERRAIN_CREASES\n" if creases else "") + code.substr(0, end) + tail + code.substr(end)
	renderer._shader_material.shader = shader

func top_view(center: Vector2, size: float):
	view.size = size; view.position = Vector3(center.x, 400, center.y); view.look_at(Vector3(center.x, 0, center.y), Vector3.FORWARD)

func render(frames := 6) -> Image:
	for index in range(frames): await process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func delta_at(image: Image, pixel: Vector2i) -> Vector3:
	var c := image.get_pixelv(pixel); return Vector3(c.r, c.g, c.b) - Vector3(0.5, 0.5, 0.5)

## Undisplaced terrain-local XZ of the surface seen at a top-down pixel.
func base_xz(pixel: Vector2i, delta: Vector3) -> Vector2:
	var origin := source.to_local(view.project_ray_origin(Vector2(pixel) + Vector2(0.5, 0.5)))
	return Vector2(origin.x - delta.x, origin.z - delta.z)

func grid(step: int, margin: int) -> Array[Vector2i]:
	var pixels: Array[Vector2i] = []
	for y in range(margin, viewport.size.y - margin, step):
		for x in range(margin, viewport.size.x - margin, step): pixels.append(Vector2i(x, y))
	return pixels

func max_image_difference(a: Image, b: Image) -> float:
	var result := 0.0
	for y in range(a.get_height()):
		for x in range(a.get_width()):
			var p := a.get_pixel(x, y); var q := b.get_pixel(x, y)
			result = maxf(result, maxf(absf(p.r - q.r), maxf(absf(p.g - q.g), absf(p.b - q.b))))
	return result

func test_readback():
	check(configure(Rect2(-32, -32, 64, 64), func(_p: Vector2) -> float: return 0.0, flat(Color(1, 1, 0, 0.5))), "Configure readback fixture")
	top_view(Vector2.ZERO, 40.0); fade_camera.position = Vector3(0, 2, 0)
	override("ALBEDO = vec3(0.123, 0.5, 0.877);")
	var image: Image = await render()
	var c := image.get_pixelv(viewport.size / 2)
	print("NORMAL_DISPLACEMENT_READBACK format=", image.get_format(), " value=", c)
	check(Vector3(c.r, c.g, c.b).distance_to(Vector3(0.123, 0.5, 0.877)) < HALF_ULP * 2.0, "Linear HDR readback returns shader output values")

func test_planes():
	var bounds := Rect2(-32, -32, 64, 64)
	top_view(Vector2.ZERO, 40.0)
	# [label, gradient, base offset, ORMH height]: steep is 3:1 (about 72 degrees).
	for fixture in [["flat", Vector2.ZERO, 2.0, 0.9], ["slope", Vector2(0.2, -0.4), 3.0, 0.9], ["steep", Vector2(3.0, 0.5), 1.0, 0.9], ["steep inward", Vector2(3.0, 0.5), 1.0, 0.1]]:
		var gradient: Vector2 = fixture[1]; var offset: float = fixture[2]; var alpha: float = fixture[3]
		check(configure(bounds, func(p: Vector2) -> float: return gradient.dot(p) + offset, flat(Color(1, 1, 0, alpha))), "Configure " + fixture[0] + " plane")
		renderer.displacement_radius = 1000.0 # whole fixture is inside the unfaded zone
		fade_camera.position = Vector3(0, offset + 2.0, 0)
		var normal := Vector3(-gradient.x, 1.0, -gradient.y).normalized()
		var expected := normal * (alpha - 0.5) * MATERIAL_DISPLACEMENT * STRENGTH
		var partitions := []
		# Uniform refined leaves, then two distinct base LOD partitions.
		for setup in [[true, Vector3(0, offset + 2.0, 0)], [false, Vector3(0, offset + 2.0, 0)], [false, Vector3(30, gradient.dot(Vector2(30, 30)) + offset + 2.0, 30)]]:
			renderer.displacement_refinement_enabled = setup[0]; fade_camera.position = setup[1]
			await render(2)
			override(delta_tail)
			var image: Image = await render()
			partitions.append(renderer._patches.keys())
			var error := 0.0; var mean := Vector3.ZERO; var samples := grid(8, 24)
			for pixel in samples:
				var delta := delta_at(image, pixel); mean += delta / samples.size(); error = maxf(error, delta.distance_to(expected))
			print("NORMAL_DISPLACEMENT_PLANE ", fixture[0], " refined=", setup[0], " patches=", renderer._patches.size(), " mean=", mean, " expected=", expected, " max_error=", error)
			check(error < 0.003, "%s plane displaces along its normal by the material amount (refined=%s)" % [fixture[0], setup[0]])
			check(mean.normalized().dot(expected.normalized()) > 0.99999, fixture[0] + " plane relief direction is the terrain normal")
			# The 3:1 fixture moves about 0.38 m of its 0.4 m relief sideways.
			if gradient.length() > 1.0: check(Vector2(mean.x, mean.z).length() > 0.37, fixture[0] + " cliff relief is mostly lateral")
		check(partitions[0] != partitions[1] and partitions[1] != partitions[2], fixture[0] + " plane was rendered with three different patch partitions")

func test_fade_and_disabled():
	var gradient := Vector2(0.2, -0.4)
	var height := func(p: Vector2) -> float: return gradient.dot(p) + 3.0
	check(configure(Rect2(-64, -64, 128, 128), height, flat(Color(1, 1, 0, 0.9))), "Configure fade fixture")
	var radius := 32.0
	renderer.displacement_radius = radius
	var camera_xz := Vector2(-56, 0); fade_camera.position = Vector3(camera_xz.x, height.call(camera_xz) + 1.0, camera_xz.y)
	top_view(Vector2.ZERO, 124.0)
	await render(2)
	override(delta_tail)
	var image: Image = await render()
	var normal := Vector3(-gradient.x, 1.0, -gradient.y).normalized()
	var counts := {"near": 0, "fading": 0, "far": 0}; var error := 0.0; var far_maximum := 0.0
	for pixel in grid(4, 2):
		var delta := delta_at(image, pixel); var p := base_xz(pixel, delta)
		var distance := Vector3(p.x, height.call(p), p.y).distance_to(fade_camera.position)
		var fade := 1.0 - smoothstep(radius * 0.55, radius, distance)
		error = maxf(error, delta.distance_to(normal * 0.4 * fade))
		if fade >= 1.0: counts.near += 1
		elif distance > radius + 0.5: counts.far += 1; far_maximum = maxf(far_maximum, delta.length())
		elif fade > 0.0: counts.fading += 1
	print("NORMAL_DISPLACEMENT_FADE counts=", counts, " max_error=", error, " far_max=", far_maximum)
	check(counts.near > 20 and counts.fading > 20 and counts.far > 200, "Fade fixture covers near, fading and far pixels")
	check(error < 0.003, "Relief along the normal follows the base-point distance fade")
	# Same reconstruction noise floor as the disabled baseline below.
	check(far_maximum < HALF_ULP, "Beyond the radius the vertex is the base surface point")
	for disable in ["enabled", "strength"]:
		if disable == "enabled": renderer.displacement_enabled = false
		else: renderer.displacement_enabled = true; renderer.displacement_strength = 0.0
		await render(2)
		override(delta_tail)
		image = await render()
		var maximum := 0.0
		for pixel in grid(4, 2): maximum = maxf(maximum, delta_at(image, pixel).length())
		print("NORMAL_DISPLACEMENT_BASELINE ", disable, " max=", maximum)
		check(maximum < HALF_ULP, "Disabled displacement (" + disable + ") renders the undisplaced base surface")
	renderer.displacement_strength = STRENGTH

func test_shading_modes_share_geometry():
	# A sharp 112-degree ridge on a lattice line splits at a 30-degree crease.
	var height := func(p: Vector2) -> float: return 10.0 - 1.5 * absf(p.x) + 0.1 * p.y
	check(configure(Rect2(-32, -32, 64, 64), height, flat(Color(1, 1, 0, 0.9))), "Configure ridge fixture")
	renderer.displacement_radius = 1000.0; fade_camera.position = Vector3(0, 12, 0)
	top_view(Vector2.ZERO, 6.0)
	await render(2)
	override(delta_tail)
	var smooth: Image = await render()
	renderer.smooth_shading = false
	var legacy: Image = await render()
	renderer.smooth_shading = true; renderer.crease_angle_degrees = 30.0
	check(renderer._shader_material.shader.code.begins_with("#define HEGO_TERRAIN_CREASES"), "Ridge fixture activates the crease variant")
	override(delta_tail, true)
	var creased: Image = await render()
	renderer.crease_angle_degrees = 180.0
	var legacy_difference := max_image_difference(smooth, legacy); var crease_difference := max_image_difference(smooth, creased)
	# Continuous field gradient: bilinear central differences, -1.5x within 1 m of the ridge.
	var error := 0.0; var ridge_lateral := 0.0
	for pixel in grid(4, 8):
		var delta := delta_at(smooth, pixel); var p := base_xz(pixel, delta)
		var gx := -1.5 * p.x if absf(p.x) <= 1.0 else -1.5 * signf(p.x)
		error = maxf(error, delta.distance_to(Vector3(-gx, 1.0, -0.1).normalized() * 0.4))
		if absf(p.x) < 0.05: ridge_lateral = maxf(ridge_lateral, absf(delta.x))
	print("NORMAL_DISPLACEMENT_SHADING_MODES legacy_diff=", legacy_difference, " crease_diff=", crease_difference, " smooth_error=", error, " ridge_lateral=", ridge_lateral)
	check(legacy_difference < HALF_ULP and crease_difference < HALF_ULP, "Legacy and crease shading leave displaced geometry unchanged")
	check(error < 0.006, "Ridge relief follows the continuous field normal, not split face normals")
	check(ridge_lateral < 0.04, "Relief at the crease line stays near vertical instead of splitting toward either face")

func test_lateral_bounds():
	check(configure(Rect2(-32, -32, 64, 64), func(p: Vector2) -> float: return 3.0 * p.x, flat(Color(1, 1, 0, 0.9))), "Configure lateral bounds fixture")
	renderer.displacement_radius = 1000.0; fade_camera.position = Vector3(-20, -58, 0)
	await render(2)
	var reach := STRENGTH * MATERIAL_DISPLACEMENT * 0.5
	var edge_patches: Array[MeshInstance3D] = []
	var covered := true
	for patch: MeshInstance3D in renderer._patches.values():
		var bounds: Rect2 = patch.get_meta("terrain_patch_bounds"); var box := patch.custom_aabb
		covered = covered and box.position.x <= bounds.position.x - reach and box.end.x >= bounds.end.x + reach and box.position.z <= bounds.position.y - reach and box.end.z >= bounds.end.y + reach and box.position.y <= -96.0 - reach and box.end.y >= 96.0 + reach
		if is_equal_approx(bounds.position.x, -32.0): edge_patches.append(patch)
	check(covered and not edge_patches.is_empty(), "Patch AABBs include the full relief reach laterally and vertically")
	# The steep west edge bulges about 0.38 m beyond the field bounds.
	top_view(Vector2(-32.2, 0.0), 0.2)
	override("ALBEDO = vec3(1.0);")
	var visible: float = (await render()).get_pixelv(viewport.size / 2).r
	for patch in edge_patches:
		var bounds: Rect2 = patch.get_meta("terrain_patch_bounds"); var box := patch.custom_aabb
		patch.custom_aabb = AABB(Vector3(bounds.position.x - 0.01, box.position.y, box.position.z), Vector3(bounds.size.x + 0.02, box.size.y, box.size.z))
	var culled: float = (await render()).get_pixelv(viewport.size / 2).r
	for patch in edge_patches: renderer._update_patch_bounds(patch)
	var restored: float = (await render()).get_pixelv(viewport.size / 2).r
	print("NORMAL_DISPLACEMENT_BOUNDS edge_patches=", edge_patches.size(), " visible=", visible, " old_xz_padding=", culled, " restored=", restored)
	check(visible > 0.9 and restored > 0.9, "Cliff relief beyond the patch rectangle is not frustum culled")
	check(culled < 0.1, "Control: the previous X/Z padding would cull that relief")

func test_patch_stitching():
	viewport.size = Vector2i(512, 512)
	var height := func(p: Vector2) -> float: return 22.0 * sin(p.x * 0.09) * cos(p.y * 0.07) + 5.0 * cos((p.x + p.y) * 0.23)
	material.uv_scale = 0.37; material.displacement_strength = 4.0 # up to 1 m of relief
	check(configure(Rect2(-128, -128, 256, 256), height, striped_relief()), "Configure rolling cliff fixture")
	renderer.displacement_radius = 32.0
	var target := Vector2(-20, -20); fade_camera.position = Vector3(target.x, height.call(target) + 2.0, target.y)
	view.size = 64.0
	var direction := Vector3(cos(deg_to_rad(55.0)) * cos(deg_to_rad(35.0)), sin(deg_to_rad(55.0)), cos(deg_to_rad(55.0)) * sin(deg_to_rad(35.0)))
	var focus := Vector3(target.x, height.call(target), target.y)
	view.position = focus + direction * 300.0; view.look_at(focus)
	await render(4)
	var spans := {}
	for key: Vector4i in renderer._patches.keys(): spans[key.z] = true
	var stats := renderer.get_stats()
	print("NORMAL_DISPLACEMENT_STITCH patches=", renderer._patches.size(), " spans=", spans.keys(), " refined=", stats.get("refinement_patch_count"), " status=", stats.get("refinement_status"))
	check(spans.size() >= 3 and int(stats.get("refinement_patch_count", 0)) > 0, "Stitch fixture mixes refined and coarser LOD patches")
	var white := "ALBEDO = vec3(1.0);"
	for mode in ["smooth", "legacy", "crease", "patch-dependent control"]:
		match mode:
			"smooth": override(white)
			"legacy": renderer.smooth_shading = false; override(white)
			"crease": renderer.smooth_shading = true; renderer.crease_angle_degrees = 30.0; override(white, true)
			"patch-dependent control":
				renderer.crease_angle_degrees = 180.0
				# Refined leaves share one level inside the radius, so vary per patch origin.
				override(white, false, {"+ direction * offset;": "+ direction * offset * (1.0 + sin(dot(patch_uv_origin, vec2(1913.0, 2711.0))));"})
		var image: Image = await render()
		var holes := 0
		for y in range(image.get_height()):
			for x in range(image.get_width()):
				if image.get_pixel(x, y).r < 0.5: holes += 1
		print("NORMAL_DISPLACEMENT_STITCH ", mode, " background_pixels=", holes)
		if mode == "patch-dependent control": check(holes > 0, "Control: patch-dependent relief opens visible cracks")
		else: check(holes == 0, "Displaced mixed-LOD surface is watertight (" + mode + ")")
	material.uv_scale = 0.25; material.displacement_strength = MATERIAL_DISPLACEMENT
	viewport.size = Vector2i(256, 256)
