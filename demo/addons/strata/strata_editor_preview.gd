@tool
class_name StrataEditorPreview
extends Node
## Editor/authoring-view bridge: compose the live authoring stack, never run a producer.
##
## The preview is a set of regions (StrataRegions, docs/development/terrain_renderer_regions.md)
## composed through the selected layer with StrataRegions.compose_region() and bound to the
## renderer with set_regions(). A full refresh composes in two time-sliced passes (height and
## holes of every region, then materials and macro tint) so the editor stays responsive; later
## refreshes recompose only the map classes whose stack signature changed, and a brush dab
## recomposes only the texel rectangle it touches in the regions it touches, bit for bit what a
## complete composition gives. A height dab never recomposes materials, a material dab never
## height.
signal refreshed
## Map classes and the stack channels each depends on. Their signatures are the cache keys.
const CLASS_HEIGHT := "height"
const CLASS_HOLES := "holes"
const CLASS_MATERIALS := "materials"
const CLASS_MACRO := "macro"
const CLASSES: Array[String] = [CLASS_HEIGHT, CLASS_HOLES, CLASS_MATERIALS, CLASS_MACRO]
## Milliseconds of composition per frame while a refresh runs sliced.
const SLICE_MS := 4.0
const _TASK_BASE := "base"

var terrain: StrataTerrain3D
var renderer: StrataRenderer
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
# The cache: regions composed for _spec, the signature of the stack each class was composed
# from, and whether the renderer shows exactly these regions.
var _spec: Dictionary = {}
var _regions: Dictionary = {}
var _signatures: Dictionary = {}
var _renderer_bound := false
# Running sliced refresh: {selected, spec, tasks, index, bind_at, structural, regions, states}.
var _job: Dictionary = {}
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

func request_refresh() -> void:
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

## True while a refresh is queued or still composing sliced.
func is_busy() -> bool:
	return _pending or not _job.is_empty()

## Runs a refresh and finishes its composition at once instead of slicing it; for tests and
## scripts. Returns whether the cache and renderer are current afterwards.
func refresh_now() -> bool:
	_pending = false
	_refresh()
	while not _job.is_empty(): _run_job(INF)
	return _job.is_empty() and (renderer == null or _renderer_bound)

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
	var job := _plan(selected, spec)
	if not is_instance_valid(renderer): return
	renderer.render_settings = terrain.render_settings
	if _aux_dirty or _last_channel != terrain.override_channel or _last_channel_visible != terrain.editor_show_channel:
		_refresh_channel()
	_aux_dirty = false
	renderer.set_ownership_overlay(selected, terrain.override_channel, terrain.show_overrides and selected != null)
	_cutoff = selected
	if job.is_empty(): _finish()
	else:
		_job = job
		set_process(true)
		_progress_status()

## Creates or reconfigures the renderer when the configuration changed. It is configured with
## the spec and no regions; the composed regions are bound afterwards with set_regions.
func _configure_renderer() -> bool:
	if is_instance_valid(renderer) and not _configuration_dirty: return true
	if _configuration_failed: return false
	var spec := _make_spec()
	if not is_instance_valid(renderer):
		renderer = StrataRenderer.new()
		renderer.name = "TexturedEditorPreview"
		renderer.render_settings = terrain.render_settings
		terrain.add_child(renderer, false, Node.INTERNAL_MODE_BACK)
		renderer.set_camera(_camera)
		if not renderer.configure_regions(terrain, terrain.editor_materials, spec, {}):
			renderer.queue_free(); renderer = null
			status = "Textured preview requires Forward+ and valid materials"
			_configuration_failed = true
			return false
		terrain.editor_renderer = renderer
	elif not renderer.configure_regions(terrain, terrain.editor_materials, spec, {}):
		# Configuration is transactional, including the rendered regions.
		status = "Invalid material/control configuration; previous rendered terrain retained"
		_configuration_failed = true
		return false
	_configuration_dirty = false
	_renderer_bound = false
	_aux_dirty = true
	return true

## Composes the cache for the current stack without a renderer (tests, scripts): the same
## job a refresh runs, completed at once. False with the reason in [member status] on failure.
func compose_cache() -> bool:
	if not is_instance_valid(terrain) or not terrain.is_inside_tree(): return false
	terrain._sanitize_preview_layer()
	var spec := _make_spec()
	if not StrataRegions.validate_spec(spec).ok: return false
	sync_configuration()
	if not is_instance_valid(renderer): _configuration_dirty = false
	_cutoff = terrain.preview_through_layer
	var job := _plan(_cutoff, spec)
	if job.is_empty(): return true
	_job = job
	while not _job.is_empty(): _run_job(INF)
	return _spec == spec and _job.is_empty()

