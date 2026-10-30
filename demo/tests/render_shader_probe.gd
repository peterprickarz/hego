extends SceneTree
## Run on a real Vulkan display, not --headless, to validate descriptor binding.

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var device := RenderingServer.get_rendering_device()
	if device == null:
		push_error("Probe requires Forward+ Vulkan RenderingDevice.")
		quit(2)
		return
	print("PROBE adapter=%s api=%s" % [RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version()])
	print("PROBE textures/stage=%d samplers/stage=%d textures/set=%d samplers/set=%d" % [device.limit_get(RenderingDevice.LIMIT_MAX_TEXTURES_PER_SHADER_STAGE), device.limit_get(RenderingDevice.LIMIT_MAX_SAMPLERS_PER_SHADER_STAGE), device.limit_get(RenderingDevice.LIMIT_MAX_TEXTURES_PER_UNIFORM_SET), device.limit_get(RenderingDevice.LIMIT_MAX_SAMPLERS_PER_UNIFORM_SET)])
	root.size = Vector2i(1024, 512)
	var scene := Node3D.new()
	root.add_child(scene)
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 0.0, 2.0)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	scene.add_child(camera)
	var shader := Shader.new()
	var shader_code := """shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D color_maps[32] : filter_nearest;
uniform sampler2D normal_maps[32] : filter_nearest;
uniform sampler2D ormh_maps[32] : filter_nearest;
uniform sampler2D height_field : filter_nearest;
uniform sampler2D control_ids : filter_nearest;
uniform sampler2D control_weights : filter_nearest;
void fragment() {
 int id = clamp(int(floor(UV.x * 32.0)), 0, 31);
 vec2 dx = dFdx(UV); vec2 dy = dFdy(UV);
 vec4 color = terrain_color_grad(id, UV, dx, dy);
 vec4 normal = terrain_normal_grad(id, UV, dx, dy);
 vec4 packed = terrain_ormh_grad(id, UV, dx, dy);
 float field = texture(height_field,UV).r + texture(control_ids,UV).r + texture(control_weights,UV).r;
 ALBEDO = vec3(color.r, normal.g, packed.a) * 0.8 + vec3(field * 0.03);
}
"""
	shader.code = shader_code.replace("void fragment()", FileAccess.get_file_as_string("res://addons/strata/shaders/terrain_texture_dispatch.gdshaderinc") + "\nvoid fragment()")
	var material := ShaderMaterial.new()
	material.shader = shader
	for family in ["color_maps", "normal_maps", "ormh_maps"]:
		var textures: Array[Texture2D] = []
		for index in range(32):
			var value := float(index + 1) / 32.0
			var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
			image.fill(Color(value, value, value, value))
			textures.append(ImageTexture.create_from_image(image))
		material.set_shader_parameter(family, textures)
	for field in ["height_field", "control_ids", "control_weights"]:
		var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.5, 0.5, 0.5, 1.0))
		material.set_shader_parameter(field, ImageTexture.create_from_image(image))
	var instance := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(4.0, 2.0)
	instance.mesh = quad
	instance.material_override = material
	scene.add_child(instance)
	for frame in range(8):
		await process_frame
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image()
	var left := result.get_pixel(32, 256)
	var right := result.get_pixel(990, 256)
	print("PROBE rendered left=%s right=%s delta=%f" % [left, right, right.r - left.r])
	var output := "user://render-binding-probe.png"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			output = argument.trim_prefix("--capture=")
	var saved := result.save_png(output) == OK
	var passed := right.r > left.r + 0.2 and absf(right.r - right.g) < 0.05 and absf(right.g - right.b) < 0.05
	var previous := -1.0
	for index in range(32):
		var pixel := result.get_pixel(16 + index * 32, 256)
		passed = passed and pixel.r > previous + 0.003 and absf(pixel.r - pixel.g) < 0.05 and absf(pixel.g - pixel.b) < 0.05
		previous = pixel.r
	passed = passed and saved
	print("PROBE 32x3+3 direct textures constant-dispatch textureGrad=%s capture=%s" % ["PASS" if passed else "FAIL", output])
	quit(0 if passed else 1)
