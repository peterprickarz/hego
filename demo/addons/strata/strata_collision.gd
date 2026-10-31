class_name StrataCollision
extends Node3D
## Chunked static collision from compiled heights and the canonical hole mask
## only; camera, render LOD and material displacement never affect it.
##
## Ordinary chunks use HeightMapShape3D. A chunk containing any hole cell uses a
## ConcavePolygonShape3D with exactly the same (a, b, c), (b, d, c) triangles and
## the hole cells' triangles omitted. Heights are never lowered or set to NaN.
## Residency is explicit and bounded: nothing is built until prepare_region(),
## prepare_around() or a tracked target requests it.

signal chunks_changed

enum ChunkKind { HEIGHTMAP, CONCAVE, EMPTY }

@export var data: StrataRuntimeData:
	set(value):
		data = value
		if not _suppress_clear:
			clear()
## Cell intervals per chunk side; 128 gives 129 x 129 shared samples.
@export_range(4, 512, 1) var chunk_cells := 128:
	set(value):
		if value < 1 or value > 512:
			push_warning("Terrain collision chunk_cells must be in 1..512; previous configuration retained.")
			return
		if value != chunk_cells:
			chunk_cells = value
			clear()
@export_flags_3d_physics var collision_layer := 1:
	set(value):
		collision_layer = value
		for chunk in _chunks.values():
			if chunk.body != null: chunk.body.collision_layer = value
@export_flags_3d_physics var collision_mask := 1:
	set(value):
		collision_mask = value
		for chunk in _chunks.values():
			if chunk.body != null: chunk.body.collision_mask = value
@export var physics_material: PhysicsMaterial:
	set(value):
		physics_material = value
		for chunk in _chunks.values():
			if chunk.body != null: chunk.body.physics_material_override = value
## Upper bound on simultaneously resident chunks (64 = 1 km² at 1 m, 128 cells).
@export_range(1, 4096, 1) var max_resident_chunks := 64:
	set(value):
		if value < 1 or value > 4096: return
		max_resident_chunks = value
		_tracked_chunk = Vector2i(-2147483648, -2147483648)
## Optional gameplay focus (player, vehicle); not the camera. Its chunk change
## triggers one re-plan: the chunks within `track_radius` of the target become the
## resident set (replacing it), built synchronously on that physics tick; standing
## still costs one lookup per tick. When the radius needs more than
## `max_resident_chunks`, the chunks farthest from the target are left out (and the
## farthest resident ones released); the chunk under the target is always resident.
@export var track_target: NodePath:
	set(value):
		track_target = value
		_tracked_chunk = Vector2i(-2147483648, -2147483648)
		set_physics_process(not value.is_empty())
@export var track_radius := 96.0:
	set(value):
		if not is_finite(value) or value < 0: return
		track_radius = value
		_tracked_chunk = Vector2i(-2147483648, -2147483648)

var _chunks: Dictionary = {}
var _suppress_clear := false
var _tracked_chunk := Vector2i(-2147483648, -2147483648)
var _track_warned := false
var _stats := {"builds": 0, "heightmap_builds": 0, "concave_builds": 0, "last_build_ms": 0.0, "last_prepare_ms": 0.0, "rejections": 0, "evictions": 0}

func _ready() -> void:
	set_physics_process(not track_target.is_empty())

func _physics_process(_delta: float) -> void:
	tick()

