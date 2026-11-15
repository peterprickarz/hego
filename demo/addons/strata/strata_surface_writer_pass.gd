@tool
extends Node
## Renders StrataSurfaceWriter meshes for one StrataSurfaceCache and its far layer
## (StrataSurfaceWriterFar). A tile is one SubViewport,
## three tile widths wide, with an orthographic top-down camera over the registry's private
## World3D: every writer is drawn once per output into its third (albedo; normal + roughness;
## AO + relief + metallic; strata_surface_writer.gdshaderinc shifts each output's copy), so a
## tile costs one viewport render. Tiles come in three shapes: rows and columns for the strips a
## scrolling cache window exposes, squares for everything else. A tile dispatched in frame N is
## drawn by Godot at the end of frame N and composited into the cache by the compute fill in
## frame N+1 (strata_surface_cache.gd). Far-layer tiles (target 1) are 512² squares
## drawn after the cache's tiles at far_tiles_per_frame. Owned by StrataRenderer as an
## internal child.
##
## Texel (i, j) of output p is cell origin + (i, j) of the tile's level at viewport pixel
## (p * width + i, j): the camera's right is terrain-local +X and image rows grow along +Z.

## Tile shapes in cells (each holds pieces of size - 2: one cell of apron on the low sides
## gives corner heights their four neighbours).
const ROW := Vector2i(1026, 34)
const COLUMN := Vector2i(34, 1026)
const SQUARE := Vector2i(256, 256)
## Far-layer tiles (512² cells each), freed when idle.
const FAR := Vector2i(514, 514)
const TARGET_CACHE := 0
const TARGET_FAR := 1
const _CAMERA_HEIGHT := 50000.0
const _MEASURE_DELAY := 4

## Tiles drawn per frame at most (one viewport render each).
var tiles_per_frame := 6
## Far-layer tiles drawn per frame at most, besides the cache's tiles_per_frame.
var far_tiles_per_frame := 1
## Viewports kept per tile shape at most (about 2-4 MB each).
var sets_per_shape := 4
## Viewports idle this long (seconds) are freed, except one per cache tile shape.
var idle_release_seconds := 5.0
var registry: StrataSurfaceWriterRegistry
## Terrain node's global transform (translation and yaw).
var terrain_transform := Transform3D.IDENTITY
## Cell edge of cache level 0 in metres.
var texel := 1.0 / 128.0
var stats := {"tiles_last_frame": 0, "tiles_queued": 0, "tiles_total": 0, "far_tiles_queued": 0, "far_tiles_total": 0, "viewports": 0, "gpu_ms_total": 0.0, "cpu_ms_total": 0.0, "measured_tiles": 0}
## Measures the viewports' render time (RenderingServer.viewport_set_measure_render_time):
## stats.gpu_ms_total / cpu_ms_total sum it over measured_tiles drawn tiles.
var measure := false

## Each: {viewport: SubViewport, camera: Camera3D, shape: Vector2i, state: 0 free / 1 drawing /
## 2 ready, frame: int, level: int, rect: Rect2i (cells to composite), origin: Vector2i,
## target: TARGET_CACHE or TARGET_FAR}
var _sets: Array[Dictionary] = []
## [level, piece: Rect2i, shape: Vector2i, target]
var _queue: Array = []
var _far_queue: Array = []
var _queued := {}
## Emitted with a terrain-local rectangle where writers changed.
signal writers_changed(local_rect: Rect2)


func _init() -> void:
	registry = StrataSurfaceWriterRegistry.shared()
	registry.users += 1
	registry.changed.connect(_on_registry_changed)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and registry != null:
		if registry.changed.is_connected(_on_registry_changed): registry.changed.disconnect(_on_registry_changed)
		registry.users -= 1
		registry = null
		StrataSurfaceWriterRegistry.release_if_unused()


func has_writers() -> bool:
	return registry != null and registry.entry_count() > 0


## Terrain-local XZ rectangle of a cell rectangle at a level.
func cell_rect_local(level: int, rect: Rect2i) -> Rect2:
	var size := texel * float(1 << level)
	return Rect2(Vector2(rect.position) * size, Vector2(rect.size) * size)


## True when a writer touches the cells (one cell of margin).
func overlaps(level: int, rect: Rect2i) -> bool:
	if not has_writers(): return false
	return registry.overlaps_xz(_local_to_global(cell_rect_local(level, rect.grow(1))))


## Splits the cells into tiles and queues those a writer touches; true when any was queued.
func queue_rect(level: int, rect: Rect2i) -> bool:
	if not has_writers() or not rect.has_area(): return false
	var shape := SQUARE
	if rect.size.y <= ROW.y - 2: shape = ROW
	elif rect.size.x <= COLUMN.x - 2: shape = COLUMN
	return not _queue_pieces(level, rect, shape, TARGET_CACHE, _queue).is_empty()


## Splits far-layer cells (at [param level]) into FAR tiles and queues those a writer touches.
## Returns the pieces no writer touches (to be cleared).
func queue_far(level: int, rect: Rect2i) -> Array[Rect2i]:
	var uncovered: Array[Rect2i] = []
	if not rect.has_area(): return uncovered
	_queue_pieces(level, rect, FAR, TARGET_FAR, _far_queue, uncovered)
	return uncovered


