class_name HEGoGraphEditor
extends RefCounted

## Viewport editing for a selected [HEGoGraphInput3D].
##
## Point selection and the move/rotate/scale widget are Godot's built-in
## subgizmos. This object only handles Draw-mode clicks, connection picks,
## empty clicks that clear the selection, the right-click menu, and the
## attribute strip.

enum Mode {
	SELECT,
	DRAW,
}

const CLICK_PIXELS := 8.0

## Subgizmo id standing for the whole selection when it is more than one
## point, or has connections. Scripts can only give Godot one subgizmo id, so
## this one carries the move widget for all of them: its transform is their
## centre, and moving it moves every point in [method group_points].
const GROUP_SUBGIZMO := 0x3FFFFFFF

enum MenuId {
	SELECT,
	SPLIT,
	DELETE,
}

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
## Plain empty press handed to the 3D editor so its move arrows still drag.
## If it is released without moving, it clears the selection.
var _empty_click := false
var _box := false
var _reselecting := false
var _saved_tool_button: Button
## Point or connection under a right press, shown in the menu on release.
var _menu_point := -1
var _menu_connection := -1
var _menu_press_pos := Vector2.ZERO
## World position the menu's Split inserts at.
var _menu_split_at := Vector3.ZERO
var _context_menu: PopupMenu
## Index we just selected ourselves; ignore stale gizmo selection until Godot's
## deferred set_subgizmo_selection lands.
var _hold_selection := -1
## True while Godot's subgizmo selection is [constant GROUP_SUBGIZMO] because
## we put it there.
var _group_pushed := false
## Positions of the group's points when the current widget drag began.
var _group_start: Dictionary = {}
var _group_start_center := Vector3.ZERO


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
	_refresh_attrib_panel()


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
	if ids.has(GROUP_SUBGIZMO):
		if ids.size() == 1:
			return
		# Shift+click on a point while the group is selected: Godot adds
		# the point next to the group id. Toggle it in and rebuild the group.
		for id in ids:
			if id == GROUP_SUBGIZMO:
				continue
			var found := selected_points.find(id)
			if found >= 0:
				selected_points.remove_at(found)
			else:
				selected_points.append(id)
		_apply_selection()
		return
	if _group_pushed:
		# Godot replaced the group (plain click on a point, Escape, ...):
		# the connections go with it.
		_group_pushed = false
		selected_connections = PackedInt32Array()
		selected_points = ids.duplicate()
		if selected_points.size() > 0:
			last_point = selected_points[selected_points.size() - 1]
		graph.update_gizmos()
		_refresh_attrib_panel()
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
		if _try_connect_key(event) or _try_delete_key(event):
			return EditorPlugin.AFTER_GUI_INPUT_STOP

	if event is InputEventMouse:
		ctrl_held = event.ctrl_pressed

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		var menu_result := _on_right_button(camera, event)
		if menu_result != EditorPlugin.AFTER_GUI_INPUT_PASS:
			return menu_result

	if _is_camera_event(event):
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseMotion:
		return _on_motion(camera, event)

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			return _on_press(camera, event)
		return _on_release(camera, event)

	return EditorPlugin.AFTER_GUI_INPUT_PASS


## Key path that does not need the 3D viewport to have focus.
##
## _forward_3d_gui_input only sees keys while the viewport surface has focus,
## which it loses to the attribute strip, the scene tree, or any other panel
## the user clicked last. The plugin feeds keys here from _input, and they
## count while the mouse is over a 3D viewport and no text field has focus.
func handle_key_anywhere(event: InputEvent) -> bool:
	if graph == null or not is_instance_valid(graph):
		return false
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return false
	var focus := EditorInterface.get_base_control().get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return false
	if not _mouse_over_3d_viewport():
		return false
	return _try_connect_key(key) or _try_delete_key(key)


## Bare C connects exactly two selected points in either editing mode.
func _try_connect_key(event: InputEventKey) -> bool:
	if event.keycode != KEY_C or event.shift_pressed or event.ctrl_pressed \
			or event.alt_pressed or event.meta_pressed or _pressed \
			or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return false
	if selected_points.size() != 2:
		return false
	var a := selected_points[0]
	var b := selected_points[1]
	if a == b or a < 0 or b < 0 or a >= graph.points.size() or b >= graph.points.size():
		return false
	# Consume an already connected pair without creating a redundant undo step.
	if not graph.has_connection(a, b):
		_mutate("Connect graph points", func() -> void:
			graph.add_connection(a, b)
		)
	return true


