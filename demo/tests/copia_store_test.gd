## CopiaStore3D contracts: write builds the touched cells; streaming loads the expected groups
## by range and announces each once; moving away unloads them; a clearing write replaces what is
## drawn; a load-time setting (range, per-surface and impostor materials) changes live params
## without a build; a build input rebuilds in the background and replaces the live groups;
## impostor groups are linked to their children; colliders follow their distance and resolve a
## ray hit; load_now loads in one call what streaming loads and leaves nothing to do, and reports
## a failure (hidden, outside the world) or a timeout; streaming_settled fires once per load;
## hiding unloads and showing streams again; excluded rectangles unload and refill their cells and
## far cells; draw overrides reach live and later groups without touching the object; freeing
## the node with reads in flight leaves nothing; to_nodes gives
## back the written instance counts; set_summary matches the sets index; build_async builds in the
## background with its signals, refuses a second build while one runs, and leaves the loaded
## groups in place; a settings change passes only the changed values to the live groups.
## Headless: the renderer is a dummy, so only bookkeeping is asserted. Objects are created in
## code and saved under a scratch directory in user://, which is deleted afterwards.
##
##   godot-4.7.2 --path demo --headless --script res://tests/copia_store_test.gd
##
## Prints COPIA_STORE_TEST PASS or FAIL and exits 0 or 1. Run time: about 4 s.
extends SceneTree

const EXTENSION := "res://addons/copia/bin/copia.gdextension"
const ObjectScript := preload("res://addons/copia/copia_object.gd")
const RenderScript := preload("res://addons/copia/copia_render_settings.gd")
const PhysicsScript := preload("res://addons/copia/copia_physics_settings.gd")
const StoreScript := preload("res://addons/copia/copia_store_3d.gd")
const CELL := 64.0
const CELLS := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(10, 10)]
const NEAR_CELLS := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)]
const CENTRE := Vector3(32, 0, 32)

var failures: Array[String] = []
var scratch := "user://copia_store_test_%d" % OS.get_process_id()
var data := ""
var grass_path := ""
var tree_path := ""
var rock_path := ""
var rng := RandomNumberGenerator.new()
var store: Node3D
var added := {}  # "kind:id" -> times announced
var removed := {}
var written := {}  # object path -> instances written


func _initialize() -> void:
	call_deferred("run")


func check(value: bool, description: String) -> void:
	if not value:
		failures.append(description)
		push_error("FAIL: " + description)


func remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for directory in DirAccess.get_directories_at(path):
		remove_tree(path.path_join(directory))
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)


func make_objects() -> void:
	DirAccess.make_dir_recursive_absolute(scratch.path_join("objects"))
	grass_path = scratch.path_join("objects/grass.tres")
	tree_path = scratch.path_join("objects/tree.tres")
	rock_path = scratch.path_join("objects/rock.tres")
	var grass := ObjectScript.new()
	var grass_mesh := BoxMesh.new()
	grass_mesh.size = Vector3(0.3, 0.5, 0.3)
	grass.mesh = grass_mesh
	grass.render = RenderScript.new()
	grass.render.batch_size = 16.0
	grass.render.visibility_range_end = 40.0
	check(ResourceSaver.save(grass, grass_path) == OK, "grass object saved")
	var tree := ObjectScript.new()
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.5
	trunk.bottom_radius = 0.5
	trunk.height = 6.0
	tree.mesh = trunk
	tree.impostor_mesh = QuadMesh.new()
	tree.render = RenderScript.new()
	tree.render.draw_mode = RenderScript.DrawMode.INSTANCE
	tree.render.visibility_range_end = 60.0
	tree.render.impostor_range_end = 0.0  # every far cell, from the start
	tree.physics = PhysicsScript.new()
	tree.physics.kind = PhysicsScript.Kind.FIT_CAPSULE
	tree.physics.distance = 30.0
	check(ResourceSaver.save(tree, tree_path) == OK, "tree object saved")
	var rock := ObjectScript.new()
	rock.mesh = BoxMesh.new()
	rock.render = RenderScript.new()
	rock.render.batch_size = 32.0
	rock.render.visibility_range_end = 50.0
	rock.physics = PhysicsScript.new()  # convex, distance 0: the store's collider_distance
	check(ResourceSaver.save(rock, rock_path) == OK, "rock object saved")
	ObjectScript.clear_cache()


func points_for(cells: Array, grass_count: int, trees: bool, rocks: bool) -> Dictionary:
	var transform := PackedFloat32Array()
	var object := PackedInt32Array()
	var add := func(index: int, origin: Vector3) -> void:
		transform.append_array(PackedFloat32Array([1, 0, 0, 0, 1, 0, 0, 0, 1, origin.x, origin.y, origin.z]))
		object.append(index)
		var path: String = [grass_path, tree_path, rock_path][index]
		written[path] = written.get(path, 0) + 1
	for cell: Vector2i in cells:
		var base := Vector3(cell.x * CELL, 0, cell.y * CELL)
		for i in grass_count:
			add.call(0, base + Vector3(rng.randf() * CELL, 0, rng.randf() * CELL))
		if trees:
			add.call(1, base + Vector3(20, 0, 20))
			for i in 10:
				add.call(1, base + Vector3(rng.randf_range(5, 30), 0, rng.randf_range(5, 30)))
		if rocks:
			for i in 20:
				add.call(2, base + Vector3(rng.randf() * CELL, 0, rng.randf_range(40, 60)))
	return {"transform": transform, "object": object, "object_paths": PackedStringArray([grass_path, tree_path, rock_path])}