## Decides what the stack changed since the cache was composed and returns the job that
## recomposes it ({} when the cache is current). Binds cached regions to a renderer that
## lost them (reconfiguration) at once.
func _plan(selected: StrataLayer, spec: Dictionary) -> Dictionary:
	var structural := spec != _spec or _regions.is_empty()
	if structural:
		# A new layout starts over; the old regions stay bound until the new ones are ready.
		_signatures.clear()
	elif is_instance_valid(renderer) and not _renderer_bound:
		_renderer_bound = renderer.set_regions(_spec, _regions)
	var states := {}
	var dirty: Array[String] = []
	for cls in CLASSES:
		if not _present(cls, spec): continue
		states[cls] = _class_state(cls, selected)
		if structural or _signatures.get(cls) != states[cls]: dirty.append(cls)
	if dirty.is_empty() and not structural:
		# A class that left the spec (the last tint layer disabled) cannot reach here:
		# the spec differs then.
		return {}
	var tasks: Array = []
	var grid := StrataRegions.grid_size(spec)
	if structural:
		for y in range(grid.y):
			for x in range(grid.x): tasks.append([_TASK_BASE, Vector2i(x, y)])
	else:
		for cls in [CLASS_HEIGHT, CLASS_HOLES]:
			if dirty.has(cls):
				for y in range(grid.y):
					for x in range(grid.x): tasks.append([cls, Vector2i(x, y)])
	var bind_at := tasks.size()
	for cls in [CLASS_MATERIALS, CLASS_MACRO]:
		if dirty.has(cls):
			for y in range(grid.y):
				for x in range(grid.x): tasks.append([cls, Vector2i(x, y)])
	return {"selected": selected, "spec": spec, "tasks": tasks, "index": 0, "bind_at": bind_at, "structural": structural, "regions": {}, "states": states, "dirty": dirty, "started": Time.get_ticks_usec(), "problem": ""}

func _process(_delta: float) -> void:
	if _job.is_empty():
		set_process(false)
		return
	_run_job(SLICE_MS)

## Composes tasks until [param budget_ms] is spent.
func _run_job(budget_ms: float) -> void:
	var started := Time.get_ticks_usec()
	var tasks: Array = _job.tasks
	while int(_job.index) < tasks.size():
		var task: Array = tasks[_job.index]
		if not _run_task(String(task[0]), task[1]):
			_abort_job()
			return
		_job.index = int(_job.index) + 1
		if bool(_job.structural) and int(_job.index) == int(_job.bind_at) and not _install_structure(): _abort_job(); return
		if (Time.get_ticks_usec() - started) / 1000.0 >= budget_ms: break
	if int(_job.index) >= tasks.size():
		_commit_job()
	else:
		_progress_status()

func _progress_status() -> void:
	var tasks: Array = _job.tasks
	var phase := "height and holes" if int(_job.index) < int(_job.bind_at) else "materials and tint"
	status = "Composing live terrain regions (%s) %d/%d (no Houdini cook)" % [phase, int(_job.index), tasks.size()]

func _abort_job() -> void:
	var message := String(_job.get("problem", ""))
	_job = {}
	if not message.is_empty(): status = message + "; previous preview retained"

func _commit_job() -> void:
	for cls in _job.states:
		if (_job.dirty as Array).has(cls): _signatures[cls] = _job.states[cls]
	if _job.dirty.has(CLASS_HEIGHT): _compile_count += 1
	if _job.dirty.has(CLASS_MATERIALS): _material_compositions += 1
	_job = {}
	_finish()

func _finish() -> void:
	_material_status = _material_problem()
	if _material_status.is_empty() and _spec.maps.has(StrataRegions.MAP_MATERIAL_IDS) and not _holds_material_samples():
		_material_status = "Materials unassigned at this stage"
	status = "Live stack through %s · %d regions · no automatic cook" % [_cutoff.name if _cutoff != null else "final layer", _regions.size()]
	if not _material_status.is_empty(): status += " · " + _material_status
	refreshed.emit()

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
# Tasks
# ─────────────────────────────────────────────

