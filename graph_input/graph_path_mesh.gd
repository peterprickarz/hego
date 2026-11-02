class_name HEGoGraphPathMesh
extends RefCounted

## Builds the path visualisation of a [HEGoGraphInput3D]: a translucent ribbon or tube
## along every connection, with an outline, in the graph's local space.
##
## Ribbon rows are oriented to the surface normal (from a [HEGoGraphSurface], else up).
## Where connections meet, every arm is cut back far enough that neighbouring edges
## meet, and the gap is filled by a fan around the node, so overlapping connections
## never double the transparency and sharp turns stay clean. A tube is a cylinder per
## connection plus a sphere at each node.

const MAX_SEGMENTS := 512
const MIN_EDGE := 0.0001

var _graph: HEGoGraphInput3D
var _surface: HEGoGraphSurface
var _fill := PackedVector3Array()
var _lines := PackedVector3Array()

var _drape := true
var _spacing := 4.0
var _lift := 0.05
var _default_width := 2.0
var _sides := 12
var _outline := true

var _node_pos := PackedVector3Array()
var _node_normal := PackedVector3Array()
var _point_width := PackedFloat32Array()
var _conn_width := PackedFloat32Array()


## Builds the mesh for [param graph]. [param surface] may be null.
static func build(graph: HEGoGraphInput3D, surface: HEGoGraphSurface) -> ArrayMesh:
	var builder := HEGoGraphPathMesh.new()
	return builder._build(graph, surface)


func _build(graph: HEGoGraphInput3D, surface: HEGoGraphSurface) -> ArrayMesh:
	_graph = graph
	_surface = surface if surface != null and surface.is_available() else null
	_drape = graph.path_drape
	_spacing = maxf(graph.path_sample_spacing, 0.25)
	_lift = graph.path_lift
	_default_width = maxf(graph.path_default_width, 0.01)
	_sides = clampi(graph.path_tube_sides, 4, 64)
	_outline = graph.path_outline
	_read_widths()
	_read_nodes()

	if graph.path_shape == HEGoGraphInput3D.PathShape.TUBE:
		_build_tube()
	else:
		_build_ribbon()

	var mesh := ArrayMesh.new()
	if not _fill.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = _fill
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material(graph.path_color, 0))
	if not _lines.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = _lines
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material(graph.path_outline_color, 1))
	return mesh


static func _material(color: Color, priority: int) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = color
	mat.render_priority = priority
	if color.a < 0.999:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat


# --- inputs ---------------------------------------------------------------------------

func _read_widths() -> void:
	var name := String(_graph.path_width_attribute)
	_point_width = _numeric_attrib(_graph.point_attribs.get(name), _graph.points.size())
	_conn_width = _numeric_attrib(_graph.connection_attribs.get(name), _graph.connection_count())


