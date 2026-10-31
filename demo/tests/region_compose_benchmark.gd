extends SceneTree
## Benchmark (NOT part of run_tests.sh): where region composition spends its time.
##
## Builds a synthetic terrain shaped like the island (4096 m at 1 m, 256-cell regions, a 16 x 16
## grid, a base height layer, four material channels with varied coverage, a hole channel and
## macro channels), composes every region per map class serially, then the whole region
## (compose_region and build_mips as the bake does) serially and, when available, in parallel
## with StrataRegions.compose_regions. The native share is measured by timing
## StrataLayerData.compose_dense directly on the same windows.
##
##   Godot --headless --path demo --script res://tests/region_compose_benchmark.gd
##   ... -- --grid=8        a smaller synthetic terrain (grid x grid regions, default 16)
##   ... -- --island        also time the saved island (needs ~4 GB; run with no other Godot open)
##   ... -- --no-synthetic  skip the synthetic terrain
##
## The synthetic data is a benchmark fixture (smooth noise), not island content.

const CELLS := 256
const APRON := 2

var grid := 16
var terrain: StrataTerrain3D

func _initialize() -> void:
	run.call_deferred()

func ms(started: int) -> String:
	return "%8.0f ms" % ((Time.get_ticks_usec() - started) / 1000.0)

func noise_rf(size: Vector2i, seed_value: int, frequency: float) -> Image:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = frequency
	var image := noise.get_image(size.x, size.y, false, false, false)
	image.convert(Image.FORMAT_RF)
	return image

func ownership(size: Vector2i, rect: Rect2i) -> Image:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RF)
	image.fill_rect(rect, Color(1, 0, 0, 1))
	return image

func make_layer(label: String, spacing: float, origin: Vector2) -> StrataLayer:
	var layer := StrataLayer.new()
	layer.name = label
	layer.data.sample_spacing = spacing
	layer.data.grid_origin = origin
	terrain.add_child(layer)
	layer.owner = terrain
	return layer

func build_synthetic() -> void:
	var started := Time.get_ticks_usec()
	var side := float(grid * CELLS)
	terrain = StrataTerrain3D.new()
	terrain.name = "Terrain"
	terrain.base_bounds = Rect2(-side * 0.5, -side * 0.5, side, side)
	terrain.editor_material_channels = PackedStringArray(["mat_a", "mat_b", "mat_c", "mat_d"])
	terrain.set_preview_enabled(false)
	root.add_child(terrain)
	var origin := terrain.base_bounds.position
	var fine := Vector2i(grid * CELLS + 1, grid * CELLS + 1)
	var coarse := Vector2i(grid * CELLS / 4 + 1, grid * CELLS / 4 + 1)
	var base := make_layer("Base", 1.0, origin)
	base.data.replace_dense(&"height", Vector2i.ZERO, noise_rf(fine, 1, 0.002))
	# Height shaped by a second layer at 4 m (Add).
	var detail := make_layer("Detail", 4.0, origin)
	detail.set_composition(&"height", StrataLayer.Composition.ADD)
	detail.data.replace_dense(&"height", Vector2i.ZERO, noise_rf(coarse, 2, 0.01), ownership(coarse, Rect2i(0, 0, coarse.x * 3 / 4, coarse.y)))
	var materials := make_layer("Materials", 4.0, origin)
	materials.data.replace_dense(&"mat_a", Vector2i.ZERO, noise_rf(coarse, 3, 0.01))
	materials.data.replace_dense(&"mat_b", Vector2i.ZERO, noise_rf(coarse, 4, 0.01), ownership(coarse, Rect2i(0, 0, coarse.x / 2, coarse.y)))
	materials.data.replace_dense(&"mat_c", Vector2i.ZERO, noise_rf(coarse, 5, 0.02), ownership(coarse, Rect2i(coarse.x / 4, coarse.y / 4, coarse.x / 2, coarse.y / 2)))
	var painted := make_layer("Painted", 1.0, origin)
	var patch := Vector2i(mini(1024, fine.x), mini(1024, fine.y))
	painted.data.replace_dense(&"mat_d", Vector2i(fine.x / 4, fine.y / 4), noise_rf(patch, 6, 0.03))
	var holes := make_layer("Holes", 4.0, origin)
	var hole_values := Image.create(coarse.x, coarse.y, false, Image.FORMAT_RF)
	hole_values.fill(Color(1, 0, 0, 1))
	var hole_owned := Image.create(coarse.x, coarse.y, false, Image.FORMAT_RF)
	for index in range(24):
		hole_owned.fill_rect(Rect2i((index * 97) % maxi(coarse.x - 30, 1), (index * 61) % maxi(coarse.y - 30, 1), 12 + index % 9, 10 + index % 7), Color(1, 0, 0, 1))
	holes.data.replace_dense(&"hole", Vector2i.ZERO, hole_values, hole_owned)
	var shade := make_layer("Shade", 4.0, origin)
	shade.data.replace_dense(&"terrain_ao", Vector2i.ZERO, noise_rf(coarse, 7, 0.01))
	shade.data.replace_dense(&"terrain_tint_r", Vector2i.ZERO, noise_rf(coarse, 8, 0.01), ownership(coarse, Rect2i(0, 0, coarse.x, coarse.y / 2)))
	print("synthetic terrain built in %s: %d m, %dx%d regions of %d cells, %d layers" % [ms(started).strip_edges(), int(side), grid, grid, CELLS, terrain.get_layers().size()])

