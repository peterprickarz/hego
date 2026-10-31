class_name StrataNavigation
extends Node3D
## Bounded, tiled navigation for selected gameplay areas. Each tile bakes real
## Recast navigation through NavigationServer3D from terrain source triangles
## (the canonical (a, b, c), (b, d, c) split). Hole cells and the cells the
## profile blocks contribute no faces. Tiles bake padded source geometry and
## clip to their own rectangle (border_size + filter_baking_aabb), so
## agent-radius erosion is consistent across tile edges and adjacent regions
## connect on the shared map.
##
## Map requirement: Godot (4.4 through 4.7) merges region edges by flooring vertices to
## cell_size * merge_rasterizer_cell_scale. Recast emits terrain vertices closer
## than one 0.25 m cell (measured 0.04 m on the 1 m island), which the default
## scale 1.0 collapses into "already-merged edge" errors. Set
## navigation/3d/merge_rasterizer_cell_scale = 0.01 in the project (the engine
## clamps smaller values to 0.01), or call NavigationServer3D.map_set_merge_rasterizer_cell_scale()
## on the map you own. This node never changes the map. Opt-in diagnostics
## predict conflicts and warn with this remedy when any exist.
##
## Agent populations: the bake stores one static navigation profile per
## population (StrataNavProfiles, StrataRuntimeData.nav_profiles). The intended
## pattern is one StrataNavigation per population, all sharing the same data,
## each with its own `profile` and its own `navigation_layers` bit; agents then
## query with that population's layers (NavigationAgent3D.navigation_layers or
## NavigationServer3D.map_get_path(..., navigation_layers)). Each node bakes its
## own regions, so populations never see each other's walkable areas. Godot's
## map edge merge ignores layers, so two nodes baking the same profile and
## settings on one map duplicate every edge; give identical populations one node.

signal bake_finished(result: Dictionary)
## A tracked tile was published, replaced or released (never emitted by bake_region()).
signal tiles_changed

const _NO_TILE := Vector2i(-2147483648, -2147483648)

@export var data: StrataRuntimeData:
	set(value):
		data = value
		clear()
## Static navigation profile of the data to bake (StrataRuntimeData.nav_profiles;
## the default profile is the nav_exclusions mask). Changing it clears the
## resident tiles and cancels pending bakes, like tile_cells. A profile missing
## from the data makes bake_region() fail.
@export var profile: StringName = StrataRuntimeData.DEFAULT_NAV_PROFILE:
	set(value):
		if value != profile:
			profile = value
			clear()
## Cell intervals per tile side. tile_cells * spacing must be a multiple of the
## navigation cell size so voxel grids line up across tiles. Tile keys depend on
## it, so changing it clears the resident tiles and cancels pending bakes.
@export_range(8, 512, 1) var tile_cells := 64:
	set(value):
		if value < 1 or value > 512:
			push_warning("Terrain navigation tile_cells must be in 1..512; previous settings retained.")
			return
		if value != tile_cells:
			tile_cells = value
			clear()
## Agent and bake settings. A change does not touch published tiles; the next
## bake_region() rebakes every tile it keeps that was baked with other settings,
## so one map never mixes settings (see is_config_current()).
@export_range(0.05, 8.0, 0.01) var agent_radius := 0.5:
	set(value):
		if not is_finite(value) or value <= 0: return
		if value != agent_radius: agent_radius = value; _settings_changed()
@export_range(0.1, 8.0, 0.01) var agent_height := 1.8:
	set(value):
		if not is_finite(value) or value <= 0: return
		if value != agent_height: agent_height = value; _settings_changed()
@export_range(0.0, 8.0, 0.01) var agent_max_climb := 0.25:
	set(value):
		if not is_finite(value) or value < 0: return
		if value != agent_max_climb: agent_max_climb = value; _settings_changed()
@export_range(0.0, 89.0, 0.1) var agent_max_slope := 45.0:
	set(value):
		if not is_finite(value) or value < 0 or value >= 90: return
		if value != agent_max_slope: agent_max_slope = value; _settings_changed()
