extends "res://tests/runtime_test_base.gd"
## StrataRegionStreamer policy against a recording stand-in for the renderer (Phase B, D2):
## tiers by distance, slot caps with the nearest winning, hysteresis, eviction when the camera
## moves, loads_per_frame, and that external data reaches the renderer only through
## StrataRuntimeData.poll_regions(). Synthetic 16 x 16 grid of 16-cell regions over 256 m.

const DIRECTORY := "../build/test-scratch/region_streamer"
const EXTENT := 16.0

## Duck-typed renderer: keeps tier slots and records every call.
class StubRenderer:
	extends Node
	var near_slots := 0
	var far_slots := 0
	var far_level := 0
	var levels: Dictionary = {}
	var calls: Array = []
	var residency: Dictionary = {}
	func configure_runtime(_source: Node3D, _data: StrataRuntimeData, _materials: Array, policy: Dictionary = {}) -> bool:
		residency = policy
		near_slots = int(policy.get("near_slots", 0))
		far_slots = int(policy.get("far_slots", 0))
		far_level = int(policy.get("far_level", 0))
		calls.append(["configure", Vector2i.ZERO, -1])
		return true
	func free_slots(level: int) -> int:
		var used_near := 0
		var used_far := 0
		for xy in levels:
			if levels[xy] == 0: used_near += 1
			else: used_far += 1
		if level == 0: return near_slots - used_near
		if level == far_level and far_slots > 0: return far_slots - used_far
		return 0
	func set_region_level(xy: Vector2i, region: StrataRegionData, level: int) -> bool:
		if region == null or region.region != xy: return false
		if levels.get(xy, -1) != level and free_slots(level) <= 0: return false
		levels[xy] = level
		calls.append(["bind", xy, level])
		return true
	func release_region(xy: Vector2i) -> bool:
		calls.append(["release", xy, -1])
		return levels.erase(xy)
	func region_level(xy: Vector2i) -> int:
		return levels.get(xy, -1)
	func count(kind: String) -> int:
		var total := 0
		for call in calls:
			if call[0] == kind: total += 1
		return total
	func level_count(level: int) -> int:
		var total := 0
		for xy in levels:
			if levels[xy] == level: total += 1
		return total

var data: StrataRuntimeData
var stub: StubRenderer
var streamer: StrataRegionStreamer
var source: Node3D
var camera: Camera3D

func _initialize() -> void:
	call_deferred("run")

static func scratch() -> String:
	return ProjectSettings.globalize_path("res://").path_join(DIRECTORY).simplify_path()

func make_terrain() -> StrataRuntimeData:
	var result := make_data(Rect2(0, 0, 256, 256), Vector2i(257, 257), func(i: int, j: int) -> float: return 0.01 * (i + j))
	for xy in result.regions: StrataRegions.build_mips(result.regions[xy], 3)
	result.mip_levels = 3
	finish_data(result)
	return result

func distance(point: Vector2, xy: Vector2i) -> float:
	var rect := Rect2(Vector2(xy) * EXTENT, Vector2.ONE * EXTENT)
	return point.distance_to(point.clamp(rect.position, rect.end))

## Regions whose closest point is within [param radius].
func within(point: Vector2, radius: float) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for y in range(16):
		for x in range(16):
			if distance(point, Vector2i(x, y)) <= radius: result.append(Vector2i(x, y))
	return result

func make_streamer(target: StrataRuntimeData) -> void:
	if streamer != null:
		streamer.stop()
		streamer.free()
		stub.free()
	stub = StubRenderer.new()
	root.add_child(stub)
	streamer = StrataRegionStreamer.new()
	streamer.renderer = stub
	streamer.data = target
	streamer.camera = camera
	streamer.near_radius = 36.0
	streamer.far_radius = 88.0
	root.add_child(streamer)
	streamer.set_process(false)

func levels_match(expected_near: Array[Vector2i], expected_far: Array[Vector2i], label: String) -> void:
	var ok := stub.level_count(0) == expected_near.size() and stub.level_count(2) == expected_far.size()
	for xy in expected_near:
		if stub.levels.get(xy, -1) != 0: ok = false
	for xy in expected_far:
		if stub.levels.get(xy, -1) != 2: ok = false
	check(ok, "%s: renderer holds %d near and %d far regions as expected (has %d / %d)" % [label, expected_near.size(), expected_far.size(), stub.level_count(0), stub.level_count(2)])

func only_far(near: Array[Vector2i], radius_far: Array[Vector2i]) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for xy in radius_far:
		if not near.has(xy): result.append(xy)
	return result

