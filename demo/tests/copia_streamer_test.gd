## CopiaStreamer equivalence: the store's native streaming decision gives, after every update of
## a scripted run, the same loaded sections with the same quality (group density, range scale and
## creation priority) as the GDScript decision the store used before it, which this file keeps as
## the reference (the class Reference below, copied from the store and stripped of server calls).
## The run: one source moving along a line, then three sources with different range scales,
## densities, collider flags and priorities crossing each other, a source appearing, settings
## changing, sources disappearing, the default source coming back, and a set written and removed
## (cells rebuilt, directories read again, sections of an object that left a cell freed), then the
## only source with colliders disabled (colliders go, drawing stays), every source disabled
## (everything unloads), a source back, and the node hidden and shown again. Every
## step moves sources by more than the store's movement_threshold, waits until the store has
## settled, then compares. Also checks that an update with nothing moved evaluates nothing and
## that the first one after a change does.
## Headless: the renderer is a dummy, so only bookkeeping is asserted. Objects are created in code
## and saved under a scratch directory in user://, which is deleted afterwards.
##
##   godot-4.7.2 --path demo --headless --script res://tests/copia_streamer_test.gd
##
## Prints COPIA_STREAMER_TEST PASS or FAIL and exits 0 or 1. Run time: about 15 s.
extends SceneTree

const EXTENSION := "res://addons/copia/bin/copia.gdextension"
const ObjectScript := preload("res://addons/copia/copia_object.gd")
const RenderScript := preload("res://addons/copia/copia_render_settings.gd")
const PhysicsScript := preload("res://addons/copia/copia_physics_settings.gd")
const StoreScript := preload("res://addons/copia/copia_store_3d.gd")
const SourceScript := preload("res://addons/copia/copia_source_3d.gd")
const CELL := 64.0
const FAR := 128.0
const GRID := Vector2i(10, 5)  # cells 0..9 x 0..4

var failures: Array[String] = []
var scratch := "user://copia_streamer_test_%d" % OS.get_process_id()
var data := ""
var paths := PackedStringArray()
var rng := RandomNumberGenerator.new()
var steps := 0
var compared_records := 0
var max_records := 0