func _try_delete_key(event: InputEventKey) -> bool:
	if not _is_delete_key(event):
		return false
	if selected_points.is_empty() and selected_connections.is_empty():
		return false
	_delete_selection()
	return true


func _mouse_over_3d_viewport() -> bool:
	for i in 4:
		var vp := EditorInterface.get_editor_viewport_3d(i)
		if vp == null:
			continue
		var container := vp.get_parent() as Control
		if container and container.is_visible_in_tree() \
				and container.get_global_rect().has_point(container.get_global_mouse_position()):
			return true
	return false


func _is_delete_key(event: InputEventKey) -> bool:
	if event.keycode == KEY_DELETE or event.keycode == KEY_BACKSPACE:
		return true
	# Bare X only: Shift+X and friends are Godot's axis locks, Ctrl+X is cut,
	# and X during an arrow drag locks the axis.
	return event.keycode == KEY_X and not (event.shift_pressed or event.ctrl_pressed
			or event.alt_pressed or event.meta_pressed) and not _pressed \
			and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)


func _on_press(camera: Camera3D, event: InputEventMouseButton) -> int:
	_press_pos = event.position
	_pointer = event.position
	_pressed = true
	_drag_started = false
	_own_click = false
	_empty_click = false
	_box = false
	_update_hover(camera, event.position)

	var empty := hover_point < 0 and hover_connection < 0
	if event.shift_pressed and empty:
		_own_click = true
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	# Ctrl+empty always places, even on top of the widget: connected to the
	# selected point, or loose when nothing is selected.
	if mode == Mode.DRAW and event.ctrl_pressed and empty:
		_own_click = true
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if mode == Mode.DRAW and event.ctrl_pressed and hover_point >= 0:
		_own_click = true
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	# Connections are ours: click selects, Ctrl+click in Draw splits.
	if hover_connection >= 0:
		_own_click = true
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	# Nothing selected means no widget to drag: the click (or box) is ours.
	if empty and not _has_point_selection() and not _group_pushed:
		_own_click = true
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	# Anything else (move arrows, selected point, empty while a point is
	# selected) goes to the 3D editor so the translate widget can drag. An
	# empty press that comes back without moving clears the selection.
	_empty_click = empty
	if not _empty_click:
		_pressed = false
	return EditorPlugin.AFTER_GUI_INPUT_CUSTOM


func _on_motion(camera: Camera3D, event: InputEventMouseMotion) -> int:
	_pointer = event.position
	# While the built-in widget is dragging, do not rebuild gizmos or hover.
	if event.button_mask & MOUSE_BUTTON_MASK_LEFT and not _own_click:
		if _empty_click and event.position.distance_to(_press_pos) > CLICK_PIXELS:
			_empty_click = false
			_pressed = false
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
	if ctrl_held and connect_from_point() >= 0 and mode == Mode.DRAW:
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
	if _empty_click:
		_empty_click = false
		_clear_selection()
		# Still CUSTOM so the 3D editor ends whatever it began on press.
		return EditorPlugin.AFTER_GUI_INPUT_CUSTOM
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
	_empty_click = false
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

	var connect_from := connect_from_point()

	# Only Ctrl+click in Draw places a point; any other empty click drops
	# the current selection.
	if hover_point < 0 and hover_connection < 0 and (shift or not ctrl or mode != Mode.DRAW):
		_clear_selection()
		return

	if hover_point >= 0:
		if mode == Mode.DRAW and ctrl:
			var to_point := hover_point
			if connect_from >= 0 and connect_from != to_point:
				_mutate("Connect graph points", func() -> void:
					graph.add_connection(connect_from, to_point)
				)
			_select_point_subgizmo(to_point)
		return

	if hover_connection >= 0:
		if mode == Mode.DRAW and ctrl and not shift:
			_split_connection(hover_connection, _split_position(camera, mouse, hover_connection))
			return
		# Click selects the edge; Shift toggles it into the selection.
		if not shift:
			_clear_point_selection()
		_select_connections(PackedInt32Array([hover_connection]), shift)
		return

	var hit: Variant = _hit(camera, mouse)
	if hit == null:
		return
	var local_hit: Vector3 = graph.to_local(hit)
	var before: Dictionary = graph.capture_state()
	var new_index := graph.add_point(local_hit)
	if connect_from >= 0:
		graph.add_connection(connect_from, new_index)
	_commit_state("Add graph point", before)
	_select_point_subgizmo(new_index)


