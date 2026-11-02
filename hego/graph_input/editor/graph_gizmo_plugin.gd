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

## Size multipliers for highlighted markers, relative to the editor settings.
const POINT_HOVER_SCALE := 1.3
const POINT_SELECTED_SCALE := 1.6
const LINE_HOVER_SCALE := 1.5
const LINE_SELECTED_SCALE := 2.0

var _point_material: ShaderMaterial
var _line_material: ShaderMaterial


func _init() -> void:
	HEGoGraphPicking.register_settings()
	_point_material = ShaderMaterial.new()
	_point_material.shader = preload("graph_point.gdshader")
	_point_material.render_priority = 10
	_line_material = ShaderMaterial.new()
	_line_material.shader = preload("graph_line.gdshader")
	_line_material.render_priority = 9


## Point markers and connection lines keep a constant size in screen pixels. Sizes come
## from the editor settings hego/graph/point_size and hego/graph/line_width.
func _apply_sizes() -> void:
	_point_material.set_shader_parameter("point_px", HEGoGraphPicking.point_size())
	_line_material.set_shader_parameter("line_px", HEGoGraphPicking.line_width())


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

	# Path mode: ribbon or tube with its outline, as gizmo geometry so that View > Gizmos
	# hides it and it never exists outside the editor.
	var path_mesh := node.get_path_mesh()
	if path_mesh != null and path_mesh.get_surface_count() > 0:
		gizmo.add_mesh(path_mesh)

	_apply_sizes()
	var line_quads := _ScreenLines.new()
	for c in node.connection_count():
		var a: int = node.connections[c * 2]
		var b: int = node.connections[c * 2 + 1]
		if a < 0 or b < 0 or a >= node.points.size() or b >= node.points.size():
			continue
		if selected_conns.has(c):
			line_quads.add(node.points[a], node.points[b], LINE_SELECTED, LINE_SELECTED_SCALE)
		elif c == hover_connection:
			line_quads.add(node.points[a], node.points[b], LINE_HOVER, LINE_HOVER_SCALE)
		else:
			line_quads.add(node.points[a], node.points[b], LINE, 1.0)

	var preview_from: int = editor.connect_from_point() if editor and editor.graph == node else -1
	if editor and editor.graph == node and editor.preview_cursor != null and preview_from >= 0:
		line_quads.add(node.points[preview_from], node.to_local(editor.preview_cursor), PREVIEW, 1.0)

	var markers := PackedVector3Array()
	var marker_colors := PackedColorArray()
	var marker_scales := PackedFloat32Array()
	for i in node.points.size():
		markers.append(node.points[i])
		if selected_pts.has(i):
			marker_colors.append(POINT_SELECTED)
			marker_scales.append(POINT_SELECTED_SCALE)
		elif i == hover_point:
			marker_colors.append(POINT_HOVER)
			marker_scales.append(POINT_HOVER_SCALE)
		else:
			marker_colors.append(POINT)
			marker_scales.append(1.0)

	var line_mesh := line_quads.build()
	if line_mesh != null:
		line_mesh.custom_aabb = _padded_bounds(line_quads.vertices)
		gizmo.add_mesh(line_mesh, _line_material)
	var point_mesh := _build_markers(markers, marker_colors, marker_scales)
	if point_mesh != null:
		gizmo.add_mesh(point_mesh, _point_material)


static func _build_markers(positions: PackedVector3Array, colors: PackedColorArray, scales: PackedFloat32Array) -> ArrayMesh:
	if positions.is_empty():
		return null
	var corners := [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var cols := PackedColorArray()
	var indices := PackedInt32Array()
	for i in positions.size():
		var base := vertices.size()
		for corner in corners:
			vertices.append(positions[i])
			uvs.append(corner)
			uv2s.append(Vector2(scales[i], 0.0))
			cols.append(colors[i])
		indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.custom_aabb = _padded_bounds(positions)
	return mesh


## Bounds of the markers grown by a lot, because their real size is set on screen and
## the engine would otherwise cull them by their zero-size quads.
static func _padded_bounds(positions: PackedVector3Array) -> AABB:
	var box := AABB(positions[0], Vector3.ZERO)
	for p in positions:
		box = box.expand(p)
	return box.grow(maxf(box.get_longest_axis_size() * 0.05, 100.0))


## Collects line segments as screen-width quads for graph_line.gdshader.
class _ScreenLines:
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var others := PackedFloat32Array()
	var cols := PackedColorArray()
	var indices := PackedInt32Array()

	func add(from: Vector3, to: Vector3, color: Color, scale: float) -> void:
		var base := vertices.size()
		for end in [[from, to, -1.0], [from, to, 1.0], [to, from, 1.0], [to, from, -1.0]]:
			vertices.append(end[0])
			uvs.append(Vector2(end[2], 0.0))
			others.append_array([end[1].x, end[1].y, end[1].z, scale])
			cols.append(color)
		indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])

	func build() -> ArrayMesh:
		if vertices.is_empty():
			return null
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_CUSTOM0] = others
		arrays[Mesh.ARRAY_COLOR] = cols
		arrays[Mesh.ARRAY_INDEX] = indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
				Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		return mesh


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
	return HEGoGraphPicking.closest_point(screen_pos, projected, HEGoGraphPicking.point_radius())


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