## The streaming decision of CopiaStore3D as it was in GDScript, before the native core: the
## records pass (free or requalify every live section), the directory requests and the load
## passes over the cached directories. Sections load at once; directories are read when
## [method deliver] is called, as the store's worker reads arrive between its updates.
##
## One rule differs from the GDScript decision: a record is freed unless some source needs it.
## The three removal tests of [method _update_records] were [code]reach < threshold[/code]
## (collider: [code]reach < unscaled[/code]; draw: [code]info.draw_reach < scaled[/code]; impostor:
## [code]info.impostor_reach < scaled[/code]) and are now [code]not (reach >= threshold)[/code]. A
## threshold over no counting source is NaN, and every comparison with NaN is false, so the old
## form kept such a record forever (no source at all, or no source with colliders left) and the
## new one frees it. With at least one counting source the threshold is finite and both forms
## agree.
class Reference extends RefCounted:
	var cell_size := 64.0
	var impostor_cell_size := 128.0
	var load_margin := 16.0
	var unload_margin := 32.0
	var collider_distance := 50.0
	var data_directory := ""
	var _cells_known := {}
	var _far_known := {}
	var _cell_dirs := {}  # cell -> {path -> {instance_count, collider_count}}
	var _far_dirs := {}
	var _pending := {}  # [is_far, cell] -> true, requested and not delivered
	var _live := {}  # cell -> {path -> {kind -> record}}
	var _far_live := {}  # far cell -> {path -> record}
	var _objects := {}  # path -> info, or null
	var _paths := {}
	var _max_draw_range := INF
	var _max_collider_range := INF
	var _max_impostor_range := INF
	var _source_count := 0
	var _source_points := PackedVector2Array()
	var _source_scales := PackedFloat64Array()
	var _source_densities := PackedFloat64Array()
	var _source_colliders := PackedByteArray()
	var _source_priorities := PackedFloat64Array()

	func scan() -> void:
		_cells_known.clear()
		_far_known.clear()
		for entry in ClassDB.class_call_static("CopiaCells", "list_cells", data_directory):
			(_far_known if entry.kind == "far" else _cells_known)[entry.cell] = true
			for path in entry.objects:
				_paths[path] = true
		for path in ClassDB.class_call_static("CopiaSets", "list_objects", data_directory):
			_paths[path] = true
		_compute_ranges()

	func _cell_file(is_far: bool, cell: Vector2i) -> String:
		return data_directory.path_join("far" if is_far else "cells").path_join("%d_%d.copiacell" % [cell.x, cell.y])

	func _info(path: String) -> Variant:
		if _objects.has(path):
			return _objects[path]
		var object = ObjectScript.resolve(path)
		if object == null:
			_objects[path] = null
			return null
		var render = object.render if object.render != null else RenderScript.new()
		var physics = object.physics
		var info := {
			"object": object,
			"draw_reach": render.visibility_range_end if render.visibility_range_end > 0.0 else INF,
			"impostor_reach": render.impostor_range_end if render.impostor_range_end > 0.0 else INF,
			"has_impostor": object.impostor_mesh != null,
			"has_physics": physics != null and physics.has_collider(),
			"physics_distance": physics.distance if physics != null else 0.0,
		}
		_objects[path] = info
		return info

	func _collider_reach(info: Dictionary) -> float:
		if info.physics_distance > 0.0:
			return info.physics_distance
		if collider_distance > 0.0:
			return collider_distance
		return info.draw_reach

	func _compute_ranges() -> void:
		_max_draw_range = 0.0
		_max_collider_range = 0.0
		_max_impostor_range = 0.0
		var any := false
		for path in _paths:
			var info = _info(path)
			if info == null:
				continue
			any = true
			_max_draw_range = maxf(_max_draw_range, info.draw_reach)
			if info.has_physics:
				_max_collider_range = maxf(_max_collider_range, _collider_reach(info))
			if info.has_impostor:
				_max_impostor_range = maxf(_max_impostor_range, info.impostor_reach)
		if not any:
			_max_draw_range = INF
			_max_collider_range = INF
			_max_impostor_range = INF

	## The sources the store gathered at its last update.
	func take_sources(store: Node) -> void:
		_source_count = store._source_count
		_source_points = store._source_points.duplicate()
		_source_scales = store._source_scales.duplicate()
		_source_densities = store._source_densities.duplicate()
		_source_colliders = store._source_colliders.duplicate()
		_source_priorities = store._source_priorities.duplicate()

	## Updates until no directory is requested, delivering the requested ones in between.
	func update_until_settled() -> void:
		while true:
			update()
			if _pending.is_empty():
				return
			deliver()

	func update() -> void:
		_update_records()
		_request_directories()
		_load_cells()
		_load_far()

	func deliver() -> void:
		for request in _pending.keys():
			_read_directory_now(request[0], request[1])
		_pending.clear()

	func _read_directory_now(is_far: bool, cell: Vector2i) -> void:
		var directory: Dictionary = ClassDB.class_call_static("CopiaCells", "read_directory", _cell_file(is_far, cell))
		var objects := {}
		if directory.get("ok", false):
			for path in directory.objects:
				objects[path] = {"instance_count": directory.objects[path].instance_count, "collider_count": directory.objects[path].collider_count}
				if not _paths.has(path):
					_paths[path] = true
					_objects.erase(path)
					_compute_ranges()
		(_far_dirs if is_far else _cell_dirs)[cell] = objects
		# Groups of objects the cell no longer has go now (_on_directory).
		for record in _records_of(is_far, cell):
			var entry: Dictionary = objects.get(record.path, {})
			var count: int = entry.get("collider_count" if record.kind == "collider" else "instance_count", 0)
			if count == 0:
				_unload(record)

	## A build wrote or deleted these cells (_apply_build_result and _invalidate).
	func rebuilt(result: Dictionary) -> void:
		for list_name in ["written", "deleted"]:
			var deleted: bool = list_name == "deleted"
			for relative in result.get(list_name, PackedStringArray()):
				var is_far: bool = relative.begins_with("far/")
				if not is_far and not relative.begins_with("cells/"):
					continue
				var parts: PackedStringArray = relative.get_file().trim_suffix(".copiacell").split("_")
				var cell := Vector2i(parts[0].to_int(), parts[1].to_int())
				var known := _far_known if is_far else _cells_known
				if deleted:
					known.erase(cell)
				else:
					known[cell] = true
				var dirs := _far_dirs if is_far else _cell_dirs
				var had := dirs.has(cell)
				dirs.erase(cell)
				_pending.erase([is_far, cell])
				var live := _far_live if is_far else _live
				if deleted:
					for record in _records_of(is_far, cell):
						_unload(record)
				elif had or live.has(cell):
					_pending[[is_far, cell]] = true
		deliver()

	static func _rect_distance(point: Vector2, cell: Vector2i, size: float) -> float:
		var low := Vector2(cell) * size
		var dx := maxf(maxf(low.x - point.x, 0.0), point.x - (low.x + size))
		var dz := maxf(maxf(low.y - point.y, 0.0), point.y - (low.y + size))
		return sqrt(dx * dx + dz * dz)

	static func _cells_in_reach(cells: Dictionary, point: Vector2, size: float, reach: float) -> Array:
		if is_inf(reach):
			return cells.keys()
		var low := Vector2i(floori((point.x - reach) / size), floori((point.y - reach) / size))
		var high := Vector2i(floori((point.x + reach) / size), floori((point.y + reach) / size))
		var result := []
		if (high.x - low.x + 1) * (high.y - low.y + 1) > cells.size():
			for cell in cells:
				if _rect_distance(point, cell, size) <= reach:
					result.append(cell)
			return result
		for x in range(low.x, high.x + 1):
			for z in range(low.y, high.y + 1):
				var cell := Vector2i(x, z)
				if cells.has(cell) and _rect_distance(point, cell, size) <= reach:
					result.append(cell)
		return result

	func _source_reach(s: int) -> float:
		var reach := _max_draw_range * _source_scales[s]
		if _source_colliders[s] != 0:
			reach = maxf(reach, _max_collider_range)
		return reach

	func _distances(cell: Vector2i, size: float) -> PackedFloat64Array:
		var result := PackedFloat64Array()
		result.resize(_source_count)
		for s in _source_count:
			result[s] = _rect_distance(_source_points[s], cell, size)
		return result

	func _threshold(distances: PackedFloat64Array, margin: float, colliders: bool) -> float:
		var result := NAN
		for s in _source_count:
			if colliders:
				if _source_colliders[s] != 0:
					result = minf(result, distances[s] - margin)
			else:
				result = minf(result, (distances[s] - margin) / _source_scales[s])
		return result

	func _source_thresholds(distances: PackedFloat64Array, margin: float, colliders: bool) -> PackedFloat64Array:
		var result := PackedFloat64Array()
		result.resize(_source_count)
		for s in _source_count:
			if colliders:
				result[s] = distances[s] - margin if _source_colliders[s] != 0 else NAN
			else:
				result[s] = (distances[s] - margin) / _source_scales[s]
		return result

	func _qualify(record: Dictionary, reach: float, distances: PackedFloat64Array, margin: float) -> void:
		var collider: bool = record.kind == "collider"
		if _source_count == 1:
			record.density = 1.0 if collider else _source_densities[0]
			record.range_scale = 1.0 if collider else _source_scales[0]
			record.priority = distances[0] / _source_priorities[0]
			return
		var best_density := 0.0
		var best_scale := 0.0
		var best_priority := INF
		for s in _source_count:
			if collider:
				if _source_colliders[s] == 0 or distances[s] - margin > reach:
					continue
			elif (distances[s] - margin) / _source_scales[s] > reach:
				continue
			best_density = maxf(best_density, _source_densities[s])
			best_scale = maxf(best_scale, _source_scales[s])
			best_priority = minf(best_priority, distances[s] / _source_priorities[s])
		if is_inf(best_priority):
			return
		record.density = 1.0 if collider else best_density
		record.range_scale = 1.0 if collider else best_scale
		record.priority = best_priority

	func _update_records() -> void:
		var single := _source_count == 1
		var single_density: float = _source_densities[0] if single else 1.0
		var single_scale: float = _source_scales[0] if single else 1.0
		for cell in _live.keys():
			var distances := _distances(cell, cell_size)
			var scaled := _threshold(distances, unload_margin, false)
			var unscaled := _threshold(distances, unload_margin, true)
			var priority: float = distances[0] / _source_priorities[0] if single else 0.0
			var each := PackedFloat64Array() if single else _source_thresholds(distances, unload_margin, false)
			var each_collider := PackedFloat64Array() if single else _source_thresholds(distances, unload_margin, true)
			var per_path: Dictionary = _live[cell]
			for path in per_path.keys():
				var info = _objects.get(path)
				var per_kind: Dictionary = per_path[path]
				for kind in per_kind.keys():
					var record: Dictionary = per_kind[kind]
					if info == null:
						_unload(record)
					elif kind == "collider":
						var reach := _collider_reach(info)
						if not (reach >= unscaled):
							_unload(record)
						elif single:
							record.priority = priority
						else:
							_requalify(record, reach, distances, each_collider)
					elif not (info.draw_reach >= scaled):
						_unload(record)
					elif single and record.density == single_density and record.range_scale == single_scale:
						record.priority = priority
					else:
						_requalify(record, info.draw_reach, distances, each)
		for cell in _far_live.keys():
			var distances := _distances(cell, impostor_cell_size)
			var scaled := _threshold(distances, unload_margin, false)
			var priority: float = distances[0] / _source_priorities[0] if single else 0.0
			var each := PackedFloat64Array() if single else _source_thresholds(distances, unload_margin, false)
			for path in _far_live[cell].keys():
				var record: Dictionary = _far_live[cell][path]
				var info = _objects.get(path)
				if info == null or not info.has_impostor or not (info.impostor_reach >= scaled):
					_unload(record)
				elif single and record.density == single_density and record.range_scale == single_scale:
					record.priority = priority
				else:
					_requalify(record, info.impostor_reach, distances, each)

	func _requalify(record: Dictionary, reach: float, distances: PackedFloat64Array, thresholds: PackedFloat64Array) -> void:
		if thresholds.is_empty():
			_qualify(record, reach, distances, unload_margin)
			return
		var best_density := 0.0
		var best_scale := 0.0
		var best_priority := INF
		for s in _source_count:
			if reach >= thresholds[s]:
				best_density = maxf(best_density, _source_densities[s])
				best_scale = maxf(best_scale, _source_scales[s])
				best_priority = minf(best_priority, distances[s] / _source_priorities[s])
		record.priority = best_priority
		if record.kind == "collider":
			return
		record.density = best_density
		record.range_scale = best_scale

	func _request_directories() -> void:
		for s in _source_count:
			var reach := _source_reach(s) + load_margin
			for cell in _cells_in_reach(_cells_known, _source_points[s], cell_size, reach):
				if not _cell_dirs.has(cell) and not _pending.has([false, cell]):
					_pending[[false, cell]] = true
		if _far_known.is_empty() or _max_impostor_range <= 0.0:
			return
		for s in _source_count:
			var reach := _max_impostor_range * _source_scales[s] + load_margin
			for cell in _cells_in_reach(_far_known, _source_points[s], impostor_cell_size, reach):
				if not _far_dirs.has(cell) and not _pending.has([true, cell]):
					_pending[[true, cell]] = true

	func _cells_near_sources(cells: Dictionary, size: float, is_far: bool) -> Array:
		if _source_count == 1:
			var reach := (_max_impostor_range * _source_scales[0] if is_far else _source_reach(0)) + load_margin
			return _cells_in_reach(cells, _source_points[0], size, reach)
		var found := {}
		for s in _source_count:
			var reach := (_max_impostor_range * _source_scales[s] if is_far else _source_reach(s)) + load_margin
			for cell in _cells_in_reach(cells, _source_points[s], size, reach):
				found[cell] = true
		return found.keys()

	func _load_cells() -> void:
		if _source_count == 0:
			return
		for cell in _cells_near_sources(_cell_dirs, cell_size, false):
			var entries: Dictionary = _cell_dirs[cell]
			var distances := _distances(cell, cell_size)
			var scaled := _threshold(distances, load_margin, false)
			var unscaled := _threshold(distances, load_margin, true)
			for path in entries:
				var info = _info(path)
				if info == null:
					continue
				var entry: Dictionary = entries[path]
				if entry.instance_count > 0 and info.object.mesh != null and info.draw_reach >= scaled:
					_want(false, cell, path, "draw", info.draw_reach, distances)
				if entry.collider_count > 0 and info.has_physics:
					var reach := _collider_reach(info)
					if reach >= unscaled:
						_want(false, cell, path, "collider", reach, distances)

	func _load_far() -> void:
		if _far_dirs.is_empty() or _source_count == 0:
			return
		for cell in _cells_near_sources(_far_dirs, impostor_cell_size, true):
			var entries: Dictionary = _far_dirs[cell]
			var distances := _distances(cell, impostor_cell_size)
			var scaled := _threshold(distances, load_margin, false)
			for path in entries:
				var info = _info(path)
				if info == null or not info.has_impostor or entries[path].instance_count == 0:
					continue
				if info.impostor_reach >= scaled:
					_want(true, cell, path, "impostor", info.impostor_reach, distances)

	func _want(is_far: bool, cell: Vector2i, path: String, kind: String, reach: float, distances: PackedFloat64Array) -> void:
		var exists: bool
		if is_far:
			exists = _far_live.has(cell) and _far_live[cell].has(path)
		else:
			exists = _live.has(cell) and _live[cell].has(path) and _live[cell][path].has(kind)
		if exists:
			return
		var record := {"kind": kind, "cell": cell, "path": path, "density": 1.0, "range_scale": 1.0, "priority": 0.0}
		if is_far:
			_far_live.get_or_add(cell, {})[path] = record
		else:
			_live.get_or_add(cell, {}).get_or_add(path, {})[kind] = record
		_qualify(record, reach, distances, maxf(load_margin, unload_margin))

	func _records_of(is_far: bool, cell: Vector2i) -> Array:
		var result := []
		if is_far:
			result.append_array(_far_live.get(cell, {}).values())
		else:
			for per_kind in _live.get(cell, {}).values():
				result.append_array(per_kind.values())
		return result

	func _unload(record: Dictionary) -> void:
		if record.kind == "impostor":
			var per_path: Dictionary = _far_live.get(record.cell, {})
			per_path.erase(record.path)
			if per_path.is_empty():
				_far_live.erase(record.cell)
		else:
			var per_path: Dictionary = _live.get(record.cell, {})
			var per_kind: Dictionary = per_path.get(record.path, {})
			per_kind.erase(record.kind)
			if per_kind.is_empty():
				per_path.erase(record.path)
			if per_path.is_empty():
				_live.erase(record.cell)

	## {"kind|path|cell": [density, range_scale, priority]} of every live record.
	func state() -> Dictionary:
		var result := {}
		for cell in _live:
			for path in _live[cell]:
				for kind in _live[cell][path]:
					var record: Dictionary = _live[cell][path][kind]
					result["%s|%s|%s" % [kind, path, cell]] = [record.density, record.range_scale, record.priority if is_finite(record.priority) else 0.0]
		for cell in _far_live:
			for path in _far_live[cell]:
				var record: Dictionary = _far_live[cell][path]
				result["impostor|%s|%s" % [path, cell]] = [record.density, record.range_scale, record.priority if is_finite(record.priority) else 0.0]
		return result


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


