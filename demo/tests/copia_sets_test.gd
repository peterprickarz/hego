## Copia set files: round trip, canonical order, clears, unchanged writes, cell placement and
## rejection of invalid input. Headless, no Houdini; uses a scratch directory under user://.
##
##   godot-4.7.2 --path demo --headless --script res://tests/copia_sets_test.gd
##
## Prints COPIA_SETS_TEST PASS or FAIL and exits 0 or 1. Run time: about 2 s (1.96 s measured).
extends SceneTree

const EXTENSION := "res://addons/copia/bin/copia.gdextension"
const CELL := 64.0
const ALL := Rect2(-100000, -100000, 200000, 200000)

var failures: Array[String] = []
var sets: Object
var scratch := "user://copia_sets_test_%d" % OS.get_process_id()
var rng := RandomNumberGenerator.new()


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


## Points as plain arrays so tests can slice and reorder them. Origins are given per point.
func make_points(origins: Array, with_optional := true) -> Array:
	var points: Array = []
	for origin: Vector3 in origins:
		var angle := rng.randf() * TAU
		var scale := rng.randf_range(0.5, 2.0)
		var point := {
			"transform": [cos(angle) * scale, 0.0, -sin(angle) * scale, 0.0, scale, 0.0, sin(angle) * scale, 0.0, cos(angle) * scale, origin.x, origin.y, origin.z],
			"object": ["res://objects/a.tres", "res://objects/b.tres", "res://mesh/c.mesh"][rng.randi() % 3],
			"set": ["default", "rocks"][rng.randi() % 2],
		}
		if with_optional:
			var none := rng.randf() < 0.4
			point.color = [NAN, NAN, NAN, NAN] if none else [rng.randf(), rng.randf(), rng.randf(), 1.0]
			point.custom = [rng.randf(), rng.randf(), 0.0, rng.randf()]
			point.keep = rng.randf()
			point.tag = rng.randi_range(-1000, 1000)
			point.radius = rng.randf_range(0, 5)
			point.dir = [rng.randf(), rng.randf(), rng.randf()]
		points.append(point)
	return points


func random_origins(count: int, area: float) -> Array:
	var origins: Array = []
	for i in count:
		origins.append(Vector3(rng.randf_range(-area, area), rng.randf_range(-5, 5), rng.randf_range(-area, area)))
	return origins


## Packs plain points into apply() columns.
func columns(points: Array) -> Dictionary:
	var transform := PackedFloat32Array()
	var object := PackedInt32Array()
	var set_index := PackedInt32Array()
	var paths: Array = []
	var names: Array = []
	var color := PackedFloat32Array()
	var custom := PackedFloat32Array()
	var keep := PackedFloat32Array()
	var tag := PackedInt32Array()
	var radius := PackedFloat32Array()
	var dir := PackedFloat32Array()
	var optional: bool = not points.is_empty() and points[0].has("color")
	for point: Dictionary in points:
		transform.append_array(PackedFloat32Array(point.transform))
		if not paths.has(point.object):
			paths.append(point.object)
		object.append(paths.find(point.object))
		if not names.has(point.set):
			names.append(point.set)
		set_index.append(names.find(point.set))
		if optional:
			color.append_array(PackedFloat32Array(point.color))
			custom.append_array(PackedFloat32Array(point.custom))
			keep.append(point.keep)
			tag.append(point.tag)
			radius.append(point.radius)
			dir.append_array(PackedFloat32Array(point.dir))
	var result := {"transform": transform, "object": object, "object_paths": PackedStringArray(paths), "set": set_index, "set_names": PackedStringArray(names)}
	if optional:
		result.color = color
		result.custom = custom
		result.keep = keep
		result.extra = {"tag": tag, "radius": radius, "dir": dir}
	return result


## One comparable string per point, from apply() input or read_points() output.
func point_keys(data: Dictionary) -> Array:
	var keys: Array = []
	var count: int = data.object.size()
	for i in count:
		var parts: Array = [data.set_names[data.set[i]], data.object_paths[data.object[i]], Array(data.transform.slice(i * 12, i * 12 + 12))]
		if data.has("color"):
			parts.append(var_to_str(Array(data.color.slice(i * 4, i * 4 + 4))))
			parts.append(Array(data.custom.slice(i * 4, i * 4 + 4)))
			parts.append(data.keep[i])
			parts.append(data.extra.tag[i])
			parts.append(data.extra.radius[i])
			parts.append(Array(data.extra.dir.slice(i * 3, i * 3 + 3)))
		keys.append(var_to_str(parts))
	keys.sort()
	return keys


func hashes(directory: String) -> Dictionary:
	var result := {}
	for set_name in sets.list_sets(directory):
		for entry: Dictionary in sets.list_cells(directory, set_name):
			result["%s/%s" % [set_name, entry.cell]] = entry.hash
	return result


func read_all(directory: String) -> Dictionary:
	return sets.read_points(directory, CELL, ALL, PackedStringArray(), PackedStringArray())


