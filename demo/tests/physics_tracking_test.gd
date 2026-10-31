extends "res://tests/runtime_test_base.gd"
## StrataCollision and StrataNavigation follow a tracked target on a synthetic 1 km
## terrain (ARTIFICIAL noise heights and a hole; a test fixture, not a game asset): a
## target crosses it in fast steps; resident chunk/tile counts stay within their budgets,
## the target's chunk/tile is always resident, far ones are evicted, results for tiles
## the target left are dropped, and the per-tick cost is logged.

const SIDE := 1024
const REGION_CELLS := 64

var world: Node3D
var data: StrataRuntimeData
var target: Node3D

func _initialize() -> void:
	call_deferred("run")

func height_at(i: int, j: int, noise: FastNoiseLite) -> float:
	return noise.get_noise_2d(i, j) * 25.0

func local_of(world: Vector3) -> Vector2:
	return Vector2(world.x, world.z)

func place(local: Vector2) -> void:
	var height := float(data.sample_height(local).get("value", 0.0))
	target.position = Vector3(local.x, (height if is_finite(height) else 0.0) + 1.0, local.y)

func run() -> void:
	var noise := FastNoiseLite.new()
	noise.frequency = 0.004
	noise.seed = 7
	var started := Time.get_ticks_usec()
	var bounds := Rect2(-SIDE / 2.0, -SIDE / 2.0, SIDE, SIDE)
	data = make_data(bounds, Vector2i(SIDE + 1, SIDE + 1), func(i: int, j: int) -> float: return height_at(i, j, noise), REGION_CELLS)
	add_cell_map(data, "holes", [Rect2i(600, 600, 12, 6)])
	print("physics_tracking: built 1 km fixture (%d regions) in %.0f ms" % [data.grid.x * data.grid.y, (Time.get_ticks_usec() - started) / 1000.0])
	check(data.validate().ok, "synthetic terrain validates")

	world = Node3D.new()
	world.name = "World"
	get_root().add_child(world)
	NavigationServer3D.map_set_merge_rasterizer_cell_scale(world.get_world_3d().navigation_map, 0.01)
	target = Node3D.new()
	target.name = "Target"
	world.add_child(target)
	await test_collision()
	await test_navigation()
	world.queue_free()
	finish("physics_tracking_test")

