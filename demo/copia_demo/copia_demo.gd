extends Node3D
## Copia demo: about 300,000 points over a 512 m square in three sets (ground, rocks, trees),
## written into a store under user:// (nothing is added to the project). Fly with WASD and the
## mouse (click to capture it, Escape to release; Shift is fast, Q and E go down and up).
## R clears and rewrites the rocks in the cells around the camera with a new seed; F toggles the
## store's density between 1 and 0.5.
##
## Command-line arguments after "--":
##   --points=N      number of points to generate (default 300000)
##   --dir=PATH      the store's data directory (default user://copia_demo)
##   --autofly       fly a scripted path for about 20 s, print the frame times and quit
## The same values are exported properties, so a test can set them before adding the scene.

const EXTENSION := "res://addons/copia/bin/copia.gdextension"
const SIDE := 512.0
const CELLS := 8  # SIDE / the store's cell size of 64 m
const OBJECTS := "res://copia_demo/objects/"
# Per set: the objects with their lift (metres per unit of scale, so that a thing sits on the
# ground), the share of the points and the scale range.
const SETS := {
	"ground": {"objects": [["grass_tuft", 0.25], ["flower", 0.12], ["fern", 0.3]], "share": 0.8, "scale": Vector2(0.7, 1.5)},
	"rocks": {"objects": [["rock_boulder", 0.25], ["rock_slab", 0.3], ["rock_spire", 0.6]], "share": 0.16, "scale": Vector2(0.5, 2.5)},
	"trees": {"objects": [["tree_pine", 4.5], ["tree_birch", 3.5]], "share": 0.04, "scale": Vector2(0.8, 1.5)},
}
const AUTOFLY_SECONDS := 20.0
const AUTOFLY_SETTLE := 3.0

## Points to generate when the store is empty.
@export var point_count := 300000
## Data directory of the store. Empty keeps the one set in the scene.
@export var data_dir := ""
## Fly the scripted path, print the frame times and quit.
@export var autofly := false
## Seed of the first generation.
@export var seed_value := 1

var _store: Node3D
var _camera: Camera3D
var _label: Label
var _yaw := 0.0
var _pitch := 0.0
var _seed := 0
var _info := ""
var _label_timer := 0.0
var _fly_time := 0.0
var _frames: Array[float] = []
var _last_usec := 0
var _events_done := 0
var _worst := 0.0
var _worst_at := 0.0
## Seconds the last [method generate] took in [code]store.write[/code] (points are written and built).
var write_seconds := 0.0
## Points written by the last [method generate].
var points_written := 0


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument == "--autofly":
			autofly = true
		elif argument.begins_with("--points="):
			point_count = argument.get_slice("=", 1).to_int()
		elif argument.begins_with("--dir="):
			data_dir = argument.get_slice("=", 1)
	_store = $CopiaStore3D
	_camera = $FlyCamera
	_label = $Help/Label
	if not data_dir.is_empty():
		_store.data_directory = data_dir
	_seed = seed_value
	_yaw = _camera.rotation.y
	if _store.list_sets().is_empty():
		generate()
	else:
		_info = "Using the existing data in %s." % _store.data_directory
		print("COPIA_DEMO existing data in %s" % _store.data_directory)
	if autofly:
		_fly_time = -AUTOFLY_SETTLE
	_last_usec = Time.get_ticks_usec()


## The store node of the scene.
func get_store() -> Node3D:
	return $CopiaStore3D


## Writes [member point_count] points over the whole square, three sets in one call, and prints
## how long the write (which builds the touched cells) took.
func generate() -> Dictionary:
	var parts := []
	for set_name in SETS:
		parts.append([set_name, Rect2(0, 0, SIDE, SIDE), int(point_count * SETS[set_name].share)])
	var attributes := _attributes(parts, _seed)
	var started := Time.get_ticks_usec()
	var report: Dictionary = _store.write([], _convert(attributes))
	write_seconds = (Time.get_ticks_usec() - started) / 1e6
	points_written = attributes.object.size()
	var built: int = report.build.get("written", []).size()
	_info = "Wrote %d points in %.2f s (%d cells built)." % [points_written, write_seconds, built]
	print("COPIA_DEMO write ok=%s points=%d seconds=%.3f cells_built=%d error=%s" % [report.ok, points_written, write_seconds, built, report.error])
	return report