## Queues the pieces of [param rect] a writer touches; returns them.
func _queue_pieces(level: int, rect: Rect2i, shape: Vector2i, target: int, queue: Array, uncovered: Array[Rect2i] = []) -> Array[Rect2i]:
	var piece_size := shape - Vector2i(2, 2)
	var queued: Array[Rect2i] = []
	var y := rect.position.y
	while y < rect.end.y:
		var x := rect.position.x
		var h := mini(piece_size.y, rect.end.y - y)
		while x < rect.end.x:
			var piece := Rect2i(x, y, mini(piece_size.x, rect.end.x - x), h)
			if overlaps(level, piece):
				var key := [piece, level, target]
				if not _queued.has(key):
					_queued[key] = true
					queue.append([level, piece, shape, target])
				queued.append(piece)
			else:
				uncovered.append(piece)
			x += piece_size.x
		y += piece_size.y
	stats.tiles_queued = _queue.size()
	stats.far_tiles_queued = _far_queue.size()
	return queued


## Drops queued cache tiles outside the window of their level ([param windows] by level, in
## cells): a moving camera queues tiles faster than they are drawn, and those it has left behind
## would only be drawn and thrown away.
func drop_outside(windows: Array) -> void:
	if _queue.is_empty(): return
	var kept := []
	for item: Array in _queue:
		var level := int(item[0])
		if level < windows.size() and (windows[level] as Rect2i).intersects(item[1]):
			kept.append(item)
		else:
			_queued.erase([item[1], level, int(item[3])])
	_queue = kept
	stats.tiles_queued = _queue.size()


## Tiles of [param target] drawn by Godot since they were dispatched: [level, rect, origin, set
## index, tile width]. Their viewport texture stays valid until that set is drawn again (end of
## this frame at the earliest), so compute work queued this frame can read it. Call it before
## dispatch().
func take_ready(target := TARGET_CACHE) -> Array:
	var frame := Engine.get_process_frames()
	var result := []
	for index in _sets.size():
		var tile_set: Dictionary = _sets[index]
		if tile_set.state == 1 and frame > int(tile_set.frame):
			tile_set.state = 2
		if tile_set.state == 2 and int(tile_set.target) == target:
			result.append([tile_set.level, tile_set.rect, tile_set.origin, index, (tile_set.shape as Vector2i).x])
			tile_set.state = 0
	return result


## RenderingServer texture of a set's viewport.
func set_texture(index: int) -> RID:
	return (_sets[index].viewport as SubViewport).get_texture().get_rid()


## Starts drawing queued tiles on free sets (at most tiles_per_frame), oldest first. Tiles
## whose shape has no free set stay queued in place; the scan stops once no shape in the queue
## can take one (a long queue costs nothing while every set is busy).
func dispatch() -> void:
	var drawn := 0
	var frame := Engine.get_process_frames()
	if measure: _collect_measurements(frame)
	var far_drawn := 0
	for far: bool in [false, true]:
		var queue: Array = _far_queue if far else _queue
		var limit := far_tiles_per_frame if far else tiles_per_frame
		var count := 0
		var busy := {}
		var shapes := 1 if far else 3
		var i := 0
		while i < queue.size() and count < limit and busy.size() < shapes:
			var item: Array = queue[i]
			var shape: Vector2i = item[2]
			if busy.has(shape):
				i += 1
				continue
			var index := _free_set(shape)
			if index < 0:
				busy[shape] = true
				i += 1
				continue
			queue.remove_at(i)
			_draw(index, item, frame)
			count += 1
		if far: far_drawn = count
		else: drawn = count
	_release_idle()
	stats.tiles_last_frame = drawn
	stats.tiles_total = int(stats.tiles_total) + drawn
	stats.far_tiles_total = int(stats.far_tiles_total) + far_drawn
	stats.tiles_queued = _queue.size()
	stats.far_tiles_queued = _far_queue.size()


func _draw(index: int, item: Array, frame: int) -> void:
	var level := int(item[0])
	var piece: Rect2i = item[1]
	var shape: Vector2i = item[2]
	if measure: _collect_measurements(frame, index)
	_queued.erase([piece, level, int(item[3])])
	var origin := piece.position - Vector2i.ONE
	var size := texel * float(1 << level)
	var centre := (Vector2(origin) + Vector2(shape) * 0.5) * size
	# Camera right = +X, camera up = -Z (image rows grow along +Z), looking down -Y. The
	# viewport is three tile widths wide; the tile is its middle third.
	var local := Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)), Vector3(centre.x, _CAMERA_HEIGHT, centre.y))
	var tile_set: Dictionary = _sets[index]
	var camera: Camera3D = tile_set.camera
	camera.global_transform = terrain_transform * local
	camera.size = shape.y * size
	(tile_set.viewport as SubViewport).render_target_update_mode = SubViewport.UPDATE_ONCE
	tile_set.state = 1
	tile_set.used = Time.get_ticks_msec()
	tile_set.unmeasured = measure
	tile_set.frame = frame
	tile_set.level = level
	tile_set.rect = piece
	tile_set.origin = origin
	tile_set.target = int(item[3])


