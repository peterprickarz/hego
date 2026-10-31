class_name StrataRuntimeData
extends Resource
## Compiled runtime terrain, format 2: the manifest of a region grid (see
## docs/development/strata_regions_plan.md and docs/development/terrain_runtime.md). Built-in
## types only: it loads, samples, collides and navigates without the native terrain
## extension, HEGo or Houdini.
##
## Lattice: sample (i, j) lies at bounds.position + spacing * (i, j) in terrain-local XZ,
## endpoints included. Cell (x, z) spans samples a=(x, z), b=(x+1, z), c=(x, z+1), d=(x+1, z+1)
## and is split into triangles (a, b, c) and (b, d, c). This is Godot Physics' HeightMapShape3D
## triangulation and the canonical surface for CPU queries, collision and navigation.
##
## The manifest holds the spec (bounds, spacing, cells, apron, maps), the channel and navigation
## profile bookkeeping, render settings and the extrema; the maps themselves live in
## StrataRegionData resources, embedded in [member regions] or loaded lazily from
## [member region_directory] by [method get_region]. Format 1 (one monolithic resource) is not
## migrated: it fails validation and the terrain must be baked again.

enum Status { OK, OUTSIDE, ABSENT, NOT_RESIDENT, HOLE }
enum Interpolation { TRIANGLE, BILINEAR }

const FORMAT_VERSION := 2
## Cell masks are 0 (solid) or 255 (masked).
const MASK_SET := 255
## Largest lattice the whole-image transitional adapters (height image, hole image, compiled
## field) assemble; region consumers use the windows instead.
const MAX_SAMPLES := 20 * 1024 * 1024
const ADAPTER_MAX_SIDE := 4097
## Payload budget of embedded regions; external regions are not bounded by it.
const MAX_PAYLOAD_BYTES := 512 * 1024 * 1024
## Total payload below which exports embed their regions by default.
const EMBED_LIMIT_BYTES := 64 * 1024 * 1024
## Macro tint/AO: RGBAH, RGB linear tint in 0..2 and A ambient occlusion in 0..1, neutral
## (1, 1, 1, 1). The region map "macro" holds it at its own scale.
const MACRO_MAX_SIDE := 4097
const MACRO_TINT_MAX := 2.0
const MACRO_NEUTRAL := Color(1.0, 1.0, 1.0, 1.0)
## Navigation profile that is always present: the nav_exclusion map itself.
const DEFAULT_NAV_PROFILE := &"default"
const REGION_FILE := "region_%d_%d.res"
## The partial file next to each region file: levels lod_level.. only.
const LOD_REGION_FILE := "region_%d_%d.lod.res"

@export var format_version := FORMAT_VERSION
## Increments on every published bake of the owning terrain.
@export var bake_revision := 0
## Cells per region axis and the apron (in samples) every full-resolution map carries.
@export var cells := StrataRegions.DEFAULT_CELLS
@export var apron := StrataRegions.DEFAULT_APRON
## Regions per axis, derived from bounds, spacing and cells.
@export var grid := Vector2i.ZERO
## The spec maps: name -> {format, kind, scale, apron}. Region files hold exactly these.
@export var maps := {}
## Levels per map the bake computed (level 0 included; capped per map by its size).
@export var mip_levels := 1
## Channels retained by the bake: each has a map of that name (and maybe "<name>__coverage").
@export var channel_names := PackedStringArray()
## Embedded regions, Vector2i -> StrataRegionData, the whole grid or none.
@export var regions: Dictionary = {}:
	set(value):
		regions = value
		_payload_checked = false
## Directory of region_<i>_<j>.res files, loaded on demand when no regions are embedded.
@export var region_directory := ""
## First level of the partial region files (region_<i>_<j>.lod.res) saved next to the full
## ones, 0..15 (the bake keeps it below mip_levels; the lod files are ignored otherwise). A request for min_level >= lod_level
## loads the partial file when it exists.
@export var lod_level := 2
## Coarse maps (Phase B): the terrain-wide image of a map at mip level [member coarse_level],
## no apron, in the map's own format, stitched by the bake from the regions' level cores. Maps
## are optional (v2 data without them is valid). Name -> PackedByteArray of
## StrataRegions.coarse_map_size(get_spec(), description(name), coarse_level) texels. The
## renderer binds them as its horizon tier before any region has loaded; a manifest that holds
## coarse maps but no regions is valid, though is_resident() stays false for it.
@export var coarse_level := 0
@export var coarse_maps: Dictionary = {}
## Optional renderer settings captured by the bake (a duplicate, so later authoring edits never
## change a published artifact). Typed as Resource so runtime-only projects can parse this
## script without the settings class.
@export var render_settings: Resource

# Floating-point values persist as raw bytes (see _get_property_list): Godot text resources
# (4.4 through 4.7) write floats with ~6 significant digits, which would silently move a .tres
# or .tscn bake away from its collision and render data.
var bounds := Rect2()
var spacing := 1.0
## Global height extrema over the terrain's own samples.
var height_min := 0.0
var height_max := 0.0
## Per region (row-major over the grid) the same extrema: [min, max] pairs.
var region_extrema := PackedFloat64Array()
## StringName -> the rule Dictionary each profile was evaluated from, including
## DEFAULT_NAV_PROFILE after a bake. Persisted as var_to_bytes (see _get_property_list).
var nav_profile_rules := {}
var _decode_error := ""
var _payload_checked := false
var _payload_validation: Dictionary = {}
var _scanned_extrema: Dictionary = {}
var _region_cache: Dictionary = {}
var _missing: Dictionary = {}
## Vector2i -> path of the threaded loads in flight (see request_region).
var _pending: Dictionary = {}

## Terrain lattice samples per axis (cells + 1).
var resolution: Vector2i:
	get: return get_cell_resolution() + Vector2i.ONE

# Transitional whole-lattice hole view, assembled from the regions once and cached (a second copy
# of the hole lattice, not meant for large terrains). Only runtime_data_test still reads it;
# production code uses cell_mask_window / is_hole_cell. validate_payload() drops the cache.
## (resolution - 1) cells, row-major; empty when no cell is a hole.
var holes: PackedByteArray:
	get:
		if _compat_holes.is_empty() and maps.has(StrataRegions.MAP_HOLES):
			_compat_holes = cell_mask_window(StrataRegions.MAP_HOLES, Rect2i(Vector2i.ZERO, get_cell_resolution()))
			if _compat_holes.count(MASK_SET) == 0: _compat_holes = PackedByteArray()
		return _compat_holes
var _compat_holes := PackedByteArray()

func _get_property_list() -> Array[Dictionary]:
	var shown := PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY
	return [
		{"name": "lattice_data", "type": TYPE_PACKED_BYTE_ARRAY, "usage": PROPERTY_USAGE_STORAGE},
		{"name": "extrema_data", "type": TYPE_PACKED_BYTE_ARRAY, "usage": PROPERTY_USAGE_STORAGE},
		{"name": "nav_profile_rule_data", "type": TYPE_PACKED_BYTE_ARRAY, "usage": PROPERTY_USAGE_STORAGE},
		{"name": "nav_profile_rules", "type": TYPE_DICTIONARY, "usage": shown},
		{"name": "bounds", "type": TYPE_RECT2, "usage": shown},
		{"name": "spacing", "type": TYPE_FLOAT, "usage": shown},
		{"name": "height_min", "type": TYPE_FLOAT, "usage": shown},
		{"name": "height_max", "type": TYPE_FLOAT, "usage": shown},
	]

func _get(property: StringName) -> Variant:
	match property:
		&"lattice_data":
			return PackedFloat64Array([bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y, spacing, height_min, height_max]).to_byte_array()
		&"extrema_data":
			return region_extrema.to_byte_array()
		&"nav_profile_rule_data":
			return var_to_bytes(nav_profile_rules) if not nav_profile_rules.is_empty() else PackedByteArray()
	return null

