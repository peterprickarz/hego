@tool
class_name StrataRegions
extends RefCounted
## Region geometry: the one implementation of the formulas in
## docs/development/strata_regions_plan.md ("Geometry"). Every map of every region is addressed
## through these functions; nothing else may compute region texel positions.
##
## A region spec is a Dictionary:
##   {bounds: Rect2, spacing: float, cells: int, apron: int, maps: {name: map}}
## and a map description is a Dictionary:
##   {format: Image.Format, kind: KIND_SAMPLE | KIND_CELL, scale: int, apron: int}
## Only built-in types are used, so runtime-only projects can load this script.

const DEFAULT_CELLS := 256
const DEFAULT_APRON := 2
const MIN_CELLS := 16
const MAX_CELLS := 4096

const KIND_SAMPLE := "sample"
const KIND_CELL := "cell"

const MAP_HEIGHT := "height"
const MAP_MATERIAL_IDS := "material_ids"
const MAP_MATERIAL_WEIGHTS := "material_weights"
const MAP_HOLES := "holes"
const MAP_NAV_EXCLUSION := "nav_exclusion"
const MAP_MACRO := "macro"
## Baked navigation-profile masks are cell maps named NAV_PROFILE_PREFIX + profile.
const NAV_PROFILE_PREFIX := "nav_"

## Formats a region map may use, with bytes per texel.
const FORMAT_BYTES := {
	Image.FORMAT_L8: 1, Image.FORMAT_R8: 1, Image.FORMAT_RH: 2, Image.FORMAT_RF: 4,
	Image.FORMAT_RGBA8: 4, Image.FORMAT_RGBAH: 8, Image.FORMAT_RGBAF: 16,
}

static func map(format: int, kind: String, scale: int = 1, apron: int = DEFAULT_APRON) -> Dictionary:
	return {"format": format, "kind": kind, "scale": scale, "apron": apron}

## The standard set of composed maps: height, material ids and weights, holes at the sample
## spacing, macro tint and AO at a quarter of it.
static func standard_spec(bounds: Rect2, spacing: float, cells: int = DEFAULT_CELLS, apron: int = DEFAULT_APRON) -> Dictionary:
	return {
		"bounds": bounds, "spacing": spacing, "cells": cells, "apron": apron,
		"maps": {
			MAP_HEIGHT: map(Image.FORMAT_RF, KIND_SAMPLE, 1, apron),
			MAP_MATERIAL_IDS: map(Image.FORMAT_RGBA8, KIND_SAMPLE, 1, apron),
			MAP_MATERIAL_WEIGHTS: map(Image.FORMAT_RGBA8, KIND_SAMPLE, 1, apron),
			MAP_HOLES: map(Image.FORMAT_L8, KIND_CELL, 1, apron),
			MAP_MACRO: map(Image.FORMAT_RGBAH, KIND_SAMPLE, 4, 1),
		},
	}

## Cells per region side for a terrain: [param requested] when it is positive, otherwise the
## automatic size, the largest power of two at or below min(DEFAULT_CELLS, the smaller bounds
## side in cells), at least MIN_CELLS. StrataTerrain3D.region_spec() and StrataBake both take
## their cells from here, so a bake of a terrain's settings matches the editor's regions.
static func resolve_cells(requested: int, bounds: Rect2, spacing: float) -> int:
	if requested > 0: return requested
	var side := minf(bounds.size.x, bounds.size.y) / spacing if spacing > 0.0 and bounds.size.is_finite() else 0.0
	var cells := MIN_CELLS
	while cells * 2 <= mini(DEFAULT_CELLS, int(minf(side, 1.0e6))): cells *= 2
	return cells

static func _error(message: String) -> Dictionary:
	return {"ok": false, "message": message}

static func valid_cells(cells: int) -> bool:
	return cells >= MIN_CELLS and cells <= MAX_CELLS and (cells & (cells - 1)) == 0

