extends SceneTree
## Native dense transport/composition regressions. Pass -- --large for 4km data.

var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	run.call_deferred()

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func rf(size: Vector2i, value: float) -> Image:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RF)
	image.fill(Color(value, 0, 0, 1))
	return image

func payload(name: String, image: Image, origin: Vector3, sx: Vector3, sy: Vector3, owner: Image = null) -> Dictionary:
	return {"name": name, "image": image, "sample_origin": origin, "sample_step_x": sx, "sample_step_y": sy, "ownership": owner}

func descriptor(data: StrataLayerData, origin: Vector3, sx: Vector3, sy: Vector3, mode: int = 0, offset: float = 0.0) -> Dictionary:
	return {"data": data, "origin": origin, "step_x": sx, "step_y": sy, "mode": mode, "height_offset": offset}

func run() -> void:
	check_bulk_ownership()
	check_mixed_grids()
	check_region_scale_windows()
	check_region_scale_cell_mask_windows()
	print("TERRAIN_BULK checks=%d failures=%d" % [checks, failures.size()])
	if OS.get_cmdline_user_args().has("--large"):
		check_large_grid()
	if failures.is_empty():
		print("HEGO_TERRAIN_BULK_PASS")
		quit(0)
	else:
		push_error("%d bulk data test(s) failed" % failures.size())
		quit(1)

func check_bulk_ownership() -> void:
	var image := rf(Vector2i(3, 3), 0)
	var owner := rf(Vector2i(3, 3), 0)
	for y in range(3):
		for x in range(3): image.set_pixel(x, y, Color(10 * y + x, 0, 0, 1))
	for p in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 2), Vector2i(2, 2)]: owner.set_pixelv(p, Color(1, 0, 0, 1))
	image.set_pixel(1, 1, Color(-17, 0, 0, 1))
	image.set_pixel(2, 0, Color(37, 0, 0, 1))
	var validation := StrataLayerData.validate_dense(image, owner)
	check(validation.ok and validation.samples == 9 and validation.owned_count == 4 and validation.min == -17 and validation.max == 37, "native image validation returns extrema over all pixels, including unowned values")
	var data := StrataLayerData.new()
	data.set_sample(&"height", Vector2i(500, 500), 999)
	var revision := data.get_revision()
	check(data.replace_dense(&"height", Vector2i(-257, -257), image, owner), "bulk replacement accepts explicit binary ownership")
	check(data.get_revision() == revision + 1 and not data.has_sample(&"height", Vector2i(500, 500)), "one atomic bulk replacement emits one revision and removes old channel contents")
	check(data.has_sample(&"height", Vector2i(-257, -257)) and data.get_sample(&"height", Vector2i(-257, -257)) == 0.0, "owned zero survives bulk import")
	check(not data.has_sample(&"height", Vector2i(-255, -257)), "unowned nonzero input values do not invent ownership")
	check(data.get_owned_rect(&"height") == Rect2i(-257, -257, 3, 3), "owned bounds span four negative tile corners exactly")
	var exported := data.read_dense(&"height", Vector2i(-258, -258), Vector2i(5, 5))
	check(exported.ok and exported.owned_count == 4 and exported.ownership.get_pixel(1, 1).r == 1.0, "bulk export preserves exact binary support with unowned padding")
	revision = data.get_revision()
	check(data.replace_dense(&"height", Vector2i(-257, -257), image, owner) and data.get_revision() == revision, "identical accepted bulk replacement does not advance revision")
	image.fill(Color(777, 0, 0, 1))
	exported.image.fill(Color(888, 0, 0, 1))
	check(data.get_sample(&"height", Vector2i(-255, -255)) == 22.0, "caller and exported images cannot mutate native storage")
	owner.set_pixel(1, 1, Color(0.5, 0, 0, 1))
	check(not data.replace_dense(&"height", Vector2i.ZERO, image, owner) and data.get_revision() == revision, "nonbinary bulk ownership fails without partial mutation")
	image.set_pixel(0, 0, Color(NAN, 0, 0, 1))
	check(not data.replace_dense(&"height", Vector2i.ZERO, image) and data.get_revision() == revision, "nonfinite dense values fail atomically")
	var thin := rf(Vector2i(1, 420000), 1)
	check(not data.replace_dense(&"height", Vector2i.ZERO, thin) and data.get_revision() == revision, "thin fields cannot bypass the preallocation native tile-memory budget")
	check(not StrataLayerData.compose_dense([], &"height", Vector3.ZERO, Vector3.RIGHT, Vector3.BACK, Vector2i(100000, 100000), Rect2(0, 0, 1, 1)).ok, "oversized composition rejects before allocating")

