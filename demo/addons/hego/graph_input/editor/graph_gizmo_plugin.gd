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
const AXIS_X := Color(0.92, 0.22, 0.2)
const AXIS_Y := Color(0.25, 0.82, 0.3)
const AXIS_Z := Color(0.25, 0.45, 1.0)

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
	create_material("axis_x", AXIS_X, false, true)
	create_material("axis_y", AXIS_Y, false, true)
	create_material("axis_z", AXIS_Z, false, true)
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

	var selected_conns := PackedInt32Array()
	var selected_pts := PackedInt32Array()
	var hover_point := -1
	var hover_connection := -1
	if editor and editor.graph == node:
		selected_conns = editor.selected_connections
		selected_pts = editor.selected_points
		hover_point = editor.hover_point
		hover_connection = editor.hover_connection

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
		# A second copy so selected edges read thicker than the rest.
		gizmo.add_lines(selected_lines, get_material("lines_selected", gizmo), false)

	if editor and editor.graph == node and editor.preview_cursor != null and editor.last_point >= 0 and editor.last_point < node.points.size():
		var preview := PackedVector3Array()
		preview.append(node.points[editor.last_point])
		preview.append(node.to_local(editor.preview_cursor))
		gizmo.add_lines(preview, get_material("preview", gizmo), false)

	for i in node.points.size():
		var selected := selected_pts.has(i)
		var mat_name := "point_selected" if selected else ("point_hover" if i == hover_point else "point")
		var mesh := _sphere_selected if selected else _sphere
		gizmo.add_mesh(mesh, get_material(mat_name, gizmo), Transform3D(Basis(), node.points[i]))

	if selected_pts.size() > 0:
		var origin := Vector3.ZERO
		var count := 0
		for i in selected_pts:
			if i >= 0 and i < node.points.size():
				origin += node.points[i]
				count += 1
		if count > 0:
			origin /= float(count)
			var axis_len := 0.45
			if editor:
				editor.gizmo_origin = origin
				axis_len = editor.axis_length
			_add_axis(gizmo, origin, Vector3.RIGHT, axis_len, "axis_x")
			_add_axis(gizmo, origin, Vector3.UP, axis_len, "axis_y")
			_add_axis(gizmo, origin, Vector3.BACK, axis_len, "axis_z")


func _add_axis(gizmo: EditorNode3DGizmo, origin: Vector3, dir: Vector3, length: float, mat_name: String) -> void:
	var tip := origin + dir * length
	var line := PackedVector3Array()
	line.append(origin)
	line.append(tip)
	gizmo.add_lines(line, get_material(mat_name, gizmo), false)
	gizmo.add_mesh(_sphere, get_material(mat_name, gizmo), Transform3D(Basis(), tip))
