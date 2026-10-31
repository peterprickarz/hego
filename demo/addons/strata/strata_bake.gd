@tool
class_name StrataBake
extends RefCounted
## Explicit runtime bake and export. Compiles the complete enabled stack (never
## the preview cutoff) into an StrataRuntimeData, validates every part,
## then publishes it on the terrain in one step. A failed bake leaves the
## previous runtime data and stale state untouched.

## Preloaded so bakes parse before the editor has registered the class name.
const NavProfiles := preload("strata_nav_profiles.gd")

## Cheap in-session identity of everything that affects the compiled stack.
## Stored on the terrain after a bake; any difference marks the bake stale.
static func stack_signature(terrain: StrataTerrain3D) -> Array:
	var signature: Array = [terrain.base_bounds]
	for layer in terrain.get_layers():
		var fields := {}
		for name in layer.procedural_fields:
			var field: StrataFieldData = layer.procedural_fields[name]
			fields[name] = field.signature() if field != null else {}
		signature.append([layer.get_instance_id(), layer.enabled, layer.composition_modes.duplicate(true), layer.data.get_instance_id(), layer.data.get_revision(), layer.procedural, layer.procedural_revision, layer.procedural_stale if layer.procedural else false, layer.producer_id, layer.producer_intent_revision, fields])
	return signature

const DEFAULT_BATCH := 32
const DEFAULT_MAX_DIRECTORY_BYTES := 64 * 1024 * 1024 * 1024
## The staging directory of a directory bake sits next to its target.
const STAGING_SUFFIX := ".baking"

static func _error(message: String) -> Dictionary:
	return {"ok": false, "message": message}