## Contour simplification in voxels. Godot recommends at most 1.0 for tiles
## baked with border_size, so tile borders stay aligned; larger is rejected.
@export_range(0.0, 1.0, 0.01) var edge_max_error := 1.0:
	set(value):
		if not is_finite(value) or value < 0 or value > 1: return
		if value != edge_max_error: edge_max_error = value; _settings_changed()
## Zero uses the navigation map's cell size/height (required to match for merging).
@export var cell_size := 0.0:
	set(value):
		if not is_finite(value) or value < 0: return
		if value != cell_size: cell_size = value; _settings_changed()
@export var cell_height := 0.0:
	set(value):
		if not is_finite(value) or value < 0: return
		if value != cell_height: cell_height = value; _settings_changed()
@export_flags_3d_navigation var navigation_layers := 1:
	set(value):
		navigation_layers = value
		for region in _tiles.values():
			if is_instance_valid(region): region.navigation_layers = value
@export_range(1, 1024, 1) var max_tiles := 64:
	set(value):
		if value < 1 or value > 1024: return
		if value != max_tiles: max_tiles = value; _settings_changed()
@export var use_async := true
## Predict Godot's map edge merge after each publication (see the class note).
@export var check_merge_conflicts := false
## Optional gameplay focus (player, vehicle, agent hub); not the camera. While set, the
## node keeps the tiles within `track_radius` of the target's TILE (so every point of
## the target's tile has the full radius around it) resident, baking tiles that enter
## and releasing tiles beyond `track_radius * 1.25`. It re-plans once per tile change
## in _physics_process; standing still costs one lookup per tick. Tracked tiles are
## baked per tile (asynchronously when use_async) and published as each arrives; a
## result for a tile that left the keep range or was evicted is dropped. When more
## than `max_tiles` would be needed, the tiles farthest from the target are never
## baked or are released first; the tile under the target is never evicted.
@export var track_target: NodePath:
	set(value):
		track_target = value
		_tracked_tile = _NO_TILE
		set_physics_process(not value.is_empty())
@export var track_radius := 96.0:
	set(value):
		if not is_finite(value) or value < 0: return
		track_radius = value
		_tracked_tile = _NO_TILE

var _tiles: Dictionary = {}
## Bake settings of the published tiles (see _bake_config()).
var _tiles_config: Dictionary = {}
var _generation := 0
var _pending: Dictionary = {}
var _stats := {"bakes": 0, "tiles_baked": 0, "last_bake_ms": 0.0, "last_source_faces": 0, "discarded_results": 0, "evictions": 0, "releases": 0, "replans": 0, "last_track_ms": 0.0}
## Tracking state: the tile the last re-plan was made for, in-flight tile bakes
## (key -> {epoch, mesh, config}), tiles known to have no walkable polygons, and the
## epoch that invalidates every in-flight tracked result (clear, settings change).
var _tracked_tile := _NO_TILE
var _track_pending: Dictionary = {}
var _track_empty: Dictionary = {}
var _track_epoch := 0
var _track_warned := false

func _ready() -> void:
	set_physics_process(not track_target.is_empty())

func _exit_tree() -> void:
	# Results of in-flight async bakes are discarded by generation.
	_generation += 1
	_pending.clear()
	_track_epoch += 1
	_track_pending.clear()
	_tracked_tile = _NO_TILE

func _physics_process(_delta: float) -> void:
	tick()

## Terrain-local XZ; this node is expected at identity under the terrain root.
func _world_to_local_xz(world_position: Vector3) -> Vector2:
	var local := global_transform.affine_inverse() * world_position
	return Vector2(local.x, local.z)

func tile_at_local(position: Vector2) -> Vector2i:
	if not position.is_finite() or data == null or get_tile_grid() == Vector2i.ZERO: return Vector2i(-1, -1)
	var lattice := data.local_to_lattice(position)
	var grid := get_tile_grid()
	return Vector2i(clampi(floori(lattice.x / tile_cells), 0, grid.x - 1), clampi(floori(lattice.y / tile_cells), 0, grid.y - 1))

