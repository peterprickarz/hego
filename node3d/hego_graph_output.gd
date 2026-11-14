@tool
class_name HEGoGraphOutput
extends RefCounted

## Turns output points flagged as graph points into [HEGoGraph3D] nodes under
## [code]Outputs/[/code].
##
## Houdini polylines reach Godot through the loose-point output: the HDA keeps its curve
## points (Add SOP, "Delete Geometry But Keep the Points") and links each point to the one
## before it on its curve.
## [br][br]
## [b]Point attributes the HDA sets[/b]
## [br]- [code]hego_graph[/code] (int): 1 on every graph point. Other points are left to the
## other handlers.
## [br]- [code]hego_graph_path[/code] (string, optional): node path under
## [code]Outputs[/code] of the graph the point belongs to, default [code]Graph[/code]. One
## cook can build several graphs.
## [br]- [code]hego_graph_id[/code] (int, optional): an id unique within the cook, default
## the point number.
## [br]- [code]hego_graph_prev[/code] (int, optional): the id of the point this one connects
## to, -1 for none. A polyline links every point but the first to its predecessor; a
## shared id (a fork point) joins curves into one graph.
## [br]- [code]hego_graph_conn_<name>[/code]: becomes the connection attribute
## [code]<name>[/code] of the connection from this point to its predecessor.
## [br]- Every other point attribute except [code]P[/code] and the [code]hego_[/code]
## prefix becomes a point attribute of the graph, declared on an [code]Attributes[/code]
## child: floats, ints, strings and three-float vectors.
## [br][br]
## A graph built this way edits, saves and feeds another cook like an authored one.

## Category this file logs under, shown in the session panel filter.
const LOG_CATEGORY := "output"

const FILTER_ATTRIB := "hego_graph"
const PATH_ATTRIB := "hego_graph_path"
const ID_ATTRIB := "hego_graph_id"
const PREV_ATTRIB := "hego_graph_prev"
const CONNECTION_PREFIX := "hego_graph_conn_"
## Folder used when a point does not name its graph.
const DEFAULT_PATH := "Graph"
## Name of the attribute schema child the handler creates.
const ATTRIBUTES_NAME := "Attributes"


## Name of the cook phase this handler is timed under.
static func output_phase() -> String:
	return "graph_output"


## Whether the cook produced graph points.
static func should_handle(summary: Dictionary) -> bool:
	return HEGoNodeUtil.output_has(summary, "has_points") \
		and HEGoNodeUtil.output_has_attribute(summary, "point_attributes", FILTER_ATTRIB)


## Fetches the graph points and builds one [HEGoGraph3D] per [code]hego_graph_path[/code].
static func handle(context: HEGoOutputContext) -> void:
	var output: HEGoPointOutput = await context.await_task(context.asset.get_point_output())
	if output == null or not output.is_valid():
		return
	var names := output.get_attribute_names(HEGoPointOutput.OWNER_POINT)
	var carried := PackedStringArray()
	var connection_names := PackedStringArray()
	for name in names:
		if name.begins_with(CONNECTION_PREFIX):
			connection_names.append(name)
		elif name != "P" and not name.begins_with("hego_") and not HEGoGraph3D.is_reserved_name(name):
			carried.append(name)
	var control := PackedStringArray([FILTER_ATTRIB])
	for name in [PATH_ATTRIB, ID_ATTRIB, PREV_ATTRIB]:
		if names.has(name):
			control.append(name)
	await context.await_task(output.load_attributes(control + carried + connection_names))

	var selection := output.filter_by(FILTER_ATTRIB, 1)
	if selection == null or selection.size() == 0:
		return
	var groups: Dictionary = selection.split_by(PATH_ATTRIB) if names.has(PATH_ATTRIB) else {null: selection}
	for key in groups:
		var group: HEGoPointSelection = groups[key]
		var path := DEFAULT_PATH if key == null or str(key).is_empty() else str(key)
		var data: Dictionary = group.get_points(control + carried + connection_names)
		var graph := context.place(path, DEFAULT_PATH, HEGoGraph3D.new) as HEGoGraph3D
		_fill(context, graph, group, data, carried, connection_names)


