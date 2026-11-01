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

## Waits until the navigation map has absorbed the latest bake. Regions and the map update on
## their own iterations (asynchronously since Godot 4.7), so wait for the iteration id to
## settle rather than a fixed frame count.
func sync_map() -> void:
	var last := NavigationServer3D.map_get_iteration_id(map)
	var stable := 0
	for frame in range(120):
		await physics_frame
		await process_frame
		var now := NavigationServer3D.map_get_iteration_id(map)
		stable = stable + 1 if now == last else 0
		last = now
		if frame >= 3 and stable >= 3:
			return

func world_at(lattice: Vector2) -> Vector3:
	var local := data.lattice_to_local(lattice)
	return terrain_root.global_transform * Vector3(local.x, data.sample_height(local, 0, true).value, local.y)

func path_length(path: PackedVector3Array) -> float:
	var total := 0.0
	for index in range(1, path.size()):
		total += path[index - 1].distance_to(path[index])
	return total

## Minimum horizontal distance from a terrain-local point to any blocked cell.
func blocked_clearance(local: Vector2, profile: StringName = StrataRuntimeData.DEFAULT_NAV_PROFILE) -> float:
	var lattice := data.local_to_lattice(local)
	var nearest := INF
	var base := Vector2i(floori(lattice.x), floori(lattice.y))
	for z in range(base.y - 3, base.y + 4):
		for x in range(base.x - 3, base.x + 4):
			var cell := Vector2i(x, z)
			if not data.is_nav_blocked_cell(cell, profile):
				continue
			var closest := lattice.clamp(Vector2(cell), Vector2(cell) + Vector2.ONE)
			nearest = minf(nearest, (closest - lattice).length() * data.get_spacing())
	return nearest

## Mirrors Godot's map merge (4.4 through 4.7): world vertices floor-quantized to the map
## cell size/height; an edge key used by more than two polygons fails to merge.
func merge_conflicts(regions: Array[NavigationRegion3D] = []) -> Dictionary:
	var size := NavigationServer3D.map_get_cell_size(map) * NavigationServer3D.map_get_merge_rasterizer_cell_scale(map)
	var height := NavigationServer3D.map_get_cell_height(map) * NavigationServer3D.map_get_merge_rasterizer_cell_scale(map)
	var edges := {}
	for region in regions if not regions.is_empty() else navigation.get_regions():
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
func check_path(path: PackedVector3Array, from: Vector3, to: Vector3, label: String, profile: StringName = StrataRuntimeData.DEFAULT_NAV_PROFILE) -> Dictionary:
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
			clearance = minf(clearance, blocked_clearance(local, profile))
			var surface: Dictionary = data.sample_height(local)
			if surface.status == StrataRuntimeData.Status.OK:
				max_height_error = maxf(max_height_error, absf(point.y - surface.value))
	# Recast erodes by radius in 0.25 m voxels and simplifies contours, so the
	# clearance can sit up to about one voxel inside the radius; never inside a cell.
	check(clearance > 0.0, "%s: path never enters a hole or exclusion cell (clearance %s)" % [label, clearance])
	check(clearance >= AGENT_RADIUS - 0.3, "%s: path keeps agent clearance from masked cells (clearance %s)" % [label, clearance])
	check(max_height_error < 0.6, "%s: path follows the terrain surface (max error %s)" % [label, max_height_error])
	return {"length": path_length(path), "clearance": clearance}

## Ramp: flat to x = 3, 45 degrees to x = 6, then 2 m per metre (63.4 degrees).
static func ramp(i: int, _j: int) -> float:
	if i <= 3: return 0.0
	if i <= 6: return float(i - 3)
	return 3.0 + 2.0 * (i - 6)

## Columns x whose cells are walkable (0) in every row; checks rows agree.
func walkable_columns(mask: PackedByteArray, cells: Vector2i) -> Array:
	var columns := []
	for x in range(cells.x):
		var walkable := mask.is_empty() or mask[x] == 0
		for z in range(cells.y):
			if (mask.is_empty() or mask[z * cells.x + x] == 0) != walkable:
				return ["rows differ at column %d" % x]
		if walkable: columns.append(x)
	return columns