## Six objects: grass (multimesh, 40 m, shadow range), bush (instance, 90 m), tree (instance,
## 60 m, impostor to 200 m), rock (multimesh, 50 m, collider at the store's distance), boulder
## (instance, 120 m, collider at 80 m), pine (instance, 150 m, impostor to 400 m).
func make_objects() -> void:
	DirAccess.make_dir_recursive_absolute(scratch.path_join("objects"))
	var specs := [
		{"name": "grass", "multimesh": true, "range": 40.0, "shadow": 30.0},
		{"name": "bush", "multimesh": false, "range": 90.0},
		{"name": "tree", "multimesh": false, "range": 60.0, "impostor": 200.0},
		{"name": "rock", "multimesh": true, "range": 50.0, "physics": 0.0},
		{"name": "boulder", "multimesh": false, "range": 120.0, "physics": 80.0},
		{"name": "pine", "multimesh": false, "range": 150.0, "impostor": 400.0},
	]
	for spec in specs:
		var object := ObjectScript.new()
		object.mesh = BoxMesh.new()
		object.render = RenderScript.new()
		if spec.multimesh:
			object.render.batch_size = 16.0
		else:
			object.render.draw_mode = RenderScript.DrawMode.INSTANCE
		object.render.visibility_range_end = spec.range
		object.render.shadow_range = spec.get("shadow", 0.0)
		if spec.has("impostor"):
			object.impostor_mesh = QuadMesh.new()
			object.render.impostor_range_end = spec.impostor
		if spec.has("physics"):
			object.physics = PhysicsScript.new()
			object.physics.distance = spec.physics
		var path := scratch.path_join("objects/%s.tres" % spec.name)
		check(ResourceSaver.save(object, path) == OK, "%s saved" % spec.name)
		paths.append(path)
	ObjectScript.clear_cache()