## One tracking step (called every physics frame; public so tests can drive it). Does
## nothing but a lookup unless the target's tile changed since the last re-plan.
func tick() -> void:
	if track_target.is_empty() or data == null or not data.is_resident() or not is_inside_tree():
		return
	var target := get_node_or_null(track_target) as Node3D
	if target == null:
		return
	var local := _world_to_local_xz(target.global_position)
	var tile := tile_at_local(local)
	if tile == _tracked_tile or tile == Vector2i(-1, -1):
		return
	_replan_tracked(tile, local)

func _tile_center(key: Vector2i) -> Vector2:
	var cells := get_tile_cells(key)
	return data.lattice_to_local(Vector2(cells.position) + Vector2(cells.size) * 0.5)

func _replan_tracked(tile: Vector2i, local: Vector2) -> void:
	var started := Time.get_ticks_usec()
	var params := _bake_params()
	if not params.ok:
		if not _track_warned:
			push_warning("Terrain navigation tracking: " + params.message)
			_track_warned = true
		return
	_track_warned = false
	_tracked_tile = tile
	_stats.replans += 1
	var config: Dictionary = params.config
	if not _tiles.is_empty() and _tiles_config != config:
		# One map never mixes bake settings: tiles of older settings are rebaked.
		for key in _tiles.keys():
			_release_tile(key)
	var tile_cells_rect := get_tile_cells(tile)
	var core := Rect2(data.lattice_to_local(Vector2(tile_cells_rect.position)), Vector2(tile_cells_rect.size) * float(params.spacing))
	var keep_keys: Dictionary = {}
	for key in tiles_in_local_rect(core.grow(track_radius * 1.25)):
		keep_keys[key] = true
	for key in _tiles.keys():
		if not keep_keys.has(key):
			_release_tile(key)
	for key in _track_pending.keys():
		if not keep_keys.has(key):
			_track_pending.erase(key)
	for key in _track_empty.keys():
		if not keep_keys.has(key):
			_track_empty.erase(key)
	var missing: Array[Vector2i] = []
	for key in tiles_in_local_rect(core.grow(track_radius)):
		if not _tiles.has(key) and not _track_pending.has(key) and not _track_empty.has(key):
			missing.append(key)
	missing.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _tile_distance(a, tile, local) < _tile_distance(b, tile, local))
	for key in missing:
		if _tiles.size() + _track_pending.size() >= max_tiles and not _evict_farther_than(_tile_distance(key, tile, local), tile, local):
			break
		var job := _make_job(key, params)
		if job.is_empty():
			_track_empty[key] = true
		elif use_async:
			_track_pending[key] = {"epoch": _track_epoch, "mesh": job.mesh, "config": config}
			NavigationServer3D.bake_from_source_geometry_data_async(job.mesh, job.source, _track_completion(weakref(self), _track_epoch, key, job.mesh))
		else:
			NavigationServer3D.bake_from_source_geometry_data(job.mesh, job.source)
			_publish_tile(key, job.mesh, config)
	_stats.last_track_ms = (Time.get_ticks_usec() - started) / 1000.0

## Distance used for eviction order; the target's own tile sorts before everything.
func _tile_distance(key: Vector2i, target_tile: Vector2i, local: Vector2) -> float:
	return -1.0 if key == target_tile else _tile_center(key).distance_to(local)

## Evicts the farthest resident or pending tile when it is farther than `limit`;
## false when nothing qualifies (the target's tile never does).
func _evict_farther_than(limit: float, target_tile: Vector2i, local: Vector2) -> bool:
	var worst := _NO_TILE
	var worst_distance := limit
	for key in _tiles:
		var distance := _tile_distance(key, target_tile, local)
		if distance > worst_distance:
			worst = key
			worst_distance = distance
	for key in _track_pending:
		var distance := _tile_distance(key, target_tile, local)
		if distance > worst_distance:
			worst = key
			worst_distance = distance
	if worst == _NO_TILE:
		return false
	_stats.evictions += 1
	if _tiles.has(worst):
		_release_tile(worst, false)
	else:
		_track_pending.erase(worst)
	return true

func _release_tile(key: Vector2i, count := true) -> void:
	var region: NavigationRegion3D = _tiles.get(key)
	_tiles.erase(key)
	if region != null and is_instance_valid(region):
		region.free()
	if count:
		_stats.releases += 1
	tiles_changed.emit()

