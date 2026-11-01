class_name StrataRegionStreamer
extends Node
## Residency policy for a runtime terrain (docs/development/terrain_runtime.md, Phase B in
## docs/development/strata_regions_plan.md): decides, from the camera position, which regions
## the renderer holds in its near tier (level 0) and its far tier ([member far_level]), loads
## their files on threads and frees what the camera has left. Everything else is drawn from the
## coarse maps, so the whole terrain stays visible while GPU and CPU memory follow the camera.
##
## Loads follow the tier: the far tier requests [code]request_region(xy, far_level)[/code] (the
## partial lod file when the bake wrote one), the near tier level 0. A region promoted from far
## to near keeps its far binding until the full file arrives; a demoted one keeps its cached
## full data and is rebound at the far level without a reload. Leaving both tiers evicts it.
##
## The streamer never blocks the frame on I/O: bound data is only ever what
## [method StrataRuntimeData.poll_regions] has delivered (or an embedded region).
##
## [member renderer] is a direct reference to a StrataRenderer (typed Node so a recording stand-in
## works in tests); it must offer configure_runtime(source, data, materials, residency),
## set_region_level(xy, region, level) -> bool, release_region(xy) -> bool, free_slots(level) -> int.
## Typical use: add the node, assign [member renderer], [member data] and [member camera], call
## [method start]. The node updates itself every frame; [method update] is public for tests.

## The renderer (StrataRenderer or a duck-typed stand-in).
@export var renderer: Node
@export var data: StrataRuntimeData
@export var camera: Camera3D
## Tier radii in metres from the camera to the closest point of a region. 0 = automatic:
## 2.5 and 8 region extents.
@export var near_radius := 0.0
@export var far_radius := 0.0
## Region layers each tier may hold at once; the nearest regions win when more qualify.
@export var near_slots := 25
@export var far_slots := 256
## Mip level bound for the far tier; needs data.mip_levels > far_level, otherwise there is no far tier.
@export var far_level := 2
## New threaded loads started per update.
@export var loads_per_frame := 2
## A bound region is kept until it is this factor beyond its tier radius.
@export var hysteresis := 1.25
## Camera movement in metres that triggers a new update while no load or bind is outstanding.
## 0 = a quarter of a region extent.
@export var camera_step := 0.0

## Start on ready without a script: with a StrataTerrain3D parent (or a renderer whose parent is
## one) the terrain's bake and materials are used, every new bake restarts the stream, a
## missing [member renderer] is a StrataRenderer sibling and a missing [member camera] is the
## viewport's current camera. The terrain's "Add runtime renderer" button relies on this.
## Nothing starts in the editor or headless.
@export var auto_start := true
var _terrain: Node3D
var _materials: Array[StrataMaterial] = []

## Threaded loads in flight are capped at this many times loads_per_frame.
const IN_FLIGHT_FACTOR := 4

var _source: Node3D
var _started := false
var _bound: Dictionary = {}
var _last_point := Vector2(INF, INF)
var _busy := false
var _loads := 0
var _evictions := 0

## Configures the renderer for streaming (coarse maps only, empty tiers) and performs the first
## update at the camera. [param source] is the node whose local space is the terrain's.
func start(source: Node3D, materials: Array[StrataMaterial]) -> bool:
	stop()
	if renderer == null or data == null or source == null or not data.validate().get("ok", false): return false
	var far_slots_used := far_slots if _far_available() else 0
	if not renderer.configure_runtime(source, data, materials, {"near_slots": near_slots, "far_slots": far_slots_used, "far_level": far_level}):
		return false
	_source = source
	_started = true
	_busy = true
	if is_instance_valid(camera):
		if renderer.has_method("set_camera"): renderer.set_camera(camera)
		update(_camera_point())
	return true

## Forgets every binding and stops updating. The renderer keeps its coarse tier.
func stop() -> void:
	if _started and renderer != null:
		for xy: Vector2i in _bound: renderer.release_region(xy)
	_bound = {}
	_started = false
	_last_point = Vector2(INF, INF)

func is_started() -> bool:
	return _started

## {near, far, pending, cached, lod_loaded, full_loaded, near_slots, far_slots, loads, evictions}:
## regions bound per tier, threaded loads in flight, external regions held in the data cache
## (of which lod_loaded hold only the partial lod data and full_loaded every level), slot
## budgets and the totals of requested loads and evicted regions.
func stats() -> Dictionary:
	var near := 0
	for xy: Vector2i in _bound:
		if _bound[xy] == 0: near += 1
	var lod_loaded := 0
	var full_loaded := 0
	if data != null:
		for xy: Vector2i in data.cached_region_keys():
			if data.cached_first_level(xy) > 0: lod_loaded += 1
			else: full_loaded += 1
	return {"near": near, "far": _bound.size() - near, "pending": data.pending_count() if data != null else 0, "cached": lod_loaded + full_loaded, "lod_loaded": lod_loaded, "full_loaded": full_loaded, "near_slots": near_slots, "far_slots": far_slots if _far_available() else 0, "loads": _loads, "evictions": _evictions}

## Level a region is bound at (0 near, far_level far), -1 when it is in the coarse tier only.
func bound_level(xy: Vector2i) -> int:
	return _bound.get(xy, -1)

func _ready() -> void:
	if not auto_start or Engine.is_editor_hint() or DisplayServer.get_name() == "headless": return
	# Deferred, so a script that wires and starts the streamer right after adding it wins.
	_auto_start.call_deferred()