func check_mixed_grids() -> void:
	var terrain := StrataTerrain3D.new()
	root.add_child(terrain)
	terrain.set_preview_enabled(false)
	terrain.base_bounds = Rect2(0, 0, 4, 4)
	var base := StrataLayer.new()
	var edits := StrataLayer.new()
	terrain.add_child(base); terrain.add_child(edits)
	base.procedural_fields = {"height": StrataFieldData.from_field(payload("height", rf(Vector2i(3, 3), 10), Vector3(0, 5, 0), Vector3(2, 0, 0), Vector3(0, 0, 2)))}
	var value := rf(Vector2i(2, 2), -2)
	var owner := rf(Vector2i(2, 2), 0)
	owner.set_pixel(0, 0, Color(1, 0, 0, 1))
	edits.procedural_fields = {"height": StrataFieldData.from_field(payload("height", value, Vector3(1, 0, 1), Vector3.RIGHT, Vector3.BACK, owner)), "mask": StrataFieldData.from_field(payload("mask", rf(Vector2i(4, 2), 0.25), Vector3(3, 0, 0), Vector3.BACK, Vector3(-2, 0, 0)))}
	edits.set_composition(&"height", StrataLayer.Composition.ADD)
	var compiled := StrataProcedural.compile_heightfield(terrain, null, 0.5, {"include_coverage": true})
	check(compiled.ok and compiled.resolution == Vector2i(9, 9), "bulk compiler includes both endpoints and returns its actual native resolution")
	if compiled.ok:
		for y in range(9):
			for x in range(9):
				var p := Vector2(x, y) * 0.5
				check(absf(compiled.image.get_pixel(x, y).r - terrain.sample_height(p)) < 0.00001, "native mixed-grid Replace/Add/datum result matches point sampling")
		check(compiled.min == 13.0 and compiled.max == 15.0, "native compiler min/max includes Add deltas and height datum")
		check(StrataProcedural.token_is_current(compiled.token), "compiled image carries a current cumulative revision token")
	var snapshot := StrataProcedural.create_snapshot(edits, "cumulative", {"channels": PackedStringArray(["height", "mask"])})
	check(snapshot.ok, "bulk cumulative snapshots support independent rotated channel grids")
	if snapshot.ok:
		for field: Dictionary in snapshot.fields:
			if field.name.ends_with("__ownership"): continue
			for y in range(field.image.get_height()):
				for x in range(field.image.get_width()):
					var world: Vector3 = field.sample_origin + field.sample_step_x * x + field.sample_step_y * y
					var expected := terrain.sample_channel(StringName(field.name), Vector2(world.x, world.z), edits)
					if field.name == "height": expected -= field.sample_origin.y
					check(absf(field.image.get_pixel(x, y).r - expected) < 0.00001, "native snapshot matches point composition on each channel's physical lattice")
	var raw := StrataProcedural.create_snapshot(edits, "raw", {"channels": PackedStringArray(["height"])})
	check(raw.ok and raw.fields[0].image.get_size() == Vector2i(2, 2) and raw.fields[1].image.get_pixel(1, 1).r == 0.0, "raw snapshots preserve native resolution and binary ownership independently")
	if compiled.ok:
		edits.procedural_fields["height"].data.set_sample(&"height", Vector2i.ZERO, -3)
		check(not StrataProcedural.token_is_current(compiled.token), "later source edits invalidate compiled revision tokens")
	terrain.free()

func memory_kib(field: String) -> int:
	var file := FileAccess.open("/proc/self/status", FileAccess.READ)
	var contents := file.get_buffer(65536).get_string_from_utf8() if file != null else ""
	for line in contents.split("\n"):
		if line.begins_with(field + ":"):
			return int(line.trim_prefix(field + ":").strip_edges().split(" ", false)[0])
	return 0

