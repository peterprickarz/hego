extends Node3D
## Separate Forward+ terrain renderer exercise. All textures and terrain are synthetic fixtures.

const MAP_SIZE := 256
const HALF_SIZE := 128
const TEXTURE_SIZE := 128
const CONTROL_SIZE := 257
const MATERIAL_COUNT := 32

var source: StrataTerrain3D
var renderer: StrataRenderer
var camera: Camera3D
var _stats_label: Label
var _mode_label: Label
var _displacement_on := true
var _no_displacement_argument := false
var _lod_colors_on := false
var _auto_path := false
var _wireframe_on := false
var _dragging := false
var _yaw := 0.65
var _pitch := 0.20
var _distance := 65.0
var _orbit_target := Vector3(0.0, 6.0, 0.0)
var _frame_count := 0
var _benchmark := false
var _benchmark_frames := 300
var _benchmark_warmup := 60
var _capture_path := ""
var _report_path := ""
var _quit_after_frames := 0
var _cpu_samples: Array[float] = []
var _script_cpu_samples: Array[float] = []
var _renderer_cpu_samples: Array[float] = []
var _gpu_samples: Array[float] = []
var _benchmark_started_usec := 0
var _exit_code := 0
var _finishing := false
var _control_fixture_summary: Dictionary = {}

func _ready() -> void:
	if not _parse_user_args():
		get_tree().quit(2)
		return
	if _benchmark:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		DisplayServer.window_set_size(Vector2i(1920, 1080))
	else:
		DisplayServer.window_set_size(Vector2i(1280, 800))
	if _no_displacement_argument:
		_displacement_on = false
	_build_world()
	if not _build_terrain():
		get_tree().quit(2)
		return
	_build_camera()
	_build_ui()
	_update_stats()
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	if _benchmark:
		_benchmark_started_usec = Time.get_ticks_usec()

func _parse_user_args() -> bool:
	var args := OS.get_cmdline_user_args()
	for index in range(args.size()):
		var arg: String = args[index]
		if arg == "--benchmark":
			_benchmark = true
		elif arg == "--no-displacement":
			_no_displacement_argument = true
		elif arg == "--frames" and index + 1 < args.size():
			_benchmark_frames = int(args[index + 1])
		elif arg.begins_with("--frames="):
			_benchmark_frames = int(arg.trim_prefix("--frames="))
		elif arg == "--report" and index + 1 < args.size():
			_report_path = args[index + 1]
		elif arg.begins_with("--report="):
			_report_path = arg.trim_prefix("--report=")
		elif arg == "--capture" and index + 1 < args.size():
			_capture_path = args[index + 1]
		elif arg.begins_with("--capture="):
			_capture_path = arg.trim_prefix("--capture=")
		elif arg == "--quit-after-frames" and index + 1 < args.size():
			_quit_after_frames = maxi(1, int(args[index + 1]))
		elif arg.begins_with("--quit-after-frames="):
			_quit_after_frames = maxi(1, int(arg.trim_prefix("--quit-after-frames=")))
	if _benchmark:
		if _report_path.is_empty():
			push_error("Benchmark mode requires --report PATH")
			return false
		if _quit_after_frames > 0:
			push_error("Do not combine --benchmark with --quit-after-frames")
			return false
		if _benchmark_frames < 300:
			push_error("Benchmark mode requires at least 300 measured frames")
			return false
	return true

func _build_world() -> void:
	RenderingServer.set_default_clear_color(Color("18212b"))
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color("263b54")
	sky_material.sky_horizon_color = Color("b6c3cb")
	sky_material.ground_bottom_color = Color("252b31")
	sky_material.ground_horizon_color = Color("a6a69a")
	sky_material.sun_angle_max = 18.0
	sky.sky_material = sky_material
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.28
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world.environment = environment
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, -32.0, 0.0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	add_child(sun)