func test_collision() -> void:
	var collision := StrataCollision.new()
	collision.name = "Collision"
	collision.chunk_cells = REGION_CELLS
	collision.max_resident_chunks = 12
	collision.track_radius = 96.0
	collision.data = data
	world.add_child(collision)
	var untracked := collision.get_stats()
	check(untracked.tracked == false and untracked.resident_chunks == 0 and untracked.pending == 0 and untracked.has("evictions") and untracked.has("last_prepare_ms"), "untracked collision stats: %s" % [untracked])
	collision.track_target = collision.get_path_to(target)
	check(collision.get_stats().tracked, "stats report the tracked target")

	# 3 x 3 chunks fit; a 192 m square crossing chunk lines needs up to 16 and is trimmed to 12.
	var position := Vector2(-450.0, -450.0)
	var step := Vector2(21.0, 17.0)
	var worst_ms := 0.0
	var total_ms := 0.0
	var ticks := 0
	var always_resident := true
	var within_budget := true
	var farthest_ok := true
	var last_chunk := Vector2i(-5, -5)
	for frame in range(48):
		place(position)
		var before_builds: int = collision.get_stats().builds
		var t0 := Time.get_ticks_usec()
		collision.tick()
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		if collision.get_stats().builds > before_builds:
			ticks += 1
			total_ms += ms
			worst_ms = maxf(worst_ms, ms)
		var chunk := collision.chunk_at_local(position)
		var replanned := chunk != last_chunk
		last_chunk = chunk
		always_resident = always_resident and collision.get_resident_chunks().has(chunk) and collision.collision_status_at(position) != StrataRuntimeData.Status.NOT_RESIDENT
		within_budget = within_budget and collision.get_resident_chunks().size() <= 12
		# Everything resident is at least as near as the nearest chunk that is not resident but wanted.
		var worst_resident := 0.0
		for key in collision.get_resident_chunks() if replanned else []:
			worst_resident = maxf(worst_resident, collision._chunk_distance(key, chunk, position))
		for key in collision.chunks_in_local_rect(Rect2(position - Vector2.ONE * 96.0, Vector2.ONE * 192.0)) if replanned else []:
			if not collision.get_resident_chunks().has(key) and collision._chunk_distance(key, chunk, position) < worst_resident - 0.001:
				farthest_ok = false
		position += step
	check(always_resident, "the target's chunk is resident after every tick, however fast it moves")
	check(within_budget, "resident chunks never exceed max_resident_chunks")
	check(farthest_ok, "only the farthest wanted chunks are left out when the budget is short")
	var stats := collision.get_stats()
	check(stats.evictions > 0 and not collision.get_resident_chunks().has(Vector2i(0, 0)), "chunks far behind the target were evicted (%d evictions)" % stats.evictions)
	check(stats.resident_chunks == collision.get_resident_chunks().size() and stats.resident == stats.resident_chunks and stats.pending == 0 and stats.last_prepare_ms > 0.0, "collision stats are consistent: %s" % [stats])
	print("physics_tracking: collision %d re-plans, avg %.1f ms, worst %.1f ms (max_resident_chunks 12, radius 96, 64-cell chunks)" % [ticks, total_ms / maxf(ticks, 1), worst_ms])

	# Standing still costs a lookup, not a build.
	var builds_before: int = collision.get_stats().builds
	var t1 := Time.get_ticks_usec()
	for index in range(1000):
		collision.tick()
	print("physics_tracking: collision idle tick %.3f ms" % ((Time.get_ticks_usec() - t1) / 1000.0 / 1000.0))
	check(collision.get_stats().builds == builds_before, "standing still builds nothing")

	# A target off the terrain is tracked at the nearest terrain point; a hole chunk stays concave.
	target.position = Vector3(-900.0, 5.0, 0.0)
	collision.tick()
	check(collision.get_resident_chunks().has(collision.chunk_at_local(Vector2(-512.0, 0.0))), "a target beyond the edge keeps the nearest chunk resident")
	place(Vector2(105.0 + 0.5, 105.0 + 0.5))
	var hole_local := data.lattice_to_local(Vector2(606.0, 603.0))
	place(hole_local)
	collision.tick()
	var info := collision.get_chunk_info(collision.chunk_at_local(hole_local))
	check(not info.is_empty() and info.kind == StrataCollision.ChunkKind.CONCAVE, "the chunk with the hole is a concave shape")

	# Property changes: a new radius re-plans; clearing target stops tracking and keeps public API.
	collision.track_radius = 20.0
	collision.tick()
	check(collision.get_resident_chunks().size() == 1 and collision.get_resident_chunks().has(collision.chunk_at_local(hole_local)), "a smaller radius shrinks the resident set")
	collision.track_target = NodePath()
	var region := collision.prepare_region(Rect2(0, 0, 10, 10))
	check(region.ok and collision.get_resident_chunks().size() == 1 and collision.get_stats().tracked == false, "prepare_region still works with tracking off")
	collision.queue_free()

func wait_navigation_idle(navigation: StrataNavigation) -> int:
	var frames := 0
	while navigation.get_stats().pending_tiles > 0 and frames < 900:
		await process_frame
		frames += 1
	return frames

func tile_delta(key: Vector2i, tile: Vector2i) -> int:
	return maxi(absi(key.x - tile.x), absi(key.y - tile.y))

func resident_keys(navigation: StrataNavigation) -> Array[Vector2i]:
	var keys: Array[Vector2i] = []
	for region in navigation.get_regions():
		var parts := String(region.name).split("_")
		keys.append(Vector2i(int(parts[1]), int(parts[2])))
	return keys

