@tool
class_name StrataRegionCompose
extends RefCounted
## Region composition (editor side). StrataRegions.compose_region() forwards here; this script
## needs the native terrain extension and the authoring scripts, so runtime-only projects
## never load it. A region composed alone equals the matching window of a whole-terrain
## composition bit for bit, because every map is one windowed native composition
## (compose_dense with an index offset, compile_cell_mask on the window's bounds). The window
## origin is shifted instead of passing a negative index offset, which keeps bit-identity
## whenever the lattice positions are exact doubles (spacings that are powers of two).

const NavProfiles := preload("strata_nav_profiles.gd")

static func _error(message: String) -> Dictionary:
	return {"ok": false, "message": message}

## Options:
##   channels (PackedStringArray): custom channels composed into maps of that name (plus
##     "<name>__coverage" when the spec has it); every other map name is rejected.
##   nav_profiles (Array of {name, rule}): evaluated on the composed region into nav_<name> maps
##     that the spec must contain.
##   sources (Dictionary): whole-lattice overrides instead of composing: height (RF Image of
##     the terrain's samples), holes / nav_exclusion (canonical cell mask bytes, one per cell;
##     empty = nothing masked). Texels outside the lattice are 0.
##   mask_options (Dictionary): hole_channel, nav_exclusion_channel, continuous_channels,
##     thresholds, max_work, max_fragments, as StrataProcedural.compile_cell_masks().
static func compose(terrain: StrataTerrain3D, through_layer: StrataLayer, xy: Vector2i, spec: Dictionary, options: Dictionary = {}) -> Dictionary:
	var checked := StrataRegions.validate_spec(spec)
	if not checked.ok: return checked
	if not StrataRegions.contains_region(spec, xy): return _error("Region %s lies outside the %s region grid" % [xy, StrataRegions.grid_size(spec)])
	var live := _check_terrain(terrain, through_layer)
	if not live.ok: return live
	var maps: Dictionary = spec.maps
	if not maps.has(StrataRegions.MAP_HEIGHT): return _error("A region spec needs a height map")
	var channels := PackedStringArray(options.get("channels", []))
	var region := StrataRegionData.new()
	region.region = xy
	region.cells = int(spec.cells)
	region.apron = int(spec.apron)
	region.spacing = float(spec.spacing)
	region.origin = StrataRegions.region_origin(spec, xy)
	var names: Array = maps.keys()
	names.sort()
	var composed_materials := false
	for name: String in names:
		var description: Dictionary = maps[name]
		var window := StrataRegions.map_window(spec, xy, description)
		var image: Image = null
		match name:
			StrataRegions.MAP_HEIGHT:
				var composed := compose_map(terrain, through_layer, name, window, spec, options)
				if not composed.ok: return composed
				image = composed.image
			StrataRegions.MAP_MATERIAL_IDS, StrataRegions.MAP_MATERIAL_WEIGHTS:
				if composed_materials: continue
				composed_materials = true
				var wanted_ids: Dictionary = maps.get(StrataRegions.MAP_MATERIAL_IDS, {})
				var wanted_weights: Dictionary = maps.get(StrataRegions.MAP_MATERIAL_WEIGHTS, {})
				if wanted_ids.is_empty() or wanted_weights.is_empty(): return _error("material_ids and material_weights go together")
				var packed := compose_map(terrain, through_layer, StrataRegions.MAP_MATERIAL_IDS, window, spec, options)
				if not packed.ok: return packed
				if not region.set_image(StrataRegions.MAP_MATERIAL_IDS, packed.ids, 0, wanted_ids): return _error("material_ids must be RGBA8 on the sample lattice")
				if not region.set_image(StrataRegions.MAP_MATERIAL_WEIGHTS, packed.weights, 0, wanted_weights): return _error("material_weights must be RGBA8 on the sample lattice")
				continue
			StrataRegions.MAP_HOLES, StrataRegions.MAP_NAV_EXCLUSION:
				var mask := compose_map(terrain, through_layer, name, window, spec, options)
				if not mask.ok: return mask
				image = mask.image
			StrataRegions.MAP_MACRO:
				var macro := compose_map(terrain, through_layer, name, window, spec, options)
				if not macro.ok: return macro
				image = macro.image
			_:
				if StrataRegions.is_nav_profile_map(name): continue
				if name.ends_with(StrataRegions.COVERAGE_SUFFIX):
					if not maps.has(name.trim_suffix(StrataRegions.COVERAGE_SUFFIX)): return _error("Coverage map %s has no channel map" % name)
					continue
				if not channels.has(name): return _error("Map %s is not a standard map and not a requested channel" % name)
				var coverage_name: String = name + StrataRegions.COVERAGE_SUFFIX
				var composed := compose_map(terrain, through_layer, name, window, spec, options)
				if not composed.ok: return composed
				if not region.set_image(name, composed.image, 0, description): return _error("Channel map %s must be a sample map" % name)
				if maps.has(coverage_name):
					if not region.set_image(coverage_name, composed.coverage, 0, maps[coverage_name]): return _error("Coverage map %s must be a sample map of the channel's size" % coverage_name)
				continue
		if image == null: return _error("Map %s could not be composed" % name)
		if image.get_format() != int(description.format): image.convert(int(description.format))
		if not region.set_image(name, image, 0, description):
			return _error("Map %s composed to %s %s but the spec wants %s %s" % [name, image.get_size(), image.get_format(), StrataRegions.map_size(spec.cells, description), description.format])
	# Extrema over the terrain's own samples (apron and the part past the bounds excluded).
	var height_image := region.get_image(StrataRegions.MAP_HEIGHT)
	var real := StrataRegions.terrain_samples(spec)
	var count := Vector2i(mini(region.cells + 1, real.x - xy.x * region.cells), mini(region.cells + 1, real.y - xy.y * region.cells))
	var scanned: Dictionary = StrataLayerData.validate_dense(height_image.get_region(Rect2i(region.apron, region.apron, count.x, count.y)))
	if not scanned.get("ok", false): return _error("Region heights: %s" % scanned.get("message", "invalid"))
	region.height_min = float(scanned.min)
	region.height_max = float(scanned.max)
	var profiles: Array = options.get("nav_profiles", [])
	for entry in profiles:
		if not maps.has(StrataRegions.nav_map_name(StringName(entry.name))): return _error("The spec has no %s map for navigation profile %s" % [StrataRegions.nav_map_name(StringName(entry.name)), entry.name])
	if not profiles.is_empty():
		var applied := NavProfiles.apply_region(region, profiles, channels)
		if not applied.ok: return applied
	return {"ok": true, "message": "", "region": region}

