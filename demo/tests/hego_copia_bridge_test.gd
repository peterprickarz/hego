## HEGo Copia bridge contracts, without Houdini: write_attributes turns point attribute arrays as
## HEGo delivers them (plain Arrays, null where a point has no value) into store points (spawn;
## clear and spawn in one call replace; spawn alone adds; a clear point empties only its set and
## cell; extra attributes pass through), find_store resolves the store by node path, blank (the
## only store; none or several is an error and writes nothing) and not-a-store, build_points
## gives consistent lengths and types, no store entry (the HDA names its store itself), an empty
## cloud for an empty store, the right cell rows, cell rows fed back as clear points
## clear those cells, and the instance rows of points_of_sets round-trip into a second store
## with equal transforms, sets, objects, keep, colour, custom data and extra columns. The
## handlers' discovery and their calls into HEGoPointOutput and HEGoInputNode need Houdini and
## are not covered, but split_routes and write_routes, which the output handler hands its
## columns to, are: the split groups rows by store (null and blank are the blank route, columns
## keep their type, one store passes the columns on uncopied), a blank route and the store's own
## path are written in one call (clear first), the cook option extra_attributes reaches the
## store, and a blank route with two stores writes nothing.
## Scratch data goes under user:// and is deleted afterwards.
##
##   godot-4.7.2 --path demo --headless --script res://tests/hego_copia_bridge_test.gd
##
## Prints HEGO_COPIA_BRIDGE_TEST PASS or FAIL and exits 0 or 1. Run time: about 2 s.
extends SceneTree

const EXTENSION := "res://addons/copia/bin/copia.gdextension"
const OutputScript := preload("res://addons/hego_copia/hego_copia_output.gd")
const InputScript := preload("res://addons/hego_copia/hego_copia_input.gd")
const StoreScript := preload("res://addons/copia/copia_store_3d.gd")
const ObjectScript := preload("res://addons/copia/copia_object.gd")
const ALL := Rect2(-100000, -100000, 200000, 200000)
const EPSILON := 1e-4

var failures: Array[String] = []
var scratch := "user://hego_copia_bridge_test_%d" % OS.get_process_id()
var scene: Node3D
var host: Node3D
var store_a: Node3D
var store_b: Node3D
var tree_path := ""
var rock_path := ""
var mesh_path := ""


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


func make_store(store_name: String, parent: Node) -> Node3D:
	var store: Node3D = StoreScript.new()
	store.name = store_name
	store.data_directory = scratch.path_join("data_" + store_name)
	store.cell_size = 64.0
	store.visible = false  # nothing streams in this test
	parent.add_child(store)
	store.owner = scene
	return store


func make_objects() -> void:
	DirAccess.make_dir_recursive_absolute(scratch.path_join("objects"))
	tree_path = scratch.path_join("objects/tree.tres")
	rock_path = scratch.path_join("objects/rock.tres")
	mesh_path = scratch.path_join("objects/plain_mesh.tres")
	for path in [tree_path, rock_path]:
		var object := ObjectScript.new()
		object.mesh = BoxMesh.new()
		check(ResourceSaver.save(object, path) == OK, "object saved: " + path)
	check(ResourceSaver.save(BoxMesh.new(), mesh_path) == OK, "mesh saved")
	ObjectScript.clear_cache()


## Attribute arrays from rows ({name: value}), as HEGo delivers them: plain Arrays with null
## where a row has no value.
func attributes_of(rows: Array) -> Dictionary:
	var names := {}
	for row: Dictionary in rows:
		for name in row:
			names[name] = true
	var result := {}
	for name in names:
		var column := []
		for row: Dictionary in rows:
			column.append(row.get(name))
		result[name] = column
	return result