func test_navigation() -> void:
	var navigation := StrataNavigation.new()
	navigation.name = "Navigation"
	navigation.tile_cells = 64
	navigation.max_tiles = 8
	navigation.track_radius = 96.0
	navigation.agent_radius = 0.5
	navigation.data = data
	world.add_child(navigation)
	var idle := navigation.get_stats()
	check(idle.tracked == false and idle.resident_tiles == 0 and idle.pending_tiles == 0 and idle.evictions == 0, "untracked navigation stats: %s" % [idle])
	place(Vector2(-300.0, -300.0))
	navigation.track_target = navigation.get_path_to(target)

	# The node's own physics tick drives tracking.
	await physics_frame
	await physics_frame
	var settle := await wait_navigation_idle(navigation)
	var tile := navigation.tile_at_local(local_of(target.position))
	var stats := navigation.get_stats()
	check(stats.tracked and stats.replans == 1 and stats.resident_tiles > 0 and stats.resident_tiles <= 8, "the physics tick re-planned once and baked tiles: %s" % [stats])
	check(resident_keys(navigation).has(tile), "the tile under the target is resident once its bake arrived (%d frames)" % settle)
	var baked_once: int = stats.tiles_baked
	for index in range(200):
		navigation.tick()
	check(navigation.get_stats().replans == 1 and navigation.get_stats().tiles_baked == baked_once, "standing still re-plans nothing and never rebakes a tile")

	# Walk across the terrain, a tile every few frames, with baking in flight throughout.
	var position := local_of(target.position)
	var step := Vector2(9.0, 7.0)
	var invariant := true
	var target_present := true
	var worst_ms := 0.0
	var total_ms := 0.0
	var replans := 0
	for frame in range(60):
		position += step
		place(position)
		var before: int = navigation.get_stats().replans
		var t0 := Time.get_ticks_usec()
		navigation.tick()
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		if navigation.get_stats().replans > before:
			replans += 1
			total_ms += ms
			worst_ms = maxf(worst_ms, ms)
		var s := navigation.get_stats()
		invariant = invariant and s.resident_tiles + s.pending_tiles <= 8
		var here := navigation.tile_at_local(position)
		for key in resident_keys(navigation):
			invariant = invariant and tile_delta(key, here) <= 2
		await process_frame
	await wait_navigation_idle(navigation)
	tile = navigation.tile_at_local(position)
	stats = navigation.get_stats()
	check(invariant, "resident + pending tiles stay within max_tiles and within the keep range while walking")
	check(resident_keys(navigation).has(tile), "the tile under the walking target is resident after it settles")
	check(stats.evictions > 0, "the budget evicted the tiles farthest from the target: %s" % [stats])
	var near_count := 0
	for key in resident_keys(navigation):
		near_count += 1 if tile_delta(key, tile) <= 1 else 0
	check(near_count >= 4, "nearest tiles are the ones kept (%d within one tile)" % near_count)
	print("physics_tracking: navigation %d re-plans while walking, avg %.1f ms, worst %.1f ms scheduling cost (async, max_tiles 8, radius 96, 64-cell tiles); %d tiles baked, %d results dropped" % [replans, total_ms / maxf(replans, 1), worst_ms, stats.tiles_baked, stats.discarded_results])

	# Teleport away while bakes are in flight: the departed area's results are dropped.
	var dropped_before: int = navigation.get_stats().discarded_results
	place(Vector2(-400.0, 300.0))
	navigation.tick()
	check(navigation.get_stats().pending_tiles > 0, "the teleport queued bakes")
	place(Vector2(400.0, -300.0))
	navigation.tick()
	await wait_navigation_idle(navigation)
	tile = navigation.tile_at_local(Vector2(400.0, -300.0))
	var far_tile := navigation.tile_at_local(Vector2(-400.0, 300.0))
	stats = navigation.get_stats()
	var leaked := false
	for key in resident_keys(navigation):
		leaked = leaked or tile_delta(key, far_tile) < tile_delta(key, tile) and tile_delta(key, tile) > 2
	check(stats.releases > 0, "resident tiles beyond the keep range were released: %s" % [stats])
	check(not leaked and resident_keys(navigation).has(tile), "the target's tile is resident and no departed tile was published")
	check(stats.discarded_results > dropped_before, "results for tiles the target left are dropped (%d dropped)" % (stats.discarded_results - dropped_before))
	check(stats.resident_tiles == navigation.get_regions().size() and stats.resident_tiles <= 8 and stats.pending_tiles == 0, "navigation stats are consistent: %s" % [stats])

	# A setting change rebakes under the new settings and never mixes them.
	navigation.agent_radius = 0.75
	navigation.tick()
	await wait_navigation_idle(navigation)
	check(navigation.is_config_current() and resident_keys(navigation).has(tile), "a settings change rebakes the tracked tiles with the new settings")

	# bake_region and clear keep working with tracking off.
	navigation.track_target = NodePath()
	navigation.clear()
	check(navigation.get_regions().is_empty() and navigation.get_stats().tracked == false, "clear releases every tile")
	var baked := navigation.bake_region(Rect2(0, 0, 64, 64))
	if baked.get("pending", false):
		baked = await navigation.bake_finished
	check(baked.ok and navigation.get_regions().size() >= 1, "bake_region still bakes a selected area: %s" % [baked])
	navigation.queue_free()
