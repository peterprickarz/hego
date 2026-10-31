@tool
class_name StrataEditorPreview
extends Node
## Editor/authoring-view bridge: compose the live authoring stack, never run a producer.
##
## The preview is a set of regions (StrataRegions, docs/development/terrain_renderer_regions.md)
## composed through the selected layer and bound to the renderer. Composition runs on
## WorkerThreadPool tasks against one StrataRegionCompose.capture() per refresh; the main thread
## only submits tasks, polls them and binds results.
##
## Terrains with at most [member near_slots] regions bind every region at level 0 (Phase A
## layout). Larger terrains use the renderer's residency tiers, driven by the editor camera:
## the coarse maps of the whole terrain are composed first and bound at once (the terrain is
## visible within about a second), then regions near the camera at level 0 and farther ones
## directly at the far level, nearest first. Moving the camera re-tiers (hysteresis 1.25),
## releasing what it leaves.
##
## Later refreshes recompose only the map classes whose stack signature changed. A brush dab
## recomposes only the texel rectangle it touches in the near regions it touches, the far-level
## maps of far regions it touches, and the coarse texels under it (uploaded at most every
## [member coarse_upload_ms]); a height dab never recomposes materials, a material dab never
## height.
##
## Thread safety: a capture references the layers' live data (it is not a snapshot), so layers
## must not change while tasks run. request_refresh() and can_patch_region() therefore wait for
## the tasks in flight, drop their results and discard the capture before an edit is applied
## (the next submission captures again); a dab arriving while work is outstanding falls back to
## a refresh instead of patching. Only composition runs on workers; every renderer and scene call
## happens on the main thread.
signal refreshed
## Map classes and the stack channels each depends on. Their signatures are the cache keys.
const CLASS_HEIGHT := "height"
const CLASS_HOLES := "holes"
const CLASS_MATERIALS := "materials"
const CLASS_MACRO := "macro"
const CLASSES: Array[String] = [CLASS_HEIGHT, CLASS_HOLES, CLASS_MATERIALS, CLASS_MACRO]
## Tier radii in region extents from the camera to the closest point of a region.
const NEAR_FACTOR := 2.5
const FAR_FACTOR := 8.0
## A tiered region is kept until it is this factor beyond its tier radius.
const HYSTERESIS := 1.25

## Slots of the near (level 0) and far tier, the far level, and the radii in metres (0 = 2.5 and
## 8 region extents). Defaults are the streamer's. Public so tests and projects can tune them;
## changing them takes effect at the next structural refresh.
var near_slots := 25
var far_slots := 256
var far_level := 2
var near_radius := 0.0
var far_radius := 0.0
## Largest side in cells of the coarse height map (StrataRegions.coarse_level).
var coarse_max_side := StrataRegions.COARSE_MAX_SIDE
## Level-0 regions kept on the CPU beyond the bound and wanted ones (least recently used go first).
var cache_regions := 64
## Minimum time in milliseconds between coarse map uploads while painting.
var coarse_upload_ms := 250
## Tasks in flight at once; 0 = twice the processor count.
var max_in_flight := 0

var terrain: StrataTerrain3D
## The StrataRenderer, created on the first refresh. A duck-typed stand-in may be assigned
## before the first refresh (tests); it must offer what this script calls: configure_regions,
## set_regions, set_region_level, release_region, free_slots, set_coarse_maps,
## update_region_window, set_camera, set_ownership_overlay, set_channel_preview, get_stats,
## get_region, region_spec, a render_settings property and a _render_bounds Rect2.
var renderer: Object
var status := "Waiting for editor camera"
var _cutoff: StrataLayer
var _pending := false
var _camera: Camera3D
var _aux_dirty := true
var _last_channel: StringName
var _last_channel_visible := false
var _compile_count := 0
var _region_count := 0
var _configuration: Array = []
var _configuration_dirty := true
# The renderer rejected the current configuration; not retried until it changes (creating the
# renderer touches the children and would otherwise re-trigger the refresh forever).
var _configuration_failed := false
var _material_status := ""
var _material_compositions := 0
var _material_regions := 0
var _region_compositions := 0
var _near_composed := 0
var _far_composed := 0
var _coarse_composed := 0
var _coarse_uploads := 0
var _far_patches := 0

# The cache: the spec it is composed for, level-0 regions (bound near, wanted, or kept by the
# LRU), far-level regions, the coarse maps, the generation of each class and the generations
# each entry was composed from.
var _spec: Dictionary = {}
var _regions: Dictionary = {}
var _far: Dictionary = {}
var _coarse: Dictionary = {}
var _coarse_level := 0
var _tiered := false
var _signatures: Dictionary = {}
var _gen: Dictionary = {}
var _gens_near: Dictionary = {}
var _gens_far: Dictionary = {}
var _gens_coarse: Dictionary = {}
# Whether the renderer shows exactly this cache's structure (the spec was installed).
var _renderer_bound := false
# Tiered: the level each region is bound at in the renderer, the level it should be at, the
# wanted regions nearest first, and the camera point they were planned for.
var _bound: Dictionary = {}
var _wanted: Dictionary = {}
var _order: Array[Vector2i] = []
var _tier_point := Vector2(INF, INF)
var _used: Dictionary = {}
var _use_counter := 0
var _zero_levels: Dictionary = {}
# Work: the capture and its shared task context, the epoch results must match, the tasks in
# flight and whether anything is outstanding.
var _capture: Dictionary = {}
var _ctx: Dictionary = {}
var _selected: StrataLayer
var _epoch := 0
var _flight: Array = []
var _flight_keys: Dictionary = {}
var _working := false
var _progress := false
var _fresh_count := 0
var _total_count := 0
var _coarse_dirty := false
var _coarse_next_ms := 0
# Set by can_patch_region() just before a dab: which classes matched the stack then, so the
# dab's own rectangle is all that can have changed in them.
var _patchable: Dictionary = {}
var _owned_keys: Dictionary = {}
# Last scalar channel preview, kept so a dab can recompose only its rectangle.
var _channel_image: Image
var _channel_image_name: StringName

func setup(source: StrataTerrain3D) -> void:
	terrain = source
	terrain.editor_preview_bridge = self
	terrain.authoring_preview_changed.connect(request_refresh)
	sync_configuration()
	request_refresh()

func sync_configuration() -> void:
	if not is_instance_valid(terrain): return
	var state: Array = [terrain.region_spacing, terrain.region_cells, terrain.editor_material_channels.duplicate()]
	for material in terrain.editor_materials: state.append(material.get_instance_id() if is_instance_valid(material) else 0)
	if state != _configuration:
		_configuration = state
		_configuration_dirty = true
		_configuration_failed = false
		request_refresh()

func set_camera(camera: Camera3D) -> void:
	_camera = camera
	if is_instance_valid(_camera) and is_instance_valid(terrain) and Engine.is_editor_hint():
		_camera.far = maxf(_camera.far, terrain.editor_far_clip)
	if is_instance_valid(renderer): renderer.set_camera(camera)
	elif not _pending: request_refresh()

## The stack (or configuration) changed: stops the composition in flight, which read the old
## stack, and schedules a refresh.
func request_refresh() -> void:
	_cancel_work()
	_aux_dirty = true
	_queue_refresh()

## Schedules a refresh without forcing the channel preview.
func _queue_refresh() -> void:
	if _pending: return
	_pending = true
	_refresh.call_deferred()

## True when the cache is what a viewer shows: no renderer (headless cache), or one bound to it.
func _attached() -> bool:
	return not is_instance_valid(renderer) or _renderer_bound

## True while a refresh is queued or composition is still outstanding.
func is_busy() -> bool:
	return _pending or _working

## Runs a refresh and finishes its composition at once instead of waiting for frames; for tests
## and scripts. Returns whether the cache and renderer are current afterwards.
func refresh_now() -> bool:
	_pending = false
	_refresh()
	var guard := 0
	while _working and guard < 1000000:
		_pump(true)
		guard += 1
	return not _working and (renderer == null or _renderer_bound)

