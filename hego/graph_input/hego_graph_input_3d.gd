@icon("res://addons/hego/assets/houdini.svg")
@tool
class_name HEGoGraphInput3D
extends Node3D

## A 3D graph of points and connections that can be fed into a [HEGoNode3D] input.
##
## Add a [HEGoGraphAttributes] child to declare the attributes each point and connection
## can carry. Positions are stored in local space. Connections are undirected unique
## pairs; a point with three or more connections is an intersection.

## Category this file logs under, shown in the session panel filter.
const LOG_CATEGORY := "input"

## Names that already mean something on Houdini input geometry.
const RESERVED_NAMES := ["P", "Cd"]

## Prefix reserved for HEGo's own metadata attributes.
const RESERVED_PREFIX := "_hego_"

## The graph's topology or attribute values changed.
signal graph_changed

## Point positions, in this node's local space.
@export var points: PackedVector3Array = PackedVector3Array():
	set(value):
		points = value
		if _syncing:
			return
		_sync_attrib_sizes()
		graph_changed.emit()

## Connection endpoints as index pairs [code][a0, b0, a1, b1, ...][/code]. Each pair is
## stored with the smaller index first.
@export var connections: PackedInt32Array = PackedInt32Array():
	set(value):
		if value.size() % 2 == 1:
			value = value.duplicate()
			value.resize(value.size() - 1)
		connections = value
		_sync_attrib_sizes()
		graph_changed.emit()

## Per-point attribute values, keyed by name. Each value is a packed array the same
## length as [member points].
@export var point_attribs: Dictionary = {}:
	set(value):
		point_attribs = value
		graph_changed.emit()

## Per-connection attribute values, keyed by name. Each value is a packed array the
## same length as [method connection_count].
@export var connection_attribs: Dictionary = {}:
	set(value):
		connection_attribs = value
		graph_changed.emit()

## How the path visualisation draws a connection.
enum PathShape {
	## A flat translucent band lying on the surface.
	RIBBON,
	## A cylinder per connection with a sphere at each point.
	TUBE,
}

@export_group("Visualization")

## Draws the graph as a path: a translucent ribbon or tube along every connection whose
## width comes from an attribute, with an outline. It is part of the graph's editor
## gizmo, so it only exists in the editor and View > Gizmos hides it.
@export var path_mode := false:
	set(value):
		path_mode = value
		_queue_path_rebuild()

## Name of the attribute that gives the path width in metres. A connection attribute
## of that name wins over a point attribute, which is interpolated between the ends of a
## connection. Missing or zero values use [member path_default_width].
@export var path_width_attribute: StringName = &"path_width":
	set(value):
		path_width_attribute = value
		_queue_path_rebuild()

## Width in metres where [member path_width_attribute] gives none.
@export_range(0.01, 100.0, 0.01, "or_greater", "suffix:m") var path_default_width := 2.0:
	set(value):
		path_default_width = value
		_queue_path_rebuild()

## Ribbon or tube. A tube uses the width as its diameter.
@export var path_shape := PathShape.RIBBON:
	set(value):
		path_shape = value
		_queue_path_rebuild()

## Colour and opacity of the ribbon or tube.
@export var path_color := Color(1.0, 0.72, 0.2, 0.35):
	set(value):
		path_color = value
		_queue_path_rebuild()

## Draws the boundary: both ribbon edges and the end caps, or the tube's silhouette lines
## and end rings.
@export var path_outline := true:
	set(value):
		path_outline = value
		_queue_path_rebuild()

## Colour of the outline.
@export var path_outline_color := Color(1.0, 0.85, 0.35, 1.0):
	set(value):
		path_outline_color = value
		_queue_path_rebuild()

## Lays the path on the surface between points, and orients the ribbon to its normal,
## using the [member surface_provider] or physics colliders. Without a surface the path
## runs straight between points and the ribbon faces up.
@export var path_drape := true:
	set(value):
		path_drape = value
		_queue_path_rebuild()

## Distance in metres between samples when draping.
@export_range(0.25, 64.0, 0.25, "or_greater", "suffix:m") var path_sample_spacing := 3.0:
	set(value):
		path_sample_spacing = value
		_queue_path_rebuild()

## Height of the path above the surface along its normal, to avoid z-fighting.
@export_range(0.0, 2.0, 0.01, "or_greater", "suffix:m") var path_lift := 0.25:
	set(value):
		path_lift = value
		_queue_path_rebuild()

