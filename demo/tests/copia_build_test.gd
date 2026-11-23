## Copia build: built cells and far cells against their set files. Every instance appears once,
## sets share batches, batches respect their size and are centred on their bounds, keep order
## and counts, colliders and impostors follow their minimum scales, a rebuild is byte-identical
## and stale_cells names exactly what a set write or a descriptor change made stale. An impostor
## batch size splits a cell's impostors into finer batches, and its default changes nothing.
## Headless, no Houdini; uses a scratch directory under user://.
##
##   godot-4.7.2 --path demo --headless --script res://tests/copia_build_test.gd
##
## Prints COPIA_BUILD_TEST PASS or FAIL and exits 0 or 1. Run time: about 1 s (1.0 s measured).
extends SceneTree

const EXTENSION := "res://addons/copia/bin/copia.gdextension"
const CELL := 64.0
const FAR := 128.0
const GRASS := "res://objects/grass.tres"
const ROCK := "res://objects/rock.tres"
const TREE := "res://objects/tree.tres"
const BARE := "res://meshes/bare.mesh"
const CELLS := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, -1), Vector2i(2, 0)]

var failures: Array[String] = []
var sets: Object
var build: Object
var cells_reader: Object
var scratch := "user://copia_build_test_%d" % OS.get_process_id()
var rng := RandomNumberGenerator.new()
var objects := {
	GRASS: {"draw": "multimesh", "mesh_aabb": AABB(Vector3(-0.2, 0, -0.2), Vector3(0.4, 0.5, 0.4)), "batch_size": 16.0, "default_color": Color(0.2, 0.8, 0.2, 1), "default_custom": Color(0.5, 0, 0, 0)},
	ROCK: {"draw": "multimesh", "mesh_aabb": AABB(Vector3(-1, -0.5, -1), Vector3(2, 1, 2)), "batch_size": 32.0, "collider": true, "collider_min_scale": 1.0},
	TREE: {"draw": "instance", "mesh_aabb": AABB(Vector3(-2, 0, -2), Vector3(4, 10, 4)), "collider": true, "collider_min_scale": 1.2, "impostor": true, "impostor_cell_size": FAR, "impostor_min_scale": 0.9},
}


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


func make_point(set_name: String, object: String, cell: Vector2i) -> Dictionary:
	var angle := rng.randf() * TAU
	var scale := rng.randf_range(0.5, 2.0)
	# Origins on a 1/64 m grid are exact in float32, so world origins rebuilt from a batch
	# origin and a relative offset round back to the same key.
	var origin := Vector3(cell.x * CELL + rng.randi_range(0, 4095) / 64.0, rng.randi_range(0, 320) / 64.0, cell.y * CELL + rng.randi_range(0, 4095) / 64.0)
	var transform := PackedFloat32Array([cos(angle) * scale, 0.0, -sin(angle) * scale, 0.0, scale, 0.0, sin(angle) * scale, 0.0, cos(angle) * scale, origin.x, origin.y, origin.z])
	var none := rng.randf() < 0.5
	return {
		"set": set_name, "object": object, "transform": transform,
		"color": PackedFloat32Array([NAN, NAN, NAN, NAN]) if none else PackedFloat32Array([rng.randf(), rng.randf(), rng.randf(), 1.0]),
		"custom": PackedFloat32Array([NAN, NAN, NAN, NAN]) if rng.randf() < 0.5 else PackedFloat32Array([rng.randf(), 0.0, 0.0, rng.randf()]),
		"keep": [1.0, 0.8, 0.6, 0.3, 0.1, 0.0, rng.randf()][rng.randi() % 7],
	}