func _set(property: StringName, value: Variant) -> bool:
	match property:
		&"lattice_data":
			if not value is PackedByteArray or (value as PackedByteArray).size() != 56:
				_decode_error = "Stored lattice header is malformed"
				return true
			var lattice: PackedFloat64Array = (value as PackedByteArray).to_float64_array()
			bounds = Rect2(lattice[0], lattice[1], lattice[2], lattice[3])
			spacing = lattice[4]
			height_min = lattice[5]
			height_max = lattice[6]
			return true
		&"extrema_data":
			if not value is PackedByteArray or (value as PackedByteArray).size() % 16 != 0:
				_decode_error = "Stored region extrema are malformed"
				return true
			region_extrema = (value as PackedByteArray).to_float64_array()
			return true
		&"nav_profile_rule_data":
			nav_profile_rules = {}
			if not value is PackedByteArray:
				_decode_error = "Stored navigation profile rules are malformed"
				return true
			if (value as PackedByteArray).is_empty():
				return true
			var rules: Variant = bytes_to_var(value)
			if not rules is Dictionary:
				_decode_error = "Stored navigation profile rules are malformed"
				return true
			nav_profile_rules = rules
			return true
	return false

# Spec and geometry -----------------------------------------------------------

## The spec dictionary StrataRegions expects: {bounds, spacing, cells, apron, maps}.
func get_spec() -> Dictionary:
	return {"bounds": bounds, "spacing": spacing, "cells": cells, "apron": apron, "maps": maps}

func get_spacing() -> float:
	return spacing

## Cells of the terrain's own lattice per axis (bounds / spacing).
func get_cell_resolution() -> Vector2i:
	if spacing <= 0.0 or not bounds.size.is_finite(): return Vector2i.ZERO
	return Vector2i(roundi(bounds.size.x / spacing), roundi(bounds.size.y / spacing))

## Cells covered by the region grid (grid * cells), at least get_cell_resolution(). Windows
## of cells, heights and masks are addressed in this space.
func cells_resolution() -> Vector2i:
	return grid * cells

## True when a region source exists (embedded regions or a region directory). Coarse maps alone
## do not make a manifest resident: a manifest with coarse maps and no regions validates and
## feeds the renderer's horizon tier, but collision, navigation and the eager renderer path
## still need regions.
func is_resident() -> bool:
	return grid.x > 0 and grid.y > 0 and (not regions.is_empty() or not region_directory.is_empty())

func has_map(name: String) -> bool:
	return maps.has(name)

func description(name: String) -> Dictionary:
	var entry: Dictionary = maps.get(name, {})
	return {"format": int(entry.get("format", Image.FORMAT_RF)), "kind": String(entry.get("kind", StrataRegions.KIND_SAMPLE)), "scale": int(entry.get("scale", 1)), "apron": int(entry.get("apron", apron))}

## Levels the bake stored for a map.
func level_count(name: String) -> int:
	return StrataRegions.level_count(cells, description(name), mip_levels) if maps.has(name) else 0

## File of the full region (all levels).
func full_region_path(xy: Vector2i) -> String:
	return region_directory.path_join(REGION_FILE % [xy.x, xy.y])

## File of the partial region (levels lod_level..).
func lod_region_path(xy: Vector2i) -> String:
	return region_directory.path_join(LOD_REGION_FILE % [xy.x, xy.y])

## The file a load with [param min_level] reads: the lod file when min_level >= lod_level and
## that file exists, otherwise the full file.
func region_path(xy: Vector2i, min_level: int = 0) -> String:
	if min_level >= lod_level and lod_level < mip_levels and not region_directory.is_empty() and ResourceLoader.exists(lod_region_path(xy)): return lod_region_path(xy)
	return full_region_path(xy)

func _is_lod_path(path: String) -> bool:
	return path.ends_with(".lod.res")

## The region at grid index [param xy] holding at least [param min_level]: the embedded one, or
## one loaded from [member region_directory] and kept in the cache until evict_region(). A
## cached region satisfies the request when its first_level is at most [param min_level]; a
## partial (lod) region does not satisfy a request below lod_level, which then loads the full
## file and replaces it. Synchronous: a threaded load in flight for [param xy] is completed.
## Null outside the grid, when the region is not available, or when its file is malformed.
func get_region(xy: Vector2i, min_level: int = 0) -> StrataRegionData:
	if regions.has(xy): return regions[xy]
	if _region_cache.has(xy) and (_region_cache[xy] as StrataRegionData).first_level <= min_level: return _region_cache[xy]
	if region_directory.is_empty() or _missing.has(xy) or not _in_grid(xy): return null
	if _pending.has(xy):
		var pending_path: String = _pending[xy]
		_pending.erase(xy)
		var finished := _accept_loaded(xy, ResourceLoader.load_threaded_get(pending_path) as StrataRegionData, pending_path)
		if finished == null: return null
		if finished.first_level <= min_level: return finished
	var path := region_path(xy, min_level)
	var loaded: StrataRegionData = null
	if ResourceLoader.exists(path):
		loaded = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as StrataRegionData
	return _accept_loaded(xy, loaded, path)

func _in_grid(xy: Vector2i) -> bool:
	return xy.x >= 0 and xy.y >= 0 and xy.x < grid.x and xy.y < grid.y

## Validates a loaded external region and caches it unless the cache already holds at least as
## much of it; a failure is reported once and remembered. Returns the region now cached.
func _accept_loaded(xy: Vector2i, loaded: StrataRegionData, path: String) -> StrataRegionData:
	var expected_first := lod_level if _is_lod_path(path) else 0
	if loaded == null or loaded.region != xy or loaded.first_level != expected_first or not loaded.validate().ok or not _region_matches(loaded):
		_fail_region(xy, path)
		return null
	if _region_cache.has(xy) and (_region_cache[xy] as StrataRegionData).first_level <= loaded.first_level: return _region_cache[xy]
	_region_cache[xy] = loaded
	return loaded

func _fail_region(xy: Vector2i, path: String = "") -> void:
	push_error("Strata: region file %s is missing or malformed" % (path if not path.is_empty() else full_region_path(xy)))
	_missing[xy] = true

## Starts a threaded load of external region [param xy] holding at least [param min_level]
## (the lod file for min_level >= lod_level, otherwise the full file). False (and nothing
## started) when the region is embedded, already cached with enough levels, pending (either
## kind: ask again after it arrives), known missing, outside the grid, or has no file (reported
## once). Finished loads arrive through poll_regions().
func request_region(xy: Vector2i, min_level: int = 0) -> bool:
	if regions.has(xy) or _pending.has(xy) or _missing.has(xy): return false
	if _region_cache.has(xy) and (_region_cache[xy] as StrataRegionData).first_level <= min_level: return false
	if region_directory.is_empty() or not _in_grid(xy): return false
	var path := region_path(xy, min_level)
	# The type hint stays empty: the loaders do not resolve script class names as hints.
	if not ResourceLoader.exists(path) or ResourceLoader.load_threaded_request(path, "", false, ResourceLoader.CACHE_MODE_IGNORE) != OK:
		_fail_region(xy, path)
		return false
	_pending[xy] = path
	return true

## Moves finished threaded loads into the cache (through the validation get_region applies; a
## failed or malformed one is reported once and marked missing). Returns the indices whose
## cached region is new or was replaced by fuller data. Never blocks.
func poll_regions() -> Array[Vector2i]:
	var arrived: Array[Vector2i] = []
	for xy: Vector2i in _pending.keys():
		var path: String = _pending[xy]
		match ResourceLoader.load_threaded_get_status(path):
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				continue
			ResourceLoader.THREAD_LOAD_LOADED:
				_pending.erase(xy)
				var loaded := ResourceLoader.load_threaded_get(path) as StrataRegionData
				if regions.has(xy): continue
				var before: StrataRegionData = _region_cache.get(xy)
				var after := _accept_loaded(xy, loaded, path)
				if after != null and after != before: arrived.append(xy)
			_:
				_pending.erase(xy)
				_fail_region(xy, path)
	return arrived

