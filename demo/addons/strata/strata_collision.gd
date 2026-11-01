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
## Tracking never leaves a target without ground: when more distinct target chunks than
## this exist, the budget is raised to that count for planning (one warning).
@export_range(1, 4096, 1) var max_resident_chunks := 64:
	set(value):
		if value < 1 or value > 4096: return
		max_resident_chunks = value
		_signature = {}
## Optional gameplay focus (player, vehicle); not the camera. It behaves as one more entry
## of [member track_targets]. A target's chunk change triggers one re-plan: the chunks
## within `track_radius` of the target become the resident set (replacing it), built
## synchronously on that physics tick; standing still costs one lookup per tick. When the
## radius needs more than `max_resident_chunks`, the chunks farthest from the target are
## left out (and the farthest resident ones released); the chunk under the target is
## always resident.
@export var track_target: NodePath:
	set(value):
		track_target = value
		_signature = {}
		_update_processing()
## Every actor that needs ground (players, vehicles, NPC hubs), as paths relative to this
## node. Invalid or off-tree paths are skipped and duplicates tracked once. The wanted set
## is the union over all targets (this array, [member track_target] and
## [member track_group]) of the chunks within `track_radius` of each; the shared
## `max_resident_chunks` budget keeps the chunks nearest to ANY target, and every
## target's own chunk is always resident. A target off the terrain is tracked at the
## nearest terrain point.
@export var track_targets: Array[NodePath] = []:
	set(value):
		track_targets = value
		_signature = {}
		_update_processing()
## Scene group whose Node3D members are tracked as well, so spawned actors only need
## `add_to_group()`. The group is re-scanned when its node count changes (checked every
## tick) and in any case every 30 ticks, which also catches one member replaced by another
## in the same interval.
@export var track_group: StringName = &"":
	set(value):
		track_group = value
		_group_nodes.clear()
		_group_count = -1
		_signature = {}
		_update_processing()
@export var track_radius := 96.0:
	set(value):
		if not is_finite(value) or value < 0: return
		track_radius = value
		_signature = {}
## Seconds of travel to plan ahead: a target's planning point is its position plus its
## velocity times this. The velocity is `velocity` of a CharacterBody3D, `linear_velocity` of a
## RigidBody3D, otherwise the position change between ticks over real time. The target's
## actual chunk stays resident too. 0 (default) plans around the position only.
@export_range(0.0, 10.0, 0.01, "or_greater") var look_ahead := 0.0:
	set(value):
		if not is_finite(value) or value < 0: return
		look_ahead = value
		_signature = {}

## With a StrataTerrain3D parent and no [member data] of its own, the node uses the parent's
## bake and follows it: every new bake rebuilds the resident chunks in place. The terrain's
## "Add collision" button relies on this.
@export var follow_terrain := true
## Without a track target, prepare the whole terrain on ready when it fits
## [member max_resident_chunks]; a larger terrain warns once and waits for a target or an
## explicit prepare_region().
@export var auto_prepare := true
var _terrain: Node3D
var _auto_warned := false
var _chunks: Dictionary = {}
var _suppress_clear := false
## Per tracked node (instance id): Vector4i(chunk, planning chunk) of the last successful re-plan.
var _signature: Dictionary = {}
var _group_nodes: Array[Node3D] = []
var _group_count := -1
var _group_ticks := 0
## Per node (instance id): [last world position, last msec, velocity], for plain nodes.
var _motion: Dictionary = {}
var _target_count := 0
var _track_warned := false
var _budget_warned := false
var _stats := {"builds": 0, "heightmap_builds": 0, "concave_builds": 0, "last_build_ms": 0.0, "last_prepare_ms": 0.0, "rejections": 0, "evictions": 0}

func _ready() -> void:
	_bind_terrain()
	_update_processing()
	# Deferred, so a script that prepares regions or sets a target right after adding the node wins.
	_auto_prepare.call_deferred()