# ─────────────────────────────────────────────
# Specification and signatures
# ─────────────────────────────────────────────

## Why material ids and weights cannot be composed, or "" when the mapping is usable.
func _material_problem() -> String:
	var channels := terrain.editor_material_channels
	if channels.is_empty(): return "Materials unassigned; configure ordered material channels for stage previews"
	if channels.size() != terrain.editor_materials.size(): return "Materials unassigned; channel mapping must match the material pool"
	return ""

func _make_spec() -> Dictionary:
	return terrain.region_spec()

## Channels a map class depends on.
func _class_channels(cls: String) -> PackedStringArray:
	match cls:
		CLASS_HEIGHT: return PackedStringArray(["height"])
		CLASS_HOLES: return PackedStringArray(["hole"])
		CLASS_MATERIALS: return terrain.editor_material_channels
		_:
			var names := PackedStringArray()
			for channel in StrataMacro.CHANNELS: names.append(String(channel))
			return names

## Cache key of a map class through a cutoff. Only layers holding one of the class's channels
## take part, so a dab on another channel leaves it unchanged; the cutoff is not part of it,
## only what the layers up to it hold is.
func _class_state(cls: String, selected: StrataLayer) -> Array:
	var state := StrataMaterialControls.signature(terrain, _class_channels(cls), selected)
	state.remove_at(3)
	if cls == CLASS_MATERIALS: state.append([terrain.editor_materials.size(), _material_problem()])
	return state

## Which channels of a class an enabled layer through the cutoff holds. A class whose set
## changes (the first tint or material sample ever painted) changes every texel, not just the
## dab's rectangle, so its dab cannot be patched.
func _owned_key(cls: String, selected: StrataLayer) -> Array:
	var key: Array = []
	var wanted := _class_channels(cls)
	for layer in terrain.get_layers():
		if layer.enabled:
			var names := layer.get_channel_names()
			for channel in wanted:
				if names.has(channel) and not key.has(channel): key.append(channel)
		if layer == selected: break
	return key

func _class_of_channel(channel: StringName) -> String:
	if channel == &"height": return CLASS_HEIGHT
	if channel == &"hole": return CLASS_HOLES
	if terrain.editor_material_channels.has(String(channel)): return CLASS_MATERIALS
	if StrataMacro.is_macro_channel(channel): return CLASS_MACRO
	return ""

func _class_maps(cls: String) -> Array[String]:
	match cls:
		CLASS_HEIGHT: return [StrataRegions.MAP_HEIGHT]
		CLASS_HOLES: return [StrataRegions.MAP_HOLES]
		CLASS_MATERIALS: return [StrataRegions.MAP_MATERIAL_IDS, StrataRegions.MAP_MATERIAL_WEIGHTS]
		_: return [StrataRegions.MAP_MACRO]

## The class's maps that the spec has.
func _present(cls: String, spec: Dictionary) -> bool:
	return spec.maps.has((_class_maps(cls) as Array)[0])

# ─────────────────────────────────────────────
# Refresh
# ─────────────────────────────────────────────

func _refresh() -> void:
	_pending = false
	_patchable.clear()
	if not is_instance_valid(terrain) or not terrain.is_inside_tree() or not is_instance_valid(_camera): return
	terrain._sanitize_preview_layer()
	var selected := terrain.preview_through_layer
	var spec := _make_spec()
	var checked := StrataRegions.validate_spec(spec)
	if not checked.ok:
		status = "Region settings are invalid: %s; previous preview retained" % checked.message
		return
	if not _configure_renderer(): return
	_plan(selected, spec)
	if not is_instance_valid(renderer): return
	renderer.render_settings = terrain.render_settings
	if _aux_dirty or _last_channel != terrain.override_channel or _last_channel_visible != terrain.editor_show_channel:
		_refresh_channel()
	_aux_dirty = false
	renderer.set_ownership_overlay(selected, terrain.override_channel, terrain.show_overrides and selected != null)
	_cutoff = selected
	_working = true
	set_process(true)
	_pump(false)

## Creates or reconfigures the renderer when the configuration changed. It is configured with
## the spec and no regions (and, for a tiered terrain, the residency without coarse maps); the
## composed regions are bound afterwards.
func _configure_renderer() -> bool:
	if is_instance_valid(renderer) and not _configuration_dirty: return true
	if _configuration_failed: return false
	var spec := _make_spec()
	var residency := _residency(spec, {})
	if not is_instance_valid(renderer):
		var created := StrataRenderer.new()
		created.name = "TexturedEditorPreview"
		created.render_settings = terrain.render_settings
		terrain.add_child(created, false, Node.INTERNAL_MODE_BACK)
		created.set_camera(_camera)
		if not created.configure_regions(terrain, terrain.editor_materials, spec, {}, residency):
			created.queue_free()
			status = "Textured preview requires Forward+ and valid materials"
			_configuration_failed = true
			return false
		renderer = created
		terrain.editor_renderer = created
	elif not renderer.configure_regions(terrain, terrain.editor_materials, spec, {}, residency):
		# Configuration is transactional, including the rendered regions.
		status = "Invalid material/control configuration; previous rendered terrain retained"
		_configuration_failed = true
		return false
	_configuration_dirty = false
	_renderer_bound = false
	_bound.clear()
	_aux_dirty = true
	return true

## Composes the cache for the current stack and finishes at once on the calling thread (tests,
## scripts): every region at level 0, no tiers (a tiered terrain's coarse maps are composed
## too). With a renderer it is refresh_now(). False with the reason in [member status] on failure.
func compose_cache() -> bool:
	if not is_instance_valid(terrain) or not terrain.is_inside_tree(): return false
	terrain._sanitize_preview_layer()
	var spec := _make_spec()
	if not StrataRegions.validate_spec(spec).ok: return false
	sync_configuration()
	if is_instance_valid(renderer) and is_instance_valid(_camera):
		return refresh_now() and _spec == spec
	_configuration_dirty = false
	_cancel_work()
	_cutoff = terrain.preview_through_layer
	_plan(_cutoff, spec)
	var cap := StrataRegionCompose.capture(terrain, _cutoff, spec)
	if not cap.get("ok", false):
		status = String(cap.get("message", "capture failed"))
		_signatures.clear()
		return false
	var ctx := {"terrain": terrain, "selected": _cutoff, "spec": spec, "capture": cap, "material_ok": _material_problem().is_empty()}
	var missing: Array[Vector2i] = []
	var grid := StrataRegions.grid_size(spec)
	for y in range(grid.y):
		for x in range(grid.x):
			var xy := Vector2i(x, y)
			if not _stale(_gens_near.get(xy, {})).is_empty(): missing.append(xy)
	if not missing.is_empty():
		var sub := spec.duplicate(true)
		if not bool(ctx.material_ok):
			sub.maps.erase(StrataRegions.MAP_MATERIAL_IDS); sub.maps.erase(StrataRegions.MAP_MATERIAL_WEIGHTS)
		var composed := StrataRegions.compose_regions(terrain, _cutoff, sub, missing, {"capture": cap})
		if not composed.ok:
			status = String(composed.message)
			_signatures.clear()
			return false
		for xy in missing:
			var region: StrataRegionData = composed.regions[xy]
			if not bool(ctx.material_ok):
				for name in [StrataRegions.MAP_MATERIAL_IDS, StrataRegions.MAP_MATERIAL_WEIGHTS]:
					if spec.maps.has(name):
						var size := StrataRegions.map_size(spec.cells, spec.maps[name])
						region.set_image(name, Image.create(size.x, size.y, false, int(spec.maps[name].format)), 0, spec.maps[name])
			_complete_maps(region)
			_regions[xy] = region
			_gens_near[xy] = _current_gens()
			_region_compositions += 1
			_near_composed += 1
	if _tiered and not _stale(_gens_coarse).is_empty():
		for cls in _stale(_gens_coarse):
			var coarse := _compose_class(ctx, cls, true, Vector2i.ZERO, _coarse_level, Rect2i())
			if not coarse.ok:
				status = String(coarse.message)
				_signatures.clear()
				return false
			_coarse.merge(coarse.images, true)
			_gens_coarse[cls] = int(_gen.get(cls, 0))
			_coarse_composed += 1
	_capture = {}
	_working = false
	_finish()
	return _spec == spec