func is_region_pending(xy: Vector2i) -> bool:
	return _pending.has(xy)

## True once a load of [param xy] failed (the failure was reported when it happened).
func is_region_missing(xy: Vector2i) -> bool:
	return _missing.has(xy)

func pending_count() -> int:
	return _pending.size()

## True when [method get_region] with [param min_level] would answer without I/O: embedded, or
## cached with first_level at most [param min_level].
func has_cached_region(xy: Vector2i, min_level: int = 0) -> bool:
	return regions.has(xy) or _region_cache.has(xy) and (_region_cache[xy] as StrataRegionData).first_level <= min_level

## Drops a loaded external region from the cache; embedded regions stay. False when nothing
## was dropped. The next get_region() or request_region() reads the file again.
func evict_region(xy: Vector2i) -> bool:
	if regions.has(xy): return false
	return _region_cache.erase(xy)

## first_level of the cached external region (0 full, lod_level partial), -1 when not cached.
func cached_first_level(xy: Vector2i) -> int:
	return (_region_cache[xy] as StrataRegionData).first_level if _region_cache.has(xy) else -1

## Indices of the external regions currently held in the cache (embedded ones excluded).
func cached_region_keys() -> Array[Vector2i]:
	var keys: Array[Vector2i] = []
	for xy: Vector2i in _region_cache: keys.append(xy)
	return keys

## Bytes of map data held by the cached external regions.
func cache_bytes() -> int:
	var total := 0
	for xy: Vector2i in _region_cache: total += (_region_cache[xy] as StrataRegionData).payload_bytes()
	return total

## Forgets loaded external regions and failed loads, so the next access reads the files again.
func clear_region_cache() -> void:
	_region_cache = {}
	_missing = {}

## Moves the embedded regions into the in-memory cache and points the manifest at a directory
## whose files the caller has just written (StrataStorage does).
func attach_region_directory(directory: String) -> void:
	for xy in regions: _region_cache[xy] = regions[xy]
	regions = {}
	region_directory = directory
	_missing = {}

## Replaces the regions with an embedded set (and the directory with nothing).
func embed_regions(embedded: Dictionary) -> void:
	regions = embedded
	region_directory = ""
	_region_cache = {}
	_missing = {}

## Loads every region (external ones included, always the full files) for embedding in exports.
func load_all_regions() -> Dictionary:
	var all := {}
	for y in range(grid.y):
		for x in range(grid.x):
			var region := get_region(Vector2i(x, y), 0)
			if region == null: return {}
			all[Vector2i(x, y)] = region
	return all

func region_extremum(xy: Vector2i) -> Vector2:
	var index := (xy.y * grid.x + xy.x) * 2
	if xy.x < 0 or xy.y < 0 or xy.x >= grid.x or xy.y >= grid.y or index + 1 >= region_extrema.size(): return Vector2.ZERO
	return Vector2(region_extrema[index], region_extrema[index + 1])

func _region_matches(region: StrataRegionData) -> bool:
	if region.cells != cells or region.apron != apron or region.spacing != spacing: return false
	if region.map_names().size() != maps.size(): return false
	for name in maps:
		if not region.has_map(name) or region.description(name) != description(name) or region.level_count(name) != level_count(name): return false
	return true

## Bytes the stored maps occupy: counted over the embedded regions, planned from the spec for
## external ones (a missing file counts as planned).
func payload_bytes() -> int:
	return grid.x * grid.y * StrataRegions.region_bytes(get_spec(), mip_levels) + coarse_bytes()

## Bytes of the stored coarse maps.
func coarse_bytes() -> int:
	var total := 0
	for name in coarse_maps:
		if coarse_maps[name] is PackedByteArray: total += (coarse_maps[name] as PackedByteArray).size()
	return total

func has_coarse_maps() -> bool:
	return not coarse_maps.is_empty()

## The coarse map [param name] as an Image of StrataRegions.coarse_map_size texels (a copy), or
## null when the manifest has none by that name or the bytes do not fit the spec.
func coarse_image(name: String) -> Image:
	if not coarse_maps.has(name) or not maps.has(name) or not coarse_maps[name] is PackedByteArray: return null
	var entry := description(name)
	var size := StrataRegions.coarse_map_size(get_spec(), entry, coarse_level)
	var bytes: PackedByteArray = coarse_maps[name]
	if bytes.size() != size.x * size.y * StrataRegions.bytes_per_texel(int(entry.format)): return null
	return Image.create_from_data(size.x, size.y, false, int(entry.format), bytes)

func _validate_coarse() -> Dictionary:
	if coarse_maps.is_empty(): return {"ok": true}
	if coarse_level < 0 or coarse_level >= mip_levels: return _error("coarse_level %d needs mip_levels above it (mip_levels is %d)" % [coarse_level, mip_levels])
	for name in coarse_maps:
		if not name is String or not maps.has(name): return _error("Coarse map %s is not a map of the spec" % name)
		if not coarse_maps[name] is PackedByteArray: return _error("Coarse map %s must be a PackedByteArray" % name)
		if coarse_image(name) == null: return _error("Coarse map %s does not match %s texels of its format" % [name, StrataRegions.coarse_map_size(get_spec(), description(name), coarse_level)])
	return {"ok": true}

# Validation -------------------------------------------------------------------