static func validate_map(cells: int, description: Dictionary) -> Dictionary:
	if not description.has("format") or not FORMAT_BYTES.has(int(description.format)):
		return _error("Region map format must be L8, R8, RH, RF, RGBA8, RGBAH or RGBAF")
	if String(description.get("kind", "")) not in [KIND_SAMPLE, KIND_CELL]:
		return _error("Region map kind must be sample or cell")
	var scale := int(description.get("scale", 1))
	if scale < 1 or (scale & (scale - 1)) != 0 or scale > cells:
		return _error("Region map scale must be a power of two dividing the region cells")
	var apron := int(description.get("apron", DEFAULT_APRON))
	if apron < 0 or apron * scale > cells / 2:
		return _error("Region map apron must be nonnegative and at most half a region")
	return {"ok": true, "message": ""}

static func validate_spec(spec: Dictionary) -> Dictionary:
	var bounds: Rect2 = spec.get("bounds", Rect2())
	if not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return _error("Region spec needs finite positive bounds")
	var spacing := float(spec.get("spacing", 0.0))
	if not is_finite(spacing) or spacing <= 0.0:
		return _error("Region spec needs a positive finite spacing")
	var cells := int(spec.get("cells", 0))
	if not valid_cells(cells):
		return _error("Region cells must be a power of two between %d and %d" % [MIN_CELLS, MAX_CELLS])
	var apron := int(spec.get("apron", -1))
	if apron < 0 or apron > cells / 2:
		return _error("Region apron must be nonnegative and at most half a region")
	var maps: Dictionary = spec.get("maps", {})
	for name in maps:
		if String(name).is_empty(): return _error("Region map names must not be empty")
		var checked := validate_map(cells, maps[name])
		if not checked.ok: return _error("%s: %s" % [name, checked.message])
	var grid := grid_size(spec)
	if grid.x < 1 or grid.y < 1 or grid.x * grid.y > 1 << 20:
		return _error("Region grid must hold between one and 1,048,576 regions")
	return {"ok": true, "message": ""}

## Metres covered by one region along each axis.
static func extent(spec: Dictionary) -> float:
	return float(spec.cells) * float(spec.spacing)

## Regions along each axis; the last ones may extend past the bounds.
static func grid_size(spec: Dictionary) -> Vector2i:
	var size: Vector2 = (spec.bounds as Rect2).size / extent(spec)
	# Bounds that are an exact multiple must not gain an empty region through rounding.
	return Vector2i(ceili(size.x - 1e-6), ceili(size.y - 1e-6)).max(Vector2i.ONE)

static func contains_region(spec: Dictionary, xy: Vector2i) -> bool:
	var grid := grid_size(spec)
	return xy.x >= 0 and xy.y >= 0 and xy.x < grid.x and xy.y < grid.y

## Terrain-local XZ of the region's first sample (no apron).
static func region_origin(spec: Dictionary, xy: Vector2i) -> Vector2:
	return (spec.bounds as Rect2).position + Vector2(xy) * extent(spec)

static func region_bounds(spec: Dictionary, xy: Vector2i) -> Rect2:
	return Rect2(region_origin(spec, xy), Vector2.ONE * extent(spec))

## The region containing a terrain-local position; may lie outside the grid, check with
## [method contains_region]. Positions on a shared edge belong to the higher region.
static func region_at(spec: Dictionary, position: Vector2) -> Vector2i:
	var relative := (position - (spec.bounds as Rect2).position) / extent(spec)
	return Vector2i(floori(relative.x), floori(relative.y))

## Texels per cell axis of a map at a level: cells / (scale << level).
static func texels_per_axis(cells: int, description: Dictionary, level: int) -> int:
	return cells / (int(description.get("scale", 1)) << level)

## Metres between two texels of a map at a level.
static func texel_step(spec: Dictionary, description: Dictionary, level: int) -> float:
	return float(spec.spacing) * float(int(description.get("scale", 1)) << level)

## Deepest level at which the map still has at least one texel per region.
static func max_level(cells: int, description: Dictionary) -> int:
	var level := 0
	while texels_per_axis(cells, description, level + 1) >= 1: level += 1
	return level

## Size in texels of a region's map at a level, apron included.
static func map_size(cells: int, description: Dictionary, level: int = 0) -> Vector2i:
	var n := texels_per_axis(cells, description, level)
	var apron := int(description.get("apron", DEFAULT_APRON))
	var side := n + 2 * apron + (1 if String(description.kind) == KIND_SAMPLE else 0)
	return Vector2i(side, side)

