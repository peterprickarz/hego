extends SceneTree

# Geometry invariants use the integer lattice, independently of rounded origin
# descriptors. Shader seam checks use actual indexed ArrayMesh UVs / float32.
var failures: Array[String] = []
var checks := 0
var mesher: StrataMesher
const CELLS := 8

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		if failures.size() <= 20: push_error(message)

func key(origin: Vector2i, span: int) -> Vector3i:
	return Vector3i(origin.x, origin.y, span)

func circle_intersects_lattice(origin: Vector2i, span: int, units: int, bounds: Rect2, camera: Vector2, radius: float) -> bool:
	# Selection is defined on the precise root lattice. Vector2 descriptor
	# origins / Vector2 clamp math round to float32 and can turn an outside
	# ulp-wide gap into a tangent; the renderer adds a movement guard band.
	var unit := float(bounds.size.x) / float(units)
	var left := float(bounds.position.x) + float(origin.x) * unit
	var north := float(bounds.position.y) + float(origin.y) * unit
	var size := float(span) * unit
	var dx := maxf(maxf(left - float(camera.x), float(camera.x) - (left + size)), 0.0)
	var dz := maxf(maxf(north - float(camera.y), float(camera.y) - (north + size)), 0.0)
	return sqrt(dx * dx + dz * dz) <= radius

func run() -> void:
	mesher = StrataMesher.new()
	var bounds := Rect2(-32.0, -48.0, 64.0, 64.0)
	for camera in [Vector2(-2, -17), bounds.position, bounds.end, Vector2(-10000, 10000)]:
		for budget in [0, 2, 3, 12, 48, 256]:
			validate_case(bounds, camera, 8.0, 128, 1.0, 5.0, budget)
	# A deliberately tiny base budget does not prohibit using the separate budget
	# to reach a target equal to or coarser than the nominal base minimum.
	for target in [8.0, 16.0]:
		var result := validate_case(bounds, Vector2(-1, -17), 8.0, 4, target, 5.0, 256)
		check(result.refinement_patch_count > 0 and not result.refinement_limited, "separate refinement budget improves budget-coarsened base at target >= nominal minimum")
		check(result.effective_refinement_patch_size <= target, "effective size reports actual circle detail after coarse base fallback")
	var base := mesher.select_patches(bounds, Vector2.ZERO, 8.0, 2.0, 128)
	for request in [[1.0, 0.0, 256], [8.0, 8.0, 256], [64.0, 8.0, 256], [128.0, 8.0, 256], [1.0, 8.0, 0]]:
		var result := mesher.select_refined_patches(bounds, Vector2.ZERO, 8.0, 2.0, 128, request[0], request[1], request[2])
		check(result.patches == base and result.refinement_patch_count == 0, "disabled/coarse/zero-budget path preserves exact old descriptors")
		check(result.refinement_limited == (request[0] == 1.0 and request[1] > 0.0 and request[2] == 0), "zero budget truthfully reports blocked refinement while geometric no-ops are unlimited")
	var fractional := Rect2(0.1, -0.3, 64.0, 64.0)
	var refined := validate_case(fractional, Vector2(31.1, 32.7), 8.0, 128, 0.5, 5.0, 512)
	check_shared_mesh_positions(refined.patches, fractional)
	# Real demo scale and depth limit; no per-cell rasterization is needed.
	validate_case(Rect2(-2048, -2048, 4096, 4096), Vector2(-556, 19), 8.0, 512, 4.0, 32.0, 1024)
	validate_case(bounds, Vector2.ZERO, 8.0, 128, 0.015625, 0.04, 1024)
	var capped := validate_case(bounds, Vector2.ZERO, 8.0, 1, 0.5, 1000.0, 4096)
	check(capped.patches.size() == 4096 and capped.refinement_limited and capped.effective_refinement_patch_size == 1.0, "total cap retries a complete uniformly coarser target without traversal starvation")
	for request in [[0.0, 1.0, 128], [-1.0, 1.0, 128], [NAN, 1.0, 128], [INF, 1.0, 128], [3.0, 1.0, 128], [0.0078125, 1.0, 128], [1.0, -1.0, 128], [1.0, NAN, 128], [1.0, INF, 128], [1.0, 1.0, -1], [1.0, 1.0, 4097]]:
		check(mesher.select_refined_patches(bounds, Vector2.ZERO, 8.0, 2.0, 128, request[0], request[1], request[2]).is_empty(), "invalid refinement input rejects completely: " + str(request))
	check(mesher.select_refined_patches(bounds, Vector2(INF, 0), 8.0, 2.0, 128, 1.0, 5.0, 256).is_empty(), "invalid base input rejects refined request")
	if failures.is_empty():
		print("Strata refinement tests passed (%d invariant checks)" % checks)
		quit(0)
	else:
		push_error("%d refinement invariant checks failed" % failures.size())
		quit(1)

