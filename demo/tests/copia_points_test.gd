## CopiaPoints contracts: the transform rule against hand-computed bases (orient; N and up; N
## parallel to up; float and vector scale with pscale; missing values), instance, clear and
## skipped points, the table columns, the "no value" rows, extra columns, packed arrays and plain
## Arrays giving identical output, the to_attributes round trip, CopiaSets.cell_points rows, and
## from_attributes output going through CopiaSets.apply and reading back. Headless, no Houdini;
## uses a scratch directory under user://.
##
##   godot-4.7.2 --path demo --headless --script res://tests/copia_points_test.gd [-- --timing]
##
## --timing also converts 2 million points from packed arrays and from plain Arrays and prints
## COPIA_POINTS_TIMING lines (about 30 s more, mostly building the input in GDScript).
## Prints COPIA_POINTS_TEST PASS or FAIL and exits 0 or 1. Run time: about 1 s.
extends SceneTree

const EXTENSION := "res://addons/copia/bin/copia.gdextension"
const CELL := 64.0
const ALL := Rect2(-100000, -100000, 200000, 200000)
const EPSILON := 1e-5

var failures: Array[String] = []
var points_class: Object
var sets: Object
var scratch := "user://copia_points_test_%d" % OS.get_process_id()


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


func to_points(attributes: Dictionary, names := {}, extra := PackedStringArray()) -> Dictionary:
	return points_class.from_attributes(attributes, names, extra)


## Point i's transform as a Transform3D (basis columns, origin).
func transform_at(points: Dictionary, i: int) -> Transform3D:
	var t: PackedFloat32Array = points.transform
	var k := i * 12
	return Transform3D(Vector3(t[k], t[k + 1], t[k + 2]), Vector3(t[k + 3], t[k + 4], t[k + 5]), Vector3(t[k + 6], t[k + 7], t[k + 8]), Vector3(t[k + 9], t[k + 10], t[k + 11]))


func same_transform(a: Transform3D, b: Transform3D) -> bool:
	for c in 4:
		var x: Vector3 = a.origin if c == 3 else a.basis[c]
		var y: Vector3 = b.origin if c == 3 else b.basis[c]
		if (x - y).length() > EPSILON * maxf(1.0, y.length()):
			return false
	return true


func is_none_row(values: PackedFloat32Array, i: int) -> bool:
	for k in 4:
		if not is_nan(values[i * 4 + k]):
			return false
	return true