## One tracking step (called every physics frame; public so tests can drive it).
func tick() -> void:
	if track_target.is_empty() or data == null or not data.is_resident():
		return
	var target := get_node_or_null(track_target) as Node3D
	if target == null:
		return
	var local := _world_to_local_xz(target.global_position)
	var chunk := chunk_at_local(local)
	if chunk == _tracked_chunk or chunk == Vector2i(-1, -1):
		return
	# A target off the terrain is tracked at the nearest terrain point.
	var focus := Vector2(clampf(local.x, data.bounds.position.x, data.bounds.end.x), clampf(local.y, data.bounds.position.y, data.bounds.end.y))
	var wanted := chunks_in_local_rect(Rect2(focus - Vector2.ONE * track_radius, Vector2.ONE * track_radius * 2.0))
	if wanted.size() > max_resident_chunks:
		wanted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _chunk_distance(a, chunk, focus) < _chunk_distance(b, chunk, focus))
		wanted.resize(max_resident_chunks)
	var result := _prepare_keys(wanted, false)
	if result.ok:
		_tracked_chunk = chunk
		_track_warned = false
	elif not _track_warned:
		_track_warned = true
		push_warning("Terrain collision tracking: " + result.message)

## Eviction order: the target's own chunk sorts before everything, then by centre distance.
func _chunk_distance(key: Vector2i, target_chunk: Vector2i, focus: Vector2) -> float:
	if key == target_chunk:
		return -1.0
	var cells := get_chunk_cells(key)
	return data.lattice_to_local(Vector2(cells.position) + Vector2(cells.size) * 0.5).distance_to(focus)

## Terrain-local XZ; this node is expected at identity under the terrain root.
func _world_to_local_xz(world_position: Vector3) -> Vector2:
	var local := global_transform.affine_inverse() * world_position
	return Vector2(local.x, local.z)

func is_transform_valid() -> bool:
	var basis := global_transform.basis
	return global_transform.is_finite() and basis.y.is_equal_approx(Vector3.UP) and is_equal_approx(basis.x.length(), 1.0) and is_equal_approx(basis.z.length(), 1.0) and is_equal_approx(basis.determinant(), 1.0)

func get_chunk_grid() -> Vector2i:
	if data == null or chunk_cells < 1:
		return Vector2i.ZERO
	var cells := data.get_cell_resolution()
	if cells.x < 1 or cells.y < 1:
		return Vector2i.ZERO
	return Vector2i(ceili(float(cells.x) / chunk_cells), ceili(float(cells.y) / chunk_cells))

## Cell rectangle covered by a chunk.
func get_chunk_cells(key: Vector2i) -> Rect2i:
	var grid := get_chunk_grid()
	if key.x < 0 or key.y < 0 or key.x >= grid.x or key.y >= grid.y: return Rect2i()
	var cells := data.get_cell_resolution()
	var start := key * chunk_cells
	return Rect2i(start, Vector2i(mini(chunk_cells, cells.x - start.x), mini(chunk_cells, cells.y - start.y)))

func chunk_at_local(position: Vector2) -> Vector2i:
	if not position.is_finite() or data == null or get_chunk_grid() == Vector2i.ZERO: return Vector2i(-1, -1)
	var lattice := data.local_to_lattice(position)
	var grid := get_chunk_grid()
	return Vector2i(clampi(floori(lattice.x / chunk_cells), 0, grid.x - 1), clampi(floori(lattice.y / chunk_cells), 0, grid.y - 1))

func chunks_in_local_rect(rect: Rect2) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var grid := get_chunk_grid()
	if grid == Vector2i.ZERO or not rect.position.is_finite() or not rect.size.is_finite() or not rect.end.is_finite() or rect.size.x < 0 or rect.size.y < 0:
		return result
	var clipped := rect.intersection(data.bounds)
	if clipped.size.x < 0.0 or clipped.size.y < 0.0 or not data.bounds.intersects(rect, true):
		return result
	var low := data.local_to_lattice(clipped.position) / chunk_cells
	var high := data.local_to_lattice(clipped.end) / chunk_cells
	# Half-open at the far edge: a rectangle ending on a boundary does not pull
	# in the next one; a degenerate rectangle still selects its own.
	var first := Vector2i(clampi(floori(low.x), 0, grid.x - 1), clampi(floori(low.y), 0, grid.y - 1))
	var last := Vector2i(clampi(maxi(ceili(high.x) - 1, first.x), 0, grid.x - 1), clampi(maxi(ceili(high.y) - 1, first.y), 0, grid.y - 1))
	for z in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			result.append(Vector2i(x, z))
	return result