## Point on connection [param conn] under [param mouse], in world space.
##
## The closest point between the view ray and the segment, so the split lands
## under the cursor whatever the placement plane.
func _split_position(camera: Camera3D, mouse: Vector2, conn: int) -> Vector3:
	var a := graph.to_global(graph.points[graph.connections[conn * 2]])
	var b := graph.to_global(graph.points[graph.connections[conn * 2 + 1]])
	var origin := camera.project_ray_origin(mouse)
	var far := origin + camera.project_ray_normal(mouse) * maxf(camera.far, 10000.0)
	var closest := Geometry3D.get_closest_points_between_segments(origin, far, a, b)
	return closest[1]


func _split_connection(conn: int, world_pos: Vector3) -> void:
	if conn < 0 or conn >= graph.connection_count():
		return
	var local := graph.to_local(world_pos)
	# Do not assign the new index inside a lambda: GDScript captures
	# ints by value, so the outer variable would stay -1.
	var before: Dictionary = graph.capture_state()
	var new_index := graph.split_connection(conn, local)
	selected_connections = PackedInt32Array()
	_commit_state("Split graph connection", before)
	_select_point_subgizmo(new_index)


func _on_right_button(camera: Camera3D, event: InputEventMouseButton) -> int:
	if event.pressed:
		_menu_point = -1
		_menu_connection = -1
		if event.shift_pressed or event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		_update_hover(camera, event.position)
		if hover_point < 0 and hover_connection < 0:
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		# Taking the press keeps Godot from starting freelook over an element.
		_menu_point = hover_point
		_menu_connection = hover_connection
		_menu_press_pos = event.position
		if _menu_connection >= 0:
			_menu_split_at = _split_position(camera, event.position, _menu_connection)
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if _menu_point < 0 and _menu_connection < 0:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if event.position.distance_to(_menu_press_pos) <= CLICK_PIXELS:
		_show_context_menu(camera, event.position)
	else:
		_menu_point = -1
		_menu_connection = -1
	return EditorPlugin.AFTER_GUI_INPUT_STOP


func _show_context_menu(camera: Camera3D, mouse: Vector2) -> void:
	if _context_menu == null:
		_context_menu = PopupMenu.new()
		_context_menu.id_pressed.connect(_on_context_menu_id)
		EditorInterface.get_base_control().add_child(_context_menu)
	_context_menu.clear()
	_context_menu.add_item("Select", MenuId.SELECT)
	if _menu_connection >= 0:
		_context_menu.add_item("Split", MenuId.SPLIT)
	_context_menu.add_item("Delete", MenuId.DELETE)
	_context_menu.reset_size()
	var screen := Vector2(DisplayServer.mouse_get_position())
	var container := camera.get_viewport().get_parent() as Control
	if container:
		screen = container.get_screen_position() + mouse
	_context_menu.popup(Rect2i(Vector2i(screen), Vector2i.ZERO))


func _on_context_menu_id(id: int) -> void:
	var point := _menu_point
	var conn := _menu_connection
	_menu_point = -1
	_menu_connection = -1
	if graph == null or not is_instance_valid(graph):
		return
	if point >= 0 and point < graph.points.size():
		match id:
			MenuId.SELECT:
				selected_connections = PackedInt32Array()
				_select_point_subgizmo(point)
			MenuId.DELETE:
				_mutate("Delete graph point", func() -> void:
					graph.remove_points(PackedInt32Array([point]))
				)
				_clear_selection()
				last_point = -1
	elif conn >= 0 and conn < graph.connection_count():
		match id:
			MenuId.SELECT:
				_clear_point_selection()
				_select_connections(PackedInt32Array([conn]), false)
			MenuId.SPLIT:
				_split_connection(conn, _menu_split_at)
			MenuId.DELETE:
				_mutate("Delete graph connection", func() -> void:
					graph.remove_connections(PackedInt32Array([conn]))
				)
				# Connection indices shift; points are untouched.
				selected_connections = PackedInt32Array()
				graph.update_gizmos()
				_refresh_attrib_panel()


## Frees the right-click menu; the plugin calls this on exit.
func cleanup() -> void:
	if _context_menu and is_instance_valid(_context_menu):
		_context_menu.queue_free()
	_context_menu = null


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
	return selected_points.size() > 0 or _hold_selection >= 0


