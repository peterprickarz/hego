class_name HEGoGraphEditor
extends RefCounted

## Viewport editing for a selected [HEGoGraphInput3D].

enum Mode {
	SELECT,
	DRAW,
}

const CLICK_PIXELS := 5.0

var plugin: EditorPlugin
var gizmo_plugin: EditorNode3DGizmoPlugin
var graph: HEGoGraphInput3D
var mode: Mode = Mode.DRAW
var placement_mode: int = HEGoGraphPlacement.Mode.CAMERA
var world_axis: int = HEGoGraphPlacement.Axis.XZ
var world_offset: float = 0.0

var selected_points: PackedInt32Array = PackedInt32Array()
var selected_connections: PackedInt32Array = PackedInt32Array()
var last_point: int = -1
var hover_point: int = -1
var hover_connection: int = -1
var preview_cursor: Variant = null
var ctrl_held: bool = false

var _press_pos := Vector2.ZERO
var _pressed := false


func edit(object: Object) -> void:
	if graph != null and graph.graph_changed.is_connected(_on_graph_changed):
		graph.graph_changed.disconnect(_on_graph_changed)
	graph = object as HEGoGraphInput3D
	selected_points = PackedInt32Array()
	selected_connections = PackedInt32Array()
	last_point = -1
	hover_point = -1
	hover_connection = -1
	preview_cursor = null
	if graph != null:
		if not graph.graph_changed.is_connected(_on_graph_changed):
			graph.graph_changed.connect(_on_graph_changed)
		graph.update_gizmos()


func set_visible(visible: bool) -> void:
	if not visible:
		edit(null)


