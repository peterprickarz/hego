extends "res://tests/runtime_test_base.gd"
## Runs in a project holding only the runtime scripts: no terrain extension,
## authoring scripts, HEGo or Houdini. Loads the exported scene and data.

const S := StrataRuntimeData.Status

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	check(not ClassDB.class_exists("StrataLayerData") and not ClassDB.class_exists("HEGoAPI"), "no native terrain or HEGo classes are loaded")
	var globals := ProjectSettings.get_global_class_list().map(func(entry: Dictionary) -> String: return entry["class"])
	check(not globals.has("StrataTerrain3D") and not globals.has("StrataLayer") and not globals.has("StrataBake"), "no authoring scripts in this project: %s" % [globals])
	var expected: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://export/expected.json"))
	var packed: PackedScene = load("res://export/runtime_terrain.scn")
	check(packed != null, "runtime scene loads")
	var terrain: Node3D = packed.instantiate()
	get_root().add_child(terrain)
	var data: StrataRuntimeData = terrain.get_meta(&"strata_runtime_data")
	check(data != null and data.resource_path == "res://export/runtime_data.res", "compiled data is the external resource: %s" % (data.resource_path if data else "null"))
	check(data.validate().ok and data.bake_revision == int(expected.revision), "data validates with the exported revision")
	check(terrain.transform.is_equal_approx(str_to_var(expected.transform)), "terrain transform preserved")
	check(payload_hashes(data) == expected.hashes, "exported payload bytes are bit-identical: %s" % payload_hashes(data))
	var collision: StrataCollision = terrain.get_node("Collision")
	var navigation: StrataNavigation = terrain.get_node("Navigation")
	check(collision.data == data and navigation.data == data, "children share the one compiled resource")
	# This test drives every bake itself; the nodes' whole-terrain automatics would add regions
	# before the baseline below is taken.
	collision.auto_prepare = false
	navigation.auto_bake = false
	check(collision.chunk_cells == 16 and collision.collision_layer == 4 and navigation.tile_cells == 16, "exported settings persisted")

	var holes := 0
	for row in expected.rows:
		var point := Vector2(row.x, row.z)
		var sampled := data.sample_height(point)
		check(sampled.status == int(row.status), "status at %s" % point)
		# JSON keeps ~15 significant digits; payload identity is the hash check.
		if sampled.status == S.OK:
			near(sampled.value, row.height, 0.000000001, "height at %s" % point)
		holes += 1 if sampled.status == S.HOLE else 0
		var mask := data.sample_channel(&"mask", point)
		check(mask.status == int(row.mask_status) and (mask.status != S.OK or absf(mask.value - row.mask) < 0.000000001), "mask at %s" % point)
	check(holes > 0, "roundtrip covers hole queries")

	# Static navigation profiles load, are reproducible here, and bake.
	var D := StrataRuntimeData.DEFAULT_NAV_PROFILE
	check(data.get_nav_profile_names().map(func(name: StringName) -> String: return String(name)) == expected.profiles and data.has_nav_profile(&"wet") and data.has_nav_profile(D), "profiles load from the exported data: %s" % [data.get_nav_profile_names()])
	check(float(data.get_nav_profile_rule(&"flat_dry").all[0].slope_max) == 20.123456789 and data.get_nav_profile_rule(D) == {"exclusion": true}, "rules load with exact thresholds")
	for name in data.get_nav_profile_names():
		if name == D: continue
		var reevaluated := true
		for y in range(data.grid.y):
			for x in range(data.grid.x):
				var region := data.get_region(Vector2i(x, y))
				reevaluated = reevaluated and StrataNavProfiles.evaluate_region(region, data.get_nav_profile_rule(name), data.channel_names) == region.level_bytes(StrataRegions.nav_map_name(name))
		check(reevaluated, "profile %s re-evaluates to its stored mask in every region without the extension" % name)
	var wet_navigation := StrataNavigation.new()
	wet_navigation.profile = &"flat_dry"
	wet_navigation.navigation_layers = 8
	wet_navigation.tile_cells = 16
	wet_navigation.use_async = false
	wet_navigation.data = data
	terrain.add_child(wet_navigation)
	var profiled := wet_navigation.bake_region(data.bounds)
	check(profiled.ok and profiled.regions > 0 and wet_navigation.get_stats().profile == &"flat_dry", "a profiled population bakes without the extension: %s" % profiled)
	var faces := 0
	for key_z in range(wet_navigation.get_tile_grid().y):
		for key_x in range(wet_navigation.get_tile_grid().x):
			faces += wet_navigation.build_source_faces(wet_navigation.get_tile_cells(Vector2i(key_x, key_z))).size() / 6
	var open_cells := 0
	var cells := data.get_cell_resolution()
	for z in range(cells.y):
		for x in range(cells.x):
			open_cells += 0 if data.is_nav_blocked_cell(Vector2i(x, z), &"flat_dry") else 1
	check(faces == open_cells and open_cells < cells.x * cells.y, "profiled source faces are exactly the open cells (%d)" % open_cells)
	wet_navigation.profile = &"missing"
	check(not wet_navigation.bake_region(data.bounds).ok, "a missing profile fails the bake without the extension")
	wet_navigation.free()

	check(collision.prepare_region(data.bounds).ok, "collision builds without the extension")
	await physics_frame
	await physics_frame
	var space := terrain.get_world_3d().direct_space_state
	var worst := 0.0
	for row in expected.rows:
		if int(row.status) == S.OUTSIDE:
			continue
		var from := terrain.global_transform * Vector3(row.x, 50.0, row.z)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 200.0, 4))
		if int(row.status) == S.HOLE:
			check(hit.is_empty(), "hole at %s,%s stays open" % [row.x, row.z])
		elif hit.is_empty():
			check(false, "missing collision at %s,%s" % [row.x, row.z])
		else:
			var surface := terrain.global_transform * Vector3(row.x, row.height, row.z)
			worst = maxf(worst, (hit.position as Vector3).distance_to(surface))
	check(worst < 0.0005, "roundtrip collision matches baked heights (max %s)" % worst)

	var map := terrain.get_world_3d().navigation_map
	var baseline := NavigationServer3D.map_get_regions(map).size()
	var baked := navigation.bake_region(data.bounds)
	check(baked.ok and baked.regions > 1, "navigation bakes without the extension: %s" % baked)
	var nav_from := terrain.global_transform * Vector3(expected.nav_from[0], data.sample_height(Vector2(expected.nav_from[0], expected.nav_from[1])).value, expected.nav_from[1])
	var nav_to := terrain.global_transform * Vector3(expected.nav_to[0], data.sample_height(Vector2(expected.nav_to[0], expected.nav_to[1])).value, expected.nav_to[1])
	# The server merges the new regions on its own thread; the number of frames that takes
	# depends on the machine, so wait (bounded) for the map to connect instead of a fixed count.
	var path := PackedVector3Array()
	for frame in range(180):
		await physics_frame
		await process_frame
		path = NavigationServer3D.map_get_path(map, nav_from, nav_to, true)
		if frame >= 3 and path.size() >= 2 and path[-1].distance_to(nav_to) < 0.75: break
	check(path.size() >= 2 and path[-1].distance_to(nav_to) < 0.75, "navigation path across tiles reaches its goal (%d points)" % path.size())

	# ResourceSaver roundtrip of the loaded data, binary and text.
	for path_name in ["res://export/resaved.res", "res://export/resaved.tres"]:
		check(ResourceSaver.save(data, path_name) == OK, "resave %s" % path_name)
		var loaded: StrataRuntimeData = ResourceLoader.load(path_name, "", ResourceLoader.CACHE_MODE_IGNORE)
		check(loaded != null and payload_hashes(loaded) == expected.hashes, "%s is bit-identical" % path_name)
		check(loaded != null and loaded.heights_window(Rect2i(Vector2i.ZERO, data.get_cell_resolution())) == data.heights_window(Rect2i(Vector2i.ZERO, data.get_cell_resolution())) and loaded.cell_mask_window("holes", Rect2i(Vector2i.ZERO, data.get_cell_resolution())) == data.cell_mask_window("holes", Rect2i(Vector2i.ZERO, data.get_cell_resolution())) and loaded.channel_names == data.channel_names and loaded.bounds == data.bounds and loaded.maps == data.maps and loaded.grid == data.grid, "%s preserves every payload" % path_name)
		check(loaded != null and loaded.nav_profile_rules == data.nav_profile_rules and loaded.nav_profile_rules.keys()[0] is StringName and loaded.validate().ok, "%s preserves profiles and exact rules" % path_name)
		var material_same := loaded != null
		for xy in data.regions:
			material_same = material_same and loaded.get_region(xy).level_bytes("material_ids") == data.regions[xy].level_bytes("material_ids") and loaded.get_region(xy).level_bytes("material_weights") == data.regions[xy].level_bytes("material_weights")
		check(material_same and data.maps.has("material_weights"), "%s preserves material maps" % path_name)
	var text: StrataRuntimeData = ResourceLoader.load("res://export/runtime_data_text.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	check(text != null and payload_hashes(text) == expected.hashes and text.validate().ok, "text resource written by the authoring project is bit-identical here")
	var corrupt: StrataRuntimeData = StrataRuntimeData.new()
	corrupt.set("lattice_data", PackedByteArray([1, 2, 3]))
	check(not corrupt.validate().ok, "a malformed stored payload fails validation")

	terrain.queue_free()
	for frame in range(4):
		await physics_frame
		await process_frame
	check(NavigationServer3D.map_get_regions(map).size() == baseline, "freeing the runtime terrain removes its regions")
	finish("RUNTIME_ROUNDTRIP_TEST")