## Composes one map of a region spec over any window of its lattice, with the exact
## expressions a whole-terrain composition uses, so a window is bit-identical to the matching
## rectangle of the full map. [param map] is a name of [param spec].maps, [param window] a
## StrataRegions.map_window() result ({first, size, step, origin}) or a sub-rectangle of one
## (first, size and origin shifted together). Returns {ok, message, image} with the image in the
## spec's format for that map:
##   height: the RF samples.
##   material_ids / material_weights: both composed together; "ids" and "weights" hold the two
##     RGBA8 images and "image" the requested one.
##   holes / nav_exclusion: the L8 cell mask; the window must be square.
##   macro: the RGBAH tint and AO; the window must be at least 2 x 2 texels.
##   any other sample-map name: a custom channel, plus "coverage" when the spec has
##     "<name>__coverage".
## nav_<profile> and coverage maps are rejected (they come from compose_region). Options as
## compose(): sources (height, holes, nav_exclusion) replace the composition, mask_options
## configures the cell masks.
static func compose_map(terrain: StrataTerrain3D, through_layer: StrataLayer, map: String, window: Dictionary, spec: Dictionary, options: Dictionary = {}) -> Dictionary:
	var checked := StrataRegions.validate_spec(spec)
	if not checked.ok: return checked
	var live := _check_terrain(terrain, through_layer)
	if not live.ok: return live
	var maps: Dictionary = spec.maps
	if not maps.has(map): return _error("Map %s is not in the region spec" % map)
	var size: Vector2i = window.get("size", Vector2i.ZERO)
	if not window.has("first") or not window.has("step") or not window.has("origin") or size.x < 1 or size.y < 1:
		return _error("Map %s: the window needs first, size, step and origin with a positive size" % map)
	var description: Dictionary = maps[map]
	var sources: Dictionary = options.get("sources", {})
	var mask_options: Dictionary = options.get("mask_options", {})
	match map:
		StrataRegions.MAP_HEIGHT:
			if sources.has("height"): return {"ok": true, "message": "", "image": _slice_samples(sources.height, window, Image.FORMAT_RF)}
			var composed := _compose_plane(terrain, &"height", through_layer, window, spec, false)
			if not composed.ok: return _error("Height: " + composed.message)
			return {"ok": true, "message": "", "image": _quantize(composed.image, int(description.format))}
		StrataRegions.MAP_MATERIAL_IDS, StrataRegions.MAP_MATERIAL_WEIGHTS:
			if not maps.has(StrataRegions.MAP_MATERIAL_IDS) or not maps.has(StrataRegions.MAP_MATERIAL_WEIGHTS): return _error("material_ids and material_weights go together")
			if int(maps[StrataRegions.MAP_MATERIAL_IDS].format) != Image.FORMAT_RGBA8 or int(maps[StrataRegions.MAP_MATERIAL_WEIGHTS].format) != Image.FORMAT_RGBA8: return _error("material_ids and material_weights must be RGBA8")
			var packed := _compose_materials(terrain, through_layer, window, spec)
			if not packed.ok: return _error("Materials: " + packed.message)
			return {"ok": true, "message": "", "ids": packed.ids, "weights": packed.weights, "image": packed.ids if map == StrataRegions.MAP_MATERIAL_IDS else packed.weights}
		StrataRegions.MAP_HOLES, StrataRegions.MAP_NAV_EXCLUSION:
			if size.x != size.y: return _error("%s: a cell-mask window must be square, got %s" % [map, size])
			var key := "holes" if map == StrataRegions.MAP_HOLES else "nav_exclusion"
			if sources.has(key): return {"ok": true, "message": "", "image": _slice_cells(sources[key], window, spec)}
			var channel := String(mask_options.get("hole_channel", "hole")) if map == StrataRegions.MAP_HOLES else String(mask_options.get("nav_exclusion_channel", "nav_exclusion"))
			var mask := _compose_mask(terrain, through_layer, StringName(channel), window, map, mask_options)
			if not mask.ok: return _error("%s: %s" % [map, mask.message])
			return {"ok": true, "message": "", "image": mask.image}
		StrataRegions.MAP_MACRO:
			if size.x < 2 or size.y < 2: return _error("Macro: a window needs at least 2 x 2 texels, got %s" % size)
			var macro := _compose_macro(terrain, through_layer, window, spec)
			if not macro.ok: return _error("Macro: " + macro.message)
			return {"ok": true, "message": "", "image": _quantize(macro.image, int(description.format))}
	if StrataRegions.is_nav_profile_map(map) or map.ends_with(StrataRegions.COVERAGE_SUFFIX):
		return _error("Map %s is derived (navigation profile or coverage) and is composed by compose_region" % map)
	if String(description.kind) != StrataRegions.KIND_SAMPLE: return _error("Channel map %s must be a sample map" % map)
	var coverage_name: String = map + StrataRegions.COVERAGE_SUFFIX
	var wants_coverage := maps.has(coverage_name)
	var channel_result := _compose_channel(terrain, through_layer, StringName(map), window, spec, wants_coverage)
	if not channel_result.ok: return _error("Channel %s: %s" % [map, channel_result.message])
	var result := {"ok": true, "message": "", "image": _quantize(channel_result.image, int(description.format))}
	if wants_coverage: result["coverage"] = _quantize(channel_result.coverage, int(maps[coverage_name].format))
	return result