func _publish_tile(key: Vector2i, mesh: NavigationMesh, config: Dictionary) -> void:
	if _tiles.has(key):
		_tiles[key].free()
		_tiles.erase(key)
	_stats.tiles_baked += 1
	if mesh.get_polygon_count() == 0:
		_track_empty[key] = true
		tiles_changed.emit()
		return
	var region := NavigationRegion3D.new()
	region.name = "Tile_%d_%d" % [key.x, key.y]
	region.navigation_layers = navigation_layers
	region.navigation_mesh = mesh
	add_child(region)
	_tiles[key] = region
	_tiles_config = config
	tiles_changed.emit()

## Static so the callback never keeps a freed navigation node alive or calls it.
static func _track_completion(owner: WeakRef, epoch: int, key: Vector2i, mesh: NavigationMesh) -> Callable:
	return func() -> void:
		var node: Object = owner.get_ref()
		if node != null:
			node.call_deferred("_on_track_tile_baked", epoch, key, mesh)

func _on_track_tile_baked(epoch: int, key: Vector2i, mesh: NavigationMesh) -> void:
	var entry: Variant = _track_pending.get(key)
	if epoch != _track_epoch or entry == null or entry.mesh != mesh:
		_stats.discarded_results += 1
		return
	_track_pending.erase(key)
	_publish_tile(key, mesh, entry.config)

func is_transform_valid() -> bool:
	var basis := global_transform.basis
	return global_transform.is_finite() and basis.y.is_equal_approx(Vector3.UP) and is_equal_approx(basis.x.length(), 1.0) and is_equal_approx(basis.z.length(), 1.0) and is_equal_approx(basis.determinant(), 1.0)

func get_navigation_map() -> RID:
	return get_world_3d().navigation_map if is_inside_tree() else RID()

func get_tile_grid() -> Vector2i:
	if data == null or tile_cells < 1:
		return Vector2i.ZERO
	var cells := data.get_cell_resolution()
	if cells.x < 1 or cells.y < 1:
		return Vector2i.ZERO
	return Vector2i(ceili(float(cells.x) / tile_cells), ceili(float(cells.y) / tile_cells))

func get_tile_cells(key: Vector2i) -> Rect2i:
	var grid := get_tile_grid()
	if key.x < 0 or key.y < 0 or key.x >= grid.x or key.y >= grid.y: return Rect2i()
	var cells := data.get_cell_resolution()
	var start := key * tile_cells
	return Rect2i(start, Vector2i(mini(tile_cells, cells.x - start.x), mini(tile_cells, cells.y - start.y)))

func tiles_in_local_rect(rect: Rect2) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var grid := get_tile_grid()
	if grid == Vector2i.ZERO or not rect.position.is_finite() or not rect.size.is_finite() or not rect.end.is_finite() or rect.size.x < 0 or rect.size.y < 0 or not data.bounds.intersects(rect, true):
		return result
	var clipped := rect.intersection(data.bounds)
	var low := data.local_to_lattice(clipped.position) / tile_cells
	var high := data.local_to_lattice(clipped.end) / tile_cells
	# Half-open at the far edge: a rectangle ending on a boundary does not pull
	# in the next one; a degenerate rectangle still selects its own.
	var first := Vector2i(clampi(floori(low.x), 0, grid.x - 1), clampi(floori(low.y), 0, grid.y - 1))
	var last := Vector2i(clampi(maxi(ceili(high.x) - 1, first.x), 0, grid.x - 1), clampi(maxi(ceili(high.y) - 1, first.y), 0, grid.y - 1))
	for z in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			result.append(Vector2i(x, z))
	return result

