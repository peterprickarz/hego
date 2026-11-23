@tool
class_name StrataAOOverlay
extends Node
## World-space AO overlay of a StrataTerrain3D: contact shadows under ground cover, props or
## anything else, baked per square world tile by StrataAOOverlayBaker and streamed around the
## camera. See "World-space AO overlay" in docs/strata/reference.md.
##
## Runtime: the tiles within [member load_radius] of the camera are loaded on threads into a
## Texture2DArray of [member slots] layers (one upload per frame at most) and bound to the
## terrain's renderers with StrataRenderer.set_ao_overlay(); tiles beyond
## [member unload_radius] free their layer. Nothing is drawn differently until a tile is
## resident, and the terrain shader skips the overlay entirely while no node binds one.
##
## Baking: rebake_tiles() bakes tiles from the instances of the MultiMeshInstance3D and
## MeshInstance3D nodes in [member source_group] (a group on a parent covers its subtree) and
## from source providers: nodes in the group "strata_ao_source_providers" with a method
## get_ao_overlay_sources(rect: Rect2) -> Array of nodes (nodes outside the scene tree are
## freed after the bake), for content that is streamed or not loaded. Per-node rules: see
## StrataAOOverlayBaker.

const Baker = preload("res://addons/strata/strata_ao_overlay_baker.gd")
const PROVIDER_GROUP := &"strata_ao_source_providers"

## The terrain whose renderers draw the overlay; empty uses the parent.
@export var terrain: StrataTerrain3D
## Folder of the baked tiles (tile_X_Z.res and edges/tile_X_Z.f32).
@export_dir var directory := ""
## World XZ of tile 0,0 and the tile edge in metres.
@export var tile_origin := Vector2.ZERO
@export var tile_size := 256.0:
	set(value):
		tile_size = maxf(value, 1.0)
## Texels per tile side (a multiple of 4). 2048 on 256 m tiles is 0.125 m per texel.
@export var resolution := 2048
## Tiles the lookup table covers, in tile coordinates; empty: the tiles of the terrain's bounds.
@export var tile_range := Rect2i()

@export_group("Shading")
@export_range(0.0, 1.0, 0.01) var ao_strength := 1.0:
	set(value):
		ao_strength = value
		_bound.clear()
@export_range(0.0, 1.0, 0.01) var albedo_strength := 0.3:
	set(value):
		albedo_strength = value
		_bound.clear()
## How far occluded ground moves towards roughness 1 (litter and shelter under the sources).
@export_range(0.0, 1.0, 0.01) var roughness_strength := 0.0:
	set(value):
		roughness_strength = value
		_bound.clear()
## Distance from the camera (m) where the overlay starts to fade and where it is gone. Keep the
## end inside the visibility ranges of the sources, so no shadow shows without its object.
@export var fade_start := 40.0:
	set(value):
		fade_start = value
		_bound.clear()
@export var fade_end := 60.0:
	set(value):
		fade_end = value
		_bound.clear()

@export_group("Streaming")
@export var enabled := true:
	set(value):
		enabled = value
		if not value: _unbind()
## Horizontal distance (m) from the camera to a tile's rectangle that loads / frees it.
@export var load_radius := 96.0
@export var unload_radius := 128.0
## Texture array layers (resident tiles). Each costs resolution² × 4/3 bytes of video memory.
@export_range(1, 64) var slots := 6
@export var update_interval := 0.25
## Also stream and draw in the editor, around the editor camera.
@export var editor_preview := true:
	set(value):
		editor_preview = value
		if Engine.is_editor_hint() and not value: _unbind()
## The stage the overlay's sources belong to (for example the layer whose cook places them). In
## the editor the overlay draws only while the terrain preview shows this layer or a later one,
## so a selected (or locked) earlier layer is seen without it. Empty: always.
@export var editor_from_layer: StrataLayer

@export_group("Baking")
@export var source_group := &"strata_ao_sources"
## Rules by key (StrataAOOverlayBaker): {key: {radius or footprint, strength}}.
@export var rules: Dictionary = {}
## Rule for sources without metadata or a matching rule; empty skips them.
@export var default_rule: Dictionary = {"footprint": 1.0, "strength": 0.4}
@export var max_radius := 2.5
## Darkest value a texel can reach.
@export_range(0.0, 1.0, 0.01) var floor_value := 0.3
## Only sources whose visibility range ends within this distance contribute (0: all).
@export var max_range := 0.0
@export_tool_button("Rebake tiles near the camera", "Reload") var rebake_button: Callable = rebake_near_camera