## Builds the graph's topology and attributes from one group's point data.
static func _fill(context: HEGoOutputContext, graph: HEGoGraph3D, group: HEGoPointSelection, data: Dictionary,
		carried: PackedStringArray, connection_names: PackedStringArray) -> void:
	var positions := PackedVector3Array(data.get("P", []))
	var count := positions.size()
	var ids := PackedInt32Array(data[ID_ATTRIB]) if data.has(ID_ATTRIB) else group.get_indices()
	var prev := PackedInt32Array(data[PREV_ATTRIB]) if data.has(PREV_ATTRIB) else PackedInt32Array()
	var local := {}
	for i in count:
		local[ids[i]] = i
	var connections := PackedInt32Array()
	var from_point := PackedInt32Array()
	var missing := 0
	for i in prev.size():
		var p: int = prev[i]
		if p < 0:
			continue
		var j: int = local.get(p, -1)
		if j < 0 or j == i:
			missing += 1
			continue
		connections.append(mini(i, j))
		connections.append(maxi(i, j))
		from_point.append(i)
	if missing > 0:
		HEGoLog.get_singleton().warning(LOG_CATEGORY, "Graph %s: %d points link to ids that are not in the graph." % [graph.name, missing])

	var defs: Array[HEGoGraphAttributeDef] = []
	var point_attribs := {}
	for name in carried:
		var values: Variant = _packed(data.get(name, []))
		if values == null:
			HEGoLog.get_singleton().warning(LOG_CATEGORY, "Graph attribute '%s' has a type graphs cannot store; skipped." % name)
			continue
		point_attribs[name] = values
		defs.append(_def(name, HEGoGraphAttributeDef.Owner.POINT, values))
	var connection_attribs := {}
	for name in connection_names:
		var values: Variant = _packed(data.get(name, []))
		if values == null:
			continue
		var per_connection: Variant = values.duplicate()
		per_connection.resize(from_point.size())
		for c in from_point.size():
			per_connection[c] = values[from_point[c]]
		var short := name.trim_prefix(CONNECTION_PREFIX)
		connection_attribs[short] = per_connection
		defs.append(_def(short, HEGoGraphAttributeDef.Owner.CONNECTION, per_connection))

	# The schema first, so the graph keeps the attributes when they are assigned.
	var attributes := graph.get_node_or_null(ATTRIBUTES_NAME) as HEGoGraphAttributes
	if attributes == null:
		attributes = HEGoGraphAttributes.new()
		attributes.name = ATTRIBUTES_NAME
		graph.add_child(attributes)
		context.own(attributes)
	attributes.attributes = defs
	graph.apply_state({"points": positions, "connections": connections, "point_attribs": point_attribs,
		"connection_attribs": connection_attribs})


## [param values] as the packed array a graph stores, or null for an unsupported type.
static func _packed(values: Variant) -> Variant:
	if values is Array and not values.is_empty():
		match typeof(values[0]):
			TYPE_FLOAT:
				return PackedFloat32Array(values)
			TYPE_INT:
				return PackedInt32Array(values)
			TYPE_STRING, TYPE_STRING_NAME:
				return PackedStringArray(values)
			TYPE_VECTOR3:
				return PackedVector3Array(values)
			TYPE_VECTOR3I:
				var floats := PackedVector3Array()
				for v in values:
					floats.append(Vector3(v))
				return floats
		return null
	if values is PackedFloat32Array or values is PackedInt32Array or values is PackedStringArray or values is PackedVector3Array:
		return values
	return PackedFloat32Array() if values is Array else null


static func _def(name: String, owner: int, values: Variant) -> HEGoGraphAttributeDef:
	var def := HEGoGraphAttributeDef.new()
	def.attribute_name = name
	def.owner = owner
	def.value_type = HEGoGraphAttributeDef.value_type_of(values)
	return def