func _auto_start() -> void:
	if _started or not is_inside_tree(): return
	var source := _find_source()
	if source == null: return
	if _terrain != null:
		if data == null: data = _terrain.get("runtime_data")
		_materials.assign(_terrain.get("editor_materials"))
		if not _terrain.is_connected(&"runtime_data_changed", _on_terrain_bake): _terrain.connect(&"runtime_data_changed", _on_terrain_bake)
	if renderer == null:
		for child in source.get_children():
			if child is StrataRenderer: renderer = child; break
	if renderer == null or data == null: return
	if start(source, _materials):
		if _terrain != null: _terrain.call("set_preview_enabled", false)
	else:
		push_warning("StrataRegionStreamer: the renderer rejected the terrain's bake; nothing is drawn.")

## The node whose local space is the terrain's: a StrataTerrain3D parent, the renderer's
## StrataTerrain3D parent, or the renderer's Node3D parent.
func _find_source() -> Node3D:
	var parent := get_parent()
	if parent is Node3D and parent.has_signal(&"runtime_data_changed"):
		_terrain = parent
		return parent
	if renderer != null and renderer.get_parent() is Node3D:
		if renderer.get_parent().has_signal(&"runtime_data_changed"): _terrain = renderer.get_parent()
		return renderer.get_parent()
	return parent as Node3D

func _on_terrain_bake() -> void:
	if not is_instance_valid(_terrain) or renderer == null: return
	data = _terrain.get("runtime_data")
	var source: Node3D = _source if is_instance_valid(_source) else _terrain
	if data != null and not start(source, _materials): push_warning("StrataRegionStreamer: the renderer rejected the new bake.")

func _process(_delta: float) -> void:
	if not _started: return
	if not is_instance_valid(camera):
		camera = get_viewport().get_camera_3d()
		if camera == null: return
		if renderer.has_method("set_camera"): renderer.set_camera(camera)
	var point := _camera_point()
	var step := camera_step if camera_step > 0.0 else StrataRegions.extent(data.get_spec()) * 0.25
	if _busy or data.pending_count() > 0 or point.distance_to(_last_point) >= step: update(point)

func _camera_point() -> Vector2:
	var local := _source.to_local(camera.global_position)
	return Vector2(local.x, local.z)

func _far_available() -> bool:
	return data != null and far_slots > 0 and far_level > 0 and data.mip_levels > far_level

## One residency step for a camera at [param point] (terrain-local XZ).
func update(point: Vector2) -> void:
	if not _started: return
	_last_point = point
	data.poll_regions()
	var spec := data.get_spec()
	var extent := StrataRegions.extent(spec)
	var radius_near := near_radius if near_radius > 0.0 else 2.5 * extent
	var radius_far := far_radius if far_radius > 0.0 else 8.0 * extent
	var far_on := _far_available()
	var grid := data.grid
	var near_candidates: Array = []
	var far_candidates: Array = []
	for y in range(grid.y):
		for x in range(grid.x):
			var xy := Vector2i(x, y)
			var distance := _distance(point, StrataRegions.region_bounds(spec, xy))
			var current: int = _bound.get(xy, -1)
			if distance <= radius_near * (hysteresis if current == 0 else 1.0):
				near_candidates.append([distance, xy])
			elif far_on and distance <= radius_far * (hysteresis if current > 0 else 1.0):
				far_candidates.append([distance, xy])
	near_candidates.sort_custom(_by_distance)
	var desired := {}
	var ordered: Array = []
	for index in range(near_candidates.size()):
		var entry: Array = near_candidates[index]
		if index < near_slots:
			desired[entry[1]] = 0
			ordered.append(entry)
		elif far_on:
			far_candidates.append(entry)
	far_candidates.sort_custom(_by_distance)
	var far_taken := 0
	for entry in far_candidates:
		if far_taken >= far_slots: break
		if desired.has(entry[1]): continue
		desired[entry[1]] = far_level
		ordered.append(entry)
		far_taken += 1
	ordered.sort_custom(_by_distance)
	# Leaving regions first, then demotions (they free near slots), then promotions and new binds.
	for xy: Vector2i in _bound.keys():
		if not desired.has(xy):
			renderer.release_region(xy)
			_bound.erase(xy)
	for xy: Vector2i in data.cached_region_keys():
		if not desired.has(xy):
			if data.evict_region(xy): _evictions += 1
	_busy = false
	var requests := 0
	# Pass 0 demotes near regions to far (freeing near slots), pass 1 does everything else.
	for pass_index in range(2):
		for entry in ordered:
			var xy: Vector2i = entry[1]
			var level: int = desired[xy]
			var current: int = _bound.get(xy, -1)
			if current == level: continue
			if pass_index == 0 and not (current == 0 and level > 0): continue
			if pass_index == 1 and current == 0 and level > 0: continue
			# A cached region binds when it holds the level: lod data serves the far tier, a full
			# region (kept from the near tier or loaded) serves both. A promotion to near with
			# only lod data cached requests the full file and keeps the far binding meanwhile.
			if data.has_cached_region(xy, level):
				if renderer.free_slots(level) > 0 and renderer.set_region_level(xy, data.get_region(xy, level), level):
					_bound[xy] = level
				else:
					_busy = true
			else:
				_busy = true
				if requests < loads_per_frame and data.pending_count() < loads_per_frame * IN_FLIGHT_FACTOR and not data.is_region_missing(xy) and data.request_region(xy, level):
					requests += 1
					_loads += 1

static func _by_distance(a: Array, b: Array) -> bool:
	return a[0] < b[0]

static func _distance(point: Vector2, rect: Rect2) -> float:
	var closest := point.clamp(rect.position, rect.end)
	return point.distance_to(closest)