## The same attributes as packed arrays and as plain Arrays (no missing values).
func both_kinds(count: int, seed_value: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var packed := {"P": PackedVector3Array(), "N": PackedVector3Array(), "up": PackedVector3Array(), "scale": PackedVector3Array(), "pscale": PackedFloat32Array(),
			"object": PackedStringArray(), "set": PackedStringArray(), "Cd": PackedVector3Array(), "custom": PackedVector4Array(), "keep": PackedFloat32Array(),
			"tag": PackedInt32Array(), "radius": PackedFloat32Array(), "dir": PackedVector3Array()}
	var plain := {}
	for key in packed:
		plain[key] = []
	for i in count:
		var normal := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
		var values := {
			"P": Vector3(rng.randf_range(-200, 200), rng.randf_range(-5, 5), rng.randf_range(-200, 200)),
			"N": normal if normal.length() > 0.1 else Vector3.BACK,
			"up": Vector3(rng.randf_range(-0.2, 0.2), 1, rng.randf_range(-0.2, 0.2)),
			"scale": Vector3(rng.randf_range(0.5, 2), rng.randf_range(0.5, 2), rng.randf_range(0.5, 2)),
			"pscale": rng.randi_range(32, 96) / 64.0,  # exact in float32, so both kinds agree
			"object": ["res://a.tres", "res://b.tres", "res://c.mesh"][i % 3],
			"set": ["ground", "rocks"][i % 2],
			"Cd": Vector3(rng.randf(), rng.randf(), rng.randf()),
			"custom": Vector4(rng.randf(), rng.randf(), rng.randf(), rng.randf()),
			"keep": rng.randi_range(0, 256) / 256.0,
			"tag": i,
			"radius": rng.randi_range(0, 48) / 16.0,
			"dir": Vector3(rng.randf(), rng.randf(), rng.randf()),
		}
		for key in values:
			packed[key].append(values[key])
			plain[key].append(values[key])
	return [packed, plain]


func run() -> void:
	var started := Time.get_ticks_msec()
	if not ClassDB.class_exists("CopiaPoints"):
		GDExtensionManager.load_extension(EXTENSION)
	if not ClassDB.class_exists("CopiaPoints"):
		push_error("CopiaPoints is not available")
		quit(1)
		return
	points_class = ClassDB.instantiate("CopiaPoints")
	sets = ClassDB.instantiate("CopiaSets")
	remove_tree(scratch)

	# The transform rule, one point per case. Hand-computed: a quarter turn about +Y maps x to -z
	# and z to x; N = +X with up = +Y gives the same frame (right = up x N = -Z).
	var quarter := Transform3D(Basis(Vector3(0, 0, -1), Vector3(0, 1, 0), Vector3(1, 0, 0)), Vector3.ZERO)
	var s := sin(PI / 4.0)
	var c := cos(PI / 4.0)
	var cases := [
		# [description, orient, N, up, scale, pscale, expected basis columns]
		["orient as Vector4", Vector4(0, s, 0, c), null, null, null, null, quarter.basis],
		["orient as Quaternion", Quaternion(0, s, 0, c), null, null, null, null, quarter.basis],
		["orient not normalised", Vector4(0, 2 * s, 0, 2 * c), null, null, null, null, quarter.basis],
		["N and up", null, Vector3(1, 0, 0), Vector3(0, 1, 0), null, null, quarter.basis],
		["N with a missing up", null, Vector3(3, 0, 0), null, null, null, quarter.basis],
		["missing orient falls back to N", null, Vector3(1, 0, 0), Vector3(0, 1, 0), null, null, quarter.basis],
		["N parallel to up", null, Vector3(0, 2, 0), Vector3(0, 1, 0), null, null, Basis.IDENTITY],
		["nothing: identity", null, null, null, null, null, Basis.IDENTITY],
		["float scale with pscale", null, Vector3(1, 0, 0), Vector3(0, 1, 0), 2.0, 3.0, quarter.basis.scaled_local(Vector3(6, 6, 6))],
		["vector scale with pscale", Vector4(0, s, 0, c), null, null, Vector3(1, 2, 3), 2.0, quarter.basis.scaled_local(Vector3(2, 4, 6))],
		["missing scale and pscale", null, null, null, null, null, Basis.IDENTITY],
	]
	var attributes := {"P": [], "orient": [], "N": [], "up": [], "scale": [], "pscale": [], "object": []}
	for i in cases.size():
		var entry: Array = cases[i]
		attributes.P.append(Vector3(i, 0.5, -i))
		attributes.orient.append(entry[1])
		attributes.N.append(entry[2])
		attributes.up.append(entry[3])
		attributes.scale.append(entry[4])
		attributes.pscale.append(entry[5])
		attributes.object.append("res://rule.tres")
	# orient exists as an attribute, so the N rows only use N where orient is missing (all here).
	var converted := to_points(attributes)
	check(converted.point_count == cases.size() and converted.errors.is_empty(), "every rule case is an instance (%s)" % [converted.errors])
	for i in cases.size():
		var entry: Array = cases[i]
		var got := transform_at(converted.points, i)
		check(same_transform(got, Transform3D(entry[6], Vector3(i, 0.5, -i))), "%s: basis %s (expected %s)" % [entry[0], got.basis, entry[6]])
	# Without an orient attribute, N and up alone decide; without either, identity.
	var frame_only := to_points({"P": [Vector3.ZERO], "N": [Vector3(1, 0, 0)], "object": ["res://x.tres"]})
	check(same_transform(transform_at(frame_only.points, 0), quarter), "N alone uses the default up")
	var up_only := to_points({"P": [Vector3.ZERO], "up": [Vector3(0, 0, 1)], "object": ["res://x.tres"]})
	# n = (0,0,1) default, u = (0,0,1): parallel, identity.
	check(same_transform(transform_at(up_only.points, 0), Transform3D.IDENTITY), "up parallel to the default N gives identity")

	# Instance, clear and skipped points; tables; "no value" rows; extras.
	var mixed := to_points({
		"P": [Vector3(1, 0, 1), Vector3(70, 0, 5), null, Vector3(3, 0, 3), Vector3(4, 0, 4), Vector3(5, 0, 5), Vector3(6, 0, 6), Vector3(7, 0, 7)],
		"object": ["res://a.tres", "res://b.tres", "res://a.tres", "", "res://a.tres", null, "res://b.tres", "res://a.tres"],
		"set": [null, "rocks", "rocks", "rocks", "rocks", "trees", "Bad-Name", ""],
		"clear": [0, null, 0, 1, 1, 1, 0, 0],
		"cell": [null, null, null, "2_-3", "nonsense", "-1_0", null, null],
		"Cd": [Vector3(0.5, 0.25, 1), null, null, null, null, null, null, Color(0.1, 0.2, 0.3, 0.4)],
		"custom": [null, Vector4(1, 2, 3, 4), null, null, null, null, null, Color(1, 0, 0, 1)],
		"keep": [0.25, null, null, null, null, null, null, 2.0],
		"tag": [7, null, 0, 0, 0, 0, 0, 9],
		"radius": [1.5, 2.5, 0.0, 0.0, 0.0, 0.0, 0.0, null],
		"dir": [Vector3(1, 2, 3), null, null, null, null, null, null, Vector3(4, 5, 6)],
	}, {}, PackedStringArray(["tag", "radius", "dir"]))
	var p: Dictionary = mixed.points
	# Instances: 0 (default set), 1 (rocks), 7 (empty set = default). Clears: 3 (rocks 2_-3), 5
	# (trees -1_0; its null object does not matter). Skipped: 2 (no position), 4 (bad cell),
	# 6 (invalid set name).
	check(mixed.point_count == 3 and mixed.clear_count == 2 and mixed.skipped_count == 3, "3 instances, 2 clears, 3 skipped (%d, %d, %d)" % [mixed.point_count, mixed.clear_count, mixed.skipped_count])
	check(mixed.clears == [{"set": "rocks", "cell": Vector2i(2, -3)}, {"set": "trees", "cell": Vector2i(-1, 0)}], "clears hold set and cell (%s)" % [mixed.clears])
	check(p.object_paths == PackedStringArray(["res://a.tres", "res://b.tres"]) and p.object == PackedInt32Array([0, 1, 0]), "object index and table columns (%s %s)" % [p.object_paths, p.object])
	check(p.set_names == PackedStringArray(["default", "rocks"]) and p.set == PackedInt32Array([0, 1, 0]), "set index and table columns, default for missing (%s %s)" % [p.set_names, p.set])
	check(p.color.size() == 12 and is_equal_approx(p.color[0], 0.5) and is_equal_approx(p.color[3], 1.0) and is_none_row(p.color, 1) and is_equal_approx(p.color[11], 0.4), "Cd: Vector3 gets alpha 1, missing is a NaN row, Color keeps alpha")
	check(is_none_row(p.custom, 0) and p.custom.slice(4, 8) == PackedFloat32Array([1, 2, 3, 4]) and p.custom.slice(8, 12) == PackedFloat32Array([1, 0, 0, 1]), "custom: missing is a NaN row; Vector4 and Color are kept")
	check(p.keep == PackedFloat32Array([0.25, 1.0, 2.0]), "keep: missing reads 1, others pass as given (%s)" % p.keep)
	check(p.extra.tag == PackedInt32Array([7, 0, 9]) and p.extra.radius == PackedFloat32Array([1.5, 2.5, 0.0]) and p.extra.dir == PackedVector3Array([Vector3(1, 2, 3), Vector3.ZERO, Vector3(4, 5, 6)]),
			"extra columns keep int, float and Vector3, zero where missing (%s)" % [p.extra])
	check(not mixed.errors.is_empty(), "skipped points are reported (%s)" % [mixed.errors])
	var wrong := to_points({"P": [Vector3.ZERO, Vector3.ONE], "object": ["res://a.tres", "res://a.tres"], "N": ["up", Vector3(1, 0, 0)]})
	check(wrong.point_count == 2 and wrong.errors.size() == 1 and same_transform(transform_at(wrong.points, 0), Transform3D(Basis.IDENTITY, Vector3.ZERO)), "a value of the wrong type reads as missing and is reported (%s)" % [wrong.errors])
	var renamed := to_points({"pos": [Vector3(1, 2, 3)], "kind": ["res://a.tres"]}, {"P": "pos", "object": "kind"})
	check(renamed.point_count == 1 and transform_at(renamed.points, 0).origin == Vector3(1, 2, 3), "names override the attribute names")

	# Packed arrays and plain Arrays give identical output.
	var kinds := both_kinds(500, 5)
	var extras := PackedStringArray(["tag", "radius", "dir"])
	var from_packed := to_points(kinds[0], {}, extras)
	var from_plain := to_points(kinds[1], {}, extras)
	check(from_packed.point_count == 500 and from_packed.errors.is_empty(), "packed input converts (%s)" % [from_packed.errors])
	check(var_to_bytes(from_packed) == var_to_bytes(from_plain), "packed arrays and plain Arrays give identical output")

	# Round trip: to_attributes then from_attributes reproduces orthogonal bases with scale.
	var back: Dictionary = points_class.to_attributes(from_packed.points)
	var types_ok: bool = back.P is PackedVector3Array and back.N is PackedVector3Array and back.up is PackedVector3Array and back.scale is PackedVector3Array \
			and back.object is PackedStringArray and back.set is PackedStringArray and back.keep is PackedFloat32Array and back.Cd is PackedVector3Array \
			and back.custom is PackedVector3Array and back.custom_w is PackedFloat32Array and back.tag is PackedInt32Array and back.radius is PackedFloat32Array and back.dir is PackedVector3Array
	check(types_ok, "to_attributes gives int32, float32, Vector3 and String arrays only")
	var again := to_points(back, {}, extras)
	var round_ok: bool = again.point_count == 500
	for i in 500:
		if not round_ok:
			break
		round_ok = same_transform(transform_at(again.points, i), transform_at(from_packed.points, i))
	check(round_ok, "a round trip reproduces every transform")
	check(again.points.object_paths == from_packed.points.object_paths and again.points.object == from_packed.points.object and again.points.set == from_packed.points.set,
			"a round trip keeps objects and sets")
	check(again.points.custom == from_packed.points.custom and again.points.keep == from_packed.points.keep and again.points.extra.tag == from_packed.points.extra.tag,
			"a round trip keeps custom data (custom + custom_w), keep and extra columns")

	# Through the store: apply, read back, cell_points.
	var dir := scratch.path_join("store")
	var applied: Dictionary = sets.apply(dir, CELL, mixed.clears, from_packed.points)
	check(applied.ok, "from_attributes output applies: %s" % applied.error)
	var read: Dictionary = sets.read_points(dir, CELL, ALL, PackedStringArray(), PackedStringArray())
	check(read.count == 500, "every converted point reads back (%d)" % read.count)
	var expected_rows := {}
	var t: PackedFloat32Array = from_packed.points.transform
	for i in 500:
		var cell := Vector2i(floori(t[i * 12 + 9] / CELL), floori(t[i * 12 + 11] / CELL))
		var key := "%d_%d %s" % [cell.x, cell.y, from_packed.points.set_names[from_packed.points.set[i]]]
		expected_rows[key] = expected_rows.get(key, 0) + 1
	var rows: Dictionary = sets.cell_points(dir, CELL)
	var got_rows := {}
	var rows_ok: bool = rows.P.size() == rows.cell.size() and rows.cell.size() == rows.set.size() and rows.set.size() == rows["count"].size()
	for i in rows.cell.size():
		got_rows["%s %s" % [rows.cell[i], rows.set[i]]] = rows["count"][i]
		var parts: PackedStringArray = rows.cell[i].split("_")
		var low := Vector3(int(parts[0]) * CELL, 0, int(parts[1]) * CELL)
		rows_ok = rows_ok and rows.cell_min[i] == low and rows.cell_max[i] == low + Vector3(CELL, 0, CELL) and rows.P[i] == low + Vector3(CELL / 2, 0, CELL / 2)
	check(rows_ok and got_rows == expected_rows, "cell_points has one row per cell and set with its count and bounds (%d rows)" % got_rows.size())
	var some: Dictionary = sets.cell_points(dir, CELL, Rect2(0, 0, 64, 64), PackedStringArray(["rocks"]))
	check(some.cell == PackedStringArray(["0_0"]) and some.set == PackedStringArray(["rocks"]), "cell_points takes a rect and set filter (%s %s)" % [some.cell, some.set])
	check(sets.list_objects(dir) == PackedStringArray(["res://a.tres", "res://b.tres", "res://c.mesh"]), "list_objects lists the objects of the set files")

	if "--timing" in OS.get_cmdline_user_args():
		timing()

	remove_tree(scratch)
	var elapsed := Time.get_ticks_msec() - started
	if failures.is_empty():
		print("COPIA_POINTS_TEST PASS (%d ms)" % elapsed)
		quit(0)
	else:
		print("COPIA_POINTS_TEST FAIL: %d failures (%d ms)" % [failures.size(), elapsed])
		for failure in failures:
			print("  - ", failure)
		quit(1)


func timing() -> void:
	var n := 2_000_000
	var build_start := Time.get_ticks_msec()
	var kinds := both_kinds(n, 9)
	print("COPIA_POINTS_TIMING input points=%d seconds=%.1f (GDScript, not part of Copia)" % [n, (Time.get_ticks_msec() - build_start) / 1000.0])
	var extras := PackedStringArray(["tag", "radius", "dir"])
	for round_index in 2:
		for kind in 2:
			var start := Time.get_ticks_usec()
			var result := to_points(kinds[kind], {}, extras)
			var seconds := (Time.get_ticks_usec() - start) / 1e6
			print("COPIA_POINTS_TIMING from_attributes %s points=%d seconds=%.3f points_per_second=%.0f" % [["packed", "plain"][kind], result.point_count, seconds, n / seconds])
	var packed := to_points(kinds[0], {}, extras)
	var start := Time.get_ticks_usec()
	var back: Dictionary = points_class.to_attributes(packed.points)
	print("COPIA_POINTS_TIMING to_attributes points=%d seconds=%.3f" % [back.P.size(), (Time.get_ticks_usec() - start) / 1e6])