static func bytes_per_texel(format: int) -> int:
	return int(FORMAT_BYTES.get(format, 0))

static func map_bytes(cells: int, description: Dictionary, level: int = 0) -> int:
	var size := map_size(cells, description, level)
	return size.x * size.y * bytes_per_texel(int(description.format))

## The composition window of a region's map at a level, in the indices of that map's lattice
## (sample 0 at bounds.position, one index per texel step): {first: Vector2i, size: Vector2i,
## origin: Vector2 (terrain-local XZ of texel (0,0), apron included), step: float}.
static func map_window(spec: Dictionary, xy: Vector2i, description: Dictionary, level: int = 0) -> Dictionary:
	var n := texels_per_axis(spec.cells, description, level)
	var apron := int(description.get("apron", DEFAULT_APRON))
	var step := texel_step(spec, description, level)
	var first := xy * n - Vector2i.ONE * apron
	return {"first": first, "size": map_size(spec.cells, description, level), "origin": (spec.bounds as Rect2).position + Vector2(first) * step, "step": step, "level": level}

## Terrain-local XZ of a texel of a region's map. For a cell map this is the cell's minimum
## corner.
static func texel_position(spec: Dictionary, xy: Vector2i, description: Dictionary, texel: Vector2i, level: int = 0) -> Vector2:
	var window := map_window(spec, xy, description, level)
	return window.origin + Vector2(texel) * window.step

## Fractional texel coordinate of a terrain-local position in a region's map; texel (u, v) is
## at integer coordinates, so sampling at (coordinate + 0.5) / size with linear filtering
## interpolates correctly.
static func texel_at(spec: Dictionary, xy: Vector2i, description: Dictionary, position: Vector2, level: int = 0) -> Vector2:
	var window := map_window(spec, xy, description, level)
	return (position - window.origin) / window.step

## The texel rectangle of a region's map that a terrain-local rectangle can affect, clipped to
## the map; empty when they do not overlap.
static func texel_rect(spec: Dictionary, xy: Vector2i, description: Dictionary, area: Rect2, level: int = 0) -> Rect2i:
	var window := map_window(spec, xy, description, level)
	var begin := Vector2i(((area.position - window.origin) / window.step).floor()).max(Vector2i.ZERO)
	var end := Vector2i(((area.end - window.origin) / window.step).ceil()).min(window.size - Vector2i.ONE)
	if end.x < begin.x or end.y < begin.y: return Rect2i()
	return Rect2i(begin, end - begin + Vector2i.ONE)

## Regions whose maps (apron included, at level 0 of [param description]) overlap a
## terrain-local rectangle, clipped to the grid.
static func regions_touching(spec: Dictionary, area: Rect2, description: Dictionary = {}) -> Array[Vector2i]:
	var margin := 0.0
	if not description.is_empty():
		margin = float(int(description.get("apron", DEFAULT_APRON))) * texel_step(spec, description, 0)
	var grown := area.grow(margin)
	var first := region_at(spec, grown.position).max(Vector2i.ZERO)
	var last := region_at(spec, grown.end).min(grid_size(spec) - Vector2i.ONE)
	var result: Array[Vector2i] = []
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			result.append(Vector2i(x, y))
	return result

## Coarse maps (Phase B): one terrain-wide image per map at a shared level, no apron, the
## horizon tier of the renderer. The level is the smallest whose coarse height map has at most
## [param max_side] cells per axis, capped so every map of the spec still has a texel per
## region at that level.
const COARSE_MAX_SIDE := 1024

static func coarse_level(spec: Dictionary, max_side: int = COARSE_MAX_SIDE) -> int:
	var grid := grid_size(spec)
	var maps: Dictionary = spec.get("maps", {})
	var height: Dictionary = maps.get(MAP_HEIGHT, {"scale": 1, "apron": int(spec.get("apron", DEFAULT_APRON)), "kind": KIND_SAMPLE, "format": Image.FORMAT_RF})
	var deepest := max_level(int(spec.cells), height)
	for name in maps: deepest = mini(deepest, max_level(int(spec.cells), maps[name]))
	var level := 0
	while level < deepest and maxi(grid.x, grid.y) * texels_per_axis(int(spec.cells), height, level) > max_side: level += 1
	return level

