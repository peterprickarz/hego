extends SceneTree
## StrataRenderSettings.custom_light_include in the real Forward+ terrain shader:
## a light() that reads both varyings changes the image and generates a shader,
## editing the include's code regenerates it without touching the settings, code
## that does not compile keeps the built-in light model, and clearing the property
## restores the plain shader file.
const BLUE_LIGHT := "void light() {\n\tDIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI;\n\t// Both varyings hold usable values on the terrain: the plane is at y = 0 and SPECULAR is 0.5.\n\tfloat on_terrain = step(-100.0, strata_world_position.y) * step(0.25, strata_specular);\n\tSPECULAR_LIGHT += vec3(0.0, 0.0, 0.6) * on_terrain;\n}"
const RED_LIGHT := "void light() {\n\tDIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI;\n\tfloat on_terrain = step(-100.0, strata_world_position.y) * step(0.25, strata_specular);\n\tSPECULAR_LIGHT += vec3(0.6, 0.0, 0.0) * on_terrain;\n}"
const BROKEN_LIGHT := "void light() {\n\tDIFFUSE_LIGHT += undefined_value;\n}"
var failures := 0
var viewport: SubViewport
var renderer: StrataRenderer
var terrain: StrataTerrain3D
var camera: Camera3D
var pixels: Array = []  # Vector2i of pixels that show the terrain

func _initialize() -> void: run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func texture(color: Color) -> ImageTexture:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBAF); image.fill(color)
	return ImageTexture.create_from_image(image)

func draw(frames: int = 8) -> Image:
	for index in range(frames): await process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

## Largest 8-bit channel difference over the terrain pixels.
func max_difference(a: Image, b: Image) -> int:
	var largest := 0
	for pixel: Vector2i in pixels:
		var x := a.get_pixelv(pixel); var y := b.get_pixelv(pixel)
		largest = maxi(largest, roundi(maxf(maxf(absf(x.r - y.r), absf(x.g - y.g)), absf(x.b - y.b)) * 255.0))
	return largest

## Share of the terrain pixels whose channel rose by more than 8/255.
func raised_share(after: Image, before: Image, channel: int) -> float:
	var count := 0
	for pixel: Vector2i in pixels:
		if after.get_pixelv(pixel)[channel] - before.get_pixelv(pixel)[channel] > 8.0 / 255.0: count += 1
	return float(count) / maxf(1.0, pixels.size())

func plane_point(pixel: Vector2) -> Vector3:
	var origin := camera.project_ray_origin(pixel)
	var direction := camera.project_ray_normal(pixel)
	return terrain.to_local(origin + direction * (-origin.y / direction.y))

func classify() -> void:
	pixels = []
	for y in range(viewport.size.y):
		for x in range(viewport.size.x):
			var point := plane_point(Vector2(x + 0.5, y + 0.5))
			if absf(point.x) < 14.0 and absf(point.z) < 14.0: pixels.append(Vector2i(x, y))

func light_stat(name: String) -> bool:
	return bool(renderer.get_stats().get(name, false))

func run() -> void:
	create_timer(180.0).timeout.connect(func() -> void: push_error("Light include test watchdog"); quit(1))
	if RenderingServer.get_rendering_device() == null or DisplayServer.get_name() == "headless":
		push_error("Use a graphical Forward+ run"); quit(2); return
	viewport = SubViewport.new(); viewport.size = Vector2i(160, 120); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var world := Node3D.new(); viewport.add_child(world)
	terrain = StrataTerrain3D.new(); terrain.base_bounds = Rect2(-16, -16, 32, 32); world.add_child(terrain)
	renderer = StrataRenderer.new(); terrain.add_child(renderer); renderer.displacement_enabled = false
	var ground := StrataMaterial.new()
	ground.color_texture = texture(Color(0.4, 0.4, 0.3)); ground.normal_texture = texture(Color(0.5, 0.5, 1.0))
	ground.ormh_texture = texture(Color(1.0, 0.8, 0.0, 0.5)); ground.uv_scale = 0.25
	var pool: Array[StrataMaterial] = [ground]
	var field := Image.create(33, 33, false, Image.FORMAT_RF)
	check(renderer.configure_compiled_field(terrain, pool, {"ok": true, "image": field, "bounds": terrain.base_bounds, "resolution": field.get_size(), "sample_step_x": Vector3.RIGHT, "sample_step_y": Vector3.BACK, "min": 0.0, "max": 0.0}), "Configure the terrain with one material")
	var settings := StrataRenderSettings.new()
	renderer.render_settings = settings
	camera = Camera3D.new(); camera.fov = 60.0; camera.position = Vector3(0.0, 14.0, 26.0)
	world.add_child(camera); camera.look_at(Vector3.ZERO); camera.current = true; renderer.set_camera(camera)
	var environment := WorldEnvironment.new(); environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR; environment.environment.background_color = Color.BLACK
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; environment.environment.ambient_light_color = Color.WHITE; environment.environment.ambient_light_energy = 0.3
	world.add_child(environment)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0); sun.shadow_enabled = false; world.add_child(sun)
	classify()
	check(pixels.size() > 1000, "The terrain covers a useful share of the view")
	var plain: Shader = load(StrataRenderer.SURFACE_SHADER_PATH)

	# (1) Default: the plain shader file and no custom light.
	var base := await draw()
	check(renderer._shader_material.shader == plain, "Without a light include the renderer uses the plain shader file")
	check(not light_stat("custom_light_active") and not light_stat("custom_light_failed"), "Stats report no custom light by default")

	# (2) A light() that reads both varyings and adds a fixed blue highlight.
	var include := ShaderInclude.new()
	include.code = BLUE_LIGHT
	settings.custom_light_include = include
	var blue := await draw()
	var generated := renderer._shader_material.shader
	check(generated != plain and generated.code.begins_with("#define STRATA_CUSTOM_LIGHT\n"), "A light include generates a shader")
	check(light_stat("custom_light_active") and not light_stat("custom_light_failed"), "Stats report the light include as active")
	var blue_share := raised_share(blue, base, 2)
	print("LIGHT blue raised share=%.3f" % blue_share)
	check(blue_share > 0.98, "The included light() changes the terrain's lighting")

	# (3) New code in the same include regenerates the shader; the settings are not touched.
	include.code = RED_LIGHT
	var red := await draw()
	var red_share := raised_share(red, blue, 0)
	print("LIGHT red raised share=%.3f" % red_share)
	check(renderer._shader_material.shader != generated and red_share > 0.98, "Editing the include's code reaches the terrain")
	check(light_stat("custom_light_active"), "The edited include is active")

	# (4) Code that does not compile keeps Godot's built-in light model.
	include.code = BROKEN_LIGHT
	var broken := await draw()
	var broken_difference := max_difference(broken, base)
	print("LIGHT broken max difference=%d" % broken_difference)
	check(broken_difference <= 1, "A light include that does not compile renders with the built-in light model")
	check(light_stat("custom_light_failed") and not light_stat("custom_light_active"), "Stats report the failed light include")

	# (5) Clearing the property restores the plain shader file.
	include.code = BLUE_LIGHT
	await draw(2)
	settings.custom_light_include = null
	var restored := await draw()
	check(renderer._shader_material.shader == plain, "Without a light include the plain shader file returns")
	check(not light_stat("custom_light_active") and not light_stat("custom_light_failed"), "Stats report no custom light after clearing")
	check(restored.get_data() == base.get_data(), "The plain path renders byte-identically")
	print("TERRAIN_LIGHT_INCLUDE_TEST failures=", failures)
	viewport.free()
	quit(0 if failures == 0 else 1)