## Clears the rocks of the 3 x 3 cells around the camera and writes new ones there.
func regenerate_rocks() -> Dictionary:
	var cell_size: float = _store.cell_size
	var centre := Vector2i(floori(_camera.position.x / cell_size), floori(_camera.position.z / cell_size))
	var first := Vector2i(clampi(centre.x - 1, 0, CELLS - 1), clampi(centre.y - 1, 0, CELLS - 1))
	var last := Vector2i(clampi(centre.x + 1, 0, CELLS - 1), clampi(centre.y + 1, 0, CELLS - 1))
	var clears := []
	for x in range(first.x, last.x + 1):
		for z in range(first.y, last.y + 1):
			clears.append({"set": "rocks", "cell": Vector2i(x, z)})
	var rect := Rect2(Vector2(first) * cell_size, Vector2(last - first + Vector2i.ONE) * cell_size)
	var count := int(point_count * SETS.rocks.share * rect.get_area() / (SIDE * SIDE))
	_seed += 1
	var attributes := _attributes([["rocks", rect, count]], _seed)
	var started := Time.get_ticks_usec()
	var report: Dictionary = _store.write(clears, _convert(attributes))
	var seconds := (Time.get_ticks_usec() - started) / 1e6
	_info = "Rewrote the rocks of %d cells (seed %d, %d points) in %.3f s." % [clears.size(), _seed, count, seconds]
	print("COPIA_DEMO rewrite ok=%s cells=%d points=%d seconds=%.3f" % [report.ok, clears.size(), count, seconds])
	return report


func toggle_density() -> void:
	_store.density = 0.5 if _store.density > 0.75 else 1.0
	_info = "Density %.1f." % _store.density