func columns(points: Array) -> Dictionary:
	var transform := PackedFloat32Array()
	var object := PackedInt32Array()
	var set_index := PackedInt32Array()
	var color := PackedFloat32Array()
	var custom := PackedFloat32Array()
	var keep := PackedFloat32Array()
	var paths: Array = []
	var names: Array = []
	for point: Dictionary in points:
		transform.append_array(point.transform)
		if not paths.has(point.object):
			paths.append(point.object)
		object.append(paths.find(point.object))
		if not names.has(point.set):
			names.append(point.set)
		set_index.append(names.find(point.set))
		color.append_array(point.color)
		custom.append_array(point.custom)
		keep.append(point.keep)
	return {"transform": transform, "object": object, "object_paths": PackedStringArray(paths), "set": set_index, "set_names": PackedStringArray(names), "color": color, "custom": custom, "keep": keep}


func cell_of(point: Dictionary) -> Vector2i:
	return Vector2i(floori(point.transform[9] / CELL), floori(point.transform[11] / CELL))


func key(basis: Array, origin: Vector3) -> String:
	return var_to_str([basis, roundi(origin.x * 64.0), roundi(origin.y * 64.0), roundi(origin.z * 64.0)])


func point_key(point: Dictionary) -> String:
	var t: PackedFloat32Array = point.transform
	return key(Array(t.slice(0, 9)), Vector3(t[9], t[10], t[11]))


func scale_of(t: PackedFloat32Array) -> float:
	return Vector3(t[3], t[4], t[5]).length()


func transform_keys(transforms: PackedFloat32Array) -> Array:
	var keys: Array = []
	for i in transforms.size() / 12:
		keys.append(key(Array(transforms.slice(i * 12, i * 12 + 9)), Vector3(transforms[i * 12 + 9], transforms[i * 12 + 10], transforms[i * 12 + 11])))
	keys.sort()
	return keys


func sorted_keys(points: Array) -> Array:
	var keys: Array = []
	for point: Dictionary in points:
		keys.append(point_key(point))
	keys.sort()
	return keys


func cell_file(directory: String, cell: Vector2i) -> String:
	return directory.path_join("cells/%d_%d.copiacell" % [cell.x, cell.y])


func far_file(directory: String, cell: Vector2i) -> String:
	return directory.path_join("far/%d_%d.copiacell" % [cell.x, cell.y])


func far_of(cell: Vector2i) -> Vector2i:
	return Vector2i(floori(cell.x / 2.0), floori(cell.y / 2.0))


