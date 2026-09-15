class_name HEGoGraphEditor
extends RefCounted

## Viewport editing for a selected [HEGoGraphInput3D].

enum Mode {
	SELECT,
	DRAW,
}

enum DragKind {
	NONE,
	BOX,
	POINTS,
	AXIS_X,
	AXIS_Y,
	AXIS_Z,
}

const CLICK_PIXELS := 8.0
const AXIS_PICK_PIXELS := 14.0

var plugin: EditorPlugin
var gizmo_plugin: EditorNode3DGizmoPlugin
var toolbar: Control
var attrib_panel: Control
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
var gizmo_origin := Vector3.ZERO
var axis_length := 0.45

var _press_pos := Vector2.ZERO
var _pressed := false
var _drag_kind: DragKind = DragKind.NONE
var _drag_started := false
var _skip_click := false
var _undo_before: Dictionary = {}
var _move_indices := PackedInt32Array()
var _move_origins := PackedVector3Array()
var _drag_anchor := Vector3.ZERO
var _drag_plane := Plane()
var _pointer := Vector2.ZERO


func edit(object: Object) -> void:
	_cancel_pointer()
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
	if toolbar:
		toolbar.visible = visible
	if attrib_panel:
		attrib_panel.visible = visible
	if not visible:
		edit(null)
	else:
		_refresh_attrib_panel()


func handle_input(camera: Camera3D, event: InputEvent) -> int:
	if graph == null or not is_instance_valid(graph):
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	_update_axis_length(camera)

	if event is InputEventKey and event.pressed and not event.echo:
		ctrl_held = event.ctrl_pressed
		if event.keycode == KEY_DELETE or event.keycode == KEY_BACKSPACE:
			if selected_points.size() > 0 or selected_connections.size() > 0:
				_delete_selection()
				return EditorPlugin.AFTER_GUI_INPUT_STOP

	if event is InputEventMouse:
		ctrl_held = event.ctrl_pressed

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and _pressed:
		_cancel_pointer()
		graph.update_gizmos()
		plugin.update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	if _is_camera_event(event):
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseMotion:
		return _on_motion(camera, event)

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			return _on_press(camera, event)
		return _on_release(camera, event)

	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _on_press(camera: Camera3D, event: InputEventMouseButton) -> int:
	_press_pos = event.position
	_pointer = event.position
	_pressed = true
	_drag_kind = DragKind.NONE
	_drag_started = false
	_skip_click = false
	_update_hover(camera, event.position)

	var axis := _pick_axis(camera, event.position)
	if axis != DragKind.NONE:
		_drag_kind = axis
		_begin_move(camera, selected_points)
		_skip_click = true
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	if hover_point >= 0:
		if event.shift_pressed:
			_select_points(PackedInt32Array([hover_point]), true)
			last_point = hover_point
			_skip_click = true
		else:
			if selected_points.find(hover_point) < 0:
				_select_points(PackedInt32Array([hover_point]), false)
			last_point = hover_point
			_drag_kind = DragKind.POINTS
			_begin_move(camera, selected_points)
			_skip_click = true
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	return EditorPlugin.AFTER_GUI_INPUT_STOP


func _on_motion(camera: Camera3D, event: InputEventMouseMotion) -> int:
	_pointer = event.position
	if _pressed and not _drag_started and event.position.distance_to(_press_pos) > CLICK_PIXELS:
		_drag_started = true
		if _drag_kind == DragKind.NONE and mode == Mode.SELECT:
			_drag_kind = DragKind.BOX
			_undo_before = {}
		if _drag_kind == DragKind.POINTS or _is_axis(_drag_kind):
			_undo_before = graph.capture_state()

	if _pressed and _drag_started:
		if _drag_kind == DragKind.BOX:
			plugin.update_overlays()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if _drag_kind == DragKind.POINTS or _is_axis(_drag_kind):
			_apply_move(camera, event.position)
			graph.update_gizmos()
			return EditorPlugin.AFTER_GUI_INPUT_STOP

	var prev_p := hover_point
	var prev_c := hover_connection
	_update_hover(camera, event.position)
	var new_preview: Variant = null
	if ctrl_held and last_point >= 0 and mode == Mode.DRAW:
		new_preview = _hit(camera, event.position)
	var preview_changed: bool = preview_cursor != new_preview
	preview_cursor = new_preview
	if hover_point != prev_p or hover_connection != prev_c or preview_changed:
		graph.update_gizmos()
	return EditorPlugin.AFTER_GUI_INPUT_STOP if _pressed else EditorPlugin.AFTER_GUI_INPUT_PASS


func _on_release(camera: Camera3D, event: InputEventMouseButton) -> int:
	if not _pressed:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	_pressed = false

	if _drag_started:
		if _drag_kind == DragKind.BOX:
			_finish_box(camera, event.shift_pressed)
			plugin.update_overlays()
		elif _drag_kind == DragKind.POINTS or _is_axis(_drag_kind):
			_commit_move()
		_drag_kind = DragKind.NONE
		_drag_started = false
		graph.update_gizmos()
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	_drag_kind = DragKind.NONE
	if _skip_click:
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	_click(camera, event.position, event.shift_pressed, event.ctrl_pressed)
	return EditorPlugin.AFTER_GUI_INPUT_STOP


