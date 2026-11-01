extends SceneTree
## Actual cached scene, real renderer/physics/nav and UI callbacks; never saves or cooks.
var failures := 0
func _initialize() -> void: call_deferred("run")
func check(condition: bool, message: String) -> void:
	if not condition: failures += 1; push_error(message)
func run() -> void:
	create_timer(120.0).timeout.connect(func(): push_error("Island graphical test watchdog expired"); quit(1))
	if DisplayServer.get_name() == "headless": push_error("Use graphical Forward+ for island_showcase_test"); quit(2); return
	print("ISLAND_GPU ", RenderingServer.get_video_adapter_name(), " / ", RenderingServer.get_video_adapter_api_version())
	# Bakes triggered by this test are published in memory only; nothing is written under island/terrain.
	Engine.set_meta("island_no_save", true)
	if change_scene_to_file("res://island/island_showcase.tscn") != OK: quit(2); return
	while current_scene == null: await process_frame
	var level := current_scene
	var started := Time.get_ticks_msec()
	while not level.ready_for_capture:
		if Time.get_ticks_msec() - started > 60000: push_error("Island startup timeout"); quit(2); return
		await process_frame
	level._capture = ""
	var terrain: StrataTerrain3D = level.terrain
	var renderer: StrataRenderer = level.renderer
	check(not HEGoAPI.get_singleton().is_session_active(), "Graphical cached startup is Houdini-free")
	check(terrain.runtime_data != null and not terrain.is_runtime_bake_stale(), "Fresh compiled runtime ready")
	check(renderer.get_stats().height_resolution == Vector2i(4097, 4097), "Actual 1 m GPU field")
	# The renderer is built by configure_runtime from the baked manifest: its regions are the
	# manifest's own region objects, and the material maps are the stack's composition.
	var data := terrain.runtime_data
	var spec := renderer.region_spec()
	var probe := Vector2i(4, 10)
	# The runtime renderer streams by camera distance (the overview camera sees coarse maps
	# only), so bring the camera to the pad and wait until the probed region is resident near.
	var pad_height := terrain.sample_height(level.PAD)
	level.camera.teleport_to(Vector3(level.PAD.x - 82.0, pad_height + 75.0, level.PAD.y + 110.0), Vector3(level.PAD.x + 4.0, pad_height + 1.0, level.PAD.y))
	started = Time.get_ticks_msec()
	while renderer.region_level(probe) != 0:
		if Time.get_ticks_msec() - started > 30000: push_error("The streamer did not bind the probed region near the camera"); quit(2); return
		await process_frame
	var streaming: Dictionary = level.streamer.stats()
	check(int(streaming.near) > 0 and int(streaming.near) <= level.streamer.near_slots and int(streaming.far) <= level.streamer.far_slots, "Streamer binds near and far regions around the camera within its slot budgets")
	check(renderer.get_stats().gpu_bytes_near + renderer.get_stats().gpu_bytes_far + renderer.get_stats().gpu_bytes_coarse < 120 * 1024 * 1024, "Resident GPU payload stays far below the whole-island 235 MB")
	check(level._bound_data == data and renderer.get_region(probe) == data.get_region(probe), "Runtime renderer holds the manifest's regions (streamed through configure_runtime)")
	check(spec.spacing == terrain.region_spacing and spec.maps.has("material_ids") and spec.maps.has("material_weights") and spec.maps.has("holes") and spec.maps.has("height"), "Renderer spec has the stack's maps at the terrain's region spacing")
	check(renderer.get_stats().control_resolution == renderer.get_stats().height_resolution, "Material maps are on the height lattice, not a 4 m control lattice")
	check(level.get_node_or_null("MaterialControlsBinding") == null and terrain.editor_control_ids == null and terrain.editor_control_weights == null, "No control-map binding or packed control maps")
	var ids_window := StrataRegions.map_window(spec, probe, spec.maps.material_ids)
	var composed := StrataRegionCompose.compose_map(terrain, null, "material_ids", ids_window, spec)
	check(composed.get("ok", false) and composed.image.get_data() == data.get_region(probe).get_image("material_ids", 0).get_data(), "Baked material ids equal the stack composition of the same region")
	check(renderer._height_image == null and renderer._control_ids == null, "No whole-image adapters are in use")
	var holes_before := renderer.get_region(probe).get_image("holes", 0).get_data()
	var height_bytes := renderer.get_region(probe).get_image("height", 0).get_data()
	await level._select_layer(0)
	check(renderer.get_region(probe) != data.get_region(probe) and data.get_region(probe).get_image("holes", 0).get_data() == holes_before, "A stage view edits private copies, never the baked regions")
	check(renderer.get_region(probe).get_image("holes", 0).get_data().find(255) == -1, "Earlier stage omits later authored holes")
	await level._select_layer(4)
	check(renderer.get_region(probe) == data.get_region(probe) and renderer.get_region(probe).get_image("holes", 0).get_data() == holes_before, "Final stage restores the baked holes")
	check(renderer.set_ownership_overlay(terrain.get_layers()[4]), "Native ownership overlay enabled")
	check(renderer.get_region(probe).get_image("height", 0).get_data() == height_bytes, "Ownership overlay preserves geometry")
	var layer := terrain.get_layers()[4]
	var snapshot := layer.data.snapshot()
	level._stroke_layer = layer; level._stroke_records = []; level._last_point = Vector2(INF, INF)
	level._radius.value = 4.0; level._strength.value = 0.5; level._operation.select(0)
	level._dab(level.PAD + Vector2(0.0, 16.0)); level._finish_stroke()
	check(layer.data.snapshot() != snapshot, "Actual dab changes the selected native layer")
	await level._undo_stroke()
	check(layer.data.snapshot() == snapshot, "UI undo restores values and ownership")
	await level._redo_stroke()
	check(layer.data.snapshot() != snapshot, "UI redo reapplies the owned stroke")
	await level._undo_stroke()
	check(layer.data.snapshot() == snapshot, "Test restores original hand layer")
	await level.set_player_enabled(true)
	check(level.player.is_player_enabled(), "Collision-driven player enables")
	for index in range(120): await physics_frame
	check(level.player.is_on_floor(), "Actual character settles on compiled collision")
	level.set_player_enabled(false)
	check(level.camera.get_parent() == level and level.camera.input_enabled, "Fly camera restored after player")
	var map: RID = level.navigation.get_navigation_map()
	for index in range(4): await physics_frame
	var a: Vector2 = level.PAD + Vector2(-12.0, 16.0); var b: Vector2 = level.PAD + Vector2(12.0, 16.0)
	var start := terrain.to_global(Vector3(a.x, terrain.sample_height(a), a.y)); var end := terrain.to_global(Vector3(b.x, terrain.sample_height(b), b.y))
	var path := NavigationServer3D.map_get_path(map, start, end, true)
	check(path.size() >= 2, "Actual selected-area Recast path is connected")
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			level._capture = ""
			var h := renderer.sample_render_height(level.PAD)
			level.camera.teleport_to(Vector3(level.PAD.x - 82.0, h + 75.0, level.PAD.y + 110.0), Vector3(level.PAD.x + 4.0, h + 1.0, level.PAD.y))
			level._ownership.button_pressed = true
			renderer.set_ownership_overlay(layer)
			for index in range(10): await process_frame
			await RenderingServer.frame_post_draw
			check(root.get_texture().get_image().save_png(argument.trim_prefix("--capture=")) == OK, "Save actual GPU capture")
	print("ISLAND_SHOWCASE_TEST failures=", failures, " nav_points=", path.size())
	quit(0 if failures == 0 else 1)
