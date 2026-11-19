## Copia core timing measurement (not a pass/fail test; prints numbers, asserts nothing).
##
## Synthetic store: 250 object paths, 64 m cells, about 22,000 points per cell. 50 dense
## ground-cover objects (16 m batches) take 85 % of the points; the other 200 are sparse rocks,
## shrubs and trees (64 m batches; 40 trees drawn as single instances with colliders and
## impostors on a 256 m far grid, 60 rocks with colliders). 60 % of the points carry colour and
## custom data, half carry a keep below 1. Measures:
## - apply of 2 million points into an empty store, a replacing write of the same points
##   (clears + points, nothing changes), and a replacing write of moved points;
## - build_cells of those cells, an unchanged rebuild (skipped) and the same forced;
## - about 40 million points applied in 2 million point chunks over a larger area, a full
##   build_cells, stale_cells (twice), an unchanged build_cells (skipped cells), the index readers
##   (CopiaCells.list_cells, CopiaSets.list_objects, stale_cells with verify, rebuilding both
##   indexes), and the disk size of sets, built files and indexes.
##
##   godot-4.7.2 --path demo --headless --script res://tests/copia_core_timing.gd [-- --chunks=20]
##
## Prints COPIA_TIMING lines and one COPIA_TIMING_SUMMARY line, deletes its scratch store, quits.
extends SceneTree

const EXTENSION := "res://addons/copia/bin/copia.gdextension"
const CELL := 64.0
const CHUNK_POINTS := 2_000_000
const TILE_CELLS := Vector2i(10, 9)  # 90 cells, about 22,000 points each
const DENSE := 50
const OBJECTS := 250
const TREES := 40
const ROCKS := 60

var sets: Object
var build: Object
var scratch := "user://copia_core_timing_%d" % OS.get_process_id()
var rng := RandomNumberGenerator.new()
var paths := PackedStringArray()
var descriptors := {}


func _initialize() -> void:
	call_deferred("run")


func remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for directory in DirAccess.get_directories_at(path):
		remove_tree(path.path_join(directory))
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)


func folder_size(path: String) -> Vector2i:  # bytes in MiB, file count
	var bytes := 0
	var files := 0
	if not DirAccess.dir_exists_absolute(path):
		return Vector2i.ZERO
	for directory in DirAccess.get_directories_at(path):
		var inner := folder_size(path.path_join(directory))
		bytes += inner.x << 20
		files += inner.y
	for file in DirAccess.get_files_at(path):
		var handle := FileAccess.open(path.path_join(file), FileAccess.READ)
		bytes += handle.get_length()
		files += 1
	return Vector2i(bytes >> 20, files)


func make_objects() -> void:
	for i in OBJECTS:
		var path: String
		var descriptor := {"mesh_aabb": AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 1, 1)), "batch_size": CELL}
		if i < DENSE:
			path = "res://objects/ground_cover_%02d.tres" % i
			descriptor.batch_size = 16.0
			descriptor.mesh_aabb = AABB(Vector3(-0.3, 0, -0.3), Vector3(0.6, 0.4, 0.6))
		elif i < DENSE + TREES:
			path = "res://objects/tree_%02d.tres" % (i - DENSE)
			descriptor.merge({"draw": "instance", "mesh_aabb": AABB(Vector3(-3, 0, -3), Vector3(6, 18, 6)), "collider": true, "collider_min_scale": 0.8, "impostor": true, "impostor_cell_size": 256.0, "impostor_min_scale": 0.7})
		elif i < DENSE + TREES + ROCKS:
			path = "res://objects/rock_%02d.tres" % (i - DENSE - TREES)
			descriptor.merge({"mesh_aabb": AABB(Vector3(-1, -0.5, -1), Vector3(2, 1.5, 2)), "collider": true, "collider_min_scale": 0.5})
		else:
			path = "res://objects/shrub_%03d.tres" % (i - DENSE - TREES - ROCKS)
		paths.append(path)
		descriptors[path] = descriptor


## One chunk of points over a TILE_CELLS area starting at the origin.
func make_chunk() -> Dictionary:
	var n := CHUNK_POINTS
	var transform := PackedFloat32Array()
	transform.resize(n * 12)
	var object := PackedInt32Array()
	object.resize(n)
	var set_index := PackedInt32Array()
	set_index.resize(n)
	var color := PackedFloat32Array()
	color.resize(n * 4)
	var custom := PackedFloat32Array()
	custom.resize(n * 4)
	var keep := PackedFloat32Array()
	keep.resize(n)
	var width := TILE_CELLS.x * CELL
	var depth := TILE_CELLS.y * CELL
	for i in n:
		var o: int
		var s: int
		if rng.randf() < 0.85:
			o = rng.randi() % DENSE
			s = 0
		else:
			o = DENSE + rng.randi() % (OBJECTS - DENSE)
			s = 2 if o < DENSE + TREES else 1
		object[i] = o
		set_index[i] = s
		var angle := rng.randf() * TAU
		var scale := rng.randf_range(0.5, 1.5)
		var c := cos(angle) * scale
		var si := sin(angle) * scale
		var t := i * 12
		transform[t] = c
		transform[t + 2] = -si
		transform[t + 4] = scale
		transform[t + 6] = si
		transform[t + 8] = c
		transform[t + 9] = rng.randf() * width
		transform[t + 10] = rng.randf() * 20.0
		transform[t + 11] = rng.randf() * depth
		var k := i * 4
		if rng.randf() < 0.6:
			color[k] = rng.randf()
			color[k + 1] = rng.randf()
			color[k + 2] = rng.randf()
			color[k + 3] = 1.0
			custom[k] = rng.randf()
			custom[k + 3] = rng.randf()
		else:
			color[k] = NAN
			custom[k] = NAN
		keep[i] = rng.randf() if i % 2 == 0 else 1.0
	return {"transform": transform, "object": object, "object_paths": paths, "set": set_index, "set_names": PackedStringArray(["ground", "rocks", "trees"]), "color": color, "custom": custom, "keep": keep}