## Independent per-cell reference: float64 corner means, triangle normals.
static func reference_walkable(source: StrataRuntimeData, rule: Dictionary, cell: Vector2i) -> Variant:
	var lattice := source.get_cell_resolution()
	var w := lattice.x + 1
	var i := cell.y * w + cell.x
	if rule.has("all"):
		var result: Variant = true
		for child in rule.all:
			var value: Variant = reference_walkable(source, child, cell)
			if value == null: return null
			result = result and value
		return result
	if rule.has("any"):
		var result: Variant = false
		for child in rule.any:
			var value: Variant = reference_walkable(source, child, cell)
			if value == null: return null
			result = result or value
		return result
	if rule.has("not"):
		var value: Variant = reference_walkable(source, rule["not"], cell)
		return null if value == null else not value
	if rule.has("exclusion"):
		return not source.is_nav_excluded_cell(cell)
	if rule.has("slope_min") or rule.has("slope_max"):
		var s := source.get_spacing()
		var heights := source.heights_window(Rect2i(Vector2i.ZERO, lattice))
		var a := Vector3(0, heights[i], 0)
		var b := Vector3(s, heights[i + 1], 0)
		var c := Vector3(0, heights[i + w], s)
		var d := Vector3(s, heights[i + w + 1], s)
		var steep := 0.0
		for triangle in [[a, b, c], [b, d, c]]:
			var normal: Vector3 = (triangle[1] - triangle[0]).cross(triangle[2] - triangle[0]).normalized()
			steep = maxf(steep, rad_to_deg(acos(absf(normal.y))))
		var low := float(rule.get("slope_min", 0.0))
		var high := float(rule.get("slope_max", 90.0))
		if absf(steep - low) < 0.001 or absf(steep - high) < 0.001: return null
		return steep >= low and steep <= high
	var values := source.heights_window(Rect2i(Vector2i.ZERO, lattice)) if rule.has("height_min") or rule.has("height_max") else source.map_window_bytes(rule.channel, Rect2i(Vector2i.ZERO, lattice)).to_float32_array()
	var mean := (float(values[i]) + values[i + 1] + values[i + w] + values[i + w + 1]) * 0.25
	var low := float(rule.get("height_min", rule.get("min", -INF)))
	var high := float(rule.get("height_max", rule.get("max", INF)))
	if absf(mean - low) < 0.0001 or absf(mean - high) < 0.0001: return null
	return mean >= low and mean <= high

