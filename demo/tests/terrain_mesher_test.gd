extends SceneTree

const EPS := 0.00001
const WEST := 1
const EAST := 2
const NORTH := 4
const SOUTH := 8
var failures: Array[String] = []
var checks := 0
var mesher: StrataMesher

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		if failures.size() <= 20:
			push_error(message)

func near(a: float, b: float) -> bool:
	return absf(a - b) <= EPS

func run() -> void:
	mesher = StrataMesher.new()
	for cells in [2, 4, 8]:
		for mask in range(16):
			_check_mesh(cells, 16.0, mask)
	_check_mesh(128, 32.0, 15)
	_check_neighbor_geometry()
	_check_selection()
	_check_shared_position_reconstruction()
	_check_invalid_inputs()
	if failures.is_empty():
		print("Strata mesher tests passed (%d invariant checks)" % checks)
		quit(0)
	else:
		push_error("%d mesher invariant check(s) failed" % failures.size())
		quit(1)

func _check_mesh(cells: int, size: float, mask: int) -> void:
	var label := "cells=%d mask=%d" % [cells, mask]
	var mesh := mesher.build_patch(cells, size, mask)
	check(mesh != null and mesh.get_surface_count() == 1, "patch has one surface: " + label)
	if mesh == null or mesh.get_surface_count() != 1:
		return
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	check(vertices.size() == (cells + 1) * (cells + 1), "patch retains its regular sampling lattice: " + label)
	check(normals.size() == vertices.size() and uvs.size() == vertices.size(), "patch has normals and UVs: " + label)
	for i in range(vertices.size()):
		var p := vertices[i]
		check(p.y == 0.0 and p.x >= 0.0 and p.x <= size and p.z >= 0.0 and p.z <= size, "flat vertices lie in patch bounds: " + label)
		# ArrayMesh round-trips normals through Godot's octahedral encoding.
		check(normals[i].distance_to(Vector3.UP) < 0.00005 and uvs[i].is_equal_approx(Vector2(p.x, p.z) / size), "native normals and UVs match patch coordinates within mesh encoding precision: " + label)
	check(indices.size() > 0 and indices.size() % 3 == 0, "patch has triangle indices: " + label)
	var area := 0.0
	var edges: Dictionary = {}
	for i in range(0, indices.size(), 3):
		var a := indices[i]
		var b := indices[i + 1]
		var c := indices[i + 2]
		check(a >= 0 and b >= 0 and c >= 0 and a < vertices.size() and b < vertices.size() and c < vertices.size(), "triangle indices are valid: " + label)
		var pa := vertices[a]
		var pb := vertices[b]
		var pc := vertices[c]
		# Positive signed XZ area is clockwise when viewed from above in Godot.
		var signed_twice_area := (pb.x - pa.x) * (pc.z - pa.z) - (pb.z - pa.z) * (pc.x - pa.x)
		check(signed_twice_area > 0.0, "triangle is nondegenerate with Godot clockwise winding: " + label)
		area += signed_twice_area * 0.5
		for pair in [[a, b], [b, c], [c, a]]:
			var key := Vector2i(mini(pair[0], pair[1]), maxi(pair[0], pair[1]))
			edges[key] = int(edges.get(key, 0)) + 1
	check(near(area, size * size), "triangle area covers the complete patch: " + label)
	var boundary := {WEST: {}, EAST: {}, NORTH: {}, SOUTH: {}}
	for key: Vector2i in edges:
		var count: int = edges[key]
		check(count == 1 or count == 2, "indexed edges are manifold: " + label)
		if count != 1:
			continue
		var a := vertices[key.x]
		var b := vertices[key.y]
		var side := 0
		if a.x == 0.0 and b.x == 0.0: side = WEST
		elif a.x == size and b.x == size: side = EAST
		elif a.z == 0.0 and b.z == 0.0: side = NORTH
		elif a.z == size and b.z == size: side = SOUTH
		check(side != 0, "no unpaired internal edges or corner T-junctions: " + label)
		if side == 0:
			continue
		var ta := a.z if side == WEST or side == EAST else a.x
		var tb := b.z if side == WEST or side == EAST else b.x
		var segment := Vector2i(roundi(minf(ta, tb) * cells / size), roundi(maxf(ta, tb) * cells / size))
		boundary[side][segment] = true
	for side in [WEST, EAST, NORTH, SOUTH]:
		var step := 2 if mask & side else 1
		var expected: Dictionary = {}
		for start in range(0, cells, step):
			expected[Vector2i(start, start + step)] = true
		check(boundary[side] == expected, "boundary segments exactly match stitch parity on side %d: %s" % [side, label])