## Texels per axis of a map's coarse image at a level: grid × cells / (scale << level), plus
## the shared far edge for sample maps.
static func coarse_map_size(spec: Dictionary, description: Dictionary, level: int) -> Vector2i:
	var size := grid_size(spec) * texels_per_axis(int(spec.cells), description, level)
	return size + (Vector2i.ONE if String(description.kind) == KIND_SAMPLE else Vector2i.ZERO)

## The composition window of a coarse map, shaped like [method map_window]: lattice index 0 at
## bounds.position, one index per texel step of the level, the whole grid.
static func coarse_window(spec: Dictionary, description: Dictionary, level: int) -> Dictionary:
	return {"first": Vector2i.ZERO, "size": coarse_map_size(spec, description, level), "origin": (spec.bounds as Rect2).position, "step": texel_step(spec, description, level), "level": level}

## Terrain-local XZ of a coarse texel (a cell map's texel is the cell's minimum corner).
static func coarse_texel_position(spec: Dictionary, description: Dictionary, texel: Vector2i, level: int) -> Vector2:
	return (spec.bounds as Rect2).position + Vector2(texel) * texel_step(spec, description, level)

## Where a region's level-[param level] core lands in the coarse map: [code]source[/code] is
## the rect inside the region's map (apron excluded, the shared far edge included for sample
## maps) and [code]destination[/code] the coarse texel it is placed at.
static func coarse_placement(spec: Dictionary, xy: Vector2i, description: Dictionary, level: int) -> Dictionary:
	var n := texels_per_axis(int(spec.cells), description, level)
	var apron := int(description.get("apron", DEFAULT_APRON))
	var side := n + (1 if String(description.kind) == KIND_SAMPLE else 0)
	return {"source": Rect2i(apron, apron, side, side), "destination": xy * n}

## Image over a level's bytes; the bytes are copied by Image.
static func image_from_level(description: Dictionary, cells: int, level: int, bytes: PackedByteArray) -> Image:
	var size := map_size(cells, description, level)
	if bytes.size() != size.x * size.y * bytes_per_texel(int(description.format)): return null
	return Image.create_from_data(size.x, size.y, false, int(description.format), bytes)

static func level_from_image(image: Image) -> PackedByteArray:
	return image.get_data()

# ─────────────────────────────────────────────
# Composition, mips and helpers added by Track D (data). The geometry above is unchanged.

## A channel map "<name>" may have a companion "<name>__coverage" map holding how much of each
## sample the stack defines (0..1). A channel without one is defined everywhere.
const COVERAGE_SUFFIX := "__coverage"
## The class that composes regions lives in the editor-side addon (it needs the native terrain
## extension and the authoring scripts), which a runtime-only project does not have. This
## script stays loadable there, so the composition entry point only finds it by class name.
const COMPOSE_CLASS := "StrataRegionCompose"

static var _compose_script: Script

## Samples per axis of the terrain's own lattice (bounds / spacing + 1); the regions of the
## last row and column may extend past it.
static func terrain_samples(spec: Dictionary) -> Vector2i:
	var size: Vector2 = (spec.bounds as Rect2).size / float(spec.spacing)
	return Vector2i(ceili(size.x - 1e-6), ceili(size.y - 1e-6)).max(Vector2i.ONE) + Vector2i.ONE

static func nav_map_name(profile: StringName) -> String:
	return MAP_NAV_EXCLUSION if profile == &"default" else NAV_PROFILE_PREFIX + String(profile)

## True for baked profile masks (nav_<profile>), not for the nav_exclusion mask itself.
static func is_nav_profile_map(name: String) -> bool:
	return name.begins_with(NAV_PROFILE_PREFIX) and name != MAP_NAV_EXCLUSION

## Levels a map has when a bake asks for [param mip_levels] in total.
static func level_count(cells: int, description: Dictionary, mip_levels: int) -> int:
	return clampi(mip_levels, 1, max_level(cells, description) + 1)

## Bytes of a region's maps for a spec and a total level count (mips included).
static func region_bytes(spec: Dictionary, mip_levels: int = 1) -> int:
	var total := 0
	for name in spec.maps:
		var description: Dictionary = spec.maps[name]
		for level in range(level_count(spec.cells, description, mip_levels)):
			total += map_bytes(spec.cells, description, level)
	return total

