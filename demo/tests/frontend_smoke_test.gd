extends SceneTree
## Exercises the real demo and its native resources without touching user saves.

var _failures: Array[String] = []
var _temporary_directory := "user://frontend_smoke_%d" % Time.get_ticks_usec()

func _initialize() -> void:
	_run.call_deferred()

func _check(condition: bool, description: String) -> void:
	if not condition:
		_failures.append(description)
		push_error(description)

func _run() -> void:
	if DisplayServer.get_name() != "headless":
		print("Frontend graphical adapter: %s; API %s" % [RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version()])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_temporary_directory))
	var packed: PackedScene = load("res://scenes/terrain_prototype/main.tscn")
	var demo: Variant = packed.instantiate()
	demo.save_path = _temporary_directory + "/layers.bin"
	demo.editor_example_directory = _temporary_directory + "/editor"
	root.add_child(demo)
	current_scene = demo
	await process_frame
	await process_frame
	var terrain: StrataTerrain3D = demo.terrain
	var manual: StrataLayer = demo.layers[1]
	var upper: StrataLayer = demo.layers[2]
	_check(terrain.get_layers().size() == 3, "Demo creates one procedural and two manual layers")
	var point := Vector2.ZERO
	var initial_height := terrain.sample_height(point, manual)
	var hit := terrain.raycast_surface(Vector3(0.0, 100.0, 0.0), Vector3.DOWN)
	_check(not hit.is_empty(), "Ray hits the preview mesh")
	if not hit.is_empty():
		_check(is_equal_approx(hit.position.y, initial_height), "Ray matches the actual preview mesh at its vertex")
	upper.data.set_sample(&"height", Vector2i.ZERO, 40.0)
	terrain.preview_through_layer = manual
	terrain.rebuild_preview()
	hit = terrain.raycast_surface(Vector3(0.0, 100.0, 0.0), Vector3.DOWN)
	_check(not hit.is_empty() and is_equal_approx(hit.position.y, initial_height), "Earlier layer hit testing excludes later layers")
	_check(is_equal_approx(terrain.sample_height(point), initial_height + 40.0), "Full-stack sampling remains independent of preview selection")
	terrain.preview_through_layer = upper
	terrain.rebuild_preview()
	hit = terrain.raycast_surface(Vector3(0.0, 100.0, 0.0), Vector3.DOWN)
	_check(not hit.is_empty() and is_equal_approx(hit.position.y, initial_height + 40.0), "Selecting upper layer displays its cumulative surface")
	upper.data.erase_sample(&"height", Vector2i.ZERO)
	terrain.preview_through_layer = manual
	terrain.rebuild_preview()
	var before := manual.data.snapshot()
	# Use the same per-stroke callbacks reached by viewport painting.
	demo._stroke_layer = manual
	demo._before = before
	demo._last_point = Vector2(INF, INF)
	demo._flatten = initial_height
	demo.operation = "raise"
	demo.radius = 2.5
	demo.strength = 1.0
	demo._dab(point)
	demo._finish_stroke()
	var after := manual.data.snapshot()
	_check(manual.data.has_sample(&"height", Vector2i.ZERO), "Viewport dab creates explicit ownership")
	_check(is_equal_approx(manual.data.get_sample(&"height", Vector2i.ZERO), initial_height + 1.0), "Raise stores the desired Replace surface on first touch")
	_check(demo._undo.size() == 1, "One completed stroke creates one undo action")
	var owned_height := manual.data.get_sample(&"height", Vector2i.ZERO)
	demo._regenerate(true)
	_check(is_equal_approx(manual.data.get_sample(&"height", Vector2i.ZERO), owned_height), "Regenerating the synthetic base preserves owned Replace values")
	_check(is_equal_approx(terrain.sample_height(point, manual), owned_height), "Owned Replace samples remain visible after regeneration")
	demo._undo_stroke()
	_check(manual.data.snapshot() == before, "Undo restores values and ownership")
	demo._redo_stroke()
	_check(manual.data.snapshot() == after, "Redo restores the complete stroke")
	demo._save_layers()
	_check(FileAccess.file_exists(demo.save_path), "Save writes the temporary layer file")
	manual.data.erase_sample(&"height", Vector2i.ZERO)
	demo._load_layers()
	_check(manual.data.snapshot() == after, "Reload restores native values, metadata and ownership")
	var fixture_path: String = demo.editor_example_directory + "/editor_example.tscn"
	_check(FileAccess.file_exists(fixture_path), "Save also creates an editor authoring scene")
	var fixture: PackedScene = ResourceLoader.load(fixture_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	_check(fixture != null, "Editor scene reloads with external native resources")
	if fixture != null:
		var first := fixture.instantiate() as StrataTerrain3D
		var second := fixture.instantiate() as StrataTerrain3D
		_check(first.get_layers().size() == 3, "Editor fixture has real selectable layer children")
		var first_data := first.get_layers()[1].data
		var second_data := second.get_layers()[1].data
		_check(first_data != second_data, "Scene instances receive independent native layer resources")
		var original_second := second_data.get_sample(&"height", Vector2i.ZERO)
		first_data.set_sample(&"height", Vector2i.ZERO, 999.0)
		_check(is_equal_approx(second_data.get_sample(&"height", Vector2i.ZERO), original_second), "Editing one scene instance cannot edit another instance")
		first.free()
		second.free()
	# Exercise pointer-based input too, using a mesh vertex projected to the view.
	terrain.rebuild_preview()
	var click_position: Vector2 = demo.camera.unproject_position(Vector3(8.0, terrain.sample_height(Vector2(8.0, 0.0), manual), 0.0))
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = click_position
	demo._unhandled_input(press)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	demo._input(release)
	_check(manual.data.has_sample(&"height", Vector2i(8, 0)), "Projected mouse click reaches the sculpting pipeline")
	# Same-value ownership must be visible without modifying any geometry.
	var same_point := Vector2(16.0, 16.0)
	manual.data.set_sample(&"height", Vector2i(16, 16), terrain.sample_height(same_point, manual))
	demo._overrides_toggle.button_pressed = false
	terrain.rebuild_preview()
	var clean_arrays: Array = terrain.get_preview_mesh().surface_get_arrays(0)
	demo._overrides_toggle.button_pressed = true
	terrain.rebuild_preview()
	var overlay_arrays: Array = terrain.get_preview_mesh().surface_get_arrays(0)
	_check(demo._overrides_toggle.text == "Show overrides", "Runtime exposes the ownership overlay toggle")
	_check(clean_arrays[Mesh.ARRAY_VERTEX] == overlay_arrays[Mesh.ARRAY_VERTEX], "Ownership overlay leaves preview geometry unchanged")
	_check(clean_arrays[Mesh.ARRAY_COLOR] != overlay_arrays[Mesh.ARRAY_COLOR], "Ownership overlay changes preview vertex colors")
	var same_value_vertex := 48 * 65 + 48
	_check(clean_arrays[Mesh.ARRAY_COLOR][same_value_vertex] != overlay_arrays[Mesh.ARRAY_COLOR][same_value_vertex], "Same-value owned sample has a visible ownership tint")
	_test_brush_limits()
	await _test_removed_cutoff()
	# Optional graphical capture: -- --capture=/absolute/path.png
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			if DisplayServer.get_name() == "headless":
				push_warning("Skipping screenshot in headless mode")
			else:
				await process_frame
				await RenderingServer.frame_post_draw
				var image := root.get_texture().get_image()
				var screenshot_error := image.save_png(argument.trim_prefix("--capture="))
				_check(screenshot_error == OK, "Graphical screenshot saved")
	demo.free()
	_cleanup(ProjectSettings.globalize_path(_temporary_directory))
	if _failures.is_empty():
		print("Frontend smoke: PASS (ray/mesh, preview cutoff, brush, regeneration, undo/redo, save/reload, instance independence, pointer input, ownership overlay)")
	else:
		print("Frontend smoke: FAIL (%d checks)" % _failures.size())
	quit(0 if _failures.is_empty() else 1)

func _cleanup(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)

func _test_brush_limits() -> void:
	var terrain := StrataTerrain3D.new()
	terrain.base_bounds = Rect2(-1.0, -1.0, 2.0, 2.0)
	var layer := StrataLayer.new()
	terrain.add_child(layer)
	root.add_child(terrain)
	layer.data.sample_spacing = 0.001
	var revision := layer.data.get_revision()
	var started := Time.get_ticks_usec()
	var touched := StrataBrush.apply_brush(layer, Vector2.ZERO, 20.0, 1.0, "raise")
	_check(touched == 0 and layer.data.get_revision() == revision, "Oversized tiny-spacing dab is rejected without mutation")
	_check(Time.get_ticks_usec() - started < 500000, "Oversized dab is rejected before iterating its candidate grid")
	for invalid in [[Vector2(NAN, 0.0), 1.0, 1.0], [Vector2.ZERO, INF, 1.0], [Vector2.ZERO, 1.0, INF]]:
		_check(StrataBrush.apply_brush(layer, invalid[0], invalid[1], invalid[2], "raise") == 0, "Nonfinite brush input is rejected")
	_check(layer.data.get_revision() == revision, "Nonfinite input never mutates ownership or values")
	_check(StrataBrush.apply_brush(layer, Vector2.ZERO, 1.0, -1.0, "flatten") == 0, "Negative flatten strength is a no-op")
	_check(StrataBrush.apply_brush(layer, Vector2.ZERO, 1.0, 1.0, "raise", &"") == 0, "Blank channel is rejected before sampling")
	_check(layer.data.get_revision() == revision and layer.data.get_owned_samples(&"height").is_empty(), "Negative strength and blank channel leave revision and ownership unchanged")
	layer.data.sample_spacing = 1.0
	touched = StrataBrush.apply_brush(layer, Vector2.ZERO, 1e30, 1.0, "raise")
	_check(touched == 9, "Huge radius is clipped to the finite terrain before candidate iteration")
	terrain.free()

func _test_removed_cutoff() -> void:
	var terrain := StrataTerrain3D.new()
	terrain.base_bounds = Rect2(-1.0, -1.0, 2.0, 2.0)
	var lower := StrataLayer.new()
	var selected := StrataLayer.new()
	for z in range(-1, 2):
		for x in range(-1, 2):
			lower.data.set_sample(&"height", Vector2i(x, z), 2.0)
			selected.data.set_sample(&"height", Vector2i(x, z), 9.0)
	terrain.add_child(lower)
	terrain.add_child(selected)
	root.add_child(terrain)
	terrain.preview_through_layer = selected
	terrain.rebuild_preview()
	terrain.remove_child(selected)
	terrain.rebuild_preview()
	_check(terrain.preview_through_layer == null, "Detaching selected layer clears the preview cutoff")
	var hit := terrain.raycast_surface(Vector3(0.0, 20.0, 0.0), Vector3.DOWN)
	_check(not hit.is_empty() and is_equal_approx(hit.position.y, 2.0), "Detached cutoff rebuilds the remaining full stack")
	_check(is_nan(terrain.sample_height(Vector2.ZERO, selected)), "Public sampling explicitly rejects a detached cutoff")
	var stale: Variant = selected
	selected.free()
	_check(is_nan(terrain.sample_height(Vector2.ZERO, stale)), "Public sampling safely rejects a freed cutoff")
	var freed_selected := StrataLayer.new()
	terrain.add_child(freed_selected)
	terrain.preview_through_layer = freed_selected
	freed_selected.free()
	terrain.rebuild_preview()
	_check(terrain.preview_through_layer == null, "Freeing selected layer clears the preview cutoff")
	hit = terrain.raycast_surface(Vector3(0.0, 20.0, 0.0), Vector3.DOWN)
	_check(not hit.is_empty() and is_equal_approx(hit.position.y, 2.0), "Freed cutoff keeps preview sampling valid")
	var updates := [0]
	terrain.preview_updated.connect(func(): updates[0] += 1)
	await process_frame
	await process_frame
	var settled: int = updates[0]
	for frame in range(4):
		await process_frame
	_check(updates[0] == settled, "Empty preview selection does not schedule perpetual mesh rebuilds")
	terrain.free()