## Structure of the manifest plus every embedded region (scanned once and cached; call
## validate_payload() after editing a region's bytes in place). External regions are checked
## when they load, or all at once with [param deep].
func validate(deep: bool = false) -> Dictionary:
	if not _decode_error.is_empty(): return _error(_decode_error)
	if format_version != FORMAT_VERSION:
		return _error("Unsupported runtime terrain format version %d (this is format %d; format 1 is not migrated, bake the terrain again)" % [format_version, FORMAT_VERSION])
	if not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite() or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return _error("Runtime terrain bounds must be finite and positive")
	var checked := StrataRegions.validate_spec(get_spec())
	if not checked.ok: return checked
	if grid != StrataRegions.grid_size(get_spec()): return _error("Region grid %s does not match the bounds (%s)" % [grid, StrataRegions.grid_size(get_spec())])
	if not maps.has(StrataRegions.MAP_HEIGHT): return _error("Runtime terrain needs a height map")
	var height := description(StrataRegions.MAP_HEIGHT)
	if int(height.format) != Image.FORMAT_RF or height.kind != StrataRegions.KIND_SAMPLE or int(height.scale) != 1:
		return _error("The height map must be an RF sample map at scale 1")
	if mip_levels < 1 or mip_levels > 16: return _error("mip_levels must be 1..16")
	if lod_level < 0 or lod_level > 15: return _error("lod_level must be 0..15")
	if not is_finite(height_min) or not is_finite(height_max) or height_min > height_max:
		return _error("Height range must be finite")
	if region_extrema.size() != grid.x * grid.y * 2: return _error("Per-region height extrema do not match the grid")
	var seen := {}
	for name in channel_names:
		if name.strip_edges().is_empty() or seen.has(name): return _error("Runtime channel manifest names must be nonempty and unique")
		if not maps.has(name) or maps[name].get("kind") != StrataRegions.KIND_SAMPLE: return _error("Channel %s has no sample map" % name)
		seen[name] = true
	for name in maps:
		var text := String(name)
		if StrataRegions.is_nav_profile_map(text):
			var profile := StringName(text.trim_prefix(StrataRegions.NAV_PROFILE_PREFIX))
			if maps[name].get("kind") != StrataRegions.KIND_CELL or not nav_profile_rules.get(profile) is Dictionary:
				return _error("Navigation profile map %s needs the cell kind and a stored rule" % text)
		elif text.ends_with(StrataRegions.COVERAGE_SUFFIX):
			if not seen.has(text.trim_suffix(StrataRegions.COVERAGE_SUFFIX)): return _error("Coverage map %s has no channel" % text)
		elif text not in [StrataRegions.MAP_HEIGHT, StrataRegions.MAP_MATERIAL_IDS, StrataRegions.MAP_MATERIAL_WEIGHTS, StrataRegions.MAP_HOLES, StrataRegions.MAP_NAV_EXCLUSION, StrataRegions.MAP_MACRO] and not seen.has(text):
			return _error("Map %s is neither a standard map nor a retained channel" % text)
	if maps.has(StrataRegions.MAP_MATERIAL_IDS) != maps.has(StrataRegions.MAP_MATERIAL_WEIGHTS): return _error("Material ids and weights must be provided together")
	for name in nav_profile_rules:
		if not name is StringName or not nav_profile_rules[name] is Dictionary: return _error("Navigation profile rule %s is malformed" % name)
		if name != DEFAULT_NAV_PROFILE and not maps.has(StrataRegions.nav_map_name(name)): return _error("Navigation profile rule %s has no profile map" % name)
	if render_settings != null and not render_settings.has_method("parameters"):
		return _error("Runtime render settings must be an StrataRenderSettings resource")
	var coarse := _validate_coarse()
	if not coarse.ok: return coarse
	if not regions.is_empty():
		if payload_bytes() > MAX_PAYLOAD_BYTES: return _error("Embedded runtime payload exceeds the 512 MiB budget; save the regions to a directory")
		if regions.size() != grid.x * grid.y: return _error("Embedded regions must cover the whole %s grid" % grid)
		if not _payload_checked:
			_payload_validation = _validate_embedded()
			_payload_checked = true
		if not _payload_validation.get("ok", false): return _payload_validation
		# The scanned extrema are cached with the scan; the stored ones are compared every time.
		var global_min := INF
		var global_max := -INF
		for xy in regions:
			var scanned: Vector2 = _scanned_extrema[xy]
			var extremum := region_extremum(xy)
			if scanned.x != extremum.x or scanned.y != extremum.y: return _error("Region %s: stored height extrema do not match its samples" % xy)
			global_min = minf(global_min, scanned.x)
			global_max = maxf(global_max, scanned.y)
		if global_min != height_min or global_max != height_max: return _error("Stored height extrema do not match the resident finite samples")
	elif deep and not region_directory.is_empty():
		for y in range(grid.y):
			for x in range(grid.x):
				if get_region(Vector2i(x, y)) == null: return _error("Region %d,%d is not available" % [x, y])
	return {"ok": true}

## Revalidates after intentional in-place edits to embedded region bytes.
func validate_payload() -> Dictionary:
	_payload_checked = false
	_compat_holes = PackedByteArray()
	return validate()

func _validate_embedded() -> Dictionary:
	_scanned_extrema = {}
	for xy in regions:
		if not xy is Vector2i or not StrataRegions.contains_region(get_spec(), xy) or not regions[xy] is StrataRegionData: return _error("Embedded regions must be keyed by their grid index")
		var region: StrataRegionData = regions[xy]
		if region.first_level != 0: return _error("Embedded regions must hold every level")
		var checked := region.validate()
		if not checked.ok: return _error("Region %s: %s" % [xy, checked.message])
		if region.region != xy or not _region_matches(region): return _error("Region %s does not match the manifest" % xy)
		var scanned := scan_region(region, get_spec())
		if not scanned.ok: return _error("Region %s: %s" % [xy, scanned.message])
		_scanned_extrema[xy] = Vector2(scanned.min, scanned.max)
	return {"ok": true}

## Finite and range checks of one region's maps; returns the height extrema over the terrain's
## own samples. Cell masks must be canonical, channel values finite, coverage in 0..1.
static func scan_region(region: StrataRegionData, spec: Dictionary) -> Dictionary:
	var side := StrataRegions.map_size(region.cells, region.description(StrataRegions.MAP_HEIGHT)).x
	var real := StrataRegions.terrain_samples(spec)
	var count := Vector2i(mini(region.cells + 1, real.x - region.region.x * region.cells), mini(region.cells + 1, real.y - region.region.y * region.cells))
	var everything := Image.create_from_data(side, side, false, Image.FORMAT_RF, region.level_bytes(StrataRegions.MAP_HEIGHT))
	if not _scan_floats(everything.get_data().to_float32_array(), everything.get_size()).ok: return _error("Resident runtime heights must be finite")
	var heights := everything.get_region(Rect2i(region.apron, region.apron, count.x, count.y))
	var extent := _scan_floats(heights.get_data().to_float32_array(), heights.get_size())
	if not extent.ok: return _error("Resident runtime heights must be finite")
	for name in region.map_names():
		var description := region.description(name)
		var format := int(description.format)
		for level in range(region.first_level, region.level_count(name)):
			var bytes := region.level_bytes(name, level)
			if String(description.kind) == StrataRegions.KIND_CELL and format == Image.FORMAT_L8:
				if not _canonical_mask(bytes): return _error("Cell mask %s must contain only 0 and 255" % name)
			elif name == StrataRegions.MAP_MACRO:
				var size := StrataRegions.map_size(region.cells, description, level)
				var macro := scan_macro_image(Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBAH, bytes))
				if not macro.ok: return macro
			elif format == Image.FORMAT_RF and name != StrataRegions.MAP_HEIGHT:
				var size := StrataRegions.map_size(region.cells, description, level)
				var values := _scan_floats(bytes.to_float32_array(), size)
				if not values.ok: return _error("Map %s contains nonfinite values" % name)
				if name.ends_with(StrataRegions.COVERAGE_SUFFIX) and (values.min < 0.0 or values.max > 1.0): return _error("Coverage %s must be in 0..1" % name)
	return {"ok": true, "min": extent.min, "max": extent.max}

static func _scan_floats(values: PackedFloat32Array, size: Vector2i) -> Dictionary:
	if values.is_empty(): return {"ok": true, "min": 0.0, "max": 0.0}
	if ClassDB.class_exists("StrataLayerData") and size.x > 0 and size.x * size.y == values.size():
		var validator: Object = ClassDB.instantiate("StrataLayerData")
		var image := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RF, values.to_byte_array())
		return validator.call("validate_dense", image)
	var minimum := INF
	var maximum := -INF
	for value in values:
		if not is_finite(value): return _error("Resident runtime values must be finite")
		minimum = minf(minimum, value); maximum = maxf(maximum, value)
	return {"ok": true, "min": minimum, "max": maximum}

static func _canonical_mask(mask: PackedByteArray) -> bool:
	return mask.count(0) + mask.count(MASK_SET) == mask.size()

static func _error(message: String) -> Dictionary:
	return {"ok": false, "message": message}

## Converts a cell mask Image/PackedByteArray into canonical bytes. Float images
## mark value >= 0.5; 8-bit images mark byte >= 128 (the same 0.5 threshold).
## Already-canonical bytes are accepted without a per-cell script loop.
static func canonicalize_cell_mask(source: Variant, cell_size: Vector2i) -> Dictionary:
	if source == null:
		return {"ok": true, "mask": PackedByteArray()}
	var bytes := PackedByteArray()
	var float_values := PackedFloat32Array()
	if source is Image:
		var image: Image = source
		if image.get_size() != cell_size or image.is_compressed():
			return _error("Cell mask must be an uncompressed %dx%d image (one texel per cell)" % [cell_size.x, cell_size.y])
		match image.get_format():
			Image.FORMAT_L8, Image.FORMAT_R8:
				bytes = image.get_data()
			Image.FORMAT_RF:
				float_values = image.get_data().to_float32_array()
			_:
				return _error("Cell mask images must be L8, R8 or RF")
	elif source is PackedByteArray:
		bytes = source
		if bytes.is_empty():
			return {"ok": true, "mask": bytes, "count": 0}
		if bytes.size() != cell_size.x * cell_size.y:
			return _error("Cell mask byte count must be %d" % (cell_size.x * cell_size.y))
	else:
		return _error("Cell mask must be an Image or PackedByteArray")
	if not float_values.is_empty():
		bytes.resize(float_values.size())
		for index in range(float_values.size()):
			var value := float_values[index]
			if not is_finite(value):
				return _error("Cell mask values must be finite")
			bytes[index] = MASK_SET if value >= 0.5 else 0
	elif not _canonical_mask(bytes):
		bytes = bytes.duplicate()
		for index in range(bytes.size()):
			bytes[index] = MASK_SET if bytes[index] >= 128 else 0
	if bytes.count(MASK_SET) == 0:
		bytes = PackedByteArray()
	return {"ok": true, "mask": bytes, "count": bytes.count(MASK_SET)}