## Composes one region of [param terrain] through [param through_layer] (null = the whole
## stack) for every map of [param spec]; see StrataRegionCompose. Needs the editor-side addon,
## so the arguments are untyped here. Returns {ok, message, region: StrataRegionData}.
## Options: channels (PackedStringArray of custom channel maps present in the spec),
## nav_profiles (Array of {name, rule}), sources (whole-lattice overrides), mask_options.
static func compose_region(terrain: Object, through_layer: Object, xy: Vector2i, spec: Dictionary, options: Dictionary = {}) -> Dictionary:
	var script := _compose_class()
	if script == null:
		return _error("Region composition needs the Strata editor-side addon (%s is not available in this project)" % COMPOSE_CLASS)
	return script.call("compose", terrain, through_layer, xy, spec, options)

static func _compose_class() -> Script:
	if _compose_script == null:
		for entry in ProjectSettings.get_global_class_list():
			if String(entry["class"]) == COMPOSE_CLASS:
				_compose_script = load(String(entry["path"]))
				break
	return _compose_script

## Composes the regions [param xys] of [param terrain] concurrently, one region per
## WorkerThreadPool task, and returns {ok, message, regions: {xy: StrataRegionData}}. Each
## region is exactly what [method compose_region] returns (the bytes do not depend on the
## thread count or order); the first failure is reported and the rest are skipped. Options as
## compose_region(), plus threads (default true; false composes serially on the calling
## thread, as does a platform without threads) and capture (a StrataRegionCompose.capture()
## result; made here when absent). The scene tree and the layers are read once, on the calling
## thread, before any task starts; the tasks only read the captured layer data, so the layers
## must not be edited until this returns. The call blocks until every region is done; call it
## from the main thread (or after capture() from any thread). Native read paths are
## thread-safe (docs/development/terrain_bulk.md, "Parallel composition").
static func compose_regions(terrain: Object, through_layer: Object, spec: Dictionary, xys: Array[Vector2i], options: Dictionary = {}) -> Dictionary:
	var script := _compose_class()
	if script == null:
		return _error("Region composition needs the Strata editor-side addon (%s is not available in this project)" % COMPOSE_CLASS)
	var regions := {}
	if xys.is_empty(): return {"ok": true, "message": "", "regions": regions}
	var local := options.duplicate()
	if not local.has("capture"):
		var captured: Dictionary = script.call("capture", terrain, through_layer, spec, options)
		if not captured.get("ok", false): return captured
		local["capture"] = captured
	var threaded := bool(options.get("threads", true)) and OS.has_feature("threads") and xys.size() > 1
	var outcomes: Array = []
	outcomes.resize(xys.size())
	if not threaded:
		for index in range(xys.size()):
			var composed: Dictionary = script.call("compose", terrain, through_layer, xys[index], spec, local)
			if not composed.ok: return _error("Region %s: %s" % [xys[index], composed.message])
			regions[xys[index]] = composed.region
		return {"ok": true, "message": "", "regions": regions}
	var failed := [false]
	var mutex := Mutex.new()
	var task := func(index: int) -> void:
		if failed[0]: return
		var composed: Dictionary = script.call("compose", terrain, through_layer, xys[index], spec, local)
		mutex.lock()
		outcomes[index] = composed
		if not composed.ok: failed[0] = true
		mutex.unlock()
	var group := WorkerThreadPool.add_group_task(task, xys.size(), -1, false, "Strata region composition")
	WorkerThreadPool.wait_for_group_task_completion(group)
	for index in range(xys.size()):
		var composed: Variant = outcomes[index]
		if composed == null: continue
		if not composed.ok: return _error("Region %s: %s" % [xys[index], composed.message])
		regions[xys[index]] = composed.region
	return {"ok": true, "message": "", "regions": regions}

# Mips ----------------------------------------------------------------