func validate_case(bounds: Rect2, camera: Vector2, minimum: float, base_budget: int, target: float, radius: float, extra: int) -> Dictionary:
	var base := mesher.select_patches(bounds, camera, minimum, 2.0, base_budget)
	var result := mesher.select_refined_patches(bounds, camera, minimum, 2.0, base_budget, target, radius, extra)
	check(not result.is_empty(), "valid refinement returns a result")
	if result.is_empty(): return {}
	var patches: Array = result.patches
	check(result.base_patch_count == base.size(), "base count matches unchanged old selector")
	check(result.refinement_patch_count == patches.size() - base.size(), "refinement count measures additional leaves including balance")
	check(patches.size() >= base.size() and patches.size() <= mini(4096, base.size() + extra), "separate additional budget preserves base without overspending")
	check(result == mesher.select_refined_patches(bounds, camera, minimum, 2.0, base_budget, target, radius, extra), "selection is deterministic after teleports and earlier budgets")
	var units: int = patches[0].lattice_units
	var lookup: Dictionary = {}
	var area := 0
	var circle_max := 0.0
	var finest := bounds.size.x
	var descendants: Dictionary = {}
	var original: Dictionary = {}
	for b: Dictionary in base:
		var multiplier := units / int(b.lattice_units)
		original[key(b.lattice_origin * multiplier, b.lattice_span * multiplier)] = b
	for p: Dictionary in patches:
		var origin: Vector2i = p.lattice_origin
		var span: int = p.lattice_span
		check(p.lattice_units == units and span > 0 and span * (1 << int(p.level)) == units, "leaf uses shared dyadic lattice")
		check(origin.x >= 0 and origin.y >= 0 and origin.x % span == 0 and origin.y % span == 0 and origin.x + span <= units and origin.y + span <= units, "leaf is aligned and inside common root")
		var k := key(origin, span)
		check(not lookup.has(k), "leaf is unique")
		lookup[k] = p
		area += span * span
		finest = minf(finest, p.size)
		if circle_intersects_lattice(origin, span, units, bounds, camera, radius): circle_max = maxf(circle_max, p.size)
		var ancestor_span := span
		var parent_count := 0
		while ancestor_span <= units:
			var ancestor_origin := Vector2i(origin.x / ancestor_span, origin.y / ancestor_span) * ancestor_span
			var ancestor_key := key(ancestor_origin, ancestor_span)
			if original.has(ancestor_key):
				parent_count += 1
				descendants[ancestor_key] = int(descendants.get(ancestor_key, 0)) + span * span
			ancestor_span *= 2
		check(parent_count == 1, "every output leaf belongs to exactly one original base leaf, never coarsening it")
	check(area == units * units, "leaf integer area covers complete root")
	for k: Vector3i in original:
		check(descendants.get(k, 0) == k.z * k.z, "each original base leaf is fully partitioned into descendants")
	for p: Dictionary in patches:
		var origin: Vector2i = p.lattice_origin
		var span: int = p.lattice_span
		var ancestor_span := span * 2
		while ancestor_span <= units:
			var ancestor_origin := Vector2i(origin.x / ancestor_span, origin.y / ancestor_span) * ancestor_span
			check(not lookup.has(key(ancestor_origin, ancestor_span)), "leaf interiors cannot overlap an ancestor")
			ancestor_span *= 2
		var midpoint := origin + Vector2i(span / 2, span / 2)
		var points := [Vector2i(origin.x - 1, midpoint.y), Vector2i(origin.x + span, midpoint.y), Vector2i(midpoint.x, origin.y - 1), Vector2i(midpoint.x, origin.y + span)]
		var expected_mask := 0
		for edge in range(4):
			var neighbor := find_leaf(points[edge], units, lookup)
			if neighbor.is_empty(): continue
			check(absi(int(neighbor.level) - int(p.level)) <= 1, "every edge neighbor is balanced 2:1")
			if neighbor.lattice_span > span: expected_mask |= 1 << edge
		check(p.stitch_mask == expected_mask, "stitch bits identify exactly the coarser neighbors")
	check(result.effective_refinement_patch_size == (circle_max if circle_max > 0.0 else finest), "effective detail is the actual largest circle-intersecting leaf")
	if not result.refinement_limited and radius > 0.0 and circle_max > 0.0:
		check(circle_max <= target, "unlimited refinement reaches target everywhere in circle")
	if extra == 0 or radius == 0.0 or circle_max == 0.0:
		check(patches == base, "no-op refinement preserves exact old lattice and descriptors")
	# Every split outside the requested circle must be necessary to balance an
	# adjacent finer leaf; inspect introduced ancestors, not just final leaves.
	var split_parents: Dictionary = {}
	for p: Dictionary in patches:
		var span: int = p.lattice_span * 2
		while span <= units:
			var origin := Vector2i(p.lattice_origin.x / span, p.lattice_origin.y / span) * span
			var k := key(origin, span)
			if original.has(k):
				split_parents[k] = true
				break
			split_parents[k] = true
			span *= 2
	for k: Vector3i in split_parents:
		# Ancestors above a base leaf are not introduced refinement splits.
		var inside_base := false
		for b: Vector3i in original:
			if k.z <= b.z and k.x >= b.x and k.y >= b.y and k.x + k.z <= b.x + b.z and k.y + k.z <= b.y + b.z:
				inside_base = true
				break
		if not inside_base: continue
		if circle_intersects_lattice(Vector2i(k.x, k.y), k.z, units, bounds, camera, radius): continue
		var required := false
		for q: Dictionary in patches:
			if q.lattice_span * 4 > k.z: continue
			var qo: Vector2i = q.lattice_origin
			var qs: int = q.lattice_span
			var overlap_x := mini(k.x + k.z, qo.x + qs) - maxi(k.x, qo.x)
			var overlap_z := mini(k.y + k.z, qo.y + qs) - maxi(k.y, qo.y)
			if (overlap_z > 0 and (qo.x + qs == k.x or qo.x == k.x + k.z)) or (overlap_x > 0 and (qo.y + qs == k.y or qo.y == k.y + k.z)):
				required = true
				break
		check(required, "splits outside circle are justified by required neighbor balancing")
	return result