## Checks a multimesh section against its source points: each point once, batch cells, bounds,
## keep order and counts, colours. Returns the number of batches.
func check_batches(section: Dictionary, source: Array, descriptor: Dictionary, batch_size: float, label: String, cell_batches := false) -> int:
	if not section.get("ok", false):
		check(false, "%s: section reads (%s)" % [label, section.get("error", "")])
		return 0
	var by_key := {}
	for point: Dictionary in source:
		by_key[point_key(point)] = point
	var seen: Array = []
	var batch_cells := {}
	var aabb: AABB = descriptor.get("mesh_aabb", AABB())
	var default_color: Color = descriptor.get("default_color", Color(1, 1, 1, 1))
	var default_custom: Color = descriptor.get("default_custom", Color(0, 0, 0, 0))
	for b in section.batch_count:
		var batch_cell := Vector2i(section.batch_cells[b * 2], section.batch_cells[b * 2 + 1])
		check(not batch_cells.has(batch_cell), "%s: batch cell %s appears once" % [label, batch_cell])
		batch_cells[batch_cell] = true
		var origin: Vector3 = section.origins[b]
		var bounds: AABB = section.bounds[b]
		check(bounds.position.is_equal_approx(-bounds.size * 0.5), "%s: batch origin is the centre of its bounds" % label)
		var buffer: PackedFloat32Array = section.buffers[b]
		var count: int = section.counts[b]
		check(buffer.size() == count * 20, "%s: buffer holds 20 floats per instance" % label)
		var merged := AABB()
		var previous_keep := INF
		var keep_counts := [0, 0, 0, 0, 0]
		var keep_order_ok := true
		for i in count:
			var m := buffer.slice(i * 20, i * 20 + 20)
			var basis := Basis(Vector3(m[0], m[4], m[8]), Vector3(m[1], m[5], m[9]), Vector3(m[2], m[6], m[10]))
			var relative := Vector3(m[3], m[7], m[11])
			var world := origin + relative
			var instance_key := key([m[0], m[4], m[8], m[1], m[5], m[9], m[2], m[6], m[10]], world)
			seen.append(instance_key)
			if cell_batches:
				check(Vector2i(floori(world.x / CELL), floori(world.z / CELL)) == batch_cell, "%s: impostor instance lies in its batch's cell" % label)
			else:
				check(Vector2i(floori(world.x / batch_size), floori(world.z / batch_size)) == batch_cell, "%s: instance lies in its batch cell" % label)
			var box := Transform3D(basis, relative) * aabb
			merged = box if i == 0 else merged.merge(box)
			check(bounds.grow(0.001).encloses(box), "%s: batch bounds enclose every instance" % label)
			if not by_key.has(instance_key):
				continue
			var point: Dictionary = by_key[instance_key]
			var keep: float = point.keep
			if keep > previous_keep:
				keep_order_ok = false
			previous_keep = keep
			for k in 5:
				if keep >= [1.0, 0.75, 0.5, 0.25, 0.0][k]:
					keep_counts[k] += 1
			var color: Color = default_color if is_nan(point.color[0]) else Color(point.color[0], point.color[1], point.color[2], point.color[3])
			var custom: Color = default_custom if is_nan(point.custom[0]) else Color(point.custom[0], point.custom[1], point.custom[2], point.custom[3])
			check(Color(m[12], m[13], m[14], m[15]).is_equal_approx(color), "%s: instance colour, or the object's default" % label)
			check(Color(m[16], m[17], m[18], m[19]).is_equal_approx(custom), "%s: instance custom data, or the object's default" % label)
		check(keep_order_ok, "%s: instances are ordered by keep, highest first" % label)
		check(Array(section.keep_counts.slice(b * 5, b * 5 + 5)) == keep_counts and keep_counts[4] == count, "%s: the five keep counts" % label)
		check(merged.position.is_equal_approx(bounds.position) and merged.size.is_equal_approx(bounds.size), "%s: batch bounds are tight" % label)
		if not cell_batches:
			check(is_equal_approx(batch_size, CELL) or count > 0, "%s: no empty batch" % label)
	seen.sort()
	check(seen == sorted_keys(source), "%s: every instance appears exactly once (%d built, %d in sets)" % [label, seen.size(), source.size()])
	return section.batch_count