## Brings the cache's structure and class generations up to the stack: a changed spec starts a
## new cache (the renderer keeps the old regions until the new structure is installed), a
## changed class signature makes that class's entries stale, and the wanted tiers are planned
## for the camera. Composition itself is done by the pump.
func _plan(selected: StrataLayer, spec: Dictionary) -> void:
	_selected = selected
	var structural := spec != _spec
	if structural:
		_cancel_work()
		_spec = spec
		_tiered = _is_tiered(spec)
		_coarse_level = StrataRegions.coarse_level(spec, coarse_max_side) if _tiered else 0
		_signatures.clear()
		_regions = {}; _far = {}; _coarse = {}
		_gens_near = {}; _gens_far = {}; _gens_coarse = {}
		_used = {}
		_renderer_bound = false
		_tier_point = Vector2(INF, INF)
	var dirty: Array[String] = []
	for cls in CLASSES:
		if not _present(cls, spec): continue
		var state := _class_state(cls, selected)
		if structural or _signatures.get(cls) != state:
			dirty.append(cls)
			_signatures[cls] = state
	if not dirty.is_empty():
		# Entries composed from the old stack are stale; results still in flight are dropped.
		_cancel_work()
		for cls in dirty: _gen[cls] = int(_gen.get(cls, 0)) + 1
		if dirty.has(CLASS_HEIGHT): _compile_count += 1
		if dirty.has(CLASS_MATERIALS): _material_compositions += 1
	_evaluate_tiers(_camera_point())

func _present_classes() -> Array[String]:
	var present: Array[String] = []
	for cls in CLASSES:
		if _present(cls, _spec): present.append(cls)
	return present

## The present classes whose generation an entry was not composed from.
func _stale(gens: Dictionary) -> Array[String]:
	var stale: Array[String] = []
	for cls in CLASSES:
		if _present(cls, _spec) and int(gens.get(cls, -1)) != int(_gen.get(cls, 0)): stale.append(cls)
	return stale

func _current_gens() -> Dictionary:
	var gens := {}
	for cls in CLASSES:
		if _present(cls, _spec): gens[cls] = int(_gen.get(cls, 0))
	return gens

## Every present class has been composed at least once (the entry may be stale).
func _entry_complete(gens: Dictionary) -> bool:
	for cls in CLASSES:
		if _present(cls, _spec) and not gens.has(cls): return false
	return true

# ─────────────────────────────────────────────
# Tiers
# ─────────────────────────────────────────────

func _region_count_of(spec: Dictionary) -> int:
	var grid := StrataRegions.grid_size(spec)
	return grid.x * grid.y

## A terrain with more regions than near slots uses the residency tiers.
func _is_tiered(spec: Dictionary) -> bool:
	return _region_count_of(spec) > near_slots

## The far tier's level: [member far_level] capped to the deepest level every map has, 0 when
## the terrain has no far tier.
func _far_level_of(spec: Dictionary) -> int:
	var deepest := 99
	for name in spec.maps: deepest = mini(deepest, StrataRegions.max_level(int(spec.cells), spec.maps[name]))
	return mini(far_level, deepest) if far_slots > 0 else 0

## The residency dictionary for the renderer: empty (Phase A) unless tiered.
func _residency(spec: Dictionary, coarse_maps: Dictionary) -> Dictionary:
	if not _is_tiered(spec): return {}
	var count := _region_count_of(spec)
	var level := _far_level_of(spec)
	return {"near_slots": mini(near_slots, count), "far_slots": mini(far_slots, count) if level > 0 else 0, "far_level": maxi(level, 1), "coarse_level": StrataRegions.coarse_level(spec, coarse_max_side), "coarse_maps": coarse_maps}

func _camera_point() -> Vector2:
	if is_instance_valid(terrain) and is_instance_valid(_camera) and _camera.is_inside_tree() and terrain.is_inside_tree():
		var local := terrain.to_local(_camera.global_position)
		return Vector2(local.x, local.z)
	var bounds: Rect2 = _spec.get("bounds", Rect2())
	return bounds.get_center()

static func _distance(point: Vector2, rect: Rect2) -> float:
	return point.distance_to(point.clamp(rect.position, rect.end))

## The tier of every region that should be resident for a camera at [param point] (terrain-local
## XZ): {region index: 0 for near, the far level for far}; regions in neither are not listed
## (coarse only). A region is in the nearest tier whose radius contains the closest point of its
## rectangle, a tier with more candidates than slots keeps the nearest ones (near overflow
## competes for far), and [param previous] (the last plan) widens a region's own tier by
## [constant HYSTERESIS]. Small terrains (not tiered) list every region as near.
func plan_tiers(spec: Dictionary, point: Vector2, previous: Dictionary = {}) -> Dictionary:
	var grid := StrataRegions.grid_size(spec)
	var wanted := {}
	if not _is_tiered(spec):
		for y in range(grid.y):
			for x in range(grid.x): wanted[Vector2i(x, y)] = 0
		return wanted
	var extent := StrataRegions.extent(spec)
	var radius_near := near_radius if near_radius > 0.0 else NEAR_FACTOR * extent
	var radius_far := far_radius if far_radius > 0.0 else FAR_FACTOR * extent
	var level := _far_level_of(spec)
	var far_on := level > 0
	var count := grid.x * grid.y
	var near_cap := mini(near_slots, count)
	var far_cap := mini(far_slots, count) if far_on else 0
	var reach := (radius_far if far_on else radius_near) * HYSTERESIS
	var first := StrataRegions.region_at(spec, point - Vector2.ONE * reach).max(Vector2i.ZERO)
	var last := StrataRegions.region_at(spec, point + Vector2.ONE * reach).min(grid - Vector2i.ONE)
	var near_candidates: Array = []
	var far_candidates: Array = []
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			var xy := Vector2i(x, y)
			var distance := _distance(point, StrataRegions.region_bounds(spec, xy))
			var current: int = previous.get(xy, -1)
			if distance <= radius_near * (HYSTERESIS if current == 0 else 1.0):
				near_candidates.append([distance, xy])
			elif far_on and distance <= radius_far * (HYSTERESIS if current > 0 else 1.0):
				far_candidates.append([distance, xy])
	near_candidates.sort_custom(_by_distance)
	for index in range(near_candidates.size()):
		var entry: Array = near_candidates[index]
		if index < near_cap: wanted[entry[1]] = 0
		elif far_on: far_candidates.append(entry)
	far_candidates.sort_custom(_by_distance)
	var taken := 0
	for entry in far_candidates:
		if taken >= far_cap: break
		if wanted.has(entry[1]): continue
		wanted[entry[1]] = level
		taken += 1
	return wanted

static func _by_distance(a: Array, b: Array) -> bool:
	return a[0] < b[0]

## Plans the tiers for [param point], orders the wanted regions nearest first and, when the
## renderer shows this cache, releases the regions that left.
func _evaluate_tiers(point: Vector2) -> void:
	_tier_point = point
	_wanted = plan_tiers(_spec, point, _wanted)
	var ranked: Array = []
	for xy: Vector2i in _wanted: ranked.append([_distance(point, StrataRegions.region_bounds(_spec, xy)), xy])
	ranked.sort_custom(_by_distance)
	_order = []
	for entry in ranked: _order.append(entry[1])
	if _tiered and _renderer_bound and is_instance_valid(renderer):
		for xy: Vector2i in _bound.keys():
			if not _wanted.has(xy):
				renderer.release_region(xy)
				_bound.erase(xy)

## Re-plans the tiers for the current camera position and resumes composition. Normally called
## by the preview itself when the camera has moved a quarter of a region extent; public for tests.
func update_tiers() -> void:
	if not _tiered or _spec.is_empty(): return
	_evaluate_tiers(_camera_point())
	_working = true
	set_process(true)
	_pump(false)

