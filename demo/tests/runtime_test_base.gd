extends SceneTree
## Shared checks for runtime_* suites. Uses only runtime scripts, so it also
## runs in the runtime-only roundtrip project.

var failures: Array[String] = []
var checks := 0

func _init() -> void:
	_start_watchdog.call_deferred()

func _start_watchdog() -> void:
	create_timer(120.0).timeout.connect(func() -> void:
		push_error("Runtime suite watchdog expired before finish()")
		quit(124))

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func near(actual: float, expected: float, tolerance: float, message: String) -> void:
	check(is_finite(actual) and absf(actual - expected) <= tolerance, "%s (got %s, expected %s, tolerance %s)" % [message, actual, expected, tolerance])

func finish(name: String) -> void:
	print("%s: %s (%d checks, %d failures)" % [name, "PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	for failure in failures.slice(0, 40):
		print("  FAILED: ", failure)
	quit(0 if failures.is_empty() else 1)

## Deterministic, nonplanar, signed fixture height for lattice sample (i, j).
static func fixture_height(i: int, j: int) -> float:
	return 3.0 * sin(i * 0.7) + 2.0 * cos(j * 1.3) - 1.5 + float((i * 7 + j * 13) % 5) * 0.4

## A format 2 manifest with embedded regions holding the heights of height_fn(i, j) on a
## [param resolution] lattice over [param bounds] (spacing must be uniform). Samples past the
## lattice edge repeat the edge sample. Extrema are consistent, so the data validates.
static func make_data(bounds: Rect2, resolution: Vector2i, height_fn: Callable = fixture_height, region_cells: int = 16, apron: int = StrataRegions.DEFAULT_APRON) -> StrataRuntimeData:
	var spacing := bounds.size.x / float(resolution.x - 1)
	var spec := StrataRegions.standard_spec(bounds, spacing, region_cells, apron)
	var maps: Dictionary = spec.maps
	for name in [StrataRegions.MAP_MATERIAL_IDS, StrataRegions.MAP_MATERIAL_WEIGHTS, StrataRegions.MAP_HOLES, StrataRegions.MAP_MACRO]:
		maps.erase(name)
	var data := StrataRuntimeData.new()
	data.bounds = bounds
	data.spacing = spacing
	data.cells = region_cells
	data.apron = apron
	data.grid = StrataRegions.grid_size(spec)
	data.maps = maps
	var side := region_cells + 1 + 2 * apron
	for ry in range(data.grid.y):
		for rx in range(data.grid.x):
			var region := StrataRegionData.new()
			region.region = Vector2i(rx, ry)
			region.cells = region_cells
			region.apron = apron
			region.spacing = spacing
			region.origin = StrataRegions.region_origin(spec, region.region)
			var floats := PackedFloat32Array()
			floats.resize(side * side)
			for v in range(side):
				for u in range(side):
					var i := clampi(rx * region_cells + u - apron, 0, resolution.x - 1)
					var j := clampi(ry * region_cells + v - apron, 0, resolution.y - 1)
					floats[v * side + u] = height_fn.call(i, j)
			region.set_image("height", Image.create_from_data(side, side, false, Image.FORMAT_RF, floats.to_byte_array()), 0, maps.height)
			data.regions[region.region] = region
	finish_data(data)
	return data

## Adds (or replaces) a cell map on every region of an embedded manifest: [param marked] are
## Rect2i cell rectangles in terrain cells, set to 255. Name: holes, nav_exclusion, nav_<profile>.
static func add_cell_map(data: StrataRuntimeData, name: String, marked: Array) -> void:
	var description := StrataRegions.map(Image.FORMAT_L8, StrataRegions.KIND_CELL, 1, data.apron)
	data.maps[name] = description
	var side := data.cells + 2 * data.apron
	for xy in data.regions:
		var bytes := PackedByteArray()
		bytes.resize(side * side)
		for rect in marked:
			var area: Rect2i = rect
			for z in range(area.position.y, area.end.y):
				for x in range(area.position.x, area.end.x):
					var local: Vector2i = Vector2i(x, z) - (xy as Vector2i) * data.cells + Vector2i.ONE * data.apron
					if local.x >= 0 and local.y >= 0 and local.x < side and local.y < side: bytes[local.y * side + local.x] = StrataRuntimeData.MASK_SET
		(data.regions[xy] as StrataRegionData).set_image(name, Image.create_from_data(side, side, false, Image.FORMAT_L8, bytes), 0, description)

## Adds a retained channel (RF values, RF coverage) from functions of the lattice index; a null
## coverage function means defined everywhere.
static func add_channel(data: StrataRuntimeData, name: String, value_fn: Callable, coverage_fn: Callable = Callable()) -> void:
	var description := StrataRegions.map(Image.FORMAT_RF, StrataRegions.KIND_SAMPLE, 1, data.apron)
	data.maps[name] = description
	data.channel_names.append(name)
	if coverage_fn.is_valid(): data.maps[name + StrataRegions.COVERAGE_SUFFIX] = description
	var side := data.cells + 1 + 2 * data.apron
	var size := data.get_cell_resolution() + Vector2i.ONE
	for xy in data.regions:
		var values := PackedFloat32Array(); values.resize(side * side)
		var coverage := PackedFloat32Array(); coverage.resize(side * side)
		for v in range(side):
			for u in range(side):
				var i := clampi(xy.x * data.cells + u - data.apron, 0, size.x - 1)
				var j := clampi(xy.y * data.cells + v - data.apron, 0, size.y - 1)
				values[v * side + u] = value_fn.call(i, j)
				coverage[v * side + u] = coverage_fn.call(i, j) if coverage_fn.is_valid() else 1.0
		var region: StrataRegionData = data.regions[xy]
		region.set_image(name, Image.create_from_data(side, side, false, Image.FORMAT_RF, values.to_byte_array()), 0, description)
		if coverage_fn.is_valid(): region.set_image(name + StrataRegions.COVERAGE_SUFFIX, Image.create_from_data(side, side, false, Image.FORMAT_RF, coverage.to_byte_array()), 0, description)

## Recomputes the extrema of an embedded manifest from its regions' heights.
static func finish_data(data: StrataRuntimeData) -> void:
	var extrema := PackedFloat64Array()
	extrema.resize(data.grid.x * data.grid.y * 2)
	data.height_min = INF
	data.height_max = -INF
	var spec := data.get_spec()
	for xy in data.regions:
		var region: StrataRegionData = data.regions[xy]
		var scanned := StrataRuntimeData.scan_region(region, spec)
		region.height_min = scanned.min
		region.height_max = scanned.max
		extrema[(xy.y * data.grid.x + xy.x) * 2] = scanned.min
		extrema[(xy.y * data.grid.x + xy.x) * 2 + 1] = scanned.max
		data.height_min = minf(data.height_min, scanned.min)
		data.height_max = maxf(data.height_max, scanned.max)
	data.region_extrema = extrema
	data.validate_payload()

## SHA-256 of every payload: the manifest header and rules, then each region's map levels.
## Used to prove byte identity across resource formats.
static func payload_hashes(data: StrataRuntimeData) -> Dictionary:
	var result := {}
	var payloads := {"lattice": PackedFloat64Array([data.bounds.position.x, data.bounds.position.y, data.bounds.size.x, data.bounds.size.y, data.spacing, data.height_min, data.height_max]).to_byte_array(), "extrema": data.region_extrema.to_byte_array(), "profile_rules": var_to_bytes(data.nav_profile_rules), "maps": JSON.stringify(data.maps, "", true).to_utf8_buffer()}
	for y in range(data.grid.y):
		for x in range(data.grid.x):
			var region := data.get_region(Vector2i(x, y))
			if region == null: continue
			var names := region.map_names()
			names.sort()
			for name in names:
				for level in range(region.level_count(name)):
					payloads["region %d,%d %s %d" % [x, y, name, level]] = region.level_bytes(name, level)
	for key in payloads:
		var context := HashingContext.new()
		context.start(HashingContext.HASH_SHA256)
		context.update(payloads[key])
		result[key] = context.finish().hex_encode()
	return result

static func cell_mask(cells: Vector2i, marked: Array) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(cells.x * cells.y)
	for rect in marked:
		var area: Rect2i = rect
		for z in range(area.position.y, area.end.y):
			for x in range(area.position.x, area.end.x):
				mask[z * cells.x + x] = StrataRuntimeData.MASK_SET
	return mask

## Reference triangle split from first principles (not the resource's code).
static func reference_height(data: StrataRuntimeData, cell: Vector2i, f: Vector2) -> float:
	var a := data.get_height_at(cell)
	var b := data.get_height_at(cell + Vector2i(1, 0))
	var c := data.get_height_at(cell + Vector2i(0, 1))
	var d := data.get_height_at(cell + Vector2i(1, 1))
	# Plane through a, b, c below the b-c diagonal, through b, d, c above it.
	var p0 := Vector3(0, a, 0) if f.x + f.y <= 1.0 else Vector3(1, d, 1)
	var p1 := Vector3(1, b, 0)
	var p2 := Vector3(0, c, 1)
	var normal := (p1 - p0).cross(p2 - p0)
	return p0.y - (normal.x * (f.x - p0.x) + normal.z * (f.y - p0.z)) / normal.y