## Bake the tiles overlapping `local_rect` and make them the resident set (or
## add to it with `keep_existing`). With use_async the result arrives through
## bake_finished; regions are published together only after every tile baked.
func bake_region(local_rect: Rect2, keep_existing := false) -> Dictionary:
	var plan := _plan(local_rect, keep_existing)
	if not plan.ok:
		return plan
	_generation += 1
	var generation := _generation
	_pending = {"generation": generation, "keys": plan.keys, "baked": {}, "remaining": plan.jobs.size(), "started": Time.get_ticks_usec(), "faces": plan.faces, "agent": plan.agent, "config": plan.config, "replace_all": plan.replace_all}
	_stats.bakes += 1
	if plan.jobs.is_empty():
		return _finish(generation)
	for job in plan.jobs:
		if use_async:
			NavigationServer3D.bake_from_source_geometry_data_async(job.mesh, job.source, _completion(weakref(self), generation, job.key, job.mesh))
		else:
			NavigationServer3D.bake_from_source_geometry_data(job.mesh, job.source)
			_pending.baked[job.key] = job.mesh
			_pending.remaining -= 1
	if not use_async:
		return _finish(generation)
	return {"ok": true, "pending": true, "generation": generation, "tiles": plan.jobs.size()}

## Static so the callback never keeps a freed navigation node alive or calls it.
static func _completion(owner: WeakRef, generation: int, key: Vector2i, mesh: NavigationMesh) -> Callable:
	return func() -> void:
		var node: Object = owner.get_ref()
		if node != null:
			node.call_deferred("_on_tile_baked", generation, key, mesh)

func _on_tile_baked(generation: int, key: Vector2i, mesh: NavigationMesh) -> void:
	if _pending.is_empty() or generation != _generation or _pending.generation != generation:
		_stats.discarded_results += 1
		return
	_pending.baked[key] = mesh
	_pending.remaining -= 1
	if _pending.remaining == 0:
		_finish(generation)

func _finish(generation: int) -> Dictionary:
	var state := _pending
	_pending = {}
	if not is_inside_tree() or state.config != _bake_config():
		var failed := {"ok": false, "message": "Navigation node or bake configuration changed before publication", "generation": generation}
		bake_finished.emit(failed)
		return failed
	var keep: Dictionary = state.keys
	for key in _tiles.keys():
		# replace_all: every kept tile was rebaked for new settings; one that
		# produced no faces must not survive with the old settings.
		if not keep.has(key) or state.baked.has(key) or state.replace_all:
			_tiles[key].free()
			_tiles.erase(key)
	var polygons := 0
	for key in state.baked:
		var mesh: NavigationMesh = state.baked[key]
		polygons += mesh.get_polygon_count()
		if mesh.get_polygon_count() == 0:
			continue
		var region := NavigationRegion3D.new()
		region.name = "Tile_%d_%d" % [key.x, key.y]
		region.navigation_layers = navigation_layers
		region.navigation_mesh = mesh
		add_child(region)
		_tiles[key] = region
	_tiles_config = state.config
	_stats.tiles_baked += state.baked.size()
	_stats.last_bake_ms = (Time.get_ticks_usec() - state.started) / 1000.0
	_stats.last_source_faces = state.faces
	var result := {"ok": true, "pending": false, "generation": generation, "tiles": state.baked.size(), "regions": _tiles.size(), "polygons": polygons, "agent": state.agent, "merge_rasterizer_cell_scale": NavigationServer3D.map_get_merge_rasterizer_cell_scale(get_navigation_map())}
	if check_merge_conflicts:
		result.merge_conflicts = predict_merge_conflicts()
		_stats.merge_conflicts = result.merge_conflicts
		if result.merge_conflicts.total > 0:
			push_warning("Terrain navigation: %d region edges collide in Godot's map edge merge at merge_rasterizer_cell_scale %s (%s); expect 'already-merged edge' errors. Set navigation/3d/merge_rasterizer_cell_scale = 0.01 or call NavigationServer3D.map_set_merge_rasterizer_cell_scale() on this map." % [result.merge_conflicts.total, result.merge_rasterizer_cell_scale, result.merge_conflicts])
	bake_finished.emit(result)
	return result