## Tier of a region as the renderer shows it: 0 near, the far level, -1 coarse only (or not
## tiered and unbound).
func tier_of(xy: Vector2i) -> int:
	return int(_bound.get(xy, -1)) if _tiered else (0 if _renderer_bound and _regions.has(xy) else -1)

func get_wanted() -> Dictionary:
	return _wanted.duplicate()

# ─────────────────────────────────────────────
# Work: tasks on the worker pool, bound on the main thread
# ─────────────────────────────────────────────

func _process(_delta: float) -> void:
	_flush_coarse(false)
	if _tiered and _renderer_bound and not _spec.is_empty() and is_instance_valid(_camera):
		var point := _camera_point()
		if point.distance_to(_tier_point) >= StrataRegions.extent(_spec) * 0.25: update_tiers()
	if _working: _pump(false)
	elif not _tiered and not _coarse_dirty: set_process(false)

## Stops the work: waits for the tasks in flight, drops their results and discards the capture,
## so the next task captures the stack as it is then. Blocks for at most one task.
func _cancel_work() -> void:
	for entry: Dictionary in _flight: WorkerThreadPool.wait_for_task_completion(int(entry.id))
	_flight.clear()
	_flight_keys.clear()
	_epoch += 1
	_capture = {}
	_ctx = {}

func _limit() -> int:
	return max_in_flight if max_in_flight > 0 else maxi(OS.get_processor_count() * 2, 2)

func _make_task(kind: String, xy: Vector2i, level: int, classes: Array[String], key: String) -> Dictionary:
	var gens := {}
	for cls in classes: gens[cls] = int(_gen.get(cls, 0))
	return {"kind": kind, "xy": xy, "level": level, "classes": classes, "key": key, "gens": gens, "epoch": _epoch, "ctx": {}, "result": {}}

## Captures the stack once per epoch. False (and the work failed) when it cannot be captured.
func _ensure_capture() -> bool:
	if not _capture.is_empty(): return true
	var cap := StrataRegionCompose.capture(terrain, _selected, _spec)
	if not cap.get("ok", false):
		_fail(String(cap.get("message", "The stack could not be captured")))
		return false
	_capture = cap
	_ctx = {"terrain": terrain, "selected": _selected, "spec": _spec, "capture": cap, "material_ok": _material_problem().is_empty()}
	return true

func _submit(task: Dictionary) -> bool:
	if not _ensure_capture(): return false
	task.ctx = _ctx
	task.epoch = _epoch
	if OS.has_feature("threads"):
		var id := WorkerThreadPool.add_task(_work.bind(task), false, "Strata preview " + String(task.key))
		_flight.append({"id": id, "key": task.key, "task": task})
		_flight_keys[task.key] = true
	else:
		_work(task)
		_apply_task(task)
	_progress = true
	return true

## Worker entry: composes the classes of a task and stores the outcome in task.result. Reads
## only the task and the shared capture; touches no scene or script state.
static func _work(task: Dictionary) -> void:
	var ctx: Dictionary = task.ctx
	var images := {}
	var t0 := Time.get_ticks_msec()
	var coarse := String(task.kind) == "coarse"
	for cls: String in task.classes:
		var composed := _compose_class(ctx, cls, coarse, task.xy, int(task.level), Rect2i())
		if not composed.ok:
			task.result = composed
			return
		images.merge(composed.images, true)
	var result := {"ok": true, "message": "", "images": images}
	if not coarse and images.has(StrataRegions.MAP_HEIGHT):
		result["extrema"] = _extrema(ctx.spec, task.xy, images[StrataRegions.MAP_HEIGHT], int(task.level))
	task.result = result

## Collects finished tasks (waiting for one when [param wait]), binds results, submits more.
func _pump(wait: bool) -> void:
	if not _working: return
	_progress = false
	_collect(wait)
	if not _working: return
	var outstanding := _drive()
	if not _working: return
	if not outstanding and _flight.is_empty():
		_complete()
	elif not _progress and _flight.is_empty():
		push_warning("Strata preview: composition stalled (%d of %d regions ready); stopping." % [_fresh_count, _total_count])
		status = "Composition stalled; previous preview retained"
		_working = false
	else:
		_progress_status()

func _collect(wait: bool) -> void:
	if _flight.is_empty(): return
	if wait:
		var any := false
		for entry: Dictionary in _flight:
			if WorkerThreadPool.is_task_completed(int(entry.id)): any = true; break
		if not any: WorkerThreadPool.wait_for_task_completion(int((_flight[0] as Dictionary).id))
	var remaining: Array = []
	var finished: Array = []
	for entry: Dictionary in _flight:
		if WorkerThreadPool.is_task_completed(int(entry.id)):
			WorkerThreadPool.wait_for_task_completion(int(entry.id))
			finished.append(entry)
		else: remaining.append(entry)
	_flight = remaining
	for entry: Dictionary in finished:
		_flight_keys.erase(entry.key)
		var task: Dictionary = entry.task
		if int(task.epoch) != _epoch: continue
		if not _apply_task(task): return

## Stores a finished task's images in the cache and, where the renderer shows the entry, in the
## renderer. False when the work failed.
func _apply_task(task: Dictionary) -> bool:
	var result: Dictionary = task.result
	if result.is_empty() or not result.get("ok", false):
		_fail(String(result.get("message", "Composition returned nothing")))
		return false
	_progress = true
	var images: Dictionary = result.images
	var xy: Vector2i = task.xy
	var gens: Dictionary = task.gens
	match String(task.kind):
		"coarse":
			_coarse.merge(images, true)
			for cls in gens: _gens_coarse[cls] = gens[cls]
			_coarse_composed += gens.size()
			if _renderer_bound and is_instance_valid(renderer) and _stale(_gens_coarse).is_empty():
				_coarse_dirty = true
				_flush_coarse(true)
		"near":
			_region_compositions += 1
			_near_composed += 1
			var data: StrataRegionData = _regions.get(xy)
			if data == null:
				data = _new_region(xy)
				_regions[xy] = data
			var window_bound := _near_bound(xy)
			if images.has(StrataRegions.MAP_HEIGHT):
				var extrema: Dictionary = result.get("extrema", {})
				if extrema.get("ok", false): data.height_min = float(extrema.min); data.height_max = float(extrema.max)
			for name: String in images:
				if window_bound:
					if not _store(xy, name, images[name], Vector2i.ZERO):
						if _renderer_bound: _fail("Region %s map %s could not be updated" % [xy, name])
						return _working
				elif not data.set_image(name, images[name], 0, _spec.maps[name]):
					_fail("Region %s map %s does not match the spec" % [xy, name])
					return false
			var held: Dictionary = _gens_near.get(xy, {})
			for cls in gens: held[cls] = gens[cls]
			_gens_near[xy] = held
			if _entry_complete(held): _complete_maps(data)
			_touch(xy)
		_:
			_region_compositions += 1
			_far_composed += 1
			var data: StrataRegionData = _far.get(xy)
			if data == null:
				data = _new_region(xy)
				_far[xy] = data
			var level := int(task.level)
			for name: String in images:
				if not _set_level_image(data, name, images[name], level):
					_fail("Region %s map %s does not match the spec at level %d" % [xy, name, level])
					return false
			if images.has(StrataRegions.MAP_HEIGHT):
				var scanned: Dictionary = result.get("extrema", {})
				if scanned.get("ok", false): data.height_min = float(scanned.min); data.height_max = float(scanned.max)
			var held: Dictionary = _gens_far.get(xy, {})
			for cls in gens: held[cls] = gens[cls]
			_gens_far[xy] = held
			if _renderer_bound and _tiered and is_instance_valid(renderer) and _bound.get(xy, -1) == level:
				# A recomposed far region replaces its slot's content.
				if not renderer.set_region_level(xy, data, level): _fail("The renderer rejected far region %s" % xy); return false
			_touch(xy)
	return true

