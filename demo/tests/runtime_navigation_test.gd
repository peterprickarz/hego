extends "res://tests/runtime_test_base.gd"
## StrataNavigation: real NavigationServer3D bakes and path queries.

const AGENT_RADIUS := 0.5

var terrain_root: Node3D
var navigation: StrataNavigation
var data: StrataRuntimeData
var map: RID

func _initialize() -> void:
	call_deferred("run")

func gentle(i: int, j: int) -> float:
	var height := 0.03 * i - 0.02 * j - 1.0 + 0.3 * sin(i * 0.2)
	# Steep cone (about 61 degrees) centred on lattice (85, 12).
	var distance := Vector2(i - 85, j - 12).length()
	return height + maxf(0.0, 5.0 - 1.8 * distance)

func sync_map() -> void:
	for frame in range(4):
		await physics_frame
		await process_frame

func world_at(lattice: Vector2) -> Vector3:
	var local := data.lattice_to_local(lattice)
	return terrain_root.global_transform * Vector3(local.x, data.sample_height(local, 0, true).value, local.y)

func path_length(path: PackedVector3Array) -> float:
	var total := 0.0
	for index in range(1, path.size()):
		total += path[index - 1].distance_to(path[index])
	return total

## Minimum horizontal distance from a terrain-local point to any blocked cell.
func blocked_clearance(local: Vector2) -> float:
	var lattice := data.local_to_lattice(local)
	var nearest := INF
	var base := Vector2i(floori(lattice.x), floori(lattice.y))
	for z in range(base.y - 3, base.y + 4):
		for x in range(base.x - 3, base.x + 4):
			var cell := Vector2i(x, z)
			if not data.is_nav_blocked_cell(cell):
				continue
			var closest := lattice.clamp(Vector2(cell), Vector2(cell) + Vector2.ONE)
			nearest = minf(nearest, (closest - lattice).length() * data.get_spacing())
	return nearest

## Mirrors Godot 4.4's map merge: world vertices floor-quantized to the map
## cell size/height; an edge key used by more than two polygons fails to merge.
func merge_conflicts() -> Dictionary:
	var size := NavigationServer3D.map_get_cell_size(map) * NavigationServer3D.map_get_merge_rasterizer_cell_scale(map)
	var height := NavigationServer3D.map_get_cell_height(map) * NavigationServer3D.map_get_merge_rasterizer_cell_scale(map)
	var edges := {}
	for region in navigation.get_regions():
		var mesh := region.navigation_mesh
		var vertices := mesh.get_vertices()
		for polygon_index in range(mesh.get_polygon_count()):
			var polygon := mesh.get_polygon(polygon_index)
			for edge in range(polygon.size()):
				var keys := []
				for vertex_index in [polygon[edge], polygon[(edge + 1) % polygon.size()]]:
					var world := region.global_transform * vertices[vertex_index]
					keys.append(Vector3i(floori(world.x / size), floori(world.y / height), floori(world.z / size)))
				keys.sort()
				var key := str(keys)
				if not edges.has(key): edges[key] = []
				edges[key].append(region.name)
	var result := {"intra_tile": 0, "cross_tile": 0}
	for key in edges:
		if edges[key].size() > 2:
			var names := {}
			for name in edges[key]: names[name] = true
			result["cross_tile" if names.size() > 1 else "intra_tile"] += 1
	return result

