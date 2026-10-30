@tool
extends EditorPlugin
## Install as a temporary plugin in an isolated editor project only.
var failures := 0
var _camera: Camera3D
var _pose := Transform3D.IDENTITY
var _lock_camera := false
var _done := false
var _elapsed := 0.0
var _reopening := false

func _enter_tree() -> void:
	_run.call_deferred()

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed > 150.0 and not _done:
		push_error("Terrain editor smoke watchdog expired")
		get_tree().quit(8)
	if _lock_camera and is_instance_valid(_camera): _camera.global_transform = _pose

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error("EDITOR_CHECK: " + message)
	else: print("EDITOR_CHECK_PASS: ", message)

func _frames(count: int) -> void:
	for index in range(count): await get_tree().process_frame

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	EditorInterface.get_base_control().get_viewport().get_texture().get_image().save_png(path)

func _run() -> void:
	for index in range(1200):
		if EditorInterface.get_edited_scene_root() != null: break
		await get_tree().process_frame
	var scene := EditorInterface.get_edited_scene_root()
	if scene == null: check(false, "edited scene available"); get_tree().quit(3); return
	var terrain := scene.get_node("Terrain") as StrataTerrain3D
	for index in range(1200):
		if is_instance_valid(terrain.editor_renderer): break
		await get_tree().process_frame
	check(is_instance_valid(terrain.editor_renderer), "actual textured editor renderer initialized")
	if not is_instance_valid(terrain.editor_renderer): get_tree().quit(4); return
	var renderer := terrain.editor_renderer
	terrain.render_settings.quality = StrataRenderSettings.Quality.HIGH
	await _frames(5)
	check(not terrain.is_preview_enabled(), "legacy coarse mesh disabled")
	check(renderer.get_stats().height_resolution == Vector2i(4097, 4097), "live 4097-square height field")
	check(not HEGoAPI.get_singleton().is_session_active(), "no Houdini session or automatic cook")
	_camera = EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	_camera.far = 24000.0
	_pose = Transform3D(Basis.IDENTITY, Vector3(-2200.0, 1200.0, 2200.0)).looking_at(Vector3(-400.0, 100.0, 0.0))
	_lock_camera = true
	await _frames(45)
	var high_stats := renderer.get_stats()
	EditorInterface.inspect_object(terrain)
	await _frames(10)
	await _capture("/tmp/hego-terrain-editor-overview.png")
	_camera.global_transform = _pose
	renderer.force_lod_update()
	var before_plan: int = renderer.get_stats().lod_updates
	_pose.origin = Vector3(-1100.0, 200.0, 700.0)
	_pose = _pose.looking_at(Vector3(-1008.0, 100.0, 592.0))
	await _frames(20)
	check(int(renderer.get_stats().lod_updates) > before_plan, "editor camera drives LOD updates")
	var manual := terrain.get_node("BuildingFlatten") as StrataLayer
	var before := manual.data.snapshot()
	var manual_path := manual.data.resource_path
	check(manual_path.begins_with("res://authoring/"), "manual edits isolated from generated caches")
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(manual)
	EditorInterface.edit_node(manual)
	await _frames(25)
	var sculpt_plugin: EditorPlugin
	for plugin in get_tree().root.find_children("*", "EditorPlugin", true, false):
		if plugin.get_script() != null and plugin.get_script().resource_path == "res://addons/strata/plugin.gd": sculpt_plugin = plugin; break
	check(sculpt_plugin != null, "terrain editor brush plugin active")
	if sculpt_plugin != null:
		sculpt_plugin._edit(manual)
		sculpt_plugin._radius.value = 1.0
		sculpt_plugin._strength.value = 0.5
		sculpt_plugin._stroke_layer = manual
		sculpt_plugin._before = before
		sculpt_plugin._last_point = Vector2(INF, INF)
		var point := Vector2(-1008.0, 592.0)
		var old_height := renderer.sample_render_height(point)
		var previous_compiles: int = terrain.editor_preview_bridge.get_stats().full_compiles
		sculpt_plugin._dab(point)
		sculpt_plugin._finish_stroke()
		await _frames(5)
		check(manual.data.snapshot() != before, "editor brush changed hand layer values and ownership")
		check(renderer.sample_render_height(point) > old_height, "actual textured preview reflects brush")
		check(int(terrain.editor_preview_bridge.get_stats().full_compiles) == previous_compiles, "brush dirty region avoids whole-terrain compilation")
		var manager := get_undo_redo()
		var history := manager.get_history_undo_redo(manager.get_object_history_id(manual))
		history.undo()
		await _frames(10)
		check(manual.data.snapshot() == before, "editor undo restores exact manual ownership and values")
		history.redo()
		await _frames(10)
		check(manual.data.snapshot() != before, "editor redo restores stroke")
		history.undo()
		await _frames(10)
	# Exercise mask painting against the same real selected hand layer.
	if sculpt_plugin != null:
		sculpt_plugin._channel.text = "hole"
		sculpt_plugin._stroke_layer = manual
		sculpt_plugin._before = manual.data.snapshot()
		sculpt_plugin._last_point = Vector2(INF, INF)
		sculpt_plugin._dab(Vector2(-1008, 592))
		sculpt_plugin._finish_stroke()
		await _frames(10)
		check(renderer._hole_image != null and renderer._hole_image.get_pixel(1040, 2640).r > 0.0, "mask brush updates canonical renderer holes")
		var manager := get_undo_redo()
		manager.get_history_undo_redo(manager.get_object_history_id(manual)).undo()
		await _frames(10)
		check(manual.data.snapshot() == before, "mask undo preserves exact hand data")
		# A tint stroke uses the neutral-one base, patches a small macro region,
		# and leaves the current full height image intact.
		sculpt_plugin._channel.text = "terrain_tint_r"
		terrain.override_channel = &"terrain_tint_r"
		terrain.editor_show_channel = true
		terrain.queue_preview_update()
		await _frames(5)
		var tint_previous_compiles: int = terrain.editor_preview_bridge.get_stats().full_compiles
		sculpt_plugin._operation.selected = 1
		sculpt_plugin._stroke_layer = manual
		sculpt_plugin._before = manual.data.snapshot()
		sculpt_plugin._last_point = Vector2(INF, INF)
		var started := Time.get_ticks_usec()
		sculpt_plugin._dab(Vector2(-1008, 592))
		sculpt_plugin._finish_stroke()
		await _frames(5)
		check(int(terrain.editor_preview_bridge.get_stats().full_compiles) == tint_previous_compiles, "tint brush patches macro without full height compilation")
		check(terrain.editor_preview_bridge._macro_image.get_pixel(260, 660).r < 1.0, "tint brush uses neutral-one base and dirty macro lattice")
		check(renderer._channel_preview_texture.get_image().get_pixel(260, 660).r > 0.0 and renderer._channel_preview_texture.get_image().get_pixel(260, 660).r < 1.0, "scalar preview preserves actual macro value instead of subtracting datum")
		print("EDITOR_TINT_DAB_AND_SETTLE_MS=", (Time.get_ticks_usec() - started) / 1000.0)
		manager.get_history_undo_redo(manager.get_object_history_id(manual)).undo()
		await _frames(10)
		check(manual.data.snapshot() == before, "tint undo restores hand data and ownership exactly")
		sculpt_plugin._operation.selected = 0
		sculpt_plugin._channel.text = "height"
		terrain.override_channel = &"height"
		terrain.editor_show_channel = false
		sculpt_plugin._overrides.button_pressed = true
	terrain.show_overrides = true
	await _frames(10)
	await _capture("/tmp/hego-terrain-editor-ownership.png")
	terrain.show_overrides = false
	terrain.preview_through_layer = terrain.get_node("ManualFine")
	await _frames(10)
	check(is_equal_approx(renderer.sample_render_height(Vector2(-1008, 592)), terrain.sample_height(Vector2(-1008, 592), terrain.preview_through_layer)), "selected layer cumulative cutoff shown")
	terrain.preview_through_layer = null
	terrain.render_settings.quality = StrataRenderSettings.Quality.ULTRA
	await _frames(10)
	check(renderer.max_patches == 2048 and renderer.cells_per_patch == 64, "Inspector quality resource updates live renderer")
	# Assigning a different material resource must replace actual bindings.
	var original_material := terrain.editor_materials[0]
	var replacement := original_material.duplicate(true) as StrataMaterial
	terrain.editor_materials[0] = replacement
	await _frames(30)
	check(terrain.editor_renderer._materials[0] == replacement, "Inspector material assignment refreshes renderer bindings")
	terrain.editor_materials[0] = original_material
	await _frames(30)
	terrain.textured_editor_preview = false
	await _frames(30)
	check(not is_instance_valid(terrain.editor_renderer) and terrain.is_preview_enabled(), "disabling textured preview restores legacy mesh")
	terrain.textured_editor_preview = true
	await _frames(40)
	check(is_instance_valid(terrain.editor_renderer) and not terrain.is_preview_enabled(), "reenabling textured preview rebuilds real renderer")
	var saved := EditorInterface.save_scene()
	check(saved == OK, "editor saved editable scene")
	var reopened := ResourceLoader.load(scene.scene_file_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var instance := reopened.instantiate()
	var saved_terrain := instance.get_node("Terrain") as StrataTerrain3D
	check(saved_terrain.render_settings.quality == StrataRenderSettings.Quality.ULTRA, "quality persists on reopen")
	check((saved_terrain.get_node("BuildingFlatten") as StrataLayer).data.snapshot() == before, "saved manual data retains original exact snapshot")
	instance.free()
	# Reopen via the actual editor, retaining saved quality and manual resources.
	if EditorInterface.has_method("reload_scene_from_path"):
		var scene_path := scene.scene_file_path
		EditorInterface.reload_scene_from_path(scene_path)
		await _frames(30)
		var loaded := EditorInterface.get_edited_scene_root().get_node("Terrain") as StrataTerrain3D
		check(loaded.render_settings.quality == StrataRenderSettings.Quality.ULTRA, "actual editor reopened saved quality")
		check((loaded.get_node("BuildingFlatten") as StrataLayer).data.snapshot() == before, "actual editor reopened exact manual values")
	print("TERRAIN_EDITOR_SMOKE failures=", failures, " high_stats=", high_stats)
	_done = true
	if failures == 0:
		# Exercise normal editor close instead of abruptly quitting its SceneTree.
		_lock_camera = false
		EditorInterface.get_base_control().get_parent().notification(NOTIFICATION_WM_CLOSE_REQUEST)
	else: get_tree().quit(1)