## Points in every cell of the grid for about 70 % of the objects (always grass), a few per
## object and cell.
func make_points() -> Dictionary:
	var transform := PackedFloat32Array()
	var object := PackedInt32Array()
	var keep := PackedFloat32Array()
	for cx in GRID.x:
		for cz in GRID.y:
			for o in paths.size():
				if o > 0 and rng.randf() > 0.7:
					continue
				for i in 4:
					var at := Vector3((cx + rng.randf_range(0.05, 0.95)) * CELL, 0.0, (cz + rng.randf_range(0.05, 0.95)) * CELL)
					transform.append_array(PackedFloat32Array([1, 0, 0, 0, 1, 0, 0, 0, 1, at.x, at.y, at.z]))
					object.append(o)
					keep.append(rng.randf())
	return {"transform": transform, "object": object, "keep": keep, "object_paths": paths}


func settle(node: Node3D, seconds := 10.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	var quiet_since := -1
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if node.get_stats().pending != 0 or not node.is_settled():
			quiet_since = -1
		elif quiet_since < 0:
			quiet_since = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - quiet_since >= 60:
			return true
	return false


func new_source(store: Node3D, position: Vector3, settings := {}) -> Node3D:
	var source: Node3D = SourceScript.new()
	for name in settings:
		source.set(name, settings[name])
	root.add_child(source)
	source.global_position = position
	source.store = source.get_path_to(store)
	return source


## The store's live records as Reference.state() gives them, after checking that each has a live
## group whose drawer density and range end follow the record.
func store_state(store: Node3D, label: String) -> Dictionary:
	var result := {}
	var drawer: Object = store.get_drawer()
	var add := func(record) -> void:
		var key := "%s|%s|%s" % [record.kind, record.path, record.cell]
		result[key] = [record.density, record.range_scale, store._record_priority(record)]
		if record.group == 0:
			check(false, "%s: %s has no group" % [label, key])
			return
		if record.kind == "collider":
			return
		var info: Dictionary = drawer.get_group_info(record.group)
		var object = ObjectScript.resolve(record.path)
		var end: float = object.render.impostor_range_end if record.kind == "impostor" else object.render.visibility_range_end
		if not is_equal_approx(info.get("density", -1.0), record.density) or not is_equal_approx(info.get("params", {}).get("visibility_end", -1.0), end * record.range_scale):
			check(false, "%s: %s drawer density %s and range end %s do not follow the record (%s, %s)" % [
					label, key, info.get("density"), info.get("params", {}).get("visibility_end"), record.density, end * record.range_scale])
	for cell in store._live:
		for path in store._live[cell]:
			for kind in store._live[cell][path]:
				add.call(store._live[cell][path][kind])
	for cell in store._far_live:
		for path in store._far_live[cell]:
			add.call(store._far_live[cell][path])
	return result


## Live records of the store by kind.
func count_kinds(store: Node3D) -> Dictionary:
	var result := {"draw": 0, "collider": 0, "impostor": 0}
	for handle in store._records:
		result[store._records[handle].kind] += 1
	return result


## Settles the store after the step's changes, runs the reference to its fixpoint with the
## sources the store gathered, and compares.
func step(store: Node3D, reference: Reference, label: String) -> void:
	steps += 1
	check(await settle(store), "%s: settled" % label)
	reference.take_sources(store)
	reference.update_until_settled()
	var expected := reference.state()
	var actual := store_state(store, label)
	compared_records += actual.size()
	max_records = maxi(max_records, actual.size())
	var keys := expected.keys()
	keys.sort()
	var actual_keys := actual.keys()
	actual_keys.sort()
	if keys != actual_keys:
		var missing := keys.filter(func(k): return not actual.has(k))
		var extra := actual_keys.filter(func(k): return not expected.has(k))
		check(false, "%s: loaded sections differ: %d expected, %d loaded; missing %s; extra %s" % [label, keys.size(), actual_keys.size(), missing.slice(0, 5), extra.slice(0, 5)])
		return
	for k in keys:
		if expected[k] != actual[k]:
			check(false, "%s: %s quality %s, expected %s" % [label, k, actual[k], expected[k]])
			return
	var groups := {}
	for info in store.get_loaded_groups():
		groups["%s|%s|%s" % [info.kind, info.object_path, info.cell]] = true
	check(groups.size() == actual.size(), "%s: get_loaded_groups lists each record once (%d groups, %d records)" % [label, groups.size(), actual.size()])


func run() -> void:
	if not ClassDB.class_exists("CopiaDrawer"):
		GDExtensionManager.load_extension(EXTENSION)
	if not ClassDB.class_exists("CopiaDrawer"):
		push_error("Copia is not available")
		quit(1)
		return
	var started := Time.get_ticks_msec()
	rng.seed = 11
	remove_tree(scratch)
	data = scratch.path_join("data")
	make_objects()
	var store: Node3D = StoreScript.new()
	store.data_directory = data
	store.cell_size = CELL
	store.impostor_cell_size = FAR
	store.update_interval = 0.02
	store.collider_distance = 50.0
	root.add_child(store)
	var report: Dictionary = store.write([], make_points())
	check(report.ok, "write: %s" % report.error)
	var reference := Reference.new()
	reference.data_directory = data
	reference.cell_size = CELL
	reference.impostor_cell_size = FAR
	reference.scan()

	# One source: the default one, along a line through the grid and back across it.
	var y := 0.0
	for i in 32:
		var at := Vector3(-120.0 + i * 27.0, y, 100.0 + 40.0 * sin(i * 0.4))
		store.update_streaming(at)
		await step(store, reference, "one source, step %d at %s" % [i, at])

	# An update with nothing moved evaluates nothing; a move beyond the threshold does.
	var streamer = store.get(&"_streamer")
	if streamer != null:
		var before: int = streamer.get_evaluation_count()
		store.update_streaming(store._last_position)
		store.update_streaming(store._last_position + Vector3(0.5, 0, 0))
		check(streamer.get_evaluation_count() == before, "updates with sources moved less than movement_threshold evaluate nothing (%d evaluations)" % (streamer.get_evaluation_count() - before))
		store.update_streaming(store._last_position + Vector3(1.5, 0, 0))
		check(streamer.get_evaluation_count() == before + 1, "an update after a move beyond movement_threshold evaluates")
		store.update_streaming(store._last_position)
		await step(store, reference, "one source, back after the small moves")

	# Three sources, the default one off: they cross each other.
	store.use_default_source = false
	var a := new_source(store, Vector3(-60, 0, 120), {})
	var b := new_source(store, Vector3(700, 0, 180), {"range_scale": 0.5, "density": 0.5, "colliders": false, "shadows": false, "priority": 2.0})
	var c := new_source(store, Vector3(320, 0, 30), {"range_scale": 1.5, "density": 0.75, "priority": 0.5})
	await step(store, reference, "three sources placed")
	for i in 24:
		a.global_position = Vector3(-60.0 + i * 33.0, 0, 120.0 + 3.0 * i)
		b.global_position = Vector3(700.0 - i * 31.0, 0, 180.0 - 4.0 * i)
		store.update_streaming_all()
		await step(store, reference, "three sources crossing, step %d" % i)

	# A fourth appears where the others crossed; settings change; sources disappear.
	var d := new_source(store, Vector3(330, 0, 160), {"range_scale": 0.8, "density": 0.3, "priority": 4.0})
	await step(store, reference, "a fourth source appears")
	c.range_scale = 0.6
	await step(store, reference, "a source's range scale changes")
	c.density = 1.0
	c.colliders = false
	await step(store, reference, "a source's density and colliders change")
	b.priority = 0.25
	d.range_scale = 2.0
	await step(store, reference, "priority and range scale change")
	a.enabled = false
	await step(store, reference, "a source is disabled")
	b.free()
	await step(store, reference, "a source is freed")
	a.enabled = true
	for i in 6:
		a.global_position = Vector3(400.0 - i * 45.0, 0, 250.0 - i * 30.0)
		d.global_position = Vector3(100.0 + i * 50.0, 0, 60.0 + i * 20.0)
		store.update_streaming_all()
		await step(store, reference, "two sources moving again, step %d" % i)

	# The default source comes back alongside them.
	store.use_default_source = true
	store.update_streaming(Vector3(500, 0, 200))
	await step(store, reference, "the default source comes back")

	# A set written into some cells and removed again: rebuilt cells are read again, the new
	# sections load, then the sections of the object that left are freed.
	var extra := {"transform": PackedFloat32Array(), "object": PackedInt32Array(), "object_paths": paths,
			"set": PackedInt32Array(), "set_names": PackedStringArray(["extra"])}
	for cell in [Vector2i(5, 2), Vector2i(6, 3), Vector2i(4, 1), Vector2i(7, 2)]:
		for o in [1, 3, 4]:
			var at := Vector3((cell.x + 0.5) * CELL, 0, (cell.y + 0.5) * CELL)
			extra.transform.append_array(PackedFloat32Array([1, 0, 0, 0, 1, 0, 0, 0, 1, at.x, 0, at.z]))
			extra.object.append(o)
			extra.set.append(0)
	report = store.write([], extra)
	check(report.ok, "write of the extra set: %s" % report.error)
	reference.rebuilt(report.build)
	await step(store, reference, "a set written near the sources")
	var removed: Dictionary = store.remove_set("extra")
	reference.rebuilt(removed.build)
	await step(store, reference, "the set removed")
	for i in 4:
		store.update_streaming(Vector3(500.0 - i * 120.0, 0, 200.0 - i * 30.0))
		a.global_position = Vector3(i * 150.0, 0, 50.0 + i * 40.0)
		await step(store, reference, "after the rebuilds, step %d" % i)

	# The only source that wants colliders is disabled: its collider sections go, the draw and
	# impostor sections the other sources need stay.
	store.use_default_source = false
	a.colliders = false
	a.global_position = Vector3(300, 0, 150)
	c.global_position = Vector3(330, 0, 170)
	d.global_position = Vector3(310, 0, 140)
	await step(store, reference, "one source with colliders left")
	var kinds := count_kinds(store)
	check(kinds.collider > 0 and kinds.draw > 0, "with one source with colliders, colliders and draw sections are loaded (%s)" % kinds)
	d.enabled = false
	await step(store, reference, "the only source with colliders disabled")
	kinds = count_kinds(store)
	check(kinds.collider == 0 and store.get_colliders().get_stats().groups == 0, "no collider section stays without a source with colliders (%s)" % kinds)
	check(kinds.draw > 0, "draw sections the other sources need stay (%s)" % kinds)

	# Every source disabled: everything unloads at the next update.
	a.enabled = false
	c.enabled = false
	store.update_streaming_all()
	await step(store, reference, "every source disabled")
	var stats: Dictionary = store.get_stats()
	check(stats.groups == 0 and stats.drawer.groups == 0 and stats.colliders.groups == 0 and store._records.is_empty(),
			"with no enabled source nothing stays loaded (%d groups, drawer %d, colliders %d, records %d)" % [stats.groups, stats.drawer.groups, stats.colliders.groups, store._records.size()])
	a.enabled = true
	await step(store, reference, "a source enabled again")
	check(store.get_stats().groups > 0, "a source enabled again loads its surroundings (%d groups)" % store.get_stats().groups)

	# Hiding unloads everything; showing streams the same sections again.
	store.visible = false
	check(await settle(store), "settled hidden")
	check(store.get_stats().groups == 0 and store.get_drawer().get_stats().groups == 0, "hidden: nothing loaded (%d groups)" % store.get_stats().groups)
	store.visible = true
	store.update_streaming_all()
	await step(store, reference, "shown again")
	check(store.get_stats().groups > 0, "shown: the sections stream again (%d groups)" % store.get_stats().groups)

	a.free()
	c.free()
	d.free()
	store.free()
	ObjectScript.clear_cache()
	PhysicsScript.clear_cache()
	remove_tree(scratch)
	print("COPIA_STREAMER_TEST compared %d steps, %d records in all, up to %d per step" % [steps, compared_records, max_records])
	if failures.is_empty():
		print("COPIA_STREAMER_TEST PASS (%d ms)" % (Time.get_ticks_msec() - started))
		quit(0)
	else:
		print("COPIA_STREAMER_TEST FAIL (%d failures)" % failures.size())
		for failure in failures.slice(0, 30):
			print("  " + failure)
		quit(1)