## Optional key function for the rules (node -> String), set by game code.
var classify: Callable
## Optional procedural world footprints, callable(Rect2) -> packed x,z,radius,strength.
var blob_source: Callable

var _layers: Texture2DArray
var _table_image: Image
var _table_texture: ImageTexture
var _table_range := Rect2i()
var _resident := {}  # tile -> slot
var _slot_tiles: Array = []  # slot -> tile or null
var _pending := {}  # path -> tile
var _ready_images: Array = []  # [tile, Image]
var _bound := {}  # renderer instance id -> true
var _elapsed := 0.0
var _stats := {"loads": 0, "uploads": 0, "evictions": 0, "dropped": 0, "last_upload_ms": 0.0, "max_upload_ms": 0.0}


func _ready() -> void:
	if terrain == null and get_parent() is StrataTerrain3D:
		terrain = get_parent()


func _exit_tree() -> void:
	_unbind()
	for entry: Array in _ready_images:
		if entry[2] >= 0: WorkerThreadPool.wait_for_task_completion(entry[2])
	_ready_images.clear()


func _active() -> bool:
	return enabled and (editor_preview if Engine.is_editor_hint() else true)


## False in the editor while the terrain preview stops at a layer below [member editor_from_layer].
func _stage_shown() -> bool:
	if not Engine.is_editor_hint() or not is_instance_valid(editor_from_layer) or terrain == null or editor_from_layer.get_parent() != terrain:
		return true
	var cutoff := terrain.preview_through_layer
	return not is_instance_valid(cutoff) or cutoff.get_index() >= editor_from_layer.get_index()


func _process(delta: float) -> void:
	if not _active():
		return
	if not _stage_shown():
		if not _bound.is_empty(): _unbind()
		return
	_poll_loads()
	_elapsed += delta
	if _elapsed < update_interval:
		return
	_elapsed = 0.0
	update()


## One residency pass: frees far tiles, requests near ones and (re)binds the renderers.
func update() -> void:
	var camera: Variant = _camera_position()
	if camera == null:
		return
	var at := Vector2((camera as Vector3).x, (camera as Vector3).z)
	_ensure_table()
	for tile: Vector2i in _resident.keys():
		if _distance(tile, at) > unload_radius:
			_release(tile)
			_stats.evictions += 1
	var wanted := _tiles_within(at, load_radius)
	for tile: Vector2i in wanted:
		var path := Baker.tile_path(layout(), tile)
		if _resident.has(tile) or _pending.has(path) or _ready_images.any(func(entry: Array) -> bool: return entry[0] == tile):
			continue
		if not ResourceLoader.exists(path):
			continue
		if ResourceLoader.load_threaded_request(path, "Image", false, ResourceLoader.CACHE_MODE_IGNORE) == OK:
			_pending[path] = tile
			_stats.loads += 1
	_bind()


func _poll_loads() -> void:
	for path: String in _pending.keys():
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		var tile: Vector2i = _pending[path]
		_pending.erase(path)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			var image := ResourceLoader.load_threaded_get(path) as Image
			if image != null:
				# Mipmaps are built off the main thread (the files store mip 0 only).
				var task := WorkerThreadPool.add_task(image.generate_mipmaps) if not image.has_mipmaps() else -1
				_ready_images.append([tile, image, task])
	# One upload per frame keeps the cost of a tile change to a single layer copy.
	if not _ready_images.is_empty():
		var entry: Array = _ready_images.front()
		if entry[2] >= 0:
			if not WorkerThreadPool.is_task_completed(entry[2]): return
			WorkerThreadPool.wait_for_task_completion(entry[2])
		_ready_images.pop_front()
		_upload(entry[0], entry[1])