func _fail(message: String) -> void:
	_cancel_work()
	_signatures.clear()
	_working = false
	if is_instance_valid(renderer) and not _renderer_bound:
		# Nothing was ever bound: a configured renderer would draw a flat terrain at height 0, so
		# drop it (which brings the shaped untextured preview mesh back) until the next refresh.
		status = message + "; textured preview withheld until the stack composes"
		(renderer as Node).queue_free()
		renderer = null
		if is_instance_valid(terrain): terrain.editor_renderer = null
		_configuration_dirty = true
		return
	status = message + "; previous preview retained"

func _touch(xy: Vector2i) -> void:
	_use_counter += 1
	_used[xy] = _use_counter

## True when the renderer shows this region's level-0 entry (so edits must reach it).
func _near_bound(xy: Vector2i) -> bool:
	return is_instance_valid(renderer) and _renderer_bound and (not _tiered or _bound.get(xy, -1) == 0)

func _new_region(xy: Vector2i) -> StrataRegionData:
	var region := StrataRegionData.new()
	region.region = xy
	region.cells = int(_spec.cells)
	region.apron = int(_spec.apron)
	region.spacing = float(_spec.spacing)
	region.origin = StrataRegions.region_origin(_spec, xy)
	return region

## Gives a freshly composed level-0 region every spec map (a map no class composes starts neutral).
func _complete_maps(region: StrataRegionData) -> void:
	for name in _spec.maps:
		if region.has_map(name): continue
		var description: Dictionary = _spec.maps[name]
		var size := StrataRegions.map_size(_spec.cells, description)
		var image := Image.create(size.x, size.y, false, int(description.format))
		if name == StrataRegions.MAP_MACRO: image.fill(Color(1, 1, 1, 1))
		region.set_image(name, image, 0, description)

## Stores [param image] as level [param level] of a map of a far region. Lower levels exist only
## as zero bytes shared between all regions (copy on write), which keeps StrataRegionData
## valid (every stored level has its exact size) without paying for level 0.
func _set_level_image(data: StrataRegionData, name: String, image: Image, level: int) -> bool:
	var description: Dictionary = _spec.maps[name]
	var entry: Dictionary = data.maps.get(name, {})
	if entry.is_empty():
		entry = {"format": int(description.format), "kind": String(description.kind), "scale": int(description.get("scale", 1)), "apron": int(description.get("apron", _spec.apron)), "levels": []}
	if image.get_size() != StrataRegions.map_size(int(_spec.cells), entry, level) or image.get_format() != int(entry.format): return false
	var levels: Array = entry.levels
	while levels.size() <= level:
		levels.append(_zero_level(name, entry, levels.size()))
	levels[level] = image.get_data()
	entry["levels"] = levels
	data.maps[name] = entry
	data.revision += 1
	return true

func _zero_level(name: String, entry: Dictionary, level: int) -> PackedByteArray:
	var key := "%s/%d/%d" % [name, level, int(_spec.cells)]
	if not _zero_levels.has(key):
		var bytes := PackedByteArray()
		bytes.resize(StrataRegions.map_bytes(int(_spec.cells), entry, level))
		_zero_levels[key] = bytes
	return _zero_levels[key]

## Everything the pump does after collecting: installs the structure, binds tiers, lists and
## submits tasks. Returns whether anything is still outstanding.
func _drive() -> bool:
	var outstanding := false
	var tasks: Array = []
	var coarse_pending := false
	if _tiered:
		for cls in _stale(_gens_coarse):
			outstanding = true
			coarse_pending = true
			tasks.append(_make_task("coarse", Vector2i.ZERO, _coarse_level, [cls] as Array[String], "c|" + cls))
	var attached := is_instance_valid(renderer)
	if attached and not _renderer_bound:
		outstanding = true
		if _installable():
			if not _install(): return false
			outstanding = false
	_fresh_count = 0
	_total_count = _order.size()
	for xy in _order:
		var level: int = _wanted[xy]
		var gens: Dictionary = (_gens_far if level > 0 else _gens_near).get(xy, {})
		var stale := _stale(gens)
		if stale.is_empty():
			_fresh_count += 1
		else:
			outstanding = true
			tasks.append(_make_task("far" if level > 0 else "near", xy, level, stale, "%s|%d|%d" % ["f" if level > 0 else "n", xy.x, xy.y]))
	if attached and _renderer_bound and _tiered:
		var waiting := _bind_pass()
		if not _working: return false
		if waiting: outstanding = true
	# Coarse maps first: while they are outstanding the regions only get the processors they
	# leave.
	var limit := _limit()
	var cpus := maxi(OS.get_processor_count(), 1)
	var coarse_flight := 0
	var region_flight := 0
	for entry: Dictionary in _flight:
		if String(entry.key).begins_with("c|"): coarse_flight += 1
		else: region_flight += 1
	for task: Dictionary in tasks:
		if _flight_keys.has(task.key): continue
		if task.kind == "coarse":
			if _flight.size() >= limit: break
			if not _submit(task): return false
			coarse_flight += 1
		else:
			var allowed := maxi(cpus - coarse_flight, 0) if coarse_pending else limit - coarse_flight
			if region_flight >= allowed: break
			if not _submit(task): return false
			region_flight += 1
	if not _flight.is_empty(): outstanding = true
	return outstanding

## The renderer can take the cache's structure: a tiered terrain needs its coarse maps, a small
## one every region (stale classes are updated afterwards).
func _installable() -> bool:
	if _tiered:
		for cls in _present_classes():
			if not _gens_coarse.has(cls): return false
		return true
	for xy in _wanted:
		if not _entry_complete(_gens_near.get(xy, {})): return false
	return true

func _install() -> bool:
	var ok: bool
	if _tiered:
		ok = renderer.set_regions(_spec, {}, _residency(_spec, _coarse))
		if ok: _coarse_uploads += 1
	else:
		ok = renderer.set_regions(_spec, _regions.duplicate())
	if not ok:
		_fail("The renderer rejected the region set")
		_spec = {}
		return false
	_renderer_bound = true
	_coarse_dirty = false
	_bound.clear()
	_progress = true
	return true

## Binds wanted regions whose entry exists: demotions first (they free near slots), then the
## rest nearest first. True while a wanted region still cannot be bound (no data yet, or no free
## slot).
func _bind_pass() -> bool:
	var waiting := false
	for pass_index in range(2):
		for xy in _order:
			var level: int = _wanted[xy]
			var current: int = _bound.get(xy, -1)
			if current == level: continue
			if pass_index == 0 and not (current == 0 and level > 0): continue
			if pass_index == 1 and current == 0 and level > 0: continue
			var gens: Dictionary = (_gens_far if level > 0 else _gens_near).get(xy, {})
			var data: StrataRegionData = (_far if level > 0 else _regions).get(xy)
			if data == null or not _entry_complete(gens):
				waiting = true
				continue
			if renderer.free_slots(level) <= 0:
				waiting = true
				continue
			if not renderer.set_region_level(xy, data, level):
				_fail("The renderer rejected region %s at level %d" % [xy, level])
				return true
			_bound[xy] = level
			_progress = true
			_touch(xy)
	return waiting

func _complete() -> void:
	_working = false
	_trim_cache()
	_finish()

## Keeps at most [member cache_regions] level-0 regions that are neither bound nor wanted,
## dropping the least recently used.
func _trim_cache() -> void:
	if not _tiered: return
	var spare: Array = []
	for xy: Vector2i in _regions:
		if _wanted.has(xy) or _bound.get(xy, -1) == 0: continue
		spare.append([int(_used.get(xy, 0)), xy])
	if spare.size() <= cache_regions: return
	spare.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for index in range(spare.size() - cache_regions):
		var xy: Vector2i = spare[index][1]
		_regions.erase(xy)
		_gens_near.erase(xy)

func _progress_status() -> void:
	var phase := "coarse terrain" if _tiered and not _stale(_gens_coarse).is_empty() else "regions near the camera"
	status = "Composing live terrain regions (%s) %d/%d, %d tasks (no Houdini cook)" % [phase, _fresh_count, _total_count, _flight.size()]