## Mirrors Godot's map edge merge (4.4 through 4.7): polygon vertices are floored to
## cell_size * merge_rasterizer_cell_scale (and cell_height * scale); an edge key
## shared by more than two published polygon edges cannot merge and makes the
## engine report an "already-merged edge" synchronization error.
func predict_merge_conflicts() -> Dictionary:
	var map := get_navigation_map()
	var result := {"total": 0, "intra_tile": 0, "cross_tile": 0, "edges": 0, "ms": 0.0}
	if not map.is_valid():
		return result
	var started := Time.get_ticks_usec()
	var scale := NavigationServer3D.map_get_merge_rasterizer_cell_scale(map)
	var size := NavigationServer3D.map_get_cell_size(map) * scale
	var height := NavigationServer3D.map_get_cell_height(map) * scale
	var uses: Dictionary = {}
	for region in _tiles.values():
		var mesh: NavigationMesh = region.navigation_mesh
		var transform: Transform3D = region.global_transform
		var vertices := mesh.get_vertices()
		var quantized: Array[Vector3i] = []
		quantized.resize(vertices.size())
		for index in range(vertices.size()):
			var world := transform * vertices[index]
			quantized[index] = Vector3i(floori(world.x / size), floori(world.y / height), floori(world.z / size))
		for polygon_index in range(mesh.get_polygon_count()):
			var polygon := mesh.get_polygon(polygon_index)
			for edge in range(polygon.size()):
				var p := quantized[polygon[edge]]
				var q := quantized[polygon[(edge + 1) % polygon.size()]]
				var key := [p, q] if p < q else [q, p]
				if not uses.has(key):
					uses[key] = []
				uses[key].append(region)
				result.edges += 1
	for key in uses:
		var owners: Array = uses[key]
		if owners.size() > 2:
			result.total += 1
			result["cross_tile" if owners.count(owners[0]) != owners.size() else "intra_tile"] += 1
	result.ms = (Time.get_ticks_usec() - started) / 1000.0
	return result

## False when agent/bake settings changed since the published tiles were baked.
func is_config_current() -> bool:
	return _tiles.is_empty() or _tiles_config == _bake_config()

func _settings_changed() -> void:
	_generation += 1
	_track_epoch += 1
	_track_pending.clear()
	_track_empty.clear()
	_tracked_tile = _NO_TILE
	if _pending.is_empty(): return
	var cancelled := int(_pending.generation)
	_pending = {}
	bake_finished.emit({"ok": false, "pending": false, "generation": cancelled, "message": "Navigation settings changed before publication; previous regions retained"})

func is_baking() -> bool:
	return not _pending.is_empty()

func clear() -> void:
	_generation += 1
	_track_epoch += 1
	_track_pending.clear()
	_track_empty.clear()
	_tracked_tile = _NO_TILE
	var cancelled := int(_pending.get("generation", -1))
	_pending = {}
	for region in _tiles.values():
		if is_instance_valid(region):
			region.free()
	_tiles.clear()
	_tiles_config = {}
	if cancelled >= 0:
		bake_finished.emit({"ok": false, "pending": false, "generation": cancelled, "message": "Navigation bake cleared before publication"})

func get_regions() -> Array[NavigationRegion3D]:
	var result: Array[NavigationRegion3D] = []
	for region in _tiles.values():
		result.append(region)
	return result

func get_stats() -> Dictionary:
	var stats := _stats.duplicate()
	stats.regions = _tiles.size()
	stats.resident_tiles = _tiles.size()
	stats.pending_tiles = _track_pending.size() + int(_pending.get("remaining", 0))
	stats.tracked = not track_target.is_empty() and is_inside_tree() and get_node_or_null(track_target) is Node3D
	stats.profile = profile
	return stats

func _resolved_cell_size() -> Vector2:
	var map := get_navigation_map()
	var size := cell_size if cell_size > 0.0 else NavigationServer3D.map_get_cell_size(map)
	var height := cell_height if cell_height > 0.0 else NavigationServer3D.map_get_cell_height(map)
	return Vector2(size, height)

## Everything that changes a tile's baked mesh, except the data itself.
func _bake_config() -> Dictionary:
	var cells := _resolved_cell_size()
	return {"profile": profile, "tile_cells": tile_cells, "agent_radius": agent_radius, "agent_height": agent_height, "agent_max_climb": agent_max_climb, "agent_max_slope": agent_max_slope, "edge_max_error": edge_max_error, "cell_size": cells.x, "cell_height": cells.y}