## Samples every path segment at 5 cm in terrain-local space.
func check_path(path: PackedVector3Array, from: Vector3, to: Vector3, label: String) -> Dictionary:
	check(path.size() >= 2, "%s: path exists (%d points)" % [label, path.size()])
	if path.size() < 2:
		return {"length": 0.0, "clearance": 0.0}
	check(path[0].distance_to(from) < 0.75 and path[-1].distance_to(to) < 0.75, "%s: endpoints reach the requested points (%s, %s)" % [label, path[0].distance_to(from), path[-1].distance_to(to)])
	var inverse := terrain_root.global_transform.affine_inverse()
	var clearance := INF
	var max_height_error := 0.0
	for index in range(1, path.size()):
		var steps := maxi(1, ceili(path[index - 1].distance_to(path[index]) / 0.05))
		for step in range(steps + 1):
			var point := inverse * path[index - 1].lerp(path[index], float(step) / steps)
			var local := Vector2(point.x, point.z)
			clearance = minf(clearance, blocked_clearance(local))
			var surface: Dictionary = data.sample_height(local)
			if surface.status == StrataRuntimeData.Status.OK:
				max_height_error = maxf(max_height_error, absf(point.y - surface.value))
	# Recast erodes by radius in 0.25 m voxels and simplifies contours, so the
	# clearance can sit up to about one voxel inside the radius; never inside a cell.
	check(clearance > 0.0, "%s: path never enters a hole or exclusion cell (clearance %s)" % [label, clearance])
	check(clearance >= AGENT_RADIUS - 0.3, "%s: path keeps agent clearance from masked cells (clearance %s)" % [label, clearance])
	check(max_height_error < 0.6, "%s: path follows the terrain surface (max error %s)" % [label, max_height_error])
	return {"length": path_length(path), "clearance": clearance}