# Report -------------------------------------------------------------------------

## Sizes and counts for budgeting and export reports. Hole and exclusion counts need the
## regions and are only given when they are resident (embedded or cached).
func get_manifest() -> Dictionary:
	var map_entries := {}
	var per_region := 0
	for name in maps:
		var bytes := 0
		for level in range(level_count(name)): bytes += StrataRegions.map_bytes(cells, description(name), level)
		map_entries[name] = bytes
		per_region += bytes
	var coarse_entries := {}
	for name in coarse_maps:
		coarse_entries[name] = {"size": StrataRegions.coarse_map_size(get_spec(), description(name), coarse_level) if maps.has(name) else Vector2i.ZERO, "bytes": (coarse_maps[name] as PackedByteArray).size() if coarse_maps[name] is PackedByteArray else 0}
	var profile_entries: Array = [{"name": DEFAULT_NAV_PROFILE, "map": StrataRegions.MAP_NAV_EXCLUSION, "rule": get_nav_profile_rule(DEFAULT_NAV_PROFILE)}]
	for name in get_nav_profile_names():
		if name != DEFAULT_NAV_PROFILE: profile_entries.append({"name": name, "map": StrataRegions.nav_map_name(name), "rule": get_nav_profile_rule(name)})
	var channel_entries: Array = []
	for name in channel_names:
		channel_entries.append({"name": name, "bytes": int(map_entries.get(name, 0)) + int(map_entries.get(name + StrataRegions.COVERAGE_SUFFIX, 0))})
	return {"format_version": format_version, "bake_revision": bake_revision, "bounds": bounds, "spacing": spacing, "resolution": resolution, "cells": cells, "apron": apron, "grid": grid, "region_count": grid.x * grid.y, "region_bytes": per_region, "mip_levels": mip_levels, "total_bytes": per_region * grid.x * grid.y, "map_bytes": map_entries, "embedded": not regions.is_empty(), "coarse_level": coarse_level, "coarse_bytes": coarse_bytes(), "coarse_maps": coarse_entries, "region_directory": region_directory, "lod_level": lod_level, "channels": channel_entries, "nav_profiles": profile_entries, "has_macro": has_macro(), "height_min": height_min, "height_max": height_max}

## Independent copy. Embedded regions are copied; an external directory is shared (the files
## are the data). With [param embed] every region is loaded and embedded instead; returns null
## when one cannot be loaded.
func duplicate_runtime(embed: bool = false) -> StrataRuntimeData:
	var copy := StrataRuntimeData.new()
	copy.bake_revision = bake_revision
	copy.bounds = bounds
	copy.spacing = spacing
	copy.cells = cells
	copy.apron = apron
	copy.grid = grid
	copy.maps = maps.duplicate(true)
	copy.mip_levels = mip_levels
	copy.lod_level = lod_level
	copy.coarse_level = coarse_level
	copy.coarse_maps = coarse_maps.duplicate()
	copy.height_min = height_min
	copy.height_max = height_max
	copy.region_extrema = region_extrema.duplicate()
	copy.channel_names = channel_names.duplicate()
	copy.nav_profile_rules = nav_profile_rules.duplicate(true)
	copy.render_settings = render_settings.duplicate(true) if render_settings != null else null
	if not regions.is_empty() or embed:
		var source := regions if not regions.is_empty() else load_all_regions()
		if source.is_empty() and grid.x * grid.y > 0: return null
		var copied := {}
		for xy in source: copied[xy] = clone_region(source[xy])
		copy.regions = copied
	else:
		copy.region_directory = region_directory
	return copy

static func clone_region(region: StrataRegionData) -> StrataRegionData:
	var copy := StrataRegionData.new()
	copy.region = region.region
	copy.cells = region.cells
	copy.apron = region.apron
	copy.spacing = region.spacing
	copy.origin = region.origin
	copy.first_level = region.first_level
	copy.height_min = region.height_min
	copy.height_max = region.height_max
	copy.revision = region.revision
	copy.maps = region.maps.duplicate(true)
	return copy

# Navigation profiles -----------------------------------------------------------

## True for DEFAULT_NAV_PROFILE (always) and every stored profile.
func has_nav_profile(name: StringName) -> bool:
	return name == DEFAULT_NAV_PROFILE or maps.has(StrataRegions.nav_map_name(name)) and nav_profile_rules.has(name)

## DEFAULT_NAV_PROFILE first, then the stored profiles in name order.
func get_nav_profile_names() -> Array[StringName]:
	var names: Array[StringName] = []
	for name in nav_profile_rules:
		if StringName(name) != DEFAULT_NAV_PROFILE: names.append(StringName(name))
	names.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	names.push_front(DEFAULT_NAV_PROFILE)
	return names

## The rule a profile was evaluated from ({} for an unknown profile).
func get_nav_profile_rule(name: StringName) -> Dictionary:
	if nav_profile_rules.has(name): return nav_profile_rules[name]
	return {"exclusion": true} if name == DEFAULT_NAV_PROFILE else {}

## Name of the cell map holding a profile's blocked cells (255 = blocked; the default profile
## is nav_exclusion), "" for an unknown profile.
func nav_profile_map(name: StringName) -> String:
	return StrataRegions.nav_map_name(name) if has_nav_profile(name) else ""

## Canonical blocked-cell mask of a profile over get_cell_resolution() cells (255 = blocked),
## empty when nothing is blocked, for an unknown profile or when a region is unavailable.
## Assembled from the regions.
func get_nav_profile_mask(name: StringName) -> PackedByteArray:
	var map := nav_profile_map(name)
	if map.is_empty() or not maps.has(map): return PackedByteArray()
	var mask := cell_mask_window(map, Rect2i(Vector2i.ZERO, get_cell_resolution()))
	return mask if mask.count(MASK_SET) > 0 else PackedByteArray()

## L8 image of the profile's blocked cells (255), like get_hole_image(); null for an unknown
## profile.
func get_nav_profile_image(name: StringName) -> Image:
	if not has_nav_profile(name): return null
	return _mask_image(nav_profile_map(name))

func get_nav_exclusion_image() -> Image:
	return _mask_image(StrataRegions.MAP_NAV_EXCLUSION)

## L8 image of size get_cell_resolution(): 255 marks a hole cell. Transitional whole-image
## adapter; null above 4097 samples per side or when a region is unavailable.
func get_hole_image() -> Image:
	return _mask_image(StrataRegions.MAP_HOLES)

func _mask_image(map: String) -> Image:
	var size := get_cell_resolution()
	if size.x < 1 or size.y < 1 or size.x >= ADAPTER_MAX_SIDE or size.y >= ADAPTER_MAX_SIDE or not is_resident(): return null
	if not maps.has(map): return Image.create(size.x, size.y, false, Image.FORMAT_L8)
	var bytes := cell_mask_window(map, Rect2i(Vector2i.ZERO, size))
	if bytes.size() != size.x * size.y: return null
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_L8, bytes)

func is_hole_cell(cell: Vector2i) -> bool:
	return _mask_at(StrataRegions.MAP_HOLES, cell)

