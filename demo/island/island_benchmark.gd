extends SceneTree
## Deterministic, whole-viewport benchmark for the cached island showcase.
## It reports renderer CPU separately; viewport GPU timing includes the whole scene.

const SCENE_PATH := "res://island/island_showcase.tscn"
const PHASES := ["overview", "walk", "fast_traversal", "teleports"]
const MODE_NAMES := ["displacement_on", "displacement_off"]
## Materials the installed registry declares; the renderer always holds 32 slots.
var MATERIAL_SLOT_COUNT := HEGoIslandMaterialRegistry.count()
const CONTROL_BLEND_SLOT_COUNT := 4
const WALK_SPEED_M_S := 6.0
const FAST_SPEED_M_S := 120.0
const SIMULATION_HZ := 60.0
const WALK_RADIUS_M := 60.0
const WALK_CENTER := Vector2(-1008.0, 692.0)
const FAST_ROUTE_START := Vector2(-1800.0, -1650.0)
const FAST_ROUTE_END := Vector2(1800.0, 1650.0)
const SEA_LEVEL_M := 0.0

signal _showcase_gate

var _frames := 300
var _warmup := 60
var _report_path := ""
var _capture_dir := ""
var _texture_stress := false
var _check_only := false
var _source: StrataTerrain3D
var _renderer: StrataRenderer
var _camera: Camera3D
var _viewport: Viewport
var _exit_code := 0
var _showcase_ready_value := false
var _source_set_count := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if not _parse_args():
		quit(2)
		return
	var registry := HEGoIslandMaterialRegistry.registry()
	if not registry.get("ok", false):
		push_error("Island benchmark requires the validated real-source registry: %s" % registry.get("message", "missing registry"))
		quit(2)
		return
	_source_set_count = registry.entries.size()
	if _check_only:
		print("Island benchmark script parsed successfully; validated real source sets=%d." % _source_set_count)
		quit(0)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	var scene_error := change_scene_to_file(SCENE_PATH)
	if scene_error != OK:
		push_error("Could not load cached island showcase: %s" % error_string(scene_error))
		quit(2)
		return
	await process_frame
	await process_frame
	var scene_root := current_scene
	if scene_root == null:
		push_error("Island showcase did not create a current scene.")
		quit(2)
		return
	if not await _wait_for_showcase(scene_root):
		push_error("Cached island did not report showcase_ready within 300 seconds.")
		quit(2)
		return
	if scene_root.has_method("set_player_enabled"):
		scene_root.call("set_player_enabled", false)
	_source = _find_node(scene_root, "StrataTerrain3D") as StrataTerrain3D
	_renderer = _find_node(scene_root, "StrataRenderer") as StrataRenderer
	_camera = _find_camera(scene_root)
	if _source == null or _renderer == null or _camera == null:
		push_error("Island scene needs a terrain source, StrataRenderer, and Camera3D.")
		quit(2)
		return
	if _source.runtime_data == null or _source.runtime_bake_stale or not _source.runtime_data.is_resident() or _source.runtime_data.resolution != Vector2i(4097, 4097):
		push_error("Benchmark requires a current, resident 4097x4097 compiled runtime cache; visual preview data is not enough.")
		quit(2)
		return
	_viewport = scene_root.get_viewport()
	_camera.current = true
	_camera.far = 12000.0
	if _has_property(_camera, "input_enabled"):
		_camera.set("input_enabled", false)
	RenderingServer.viewport_set_measure_render_time(_viewport.get_viewport_rid(), true)
	await RenderingServer.frame_post_draw
	var initial_stats: Dictionary = _renderer.get_stats()
	if int(initial_stats.get("material_count", 0)) != MATERIAL_SLOT_COUNT or Vector2i(initial_stats.get("control_resolution", Vector2i.ZERO)) == Vector2i.ZERO:
		push_error("Benchmark fixture must load %d material slots and nonempty control maps; got %s." % [MATERIAL_SLOT_COUNT, initial_stats])
		quit(2)
		return
	var bound_inventory := _material_inventory()
	for kind in ["unique_color_textures", "unique_normal_textures", "unique_ormh_textures"]:
		if int(bound_inventory.get(kind, 0)) != _source_set_count:
			push_error("Actual material bindings disagree with the validated source registry: %s=%d, sources=%d." % [kind, int(bound_inventory.get(kind, 0)), _source_set_count])
			quit(2)
			return
	if Vector2i(initial_stats.get("height_resolution", Vector2i.ZERO)) != Vector2i(4097, 4097):
		push_error("Renderer must be drawing the full 4097x4097 compiled field, got %s." % initial_stats.get("height_resolution"))
		quit(2)
		return
	if RenderingServer.get_current_rendering_method() != "forward_plus":
		push_error("Benchmark requires Forward+, got %s." % RenderingServer.get_current_rendering_method())
		quit(2)
		return
	var actual_size := _viewport.get_texture().get_size()
	if actual_size != Vector2(1920.0, 1080.0):
		push_error("Benchmark requires a 1920x1080 render target, got %s." % actual_size)
		quit(2)
		return
	var report: Dictionary = await _run_phases()
	if report.is_empty():
		quit(2)
		return
	report["material_inventory"] = _material_inventory()
	if _texture_stress:
		var stress_result: Dictionary = await _run_texture_stress_pass(scene_root)
		if not stress_result.get("ok", false):
			push_error("Synthetic 32-material residency stress failed: %s" % stress_result.get("message", "unknown error"))
			quit(2)
			return
		report["synthetic_texture_residency_stress"] = stress_result
	var file := FileAccess.open(_report_path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write benchmark report: %s" % _report_path)
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("Island benchmark report: %s" % _report_path)
	quit(_exit_code)

func _parse_args() -> bool:
	var args := OS.get_cmdline_user_args()
	for index in range(args.size()):
		var arg: String = args[index]
		if arg == "--frames" and index + 1 < args.size():
			_frames = int(args[index + 1])
		elif arg.begins_with("--frames="):
			_frames = int(arg.trim_prefix("--frames="))
		elif arg == "--warmup" and index + 1 < args.size():
			_warmup = int(args[index + 1])
		elif arg.begins_with("--warmup="):
			_warmup = int(arg.trim_prefix("--warmup="))
		elif arg == "--report" and index + 1 < args.size():
			_report_path = args[index + 1]
		elif arg.begins_with("--report="):
			_report_path = arg.trim_prefix("--report=")
		elif arg == "--capture-dir" and index + 1 < args.size():
			_capture_dir = args[index + 1]
		elif arg.begins_with("--capture-dir="):
			_capture_dir = arg.trim_prefix("--capture-dir=")
		elif arg == "--texture-stress":
			_texture_stress = true
		elif arg == "--check-only":
			_check_only = true
	if not _check_only and (_frames < 300 or _warmup < 60 or _report_path.is_empty()):
		push_error("Use --frames >= 300, --warmup >= 60, and an explicit --report PATH.")
		return false
	return true

func _wait_for_showcase(scene_root: Node) -> bool:
	if not scene_root.has_signal("showcase_ready"):
		push_error("Island scene does not expose showcase_ready.")
		return false
	if bool(scene_root.get("ready_for_capture")):
		return true
	scene_root.connect("showcase_ready", _on_showcase_ready, CONNECT_ONE_SHOT)
	var timer := create_timer(300.0)
	timer.timeout.connect(_on_showcase_timeout, CONNECT_ONE_SHOT)
	if bool(scene_root.get("ready_for_capture")):
		_showcase_ready_value = true
		_showcase_gate.emit()
	await _showcase_gate
	return _showcase_ready_value

func _on_showcase_ready() -> void:
	_showcase_ready_value = true
	_showcase_gate.emit()

func _on_showcase_timeout() -> void:
	_showcase_ready_value = false
	_showcase_gate.emit()

func _run_phases() -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	var phase_reports: Dictionary = {}
	var renderer_stats: Dictionary = _renderer.get_stats()
	var viewport_size := _viewport.get_texture().get_size()
	for mode in MODE_NAMES:
		_renderer.displacement_enabled = mode == "displacement_on"
		for phase_name in PHASES:
			var cpu: Array[float] = []
			var gpu: Array[float] = []
			var renderer_cpu: Array[float] = []
			var frame_ms: Array[float] = []
			var previous_frame_usec := Time.get_ticks_usec()
			for frame in range(_warmup + _frames):
				_set_camera_for_phase(phase_name, frame)
				await RenderingServer.frame_post_draw
				var current_frame_usec := Time.get_ticks_usec()
				var elapsed_ms := float(current_frame_usec - previous_frame_usec) / 1000.0
				previous_frame_usec = current_frame_usec
				if frame < _warmup:
					if _capture_dir != "" and mode == "displacement_on" and frame == _warmup - 1:
						var capture_name := "overview.png" if phase_name == "overview" else ("ground-walk.png" if phase_name == "walk" else "")
						if capture_name != "" and not _save_capture(capture_name):
							return {}
						# Image readback and disk IO belong to setup, not frame timing.
						previous_frame_usec = Time.get_ticks_usec()
					continue
				var rid := _viewport.get_viewport_rid()
				cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(rid))
				gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
				renderer_cpu.append(float(_renderer.get_stats().get("process_cpu_ms", 0.0)))
				frame_ms.append(elapsed_ms)
			if cpu.size() != _frames:
				push_error("Internal sampling error in phase %s: got %d frames." % [phase_name, cpu.size()])
				return {}
			var phase_key := "%s/%s" % [mode, phase_name]
			var current_stats: Dictionary = _renderer.get_stats()
			var gpu_available := _has_positive(gpu)
			var cpu_available := _has_positive(cpu)
			var renderer_cpu_available := _has_positive(renderer_cpu)
			phase_reports[phase_key] = {
				"warmup_frames": _warmup,
				"measured_frames": _frames,
				"viewport_cpu_ms": _distribution(cpu) if cpu_available else null,
				"viewport_gpu_ms": _distribution(gpu) if gpu_available else null,
				"renderer_process_cpu_ms": _distribution(renderer_cpu) if renderer_cpu_available else null,
				"main_loop_frame_ms": _distribution(frame_ms),
				"viewport_cpu_timing_available": cpu_available,
				"gpu_timing_available": gpu_available,
				"renderer_process_cpu_timing_available": renderer_cpu_available,
				"renderer_stats": current_stats,
				"memory": _memory_stats()
			}
			renderer_stats = current_stats
			print("Island benchmark %s: viewport GPU p50=%s ms, renderer CPU p50=%.3f ms" % [phase_key, _percentile(gpu, 0.5), _percentile(renderer_cpu, 0.5)])
	return {
		"engine": Engine.get_version_info(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"graphics_adapter": {
			"name": RenderingServer.get_video_adapter_name(),
			"vendor": RenderingServer.get_video_adapter_vendor(),
			"api_version": RenderingServer.get_video_adapter_api_version()
		},
		"viewport": {
			"render_target_width": viewport_size.x,
			"render_target_height": viewport_size.y,
			"window_width": DisplayServer.window_get_size().x,
			"window_height": DisplayServer.window_get_size().y
		},
		"settings": {
			"scene": SCENE_PATH,
			"phase_order": PHASES,
			"displacement_modes": MODE_NAMES,
			"frames_per_phase": _frames,
			"warmup_frames_per_phase": _warmup,
			"displacement_strength_m": _renderer.displacement_strength,
			"displacement_radius_m": _renderer.displacement_radius,
			"material_slots": int(renderer_stats.get("material_count", 0)),
			"material_source_sets": _source_set_count,
			"control_blend_slots_max": CONTROL_BLEND_SLOT_COUNT,
			"cells_per_patch": _renderer.cells_per_patch,
			"min_patch_size_m": _renderer.min_patch_size,
			"split_ratio": _renderer.split_ratio,
			"max_patches": _renderer.max_patches,
			"terrain_bounds_local": [_source.base_bounds.position.x, _source.base_bounds.position.y, _source.base_bounds.size.x, _source.base_bounds.size.y],
			"vsync": "disabled",
			"texture_material_definitions": MATERIAL_SLOT_COUNT,
			"unique_color_textures": int(_material_inventory().get("unique_color_textures", 0)),
			"unique_normal_textures": int(_material_inventory().get("unique_normal_textures", 0)),
			"unique_ormh_textures": int(_material_inventory().get("unique_ormh_textures", 0)),
			"unique_texture_resources_total": int(_material_inventory().get("unique_texture_resources_total", 0)),
			"camera_paths": "deterministic frame-indexed overview, walk, fast traversal, and teleport paths",
			"camera_motion": {
				"simulation_hz": SIMULATION_HZ,
				"walk_speed_m_s": WALK_SPEED_M_S,
				"walk_frame_step_m": WALK_SPEED_M_S / SIMULATION_HZ,
				"walk_path": "60 m radius arc centered at %s; first point is 40 m +Z from building platform center (-1008, 592)" % [WALK_CENTER],
				"fast_traversal_speed_m_s": FAST_SPEED_M_S,
				"fast_traversal_frame_step_m": FAST_SPEED_M_S / SIMULATION_HZ,
				"fast_route_start_xz": [FAST_ROUTE_START.x, FAST_ROUTE_START.y],
				"fast_route_end_xz": [FAST_ROUTE_END.x, FAST_ROUTE_END.y],
				"minimum_camera_clearance_over_sea_or_terrain_m": 3.0,
				"teleport_anchor_xz": [[-1800.0, -1800.0], [1800.0, -1800.0], [1800.0, 1800.0], [-1800.0, 1800.0], [0.0, 0.0], [900.0, -400.0]]
			}
		},
		"scope_note": "Viewport CPU/GPU timings cover the complete rendered scene, including sky, lighting, shadows, materials, UI, and terrain. They are not terrain-only GPU measurements.",
		"startup_and_scene_load_included": false,
		"wall_seconds": float(Time.get_ticks_usec() - started_usec) / 1000000.0,
		"renderer_stats": renderer_stats,
		"phases": phase_reports
	}

func _material_inventory() -> Dictionary:
	var materials: Array = _renderer.get("_materials") if _renderer != null else []
	var colors := {}
	var normals := {}
	var ormh := {}
	var tuples := {}
	var all_textures := {}
	var texture_profiles := {}
	for material in materials:
		if not material is StrataMaterial:
			continue
		var texture_ids: Array[int] = []
		for pair in [[material.color_texture, colors], [material.normal_texture, normals], [material.ormh_texture, ormh]]:
			var texture: Texture2D = pair[0]
			if texture == null:
				continue
			var instance_id := texture.get_instance_id()
			pair[1][instance_id] = true
			all_textures[instance_id] = true
			texture_ids.append(instance_id)
			if not texture_profiles.has(instance_id):
				var image := texture.get_image()
				texture_profiles[instance_id] = {
					"kind": ["color", "normal_gl", "ormh"][texture_ids.size() - 1],
					"class": texture.get_class(),
					"width": image.get_width() if image != null else 0,
					"height": image.get_height() if image != null else 0,
					"image_format": int(image.get_format()) if image != null else -1,
					"image_is_compressed": image.is_compressed() if image != null else false,
					"has_mipmaps": image.has_mipmaps() if image != null else false
				}
		if texture_ids.size() == 3:
			tuples[str(texture_ids)] = true
	return {
		"material_definitions": materials.size(),
		"unique_material_texture_triples": tuples.size(),
		"unique_color_textures": colors.size(),
		"unique_normal_textures": normals.size(),
		"unique_ormh_textures": ormh.size(),
		"unique_texture_resources_total": all_textures.size(),
		"bound_texture_profiles": texture_profiles.values()
	}

func _run_texture_stress_pass(scene_root: Node) -> Dictionary:
	var templates: Array = scene_root.get("_materials")
	if templates.is_empty():
		return {"ok": false, "message": "showcase did not expose its source material definitions"}
	# Capture baseline before constructing any duplicated ImageTexture resources.
	var memory_before := _memory_stats()
	var before_texture_bytes := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)
	var stress_materials: Array[StrataMaterial] = []
	var resource_ids := {}
	var stress_texture_profiles := {}
	var source_texture_bytes := 0
	for index in range(MATERIAL_SLOT_COUNT):
		var source: StrataMaterial = templates[index % templates.size()]
		var stress := StrataMaterial.new()
		stress.uv_scale = source.uv_scale
		stress.displacement_strength = source.displacement_strength
		var texture_names := ["color_texture", "normal_texture", "ormh_texture"]
		var texture_kinds := ["color", "normal_gl", "ormh"]
		for texture_index in range(texture_names.size()):
			var texture_name: String = texture_names[texture_index]
			var texture_kind: String = texture_kinds[texture_index]
			var original := source.get(texture_name) as Texture2D
			if original == null:
				return {"ok": false, "message": "source material %d has no %s" % [index % templates.size(), texture_name]}
			var image := original.get_image()
			if image == null or image.is_empty():
				return {"ok": false, "message": "could not read %s from source material %d" % [texture_name, index % templates.size()]}
			var copied_image := image.duplicate() as Image
			var copied_texture := ImageTexture.create_from_image(copied_image)
			if copied_texture == null:
				return {"ok": false, "message": "could not create unique %s resource %d" % [texture_name, index]}
			stress.set(texture_name, copied_texture)
			resource_ids[copied_texture.get_instance_id()] = true
			source_texture_bytes += copied_image.get_data().size()
			var uploaded_image := copied_texture.get_image()
			var profile_key := "%s:format=%d:compressed=%s:mips=%s" % [texture_kind, copied_image.get_format(), copied_image.is_compressed(), copied_image.has_mipmaps()]
			if not stress_texture_profiles.has(profile_key):
				stress_texture_profiles[profile_key] = {"kind": texture_kind, "image_format": copied_image.get_format(), "compressed": copied_image.is_compressed(), "has_mipmaps": copied_image.has_mipmaps(), "width": uploaded_image.get_width() if uploaded_image != null else 0, "height": uploaded_image.get_height() if uploaded_image != null else 0, "resources": 0}
			stress_texture_profiles[profile_key].resources += 1
		stress_materials.append(stress)
	if not _renderer.configure_runtime(_source, _source.runtime_data, stress_materials):
		return {"ok": false, "message": "renderer rejected the 32-slot duplicated texture pool"}
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var after_texture_bytes := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)
	var memory_after := _memory_stats()
	return {
		"ok": true,
		"label": "synthetic residency stress; duplicate texture allocations from the %d registered real source sets, after normal measurements" % _source_set_count,
		"material_slots": stress_materials.size(),
		"unique_gpu_texture_resources_created": resource_ids.size(),
		"expected_unique_gpu_texture_resources": MATERIAL_SLOT_COUNT * 3,
		"duplicated_texture_profiles": stress_texture_profiles.values(),
		"source_image_bytes_before_gpu_upload": source_texture_bytes,
		"rendering_server_texture_bytes_before": before_texture_bytes,
		"rendering_server_texture_bytes_after": after_texture_bytes,
		"rendering_server_texture_bytes_delta": after_texture_bytes - before_texture_bytes,
		"memory_before": memory_before,
		"memory_after": memory_after,
		"renderer_stats": _renderer.get_stats(),
		"note": "Texture allocation delta is whole-process RenderingServer accounting; it is not terrain-only memory. Source materials are replaced only in this benchmark process after normal measurements."
	}