## Validates the settings and derives the voxel-rounded agent values shared by every
## tile of one bake; `ok` false carries the message.
func _bake_params() -> Dictionary:
	if data == null or not data.validate().ok or not data.is_resident():
		return _error("Navigation needs valid resident runtime terrain data")
	if not data.has_nav_profile(profile):
		return _error("Navigation profile %s is not in the runtime data (available: %s)" % [profile, ", ".join(data.get_nav_profile_names())])
	if tile_cells < 1 or max_tiles < 1:
		return _error("tile_cells (%d) and max_tiles (%d) must be at least 1" % [tile_cells, max_tiles])
	for setting in [agent_radius, agent_height, agent_max_climb, agent_max_slope, edge_max_error, cell_size, cell_height]:
		if not is_finite(setting) or setting < 0.0:
			return _error("Navigation agent and cell settings must be finite and nonnegative")
	if agent_radius <= 0.0 or agent_height <= 0.0 or agent_max_slope >= 90.0:
		return _error("agent_radius and agent_height must be positive and agent_max_slope below 90")
	if edge_max_error > 1.0:
		return _error("edge_max_error %s exceeds 1.0, the documented maximum for border_size tiles" % edge_max_error)
	if not is_inside_tree():
		return _error("Navigation must be inside the scene tree to use its world map")
	if not is_transform_valid():
		return _error("Terrain navigation supports translation and yaw with unit scale only")
	var cells := _resolved_cell_size()
	var spacing := data.get_spacing()
	if cells.x <= 0.0 or cells.y <= 0.0 or cells.x > spacing * 0.5:
		return _error("Navigation cell size %s must be positive and at most half the terrain spacing %s so masked cells cannot be filled" % [cells.x, spacing])
	var tile_span := tile_cells * spacing / cells.x
	if absf(tile_span - roundf(tile_span)) > 0.0001:
		return _error("tile_cells * spacing (%s) must be a multiple of the navigation cell size %s" % [tile_cells * spacing, cells.x])
	# Agent sizes in whole voxels, rounded as Recast does (height and radius up,
	# climb down), so the effective values are explicit instead of warnings.
	var radius := ceilf(agent_radius / cells.x - 0.0001) * cells.x
	var height := ceilf(agent_height / cells.y - 0.0001) * cells.y
	var climb := floorf(agent_max_climb / cells.y + 0.0001) * cells.y
	# Recast recommends erosion radius + 3 voxels of border.
	var border := radius + 3.0 * cells.x
	return {"ok": true, "cells": cells, "spacing": spacing, "config": _bake_config(), "pad": ceili(border / spacing) + 1, "border": border,
		"agent": {"radius": radius, "height": height, "max_climb": climb, "max_slope": agent_max_slope, "edge_max_error": edge_max_error, "cell_size": cells.x, "cell_height": cells.y, "border": border}}

## One tile's bake job ({key, mesh, source, faces}); empty when the tile has no faces.
func _make_job(key: Vector2i, params: Dictionary) -> Dictionary:
	var cells: Vector2 = params.cells
	var spacing: float = params.spacing
	var border: float = params.border
	var agent: Dictionary = params.agent
	var tile := get_tile_cells(key)
	var source_cells := tile.grow(int(params.pad)).intersection(Rect2i(Vector2i.ZERO, data.get_cell_resolution()))
	var faces := build_source_faces(source_cells)
	if faces.is_empty():
		return {}
	var source := NavigationMeshSourceGeometryData3D.new()
	source.add_faces(faces, Transform3D.IDENTITY)
	var mesh := NavigationMesh.new()
	mesh.cell_size = cells.x
	mesh.cell_height = cells.y
	mesh.agent_radius = agent.radius
	mesh.agent_height = agent.height
	mesh.agent_max_climb = agent.max_climb
	mesh.agent_max_slope = agent_max_slope
	mesh.edge_max_error = edge_max_error
	# Godot (4.4 through 4.7) trims border_size inward from the baking bounds, so the
	# bounds are the tile grown by the border: the padded geometry is
	# rasterized and the result is clipped exactly at the tile edge.
	mesh.border_size = border
	var start := data.lattice_to_local(Vector2(tile.position)) - Vector2.ONE * border
	var size := Vector2(tile.size) * spacing + Vector2.ONE * border * 2.0
	mesh.filter_baking_aabb = AABB(Vector3(start.x, data.height_min - float(agent.height) - 1.0, start.y), Vector3(size.x, data.height_max - data.height_min + float(agent.height) * 2.0 + 2.0, size.y))
	return {"key": key, "mesh": mesh, "source": source, "faces": faces.size() / 3}