## Profile rules on a ramp, the two-triangle split and combinators, plus an
## independent per-cell reference over every scheduling path of the evaluator.
func check_rules() -> void:
	var ramp_data := make_data(Rect2(0, 0, 9, 3), Vector2i(10, 4), ramp)
	var cells := ramp_data.get_cell_resolution()
	add_cell_map(ramp_data, "nav_exclusion", [Rect2i(0, 1, 9, 1)])
	add_channel(ramp_data, "fungal_network", func(i: int, _j: int) -> float: return 1.0 if i == 4 else 0.0)
	finish_data(ramp_data)
	check(ramp_data.validate().ok, "ramp fixture valid")
	# Cell means by column: 0, 0, 0, 0.5, 1.5, 2.5, 4, 6, 8; slopes 0, 45, 63.4.
	var expectations := [
		[{"slope_max": 30.0}, [0, 1, 2]],
		[{"slope_max": 50.0}, [0, 1, 2, 3, 4, 5]],
		[{"slope_min": 50.0}, [6, 7, 8]],
		[{"slope_min": 30.0, "slope_max": 50.0}, [3, 4, 5]],
		[{"height_min": 1.0}, [4, 5, 6, 7, 8]],
		[{"height_max": 1.5}, [0, 1, 2, 3, 4]],
		[{"height_min": 1.5, "height_max": 4.0}, [4, 5, 6]],
		[{"not": {"height_min": 1.0}}, [0, 1, 2, 3]],
		[{"all": [{"slope_max": 50.0}, {"height_min": 1.0}]}, [4, 5]],
		[{"any": [{"slope_max": 30.0}, {"height_min": 5.0}]}, [0, 1, 2, 7, 8]],
		[{"not": {"any": [{"slope_min": 50.0}, {"height_max": 0.0}]}}, [3, 4, 5]],
		# Mean of the four corners: two of them on the 0/1 network column.
		[{"channel": "fungal_network", "min": 0.5}, [3, 4]],
		[{"channel": "fungal_network", "min": 0.6}, []],
		[{"channel": "fungal_network", "max": 0.25}, [0, 1, 2, 5, 6, 7, 8]],
	]
	for entry in expectations:
		var mask := StrataNavProfiles.evaluate(ramp_data, entry[0])
		check(walkable_columns(mask, cells) == entry[1], "ramp rule %s walkable columns %s (expected %s)" % [entry[0], walkable_columns(mask, cells), entry[1]])
	# Exclusion literal: the middle row; the default rule reproduces nav_exclusions.
	check(StrataNavProfiles.evaluate(ramp_data, StrataNavProfiles.DEFAULT_RULE) == ramp_data.cell_mask_window("nav_exclusion", Rect2i(Vector2i.ZERO, cells)), "the default rule is exactly nav_exclusions")
	var inverted := StrataNavProfiles.evaluate(ramp_data, {"not": {"exclusion": true}})
	check(inverted.count(255) == 18 and inverted[9] == 0 and inverted[0] == 255, "not exclusion walks only the excluded row")
	var excluded_flat := StrataNavProfiles.evaluate(ramp_data, {"all": [{"exclusion": true}, {"slope_max": 30.0}]})
	check(excluded_flat.count(0) == 6 and excluded_flat[0] == 0 and excluded_flat[9] == 255, "all of exclusion and slope")
	check(StrataNavProfiles.evaluate(ramp_data, {"any": [{"slope_min": 0.0}, {"height_min": 99.0}]}).is_empty(), "a rule true everywhere stores an empty mask")
	check(StrataNavProfiles.evaluate(ramp_data, {"all": [{"height_min": 99.0}, {"slope_max": 10.0}]}).count(255) == 27, "a rule false everywhere blocks every cell")
	# The steeper of the two canonical triangles decides, in either one.
	for corner in [Vector2i(1, 1), Vector2i(0, 0)]:
		var probe := make_data(Rect2(0, 0, 1, 1), Vector2i(2, 2), func(i: int, j: int) -> float: return 2.0 if Vector2i(i, j) == corner else 0.0)
		check(StrataNavProfiles.evaluate(probe, {"slope_max": 60.0}) == PackedByteArray([255]) and StrataNavProfiles.evaluate(probe, {"slope_min": 70.0}).is_empty() and StrataNavProfiles.evaluate(probe, {"slope_min": 71.0}) == PackedByteArray([255]), "the 70.5 degree triangle with raised corner %s decides the cell" % corner)

	# Reference over the navigation fixture: sparse and dense terms, literals and
	# nested terms, so candidate passes and sparse/dense mapping are all covered.
	var rules := [
		{"all": [{"channel": "footpath", "min": 0.5}, {"slope_max": 12.0}, {"exclusion": true}]},
		{"all": [{"not": {"channel": "footpath", "min": 0.5}}, {"slope_max": 12.0}]},
		{"all": [{"height_max": -1.0}, {"slope_min": 4.0}, {"not": {"exclusion": true}}]},
		{"all": [{"channel": "footpath", "min": 0.25}, {"any": [{"exclusion": true}, {"slope_min": 20.0}]}, {"slope_max": 50.0}]},
		{"any": [{"channel": "footpath", "min": 0.5}, {"slope_min": 40.0}, {"not": {"exclusion": true}}]},
		{"all": [{"slope_max": 30.0}, {"not": {"slope_max": 30.0}}]},
		{"not": {"all": [{"height_min": -1.5}, {"height_max": 0.5}]}},
	]
	var data_cells := data.get_cell_resolution()
	for rule in rules:
		var mask := StrataNavProfiles.evaluate(data, rule)
		var mismatches := 0
		var compared := 0
		for z in range(data_cells.y):
			for x in range(data_cells.x):
				var expected: Variant = reference_walkable(data, rule, Vector2i(x, z))
				if expected == null: continue
				compared += 1
				var walkable := mask.is_empty() or mask[z * data_cells.x + x] == 0
				if walkable != expected: mismatches += 1
		check(mismatches == 0 and compared > data_cells.x * data_cells.y * 0.95, "rule %s matches the per-cell reference (%d mismatches of %d)" % [rule, mismatches, compared])