func _upload(tile: Vector2i, image: Image) -> void:
	if image.get_format() != Image.FORMAT_R8 or image.get_width() != resolution or image.get_height() != resolution:
		push_warning("StrataAOOverlay: %s is not an R8 %d² map." % [Baker.tile_path(layout(), tile), resolution])
		return
	var camera: Variant = _camera_position()
	if camera != null and _distance(tile, Vector2((camera as Vector3).x, (camera as Vector3).z)) > unload_radius:
		return
	if not _table_range.has_point(tile):
		return
	var started := Time.get_ticks_usec()
	if not image.has_mipmaps():
		image.generate_mipmaps()  # not from _poll_loads
	var slot := _resident.get(tile, -1) as int
	if slot < 0:
		slot = _free_slot(camera)
	if slot < 0:
		_stats.dropped += 1
		return
	if _layers == null:
		var images: Array[Image] = []
		for i in slots: images.append(image)
		_layers = Texture2DArray.new()
		_layers.create_from_images(images)
		_slot_tiles.resize(slots)
		_slot_tiles.fill(null)
		_bound.clear()
	else:
		_layers.update_layer(image, slot)
	_resident[tile] = slot
	_slot_tiles[slot] = tile
	_table_image.set_pixelv(tile - _table_range.position, Color8(slot + 1, 0, 0))
	_table_texture.update(_table_image)
	_stats.uploads += 1
	_stats.last_upload_ms = (Time.get_ticks_usec() - started) / 1000.0
	_stats.max_upload_ms = maxf(_stats.max_upload_ms, _stats.last_upload_ms)
	_bind()


func _free_slot(camera: Variant) -> int:
	if _layers == null:
		return 0
	for slot in _slot_tiles.size():
		if _slot_tiles[slot] == null:
			return slot
	# Full: reuse the farthest tile beyond the fade, which draws nothing.
	if camera == null:
		return -1
	var at := Vector2((camera as Vector3).x, (camera as Vector3).z)
	var farthest := -1
	var distance := fade_end
	for slot in _slot_tiles.size():
		var d := _distance(_slot_tiles[slot], at)
		if d > distance:
			distance = d
			farthest = slot
	if farthest >= 0:
		_release(_slot_tiles[farthest])
		_stats.evictions += 1
	return farthest


func _release(tile: Vector2i) -> void:
	var slot := int(_resident.get(tile, -1))
	_resident.erase(tile)
	if slot >= 0 and slot < _slot_tiles.size():
		_slot_tiles[slot] = null
	if _table_image != null and _table_range.has_point(tile):
		_table_image.set_pixelv(tile - _table_range.position, Color8(0, 0, 0))
		_table_texture.update(_table_image)


func _distance(tile: Vector2i, at: Vector2) -> float:
	var rect := Baker.tile_rect(layout(), tile)
	return at.distance_to(at.clamp(rect.position, rect.end))


func _tiles_within(at: Vector2, radius: float) -> Array[Vector2i]:
	var low := Baker.tile_of(layout(), at - Vector2(radius, radius))
	var high := Baker.tile_of(layout(), at + Vector2(radius, radius))
	var result: Array[Vector2i] = []
	for z in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			var tile := Vector2i(x, z)
			if _distance(tile, at) <= radius:
				result.append(tile)
	result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _distance(a, at) < _distance(b, at))
	return result


func _ensure_table() -> void:
	var wanted := tile_range
	if not wanted.has_area() and terrain != null:
		var bounds := terrain.base_bounds
		var origin := Vector2(terrain.global_position.x, terrain.global_position.z) if terrain.is_inside_tree() else Vector2.ZERO
		var low := Baker.tile_of(layout(), origin + bounds.position)
		var high := Baker.tile_of(layout(), origin + bounds.end - Vector2(0.001, 0.001))
		wanted = Rect2i(low, high - low + Vector2i.ONE)
	if not wanted.has_area() or (_table_image != null and wanted == _table_range):
		return
	_table_range = wanted
	_table_image = Image.create(wanted.size.x, wanted.size.y, false, Image.FORMAT_R8)
	_table_texture = ImageTexture.create_from_image(_table_image)
	for tile: Vector2i in _resident.keys():
		if wanted.has_point(tile):
			_table_image.set_pixelv(tile - wanted.position, Color8(int(_resident[tile]) + 1, 0, 0))
		else:
			_release(tile)
	_table_texture.update(_table_image)
	_bound.clear()


## Renderers drawing the terrain: its StrataRenderer children and the editor preview.
func renderers() -> Array[StrataRenderer]:
	var result: Array[StrataRenderer] = []
	if terrain == null:
		return result
	for child in terrain.get_children():
		if child is StrataRenderer:
			result.append(child)
	if Engine.is_editor_hint() and is_instance_valid(terrain.editor_renderer):
		result.append(terrain.editor_renderer)
	return result


func _bind() -> void:
	if _layers == null or _table_texture == null:
		return
	var settings := {"ao_strength": ao_strength, "albedo_strength": albedo_strength, "roughness_strength": roughness_strength, "fade_start": fade_start, "fade_end": fade_end}
	var origin := tile_origin + Vector2(_table_range.position) * tile_size
	for renderer in renderers():
		var current := renderer.get_ao_overlay()
		if _bound.has(renderer.get_instance_id()) and current.get("layers") == _layers and current.get("table") == _table_texture:
			continue
		if renderer.set_ao_overlay(_layers, _table_texture, origin, Vector2(tile_size, tile_size), settings):
			_bound[renderer.get_instance_id()] = true