static func _check_terrain(terrain: StrataTerrain3D, through_layer: StrataLayer) -> Dictionary:
	if not is_instance_valid(terrain) or not terrain.is_inside_tree() or not terrain.is_transform_valid():
		return _error("Region composition requires a live valid terrain")
	if through_layer != null and (not is_instance_valid(through_layer) or not terrain.get_layers().has(through_layer)):
		return _error("Region cutoff must be a live direct terrain layer")
	return {"ok": true, "message": ""}

# Plane composition -----------------------------------------------------

## compose_dense over a map window. [param window] comes from StrataRegions.map_window. The
## window's first index is passed as the native index offset (negative for the apron before the
## terrain origin), so every texel is computed with the whole lattice's expression and the
## window is bit-identical to the matching rectangle of a full composition for any spacing.
static func _compose_plane(terrain: StrataTerrain3D, channel: StringName, through_layer: StrataLayer, window: Dictionary, spec: Dictionary, include_coverage: bool, descriptors: Array = []) -> Dictionary:
	if descriptors.is_empty(): descriptors = StrataProcedural._capture_layers(terrain, channel, through_layer)
	var first: Vector2i = window.first
	var step: float = window.step
	var bounds: Rect2 = spec.bounds
	var origin := Vector3(bounds.position.x, 0.0, bounds.position.y)
	var composed: Dictionary = ClassDB.class_call_static(&"StrataLayerData", &"compose_dense", descriptors, channel, origin, Vector3(step, 0.0, 0.0), Vector3(0.0, 0.0, step), window.size, terrain.base_bounds, include_coverage, 0.0, first)
	if not composed.get("ok", false): return _error(String(composed.get("message", "composition failed")))
	return {"ok": true, "message": "", "image": composed.image, "coverage": composed.get("coverage")}

