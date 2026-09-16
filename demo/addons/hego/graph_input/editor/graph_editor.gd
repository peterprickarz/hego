class_name HEGoGraphEditor
extends RefCounted

## Viewport editing for a selected [HEGoGraphInput3D].
##
## Point selection and the move/rotate/scale widget are Godot's built-in
## subgizmos. This object only handles Draw-mode clicks, connection picks,
## Shift+empty to clear, and the attribute strip.

enum Mode {
	SELECT,
	DRAW,
}

const CLICK_PIXELS := 8.0

var plugin: EditorPlugin
var gizmo_plugin: EditorNode3DGizmoPlugin
## Filled by the gizmo plugin on redraw. Node3D.get_gizmos() is empty on a
## scripted Node3D, so this is how we call set_subgizmo_selection.
var active_gizmo: EditorNode3DGizmo
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

var _press_pos := Vector2.ZERO
var _pointer := Vector2.ZERO
var _pressed := false
var _drag_started := false
var _own_click := false
var _box := false
var _reselecting := false
var _saved_tool_button: Button
## Index we just selected ourselves; ignore stale gizmo selection until Godot's
## deferred set_subgizmo_selection lands.
var _hold_selection := -1


func edit(object: Object) -> void:
	if _reselecting and object == graph:
		return
	_cancel_pointer()
	if graph != null and graph.graph_changed.is_connected(_on_graph_changed):
		graph.graph_changed.disconnect(_on_graph_changed)
	graph = object as HEGoGraphInput3D
	selected_points = PackedInt32Array()
	selected_connections = PackedInt32Array()
	last_point = -1
	_hold_selection = -1
	hover_point = -1
	hover_connection = -1
	preview_cursor = null
	if graph != null:
		if not graph.graph_changed.is_connected(_on_graph_changed):
			graph.graph_changed.connect(_on_graph_changed)
		graph.update_gizmos()


func set_visible(visible: bool) -> void:
	if _reselecting:
		return
	if toolbar:
		toolbar.visible = visible
	if attrib_panel:
		attrib_panel.visible = visible
	if not visible:
		_restore_spatial_tool()
		edit(null)
	else:
		_use_move_tool()
		_refresh_attrib_panel()


func held_point_selection() -> PackedInt32Array:
	if _hold_selection >= 0:
		return selected_points
	return PackedInt32Array()


func sync_point_selection(ids: PackedInt32Array) -> void:
	if _hold_selection >= 0:
		if ids.size() == 1 and ids[0] == _hold_selection:
			_hold_selection = -1
		else:
			return
	if _ids_equal(selected_points, ids):
		return
	selected_points = ids.duplicate()
	if selected_points.size() > 0:
		last_point = selected_points[selected_points.size() - 1]
	_refresh_attrib_panel()


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
	_drag_started = false
	_own_click = false
	_box = false
	_update_hover(camera, event.position)

	var empty := hover_point < 0 and hover_connection < 0
	if event.shift_pressed and empty:
		_own_click = true
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	# Continue a polyline: Ctrl+empty always places, even on top of the widget.
	if mode == Mode.DRAW and event.ctrl_pressed and empty:
		_own_click = true
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if mode == Mode.DRAW and event.ctrl_pressed and hover_point >= 0:
		_own_click = true
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if mode == Mode.DRAW and hover_connection >= 0:
		_own_click = true
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if hover_connection >= 0:
		_own_click = true
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	# First point, or an isolated add with nothing selected: Draw on empty.
	if mode == Mode.DRAW and empty and not _has_point_selection():
		_own_click = true
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	# Anything else (move arrows, selected point, empty while a point is
	# selected) goes to the 3D editor so the translate widget can drag.
	_pressed = false
	return EditorPlugin.AFTER_GUI_INPUT_CUSTOM