func _set_camera_for_phase(phase_name: String, frame: int) -> void:
	var point := Vector2.ZERO
	var look_offset := Vector2(80.0, 0.0)
	var altitude := 3.0
	match phase_name:
		"overview":
			point = Vector2(0.0, 0.0)
			altitude = 4400.0
			look_offset = Vector2(0.0, 0.0)
		"walk":
			var distance := float(frame) * WALK_SPEED_M_S / SIMULATION_HZ
			var angle := distance / WALK_RADIUS_M
			point = WALK_CENTER + Vector2(sin(angle), -cos(angle)) * WALK_RADIUS_M
			look_offset = Vector2(cos(angle), sin(angle)) * 24.0
		"fast_traversal":
			var route := FAST_ROUTE_END - FAST_ROUTE_START
			var distance := fposmod(float(frame) * FAST_SPEED_M_S / SIMULATION_HZ, route.length())
			var direction := route.normalized()
			point = FAST_ROUTE_START + direction * distance
			look_offset = direction * 40.0
		"teleports":
			var anchors := [Vector2(-1800.0, -1800.0), Vector2(1800.0, -1800.0), Vector2(1800.0, 1800.0), Vector2(-1800.0, 1800.0), Vector2(0.0, 0.0), Vector2(900.0, -400.0)]
			point = anchors[int(frame / 18) % anchors.size()]
			look_offset = Vector2(70.0, 40.0)
	var height := maxf(SEA_LEVEL_M, _height_at(point))
	var view_height := height + altitude
	var camera_position := Vector3(point.x, view_height, point.y)
	if phase_name == "overview":
		camera_position.z += 3800.0
	_camera.global_position = _source.to_global(camera_position)
	var look_point := point + look_offset
	var target_height := maxf(SEA_LEVEL_M, _height_at(look_point)) + (1.5 if altitude < 20.0 else 0.0)
	_camera.look_at(_source.to_global(Vector3(look_point.x, target_height, look_point.y)), Vector3.UP)

