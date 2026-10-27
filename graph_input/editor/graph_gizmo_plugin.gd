@tool
extends EditorNode3DGizmoPlugin

var editor: HEGoGraphEditor

const LINE := Color(0.55, 0.55, 0.6)
const LINE_HOVER := Color(0.45, 0.85, 1.0)
const LINE_SELECTED := Color(1.0, 0.5, 0.12)
const POINT := Color(0.92, 0.86, 0.35)
const POINT_HOVER := Color(1.0, 1.0, 1.0)
const POINT_SELECTED := Color(1.0, 0.38, 0.08)
const PREVIEW := Color(0.55, 0.85, 1.0, 0.85)

var _sphere: SphereMesh
var _sphere_selected: SphereMesh


func _init() -> void:
	create_material("lines", LINE, false, true)
	create_material("lines_hover", LINE_HOVER, false, true)
	create_material("lines_selected", LINE_SELECTED, false, true)
	create_material("preview", PREVIEW, false, true)
	create_material("point", POINT, false, true)
	create_material("point_hover", POINT_HOVER, false, true)
	create_material("point_selected", POINT_SELECTED, false, true)
	_sphere = _make_sphere(0.07)
	_sphere_selected = _make_sphere(0.11)


func _make_sphere(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 12
	mesh.rings = 6
	return mesh


func _get_gizmo_name() -> String:
	return "HEGoGraphInput3D"


func _get_priority() -> int:
	return 50


func _has_gizmo(for_node_3d: Node3D) -> bool:
	return for_node_3d is HEGoGraphInput3D


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d() as HEGoGraphInput3D
	if node == null:
		return

	var selected_pts := gizmo.get_subgizmo_selection()
	var selected_conns := PackedInt32Array()
	var hover_point := -1
	var hover_connection := -1
	if editor and editor.graph == node:
		editor.on_gizmo_redraw(gizmo)
		selected_conns = editor.selected_connections
		hover_point = editor.hover_point
		hover_connection = editor.hover_connection
		# Engine map may still be a frame behind after we create a point.
		selected_pts = gizmo.get_subgizmo_selection()
		editor.sync_point_selection(selected_pts)
		var held := editor.held_point_selection()
		if held.size() > 0:
			selected_pts = held
		elif editor.selected_points.size() > 0:
			selected_pts = editor.selected_points

	var lines := PackedVector3Array()
	var hover_lines := PackedVector3Array()
	var selected_lines := PackedVector3Array()
	for c in node.connection_count():
		var a: int = node.connections[c * 2]
		var b: int = node.connections[c * 2 + 1]
		if a < 0 or b < 0 or a >= node.points.size() or b >= node.points.size():
			continue
		if selected_conns.has(c):
			selected_lines.append(node.points[a])
			selected_lines.append(node.points[b])
		elif c == hover_connection:
			hover_lines.append(node.points[a])
			hover_lines.append(node.points[b])
		else:
			lines.append(node.points[a])
			lines.append(node.points[b])

	if lines.size() >= 2:
		gizmo.add_lines(lines, get_material("lines", gizmo), false)
	if hover_lines.size() >= 2:
		gizmo.add_lines(hover_lines, get_material("lines_hover", gizmo), false)
	if selected_lines.size() >= 2:
		gizmo.add_lines(selected_lines, get_material("lines_selected", gizmo), false)
		gizmo.add_lines(selected_lines, get_material("lines_selected", gizmo), false)

	var preview_from: int = editor.connect_from_point() if editor and editor.graph == node else -1
	if editor and editor.graph == node and editor.preview_cursor != null and preview_from >= 0:
		var preview := PackedVector3Array()
		preview.append(node.points[preview_from])
		preview.append(node.to_local(editor.preview_cursor))
		gizmo.add_lines(preview, get_material("preview", gizmo), false)

	for i in node.points.size():
		var selected := selected_pts.has(i)
		var mat_name := "point_selected" if selected else ("point_hover" if i == hover_point else "point")
		var mesh := _sphere_selected if selected else _sphere
		gizmo.add_mesh(mesh, get_material(mat_name, gizmo), Transform3D(Basis(), node.points[i]))


func _subgizmos_intersect_ray(gizmo: EditorNode3DGizmo, camera: Camera3D, screen_pos: Vector2) -> int:
	var node := gizmo.get_node_3d() as HEGoGraphInput3D
	if node == null or node.points.is_empty():
		return -1
	var projected := PackedVector2Array()
	projected.resize(node.points.size())
	for i in node.points.size():
		var global_pt: Vector3 = node.to_global(node.points[i])
		if camera.is_position_behind(global_pt):
			projected[i] = Vector2(-1e6, -1e6)
		else:
			projected[i] = camera.unproject_position(global_pt)
	return HEGoGraphPicking.closest_point(screen_pos, projected)


func _subgizmos_intersect_frustum(gizmo: EditorNode3DGizmo, camera: Camera3D, frustum_planes: Array) -> PackedInt32Array:
	var ids := PackedInt32Array()
	var node := gizmo.get_node_3d() as HEGoGraphInput3D
	if node == null:
		return ids
	for i in node.points.size():
		var p: Vector3 = node.to_global(node.points[i])
		var inside := true
		for plane in frustum_planes:
			if (plane as Plane).distance_to(p) < 0.0:
				inside = false
				break
		if inside:
			ids.append(i)
	return ids


func _get_subgizmo_transform(gizmo: EditorNode3DGizmo, subgizmo_id: int) -> Transform3D:
	var node := gizmo.get_node_3d() as HEGoGraphInput3D
	if subgizmo_id == HEGoGraphEditor.GROUP_SUBGIZMO:
		if editor and editor.graph == node:
			return Transform3D(Basis(), editor.group_center())
		return Transform3D()
	if node == null or subgizmo_id < 0 or subgizmo_id >= node.points.size():
		return Transform3D()
	return Transform3D(Basis(), node.points[subgizmo_id])


func _set_subgizmo_transform(gizmo: EditorNode3DGizmo, subgizmo_id: int, transform: Transform3D) -> void:
	var node := gizmo.get_node_3d() as HEGoGraphInput3D
	if subgizmo_id == HEGoGraphEditor.GROUP_SUBGIZMO:
		if editor and editor.graph == node:
			editor.move_group_live(transform.origin)
		return
	if node == null or subgizmo_id < 0 or subgizmo_id >= node.points.size():
		return
	# Location only: ignore basis so rotate/scale handles cannot twist a point.
	node.set_point_position_live(subgizmo_id, transform.origin)


func _commit_subgizmos(gizmo: EditorNode3DGizmo, ids: PackedInt32Array, restores: Array, cancel: bool) -> void:
	var node := gizmo.get_node_3d() as HEGoGraphInput3D
	if node == null:
		return
	# The group id restores from where each of its points started.
	var group_start: Dictionary = {}
	if ids.has(HEGoGraphEditor.GROUP_SUBGIZMO) and editor and editor.graph == node:
		group_start = editor.take_group_start()
	if cancel:
		for i in ids.size():
			if ids[i] != HEGoGraphEditor.GROUP_SUBGIZMO and i < restores.size() and restores[i] is Transform3D:
				node.set_point_position(ids[i], (restores[i] as Transform3D).origin)
		for p in group_start:
			node.set_point_position(p, group_start[p])
		return
	var after: Dictionary = node.capture_state()
	var before_points := node.points.duplicate()
	var moved := not group_start.is_empty()
	for i in ids.size():
		if ids[i] != HEGoGraphEditor.GROUP_SUBGIZMO and i < restores.size() and restores[i] is Transform3D:
			before_points[ids[i]] = (restores[i] as Transform3D).origin
			moved = true
	for p in group_start:
		if p < before_points.size():
			before_points[p] = group_start[p]
	if not moved:
		return
	var before := after.duplicate(true)
	before["points"] = before_points
	if editor and editor.plugin:
		var ur := editor.plugin.get_undo_redo()
		ur.create_action("Move graph points")
		ur.add_do_method(node, "apply_state", after)
		ur.add_undo_method(node, "apply_state", before)
		ur.commit_action(false)