## Windows of a region's map over the complete map (rect empty) or a texel rectangle of it.
func _window(spec: Dictionary, xy: Vector2i, name: String, rect: Rect2i = Rect2i()) -> Dictionary:
	var window := StrataRegions.map_window(spec, xy, spec.maps[name])
	if rect.has_area():
		window.first = (window.first as Vector2i) + rect.position
		window.size = rect.size
		window.origin = (window.origin as Vector2) + Vector2(rect.position) * float(window.step)
	return window

## Composes one class of one region. Returns {map name: Image} or {} with the job's problem
## set. [param rect] limits the composition to a texel rectangle of the maps.
func _compose_class(cls: String, xy: Vector2i, spec: Dictionary, selected: StrataLayer, rect: Rect2i = Rect2i()) -> Dictionary:
	_region_compositions += 1
	match cls:
		CLASS_HEIGHT:
			var composed := StrataRegionCompose.compose_map(terrain, selected, StrataRegions.MAP_HEIGHT, _window(spec, xy, StrataRegions.MAP_HEIGHT, rect), spec)
			if not composed.ok: return _problem(String(composed.message))
			return {StrataRegions.MAP_HEIGHT: composed.image}
		CLASS_HOLES:
			var mask := StrataRegionCompose.compose_map(terrain, selected, StrataRegions.MAP_HOLES, _window(spec, xy, StrataRegions.MAP_HOLES, rect), spec)
			if not mask.ok: return _problem(String(mask.message))
			return {StrataRegions.MAP_HOLES: mask.image}
		CLASS_MATERIALS:
			var window := _window(spec, xy, StrataRegions.MAP_MATERIAL_IDS, rect)
			if not _material_problem().is_empty():
				var size: Vector2i = window.size
				return {StrataRegions.MAP_MATERIAL_IDS: Image.create(size.x, size.y, false, Image.FORMAT_RGBA8), StrataRegions.MAP_MATERIAL_WEIGHTS: Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)}
			var packed := StrataRegionCompose.compose_map(terrain, selected, StrataRegions.MAP_MATERIAL_IDS, window, spec)
			if not packed.ok: return _problem(String(packed.message))
			return {StrataRegions.MAP_MATERIAL_IDS: packed.ids, StrataRegions.MAP_MATERIAL_WEIGHTS: packed.weights}
		_:
			var macro := StrataRegionCompose.compose_map(terrain, selected, StrataRegions.MAP_MACRO, _window(spec, xy, StrataRegions.MAP_MACRO, rect), spec)
			if not macro.ok: return _problem(String(macro.message))
			return {StrataRegions.MAP_MACRO: macro.image}

func _problem(message: String) -> Dictionary:
	if not _job.is_empty(): _job.problem = message
	else: status = message
	return {}

func _run_task(kind: String, xy: Vector2i) -> bool:
	var spec: Dictionary = _job.spec
	var selected: StrataLayer = _job.selected
	if kind == _TASK_BASE:
		# Height and holes through compose_region (it also finds the height extrema); the
		# other maps start neutral and are filled by the second pass.
		var sub := spec.duplicate(true)
		for name in sub.maps.keys():
			if name not in [StrataRegions.MAP_HEIGHT, StrataRegions.MAP_HOLES]: sub.maps.erase(name)
		var composed := StrataRegions.compose_region(terrain, selected, xy, sub)
		_region_compositions += 1
		if not composed.ok: _job.problem = String(composed.message); return false
		var region: StrataRegionData = composed.region
		for name in spec.maps:
			if region.has_map(name): continue
			var description: Dictionary = spec.maps[name]
			var size := StrataRegions.map_size(spec.cells, description)
			var image := Image.create(size.x, size.y, false, int(description.format))
			if name == StrataRegions.MAP_MACRO: image.fill(Color(1, 1, 1, 1))
			region.set_image(name, image, 0, description)
		(_job.regions as Dictionary)[xy] = region
		return true
	if kind == CLASS_HEIGHT:
		# Through compose_region as well, which scans the extrema.
		var sub_spec := spec.duplicate(true)
		for name in sub_spec.maps.keys():
			if name != StrataRegions.MAP_HEIGHT: sub_spec.maps.erase(name)
		var composed := StrataRegions.compose_region(terrain, selected, xy, sub_spec)
		_region_compositions += 1
		if not composed.ok: _job.problem = String(composed.message); return false
		var region: StrataRegionData = composed.region
		var data: StrataRegionData = _regions[xy]
		data.height_min = region.height_min; data.height_max = region.height_max
		return _store(xy, StrataRegions.MAP_HEIGHT, region.get_image(StrataRegions.MAP_HEIGHT), Vector2i.ZERO)
	var images := _compose_class(kind, xy, spec, selected)
	if images.is_empty(): return false
	for name in images:
		if not _store(xy, name, images[name], Vector2i.ZERO): _job.problem = "Region %s map %s could not be updated" % [xy, name]; return false
	return true