func _height_at(point: Vector2) -> float:
	if _source.runtime_data != null:
		var sample: Dictionary = _source.runtime_data.sample_height(point)
		if int(sample.get("status", StrataRuntimeData.Status.NOT_RESIDENT)) == StrataRuntimeData.Status.OK:
			return float(sample.value)
	return 0.0

func _save_capture(filename: String) -> bool:
	var path := _capture_dir.path_join(filename)
	var image := _viewport.get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		push_error("Could not save capture %s: %s" % [path, error_string(error)])
		return false
	print("Island benchmark capture: %s" % path)
	return true

func _distribution(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {"count": 0, "p50_ms": null, "p95_ms": null, "p99_ms": null, "max_ms": null}
	return {
		"count": values.size(),
		"p50_ms": _percentile(values, 0.50),
		"p95_ms": _percentile(values, 0.95),
		"p99_ms": _percentile(values, 0.99),
		"max_ms": values.max()
	}

func _percentile(values: Array[float], fraction: float) -> Variant:
	if values.is_empty():
		return null
	var ordered: Array[float] = values.duplicate()
	ordered.sort()
	if is_equal_approx(fraction, 0.5) and ordered.size() % 2 == 0:
		var middle := floori(float(ordered.size()) / 2.0)
		return (ordered[middle - 1] + ordered[middle]) * 0.5
	var index := clampi(ceili(float(ordered.size() - 1) * fraction), 0, ordered.size() - 1)
	return ordered[index]

func _has_positive(values: Array[float]) -> bool:
	for value in values:
		if value > 0.0:
			return true
	return false

func _memory_stats() -> Dictionary:
	var texture_bytes := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)
	var buffer_bytes := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED)
	var rss_kib := -1
	var status := FileAccess.open("/proc/self/status", FileAccess.READ)
	if status != null:
		while not status.eof_reached():
			var line := status.get_line()
			if line.begins_with("VmRSS:"):
				var fields := line.replace("\t", " ").split(" ", false)
				if fields.size() >= 2:
					rss_kib = int(fields[1])
				break
	return {
		"rendering_server_texture_bytes": texture_bytes,
		"rendering_server_buffer_bytes": buffer_bytes,
		"process_rss_kib": rss_kib
	}

func _find_node(root: Node, wanted_class: String) -> Node:
	if wanted_class == "StrataTerrain3D" and root is StrataTerrain3D:
		return root
	if wanted_class == "StrataRenderer" and root is StrataRenderer:
		return root
	for child in root.get_children():
		var found := _find_node(child, wanted_class)
		if found != null:
			return found
	return null

func _find_camera(root: Node) -> Camera3D:
	if root is Camera3D:
		return root
	for child in root.get_children():
		var found := _find_camera(child)
		if found != null:
			return found
	return null

func _has_property(object: Object, property_name: String) -> bool:
	for property in object.get_property_list():
		if String(property.name) == property_name:
			return true
	return false
