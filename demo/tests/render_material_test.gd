extends SceneTree
## CPU categorical blending reference tests; optional real Forward+ lab capture.

var _failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _check(condition: bool, description: String) -> void:
	if not condition:
		_failures.append(description)
		push_error(description)

static func _encoded(values: Array) -> Color:
	return Color(float(values[0]) / 255.0, float(values[1]) / 255.0, float(values[2]) / 255.0, float(values[3]) / 255.0)

func _run() -> void:
	var bounds := Rect2(-128.0, -128.0, 256.0, 256.0)
	var ids := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	var weights := Image.create(2, 2, false, Image.FORMAT_RGBAF)
	var permutations := [[0, 1, 2, 3], [3, 0, 2, 1], [1, 3, 0, 2], [2, 1, 3, 0]]
	var source_ids := [2, 7, 11, 19]
	var source_weights := [0.4, 0.3, 0.2, 0.1]
	for corner in range(4):
		var ordered_ids: Array = []
		var ordered_weights: Array = []
		for slot in permutations[corner]:
			ordered_ids.append(source_ids[slot])
			ordered_weights.append(source_weights[slot])
		ids.set_pixel(corner % 2, corner / 2, _encoded(ordered_ids))
		weights.set_pixel(corner % 2, corner / 2, Color(ordered_weights[0], ordered_weights[1], ordered_weights[2], ordered_weights[3]))
	for position in [Vector2(-128.0, -128.0), Vector2(128.0, 128.0), Vector2(-33.28, 18.0), Vector2.ZERO]:
		var result := StrataRenderer.blend_control_samples(ids, weights, position, bounds)
		_check(result.ids == PackedInt32Array(source_ids), "Permuted categorical slots preserve material identity")
		for slot in range(4):
			_check(absf(result.weights[slot] - source_weights[slot]) < 0.000001, "By-ID merge preserves the same underlying mixture")
		_check(absf(result.discarded_weight) < 0.000001, "Four distinct IDs discard no contribution")
	# Sixteen equal contributions: deterministic lower-ID ties, 75% discarded.
	for corner in range(4):
		ids.set_pixel(corner % 2, corner / 2, _encoded([corner * 4, corner * 4 + 1, corner * 4 + 2, corner * 4 + 3]))
	weights.fill(Color(0.25, 0.25, 0.25, 0.25))
	var truncated := StrataRenderer.blend_control_samples(ids, weights, Vector2.ZERO, bounds)
	_check(truncated.ids == PackedInt32Array([0, 1, 2, 3]), "Top-four ties resolve deterministically by ascending ID")
	_check(absf(truncated.discarded_weight - 0.75) < 0.000001, "Discarded-weight diagnostic exposes sixteen-to-four truncation")
	for weight in truncated.weights:
		_check(absf(weight - 0.25) < 0.000001, "Retained top-four weights are normalized")
	weights.fill(Color(0.0, 0.0, 0.0, 0.0))
	var empty := StrataRenderer.blend_control_samples(ids, weights, Vector2.ZERO, bounds)
	_check(empty.weights == PackedFloat32Array([0, 0, 0, 0]), "Empty controls remain unassigned without resurrecting material zero")
	print("Render material CPU reference: %s" % ("PASS" if _failures.is_empty() else "FAIL"))
	if OS.get_cmdline_user_args().has("--render-lab"):
		if DisplayServer.get_name() == "headless" or RenderingServer.get_rendering_device() == null:
			_check(false, "Real rendering check requires a graphical Forward+ device")
		else:
			await _test_gpu_control_blend()
			await _render_lab()
	quit(0 if _failures.is_empty() else 1)

