extends "res://tests/runtime_test_base.gd"
## Suite test on ARTIFICIAL data: a 2 km x 2 km fixture terrain (LargeWorldFixture, noise, not island
## content) at 1 m, 8 x 8 regions of 256 cells, baked, saved to a directory, reloaded fresh and
## streamed by the real StrataRegionStreamer against a recording stand-in for the renderer along a
## scripted camera path. Checks the slot caps, bounded pending loads, tiers following the camera,
## the resident GPU bytes the renderer's tier layout implies against the Phase C budget, the CPU
## cache bound, and physics (collision chunks and a navigation bake) around a point, with the
## player-style CPU height probe agreeing with the collision shapes.
## Needs no GPU. docs/development/testing.md, "Large-world fixture".

const SIZE := 2048.0
const SPACING := 1.0
const DIRECTORY := "../build/test-scratch/large_world"
const NEAR_RADIUS := 300.0
const FAR_RADIUS := 1000.0
const NEAR_SLOTS := 16
const FAR_SLOTS := 24
const GPU_BUDGET := 64 * 1024 * 1024
const CACHE_BUDGET := 300

## Duck-typed renderer: keeps tier slots, as StrataRenderer does.
class StubRenderer:
	extends Node
	var near_slots := 0
	var far_slots := 0
	var far_level := 0
	var levels: Dictionary = {}
	func configure_runtime(_source: Node3D, _data: StrataRuntimeData, _materials: Array, policy: Dictionary = {}) -> bool:
		near_slots = int(policy.get("near_slots", 0))
		far_slots = int(policy.get("far_slots", 0))
		far_level = int(policy.get("far_level", 0))
		return true
	func level_count(level: int) -> int:
		var total := 0
		for xy in levels:
			if (levels[xy] == 0) == (level == 0): total += 1
		return total
	func free_slots(level: int) -> int:
		if level == 0: return near_slots - level_count(0)
		if level == far_level and far_slots > 0: return far_slots - level_count(far_level)
		return 0
	func set_region_level(xy: Vector2i, region: StrataRegionData, level: int) -> bool:
		if region == null or region.region != xy: return false
		if levels.get(xy, -1) != level and free_slots(level) <= 0: return false
		levels[xy] = level
		return true
	func release_region(xy: Vector2i) -> bool:
		return levels.erase(xy)
	func region_level(xy: Vector2i) -> int:
		return levels.get(xy, -1)

var data: StrataRuntimeData
var stub: StubRenderer
var streamer: StrataRegionStreamer
var max_pending := 0
var max_cached := 0

func _initialize() -> void:
	call_deferred("run")

static func scratch() -> String:
	return ProjectSettings.globalize_path("res://").path_join(DIRECTORY).simplify_path()

static func ms(started: int) -> float:
	return (Time.get_ticks_usec() - started) / 1000.0

static func remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path): return
	for file in DirAccess.get_files_at(path): DirAccess.remove_absolute(path.path_join(file))
	for folder in DirAccess.get_directories_at(path):
		remove_tree(path.path_join(folder))
		DirAccess.remove_absolute(path.path_join(folder))

func distance(point: Vector2, xy: Vector2i) -> float:
	var rect := StrataRegions.region_bounds(data.get_spec(), xy)
	return point.distance_to(point.clamp(rect.position, rect.end))

## Bytes the renderer's tiers hold for this spec (its _tier_bytes over the shader maps) plus the coarse maps.
func resident_bytes() -> int:
	var spec := data.get_spec()
	var shader_maps := [StrataRegions.MAP_HEIGHT, StrataRegions.MAP_MATERIAL_IDS, StrataRegions.MAP_MATERIAL_WEIGHTS, StrataRegions.MAP_HOLES, StrataRegions.MAP_MACRO]
	var near := 0
	var far := 0
	for name in spec.maps:
		if not shader_maps.has(name): continue
		near += StrataRegions.map_bytes(spec.cells, spec.maps[name], 0)
		far += StrataRegions.map_bytes(spec.cells, spec.maps[name], streamer.far_level)
	return NEAR_SLOTS * near + FAR_SLOTS * far + data.coarse_bytes()

