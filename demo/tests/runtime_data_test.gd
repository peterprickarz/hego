extends "res://tests/runtime_test_base.gd"
## StrataRuntimeData: lattice, statuses, holes, channels, conversions.

const S := StrataRuntimeData.Status

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	# Rectangular 6 x 4 m grid at 1 m with a negative, fractional origin.
	var data := make_data(Rect2(-10.5, 5.25, 6.0, 4.0), Vector2i(7, 5))
	check(data.validate().ok, "valid fixture: %s" % data.validate())
	near(data.get_spacing(), 1.0, 0.0, "uniform spacing")
	check(data.get_cell_resolution() == Vector2i(6, 4), "cell resolution is width-1 x height-1")

	# Exact signed values at lattice points.
	var negative_seen := false
	for j in range(5):
		for i in range(7):
			var point := data.bounds.position + Vector2(i, j)
			var sampled := data.sample_height(point)
			check(sampled.status == S.OK, "lattice point %s is OK" % point)
			near(sampled.value, data.heights[j * 7 + i], 0.0, "lattice value exact at %d,%d" % [i, j])
			negative_seen = negative_seen or sampled.value < 0.0
	check(negative_seen and data.height_max > 0.0, "fixture spans negative and positive heights")

	# Nonplanar cell interiors follow the (a, b, c), (b, d, c) split.
	var max_gap := 0.0
	for cell in [Vector2i(0, 0), Vector2i(2, 1), Vector2i(5, 3)]:
		for f in [Vector2(0.25, 0.25), Vector2(0.75, 0.75), Vector2(0.7, 0.2), Vector2(0.2, 0.7), Vector2(0.5, 0.5), Vector2(0.9, 0.05)]:
			var point: Vector2 = data.bounds.position + Vector2(cell) + f
			# Vector2 is float32: evaluate the reference at the quantized query.
			var expected := reference_height(data, cell, data.local_to_lattice(point) - Vector2(cell))
			near(data.sample_height(point).value, expected, 0.000001, "triangle interpolation cell %s f %s" % [cell, f])
			var bilinear: float = data.sample_height(point, StrataRuntimeData.Interpolation.BILINEAR).value
			max_gap = maxf(max_gap, absf(bilinear - expected))
	check(max_gap > 0.25, "fixture is nonplanar: bilinear vs triangle gap %s" % max_gap)
	print("bilinear/triangle gap on fixture cells: ", max_gap)

	# Hand-computed cell: heights a=0, b=4, c=6, d=-3 (the physics probe values).
	var probe := make_data(Rect2(0, 0, 1, 1), Vector2i(2, 2), func(i: int, j: int) -> float: return [[0.0, 4.0], [6.0, -3.0]][j][i])
	near(probe.sample_height(Vector2(0.25, 0.25)).value, 2.5, 0.000001, "abc triangle 0.25,0.25")
	near(probe.sample_height(Vector2(0.75, 0.75)).value, 1.0, 0.000001, "bdc triangle 0.75,0.75")
	near(probe.sample_height(Vector2(0.5, 0.5)).value, 5.0, 0.000001, "diagonal midpoint is (b+c)/2")
	near(probe.sample_height(Vector2(0.5, 0.5), StrataRuntimeData.Interpolation.BILINEAR).value, 1.75, 0.000001, "bilinear midpoint")

	# Statuses: outside, not resident, valid zero.
	check(data.sample_height(Vector2(-11.0, 6.0)).status == S.OUTSIDE, "outside bounds")
	check(data.sample_height(Vector2(NAN, 6.0)).status == S.OUTSIDE, "non-finite query is outside")
	var empty := StrataRuntimeData.new()
	empty.bounds = data.bounds
	empty.resolution = data.resolution
	check(empty.validate().ok, "manifest-only data validates")
	check(empty.sample_height(Vector2(-8.0, 6.0)).status == S.NOT_RESIDENT, "missing payload is NOT_RESIDENT")
	var zero := make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3), func(_i: int, _j: int) -> float: return 0.0)
	var zero_sample := zero.sample_height(Vector2(0.5, 1.5))
	check(zero_sample.status == S.OK and zero_sample.value == 0.0, "valid zero height is OK, not absent")

	# Holes: cell (2, 1) and the 2 x 1 block (4..5, 3).
	data.holes = cell_mask(Vector2i(6, 4), [Rect2i(2, 1, 1, 1), Rect2i(4, 3, 2, 1)])
	check(data.validate().ok, "canonical holes validate")
	var hole_center := data.bounds.position + Vector2(2.5, 1.5)
	check(data.sample_height(hole_center).status == S.HOLE, "hole cell interior is HOLE")
	check(data.sample_height(hole_center, 0, true).status == S.OK, "ignore_holes samples the underlying lattice")
	var edge := data.bounds.position + Vector2(2.0, 1.5)
	check(data.sample_height(edge).status == S.OK and not data.is_hole_at(edge), "shared hole edge keeps the solid side")
	var internal_edge := data.bounds.position + Vector2(5.0, 3.5)
	check(data.is_hole_at(internal_edge), "edge between two hole cells is a hole")
	check(data.sample_height(data.bounds.position + Vector2(1.5, 1.5)).status == S.OK, "neighbour cell is solid")
	var hole_image := data.get_hole_image()
	check(hole_image.get_size() == Vector2i(6, 4) and hole_image.get_format() == Image.FORMAT_L8, "hole image is L8 cells")
	check(hole_image.get_pixel(2, 1).r == 1.0 and hole_image.get_pixel(1, 1).r == 0.0, "hole image marks exactly the hole cells")
	data.holes[0] = 7
	check(not data.validate().ok, "non-canonical stored mask is rejected")
	data.holes[0] = 0

	# Canonical threshold: float >= 0.5, byte >= 128.
	var rf := Image.create(3, 1, false, Image.FORMAT_RF)
	rf.set_pixel(0, 0, Color(0.4999, 0, 0)); rf.set_pixel(1, 0, Color(0.5, 0, 0)); rf.set_pixel(2, 0, Color(-3.0, 0, 0))
	var canonical := StrataRuntimeData.canonicalize_cell_mask(rf, Vector2i(3, 1))
	check(canonical.ok and canonical.mask == PackedByteArray([0, 255, 0]), "RF threshold >= 0.5: %s" % canonical)
	var l8 := Image.create_from_data(3, 1, false, Image.FORMAT_L8, PackedByteArray([127, 128, 255]))
	canonical = StrataRuntimeData.canonicalize_cell_mask(l8, Vector2i(3, 1))
	check(canonical.ok and canonical.mask == PackedByteArray([0, 255, 255]), "L8 threshold >= 128: %s" % canonical)
	check(StrataRuntimeData.canonicalize_cell_mask(PackedByteArray([0, 0, 0]), Vector2i(3, 1)).mask.is_empty(), "all-solid masks compact to empty")
	var absent_mask := StrataRuntimeData.canonicalize_cell_mask(PackedByteArray(), Vector2i(4096, 4096))
	check(absent_mask.ok and absent_mask.mask.is_empty() and absent_mask.count == 0, "empty canonical bytes represent no mask without allocating the 4km cell lattice")
	check(not StrataRuntimeData.canonicalize_cell_mask(Image.create(4, 1, false, Image.FORMAT_L8), Vector2i(3, 1)).ok, "wrong mask size rejected")
	rf.set_pixel(0, 0, Color(NAN, 0, 0))
	check(not StrataRuntimeData.canonicalize_cell_mask(rf, Vector2i(3, 1)).ok, "non-finite float mask rejected")

	# Channels: defined zero vs absent, signed and unclamped values, eviction.
	var count := 35
	var values := PackedFloat32Array(); values.resize(count)
	var coverage := PackedFloat32Array(); coverage.resize(count)
	for index in range(count):
		var i := index % 7
		if i <= 2:
			values[index] = [0.0, -2.5, 7.0][i]
			coverage[index] = 1.0
	data.channels = {"wetness": {"values": values, "coverage": coverage}}
	data.channel_names = PackedStringArray(["wetness", "unbaked"])
	check(data.validate().ok, "channel payload validates")
	var at_zero := data.sample_channel(&"wetness", data.bounds.position + Vector2(0, 2))
	check(at_zero.status == S.OK and at_zero.value == 0.0, "defined zero channel value is OK")
	near(data.sample_channel(&"wetness", data.bounds.position + Vector2(1, 1)).value, -2.5, 0.0, "negative channel value preserved")
	near(data.sample_channel(&"wetness", data.bounds.position + Vector2(2, 0)).value, 7.0, 0.0, "values above 1 stay unclamped")
	near(data.sample_channel(&"wetness", data.bounds.position + Vector2(1.5, 0.5)).value, 2.25, 0.000001, "channel bilinear between defined samples")
	var partial := data.sample_channel(&"wetness", data.bounds.position + Vector2(2.5, 0.5))
	check(partial.status == S.OK and is_equal_approx(partial.value, 7.0) and is_equal_approx(partial.coverage, 0.5), "partially defined cell uses only defined corners: %s" % partial)
	check(data.sample_channel(&"wetness", data.bounds.position + Vector2(5, 2)).status == S.ABSENT, "undefined samples are ABSENT")
	check(data.sample_channel(&"missing", data.bounds.position).status == S.ABSENT, "unknown channel is ABSENT")
	check(data.sample_channel(&"unbaked", data.bounds.position).status == S.NOT_RESIDENT, "manifest channel without payload is NOT_RESIDENT")
	check(data.sample_channel(&"wetness", Vector2(100, 100)).status == S.OUTSIDE, "channel outside bounds")
	var manifest := data.get_manifest()
	check(manifest.height_bytes == 35 * 4 and manifest.channels[0].bytes == 35 * 8 and manifest.hole_cells == 3, "manifest bytes: %s" % manifest)
	data.evict_channel(&"wetness")
	check(data.sample_channel(&"wetness", data.bounds.position).status == S.NOT_RESIDENT, "evicted channel is NOT_RESIDENT")

	# Batch and world conversion through translation + yaw.
	var transform := Transform3D(Basis(Vector3.UP, deg_to_rad(37.0)), Vector3(120.0, -15.0, -42.0))
	var points := PackedVector2Array([data.bounds.position + Vector2(0.3, 0.6), data.bounds.position + Vector2(4.2, 2.9), Vector2(500, 0), hole_center])
	var batch := data.sample_heights(points)
	check(batch.status == PackedByteArray([S.OK, S.OK, S.OUTSIDE, S.HOLE]), "batch statuses %s" % batch.status)
	near(batch.values[1], data.sample_height(points[1]).value, 0.000001, "batch value equals single query (float32 storage)")
	check(is_nan(batch.values[2]), "non-OK batch values are NAN")
	var world_query := transform * Vector3(points[1].x, 99.0, points[1].y)
	var world := data.sample_height_world(world_query, transform)
	check(world.status == S.OK, "world query OK")
	near(world.value, batch.values[1], 0.00001, "world query uses terrain-local height")
	var expected_world := transform * Vector3(points[1].x, batch.values[1], points[1].y)
	check(world.position.is_equal_approx(expected_world), "world surface position %s vs %s" % [world.position, expected_world])
	near(world.position.y, batch.values[1] - 15.0, 0.0001, "world height includes translation")
	var world_batch := data.sample_heights_world(PackedVector3Array([world_query]), transform)
	check(world_batch.status[0] == S.OK and world_batch.positions[0].is_equal_approx(expected_world), "world batch")

	# Validation rejects inconsistent payloads.
	var bad := make_data(Rect2(0, 0, 4, 3), Vector2i(5, 3))
	check(not bad.validate().ok, "non-uniform spacing rejected")
	bad = make_data(Rect2(0, 0, 4, 2), Vector2i(5, 3))
	bad.heights.resize(4)
	check(not bad.validate().ok, "wrong height count rejected")
	bad = make_data(Rect2(0, 0, 4, 2), Vector2i(5, 3))
	bad.format_version = 99
	check(not bad.validate().ok, "unknown format version rejected")
	bad = make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	var malformed := bad.heights.duplicate()
	malformed[0] = NAN
	bad.heights = malformed
	check(not bad.validate().ok, "resident nonfinite heights fail ingestion validation")
	bad = make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	bad.set("height_data", malformed.to_byte_array())
	check(not bad.validate().ok, "decoded nonfinite heights fail before physics/navigation ingestion")
	bad = make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	bad.set("channel_data", {"broken": "not an array"})
	check(not bad.validate().ok, "malformed serialized channel types reject without a script error")
	bad = make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	var wrong_coverage := PackedFloat32Array(); wrong_coverage.resize(9); wrong_coverage.fill(1.01)
	bad.channel_names = PackedStringArray(["wetness"])
	bad.channels = {"wetness": {"values": bad.heights.duplicate(), "coverage": wrong_coverage}}
	check(not bad.validate().ok, "resident channel coverage outside 0..1 rejects")
	bad = make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	bad.height_max = bad.height_min
	check(not bad.validate().ok, "stored extrema cannot understate actual resident heights")
	bad = make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	check(bad.validate().ok, "payload validated before an intentional in-place edit")
	bad.heights[0] = INF
	check(not bad.validate_payload().ok, "explicit payload revalidation detects in-place array edits")
	bad = make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	var valid_ids := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	var valid_weights := Image.create(2, 2, false, Image.FORMAT_RGBAF); valid_weights.fill(Color(1, 0, 0, 0))
	bad.material_ids = valid_ids; bad.material_weights = valid_weights
	check(bad.validate().ok, "material payload validated before replacement")
	var invalid_ids := valid_ids.duplicate(); invalid_ids.set_pixel(0, 0, Color(32.0 / 255.0, 0, 0, 0))
	bad.material_ids = invalid_ids
	check(not bad.validate().ok, "assigning invalid material IDs invalidates the resident validation cache")
	bad.material_ids = valid_ids
	var invalid_weights := valid_weights.duplicate(); invalid_weights.set_pixel(0, 0, Color(NAN, 0, 0, 0))
	bad.material_weights = invalid_weights
	check(not bad.validate().ok, "assigning nonfinite material weights invalidates the resident validation cache")

	# Renderer handoff in the compile_heightfield() shape, no per-pixel loops.
	var compiled := data.to_compiled_field()
	check(compiled.ok and compiled.image.get_size() == Vector2i(7, 5) and compiled.image.get_format() == Image.FORMAT_RF, "compiled-field handoff")
	near(compiled.image.get_pixel(3, 2).r, data.heights[2 * 7 + 3], 0.0, "handoff image preserves heights")

	# Memory/time for the 4097 x 4097 1 m target: payload sizes and no loops.
	var large := StrataRuntimeData.new()
	large.bounds = Rect2(-2048, -2048, 4096, 4096)
	large.resolution = Vector2i(4097, 4097)
	var started := Time.get_ticks_usec()
	var heights := PackedFloat32Array()
	heights.resize(4097 * 4097)
	large.heights = heights
	check(large.validate().ok, "4097^2 validates")
	var validated_at := Time.get_ticks_usec()
	for repeat in range(100): check(large.validate().ok, "repeated residency validation remains valid")
	print("4097^2 repeated structural validation x100: %.1f ms" % ((Time.get_ticks_usec() - validated_at) / 1000.0))
	var image := large.create_height_image()
	var holes := large.get_hole_image()
	var elapsed := (Time.get_ticks_usec() - started) / 1000.0
	check(large.get_manifest().height_bytes == 4097 * 4097 * 4, "4097^2 heights are 64 MiB")
	check(image.get_size() == Vector2i(4097, 4097) and holes.get_size() == Vector2i(4096, 4096), "large renderer images")
	print("4097^2 allocate+validate+images: %.1f ms, height payload %.1f MiB" % [elapsed, large.get_manifest().height_bytes / 1048576.0])
	started = Time.get_ticks_usec()
	var many := PackedVector2Array()
	for index in range(10000):
		many.append(Vector2(-2000.0 + index * 0.37, 1000.0 - index * 0.11))
	large.sample_heights(many)
	print("10k batch height queries: %.1f ms" % ((Time.get_ticks_usec() - started) / 1000.0))
	finish("RUNTIME_DATA_TEST")