func on_added(info: Dictionary) -> void:
	var key := "%s:%d" % ["collider" if info.kind == "collider" else "draw", info.group]
	added[key] = added.get(key, 0) + 1


func on_removed(info: Dictionary) -> void:
	var key := "%s:%d" % ["collider" if info.kind == "collider" else "draw", info.group]
	removed[key] = removed.get(key, 0) + 1


## Frames until the store has nothing pending, or the time runs out.
func settle(node: Node3D = null, seconds := 10.0) -> bool:
	if node == null:
		node = store
	# Quiet for several update intervals, so an update that is due has run.
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	var quiet_since := -1
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if node.get_stats().pending != 0:
			quiet_since = -1
		elif quiet_since < 0:
			quiet_since = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - quiet_since >= 100:
			return true
	return false


## Frames until the node's background build is done and applied, or the time runs out.
func wait_build(node: Node3D, seconds := 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while node.is_building() and Time.get_ticks_msec() < deadline:
		await process_frame
	return not node.is_building()


func sorted(values: Array) -> Array:
	var copy := values.duplicate()
	copy.sort()
	return copy


func move(position: Vector3) -> bool:
	store.update_streaming(position)
	return await settle()


## {"kind|path|cell": group id} of the live groups (replacements finished).
func live() -> Dictionary:
	var result := {}
	for info in store.get_loaded_groups():
		result["%s|%s|%s" % [info.kind, info.object_path, info.cell]] = info.group
	return result


func new_store(directory: String) -> Node3D:
	var node: Node3D = StoreScript.new()
	node.data_directory = directory
	node.cell_size = CELL
	node.impostor_cell_size = 128.0
	node.update_interval = 0.02
	node.collider_distance = 50.0
	root.add_child(node)
	return node


## {"kind|path|cell": group id} of a store's live groups.
func ids_of(node: Node3D) -> Dictionary:
	var result := {}
	for info in node.get_loaded_groups():
		result[key(info.kind, info.object_path, info.cell)] = info.group
	return result


func key(kind: String, path: String, cell: Vector2i) -> String:
	return "%s|%s|%s" % [kind, path, cell]


func instance_total(groups: Dictionary, path: String, cell: Vector2i) -> int:
	var id: int = groups.get(key("draw", path, cell), 0)
	return store.get_drawer().get_group_info(id).get("instance_count", -1) if id != 0 else 0


func far_batch(far: Vector2i, cell: Vector2i) -> int:
	var section: Dictionary = ClassDB.class_call_static("CopiaCells", "read_section", data.path_join("far/%d_%d.copiacell" % [far.x, far.y]), tree_path, "draw")
	var cells: PackedInt32Array = section.get("batch_cells", PackedInt32Array())
	for b in cells.size() / 2:
		if Vector2i(cells[b * 2], cells[b * 2 + 1]) == cell:
			return b
	return -1


func check_link(groups: Dictionary, cell: Vector2i, description: String) -> void:
	var child: int = groups.get(key("draw", tree_path, cell), 0)
	var impostor: int = groups.get(key("impostor", tree_path, Vector2i(floori(cell.x / 2.0), floori(cell.y / 2.0))), 0)
	check(child != 0 and impostor != 0, "%s: tree group and its impostor group are live" % description)
	if child == 0 or impostor == 0:
		return
	var link: Dictionary = store.get_drawer().get_group_info(child).get("impostor_link", {})
	check(link.get("impostor") == impostor and link.get("batch") == far_batch(Vector2i(floori(cell.x / 2.0), floori(cell.y / 2.0)), cell) and is_equal_approx(link.get("swap_distance", 0.0), 60.0),
			"%s: tree group of %s is linked to its far cell's batch at the tree range (%s)" % [description, cell, link])
	check(store.get_drawer().get_group_info(impostor).linked_children.has(child), "%s: the impostor lists the child" % description)


func run() -> void:
	if not ClassDB.class_exists("CopiaDrawer"):
		GDExtensionManager.load_extension(EXTENSION)
	if not ClassDB.class_exists("CopiaDrawer"):
		push_error("Copia is not available")
		quit(1)
		return
	var started := Time.get_ticks_msec()
	rng.seed = 7
	remove_tree(scratch)
	data = scratch.path_join("data")
	make_objects()

	store = StoreScript.new()
	store.data_directory = data
	store.cell_size = CELL
	store.impostor_cell_size = 128.0
	store.update_interval = 0.02
	store.collider_distance = 50.0
	store.watch_objects = true
	store.group_added.connect(on_added)
	store.group_removed.connect(on_removed)
	root.add_child(store)

	# Write: set files, built cells and far cells; nothing stale.
	var report: Dictionary = store.write([], points_for(CELLS, 300, true, true))
	check(report.ok, "write: %s" % report.error)
	for cell in CELLS:
		check(FileAccess.file_exists(data.path_join("sets/default/%d_%d.copiaset" % [cell.x, cell.y])), "set file of %s" % cell)
		check(FileAccess.file_exists(data.path_join("cells/%d_%d.copiacell" % [cell.x, cell.y])), "built cell %s" % cell)
	check(FileAccess.file_exists(data.path_join("far/0_0.copiacell")) and FileAccess.file_exists(data.path_join("far/5_5.copiacell")), "far cells built")
	check(FileAccess.file_exists(data.path_join("sets/index.copiaindex")) and FileAccess.file_exists(data.path_join("cells/index.copiaindex")), "index files written")
	check(store.stale_cells().is_empty(), "nothing stale after write: %s" % [store.stale_cells()])
	check(report.build.get("defaulted", []).is_empty(), "every object had a descriptor")

	# Streaming at the edge: the rock collider reaches cell 0_0, the tree collider not yet.
	check(await move(Vector3(32, 0, -50)), "settled at the edge")
	var groups := live()
	check(groups.has(key("draw", tree_path, Vector2i(0, 0))) and groups.has(key("collider", rock_path, Vector2i(0, 0))), "at 50 m: tree drawn, rock colliders")
	check(not groups.has(key("collider", tree_path, Vector2i(0, 0))), "at 50 m: no tree colliders (distance 30 + margin 16)")
	check(not groups.has(key("draw", grass_path, Vector2i(1, 0))), "at 59 m: no grass in 1_0 (range 40 + margin 16)")

	# Streaming at the centre: every near group, each announced once.
	check(await move(CENTRE), "settled at the centre")
	groups = live()
	var expected := []
	for cell in NEAR_CELLS:
		for path in [grass_path, tree_path, rock_path]:
			expected.append(key("draw", path, cell))
		expected.append(key("collider", tree_path, cell))
		expected.append(key("collider", rock_path, cell))
	expected.append(key("impostor", tree_path, Vector2i(0, 0)))
	expected.append(key("impostor", tree_path, Vector2i(5, 5)))
	var names := groups.keys()
	names.sort()
	expected.sort()
	check(names == expected, "live groups at the centre are %s (got %s)" % [expected, names])
	var stats: Dictionary = store.get_stats()
	check(stats.groups == expected.size() and stats.drawer.groups == expected.size() - 6 and stats.colliders.groups == 6, "stats count the groups: %s" % stats)
	for name in groups:
		var announced := "%s:%d" % ["collider" if name.begins_with("collider") else "draw", groups[name]]
		check(added.get(announced, 0) == 1, "group_added once for %s" % name)
	check(instance_total(groups, grass_path, Vector2i(1, 0)) == 300 and instance_total(groups, tree_path, Vector2i(1, 0)) == 11, "drawn instance counts match the writes")
	check(store.get_drawer().get_group_info(groups[key("draw", grass_path, Vector2i(0, 0))]).params.visibility_end == 40.0, "draw params come from the object")
	check_link(groups, Vector2i(0, 0), "centre")
	check_link(groups, Vector2i(1, 0), "centre")
	check(store.get_drawer().get_group_info(groups[key("impostor", tree_path, Vector2i(5, 5))]).params.visibility_end == 0.0, "impostor range end is the object's impostor range")

	# Colliders: a ray hit resolves to object, cell and instance.
	await physics_frame
	await physics_frame
	var space := store.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(84, 50, 20), Vector3(84, -10, 20)))
	check(not hit.is_empty(), "ray hits the tree in 1_0")
	if not hit.is_empty():
		var info: Dictionary = store.get_collider_info(hit.rid)
		check(info.get("object_path") == tree_path and info.get("cell") == Vector2i(1, 0) and info.get("index", -1) >= 0 and info.index < 11, "ray hit resolves: %s" % info)
		check(hit.collider == store, "the ray's collider is the store node")
	var rock_group: int = groups[key("collider", rock_path, Vector2i(0, 1))]
	var body: RID = store.get_colliders().get_group_rids(rock_group)[3]
	check(store.get_collider_info(body) == {"object_path": rock_path, "cell": Vector2i(0, 1), "index": 3}, "a body RID resolves to its instance")
	check(store.get_collider_info(RID()).is_empty(), "an unknown body gives {}")

	# Moving away unloads every near group; the unlimited impostors stay.
	var before := groups.duplicate()
	check(await move(Vector3(3000, 0, 3000)), "settled far away")
	groups = live()
	check(groups.keys().size() == 2 and groups.has(key("impostor", tree_path, Vector2i(0, 0))), "far away only the impostors remain: %s" % [groups.keys()])
	for name in before:
		if not name.begins_with("impostor"):
			var announced := "%s:%d" % ["collider" if name.begins_with("collider") else "draw", before[name]]
			check(removed.get(announced, 0) == 1, "group_removed once for %s" % name)
	stats = store.get_stats()
	check(stats.drawer.groups == 2 and stats.colliders.groups == 0 and stats.drawer.pending_free == 0, "far away the native groups are freed: %s" % stats)

	# A clearing write replaces what is drawn in 0_0.
	check(await move(CENTRE), "settled back at the centre")
	before = live()
	written.clear()
	report = store.write([{"set": "default", "cell": Vector2i(0, 0)}], points_for([Vector2i(0, 0)], 100, false, false))
	check(report.ok, "clearing write: %s" % report.error)
	check(await settle(), "settled after the clearing write")
	groups = live()
	var grass_00 := key("draw", grass_path, Vector2i(0, 0))
	check(groups.has(grass_00) and groups[grass_00] != before[grass_00], "grass of 0_0 is a new group")
	check(instance_total(groups, grass_path, Vector2i(0, 0)) == 100, "grass of 0_0 has the new 100 instances")
	check(removed.get("draw:%d" % before[grass_00], 0) == 1, "the old grass group was removed")
	for name in [key("draw", tree_path, Vector2i(0, 0)), key("draw", rock_path, Vector2i(0, 0)), key("collider", tree_path, Vector2i(0, 0))]:
		check(not groups.has(name), "cleared %s is gone" % name)
	check(groups.get(key("draw", grass_path, Vector2i(1, 0))) == before[key("draw", grass_path, Vector2i(1, 0))], "an untouched cell keeps its groups")
	check(groups.get(key("impostor", tree_path, Vector2i(0, 0))) != before[key("impostor", tree_path, Vector2i(0, 0))], "the rebuilt far cell's impostor group is replaced")
	check_link(groups, Vector2i(1, 0), "after the clearing write")

	# A load-time setting: live params change, the built file does not.
	var cell_file := data.path_join("cells/1_0.copiacell")
	var bytes := FileAccess.get_file_as_bytes(cell_file)
	var grass: Resource = ObjectScript.resolve(grass_path)
	grass.render.visibility_range_end = 45.0
	check(store.get_drawer().get_group_info(groups[key("draw", grass_path, Vector2i(1, 0))]).params.visibility_end == 45.0, "visibility_range_end reaches the live group")
	check(not store.get_stats().rebuild_scheduled, "a load-time setting schedules no build")
	grass.render.extra_cull_margin = 2.5
	var grass_params: Dictionary = store.get_drawer().get_group_info(groups[key("draw", grass_path, Vector2i(1, 0))]).params
	check(grass_params.extra_cull_margin == 2.5 and grass_params.visibility_end == 45.0, "a second setting reaches the live group and keeps the first (%s, %s)" % [grass_params.extra_cull_margin, grass_params.visibility_end])
	check(StoreScript._params_diff({"a": 1, "b": 2.0, "c": [RID()]}, {"a": 1, "b": 3.0, "c": [RID()]}) == {"b": 3.0} and StoreScript._params_diff(null, {"a": 1}) == {"a": 1},
			"a settings change passes only the keys whose value changed")
	grass.render.extra_cull_margin = 0.0
	check(await settle(), "settled after the range change")
	check(FileAccess.get_file_as_bytes(cell_file) == bytes, "the built cell is unchanged")
	var tree: Resource = ObjectScript.resolve(tree_path)
	tree.render.visibility_range_end = 70.0
	var link: Dictionary = store.get_drawer().get_group_info(groups[key("draw", tree_path, Vector2i(1, 0))]).get("impostor_link", {})
	check(is_equal_approx(link.get("swap_distance", 0.0), 70.0), "a new tree range moves the impostor swap (%s)" % link)
	tree.render.visibility_range_end = 60.0

	# Per-surface and impostor materials are load-time values: live groups take them at once.
	var bark := StandardMaterial3D.new()
	var card := StandardMaterial3D.new()
	tree.surface_materials = [bark] as Array[Material]
	tree.impostor_material = card
	var tree_info: Dictionary = store.get_drawer().get_group_info(groups[key("draw", tree_path, Vector2i(1, 0))])
	check(tree_info.params.surface_materials == [bark.get_rid()], "surface materials reach the live tree group (%s)" % [tree_info.params.surface_materials])
	var far_info: Dictionary = store.get_drawer().get_group_info(groups[key("impostor", tree_path, Vector2i(0, 0))])
	check(far_info.params.material_override == card.get_rid() and far_info.params.surface_materials == [], "the impostor group takes the impostor material and no surface materials")
	check(not store.get_stats().rebuild_scheduled, "materials schedule no build")
	tree.surface_materials = [] as Array[Material]
	tree.impostor_material = null
	check(store.get_drawer().get_group_info(groups[key("draw", tree_path, Vector2i(1, 0))]).params.surface_materials == [], "cleared surface materials reach the live group")

	# A build input: background rebuild, bytes differ, live groups replaced.
	before = live()
	grass.render.batch_size = 32.0
	check(store.get_stats().rebuild_scheduled, "batch_size schedules a rebuild")
	check(await settle(null, 20.0), "settled after the rebuild")
	check(store.get_last_build().get("ok", false), "background build: %s" % store.get_last_build().get("error"))
	check(FileAccess.get_file_as_bytes(cell_file) != bytes, "the built cell changed")
	check(store.stale_cells().is_empty(), "nothing stale after the background build")
	groups = live()
	for cell in NEAR_CELLS:
		var name := key("draw", grass_path, cell)
		check(groups.has(name) and groups[name] != before[name] and removed.get("draw:%d" % before[name], 0) == 1, "grass of %s replaced after the rebuild" % cell)
		check(store.get_drawer().get_group_info(groups.get(name, 0)).get("count", 0) <= 4, "grass of %s has 32 m batches" % cell)
	check(groups.get(key("draw", rock_path, Vector2i(1, 0))) == before[key("draw", rock_path, Vector2i(1, 0))], "rock groups are not touched by a grass rebuild")

	# to_nodes: the same instance counts as written.
	var nodes: Node3D = store.to_nodes(Rect2(-10000, -10000, 20000, 20000))
	var counted := {}
	var names_ok := true
	for cell_node in nodes.get_children():
		for child: MultiMeshInstance3D in cell_node.get_children():
			var base := String(child.name).rsplit("_", true, 1)[0]
			counted[base] = counted.get(base, 0) + child.multimesh.instance_count
			names_ok = names_ok and Vector2i(int(String(cell_node.name).split("_")[0]), int(String(cell_node.name).split("_")[1])) in CELLS
	var expected_counts := {"grass": 300 * 3 + 100, "tree": 11 * 3, "rock": 20 * 3}
	check(counted == expected_counts, "to_nodes instance counts %s (expected %s)" % [counted, expected_counts])
	check(names_ok, "to_nodes names cells <cx>_<cz>")
	check(nodes.get_node_or_null("1_0/tree_0") is MultiMeshInstance3D and nodes.get_node_or_null("1_0/grass_0") is MultiMeshInstance3D, "to_nodes names nodes <cell>/<object>_<batch>")
	# The dummy renderer keeps no buffers, so the column-to-row conversion is checked directly.
	var columns := PackedFloat32Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24])
	var rows: PackedFloat32Array = StoreScript._rows_from_columns(columns, 2)
	check(rows == PackedFloat32Array([1, 4, 7, 10, 2, 5, 8, 11, 3, 6, 9, 12, 13, 16, 19, 22, 14, 17, 20, 23, 15, 18, 21, 24]), "single-instance transforms become MultiMesh rows (%s)" % rows)
	nodes.free()

	# set_summary: per set, the cells and points of the sets index, as CopiaSets.list_cells gives them.
	var summary: Array = store.set_summary()
	var listed: Array = ClassDB.class_call_static("CopiaSets", "list_cells", data, "default")
	var listed_points := 0
	for entry in listed:
		listed_points += int(entry.count)
	check(summary.size() == 1 and summary[0].set == "default" and summary[0].cells == listed.size() and summary[0].instances == listed_points,
			"set_summary gives each set's cells and points (%s; index %d cells, %d points)" % [summary, listed.size(), listed_points])

	# build_async: a background build of the stale cells, then a forced rebuild of every cell; the
	# signals, is_building, a second call refused while one runs, and the report.
	var build_events := []
	var on_started := func() -> void: build_events.append("started")
	var on_finished := func(report_in: Dictionary) -> void: build_events.append(report_in)
	store.build_started.connect(on_started)
	store.build_finished.connect(on_finished)
	var live_before := live()
	check(not store.is_building(), "no build runs before build_async")
	check(store.build_async(), "build_async starts a build of the stale cells")
	check(store.is_building() and build_events == ["started"], "build_started is emitted at once and is_building is true (%s)" % [build_events])
	check(not store.build_async(), "a second build_async is refused while one runs")
	check(await wait_build(store), "the background build finishes")
	check(build_events.size() == 2 and build_events[1] is Dictionary, "build_finished is emitted once (%d events)" % build_events.size())
	var async_report: Dictionary = build_events[-1] if build_events[-1] is Dictionary else {}
	check(async_report.get("ok", false) and async_report.get("stale", [1]).is_empty() and async_report.get("written", [1]).is_empty() and async_report.has("usec"),
			"nothing stale: the report is ok and writes nothing (%s)" % [async_report])
	check(store.get_last_build() == async_report, "get_last_build returns the same report")
	build_events.clear()
	var all_cells: Array = store.rebuild_all_cells()
	check(all_cells.size() == CELLS.size(), "rebuild_all_cells lists every cell with set files (%d)" % all_cells.size())
	var async_started := Time.get_ticks_usec()
	check(store.build_async(all_cells, true), "build_async with cells and force starts")
	var call_usec := Time.get_ticks_usec() - async_started
	check(await wait_build(store), "the forced background build finishes")
	async_report = build_events[-1] if not build_events.is_empty() and build_events[-1] is Dictionary else {}
	check(async_report.get("ok", false) and async_report.get("written", []).size() + async_report.get("unchanged", []).size() >= all_cells.size(),
			"the forced build covers every cell (%d written, %d unchanged)" % [async_report.get("written", []).size(), async_report.get("unchanged", []).size()])
	check(await settle(), "settled after the background builds")
	check(sorted(live().keys()) == sorted(live_before.keys()), "the loaded groups are the same after the background builds")
	print("COPIA_STORE_TEST build_async: call %d us, forced build of %d cells %.1f ms on the build thread" % [call_usec, all_cells.size(), async_report.get("usec", 0) / 1000.0])
	store.build_started.disconnect(on_started)
	store.build_finished.disconnect(on_finished)

	# Hidden: everything unloads; shown: it streams again.
	store.visible = false
	check(await settle(), "settled hidden")
	stats = store.get_stats()
	check(stats.groups == 0 and stats.drawer.groups == 0 and stats.drawer.instances == 0 and stats.colliders.bodies == 0, "hidden: nothing loaded: %s" % stats)
	store.visible = true
	for i in 5:
		await process_frame
	check(await settle(), "settled shown")
	check(store.get_stats().groups == expected.size() - 4, "shown: the groups stream again without an explicit update (%d)" % store.get_stats().groups)
	check(await move(CENTRE), "settled shown at the centre")
	check(store.get_stats().groups == expected.size() - 4, "shown: the groups stream again (%d)" % store.get_stats().groups)

	# Excluded rectangles: cells whose centre lies in one unload, far cells too; clearing the list
	# loads them again; the exclusion holds from the start for a node that is added with it.
	var shown := live()
	var right_cell := Rect2(64, 0, 64, 64)  # centre of cell 1_0
	store.set_excluded_rects([right_cell] as Array[Rect2])
	check(store.get_excluded_rects().size() == 1 and store.get_excluded_rects()[0] == right_cell, "get_excluded_rects returns the list")
	check(await settle(), "settled with 1_0 excluded")
	groups = live()
	var expected_excluded := shown.keys().filter(func(name: String) -> bool: return not name.ends_with("|(1, 0)"))
	check(sorted(groups.keys()) == sorted(expected_excluded) and expected_excluded.size() < shown.size(),
			"excluding 1_0 removes its groups and keeps the others (%s)" % [groups.keys()])
	for name in expected_excluded:
		check(groups[name] == shown[name], "%s is not touched by the exclusion" % name)
	store.set_excluded_rects([Rect2(0, 0, 128, 128)] as Array[Rect2])
	check(await settle(), "settled with far cell 0_0 excluded")
	groups = live()
	check(groups.keys() == [key("impostor", tree_path, Vector2i(5, 5))], "excluding far cell 0_0 leaves only the impostor of 5_5 (%s)" % [groups.keys()])
	store.update_streaming(CENTRE + Vector3(3, 0, 3))
	check(await settle() and sorted(live().keys()) == sorted(groups.keys()), "a move inside the exclusion loads nothing there")
	store.set_excluded_rects([] as Array[Rect2])
	check(await move(CENTRE), "settled with nothing excluded")
	check(sorted(live().keys()) == sorted(shown.keys()), "clearing the exclusion loads every group again")
	var excluded_store: Node3D = StoreScript.new()
	excluded_store.data_directory = data
	excluded_store.cell_size = CELL
	excluded_store.collider_distance = 50.0
	excluded_store.set_excluded_rects([right_cell] as Array[Rect2])
	root.add_child(excluded_store)
	var excluded_load: Dictionary = excluded_store.load_now(CENTRE)
	var excluded_cells := ids_of(excluded_store).keys().filter(func(name: String) -> bool: return name.ends_with("|(1, 0)"))
	check(excluded_load.ok and excluded_load.groups > 0 and excluded_cells.is_empty(), "a node added with an exclusion never loads there (%s)" % [excluded_cells])
	excluded_store.free()

	# Draw overrides: merged into the live groups' params and into groups created later, without
	# touching the object; impostor overrides reach the impostor groups only; clearing restores.
	groups = live()
	var grass_10 := key("draw", grass_path, Vector2i(1, 0))
	var tree_10 := key("draw", tree_path, Vector2i(1, 0))
	var impostor_00 := key("impostor", tree_path, Vector2i(0, 0))
	var grass_render: Resource = ObjectScript.resolve(grass_path).render
	var drawer: Object = store.get_drawer()
	store.set_draw_override(grass_path, {"extra_cull_margin": 3.0})
	check(drawer.get_group_info(groups[grass_10]).params.extra_cull_margin == 3.0, "a draw override reaches the live group")
	check(grass_render.extra_cull_margin == 0.0 and not store.get_stats().rebuild_scheduled, "a draw override leaves the object alone and builds nothing")
	check(store.get_draw_override(grass_path) == {"draw": {"extra_cull_margin": 3.0}, "impostor": {}}, "get_draw_override returns it")
	store.set_excluded_rects([right_cell] as Array[Rect2])
	check(await settle(), "settled with 1_0 excluded again")
	store.set_excluded_rects([] as Array[Rect2])
	check(await settle(), "settled with 1_0 back")
	groups = live()
	check(groups.has(grass_10) and drawer.get_group_info(groups[grass_10]).params.extra_cull_margin == 3.0, "a group created later takes the override")
	grass_render.visibility_range_end = 44.0
	var grass_now: Dictionary = drawer.get_group_info(groups[grass_10]).params
	check(grass_now.visibility_end == 44.0 and grass_now.extra_cull_margin == 3.0, "an object change keeps the override (%s, %s)" % [grass_now.visibility_end, grass_now.extra_cull_margin])
	grass_render.visibility_range_end = 45.0
	store.set_draw_override(tree_path, {}, {"extra_cull_margin": 4.0})
	check(drawer.get_group_info(groups[impostor_00]).params.extra_cull_margin == 4.0 and drawer.get_group_info(groups[tree_10]).params.extra_cull_margin == 0.0,
			"an impostor override reaches the impostor groups only")
	store.clear_draw_override(grass_path)
	store.clear_draw_override(tree_path)
	check(drawer.get_group_info(groups[grass_10]).params.extra_cull_margin == 0.0 and drawer.get_group_info(groups[impostor_00]).params.extra_cull_margin == 0.0,
			"clearing an override restores the object's params")
	check(store.get_draw_override(grass_path).is_empty() and store.get_stats().draw_overrides == 0, "no override is left")

	# Freeing a store with reads in flight: no crash, nothing left in the scenario.
	var other: Node3D = StoreScript.new()
	other.data_directory = data
	other.cell_size = CELL
	root.add_child(other)
	other.update_streaming(CENTRE)
	var in_flight: int = other.get_stats().loading + other.get_stats().directory_reads
	var drawer_ref: WeakRef = weakref(other.get_drawer())
	var other_id := other.get_instance_id()
	other.free()
	await process_frame
	check(drawer_ref.get_ref() == null, "a freed store drops its drawer (%d reads were in flight)" % in_flight)
	var leftover := 0
	for id in RenderingServer.instances_cull_aabb(AABB(Vector3(-1000, -100, -1000), Vector3(3000, 200, 3000)), store.get_world_3d().scenario):
		if id == other_id:
			leftover += 1
	check(leftover == 0, "a freed store leaves no instance (%d)" % leftover)

	# to_nodes names: objects sharing a file name in different folders get distinct, stable names
	# built from the path below the common directory.
	var twin_data := scratch.path_join("twin_data")
	var twin_paths := PackedStringArray()
	for folder in ["a", "b"]:
		DirAccess.make_dir_recursive_absolute(scratch.path_join("twins/%s" % folder))
		var twin := ObjectScript.new()
		twin.mesh = BoxMesh.new()
		var twin_path := scratch.path_join("twins/%s/fern_01.tres" % folder)
		check(ResourceSaver.save(twin, twin_path) == OK, "twin object %s saved" % folder)
		twin_paths.append(twin_path)
	ObjectScript.clear_cache()
	var twin_store: Node3D = StoreScript.new()
	twin_store.data_directory = twin_data
	twin_store.cell_size = CELL
	var twin_transforms := PackedFloat32Array()
	for origin in [Vector3(1, 0, 1), Vector3(2, 0, 2)]:
		twin_transforms.append_array(PackedFloat32Array([1, 0, 0, 0, 1, 0, 0, 0, 1, origin.x, origin.y, origin.z]))
	var twin_report: Dictionary = twin_store.write([], {"transform": twin_transforms, "object": PackedInt32Array([0, 1]), "object_paths": twin_paths})
	check(twin_report.ok, "twin write: %s" % twin_report.error)
	var twin_nodes: Node3D = twin_store.to_nodes(Rect2(0, 0, CELL, CELL))
	var twin_cell := twin_nodes.get_node_or_null("0_0")
	check(twin_cell != null and twin_cell.get_child_count() == 2, "twin cell has two nodes")
	check(twin_nodes.get_node_or_null("0_0/a_fern_01_0") is MultiMeshInstance3D and twin_nodes.get_node_or_null("0_0/b_fern_01_0") is MultiMeshInstance3D, "to_nodes names same-named objects <folder>_<name>_<batch>")
	twin_nodes.free()
	twin_store.free()

	# load_now: the same groups as streaming plus stepping, in one call, and nothing to do after.
	var reference := {"live": live(), "stats": store.get_stats()}
	var cold: Node3D = new_store(data)
	var cold_events := []
	cold.group_added.connect(func(info: Dictionary) -> void: cold_events.append("add"))
	cold.group_removed.connect(func(info: Dictionary) -> void: cold_events.append("remove"))
	var loaded: Dictionary = cold.load_now(CENTRE)
	check(loaded.ok and not loaded.timed_out and loaded.error == "", "load_now ok: %s" % [loaded])
	var cold_live := {}
	for info in cold.get_loaded_groups():
		cold_live["%s|%s|%s" % [info.kind, info.object_path, info.cell]] = true
	var expected_keys: Array = reference.live.keys()
	expected_keys.sort()
	var cold_keys: Array = cold_live.keys()
	cold_keys.sort()
	check(cold_keys == expected_keys, "load_now creates the groups streaming creates (%d vs %d)" % [cold_keys.size(), expected_keys.size()])
	var cold_stats: Dictionary = cold.get_stats()
	check(cold_stats.groups == reference.stats.groups and cold_stats.drawer.instances == reference.stats.drawer.instances and cold_stats.colliders.bodies == reference.stats.colliders.bodies,
			"load_now stats match streaming: %d groups, %d instances, %d bodies" % [cold_stats.groups, cold_stats.drawer.instances, cold_stats.colliders.bodies])
	check(loaded.groups == cold_stats.groups and loaded.instances == cold_stats.drawer.instances and loaded.bodies == cold_stats.colliders.bodies, "load_now returns the counts: %s" % [loaded])
	check(cold.is_settled() and cold_stats.pending == 0, "settled after load_now (pending %d)" % cold_stats.pending)
	var cold_tree: int = ids_of(cold).get(key("draw", tree_path, Vector2i(1, 0)), 0)
	var cold_link: Dictionary = cold.get_drawer().get_group_info(cold_tree).get("impostor_link", {})
	check(cold_tree != 0 and cold_link.get("impostor", 0) != 0, "load_now links the tree group to its impostor (%s)" % [cold_link])
	var ids_before := ids_of(cold)
	cold_events.clear()
	cold.update_streaming(CENTRE)
	check(await settle(cold), "settled after the update that follows load_now")
	await process_frame
	check(cold_events.is_empty() and ids_of(cold) == ids_before, "an update after load_now neither unloads nor reloads (%s)" % [cold_events])
	print("COPIA_STORE_TEST load_now: %d groups, %d instances, %d bodies in %.1f ms" % [loaded.groups, loaded.instances, loaded.bodies, loaded.usec / 1000.0])
	cold.free()

	# load_now when nothing is in range, hidden, outside the world, and with an expired timeout.
	var far_data := scratch.path_join("far_data")
	var far_store: Node3D = new_store(far_data)
	DirAccess.make_dir_recursive_absolute(far_data)
	check(far_store.write([], points_for([Vector2i(0, 0)], 100, false, false)).ok, "far store write")
	far_store.free()
	far_store = new_store(far_data)
	var far_result: Dictionary = far_store.load_now(Vector3(3000, 0, 3000))
	check(far_result.ok and far_result.groups == 0 and far_result.instances == 0, "load_now far from any cell: ok, no groups (%s)" % [far_result])
	far_result = far_store.load_now(CENTRE)
	check(far_result.ok and far_result.groups == 1 and far_result.instances > 0, "load_now at the cell loads its one group (%s)" % [far_result])
	far_store.free()
	var hidden_store: Node3D = new_store(data)
	hidden_store.visible = false
	var hidden_result: Dictionary = hidden_store.load_now(CENTRE)
	check(not hidden_result.ok and not hidden_result.error.is_empty() and hidden_result.groups == 0 and hidden_store.get_stats().groups == 0 and hidden_store.get_stats().pending == 0, "a hidden node load_now fails and creates nothing (%s)" % [hidden_result])
	hidden_store.free()
	var detached: Node3D = StoreScript.new()
	detached.data_directory = data
	var detached_result: Dictionary = detached.load_now(CENTRE)
	check(not detached_result.ok and not detached_result.error.is_empty() and detached.is_settled(), "a node outside the world load_now fails (%s)" % [detached_result])
	detached.free()
	var slow_store: Node3D = new_store(data)
	var slow_result: Dictionary = slow_store.load_now(CENTRE, 0.0)
	check(slow_result.timed_out and not slow_result.ok, "load_now reports timed_out with no time (%s)" % [slow_result])
	check(await settle(slow_store), "a timed-out load_now finishes in later frames")
	check(slow_store.get_stats().groups == reference.stats.groups, "the timed-out load_now completed by streaming (%d groups)" % slow_store.get_stats().groups)
	slow_store.free()

	# streaming_settled: once per load, again after a move that loads more.
	var settled_store: Node3D = new_store(data)
	var settled_count := [0]
	settled_store.streaming_settled.connect(func() -> void: settled_count[0] += 1)
	check(settled_store.is_settled(), "a new store is settled")
	settled_store.update_streaming(CENTRE)
	check(await settle(settled_store), "settled store streamed")
	for i in 10:
		await process_frame
	check(settled_count[0] == 1 and settled_store.is_settled(), "streaming_settled fired once for the first load (%d)" % settled_count[0])
	settled_store.update_streaming(Vector3(10 * CELL + 32, 0, 10 * CELL + 32))
	check(await settle(settled_store), "settled store streamed the far corner")
	for i in 10:
		await process_frame
	check(settled_count[0] == 2 and settled_store.is_settled(), "streaming_settled fired again after the move (%d)" % settled_count[0])
	settled_store.free()

	store.free()
	ObjectScript.clear_cache()
	PhysicsScript.clear_cache()
	remove_tree(scratch)
	if failures.is_empty():
		print("COPIA_STORE_TEST PASS (%d ms)" % (Time.get_ticks_msec() - started))
		quit(0)
	else:
		print("COPIA_STORE_TEST FAIL (%d failures)" % failures.size())
		for failure in failures:
			print("  " + failure)
		quit(1)