## Text for the editor toolbar while the preview works, "" when idle.
func progress_text() -> String:
	if not _working and not _pending: return ""
	return status

func _finish() -> void:
	_material_status = _material_problem()
	if _material_status.is_empty() and _spec.maps.has(StrataRegions.MAP_MATERIAL_IDS) and not _holds_material_samples():
		_material_status = "Materials unassigned at this stage"
	status = "Live stack through %s · %d regions · no automatic cook" % [_cutoff.name if _cutoff != null else "final layer", _region_count_of(_spec)]
	if _tiered: status += " · %d near, %d far, coarse %s" % [_count_bound(0), _count_bound(1), "ready" if _stale(_gens_coarse).is_empty() else "pending"]
	if not _material_status.is_empty(): status += " · " + _material_status
	refreshed.emit()

func _count_bound(kind: int) -> int:
	var total := 0
	for xy: Vector2i in _bound:
		if (_bound[xy] == 0) == (kind == 0): total += 1
	return total

## True when an enabled layer through the cutoff holds a material channel.
func _holds_material_samples() -> bool:
	for layer in terrain.get_layers():
		if layer.enabled:
			var names := layer.get_channel_names()
			for channel in terrain.editor_material_channels:
				if names.has(channel): return true
		if layer == _cutoff: break
	return false

# ─────────────────────────────────────────────
# Composition
# ─────────────────────────────────────────────

## Window of a map over a region (or, [param coarse], the whole terrain) at a level, over the
## complete map (rect empty) or a texel rectangle of it.
static func _class_window(spec: Dictionary, name: String, coarse: bool, xy: Vector2i, level: int, rect: Rect2i) -> Dictionary:
	var window: Dictionary
	if coarse: window = StrataRegions.coarse_window(spec, spec.maps[name], level)
	else: window = StrataRegions.map_window(spec, xy, spec.maps[name], level)
	if rect.has_area():
		window.first = (window.first as Vector2i) + rect.position
		window.size = rect.size
		window.origin = (window.origin as Vector2) + Vector2(rect.position) * float(window.step)
	return window

## Composes one map class of a region at a level (or of the whole terrain at the coarse level)
## through ctx.capture when present; returns {ok, message, images: {map: Image}}. Static and
## free of script state so a worker can run it; without a capture it must run on the main thread.
static func _compose_class(ctx: Dictionary, cls: String, coarse: bool, xy: Vector2i, level: int, rect: Rect2i) -> Dictionary:
	var spec: Dictionary = ctx.spec
	var terrain: StrataTerrain3D = ctx.terrain
	var selected: StrataLayer = ctx.selected
	var capture: Dictionary = ctx.capture
	var options := {"capture": capture} if not capture.is_empty() else {}
	match cls:
		CLASS_HEIGHT:
			var composed := StrataRegionCompose.compose_map(terrain, selected, StrataRegions.MAP_HEIGHT, _class_window(spec, StrataRegions.MAP_HEIGHT, coarse, xy, level, rect), spec, options)
			if not composed.ok: return composed
			return {"ok": true, "message": "", "images": {StrataRegions.MAP_HEIGHT: composed.image}}
		CLASS_HOLES:
			var mask := _compose_mask(terrain, selected, _class_window(spec, StrataRegions.MAP_HOLES, coarse, xy, level, rect), spec, options)
			if not mask.ok: return mask
			return {"ok": true, "message": "", "images": {StrataRegions.MAP_HOLES: mask.image}}
		CLASS_MATERIALS:
			var window := _class_window(spec, StrataRegions.MAP_MATERIAL_IDS, coarse, xy, level, rect)
			if not bool(ctx.material_ok):
				var size: Vector2i = window.size
				return {"ok": true, "message": "", "images": {StrataRegions.MAP_MATERIAL_IDS: Image.create(size.x, size.y, false, Image.FORMAT_RGBA8), StrataRegions.MAP_MATERIAL_WEIGHTS: Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)}}
			var packed := StrataRegionCompose.compose_map(terrain, selected, StrataRegions.MAP_MATERIAL_IDS, window, spec, options)
			if not packed.ok: return packed
			return {"ok": true, "message": "", "images": {StrataRegions.MAP_MATERIAL_IDS: packed.ids, StrataRegions.MAP_MATERIAL_WEIGHTS: packed.weights}}
		_:
			var macro := StrataRegionCompose.compose_map(terrain, selected, StrataRegions.MAP_MACRO, _class_window(spec, StrataRegions.MAP_MACRO, coarse, xy, level, rect), spec, options)
			if not macro.ok: return macro
			return {"ok": true, "message": "", "images": {StrataRegions.MAP_MACRO: macro.image}}

## Cell masks compose over square windows; a window that is not square (the coarse mask of a
## terrain that is not square, a dab rectangle) is composed in square tiles that overlap at
## their ends.
static func _compose_mask(terrain: StrataTerrain3D, selected: StrataLayer, window: Dictionary, spec: Dictionary, options: Dictionary) -> Dictionary:
	var size: Vector2i = window.size
	if size.x == size.y: return StrataRegionCompose.compose_map(terrain, selected, StrataRegions.MAP_HOLES, window, spec, options)
	var side := mini(size.x, size.y)
	var image := Image.create(size.x, size.y, false, int(spec.maps[StrataRegions.MAP_HOLES].format))
	var y := 0
	while y < size.y:
		var ty := mini(y, size.y - side)
		var x := 0
		while x < size.x:
			var tx := mini(x, size.x - side)
			var tile := window.duplicate()
			tile.first = (window.first as Vector2i) + Vector2i(tx, ty)
			tile.size = Vector2i(side, side)
			tile.origin = (window.origin as Vector2) + Vector2(tx, ty) * float(window.step)
			var composed := StrataRegionCompose.compose_map(terrain, selected, StrataRegions.MAP_HOLES, tile, spec, options)
			if not composed.ok: return composed
			image.blit_rect(composed.image, Rect2i(Vector2i.ZERO, Vector2i(side, side)), Vector2i(tx, ty))
			x += side
		y += side
	return {"ok": true, "message": "", "image": image}

## Height extrema of a composed region map: over the terrain's own samples at level 0 (apron and
## the part past the bounds excluded, as StrataRegionCompose.compose), over the whole image at a
## far level.
static func _extrema(spec: Dictionary, xy: Vector2i, image: Image, level: int) -> Dictionary:
	if level > 0: return StrataLayerData.validate_dense(image)
	var cells := int(spec.cells)
	var apron := int(spec.apron)
	var real := StrataRegions.terrain_samples(spec)
	var count := Vector2i(mini(cells + 1, real.x - xy.x * cells), mini(cells + 1, real.y - xy.y * cells))
	return StrataLayerData.validate_dense(image.get_region(Rect2i(apron, apron, count.x, count.y)))

## Main-thread composition for dabs (no capture: reads the live layers).
func _compose_sync(cls: String, xy: Vector2i, level: int, rect: Rect2i, coarse: bool = false) -> Dictionary:
	_region_compositions += 1
	var ctx := {"terrain": terrain, "selected": terrain.preview_through_layer, "spec": _spec, "capture": {}, "material_ok": _material_problem().is_empty()}
	var composed := _compose_class(ctx, cls, coarse, xy, level, rect)
	if not composed.ok:
		status = String(composed.message)
		return {}
	return composed.images

## Writes a composed image (or a window of one) into the cached region and the renderer.
func _store(xy: Vector2i, name: String, image: Image, origin: Vector2i) -> bool:
	var data: StrataRegionData = _regions.get(xy)
	if data == null: return false
	var full := origin == Vector2i.ZERO and image.get_size() == StrataRegions.map_size(_spec.cells, _spec.maps[name])
	if full:
		if not data.set_image(name, image): return false
	elif not data.blit(name, 0, image, origin): return false
	if name == StrataRegions.MAP_HEIGHT and not full: _recompute_extrema(data)
	if _near_bound(xy) and not renderer.update_region_window(xy, name, image, origin):
		push_warning("Strata preview: the renderer rejected the %s window of region %s (%s at %s); rebinding the regions." % [name, xy, image.get_size(), origin])
		_renderer_bound = false
		request_refresh()
		return false
	return true

