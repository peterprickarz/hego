extends "res://tests/terrain_normal_displacement_test.gd"
## Synthetic categorical neighborhoods only. Every texel has <=4 materials;
## interpolation can merge five or sixteen. No showcase assets or caches change.
var checks := 0
var soft_stitch_fixture := false
const HEIGHTS := [0.2, 0.35, 0.5, 0.8, 0.65]
const COLORS := [Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW, Color.CYAN]

func check(value: bool, message: String):
	checks += 1
	if not value: failures += 1; push_error("SOFT_LIMIT: " + message)

func run():
	create_timer(180.0).timeout.connect(func(): push_error("Soft material limit watchdog"); quit(1))
	test_cpu()
	if RenderingServer.get_rendering_device() != null:
		await test_gpu_kernel()
		setup_scene()
		await test_production()
		soft_stitch_fixture = true
		await test_patch_stitching()
		world.free(); viewport.free()
	else: print("SOFT_LIMIT headless: CPU checks only; GPU cases require graphical Forward+")
	print("TERRAIN_MATERIAL_SOFT_LIMIT_TEST checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func configure(bounds: Rect2, height: Callable, relief: Texture2D) -> bool:
	var configured := super.configure(bounds, height, relief)
	if configured and soft_stitch_fixture:
		# Exercise the inherited watertightness camera/partitions with five
		# distinct relief sources and neighboring four-slot control palettes.
		var pool: Array[StrataMaterial] = []
		for id in range(5):
			var item := StrataMaterial.new()
			item.color_texture = flat(COLORS[id]); item.normal_texture = flat(Color(0.5, 0.5, 1))
			item.ormh_texture = flat(Color(1, 1, 0, HEIGHTS[id])); item.height_blend_contrast = 16.0
			item.displacement_strength = material.displacement_strength; pool.append(item)
		renderer._materials = pool; renderer._bind_material_pool()
		var data := fixture()
		configured = renderer.set_control_maps(data.ids, data.weights)
	return configured

func fixture(kind := "crossing") -> Dictionary:
	var ids := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	var weights := Image.create(2, 2, false, Image.FORMAT_RGBAF)
	for corner in range(4):
		var entries: Array = [0, 1, 2, 3 if corner % 2 == 0 else 4]
		var values := Color(0.36, 0.28, 0.24, 0.12)
		match kind:
			"four": entries = [3, 0, 2, 1]
			"ties": entries = [corner * 4, corner * 4 + 1, corner * 4 + 2, corner * 4 + 3]; values = Color(0.25, 0.25, 0.25, 0.25)
			"empty": values = Color(0, 0, 0, 0)
		var encoded := Color()
		for slot in range(4): encoded[slot] = entries[slot] / 255.0
		ids.set_pixel(corner % 2, corner / 2, encoded); weights.set_pixel(corner % 2, corner / 2, values)
	return {"ids": ids, "weights": weights}

func sample(data: Dictionary, x: float) -> Dictionary:
	return StrataRenderer.blend_control_samples(data.ids, data.weights, Vector2(x, 0.5), Rect2(0, 0, 1, 1))

func by_id(result: Dictionary) -> PackedFloat32Array:
	var values := PackedFloat32Array(); values.resize(32)
	for slot in range(4): values[result.ids[slot]] += result.weights[slot]
	return values

func output(result: Dictionary, height_blend := true) -> Vector3:
	var heights := Vector4.ZERO
	for slot in range(4): heights[slot] = HEIGHTS[result.ids[slot]]
	var painted := Vector4(result.weights[0], result.weights[1], result.weights[2], result.weights[3])
	var weights := StrataRenderer.height_blend_weights(painted, heights, Vector4.ONE * 16.0, Vector4.ZERO, height_blend)
	var red := 0.0; var alpha := 0.0
	for slot in range(4): red += COLORS[result.ids[slot]].r * weights[slot]; alpha += heights[slot] * weights[slot]
	return Vector3(red, alpha, (alpha - 0.5) * 0.2 + 0.5)

func test_cpu():
	var data := fixture()
	for x in [0.0, 0.1, 0.49, 0.5, 0.51, 0.9, 1.0]:
		var result := sample(data, x); var actual := by_id(result)
		var threshold := 0.12 * minf(x, 1.0 - x)
		var expected := PackedFloat32Array([0.36 - threshold, 0.28 - threshold, 0.24 - threshold, maxf(0.12 * (1.0 - x) - threshold, 0), maxf(0.12 * x - threshold, 0)])
		var total := 0.0
		for value in expected: total += value
		for id in range(5): check(absf(actual[id] - expected[id] / total) < 0.000001, "CPU follows the fifth-weight subtraction reference")
		check(absf(result.discarded_weight - threshold) < 0.000001, "Discard diagnostic retains raw dropped mass, excluding threshold subtraction")
	var previous := INF
	for epsilon in [0.01, 0.001, 0.0001, 0.00001, 0.000001]:
		var left := sample(data, 0.5 - epsilon); var right := sample(data, 0.5 + epsilon)
		var difference := output(left).distance_to(output(right))
		check(difference < previous, "Fourth/fifth exchange converges continuously even under contrast sixteen")
		previous = difference
	check(previous < 0.0001, "Strong height competition cannot resurrect a finite fourth/fifth jump")
	var center := by_id(sample(data, 0.5))
	check(center[3] == 0 and center[4] == 0 and center[0] > 0, "Equal fourth/fifth candidates fade to zero while the leading materials survive")
	var four := sample(fixture("four"), 0.37)
	check(four.ids == PackedInt32Array([3, 0, 2, 1]), "Four-input ranking retains material identity")
	for slot in range(4): check(absf(four.weights[slot] - [0.36, 0.28, 0.24, 0.12][slot]) < 0.000001, "At most four positive materials keep their original ratios")
	var tied := sample(fixture("ties"), 0.5)
	check(tied.ids == PackedInt32Array([0, 1, 2, 3]) and tied.weights == PackedFloat32Array([0.25, 0.25, 0.25, 0.25]), "Equal-maximum tie uses the documented deterministic hard fallback")
	check(is_equal_approx(tied.discarded_weight, 0.75), "Tie fallback preserves the raw discard diagnostic")
	var tied_left := sample(fixture("ties"), 0.5 - 0.000001)
	var tied_right := sample(fixture("ties"), 0.5 + 0.000001)
	check(tied_left.ids == PackedInt32Array([0, 1, 2, 3]) and tied_right.ids == PackedInt32Array([4, 5, 6, 7]), "Degenerate tied leading palettes retain the documented discontinuity, rather than claiming global continuity")
	check(sample(fixture("empty"), 0.5).weights == PackedFloat32Array([0, 0, 0, 0]), "Empty controls stay unassigned")
	print("SOFT_LIMIT_CPU crossing_final_difference=", previous)

func test_gpu_kernel():
	var canvas := SubViewport.new(); canvas.size = Vector2i(32, 4); canvas.use_hdr_2d = true; canvas.transparent_bg = true; canvas.world_2d = World2D.new(); canvas.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(canvas)
	var shader := Shader.new()
	shader.code = """shader_type canvas_item;
render_mode unshaded, blend_disabled;
uniform sampler2D control_ids : filter_nearest;
uniform sampler2D control_weights : filter_nearest;
uniform vec2 field_origin = vec2(0.0);
uniform vec2 field_size = vec2(1.0);
uniform vec2 probes[32];
uniform bool height_blend_enabled = true;
""" + FileAccess.get_file_as_string("res://addons/strata/shaders/terrain_controls.gdshaderinc") + FileAccess.get_file_as_string("res://addons/strata/shaders/terrain_height_blend.gdshaderinc") + """
float alpha_for(int id) { return id == 0 ? 0.2 : id == 1 ? 0.35 : id == 2 ? 0.5 : id == 3 ? 0.8 : 0.65; }
float red_for(int id) { return id == 0 || id == 3 ? 1.0 : 0.0; }
void fragment() {
 ivec4 ids; vec4 weights; float discarded;
 terrain_blend(probes[int(FRAGCOORD.x)], ids, weights, discarded);
 vec4 heights; vec4 red;
 for (int slot=0;slot<4;slot++) { heights[slot]=alpha_for(ids[slot]); red[slot]=red_for(ids[slot]); }
 vec4 adjusted=terrain_height_blend_weights(weights, heights, vec4(16.0), vec4(0.0));
 float alpha=dot(adjusted, heights);
 if (FRAGCOORD.y < 1.0) { COLOR=weights; }
 else if (FRAGCOORD.y < 2.0) { COLOR=vec4(ids)/31.0; }
 else if (FRAGCOORD.y < 3.0) { COLOR=vec4(dot(adjusted,red), alpha, (alpha-0.5)*0.2+0.5, 1.0); }
 else { COLOR=vec4(discarded,0.0,0.0,1.0); }
}
"""
	var m := ShaderMaterial.new(); m.shader = shader
	var rect := ColorRect.new(); rect.size = Vector2(32, 4); rect.material = m; canvas.add_child(rect)
	var probes := PackedVector2Array()
	for x in [0.0, 0.1, 0.49, 0.4999, 0.49999, 0.499999, 0.5, 0.500001, 0.50001, 0.5001, 0.51, 0.9, 1.0]: probes.append(Vector2(x, 0.5))
	while probes.size() < 32: probes.append(Vector2(0.5, 0.5))
	m.set_shader_parameter("probes", probes)
	for kind in ["crossing", "four", "ties", "empty"]:
		var data := fixture(kind)
		m.set_shader_parameter("control_ids", ImageTexture.create_from_image(data.ids)); m.set_shader_parameter("control_weights", ImageTexture.create_from_image(data.weights))
		for index in range(4): await process_frame
		await RenderingServer.frame_post_draw
		var image := canvas.get_texture().get_image()
		for index in range(13):
			var cpu := sample(data, probes[index].x); var w := image.get_pixel(index, 0); var ids := image.get_pixel(index, 1)
			for slot in range(4):
				check(absf(w[slot] - cpu.weights[slot]) < 0.001, "GPU soft weights agree with CPU")
				check(roundi(ids[slot] * 31.0) == cpu.ids[slot], "GPU ranked IDs agree with CPU")
			check(absf(image.get_pixel(index, 3).r - cpu.discarded_weight) < 0.001, "GPU raw discarded mass agrees with CPU")
			if kind == "crossing":
				var c := image.get_pixel(index, 2)
				check(Vector3(c.r, c.g, c.b).distance_to(output(cpu)) < 0.002, "GPU color/height continuity survives contrast sixteen")
		if kind == "crossing":
			var a := image.get_pixel(5, 2); var b := image.get_pixel(7, 2)
			check(Vector3(a.r, a.g, a.b).distance_to(Vector3(b.r, b.g, b.b)) < 0.001, "GPU fourth/fifth exchange tends to the same surface response")
	# Positive control: restoring the old hard cap at the same probe locations
	# must expose the finite color/height jump this regression is intended to fix.
	var crossing := fixture()
	m.set_shader_parameter("control_ids", ImageTexture.create_from_image(crossing.ids)); m.set_shader_parameter("control_weights", ImageTexture.create_from_image(crossing.weights))
	var edit_target := "threshold = max(threshold, weights[candidate]);"
	check(shader.code.contains(edit_target), "Hard-cap positive control targets the fifth-weight calculation")
	shader.code = shader.code.replace(edit_target, "threshold = 0.0;")
	for index in range(4): await process_frame
	await RenderingServer.frame_post_draw
	var hard := canvas.get_texture().get_image()
	var left := hard.get_pixel(5, 2); var right := hard.get_pixel(7, 2)
	var hard_difference := Vector3(left.r, left.g, left.b).distance_to(Vector3(right.r, right.g, right.b))
	print("SOFT_LIMIT_GPU old_hard_cap_crossing_difference=", hard_difference)
	check(hard_difference > 0.2, "Control: the previous hard top-four has a finite material jump")
	canvas.free()

func test_production():
	check(configure(Rect2(-16, -16, 32, 32), func(_p: Vector2) -> float: return 0.0, flat(Color(1, 1, 0, 0.5))), "Configure production soft-limit surface")
	var pool: Array[StrataMaterial] = []
	for id in range(5):
		var item := StrataMaterial.new(); item.color_texture = flat(COLORS[id]); item.normal_texture = flat(Color(0.5, 0.5, 1)); item.ormh_texture = flat(Color(1, 1, 0, HEIGHTS[id])); item.displacement_strength = 1.0; item.height_blend_contrast = 16.0; pool.append(item)
	renderer._materials = pool; renderer._bind_material_pool()
	var data := fixture(); check(renderer.set_control_maps(data.ids, data.weights), "Neighboring four-slot palettes merge five IDs")
	renderer.displacement_strength = 0.2; renderer.displacement_radius = 1000.0; fade_camera.position = Vector3(0, 2, 0)
	top_view(Vector2.ZERO, 12.0)
	await render(3)
	override("vec3 probe_local=(inverse(MODEL_MATRIX)*(INV_VIEW_MATRIX*vec4(VERTEX,1.0))).xyz; ALBEDO=vec3(color.r,dot(weights,heights),probe_local.y+0.5);")
	var image: Image = await render(4)
	var color_error := 0.0; var height_error := 0.0; var vertex_error := 0.0
	for pixel in grid(8, 32):
		var ray := view.project_ray_origin(Vector2(pixel) + Vector2(0.5, 0.5)); var x := (ray.x + 16.0) / 32.0
		var expected := output(sample(data, x)); var c := image.get_pixelv(pixel)
		color_error = maxf(color_error, absf(c.r - expected.x)); height_error = maxf(height_error, absf(c.g - expected.y)); vertex_error = maxf(vertex_error, absf(c.b - expected.z))
	print("SOFT_LIMIT_PRODUCTION color_error=", color_error, " alpha_error=", height_error, " vertex_error=", vertex_error)
	check(color_error < 0.002 and height_error < 0.002, "Production color and ORMH height use the softened control weights and height competition")
	check(vertex_error < 0.002, "Production vertex relief follows the same softened height response")
	# The inherited mixed-LOD regression intentionally returns to one material.
	renderer._control_ids = null; renderer._control_weights = null
	material.height_blend_contrast = 0.0