## Options:
##   spacing (the terrain's region_spacing): runtime lattice spacing; bounds must divide exactly.
##   region_cells (the terrain's region_cells, 0 = automatic), region_apron (2): the region grid; region_cells is a power of two.
##   mip_levels (3): levels per map including level 0 (capped per map by its size). Raised to
##     max(mip_levels, far_level + 1, coarse_level + 1) so the streamer's far tier and the coarse
##     maps exist.
##   far_level (2): the streamer's far tier level; only raises mip_levels.
##   coarse_max_side (StrataRegions.COARSE_MAX_SIDE, 1024): longest side in cells of the coarse
##     height map; picks coarse_level. Every map of the spec is stitched into data.coarse_maps.
##   cell_masks: true, a compile options Dictionary, or a precompiled
##     StrataProcedural.compile_cell_masks() result. Holes and navigation
##     exclusions then come from the layers' categorical hole/nav_exclusion
##     channels (ownership resolved before conservative reduction), composed per region
##     (a precompiled result is checked against the complete stack and sliced instead).
##   holes / nav_exclusions: explicit canonical cell masks instead, Image
##     (L8/R8/RF) or bytes, size (width - 1, height - 1). Float >= 0.5 /
##     byte >= 128 marks a cell.
##   channels: PackedStringArray of custom scalar channels to retain (deduplicated). Each
##     becomes a sample map of that name plus "<name>__coverage"; names must not start with
##     "nav_" or end with the coverage suffix.
##   channel_formats: {name: "rf" (default) | "rh" | "l8"}; rh and l8 quantize 0..1.
##   nav_profiles: Array of {"name": StringName, "rule": Dictionary} static
##     navigation profiles (StrataNavProfiles DSL), evaluated per region after the channels
##     and masks into the cell maps nav_<name> (255 = blocked) with their rules in
##     data.nav_profile_rules. Rules may only reference channels retained by
##     this bake, so every mask is reproducible from the data. The "default"
##     profile is reserved and always the nav_exclusion mask, "exclusion" is reserved too.
##   lod_level (2): first level of the partial region files (region_<i>_<j>.lod.res) saved next
##     to the full ones and recorded in the manifest; 0..15 and below mip_levels. 0 writes no lod
##     files. Left out, it is clamped to the deepest level every map has and to mip_levels - 1.
##   max_runtime_bytes: aggregate payload budget over all regions and mips of an embedded bake,
##     default/max 512 MiB. A directory bake is not bound by it.
##   region_directory: a directory (res://, user:// or absolute) to write the region files to, in
##     batches, instead of embedding them (see "Directory bakes" below). StrataBake.bake() sets it
##     to the terrain's regions directory when the terrain has a storage directory; pass "" to
##     embed anyway.
##   bake_batch (32): regions composed, written and released together in a directory bake. Memory
##     is bounded by the batch: about 1.3 MB per 256-cell region with the island's maps (a
##     batch of 32 is roughly 45 MB, plus the composition scratch of the worker threads), never
##     by the grid.
##   max_directory_bytes (64 GiB): sanity cap on the planned size of a directory bake; the free
##     space of the target drive is checked too.
##   progress: optional Callable(done_regions: int, total_regions: int) called after each batch.
##   allow_stale_procedural (false): accept cached procedural results that need
##     a recook (for example after a scene reload); listed in the report.
##   compiled: an existing compile_heightfield() result with a current token; its heights are
##     sliced into the regions instead of composing them.
##   macro ("auto"): terrain-wide tint/AO map from the terrain_tint_r/g/b and
##     terrain_ao channels (StrataMacro), composed per region as the "macro" map. "auto"
##     composes it only when an enabled layer owns one of them; true always, false never. A
##     Dictionary may carry spacing (macro texel spacing, default 4 m; spacing / bake spacing
##     must be a power of two).
##   material_ids / material_weights: no longer accepted; the material maps come from the
##     stack's editor_material_channels. Passing them is ignored and listed in
##     report.deprecated.
##   The terrain's render_settings are copied (deep duplicate) into the data.
## The regions are composed through the final layer, so the preview cutoff never matters.
## Without region_directory the result holds the regions embedded. Directory bakes: the
## regions are composed bake_batch at a time (concurrently on the worker pool), their mips
## built, their coarse cores stitched into the terrain-wide coarse maps, their extrema and
## navigation counts recorded, and their files (region_<i>_<j>.res and .lod.res) written into a
## staging directory next to the target; the batch is then dropped. When the whole stack is
## still the one that was captured, the staged files replace the target's region files (files
## of regions the grid no longer has are removed). A rejected bake therefore leaves the
## previous files and manifest untouched and removes its staging directory. The result's data
## holds no embedded regions, region_directory set, and report.written_files, disk_bytes,
## batches and peak_regions_in_memory.
static func compile(terrain: StrataTerrain3D, options: Dictionary = {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	if not is_instance_valid(terrain) or not terrain.is_inside_tree():
		return _error("Bake needs a live terrain inside the scene tree")
	if not terrain.is_transform_valid():
		return _error("Terrain bake requires translation/yaw and unit scale")
	var spacing := float(options.get("spacing", terrain.region_spacing))
	var bounds := terrain.base_bounds
	if not is_finite(spacing) or spacing <= 0.0 or not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite() or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return _error("Bake needs positive finite spacing and terrain bounds")
	var columns := bounds.size.x / spacing
	var rows := bounds.size.y / spacing
	if not is_finite(columns) or not is_finite(rows) or columns >= StrataRegions.MAX_CELLS * 4096.0 or rows >= StrataRegions.MAX_CELLS * 4096.0:
		return _error("Runtime bake exceeds the bounded sample budget")
	if absf(columns - roundf(columns)) > 0.0001 or absf(rows - roundf(rows)) > 0.0001:
		return _error("Terrain bounds %s are not a whole number of %s m intervals" % [bounds.size, spacing])
	var resolution := Vector2i(roundi(columns) + 1, roundi(rows) + 1)
	var cells := resolution - Vector2i.ONE
	var region_cells := StrataRegions.resolve_cells(int(options.get("region_cells", terrain.region_cells)), bounds, spacing)
	var region_apron := int(options.get("region_apron", StrataRegions.DEFAULT_APRON))
	var mip_levels := int(options.get("mip_levels", 3))
	if mip_levels < 1 or mip_levels > 16: return _error("mip_levels must be 1..16")
	var far_level := int(options.get("far_level", 2))
	if far_level < 0 or far_level > 15: return _error("far_level must be 0..15")
	var coarse_max_side := int(options.get("coarse_max_side", StrataRegions.COARSE_MAX_SIDE))
	if coarse_max_side < 1: return _error("coarse_max_side must be positive")
	var requested_channels := PackedStringArray()
	for name in PackedStringArray(options.get("channels", [])):
		if name == "height" or name.strip_edges().is_empty() or name.ends_with(StrataProcedural.OWNERSHIP_SUFFIX) or name.ends_with(StrataRegions.COVERAGE_SUFFIX) or name.begins_with(StrataRegions.NAV_PROFILE_PREFIX) or StrataRegions.standard_spec(bounds, spacing).maps.has(name):
			return _error("Retained channel names must be custom, nonblank, not ownership companions, coverage maps, standard maps or nav_ names")
		if not requested_channels.has(name): requested_channels.append(name)
	var payload_limit := int(options.get("max_runtime_bytes", StrataRuntimeData.MAX_PAYLOAD_BYTES))
	if payload_limit < 1 or payload_limit > StrataRuntimeData.MAX_PAYLOAD_BYTES: return _error("max_runtime_bytes must be positive and at most 512 MiB")
	var directory := String(options.get("region_directory", "")).strip_edges().rstrip("/")
	var batch_size := int(options.get("bake_batch", DEFAULT_BATCH))
	if batch_size < 1: return _error("bake_batch must be positive")
	var directory_limit := int(options.get("max_directory_bytes", DEFAULT_MAX_DIRECTORY_BYTES))
	if directory_limit < 1: return _error("max_directory_bytes must be positive")
	if not directory.is_empty() and not (directory.begins_with("res://") or directory.begins_with("user://") or directory.is_absolute_path()):
		return _error("region_directory must be a res://, user:// or absolute path, not %s" % directory)
	var profiles: Variant = options.get("nav_profiles", [])
	var profile_check: Dictionary = NavProfiles.validate_profiles(profiles, requested_channels)
	if not profile_check.ok: return profile_check
	for entry in profiles:
		if String(entry.name) == "exclusion": return _error("Navigation profile exclusion is reserved: its map would be nav_exclusion")
	var formats: Dictionary = options.get("channel_formats", {})
	var spec := _build_spec(terrain, options, spacing, region_cells, region_apron, requested_channels, formats, profiles)
	if not spec.ok: return spec
	var region_spec: Dictionary = spec.spec
	var grid := StrataRegions.grid_size(region_spec)
	var coarse_level_planned := StrataRegions.coarse_level(region_spec, coarse_max_side)
	mip_levels = maxi(mip_levels, maxi(far_level, coarse_level_planned) + 1)
	if mip_levels > 16: return _error("The far and coarse levels need %d mip levels (at most 16)" % mip_levels)
	var deepest := 15
	for name in region_spec.maps: deepest = mini(deepest, StrataRegions.max_level(region_cells, region_spec.maps[name]))
	var lod_level: int
	if options.has("lod_level"):
		lod_level = int(options.lod_level)
		if lod_level < 0 or lod_level > 15 or lod_level >= mip_levels: return _error("lod_level must be 0..15 and below the %d mip levels" % mip_levels)
		if lod_level > deepest: return _error("lod_level %d is deeper than the deepest level every map has (%d)" % [lod_level, deepest])
	else:
		lod_level = mini(2, mini(mip_levels - 1, deepest))
	var planned_bytes := StrataRegions.region_bytes(region_spec, mip_levels) * grid.x * grid.y
	if directory.is_empty():
		if planned_bytes > payload_limit: return _error("Requested runtime regions (%d bytes for %d regions) exceed the aggregate payload budget" % [planned_bytes, grid.x * grid.y])
	else:
		var lod_bytes := 0
		if lod_level > 0:
			for name in region_spec.maps:
				for level in range(lod_level, StrataRegions.level_count(region_cells, region_spec.maps[name], mip_levels)): lod_bytes += StrataRegions.map_bytes(region_cells, region_spec.maps[name], level)
		var planned_disk := planned_bytes + lod_bytes * grid.x * grid.y
		if planned_disk > directory_limit: return _error("Requested region files (%d bytes for %d regions) exceed max_directory_bytes (%d)" % [planned_disk, grid.x * grid.y, directory_limit])
		var space := _free_space(directory)
		if space >= 0 and planned_disk > space: return _error("Requested region files (%d bytes) exceed the free space of the target drive (%d bytes)" % [planned_disk, space])
	var stale: PackedStringArray = []
	for layer in terrain.get_layers():
		if layer.enabled and layer.procedural and (layer.procedural_stale or layer.procedural_fields.is_empty()):
			stale.append(String(layer.name))
	if not stale.is_empty() and not options.get("allow_stale_procedural", false):
		return _error("Stale or uncooked procedural layers: %s. Recook them, or pass allow_stale_procedural to bake their cached results." % ", ".join(stale))
	var signature := stack_signature(terrain)
	var sources := {}
	var compiled: Dictionary = options.get("compiled", {})
	if not compiled.is_empty():
		var checked := _check_compiled(terrain, compiled, resolution)
		if not checked.ok: return checked
		sources["height"] = compiled.image
	var hole_source: Variant = options.get("holes")
	var exclusion_source: Variant = options.get("nav_exclusions")
	var masks: Dictionary = {}
	var mask_options := {}
	var mask_request: Variant = options.get("cell_masks", false)
	if not (mask_request is bool and not mask_request):
		if hole_source != null or exclusion_source != null:
			return _error("Pass either cell_masks or explicit holes/nav_exclusions, not both")
		if mask_request is Dictionary and mask_request.has("token"):
			masks = mask_request
			if masks.get("resolution") != resolution or masks.get("bounds") != bounds:
				return _error("Compiled cell masks must use the bake's lattice")
			var mask_token := _check_token(terrain, masks.get("token"))
			if not mask_token.ok:
				return _error("Cell masks: " + mask_token.message)
			hole_source = masks.holes
			exclusion_source = masks.nav_exclusions
		else:
			mask_options = mask_request if mask_request is Dictionary else {}
			masks = {"ok": true}
	if hole_source != null or exclusion_source != null:
		var holes := StrataRuntimeData.canonicalize_cell_mask(hole_source, cells)
		if not holes.ok: return _error("Holes: " + holes.message)
		var exclusions := StrataRuntimeData.canonicalize_cell_mask(exclusion_source, cells)
		if not exclusions.ok: return _error("Navigation exclusions: " + exclusions.message)
		sources["holes"] = holes.mask
		sources["nav_exclusion"] = exclusions.mask
	var data := StrataRuntimeData.new()
	data.bounds = bounds
	data.spacing = spacing
	data.cells = region_cells
	data.apron = region_apron
	data.grid = grid
	data.maps = region_spec.maps
	data.mip_levels = mip_levels
	data.lod_level = lod_level
	data.channel_names = requested_channels
	var embedded := {}
	var extrema := PackedFloat64Array()
	var nav_report := {}
	var cell_size := data.get_cell_resolution()
	var hole_cells := 0
	var exclusion_cells := 0
	var compose_options := {"channels": requested_channels, "nav_profiles": profiles, "sources": sources, "mask_options": mask_options}
	var composer := StrataRegions._compose_class()
	if composer == null: return _error("Region composition needs the Strata editor-side addon")
	var captured: Dictionary = composer.call("capture", terrain, null, region_spec, compose_options)
	if not captured.get("ok", false): return _error(String(captured.get("message", "Could not capture the terrain stack")))
	compose_options["capture"] = captured
	var global_min := INF
	var global_max := -INF
	var coarse_level := coarse_level_planned
	var coarse_images := _new_coarse(region_spec, coarse_level)
	var order: Array[Vector2i] = []
	for y in range(grid.y):
		for x in range(grid.x): order.append(Vector2i(x, y))
	var stage := ""
	var stats := {"written_files": 0, "disk_bytes": 0, "batches": 0, "peak_regions_in_memory": 0}
	if not directory.is_empty():
		stage = directory + STAGING_SUFFIX
		var prepared := _prepare_stage(stage)
		if not prepared.ok: return prepared
	var progress: Callable = options.get("progress", Callable())
	var step := order.size() if directory.is_empty() else batch_size
	# Regions compose concurrently on the worker pool (nothing edits the layers while a bake
	# runs; the stack signature is checked again below), then their mips build the same way.
	for start in range(0, order.size(), step):
		var xys: Array[Vector2i] = []
		for index in range(start, mini(start + step, order.size())): xys.append(order[index])
		var composed := StrataRegions.compose_regions(terrain, null, region_spec, xys, compose_options)
		if not composed.ok:
			_discard_stage(stage)
			return _error(String(composed.message))
		var batch: Dictionary = composed.regions
		if mip_levels > 1:
			var mip_task := func(index: int) -> void: StrataRegions.build_mips(batch[xys[index]], mip_levels)
			if OS.has_feature("threads") and xys.size() > 1:
				var group := WorkerThreadPool.add_group_task(mip_task, xys.size(), -1, true, "StrataBake mips")
				WorkerThreadPool.wait_for_group_task_completion(group)
			else:
				for index in range(xys.size()): mip_task.call(index)
		for xy in xys:
			var region: StrataRegionData = batch[xy]
			extrema.append(region.height_min)
			extrema.append(region.height_max)
			global_min = minf(global_min, region.height_min)
			global_max = maxf(global_max, region.height_max)
			hole_cells += _clipped_count(region, StrataRegions.MAP_HOLES, cell_size)
			exclusion_cells += _clipped_count(region, StrataRegions.MAP_NAV_EXCLUSION, cell_size)
			for entry in profiles:
				var map := StrataRegions.nav_map_name(StringName(entry.name))
				var blocked := NavProfiles._interior_count(region.level_bytes(map), region)
				if not nav_report.has(entry.name): nav_report[entry.name] = {"blocked_cells": 0, "terms": NavProfiles.validate(entry.rule, requested_channels).terms}
				nav_report[entry.name].blocked_cells += blocked
			_blit_coarse(region_spec, coarse_images, region, coarse_level)
		stats.batches += 1
		stats.peak_regions_in_memory = maxi(stats.peak_regions_in_memory, xys.size())
		if directory.is_empty():
			embedded = batch
		else:
			var written := _write_batch(stage, batch, xys, lod_level, mip_levels)
			if not written.ok:
				_discard_stage(stage)
				return written
			stats.written_files += int(written.files)
			stats.disk_bytes += int(written.bytes)
		if progress.is_valid(): progress.call(mini(start + step, order.size()), order.size())
	data.regions = embedded
	data.coarse_level = coarse_level
	data.coarse_maps = {}
	for name in coarse_images: data.coarse_maps[name] = (coarse_images[name] as Image).get_data()
	data.region_extrema = extrema
	data.height_min = global_min
	data.height_max = global_max
	var rules := {NavProfiles.DEFAULT: NavProfiles.DEFAULT_RULE.duplicate(true)}
	for entry in profiles: rules[StringName(entry.name)] = (entry.rule as Dictionary).duplicate(true)
	data.nav_profile_rules = rules
	if terrain.render_settings != null:
		data.render_settings = terrain.render_settings.duplicate(true)
	if not directory.is_empty(): data.region_directory = directory
	var validation := data.validate()
	if not validation.ok:
		_discard_stage(stage)
		return validation
	# Nothing above awaits (a progress callback might), but the tokens are checked again so an
	# externally supplied result can never describe an older stack.
	if stack_signature(terrain) != signature or not compiled.is_empty() and not StrataProcedural.token_is_current(compiled.token) or masks.has("token") and not StrataProcedural.token_is_current(masks.token):
		_discard_stage(stage)
		return _error("Terrain stack changed while compiling; bake rejected")
	if not directory.is_empty():
		var swapped := _commit_stage(stage, directory)
		if not swapped.ok: return swapped
	var deprecated := PackedStringArray()
	for key in ["material_ids", "material_weights"]:
		if options.has(key): deprecated.append("%s is ignored: material maps are composed from the stack's editor_material_channels" % key)
	var coarse_sizes := {}
	for name in data.coarse_maps: coarse_sizes[name] = StrataRegions.coarse_map_size(region_spec, data.description(name), coarse_level)
	var report := {"resolution": resolution, "spacing": spacing, "regions": grid.x * grid.y, "grid": grid, "cells": region_cells, "mip_levels": mip_levels, "coarse_level": coarse_level, "coarse_sizes": coarse_sizes, "stale_procedural_used": stale, "mask_source": "layers" if not masks.is_empty() else ("explicit" if sources.has("holes") else "none"), "mask_report": masks.get("report", {}), "hole_cells": hole_cells, "nav_excluded_cells": exclusion_cells, "region_directory": directory, "lod_level": lod_level, "written_files": stats.written_files, "disk_bytes": stats.disk_bytes, "batches": stats.batches, "peak_regions_in_memory": stats.peak_regions_in_memory, "nav_profiles": nav_report, "macro": spec.macro_report, "deprecated": deprecated, "manifest": data.get_manifest(), "cpu_ms": (Time.get_ticks_usec() - started) / 1000.0}
	return {"ok": true, "data": data, "signature": signature, "report": report}

## One terrain-wide image per map of [param spec] at [param level], stitched from the regions'
## level cores (StrataRegions.coarse_placement). Regions are placed in row-major order, so the
## sample a region shares with its east and south neighbours ends up with the region that owns
## it; the last column and row come from the last regions. Returns name -> PackedByteArray.
static func stitch_coarse(spec: Dictionary, regions: Dictionary, level: int) -> Dictionary:
	var images := _new_coarse(spec, level)
	var grid := StrataRegions.grid_size(spec)
	for y in range(grid.y):
		for x in range(grid.x): _blit_coarse(spec, images, regions[Vector2i(x, y)], level)
	var result := {}
	for name in images: result[name] = (images[name] as Image).get_data()
	return result

static func _new_coarse(spec: Dictionary, level: int) -> Dictionary:
	var images := {}
	for name in spec.maps:
		var description: Dictionary = spec.maps[name]
		var size := StrataRegions.coarse_map_size(spec, description, level)
		images[name] = Image.create_empty(size.x, size.y, false, int(description.format))
	return images

## Places one region's level core into the coarse images (see stitch_coarse).
static func _blit_coarse(spec: Dictionary, images: Dictionary, region: StrataRegionData, level: int) -> void:
	for name in spec.maps:
		var description: Dictionary = spec.maps[name]
		var placed := StrataRegions.coarse_placement(spec, region.region, description, level)
		(images[name] as Image).blit_rect(region.get_image(name, level), placed.source, placed.destination)

## Set cells of a cell map among the region's own cells that lie inside the terrain's cells
## (the part of the last row and column of regions beyond the lattice is not counted).
static func _clipped_count(region: StrataRegionData, map: String, cell_size: Vector2i) -> int:
	if not region.has_map(map): return 0
	var bytes := region.level_bytes(map)
	var side := region.cells + 2 * region.apron
	var width := mini(region.cells, cell_size.x - region.region.x * region.cells)
	var height := mini(region.cells, cell_size.y - region.region.y * region.cells)
	var total := 0
	for row in range(height):
		var start := (region.apron + row) * side + region.apron
		total += bytes.slice(start, start + width).count(StrataRuntimeData.MASK_SET)
	return total

# Directory bakes ---------------------------------------------------------------

## Free bytes of the drive holding [param directory] (its nearest existing parent), -1 if unknown.
static func _free_space(directory: String) -> int:
	var path := ProjectSettings.globalize_path(directory)
	while not path.is_empty() and not DirAccess.dir_exists_absolute(path):
		var parent := path.get_base_dir()
		if parent == path: break
		path = parent
	var access := DirAccess.open(path)
	return access.get_space_left() if access != null else -1

## Empties (or creates) the staging directory.
static func _prepare_stage(stage: String) -> Dictionary:
	_discard_stage(stage)
	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(stage))
	if error != OK: return _error("Could not create %s (%s)" % [stage, error_string(error)])
	return {"ok": true}

static func _discard_stage(stage: String) -> void:
	if stage.is_empty(): return
	var folder := ProjectSettings.globalize_path(stage)
	if not DirAccess.dir_exists_absolute(folder): return
	for file in DirAccess.get_files_at(folder): DirAccess.remove_absolute(folder.path_join(file))
	DirAccess.remove_absolute(folder)

## Writes one batch's full and lod files into [param stage], concurrently. Files are written
## compressed like StrataStorage's. {ok, files, bytes}.
static func _write_batch(stage: String, batch: Dictionary, xys: Array[Vector2i], lod_level: int, mip_levels: int) -> Dictionary:
	var jobs: Array = []
	for xy in xys:
		var region: StrataRegionData = batch[xy]
		jobs.append([region, stage.path_join(StrataRuntimeData.REGION_FILE % [xy.x, xy.y])])
		var lod: StrataRegionData = region.partial_copy(lod_level) if lod_level > 0 and lod_level < mip_levels else null
		if lod != null: jobs.append([lod, stage.path_join(StrataRuntimeData.LOD_REGION_FILE % [xy.x, xy.y])])
	var errors: Array = []
	errors.resize(jobs.size())
	var sizes: Array = []
	sizes.resize(jobs.size())
	var task := func(index: int) -> void:
		var path: String = jobs[index][1]
		errors[index] = ResourceSaver.save(jobs[index][0], path, ResourceSaver.FLAG_COMPRESS)
		var file := FileAccess.open(path, FileAccess.READ)
		sizes[index] = file.get_length() if file != null else 0
	if OS.has_feature("threads") and jobs.size() > 1:
		var group := WorkerThreadPool.add_group_task(task, jobs.size(), -1, true, "StrataBake write")
		WorkerThreadPool.wait_for_group_task_completion(group)
	else:
		for index in range(jobs.size()): task.call(index)
	var bytes := 0
	for index in range(jobs.size()):
		if errors[index] != OK: return _error("Could not write %s (%s)" % [jobs[index][1], error_string(errors[index])])
		bytes += int(sizes[index])
	return {"ok": true, "files": jobs.size(), "bytes": bytes}

## Replaces the region files of [param directory] with the staged ones and removes the staging
## directory. Files of regions the grid no longer has go with the old ones.
static func _commit_stage(stage: String, directory: String) -> Dictionary:
	var target := ProjectSettings.globalize_path(directory)
	var source := ProjectSettings.globalize_path(stage)
	var error := DirAccess.make_dir_recursive_absolute(target)
	if error != OK:
		_discard_stage(stage)
		return _error("Could not create %s (%s)" % [directory, error_string(error)])
	for file in DirAccess.get_files_at(target):
		if file.begins_with("region_") and file.get_extension() == "res": DirAccess.remove_absolute(target.path_join(file))
	for file in DirAccess.get_files_at(source):
		error = DirAccess.rename_absolute(source.path_join(file), target.path_join(file))
		if error != OK: return _error("Could not move %s into %s (%s); the region files are incomplete, bake again" % [file, directory, error_string(error)])
	DirAccess.remove_absolute(source)
	return {"ok": true}

## The region spec of a bake: height, material maps when the terrain maps materials, cell masks
## when requested, the macro map, retained channels with coverage, and one nav_<profile> map
## per profile. {ok, spec, macro_report}.
static func _build_spec(terrain: StrataTerrain3D, options: Dictionary, spacing: float, region_cells: int, region_apron: int, channels: PackedStringArray, formats: Dictionary, profiles: Array) -> Dictionary:
	var spec := StrataRegions.standard_spec(terrain.base_bounds, spacing, region_cells, region_apron)
	var maps: Dictionary = spec.maps
	if terrain.editor_material_channels.is_empty():
		maps.erase(StrataRegions.MAP_MATERIAL_IDS)
		maps.erase(StrataRegions.MAP_MATERIAL_WEIGHTS)
	var masks: Variant = options.get("cell_masks", false)
	var wants_masks: bool = not (masks is bool and not masks) or options.get("holes") != null or options.get("nav_exclusions") != null
	if wants_masks:
		maps[StrataRegions.MAP_NAV_EXCLUSION] = StrataRegions.map(Image.FORMAT_L8, StrataRegions.KIND_CELL, 1, region_apron)
	else:
		maps.erase(StrataRegions.MAP_HOLES)
	maps.erase(StrataRegions.MAP_MACRO)
	var macro_report: Variant = null
	var request: Variant = options.get("macro", "auto")
	if not (request is bool or request is Dictionary or request is String and request == "auto"):
		return _error("macro must be \"auto\", a bool or compose options")
	if request is Dictionary and request.has("token"):
		return _error("Precompiled macro maps are not accepted: the macro map composes per region")
	if request is bool and request or request is Dictionary or request is String and request == "auto" and StrataMacro.has_macro_channels(terrain):
		var macro_spacing := float((request as Dictionary).get("spacing", StrataMacro.DEFAULT_SPACING)) if request is Dictionary else StrataMacro.DEFAULT_SPACING
		var scale := roundi(macro_spacing / spacing)
		if scale < 1 or (scale & (scale - 1)) != 0 or absf(float(scale) * spacing - macro_spacing) > 0.0001:
			return _error("Macro spacing %s must be the bake spacing %s times a power of two" % [macro_spacing, spacing])
		maps[StrataRegions.MAP_MACRO] = StrataRegions.map(Image.FORMAT_RGBAH, StrataRegions.KIND_SAMPLE, scale, 1)
		macro_report = {"owned_channels": StrataMacro.owned_channels(terrain), "scale": scale, "spacing": macro_spacing}
	for name in channels:
		var format := String(formats.get(name, "rf")).to_lower()
		if format not in ["rf", "rh", "l8"]: return _error("Channel %s format must be rf, rh or l8" % name)
		var image_format: int = {"rf": Image.FORMAT_RF, "rh": Image.FORMAT_RH, "l8": Image.FORMAT_L8}[format]
		maps[name] = StrataRegions.map(image_format, StrataRegions.KIND_SAMPLE, 1, region_apron)
		maps[name + StrataRegions.COVERAGE_SUFFIX] = StrataRegions.map(Image.FORMAT_RF if format == "rf" else Image.FORMAT_L8, StrataRegions.KIND_SAMPLE, 1, region_apron)
	for entry in profiles:
		maps[StrataRegions.nav_map_name(StringName(entry.name))] = StrataRegions.map(Image.FORMAT_L8, StrataRegions.KIND_CELL, 1, region_apron)
	var checked := StrataRegions.validate_spec(spec)
	if not checked.ok: return checked
	return {"ok": true, "spec": spec, "macro_report": macro_report}

## compile() and publish on success. The terrain's old bake survives failure.
## A terrain with a storage directory bakes straight into its regions directory (see the
## region_directory option); publishing then only writes the manifest.
static func bake(terrain: StrataTerrain3D, options: Dictionary = {}) -> Dictionary:
	if not options.has("region_directory") and StrataStorage.has_storage(terrain):
		options = options.duplicate()
		options["region_directory"] = StrataStorage.regions_directory(terrain)
	var result := compile(terrain, options)
	if not result.ok:
		return result
	terrain.publish_runtime_data(result.data, result.signature)
	return result

static func _check_compiled(terrain: StrataTerrain3D, compiled: Dictionary, resolution: Vector2i) -> Dictionary:
	if not compiled.get("ok", false):
		return _error("Height compilation failed: %s" % compiled.get("message", "no result"))
	var image: Image = compiled.get("image")
	if image == null or image.get_format() != Image.FORMAT_RF or image.get_size() != resolution:
		return _error("Compiled heights must be an RF image of %s samples" % resolution)
	if compiled.get("bounds") != terrain.base_bounds:
		return _error("Compiled heights must cover the complete terrain bounds")
	if not is_finite(float(compiled.get("min", NAN))) or not is_finite(float(compiled.get("max", NAN))) or float(compiled.min) > float(compiled.max):
		return _error("Compiled heights need a finite min/max")
	var token := _check_token(terrain, compiled.get("token"))
	if not token.ok:
		return _error("Compiled heights: " + token.message)
	# Native compilation guarantees finite values; an external image is checked.
	var validation: Dictionary = StrataLayerData.validate_dense(image)
	if not validation.ok:
		return _error("Compiled heights: " + validation.message)
	return {"ok": true, "min": validation.min, "max": validation.max}

## A compile token must be current and cover the complete stack.
static func _check_token(terrain: StrataTerrain3D, token: Variant) -> Dictionary:
	if not token is Dictionary or not StrataProcedural.token_is_current(token):
		return _error("stale or missing revision token")
	var layers := terrain.get_layers()
	if token.get("mode") != "empty" and (layers.is_empty() or not token.has("selected") or token.selected.get_ref() != layers[-1] or token.get("mode") != "cumulative"):
		return _error("must include the complete stack, not a preview cutoff")
	return {"ok": true}

## Builds a new runtime terrain (no authoring layers, ownership or producers):
## a Node3D with the authoring terrain's local transform, the compiled data in
## meta "strata_runtime_data", and optional Collision / Navigation
## children. The authoring scene is not modified.
## Options: name, collision (bool or settings Dictionary), navigation (same),
## allow_stale_bake (false), share_data (false: copy the data; true: reference
## the terrain's published resource, avoiding a second large payload, e.g.
## when the export is saved right away), embed_regions (default: true when the
## payload is below 64 MiB; embedded regions travel inside the data resource, otherwise the
## copy keeps pointing at the terrain's region directory, which must then ship with it).
static func export_runtime(terrain: StrataTerrain3D, options: Dictionary = {}) -> Dictionary:
	if not is_instance_valid(terrain) or terrain.runtime_data == null:
		return _error("Export needs a terrain with a published runtime bake")
	if terrain.is_runtime_bake_stale() and not options.get("allow_stale_bake", false):
		return _error("Runtime bake is stale; bake again before exporting")
	var data: StrataRuntimeData = terrain.runtime_data
	if not options.get("share_data", false):
		var embed := bool(options.get("embed_regions", terrain.runtime_data.payload_bytes() < StrataRuntimeData.EMBED_LIMIT_BYTES))
		if not embed and terrain.runtime_data.region_directory.is_empty():
			return _error("embed_regions=false needs regions saved in a storage directory to point at")
		data = terrain.runtime_data.duplicate_runtime(embed)
		if data == null: return _error("Could not load every region of the published bake for the export")
	var validation := data.validate()
	if not validation.ok:
		return validation
	var root := Node3D.new()
	root.name = String(options.get("name", String(terrain.name)))
	root.transform = terrain.transform
	root.set_meta(&"strata_runtime_data", data)
	for entry in [["collision", "Collision", StrataCollision], ["navigation", "Navigation", StrataNavigation]]:
		var settings: Variant = options.get(entry[0], false)
		if settings is bool and not settings:
			continue
		var node: Node3D = entry[2].new()
		node.name = entry[1]
		node.data = data
		if settings is Dictionary:
			for property in settings:
				if not property in node:
					node.free()
					root.free()
					return _error("Unknown %s setting %s" % [entry[0], property])
				node.set(property, settings[property])
				if node.get(property) != settings[property]:
					node.free(); root.free()
					return _error("Invalid %s setting %s" % [entry[0], property])
		root.add_child(node)
		node.owner = root
	return {"ok": true, "root": root, "data": data}

## Packs export_runtime() into a scene. With data_path, the compiled data is
## saved as its own resource and referenced by the scene.
static func save_runtime_scene(terrain: StrataTerrain3D, path: String, options: Dictionary = {}) -> Dictionary:
	var exported := export_runtime(terrain, options)
	if not exported.ok:
		return exported
	var root: Node3D = exported.root
	var data_path := String(options.get("data_path", ""))
	if not data_path.is_empty():
		var saved := ResourceSaver.save(exported.data, data_path)
		if saved != OK:
			root.free()
			return _error("Could not save runtime data to %s (%s)" % [data_path, error_string(saved)])
		exported.data.take_over_path(data_path)
	var packed := PackedScene.new()
	var packed_error := packed.pack(root)
	root.free()
	if packed_error != OK:
		return _error("Could not pack runtime terrain (%s)" % error_string(packed_error))
	var error := ResourceSaver.save(packed, path)
	if error != OK:
		return _error("Could not save runtime scene to %s (%s)" % [path, error_string(error)])
	return {"ok": true, "path": path, "data_path": data_path}
