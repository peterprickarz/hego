extends SceneTree
## Read-only visual/residency acceptance of an explicitly chosen saved scene.
## No producer cook, synthetic controls, material substitution or settings reset.
var candidate := ""
var output := "/tmp/hego-materials/gpu-actual.json"
var captures := ""
var terrain: StrataTerrain3D
var renderer: StrataRenderer
var camera: Camera3D
var report := {}

func _initialize() -> void:
	run.call_deferred()

func fail(message: String) -> void:
	push_error(message)
	quit(1)

func resource_hash(resource: Resource) -> String:
	var names := PackedStringArray()
	for property in resource.get_property_list():
		if int(property.usage) & PROPERTY_USAGE_STORAGE and property.name != "script": names.append(property.name)
	names.sort()
	var values := []
	for name in names: values.append([name, resource.get(name)])
	var context := HashingContext.new(); context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(values))
	return context.finish().hex_encode()

func find_renderer(node: Node) -> StrataRenderer:
	if node is StrataRenderer: return node
	for child in node.get_children(true):
		var found := find_renderer(child)
		if found != null: return found
	return null

func summary(samples: Array[float]) -> Dictionary:
	samples.sort()
	return {"p50": samples[roundi((samples.size() - 1) * 0.5)], "p95": samples[roundi((samples.size() - 1) * 0.95)], "max": samples[-1]}

func memory() -> Dictionary:
	return {"texture_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED), "buffer_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED), "rendering_total_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED), "process_static_bytes": OS.get_static_memory_usage()}

func inventory() -> Dictionary:
	var paths := {}; var profiles := []; var materials := []
	for material: StrataMaterial in renderer._materials:
		materials.append({"path": material.resource_path, "state_hash": resource_hash(material), "uv_scale": material.uv_scale, "displacement_strength": material.displacement_strength, "contrast": material.height_blend_contrast, "bias": material.height_blend_bias, "roughness_scale": material.roughness_scale, "roughness_bias": material.roughness_bias})
		for pair in [[material.color_texture, "color"], [material.normal_texture, "normal"], [material.ormh_texture, "ormh"]]:
			var texture: Texture2D = pair[0]
			var image := texture.get_image()
			paths[texture.resource_path] = true
			profiles.append({"path": texture.resource_path, "kind": pair[1], "rid_valid": texture.get_rid().is_valid(), "size": [image.get_width(), image.get_height()], "format": image.get_format(), "mipmaps": image.has_mipmaps(), "compressed_bytes": image.get_data().size()})
	return {"material_count": materials.size(), "unique_texture_paths": paths.size(), "materials": materials, "textures": profiles}

func actual_point(ids_wanted: Array, preferred: Vector2, low: float, high: float, cliff: bool = false) -> Vector2:
	# Camera selection reads the real saved Houdini controls; it does not create
	# or edit material weights. A nearby clear example is useful for visual QA.
	var best := preferred
	var best_score := -INF
	# The controls are the baked regions' material ids and weights (one lattice at the region
	# spacing); sample them on an 8 m grid around the preferred point.
	for y in range(-52, 53):
		for x in range(-52, 53):
			var point := preferred + Vector2(x, y) * 8.0
			if not terrain.base_bounds.has_point(point) or point.distance_to(preferred) > 420.0: continue
			var height := renderer.sample_render_height(point)
			if height < low or height > high: continue
			var blend := renderer.sample_control_blend(point)
			var influence := 0.0
			for slot in range(4):
				if int(blend.ids[slot]) in ids_wanted: influence += float(blend.weights[slot])
			if influence < 0.4: continue
			if cliff:
				var gradient := Vector2(renderer.sample_render_height(point + Vector2(4, 0)) - renderer.sample_render_height(point - Vector2(4, 0)), renderer.sample_render_height(point + Vector2(0, 4)) - renderer.sample_render_height(point - Vector2(0, 4))) / 8.0
				if rad_to_deg(atan(gradient.length())) < 42.0: continue
			var score := influence - point.distance_to(preferred) / 700.0
			if score > best_score: best = point; best_score = score
	return best

func set_view(label: String, point: Vector2) -> Dictionary:
	var height := renderer.sample_render_height(point)
	var gradient := Vector2(renderer.sample_render_height(point + Vector2(4, 0)) - renderer.sample_render_height(point - Vector2(4, 0)), renderer.sample_render_height(point + Vector2(0, 4)) - renderer.sample_render_height(point - Vector2(0, 4))) / 8.0
	var outward := -gradient.normalized() if gradient.length() > 0.01 else Vector2(-0.6, 0.8)
	var position: Vector3
	var target := Vector3(point.x, height + 1.2, point.y)
	match label:
		"coast":
			var xz := point + outward * 24.0
			position = Vector3(xz.x, maxf(renderer.sample_render_height(xz) + 3.5, 3.5), xz.y)
		"cliff":
			var xz := point + outward * 27.0
			position = Vector3(xz.x, maxf(height + 4.0, renderer.sample_render_height(xz) + 3.5), xz.y)
		"forest-ground":
			var xz := point + Vector2(-12, 18)
			position = Vector3(xz.x, renderer.sample_render_height(xz) + 3.0, xz.y)
		_:
			var xz := point + Vector2(-90, 110)
			position = Vector3(xz.x, maxf(height + 35.0, renderer.sample_render_height(xz) + 8.0), xz.y)
	camera.global_position = terrain.to_global(position)
	camera.look_at(terrain.to_global(target), Vector3.UP)
	renderer.force_lod_update()
	return {"target_local": [target.x, target.y, target.z], "camera_local": [position.x, position.y, position.z], "fov_saved": camera.fov}

