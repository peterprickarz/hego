extends "res://tests/runtime_test_base.gd"
## StrataCollision against real Godot physics raycasts.

const S := StrataRuntimeData.Status
const TERRAIN_LAYER := 4
const FLOOR_LAYER := 2
const FLOOR_TOP := -80.0
## float32 world coordinates near 150 m resolve ~1e-5 m; this is not a gap budget.
const TOLERANCE := 0.0005

var terrain_root: Node3D
var collision: StrataCollision
var floor_body: StaticBody3D
var world: World3D
var max_error := 0.0
var rays := 0

func _initialize() -> void:
	call_deferred("run")

func settle() -> void:
	await physics_frame
	await physics_frame

## Cast straight down through terrain-local XZ and classify the hit.
func cast(local: Vector2, mask: int = TERRAIN_LAYER | FLOOR_LAYER, node: Node3D = null) -> Dictionary:
	var base := node if node != null else terrain_root
	var from := base.global_transform * Vector3(local.x, 60.0, local.y)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 400.0, mask)
	var hit := world.direct_space_state.intersect_ray(query)
	rays += 1
	if hit.is_empty():
		return {"kind": "none"}
	if hit.collider == floor_body:
		return {"kind": "floor", "position": hit.position}
	return {"kind": "terrain", "position": hit.position, "collider": hit.collider}

func expect_surface(data: StrataRuntimeData, local: Vector2, label: String, node: Node3D = null) -> void:
	var base := node if node != null else terrain_root
	var sampled := data.sample_height(local)
	var hit := cast(local, TERRAIN_LAYER | FLOOR_LAYER, base)
	if sampled.status == S.HOLE:
		check(hit.kind == "floor", "%s: hole at %s must pass through to the next solid (got %s)" % [label, local, hit.kind])
		return
	check(sampled.status == S.OK, "%s: expected OK sample at %s" % [label, local])
	if hit.kind != "terrain":
		check(false, "%s: expected terrain hit at %s, got %s" % [label, local, hit.kind])
		return
	var expected := base.global_transform * Vector3(local.x, sampled.value, local.y)
	var error := (hit.position as Vector3).distance_to(expected)
	max_error = maxf(max_error, error)
	check(error <= TOLERANCE, "%s: hit %s expected %s (error %s) at local %s" % [label, hit.position, expected, error, local])