func _edge_parameters(mesh: ArrayMesh, edge: int, size: float, origin: Vector2, first: float, last: float) -> Array:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var parameters: Dictionary = {}
	for index in indices:
		var p := vertices[index]
		var on_edge := (edge == WEST and p.x == 0.0) or (edge == EAST and p.x == size) or (edge == NORTH and p.z == 0.0) or (edge == SOUTH and p.z == size)
		if on_edge:
			var parameter := p.z + origin.y if edge == WEST or edge == EAST else p.x + origin.x
			if parameter >= first and parameter <= last:
				parameters[parameter] = true
	var result := parameters.keys()
	result.sort()
	return result

func _check_neighbor_geometry() -> void:
	var coarse_origin := Vector2(-32.0, -48.0)
	var coarse := mesher.build_patch(8, 16.0, 0)
	for pair in [[WEST, EAST, Vector2(16.0, 0.0)], [EAST, WEST, Vector2(-8.0, 0.0)], [NORTH, SOUTH, Vector2(0.0, 16.0)], [SOUTH, NORTH, Vector2(0.0, -8.0)]]:
		var side: int = pair[0]
		var fine_origin: Vector2 = coarse_origin + pair[2]
		var fine := mesher.build_patch(8, 8.0, side)
		var first := fine_origin.y if side == WEST or side == EAST else fine_origin.x
		var fine_points := _edge_parameters(fine, side, 8.0, fine_origin, first, first + 8.0)
		var coarse_points := _edge_parameters(coarse, pair[1], 16.0, coarse_origin, first, first + 8.0)
		check(fine_points == coarse_points and fine_points.size() == 5, "stitched fine boundary matches neighboring coarse vertices exactly, side %d" % side)

func _check_partition(patches: Array, bounds: Rect2, minimum_size: float, budget: int, label: String) -> void:
	check(not patches.is_empty() and patches.size() <= budget, "selection obeys budget without dropping coverage: " + label)
	var area := 0.0
	var expected_masks: Array[int] = []
	expected_masks.resize(patches.size())
	expected_masks.fill(0)
	for i in range(patches.size()):
		var patch: Dictionary = patches[i]
		var origin: Vector2 = patch.origin
		var size: float = patch.size
		var level: int = patch.level
		var lattice_origin: Vector2i = patch.lattice_origin
		var lattice_span: int = patch.lattice_span
		var lattice_units: int = patch.lattice_units
		check(lattice_units >= 1 and lattice_units <= 4096 and lattice_span * (1 << level) == lattice_units, "integer lattice identifies patch span exactly: " + label)
		check(lattice_origin.x >= 0 and lattice_origin.y >= 0 and lattice_origin.x % lattice_span == 0 and lattice_origin.y % lattice_span == 0 and lattice_origin.x + lattice_span <= lattice_units and lattice_origin.y + lattice_span <= lattice_units, "integer lattice origin is aligned and bounded: " + label)
		check(size >= minimum_size - EPS and size > 0.0 and level >= 0 and level <= 12, "patch size and level are valid: " + label)
		check(near(size, bounds.size.x / pow(2.0, level)), "level identifies root-relative resolution: " + label)
		check(near((origin.x - bounds.position.x) / size, round((origin.x - bounds.position.x) / size)) and near((origin.y - bounds.position.y) / size, round((origin.y - bounds.position.y) / size)), "patch aligns to common quadtree origin: " + label)
		check(origin.x >= bounds.position.x - EPS and origin.y >= bounds.position.y - EPS and origin.x + size <= bounds.end.x + EPS and origin.y + size <= bounds.end.y + EPS, "patch remains inside root bounds: " + label)
		area += size * size
		for j in range(i):
			var other: Dictionary = patches[j]
			var other_origin: Vector2 = other.origin
			var other_size: float = other.size
			var overlap_x := minf(origin.x + size, other_origin.x + other_size) - maxf(origin.x, other_origin.x)
			var overlap_z := minf(origin.y + size, other_origin.y + other_size) - maxf(origin.y, other_origin.y)
			check(overlap_x <= EPS or overlap_z <= EPS, "patch interiors do not overlap: " + label)
			var edge := 0
			var opposite := 0
			if overlap_z > EPS:
				if near(origin.x, other_origin.x + other_size): edge = WEST; opposite = EAST
				elif near(origin.x + size, other_origin.x): edge = EAST; opposite = WEST
			if overlap_x > EPS:
				if near(origin.y, other_origin.y + other_size): edge = NORTH; opposite = SOUTH
				elif near(origin.y + size, other_origin.y): edge = SOUTH; opposite = NORTH
			if edge == 0:
				continue
			check(maxf(size, other_size) <= minf(size, other_size) * 2.0 + EPS, "edge neighbors obey 2:1 balance: " + label)
			if other_size > size + EPS: expected_masks[i] |= edge
			elif size > other_size + EPS: expected_masks[j] |= opposite
	check(near(area, bounds.size.x * bounds.size.y), "patch partition covers root area exactly: " + label)
	for i in range(patches.size()):
		check(patches[i].stitch_mask == expected_masks[i], "stitch mask identifies every coarser neighbor and no other edges: " + label)

