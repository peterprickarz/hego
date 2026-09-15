@tool
extends EditorNode3DGizmoPlugin

var editor: HEGoGraphEditor

const LINE := Color(0.85, 0.7, 0.25)
const LINE_SELECTED := Color(1.0, 0.45, 0.15)
const PREVIEW := Color(0.6, 0.85, 1.0, 0.8)


func _init() -> void:
	create_material("lines", LINE)
	create_material("lines_selected", LINE_SELECTED)
	create_material("preview", PREVIEW)
	create_handle_material("handles")


func _get_gizmo_name() -> String:
	return "HEGoGraphInput3D"


func _has_gizmo(for_node_3d: Node3D) -> bool:
	return for_node_3d is HEGoGraphInput3D


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d() as HEGoGraphInput3D
	if node == null:
		return

	var selected_conns := PackedInt32Array()
	var selected_pts := PackedInt32Array()
	if editor and editor.graph == node:
		selected_conns = editor.selected_connections
		selected_pts = editor.selected_points

	var lines := PackedVector3Array()
	var selected_lines := PackedVector3Array()
	for c in node.connection_count():
		var a: int = node.connections[c * 2]
		var b: int = node.connections[c * 2 + 1]
		if a < 0 or b < 0 or a >= node.points.size() or b >= node.points.size():
			continue
		if selected_conns.has(c):
			selected_lines.append(node.points[a])
			selected_lines.append(node.points[b])
		else:
			lines.append(node.points[a])
			lines.append(node.points[b])

	if lines.size() >= 2:
		gizmo.add_lines(lines, get_material("lines", gizmo), false)
	if selected_lines.size() >= 2:
		gizmo.add_lines(selected_lines, get_material("lines_selected", gizmo), false)

	if editor and editor.graph == node and editor.preview_cursor != null and editor.last_point >= 0 and editor.last_point < node.points.size():
		var preview := PackedVector3Array()
		preview.append(node.points[editor.last_point])
		preview.append(node.to_local(editor.preview_cursor))
		gizmo.add_lines(preview, get_material("preview", gizmo), false)

	if node.points.size() > 0:
		var ids := PackedInt32Array()
		ids.resize(node.points.size())
		for i in node.points.size():
			ids[i] = i
		gizmo.add_handles(node.points, get_material("handles", gizmo), ids)

	# Selected points get a second handle pass so they read as highlighted.
	if selected_pts.size() > 0:
		var selected_pos := PackedVector3Array()
		var selected_ids := PackedInt32Array()
		for i in selected_pts:
			if i >= 0 and i < node.points.size():
				selected_pos.append(node.points[i])
				selected_ids.append(i)
		if selected_pos.size() > 0:
			gizmo.add_handles(selected_pos, get_material("handles", gizmo), selected_ids)


func _get_handle_name(_gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool) -> String:
	return "Point %d" % handle_id


func _get_handle_value(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool) -> Variant:
	var node := gizmo.get_node_3d() as HEGoGraphInput3D
	if node == null or handle_id < 0 or handle_id >= node.points.size():
		return Vector3.ZERO
	return node.points[handle_id]


func _set_handle(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool, camera: Camera3D, screen_pos: Vector2) -> void:
	var node := gizmo.get_node_3d() as HEGoGraphInput3D
	if node == null or handle_id < 0 or handle_id >= node.points.size():
		return
	var origin := camera.project_ray_origin(screen_pos)
	var direction := camera.project_ray_normal(screen_pos)
	var anchor: Vector3 = node.to_global(node.points[handle_id])
	var plane := HEGoGraphPlacement.camera_plane(-camera.global_transform.basis.z, anchor)
	if editor and editor.placement_mode == HEGoGraphPlacement.Mode.WORLD:
		plane = HEGoGraphPlacement.world_plane(editor.world_axis, node.global_position, editor.world_offset)
	var hit: Variant = HEGoGraphPlacement.intersect_ray(origin, direction, plane)
	if hit == null:
		return
	node.set_point_position(handle_id, node.to_local(hit))
	node.update_gizmos()


func _commit_handle(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool, restore: Variant, cancel: bool) -> void:
	if editor:
		editor.commit_handle(handle_id, restore, cancel)
	else:
		var node := gizmo.get_node_3d() as HEGoGraphInput3D
		if node and cancel:
			node.set_point_position(handle_id, restore)
			node.update_gizmos()
