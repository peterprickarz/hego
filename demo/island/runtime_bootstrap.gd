extends Node3D
## Persistent compiled-only scene bootstrap. No Houdini or authoring layer calls.
var ready_for_capture := false
var _capture := ""
var _frames := 0
var _quit_frames := 0
var _captured := false
var _capture_finished := false

func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="): _capture = argument.trim_prefix("--capture=")
		if argument.begins_with("--quit-after-frames="): _quit_frames = int(argument.trim_prefix("--quit-after-frames="))
	var data := get_meta("strata_runtime_data") as StrataRuntimeData
	if data == null: push_error("Runtime scene has no compiled terrain resource"); return
	if get_meta("island_material_registry_version", 0) != 1 or get_meta("island_material_registry_sha256", "") != FileAccess.get_sha256(HEGoIslandMaterialRegistry.REGISTRY): push_error("Legacy alias controls cannot use the distinct32 registry. Run the explicit material-only migration first."); get_tree().quit(2); return
	var materials := HEGoIslandMaterialRegistry.pool()
	if materials.is_empty() or materials.size() != HEGoIslandMaterialRegistry.count(): push_error("Runtime needs every registered material resource"); get_tree().quit(2); return
	var renderer := StrataRenderer.new(); renderer.name = "IslandRenderer"; add_child(renderer)
	if not renderer.configure_runtime(self, data, materials): return
	var camera := Camera3D.new(); camera.name = "Camera"; camera.set_script(load("res://island/island_camera.gd")); camera.far = 22000.0; add_child(camera)
	camera.set("renderer", renderer)
	camera.call("teleport_to", to_global(Vector3(-3000.0, 2000.0, 3300.0)), to_global(Vector3(-700.0, 80.0, -250.0))); camera.current = true; renderer.set_camera(camera)
	var environment := Environment.new(); environment.background_mode = Environment.BG_SKY
	var sky := Sky.new(); var sky_material := ProceduralSkyMaterial.new(); sky_material.sky_top_color = Color(0.18, 0.35, 0.49); sky_material.sky_horizon_color = Color(0.7, 0.78, 0.78); sky_material.ground_bottom_color = Color(0.14, 0.23, 0.24); sky_material.ground_horizon_color = Color(0.7, 0.75, 0.73); sky.sky_material = sky_material; environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY; environment.ambient_light_energy = 0.28; environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.fog_enabled = true; environment.fog_density = 0.000012; environment.fog_light_color = Color(0.55, 0.68, 0.72); environment.fog_sky_affect = 0.5
	var world := WorldEnvironment.new(); world.environment = environment; add_child(world)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-32.0, -38.0, 0.0); sun.light_energy = 1.15; sun.shadow_enabled = true; sun.directional_shadow_max_distance = 2600.0; add_child(sun)
	var ocean := MeshInstance3D.new(); var plane := PlaneMesh.new(); plane.size = Vector2(80000.0, 80000.0); plane.subdivide_width = 128; plane.subdivide_depth = 128; ocean.mesh = plane
	var material := ShaderMaterial.new(); material.shader = load("res://island/shaders/ocean.gdshader"); ocean.material_override = material; add_child(ocean)
	var collision := get_node_or_null("Collision") as StrataCollision
	if collision != null: collision.prepare_region(Rect2(Vector2(-1136.0, 464.0), Vector2(256.0, 256.0)))
	var navigation := get_node_or_null("Navigation") as StrataNavigation
	if navigation != null:
		var baked := navigation.bake_region(Rect2(Vector2(-1072.0, 528.0), Vector2(128.0, 128.0)))
		if baked.get("pending", false): baked = await navigation.bake_finished
		if not baked.get("ok", false): push_error("Runtime navigation region failed: " + str(baked)); return
	ready_for_capture = true
	print("ISLAND_COMPILED_RUNTIME_READY resolution=", data.resolution, " macro=", data.has_macro(), " shader_macro=", renderer._shader_material.get_shader_parameter("has_terrain_macro_map"))

func _process(_delta: float) -> void:
	if not ready_for_capture: return
	_frames += 1
	if not _captured and not _capture.is_empty() and _frames >= (maxi(1, _quit_frames - 1) if _quit_frames > 0 else 60):
		_captured = true
		await RenderingServer.frame_post_draw
		var error := get_viewport().get_texture().get_image().save_png(_capture)
		if error != OK:
			push_error("Could not save compiled runtime capture: " + error_string(error))
			get_tree().quit(1)
			return
		_capture_finished = true
		print("ISLAND_COMPILED_RUNTIME_CAPTURE ", _capture)
	# The frame limit may be reached while frame_post_draw is still pending.
	if _quit_frames > 0 and _frames >= _quit_frames and (_capture.is_empty() or _capture_finished): get_tree().quit()