func _check_selection() -> void:
	var bounds := Rect2(-32.0, -48.0, 64.0, 64.0)
	var cameras := [Vector2(0.0, -16.0), bounds.position, bounds.end, Vector2(-1000.0, 2000.0), Vector2(17.5, -43.75)]
	for camera: Vector2 in cameras:
		var patches := mesher.select_patches(bounds, camera, 2.0)
		_check_partition(patches, bounds, 2.0, 512, "camera=%s" % str(camera))
		check(patches == mesher.select_patches(bounds, camera, 2.0), "camera teleports and repeated calls produce deterministic selection")
	var near_patches := mesher.select_patches(bounds, Vector2(0.0, -16.0), 2.0)
	var sizes: Dictionary = {}
	for patch: Dictionary in near_patches: sizes[patch.size] = true
	check(sizes.has(2.0) and sizes.size() > 1, "near camera requests minimum resolution with coarser distant patches")
	var distant := mesher.select_patches(bounds, Vector2(10000.0, 10000.0), 2.0)
	check(distant.size() == 1 and distant[0].level == 0, "camera far outside root keeps one complete root patch")
	for budget in [1, 2, 3, 4, 7, 16, 64, 128]:
		var limited := mesher.select_patches(bounds, Vector2.ZERO, 0.015625, 2.0, budget)
		_check_partition(limited, bounds, 0.015625, budget, "deep request budget=%d" % budget)
		check(limited == mesher.select_patches(bounds, Vector2.ZERO, 0.015625, 2.0, budget), "budget coarsening is deterministic")
	_check_partition(mesher.select_patches(bounds, Vector2.ZERO, 0.015625), bounds, 0.015625, 512, "maximum-depth request at default budget")
	var fractional_bounds := Rect2(-13.25, -27.75, 32.0, 32.0)
	_check_partition(mesher.select_patches(fractional_bounds, Vector2(-12.5, -27.0), 0.5, 1.5, 128), fractional_bounds, 0.5, 128, "negative fractional origin")
	var started := Time.get_ticks_usec()
	var largest_count := 0
	for i in range(100):
		var camera := bounds.position + Vector2((i * 17) % 64, (i * 31) % 64)
		largest_count = maxi(largest_count, mesher.select_patches(bounds, camera, 2.0).size())
	print("Mesher selection benchmark: %.3f ms/call across 100 camera positions, maximum %d patches" % [float(Time.get_ticks_usec() - started) / 100000.0, largest_count])
	started = Time.get_ticks_usec()
	for i in range(20):
		mesher.select_patches(bounds, bounds.position + Vector2((i * 17) % 64, (i * 31) % 64), 0.015625)
	print("Mesher maximum-depth/budget fallback benchmark: %.3f ms/call across 20 camera positions" % [float(Time.get_ticks_usec() - started) / 20000.0])