func run() -> void:
	data = make_data(Rect2(-48.0, -24.0, 96.0, 48.0), Vector2i(97, 49), gentle)
	var cells := data.get_cell_resolution()
	# Hole wall leaving a gap at the top; exclusion pad reaching the far edge.
	data.holes = cell_mask(cells, [Rect2i(44, 0, 4, 34)])
	data.nav_exclusions = cell_mask(cells, [Rect2i(60, 36, 6, 12)])
	check(data.validate().ok and data.height_min < 0.0 and data.height_max > 0.0, "signed navigation fixture valid")

	terrain_root = Node3D.new()
	terrain_root.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(23.0)), Vector3(40.0, 5.0, -30.0))
	get_root().add_child(terrain_root)
	map = terrain_root.get_world_3d().navigation_map
	# The test owns this isolated map; the addon never changes consumer maps.
	NavigationServer3D.map_set_merge_rasterizer_cell_scale(map, 0.01)
	await sync_map()
	var baseline_regions := NavigationServer3D.map_get_regions(map).size()

	navigation = StrataNavigation.new()
	navigation.tile_cells = 32
	navigation.agent_radius = AGENT_RADIUS
	navigation.agent_max_slope = 45.0
	navigation.use_async = false
	navigation.data = data
	terrain_root.add_child(navigation)
	check(navigation.get_tile_grid() == Vector2i(3, 2), "3 x 2 navigation tiles")

	navigation.max_tiles = 2
	check(not navigation.bake_region(data.bounds).ok and navigation.get_regions().is_empty(), "oversized navigation area rejected before baking")
	navigation.max_tiles = 64
	var bad_cells := StrataNavigation.new()
	bad_cells.cell_size = 0.7
	bad_cells.data = data
	terrain_root.add_child(bad_cells)
	check(not bad_cells.bake_region(data.bounds).ok, "navigation cells coarser than half the terrain spacing are rejected")
	bad_cells.free()

	var baked := navigation.bake_region(data.bounds)
	check(baked.ok and baked.regions == 6 and baked.polygons > 0, "synchronous bake of all tiles: %s" % baked)
	check(baked.agent.radius == 0.5 and baked.agent.height == 2.0 and baked.agent.max_climb == 0.25, "agent sizes are explicit whole voxels: %s" % baked.agent)
	await sync_map()
	check(NavigationServer3D.map_get_regions(map).size() == baseline_regions + 6, "six regions on the world map")
	var old_regions := navigation.get_regions()
	navigation.tile_cells = 0; navigation.max_tiles = 0; navigation.agent_radius = NAN; navigation.edge_max_error = 1.3
	check(navigation.tile_cells == 32 and navigation.max_tiles == 64 and navigation.agent_radius == AGENT_RADIUS and navigation.edge_max_error == 1.0 and navigation.get_regions() == old_regions, "invalid navigation settings retain the valid configuration and published regions")
	navigation.agent_height = 2.2
	check(not navigation.is_config_current(), "baked regions report changed geometry settings")
	var reconfigured := navigation.bake_region(Rect2(data.bounds.position, Vector2(1, 1)), true)
	check(reconfigured.ok and reconfigured.tiles == 6 and navigation.is_config_current(), "keep-existing request rebakes all retained tiles when settings change")
	navigation.agent_height = 1.8
	check(navigation.bake_region(data.bounds).ok, "original agent settings restored coherently")
	await sync_map()

	# Tile meshes are clipped to their own rectangles (border_size + filter AABB).
	var clipped := true
	for region in navigation.get_regions():
		var key := Vector2i(int(region.name.split("_")[1]), int(region.name.split("_")[2]))
		var rect := Rect2(data.lattice_to_local(Vector2(key * 32)), Vector2(navigation.get_tile_cells(key).size))
		for vertex in region.navigation_mesh.get_vertices():
			clipped = clipped and rect.grow(0.01).has_point(Vector2(vertex.x, vertex.z))
	check(clipped, "every tile mesh stays inside its tile rectangle")
	var conflicts := merge_conflicts()
	check(conflicts.cross_tile == 0 and conflicts.intra_tile == 0, "no intra/cross-tile merged-edge conflicts after synchronization: %s" % conflicts)
	print("navigation edge-key conflicts (Godot map quantization): %s" % conflicts)

	# Around the hole wall: must detour through the gap above z = 34.
	var from := world_at(Vector2(20, 10))
	var to := world_at(Vector2(70, 10))
	var around := NavigationServer3D.map_get_path(map, from, to, true)
	var around_result := check_path(around, from, to, "around hole")
	check(around_result.length > from.distance_to(to) * 1.5, "hole forces a detour (%s vs straight %s)" % [around_result.length, from.distance_to(to)])
	var inverse := terrain_root.global_transform.affine_inverse()
	var max_z := -INF
	for point in around:
		max_z = maxf(max_z, data.local_to_lattice(Vector2((inverse * point).x, (inverse * point).z)).y)
	check(max_z >= 34.0, "detour passes through the gap beyond the wall (max lattice z %s)" % max_z)

	# Around the navigation exclusion (solid for collision, blocked for agents).
	from = world_at(Vector2(55, 42))
	to = world_at(Vector2(75, 42))
	var excluded := NavigationServer3D.map_get_path(map, from, to, true)
	var excluded_result := check_path(excluded, from, to, "around exclusion")
	check(excluded_result.length > from.distance_to(to) * 1.2, "exclusion forces a detour (%s vs %s)" % [excluded_result.length, from.distance_to(to)])
	check(data.sample_height(data.lattice_to_local(Vector2(62.5, 40.5))).status == StrataRuntimeData.Status.OK, "exclusion cells keep their terrain surface")

	# Straight paths across adjacent tile regions connect without detour.
	for pair in [[Vector2(10, 20), Vector2(40, 20)], [Vector2(10, 25), Vector2(10, 40)], [Vector2(28, 28), Vector2(36, 36)], [Vector2(60, 10), Vector2(80, 24)]]:
		from = world_at(pair[0])
		to = world_at(pair[1])
		var direct := NavigationServer3D.map_get_path(map, from, to, true)
		var direct_result := check_path(direct, from, to, "across tiles %s" % [pair])
		check(direct_result.length < from.distance_to(to) * 1.05 + 0.2, "adjacent tile regions are connected (%s vs %s)" % [direct_result.length, from.distance_to(to)])

	# Maximum slope: the ~61 degree cone is unwalkable at 45, walkable at 70.
	var apex := world_at(Vector2(85, 12))
	var closest := NavigationServer3D.map_get_closest_point(map, apex)
	var apex_offset := Vector2(closest.x - apex.x, closest.z - apex.z).length()
	check(apex_offset > 1.5, "steep cone excluded by agent_max_slope 45 (closest navmesh %s m away)" % apex_offset)
	# The cone rises ~0.45 m per 0.25 m voxel, so the climb limit must allow it too.
	navigation.agent_max_slope = 70.0
	navigation.agent_max_climb = 0.75
	check(navigation.bake_region(data.bounds).ok, "rebake with a steeper slope limit")
	await sync_map()
	closest = NavigationServer3D.map_get_closest_point(map, apex)
	check(Vector2(closest.x - apex.x, closest.z - apex.z).length() < 1.0, "agent_max_slope 70 makes the cone walkable")
	check(NavigationServer3D.map_get_regions(map).size() == baseline_regions + 6, "rebake replaces regions instead of adding duplicates")
	navigation.agent_max_slope = 45.0
	navigation.agent_max_climb = 0.25

	# Bounded selected area, asynchronous, published only after every tile.
	navigation.clear()
	await sync_map()
	check(NavigationServer3D.map_get_regions(map).size() == baseline_regions, "clear removes all regions")
	navigation.use_async = true
	var selected := Rect2(data.lattice_to_local(Vector2(4, 4)), Vector2(40, 20))
	var started := navigation.bake_region(selected)
	check(started.ok and started.pending and started.tiles == 2, "async bake of a selected two-tile area: %s" % started)
	check(navigation.get_regions().is_empty() and navigation.is_baking(), "nothing is published while tiles are baking")
	var finished: Dictionary = await navigation.bake_finished
	check(finished.ok and finished.regions == 2, "async bake publishes both tiles together: %s" % finished)
	await sync_map()
	from = world_at(Vector2(6, 6))
	to = world_at(Vector2(40, 20))
	check_path(NavigationServer3D.map_get_path(map, from, to, true), from, to, "async selected area")
	var outside := NavigationServer3D.map_get_closest_point(map, world_at(Vector2(90, 40)))
	check(outside.distance_to(world_at(Vector2(90, 40))) > 20.0, "tiles outside the selected area are not baked")

	# A newer request supersedes an in-flight one.
	navigation.bake_region(data.bounds)
	var latest := navigation.bake_region(selected)
	var superseded: Dictionary = await navigation.bake_finished
	check(superseded.generation == latest.generation and superseded.regions == 2, "only the latest async request publishes: %s" % superseded)
	for frame in range(30):
		await process_frame
	check(navigation.get_regions().size() == 2 and navigation.get_stats().discarded_results >= 1, "stale async results are discarded: %s" % navigation.get_stats())

	var cancellations: Array = []
	navigation.bake_finished.connect(func(result: Dictionary) -> void:
		if not result.ok: cancellations.append(result))
	var retained := navigation.get_regions()
	navigation.bake_region(selected)
	navigation.agent_radius = 0.75
	check(not navigation.is_baking() and cancellations.size() == 1 and navigation.get_regions() == retained, "changing async geometry settings signals cancellation and retains old regions")
	for frame in range(20): await process_frame
	check(navigation.get_regions() == retained, "cancelled stale geometry never publishes later")
	navigation.agent_radius = AGENT_RADIUS
	for clear_kind in ["clear", "data", "tile"]:
		navigation.bake_region(selected)
		var previous_cancellations := cancellations.size()
		match clear_kind:
			"clear": navigation.clear()
			"data": navigation.data = data
			"tile": navigation.tile_cells = 16
		check(not navigation.is_baking() and cancellations.size() == previous_cancellations + 1, "%s cancellation notifies a live bake waiter" % clear_kind)
	navigation.tile_cells = 32

	# Teardown, including an async bake still in flight.
	navigation.bake_region(data.bounds)
	terrain_root.queue_free()
	for frame in range(60):
		await process_frame
	await sync_map()
	check(NavigationServer3D.map_get_regions(map).size() == baseline_regions, "teardown leaves no regions on the map")
	finish("RUNTIME_NAVIGATION_TEST")