func run() -> void:
	data = make_data(Rect2(-48.0, -24.0, 96.0, 48.0), Vector2i(97, 49), gentle)
	var cells := data.get_cell_resolution()
	# Hole wall leaving a gap at the top; exclusion pad reaching the far edge.
	add_cell_map(data, "holes", [Rect2i(44, 0, 4, 34)])
	add_cell_map(data, "nav_exclusion", [Rect2i(60, 36, 6, 12)])
	# Footpath: an L of path samples, x 4..10 for z 4..45 and z 38..45 for x 4..40.
	var footpath := PackedFloat32Array(); footpath.resize(97 * 49)
	for j in range(49):
		for i in range(97):
			if i >= 4 and i <= 10 and j >= 4 and j <= 45 or j >= 38 and j <= 45 and i >= 4 and i <= 40:
				footpath[j * 97 + i] = 1.0
	add_channel(data, "footpath", func(i: int, j: int) -> float: return footpath[j * 97 + i])
	finish_data(data)
	var applied := StrataNavProfiles.apply(data, [{"name": &"paths", "rule": {"channel": "footpath", "min": 0.5}}])
	check(applied.ok and data.get_nav_profile_names() == [&"default", &"paths"], "paths profile evaluated: %s" % applied)
	# Walkable: cells with at least two of four path corners (mean >= 0.5); the
	# outer corner cells of the L have only one.
	var expected_paths := PackedByteArray(); expected_paths.resize(cells.x * cells.y); expected_paths.fill(255)
	for z in range(cells.y):
		for x in range(cells.x):
			var corners := 0
			for corner in [Vector2i(x, z), Vector2i(x + 1, z), Vector2i(x, z + 1), Vector2i(x + 1, z + 1)]:
				corners += 1 if footpath[corner.y * 97 + corner.x] == 1.0 else 0
			if corners >= 2: expected_paths[z * cells.x + x] = 0
	var path_differences := []
	for index in range(expected_paths.size()):
		if data.get_nav_profile_mask(&"paths")[index] != expected_paths[index]: path_differences.append(Vector2i(index % cells.x, index / cells.x))
	check(path_differences.is_empty() and expected_paths.count(0) == 609, "paths profile walks exactly the footpath cells (%d); differing cells %s" % [expected_paths.count(0), path_differences.slice(0, 12)])
	check(data.is_nav_blocked_cell(Vector2i(20, 20), &"paths") and not data.is_nav_blocked_cell(Vector2i(20, 20)) and not data.is_nav_blocked_cell(Vector2i(20, 40), &"paths"), "is_nav_blocked_cell follows the profile")
	check(data.validate().ok and data.height_min < 0.0 and data.height_max > 0.0, "signed navigation fixture valid")
	check_rules()

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

	# Agent populations: one StrataNavigation per profile, each on its own layer.
	check(navigation.bake_region(data.bounds).ok and navigation.get_stats().profile == &"default", "default population (layer 1) rebaked at 45 degrees")
	var paths_nav := StrataNavigation.new()
	paths_nav.name = "PathsNavigation"
	paths_nav.tile_cells = 32
	paths_nav.agent_radius = AGENT_RADIUS
	paths_nav.use_async = false
	paths_nav.navigation_layers = 2
	paths_nav.profile = &"paths"
	paths_nav.data = data
	terrain_root.add_child(paths_nav)
	var paths_baked := paths_nav.bake_region(data.bounds)
	check(paths_baked.ok and paths_baked.regions > 0 and paths_nav.get_stats().profile == &"paths", "paths population (layer 2) bakes: %s" % paths_baked)
	var paths_faces := paths_nav.build_source_faces(Rect2i(Vector2i.ZERO, cells)).size() / 6
	check(paths_faces == data.get_nav_profile_mask(&"paths").count(0), "paths source faces cover only path cells (%d)" % paths_faces)
	await sync_map()
	var populations := merge_conflicts(navigation.get_regions() + paths_nav.get_regions())
	print("two-population edge-key conflicts on one map: %s" % populations)
	check(populations.cross_tile == 0 and populations.intra_tile == 0, "the two populations' regions merge on one map without edge conflicts: %s" % populations)
	var path_from := world_at(Vector2(36, 41.5))
	var path_to := world_at(Vector2(7, 8))
	var off_path := world_at(Vector2(25, 15))
	var along := NavigationServer3D.map_get_path(map, path_from, path_to, true, 2)
	var along_result := check_path(along, path_from, path_to, "paths layer along the footpath", &"paths")
	check(along_result.length > path_from.distance_to(path_to) * 1.2, "the footpath route follows the L, not the diagonal (%s vs %s)" % [along_result.length, path_from.distance_to(path_to)])
	var stranded := NavigationServer3D.map_get_path(map, path_from, off_path, true, 2)
	check(stranded.is_empty() or stranded[-1].distance_to(off_path) > 5.0, "no paths-layer route reaches the off-path target (ends %s m away)" % (stranded[-1].distance_to(off_path) if not stranded.is_empty() else INF))
	var inverse_root := terrain_root.global_transform.affine_inverse()
	var stays_on_path := true
	for point in stranded:
		var local := inverse_root * point
		stays_on_path = stays_on_path and blocked_clearance(Vector2(local.x, local.z), &"paths") > 0.0
	check(stays_on_path, "the stranded paths-layer route stays on path cells")
	check_path(NavigationServer3D.map_get_path(map, path_from, off_path, true, 1), path_from, off_path, "default layer reaches the off-path target")
	var missing_nav := StrataNavigation.new()
	missing_nav.profile = &"swamp"
	missing_nav.use_async = false
	missing_nav.data = data
	terrain_root.add_child(missing_nav)
	var missing := missing_nav.bake_region(data.bounds)
	check(not missing.ok and "swamp" in missing.message and missing_nav.get_regions().is_empty() and missing_nav.build_source_faces(Rect2i(0, 0, 4, 4)).is_empty(), "a missing profile is a bake error, not a crash: %s" % missing.get("message"))
	missing_nav.free()
	paths_nav.profile = &"default"
	check(paths_nav.get_regions().is_empty() and paths_nav.get_stats().profile == &"default" and paths_nav.get_stats().regions == 0, "changing the profile clears the population's tiles")
	paths_nav.free()
	await sync_map()

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