## Hands the composed regions to the renderer once the first pass has finished.
func _install_structure() -> bool:
	_spec = _job.spec
	_regions = _job.regions
	_renderer_bound = false
	if is_instance_valid(renderer):
		if not renderer.set_regions(_spec, _regions):
			_job.problem = "The renderer rejected the region set"
			_spec = {}; _regions = {}
			return false
		_renderer_bound = true
	_job.structural = false
	return true

## Writes a composed image (or a window of one) into the cached region and the renderer.
func _store(xy: Vector2i, name: String, image: Image, origin: Vector2i) -> bool:
	var data: StrataRegionData = _regions.get(xy)
	if data == null: return false
	var full := origin == Vector2i.ZERO and image.get_size() == StrataRegions.map_size(_spec.cells, _spec.maps[name])
	if full:
		if not data.set_image(name, image): return false
	elif not data.blit(name, 0, image, origin): return false
	if name == StrataRegions.MAP_HEIGHT and not full: _recompute_extrema(data)
	if is_instance_valid(renderer) and _renderer_bound and not renderer.update_region_window(xy, name, image, origin):
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
# Brush dabs
# ─────────────────────────────────────────────

## Small brush dirty rectangle; the caches describe exactly the updated stack afterwards.
## Call just before the dab; also records which map classes are current.
func can_patch_region() -> bool:
	sync_configuration()
	_patchable.clear()
	if _configuration_dirty or not _attached() or not _job.is_empty() or _spec.is_empty(): return false
	var selected := terrain.preview_through_layer
	if _make_spec() != _spec or is_instance_valid(renderer) and renderer._render_bounds != terrain.base_bounds: return false
	for cls in CLASSES:
		if _present(cls, _spec):
			_patchable[cls] = _signatures.has(cls) and _signatures[cls] == _class_state(cls, selected)
			_owned_keys[cls] = _owned_key(cls, selected)
	return true

func refresh_region(point: Vector2, radius: float, native_spacing: float, channel: StringName = &"height", was_current: bool = false) -> void:
	# Only a dab that began on the current complete surface may update the caches.
	# A queued cutoff/configuration/external edit must first compose the full view.
	var patchable := _patchable
	_patchable = {}
	var step := terrain.region_spacing if is_instance_valid(terrain) else 0.0
	if not was_current or _configuration_dirty or not _attached() or not _job.is_empty() or _spec.is_empty() or _cutoff != terrain.preview_through_layer or _make_spec() != _spec or not is_finite(step) or step <= 0.0:
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

## Recomposes the texel rectangles [param area] touches in every region it touches for the
## maps of [param cls], on the exact windows of the regions' own lattices.
func _patch_class(cls: String, area: Rect2, selected: StrataLayer) -> bool:
	var first_map: String = (_class_maps(cls) as Array)[0]
	var description: Dictionary = _spec.maps[first_map]
	var exact := _exact_windows()
	var size := StrataRegions.map_size(_spec.cells, description)
	for xy in StrataRegions.regions_touching(_spec, area, description):
		if not _regions.has(xy): return false
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
		var images := _compose_class(cls, xy, _spec, selected, Rect2i() if whole else rect)
		if images.is_empty(): return false
		for name in images:
			if not _store(xy, name, images[name], rect.position): return false
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
	return {"full_compiles": _compile_count, "region_compiles": _region_count, "material_compositions": _material_compositions, "material_regions": _material_regions, "region_compositions": _region_compositions, "regions": _regions.size(), "last_patch_ms": _last_patch_ms, "status": status}

## The composed region at a grid index, or null (the cache the renderer shows).
func get_region(xy: Vector2i) -> StrataRegionData:
	return _regions.get(xy)

func get_spec() -> Dictionary:
	return _spec.duplicate(true)

func _exit_tree() -> void:
	if is_instance_valid(terrain):
		terrain.editor_renderer = null
		terrain.editor_preview_bridge = null
	if is_instance_valid(renderer): renderer.queue_free()