func _recompute_extrema(data: StrataRegionData) -> void:
	var description := data.description(StrataRegions.MAP_HEIGHT)
	var apron := int(description.apron)
	var side := StrataRegions.texels_per_axis(data.cells, description, 0) + 1
	var real := StrataRegions.terrain_samples(_spec)
	var count := Vector2i(mini(side, real.x - data.region.x * data.cells), mini(side, real.y - data.region.y * data.cells))
	var scanned: Dictionary = StrataLayerData.validate_dense(data.get_image(StrataRegions.MAP_HEIGHT, 0).get_region(Rect2i(apron, apron, count.x, count.y)))
	if scanned.get("ok", false):
		data.height_min = float(scanned.min); data.height_max = float(scanned.max)

# ─────────────────────────────────────────────
# Coarse upload
# ─────────────────────────────────────────────

## Uploads the coarse maps when they changed and [member coarse_upload_ms] have passed since the
## last upload (always with [param force]).
func _flush_coarse(force: bool) -> void:
	if not _coarse_dirty: return
	var now := Time.get_ticks_msec()
	if not force and now < _coarse_next_ms: return
	if not is_instance_valid(renderer) or not _renderer_bound or not _stale(_gens_coarse).is_empty():
		_coarse_dirty = false
		return
	_coarse_dirty = false
	_coarse_next_ms = now + coarse_upload_ms
	_coarse_uploads += 1
	if not renderer.set_coarse_maps(_coarse_level, _coarse):
		push_warning("Strata preview: the renderer rejected the coarse maps; refreshing.")
		_signatures.clear()
		request_refresh()

## Uploads pending coarse changes now (a stroke ended, tests).
func flush_coarse() -> void:
	_flush_coarse(true)

# ─────────────────────────────────────────────
# Brush dabs
# ─────────────────────────────────────────────

## Small brush dirty rectangle; the caches describe exactly the updated stack afterwards.
## Call just before the dab; also records which map classes are current. When composition is
## outstanding this waits for the tasks in flight (they read the layers the dab is about to
## change), drops them and returns false, so the dab falls back to a refresh.
func can_patch_region() -> bool:
	sync_configuration()
	_patchable.clear()
	if not _flight.is_empty():
		_cancel_work()
		_queue_refresh()
		return false
	if _configuration_dirty or not _attached() or _working or _spec.is_empty(): return false
	var selected := terrain.preview_through_layer
	if _make_spec() != _spec or is_instance_valid(renderer) and renderer._render_bounds != terrain.base_bounds: return false
	for cls in CLASSES:
		if _present(cls, _spec):
			_patchable[cls] = _signatures.has(cls) and _signatures[cls] == _class_state(cls, selected) and _stale_free(cls)
			_owned_keys[cls] = _owned_key(cls, selected)
	return true

## True when every entry the dab could touch is composed from the class's current generation.
func _stale_free(cls: String) -> bool:
	for xy: Vector2i in _wanted:
		if int((_gens_far if int(_wanted[xy]) > 0 else _gens_near).get(xy, {}).get(cls, -1)) != int(_gen.get(cls, 0)): return false
	return not _tiered or int(_gens_coarse.get(cls, -1)) == int(_gen.get(cls, 0))

func refresh_region(point: Vector2, radius: float, native_spacing: float, channel: StringName = &"height", was_current: bool = false) -> void:
	# Only a dab that began on the current complete surface may update the caches.
	# A queued cutoff/configuration/external edit must first compose the full view.
	var patchable := _patchable
	_patchable = {}
	var step := terrain.region_spacing if is_instance_valid(terrain) else 0.0
	if not was_current or _configuration_dirty or not _attached() or _working or not _flight.is_empty() or _spec.is_empty() or _cutoff != terrain.preview_through_layer or _make_spec() != _spec or not is_finite(step) or step <= 0.0:
		request_refresh(); return
	var selected := terrain.preview_through_layer
	var margin := radius + maxf(step * 2.0, native_spacing * 2.0)
	var area := Rect2(point - Vector2.ONE * margin, Vector2.ONE * margin * 2.0)
	var affected := _class_of_channel(channel)
	# Anything else the dab changed (a brush that wrote a second class) is caught by the
	# queued refresh: its signature no longer matches the cache.
	var started := Time.get_ticks_usec()
	var same_ownership: bool = affected.is_empty() or affected in [CLASS_HEIGHT, CLASS_HOLES] or _owned_key(affected, selected) == _owned_keys.get(affected)
	var patched: bool = affected.is_empty() or (same_ownership and patchable.get(affected, false) and _present(affected, _spec) and _patch_class(affected, area, selected))
	if not patched:
		request_refresh(); return
	# The dab changed the layers: the next task captures the stack again.
	_capture = {}
	_ctx = {}
	if not affected.is_empty():
		_signatures[affected] = _class_state(affected, selected)
		if affected == CLASS_MATERIALS: _material_regions += 1
	for cls in CLASSES:
		if cls != affected and _present(cls, _spec) and patchable.get(cls, false) and _signatures.get(cls) != _class_state(cls, selected):
			_signatures.erase(cls)
			request_refresh()
	_region_count += 1
	_last_patch_ms = (Time.get_ticks_usec() - started) / 1000.0
	# Everything below is channel-specific; the channel preview patches its rectangle.
	_aux_dirty = false
	_cutoff = selected
	if is_instance_valid(renderer):
		if terrain.editor_show_channel and channel == terrain.override_channel and not _refresh_channel_region(point, margin): _refresh_channel()
		if terrain.show_overrides: renderer.set_ownership_overlay(_cutoff, terrain.override_channel)

var _last_patch_ms := 0.0

## Recomposes what a dab over [param area] changed for the maps of [param cls]: in every cached
## near region it touches the texel rectangles on the regions' own lattices (the renderer is
## patched with update_region_window), in every far region it touches the far-level maps
## (rebound), and the coarse texels under it (uploaded throttled). Regions in no tier and
## without a cache entry have nothing to update.
func _patch_class(cls: String, area: Rect2, selected: StrataLayer) -> bool:
	var first_map: String = (_class_maps(cls) as Array)[0]
	var description: Dictionary = _spec.maps[first_map]
	var exact := _exact_windows()
	var size := StrataRegions.map_size(_spec.cells, description)
	var far_level_used := _far_level_of(_spec)
	for xy in StrataRegions.regions_touching(_spec, area, description):
		if not _wanted.has(xy) and not _regions.has(xy) and not _far.has(xy):
			if _tiered: continue
			return false
		if _far.has(xy) and far_level_used > 0 and not _patch_far(cls, xy): return false
		if not _regions.has(xy):
			if _tiered: continue
			return false
		var rect := StrataRegions.texel_rect(_spec, xy, description, area)
		if not rect.has_area(): continue
		var window := StrataRegions.map_window(_spec, xy, description)
		if not exact:
			rect = Rect2i(Vector2i.ZERO, size)
		else:
			# Start at the region's own first texel where the lattice index would be negative, so
			# the shifted origin equals the complete map's; the native packs want two texels.
			var begin := rect.position
			var end := rect.end
			for axis in range(2):
				if int(window.first[axis]) + begin[axis] < 0: begin[axis] = 0
			end = end.max(begin + Vector2i(2, 2)).min(size)
			begin = begin.min(end - Vector2i(2, 2)).max(Vector2i.ZERO)
			if String(description.kind) == StrataRegions.KIND_CELL:
				# Cell masks compose over square windows.
				var side := maxi(end.x - begin.x, end.y - begin.y)
				begin = Vector2i(mini(begin.x, size.x - side), mini(begin.y, size.y - side)).max(Vector2i.ZERO)
				end = begin + Vector2i(side, side)
			rect = Rect2i(begin, end - begin)
		var whole := rect == Rect2i(Vector2i.ZERO, size)
		var images := _compose_sync(cls, xy, 0, Rect2i() if whole else rect)
		if images.is_empty(): return false
		for name in images:
			if not _store(xy, name, images[name], rect.position): return false
		_touch(xy)
	if _tiered and not _patch_coarse(cls, area): return false
	return true