func _bind_terrain() -> void:
	var parent := get_parent() as Node3D
	if not follow_terrain or parent == null or not parent.has_signal(&"runtime_data_changed"): return
	_terrain = parent
	if data == null: data = parent.get("runtime_data")
	if not parent.is_connected(&"runtime_data_changed", _on_terrain_bake): parent.connect(&"runtime_data_changed", _on_terrain_bake)

func _on_terrain_bake() -> void:
	if not is_instance_valid(_terrain) or _terrain.get("runtime_data") == null: return
	if data == null or _chunks.is_empty():
		data = _terrain.get("runtime_data")
	else:
		var swapped := replace_data(_terrain.get("runtime_data"))
		if not swapped.get("ok", false): push_warning("StrataCollision: the new bake could not replace the resident chunks: " + String(swapped.get("message", "")))
	_signature = {}
	_auto_prepare.call_deferred()

func _auto_prepare() -> void:
	if not auto_prepare or not is_inside_tree() or _has_track_sources() or data == null or not data.is_resident() or not _chunks.is_empty(): return
	var grid := get_chunk_grid()
	if grid.x * grid.y > max_resident_chunks:
		if not _auto_warned:
			_auto_warned = true
			push_warning("StrataCollision: the terrain needs %d chunks but max_resident_chunks is %d; set track_target / track_targets (the player) or call prepare_region() for the areas you need." % [grid.x * grid.y, max_resident_chunks])
		return
	var prepared := prepare_region(data.bounds)
	if not prepared.get("ok", false): push_warning("StrataCollision: automatic preparation failed: " + String(prepared.get("message", "")))

func _physics_process(_delta: float) -> void:
	tick()

func _has_track_sources() -> bool:
	return not track_target.is_empty() or not track_targets.is_empty() or track_group != &""

func _update_processing() -> void:
	if is_inside_tree(): set_physics_process(_has_track_sources())

## Tracked nodes, deduplicated: `track_target`, then `track_targets`, then the group. Paths
## that do not resolve to an in-tree Node3D are skipped.
func _collect_targets(rescan := true) -> Array[Node3D]:
	var result: Array[Node3D] = []
	var seen: Dictionary = {}
	var paths: Array[NodePath] = []
	if not track_target.is_empty(): paths.append(track_target)
	paths.append_array(track_targets)
	for path in paths:
		if path.is_empty(): continue
		var node := get_node_or_null(path) as Node3D
		if node != null and node.is_inside_tree() and not seen.has(node.get_instance_id()):
			seen[node.get_instance_id()] = true
			result.append(node)
	if track_group != &"" and is_inside_tree():
		if rescan: _refresh_group()
		for node in _group_nodes:
			if is_instance_valid(node) and node.is_inside_tree() and not seen.has(node.get_instance_id()):
				seen[node.get_instance_id()] = true
				result.append(node)
	return result

func _refresh_group() -> void:
	_group_ticks += 1
	var members := get_tree().get_nodes_in_group(track_group)
	var stale := members.size() != _group_count or _group_ticks >= 30
	if not stale:
		for node in _group_nodes:
			if not is_instance_valid(node):
				stale = true
				break
	if not stale: return
	_group_ticks = 0
	_group_count = members.size()
	_group_nodes.clear()
	for member in members:
		var node := member as Node3D
		if node != null: _group_nodes.append(node)

## World position a target is planned around (see `look_ahead`).
func _planning_point(node: Node3D) -> Vector3:
	var position := node.global_position
	var velocity := Vector3.ZERO
	if node is CharacterBody3D: velocity = (node as CharacterBody3D).velocity
	elif node is RigidBody3D: velocity = (node as RigidBody3D).linear_velocity
	else:
		var id := node.get_instance_id()
		var now := Time.get_ticks_msec()
		var last: Array = _motion.get(id, [])
		if last.is_empty():
			_motion[id] = [position, now, Vector3.ZERO]
		elif now > last[1]:
			velocity = (position - last[0]) / maxf((now - last[1]) / 1000.0, 0.001)
			_motion[id] = [position, now, velocity]
		else:
			velocity = last[2]
	return position + velocity * look_ahead