func _check_shared_position_reconstruction() -> void:
	# Use actual ArrayMesh UVs and Vector2 float32 operations, comparing exact
	# values rather than approximate geometry. Independent origin+local-position
	# addition produces seams for these otherwise valid non-dyadic roots.
	var shared_vertices := 0
	for bounds in [Rect2(0.1234567, 0.1234567, 4096.0, 4096.0), Rect2(0.1, -0.3, 4096.1, 4096.1), Rect2(0.1, -0.3, 0.1, 0.1)]:
		var minimum_size: float = bounds.size.x / (64.0 if bounds.size.x < 1.0 else 4096.0)
		var patches := mesher.select_patches(bounds, bounds.position, minimum_size)
		var mesh_data: Dictionary = {}
		for patch: Dictionary in patches:
			var key := Vector2(patch.size, patch.stitch_mask)
			if not mesh_data.has(key):
				var arrays := mesher.build_patch(32, patch.size, patch.stitch_mask).surface_get_arrays(0)
				var used: Dictionary = {}
				for index in arrays[Mesh.ARRAY_INDEX]: used[index] = true
				mesh_data[key] = {"uvs": arrays[Mesh.ARRAY_TEX_UV], "used": used}
		for i in range(patches.size()):
			var a: Dictionary = patches[i]
			var ai: Vector2i = a.lattice_origin
			var sa: int = a.lattice_span
			for j in range(i):
				var b: Dictionary = patches[j]
				var bi: Vector2i = b.lattice_origin
				var sb: int = b.lattice_span
				var overlap_x := mini(ai.x + sa, bi.x + sb) - maxi(ai.x, bi.x)
				var overlap_z := mini(ai.y + sa, bi.y + sb) - maxi(ai.y, bi.y)
				var edge_x := INF
				var edge_z := INF
				if overlap_z > 0:
					if ai.x == bi.x + sb: edge_x = ai.x
					elif ai.x + sa == bi.x: edge_x = bi.x
				if overlap_x > 0:
					if ai.y == bi.y + sb: edge_z = ai.y
					elif ai.y + sa == bi.y: edge_z = bi.y
				var first := 0.0
				var last := 0.0
				if is_finite(edge_x):
					first = maxi(ai.y, bi.y); last = mini(ai.y + sa, bi.y + sb)
				elif is_finite(edge_z):
					first = maxi(ai.x, bi.x); last = mini(ai.x + sa, bi.x + sb)
				else:
					continue
				var step := float(maxi(sa, sb)) / 32.0
				for k in range(roundi((last - first) / step) + 1):
					var logical := Vector2(edge_x, first + k * step) if is_finite(edge_x) else Vector2(first + k * step, edge_z)
					var normalized_a := _normalized_mesh_vertex(a, logical, mesh_data)
					var normalized_b := _normalized_mesh_vertex(b, logical, mesh_data)
					check(normalized_a == normalized_b, "shared mesh UVs reconstruct identical normalized float32 coordinates")
					var world_a: Vector2 = bounds.position + bounds.size * normalized_a
					var world_b: Vector2 = bounds.position + bounds.size * normalized_b
					check(world_a == world_b, "common root transform gives bit-identical terrain-local positions at non-dyadic shared edges")
					shared_vertices += 1
	check(shared_vertices > 10000, "non-dyadic seam regressions exercise many real shared vertices")
	print("Mesher exact shared-position checks: %d vertices" % shared_vertices)

func _normalized_mesh_vertex(patch: Dictionary, logical: Vector2, mesh_data: Dictionary) -> Vector2:
	var lattice_origin: Vector2i = patch.lattice_origin
	var span: int = patch.lattice_span
	var units: int = patch.lattice_units
	var vertex_index := Vector2i(((logical - Vector2(lattice_origin)) / span * 32.0).round())
	var index := vertex_index.y * 33 + vertex_index.x
	var data: Dictionary = mesh_data[Vector2(patch.size, patch.stitch_mask)]
	check(data.used.has(index), "shared coarse/fine positions reference vertices retained by stitch indices")
	var uv: Vector2 = data.uvs[index]
	return Vector2(lattice_origin) / units + uv * (float(span) / units)

func _check_invalid_inputs() -> void:
	for request in [[1, 8.0, 0], [3, 8.0, 0], [256, 8.0, 0], [8, 0.0, 0], [8, -1.0, 0], [8, NAN, 0], [8, INF, 0], [8, 8.0, -1], [8, 8.0, 16]]:
		check(mesher.build_patch(request[0], request[1], request[2]) == null, "invalid mesh input rejects without geometry: " + str(request))
	var valid := Rect2(-32.0, -32.0, 64.0, 64.0)
	for bounds in [Rect2(0.0, 0.0, 0.0, 0.0), Rect2(0.0, 0.0, -64.0, -64.0), Rect2(0.0, 0.0, 64.0, 32.0), Rect2(Vector2(NAN, 0.0), Vector2(64.0, 64.0)), Rect2(Vector2.ZERO, Vector2(INF, INF))]:
		check(mesher.select_patches(bounds, Vector2.ZERO, 2.0).is_empty(), "invalid bounds reject without partial coverage")
	for camera in [Vector2(NAN, 0.0), Vector2(0.0, INF)]:
		check(mesher.select_patches(valid, camera, 2.0).is_empty(), "nonfinite camera rejects without patches")
	for size in [0.0, -1.0, NAN, INF, 3.0, 128.0, 0.0078125]:
		check(mesher.select_patches(valid, Vector2.ZERO, size).is_empty(), "invalid minimum size or subdivision depth rejects")
	for split_ratio in [0.0, -1.0, NAN, INF]:
		check(mesher.select_patches(valid, Vector2.ZERO, 2.0, split_ratio).is_empty(), "invalid split ratio rejects")
	for budget in [0, 4097]:
		check(mesher.select_patches(valid, Vector2.ZERO, 2.0, 2.0, budget).is_empty(), "invalid patch budget rejects")
	check(mesher.select_patches(Rect2(1.0e12, -1.0e12, 1048576.0, 1048576.0), Vector2.ZERO, 256.0).is_empty(), "finite large origin rejects collapsed minimum-patch coordinates")