func is_nav_excluded_cell(cell: Vector2i) -> bool:
	return _mask_at(StrataRegions.MAP_NAV_EXCLUSION, cell)

## Hole, or blocked for the profile (the default profile is nav_exclusion): cells that never
## carry that profile's navigation source faces. Every cell is blocked for an unknown profile.
func is_nav_blocked_cell(cell: Vector2i, profile: StringName = DEFAULT_NAV_PROFILE) -> bool:
	if not has_nav_profile(profile): return true
	return _mask_at(StrataRegions.MAP_HOLES, cell) or _mask_at(nav_profile_map(profile), cell)

## One byte of a cell map at a terrain cell (0 when the map or region is absent or the cell
## lies outside the terrain).
func _mask_at(map: String, cell: Vector2i) -> bool:
	var size := get_cell_resolution()
	if not maps.has(map) or cell.x < 0 or cell.y < 0 or cell.x >= size.x or cell.y >= size.y: return false
	var region := get_region(cell / cells)
	if region == null: return false
	var local_apron := int(maps[map].get("apron", apron))
	var local := cell % cells
	return region.level_bytes(map)[(local.y + local_apron) * (cells + 2 * local_apron) + local.x + local_apron] == MASK_SET

# Windows ---------------------------------------------------------------------

## Raw level-0 bytes of a map over [param rect], addressed in the map's own lattice units
## (cells for a scale-1 map; scaled maps count their coarser texels). A sample map returns
## (w + 1) x (h + 1) texels using the edge samples the regions share, a cell map w x h; rows are
## row-major, texels are the map's format. The rectangle must lie inside the region grid
## (grid * cells / scale); empty array otherwise, or when a region is unavailable.
@warning_ignore("integer_division")
func map_window_bytes(map: String, rect: Rect2i) -> PackedByteArray:
	if not maps.has(map) or grid.x < 1 or grid.y < 1 or rect.size.x < 0 or rect.size.y < 0: return PackedByteArray()
	var info := description(map)
	var n: int = cells / int(info.scale)
	var sample := String(info.kind) == StrataRegions.KIND_SAMPLE
	var texel := StrataRegions.bytes_per_texel(int(info.format))
	var columns := rect.size.x + (1 if sample else 0)
	var rows := rect.size.y + (1 if sample else 0)
	var extra := 1 if sample else 0
	if rect.position.x < 0 or rect.position.y < 0 or rect.position.x + columns > grid.x * n + extra or rect.position.y + rows > grid.y * n + extra: return PackedByteArray()
	var side := n + 2 * int(info.apron) + extra
	var out := PackedByteArray()
	for row in range(rows):
		var gy := rect.position.y + row
		var ry := mini(gy / n, grid.y - 1)
		var ly := gy - ry * n
		var gx := rect.position.x
		var remaining := columns
		while remaining > 0:
			var rx := mini(gx / n, grid.x - 1)
			var lx := gx - rx * n
			var owned_end := (rx + 1) * n + (extra if rx == grid.x - 1 else 0)
			var take := mini(remaining, owned_end - gx)
			var region := get_region(Vector2i(rx, ry))
			if region == null: return PackedByteArray()
			var bytes := region.level_bytes(map)
			var offset := ((ly + int(info.apron)) * side + lx + int(info.apron)) * texel
			out.append_array(bytes.slice(offset, offset + take * texel))
			gx += take
			remaining -= take
	return out

## (w + 1) * (h + 1) height samples of the cell rectangle, row-major, assembled across regions
## with the shared edge samples. Empty when the rectangle leaves cells_resolution().
func heights_window(cell_rect: Rect2i) -> PackedFloat32Array:
	return map_window_bytes(StrataRegions.MAP_HEIGHT, cell_rect).to_float32_array()

## w * h bytes (0 or 255) of a cell map ("holes", "nav_exclusion", "nav_<profile>"), row-major.
## Empty for an unknown map or a rectangle outside cells_resolution().
func cell_mask_window(map: String, cell_rect: Rect2i) -> PackedByteArray:
	if not maps.has(map) or String(maps[map].get("kind")) != StrataRegions.KIND_CELL: return PackedByteArray()
	return map_window_bytes(map, cell_rect)

# Lattice and height queries ------------------------------------------------------

func contains_local(position: Vector2) -> bool:
	return position.x >= bounds.position.x and position.y >= bounds.position.y and position.x <= bounds.end.x and position.y <= bounds.end.y

## Continuous lattice coordinates of a terrain-local XZ position.
func local_to_lattice(position: Vector2) -> Vector2:
	return (position - bounds.position) / spacing

func lattice_to_local(lattice: Vector2) -> Vector2:
	return bounds.position + lattice * spacing

## Cells whose closed area contains the point (one, two or four).
func cells_at(position: Vector2) -> Array[Vector2i]:
	var lattice := local_to_lattice(position)
	var size := get_cell_resolution()
	var cells_x := _cell_candidates(lattice.x, size.x)
	var cells_z := _cell_candidates(lattice.y, size.y)
	var result: Array[Vector2i] = []
	for z in cells_z:
		for x in cells_x:
			result.append(Vector2i(x, z))
	return result

static func _cell_candidates(coordinate: float, count: int) -> PackedInt32Array:
	var base := floori(coordinate)
	var result := PackedInt32Array()
	if float(base) == coordinate and base > 0:
		result.append(base - 1)
	if base < count:
		result.append(maxi(base, 0))
	elif result.is_empty():
		result.append(count - 1)
	return result

## Height of the sample at a terrain lattice index, from its owning region (the higher region
## for a shared edge, the last one at the far edge). NAN when the region is unavailable.
@warning_ignore("integer_division")
func get_height_at(index: Vector2i) -> float:
	var region := get_region(Vector2i(mini(index.x / cells, grid.x - 1), mini(index.y / cells, grid.y - 1)))
	if region == null: return NAN
	var local := index - region.region * cells
	return region.level_bytes(StrataRegions.MAP_HEIGHT).decode_float(((local.y + apron) * (cells + 1 + 2 * apron) + local.x + apron) * 4)

## Heights a, b, c, d of a cell (empty when its region is unavailable). A cell's four corners
## always lie in the one region that owns the cell.
func _cell_corners(cell: Vector2i) -> PackedFloat64Array:
	var region := get_region(cell / cells)
	if region == null: return PackedFloat64Array()
	var local := cell % cells
	var stride := cells + 1 + 2 * apron
	var bytes := region.level_bytes(StrataRegions.MAP_HEIGHT)
	var at := ((local.y + apron) * stride + local.x + apron) * 4
	return PackedFloat64Array([bytes.decode_float(at), bytes.decode_float(at + 4), bytes.decode_float(at + stride * 4), bytes.decode_float(at + stride * 4 + 4)])

## A point is in a hole only if every cell touching it is a hole, so the solid
## side of a hole edge keeps its surface (matching the omitted triangles).
func is_hole_at(position: Vector2) -> bool:
	if not maps.has(StrataRegions.MAP_HOLES) or not contains_local(position):
		return false
	for cell in cells_at(position):
		if not is_hole_cell(cell):
			return false
	return true

## {status, value}. TRIANGLE matches collision/navigation exactly. BILINEAR
## matches the current renderer's filtered height texture instead.
func sample_height(position: Vector2, interpolation: int = Interpolation.TRIANGLE, ignore_holes := false) -> Dictionary:
	if not position.is_finite() or not contains_local(position):
		return {"status": Status.OUTSIDE, "value": NAN}
	if not is_resident():
		return {"status": Status.NOT_RESIDENT, "value": NAN}
	var cell := Vector2i(-1, -1)
	for candidate in cells_at(position):
		if ignore_holes or not is_hole_cell(candidate):
			cell = candidate
			break
	if cell.x < 0:
		return {"status": Status.HOLE, "value": NAN}
	var corners := _cell_corners(cell)
	if corners.is_empty():
		return {"status": Status.NOT_RESIDENT, "value": NAN}
	return {"status": Status.OK, "value": _interpolate(corners, local_to_lattice(position) - Vector2(cell), interpolation)}