## impostor_batch_size: 0 or the cell size leaves built data current; a smaller size splits each
## cell's impostors into batches of that cell, which the far cell gathers. A multimesh object's
## impostor batch cell holds whole draw batches. Restores the store to `objects` at the end.
func test_impostor_batches(dir: String, points: Array) -> void:
	for value in [0.0, CELL]:
		var same := objects.duplicate(true)
		same[TREE].impostor_batch_size = value
		check((build.stale_cells(dir, CELL, same) as Array).is_empty(), "impostor_batch_size %.0f leaves the built cells current" % value)
	var fine := objects.duplicate(true)
	fine[TREE].impostor_batch_size = 32.0
	fine[GRASS].merge({"impostor": true, "impostor_cell_size": FAR, "impostor_batch_size": 32.0})
	var result: Dictionary = build.build_cells(dir, CELL, CELLS, fine)
	check(result.ok, "fine impostor batches build: %s" % result.error)
	var far_expected := {}
	for cell: Vector2i in CELLS:
		var path := cell_file(dir, cell)
		var directory: Dictionary = cells_reader.read_directory(path)
		for object: String in [TREE, GRASS]:
			var source := points.filter(func(p: Dictionary) -> bool: return cell_of(p) == cell and p.object == object)
			var expected := source.filter(func(p: Dictionary) -> bool: return scale_of(p.transform) >= fine[object].get("impostor_min_scale", 0.0))
			var label := "fine cell %s %s" % [cell, object.get_file()]
			var section: Dictionary = cells_reader.read_section(path, object, "impostor")
			var batches := check_batches(section, expected, fine[object], 32.0, label)
			check(batches <= 4 and directory.objects[object].impostor_batch_count == batches, "%s: impostor batches per 32 m cell (%d)" % [label, batches])
			if object == GRASS:
				var draw: Dictionary = cells_reader.read_section(path, object)
				var from_draw := {}
				for b in draw.batch_count:
					from_draw[Vector2i(floori(draw.batch_cells[b * 2] / 2.0), floori(draw.batch_cells[b * 2 + 1] / 2.0))] = true
				var impostor_cells := {}
				for b in section.batch_count:
					impostor_cells[Vector2i(section.batch_cells[b * 2], section.batch_cells[b * 2 + 1])] = true
				check(from_draw == impostor_cells, "%s: each impostor batch holds whole draw batches" % label)
			far_expected.get_or_add([far_of(cell), object], []).append_array(expected)
	for far_key: Array in far_expected:
		var section: Dictionary = cells_reader.read_section(far_file(dir, far_key[0]), far_key[1])
		check_batches(section, far_expected[far_key], fine[far_key[1]], 32.0, "fine far %s %s" % [far_key[0], far_key[1].get_file()])
	var restored: Dictionary = build.build_cells(dir, CELL, build.stale_cells(dir, CELL, objects), objects)
	check(restored.ok and (build.stale_cells(dir, CELL, objects) as Array).is_empty(), "rebuilding for the default impostor batch leaves nothing stale")


func snapshot(directory: String) -> Dictionary:
	var files := {}
	for folder in ["cells", "far"]:
		var path := directory.path_join(folder)
		if DirAccess.dir_exists_absolute(path):
			for file in DirAccess.get_files_at(path):
				if file.ends_with(".copiacell"):  # built files, not the index
					files[folder + "/" + file] = FileAccess.get_file_as_bytes(path.path_join(file))
	return files


func stale_set(entries: Array) -> Dictionary:
	var result := {}
	for entry: Dictionary in entries:
		result["%s %s %s" % [entry.get("kind"), entry.get("cell"), entry.get("reason")]] = true
	return result