func _build_terrain() -> bool:
	source = StrataTerrain3D.new()
	source.name = "SyntheticHeightSource"
	source.base_bounds = Rect2(-HALF_SIZE, -HALF_SIZE, MAP_SIZE, MAP_SIZE)
	add_child(source)
	var height_layer := StrataLayer.new()
	height_layer.name = "SyntheticHeight"
	height_layer.data.sample_spacing = 1.0
	source.add_child(height_layer)
	for z in range(-HALF_SIZE, HALF_SIZE + 1):
		for x in range(-HALF_SIZE, HALF_SIZE + 1):
			height_layer.data.set_sample(&"height", Vector2i(x, z), _height_at(float(x), float(z)))

	var materials: Array[StrataMaterial] = []
	for index in range(MATERIAL_COUNT):
		materials.append(_make_material(index))
	renderer = StrataRenderer.new()
	renderer.name = "ForwardTerrainRenderer"
	source.add_child(renderer)
	if not renderer.configure(source, materials, 1.0):
		push_error("Could not configure the Forward+ terrain renderer.")
		return false
	renderer.displacement_enabled = _displacement_on
	renderer.displacement_strength = 1.0
	renderer.displacement_radius = 32.0
	renderer.debug_lod = _lod_colors_on
	var maps := _make_control_maps()
	if not renderer.set_control_maps(maps[0], maps[1]):
		push_error("Could not install the synthetic material control maps.")
		return false
	return true

func _height_at(x: float, z: float) -> float:
	var ridge := 7.0 * sin(x * 0.045 + sin(z * 0.025) * 2.0) * cos(z * 0.04)
	var hill_a := 15.0 * exp(-Vector2(x + 34.0, z - 18.0).length_squared() / 1250.0)
	var hill_b := 9.0 * exp(-Vector2(x - 48.0, z + 38.0).length_squared() / 900.0)
	return ridge + hill_a + hill_b