static func _quantize(image: Image, format: int) -> Image:
	if image.get_format() != format:
		image = image.duplicate()
		image.convert(format)
	return image

static func _compose_channel(terrain: StrataTerrain3D, through_layer: StrataLayer, channel: StringName, window: Dictionary, spec: Dictionary, include_coverage: bool) -> Dictionary:
	if channel == &"height" or String(channel).strip_edges().is_empty() or String(channel).ends_with(StrataProcedural.OWNERSHIP_SUFFIX):
		return _error("Retained channel names must be custom, nonblank and not ownership companions")
	# The descriptor contract StrataBake used for whole-lattice channels, cut off at the layer.
	var descriptors: Array = []
	if StrataMacro.is_macro_channel(channel):
		descriptors.append(StrataMacro.neutral_descriptor(channel, terrain.base_bounds))
	for layer in terrain.get_layers():
		if layer.enabled:
			var field: StrataFieldData = layer.procedural_fields.get(String(channel))
			var storage := layer.get_channel_data(channel)
			var origin := field.sample_origin if field != null else Vector3(storage.grid_origin.x, 0.0, storage.grid_origin.y)
			var step_x := field.sample_step_x if field != null else Vector3(storage.sample_spacing, 0.0, 0.0)
			var step_y := field.sample_step_y if field != null else Vector3(0.0, 0.0, storage.sample_spacing)
			descriptors.append({"data": storage, "origin": origin, "step_x": step_x, "step_y": step_y, "mode": layer.get_composition(channel), "height_offset": 0.0})
		if layer == through_layer: break
	return _compose_plane(terrain, channel, through_layer, window, spec, include_coverage, descriptors)

# Materials ---------------------------------------------------------------

## ids and weights (RGBA8) for a window: every editor_material_channels plane composed and
## packed to the strongest four; weights are rounded to bytes that sum to 255 on assigned texels
## (the largest slot takes the remainder) and stay 0 where no material is assigned.
static func _compose_materials(terrain: StrataTerrain3D, through_layer: StrataLayer, window: Dictionary, spec: Dictionary) -> Dictionary:
	var size: Vector2i = window.size
	var channels: PackedStringArray = terrain.editor_material_channels
	var owned := {}
	for layer in terrain.get_layers():
		if layer.enabled:
			for channel in layer.get_channel_names():
				if channels.has(channel): owned[channel] = true
		if layer == through_layer: break
	if owned.is_empty():
		return {"ok": true, "ids": Image.create(size.x, size.y, false, Image.FORMAT_RGBA8), "weights": Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)}
	var zero := Image.create(size.x, size.y, false, Image.FORMAT_RF)
	var planes: Array[Image] = []
	for channel in channels:
		if not owned.has(channel):
			planes.append(zero)
			continue
		var composed := _compose_plane(terrain, StringName(channel), through_layer, window, spec, false)
		if not composed.ok: return composed
		planes.append(composed.image)
	var packed := StrataMaterialControls._pack_sparse(planes)
	if not packed.get("ok", false): return _error(String(packed.get("message", "material packing failed")))
	var floats: PackedFloat32Array = (packed.weights as Image).get_data().to_float32_array()
	var bytes := PackedByteArray()
	bytes.resize(floats.size())
	for texel in range(size.x * size.y):
		var base := texel * 4
		var total := floats[base] + floats[base + 1] + floats[base + 2] + floats[base + 3]
		if total <= 0.0: continue
		var assigned := 0
		var largest := 0
		for slot in range(4):
			var quantized := clampi(roundi(floats[base + slot] / total * 255.0), 0, 255)
			bytes[base + slot] = quantized
			assigned += quantized
			if quantized > bytes[base + largest]: largest = slot
		bytes[base + largest] = clampi(int(bytes[base + largest]) + 255 - assigned, 0, 255)
	return {"ok": true, "ids": packed.ids, "weights": Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, bytes)}