## Make exactly the chunks overlapping `local_rect` resident (or add them when
## `keep_existing`). All new shapes are prepared before any change is published;
## on failure the previous chunk set stays untouched.
func prepare_region(local_rect: Rect2, keep_existing := false) -> Dictionary:
	if chunk_cells < 1 or max_resident_chunks < 1 or not local_rect.position.is_finite() or not local_rect.size.is_finite() or not local_rect.end.is_finite() or local_rect.size.x < 0 or local_rect.size.y < 0:
		return _reject("Collision requires positive chunk/budget settings and finite nonnegative request bounds")
	if data == null or not data.validate().ok or not data.is_resident():
		return _reject("Collision needs valid resident runtime terrain data")
	if not is_transform_valid():
		return _reject("Terrain collision supports translation and yaw with unit scale only")
	return _prepare_keys(chunks_in_local_rect(local_rect), keep_existing)

func _prepare_keys(wanted: Array[Vector2i], keep_existing: bool) -> Dictionary:
	if data == null or not data.validate().ok or not data.is_resident():
		return _reject("Collision needs valid resident runtime terrain data")
	if not is_transform_valid():
		return _reject("Terrain collision supports translation and yaw with unit scale only")
	if wanted.is_empty(): return _reject("Collision region does not overlap the terrain; previous residency retained")
	var keys: Dictionary = {}
	for key in wanted:
		keys[key] = true
	if keep_existing:
		for key in _chunks:
			keys[key] = true
	if keys.size() > max_resident_chunks:
		return _reject("Region needs %d chunks, above max_resident_chunks %d" % [keys.size(), max_resident_chunks])
	var started := Time.get_ticks_usec()
	var built: Dictionary = {}
	for key in keys:
		if not _chunks.has(key):
			var chunk := _build_chunk(key)
			if chunk.is_empty():
				for entry in built.values():
					if entry.body != null: entry.body.free()
				return _reject("Collision chunk %s could not be built" % key)
			built[key] = chunk
	_publish(keys, built)
	_stats.last_build_ms = (Time.get_ticks_usec() - started) / 1000.0
	_stats.last_prepare_ms = _stats.last_build_ms
	return {"ok": true, "built": built.size(), "resident": _chunks.size()}

## Square gameplay area around a world position (player, spawn point, NPC).
func prepare_around(world_position: Vector3, radius: float, keep_existing := false) -> Dictionary:
	if data == null or not world_position.is_finite() or not is_finite(radius) or radius < 0.0 or not is_transform_valid():
		return _reject("prepare_around needs data and a finite nonnegative radius")
	var center := _world_to_local_xz(world_position)
	return prepare_region(Rect2(center - Vector2.ONE * radius, Vector2.ONE * radius * 2.0), keep_existing)

## Swap to new runtime data (for example a fresh bake), rebuilding the same
## resident chunk keys before anything is published. On failure both the old
## data and its shapes stay in place.
func replace_data(next: StrataRuntimeData) -> Dictionary:
	if chunk_cells < 1 or max_resident_chunks < 1 or _chunks.size() > max_resident_chunks or not is_transform_valid():
		return _reject("Cannot replace collision data with invalid settings, transform, or residency budget")
	if next == null or not next.validate().ok or not next.is_resident():
		return _reject("Collision needs valid resident runtime terrain data")
	var previous := data
	var built: Dictionary = {}
	var keys: Dictionary = {}
	var resident: Array = _chunks.keys()
	var old_chunks := _chunks
	# Shapes are built from `next`; nothing is published until all succeed.
	_set_data_silently(next)
	var grid := get_chunk_grid()
	for key in resident:
		if key.x >= grid.x or key.y >= grid.y:
			continue
		var chunk := _build_chunk(key)
		if chunk.is_empty():
			for entry in built.values():
				if entry.body != null: entry.body.free()
			_set_data_silently(previous)
			return _reject("Collision chunk %s could not be rebuilt" % key)
		built[key] = chunk
		keys[key] = true
	for chunk in old_chunks.values():
		if chunk.body != null: chunk.body.free()
	_chunks = {}
	_publish(keys, built)
	return {"ok": true, "built": built.size(), "resident": _chunks.size(), "previous_revision": previous.bake_revision if previous != null else -1}

