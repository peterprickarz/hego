extends "res://tests/runtime_test_base.gd"
## Threaded region loading and the coarse-map fields of StrataRuntimeData (Phase B, D2): a saved
## region directory, request/poll/evict, the synchronous get_region fallback, one report per
## missing file, coarse map validation, and coarse maps surviving duplicate and a resource round
## trip. Runtime scripts only, no Houdini or native extension.

const DIRECTORY := "../build/test-scratch/runtime_loading"

func _initialize() -> void:
	call_deferred("run")

static func scratch() -> String:
	return ProjectSettings.globalize_path("res://").path_join(DIRECTORY).simplify_path()

## 64 m terrain, 16-cell regions (4 x 4), mips 3, coarse level 1 stitched from the regions.
static func make_mipped() -> StrataRuntimeData:
	var data := make_data(Rect2(-32, -32, 64, 64), Vector2i(65, 65))
	for xy in data.regions: StrataRegions.build_mips(data.regions[xy], 3)
	data.mip_levels = 3
	data.coarse_level = 1
	data.coarse_maps = StrataBake.stitch_coarse(data.get_spec(), data.regions, 1)
	finish_data(data)
	return data

## Writes the regions as region_i_j.res and region_i_j.lod.res plus the manifest, the way StrataStorage does.
static func save_external(data: StrataRuntimeData, folder: String) -> String:
	DirAccess.make_dir_recursive_absolute(folder)
	for file in DirAccess.get_files_at(folder): DirAccess.remove_absolute(folder.path_join(file))
	for xy in data.regions:
		ResourceSaver.save(data.regions[xy], folder.path_join(StrataRuntimeData.REGION_FILE % [xy.x, xy.y]))
		ResourceSaver.save((data.regions[xy] as StrataRegionData).partial_copy(data.lod_level), folder.path_join(StrataRuntimeData.LOD_REGION_FILE % [xy.x, xy.y]))
	var manifest := data.duplicate_runtime(false)
	manifest.regions = {}
	manifest.region_directory = folder
	ResourceSaver.save(manifest, folder.path_join("runtime_data.res"))
	return folder.path_join("runtime_data.res")

func wait_for(external: StrataRuntimeData, wanted: Array[Vector2i], frames: int = 600) -> Array[Vector2i]:
	var arrived: Array[Vector2i] = []
	for frame in range(frames):
		await process_frame
		arrived.append_array(external.poll_regions())
		var all := true
		for xy in wanted:
			if not external.has_cached_region(xy): all = false
		if all: break
	return arrived

