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

static func make_data(bounds: Rect2, resolution: Vector2i, height_fn: Callable = fixture_height) -> StrataRuntimeData:
	var data := StrataRuntimeData.new()
	data.bounds = bounds
	data.resolution = resolution
	var heights := PackedFloat32Array()
	heights.resize(resolution.x * resolution.y)
	for j in range(resolution.y):
		for i in range(resolution.x):
			heights[j * resolution.x + i] = height_fn.call(i, j)
	data.heights = heights
	data.height_min = INF
	data.height_max = -INF
	for value in heights:
		data.height_min = minf(data.height_min, value)
		data.height_max = maxf(data.height_max, value)
	return data

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
	var w := data.resolution.x
	var a := data.heights[cell.y * w + cell.x]
	var b := data.heights[cell.y * w + cell.x + 1]
	var c := data.heights[(cell.y + 1) * w + cell.x]
	var d := data.heights[(cell.y + 1) * w + cell.x + 1]
	# Plane through a, b, c below the b-c diagonal, through b, d, c above it.
	var p0 := Vector3(0, a, 0) if f.x + f.y <= 1.0 else Vector3(1, d, 1)
	var p1 := Vector3(1, b, 0)
	var p2 := Vector3(0, c, 1)
	var normal := (p1 - p0).cross(p2 - p0)
	return p0.y - (normal.x * (f.x - p0.x) + normal.z * (f.y - p0.z)) / normal.y