## Segments around a tube.
@export_range(4, 64) var path_tube_sides := 12:
	set(value):
		path_tube_sides = value
		_queue_path_rebuild()

@export_group("Surface")

## Optional node that gives the ground height, for snapping and for the path
## visualisation. It needs [code]sample_height(Vector2) -> float[/code], taking a local
## x/z position and returning the local height, and may have
## [code]contains_position(Vector2) -> bool[/code]. Without one, a physics ray from above
## is used. HEGo does not depend on any terrain addon.
@export_node_path("Node3D") var surface_provider := NodePath():
	set(value):
		surface_provider = value
		_queue_path_rebuild()

## Puts every point added or moved in the editor on the surface.
@export var snap_to_surface := false

## Height above the surface in metres that snapped points get.
@export_range(-10.0, 10.0, 0.01, "or_greater", "or_less", "suffix:m") var surface_offset := 0.0

## Moves every point onto the surface now, as one undoable step.
@export_tool_button("Snap all points to surface", "Snap") var snap_all_button := request_snap_all

## Emitted by [method request_snap_all] when an editor wants to apply the snap as an
## undoable action. Without a listener the snap is applied directly.
signal snap_all_requested

var _syncing := false
var _path_mesh: ArrayMesh
var _path_dirty := true
var _path_redraw_queued := false


func _enter_tree() -> void:
	if not graph_changed.is_connected(_queue_path_rebuild):
		graph_changed.connect(_queue_path_rebuild)
	if not child_entered_tree.is_connected(_on_child_entered):
		child_entered_tree.connect(_on_child_entered)
	if not child_exiting_tree.is_connected(_on_child_exiting):
		child_exiting_tree.connect(_on_child_exiting)
	_connect_attribute_children()
	sync_schema()


func _exit_tree() -> void:
	if graph_changed.is_connected(_queue_path_rebuild):
		graph_changed.disconnect(_queue_path_rebuild)
	if child_entered_tree.is_connected(_on_child_entered):
		child_entered_tree.disconnect(_on_child_entered)
	if child_exiting_tree.is_connected(_on_child_exiting):
		child_exiting_tree.disconnect(_on_child_exiting)
	_disconnect_attribute_children()


## Number of connections, i.e. half of [member connections].
func connection_count() -> int:
	return connections.size() / 2


## The two point indices of connection [param index], smaller first.
func get_connection(index: int) -> Vector2i:
	if index < 0 or index >= connection_count():
		return Vector2i(-1, -1)
	return Vector2i(connections[index * 2], connections[index * 2 + 1])


## Appends a point at [param position] and returns its index.
func add_point(position: Vector3) -> int:
	var next := points.duplicate()
	next.append(_snapped(position))
	points = next
	return points.size() - 1


## Moves point [param index] to [param position].
func set_point_position(index: int, position: Vector3) -> void:
	if index < 0 or index >= points.size():
		return
	var next := points.duplicate()
	next[index] = _snapped(position)
	points = next


## Sets a point during a live gizmo drag without emitting [signal graph_changed].
func set_point_position_live(index: int, position: Vector3) -> void:
	if index < 0 or index >= points.size():
		return
	var next := points.duplicate()
	next[index] = _snapped(position)
	_syncing = true
	points = next
	_syncing = false
	if Engine.is_editor_hint():
		update_gizmos()
	_queue_path_rebuild()


## [param position] (graph local) put on the surface when [member snap_to_surface] is on
## in the editor; otherwise unchanged.
func _snapped(position: Vector3) -> Vector3:
	if not snap_to_surface or not Engine.is_editor_hint():
		return position
	return snapped_to_surface(position, HEGoGraphSurface.new(self, surface_provider))


## [param position] (graph local) with its height replaced by the surface under it plus
## [member surface_offset]. Unchanged where there is no surface.
func snapped_to_surface(position: Vector3, surface: HEGoGraphSurface) -> Vector3:
	var hit := surface.query_local(position)
	if hit.is_empty():
		return position
	return Vector3(position.x, hit.position.y + surface_offset, position.z)


