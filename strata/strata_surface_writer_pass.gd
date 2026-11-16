@tool
extends Node
## Renders StrataSurfaceWriter meshes for the pages of one StrataSurfaceCache. A tile is one
## SubViewport, three tile widths wide, with an orthographic top-down camera over the registry's
## private World3D: every writer is drawn once per output into its third (albedo; normal +
## roughness; AO + relief + metallic; strata_surface_writer.gdshaderinc shifts each output's
## copy), so a tile costs one viewport render. A tile covers the cells of one page slot (the
## page and its border) at the page's mip. One dispatched in frame N is drawn by Godot at the
## end of frame N and composited into the page by the cache's compute fill in frame N+1
## (strata_surface_cache.gd). Owned by StrataRenderer as an internal child.
##
## Texel (i, j) of output p is cell origin + (i, j) of the tile's mip at viewport pixel
## (p * width + i, j): the camera's right is terrain-local +X and image rows grow along +Z. A
## tile is two cells larger than its slot: one cell of apron on the low sides gives corner
## heights their four neighbours.

const _CAMERA_HEIGHT := 50000.0
const _MEASURE_DELAY := 4

## Tiles drawn per frame at most (one viewport render each).
var tiles_per_frame := 16
## Viewports kept at most (about 1 MB each for 128-cell pages). A tile holds its viewport for
## two frames.
var max_viewports := 32
## Viewports idle this long (seconds) are freed, except one.
var idle_release_seconds := 5.0
var registry: StrataSurfaceWriterRegistry
## Terrain node's global transform (translation and yaw).
var terrain_transform := Transform3D.IDENTITY
## Cell edge of the cache's mip 0 in metres.
var texel := 1.0 / 128.0
var stats := {"tiles_last_frame": 0, "tiles_queued": 0, "tiles_total": 0, "viewports": 0, "gpu_ms_total": 0.0, "cpu_ms_total": 0.0, "measured_tiles": 0}
## Measures the viewports' render time (RenderingServer.viewport_set_measure_render_time):
## stats.gpu_ms_total / cpu_ms_total sum it over measured_tiles drawn tiles.
var measure := false

## Each: {viewport: SubViewport, camera: Camera3D, shape: Vector2i, state: 0 free / 1 drawing /
## 2 ready, frame: int, level: int, rect: Rect2i (cells to composite), origin: Vector2i}
var _sets: Array[Dictionary] = []
## [level, cells: Rect2i]
var _queue: Array = []
var _queued := {}
## Tile size in cells of the tiles queued last (the slot plus the apron).
var _shape := Vector2i.ZERO
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


## Terrain-local XZ rectangle of a cell rectangle at a mip.
func cell_rect_local(level: int, rect: Rect2i) -> Rect2:
	var size := texel * float(1 << level)
	return Rect2(Vector2(rect.position) * size, Vector2(rect.size) * size)


## True when a writer touches the cells (one cell of margin).
func overlaps(level: int, rect: Rect2i) -> bool:
	if not has_writers(): return false
	return registry.overlaps_xz(_local_to_global(cell_rect_local(level, rect.grow(1))))


## Queues the tile of a page slot ([param rect]: its cells at mip [param level]) when a writer
## touches it. True when the tile is queued, now or already.
func queue_rect(level: int, rect: Rect2i) -> bool:
	if not rect.has_area() or not overlaps(level, rect): return false
	_shape = rect.size + Vector2i(2, 2)
	var key := [rect, level]
	if not _queued.has(key):
		_queued[key] = true
		_queue.append([level, rect])
		stats.tiles_queued = _queue.size()
	return true


## Drops the queued tiles [param keep] (level, cells) rejects: pages no longer wanted.
func drop_pages(keep: Callable) -> void:
	if _queue.is_empty(): return
	var kept := []
	for item: Array in _queue:
		if keep.call(int(item[0]), item[1]):
			kept.append(item)
		else:
			_queued.erase([item[1], int(item[0])])
	_queue = kept
	stats.tiles_queued = _queue.size()


## Tiles drawn by Godot since they were dispatched: [level, rect, origin, set index, tile
## width]. Their viewport texture stays valid until that set is drawn again (end of this frame
## at the earliest), so compute work queued this frame can read it. Call it before dispatch().
func take_ready() -> Array:
	var frame := Engine.get_process_frames()
	var result := []
	for index in _sets.size():
		var tile_set: Dictionary = _sets[index]
		if tile_set.state == 1 and frame > int(tile_set.frame):
			tile_set.state = 2
		if tile_set.state == 2:
			result.append([tile_set.level, tile_set.rect, tile_set.origin, index, (tile_set.shape as Vector2i).x])
			tile_set.state = 0
	return result


## RenderingServer texture of a set's viewport.
func set_texture(index: int) -> RID:
	return (_sets[index].viewport as SubViewport).get_texture().get_rid()


## Starts drawing queued tiles on free viewports (at most tiles_per_frame), oldest first.
func dispatch() -> void:
	var frame := Engine.get_process_frames()
	if measure: _collect_measurements(frame)
	var drawn := 0
	while not _queue.is_empty() and drawn < tiles_per_frame:
		var item: Array = _queue[0]
		var index := _free_set((item[1] as Rect2i).size + Vector2i(2, 2))
		if index < 0: break
		_queue.remove_at(0)
		_draw(index, item, frame)
		drawn += 1
	_release_idle()
	stats.tiles_last_frame = drawn
	stats.tiles_total = int(stats.tiles_total) + drawn
	stats.tiles_queued = _queue.size()


func _draw(index: int, item: Array, frame: int) -> void:
	var level := int(item[0])
	var piece: Rect2i = item[1]
	var shape := piece.size + Vector2i(2, 2)
	if measure: _collect_measurements(frame, index)
	_queued.erase([piece, level])
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


## True while tiles wait to be drawn or composited.
func busy() -> bool:
	if not _queue.is_empty(): return true
	for tile_set in _sets:
		if tile_set.state != 0: return true
	return false


## Drops queued and drawn tiles (the cache was reallocated or reconfigured).
func reset() -> void:
	_queue.clear()
	_queued.clear()
	for tile_set in _sets: tile_set.state = 0
	stats.tiles_queued = 0


## A free viewport of a tile size, a new one while fewer than max_viewports exist, else -1.
func _free_set(shape: Vector2i) -> int:
	for index in _sets.size():
		if _sets[index].shape == shape and _sets[index].state == 0: return index
	if _sets.size() >= max_viewports: return -1
	_sets.append(_create_set(shape))
	stats.viewports = _sets.size()
	return _sets.size() - 1


## Frees viewports unused for idle_release_seconds, keeping one of the current tile size.
func _release_idle() -> void:
	var now := Time.get_ticks_msec()
	var kept := false
	for index in range(_sets.size() - 1, -1, -1):
		var tile_set: Dictionary = _sets[index]
		var current: bool = tile_set.shape == _shape
		if tile_set.state != 0 or now - int(tile_set.get("used", now)) < idle_release_seconds * 1000.0 or (current and not kept):
			kept = kept or current
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
	return {"viewport": viewport, "camera": camera, "shape": shape, "state": 0, "frame": 0, "level": 0, "rect": Rect2i(), "origin": Vector2i.ZERO, "used": Time.get_ticks_msec()}


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