func run() -> void:
	# 40 x 24 cells, rectangular, fractional negative origin; 16-cell chunks.
	var data := make_data(Rect2(-20.25, 10.5, 40.0, 24.0), Vector2i(41, 25))
	add_cell_map(data, "holes", [Rect2i(18, 3, 3, 2), Rect2i(37, 20, 1, 1)])
	finish_data(data)
	check(data.validate().ok, "fixture valid")
	check(data.height_min < 0.0 and data.height_max > 0.0, "fixture has negative and positive heights")

	terrain_root = Node3D.new()
	terrain_root.name = "RuntimeTerrain"
	terrain_root.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(37.0)), Vector3(130.0, -20.0, -55.0))
	get_root().add_child(terrain_root)
	world = terrain_root.get_world_3d()
	floor_body = StaticBody3D.new()
	floor_body.collision_layer = FLOOR_LAYER
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2000, 2, 2000)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(130, FLOOR_TOP - 1.0, -55)
	get_root().add_child(floor_body)

	collision = StrataCollision.new()
	collision.name = "Collision"
	collision.chunk_cells = 16
	collision.collision_layer = TERRAIN_LAYER
	collision.collision_mask = 0
	var material := PhysicsMaterial.new()
	material.friction = 0.3
	collision.physics_material = material
	collision.data = data
	terrain_root.add_child(collision)
	check(collision.get_resident_chunks().is_empty(), "nothing is built before an explicit request")
	check(collision.get_chunk_grid() == Vector2i(3, 2), "3 x 2 chunk grid")
	check(collision.get_chunk_cells(Vector2i(2, 1)) == Rect2i(32, 16, 8, 8), "edge chunks are clipped")

	var built := collision.prepare_region(data.bounds)
	check(built.ok and built.resident == 6, "prepare whole fixture: %s" % built)
	var valid_chunks := collision.get_resident_chunks()
	collision.chunk_cells = 0
	collision.max_resident_chunks = 0
	check(collision.chunk_cells == 16 and collision.max_resident_chunks == 64 and collision.get_resident_chunks() == valid_chunks, "invalid programmatic chunk/budget assignments retain valid settings and resident shapes")
	check(not collision.prepare_region(Rect2(Vector2(NAN, 0), Vector2.ONE)).ok and collision.get_resident_chunks() == valid_chunks, "nonfinite request preserves collision residency")
	check(not collision.prepare_around(Vector3(INF, 0, 0), 2).ok and collision.get_resident_chunks() == valid_chunks, "nonfinite world request preserves collision residency")
	check(not collision.prepare_region(Rect2(10000, 10000, 1, 1)).ok and collision.get_resident_chunks() == valid_chunks, "outside request preserves collision residency")
	await settle()

	# Shape kinds, exact source heights, omitted hole triangles.
	for key in collision.get_resident_chunks():
		var info := collision.get_chunk_info(key)
		var expected_kind := StrataCollision.ChunkKind.CONCAVE if key in [Vector2i(1, 0), Vector2i(2, 1)] else StrataCollision.ChunkKind.HEIGHTMAP
		check(info.kind == expected_kind, "chunk %s kind %s" % [key, info.kind])
		var shape: Shape3D = info.body.get_node("Shape").shape
		check(info.body.collision_layer == TERRAIN_LAYER and info.body.collision_mask == 0 and info.body.physics_material_override == material, "chunk %s layer/mask/material" % key)
		if shape is HeightMapShape3D:
			var cells: Rect2i = info.cells
			check(shape.map_width == cells.size.x + 1 and shape.map_depth == cells.size.y + 1, "heightmap %s has shared edge samples" % key)
			var exact := true
			for z in range(cells.size.y + 1):
				for x in range(cells.size.x + 1):
					exact = exact and shape.map_data[z * shape.map_width + x] == data.get_height_at(cells.position + Vector2i(x, z))
			check(exact, "heightmap %s copies compiled heights exactly" % key)
		elif shape is ConcavePolygonShape3D:
			var faces: PackedVector3Array = shape.get_faces()
			# Chunk cells plus the one-cell apron, clipped to the terrain.
			var apron: Rect2i = (info.cells as Rect2i).grow(1).intersection(Rect2i(Vector2i.ZERO, data.get_cell_resolution()))
			var holes_in_apron := 6 if key == Vector2i(1, 0) else 1
			check(faces.size() == (apron.size.x * apron.size.y - holes_in_apron) * 6, "concave chunk %s omits exactly the hole cells' triangles (%d vertices)" % [key, faces.size()])
			var lowest := INF
			for vertex in faces: lowest = minf(lowest, vertex.y)
			check(lowest >= data.height_min, "no vertex is lowered to fake a hole")
	var chunk_one: Dictionary = collision.get_chunk_info(Vector2i(1, 0))
	check(chunk_one.body.get_node("Shape").shape is ConcavePolygonShape3D, "hole chunk is concave, not a heightmap")

	# Lattice points, including chunk edges at cells 16 and 32 and row 16.
	# Points exactly on the outer perimeter can round outside the shape under
	# the yawed float32 transform; they are inset 1 mm and counted separately.
	var perimeter_misses := 0
	var perimeter_rays := 0
	for z in [0, 1, 7, 15, 16, 17, 23, 24]:
		for x in [0, 1, 15, 16, 17, 31, 32, 33, 39, 40]:
			var lattice := Vector2(x, z)
			if x in [0, 40] or z in [0, 24]:
				perimeter_rays += 1
				if cast(data.lattice_to_local(lattice)).kind != "terrain": perimeter_misses += 1
				lattice = lattice.clamp(Vector2.ONE * 0.001, Vector2(40, 24) - Vector2.ONE * 0.001)
			expect_surface(data, data.lattice_to_local(lattice), "lattice")
	print("exact outer-perimeter rays missing terrain: %d of %d (inset 1 mm all checked)" % [perimeter_misses, perimeter_rays])
	# Nonplanar cell interiors either side of the b-c diagonal, chunk-edge cells.
	for cell in [Vector2i(0, 0), Vector2i(15, 15), Vector2i(16, 15), Vector2i(15, 16), Vector2i(17, 3), Vector2i(21, 4), Vector2i(31, 20), Vector2i(32, 20), Vector2i(38, 21), Vector2i(36, 20)]:
		for f in [Vector2(0.25, 0.25), Vector2(0.75, 0.75), Vector2(0.5, 0.49), Vector2(0.8, 0.1), Vector2(0.1, 0.8), Vector2(0.97, 0.97)]:
			expect_surface(data, data.lattice_to_local(Vector2(cell) + f), "interior")
	# Chunk edges between lattice points.
	for z in [2.5, 9.3, 16.0, 20.7]:
		for x in [16.0, 32.0]:
			expect_surface(data, data.lattice_to_local(Vector2(x, z)), "chunk edge")
	for x in [3.5, 16.5, 31.2, 35.9]:
		expect_surface(data, data.lattice_to_local(Vector2(x, 16.0)), "chunk edge row")
	# Deterministic scatter.
	var rng := RandomNumberGenerator.new()
	rng.seed = 4401
	for index in range(400):
		expect_surface(data, data.lattice_to_local(Vector2(rng.randf_range(0.0, 40.0), rng.randf_range(0.0, 24.0))), "scatter")

	# Dense sweep exactly along every chunk seam (and through seam vertices)
	# for several yaws: no ray may slip between adjacent chunk shapes.
	var seam_rays := 0
	var seam_misses := 0
	var base_transform := terrain_root.transform
	for yaw in [0.0, 12.3, 37.0, 90.0, 211.7]:
		terrain_root.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)), base_transform.origin)
		await settle()
		for step in range(1, 800):
			var t := step / 800.0
			for lattice in [Vector2(16.0, t * 24.0), Vector2(32.0, t * 24.0), Vector2(t * 40.0, 16.0)]:
				var local: Vector2 = data.lattice_to_local(lattice)
				if data.is_hole_at(local): continue
				seam_rays += 1
				if cast(local, TERRAIN_LAYER).kind != "terrain": seam_misses += 1
	terrain_root.transform = base_transform
	await settle()
	check(seam_misses == 0, "seam rays leaking between chunks: %d of %d" % [seam_misses, seam_rays])
	print("seam sweep: %d rays across 5 yaws, %d leaks" % [seam_rays, seam_misses])

	# True holes: absence of terrain and presence of the next solid below.
	for cell in [Vector2i(18, 3), Vector2i(20, 4), Vector2i(37, 20)]:
		for f in [Vector2(0.5, 0.5), Vector2(0.02, 0.02), Vector2(0.98, 0.5), Vector2(0.3, 0.9)]:
			var local := data.lattice_to_local(Vector2(cell) + f)
			var hit := cast(local)
			check(hit.kind == "floor", "hole %s %s reaches the floor (got %s)" % [cell, f, hit.kind])
			if hit.kind == "floor":
				near(hit.position.y, FLOOR_TOP, 0.001, "floor beneath hole")
			check(collision.collision_status_at(local) == S.HOLE, "status HOLE at %s" % local)
			check(cast(local, TERRAIN_LAYER).kind == "none", "terrain-only ray finds nothing in hole %s" % cell)
	# Solid neighbours of holes (inside the concave chunk) still collide.
	for local_lattice in [Vector2(17.95, 3.5), Vector2(21.05, 4.5), Vector2(19.5, 2.95), Vector2(19.5, 5.05), Vector2(36.98, 20.5), Vector2(38.02, 20.5)]:
		expect_surface(data, data.lattice_to_local(local_lattice), "hole neighbour")
	# Layer/mask filtering.
	check(cast(data.lattice_to_local(Vector2(5.5, 5.5)), FLOOR_LAYER).kind == "floor", "floor-only mask ignores terrain layer")

	# Camera is irrelevant: moving one far away changes nothing.
	var builds_before: int = collision.get_stats().builds
	var camera := Camera3D.new()
	get_root().add_child(camera)
	camera.global_position = Vector3(5000, 300, 5000)
	camera.make_current()
	for frame in range(5):
		camera.global_position += Vector3(-900, 0, -900)
		await process_frame
	await settle()
	check(collision.get_stats().builds == builds_before and collision.get_resident_chunks().size() == 6, "camera motion causes no rebuild or residency change")
	expect_surface(data, data.lattice_to_local(Vector2(12.25, 7.75)), "after camera motion")

	# Bounded residency: oversize request is rejected without touching the set.
	collision.max_resident_chunks = 2
	var refused := collision.prepare_region(data.bounds)
	check(not refused.ok and collision.get_resident_chunks().size() == 6, "oversized region rejected, existing chunks kept")
	collision.max_resident_chunks = 64

	# Gameplay-area residency around a world position.
	collision.clear()
	await settle()
	check(cast(data.lattice_to_local(Vector2(5.5, 5.5)), TERRAIN_LAYER).kind == "none", "clear removes all shapes")
	var spawn := terrain_root.global_transform * Vector3(data.lattice_to_local(Vector2(4, 4)).x, 0, data.lattice_to_local(Vector2(4, 4)).y)
	var around := collision.prepare_around(spawn, 2.0)
	check(around.ok and collision.get_resident_chunks() == [Vector2i(0, 0)], "prepare_around builds only the local chunk: %s" % [collision.get_resident_chunks()])
	await settle()
	expect_surface(data, data.lattice_to_local(Vector2(4.3, 4.6)), "around spawn")
	var far := data.lattice_to_local(Vector2(36.5, 22.5))
	check(collision.collision_status_at(far) == S.NOT_RESIDENT and cast(far, TERRAIN_LAYER).kind == "none", "far chunk is not resident")

	# Tracked gameplay target: rebuilds only when it changes chunk.
	collision.clear()
	var player := Node3D.new()
	player.name = "Player"
	terrain_root.add_child(player)
	player.position = Vector3(data.lattice_to_local(Vector2(3, 3)).x, 0, data.lattice_to_local(Vector2(3, 3)).y)
	collision.track_radius = 3.0
	collision.track_target = collision.get_path_to(player)
	for frame in range(3):
		await physics_frame
	check(collision.get_resident_chunks() == [Vector2i(0, 0)], "tracking builds around the target: %s" % [collision.get_resident_chunks()])
	var tracked_builds: int = collision.get_stats().builds
	for frame in range(20):
		await physics_frame
	check(collision.get_stats().builds == tracked_builds, "stationary target causes no per-tick rebuild")
	player.position = Vector3(data.lattice_to_local(Vector2(36, 21)).x, 0, data.lattice_to_local(Vector2(36, 21)).y)
	for frame in range(3):
		await physics_frame
	check(collision.get_resident_chunks() == [Vector2i(2, 1)] and collision.get_stats().builds == tracked_builds + 1, "moving target swaps to its new chunk only: %s" % [collision.get_resident_chunks()])
	collision.track_target = NodePath()

	# A failed request must retry at the same target position when its temporary
	# budget problem is fixed; no movement is required to make collision resident.
	collision.clear()
	collision.max_resident_chunks = 1
	collision.track_radius = 30.0
	player.position = Vector3(data.lattice_to_local(Vector2(20, 12)).x, 0, data.lattice_to_local(Vector2(20, 12)).y)
	collision.track_target = collision.get_path_to(player)
	await physics_frame
	check(collision.get_resident_chunks() == [collision.chunk_at_local(Vector2(player.position.x, player.position.z))], "an over-budget tracked area keeps only the chunk under the target")
	collision.max_resident_chunks = 64
	for frame in range(3): await physics_frame
	check(collision.get_resident_chunks().size() == 6, "raising the budget re-plans the unchanged target")
	collision.track_target = NodePath()
	collision.chunk_cells = 8
	check(collision.get_resident_chunks().is_empty() and collision.get_chunk_grid() == Vector2i(5, 3), "valid chunk configuration change invalidates old shape indexing")
	collision.chunk_cells = 16

	# Chunks that do not divide the 16-cell regions read windows across region edges.
	collision.chunk_cells = 24
	check(collision.prepare_region(data.bounds).ok and collision.get_chunk_grid() == Vector2i(2, 1), "24-cell chunks over 16-cell regions build")
	await settle()
	for key in collision.get_resident_chunks():
		var odd_shape: Shape3D = collision.get_chunk_info(key).body.get_node("Shape").shape
		if odd_shape is HeightMapShape3D:
			var odd_cells: Rect2i = collision.get_chunk_info(key).cells
			var odd_exact := true
			for z in range(odd_cells.size.y + 1):
				for x in range(odd_cells.size.x + 1):
					odd_exact = odd_exact and odd_shape.map_data[z * odd_shape.map_width + x] == data.get_height_at(odd_cells.position + Vector2i(x, z))
			check(odd_exact, "24-cell heightmap %s copies heights across region seams exactly" % key)
	for index in range(200):
		expect_surface(data, data.lattice_to_local(Vector2(rng.randf_range(0.0, 40.0), rng.randf_range(0.0, 24.0))), "24-cell chunks")
	collision.chunk_cells = 16

	# Atomic replacement with a new bake; failed replacement keeps the old one.
	collision.prepare_region(data.bounds)
	var raised := make_data(data.bounds, Vector2i(41, 25), func(i: int, j: int) -> float: return fixture_height(i, j) + 5.0)
	add_cell_map(raised, "holes", [Rect2i(18, 3, 3, 2), Rect2i(37, 20, 1, 1)])
	finish_data(raised)
	var replaced := collision.replace_data(raised)
	check(replaced.ok and replaced.resident == 6 and collision.data == raised, "replace_data rebuilds all resident chunks: %s" % replaced)
	await settle()
	expect_surface(raised, data.lattice_to_local(Vector2(10.4, 12.7)), "after replace")
	var broken := make_data(data.bounds, Vector2i(41, 25))
	broken.regions.erase(Vector2i(1, 0))
	check(not broken.validate_payload().get("ok", true) or not broken.validate().ok, "fixture with a missing region is invalid")
	var rejected := collision.replace_data(broken)
	check(not rejected.ok and collision.data == raised and collision.get_resident_chunks().size() == 6, "invalid replacement keeps previous data and shapes")
	await settle()
	expect_surface(raised, data.lattice_to_local(Vector2(10.4, 12.7)), "after rejected replace")

	# Non-unit spacing (2 m) uses a uniformly scaled heightmap and scaled faces.
	var coarse := make_data(Rect2(-8.0, -6.0, 16.0, 12.0), Vector2i(9, 7))
	add_cell_map(coarse, "holes", [Rect2i(1, 1, 1, 1)])
	finish_data(coarse)
	check(coarse.validate().ok and coarse.get_spacing() == 2.0, "2 m fixture")
	var coarse_root := Node3D.new()
	coarse_root.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(-71.0)), Vector3(-300.0, 12.0, 80.0))
	get_root().add_child(coarse_root)
	var coarse_collision := StrataCollision.new()
	coarse_collision.chunk_cells = 4
	coarse_collision.collision_layer = TERRAIN_LAYER
	coarse_collision.data = coarse
	coarse_root.add_child(coarse_collision)
	check(coarse_collision.prepare_region(coarse.bounds).ok, "2 m collision builds")
	await settle()
	for lattice in [Vector2(0.25, 0.25), Vector2(5.75, 4.75), Vector2(3.5, 3.5), Vector2(4.0, 2.5), Vector2(1.2, 2.6), Vector2(2.9, 1.5), Vector2(7.0, 5.0)]:
		expect_surface(coarse, coarse.lattice_to_local(lattice), "2 m spacing", coarse_root)
	check(cast(coarse.lattice_to_local(Vector2(1.5, 1.5)), TERRAIN_LAYER | FLOOR_LAYER, coarse_root).kind != "terrain", "2 m hole is open")

	# Teardown.
	collision.clear()
	check(collision.get_child_count() == 0 and collision.get_resident_chunks().is_empty(), "clear frees every chunk body")
	collision.prepare_region(data.bounds)
	var probe_from := terrain_root.global_transform * Vector3(data.lattice_to_local(Vector2(5.5, 5.5)).x, 60.0, data.lattice_to_local(Vector2(5.5, 5.5)).y)
	terrain_root.queue_free()
	coarse_root.queue_free()
	await settle()
	var after := world.direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(probe_from, probe_from + Vector3.DOWN * 400.0, TERRAIN_LAYER))
	check(after.is_empty(), "freeing the runtime terrain removes its shapes from the space")
	print("collision rays: %d, max surface error %s m" % [rays, max_error])
	finish("RUNTIME_COLLISION_TEST")