## Point a Ctrl+click connects from, or -1 when no point is selected.
func connect_from_point() -> int:
	if graph == null or not _has_point_selection():
		return -1
	if last_point >= 0 and last_point < graph.points.size() \
			and (_hold_selection == last_point or selected_points.has(last_point)):
		return last_point
	if selected_points.size() > 0 and selected_points[-1] < graph.points.size():
		return selected_points[-1]
	return -1


func _select_point_subgizmo(index: int) -> void:
	if graph == null or index < 0 or index >= graph.points.size():
		return
	last_point = index
	selected_points = PackedInt32Array([index])
	selected_connections = PackedInt32Array()
	_group_pushed = false
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
	_push_engine_id(index, Transform3D(Basis(), graph.points[index]))


## Hands Godot [param id] as the only selected subgizmo. False when the gizmo
## does not exist yet.
func _push_engine_id(id: int, xf: Transform3D) -> bool:
	var giz: Variant = active_gizmo
	if giz == null:
		var gizmos := graph.get_gizmos()
		if gizmos.size() > 0:
			giz = gizmos[0]
			active_gizmo = giz
	if giz == null:
		return false
	var spatial := _spatial_editor()
	if spatial and spatial.has_method("_set_subgizmo_selection"):
		spatial.call("_set_subgizmo_selection", graph, giz, id, xf)
		if spatial.has_method("update_transform_gizmo"):
			spatial.call("update_transform_gizmo")
	else:
		graph.set_subgizmo_selection(giz, id, xf)
	return true


## Points the group widget moves: the selected points plus both ends of every
## selected connection.
func group_points() -> PackedInt32Array:
	var ids := PackedInt32Array()
	if graph == null:
		return ids
	for p in selected_points:
		if p >= 0 and p < graph.points.size() and not ids.has(p):
			ids.append(p)
	for c in selected_connections:
		if c < 0 or c >= graph.connection_count():
			continue
		for end in [graph.connections[c * 2], graph.connections[c * 2 + 1]]:
			if not ids.has(end):
				ids.append(end)
	return ids


## Local-space centre of [method group_points].
func group_center() -> Vector3:
	var ids := group_points()
	if ids.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for p in ids:
		sum += graph.points[p]
	return sum / ids.size()


## Moves the group so its centre sits at [param center]. Offsets are taken
## from where the points were when the drag began, so a point shared by two
## selected connections moves once.
func move_group_live(center: Vector3) -> void:
	if _group_start.is_empty():
		for p in group_points():
			_group_start[p] = graph.points[p]
		_group_start_center = group_center()
	var delta := center - _group_start_center
	for p in _group_start:
		graph.set_point_position_live(p, _group_start[p] + delta)


## Ends a group drag. Returns the positions from before it, keyed by point.
func take_group_start() -> Dictionary:
	var start := _group_start
	_group_start = {}
	return start


## Pushes Godot's subgizmo selection to match ours: nothing, one point, or
## the group.
func _apply_selection() -> void:
	_group_start = {}
	if selected_connections.is_empty() and selected_points.size() == 1:
		_select_point_subgizmo(selected_points[0])
		return
	_hold_selection = -1
	if selected_connections.is_empty() and selected_points.is_empty():
		_clear_point_selection()
	else:
		_group_pushed = _push_engine_id(GROUP_SUBGIZMO, Transform3D(Basis(), group_center()))
	if selected_points.size() > 0:
		last_point = selected_points[selected_points.size() - 1]
	if graph:
		graph.update_gizmos()
	_refresh_attrib_panel()


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
	_apply_selection()


func _clear_point_selection() -> void:
	selected_points = PackedInt32Array()
	_hold_selection = -1
	_group_pushed = false
	_group_start = {}
	if graph == null:
		return
	var spatial := _spatial_editor()
	if spatial and spatial.has_method("_clear_subgizmo_selection"):
		spatial.call("_clear_subgizmo_selection", graph)
	else:
		graph.clear_subgizmo_selection()


func _clear_selection() -> void:
	selected_connections = PackedInt32Array()
	preview_cursor = null
	_clear_point_selection()
	if graph:
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
	# The box is ours, not Godot's frustum select, so apply points here and
	# hand Godot the matching subgizmo (one point, or the group).
	if not additive:
		selected_points = pts
	else:
		for index in pts:
			if selected_points.find(index) < 0:
				selected_points.append(index)
	_apply_selection()


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


func _mutate(action: String, fn: Callable) -> void:
	var before: Dictionary = graph.capture_state()
	fn.call()
	_commit_state(action, before)


func _commit_state(action: String, before: Dictionary) -> void:
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