func _make_material(index: int) -> StrataMaterial:
	var palette := [Color("55765a"), Color("82905e"), Color("9b8662"), Color("a9b1b4"), Color("765e4f"), Color("4c7275"), Color("858b7a"), Color("9f9b91")]
	var base: Color = palette[index % palette.size()]
	var color_image := Image.create(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	var normal_image := Image.create(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	var ormh_image := Image.create(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	for y in range(TEXTURE_SIZE):
		for x in range(TEXTURE_SIZE):
			var wave := 0.88 + 0.12 * sin(TAU * float(x) / TEXTURE_SIZE) * cos(TAU * float(y) / TEXTURE_SIZE)
			color_image.set_pixel(x, y, Color(base.r * wave, base.g * wave, base.b * wave, 1.0))
			# Encode the normal derived from the same periodic height surface below.
			var u := TAU * float(x) / TEXTURE_SIZE
			var v := TAU * float(y) / TEXTURE_SIZE
			var amplitude := 0.1
			var frequency := 0.25 + float(index % 4) * 0.025
			var dhdx := amplitude * TAU * frequency * cos(u) * sin(v)
			var dhdz := amplitude * TAU * frequency * sin(u) * cos(v)
			var normal := Vector3(-dhdx, -dhdz, 1.0).normalized()
			normal_image.set_pixel(x, y, Color(normal.x * 0.5 + 0.5, normal.y * 0.5 + 0.5, normal.z * 0.5 + 0.5, 1.0))
			var height := 0.5 + 0.5 * sin(u) * sin(v)
			ormh_image.set_pixel(x, y, Color(1.0, 0.78, 0.0, height))
	color_image.generate_mipmaps()
	normal_image.generate_mipmaps()
	ormh_image.generate_mipmaps()
	var material := StrataMaterial.new()
	material.resource_name = "Generated fixture %02d" % index
	material.color_texture = ImageTexture.create_from_image(color_image)
	material.normal_texture = ImageTexture.create_from_image(normal_image)
	material.ormh_texture = ImageTexture.create_from_image(ormh_image)
	material.uv_scale = 0.25 + float(index % 4) * 0.025
	material.displacement_strength = 0.2
	return material

func _make_control_maps() -> Array:
	var ids := Image.create(CONTROL_SIZE, CONTROL_SIZE, false, Image.FORMAT_RGBA8)
	var weights := Image.create(CONTROL_SIZE, CONTROL_SIZE, false, Image.FORMAT_RGBAF)
	var used_materials: Dictionary = {}
	var all_weights_positive := true
	var all_slots_unique := true
	var max_weight_sum_error := 0.0
	for z in range(CONTROL_SIZE):
		for x in range(CONTROL_SIZE):
			var world := Vector2(float(x - HALF_SIZE), float(z - HALF_SIZE))
			var region_x := mini(3, floori(float(x) / 64.0))
			var region_z := mini(1, floori(float(z) / 128.0))
			var region := region_z * 4 + region_x
			var first_id := region * 4
			var permutation := 1 if (region_x + region_z) % 2 == 0 else 3
			var id0 := first_id
			var id1 := first_id + permutation
			var id2 := first_id + (2 if permutation == 1 else 1)
			var id3 := first_id + (3 if permutation != 3 else 2)
			var values := Vector4(0.2 + absf(sin(world.x * 0.025)), 0.2 + absf(cos(world.y * 0.021)), 0.2 + absf(sin((world.x + world.y) * 0.017)), 0.2 + absf(cos((world.x - world.y) * 0.019)))
			values /= values.x + values.y + values.z + values.w
			ids.set_pixel(x, z, Color(float(id0) / 255.0, float(id1) / 255.0, float(id2) / 255.0, float(id3) / 255.0))
			weights.set_pixel(x, z, Color(values.x, values.y, values.z, values.w))
			for material_id in [id0, id1, id2, id3]:
				used_materials[material_id] = true
			all_slots_unique = all_slots_unique and [id0, id1, id2, id3].size() == 4 and id0 != id1 and id0 != id2 and id0 != id3 and id1 != id2 and id1 != id3 and id2 != id3
			all_weights_positive = all_weights_positive and values.x > 0.0 and values.y > 0.0 and values.z > 0.0 and values.w > 0.0
			max_weight_sum_error = maxf(max_weight_sum_error, absf(values.x + values.y + values.z + values.w - 1.0))
	_control_fixture_summary = {
		"resolution": [CONTROL_SIZE, CONTROL_SIZE],
		"distinct_material_ids": used_materials.size(),
		"all_texels_have_four_distinct_ids": all_slots_unique,
		"all_texels_have_four_positive_weights": all_weights_positive,
		"max_weight_sum_error": max_weight_sum_error,
		"valid": used_materials.size() == MATERIAL_COUNT and all_slots_unique and all_weights_positive and max_weight_sum_error < 0.00001
	}
	if not _control_fixture_summary.valid:
		push_error("Generated control-map fixture failed its validity checks: %s" % JSON.stringify(_control_fixture_summary))
	return [ids, weights]

func _build_camera() -> void:
	camera = Camera3D.new()
	camera.fov = 52.0
	camera.far = 1200.0
	add_child(camera)
	_update_camera()
	renderer.set_camera(camera)

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var panel := PanelContainer.new()
	panel.position = Vector2(18.0, 18.0)
	panel.custom_minimum_size = Vector2(330.0, 0.0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.075, 0.09, 0.93)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", style)
	canvas.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	var heading := Label.new()
	heading.text = "Strata / Render lab"
	heading.add_theme_font_size_override("font_size", 21)
	box.add_child(heading)
	var note := Label.new()
	note.text = "Forward+ · synthetic 256 m heightfield\nGenerated 128 px material maps · 32 slots"
	note.add_theme_color_override("font_color", Color("b9c8d0"))
	box.add_child(note)
	_add_button(box, "Toggle displacement", func():
		_displacement_on = not _displacement_on
		renderer.displacement_enabled = _displacement_on
		_refresh_mode_label())
	_add_button(box, "Toggle LOD colors", func():
		_lod_colors_on = not _lod_colors_on
		renderer.debug_lod = _lod_colors_on
		renderer.force_lod_update()
		_refresh_mode_label())
	_add_button(box, "Toggle wireframe", func():
		_wireframe_on = not _wireframe_on
		renderer.wireframe = _wireframe_on
		_refresh_mode_label())
	_add_button(box, "Toggle fixed camera path", func():
		_auto_path = not _auto_path
		_refresh_mode_label())
	var help := Label.new()
	help.text = "Right drag orbit · wheel zoom\nWASD move · F free/fixed view"
	help.add_theme_color_override("font_color", Color("b9c8d0"))
	box.add_child(help)
	_mode_label = Label.new()
	box.add_child(_mode_label)
	_stats_label = Label.new()
	_stats_label.add_theme_color_override("font_color", Color("e3d9bb"))
	box.add_child(_stats_label)
	_refresh_mode_label()

func _add_button(parent: VBoxContainer, title: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = title
	button.pressed.connect(callback)
	parent.add_child(button)

func _refresh_mode_label() -> void:
	if _mode_label == null:
		return
	_mode_label.text = "Displacement %s · LOD colors %s · Wireframe %s\nCamera: %s" % ["ON" if _displacement_on else "OFF", "ON" if _lod_colors_on else "OFF", "ON" if _wireframe_on else "OFF", "path" if _auto_path else "orbit"]

func _process(delta: float) -> void:
	if _finishing:
		return
	var script_started := Time.get_ticks_usec()
	_frame_count += 1
	if _benchmark:
		_update_benchmark_camera(_frame_count)
	elif _auto_path:
		_update_benchmark_camera(_frame_count)
	if not _benchmark and not _auto_path:
		var move := Vector2.ZERO
		if Input.is_key_pressed(KEY_A): move.x -= 1.0
		if Input.is_key_pressed(KEY_D): move.x += 1.0
		if Input.is_key_pressed(KEY_W): move.y += 1.0
		if Input.is_key_pressed(KEY_S): move.y -= 1.0
		if move != Vector2.ZERO:
			var forward := Vector2(sin(_yaw), cos(_yaw))
			var right := Vector2(forward.y, -forward.x)
			var step: Vector2 = (right * move.x + forward * move.y) * delta * _distance * 0.35
			_orbit_target += Vector3(step.x, 0.0, step.y)
			_update_camera()
	if _frame_count % 20 == 0:
		_update_stats()
	if _benchmark:
		if _frame_count > _benchmark_warmup:
			_script_cpu_samples.append(float(Time.get_ticks_usec() - script_started) / 1000.0)
		_sample_benchmark()
	elif _quit_after_frames > 0 and _frame_count >= _quit_after_frames:
		_finish_capture_and_quit()

func _update_benchmark_camera(frame: int) -> void:
	var x := -112.0 + fposmod(float(frame - 1) * 0.42, 224.0)
	var z := 12.0 * sin(float(frame - 1) * 0.009)
	var y := _height_at(x, z) + 3.0
	camera.position = Vector3(x, y, z - 1.0)
	camera.look_at(Vector3(x + 18.0, _height_at(x + 18.0, z + 4.0) + 1.5, z + 4.0), Vector3.UP)

func _sample_benchmark() -> void:
	if _frame_count <= _benchmark_warmup:
		return
	_cpu_samples.append(RenderingServer.viewport_get_measured_render_time_cpu(get_viewport().get_viewport_rid()))
	_gpu_samples.append(RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()))
	_renderer_cpu_samples.append(float(renderer.get_stats().get("process_cpu_ms", 0.0)))
	if _cpu_samples.size() >= _benchmark_frames:
		if not _write_benchmark_report():
			_exit_code = 2
		_finish_capture_and_quit()

func _write_benchmark_report() -> bool:
	var stats: Dictionary = renderer.get_stats()
	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"graphics_adapter": {
			"name": RenderingServer.get_video_adapter_name(),
			"vendor": RenderingServer.get_video_adapter_vendor(),
			"api_version": RenderingServer.get_video_adapter_api_version()
		},
		"viewport": {
			"render_target_width": get_viewport().get_texture().get_size().x,
			"render_target_height": get_viewport().get_texture().get_size().y,
			"root_viewport_width": get_viewport().size.x,
			"root_viewport_height": get_viewport().size.y,
			"window_width": DisplayServer.window_get_size().x,
			"window_height": DisplayServer.window_get_size().y
		},
		"warmup_frames": _benchmark_warmup,
		"measured_frames": _cpu_samples.size(),
		"wall_seconds": float(Time.get_ticks_usec() - _benchmark_started_usec) / 1000000.0,
		"script_process_cpu_ms": _distribution(_script_cpu_samples),
		"renderer_process_cpu_ms": _distribution(_renderer_cpu_samples),
		"viewport_render_cpu_ms": _distribution(_cpu_samples),
		"viewport_render_gpu_ms": _distribution(_gpu_samples),
		"gpu_timing_available": _mean(_gpu_samples) > 0.0,
		"render_settings": {
			"displacement_enabled": _displacement_on,
			"global_displacement_strength": renderer.displacement_strength,
			"displacement_radius_m": renderer.displacement_radius,
			"per_material_displacement_strength": 0.2,
			"camera_path": "frame-indexed near-ground path",
			"vsync": "disabled"
		},
		"renderer_stats": stats,
		"fixture": {"map_size_m": MAP_SIZE, "material_slots": MATERIAL_COUNT, "textures_are_generated": true, "control_maps": _control_fixture_summary}
	}
	var file := FileAccess.open(_report_path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write benchmark report to %s" % _report_path)
		return false
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("Render benchmark report: %s" % _report_path)
	return true

func _distribution(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {"count": 0, "mean_ms": 0.0, "median_ms": 0.0, "p95_ms": 0.0, "max_ms": 0.0}
	var sorted: Array[float] = values.duplicate()
	sorted.sort()
	var middle := floori(float(sorted.size()) / 2.0)
	var median := sorted[middle] if sorted.size() % 2 == 1 else (sorted[middle - 1] + sorted[middle]) * 0.5
	var p95_index := mini(sorted.size() - 1, ceili(float(sorted.size() - 1) * 0.95))
	return {"count": sorted.size(), "mean_ms": _mean(values), "median_ms": median, "p95_ms": sorted[p95_index], "max_ms": sorted.back()}

func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / values.size()

func _update_stats() -> void:
	if _stats_label == null:
		return
	var stats: Dictionary = renderer.get_stats()
	var rid := get_viewport().get_viewport_rid()
	var render_cpu := RenderingServer.viewport_get_measured_render_time_cpu(rid)
	var render_gpu := RenderingServer.viewport_get_measured_render_time_gpu(rid)
	_stats_label.text = "patches %s · triangles %s\nLOD update %.3f ms · height refresh %.3f ms\nRenderer %.3f ms · lab %.3f ms\nViewport CPU %s · GPU %s" % [str(stats.get("patches", "?")), str(stats.get("triangles", "?")), float(stats.get("last_lod_cpu_ms", 0.0)), float(stats.get("height_refresh_cpu_ms", 0.0)), float(stats.get("process_cpu_ms", 0.0)), (_script_cpu_samples.back() if not _script_cpu_samples.is_empty() else 0.0), _timing_label(render_cpu), _timing_label(render_gpu)]

func _timing_label(milliseconds: float) -> String:
	return "%.3f ms" % milliseconds if milliseconds > 0.0 else "unavailable"

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F:
			_auto_path = not _auto_path
			_refresh_mode_label()
		elif event.keycode == KEY_ESCAPE and _quit_after_frames == 0 and not _benchmark:
			_finish_capture_and_quit()
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = maxf(3.0, _distance * 0.9)
			_update_camera()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = minf(600.0, _distance * 1.1)
			_update_camera()
	elif event is InputEventMouseMotion and _dragging:
		_yaw -= event.relative.x * 0.006
		_pitch = clampf(_pitch + event.relative.y * 0.005, 0.15, 1.4)
		_auto_path = false
		_update_camera()
		_refresh_mode_label()

func _update_camera() -> void:
	camera.position = _orbit_target + Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * _distance
	camera.look_at(_orbit_target)

func _finish_capture_and_quit() -> void:
	if _finishing:
		return
	_finishing = true
	if not _capture_path.is_empty():
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		var error := image.save_png(_capture_path)
		if error != OK:
			push_error("Could not save render-lab screenshot: %s" % error_string(error))
			_exit_code = 2
		else:
			print("Render-lab screenshot: %s" % _capture_path)
	get_tree().quit(_exit_code)