func _test_gpu_control_blend() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(8, 6)
	viewport.use_hdr_2d = true
	viewport.transparent_bg = true
	viewport.world_2d = World2D.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var shader := Shader.new()
	shader.code = """shader_type canvas_item;
render_mode blend_disabled, unshaded;
uniform sampler2D control_ids : filter_nearest;
uniform sampler2D control_weights : filter_nearest;
uniform vec2 field_origin = vec2(0.0);
uniform vec2 field_size = vec2(1.0);
uniform vec2 sample_position = vec2(0.5);
void terrain_control_corner(vec2 position, ivec2 offset, out ivec4 ids, out vec4 weights, out vec2 fraction) {
 ivec2 dimensions = textureSize(control_ids, 0);
 vec2 grid = clamp((position - field_origin) / field_size, vec2(0.0), vec2(1.0)) * vec2(dimensions - ivec2(1));
 fraction = fract(grid);
 ivec2 texel = min(ivec2(floor(grid)) + offset, dimensions - ivec2(1));
 ids = ivec4(round(texelFetch(control_ids, texel, 0) * 255.0));
 weights = texelFetch(control_weights, texel, 0);
}
""" + FileAccess.get_file_as_string("res://addons/strata/shaders/terrain_controls.gdshaderinc") + """
void fragment() {
 ivec4 ids; vec4 weights; float discarded;
 terrain_blend(sample_position, ids, weights, discarded);
 if (UV.y < 0.333333) { COLOR = vec4(ids) / 31.0; }
 else if (UV.y < 0.666667) { COLOR = weights; }
 else { COLOR = vec4(discarded, 0.0, 0.0, 1.0); }
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	var rect := ColorRect.new()
	rect.size = Vector2(8.0, 6.0)
	rect.material = material
	viewport.add_child(rect)
	var ids := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	var weights := Image.create(2, 2, false, Image.FORMAT_RGBAF)
	for fixture in range(2):
		for corner in range(4):
			if fixture == 0:
				var order: Array = [[2, 7, 11, 19], [19, 2, 11, 7], [7, 19, 2, 11], [11, 7, 19, 2]][corner]
				ids.set_pixel(corner % 2, corner / 2, _encoded(order))
				var values := Color()
				for slot in range(4): values[slot] = {2: 0.4, 7: 0.3, 11: 0.2, 19: 0.1}[order[slot]]
				weights.set_pixel(corner % 2, corner / 2, values)
			else:
				ids.set_pixel(corner % 2, corner / 2, _encoded([corner * 4, corner * 4 + 1, corner * 4 + 2, corner * 4 + 3]))
				weights.set_pixel(corner % 2, corner / 2, Color(0.25, 0.25, 0.25, 0.25))
		material.set_shader_parameter("control_ids", ImageTexture.create_from_image(ids))
		material.set_shader_parameter("control_weights", ImageTexture.create_from_image(weights))
		await process_frame
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		var gpu_ids := image.get_pixel(4, 0)
		var gpu_weights := image.get_pixel(4, 3)
		var gpu_discarded := image.get_pixel(4, 5).r
		var cpu := StrataRenderer.blend_control_samples(ids, weights, Vector2(0.5, 0.5), Rect2(0.0, 0.0, 1.0, 1.0))
		for slot in range(4):
			_check(roundi(gpu_ids[slot] * 31.0) == cpu.ids[slot], "GPU shared blend function agrees with CPU categorical IDs")
			_check(absf(gpu_weights[slot] - cpu.weights[slot]) < 0.002, "GPU shared blend function agrees with CPU normalized weights")
		_check(absf(gpu_discarded - cpu.discarded_weight) < 0.002, "GPU shared blend function agrees with CPU discarded contribution")
	print("GPU categorical readback (permuted slots, sixteen-ID ties): %s" % ("PASS" if _failures.is_empty() else "FAIL"))
	viewport.free()

func _render_lab() -> void:
	var packed: PackedScene = load("res://scenes/terrain_prototype/render_lab.tscn")
	var lab: Variant = packed.instantiate()
	root.add_child(lab)
	current_scene = lab
	if OS.get_cmdline_user_args().has("--probe-no-shadows"):
		for child in lab.get_children():
			if child is DirectionalLight3D:
				child.shadow_enabled = false
	if OS.get_cmdline_user_args().has("--probe-root-lod"):
		lab.renderer.min_patch_size = lab.renderer._source.base_bounds.size.x
		lab.renderer.force_lod_update()
	if OS.get_cmdline_user_args().has("--probe-flat-color"):
		var shader: Shader = lab.renderer._shader_material.shader.duplicate()
		shader.code = shader.code.replace('#include "terrain_controls.gdshaderinc"', FileAccess.get_file_as_string("res://addons/strata/shaders/terrain_controls.gdshaderinc")).replace('#include "terrain_texture_dispatch.gdshaderinc"', FileAccess.get_file_as_string("res://addons/strata/shaders/terrain_texture_dispatch.gdshaderinc")).replace("render_mode cull_back,", "render_mode unshaded, cull_back,").replace("ALBEDO = color;", "ALBEDO = vec3(0.1, 0.4, 0.1);")
		lab.renderer._shader_material.shader = shader
	for frame in range(12):
		await process_frame
	await RenderingServer.frame_post_draw
	var renderer: StrataRenderer = lab.renderer
	var stats := renderer.get_stats()
	print("Render material GPU adapter=%s api=%s stats=%s" % [RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version(), stats])
	_check(int(stats.patches) > 0, "Native quadtree renderer creates patch instances")
	_check(int(stats.material_count) == 32, "Renderer binds the complete 32-material source pool")
	_check(stats.height_resolution.x > 1 and stats.height_resolution.y > 1, "Renderer samples a finite base-height texture")
	var colors: Variant = renderer._shader_material.get_shader_parameter("color_maps")
	var normals: Variant = renderer._shader_material.get_shader_parameter("normal_maps")
	var packed_maps: Variant = renderer._shader_material.get_shader_parameter("ormh_maps")
	_check(colors.size() == 32 and normals.size() == 32 and packed_maps.size() == 32, "All 96 direct source textures remain individually referenced")
	var uniforms := renderer._shader_material.shader.get_shader_uniform_list()
	_check(uniforms.size() > 10, "Full spatial shader compiled with its declared uniforms")
	var first_instances := renderer._patches.values()
	renderer.force_lod_update()
	_check(renderer._patches.values() == first_instances, "An unchanged leaf set retains its MeshInstance3D nodes")
	var image := root.get_texture().get_image()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			var path := argument.trim_prefix("--capture=")
			_check(image.save_png(path) == OK, "Rendered material lab capture saved")
	print("Render material GPU: %s" % ("PASS" if _failures.is_empty() else "FAIL"))
	lab.free()