func check_large_grid() -> void:
	var rss_before := memory_kib("VmRSS")
	var terrain := StrataTerrain3D.new()
	root.add_child(terrain); terrain.set_preview_enabled(false)
	terrain.base_bounds = Rect2(-2048, -2048, 4096, 4096)
	var base := StrataLayer.new()
	var fine := StrataLayer.new()
	var manual := StrataLayer.new()
	terrain.add_child(base); terrain.add_child(fine); terrain.add_child(manual)
	var start := Time.get_ticks_usec()
	base.procedural_fields = {"height": StrataFieldData.from_field(payload("height", rf(Vector2i(513, 513), 10), Vector3(-2048, 0, -2048), Vector3(8, 0, 0), Vector3(0, 0, 8)))}
	fine.procedural_fields = {"height": StrataFieldData.from_field(payload("height", rf(Vector2i(2049, 2049), 2), Vector3(-2048, 0, -2048), Vector3(2, 0, 0), Vector3(0, 0, 2)))}
	fine.set_composition(&"height", StrataLayer.Composition.ADD)
	manual.data.sample_spacing = 2.0
	manual.data.set_sample(&"height", Vector2i(50, 50), 20)
	var import_ms := float(Time.get_ticks_usec() - start) / 1000.0
	check(fine.procedural_fields["height"] != null and fine.procedural_fields["height"].data.get_revision() == 1, "2049² dense field imports in one native revision")
	start = Time.get_ticks_usec()
	var snapshot := StrataProcedural.create_snapshot(fine, "cumulative", {"channels": PackedStringArray(["height"])})
	var snapshot_ms := float(Time.get_ticks_usec() - start) / 1000.0
	check(snapshot.ok and snapshot.fields[0].image.get_size() == Vector2i(2049, 2049), "native cumulative transport supports a complete 4km field at 2m")
	snapshot.clear()
	start = Time.get_ticks_usec()
	var compiled := StrataProcedural.compile_heightfield(terrain, null, 1.0)
	var compile_ms := float(Time.get_ticks_usec() - start) / 1000.0
	check(compiled.ok and compiled.resolution == Vector2i(4097, 4097), "native runtime compilation supports all 16,785,409 samples at 1m")
	if compiled.ok:
		check(compiled.image.get_pixel(0, 0).r == 12 and compiled.image.get_pixel(4096, 4096).r == 12, "large compiled corners reconstruct coarse and fine fields exactly")
		check(compiled.image.get_pixel(2148, 2148).r == 20 and compiled.image.get_pixel(2149, 2148).r == 16 and compiled.image.get_pixel(2149, 2149).r == 14, "large runtime preserves authored samples and bilinear binary-ownership influence")
		check(compiled.min == 12 and compiled.max == 20 and not compiled.has("coverage"), "runtime compilation omits an unnecessary 64 MiB coverage image")
	print("BULK_4KM import_ms=%.1f snapshot_2m_ms=%.1f compile_1m_ms=%.1f rss_delta_mib=%.1f peak_rss_mib=%.1f" % [import_ms, snapshot_ms, compile_ms, float(memory_kib("VmRSS") - rss_before) / 1024.0, float(memory_kib("VmHWM")) / 1024.0])
	terrain.free()


func region_layer(spacing: float, seed_value: int, blocks: Array, scattered: Array) -> StrataLayerData:
	var data := StrataLayerData.new()
	data.sample_spacing = spacing
	for block: Array in blocks:
		var origin: Vector2i = block[0]
		var size: Vector2i = block[1]
		var image := Image.create(size.x, size.y, false, Image.FORMAT_RF)
		var owner := Image.create(size.x, size.y, false, Image.FORMAT_RF)
		for y in range(size.y):
			for x in range(size.x):
				image.set_pixel(x, y, Color(sin(float(x + seed_value) * 0.05) * 4.0 + cos(float(y) * 0.07) + seed_value, 0, 0, 1))
				owner.set_pixel(x, y, Color(1.0 if (x * 7 + y * 3) % 11 != 0 else 0.0, 0, 0, 1))
		data.patch_dense(&"height", origin, image, owner)
	for p: Vector2i in scattered:
		data.set_sample(&"height", p, float(p.x % 13) - 5.0 + seed_value)
	return data

func same_window(full: Image, window: Image, offset: Vector2i) -> bool:
	return full.get_region(Rect2i(offset, window.get_size())).get_data() == window.get_data()