func find_leaf(point: Vector2i, units: int, lookup: Dictionary) -> Dictionary:
	if point.x < 0 or point.y < 0 or point.x >= units or point.y >= units: return {}
	var span := units
	while span > 0:
		var origin := Vector2i(point.x / span, point.y / span) * span
		if lookup.has(key(origin, span)): return lookup[key(origin, span)]
		span /= 2
	return {}

func check_shared_mesh_positions(patches: Array, bounds: Rect2) -> void:
	var mesh_data: Dictionary = {}
	var shared_count := 0
	var transitions := 0
	for p: Dictionary in patches:
		var cache_key := Vector2(p.size, p.stitch_mask)
		if mesh_data.has(cache_key): continue
		var arrays := mesher.build_patch(CELLS, p.size, p.stitch_mask).surface_get_arrays(0)
		var used: Dictionary = {}
		for index in arrays[Mesh.ARRAY_INDEX]: used[index] = true
		mesh_data[cache_key] = {"uvs": arrays[Mesh.ARRAY_TEX_UV], "used": used}
	for i in range(patches.size()):
		var a: Dictionary = patches[i]
		var ao: Vector2i = a.lattice_origin
		var sa: int = a.lattice_span
		for j in range(i):
			var b: Dictionary = patches[j]
			var bo: Vector2i = b.lattice_origin
			var sb: int = b.lattice_span
			var ox := mini(ao.x + sa, bo.x + sb) - maxi(ao.x, bo.x)
			var oz := mini(ao.y + sa, bo.y + sb) - maxi(ao.y, bo.y)
			var vertical := oz > 0 and (ao.x + sa == bo.x or bo.x + sb == ao.x)
			var horizontal := ox > 0 and (ao.y + sa == bo.y or bo.y + sb == ao.y)
			if not vertical and not horizontal: continue
			var first := maxi(ao.y, bo.y) if vertical else maxi(ao.x, bo.x)
			var last := mini(ao.y + sa, bo.y + sb) if vertical else mini(ao.x + sa, bo.x + sb)
			var edge := maxi(ao.x, bo.x) if vertical else maxi(ao.y, bo.y)
			var step := float(maxi(sa, sb)) / CELLS
			if sa != sb: transitions += 1
			for v in range(roundi((last - first) / step) + 1):
				var logical := Vector2(edge, first + v * step) if vertical else Vector2(first + v * step, edge)
				var na := mesh_normalized(a, logical, mesh_data)
				var nb := mesh_normalized(b, logical, mesh_data)
				check(na == nb, "indexed shared mesh vertices have bit-identical normalized shader coordinates")
				var world_a := bounds.position + bounds.size * na
				var world_b := bounds.position + bounds.size * nb
				check(world_a == world_b, "refined/shared boundary positions remain bit-identical at fractional origin")
				check(world_a * Vector2(0.0137, 0.0079) + Vector2(0.1, 0.3) == world_b * Vector2(0.0137, 0.0079) + Vector2(0.1, 0.3), "shared positions sample identical heightfield UVs")
				shared_count += 1
	check(shared_count > 100 and transitions > 0, "actual ArrayMesh boundary regression exercises new fine/coarse transitions")

func mesh_normalized(p: Dictionary, logical: Vector2, mesh_data: Dictionary) -> Vector2:
	var origin: Vector2i = p.lattice_origin
	var span: int = p.lattice_span
	var vertex := Vector2i(((logical - Vector2(origin)) / span * CELLS).round())
	var index := vertex.y * (CELLS + 1) + vertex.x
	var data: Dictionary = mesh_data[Vector2(p.size, p.stitch_mask)]
	check(data.used.has(index), "shared fine/coarse sample references an actual indexed vertex after stitching")
	var uv: Vector2 = data.uvs[index]
	return Vector2(origin) / int(p.lattice_units) + uv * (float(span) / int(p.lattice_units))