func _interpolate(corners: PackedFloat64Array, local: Vector2, interpolation: int) -> float:
	var a := corners[0]
	var b := corners[1]
	var c := corners[2]
	var d := corners[3]
	var fx := clampf(local.x, 0.0, 1.0)
	var fz := clampf(local.y, 0.0, 1.0)
	if interpolation == Interpolation.BILINEAR:
		return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fz)
	if fx + fz <= 1.0:
		return a + (b - a) * fx + (c - a) * fz
	return d + (c - d) * (1.0 - fx) + (b - d) * (1.0 - fz)

## Batch query: values (NAN unless status is OK) and per-point Status bytes.
func sample_heights(positions: PackedVector2Array, interpolation: int = Interpolation.TRIANGLE) -> Dictionary:
	var values := PackedFloat32Array()
	var statuses := PackedByteArray()
	values.resize(positions.size())
	statuses.resize(positions.size())
	for index in range(positions.size()):
		var sampled := sample_height(positions[index], interpolation)
		values[index] = sampled.value
		statuses[index] = sampled.status
	return {"values": values, "status": statuses}

## World-space query through the runtime/authoring terrain's global transform.
## Returns the local query plus the world-space surface position when OK.
func sample_height_world(world_position: Vector3, terrain_transform: Transform3D, interpolation: int = Interpolation.TRIANGLE) -> Dictionary:
	var local := terrain_transform.affine_inverse() * world_position
	var result := sample_height(Vector2(local.x, local.z), interpolation)
	if result.status == Status.OK:
		result.position = terrain_transform * Vector3(local.x, result.value, local.z)
	return result

func sample_heights_world(world_positions: PackedVector3Array, terrain_transform: Transform3D, interpolation: int = Interpolation.TRIANGLE) -> Dictionary:
	var inverse := terrain_transform.affine_inverse()
	var local := PackedVector2Array()
	local.resize(world_positions.size())
	for index in range(world_positions.size()):
		var point := inverse * world_positions[index]
		local[index] = Vector2(point.x, point.z)
	var result := sample_heights(local, interpolation)
	var positions := PackedVector3Array()
	positions.resize(world_positions.size())
	for index in range(world_positions.size()):
		positions[index] = terrain_transform * Vector3(local[index].x, result.values[index], local[index].y)
	result.positions = positions
	return result

# Channels ------------------------------------------------------------------------------

## True when the bake retained the channel, so sample_channel() can return OK.
func has_channel(name: StringName) -> bool:
	return channel_names.has(String(name)) and maps.has(String(name))

static func _decode_scalar(bytes: PackedByteArray, format: int, index: int) -> float:
	match format:
		Image.FORMAT_RF: return bytes.decode_float(index * 4)
		Image.FORMAT_RH: return bytes.decode_half(index * 2)
	return float(bytes[index]) / 255.0

## {ok, status, value, coverage} in terrain-local XZ. Coverage-weighted over the defined
## corners; a defined zero is OK, never ABSENT. BILINEAR (default) weights all four corners;
## TRIANGLE uses the canonical (a, b, c) / (b, d, c) triangle containing the point. Channels
## without a coverage map are defined everywhere.
func sample_channel(name: StringName, position: Vector2, interpolation: int = Interpolation.BILINEAR) -> Dictionary:
	if not position.is_finite() or not contains_local(position):
		return {"ok": false, "status": Status.OUTSIDE, "value": NAN, "coverage": 0.0}
	if not channel_names.has(String(name)) or not maps.has(String(name)):
		return {"ok": false, "status": Status.ABSENT, "value": NAN, "coverage": 0.0}
	var lattice := local_to_lattice(position)
	var size := get_cell_resolution()
	var cell := Vector2i(clampi(floori(lattice.x), 0, size.x - 1), clampi(floori(lattice.y), 0, size.y - 1))
	var region := get_region(cell / cells)
	if region == null:
		return {"ok": false, "status": Status.NOT_RESIDENT, "value": NAN, "coverage": 0.0}
	var f := (lattice - Vector2(cell)).clamp(Vector2.ZERO, Vector2.ONE)
	# Corner weights of a, b, c, d.
	var wa := (1.0 - f.x) * (1.0 - f.y)
	var wb := f.x * (1.0 - f.y)
	var wc := (1.0 - f.x) * f.y
	var wd := f.x * f.y
	if interpolation == Interpolation.TRIANGLE:
		if f.x + f.y <= 1.0:
			wa = 1.0 - f.x - f.y; wb = f.x; wc = f.y; wd = 0.0
		else:
			wa = 0.0; wb = 1.0 - f.y; wc = 1.0 - f.x; wd = f.x + f.y - 1.0
	var key := String(name)
	var coverage_key := key + StrataRegions.COVERAGE_SUFFIX
	var values := region.level_bytes(key)
	var value_format := int(maps[key].format)
	var coverage := region.level_bytes(coverage_key) if maps.has(coverage_key) else PackedByteArray()
	var coverage_format := int(maps[coverage_key].format) if maps.has(coverage_key) else 0
	var stride := cells + 1 + 2 * apron
	var local := cell % cells
	var a := (local.y + apron) * stride + local.x + apron
	var c := a + stride
	var numerator := 0.0
	var weight_sum := 0.0
	var covered := 0.0
	for corner in [[a, wa], [a + 1, wb], [c, wc], [c + 1, wd]]:
		var index: int = corner[0]
		var weight: float = corner[1]
		var defined := _decode_scalar(coverage, coverage_format, index) if not coverage.is_empty() else 1.0
		if weight > 0.0 and defined > 0.0:
			numerator += _decode_scalar(values, value_format, index) * weight
			weight_sum += weight
			covered += defined * weight
	if weight_sum <= 0.0:
		return {"ok": false, "status": Status.ABSENT, "value": NAN, "coverage": 0.0}
	return {"ok": true, "status": Status.OK, "value": numerator / weight_sum, "coverage": covered}

## World-space sample_channel() through the terrain's global transform.
func sample_channel_world(name: StringName, world_position: Vector3, terrain_transform: Transform3D, interpolation: int = Interpolation.BILINEAR) -> Dictionary:
	var local := terrain_transform.affine_inverse() * world_position
	return sample_channel(name, Vector2(local.x, local.z), interpolation)

# Macro tint / AO -------------------------------------------------------------------------

func has_macro() -> bool:
	return maps.has(StrataRegions.MAP_MACRO)

## Metres between macro texels.
func macro_step() -> float:
	return spacing * float(int(description(StrataRegions.MAP_MACRO).scale))

## Terrain-local XZ of the first and last macro texel centres of the assembled macro image
## (see [method get_macro_image]).
func get_macro_bounds() -> Rect2:
	var size := _macro_samples()
	return Rect2(bounds.position, Vector2(size - Vector2i.ONE) * macro_step())

func _macro_samples() -> Vector2i:
	var step := macro_step()
	return Vector2i(ceili(bounds.size.x / step - 1e-6), ceili(bounds.size.y / step - 1e-6)).max(Vector2i.ONE) + Vector2i.ONE

## The macro lattice over the terrain as one RGBAH image (transitional adapter; null when
## there is none, a region is unavailable or a side exceeds MACRO_MAX_SIDE).
func get_macro_image() -> Image:
	if not has_macro() or not is_resident(): return null
	var size := _macro_samples()
	if size.x > MACRO_MAX_SIDE or size.y > MACRO_MAX_SIDE: return null
	var bytes := map_window_bytes(StrataRegions.MAP_MACRO, Rect2i(Vector2i.ZERO, size - Vector2i.ONE))
	if bytes.size() != size.x * size.y * 8: return null
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBAH, bytes)