## Attribute values as floats, or 0 for "not set", sized to [param count].
static func _numeric_attrib(values: Variant, count: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(count)
	if values is PackedFloat32Array or values is PackedInt32Array or values is PackedFloat64Array:
		for i in mini(count, values.size()):
			out[i] = float(values[i])
	return out


func _read_nodes() -> void:
	var count := _graph.points.size()
	_node_pos.resize(count)
	_node_normal.resize(count)
	for i in count:
		var ground := _ground(_graph.points[i], _graph.points[i].y)
		_node_pos[i] = ground.position
		_node_normal[i] = ground.normal


## Surface position and normal under [param local], or the point itself and up.
func _ground(local: Vector3, fallback_y: float) -> Dictionary:
	if _drape and _surface != null:
		var hit := _surface.query_local(local)
		if not hit.is_empty():
			return hit
	return {"position": Vector3(local.x, fallback_y, local.z), "normal": Vector3.UP}


func _connection_width(c: int, a: int, b: int, t: float) -> float:
	if _conn_width[c] > 0.0:
		return _conn_width[c]
	var wa := _point_width[a] if _point_width[a] > 0.0 else _default_width
	var wb := _point_width[b] if _point_width[b] > 0.0 else _default_width
	return lerpf(wa, wb, t)


func _valid_connection(c: int) -> bool:
	var a: int = _graph.connections[c * 2]
	var b: int = _graph.connections[c * 2 + 1]
	return a >= 0 and b >= 0 and a < _node_pos.size() and b < _node_pos.size() and a != b


# --- sampling -------------------------------------------------------------------------

## Rows along connection [param c] between parameters [param t0] and [param t1]:
## position (lifted off the ground), unit normal and width.
func _rows(c: int, t0: float, t1: float) -> Array:
	var a: int = _graph.connections[c * 2]
	var b: int = _graph.connections[c * 2 + 1]
	var pa := _graph.points[a]
	var pb := _graph.points[b]
	var length := maxf((t1 - t0) * pa.distance_to(pb), 0.0)
	var follow := _drape and _surface != null
	var segments := clampi(ceili(length / _spacing), 1, MAX_SEGMENTS) if follow else 1
	var rows: Array = []
	for s in segments + 1:
		var t := lerpf(t0, t1, float(s) / segments)
		var local := pa.lerp(pb, t)
		var ground: Dictionary
		if s == 0 and t0 <= 0.0:
			ground = {"position": _node_pos[a], "normal": _node_normal[a]}
		elif s == segments and t1 >= 1.0:
			ground = {"position": _node_pos[b], "normal": _node_normal[b]}
		else:
			ground = _ground(local, local.y)
		var n: Vector3 = ground.normal
		rows.append({
			"pos": ground.position + n * _lift,
			"normal": n,
			"width": _connection_width(c, a, b, t),
		})
	_assign_sides(rows)
	return rows


## Adds "left" (normal x tangent) to every row.
static func _assign_sides(rows: Array) -> void:
	var count := rows.size()
	for i in count:
		var before: Vector3 = rows[maxi(i - 1, 0)].pos
		var after: Vector3 = rows[mini(i + 1, count - 1)].pos
		var tangent := (after - before).normalized()
		var n: Vector3 = rows[i].normal
		var left := n.cross(tangent)
		if left.length_squared() < 0.000001:
			left = Vector3.RIGHT
		rows[i]["tangent"] = tangent
		rows[i]["left"] = left.normalized()


# --- ribbon ---------------------------------------------------------------------------

func _build_ribbon() -> void:
	var count := _node_pos.size()
	# Arms per node: [{conn, end(0=a,1=b), dir, angle, width, length}].
	var arms: Array = []
	arms.resize(count)
	for i in count:
		arms[i] = []
	for c in _graph.connection_count():
		if not _valid_connection(c):
			continue
		var a: int = _graph.connections[c * 2]
		var b: int = _graph.connections[c * 2 + 1]
		var length := _node_pos[a].distance_to(_node_pos[b])
		var wa := _connection_width(c, a, b, 0.0)
		var wb := _connection_width(c, a, b, 1.0)
		arms[a].append({"conn": c, "end": 0, "dir": (_node_pos[b] - _node_pos[a]).normalized(), "width": wa, "length": length})
		arms[b].append({"conn": c, "end": 1, "dir": (_node_pos[a] - _node_pos[b]).normalized(), "width": wb, "length": length})

	# How far each arm is cut back, from the angles to its neighbours around the node.
	var trim := {}
	for k in count:
		_order_arms(k, arms[k])
		_cut_arms(arms[k], trim)

	# Ribbon bodies; remember the first row of each arm for the junction fans.
	var corners := {}
	for c in _graph.connection_count():
		if not _valid_connection(c):
			continue
		var length := maxf(_node_pos[_graph.connections[c * 2]].distance_to(_node_pos[_graph.connections[c * 2 + 1]]), 0.0001)
		var ta: float = minf(trim.get(Vector2i(c, 0), 0.0) / length, 0.49)
		var tb: float = minf(trim.get(Vector2i(c, 1), 0.0) / length, 0.49)
		var rows := _rows(c, ta, 1.0 - tb)
		_emit_ribbon(rows)
		var first: Dictionary = rows[0]
		var last: Dictionary = rows[rows.size() - 1]
		# "facing" is the corner on the counter-clockwise side of the arm as seen from the node.
		corners[Vector2i(c, 0)] = [first.pos + first.left * first.width * 0.5, first.pos - first.left * first.width * 0.5]
		corners[Vector2i(c, 1)] = [last.pos - last.left * last.width * 0.5, last.pos + last.left * last.width * 0.5]
		if _outline:
			for sign in [1.0, -1.0]:
				for i in rows.size() - 1:
					_line(rows[i].pos + rows[i].left * rows[i].width * 0.5 * sign,
							rows[i + 1].pos + rows[i + 1].left * rows[i + 1].width * 0.5 * sign)

	for k in count:
		_emit_junction(k, arms[k], corners)


func _order_arms(k: int, node_arms: Array) -> void:
	var n := _node_normal[k]
	var e1 := Vector3.RIGHT - n * n.dot(Vector3.RIGHT)
	if e1.length_squared() < 0.0001:
		e1 = Vector3.FORWARD - n * n.dot(Vector3.FORWARD)
	e1 = e1.normalized()
	var e2 := n.cross(e1)
	for arm in node_arms:
		arm["angle"] = atan2(arm.dir.dot(e2), arm.dir.dot(e1))
	node_arms.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x.angle < y.angle)