func handle_input(camera: Camera3D, event: InputEvent) -> int:
	if graph == null or not is_instance_valid(graph):
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventKey and event.pressed and not event.echo:
		ctrl_held = event.ctrl_pressed
		if event.keycode == KEY_DELETE or event.keycode == KEY_BACKSPACE:
			if selected_points.size() > 0 or selected_connections.size() > 0:
				_delete_selection()
				return EditorPlugin.AFTER_GUI_INPUT_STOP

	if event is InputEventMouse:
		ctrl_held = event.ctrl_pressed

	if _is_camera_event(event):
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseMotion:
		_update_hover(camera, event.position)
		if ctrl_held and last_point >= 0:
			preview_cursor = _hit(camera, event.position)
		else:
			preview_cursor = null
		graph.update_gizmos()
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press_pos = event.position
			_pressed = true
			_update_hover(camera, event.position)
			# Point handles belong to the gizmo, so a press on a point must pass
			# through or dragging a point never starts.
			if hover_point >= 0:
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if _pressed:
			_pressed = false
			if event.position.distance_to(_press_pos) <= CLICK_PIXELS:
				_click(camera, event.position, event.shift_pressed, event.ctrl_pressed)
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			return EditorPlugin.AFTER_GUI_INPUT_PASS

	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _is_camera_event(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE or event.button_index == MOUSE_BUTTON_RIGHT:
			return true
		if event.button_index == MOUSE_BUTTON_LEFT and event.alt_pressed:
			return true
	if event is InputEventMouseMotion:
		if event.button_mask & (MOUSE_BUTTON_MASK_MIDDLE | MOUSE_BUTTON_MASK_RIGHT):
			return true
		if event.alt_pressed and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			return true
	return false


func _click(camera: Camera3D, mouse: Vector2, shift: bool, ctrl: bool) -> void:
	_update_hover(camera, mouse)
	if hover_point >= 0:
		if mode == Mode.DRAW and ctrl and last_point >= 0:
			_mutate("Connect graph points", func() -> void:
				graph.add_connection(last_point, hover_point)
			)
			last_point = hover_point
			_select_points(PackedInt32Array([hover_point]), false)
		else:
			_select_points(PackedInt32Array([hover_point]), shift)
			last_point = hover_point
		return

	if hover_connection >= 0:
		if mode == Mode.DRAW:
			var a: int = graph.connections[hover_connection * 2]
			var b: int = graph.connections[hover_connection * 2 + 1]
			var split_at := HEGoGraphPicking.closest_on_segment(
					graph.to_global(graph.points[a]), graph.to_global(graph.points[b]),
					_ray_point(camera, mouse))
			var local := graph.to_local(split_at)
			var conn := hover_connection
			_mutate("Split graph connection", func() -> void:
				last_point = graph.split_connection(conn, local)
			)
			if last_point >= 0:
				_select_points(PackedInt32Array([last_point]), false)
		else:
			_select_connections(PackedInt32Array([hover_connection]), shift)
		return

	if mode != Mode.DRAW:
		if not shift:
			_clear_selection()
		return

	var hit: Variant = _hit(camera, mouse)
	if hit == null:
		return
	var local_hit: Vector3 = graph.to_local(hit)
	var connect_from := last_point if ctrl else -1
	_mutate("Add graph point", func() -> void:
		last_point = graph.add_point(local_hit)
		if connect_from >= 0:
			graph.add_connection(connect_from, last_point)
	)
	if last_point >= 0:
		_select_points(PackedInt32Array([last_point]), false)


func _delete_selection() -> void:
	var pts := selected_points.duplicate()
	var cons := selected_connections.duplicate()
	_mutate("Delete graph selection", func() -> void:
		if cons.size() > 0:
			graph.remove_connections(cons)
		if pts.size() > 0:
			graph.remove_points(pts)
	)
	_clear_selection()
	last_point = -1


func _select_points(indices: PackedInt32Array, additive: bool) -> void:
	if not additive:
		selected_points = PackedInt32Array()
		selected_connections = PackedInt32Array()
	for index in indices:
		var found := selected_points.find(index)
		if found >= 0:
			selected_points.remove_at(found)
		else:
			selected_points.append(index)
	graph.update_gizmos()


func _select_connections(indices: PackedInt32Array, additive: bool) -> void:
	if not additive:
		selected_points = PackedInt32Array()
		selected_connections = PackedInt32Array()
	for index in indices:
		var found := selected_connections.find(index)
		if found >= 0:
			selected_connections.remove_at(found)
		else:
			selected_connections.append(index)
	graph.update_gizmos()


func _clear_selection() -> void:
	selected_points = PackedInt32Array()
	selected_connections = PackedInt32Array()
	if graph:
		graph.update_gizmos()


func _update_hover(camera: Camera3D, mouse: Vector2) -> void:
	hover_point = -1
	hover_connection = -1
	if graph.points.is_empty():
		return
	var projected := PackedVector2Array()
	projected.resize(graph.points.size())
	var visible := PackedInt32Array()
	visible.resize(graph.points.size())
	for i in graph.points.size():
		var global_pt: Vector3 = graph.to_global(graph.points[i])
		if camera.is_position_behind(global_pt):
			projected[i] = Vector2(-1e6, -1e6)
			visible[i] = 0
		else:
			projected[i] = camera.unproject_position(global_pt)
			visible[i] = 1
	hover_point = HEGoGraphPicking.closest_point(mouse, projected)
	if hover_point >= 0 and visible[hover_point] == 0:
		hover_point = -1
	if hover_point < 0:
		hover_connection = HEGoGraphPicking.closest_connection(mouse, projected, graph.connections)


func _hit(camera: Camera3D, mouse: Vector2) -> Variant:
	var origin := camera.project_ray_origin(mouse)
	var direction := camera.project_ray_normal(mouse)
	var plane: Plane
	if placement_mode == HEGoGraphPlacement.Mode.WORLD:
		plane = HEGoGraphPlacement.world_plane(world_axis, graph.global_position, world_offset)
	else:
		var anchor := graph.global_position
		if last_point >= 0 and last_point < graph.points.size():
			anchor = graph.to_global(graph.points[last_point])
		elif selected_points.size() > 0 and selected_points[0] < graph.points.size():
			anchor = graph.to_global(graph.points[selected_points[0]])
		plane = HEGoGraphPlacement.camera_plane(-camera.global_transform.basis.z, anchor)
	return HEGoGraphPlacement.intersect_ray(origin, direction, plane)


func _ray_point(camera: Camera3D, mouse: Vector2) -> Vector3:
	var hit: Variant = _hit(camera, mouse)
	if hit != null:
		return hit
	return camera.project_ray_origin(mouse) + camera.project_ray_normal(mouse)


func _mutate(action: String, fn: Callable) -> void:
	var before: Dictionary = graph.capture_state()
	fn.call()
	var after: Dictionary = graph.capture_state()
	var ur := plugin.get_undo_redo()
	ur.create_action(action)
	ur.add_do_method(graph, "apply_state", after)
	ur.add_undo_method(graph, "apply_state", before)
	ur.commit_action(false)
	graph.update_gizmos()


func _on_graph_changed() -> void:
	if graph:
		graph.update_gizmos()


func handle_id_moved(handle_id: int, local_position: Vector3) -> void:
	if graph == null or handle_id < 0 or handle_id >= graph.points.size():
		return
	graph.set_point_position(handle_id, local_position)


func commit_handle(handle_id: int, restore: Vector3, cancel: bool) -> void:
	if graph == null:
		return
	if cancel:
		graph.set_point_position(handle_id, restore)
		graph.update_gizmos()
		return
	var after: Vector3 = graph.points[handle_id]
	var ur := plugin.get_undo_redo()
	ur.create_action("Move graph point")
	ur.add_do_method(graph, "set_point_position", handle_id, after)
	ur.add_undo_method(graph, "set_point_position", handle_id, restore)
	ur.commit_action(false)