func rebuild() -> Dictionary:
	return replace_data(data)

func _set_data_silently(value: StrataRuntimeData) -> void:
	_suppress_clear = true
	data = value
	_suppress_clear = false

func release_region(local_rect: Rect2) -> void:
	var changed := false
	for key in chunks_in_local_rect(local_rect):
		if _chunks.has(key):
			var chunk: Dictionary = _chunks[key]
			if chunk.body != null: chunk.body.free()
			_chunks.erase(key)
			changed = true
	if changed:
		chunks_changed.emit()

func clear() -> void:
	var had := not _chunks.is_empty()
	for chunk in _chunks.values():
		if chunk.body != null and is_instance_valid(chunk.body):
			chunk.body.free()
	_chunks.clear()
	_tracked_chunk = Vector2i(-2147483648, -2147483648)
	if had:
		chunks_changed.emit()

func _publish(keys: Dictionary, built: Dictionary) -> void:
	for key in _chunks.keys():
		if not keys.has(key):
			var chunk: Dictionary = _chunks[key]
			if chunk.body != null: chunk.body.free()
			_chunks.erase(key)
			_stats.evictions += 1
	for key in built:
		var chunk: Dictionary = built[key]
		if chunk.body != null:
			add_child(chunk.body)
		_chunks[key] = chunk
	chunks_changed.emit()

func _reject(message: String) -> Dictionary:
	_stats.rejections += 1
	return {"ok": false, "message": message}

func _build_chunk(key: Vector2i) -> Dictionary:
	var cells := get_chunk_cells(key)
	if cells.size.x < 1 or cells.size.y < 1:
		return {}
	var has_hole := false
	var all_holes := false
	# One apron-free window of the hole map; a map absent from the manifest means no holes.
	var hole_bytes := PackedByteArray()
	if data.has_map(StrataRegions.MAP_HOLES):
		hole_bytes = data.cell_mask_window(StrataRegions.MAP_HOLES, cells)
		if hole_bytes.size() != cells.size.x * cells.size.y:
			return {}
		var masked := hole_bytes.count(StrataRuntimeData.MASK_SET)
		has_hole = masked > 0
		all_holes = masked == hole_bytes.size()
	_stats.builds += 1
	if all_holes:
		return {"kind": ChunkKind.EMPTY, "body": null, "cells": cells}
	var spacing := data.get_spacing()
	var center_lattice := Vector2(cells.position) + Vector2(cells.size) * 0.5
	var center := data.lattice_to_local(center_lattice)
	var shape: Shape3D
	var shape_transform := Transform3D.IDENTITY
	var kind := ChunkKind.HEIGHTMAP
	if has_hole:
		shape = _concave_shape(cells, center_lattice, spacing)
		kind = ChunkKind.CONCAVE
		_stats.concave_builds += 1
	else:
		shape = _heightmap_shape(cells, spacing)
		# HeightMapShape3D is centred on its sample grid and spaced 1 unit; a
		# uniform scale converts that to metres (heights were divided first).
		shape_transform.basis = Basis.from_scale(Vector3.ONE * spacing)
		_stats.heightmap_builds += 1
	if shape == null:
		return {}
	var body := StaticBody3D.new()
	body.name = "Chunk_%d_%d" % [key.x, key.y]
	body.collision_layer = collision_layer
	body.collision_mask = collision_mask
	body.physics_material_override = physics_material
	body.position = Vector3(center.x, 0.0, center.y)
	var collision_shape := CollisionShape3D.new()
	collision_shape.name = "Shape"
	collision_shape.shape = shape
	collision_shape.transform = shape_transform
	body.add_child(collision_shape)
	return {"kind": kind, "body": body, "cells": cells}

