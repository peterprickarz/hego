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

## Writes the regions as region_i_j.res plus the manifest, the way StrataStorage does.
static func save_external(data: StrataRuntimeData, folder: String) -> String:
	DirAccess.make_dir_recursive_absolute(folder)
	for file in DirAccess.get_files_at(folder): DirAccess.remove_absolute(folder.path_join(file))
	for xy in data.regions: ResourceSaver.save(data.regions[xy], folder.path_join(StrataRuntimeData.REGION_FILE % [xy.x, xy.y]))
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