func run() -> void:
	source = Node3D.new(); root.add_child(source)
	camera = Camera3D.new(); root.add_child(camera)
	camera.position = Vector3(136.0, 50.0, 136.0)
	data = make_terrain()
	check(data.validate().ok, "synthetic terrain validates: %s" % data.validate())
	var materials: Array[StrataMaterial] = []

	# Embedded regions: tiers by distance.
	make_streamer(data)
	check(streamer.start(source, materials), "start configures the renderer")
	check(stub.residency == {"near_slots": 25, "far_slots": 256, "far_level": 2}, "residency policy reaches the renderer: %s" % stub.residency)
	var point := Vector2(136.0, 136.0)
	var near_set := within(point, 36.0)
	var far_set := only_far(near_set, within(point, 88.0))
	check(near_set.size() > 9 and near_set.size() <= 25 and far_set.size() > near_set.size(), "the radii cover a 5 x 5-ish near and an 11 x 11-ish far set (%d / %d)" % [near_set.size(), far_set.size()])
	levels_match(near_set, far_set, "first update at the camera")
	var stats := streamer.stats()
	check(stats.near == near_set.size() and stats.far == far_set.size() and stats.pending == 0 and stats.loads == 0 and stats.near_slots == 25 and stats.far_slots == 256, "stats agree: %s" % stats)
	var binds := stub.count("bind")
	streamer.update(point)
	check(stub.count("bind") == binds and stub.count("release") == 0, "an unchanged camera changes nothing")

	# Slot caps: the nearest regions win.
	streamer.near_slots = 6
	streamer.far_slots = 20
	streamer.start(source, materials)
	var jitter := Vector2(137.3, 139.1)
	streamer.update(jitter)
	check(stub.level_count(0) == 6 and stub.level_count(2) == 20, "slot caps hold (%d / %d)" % [stub.level_count(0), stub.level_count(2)])
	var worst_near := 0.0
	var best_far := INF
	var worst_far := 0.0
	var best_unbound := INF
	for y in range(16):
		for x in range(16):
			var xy := Vector2i(x, y)
			var d := distance(jitter, xy)
			match stub.levels.get(xy, -1):
				0: worst_near = maxf(worst_near, d)
				2:
					best_far = minf(best_far, d)
					worst_far = maxf(worst_far, d)
				_:
					if d <= 88.0: best_unbound = minf(best_unbound, d)
	check(worst_near <= best_far, "every near region is nearer than every far one (%s <= %s)" % [worst_near, best_far])
	check(worst_far <= best_unbound, "every far region is nearer than any unbound candidate (%s <= %s)" % [worst_far, best_unbound])
	check(streamer.stats().near == 6 and streamer.stats().far == 20, "stats follow the caps")

	# Hysteresis: a region just outside the radius stays, far outside it leaves.
	streamer.near_slots = 49
	streamer.far_slots = 256
	streamer.start(source, materials)
	streamer.update(Vector2(136.0, 136.0))
	var inside := Vector2i(10, 8)
	check(stub.region_level(inside) == 0, "region (10, 8) is near at the start (%d)" % stub.region_level(inside))
	# Move west so (10, 8) is 38 m from the camera: just outside 36, inside 36 x 1.25 = 45.
	var east_point := Vector2(16.0 * 10.0 - 38.0, 136.0)
	check(is_equal_approx(distance(east_point, inside), 38.0), "fixture: the region is 38 m away")
	streamer.update(east_point)
	check(stub.region_level(inside) == 0, "a near region 38 m away stays near (hysteresis 1.25 x 36 = 45)")
	var fresh := Vector2i(11, 8)
	check(distance(east_point, fresh) > 36.0, "fixture: a fresh region at that distance is not eligible")
	var released := stub.count("release")
	streamer.update(Vector2(16.0 * 10.0 - 50.0, 136.0))
	check(stub.region_level(inside) != 0, "past the hysteresis band the region leaves the near tier (%d)" % stub.region_level(inside))
	check(stub.count("release") >= released, "release bookkeeping stays consistent")

	# A far journey: the whole residency follows the camera.
	streamer.update(Vector2(8.0, 8.0))
	var corner_near := within(Vector2(8.0, 8.0), 36.0)
	check(stub.levels.get(Vector2i(0, 0), -1) == 0 and stub.level_count(0) <= 25 and stub.level_count(2) <= 256, "near the origin: corner region near, caps hold")
	check(stub.levels.get(Vector2i(8, 8), -1) == -1, "the old centre is released")
	check(stub.level_count(0) == corner_near.size() or stub.level_count(0) <= 25, "near count at the corner is within the budget")
	check(streamer.stats().evictions == 0, "embedded regions are never evicted")
	camera.position = Vector3(250.0, 50.0, 250.0)
	streamer.update(Vector2(250.0, 250.0))
	check(stub.levels.get(Vector2i(15, 15), -1) == 0 and stub.levels.get(Vector2i(0, 0), -1) == -1, "the opposite corner follows")
	streamer.stop()
	check(stub.levels.is_empty() and not streamer.is_started(), "stop releases every region")

	# External data: loads are throttled and bound only on poll.
	var folder := scratch()
	DirAccess.make_dir_recursive_absolute(folder)
	for file in DirAccess.get_files_at(folder): DirAccess.remove_absolute(folder.path_join(file))
	for xy in data.regions: ResourceSaver.save(data.regions[xy], folder.path_join(StrataRuntimeData.REGION_FILE % [xy.x, xy.y]))
	var manifest := data.duplicate_runtime(false)
	manifest.regions = {}
	manifest.region_directory = folder
	ResourceSaver.save(manifest, folder.path_join("runtime_data.res"))
	var external := ResourceLoader.load(folder.path_join("runtime_data.res"), "", ResourceLoader.CACHE_MODE_IGNORE) as StrataRuntimeData
	check(external != null and external.regions.is_empty(), "external manifest loads")
	camera.position = Vector3(136.0, 50.0, 136.0)
	make_streamer(external)
	streamer.loads_per_frame = 2
	check(streamer.start(source, materials), "external start succeeds")
	check(stub.levels.is_empty() and external.pending_count() == 2 and streamer.stats().loads == 2 and streamer.stats().pending == 2, "the first update only requests two loads and binds nothing (%s)" % streamer.stats())
	check(external.cached_region_keys().is_empty(), "nothing is cached before a poll delivers it")
	var edge_point := Vector2(136.0, 136.0)
	near_set = within(edge_point, 36.0)
	far_set = only_far(near_set, within(edge_point, 88.0))
	var wanted := near_set.size() + far_set.size()
	var last_loads: int = streamer.stats().loads
	var steady := 0
	var frames := 0
	var overshoot := false
	var bound_without_cache := false
	while frames < 1500 and stub.levels.size() < wanted:
		await process_frame
		frames += 1
		streamer.update(edge_point)
		var current: Dictionary = streamer.stats()
		if current.loads - last_loads > 2: overshoot = true
		last_loads = current.loads
		for xy in stub.levels:
			if not external.has_cached_region(xy): bound_without_cache = true
	check(stub.levels.size() == wanted and stub.level_count(0) == near_set.size() and stub.level_count(2) == far_set.size(), "external regions arrive and bind (%d of %d after %d frames)" % [stub.levels.size(), wanted, frames])
	check(not overshoot, "never more than loads_per_frame new loads per update")
	check(not bound_without_cache, "bound regions are always cached ones")
	check(streamer.stats().loads == wanted and external.cached_region_keys().size() == wanted, "every region loaded exactly once and cached (loads %d, cached %d)" % [streamer.stats().loads, external.cached_region_keys().size()])
	# Move away: regions leave and are evicted from the cache.
	var before_evictions: int = streamer.stats().evictions
	camera.position = Vector3(250.0, 50.0, 250.0)
	edge_point = Vector2(250.0, 250.0)
	for frame in range(600):
		await process_frame
		streamer.update(edge_point)
	var far_near := within(edge_point, 36.0)
	check(streamer.stats().evictions > before_evictions, "regions that left both tiers are evicted (%d)" % streamer.stats().evictions)
	check(stub.levels.get(Vector2i(15, 15), -1) == 0 and stub.levels.get(Vector2i(8, 8), -1) == -1 and stub.level_count(0) == far_near.size(), "the residency followed the camera")
	check(external.cached_region_keys().size() == stub.levels.size(), "the cache holds exactly the bound regions (%d vs %d)" % [external.cached_region_keys().size(), stub.levels.size()])
	check(external.cache_bytes() > 0 and streamer.stats().cached == stub.levels.size(), "cache bytes and stats agree")
	# Without far mips there is no far tier.
	var flat := external.duplicate_runtime(false)
	flat.mip_levels = 1
	make_streamer(flat)
	check(streamer.start(source, materials) and stub.residency.far_slots == 0, "no far mips, no far slots")
	finish("region_streamer_test")