func run() -> void:
	create_timer(300.0).timeout.connect(func(): fail("Actual32 GPU acceptance watchdog"))
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--candidate="): candidate = argument.trim_prefix("--candidate=")
		if argument.begins_with("--report="): output = argument.trim_prefix("--report=")
		if argument.begins_with("--captures="): captures = argument.trim_prefix("--captures=")
	if candidate.is_empty() or captures.is_empty(): fail("Use explicit --candidate=res://... and --captures=absolute/path"); return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	Engine.max_fps = 0
	if change_scene_to_file(candidate) != OK: fail("Cannot open accepted saved candidate"); return
	var scene_deadline := Time.get_ticks_msec() + 120000
	while current_scene == null:
		if Time.get_ticks_msec() > scene_deadline: fail("Saved candidate did not finish entering the scene tree"); return
		await process_frame
	terrain = current_scene.get_node_or_null("Terrain") as StrataTerrain3D
	camera = current_scene.get_node_or_null("Camera") as Camera3D
	if terrain == null or camera == null: fail("Saved candidate needs terrain and camera"); return
	var settings_before := resource_hash(terrain.render_settings)
	var deadline := Time.get_ticks_msec() + 180000
	while renderer == null or renderer.get_stats().get("material_count", 0) != HEGoIslandMaterialRegistry.count():
		if Time.get_ticks_msec() > deadline: fail("Saved candidate renderer failed to bind32 sources"); return
		renderer = find_renderer(terrain)
		await process_frame
	if RenderingServer.get_rendering_device() == null or RenderingServer.get_current_rendering_method() != "forward_plus": fail("Actual32 GPU acceptance requires Forward+"); return
	if root.get_texture().get_size() != Vector2(1920, 1080): fail("Actual viewport must be1920x1080"); return
	if camera is HEGoIslandCamera: camera.input_enabled = false
	camera.current = true
	# Only temporary debug-display overrides; saved resources and field values
	# remain untouched. Material/UV/roughness/displacement/LOD settings stay saved.
	renderer.debug_lod = false; renderer.debug_discarded = false; renderer.debug_shading_normals = false; renderer.wireframe = false
	renderer.set_channel_preview(null, terrain.base_bounds, false)
	renderer.set_ownership_overlay(null)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	var actual_inventory := inventory()
	if actual_inventory.material_count != HEGoIslandMaterialRegistry.count() or actual_inventory.unique_texture_paths != 3 * HEGoIslandMaterialRegistry.count(): fail("Actual residency inventory is incomplete"); return
	var expected_lattice := Vector2i((terrain.base_bounds.size / terrain.region_spacing).round()) + Vector2i.ONE
	if Vector2i(renderer.get_stats().get("control_resolution", Vector2i.ZERO)) != expected_lattice: fail("Actual32 views require region material maps on the terrain lattice %s" % expected_lattice); return
	var points := {
		"coast": actual_point([0, 6, 7, 8, 9], Vector2(508, 700), -0.5, 8.0),
		"cliff": actual_point([2, 3, 10, 11, 12, 13, 14, 15], Vector2(-900, 300), 80.0, 330.0, true),
		"forest-ground": actual_point([21, 22, 23, 24], Vector2(-1000, 0), 15.0, 230.0),
		"summit": actual_point([5, 31], Vector2(-568, 12), 380.0, 500.0),
	}
	var views := {}
	for label: String in points:
		var view := set_view(label, points[label])
		for frame in range(60): await RenderingServer.frame_post_draw
		var cpu: Array[float] = []; var gpu: Array[float] = []; var controller: Array[float] = []; var frame_ms: Array[float] = []
		var previous := Time.get_ticks_usec()
		for frame in range(180):
			await RenderingServer.frame_post_draw
			var now := Time.get_ticks_usec(); frame_ms.append((now - previous) / 1000.0); previous = now
			cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid()))
			gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
			controller.append(float(renderer.get_stats().get("process_cpu_ms", 0.0)))
		view["viewport_cpu_ms"] = summary(cpu); view["viewport_gpu_ms"] = summary(gpu); view["renderer_cpu_ms"] = summary(controller); view["frame_ms"] = summary(frame_ms)
		view["renderer_stats"] = renderer.get_stats(); view["memory"] = memory()
		var path := captures.path_join("materials32-" + label + ".png")
		if root.get_texture().get_image().save_png(path) != OK: fail("Cannot save actual32 capture " + path); return
		view["capture"] = path; views[label] = view
		print("MATERIALS32_VIEW ", label, " ", JSON.stringify(view))
	var materials_unchanged := true
	for index in range(renderer._materials.size()):
		materials_unchanged = materials_unchanged and resource_hash(renderer._materials[index]) == actual_inventory.materials[index].state_hash
	report = {"candidate": candidate, "registry_sha256": FileAccess.get_sha256("res://island/materials/material_registry.json"), "engine": Engine.get_version_info(), "adapter": RenderingServer.get_video_adapter_name(), "rendering_method": RenderingServer.get_current_rendering_method(), "viewport": [1920, 1080], "warmup_frames_per_view": 60, "measured_frames_per_view": 180, "timing_scope": "Indicative whole-viewport timings. Other desktop GPU applications remain open; this is not an isolated performance benchmark.", "settings_hash_before": settings_before, "settings_hash_after": resource_hash(terrain.render_settings), "materials_unchanged": materials_unchanged, "inventory": actual_inventory, "views": views, "selected_cutoff": str(terrain.preview_through_layer), "memory": memory()}
	if report.settings_hash_before != report.settings_hash_after or not materials_unchanged: fail("Actual32 validation changed saved appearance settings"); return
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null: fail("Cannot write actual32 GPU report"); return
	file.store_string(JSON.stringify(report, "  ")); file.close()
	print("MATERIALS32_GPU_PASS ", output)
	quit(0)