## Every point of a store as {origin, basis, set, object, keep, color, custom, extra}, ordered by origin.
func points_of(store: Node, set_name := "") -> Array:
	var read: Dictionary = store.read_points(ALL, PackedStringArray([set_name]) if not set_name.is_empty() else PackedStringArray())
	var transform: PackedFloat32Array = read.transform
	var set_index: PackedInt32Array = read["set"]
	var objects: PackedInt32Array = read["object"]
	var colors: PackedFloat32Array = read.get("color", PackedFloat32Array())
	var customs: PackedFloat32Array = read.get("custom", PackedFloat32Array())
	var keeps: PackedFloat32Array = read.get("keep", PackedFloat32Array())
	var result := []
	for i in int(read["count"]):
		var k := i * 12
		var extra := {}
		for name in read.get("extra", {}):
			var column = read.extra[name]
			# Three-wide float columns come back flat.
			extra[name] = Vector3(column[i * 3], column[i * 3 + 1], column[i * 3 + 2]) if column is PackedFloat32Array and column.size() == int(read["count"]) * 3 else column[i]
		result.append({
			"origin": Vector3(transform[k + 9], transform[k + 10], transform[k + 11]),
			"basis": Basis(Vector3(transform[k], transform[k + 1], transform[k + 2]), Vector3(transform[k + 3], transform[k + 4], transform[k + 5]), Vector3(transform[k + 6], transform[k + 7], transform[k + 8])),
			"set": read.set_names[set_index[i]], "object": read.object_paths[objects[i]],
			"keep": keeps[i] if keeps.size() > i else 1.0,
			"color": Vector4(colors[i * 4], colors[i * 4 + 1], colors[i * 4 + 2], colors[i * 4 + 3]) if colors.size() > i * 4 else Vector4(NAN, NAN, NAN, NAN),
			"custom": Vector4(customs[i * 4], customs[i * 4 + 1], customs[i * 4 + 2], customs[i * 4 + 3]) if customs.size() > i * 4 else Vector4(NAN, NAN, NAN, NAN),
			"extra": extra,
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.origin.x < b.origin.x or (a.origin.x == b.origin.x and a.origin.z < b.origin.z))
	return result


func count_of(store: Node, set_name: String, cell: String) -> int:
	var rows: Dictionary = store.cell_points(Rect2(), PackedStringArray([set_name]))
	for i in rows.cell.size():
		if rows.cell[i] == cell:
			return rows["count"][i]
	return 0


func same_basis(a: Basis, b: Basis) -> bool:
	for c in 3:
		if (a[c] - b[c]).length() > EPSILON * maxf(1.0, b[c].length()):
			return false
	return true


func same_vector4(a: Vector4, b: Vector4) -> bool:
	for c in 4:
		if is_nan(a[c]) != is_nan(b[c]) or (not is_nan(a[c]) and absf(a[c] - b[c]) > EPSILON):
			return false
	return true


func at_origin(points: Array, origin: Vector3) -> Dictionary:
	for point: Dictionary in points:
		if (point.origin - origin).length() < 0.01:
			return point
	return {}


func run() -> void:
	var started := Time.get_ticks_msec()
	if not ClassDB.class_exists("CopiaPoints"):
		GDExtensionManager.load_extension(EXTENSION)
	if not ClassDB.class_exists("CopiaPoints"):
		push_error("Copia is not available")
		quit(1)
		return
	remove_tree(scratch)
	make_objects()
	scene = Node3D.new()
	scene.name = "Scene"
	root.add_child(scene)
	host = Node3D.new()
	host.name = "Host"
	scene.add_child(host)
	host.owner = scene
	store_a = make_store("StoreA", scene)

	test_discovery_surface()

	# Blank store with one store in the scene.
	check(OutputScript.find_store(host, "") == store_a, "a blank store path finds the only store")
	check(OutputScript.find_store(host, "StoreA") == store_a, "the node path finds the store")
	check(OutputScript.find_store(host, "Missing") == null, "a path to nothing finds no store")
	check(OutputScript.find_store(host, "Host") == null, "a path to a node that is not a store finds none")
	check(OutputScript.find_store(host, "/root/Scene/StoreA") == store_a, "an absolute path finds the store")
	var ownerless := Node3D.new()
	root.add_child(ownerless)
	check(OutputScript.scene_root(ownerless) == ownerless, "a host without an owner is its own scene root")
	ownerless.free()

	test_spawn_clear()
	test_write_routes()
	test_routing_and_blank()
	test_extra_attributes()
	test_build_points()
	test_round_trip()

	remove_tree(scratch)
	var elapsed := Time.get_ticks_msec() - started
	if failures.is_empty():
		print("HEGO_COPIA_BRIDGE_TEST PASS (%d ms)" % elapsed)
		quit(0)
	else:
		print("HEGO_COPIA_BRIDGE_TEST FAIL: %d failures" % failures.size())
		for failure in failures:
			print("  - " + failure)
		quit(1)


func test_discovery_surface() -> void:
	var output: RefCounted = OutputScript.new()
	check(output.should_handle({}), "an unknown output summary runs the output handler")
	check(output.should_handle({"point_attributes": PackedStringArray(["P", "hegocopia_object"])}), "hegocopia_object selects the output handler")
	check(output.should_handle({"point_attributes": PackedStringArray(["P", "hegocopia_clear"])}), "hegocopia_clear selects the output handler")
	check(not output.should_handle({"point_attributes": PackedStringArray(["P", "Cd"])}), "other points do not select the output handler")
	var input: RefCounted = InputScript.new()
	check(input.handles(store_a), "the input handler takes a CopiaStore3D")
	check(not input.handles(host), "the input handler does not take another node")
	check(input.claims_settings({"copia_input": true}) and not input.claims_settings({"terrain_input": true}), "the input handler claims its own settings")
	check(input.requires_strict_cook({"copia_input": true}), "a Copia input makes its cook strict")


func test_spawn_clear() -> void:
	var half_turn_y := Quaternion(Vector3.UP, PI / 2.0)
	var rows := [
		{"P": Vector3(10, 0, 10), "orient": Vector4(half_turn_y.x, half_turn_y.y, half_turn_y.z, half_turn_y.w), "hegocopia_object": tree_path, "hegocopia_set": "trees",
			"Cd": Vector3(0.25, 0.5, 0.75), "hegocopia_custom": Vector4(1, 2, 3, 4), "hegocopia_keep": 0.5},
		{"P": Vector3(20, 0, 20), "N": Vector3(1, 0, 0), "up": Vector3(0, 1, 0), "scale": Vector3(2, 1, 1), "pscale": 3.0, "hegocopia_object": tree_path, "hegocopia_set": "trees"},
		{"P": Vector3(30, 0, 30), "pscale": 2.0, "hegocopia_object": mesh_path},
		{"P": Vector3(70, 0, 10), "hegocopia_object": rock_path, "hegocopia_set": "trees"},
		{"P": Vector3(-10, 0, 10), "hegocopia_object": rock_path, "hegocopia_set": ""},
	]
	var report: Dictionary = OutputScript.write_attributes(attributes_of(rows), store_a)
	check(report.ok and report.point_count == 5 and report.clear_count == 0 and report.skipped_count == 0, "spawn: %s" % [report])
	check(report.write.get("ok", false), "spawn: the store write succeeded")
	var all := points_of(store_a)
	check(all.size() == 5, "spawn: five points are in the store (%d)" % all.size())
	var first := at_origin(all, Vector3(10, 0, 10))
	check(not first.is_empty() and first.set == "trees" and first.object == tree_path and same_basis(first.basis, Basis(half_turn_y)), "spawn: orient gives the basis, set and object")
	check(not first.is_empty() and same_vector4(first.color, Vector4(0.25, 0.5, 0.75, 1.0)) and same_vector4(first.custom, Vector4(1, 2, 3, 4)) and absf(first.keep - 0.5) < EPSILON, "spawn: colour, custom data and keep are stored")
	var second := at_origin(all, Vector3(20, 0, 20))
	check(not second.is_empty() and same_basis(second.basis, Basis(Vector3(0, 0, -6), Vector3(0, 3, 0), Vector3(3, 0, 0))), "spawn: N and up with scale and pscale give the basis (%s)" % [second.get("basis")])
	check(not second.is_empty() and same_vector4(second.color, Vector4(NAN, NAN, NAN, NAN)) and absf(second.keep - 1.0) < EPSILON, "spawn: a point without colour keeps the object's default")
	var third := at_origin(all, Vector3(30, 0, 30))
	check(not third.is_empty() and third.set == "default" and third.object == mesh_path and same_basis(third.basis, Basis.from_scale(Vector3(2, 2, 2))), "spawn: no set is default, a Mesh path is accepted, pscale scales")
	check(at_origin(all, Vector3(-10, 0, 10)).get("set") == "default", "spawn: a blank set is default")
	check(count_of(store_a, "trees", "0_0") == 2 and count_of(store_a, "trees", "1_0") == 1 and count_of(store_a, "default", "0_0") == 1 and count_of(store_a, "default", "-1_0") == 1, "spawn: the points are in their cells and sets")

	# Spawning without a clear adds.
	var added: Dictionary = OutputScript.write_attributes(attributes_of([
		{"P": Vector3(40, 0, 40), "hegocopia_object": tree_path, "hegocopia_set": "trees"},
		{"P": Vector3(41, 0, 41), "hegocopia_object": tree_path, "hegocopia_set": "trees"}]), store_a)
	check(added.ok and count_of(store_a, "trees", "0_0") == 4, "spawn without a clear adds to the set (%d)" % count_of(store_a, "trees", "0_0"))

	# Clear and spawn in one call: the clear is applied first, so the new points replace the old.
	var replaced: Dictionary = OutputScript.write_attributes(attributes_of([
		{"P": Vector3(32, 0, 32), "hegocopia_clear": 1, "hegocopia_set": "trees", "hegocopia_cell": "0_0"},
		{"P": Vector3(5, 0, 5), "hegocopia_object": tree_path, "hegocopia_set": "trees"},
		{"P": Vector3(6, 0, 6), "hegocopia_object": tree_path, "hegocopia_set": "trees"}]), store_a)
	check(replaced.ok and replaced.clear_count == 1 and replaced.point_count == 2, "clear and spawn: %s" % [replaced])
	var trees := points_of(store_a, "trees")
	check(count_of(store_a, "trees", "0_0") == 2 and at_origin(trees, Vector3(5, 0, 5)).size() > 0 and at_origin(trees, Vector3(10, 0, 10)).is_empty(), "clear and spawn: the cell holds only the new points")
	check(count_of(store_a, "trees", "1_0") == 1 and count_of(store_a, "default", "0_0") == 1 and count_of(store_a, "default", "-1_0") == 1, "clear and spawn: other cells and sets are untouched")

	# A clear point alone empties its set in its cell and nothing else.
	var cleared: Dictionary = OutputScript.write_attributes(attributes_of([
		{"hegocopia_clear": 1, "hegocopia_set": "default", "hegocopia_cell": "-1_0"}]), store_a)
	check(cleared.ok and cleared.clear_count == 1 and cleared.point_count == 0, "clear: %s" % [cleared])
	check(count_of(store_a, "default", "-1_0") == 0 and count_of(store_a, "default", "0_0") == 1 and count_of(store_a, "trees", "0_0") == 2 and count_of(store_a, "trees", "1_0") == 1, "clear: only that set in that cell is empty")

	# A point that is neither an instance nor a clear is skipped and reported.
	var skipped: Dictionary = OutputScript.write_attributes(attributes_of([
		{"P": Vector3(1, 0, 1)}, {"P": Vector3(2, 0, 2), "hegocopia_object": tree_path, "hegocopia_set": "trees"}]), store_a)
	check(skipped.ok and skipped.point_count == 1 and skipped.skipped_count == 1, "a point with no object is skipped and counted: %s" % [skipped])
	# A bad set name rejects the call and writes nothing.
	var before := points_of(store_a).size()
	var rejected: Dictionary = OutputScript.write_attributes(attributes_of([
		{"P": Vector3(3, 0, 3), "hegocopia_object": tree_path, "hegocopia_set": "Not A Set"}]), store_a)
	check(points_of(store_a).size() == before and rejected.point_count == 0, "an invalid set name writes nothing: %s" % [rejected])
	# Packed arrays work as well as plain Arrays.
	var packed: Dictionary = OutputScript.write_attributes({"P": PackedVector3Array([Vector3(50, 0, 50)]), "hegocopia_object": PackedStringArray([rock_path]), "hegocopia_set": PackedStringArray(["packed"])}, store_a)
	check(packed.ok and count_of(store_a, "packed", "0_0") == 1, "packed arrays are accepted")
	check(not OutputScript.write_attributes({"Cd": []}, store_a).ok, "points with no P, object or clear are an error")
	check(not OutputScript.write_attributes(attributes_of([{"P": Vector3.ZERO}]), host).ok, "a node that is not a store is an error")


## write_routes, which the output handler calls with the points grouped by hegocopia_store.
func test_write_routes() -> void:
	OutputScript.write_attributes(attributes_of([
		{"P": Vector3(1, 0, 2), "hegocopia_object": tree_path, "hegocopia_set": "pattern"},
		{"P": Vector3(2, 0, 1), "hegocopia_object": tree_path, "hegocopia_set": "pattern"}]), store_a)
	check(count_of(store_a, "pattern", "0_0") == 2, "write_routes: the old points are there")
	# The documented clear pattern with one store: the spawned points name no store, the clear
	# points carry the store's path from the Copia input. Both mean StoreA, so they are written
	# in one call and the clear comes first, whatever order the routes arrive in.
	var report: Dictionary = OutputScript.write_routes(host, {
		"": attributes_of([
			{"P": Vector3(3, 0, 3), "hegocopia_object": tree_path, "hegocopia_set": "pattern", "tag": 3},
			{"P": Vector3(4, 0, 4), "hegocopia_object": tree_path, "hegocopia_set": "pattern", "tag": 4}]),
		"StoreA": attributes_of([{"P": Vector3(32, 0, 32), "hegocopia_clear": 1, "hegocopia_set": "pattern", "hegocopia_cell": "0_0"}]),
	}, {"extra_attributes": PackedStringArray(["tag"])})
	var pattern := points_of(store_a, "pattern")
	check(report.errors.is_empty() and report.stores.keys() == ["StoreA"] and report.point_count == 2 and report.clear_count == 1, "write_routes: a blank path and the store's path are one store and one write (%s)" % [report])
	check(pattern.size() == 2 and not at_origin(pattern, Vector3(3, 0, 3)).is_empty() and at_origin(pattern, Vector3(1, 0, 2)).is_empty(), "write_routes: the clear of one route applies before the spawn of the other (%d points)" % pattern.size())
	check(at_origin(pattern, Vector3(3, 0, 3)).get("extra", {}).get("tag") == 3, "write_routes: the cook option extra_attributes stores the pass-through column")
	# Columns only one side has stay aligned.
	var merged := {}
	OutputScript.merge_points(merged, {"P": [Vector3(1, 0, 0)], "Cd": [Vector3(1, 1, 1)]})
	OutputScript.merge_points(merged, {"P": PackedVector3Array([Vector3(2, 0, 0)]), "tag": [5]})
	check(merged.P.size() == 2 and merged.Cd.size() == 2 and merged.Cd[1] == null and merged.tag.size() == 2 and merged.tag[0] == null and merged.tag[1] == 5, "merge_points: missing columns are padded with null (%s)" % [merged])
	# No instance and no clear point (a cook with count 0 and clearing off) writes nothing.
	var held := points_of(store_a).size()
	var sets_before: PackedStringArray = store_a.list_sets()
	for routes: Dictionary in [{}, {"": {}}, {"": attributes_of([{"P": Vector3(5, 0, 5)}])},
			{"": {"P": [], "hegocopia_object": [], "hegocopia_set": [], "hegocopia_clear": []}}]:
		var nothing: Dictionary = OutputScript.write_routes(host, routes)
		var written: Dictionary = nothing.stores.get("StoreA", {}).get("write", {})
		check(nothing.errors.is_empty() and nothing.point_count == 0 and nothing.clear_count == 0 and written.is_empty()
			and points_of(store_a).size() == held and store_a.list_sets() == sets_before, "write_routes: no instance and no clear writes nothing (%s -> %s)" % [routes.keys(), nothing])
	store_a.remove_set("pattern")


func test_routing_and_blank() -> void:
	var group := Node3D.new()
	group.name = "Group"
	scene.add_child(group)
	group.owner = scene
	store_b = make_store("StoreB", group)
	check(OutputScript.find_store(host, "Group/StoreB") == store_b and OutputScript.find_store(host, "StoreA") == store_a, "two stores are found by their node paths")
	var lookup := OutputScript.resolve_store(host, "")
	check(lookup.store == null and not lookup.error.is_empty() and "2" in lookup.error, "a blank path with two stores is an error: " + lookup.error)
	var none := OutputScript.resolve_store(host, "Nope/Nothing")
	check(none.store == null and not none.error.is_empty(), "an unknown path says why: " + none.error)

	# Route a batch of points by hegocopia_store with the handler's own split and write.
	var rows := [
		{"P": Vector3(1, 0, 1), "hegocopia_object": tree_path, "hegocopia_set": "trees", "hegocopia_store": "StoreA"},
		{"P": Vector3(2, 0, 2), "hegocopia_object": tree_path, "hegocopia_set": "routed", "hegocopia_store": "Group/StoreB"},
		{"P": Vector3(3, 0, 3), "hegocopia_object": rock_path, "hegocopia_set": "routed", "hegocopia_store": "Group/StoreB"},
		{"P": Vector3(4, 0, 4), "hegocopia_object": rock_path, "hegocopia_set": "routed", "hegocopia_store": "StoreA"},
	]
	var a_before := points_of(store_a).size()
	var columns := attributes_of(rows)
	columns["tag"] = PackedInt32Array([1, 2, 3, 4])
	var routes := OutputScript.split_routes(columns)
	check(routes.keys() == ["StoreA", "Group/StoreB"] and routes.StoreA.P == [Vector3(1, 0, 1), Vector3(4, 0, 4)] and routes.StoreA.tag == PackedInt32Array([1, 4])
		and routes["Group/StoreB"].hegocopia_object == [tree_path, rock_path] and routes["Group/StoreB"].tag is PackedInt32Array,
		"split_routes: rows grouped by store in order of first appearance, each column in its own type (%s)" % [routes])
	var written := OutputScript.write_routes(host, routes)
	check(written.errors.is_empty() and points_of(store_b).size() == 2 and points_of(store_a).size() == a_before + 2, "points go to the store they name (A +2: %d, B: %d)" % [points_of(store_a).size() - a_before, points_of(store_b).size()])
	check(count_of(store_b, "routed", "0_0") == 2 and count_of(store_a, "routed", "0_0") == 1, "routed sets are in the right stores")
	# One store for every point: the columns go on as they are. No store, or null, is the blank route.
	var same := {"P": [Vector3.ZERO, Vector3.ONE], "hegocopia_store": ["StoreA", "StoreA"]}
	var one := OutputScript.split_routes(same)
	check(one.keys() == ["StoreA"] and is_same(one.StoreA, same), "split_routes: one store passes the columns on without a copy")
	var blanks := OutputScript.split_routes({"P": [Vector3.ZERO, Vector3.ONE, Vector3.UP], "hegocopia_store": [null, "", "StoreA"]})
	check(blanks.keys() == ["", "StoreA"] and blanks[""].P.size() == 2 and OutputScript.split_routes({"P": [Vector3.ZERO]}).keys() == [""],
		"split_routes: null, blank and a missing store column are the blank route (%s)" % [blanks.keys()])

	# Blank with two stores writes nothing: no store is found, and a null store is an error.
	var a_count := points_of(store_a).size()
	var b_count := points_of(store_b).size()
	var blank := OutputScript.find_store(host, "")
	var refused: Dictionary = OutputScript.write_attributes(attributes_of([{"P": Vector3(9, 0, 9), "hegocopia_object": tree_path}]), blank)
	check(blank == null and not refused.ok and points_of(store_a).size() == a_count and points_of(store_b).size() == b_count, "a blank store with two stores writes nothing")

	# The handler's own path: write_routes with a blank route and two stores is an error and writes nothing.
	var routed: Dictionary = OutputScript.write_routes(host, {"": attributes_of([{"P": Vector3(9, 0, 9), "hegocopia_object": tree_path}]),
		"Group/StoreB": attributes_of([{"P": Vector3(8, 0, 8), "hegocopia_object": tree_path, "hegocopia_set": "routed"}])})
	check(routed.stores.keys() == ["Group/StoreB"] and routed.errors.size() == 1 and "2 CopiaStore3D" in str(routed.errors) and points_of(store_a).size() == a_count and points_of(store_b).size() == b_count + 1,
		"write_routes: the blank route is an error and writes nothing, the named one is written (%s)" % [routed])


func test_extra_attributes() -> void:
	var rows := [
		{"P": Vector3(11, 0, 11), "hegocopia_object": tree_path, "hegocopia_set": "extras", "tag": 7, "radius": 1.5, "dir": Vector3(1, 2, 3)},
		{"P": Vector3(12, 0, 12), "hegocopia_object": tree_path, "hegocopia_set": "extras", "tag": 9, "radius": 2.5, "dir": Vector3(4, 5, 6)},
	]
	var report: Dictionary = OutputScript.write_attributes(attributes_of(rows), store_a, {"extra": PackedStringArray(["tag", "radius", "dir", "absent"])})
	check(report.ok, "extra attributes: %s" % [report])
	var points := points_of(store_a, "extras")
	var one := at_origin(points, Vector3(11, 0, 11))
	var two := at_origin(points, Vector3(12, 0, 12))
	check(not one.is_empty() and one.extra.get("tag") == 7 and absf(one.extra.get("radius", 0.0) - 1.5) < EPSILON and one.extra.get("dir") == Vector3(1, 2, 3), "extra attributes pass through (%s)" % [one.get("extra")])
	check(not two.is_empty() and two.extra.get("tag") == 9 and two.extra.get("dir") == Vector3(4, 5, 6), "extra attributes keep their rows")
	var plain: Dictionary = OutputScript.write_attributes(attributes_of([{"P": Vector3(13, 0, 13), "hegocopia_object": tree_path, "hegocopia_set": "unlisted", "tag": 1}]), store_a)
	check(plain.ok and points_of(store_a, "unlisted").size() == 1 and points_of(store_a, "unlisted")[0].extra.is_empty(), "an attribute that is not listed is not stored")


func test_build_points() -> void:
	var cells: Dictionary = store_a.cell_points()
	var expected_rows: int = cells.cell.size()
	check(expected_rows > 3, "the store has several cell rows to send (%d)" % expected_rows)
	var built := InputScript.build_points(store_a, {})
	check(built.error.is_empty() and built.cell_count == expected_rows and built.instance_count == 0 and built.P.size() == expected_rows, "build_points: one point per cell and set (%s)" % [built.error])
	var types_ok := true
	var lengths_ok := true
	var names := []
	for attribute: Dictionary in built.attributes:
		names.append(attribute.name)
		if attribute.name == "_hego_node_path":
			continue
		var values: Variant = attribute.values
		types_ok = types_ok and (values is PackedInt32Array or values is PackedFloat32Array or values is PackedVector3Array or values is PackedStringArray) and attribute.type == "point"
		lengths_ok = lengths_ok and values.size() == built.P.size()
	check(types_ok, "build_points: every point attribute is an int, float, vector3 or string array")
	check(lengths_ok, "build_points: every point attribute has one value per point")
	check(not names.has("hegocopia_store") and built.attributes.all(func(a: Dictionary) -> bool: return a.type == "point"), "build_points: every attribute is on points and none names the store")
	for name in ["_hego_node_path", "hegocopia_cell", "hegocopia_set", "hegocopia_count", "hegocopia_cell_min", "hegocopia_cell_max", "hegocopia_cell_point", "hegocopia_object", "N", "up", "scale", "hegocopia_keep"]:
		check(names.has(name), "build_points: attribute %s is sent" % name)
	var column := func(name: String) -> Variant:
		for attribute: Dictionary in built.attributes:
			if attribute.name == name:
				return attribute.get("values", attribute.get("value"))
		return null
	check(column.call("hegocopia_cell") == cells.cell and column.call("hegocopia_set") == cells.set and column.call("hegocopia_count") == cells["count"], "build_points: the cell rows are the store's cell rows")
	check(built.P == cells.P and column.call("hegocopia_cell_min") == cells.cell_min and column.call("hegocopia_cell_max") == cells.cell_max, "build_points: P is the cell centre, with the cell bounds")
	var markers: PackedInt32Array = column.call("hegocopia_cell_point")
	check(markers.count(1) == expected_rows, "build_points: every row is a cell point")
	check(column.call("_hego_node_path") == "StoreA", "build_points: _hego_node_path names the store")

	# Limits: sets, exclude_sets and rect.
	var only_trees := InputScript.build_points(store_a, {"sets": ["trees"]})
	var tree_rows: Dictionary = store_a.cell_points(Rect2(), PackedStringArray(["trees"]))
	check(only_trees.P.size() == tree_rows.cell.size() and tree_rows.cell.size() > 0 and tree_rows.set.count("trees") == tree_rows.set.size(), "build_points: sets limits the cell rows")
	var without_trees := InputScript.build_points(store_a, {"exclude_sets": ["trees"]})
	check(without_trees.P.size() == expected_rows - tree_rows.cell.size(), "build_points: exclude_sets leaves those sets out")
	var in_rect := InputScript.build_points(store_a, {"rect": [0, 0, 64, 64]})
	var rect_rows: Dictionary = store_a.cell_points(Rect2(0, 0, 64, 64))
	check(in_rect.P.size() == rect_rows.cell.size() and rect_rows.cell.size() > 0 and rect_rows.cell.size() < expected_rows and rect_rows.cell.count("0_0") == rect_rows.cell.size(), "build_points: rect limits the cells")
	check(not InputScript.build_points(store_a, {"rect": [0, 0, 64]}).error.is_empty() and not InputScript.build_points(store_a, {"rect": [10, 0, 5, 64]}).error.is_empty(), "build_points: an invalid rect is an error")
	check(not InputScript.build_points(host, {}).error.is_empty(), "build_points: a node that is not a store is an error")
	var empty_store := make_store("Empty", scene)
	var nothing := InputScript.build_points(empty_store, {})
	check(nothing.error.is_empty() and nothing.P.is_empty() and nothing.attributes.is_empty(), "build_points: an empty store sends an empty cloud, no points and no attributes")
	empty_store.free()

	# The cell rows, fed back as clear points, clear those cells and nothing else.
	var trees_before := points_of(store_a, "trees").size()
	var other_before := points_of(store_a).size() - trees_before
	check(trees_before > 0 and other_before > 0, "the store has trees and other sets before clearing")
	var cell_rows: int = only_trees.cell_count
	var fed := {"P": [], "hegocopia_clear": [], "hegocopia_set": [], "hegocopia_cell": []}
	for attribute: Dictionary in only_trees.attributes:
		if fed.has(attribute.name) and attribute.has("values"):
			fed[attribute.name] = Array(attribute.values)
	fed["P"] = Array(only_trees.P)
	var ones := []
	ones.resize(cell_rows)
	ones.fill(1)
	fed["hegocopia_clear"] = ones
	var clear_report: Dictionary = OutputScript.write_attributes(fed, store_a)
	check(clear_report.ok and clear_report.clear_count == cell_rows and clear_report.point_count == 0, "cell rows as clear points: %s" % [clear_report])
	check(points_of(store_a, "trees").is_empty() and points_of(store_a).size() == other_before, "the cleared cells are empty and no other set changed")


func test_round_trip() -> void:
	var rows := [
		{"P": Vector3(10, 1, 10), "orient": Vector4(0, 0.7071068, 0, 0.7071068), "scale": Vector3(1, 2, 3), "hegocopia_object": tree_path, "hegocopia_set": "trees", "Cd": Vector3(0.1, 0.2, 0.3), "hegocopia_custom": Vector4(1, 2, 3, 0.5), "hegocopia_keep": 0.25, "tag": 5},
		{"P": Vector3(80, 2, 20), "N": Vector3(0, 0, 1), "up": Vector3(0.2, 1, 0), "pscale": 1.5, "hegocopia_object": rock_path, "hegocopia_set": "trees", "Cd": Vector3(0.9, 0.8, 0.7), "hegocopia_custom": Vector4(4, 3, 2, 1), "hegocopia_keep": 0.75, "tag": 6},
		{"P": Vector3(-30, 0, 100), "hegocopia_object": tree_path, "hegocopia_set": "trees", "hegocopia_keep": 1.0, "tag": 7},
		{"P": Vector3(15, 0, 15), "hegocopia_object": rock_path, "hegocopia_set": "ground", "tag": 8},
	]
	var source := make_store("Source", scene)
	var options := {"extra": PackedStringArray(["tag"])}
	check(OutputScript.write_attributes(attributes_of(rows), source, options).ok, "round trip: the source store is written")
	var built := InputScript.build_points(source, {"points_of_sets": ["trees"]})
	check(built.error.is_empty() and built.instance_count == 3 and built.cell_count == 3 + 1, "points_of_sets: the instance rows of the set are sent after the cell rows (%s)" % [built.error])
	var lengths_ok := true
	var by_name := {}
	for attribute: Dictionary in built.attributes:
		if attribute.has("values"):
			lengths_ok = lengths_ok and attribute.values.size() == built.P.size() and attribute.type == "point"
			by_name[attribute.name] = attribute.values
	check(lengths_ok and by_name.size() > 10 and not by_name.has("hegocopia_store"), "points_of_sets: every attribute has one value per combined point, and none names the store")
	for name in ["Cd", "hegocopia_custom", "hegocopia_custom_w", "tag"]:
		check(by_name.has(name), "points_of_sets: %s is sent when the points have it" % name)
	var markers: PackedInt32Array = by_name["hegocopia_cell_point"]
	check(markers.slice(0, built.cell_count).count(1) == built.cell_count and markers.slice(built.cell_count).count(0) == built.instance_count, "points_of_sets: cell points first, then instance points")
	check((by_name["hegocopia_object"] as PackedStringArray).slice(0, built.cell_count).count("") == built.cell_count and (by_name["hegocopia_count"] as PackedInt32Array).slice(built.cell_count).count(0) == built.instance_count, "points_of_sets: the other kind's rows are zero or empty")
	check(InputScript.build_points(source, {"points_of_sets": ["trees"], "rect": [0, 0, 64, 64]}).instance_count == 1, "points_of_sets: rect limits the instance points")

	# Feed the instance rows into a second store, as plain Arrays.
	var cell_rows: int = built.cell_count
	var attributes := {"P": Array(built.P.slice(cell_rows))}
	for name in by_name:
		if name in ["hegocopia_object", "hegocopia_set", "hegocopia_keep", "Cd", "hegocopia_custom", "hegocopia_custom_w", "tag", "N", "up", "scale"]:
			attributes[name] = Array(by_name[name].slice(cell_rows))
	var target := make_store("Target", scene)
	var back: Dictionary = OutputScript.write_attributes(attributes, target, options)
	check(back.ok and back.point_count == 3, "round trip: the instance rows write into the second store: %s" % [back])
	var wanted := points_of(source, "trees")
	var got := points_of(target)
	check(got.size() == wanted.size() and wanted.size() == 3, "round trip: the same number of points (%d)" % got.size())
	for point: Dictionary in wanted:
		var other := at_origin(got, point.origin)
		check(not other.is_empty() and same_basis(other.basis, point.basis), "round trip: the transform at %s is equal" % point.origin)
		if other.is_empty():
			continue
		check(other.set == point.set and other.object == point.object and absf(other.keep - point.keep) < EPSILON, "round trip: set, object and keep at %s are equal" % point.origin)
		check(same_vector4(other.color, point.color) and same_vector4(other.custom, point.custom) and other.extra.get("tag") == point.extra.get("tag"), "round trip: colour, custom data and tag at %s are equal" % point.origin)