# Per-point attributes (the names CopiaPoints reads) for the parts [[set, rect, count]].
func _attributes(parts: Array, seed_for: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_for
	var total := 0
	for part in parts:
		total += part[2]
	var origin := PackedVector3Array()
	origin.resize(total)
	var facing := PackedVector3Array()
	facing.resize(total)
	var uniform_scale := PackedFloat32Array()
	uniform_scale.resize(total)
	var keep := PackedFloat32Array()
	keep.resize(total)
	var object := PackedStringArray()
	object.resize(total)
	var set_names := PackedStringArray()
	set_names.resize(total)
	var index := 0
	for part in parts:
		var set_name: String = part[0]
		var rect: Rect2 = part[1]
		var definition: Dictionary = SETS[set_name]
		var entries: Array = definition.objects
		var paths := PackedStringArray()
		for entry in entries:
			paths.append(OBJECTS + entry[0] + ".tres")
		var scale_range: Vector2 = definition.scale
		for i in part[2]:
			var which := rng.randi() % entries.size()
			var size := rng.randf_range(scale_range.x, scale_range.y)
			var angle := rng.randf() * TAU
			origin[index] = Vector3(rect.position.x + rng.randf() * rect.size.x, entries[which][1] * size, rect.position.y + rng.randf() * rect.size.y)
			facing[index] = Vector3(sin(angle), 0.0, cos(angle))
			uniform_scale[index] = size
			keep[index] = rng.randf()
			object[index] = paths[which]
			set_names[index] = set_name
			index += 1
	return {"P": origin, "N": facing, "pscale": uniform_scale, "keep": keep, "object": object, "set": set_names}


func _convert(attributes: Dictionary) -> Dictionary:
	if not ClassDB.class_exists("CopiaPoints"):
		GDExtensionManager.load_extension(EXTENSION)
	var converted: Dictionary = ClassDB.instantiate("CopiaPoints").from_attributes(attributes)
	if converted.skipped_count > 0:
		push_warning("CopiaDemo: %d points skipped: %s" % [converted.skipped_count, converted.errors])
	return converted.points


func _unhandled_input(event: InputEvent) -> void:
	if autofly:
		return
	if event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * 0.002
		_pitch = clampf(_pitch - event.relative.y * 0.002, -1.5, 1.5)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif event.keycode == KEY_R:
			regenerate_rocks()
		elif event.keycode == KEY_F:
			toggle_density()


func _process(delta: float) -> void:
	var now := Time.get_ticks_usec()
	var frame := (now - _last_usec) / 1000.0
	_last_usec = now
	if autofly:
		_autofly(delta, frame)
	else:
		_move(delta)
	_camera.rotation = Vector3(_pitch, _yaw, 0.0)
	_label_timer -= delta
	if _label_timer <= 0.0:
		_label_timer = 0.25
		var stats: Dictionary = _store.get_stats()
		var kinds: Dictionary = stats.groups_by_kind
		_label.text = "WASD move, Shift fast, Q/E down/up, mouse look (click to capture, Esc to release)\nR: rewrite the rocks around the camera   F: density 1 / 0.5 (now %.1f)\n%s\n%d fps, %d groups (%d draw, %d impostor, %d collider)" % [
				_store.density, _info, Engine.get_frames_per_second(), stats.groups, kinds.draw, kinds.impostor, kinds.collider]


func _move(delta: float) -> void:
	var direction := Vector3.ZERO
	var basis := Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	if Input.is_physical_key_pressed(KEY_W): direction -= basis.z
	if Input.is_physical_key_pressed(KEY_S): direction += basis.z
	if Input.is_physical_key_pressed(KEY_A): direction -= basis.x
	if Input.is_physical_key_pressed(KEY_D): direction += basis.x
	if Input.is_physical_key_pressed(KEY_E): direction += Vector3.UP
	if Input.is_physical_key_pressed(KEY_Q): direction += Vector3.DOWN
	var speed := 40.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 8.0
	_camera.position += direction.normalized() * speed * delta


# A loop around the square at head height, 15 m/s. Frame times of the path are collected after
# the settle; the rock rewrite (t = 7 s) and the density toggle (t = 13 s) happen on the way, and
# the frame of the synchronous rewrite is left out (its time is printed by the rewrite).
func _autofly(delta: float, frame: float) -> void:
	_fly_time += delta
	var path_time := maxf(_fly_time, 0.0)
	var low := 80.0
	var high := SIDE - 80.0
	var leg := high - low
	var along := fposmod(path_time * 15.0, leg * 4.0)
	var side := int(along / leg)
	var t := along - side * leg
	var corners := [Vector2(low + t, low), Vector2(high, low + t), Vector2(high - t, high), Vector2(low, high - t)]
	var headings := [Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0), Vector2(0, -1)]
	var position: Vector2 = corners[side]
	var heading: Vector2 = headings[side]
	_camera.position = Vector3(position.x, 3.0, position.y)
	_yaw = atan2(-heading.x, -heading.y)
	_pitch = -0.15
	if _fly_time < 0.0:
		return
	if _fly_time >= AUTOFLY_SECONDS:
		_report()
		return
	if _events_done == 0 and _fly_time >= 7.0:
		_events_done = 1
		regenerate_rocks()
		return
	if _events_done == 1 and _fly_time >= 13.0:
		_events_done = 2
		toggle_density()
	_frames.append(frame)
	if frame > _worst:
		_worst = frame
		_worst_at = _fly_time


func _report() -> void:
	autofly = false
	var sorted := _frames.duplicate()
	sorted.sort()
	var count := sorted.size()
	var median: float = sorted[count / 2] if count > 0 else 0.0
	var p99: float = sorted[mini(int(count * 0.99), count - 1)] if count > 0 else 0.0
	var worst: float = sorted[count - 1] if count > 0 else 0.0
	print("COPIA_DEMO_FLY frames=%d median_ms=%.2f p99_ms=%.2f worst_ms=%.2f worst_at_s=%.2f groups=%s" % [count, median, p99, worst, _worst_at, _store.get_stats().groups_by_kind])
	get_tree().quit()