## Moves every point onto the surface under it ([member surface_provider], else
## physics) plus [member surface_offset]. Returns the number of points that moved.
func snap_all_to_surface() -> int:
	var surface := HEGoGraphSurface.new(self, surface_provider)
	if not surface.is_available():
		return 0
	var next := points.duplicate()
	var moved := 0
	for i in next.size():
		var target := snapped_to_surface(next[i], surface)
		if not is_equal_approx(target.y, next[i].y):
			next[i] = target
			moved += 1
	if moved > 0:
		points = next
		if Engine.is_editor_hint():
			update_gizmos()
	return moved


## What the "Snap all points to surface" button calls: lets an editor do it as an undoable
## action through [signal snap_all_requested], else snaps directly.
func request_snap_all() -> void:
	if snap_all_requested.get_connections().is_empty():
		snap_all_to_surface()
	else:
		snap_all_requested.emit()


## Marks the path mesh stale and asks the gizmo to redraw on the next idle frame, once
## however many changes came in.
func _queue_path_rebuild() -> void:
	_path_dirty = true
	if _path_redraw_queued or not is_inside_tree() or not Engine.is_editor_hint():
		return
	_path_redraw_queued = true
	_redraw_path.call_deferred()


func _redraw_path() -> void:
	_path_redraw_queued = false
	if is_inside_tree():
		update_gizmos()


## The path visualisation mesh (fill and outline surfaces, in local space), rebuilt only
## when the graph or a visualisation property changed since the last call. Null when
## [member path_mode] is off. The editor gizmo draws it.
func get_path_mesh() -> ArrayMesh:
	if not path_mode:
		return null
	if _path_dirty or _path_mesh == null:
		_path_mesh = HEGoGraphPathMesh.build(self, HEGoGraphSurface.new(self, surface_provider))
		_path_dirty = false
	return _path_mesh


## Deletes the given point indices and any connection that used them. Remaining
## connection indices are remapped.
func remove_points(indices: PackedInt32Array) -> void:
	if indices.is_empty() or points.is_empty():
		return

	var drop := {}
	for index in indices:
		if index >= 0 and index < points.size():
			drop[index] = true
	if drop.is_empty():
		return

	var old_to_new := PackedInt32Array()
	old_to_new.resize(points.size())
	var next_points := PackedVector3Array()
	var new_index := 0
	for i in points.size():
		if drop.has(i):
			old_to_new[i] = -1
		else:
			old_to_new[i] = new_index
			next_points.append(points[i])
			new_index += 1

	var keep_rows := PackedInt32Array()
	for i in points.size():
		if old_to_new[i] >= 0:
			keep_rows.append(i)
	var next_point_attribs := _take_attrib_rows(point_attribs, keep_rows)

	var next_connections := PackedInt32Array()
	var keep_conns := PackedInt32Array()
	for c in connection_count():
		var a: int = old_to_new[connections[c * 2]]
		var b: int = old_to_new[connections[c * 2 + 1]]
		if a < 0 or b < 0:
			continue
		next_connections.append(a)
		next_connections.append(b)
		keep_conns.append(c)
	var next_conn_attribs := _take_attrib_rows(connection_attribs, keep_conns)

	_syncing = true
	point_attribs = next_point_attribs
	connection_attribs = next_conn_attribs
	points = next_points
	connections = next_connections
	_syncing = false
	_sync_attrib_sizes()
	graph_changed.emit()


## Adds an undirected connection between [param a] and [param b]. Returns the new
## connection index, or [code]-1[/code] if the pair is invalid or already present.
func add_connection(a: int, b: int) -> int:
	if a == b or a < 0 or b < 0 or a >= points.size() or b >= points.size():
		return -1
	var lo := mini(a, b)
	var hi := maxi(a, b)
	if has_connection(lo, hi):
		return -1
	var next := connections.duplicate()
	next.append(lo)
	next.append(hi)
	connections = next
	return connection_count() - 1


## Whether an undirected connection between [param a] and [param b] already exists.
func has_connection(a: int, b: int) -> bool:
	var lo := mini(a, b)
	var hi := maxi(a, b)
	for c in connection_count():
		if connections[c * 2] == lo and connections[c * 2 + 1] == hi:
			return true
	return false