func _cancel_pointer() -> void:
	if _pressed and _drag_started and not _undo_before.is_empty() and graph:
		graph.apply_state(_undo_before)
	_pressed = false
	_drag_kind = DragKind.NONE
	_drag_started = false
	_skip_click = false
	_undo_before = {}
	if plugin:
		plugin.update_overlays()


func _is_camera_event(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			return true
		if event.button_index == MOUSE_BUTTON_RIGHT and not _pressed:
			return true
		if event.button_index == MOUSE_BUTTON_LEFT and event.alt_pressed:
			return true
	if event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			return true
		if event.button_mask & MOUSE_BUTTON_MASK_RIGHT and not _pressed:
			return true
		if event.alt_pressed and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			return true
	return false


func _is_axis(kind: DragKind) -> bool:
	return kind == DragKind.AXIS_X or kind == DragKind.AXIS_Y or kind == DragKind.AXIS_Z


func _begin_move(camera: Camera3D, indices: PackedInt32Array) -> void:
	_move_indices = PackedInt32Array()
	_move_origins = PackedVector3Array()
	for index in indices:
		if index >= 0 and index < graph.points.size():
			_move_indices.append(index)
			_move_origins.append(graph.points[index])
	if _move_indices.is_empty():
		return
	_drag_anchor = graph.points[_move_indices[0]]
	if selected_points.size() > 0:
		var origin := Vector3.ZERO
		var count := 0
		for i in selected_points:
			if i >= 0 and i < graph.points.size():
				origin += graph.points[i]
				count += 1
		if count > 0:
			gizmo_origin = origin / float(count)
	_drag_plane = _placement_plane(camera, graph.to_global(_drag_anchor))


func _apply_move(camera: Camera3D, mouse: Vector2) -> void:
	if _move_indices.is_empty():
		return
	var delta := Vector3.ZERO
	if _drag_kind == DragKind.POINTS:
		var origin := camera.project_ray_origin(mouse)
		var direction := camera.project_ray_normal(mouse)
		var hit: Variant = HEGoGraphPlacement.intersect_ray(origin, direction, _drag_plane)
		if hit == null:
			return
		delta = graph.to_local(hit) - _drag_anchor
	else:
		var axis := Vector3.RIGHT
		if _drag_kind == DragKind.AXIS_Y:
			axis = Vector3.UP
		elif _drag_kind == DragKind.AXIS_Z:
			axis = Vector3.BACK
		var origin_global: Vector3 = graph.to_global(gizmo_origin)
		var axis_global: Vector3 = (graph.global_transform.basis * axis).normalized()
		var ray_o := camera.project_ray_origin(mouse)
		var ray_d := camera.project_ray_normal(mouse)
		var along := _closest_on_axis(ray_o, ray_d, origin_global, axis_global)
		var anchor_along := gizmo_origin.dot(axis)
		var now_along := graph.to_local(along).dot(axis)
		delta = axis * (now_along - anchor_along)

	var next := graph.points.duplicate()
	for i in _move_indices.size():
		next[_move_indices[i]] = _move_origins[i] + delta
	graph.points = next


func _commit_move() -> void:
	if _undo_before.is_empty():
		return
	var after: Dictionary = graph.capture_state()
	var ur := plugin.get_undo_redo()
	ur.create_action("Move graph points")
	ur.add_do_method(graph, "apply_state", after)
	ur.add_undo_method(graph, "apply_state", _undo_before)
	ur.commit_action(false)
	_undo_before = {}


func _closest_on_axis(ray_o: Vector3, ray_d: Vector3, axis_o: Vector3, axis_d: Vector3) -> Vector3:
	# Closest point on the axis line to the mouse ray.
	var d := ray_d.cross(axis_d)
	var denom := d.length_squared()
	if denom < 0.0000001:
		return axis_o
	var t := ((axis_o - ray_o).cross(ray_d)).dot(d) / denom
	return axis_o + axis_d * t


func _pick_axis(camera: Camera3D, mouse: Vector2) -> DragKind:
	if selected_points.is_empty() or graph.points.is_empty():
		return DragKind.NONE
	var origin_global: Vector3 = graph.to_global(gizmo_origin)
	if camera.is_position_behind(origin_global):
		return DragKind.NONE
	var tips := {
		DragKind.AXIS_X: graph.to_global(gizmo_origin + Vector3.RIGHT * axis_length),
		DragKind.AXIS_Y: graph.to_global(gizmo_origin + Vector3.UP * axis_length),
		DragKind.AXIS_Z: graph.to_global(gizmo_origin + Vector3.BACK * axis_length),
	}
	var best := DragKind.NONE
	var best_dist := AXIS_PICK_PIXELS
	for kind in tips:
		var tip: Vector3 = tips[kind]
		if camera.is_position_behind(tip):
			continue
		var dist := camera.unproject_position(tip).distance_to(mouse)
		if dist <= best_dist:
			best_dist = dist
			best = kind
	return best


func _update_axis_length(camera: Camera3D) -> void:
	if graph == null or selected_points.is_empty():
		return
	var origin := Vector3.ZERO
	var count := 0
	for i in selected_points:
		if i >= 0 and i < graph.points.size():
			origin += graph.points[i]
			count += 1
	if count == 0:
		return
	gizmo_origin = origin / float(count)
	var dist := camera.global_position.distance_to(graph.to_global(gizmo_origin))
	axis_length = clampf(dist * 0.12, 0.2, 3.0)


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
		selected_points = indices.duplicate()
		selected_connections = PackedInt32Array()
	else:
		for index in indices:
			var found := selected_points.find(index)
			if found >= 0:
				selected_points.remove_at(found)
			else:
				selected_points.append(index)
	graph.update_gizmos()
	_refresh_attrib_panel()


func _select_connections(indices: PackedInt32Array, additive: bool) -> void:
	if not additive:
		selected_points = PackedInt32Array()
		selected_connections = indices.duplicate()
	else:
		for index in indices:
			var found := selected_connections.find(index)
			if found >= 0:
				selected_connections.remove_at(found)
			else:
				selected_connections.append(index)
	graph.update_gizmos()
	_refresh_attrib_panel()


func _clear_selection() -> void:
	selected_points = PackedInt32Array()
	selected_connections = PackedInt32Array()
	if graph:
		graph.update_gizmos()
	_refresh_attrib_panel()


func draw_overlay(overlay: Control) -> void:
	if not _pressed or _drag_kind != DragKind.BOX or not _drag_started:
		return
	var rect := Rect2(_press_pos, _pointer - _press_pos).abs()
	overlay.draw_rect(rect, Color(0.2, 0.55, 1.0, 0.12), true)
	overlay.draw_rect(rect, Color(0.2, 0.55, 1.0, 0.9), false, 1.0)


func _finish_box(camera: Camera3D, additive: bool) -> void:
	var rect := Rect2(_press_pos, _pointer - _press_pos).abs()
	if rect.size.x < 2.0 and rect.size.y < 2.0:
		return
	var projected := PackedVector2Array()
	projected.resize(graph.points.size())
	for i in graph.points.size():
		var global_pt: Vector3 = graph.to_global(graph.points[i])
		if camera.is_position_behind(global_pt):
			projected[i] = Vector2(-1e6, -1e6)
		else:
			projected[i] = camera.unproject_position(global_pt)
	var pts := HEGoGraphPicking.points_in_rect(rect, projected)
	var cons := HEGoGraphPicking.connections_in_rect(rect, projected, graph.connections)
	if not additive:
		selected_points = PackedInt32Array()
		selected_connections = PackedInt32Array()
	for index in pts:
		if selected_points.find(index) < 0:
			selected_points.append(index)
	for index in cons:
		if selected_connections.find(index) < 0:
			selected_connections.append(index)
	if selected_points.size() > 0:
		last_point = selected_points[selected_points.size() - 1]
	graph.update_gizmos()
	_refresh_attrib_panel()


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
	if placement_mode == HEGoGraphPlacement.Mode.GEOMETRY:
		var tree := graph.get_tree()
		var root: Node = tree.edited_scene_root if tree != null and tree.edited_scene_root != null else graph
		var geo: Variant = HEGoGraphPlacement.intersect_scene(root, origin, direction, graph)
		if geo != null:
			return geo
	var anchor := graph.global_position
	if last_point >= 0 and last_point < graph.points.size():
		anchor = graph.to_global(graph.points[last_point])
	elif selected_points.size() > 0 and selected_points[0] < graph.points.size():
		anchor = graph.to_global(graph.points[selected_points[0]])
	return HEGoGraphPlacement.intersect_ray(origin, direction, _placement_plane(camera, anchor))


func _placement_plane(camera: Camera3D, anchor: Vector3) -> Plane:
	if placement_mode == HEGoGraphPlacement.Mode.WORLD:
		return HEGoGraphPlacement.world_plane(world_axis, graph.global_position, world_offset)
	return HEGoGraphPlacement.camera_plane(-camera.global_transform.basis.z, anchor)


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
	_refresh_attrib_panel()


func _refresh_attrib_panel() -> void:
	if attrib_panel and attrib_panel.has_method("rebuild"):
		attrib_panel.rebuild(graph, selected_points, selected_connections)


func on_mode_changed(new_mode: int) -> void:
	mode = new_mode
	_cancel_pointer()


func on_placement_changed(new_mode: int) -> void:
	placement_mode = new_mode


func on_world_axis_changed(axis: int) -> void:
	world_axis = axis


func on_world_offset_changed(offset: float) -> void:
	world_offset = offset


func on_attrib_changed(owner_kind: int, name: String, value: Variant) -> void:
	if graph == null:
		return
	if owner_kind == 0:
		var indices := selected_points.duplicate()
		_mutate("Set graph point attribute", func() -> void:
			graph.set_point_attrib_on(name, indices, value)
		)
	else:
		var indices := selected_connections.duplicate()
		_mutate("Set graph connection attribute", func() -> void:
			graph.set_connection_attrib_on(name, indices, value)
		)
