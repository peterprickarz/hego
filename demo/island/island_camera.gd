class_name HEGoIslandCamera
extends Camera3D

var renderer: StrataRenderer
var ground_mode := false
var input_enabled := true
var speed := 90.0
var _looking := false

func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled: return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_looking = event.pressed
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _looking else Input.MOUSE_MODE_VISIBLE
	if event is InputEventMouseMotion and _looking:
		rotation.y -= event.relative.x * 0.0025
		rotation.x = clampf(rotation.x - event.relative.y * 0.0025, -1.5, 1.5)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP: speed = minf(500.0, speed * 1.25)
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN: speed = maxf(4.0, speed / 1.25)

func _process(delta: float) -> void:
	if not input_enabled: return
	var forward := -global_basis.z
	var right := global_basis.x
	if ground_mode:
		forward.y = 0.0; forward = forward.normalized()
	var direction := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W): direction += forward
	if Input.is_physical_key_pressed(KEY_S): direction -= forward
	if Input.is_physical_key_pressed(KEY_D): direction += right
	if Input.is_physical_key_pressed(KEY_A): direction -= right
	if not ground_mode:
		if Input.is_physical_key_pressed(KEY_E): direction += Vector3.UP
		if Input.is_physical_key_pressed(KEY_Q): direction -= Vector3.UP
	var multiplier := 3.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0
	if direction.length_squared() > 0.0: global_position += direction.normalized() * speed * multiplier * delta
	if ground_mode and renderer != null:
		global_position.y = maxf(renderer.sample_render_height(Vector2(global_position.x, global_position.z)) + 1.8, 1.8)

func teleport_to(point: Vector3, target: Vector3) -> void:
	global_position = point
	look_at(target, Vector3.UP)