## Deletes the given connection indices. Points are left in place.
func remove_connections(indices: PackedInt32Array) -> void:
	if indices.is_empty() or connection_count() == 0:
		return

	var drop := {}
	for index in indices:
		if index >= 0 and index < connection_count():
			drop[index] = true
	if drop.is_empty():
		return

	var next_connections := PackedInt32Array()
	var keep := PackedInt32Array()
	for c in connection_count():
		if drop.has(c):
			continue
		next_connections.append(connections[c * 2])
		next_connections.append(connections[c * 2 + 1])
		keep.append(c)

	_syncing = true
	connection_attribs = _take_attrib_rows(connection_attribs, keep)
	connections = next_connections
	_syncing = false
	_sync_attrib_sizes()
	graph_changed.emit()


## Inserts a point at [param position] on connection [param conn_index], replacing
## that connection with two that inherit its attributes. Returns the new point index,
## or [code]-1[/code] if the connection does not exist.
func split_connection(conn_index: int, position: Vector3) -> int:
	if conn_index < 0 or conn_index >= connection_count():
		return -1
	var a: int = connections[conn_index * 2]
	var b: int = connections[conn_index * 2 + 1]
	# Preserve continuous fields such as radius when inserting a control point.
	# Discrete labels/toggles inherit the nearer endpoint, rather than a default.
	var span := points[b] - points[a]
	var weight := clampf((position - points[a]).dot(span) / maxf(span.length_squared(), 0.00000001), 0.0, 1.0)
	var point_values := {}
	for key in point_attribs:
		var values: Variant = point_attribs[key]
		point_values[key] = lerpf(values[a], values[b], weight) if values is PackedFloat32Array else values[a if weight <= 0.5 else b]
	var saved := _copy_attrib_row(connection_attribs, conn_index)
	remove_connections(PackedInt32Array([conn_index]))
	var new_point := add_point(position)
	_apply_attrib_row(point_attribs, new_point, point_values)
	var c0 := add_connection(a, new_point)
	var c1 := add_connection(new_point, b)
	if c0 >= 0:
		_apply_attrib_row(connection_attribs, c0, saved)
	if c1 >= 0:
		_apply_attrib_row(connection_attribs, c1, saved)
	connection_attribs = connection_attribs
	return new_point


## Sets attribute [param name] on each of [param indices] to [param value].
func set_point_attrib_on(name: String, indices: PackedInt32Array, value: Variant) -> void:
	_set_attrib_on(point_attribs, name, indices, value)
	point_attribs = point_attribs


## Sets attribute [param name] on each of [param indices] to [param value].
func set_connection_attrib_on(name: String, indices: PackedInt32Array, value: Variant) -> void:
	_set_attrib_on(connection_attribs, name, indices, value)
	connection_attribs = connection_attribs


## Rebuilds stored attribute arrays from [HEGoGraphAttributes] children: adds missing
## keys at their defaults, drops keys that are no longer defined, and resizes to the
## current point and connection counts.
func sync_schema() -> void:
	var point_defs := {}
	var conn_defs := {}
	for def in collect_schema():
		if def.owner == HEGoGraphAttributeDef.Owner.POINT:
			point_defs[def.attribute_name] = def
		else:
			conn_defs[def.attribute_name] = def

	_syncing = true
	point_attribs = _reconcile_dict(point_attribs, point_defs, points.size())
	connection_attribs = _reconcile_dict(connection_attribs, conn_defs, connection_count())
	_syncing = false
	graph_changed.emit()


## Attribute definitions from every [HEGoGraphAttributes] child, in tree order.
## Reserved and duplicate names are skipped with a warning.
func collect_schema(warn := true) -> Array:
	var defs: Array = []
	var seen_point := {}
	var seen_conn := {}
	for child in get_children():
		if not child is HEGoGraphAttributes:
			continue
		for def in child.attributes:
			if def == null or not def is HEGoGraphAttributeDef:
				continue
			if is_reserved_name(def.attribute_name):
				if warn:
					HEGoLog.get_singleton().warning(LOG_CATEGORY,
							"Graph attribute '%s' is reserved, skipping it." % def.attribute_name)
				continue
			var seen: Dictionary = seen_point if def.owner == HEGoGraphAttributeDef.Owner.POINT else seen_conn
			if seen.has(def.attribute_name):
				if warn:
					HEGoLog.get_singleton().warning(LOG_CATEGORY,
							"Graph attribute '%s' is defined twice, keeping the first." % def.attribute_name)
				continue
			seen[def.attribute_name] = true
			defs.append(def)
	return defs


## Whether [param name] is reserved for Houdini or HEGo metadata.
static func is_reserved_name(name: String) -> bool:
	return name.is_empty() or name in RESERVED_NAMES or name.begins_with(RESERVED_PREFIX)