func _on_motion(camera: Camera3D, event: InputEventMouseMotion) -> int:
	_pointer = event.position
	# While the built-in widget is dragging, do not rebuild gizmos or hover.
	if event.button_mask & MOUSE_BUTTON_MASK_LEFT and not _own_click:
		return EditorPlugin.AFTER_GUI_INPUT_CUSTOM
	if _pressed and not _drag_started and event.position.distance_to(_press_pos) > CLICK_PIXELS:
		_drag_started = true
		if _own_click and mode == Mode.SELECT:
			_box = true

	if _pressed and _drag_started and _box:
		plugin.update_overlays()
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
	if _pressed and _own_click:
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_CUSTOM


func _on_release(camera: Camera3D, event: InputEventMouseButton) -> int:
	if not _pressed:
		return EditorPlugin.AFTER_GUI_INPUT_CUSTOM
	_pressed = false
	if _box:
		_finish_box(camera, event.shift_pressed)
		_box = false
		_drag_started = false
		plugin.update_overlays()
		graph.update_gizmos()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if _own_click and not _drag_started:
		_click(camera, event.position, event.shift_pressed, event.ctrl_pressed)
		_drag_started = false
		_own_click = false
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	_drag_started = false
	_own_click = false
	return EditorPlugin.AFTER_GUI_INPUT_CUSTOM


func _cancel_pointer() -> void:
	_pressed = false
	_drag_started = false
	_own_click = false
	_box = false
	if plugin:
		plugin.update_overlays()


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

	# Shift+empty never places a point; it drops the current selection.
	if hover_point < 0 and hover_connection < 0 and shift:
		_clear_selection()
		return

	if hover_point >= 0:
		if mode == Mode.DRAW and ctrl and last_point >= 0:
			var to_point := hover_point
			_mutate("Connect graph points", func() -> void:
				graph.add_connection(last_point, to_point)
			)
			_select_point_subgizmo(to_point)
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
			var new_index := -1
			_mutate("Split graph connection", func() -> void:
				new_index = graph.split_connection(conn, local)
			)
			_select_point_subgizmo(new_index)
		else:
			_select_connections(PackedInt32Array([hover_connection]), shift)
		return

	if mode != Mode.DRAW:
		_clear_selection()
		return

	var hit: Variant = _hit(camera, mouse)
	if hit == null:
		return
	var local_hit: Vector3 = graph.to_local(hit)
	var connect_from := last_point if ctrl else -1
	var new_index := -1
	_mutate("Add graph point", func() -> void:
		new_index = graph.add_point(local_hit)
		if connect_from >= 0:
			graph.add_connection(connect_from, new_index)
	)
	_select_point_subgizmo(new_index)


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


func _has_point_selection() -> bool:
	return selected_points.size() > 0 or _hold_selection >= 0 or last_point >= 0


func _select_point_subgizmo(index: int) -> void:
	if graph == null or index < 0 or index >= graph.points.size():
		return
	last_point = index
	selected_points = PackedInt32Array([index])
	selected_connections = PackedInt32Array()
	_hold_selection = index
	# Node3D.set_subgizmo_selection is group-deferred, so a redraw from
	# add_point can restore the previous id before it lands. Talk to
	# Node3DEditor immediately, then once more next frame if the gizmo
	# did not exist yet.
	_push_engine_subgizmo(index)
	if graph:
		graph.update_gizmos()
		_schedule_subgizmo_retry()
	_refresh_attrib_panel()


func on_gizmo_redraw(gizmo: EditorNode3DGizmo) -> void:
	active_gizmo = gizmo
	if _hold_selection >= 0 and not gizmo.is_subgizmo_selected(_hold_selection):
		_push_engine_subgizmo(_hold_selection)