## Far-layer tiles queued, drawing or drawn but not yet composited.
func pending_far() -> int:
	var count := _far_queue.size()
	for tile_set in _sets:
		if tile_set.state != 0 and int(tile_set.target) == TARGET_FAR: count += 1
	return count


## True while tiles wait to be drawn or composited.
func busy() -> bool:
	if not _queue.is_empty() or not _far_queue.is_empty(): return true
	for tile_set in _sets:
		if tile_set.state != 0: return true
	return false


## Drops queued and drawn tiles (the cache was reallocated or reconfigured).
func reset() -> void:
	_queue.clear()
	_far_queue.clear()
	_queued.clear()
	for tile_set in _sets: tile_set.state = 0


func _free_set(shape: Vector2i) -> int:
	var count := 0
	for index in _sets.size():
		if _sets[index].shape != shape: continue
		count += 1
		if _sets[index].state == 0: return index
	if count >= sets_per_shape: return -1
	_sets.append(_create_set(shape))
	stats.viewports = _sets.size()
	return _sets.size() - 1


## Frees viewports unused for idle_release_seconds (keeping one of each shape).
func _release_idle() -> void:
	var now := Time.get_ticks_msec()
	var kept := {}
	for index in range(_sets.size() - 1, -1, -1):
		var tile_set: Dictionary = _sets[index]
		var shape: Vector2i = tile_set.shape
		if tile_set.state != 0 or now - int(tile_set.get("used", now)) < idle_release_seconds * 1000.0 or (shape != FAR and not kept.has(shape)):
			kept[shape] = true
			continue
		(tile_set.viewport as SubViewport).queue_free()
		_sets.remove_at(index)
	stats.viewports = _sets.size()


func _create_set(shape: Vector2i) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.name = "WriterTile%d" % _sets.size()
	viewport.size = Vector2i(shape.x * StrataSurfaceWriterRegistry.PASS_COUNT, shape.y)
	viewport.world_3d = registry.world
	viewport.transparent_bg = true
	# Linear float output: the writer values arrive unclamped and without the sRGB curve.
	viewport.use_hdr_2d = true
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.use_taa = false
	viewport.use_debanding = false
	viewport.use_occlusion_culling = false
	viewport.mesh_lod_threshold = 0.0
	viewport.positional_shadow_atlas_size = 0
	viewport.scaling_3d_scale = 1.0
	viewport.audio_listener_enable_3d = false
	viewport.gui_disable_input = true
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.near = 1.0
	camera.far = _CAMERA_HEIGHT * 2.0
	camera.cull_mask = 1
	camera.current = true
	viewport.add_child(camera)
	add_child(viewport)
	RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
	return {"viewport": viewport, "camera": camera, "shape": shape, "state": 0, "frame": 0, "level": 0, "rect": Rect2i(), "origin": Vector2i.ZERO, "target": TARGET_CACHE, "used": Time.get_ticks_msec()}


## Godot reports a viewport's render time a few frames after it rendered: read each drawn set
## once, before it is drawn again or after _MEASURE_DELAY frames.
func _collect_measurements(frame: int, force_index := -1) -> void:
	var gpu := 0.0
	var cpu := 0.0
	for index in _sets.size():
		var tile_set: Dictionary = _sets[index]
		if not bool(tile_set.get("unmeasured", false)): continue
		if index != force_index and frame < int(tile_set.frame) + _MEASURE_DELAY: continue
		var rid := (tile_set.viewport as SubViewport).get_viewport_rid()
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(rid)
		tile_set.unmeasured = false
		stats.measured_tiles = int(stats.measured_tiles) + 1
	stats.gpu_ms_total = float(stats.gpu_ms_total) + gpu
	stats.cpu_ms_total = float(stats.cpu_ms_total) + cpu


func _local_to_global(rect: Rect2) -> Rect2:
	var result := Rect2()
	for i in 4:
		var corner := Vector2(rect.position.x + rect.size.x * float(i & 1), rect.position.y + rect.size.y * float(i >> 1))
		var point := terrain_transform * Vector3(corner.x, 0.0, corner.y)
		var p := Vector2(point.x, point.z)
		result = Rect2(p, Vector2.ZERO) if i == 0 else result.expand(p)
	return result


func _global_to_local(bounds: AABB) -> Rect2:
	var inverse := terrain_transform.affine_inverse()
	var result := Rect2()
	for i in 4:
		var point := inverse * Vector3(bounds.position.x + bounds.size.x * float(i & 1), 0.0, bounds.position.z + bounds.size.z * float(i >> 1))
		var p := Vector2(point.x, point.z)
		result = Rect2(p, Vector2.ZERO) if i == 0 else result.expand(p)
	return result


func _on_registry_changed(bounds: AABB) -> void:
	writers_changed.emit(_global_to_local(bounds))
