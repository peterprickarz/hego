class_name HEGoIslandPlayer
extends CharacterBody3D
## Small runtime player for exercising the compiled island's chunked collision.
## Collision and navigation residency follow this body, never the free-fly/showcase camera.

@export var terrain: StrataTerrain3D
@export var collision: StrataCollision
## Optional; when set, its tiles follow the player like the collision chunks do.
@export var navigation: StrataNavigation
@export var player_camera: Camera3D
@export var spawn_local_xz := Vector2.ZERO
@export var spawn_height := 2.0
@export var move_speed := 9.0
@export var ground_acceleration := 32.0
@export var jump_speed := 8.5
@export var mouse_sensitivity := 0.0025
@export var follow_collision_radius := 96.0
@export var follow_navigation_radius := 96.0

var _enabled := false
var _saved_camera_parent: Node
var _saved_camera_transform := Transform3D.IDENTITY
var _saved_camera_current := false
var _saved_camera_input_enabled: Variant
var _saved_camera_process := false
var _saved_camera_physics_process := false
var _saved_camera_unhandled_input := false
var _camera_pitch := 0.0
var _gravity := 9.8
var _saved_collision_track_target := NodePath()
var _saved_collision_track_radius := 96.0
var _saved_navigation_track_target := NodePath()
var _saved_navigation_track_radius := 96.0

func _ready() -> void:
	add_to_group("hego_island_player")
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_ensure_capsule()
	set_physics_process(false)
	set_process_unhandled_input(false)
	if collision != null and collision.track_target.is_empty():
		collision.track_radius = follow_collision_radius

func set_player_enabled(value: bool) -> bool:
	if value == _enabled:
		return true
	if value:
		if not _prepare_spawn_and_camera():
			return false
		_enabled = true
		set_collision_layer(1)
		set_collision_mask(1)
		set_physics_process(true)
		set_process_unhandled_input(true)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return true
	_disable_player()
	return true

func is_player_enabled() -> bool:
	return _enabled

func toggle_player() -> bool:
	return set_player_enabled(not _enabled)

func _prepare_spawn_and_camera() -> bool:
	if terrain == null or terrain.runtime_data == null or collision == null or player_camera == null:
		push_warning("Island player needs a terrain runtime bake, collision node, and camera.")
		return false
	var sample: Dictionary = terrain.runtime_data.sample_height(spawn_local_xz)
	if int(sample.get("status", StrataRuntimeData.Status.NOT_RESIDENT)) != StrataRuntimeData.Status.OK:
		push_warning("Island player spawn is unavailable in the compiled terrain (%s)." % sample.get("status", "unknown"))
		return false
	set_collision_layer(0)
	set_collision_mask(0)
	global_position = terrain.to_global(Vector3(spawn_local_xz.x, float(sample.value) + spawn_height, spawn_local_xz.y))
	velocity = Vector3.ZERO
	var prepared: Dictionary = collision.prepare_around(global_position, follow_collision_radius)
	if not prepared.get("ok", false):
		push_warning("Could not prepare nearby island collision: %s" % prepared.get("message", "unknown error"))
		return false
	_saved_collision_track_target = collision.track_target
	_saved_collision_track_radius = collision.track_radius
	collision.track_radius = follow_collision_radius
	collision.track_target = collision.get_path_to(self)
	if navigation != null:
		_saved_navigation_track_target = navigation.track_target
		_saved_navigation_track_radius = navigation.track_radius
		navigation.track_radius = follow_navigation_radius
		navigation.track_target = navigation.get_path_to(self)
	_attach_camera()
	return true

func _attach_camera() -> void:
	_saved_camera_parent = player_camera.get_parent()
	_saved_camera_transform = player_camera.transform
	_saved_camera_current = player_camera.current
	_saved_camera_process = player_camera.is_processing()
	_saved_camera_physics_process = player_camera.is_physics_processing()
	_saved_camera_unhandled_input = player_camera.is_processing_unhandled_input()
	_saved_camera_input_enabled = null
	if _has_property(player_camera, "input_enabled"):
		var input_value: Variant = player_camera.get("input_enabled")
		if input_value != null:
			_saved_camera_input_enabled = input_value
			player_camera.set("input_enabled", false)
	player_camera.set_process(false)
	player_camera.set_physics_process(false)
	player_camera.set_process_unhandled_input(false)
	player_camera.reparent(self, true)
	player_camera.position = Vector3(0.0, 1.7, 0.0)
	player_camera.rotation = Vector3.ZERO
	player_camera.current = true
	_camera_pitch = 0.0

func _disable_player() -> void:
	_enabled = false
	set_physics_process(false)
	set_process_unhandled_input(false)
	set_collision_layer(0)
	set_collision_mask(0)
	velocity = Vector3.ZERO
	if is_instance_valid(player_camera) and is_instance_valid(_saved_camera_parent):
		player_camera.reparent(_saved_camera_parent, true)
		player_camera.transform = _saved_camera_transform
		player_camera.current = _saved_camera_current
		if _saved_camera_input_enabled != null:
			player_camera.set("input_enabled", _saved_camera_input_enabled)
		player_camera.set_process(_saved_camera_process)
		player_camera.set_physics_process(_saved_camera_physics_process)
		player_camera.set_process_unhandled_input(_saved_camera_unhandled_input)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if collision != null:
		collision.track_target = _saved_collision_track_target
		collision.track_radius = _saved_collision_track_radius
		if _saved_collision_track_target.is_empty():
			collision.clear()
	if navigation != null:
		# The tiles stay resident (the level's fixed navigation survives the player);
		# only the tracking settings return to what they were.
		navigation.track_target = _saved_navigation_track_target
		navigation.track_radius = _saved_navigation_track_radius

func _physics_process(delta: float) -> void:
	var input_x := float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A))
	var input_z := float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
	var input_vector := Vector2(input_x, input_z).limit_length(1.0)
	var direction := (global_basis.x * input_vector.x + global_basis.z * input_vector.y).normalized()
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var target_horizontal := direction * move_speed
	horizontal = horizontal.move_toward(target_horizontal, ground_acceleration * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z
	if not is_on_floor():
		velocity.y -= _gravity * delta
	elif Input.is_key_pressed(KEY_SPACE):
		velocity.y = jump_speed
	move_and_slide()

func _unhandled_input(event: InputEvent) -> void:
	if not _enabled:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotation.y -= event.relative.x * mouse_sensitivity
		_camera_pitch = clampf(_camera_pitch - event.relative.y * mouse_sensitivity, -1.35, 1.35)
		player_camera.rotation.x = _camera_pitch

func _ensure_capsule() -> void:
	var shape_node := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape_node == null:
		shape_node = CollisionShape3D.new()
		shape_node.name = "CollisionShape3D"
		add_child(shape_node)
	if shape_node.shape == null:
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.38
		capsule.height = 1.8
		shape_node.shape = capsule

func _has_property(object: Object, property_name: String) -> bool:
	for property in object.get_property_list():
		if String(property.name) == property_name:
			return true
	return false