func check_region_scale_windows() -> void:
	# A 4097 lattice (16.8 M texels) with sparse owned data: the 261 window used for a
	# 256-cell region plus an apron of 2 equals the same rectangle of the whole composition.
	var base := region_layer(1.0, 1, [[Vector2i(3000, 3100), Vector2i(1000, 900)]], [Vector2i(5, 5), Vector2i(4095, 4095), Vector2i(2000, 3900)])
	var add := region_layer(1.0, 2, [[Vector2i(3600, 3500), Vector2i(430, 430)]], [Vector2i(3700, 3700), Vector2i(4096, 100)])
	var layers: Array = [
		descriptor(base, Vector3(-0.37, 0, 0.21), Vector3.RIGHT, Vector3.BACK, 0),
		descriptor(add, Vector3(0.5, 0, -0.5), Vector3.RIGHT, Vector3.BACK, 1),
	]
	var size := Vector2i(4097, 4097)
	var bounds := Rect2(0, 0, 4096, 4096)
	var full := StrataLayerData.compose_dense(layers, &"height", Vector3.ZERO, Vector3.RIGHT, Vector3.BACK, size, bounds, true, 0.0)
	check(full.ok and full.image.get_size() == size, "4097 lattice composes in full")
	for offset: Vector2i in [Vector2i(3700, 3650), Vector2i(3836, 3836), Vector2i(0, 0), Vector2i(3198, 3098)]:
		var window := StrataLayerData.compose_dense(layers, &"height", Vector3.ZERO, Vector3.RIGHT, Vector3.BACK, Vector2i(261, 261), bounds, true, 0.0, offset)
		check(window.ok and same_window(full.image, window.image, offset), "261 window at %s equals the full composition (values)" % offset)
		check(window.ok and same_window(full.coverage, window.coverage, offset), "261 window at %s equals the full composition (coverage)" % offset)
	# Replace layer alone and Add layer alone, plus a datum, bit identical as well.
	for single in [[layers[0]], [layers[1]]]:
		var full_single := StrataLayerData.compose_dense(single, &"height", Vector3.ZERO, Vector3.RIGHT, Vector3.BACK, size, bounds, false, 1.5)
		var window_single := StrataLayerData.compose_dense(single, &"height", Vector3.ZERO, Vector3.RIGHT, Vector3.BACK, Vector2i(261, 261), bounds, false, 1.5, Vector2i(3700, 3650))
		check(full_single.ok and window_single.ok and same_window(full_single.image, window_single.image, Vector2i(3700, 3650)), "single-mode window with datum equals the full composition")
	var inside := StrataLayerData.compose_dense(layers, &"height", Vector3.ZERO, Vector3.RIGHT, Vector3.BACK, Vector2i(261, 261), bounds, false, 0.0, Vector2i(3700, 3650))
	check(inside.ok and inside.max > inside.min, "the checked window actually contains data")
	# A negative offset addresses lattice points before the origin (a region's apron) and must
	# equal the full lattice composed from a shifted origin.
	var shifted: Dictionary = StrataLayerData.compose_dense(layers, &"height", Vector3(-2, 0, -2), Vector3.RIGHT, Vector3.BACK, Vector2i(261, 261), bounds, false, 0.0)
	var negative: Dictionary = StrataLayerData.compose_dense(layers, &"height", Vector3.ZERO, Vector3.RIGHT, Vector3.BACK, Vector2i(261, 261), bounds, false, 0.0, Vector2i(-2, -2))
	check(negative.ok and shifted.ok and negative.image.get_data() == shifted.image.get_data(), "a negative window offset composes the apron before the origin bit-identically")
	check(not StrataLayerData.compose_dense(layers, &"height", Vector3.ZERO, Vector3.RIGHT, Vector3.BACK, Vector2i(261, 261), bounds, false, 0.0, Vector2i(-30000000, 0)).ok, "window offsets beyond the dense budget are rejected")

func mask_source(data: StrataLayerData) -> Dictionary:
	return {"data": data, "origin": Vector3.ZERO, "step_x": Vector3.RIGHT, "step_y": Vector3.BACK, "mode": 0}

func check_region_scale_cell_mask_windows() -> void:
	# compile_cell_mask needs no extra argument for a window: passing the window's bounds and
	# its vertex resolution gives the matching cells of the full mask (cell size must be exact).
	var lower := StrataLayerData.new()
	var upper := StrataLayerData.new()
	for y in range(3400, 3416):
		for x in range(3300, 3321): lower.set_sample(&"hole", Vector2i(x, y), 1.0)
	for y in range(3650, 3661):
		for x in range(3700, 3707): lower.set_sample(&"hole", Vector2i(x, y), 1.0)
	lower.set_sample(&"hole", Vector2i(3591, 3591), 1.0)
	for y in range(3652, 3655):
		for x in range(3702, 3704): upper.set_sample(&"hole", Vector2i(x, y), 0.0)
	var layers: Array = [mask_source(lower), mask_source(upper)]
	var full := StrataLayerData.compile_cell_mask(layers, &"hole", Rect2(0, 0, 4096, 4096), Vector2i(4097, 4097))
	check(full.ok and full.cells == Vector2i(4096, 4096) and full.count > 0, "full 4096-cell mask compiles")
	for first: Vector2i in [Vector2i(3582, 3582), Vector2i(3198, 3298), Vector2i(0, 0), Vector2i(3800, 3800)]:
		var window := StrataLayerData.compile_cell_mask(layers, &"hole", Rect2(Vector2(first), Vector2(260, 260)), Vector2i(261, 261))
		var equal: bool = window.ok and window.cells == Vector2i(260, 260)
		var count := 0
		for y in range(260):
			for x in range(260):
				var full_cell: int = full.mask[(first.y + y) * 4096 + first.x + x]
				var window_cell: int = 0 if window.mask.is_empty() else window.mask[y * 260 + x]
				if window_cell == 255: count += 1
				if full_cell != window_cell: equal = false
		check(equal and count == window.count, "cell mask window at %s equals the matching cells of the full mask (%d holes)" % [first, count])
	var holes_in_window := StrataLayerData.compile_cell_mask(layers, &"hole", Rect2(3582, 3582, 260, 260), Vector2i(261, 261))
	check(holes_in_window.count > 0 and holes_in_window.count < full.count, "the cell mask window contains part of the holes, with the upper Solid restoring some")