func apply(directory: String, clears: Array, points: Dictionary) -> Dictionary:
	var result: Dictionary = sets.apply(directory, CELL, clears, points)
	return result


func run() -> void:
	var started := Time.get_ticks_msec()
	if not ClassDB.class_exists("CopiaSets"):
		GDExtensionManager.load_extension(EXTENSION)
	if not ClassDB.class_exists("CopiaSets"):
		push_error("CopiaSets is not available")
		quit(1)
		return
	sets = ClassDB.instantiate("CopiaSets")
	rng.seed = 7
	remove_tree(scratch)

	# Round trip: every column, extra columns included, comes back identical.
	var points := make_points(random_origins(600, 150.0))
	var dir_a := scratch.path_join("a")
	var applied := apply(dir_a, [], columns(points))
	check(applied.ok, "round trip apply succeeds: %s" % applied.error)
	var back := read_all(dir_a)
	check(back.count == points.size(), "round trip returns every point (%d of %d)" % [back.count, points.size()])
	check(point_keys(back) == point_keys(columns(points)), "round trip returns identical columns")
	check(back.extra.tag is PackedInt32Array and back.extra.radius.size() == points.size() and back.extra.dir.size() == points.size() * 3, "extra columns keep their type and width")

	# The same points in another order, and in two calls, give the same hashes.
	var shuffled := points.duplicate()
	shuffled.shuffle()
	var dir_b := scratch.path_join("b")
	apply(dir_b, [], columns(shuffled))
	check(hashes(dir_b) == hashes(dir_a) and not hashes(dir_a).is_empty(), "another order gives the same file hashes")
	var dir_c := scratch.path_join("c")
	apply(dir_c, [], columns(shuffled.slice(0, 250)))
	apply(dir_c, [], columns(shuffled.slice(250)))
	check(hashes(dir_c) == hashes(dir_a), "two calls give the same file hashes as one")

	# An unchanged apply rewrites nothing: a replacing write of the same points.
	var clears: Array = []
	for key: String in hashes(dir_a):
		var parts := key.split("/")
		var cell_text := parts[1].trim_prefix("(").trim_suffix(")").split(", ")
		clears.append({"set": parts[0], "cell": Vector2i(int(cell_text[0]), int(cell_text[1]))})
	var file_path := dir_a.path_join("sets/default").path_join(DirAccess.get_files_at(dir_a.path_join("sets/default"))[0])
	var modified := FileAccess.get_modified_time(file_path)
	var before := hashes(dir_a)
	var again := apply(dir_a, clears, columns(points))
	check(again.ok and again.written.is_empty() and again.deleted.is_empty() and again.unchanged.size() == before.size(), "a replacing write of the same points writes nothing (%d written, %d unchanged)" % [again.written.size(), again.unchanged.size()])
	check(again.cells.is_empty(), "an unchanged write touches no cell")
	check(FileAccess.get_modified_time(file_path) == modified and hashes(dir_a) == before, "unchanged files keep their modification time and hash")
	var plain := apply(dir_a, [], {})
	check(plain.ok and plain.written.is_empty() and plain.unchanged.is_empty(), "an empty apply does nothing")

	# Clear then add in one call replaces; add without clear appends; a clear empties only
	# the named set in the named cell.
	var dir_d := scratch.path_join("d")
	var first := make_points([Vector3(1, 0, 1), Vector3(10, 0, 20), Vector3(30, 0, 40)])
	var second := make_points([Vector3(5, 0, 5), Vector3(50, 0, 50)])
	var third := make_points([Vector3(7, 0, 7)])
	var other_cell := make_points([Vector3(100, 0, 10)])
	for group in [first, second, third, other_cell]:
		for point: Dictionary in group:
			point.set = "a"
	var neighbour := make_points([Vector3(2, 0, 2), Vector3(3, 0, 3)])
	for point: Dictionary in neighbour:
		point.set = "b"
	apply(dir_d, [], columns(first + other_cell + neighbour))
	var replaced := apply(dir_d, [{"set": "a", "cell": Vector2i(0, 0)}], columns(second))
	check(replaced.ok and replaced.written.size() == 1, "clear and add in one call write the file once")
	var a_now: Dictionary = sets.read_points(dir_d, CELL, Rect2(0, 0, 64, 64), PackedStringArray(["a"]), PackedStringArray())
	check(point_keys(a_now) == point_keys(columns(second)), "clear then add in one call replaces")
	apply(dir_d, [], columns(third))
	a_now = sets.read_points(dir_d, CELL, Rect2(0, 0, 64, 64), PackedStringArray(["a"]), PackedStringArray())
	check(point_keys(a_now) == point_keys(columns(second + third)), "add without clear appends")
	var cleared := apply(dir_d, [{"set": "a", "cell": Vector2i(0, 0)}], {})
	check(cleared.ok and cleared.deleted == PackedStringArray(["sets/a/0_0.copiaset"]) and cleared.cells == [Vector2i(0, 0)], "a clear deletes the emptied file and reports its cell")
	var b_now: Dictionary = sets.read_points(dir_d, CELL, Rect2(0, 0, 64, 64), PackedStringArray(["b"]), PackedStringArray())
	check(point_keys(b_now) == point_keys(columns(neighbour)), "a clear leaves other sets in the cell")
	var a_elsewhere: Array = sets.list_cells(dir_d, "a")
	check(a_elsewhere.size() == 1 and a_elsewhere[0].cell == Vector2i(1, 0), "a clear leaves the set's other cells")
	var excluded: Dictionary = sets.read_points(dir_d, CELL, ALL, PackedStringArray(), PackedStringArray(["b"]))
	check(excluded.set_names == PackedStringArray(["a"]), "read_points excludes the named sets")

	# Cell placement: negative coordinates and points exactly on a cell edge.
	var dir_e := scratch.path_join("e")
	var placement := {
		Vector3(0, 0, 0): Vector2i(0, 0),
		Vector3(-0.5, 0, 0.5): Vector2i(-1, 0),
		Vector3(64, 0, 0): Vector2i(1, 0),
		Vector3(0, 0, -64): Vector2i(0, -1),
		Vector3(-64.25, 0, 127.75): Vector2i(-2, 1),
		Vector3(-128, 0, -128): Vector2i(-2, -2),
	}
	for origin: Vector3 in placement:
		remove_tree(dir_e)
		var single := make_points([origin], false)
		single[0].set = "default"
		apply(dir_e, [], columns(single))
		var cells: Array = sets.list_cells(dir_e, "default")
		check(cells.size() == 1 and cells[0].cell == placement[origin], "origin %s lands in cell %s (got %s)" % [origin, placement[origin], cells])
	var edge_points: Dictionary = sets.read_points(dir_e, CELL, Rect2(-128, -128, 64, 64), PackedStringArray(), PackedStringArray())
	check(edge_points.count == 1, "read_points includes a point on the rectangle's start edge")
	edge_points = sets.read_points(dir_e, CELL, Rect2(-192, -192, 64, 64), PackedStringArray(), PackedStringArray())
	check(edge_points.count == 0, "read_points excludes a point on the rectangle's end edge")

	# Invalid input is rejected whole: nothing written, not even the clears.
	var snapshot := hashes(dir_d)
	var good := columns(make_points(random_origins(20, 100.0)))
	var bad_cases := {}
	var bad := good.duplicate(true)
	bad.set_names = PackedStringArray(["Not-Valid", "rocks"])
	bad_cases["bad set name"] = bad
	bad = good.duplicate(true)
	bad.object = PackedInt32Array(Array(bad.object).slice(1))
	bad_cases["mismatched column lengths"] = bad
	bad = good.duplicate(true)
	bad.color = PackedFloat32Array(Array(bad.color).slice(4))
	bad_cases["mismatched colour length"] = bad
	bad = good.duplicate(true)
	bad.object[3] = 99
	bad_cases["object index out of range"] = bad
	bad = good.duplicate(true)
	bad.transform[25] = NAN
	bad_cases["non-finite transform"] = bad
	bad = good.duplicate(true)
	bad.transform[0] = INF
	bad_cases["infinite transform"] = bad
	bad = good.duplicate(true)
	bad.custom[5] = INF
	bad_cases["infinite custom value"] = bad
	bad = good.duplicate(true)
	bad.extra.tag = PackedInt32Array([1, 2])
	bad_cases["short extra column"] = bad
	for name: String in bad_cases:
		var rejected := apply(dir_d, [{"set": "b", "cell": Vector2i(0, 0)}], bad_cases[name])
		check(not rejected.ok and not String(rejected.error).is_empty() and rejected.written.is_empty() and rejected.deleted.is_empty(), "%s is rejected" % name)
		check(hashes(dir_d) == snapshot, "%s writes nothing" % name)
	var bad_clear := apply(dir_d, [{"set": "B", "cell": Vector2i(0, 0)}], good)
	check(not bad_clear.ok and hashes(dir_d) == snapshot, "an invalid clear rejects the whole call")
	# A stored extra column with another type rejects the call.
	var typed := columns(make_points([Vector3(3, 0, 4)]))
	typed.set_names = PackedStringArray(["b"])
	typed.extra.tag = PackedFloat32Array([1.5])
	var conflict := apply(dir_d, [], typed)
	check(not conflict.ok and hashes(dir_d) == snapshot, "an extra column stored with another type is rejected")

	# remove_set deletes a set and returns its cells.
	var removed: Array = sets.remove_set(dir_d, "a")
	check(removed == [Vector2i(1, 0)] and not sets.list_sets(dir_d).has("a"), "remove_set deletes the set and returns its cells")

	remove_tree(scratch)
	var elapsed := Time.get_ticks_msec() - started
	if failures.is_empty():
		print("COPIA_SETS_TEST PASS (%d ms)" % elapsed)
		quit(0)
	else:
		print("COPIA_SETS_TEST FAIL: %d failures (%d ms)" % [failures.size(), elapsed])
		for failure in failures:
			print("  - ", failure)
		quit(1)