## A copy of the topology and attribute arrays, for undo.
func capture_state() -> Dictionary:
	return {
		"points": points.duplicate(),
		"connections": connections.duplicate(),
		"point_attribs": point_attribs.duplicate(true),
		"connection_attribs": connection_attribs.duplicate(true),
	}


## Restores a state produced by [method capture_state].
func apply_state(state: Dictionary) -> void:
	_syncing = true
	points = state.get("points", PackedVector3Array())
	connections = state.get("connections", PackedInt32Array())
	point_attribs = state.get("point_attribs", {})
	connection_attribs = state.get("connection_attribs", {})
	_syncing = false
	if Engine.is_editor_hint():
		update_gizmos()
	graph_changed.emit()


func _on_child_entered(child: Node) -> void:
	if child is HEGoGraphAttributes:
		if not child.schema_changed.is_connected(sync_schema):
			child.schema_changed.connect(sync_schema)
		sync_schema()


func _on_child_exiting(child: Node) -> void:
	if child is HEGoGraphAttributes:
		if child.schema_changed.is_connected(sync_schema):
			child.schema_changed.disconnect(sync_schema)
		# Defer so the child is gone from get_children() when we rebuild.
		sync_schema.call_deferred()


func _connect_attribute_children() -> void:
	for child in get_children():
		if child is HEGoGraphAttributes and not child.schema_changed.is_connected(sync_schema):
			child.schema_changed.connect(sync_schema)


func _disconnect_attribute_children() -> void:
	for child in get_children():
		if child is HEGoGraphAttributes and child.schema_changed.is_connected(sync_schema):
			child.schema_changed.disconnect(sync_schema)


func _sync_attrib_sizes() -> void:
	if _syncing:
		return
	_syncing = true
	var point_defs := {}
	var conn_defs := {}
	for def in collect_schema(false):
		if def.owner == HEGoGraphAttributeDef.Owner.POINT:
			point_defs[def.attribute_name] = def
		else:
			conn_defs[def.attribute_name] = def
	if not point_defs.is_empty() or not point_attribs.is_empty():
		point_attribs = _reconcile_dict(point_attribs, point_defs, points.size())
	if not conn_defs.is_empty() or not connection_attribs.is_empty():
		connection_attribs = _reconcile_dict(connection_attribs, conn_defs, connection_count())
	_syncing = false


func _reconcile_dict(existing: Dictionary, wanted: Dictionary, count: int) -> Dictionary:
	var next := {}
	for name in wanted:
		var def: HEGoGraphAttributeDef = wanted[name]
		next[name] = _coerced_array(existing.get(name), count, def)
	return next


func _coerced_array(existing: Variant, count: int, def: HEGoGraphAttributeDef) -> Variant:
	if def.matches_array(existing):
		return _resized(existing, count, def.default_value())
	return def.make_array(count)


func _resized(array: Variant, count: int, default: Variant) -> Variant:
	var old_size: int = array.size()
	if old_size == count:
		return array
	array.resize(count)
	if count > old_size:
		for i in range(old_size, count):
			array[i] = default
	return array


func _take_attrib_rows(source: Dictionary, keep: PackedInt32Array) -> Dictionary:
	var next := {}
	for name in source:
		var src: Variant = source[name]
		if src == null:
			continue
		var dst: Variant = src.duplicate()
		dst.resize(keep.size())
		for i in keep.size():
			dst[i] = src[keep[i]]
		next[name] = dst
	return next


func _copy_attrib_row(source: Dictionary, index: int) -> Dictionary:
	var row := {}
	for name in source:
		var src: Variant = source[name]
		if src == null or index < 0 or index >= src.size():
			continue
		row[name] = src[index]
	return row


func _apply_attrib_row(target: Dictionary, index: int, row: Dictionary) -> void:
	for name in row:
		if not target.has(name):
			continue
		var arr: Variant = target[name]
		if index < 0 or index >= arr.size():
			continue
		arr[index] = row[name]
		target[name] = arr


func _set_attrib_on(target: Dictionary, name: String, indices: PackedInt32Array, value: Variant) -> void:
	if not target.has(name):
		return
	var arr: Variant = target[name]
	for index in indices:
		if index >= 0 and index < arr.size():
			arr[index] = value
	target[name] = arr