func region_list(spec: Dictionary) -> Array[Vector2i]:
	var list: Array[Vector2i] = []
	var size := StrataRegions.grid_size(spec)
	for y in range(size.y):
		for x in range(size.x):
			list.append(Vector2i(x, y))
	return list

func profile(label: String, spec: Dictionary, options: Dictionary) -> void:
	print("== %s ==" % label)
	var xys := region_list(spec)
	# Per map class, serial, one compose_map per region.
	var total := 0
	for map in ["height", "holes", "material_ids", "macro"]:
		if not spec.maps.has(map): continue
		var started := Time.get_ticks_usec()
		for xy in xys:
			var window := StrataRegions.map_window(spec, xy, spec.maps[map])
			var composed := StrataRegionCompose.compose_map(terrain, null, map, window, spec, options)
			if not composed.ok: print("  %s failed: %s" % [map, composed.message]); return
		var elapsed := Time.get_ticks_usec() - started
		total += elapsed
		print("  compose_map %-13s serial %s  (%d regions)" % [map, ms(started), xys.size()])
	print("  classes total           serial %8.0f ms" % (total / 1000.0))
	# Native share: compose_dense alone on every height window, descriptors captured once.
	var descriptors := StrataProcedural._capture_layers(terrain, &"height", null)
	var started := Time.get_ticks_usec()
	var native_us := 0
	for xy in xys:
		var window := StrataRegions.map_window(spec, xy, spec.maps.height)
		var origin := Vector3(spec.bounds.position.x, 0.0, spec.bounds.position.y)
		var before := Time.get_ticks_usec()
		ClassDB.class_call_static(&"StrataLayerData", &"compose_dense", descriptors, &"height", origin, Vector3(window.step, 0, 0), Vector3(0, 0, window.step), window.size, terrain.base_bounds, false, 0.0, window.first)
		native_us += Time.get_ticks_usec() - before
	print("  native compose_dense, height only            %8.0f ms (native calls %.0f ms)" % [(Time.get_ticks_usec() - started) / 1000.0, native_us / 1000.0])
	# Whole regions as the bake builds them.
	started = Time.get_ticks_usec()
	var kept: Array[StrataRegionData] = []
	for xy in xys:
		var composed := StrataRegions.compose_region(terrain, null, xy, spec, options)
		if not composed.ok: print("  compose_region failed: %s" % composed.message); return
		kept.append(composed.region)
	print("  compose_region x%d      serial %s" % [xys.size(), ms(started)])
	started = Time.get_ticks_usec()
	for region in kept: StrataRegions.build_mips(region, 5)
	print("  build_mips (5 levels) x%d serial %s" % [xys.size(), ms(started)])
	kept.clear()
	var regions_script: GDScript = load("res://addons/strata/strata_regions.gd")
	if regions_script.get_script_method_list().any(func(entry: Dictionary) -> bool: return entry.name == "compose_regions"):
		for threads in [true]:
			started = Time.get_ticks_usec()
			var result: Dictionary = regions_script.call("compose_regions", terrain, null, spec, xys, options.merged({"threads": threads}))
			print("  compose_regions x%d     parallel %s  ok=%s %s" % [xys.size(), ms(started), result.ok, result.get("message", "")])
			if result.ok:
				started = Time.get_ticks_usec()
				var pool: Array = result.regions.values()
				var task := WorkerThreadPool.add_group_task(func(index: int) -> void: StrataRegions.build_mips(pool[index], 5), pool.size(), -1, true, "benchmark mips")
				WorkerThreadPool.wait_for_group_task_completion(task)
				print("  build_mips x%d          parallel %s" % [pool.size(), ms(started)])

func run() -> void:
	var args := OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--grid="): grid = int(arg.trim_prefix("--grid="))
	if not args.has("--no-synthetic"):
		build_synthetic()
		await process_frame
		var spec := StrataRegions.standard_spec(terrain.base_bounds, 1.0, CELLS, APRON)
		profile("synthetic island-like terrain", spec, {})
		terrain.queue_free()
		await process_frame
	if args.has("--island"):
		await island_profile()
	quit(0)

func island_profile() -> void:
	var packed := load("res://scenes/terrain_island.tscn") as PackedScene
	if packed == null: print("island scene not loadable"); return
	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	await process_frame
	terrain = scene.get_node("Terrain") as StrataTerrain3D
	var spec := terrain.region_spec()
	var options := {"channels": PackedStringArray(), "nav_profiles": []}
	profile("saved island (%s)" % terrain.base_bounds, spec, options)