## Adds levels 1..levels-1 to every map of [param region] (capped per map at max_level + 1) and
## drops any existing ones. Level l texel u of a sample map covers lattice index (u - apron) << l,
## so levels share lattice points: the height map is decimated (a coarse texel is the
## coincident level-0 sample, source texel 2u - apron of the previous level, clamped at the
## edges), which makes heights identical at shared points across tiers. The other scalar sample
## maps (channels, coverage, macro) use a separable [1 2 1] / 4 filter centred on that texel;
## cell maps take the maximum over the 2 x 2 texels the coarse cell covers (any set cell stays
## set); material_ids keep, per coarse texel, the up to four heaviest ids over the 2 x 2 block
## starting at that centre texel, and material_weights are renormalised from those sums to
## total 255. The per-texel work is native (StrataLayerData.downsample_samples and
## downsample_materials, safe on worker threads, one region per task) with a script fallback of
## identical results for builds without them.
static func build_mips(region: StrataRegionData, levels: int) -> void:
	var names := region.map_names()
	var paired := region.has_map(MAP_MATERIAL_IDS) and region.has_map(MAP_MATERIAL_WEIGHTS)
	for name in names:
		var entry: Dictionary = region.maps[name]
		var base: PackedByteArray = (entry.levels as Array)[0]
		entry["levels"] = [base]
	for name in names:
		if paired and (name == MAP_MATERIAL_IDS or name == MAP_MATERIAL_WEIGHTS): continue
		var description := region.description(name)
		var count := level_count(region.cells, description, levels)
		var entry: Dictionary = region.maps[name]
		for level in range(1, count):
			var source: PackedByteArray = (entry.levels as Array)[level - 1]
			(entry.levels as Array).append(_downsample(region.cells, description, level - 1, source, name == MAP_HEIGHT))
	if paired:
		var ids_entry: Dictionary = region.maps[MAP_MATERIAL_IDS]
		var weights_entry: Dictionary = region.maps[MAP_MATERIAL_WEIGHTS]
		var description := region.description(MAP_MATERIAL_IDS)
		var count := level_count(region.cells, description, levels)
		for level in range(1, count):
			var mixed := _downsample_materials(region.cells, description, level - 1, (ids_entry.levels as Array)[level - 1], (weights_entry.levels as Array)[level - 1])
			(ids_entry.levels as Array).append(mixed.ids)
			(weights_entry.levels as Array).append(mixed.weights)
	region.revision += 1

## True when the loaded native extension has [param method] (builds from before the mip
## helpers fall back to the script implementations below, with identical results).
static func _has_native(method: StringName) -> bool:
	return ClassDB.class_exists(&"StrataLayerData") and ClassDB.class_has_method(&"StrataLayerData", method)

static func _downsample(cells: int, description: Dictionary, from_level: int, bytes: PackedByteArray, decimate: bool = false) -> PackedByteArray:
	var format := int(description.format)
	var source_size := map_size(cells, description, from_level)
	var target_size := map_size(cells, description, from_level + 1)
	var apron := int(description.get("apron", DEFAULT_APRON))
	var image := Image.create_from_data(source_size.x, source_size.y, false, format, bytes)
	var planes := 1
	if format in [Image.FORMAT_RGBA8, Image.FORMAT_RGBAH, Image.FORMAT_RGBAF]:
		planes = 4
		image.convert(Image.FORMAT_RGBAF)
	elif format != Image.FORMAT_RF:
		image.convert(Image.FORMAT_RF)
	var values := image.get_data().to_float32_array()
	var is_cell := String(description.kind) == KIND_CELL
	var result: PackedFloat32Array
	if _has_native(&"downsample_samples"):
		var mode := 1 if is_cell else (2 if decimate else 0)
		result = ClassDB.class_call_static(&"StrataLayerData", &"downsample_samples", values, planes, source_size, target_size, apron, mode)
	else:
		result = _downsample_script(values, planes, is_cell, decimate, source_size, target_size, apron)
	var output := Image.create_from_data(target_size.x, target_size.y, false, Image.FORMAT_RGBAF if planes == 4 else Image.FORMAT_RF, result.to_byte_array())
	if output.get_format() != format: output.convert(format)
	return output.get_data()