func _push_engine_subgizmo(index: int) -> void:
	if graph == null or index < 0 or index >= graph.points.size():
		return
	var giz: Variant = active_gizmo
	if giz == null:
		var gizmos := graph.get_gizmos()
		if gizmos.size() > 0:
			giz = gizmos[0]
			active_gizmo = giz
	if giz == null:
		return
	var xf := Transform3D(Basis(), graph.points[index])
	var spatial := _spatial_editor()
	if spatial and spatial.has_method("_set_subgizmo_selection"):
		spatial.call("_set_subgizmo_selection", graph, giz, index, xf)
		if spatial.has_method("update_transform_gizmo"):
			spatial.call("update_transform_gizmo")
	else:
		graph.set_subgizmo_selection(giz, index, xf)


func _schedule_subgizmo_retry() -> void:
	if graph == null or not is_instance_valid(graph):
		return
	var tree := graph.get_tree()
	if tree == null:
		return
	if tree.process_frame.is_connected(_finish_point_selection):
		return
	tree.process_frame.connect(_finish_point_selection, CONNECT_ONE_SHOT)


func _finish_point_selection() -> void:
	if _hold_selection < 0 or graph == null or not is_instance_valid(graph):
		return
	_push_engine_subgizmo(_hold_selection)
	graph.update_gizmos()


func _select_connections(indices: PackedInt32Array, additive: bool) -> void:
	if not additive:
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
	_hold_selection = -1
	if graph:
		var spatial := _spatial_editor()
		if spatial and spatial.has_method("_clear_subgizmo_selection"):
			spatial.call("_clear_subgizmo_selection", graph)
		else:
			graph.clear_subgizmo_selection()
		graph.update_gizmos()
	_refresh_attrib_panel()


func draw_overlay(overlay: Control) -> void:
	if not _pressed or not _box or not _drag_started:
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
		selected_connections = PackedInt32Array()
	for index in cons:
		if selected_connections.find(index) < 0:
			selected_connections.append(index)
	# Point box-select is left to Godot subgizmos when CUSTOM/PASS is used.
	# Our overlay box still records connections; points come from subgizmo frustum
	# only if the 3D editor ran it. Apply points ourselves so mixed boxes work.
	if not additive:
		selected_points = pts
	else:
		for index in pts:
			if selected_points.find(index) < 0:
				selected_points.append(index)
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
	var plane: Plane
	if placement_mode == HEGoGraphPlacement.Mode.WORLD:
		plane = HEGoGraphPlacement.world_plane(world_axis, graph.global_position, world_offset)
	else:
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
	_refresh_attrib_panel()


func _refresh_attrib_panel() -> void:
	if attrib_panel and attrib_panel.has_method("rebuild"):
		attrib_panel.rebuild(graph, selected_points, selected_connections)


func _spatial_editor() -> Node:
	var found := EditorInterface.get_base_control().find_children("*", "Node3DEditor", true, false)
	return found[0] if not found.is_empty() else null


func _spatial_tool_button(keycode: int) -> Button:
	var spatial := _spatial_editor()
	if spatial == null:
		return null
	for node in spatial.find_children("*", "Button", true, false):
		var button := node as Button
		if button == null or button.shortcut == null:
			continue
		for ev in button.shortcut.events:
			if ev is InputEventKey and ev.keycode == keycode and not ev.shift_pressed and not ev.ctrl_pressed and not ev.alt_pressed and not ev.meta_pressed:
				return button
	return null


func _use_move_tool() -> void:
	var move := _spatial_tool_button(KEY_W)
	if move == null:
		return
	if _saved_tool_button == null:
		for key in [KEY_Q, KEY_W, KEY_E, KEY_R]:
			var button := _spatial_tool_button(key)
			if button and button.button_pressed:
				_saved_tool_button = button
				break
	if not move.button_pressed:
		move.pressed.emit()


func _restore_spatial_tool() -> void:
	if _saved_tool_button and not _saved_tool_button.button_pressed:
		_saved_tool_button.pressed.emit()
	_saved_tool_button = null


func _ids_equal(a: PackedInt32Array, b: PackedInt32Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true


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