func _plan(local_rect: Rect2, keep_existing: bool) -> Dictionary:
	var params := _bake_params()
	if not params.ok:
		return params
	var keys: Dictionary = {}
	for key in tiles_in_local_rect(local_rect):
		keys[key] = true
	if keys.is_empty():
		return _error("Requested navigation area does not overlap the terrain")
	var config: Dictionary = params.config
	var total := keys.duplicate()
	if keep_existing:
		for key in _tiles:
			total[key] = true
	if total.size() > max_tiles:
		return _error("Area needs %d navigation tiles, above max_tiles %d" % [total.size(), max_tiles])
	# Kept tiles baked with other settings are rebaked with this request.
	var replace_all := keep_existing and not _tiles.is_empty() and _tiles_config != config
	if replace_all:
		keys = total
	var jobs: Array = []
	var faces_total := 0
	for key in keys:
		var job := _make_job(key, params)
		if job.is_empty():
			continue
		faces_total += int(job.faces)
		jobs.append(job)
	var keep_keys := keys.duplicate()
	if keep_existing:
		for key in _tiles:
			keep_keys[key] = true
	return {"ok": true, "jobs": jobs, "keys": keep_keys, "faces": faces_total, "config": config, "replace_all": replace_all, "agent": params.agent}

## Terrain-local triangles for the cells in `cells` that are neither holes nor
## blocked for `profile`: two canonical final cell masks, checked per cell. No
## faces for a profile the data does not have.
func build_source_faces(cells: Rect2i) -> PackedVector3Array:
	var faces := PackedVector3Array()
	if not data.has_nav_profile(profile):
		return faces
	var cells_rect := cells.intersection(Rect2i(Vector2i.ZERO, data.get_cell_resolution()))
	if cells_rect.size.x < 1 or cells_rect.size.y < 1:
		return faces
	cells = cells_rect
	var width := cells.size.x + 1
	var heights := data.heights_window(cells)
	if heights.size() != width * (cells.size.y + 1):
		return faces
	# Masks absent from the manifest block nothing.
	var holes := PackedByteArray()
	if data.has_map(StrataRegions.MAP_HOLES):
		holes = data.cell_mask_window(StrataRegions.MAP_HOLES, cells)
	var exclusions := PackedByteArray()
	var exclusion_map := data.nav_profile_map(profile)
	if data.has_map(exclusion_map):
		exclusions = data.cell_mask_window(exclusion_map, cells)
	var origin := data.bounds.position
	var spacing := data.get_spacing()
	faces.resize(cells.size.x * cells.size.y * 6)
	var write := 0
	for lz in range(cells.size.y):
		var z0 := origin.y + (cells.position.y + lz) * spacing
		var z1 := origin.y + (cells.position.y + lz + 1) * spacing
		for lx in range(cells.size.x):
			var cell := lz * cells.size.x + lx
			if not holes.is_empty() and holes[cell] == StrataRuntimeData.MASK_SET or not exclusions.is_empty() and exclusions[cell] == StrataRuntimeData.MASK_SET:
				continue
			var x0 := origin.x + (cells.position.x + lx) * spacing
			var x1 := origin.x + (cells.position.x + lx + 1) * spacing
			var row := lz * width + lx
			var a := Vector3(x0, heights[row], z0)
			var b := Vector3(x1, heights[row + 1], z0)
			var c := Vector3(x0, heights[row + width], z1)
			var d := Vector3(x1, heights[row + width + 1], z1)
			faces[write] = a; faces[write + 1] = b; faces[write + 2] = c
			faces[write + 3] = b; faces[write + 4] = d; faces[write + 5] = c
			write += 6
	faces.resize(write)
	return faces

func _error(message: String) -> Dictionary:
	return {"ok": false, "message": message}