## Fills [param trim] with the distance each arm of one node is shortened by.
func _cut_arms(node_arms: Array, trim: Dictionary) -> void:
	var count := node_arms.size()
	for i in count:
		var arm: Dictionary = node_arms[i]
		var distance := 0.0
		if count > 1:
			var next: Dictionary = node_arms[(i + 1) % count]
			var previous: Dictionary = node_arms[(i + count - 1) % count]
			# Counter-clockwise gap to the next arm, and from the previous one.
			var gaps := [[fposmod(next.angle - arm.angle, TAU), next], [fposmod(arm.angle - previous.angle, TAU), previous]]
			for entry in gaps:
				var gap: float = entry[0]
				if gap < PI - 0.01:
					var half := maxf(arm.width, entry[1].width) * 0.5
					distance = maxf(distance, half / maxf(tan(gap * 0.5), 0.01))
		var limit := minf(arm.length * 0.45, arm.width * 4.0)
		trim[Vector2i(arm.conn, arm.end)] = minf(distance, limit)


func _emit_ribbon(rows: Array) -> void:
	for i in rows.size() - 1:
		var r0: Dictionary = rows[i]
		var r1: Dictionary = rows[i + 1]
		var a0: Vector3 = r0.pos + r0.left * r0.width * 0.5
		var b0: Vector3 = r0.pos - r0.left * r0.width * 0.5
		var a1: Vector3 = r1.pos + r1.left * r1.width * 0.5
		var b1: Vector3 = r1.pos - r1.left * r1.width * 0.5
		_fill.append_array([a0, b0, a1, b0, b1, a1])


func _emit_junction(k: int, node_arms: Array, corners: Dictionary) -> void:
	var count := node_arms.size()
	if count == 0:
		return
	var center := _node_pos[k] + _node_normal[k] * _lift
	for i in count:
		var arm: Dictionary = node_arms[i]
		var mine: Array = corners[Vector2i(arm.conn, arm.end)]
		var next: Dictionary = node_arms[(i + 1) % count]
		var theirs: Array = corners[Vector2i(next.conn, next.end)]
		if count > 1:
			_fill.append_array([center, mine[0], mine[1]])
			_fill.append_array([center, mine[0], theirs[1]])
		if _outline:
			_line(mine[0], theirs[1])


func _line(from: Vector3, to: Vector3) -> void:
	if from.distance_squared_to(to) > MIN_EDGE * MIN_EDGE:
		_lines.append(from)
		_lines.append(to)


# --- tube -----------------------------------------------------------------------------

func _build_tube() -> void:
	var node_radius := PackedFloat32Array()
	node_radius.resize(_node_pos.size())
	for i in _node_pos.size():
		node_radius[i] = (_point_width[i] if _point_width[i] > 0.0 else _default_width) * 0.5

	for c in _graph.connection_count():
		if not _valid_connection(c):
			continue
		var a: int = _graph.connections[c * 2]
		var b: int = _graph.connections[c * 2 + 1]
		var rows := _rows(c, 0.0, 1.0)
		node_radius[a] = maxf(node_radius[a], rows[0].width * 0.5)
		node_radius[b] = maxf(node_radius[b], rows[rows.size() - 1].width * 0.5)
		for i in rows.size() - 1:
			for s in _sides:
				var p00 := _ring_point(rows[i], s)
				var p01 := _ring_point(rows[i], s + 1)
				var p10 := _ring_point(rows[i + 1], s)
				var p11 := _ring_point(rows[i + 1], s + 1)
				_fill.append_array([p00, p01, p10, p01, p11, p10])
		if _outline:
			# Silhouette seen from above and from the side: the two outermost lines.
			for angle in [PI * 0.5, PI * 1.5]:
				for i in rows.size() - 1:
					_line(_ring_angle(rows[i], angle), _ring_angle(rows[i + 1], angle))
			for end in [0, rows.size() - 1]:
				for s in _sides:
					_line(_ring_point(rows[end], s), _ring_point(rows[end], s + 1))

	for i in _node_pos.size():
		_emit_sphere(_node_pos[i] + _node_normal[i] * _lift, node_radius[i])


func _ring_point(row: Dictionary, s: int) -> Vector3:
	return _ring_angle(row, TAU * s / _sides)


func _ring_angle(row: Dictionary, angle: float) -> Vector3:
	return row.pos + (row.normal * cos(angle) + row.left * sin(angle)) * row.width * 0.5


func _emit_sphere(center: Vector3, radius: float) -> void:
	var rings := maxi(_sides / 2, 3)
	for r in rings:
		var phi0 := PI * r / rings
		var phi1 := PI * (r + 1) / rings
		for s in _sides:
			var th0 := TAU * s / _sides
			var th1 := TAU * (s + 1) / _sides
			var p00 := center + _sphere_point(phi0, th0) * radius
			var p01 := center + _sphere_point(phi0, th1) * radius
			var p10 := center + _sphere_point(phi1, th0) * radius
			var p11 := center + _sphere_point(phi1, th1) * radius
			_fill.append_array([p00, p10, p01, p01, p10, p11])


static func _sphere_point(phi: float, theta: float) -> Vector3:
	return Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
