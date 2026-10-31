extends "res://tests/runtime_test_base.gd"
## StrataRuntimeData (format 2): lattice, statuses, holes, channels, windows, conversions,
## validation and the region plumbing, on small synthetic region grids.

const S := StrataRuntimeData.Status

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	# Rectangular 6 x 4 m grid at 1 m with a negative, fractional origin.
	var data := make_data(Rect2(-10.5, 5.25, 6.0, 4.0), Vector2i(7, 5))
	check(data.validate().ok, "valid fixture: %s" % data.validate())
	near(data.get_spacing(), 1.0, 0.0, "uniform spacing")
	check(data.get_cell_resolution() == Vector2i(6, 4) and data.resolution == Vector2i(7, 5), "cell resolution is width-1 x height-1")
	check(data.grid == Vector2i(1, 1) and data.cells_resolution() == Vector2i(16, 16) and data.get_region(Vector2i.ZERO) != null and data.get_region(Vector2i(1, 0)) == null, "a small terrain is one 16-cell region; cells_resolution is grid * cells")

	# Exact signed values at lattice points.
	var negative_seen := false
	for j in range(5):
		for i in range(7):
			var point := data.bounds.position + Vector2(i, j)
			var sampled := data.sample_height(point)
			check(sampled.status == S.OK, "lattice point %s is OK" % point)
			near(sampled.value, data.get_height_at(Vector2i(i, j)), 0.0, "lattice value exact at %d,%d" % [i, j])
			near(sampled.value, fixture_height(i, j), 0.000001, "lattice value is the fixture height at %d,%d" % [i, j])
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
	var empty := data.duplicate_runtime()
	empty.regions = {}
	check(empty.validate().ok and not empty.is_resident(), "manifest-only data validates")
	check(empty.sample_height(Vector2(-8.0, 6.0)).status == S.NOT_RESIDENT, "missing payload is NOT_RESIDENT")
	var zero := make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3), func(_i: int, _j: int) -> float: return 0.0)
	var zero_sample := zero.sample_height(Vector2(0.5, 1.5))
	check(zero_sample.status == S.OK and zero_sample.value == 0.0, "valid zero height is OK, not absent")

	# Holes: cell (2, 1) and the 2 x 1 block (4..5, 3).
	add_cell_map(data, "holes", [Rect2i(2, 1, 1, 1), Rect2i(4, 3, 2, 1)])
	check(data.validate_payload().ok, "canonical holes validate")
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
	check(data.cell_mask_window("holes", Rect2i(0, 0, 6, 4)) == cell_mask(Vector2i(6, 4), [Rect2i(2, 1, 1, 1), Rect2i(4, 3, 2, 1)]) and data.holes.count(255) == 3, "cell_mask_window assembles the hole cells row-major")
	check(data.cell_mask_window("holes", Rect2i(2, 1, 2, 2)) == PackedByteArray([255, 0, 0, 0]) and data.cell_mask_window("nothing", Rect2i(0, 0, 1, 1)).is_empty() and data.cell_mask_window("holes", Rect2i(10, 10, 20, 20)).is_empty(), "cell windows are exact; unknown maps and out-of-grid rectangles are empty")
	var region_zero := data.get_region(Vector2i.ZERO)
	var broken_levels: Array = region_zero.maps.holes.levels
	var holes_bytes: PackedByteArray = broken_levels[0]
	holes_bytes[0] = 7
	broken_levels[0] = holes_bytes
	check(not data.validate_payload().ok, "non-canonical stored mask is rejected")
	holes_bytes[0] = 0
	broken_levels[0] = holes_bytes
	check(data.validate_payload().ok, "the mask validates again once canonical")

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

	# Channels: defined zero vs absent, signed and unclamped values, coverage.
	add_channel(data, "wetness", func(i: int, _j: int) -> float: return [0.0, -2.5, 7.0][i] if i <= 2 else 0.0, func(i: int, _j: int) -> float: return 1.0 if i <= 2 else 0.0)
	check(data.validate_payload().ok, "channel payload validates: %s" % data.validate())
	var at_zero := data.sample_channel(&"wetness", data.bounds.position + Vector2(0, 2))
	check(at_zero.status == S.OK and at_zero.value == 0.0, "defined zero channel value is OK")
	near(data.sample_channel(&"wetness", data.bounds.position + Vector2(1, 1)).value, -2.5, 0.0, "negative channel value preserved")
	near(data.sample_channel(&"wetness", data.bounds.position + Vector2(2, 0)).value, 7.0, 0.0, "values above 1 stay unclamped")
	near(data.sample_channel(&"wetness", data.bounds.position + Vector2(1.5, 0.5)).value, 2.25, 0.000001, "channel bilinear between defined samples")
	var partial := data.sample_channel(&"wetness", data.bounds.position + Vector2(2.5, 0.5))
	check(partial.status == S.OK and is_equal_approx(partial.value, 7.0) and is_equal_approx(partial.coverage, 0.5), "partially defined cell uses only defined corners: %s" % partial)
	check(data.sample_channel(&"wetness", data.bounds.position + Vector2(5, 2)).status == S.ABSENT, "undefined samples are ABSENT")
	check(data.sample_channel(&"missing", data.bounds.position).status == S.ABSENT, "unknown channel is ABSENT")
	check(data.sample_channel(&"wetness", Vector2(100, 100)).status == S.OUTSIDE, "channel outside bounds")
	var manifest := data.get_manifest()
	var region_height_bytes: int = StrataRegions.map_bytes(16, data.maps.height)
	check(manifest.map_bytes.height == region_height_bytes and region_height_bytes == 21 * 21 * 4 and manifest.channels[0].bytes == 2 * 21 * 21 * 4 and manifest.region_count == 1 and manifest.total_bytes == manifest.region_bytes, "manifest bytes: %s" % manifest)
	check(data.heights_window(Rect2i(0, 0, 6, 4)).size() == 35 and absf(data.heights_window(Rect2i(0, 0, 6, 4))[8] - fixture_height(1, 1)) < 0.000001, "heights_window is (w+1)*(h+1) row-major samples")

	# Channel lookup: has_channel, ok, exact lattice values, TRIANGLE/BILINEAR.
	check(data.has_channel(&"wetness") and not data.has_channel(&"missing"), "has_channel means retained")
	check(data.sample_channel(&"wetness", data.bounds.position).ok and not data.sample_channel(&"missing", data.bounds.position).ok and not data.sample_channel(&"wetness", Vector2(100, 100)).ok, "ok mirrors an OK status")
	# A nonplanar, fully covered channel (the fixture heights, so the height sampler is an
	# independent reference for both interpolations).
	add_channel(data, "relief", fixture_height)
	check(data.validate_payload().ok and data.has_channel(&"relief"), "second channel validates")
	var lattice_exact := true
	for j in range(5):
		for i in range(7):
			for mode in [StrataRuntimeData.Interpolation.TRIANGLE, StrataRuntimeData.Interpolation.BILINEAR]:
				var sampled := data.sample_channel(&"relief", data.bounds.position + Vector2(i, j), mode)
				lattice_exact = lattice_exact and sampled.ok and sampled.value == float(PackedFloat32Array([fixture_height(i, j)])[0]) and sampled.coverage == 1.0
	check(lattice_exact, "sample_channel returns the stored value at every lattice point in both modes")
	var channel_gap := 0.0
	for cell in [Vector2i(0, 0), Vector2i(2, 1), Vector2i(5, 3)]:
		for f in [Vector2(0.25, 0.25), Vector2(0.75, 0.75), Vector2(0.7, 0.2), Vector2(0.2, 0.7), Vector2(0.5, 0.5)]:
			var point: Vector2 = data.bounds.position + Vector2(cell) + f
			var local := data.local_to_lattice(point) - Vector2(cell)
			var triangle: float = data.sample_channel(&"relief", point, StrataRuntimeData.Interpolation.TRIANGLE).value
			var bilinear: float = data.sample_channel(&"relief", point, StrataRuntimeData.Interpolation.BILINEAR).value
			near(triangle, reference_height(data, cell, local), 0.000001, "channel TRIANGLE interpolation cell %s f %s" % [cell, f])
			near(bilinear, data.sample_height(point, StrataRuntimeData.Interpolation.BILINEAR, true).value, 0.000001, "channel BILINEAR interpolation cell %s f %s" % [cell, f])
			check(bilinear == data.sample_channel(&"relief", point).value, "BILINEAR is the default channel interpolation")
			channel_gap = maxf(channel_gap, absf(triangle - bilinear))
	check(channel_gap > 0.25, "the two channel interpolations differ on a nonplanar cell (%s)" % channel_gap)
	var channel_transform := Transform3D(Basis(Vector3.UP, deg_to_rad(-71.0)), Vector3(-30.0, 4.0, 12.5))
	var channel_point := data.bounds.position + Vector2(3.3, 1.7)
	var channel_world := data.sample_channel_world(&"relief", channel_transform * Vector3(channel_point.x, 99.0, channel_point.y), channel_transform, StrataRuntimeData.Interpolation.TRIANGLE)
	check(channel_world.ok, "world channel query OK")
	near(channel_world.value, data.sample_channel(&"relief", channel_point, StrataRuntimeData.Interpolation.TRIANGLE).value, 0.00001, "world channel query maps to terrain-local XZ")
	# Channel maps in other formats decode the way they were quantized.
	var quantized := data.duplicate_runtime()
	var quantized_description := StrataRegions.map(Image.FORMAT_L8, StrataRegions.KIND_SAMPLE, 1, 2)
	var shade_image := Image.create(21, 21, false, Image.FORMAT_L8)
	shade_image.fill(Color(128.0 / 255.0, 0, 0))
	quantized.maps["shade"] = quantized_description
	quantized.channel_names.append("shade")
	(quantized.regions[Vector2i.ZERO] as StrataRegionData).set_image("shade", shade_image, 0, quantized_description)
	near(quantized.sample_channel(&"shade", quantized.bounds.position + Vector2(1.5, 1.5)).value, 128.0 / 255.0, 0.000001, "an L8 channel map reads as byte / 255; no coverage map means defined everywhere")

	# Navigation profile accessors without stored profiles: default = exclusions.
	var D := StrataRuntimeData.DEFAULT_NAV_PROFILE
	check(data.has_nav_profile(D) and not data.has_nav_profile(&"paths") and data.get_nav_profile_names() == [D], "default profile is always present")
	check(data.get_nav_profile_rule(D) == {"exclusion": true} and data.get_nav_profile_mask(D).is_empty() and data.nav_profile_map(D) == "nav_exclusion", "default profile is the nav_exclusion map (none baked here)")
	check(data.is_nav_blocked_cell(Vector2i(2, 1)) and data.is_nav_blocked_cell(Vector2i(2, 1), D) and not data.is_nav_blocked_cell(Vector2i(0, 0)), "holes block the default profile")
	check(data.is_nav_blocked_cell(Vector2i(0, 0), &"paths") and data.get_nav_profile_image(&"paths") == null, "unknown profiles block every cell and have no image")
	var default_image := data.get_nav_profile_image(D)
	check(default_image.get_size() == Vector2i(6, 4) and default_image.get_format() == Image.FORMAT_L8, "profile image is L8 cells")
	add_cell_map(data, "nav_paths", [Rect2i(0, 0, 3, 4)])
	check(not data.validate_payload().ok, "a stored profile map needs its rule")
	data.nav_profile_rules = {D: {"exclusion": true}, &"paths": {"channel": "relief", "min": 0.0}}
	check(data.validate_payload().ok and data.has_nav_profile(&"paths") and data.get_nav_profile_names() == [D, &"paths"], "profile with rule validates: %s" % data.validate())
	check(data.is_nav_blocked_cell(Vector2i(1, 1), &"paths") and not data.is_nav_blocked_cell(Vector2i(3, 1), &"paths") and data.is_nav_blocked_cell(Vector2i(4, 3), &"paths"), "profile cells and holes are blocked for that profile")
	check(data.get_nav_profile_image(&"paths").get_pixel(1, 1).r == 1.0 and data.get_nav_profile_image(&"paths").get_pixel(3, 1).r == 0.0, "profile image marks blocked cells")
	check(data.get_nav_profile_mask(&"paths") == cell_mask(Vector2i(6, 4), [Rect2i(0, 0, 3, 4)]) and data.cell_mask_window("nav_paths", Rect2i(2, 0, 2, 1)) == PackedByteArray([255, 0]), "profile masks assemble from the region maps")
	var profile_manifest := data.get_manifest()
	check(profile_manifest.nav_profiles.size() == 2 and profile_manifest.nav_profiles[1].map == "nav_paths" and profile_manifest.map_bytes.nav_paths == 20 * 20, "manifest lists profiles and counts their bytes: %s" % [profile_manifest.nav_profiles])
	var without_rule := data.duplicate_runtime()
	without_rule.nav_profile_rules = {D: {"exclusion": true}}
	check(not without_rule.validate().ok, "a profile map without a rule is rejected")
	var without_map := data.duplicate_runtime()
	without_map.maps.erase("nav_paths")
	check(not without_map.validate().ok, "a rule without its map is rejected")
	var rule_bytes := StrataRuntimeData.new()
	rule_bytes.set("nav_profile_rule_data", var_to_bytes([1, 2]))
	check(not rule_bytes.validate().ok, "malformed stored profile rules fail validation")

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

	# Several regions: queries, windows and edges across region borders (16-cell regions on a
	# 40 x 24 m terrain: a 3 x 2 grid whose last column and row extend past the bounds).
	var wide := make_data(Rect2(-20.0, -12.0, 40.0, 24.0), Vector2i(41, 25))
	add_cell_map(wide, "holes", [Rect2i(15, 15, 2, 2), Rect2i(38, 22, 2, 2)])
	check(wide.validate().ok and wide.grid == Vector2i(3, 2) and wide.regions.size() == 6 and wide.cells_resolution() == Vector2i(48, 32) and wide.get_cell_resolution() == Vector2i(40, 24), "a 40 x 24 m terrain is a 3 x 2 grid of 16-cell regions: %s" % wide.validate())
	var cross_ok := true
	for j in range(25):
		for i in range(41):
			var sampled := wide.sample_height(Vector2(-20.0 + i, -12.0 + j), StrataRuntimeData.Interpolation.TRIANGLE, true)
			cross_ok = cross_ok and sampled.status == S.OK and absf(sampled.value - fixture_height(i, j)) <= 0.0000005 and absf(wide.get_height_at(Vector2i(i, j)) - fixture_height(i, j)) <= 0.0000005
	check(cross_ok, "every lattice sample is exact across region borders and at the far edge")
	var window := wide.heights_window(Rect2i(10, 10, 12, 8))
	var window_ok := window.size() == 13 * 9
	for j in range(9):
		for i in range(13): window_ok = window_ok and absf(window[j * 13 + i] - fixture_height(10 + i, 10 + j)) <= 0.0000005
	check(window_ok, "heights_window assembles samples across four regions using the shared edges")
	check(wide.heights_window(Rect2i(0, 0, 40, 24)).size() == 41 * 25 and wide.heights_window(Rect2i(0, 0, 48, 32)).size() == 49 * 33 and wide.heights_window(Rect2i(0, 0, 49, 32)).is_empty(), "windows may cover the whole grid but not leave it")
	check(wide.is_hole_cell(Vector2i(15, 15)) and wide.is_hole_cell(Vector2i(16, 16)) and not wide.is_hole_cell(Vector2i(14, 15)) and wide.is_hole_cell(Vector2i(39, 23)), "hole cells resolve in their own region")
	var corner_hole := wide.cell_mask_window("holes", Rect2i(14, 14, 4, 4))
	check(corner_hole == cell_mask(Vector2i(4, 4), [Rect2i(1, 1, 2, 2)]), "a cell window crossing four regions assembles the right cells")
	check(wide.is_hole_at(Vector2(-4.0, 4.0)) and wide.sample_height(Vector2(-4.5, 3.5)).status == S.HOLE and wide.sample_height(Vector2(-4.5, 3.5), 0, true).status == S.OK, "holes across a region corner are holes")
	check(wide.get_hole_image().get_size() == Vector2i(40, 24) and wide.get_hole_image().get_pixel(39, 23).r == 1.0, "the hole image spans the terrain's own cells, not the grid")
	var gapped := wide.duplicate_runtime()
	gapped.regions.erase(Vector2i(1, 1))
	check(not gapped.validate().ok and gapped.sample_height(Vector2(-2.5, 5.5)).status == S.NOT_RESIDENT, "a missing embedded region fails validation and does not sample")
	var tampered := wide.duplicate_runtime()
	var tampered_region: StrataRegionData = tampered.regions[Vector2i(2, 1)]
	tampered_region.maps.height.levels[0] = tampered_region.maps.height.levels[0].slice(4)
	check(not tampered.validate_payload().ok, "wrong height byte count rejects")

	# External regions: save every region, load the manifest, compare, and a missing file.
	var directory := "user://runtime_data_test"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	for xy in wide.regions:
		ResourceSaver.save(wide.regions[xy], directory.path_join("region_%d_%d.res" % [xy.x, xy.y]))
	var external := wide.duplicate_runtime()
	external.regions = {}
	external.region_directory = directory
	check(external.validate(true).ok and external.is_resident() and external.payload_bytes() == wide.payload_bytes(), "external manifest validates deeply: %s" % external.validate(true))
	check(external.heights_window(Rect2i(0, 0, 40, 24)) == wide.heights_window(Rect2i(0, 0, 40, 24)) and external.sample_height(Vector2(-4.5, 3.5)).status == S.HOLE and external.get_region(Vector2i(0, 0)) == external.get_region(Vector2i(0, 0)), "external regions load on demand, are cached and sample identically")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(directory.path_join("region_1_1.res")))
	var missing := wide.duplicate_runtime()
	missing.regions = {}
	missing.region_directory = directory
	check(missing.sample_height(Vector2(-20.5 + 1.0, -11.5)).status == S.OK and missing.sample_height(Vector2(-2.5, 5.5)).status == S.NOT_RESIDENT and not missing.validate(true).ok, "a missing region file is NOT_RESIDENT, not a crash")
	for xy in wide.regions:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(directory.path_join("region_%d_%d.res" % [xy.x, xy.y])))

	# Validation rejects inconsistent payloads.
	var bad := make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	bad.format_version = 99
	check(not bad.validate().ok, "unknown format version rejected")
	bad = make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	bad.format_version = 1
	check(not bad.validate().ok and "bake the terrain again" in bad.validate().message, "format 1 is not migrated: %s" % bad.validate().message)
	bad = make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	var malformed := PackedFloat32Array(); malformed.resize(21 * 21); malformed[0] = NAN
	(bad.regions[Vector2i.ZERO] as StrataRegionData).maps.height.levels[0] = malformed.to_byte_array()
	check(not bad.validate_payload().ok, "resident nonfinite heights fail ingestion validation")
	bad = make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	bad.set("lattice_data", PackedByteArray([1, 2, 3]))
	check(not bad.validate().ok, "a malformed stored lattice header fails before any consumer")
	bad = make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	add_channel(bad, "wetness", func(_i: int, _j: int) -> float: return 0.5, func(_i: int, _j: int) -> float: return 1.01)
	check(not bad.validate_payload().ok, "resident channel coverage outside 0..1 rejects")
	bad = make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	bad.height_max = bad.height_min
	check(not bad.validate().ok, "stored extrema cannot understate actual resident heights")
	bad = make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	bad.region_extrema = PackedFloat64Array()
	check(not bad.validate().ok, "per-region extrema must match the grid")
	bad = make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	check(bad.validate().ok, "payload validated before an intentional in-place edit")
	var edited: PackedByteArray = (bad.regions[Vector2i.ZERO] as StrataRegionData).maps.height.levels[0]
	edited.encode_float(8, INF)
	(bad.regions[Vector2i.ZERO] as StrataRegionData).maps.height.levels[0] = edited
	check(bad.validate().ok and not bad.validate_payload().ok, "explicit payload revalidation detects in-place edits")
	bad = make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	bad.grid = Vector2i(2, 2)
	check(not bad.validate().ok, "a grid that does not match the bounds rejects")
	bad = make_data(Rect2(0, 0, 2, 2), Vector2i(3, 3))
	bad.maps.erase("height")
	check(not bad.validate().ok, "a manifest without a height map rejects")

	# Renderer handoff in the compile_heightfield() shape.
	var compiled := data.to_compiled_field()
	check(compiled.ok and compiled.image.get_size() == Vector2i(7, 5) and compiled.image.get_format() == Image.FORMAT_RF, "compiled-field handoff")
	near(compiled.image.get_pixel(3, 2).r, fixture_height(3, 2), 0.0000005, "handoff image preserves heights")
	check(compiled.bounds == data.bounds and compiled.min == data.height_min and compiled.max == data.height_max and compiled.sample_step_x == Vector3(1, 0, 0), "handoff carries bounds, extrema and steps")

	# The 4 km / 1 m target as a 16 x 16 grid of 256-cell regions, flat heights shared between
	# regions: validation, adapters, batch queries and a three-term navigation profile.
	var started := Time.get_ticks_usec()
	var large := StrataRuntimeData.new()
	large.bounds = Rect2(-2048, -2048, 4096, 4096)
	large.spacing = 1.0
	large.cells = 256
	large.apron = 2
	large.grid = Vector2i(16, 16)
	large.maps = {"height": StrataRegions.map(Image.FORMAT_RF, StrataRegions.KIND_SAMPLE, 1, 2), "nav_exclusion": StrataRegions.map(Image.FORMAT_L8, StrataRegions.KIND_CELL, 1, 2), "footpath": StrataRegions.map(Image.FORMAT_RF, StrataRegions.KIND_SAMPLE, 1, 2)}
	large.channel_names = PackedStringArray(["footpath"])
	var flat := Image.create(261, 261, false, Image.FORMAT_RF)
	var strip := Image.create(261, 261, false, Image.FORMAT_RF)
	# Path samples x 2000..2007 of the whole lattice are texels 210..217 of region column 7.
	strip.fill_rect(Rect2i(210, 0, 8, 261), Color(1, 0, 0))
	var none := Image.create(260, 260, false, Image.FORMAT_L8)
	var excluded := Image.create(260, 260, false, Image.FORMAT_L8)
	# Cells 2000..2007 x 1000..1015: region (7, 3), local cell 208.., row 232.. plus apron.
	excluded.fill_rect(Rect2i(210, 234, 8, 16), Color(1, 1, 1))
	var template := StrataRegionData.new()
	template.cells = 256
	template.apron = 2
	template.spacing = 1.0
	var extrema := PackedFloat64Array()
	for y in range(16):
		for x in range(16):
			var region := StrataRegionData.new()
			region.region = Vector2i(x, y)
			region.cells = 256
			region.apron = 2
			region.spacing = 1.0
			region.origin = Vector2(-2048 + x * 256, -2048 + y * 256)
			region.set_image("height", flat, 0, large.maps.height)
			region.set_image("footpath", strip if x == 7 else flat, 0, large.maps.footpath)
			region.set_image("nav_exclusion", excluded if x == 7 and y == 3 else none, 0, large.maps.nav_exclusion)
			large.regions[Vector2i(x, y)] = region
			extrema.append_array(PackedFloat64Array([0.0, 0.0]))
	large.region_extrema = extrema
	var built_ms := (Time.get_ticks_usec() - started) / 1000.0
	started = Time.get_ticks_usec()
	var large_valid := large.validate()
	check(large_valid.ok, "4 km grid validates: %s" % large_valid)
	var validated_at := Time.get_ticks_usec()
	for repeat in range(100): check(large.validate().ok, "repeated residency validation remains valid")
	print("4 km grid (256 regions) build %.0f ms, first validation %.0f ms, repeated structural validation x100: %.1f ms" % [built_ms, (validated_at - started) / 1000.0, (Time.get_ticks_usec() - validated_at) / 1000.0])
	started = Time.get_ticks_usec()
	var image := large.create_height_image()
	var holes_image := large.get_hole_image()
	var elapsed := (Time.get_ticks_usec() - started) / 1000.0
	check(large.get_manifest().region_bytes == 261 * 261 * 8 + 260 * 260 and large.payload_bytes() == 256 * (261 * 261 * 8 + 260 * 260), "region payload sizes follow the geometry: %s" % large.get_manifest().region_bytes)
	check(image.get_size() == Vector2i(4097, 4097) and holes_image.get_size() == Vector2i(4096, 4096) and holes_image.get_data().count(255) == 0, "large adapters assemble 4097^2 heights and an all-solid 4096^2 hole image")
	print("4097^2 height adapter assembly: %.1f ms" % elapsed)
	started = Time.get_ticks_usec()
	var many := PackedVector2Array()
	for index in range(10000):
		many.append(Vector2(-2000.0 + index * 0.37, 1000.0 - index * 0.11))
	large.sample_heights(many)
	print("10k batch height queries: %.1f ms" % ((Time.get_ticks_usec() - started) / 1000.0))
	started = Time.get_ticks_usec()
	var window_started := Time.get_ticks_usec()
	var big_window := large.heights_window(Rect2i(0, 0, 4096, 4096))
	check(big_window.size() == 4097 * 4097, "the full lattice window assembles")
	print("full-lattice heights_window: %.1f ms" % ((Time.get_ticks_usec() - window_started) / 1000.0))
	big_window = PackedFloat32Array()
	var huge := Image.create(4097, 4097, false, Image.FORMAT_RF)
	huge = null
	var rule := {"all": [{"channel": "footpath", "min": 0.5}, {"slope_max": 35.0}, {"exclusion": true}]}
	var blocked := 0
	var evaluate_ms := 0.0
	for y in range(16):
		for x in range(16):
			var region := large.get_region(Vector2i(x, y))
			var evaluated := StrataNavProfiles.evaluate_region_checked(region, rule, large.channel_names)
			check(evaluated.ok, "region %d,%d evaluates" % [x, y])
			if not evaluated.ok: continue
			blocked += StrataNavProfiles._interior_count(evaluated.mask, region)
			evaluate_ms += evaluated.ms
	# Path samples x 2000..2007: cells 1999..2007 have a corner on it, 2000..2006 a mean of 1,
	# 1999 and 2007 a mean of 0.5; 8 x 16 of them are excluded.
	check(blocked == 4096 * 4096 - 9 * 4096 + 8 * 16, "4 km three-term profile over 256 regions: %d blocked" % blocked)
	print("4 km three-term navigation profile over 256 regions: %.0f ms evaluate (%.0f ms wall)" % [evaluate_ms, (Time.get_ticks_usec() - started) / 1000.0])
	finish("RUNTIME_DATA_TEST")