func run() -> void:
	var started := Time.get_ticks_msec()
	if not ClassDB.class_exists("CopiaBuild"):
		GDExtensionManager.load_extension(EXTENSION)
	if not ClassDB.class_exists("CopiaBuild"):
		push_error("CopiaBuild is not available")
		quit(1)
		return
	sets = ClassDB.instantiate("CopiaSets")
	build = ClassDB.instantiate("CopiaBuild")
	cells_reader = ClassDB.instantiate("CopiaCells")
	rng.seed = 11
	remove_tree(scratch)
	var dir := scratch.path_join("store")

	var points: Array = []
	for cell: Vector2i in CELLS:
		for i in 120:
			points.append(make_point("ground", [GRASS, BARE][i % 2], cell))
		for i in 80:
			points.append(make_point("rocks", [GRASS, ROCK][i % 2], cell))
		for i in 40:
			points.append(make_point("trees", TREE, cell))
	var applied: Dictionary = sets.apply(dir, CELL, [], columns(points))
	check(applied.ok, "points apply: %s" % applied.error)

	# Invalid descriptors are rejected and nothing is built.
	var bad_objects := objects.duplicate(true)
	bad_objects[ROCK].batch_size = 20.0
	var rejected: Dictionary = build.build_cells(dir, CELL, CELLS, bad_objects)
	check(not rejected.ok and rejected.written.is_empty(), "a batch size that does not divide the cell size is rejected")
	bad_objects = objects.duplicate(true)
	bad_objects[GRASS].impostor = true
	bad_objects[GRASS].impostor_cell_size = 256.0
	rejected = build.build_cells(dir, CELL, CELLS, bad_objects)
	check(not rejected.ok and rejected.written.is_empty(), "two far grid sizes are rejected")
	bad_objects = objects.duplicate(true)
	bad_objects[TREE].impostor_batch_size = 24.0
	rejected = build.build_cells(dir, CELL, CELLS, bad_objects)
	check(not rejected.ok and rejected.written.is_empty(), "an impostor batch size that does not divide the cell size is rejected")
	bad_objects = objects.duplicate(true)
	bad_objects[GRASS].merge({"impostor": true, "impostor_cell_size": FAR, "impostor_batch_size": 8.0})
	rejected = build.build_cells(dir, CELL, CELLS, bad_objects)
	check(not rejected.ok and rejected.written.is_empty(), "a multimesh impostor batch size below the batch size is rejected")

	var result: Dictionary = build.build_cells(dir, CELL, CELLS, objects)
	check(result.ok, "build succeeds: %s" % result.error)
	check(result.instance_count == points.size(), "the build counts every instance")
	check(result.defaulted == PackedStringArray([BARE]), "an object without a descriptor is built with defaults and reported")
	check(result.written.size() == CELLS.size() + 3, "the build writes every cell and the three far cells (%s)" % [result.written])

	var far_expected := {}
	for cell: Vector2i in CELLS:
		var path := cell_file(dir, cell)
		var directory: Dictionary = cells_reader.read_directory(path)
		check(directory.ok and directory.kind == "cell" and directory.cell == cell, "cell %s: directory reads" % cell)
		var in_cell := points.filter(func(p: Dictionary) -> bool: return cell_of(p) == cell)
		for object: String in [GRASS, ROCK, TREE, BARE]:
			var source := in_cell.filter(func(p: Dictionary) -> bool: return p.object == object)
			var label := "cell %s %s" % [cell, object.get_file()]
			var entry: Dictionary = directory.objects.get(object, {})
			check(entry.get("instance_count", -1) == source.size(), "%s: instance count" % label)
			var descriptor: Dictionary = objects.get(object, {})
			if object == TREE:
				var draw: Dictionary = cells_reader.read_section(path, object)
				check(draw.kind == "transforms" and transform_keys(draw.transforms) == sorted_keys(source), "%s: single instances are the set transforms" % label)
			else:
				var batch_size: float = descriptor.get("batch_size", CELL)
				var batches := check_batches(cells_reader.read_section(path, object), source, descriptor, batch_size, label)
				check(batches <= int(CELL / batch_size) ** 2, "%s: batch count within the cell's batch grid" % label)
			if object == GRASS:
				var sets_using := {}
				for point: Dictionary in source:
					sets_using[point.set] = true
				var batch_cells := {}
				for point: Dictionary in source:
					batch_cells[Vector2i(floori(point.transform[9] / 16.0), floori(point.transform[11] / 16.0))] = true
				check(sets_using.size() == 2 and entry.batch_count == batch_cells.size(), "%s: two sets using one object share batches" % label)
			if object == BARE:
				check(entry.defaulted and entry.batch_count == 1, "%s: a defaulted object has one batch per cell" % label)
			if descriptor.get("collider", false):
				var expected := source.filter(func(p: Dictionary) -> bool: return scale_of(p.transform) >= descriptor.collider_min_scale)
				var colliders: Dictionary = cells_reader.read_section(path, object, "collider")
				check(entry.collider_count == expected.size() and colliders.ok and transform_keys(colliders.transforms) == sorted_keys(expected), "%s: colliders respect collider_min_scale (%d)" % [label, expected.size()])
			else:
				check(entry.get("collider_count", 0) == 0 and not cells_reader.read_section(path, object, "collider").ok, "%s: no colliders without a collider rule" % label)
			if descriptor.get("impostor", false):
				var expected := source.filter(func(p: Dictionary) -> bool: return scale_of(p.transform) >= descriptor.impostor_min_scale)
				check(entry.impostor_count == expected.size(), "%s: impostors respect impostor_min_scale" % label)
				var far_cell := far_of(cell)
				if not far_expected.has(far_cell):
					far_expected[far_cell] = []
				far_expected[far_cell].append_array(expected)

	# Far cells: the impostors of every cell inside them, batched per cell.
	for far_cell: Vector2i in far_expected:
		var path := far_file(dir, far_cell)
		var directory: Dictionary = cells_reader.read_directory(path)
		check(directory.ok and directory.kind == "far" and directory.cell_size == FAR and directory.objects.keys() == [TREE], "far %s: holds the impostor object only" % far_cell)
		var section: Dictionary = cells_reader.read_section(path, TREE)
		check_batches(section, far_expected[far_cell], objects[TREE], CELL, "far %s" % far_cell, true)
		for i in section.get("batch_count", 0):
			var source_cell := Vector2i(section.batch_cells[i * 2], section.batch_cells[i * 2 + 1])
			check(far_of(source_cell) == far_cell, "far %s: its batches come from cells inside it" % far_cell)

	# A second build is byte-identical, whether the files exist or are rebuilt from nothing.
	var before := snapshot(dir)
	var second: Dictionary = build.build_cells(dir, CELL, CELLS, objects)
	check(second.ok and second.written.is_empty() and second.unchanged.size() == before.size(), "an unchanged build rewrites nothing")
	remove_tree(dir.path_join("cells"))
	remove_tree(dir.path_join("far"))
	var fresh: Dictionary = build.build_cells(dir, CELL, CELLS, objects)
	check(fresh.ok and snapshot(dir) == before, "a rebuild from nothing is byte-identical")

	# stale_cells: empty after a build, then exactly what changed.
	check((build.stale_cells(dir, CELL, objects) as Array).is_empty(), "nothing is stale after a build")
	test_impostor_batches(dir, points)
	var extra_rocks: Array = []
	for i in 5:
		extra_rocks.append(make_point("rocks", ROCK, Vector2i(1, 0)))
	sets.apply(dir, CELL, [], columns(extra_rocks))
	var stale: Array = build.stale_cells(dir, CELL, objects)
	check(stale_set(stale) == {"cell (1, 0) sets": true, "far (0, 0) sets": true}, "a set write makes its cell and far cell stale (%s)" % [stale])
	var rebuilt: Dictionary = build.build_cells(dir, CELL, stale, objects)
	check(rebuilt.ok and (build.stale_cells(dir, CELL, objects) as Array).is_empty(), "building the stale entries leaves nothing stale")

	var changed := objects.duplicate(true)
	changed[ROCK].batch_size = 16.0
	stale = build.stale_cells(dir, CELL, changed)
	var expected_stale := {}
	for cell: Vector2i in CELLS:
		var directory: Dictionary = cells_reader.read_directory(cell_file(dir, cell))
		if directory.objects.has(ROCK):
			expected_stale["cell %s objects" % cell] = true
			expected_stale["far %s objects" % far_of(cell)] = true
	check(not expected_stale.is_empty() and stale_set(stale) == expected_stale, "a descriptor change makes the cells that use it stale, and their far cells (%s)" % [stale])
	build.build_cells(dir, CELL, stale, changed)
	check((build.stale_cells(dir, CELL, changed) as Array).is_empty(), "nothing is stale after rebuilding for the new descriptor")

	# A cell with set files but no built file, and a built file whose sets are gone.
	sets.apply(dir, CELL, [], columns([make_point("lonely", GRASS, Vector2i(7, 7))]))
	stale = build.stale_cells(dir, CELL, changed)
	check(stale_set(stale) == {"cell (7, 7) missing": true}, "a cell with sets and no built file is stale (%s)" % [stale])
	build.build_cells(dir, CELL, stale, changed)
	sets.remove_set(dir, "lonely")
	stale = build.stale_cells(dir, CELL, changed)
	check(stale_set(stale) == {"cell (7, 7) orphan": true}, "a built file whose sets are gone is stale (%s)" % [stale])
	var orphan: Dictionary = build.build_cells(dir, CELL, stale, changed)
	check(orphan.deleted == PackedStringArray(["cells/7_7.copiacell"]) and not FileAccess.file_exists(cell_file(dir, Vector2i(7, 7))), "building an orphan deletes it")
	# Impostors switched off: the far cells become orphans and their rebuild deletes them.
	var no_impostors := changed.duplicate(true)
	no_impostors[TREE].impostor = false
	build.build_cells(dir, CELL, CELLS, no_impostors)
	stale = build.stale_cells(dir, CELL, no_impostors)
	check(stale.size() == far_expected.size() and stale.all(func(e: Dictionary) -> bool: return e.kind == "far" and e.reason == "orphan"), "far cells without impostors are stale (%s)" % [stale])
	build.build_cells(dir, CELL, stale, no_impostors)
	check(DirAccess.get_files_at(dir.path_join("far")).is_empty() and (build.stale_cells(dir, CELL, no_impostors) as Array).is_empty(), "building them deletes the far cells")

	# Index files: rebuilt when missing; a set file replaced outside Copia is found with verify.
	var sets_index := dir.path_join("sets/index.copiaindex")
	var cells_index := dir.path_join("cells/index.copiaindex")
	var loaded: Resource = ResourceLoader.load(cells_index, "", ResourceLoader.CACHE_MODE_IGNORE)
	check(loaded != null and loaded.kind == "index" and loaded.counts.get("files") == CELLS.size(), "the cells index loads as a CopiaFile of kind index")
	DirAccess.remove_absolute(sets_index)
	DirAccess.remove_absolute(cells_index)
	check((build.stale_cells(dir, CELL, no_impostors) as Array).is_empty() and FileAccess.file_exists(sets_index) and FileAccess.file_exists(cells_index), "missing indexes are rebuilt from the headers")
	var rocks_file := dir.path_join("sets/rocks/1_0.copiaset")
	var old_bytes := FileAccess.get_file_as_bytes(rocks_file)
	sets.apply(dir, CELL, [], columns([make_point("rocks", ROCK, Vector2i(1, 0))]))
	build.build_cells(dir, CELL, [Vector2i(1, 0)], no_impostors)
	var replaced := FileAccess.open(rocks_file, FileAccess.WRITE)
	replaced.store_buffer(old_bytes)
	replaced.close()
	check((build.stale_cells(dir, CELL, no_impostors) as Array).is_empty(), "without verify the index still holds the replaced file's old entry")
	stale = build.stale_cells(dir, CELL, no_impostors, true)
	check(stale_set(stale) == {"cell (1, 0) sets": true}, "verify finds the replaced set file (%s)" % [stale])
	build.build_cells(dir, CELL, stale, no_impostors)
	check((build.stale_cells(dir, CELL, no_impostors) as Array).is_empty(), "building after verify leaves nothing stale")
	var reindexed: Dictionary = build.reindex(dir)
	check(reindexed.ok and reindexed.files == CELLS.size() and (sets.reindex(dir) as Dictionary).ok, "reindex rebuilds both indexes (%s)" % [reindexed])

	remove_tree(scratch)
	var elapsed := Time.get_ticks_msec() - started
	if failures.is_empty():
		print("COPIA_BUILD_TEST PASS (%d ms)" % elapsed)
		quit(0)
	else:
		print("COPIA_BUILD_TEST FAIL: %d failures (%d ms)" % [failures.size(), elapsed])
		var shown := {}
		for failure in failures:
			if not shown.has(failure):
				shown[failure] = true
				print("  - ", failure)
		quit(1)