func _heightmap_shape(cells: Rect2i, spacing: float) -> HeightMapShape3D:
	var map := data.heights_window(cells)
	if map.size() != (cells.size.x + 1) * (cells.size.y + 1):
		return null
	if spacing != 1.0:
		var inverse := 1.0 / spacing
		for index in range(map.size()):
			map[index] *= inverse
	var shape := HeightMapShape3D.new()
	shape.map_width = cells.size.x + 1
	shape.map_depth = cells.size.y + 1
	shape.map_data = map
	return shape

## Faces relative to the chunk centre to keep float32 precision far from origin.
## The shape also carries a one-cell apron of the neighbours' solid cells (same
## canonical triangles, holes still omitted). Separately transformed shapes
## round a shared edge differently; measured at 37 degrees yaw, rays exactly on
## a heightmap/concave seam leaked through that ~1e-6 m crack. With the apron
## every such seam lies inside one shape, whose shared vertices are identical.
func _concave_shape(chunk_cells_rect: Rect2i, center_lattice: Vector2, spacing: float) -> ConcavePolygonShape3D:
	var cells := chunk_cells_rect.grow(1).intersection(Rect2i(Vector2i.ZERO, data.get_cell_resolution()))
	var width := cells.size.x + 1
	var heights := data.heights_window(cells)
	var holes := data.cell_mask_window(StrataRegions.MAP_HOLES, cells)
	if heights.size() != width * (cells.size.y + 1) or holes.size() != cells.size.x * cells.size.y:
		return null
	var faces := PackedVector3Array()
	var solid := cells.size.x * cells.size.y - holes.count(StrataRuntimeData.MASK_SET)
	faces.resize(solid * 6)
	var write := 0
	for lz in range(cells.size.y):
		var z0 := (cells.position.y + lz - center_lattice.y) * spacing
		var z1 := (cells.position.y + lz + 1 - center_lattice.y) * spacing
		for lx in range(cells.size.x):
			if holes[lz * cells.size.x + lx] == StrataRuntimeData.MASK_SET:
				continue
			var x0 := (cells.position.x + lx - center_lattice.x) * spacing
			var x1 := (cells.position.x + lx + 1 - center_lattice.x) * spacing
			var row := lz * width + lx
			var a := Vector3(x0, heights[row], z0)
			var b := Vector3(x1, heights[row + 1], z0)
			var c := Vector3(x0, heights[row + width], z1)
			var d := Vector3(x1, heights[row + width + 1], z1)
			faces[write] = a; faces[write + 1] = b; faces[write + 2] = c
			faces[write + 3] = b; faces[write + 4] = d; faces[write + 5] = c
			write += 6
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	return shape

func get_resident_chunks() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for key in _chunks:
		result.append(key)
	return result

func get_chunk_info(key: Vector2i) -> Dictionary:
	if not _chunks.has(key):
		return {}
	var chunk: Dictionary = _chunks[key]
	return {"kind": chunk.kind, "body": chunk.body, "cells": chunk.cells}

## Status of collision at a terrain-local XZ point, without a physics query.
func collision_status_at(position: Vector2) -> int:
	if data == null or not data.contains_local(position):
		return StrataRuntimeData.Status.OUTSIDE
	if not _chunks.has(chunk_at_local(position)):
		return StrataRuntimeData.Status.NOT_RESIDENT
	if data.is_hole_at(position):
		return StrataRuntimeData.Status.HOLE
	return StrataRuntimeData.Status.OK

func get_stats() -> Dictionary:
	var stats := _stats.duplicate()
	stats.resident = _chunks.size()
	stats.resident_chunks = _chunks.size()
	stats.pending = 0
	stats.tracked = not track_target.is_empty() and is_inside_tree() and get_node_or_null(track_target) is Node3D
	return stats