## One tracking step (called every physics frame; public so tests can drive it). Standing
## still costs one lookup per target.
func tick() -> void:
	if not _has_track_sources() or data == null or not data.is_resident():
		return
	var targets := _collect_targets()
	_target_count = targets.size()
	if targets.is_empty():
		return
	var plans: Array[Dictionary] = []
	var signature: Dictionary = {}
	for node in targets:
		var local := _world_to_local_xz(node.global_position)
		var chunk := chunk_at_local(local)
		if chunk == Vector2i(-1, -1):
			continue
		var planning := local
		var ahead := chunk
		if look_ahead > 0.0:
			planning = _world_to_local_xz(_planning_point(node))
			ahead = chunk_at_local(planning)
		signature[node.get_instance_id()] = Vector4i(chunk.x, chunk.y, ahead.x, ahead.y)
		# A target off the terrain is tracked at the nearest terrain point.
		var focus := Vector2(clampf(planning.x, data.bounds.position.x, data.bounds.end.x), clampf(planning.y, data.bounds.position.y, data.bounds.end.y))
		plans.append({"chunk": chunk, "focus": focus})
	if plans.is_empty() or _same_signature(signature):
		return
	var own: Dictionary = {}
	var wanted_set: Dictionary = {}
	for plan in plans:
		own[plan.chunk] = true
		wanted_set[plan.chunk] = true
		for key in chunks_in_local_rect(Rect2(plan.focus - Vector2.ONE * track_radius, Vector2.ONE * track_radius * 2.0)):
			wanted_set[key] = true
	var budget := max_resident_chunks
	if own.size() > budget:
		budget = own.size()
		if not _budget_warned:
			_budget_warned = true
			push_warning("Terrain collision tracking: %d targets stand on distinct chunks but max_resident_chunks is %d; planning with %d so no target loses its ground." % [own.size(), max_resident_chunks, budget])
	var wanted: Array[Vector2i] = []
	for key in wanted_set:
		wanted.append(key)
	if wanted.size() > budget:
		var distances: Dictionary = {}
		for key in wanted:
			var nearest := INF
			for plan in plans:
				nearest = minf(nearest, _chunk_distance(key, plan.chunk, plan.focus))
			distances[key] = nearest
		wanted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return distances[a] < distances[b])
		wanted.resize(budget)
	var result := _prepare_keys(wanted, false, budget)
	if result.ok:
		_signature = signature
		_track_warned = false
	elif not _track_warned:
		_track_warned = true
		push_warning("Terrain collision tracking: " + result.message)

func _same_signature(signature: Dictionary) -> bool:
	if signature.size() != _signature.size():
		return false
	for id in signature:
		if not _signature.has(id) or _signature[id] != signature[id]:
			return false
	return true

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

func _prepare_keys(wanted: Array[Vector2i], keep_existing: bool, budget := -1) -> Dictionary:
	if budget < 0: budget = max_resident_chunks
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
	if keys.size() > budget:
		return _reject("Region needs %d chunks, above max_resident_chunks %d" % [keys.size(), budget])
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
	_signature = {}
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
## The terrain's surface tag under a world position (StrataTerrain3D.runtime_surface_type()),
## for the body a ray or contact reported; empty without a terrain parent or a tag.
func surface_type_at(world_position: Vector3) -> StringName:
	var terrain: Node = _terrain if _terrain != null else get_parent()
	if terrain == null or not terrain.has_method(&"runtime_surface_type"): return &""
	return terrain.runtime_surface_type(world_position)

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
	stats.tracked = is_inside_tree() and not _collect_targets(false).is_empty()
	stats.targets = _target_count
	return stats