func run() -> void:
	var source := make_mipped()
	check(source.validate().ok, "mipped source validates: %s" % source.validate())
	check(source.has_coarse_maps() and source.coarse_image("height") != null and source.coarse_image("height").get_size() == Vector2i(33, 33), "coarse height at level 1 is 33 x 33")
	check(source.coarse_image("nothing") == null, "unknown coarse map has no image")
	var manifest_path := save_external(source, scratch())
	var external := ResourceLoader.load(manifest_path, "", ResourceLoader.CACHE_MODE_IGNORE) as StrataRuntimeData
	check(external != null and external.regions.is_empty() and external.region_directory == scratch(), "manifest loads external")
	check(external.validate().ok and external.is_resident() and external.coarse_level == 1 and external.coarse_maps.size() == source.coarse_maps.size(), "external manifest validates with its coarse maps")
	check(external.coarse_maps["height"] == source.coarse_maps["height"], "coarse bytes survive a resource round trip")
	check(external.payload_bytes() == source.payload_bytes(), "payload bytes agree and include the coarse maps")
	check(source.payload_bytes() == source.grid.x * source.grid.y * StrataRegions.region_bytes(source.get_spec(), 3) + source.coarse_bytes(), "payload = regions + coarse")

	var a := Vector2i(1, 1)
	var b := Vector2i(3, 2)
	check(external.request_region(a) and external.request_region(b), "two requests start")
	check(not external.request_region(a), "a pending region is not requested twice")
	check(external.is_region_pending(a) and external.is_region_pending(b) and external.pending_count() == 2, "both are pending")
	check(not external.request_region(Vector2i(-1, 0)) and not external.request_region(Vector2i(4, 0)), "regions outside the grid are refused")
	check(not source.request_region(a), "embedded regions are never requested")
	var arrived := await wait_for(external, [a, b])
	check(arrived.size() == 2 and arrived.has(a) and arrived.has(b), "poll delivers both regions (%s)" % [arrived])
	check(external.pending_count() == 0 and not external.is_region_pending(a), "nothing pending after delivery")
	check(external.poll_regions().is_empty(), "a second poll delivers nothing")
	check(external.cached_region_keys().size() == 2 and external.cache_bytes() == 2 * source.regions[a].payload_bytes(), "cache holds the two regions: %d bytes" % external.cache_bytes())
	check(not external.request_region(a), "a cached region is not requested")
	for xy in [a, b]:
		var loaded := external.get_region(xy)
		var original: StrataRegionData = source.regions[xy]
		var same: bool = loaded != null and loaded.region == xy and loaded.map_names() == original.map_names()
		if same:
			for name in original.map_names():
				for level in range(original.level_count(name)):
					if loaded.level_bytes(name, level) != original.level_bytes(name, level): same = false
		check(same, "region %s equals the embedded one byte for byte, every level" % xy)
	check(external.evict_region(a) and not external.has_cached_region(a) and external.cached_region_keys() == [b], "eviction drops one region")
	check(not external.evict_region(a), "evicting twice reports false")
	var again := external.get_region(a)
	check(again != null and again.region == a and external.has_cached_region(a), "get_region reloads an evicted region synchronously")
	check(not source.evict_region(a) and source.regions.has(a), "embedded regions are never evicted")

	# get_region completes a pending load.
	var c := Vector2i(0, 3)
	check(external.request_region(c) and external.is_region_pending(c), "request c")
	var completed := external.get_region(c)
	check(completed != null and not external.is_region_pending(c) and external.has_cached_region(c), "get_region completes a pending load")
	check(external.poll_regions().is_empty(), "no stale pending entry remains")

	# Missing files report once.
	DirAccess.remove_absolute(scratch().path_join(StrataRuntimeData.REGION_FILE % [2, 0]))
	var gone := Vector2i(2, 0)
	check(not external.request_region(gone) and external.is_region_missing(gone), "a missing file fails the request and is remembered")
	check(not external.request_region(gone) and external.get_region(gone) == null, "a known-missing region is neither requested nor loaded again")
	external.clear_region_cache()
	check(not external.is_region_missing(gone) and external.cached_region_keys().is_empty(), "clearing the cache forgets failures")

	await level_files(source, external)

	# Coarse map validation.
	var broken := source.duplicate_runtime()
	check(broken.coarse_level == 1 and broken.coarse_maps["height"] == source.coarse_maps["height"] and broken.validate().ok, "duplicate carries the coarse maps")
	broken.coarse_maps["height"] = PackedByteArray([1, 2, 3])
	check(not broken.validate().ok, "a short coarse map is rejected")
	broken.coarse_maps = {"height": source.coarse_maps["height"], "ghost": PackedByteArray()}
	check(not broken.validate().ok, "a coarse map outside the spec is rejected")
	broken.coarse_maps = {"height": "text"}
	check(not broken.validate().ok, "a coarse map that is not bytes is rejected")
	broken.coarse_maps = source.coarse_maps.duplicate()
	broken.coarse_level = 3
	check(not broken.validate().ok, "a coarse level beyond the mips is rejected")
	var bare := source.duplicate_runtime()
	bare.coarse_maps = {}
	check(bare.validate().ok and not bare.has_coarse_maps(), "coarse maps are optional")
	check(source.get_manifest().coarse_level == 1 and source.get_manifest().coarse_bytes == source.coarse_bytes() and source.get_manifest().coarse_maps.has("height"), "the manifest reports the coarse maps")

	# Coarse maps without regions.
	var horizon := source.duplicate_runtime()
	horizon.regions = {}
	check(horizon.validate().ok and not horizon.is_resident() and horizon.coarse_image("height") != null, "coarse maps alone validate, but the manifest is not resident")
	finish("runtime_loading_test")