func shift(points: Dictionary, offset: Vector3) -> void:
	var transform: PackedFloat32Array = points.transform
	for i in transform.size() / 12:
		transform[i * 12 + 9] += offset.x
		transform[i * 12 + 11] += offset.z
	points.transform = transform


## Moves every point vertically, so each changes but stays in its cell.
func lift(points: Dictionary, amount: float) -> void:
	var transform: PackedFloat32Array = points.transform
	for i in transform.size() / 12:
		transform[i * 12 + 10] += amount
	points.transform = transform


func tile_clears(origin_cell: Vector2i) -> Array:
	var clears: Array = []
	for set_name in ["ground", "rocks", "trees"]:
		for x in TILE_CELLS.x:
			for z in TILE_CELLS.y:
				clears.append({"set": set_name, "cell": origin_cell + Vector2i(x, z)})
	return clears


func report(name: String, points: int, usec: int, extra := "") -> void:
	var seconds := usec / 1e6
	print("COPIA_TIMING %s points=%d seconds=%.3f points_per_second=%.0f %s" % [name, points, seconds, points / max(seconds, 1e-9), extra])


func run() -> void:
	if not ClassDB.class_exists("CopiaSets"):
		GDExtensionManager.load_extension(EXTENSION)
	if not ClassDB.class_exists("CopiaSets"):
		push_error("Copia is not available")
		quit(1)
		return
	var chunks := 20
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--chunks="):
			chunks = int(argument.trim_prefix("--chunks="))
	sets = ClassDB.instantiate("CopiaSets")
	build = ClassDB.instantiate("CopiaBuild")
	rng.seed = 3
	remove_tree(scratch)
	make_objects()
	var generate_start := Time.get_ticks_usec()
	var points := make_chunk()
	print("COPIA_TIMING generate points=%d seconds=%.1f (GDScript, not part of Copia)" % [CHUNK_POINTS, (Time.get_ticks_usec() - generate_start) / 1e6])

	# 2 million points.
	var small := scratch.path_join("small")
	var start := Time.get_ticks_usec()
	var result: Dictionary = sets.apply(small, CELL, [], points)
	var usec := Time.get_ticks_usec() - start
	report("apply_empty", CHUNK_POINTS, usec, "written=%d cells=%d ok=%s" % [result.written.size(), result.cells.size(), result.ok])
	var cells: Array = result.cells
	start = Time.get_ticks_usec()
	result = sets.apply(small, CELL, tile_clears(Vector2i.ZERO), points)
	report("apply_replace_unchanged", CHUNK_POINTS, Time.get_ticks_usec() - start, "written=%d unchanged=%d ok=%s" % [result.written.size(), result.unchanged.size(), result.ok])
	lift(points, 0.01)
	start = Time.get_ticks_usec()
	result = sets.apply(small, CELL, tile_clears(Vector2i.ZERO), points)
	report("apply_replace_moved", CHUNK_POINTS, Time.get_ticks_usec() - start, "written=%d unchanged=%d ok=%s" % [result.written.size(), result.unchanged.size(), result.ok])
	lift(points, -0.01)
	start = Time.get_ticks_usec()
	result = build.build_cells(small, CELL, cells, descriptors)
	report("build_2m", result.instance_count, Time.get_ticks_usec() - start, "cells=%d far=%d written=%d threads=%d ok=%s %s" % [result.cell_count, result.far_count, result.written.size(), result.threads, result.ok, result.error])
	print("COPIA_TIMING build_2m_profile ", result.profile)
	start = Time.get_ticks_usec()
	result = build.build_cells(small, CELL, cells, descriptors)
	report("build_2m_unchanged", result.instance_count, Time.get_ticks_usec() - start, "unchanged=%d skipped=%d written=%d" % [result.unchanged.size(), result.skipped.size(), result.written.size()])
	start = Time.get_ticks_usec()
	result = build.build_cells(small, CELL, cells, descriptors, true)
	report("build_2m_unchanged_forced", result.instance_count, Time.get_ticks_usec() - start, "unchanged=%d skipped=%d written=%d" % [result.unchanged.size(), result.skipped.size(), result.written.size()])
	var small_sets := folder_size(small.path_join("sets"))
	var small_cells := folder_size(small.path_join("cells"))
	print("COPIA_TIMING disk_2m sets_mib=%d set_files=%d cells_mib=%d cell_files=%d" % [small_sets.x, small_sets.y, small_cells.x, small_cells.y])
	remove_tree(small)

	# About 40 million points: the chunk applied as tiles over a larger area.
	var large := scratch.path_join("large")
	var columns_per_row := 5
	var apply_usec := 0
	var all_cells := {}
	var placed := Vector3.ZERO
	for chunk in chunks:
		var tile := Vector2i(chunk % columns_per_row, chunk / columns_per_row)
		var target := Vector3(tile.x * TILE_CELLS.x * CELL, 0, tile.y * TILE_CELLS.y * CELL)
		shift(points, target - placed)
		placed = target
		start = Time.get_ticks_usec()
		result = sets.apply(large, CELL, [], points)
		apply_usec += Time.get_ticks_usec() - start
		for cell in result.cells:
			all_cells[cell] = true
		if not result.ok:
			print("COPIA_TIMING apply failed: ", result.error)
			break
	var total := chunks * CHUNK_POINTS
	report("apply_large_total", total, apply_usec, "chunks=%d cells=%d" % [chunks, all_cells.size()])
	points = {}
	start = Time.get_ticks_usec()
	result = build.build_cells(large, CELL, all_cells.keys(), descriptors)
	var build_usec := Time.get_ticks_usec() - start
	report("build_large", result.instance_count, build_usec, "cells=%d far=%d written=%d threads=%d ok=%s %s" % [result.cell_count, result.far_count, result.written.size(), result.threads, result.ok, result.error])
	print("COPIA_TIMING build_large_profile ", result.profile)
	start = Time.get_ticks_usec()
	var stale: Array = build.stale_cells(large, CELL, descriptors)
	report("stale_large", total, Time.get_ticks_usec() - start, "stale=%d" % stale.size())
	# Again: the files are no longer freshly written (on Windows the first open of a new file
	# can include an antivirus scan).
	start = Time.get_ticks_usec()
	stale = build.stale_cells(large, CELL, descriptors)
	report("stale_large_repeat", total, Time.get_ticks_usec() - start, "stale=%d" % stale.size())
	start = Time.get_ticks_usec()
	result = build.build_cells(large, CELL, all_cells.keys(), descriptors)
	report("build_large_unchanged", result.instance_count, Time.get_ticks_usec() - start, "unchanged=%d skipped=%d written=%d" % [result.unchanged.size(), result.skipped.size(), result.written.size()])
	# The index files: the run-time listing, the object list, a verified comparison (every header
	# read again) and rebuilding both indexes from the headers.
	var cells_class: Object = ClassDB.instantiate("CopiaCells")
	start = Time.get_ticks_usec()
	var listed: Array = cells_class.list_cells(large)
	report("list_cells_large", total, Time.get_ticks_usec() - start, "files=%d" % listed.size())
	start = Time.get_ticks_usec()
	var object_list: PackedStringArray = sets.list_objects(large)
	report("list_objects_large", total, Time.get_ticks_usec() - start, "objects=%d" % object_list.size())
	start = Time.get_ticks_usec()
	stale = build.stale_cells(large, CELL, descriptors, true)
	report("stale_large_verify", total, Time.get_ticks_usec() - start, "stale=%d" % stale.size())
	start = Time.get_ticks_usec()
	var reindexed: Dictionary = sets.reindex(large)
	var reindexed_cells: Dictionary = build.reindex(large)
	report("reindex_large", total, Time.get_ticks_usec() - start, "set_files=%d cell_files=%d ok=%s" % [reindexed.files, reindexed_cells.files, reindexed.ok and reindexed_cells.ok])
	var index_bytes := 0
	for index_path in [large.path_join("sets/index.copiaindex"), large.path_join("cells/index.copiaindex")]:
		var handle := FileAccess.open(index_path, FileAccess.READ)
		index_bytes += handle.get_length() if handle != null else 0
	print("COPIA_TIMING index_size kib=%d" % (index_bytes >> 10))
	var large_sets := folder_size(large.path_join("sets"))
	var large_cells := folder_size(large.path_join("cells"))
	var large_far := folder_size(large.path_join("far"))
	print("COPIA_TIMING disk_large sets_mib=%d set_files=%d cells_mib=%d cell_files=%d far_mib=%d far_files=%d" % [large_sets.x, large_sets.y, large_cells.x, large_cells.y, large_far.x, large_far.y])
	print("COPIA_TIMING_SUMMARY points=%d apply_seconds=%.2f build_seconds=%.2f threads=%d godot_static_peak_mib=%d" % [total, apply_usec / 1e6, build_usec / 1e6, result.threads, OS.get_static_memory_peak_usage() >> 20])
	remove_tree(scratch)
	quit(0)