## Recomposes a far region's far-level maps of a class and rebinds them.
func _patch_far(cls: String, xy: Vector2i) -> bool:
	var level := _far_level_of(_spec)
	var images := _compose_sync(cls, xy, level, Rect2i())
	if images.is_empty(): return false
	var data: StrataRegionData = _far[xy]
	for name in images:
		if not _set_level_image(data, name, images[name], level): return false
		if name == StrataRegions.MAP_HEIGHT:
			var scanned := _extrema(_spec, xy, images[name], level)
			if scanned.get("ok", false): data.height_min = float(scanned.min); data.height_max = float(scanned.max)
	_far_patches += 1
	if _renderer_bound and is_instance_valid(renderer) and _bound.get(xy, -1) == level and not renderer.set_region_level(xy, data, level): return false
	return true

## Recomposes the coarse texels a dab over [param area] covers and marks the maps for upload.
func _patch_coarse(cls: String, area: Rect2) -> bool:
	if not _stale(_gens_coarse).is_empty(): return false
	var description: Dictionary = _spec.maps[(_class_maps(cls) as Array)[0]]
	var window := StrataRegions.coarse_window(_spec, description, _coarse_level)
	var size: Vector2i = window.size
	var step := float(window.step)
	var begin := Vector2i(((area.position - (window.origin as Vector2)) / step).floor()).max(Vector2i.ZERO)
	var end := (Vector2i(((area.end - (window.origin as Vector2)) / step).ceil()) + Vector2i.ONE).min(size)
	if end.x <= begin.x or end.y <= begin.y: return true
	if String(description.kind) == StrataRegions.KIND_SAMPLE:
		end = end.max(begin + Vector2i(2, 2)).min(size)
		begin = begin.min(end - Vector2i(2, 2)).max(Vector2i.ZERO)
	var rect := Rect2i(begin, end - begin)
	var images := _compose_sync(cls, Vector2i.ZERO, _coarse_level, Rect2i() if rect == Rect2i(Vector2i.ZERO, size) else rect, true)
	if images.is_empty(): return false
	for name in images:
		var target: Image = _coarse.get(name)
		var image: Image = images[name]
		if target == null: return false
		target.blit_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), rect.position)
	_coarse_dirty = true
	set_process(true)
	_flush_coarse(false)
	return true

## Windowed composition equals the complete map when lattice positions are exact doubles
## (spacings that are powers of two); otherwise whole region maps are recomposed.
func _exact_windows() -> bool:
	var exponent := roundf(log(float(_spec.spacing)) / log(2.0))
	return pow(2.0, exponent) == float(_spec.spacing)


# ─────────────────────────────────────────────
# Channel preview (a debug map, unchanged)
# ─────────────────────────────────────────────

func _refresh_channel() -> void:
	_last_channel = terrain.override_channel
	_last_channel_visible = terrain.editor_show_channel
	if not terrain.editor_show_channel:
		_channel_image = null
		renderer.set_channel_preview(null, terrain.base_bounds, false)
		return
	# Scalar diagnostic only: bounded 4 m lattice, independent of exact cell holes.
	var resolution := Vector2i(ceili(terrain.base_bounds.size.x / 4.0) + 1, ceili(terrain.base_bounds.size.y / 4.0) + 1)
	var step := terrain.base_bounds.size / Vector2(resolution - Vector2i.ONE)
	var origin := Vector3(terrain.base_bounds.position.x, 0.0, terrain.base_bounds.position.y)
	var field: Dictionary = StrataLayerData.compose_dense(StrataProcedural._capture_layers(terrain, terrain.override_channel, terrain.preview_through_layer), terrain.override_channel, origin, Vector3(step.x, 0, 0), Vector3(0, 0, step.y), resolution, terrain.base_bounds, false, 0.0)
	_channel_image = field.image if field.get("ok", false) else null
	_channel_image_name = terrain.override_channel
	if field.get("ok", false): renderer.set_channel_preview(field.image, terrain.base_bounds, true)

## Texel rectangle of an endpoint-aligned lattice over the terrain bounds that a dab of
## [param margin] around [param point] can change.
func _lattice_window(size: Vector2i, point: Vector2, margin: float) -> Rect2i:
	var bounds := terrain.base_bounds
	var step := bounds.size / Vector2(size - Vector2i.ONE)
	var begin := Vector2i(((point - Vector2.ONE * margin - bounds.position) / step).floor()).max(Vector2i.ZERO)
	var end := Vector2i(((point + Vector2.ONE * margin - bounds.position) / step).ceil()).min(size - Vector2i.ONE)
	return Rect2i(begin, end - begin + Vector2i.ONE)

## Recomposes the dab's rectangle of the scalar channel preview. False when there is no
## matching full preview to patch.
func _refresh_channel_region(point: Vector2, margin: float) -> bool:
	if _channel_image == null or _channel_image_name != terrain.override_channel or not StrataMaterialControls._native(&"compose_dense_window"): return false
	var size := _channel_image.get_size()
	if size != Vector2i(ceili(terrain.base_bounds.size.x / 4.0) + 1, ceili(terrain.base_bounds.size.y / 4.0) + 1): return false
	var window := _lattice_window(size, point, margin)
	if not window.has_area(): return false
	var step := terrain.base_bounds.size / Vector2(size - Vector2i.ONE)
	var origin := Vector3(terrain.base_bounds.position.x, 0.0, terrain.base_bounds.position.y)
	var field: Dictionary = ClassDB.class_call_static(&"StrataLayerData", &"compose_dense", StrataProcedural._capture_layers(terrain, terrain.override_channel, terrain.preview_through_layer), terrain.override_channel, origin, Vector3(step.x, 0, 0), Vector3(0, 0, step.y), window.size, terrain.base_bounds, false, 0.0, window.position)
	if not field.get("ok", false): return false
	_channel_image.blit_rect(field.image, Rect2i(Vector2i.ZERO, window.size), window.position)
	_last_channel = terrain.override_channel
	_last_channel_visible = true
	return renderer.set_channel_preview(_channel_image, terrain.base_bounds, true)


func get_stats() -> Dictionary:
	return {"full_compiles": _compile_count, "region_compiles": _region_count, "material_compositions": _material_compositions, "material_regions": _material_regions, "region_compositions": _region_compositions, "regions": _regions.size(), "last_patch_ms": _last_patch_ms, "status": status,
		"tiered": _tiered, "near_bound": _count_bound(0) if _tiered else (_regions.size() if _renderer_bound else 0), "far_bound": _count_bound(1) if _tiered else 0, "far_cached": _far.size(),
		"near_composed": _near_composed, "far_composed": _far_composed, "coarse_composed": _coarse_composed, "coarse_uploads": _coarse_uploads, "far_patches": _far_patches, "pending_tasks": _flight.size(), "coarse_level": _coarse_level}

## The composed level-0 region at a grid index, or null (the cache the renderer shows; a
## tiered terrain caches only its near regions and a few recently used ones).
func get_region(xy: Vector2i) -> StrataRegionData:
	return _regions.get(xy)

## The far-level region (only its far-level maps are filled), or null.
func get_far_region(xy: Vector2i) -> StrataRegionData:
	return _far.get(xy)

## The coarse maps the renderer shows (a copy of the dictionary; the images are shared).
func get_coarse_maps() -> Dictionary:
	return _coarse.duplicate()

func get_spec() -> Dictionary:
	return _spec.duplicate(true)

func _exit_tree() -> void:
	_cancel_work()
	if is_instance_valid(terrain):
		terrain.editor_renderer = null
		terrain.editor_preview_bridge = null
	if renderer is Node and is_instance_valid(renderer): (renderer as Node).queue_free()