## Shader binding of the assembled map ({ok: false} without one); see macro_binding().
func get_macro_binding() -> Dictionary:
	var image := get_macro_image()
	if image == null: return {"ok": false, "message": "No terrain-wide tint/AO map"}
	return macro_binding(image, get_macro_bounds())

## {status, tint: Color (rgb, a = 1), ao}. Bilinear between texel centres, like a
## linear-filtered clamp-to-edge texture. ABSENT/OUTSIDE return neutral values.
@warning_ignore("integer_division")
func sample_macro(position: Vector2) -> Dictionary:
	if not has_macro():
		return {"status": Status.ABSENT, "tint": MACRO_NEUTRAL, "ao": 1.0}
	if not position.is_finite() or not contains_local(position):
		return {"status": Status.OUTSIDE, "tint": MACRO_NEUTRAL, "ao": 1.0}
	var info := description(StrataRegions.MAP_MACRO)
	var n: int = cells / int(info.scale)
	var macro_apron := int(info.apron)
	var step := macro_step()
	var lattice := (position - bounds.position) / step
	var last := _macro_samples() - Vector2i.ONE
	lattice = lattice.clamp(Vector2.ZERO, Vector2(last))
	var region_index := Vector2i(mini(floori(lattice.x) / n, grid.x - 1), mini(floori(lattice.y) / n, grid.y - 1))
	var region := get_region(region_index)
	if region == null:
		return {"status": Status.NOT_RESIDENT, "tint": MACRO_NEUTRAL, "ao": 1.0}
	var local := lattice - Vector2(region_index * n)
	var texel := Vector2i(mini(floori(local.x), n - 1), mini(floori(local.y), n - 1))
	var f := local - Vector2(texel)
	var side := n + 1 + 2 * macro_apron
	var bytes := region.level_bytes(StrataRegions.MAP_MACRO)
	var at := func(dx: int, dy: int) -> Color:
		var offset := ((texel.y + macro_apron + dy) * side + texel.x + macro_apron + dx) * 8
		return Color(bytes.decode_half(offset), bytes.decode_half(offset + 2), bytes.decode_half(offset + 4), bytes.decode_half(offset + 6))
	var top: Color = at.call(0, 0).lerp(at.call(1, 0), f.x)
	var bottom: Color = at.call(0, 1).lerp(at.call(1, 1), f.x)
	var value := top.lerp(bottom, f.y)
	return {"status": Status.OK, "tint": Color(value.r, value.g, value.b, 1.0), "ao": value.a}

static func validate_macro_layout(image: Image, macro_bounds: Rect2) -> Dictionary:
	if image == null: return _error("Macro map is missing")
	if image.is_compressed() or image.has_mipmaps() or image.get_format() != Image.FORMAT_RGBAH:
		return _error("Macro map must be an uncompressed RGBAH image without mipmaps")
	if image.get_width() < 2 or image.get_height() < 2 or image.get_width() > MACRO_MAX_SIDE or image.get_height() > MACRO_MAX_SIDE:
		return _error("Macro map needs 2..%d texels per axis" % MACRO_MAX_SIDE)
	if not macro_bounds.position.is_finite() or not macro_bounds.size.is_finite() or not macro_bounds.end.is_finite() or macro_bounds.size.x <= 0.0 or macro_bounds.size.y <= 0.0:
		return _error("Macro map bounds must be finite and positive")
	return {"ok": true}

## Per-channel finite/range scan. Each channel is extracted by an engine-side
## format conversion of the byte payload shifted by whole half-floats, so no
## per-texel script loop runs when the native validator is present.
static func scan_macro_image(image: Image) -> Dictionary:
	var bytes := image.get_data()
	var minimum := Color(); var maximum := Color()
	for channel in range(4):
		var shifted := bytes.slice(channel * 2)
		shifted.resize(bytes.size())
		var extracted := Image.create_from_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBAH, shifted)
		extracted.convert(Image.FORMAT_RF)
		var scanned := _scan_floats(extracted.get_data().to_float32_array(), image.get_size())
		if not scanned.ok: return _error("Macro map values must be finite")
		minimum[channel] = scanned.min; maximum[channel] = scanned.max
	if minimum.r < 0.0 or minimum.g < 0.0 or minimum.b < 0.0 or maximum.r > MACRO_TINT_MAX or maximum.g > MACRO_TINT_MAX or maximum.b > MACRO_TINT_MAX:
		return _error("Macro tint must be in 0..%s" % MACRO_TINT_MAX)
	if minimum.a < 0.0 or maximum.a > 1.0:
		return _error("Macro ambient occlusion must be in 0..1")
	return {"ok": true, "min": minimum, "max": maximum}

## Shader contract: texel (i, j) centre lies at bounds.position + (i, j) *
## bounds.size / (resolution - 1), endpoints included. With linear filtering
## and clamp-to-edge, sample uv = local_xz * uv_scale + uv_offset.
static func macro_binding(image: Image, macro_bounds: Rect2) -> Dictionary:
	var layout := validate_macro_layout(image, macro_bounds)
	if not layout.ok: return layout
	var size := Vector2(image.get_size())
	var uv_scale := (size - Vector2.ONE) / (macro_bounds.size * size)
	return {"ok": true, "image": image, "bounds": macro_bounds, "resolution": image.get_size(), "uv_scale": uv_scale, "uv_offset": Vector2(0.5, 0.5) / size - macro_bounds.position * uv_scale}

## CPU reference of the shader lookup (clamped to the bounds).
static func sample_macro_image(image: Image, macro_bounds: Rect2, position: Vector2) -> Color:
	var last := image.get_size() - Vector2i.ONE
	var lattice := ((position - macro_bounds.position) / macro_bounds.size * Vector2(last)).clamp(Vector2.ZERO, Vector2(last))
	var cell := Vector2i(mini(floori(lattice.x), last.x - 1), mini(floori(lattice.y), last.y - 1))
	var f := lattice - Vector2(cell)
	var top := image.get_pixel(cell.x, cell.y).lerp(image.get_pixel(cell.x + 1, cell.y), f.x)
	var bottom := image.get_pixel(cell.x, cell.y + 1).lerp(image.get_pixel(cell.x + 1, cell.y + 1), f.x)
	return top.lerp(bottom, f.y)

# Renderer adapters --------------------------------------------------------------------------

## Whole height lattice as one RF image (transitional adapter, see ADAPTER_MAX_SIDE); null
## above that size or when a region is unavailable.
func create_height_image() -> Image:
	return _height_adapter().get("image")

func _height_adapter() -> Dictionary:
	if not is_resident(): return {"message": "Runtime regions are not resident"}
	var size := resolution
	if size.x > ADAPTER_MAX_SIDE or size.y > ADAPTER_MAX_SIDE:
		return {"message": "The whole-image height adapter handles at most %d samples per side; this terrain has %s (use the region windows)" % [ADAPTER_MAX_SIDE, size]}
	var bytes := map_window_bytes(StrataRegions.MAP_HEIGHT, Rect2i(Vector2i.ZERO, get_cell_resolution()))
	if bytes.size() != size.x * size.y * 4: return {"message": "A region of the height lattice is unavailable"}
	return {"image": Image.create_from_data(size.x, size.y, false, Image.FORMAT_RF, bytes)}

## Same shape as StrataProcedural.compile_heightfield(), for renderers that bind a compiled
## RF field (StrataRenderer.set_compiled_field()).
func to_compiled_field() -> Dictionary:
	var adapted := _height_adapter()
	if not adapted.has("image"): return {"ok": false, "message": adapted.message}
	return {"ok": true, "image": adapted.image, "min": height_min, "max": height_max, "bounds": bounds, "resolution": resolution, "sample_origin": Vector3(bounds.position.x, 0.0, bounds.position.y), "sample_step_x": Vector3(spacing, 0.0, 0.0), "sample_step_y": Vector3(0.0, 0.0, spacing), "bake_revision": bake_revision}
