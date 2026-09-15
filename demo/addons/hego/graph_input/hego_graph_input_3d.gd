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

var _syncing := false


func _enter_tree() -> void:
	if not child_entered_tree.is_connected(_on_child_entered):
		child_entered_tree.connect(_on_child_entered)
	if not child_exiting_tree.is_connected(_on_child_exiting):
		child_exiting_tree.connect(_on_child_exiting)
	_connect_attribute_children()
	sync_schema()


func _exit_tree() -> void:
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
	next.append(position)
	points = next
	return points.size() - 1


## Moves point [param index] to [param position].
func set_point_position(index: int, position: Vector3) -> void:
	if index < 0 or index >= points.size():
		return
	var next := points.duplicate()
	next[index] = position
	points = next


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
	var saved := _copy_attrib_row(connection_attribs, conn_index)
	remove_connections(PackedInt32Array([conn_index]))
	var new_point := add_point(position)
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