func _unbind() -> void:
	if terrain != null:
		for renderer in renderers():
			if _layers != null and renderer.get_ao_overlay().get("layers") == _layers:
				renderer.clear_ao_overlay()
	_bound.clear()


func _camera_position() -> Variant:
	if Engine.is_editor_hint():
		var editor: Object = Engine.get_singleton(&"EditorInterface")
		if editor == null:
			return null
		var camera: Camera3D = editor.get_editor_viewport_3d(0).get_camera_3d()
		return camera.global_position if camera != null else null
	var viewport := get_viewport()
	var active := viewport.get_camera_3d() if viewport != null else null
	return active.global_position if active != null else null


## Drops [param tiles] from residency so they reload from disk (after a bake).
func reload_tiles(tiles: Array) -> void:
	for tile: Vector2i in tiles:
		if _resident.has(tile):
			_release(tile)
	_elapsed = update_interval


## Residency and upload counters, and the video memory of the layer array.
func get_stats() -> Dictionary:
	var result := _stats.duplicate()
	result.resident = _resident.size()
	result.pending = _pending.size()
	result.slots = slots
	result.tiles = _resident.keys()
	var layer_bytes := 0
	var size := resolution
	while size >= 1:
		layer_bytes += size * size
		size /= 2
	result.video_memory_bytes = layer_bytes * slots if _layers != null else 0
	result.bound_renderers = _bound.size()
	return result


# ─────────────────────────────────────────────
# Baking
# ─────────────────────────────────────────────

func layout() -> Dictionary:
	return {"directory": directory, "origin": tile_origin, "tile_size": tile_size, "resolution": resolution}


func bake_options() -> Dictionary:
	return {"rules": rules, "default": default_rule if not default_rule.is_empty() else null,
		"classify": classify if classify.is_valid() else null, "max_radius": max_radius,
		"floor": floor_value, "max_range": max_range, "blob_source": blob_source}


## Source roots for [param rect]: the [member source_group] nodes (filtered by bounds in the
## bake) and the providers' nodes. Nodes outside the tree are the caller's to free.
func sources_for(rect: Rect2, use_providers := true) -> Array:
	var result: Array = []
	if not is_inside_tree():
		return result
	result.append_array(get_tree().get_nodes_in_group(source_group))
	if use_providers:
		for provider in get_tree().get_nodes_in_group(PROVIDER_GROUP):
			if provider.has_method(&"get_ao_overlay_sources"):
				result.append_array(provider.get_ao_overlay_sources(rect))
	return result


## Bakes [param tiles] (Vector2i) from [param extra_roots], the source group and (with
## [param use_providers]) the providers, then reloads them and their rebaked neighbours.
## Returns one report per tile (StrataAOOverlayBaker.bake_tile).
func rebake_tiles(tiles: Array, extra_roots: Array = [], use_providers := true, repair_neighbours := true) -> Array:
	var reports := []
	var touched := []
	for tile: Vector2i in tiles:
		var rect := Baker.tile_rect(layout(), tile)
		var roots := extra_roots.duplicate()
		var provided := sources_for(rect, use_providers)
		roots.append_array(provided)
		var report := Baker.bake_tile(layout(), tile, roots, bake_options(), repair_neighbours)
		for node: Variant in provided:
			if node is Node and is_instance_valid(node) and not (node as Node).is_inside_tree():
				(node as Node).free()
		reports.append(report)
		touched.append(tile)
		touched.append_array(report.get("neighbours_rebaked", []))
	reload_tiles(touched)
	return reports


## Rebakes the tiles within [member load_radius] of the (editor) camera.
func rebake_near_camera() -> void:
	var camera: Variant = _camera_position()
	if camera == null:
		push_warning("StrataAOOverlay: no camera to rebake around.")
		return
	var tiles := _tiles_within(Vector2((camera as Vector3).x, (camera as Vector3).z), load_radius)
	for report: Dictionary in rebake_tiles(tiles):
		print("StrataAOOverlay: tile %s %s, %d instances, %.0f ms" % [report.tile, "baked" if report.ok else str(report.get("message", "failed")), int(report.get("instances", 0)), float(report.get("ms", 0.0))])