## Updates until the streamer has nothing in flight and stops changing; false if it never settles.
func settle(point: Vector2) -> bool:
	var previous := ""
	var stable := 0
	for iteration in range(600):
		streamer.update(point)
		var stats := streamer.stats()
		max_pending = maxi(max_pending, stats.pending)
		max_cached = maxi(max_cached, stats.cached)
		var signature := "%d %d %d" % [stats.near, stats.far, stats.loads]
		stable = stable + 1 if (signature == previous and stats.pending == 0) else 0
		previous = signature
		if stable >= 2: return true
		OS.delay_msec(2)
	return false

func run() -> void:
	var directory := scratch()
	remove_tree(directory)
	DirAccess.make_dir_recursive_absolute(directory)
	print("LARGE_WORLD_TEST ", LargeWorldFixture.describe())

	var started := Time.get_ticks_usec()
	var terrain := LargeWorldFixture.build(SIZE, SPACING)
	var build_ms := ms(started)
	root.add_child(terrain)
	check(terrain.effective_region_cells() == 256 and terrain.get_layers().size() == 4, "the fixture uses 256-cell regions and four layers")
	terrain.storage_directory = "res://" + DIRECTORY # res:// beside the project (storage refuses absolute paths); the same folder as scratch()
	started = Time.get_ticks_usec()
	var options := {"cell_masks": true}
	# Incremental directory bake when the bake supports it, embedded bake saved afterwards otherwise.
	var directory_bake := (load("res://addons/strata/strata_bake.gd") as GDScript).source_code.contains("region_directory")
	if directory_bake: options.region_directory = directory.path_join(StrataStorage.REGION_DIRECTORY)
	var baked := StrataBake.bake(terrain, options)
	var bake_ms := ms(started)
	check(baked.ok, "bake: %s" % baked.get("message", ""))
	if not baked.ok:
		finish("LARGE_WORLD_TEST")
		return
	started = Time.get_ticks_usec()
	var saved := StrataStorage.save_runtime_data(terrain)
	var save_ms := ms(started)
	check(saved.ok, "save_runtime_data: %s" % saved.get("message", ""))
	var files := DirAccess.get_files_at(directory.path_join(StrataStorage.REGION_DIRECTORY))
	var region_files := files.size()
	check(files.has("region_0_0.res") and files.has("region_7_7.res") and FileAccess.file_exists(StrataStorage.runtime_data_path(terrain)), "the region files and the manifest are on disk (%d region files)" % region_files)
	if directory_bake: check(files.has("region_0_0.lod.res") and files.has("region_7_7.lod.res") and region_files == 128 and baked.report.get("disk_bytes", 0) > 0, "a directory bake wrote 64 full and 64 lod files (%d files, %s bytes)" % [region_files, baked.report.get("disk_bytes")])

	# Fresh manifest: regions load from files only.
	terrain.runtime_data = null
	data = StrataStorage.load_runtime_data(terrain)
	check(data != null and data.validate().get("ok", false), "the manifest reloads and validates")
	if data == null:
		finish("LARGE_WORLD_TEST")
		return
	check(data.grid == Vector2i(8, 8) and data.cells == 256 and data.is_resident() and data.regions.is_empty() and not data.region_directory.is_empty() and data.cached_region_keys().is_empty(), "8 x 8 regions of 256 cells read from a directory, nothing embedded or cached")
	check(data.mip_levels > 2 and data.has_coarse_maps() and data.has_macro(), "far level and coarse maps exist, macro present")

	var source := Node3D.new()
	root.add_child(source)
	var camera := Camera3D.new()
	root.add_child(camera)
	stub = StubRenderer.new()
	root.add_child(stub)
	streamer = StrataRegionStreamer.new()
	streamer.renderer = stub
	streamer.data = data
	streamer.camera = camera
	streamer.near_radius = NEAR_RADIUS
	streamer.far_radius = FAR_RADIUS
	streamer.near_slots = NEAR_SLOTS
	streamer.far_slots = FAR_SLOTS
	root.add_child(streamer)
	streamer.set_process(false)
	check(streamer.start(source, [] as Array[StrataMaterial]), "the streamer starts")
	check(stub.level_count(0) == 0 and data.cached_region_keys().is_empty(), "nothing is bound or cached before the camera is placed")

	# Scripted flight: corner, centre, opposite corner, back along the diagonal.
	var half := SIZE * 0.5
	var waypoints: Array[Vector2] = [Vector2(-half + 40, -half + 40), Vector2(0, 0), Vector2(half - 40, half - 40), Vector2(half - 40, -half + 40), Vector2(-half + 40, half - 40)]
	var current := waypoints[0]
	var total_steps := 0
	var all_settled := true
	var tiers_ok := true
	var standing_ok := true
	var caps_ok := true
	var far_ok := true
	var peak_bytes := 0
	var flight_started := Time.get_ticks_usec()
	var tier_message := ""
	for leg in range(waypoints.size()):
		var target := waypoints[leg]
		var span := current.distance_to(target)
		var steps := maxi(1, int(span / 24.0))
		for step in range(1, steps + 1):
			var point := current.lerp(target, float(step) / steps)
			streamer.update(point)
			total_steps += 1
			var stats := streamer.stats()
			max_pending = maxi(max_pending, stats.pending)
			max_cached = maxi(max_cached, stats.cached)
			if stats.near > NEAR_SLOTS or stats.far > FAR_SLOTS or stub.level_count(0) != stats.near: caps_ok = false
			if step % 8 == 0: OS.delay_msec(3)
		current = target
		if not settle(current): all_settled = false
		var stats := streamer.stats()
		var standing := Vector2i(floori((current.x + half) / 256.0), floori((current.y + half) / 256.0)).clamp(Vector2i.ZERO, Vector2i(7, 7))
		if stub.region_level(standing) != 0: standing_ok = false; tier_message = "standing region %s at leg %d has level %d" % [standing, leg, stub.region_level(standing)]
		var strict_far := 0
		for y in range(8):
			for x in range(8):
				var xy := Vector2i(x, y)
				var level := stub.region_level(xy)
				var d := distance(current, xy)
				if d <= NEAR_RADIUS and level != 0: tiers_ok = false; tier_message = "region %s at %.0f m is not near at leg %d" % [xy, d, leg]
				if level > 0 and level != streamer.far_level: tiers_ok = false; tier_message = "region %s bound at level %d" % [xy, level]
				if level == 0 and d > NEAR_RADIUS * streamer.hysteresis: tiers_ok = false; tier_message = "region %s at %.0f m is still near at leg %d" % [xy, d, leg]
				if level != 0 and d <= FAR_RADIUS: strict_far += 1
		if stats.far < mini(FAR_SLOTS, strict_far): far_ok = false; tier_message = "only %d far regions at leg %d, wanted %d" % [stats.far, leg, mini(FAR_SLOTS, strict_far)]
		if stats.near > NEAR_SLOTS or stats.far > FAR_SLOTS: caps_ok = false
		# Only streamed regions are in the CPU cache: every bound region and nothing else.
		if stats.cached != stats.near + stats.far: caps_ok = false; tier_message = "cache %d vs bound %d at leg %d" % [stats.cached, stats.near + stats.far, leg]
		peak_bytes = maxi(peak_bytes, data.cache_bytes() if data.has_method("cache_bytes") else 0)
	var flight_ms := ms(flight_started)
	check(all_settled, "the streamer settles at every waypoint")
	check(caps_ok, "near and far counts stay within their slots and the cache holds exactly the bound regions: %s" % tier_message)
	check(standing_ok, "the region under the camera is always near: %s" % tier_message)
	check(tiers_ok, "every region within the near radius is near, far regions hold the far level, nothing lingers past hysteresis: %s" % tier_message)
	check(far_ok, "the far tier is filled up to its slots from the regions within the far radius: %s" % tier_message)
	check(max_pending <= streamer.loads_per_frame * StrataRegionStreamer.IN_FLIGHT_FACTOR, "pending loads stay bounded (peak %d)" % max_pending)
	check(max_cached <= NEAR_SLOTS + FAR_SLOTS and max_cached < CACHE_BUDGET, "the CPU region cache stays small (peak %d regions, %.1f MiB)" % [max_cached, peak_bytes / 1048576.0])
	var resident := resident_bytes()
	check(resident < GPU_BUDGET, "resident GPU bytes for these slots (%.1f MiB) under 64 MiB" % (resident / 1048576.0))
	check(streamer.stats().loads > 20 and streamer.stats().evictions > 10, "the flight loaded and evicted regions (%s)" % streamer.stats())

	# Physics around the last waypoint (a region interior near a corner of the terrain).
	var probe_centre := Vector2(300.0, 200.0)
	var holes_ok := true
	for index in range(6):
		var hole := LargeWorldFixture.hole_point(terrain, index)
		if not data.is_hole_at(hole): holes_ok = false
	check(holes_ok, "the fixture's hole cells are holes in the bake")
	var physics_root := Node3D.new()
	root.add_child(physics_root)
	var collision := StrataCollision.new()
	collision.data = data
	physics_root.add_child(collision)
	started = Time.get_ticks_usec()
	var around := collision.prepare_around(Vector3(probe_centre.x, 0, probe_centre.y), 96.0)
	var collision_ms := ms(started)
	check(around.get("ok", false) and around.resident <= 9, "collision prepares a bounded area around a point: %s" % around)
	var navigation := StrataNavigation.new()
	navigation.data = data
	navigation.use_async = false
	physics_root.add_child(navigation)
	started = Time.get_ticks_usec()
	var nav := navigation.bake_region(Rect2(probe_centre - Vector2(64, 64), Vector2(128, 128)))
	var nav_ms := ms(started)
	check(nav.get("ok", false), "navigation bakes a 128 m area around the point: %s" % nav)
	await physics_frame
	await physics_frame
	var matched := 0
	var probes := [Vector2(0, 0), Vector2(31.3, -17.7), Vector2(-48.2, 40.9), Vector2(70.5, 66.1)]
	for offset: Vector2 in probes:
		var p := probe_centre + offset
		if data.is_hole_at(p): continue
		var surface := data.sample_height(p)
		var hit := physics_root.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(p.x, 1000, p.y), Vector3(p.x, -1000, p.y)))
		check(not hit.is_empty() and absf(hit.position.y - float(surface.value)) < 0.002, "collision shape height matches the CPU probe at %s (%s vs %s)" % [p, hit.get("position", Vector3.ZERO).y, surface.value])
		check(absf(float(surface.value) - terrain.sample_height(p)) < 0.002, "baked height matches the layer stack at %s" % p)
		matched += 1
	check(matched >= 3, "at least three probes were compared")
	print("LARGE_WORLD_TEST fixture %.0f ms, bake %.0f ms (%s), save %.0f ms, %d region files; flight %d updates %.0f ms, loads %d evictions %d, peak pending %d cached %d; resident GPU %.1f MiB; collision %.0f ms, navigation %.0f ms" % [build_ms, bake_ms, "directory" if directory_bake else "embedded", save_ms, region_files, total_steps, flight_ms, streamer.stats().loads, streamer.stats().evictions, max_pending, max_cached, resident / 1048576.0, collision_ms, nav_ms])
	streamer.stop()
	finish("LARGE_WORLD_TEST")