## Partial regions and level files: lod loads, cache replacement, embedded regions unaffected.
func level_files(source: StrataRuntimeData, external: StrataRuntimeData) -> void:
	var a := Vector2i(1, 1)
	var original: StrataRegionData = source.regions[a]
	var partial := original.partial_copy(2)
	check(partial != null and partial.first_level == 2 and partial.validate().ok and original.first_level == 0, "partial_copy holds levels 2.. and validates")
	var shaped := true
	for name in original.map_names():
		shaped = shaped and partial.level_count(name) == original.level_count(name) and partial.level_count(name) >= 1 and partial.has_level(name, 2) and not partial.has_level(name, 1) and partial.level_bytes(name, 2) == original.level_bytes(name, 2) and partial.level_bytes(name, 1).is_empty() and partial.level_bytes(name, 0).is_empty() and partial.get_image(name, 0) == null and partial.get_image(name, 1) == null and partial.get_image(name, 2) != null and (partial.maps[name].levels as Array).size() == original.level_count(name) - 2
	check(shaped, "level_count is the highest level + 1, lower levels read as absent, levels[0] is level first_level")
	check(partial.payload_bytes() < original.payload_bytes() and partial.payload_bytes() > 0 and original.partial_copy(4) == null and partial.partial_copy(1) == null and partial.partial_copy(2) != null, "payload counts what is held; impossible partial copies are refused")
	var image := partial.get_image("height", 2)
	check(partial.set_image("height", image, 1) == false and partial.set_image("height", image, 2) and partial.get_image("height", 2).get_data() == image.get_data(), "set_image works at or above first_level only")
	var clone := StrataRuntimeData.clone_region(partial)
	check(clone.first_level == 2 and clone.validate().ok and clone.level_bytes("height", 2) == partial.level_bytes("height", 2), "clone keeps first_level")
	var broken := original.partial_copy(2)
	broken.maps["height"].levels = [PackedByteArray([1, 2])]
	check(not broken.validate().ok, "a partial region with a wrong level size is invalid")
	broken = original.partial_copy(2)
	broken.first_level = 99
	check(not broken.validate().ok, "an impossible first_level is invalid")
	# The renderer's predicates (strata_renderer.gd _region_problem / _bind_region) hold for lod data.
	var renderer_ok: bool = partial.validate().ok
	for name in external.maps: renderer_ok = renderer_ok and partial.has_map(name) and partial.level_count(name) >= 1 and partial.get_image(name, 2) != null
	check(renderer_ok, "a partial region passes the renderer's checks and offers every shader map at the far level")

	external.clear_region_cache()
	check(external.lod_level == 2 and external.region_path(a, 2).ends_with("region_1_1.lod.res") and external.region_path(a, 3).ends_with("region_1_1.lod.res") and external.region_path(a, 0).ends_with("region_1_1.res") and external.region_path(a, 1).ends_with("region_1_1.res"), "region_path picks the lod file from lod_level up")
	check(external.request_region(a, 2) and external.is_region_pending(a) and not external.request_region(a, 2) and not external.request_region(a, 0), "a pending lod load blocks a second request of either kind")
	var arrived := await wait_for(external, [a])
	var lod_region := external.get_region(a, 2)
	check(arrived == [a] and lod_region != null and lod_region.first_level == 2 and external.cached_first_level(a) == 2, "poll delivers the lod region")
	check(external.has_cached_region(a, 2) and external.has_cached_region(a, 3) and not external.has_cached_region(a, 1) and not external.has_cached_region(a, 0) and not external.request_region(a, 2), "a cached lod region satisfies min_level >= lod_level only")
	check(external.cache_bytes() == lod_region.payload_bytes() and lod_region.payload_bytes() < source.regions[a].payload_bytes(), "the lod cache holds only the partial bytes")
	check(external.request_region(a, 0) and external.is_region_pending(a), "a request for level 0 loads the full file though lod data is cached")
	arrived = await wait_for(external, [a])
	var wait_frames := 0
	while external.cached_first_level(a) != 0 and wait_frames < 600:
		await process_frame
		arrived.append_array(external.poll_regions())
		wait_frames += 1
	check(external.cached_first_level(a) == 0 and arrived.has(a) and external.get_region(a, 2).first_level == 0 and external.has_cached_region(a, 0) and not external.request_region(a, 2), "the full region replaced the lod one and now satisfies every level")
	check(external.get_region(a).payload_bytes() == source.regions[a].payload_bytes(), "full data restored")
	# A lod request while full data is cached loads nothing.
	var b := Vector2i(3, 2)
	check(external.get_region(b, 0) != null and not external.request_region(b, 2) and external.cached_first_level(b) == 0, "a cached full region is never replaced by lod data")
	# Synchronous get_region with a level: lod from the file, then full replaces it; a pending lod is completed.
	var c := Vector2i(0, 3)
	var sync_lod := external.get_region(c, 2)
	check(sync_lod != null and sync_lod.first_level == 2 and external.get_region(c, 1).first_level == 0 and external.cached_first_level(c) == 0, "get_region(xy, min_level) loads the file for that level and replaces lod data when level 0 is asked")
	var d := Vector2i(2, 3)
	check(external.request_region(d, 2) and external.get_region(d, 0).first_level == 0 and not external.is_region_pending(d) and external.cached_first_level(d) == 0, "get_region completes a pending lod load and then loads the full file")
	check(external.poll_regions().is_empty(), "no stale pending entries remain")
	# Accessors work on level 0 even when only lod data is cached.
	var e := Vector2i(2, 2)
	external.evict_region(e)
	external.request_region(e, 2)
	await wait_for(external, [e])
	check(external.cached_first_level(e) == 2, "fixture: only lod data cached for e")
	var local := (source.regions[e] as StrataRegionData).origin + Vector2(3.5, 4.5)
	var expected := source.sample_height(local)
	var sampled := external.sample_height(local)
	check(sampled.status == expected.status and is_equal_approx(float(sampled.value), float(expected.value)) and external.cached_first_level(e) == 0, "sample_height asks for level 0: the full file loads and replaces the lod data")
	# Embedded regions are always full and unaffected.
	check(source.get_region(a, 2) == source.regions[a] and source.has_cached_region(a, 5) and not source.request_region(a, 2) and not source.request_region(a, 0) and source.cached_first_level(a) == -1 and source.get_region(a, 0).first_level == 0, "embedded regions are full and never requested")
	# A lod file that is not partial, or a missing lod file, is handled.
	var folder := scratch()
	var f := Vector2i(3, 0)
	ResourceSaver.save(source.regions[f], folder.path_join(StrataRuntimeData.LOD_REGION_FILE % [f.x, f.y]))
	external.evict_region(f)
	check(external.request_region(f, 2), "the request starts")
	var wait := 0
	while external.is_region_pending(f) and wait < 600:
		await process_frame
		external.poll_regions()
		wait += 1
	check(not external.has_cached_region(f, 2) and external.is_region_missing(f), "a lod file holding every level is rejected")
	var g := Vector2i(0, 1)
	DirAccess.remove_absolute(folder.path_join(StrataRuntimeData.LOD_REGION_FILE % [g.x, g.y]))
	external.evict_region(g)
	check(external.region_path(g, 2).ends_with("region_0_1.res") and external.request_region(g, 2), "without a lod file the full file serves the request")
	wait = 0
	while external.is_region_pending(g) and wait < 600:
		await process_frame
		external.poll_regions()
		wait += 1
	check(external.cached_first_level(g) == 0 and external.has_cached_region(g, 2), "full data satisfies the far request")
	external.lod_level = 16
	check(not external.validate().ok, "an out-of-range lod_level is invalid")
	external.lod_level = 2
	check(external.duplicate_runtime().lod_level == 2 and external.get_manifest().lod_level == 2, "lod_level survives duplicate and appears in the manifest")
	external.clear_region_cache()