# Cell masks ----------------------------------------------------------------

static func _compose_mask(terrain: StrataTerrain3D, through_layer: StrataLayer, channel: StringName, window: Dictionary, map: String, mask_options: Dictionary) -> Dictionary:
	if String(channel).strip_edges().is_empty(): return _error("Canonical mask channel names must be nonempty")
	var cells_per_axis: int = (window.size as Vector2i).x
	var step: float = window.step
	var bounds := Rect2(window.origin, Vector2.ONE * float(cells_per_axis) * step)
	var converted := PackedStringArray(mask_options.get("continuous_channels", []))
	var thresholds: Dictionary = mask_options.get("thresholds", {})
	var captured := StrataProcedural._capture_layers(terrain, channel, through_layer)
	for descriptor in captured:
		descriptor.mapping = "threshold" if converted.has(String(channel)) and descriptor.imported_field else "binary"
		descriptor.threshold = float(thresholds.get(String(channel), 0.5))
	var compiled: Dictionary = StrataLayerData.compile_cell_mask(captured, channel, bounds, Vector2i(cells_per_axis + 1, cells_per_axis + 1), int(mask_options.get("max_work", 268435456)), int(mask_options.get("max_fragments", 4096)))
	if not compiled.get("ok", false): return _error(String(compiled.get("message", "mask compilation failed")))
	var mask: PackedByteArray = compiled.mask
	if mask.is_empty():
		mask.resize(cells_per_axis * cells_per_axis)
	elif mask.size() != cells_per_axis * cells_per_axis:
		return _error("Native mask has %d cells, expected %d" % [mask.size(), cells_per_axis * cells_per_axis])
	return {"ok": true, "image": Image.create_from_data(cells_per_axis, cells_per_axis, false, Image.FORMAT_L8, mask)}

# Macro -----------------------------------------------------------------------

static func _compose_macro(terrain: StrataTerrain3D, through_layer: StrataLayer, window: Dictionary, spec: Dictionary) -> Dictionary:
	var owned := StrataMacro.owned_channels(terrain, through_layer)
	var planes: Array[Image] = []
	for channel in StrataMacro.CHANNELS:
		if not owned.has(String(channel)):
			planes.append(null)
			continue
		var composed := _compose_plane(terrain, channel, through_layer, window, spec, false)
		if not composed.ok: return _error("%s: %s" % [channel, composed.message])
		planes.append(composed.image)
	var packed := StrataMacro._pack(planes, window.size)
	if not packed.get("ok", false): return _error(String(packed.get("message", "macro packing failed")))
	return {"ok": true, "image": packed.image}

# Whole-lattice overrides -----------------------------------------------------

static func _slice_samples(source: Variant, window: Dictionary, format: int) -> Image:
	var size: Vector2i = window.size
	var result := Image.create(size.x, size.y, false, format)
	var image := source as Image
	if image == null or image.get_format() != format: return result
	var area := Rect2i(window.first, size).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if area.has_area(): result.blit_rect(image, area, area.position - (window.first as Vector2i))
	return result

static func _slice_cells(source: Variant, window: Dictionary, spec: Dictionary) -> Image:
	var size: Vector2i = window.size
	var cells := StrataRegions.terrain_samples(spec) - Vector2i.ONE
	var bytes := PackedByteArray(source) if source is PackedByteArray else PackedByteArray()
	if bytes.size() != cells.x * cells.y: return Image.create(size.x, size.y, false, Image.FORMAT_L8)
	return _slice_samples(Image.create_from_data(cells.x, cells.y, false, Image.FORMAT_L8, bytes), window, Image.FORMAT_L8)