static func _downsample_script(values: PackedFloat32Array, planes: int, is_cell: bool, decimate: bool, source_size: Vector2i, target_size: Vector2i, apron: int) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(target_size.x * target_size.y * planes)
	if decimate and not is_cell:
		for v in range(target_size.y):
			var y := clampi(2 * v - apron, 0, source_size.y - 1)
			for u in range(target_size.x):
				var x := clampi(2 * u - apron, 0, source_size.x - 1)
				for plane in range(planes):
					result[(v * target_size.x + u) * planes + plane] = values[(y * source_size.x + x) * planes + plane]
	elif is_cell:
		for v in range(target_size.y):
			for u in range(target_size.x):
				for plane in range(planes):
					var best := -INF
					for dy in range(2):
						var y := 2 * v - apron + dy
						if y < 0 or y >= source_size.y: continue
						for dx in range(2):
							var x := 2 * u - apron + dx
							if x < 0 or x >= source_size.x: continue
							best = maxf(best, values[(y * source_size.x + x) * planes + plane])
					result[(v * target_size.x + u) * planes + plane] = best if best > -INF else 0.0
	else:
		# Horizontal pass over every source row, then the vertical pass.
		var rows := PackedFloat32Array()
		rows.resize(target_size.x * source_size.y * planes)
		for y in range(source_size.y):
			for u in range(target_size.x):
				var centre := 2 * u - apron
				var left := clampi(centre - 1, 0, source_size.x - 1)
				var middle := clampi(centre, 0, source_size.x - 1)
				var right := clampi(centre + 1, 0, source_size.x - 1)
				for plane in range(planes):
					rows[(y * target_size.x + u) * planes + plane] = (values[(y * source_size.x + left) * planes + plane] + 2.0 * values[(y * source_size.x + middle) * planes + plane] + values[(y * source_size.x + right) * planes + plane]) * 0.25
		for v in range(target_size.y):
			var centre := 2 * v - apron
			var top := clampi(centre - 1, 0, source_size.y - 1)
			var middle := clampi(centre, 0, source_size.y - 1)
			var bottom := clampi(centre + 1, 0, source_size.y - 1)
			for u in range(target_size.x):
				for plane in range(planes):
					result[(v * target_size.x + u) * planes + plane] = (rows[(top * target_size.x + u) * planes + plane] + 2.0 * rows[(middle * target_size.x + u) * planes + plane] + rows[(bottom * target_size.x + u) * planes + plane]) * 0.25
	return result

static func _downsample_materials(cells: int, description: Dictionary, from_level: int, ids: PackedByteArray, weights: PackedByteArray) -> Dictionary:
	var source_size := map_size(cells, description, from_level)
	var target_size := map_size(cells, description, from_level + 1)
	var apron := int(description.get("apron", DEFAULT_APRON))
	if _has_native(&"downsample_materials"):
		var native: Dictionary = ClassDB.class_call_static(&"StrataLayerData", &"downsample_materials", ids, weights, source_size, target_size, apron)
		if native.get("ok", false): return native
	var out_ids := PackedByteArray(); out_ids.resize(target_size.x * target_size.y * 4)
	var out_weights := PackedByteArray(); out_weights.resize(target_size.x * target_size.y * 4)
	for v in range(target_size.y):
		for u in range(target_size.x):
			var sums := {}
			for dy in range(2):
				var y := clampi(2 * v - apron, 0, source_size.y - 1) + dy
				if y >= source_size.y: continue
				for dx in range(2):
					var x := clampi(2 * u - apron, 0, source_size.x - 1) + dx
					if x >= source_size.x: continue
					var base := (y * source_size.x + x) * 4
					for slot in range(4):
						var weight := weights[base + slot]
						if weight > 0: sums[ids[base + slot]] = int(sums.get(ids[base + slot], 0)) + weight
			if sums.is_empty(): continue
			var ranked: Array = sums.keys()
			ranked.sort_custom(func(a: int, b: int) -> bool: return sums[a] > sums[b] or sums[a] == sums[b] and a < b)
			var total := 0
			for slot in range(mini(4, ranked.size())): total += int(sums[ranked[slot]])
			var assigned := 0
			var target := (v * target_size.x + u) * 4
			for slot in range(mini(4, ranked.size())):
				var weight := int(roundf(float(sums[ranked[slot]]) * 255.0 / float(total)))
				out_ids[target + slot] = ranked[slot]
				out_weights[target + slot] = weight
				assigned += weight
			out_weights[target] = clampi(int(out_weights[target]) + 255 - assigned, 0, 255)
	return {"ids": out_ids, "weights": out_weights}
