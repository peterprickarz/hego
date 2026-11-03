## Covers the graph output side of HEGoGraph3D without a Houdini session: when the
## handler runs, how cooked attribute arrays become graph attributes (vectors included),
## that HEGoGraphInput3D stays a HEGoGraph3D, and the vector attribute type on its own.
## The native fetch is exercised by a real cook (docs/node_reference/outputs/graph_output.rst).
extends SceneTree

var failures := 0


func check(condition: bool, what: String) -> void:
	if condition:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func _initialize() -> void:
	# --- when the handler runs --------------------------------------------------
	var summary := {"has_points": true, "point_attributes": PackedStringArray(["hego_graph", "radius"])}
	check(HEGoGraphOutput.should_handle(summary), "points with hego_graph run graph output")
	summary.point_attributes = PackedStringArray(["radius"])
	check(not HEGoGraphOutput.should_handle(summary), "points without hego_graph skip graph output")
	check(HEGoGraphOutput.should_handle({}), "an unreadable summary still runs graph output")
	var handlers: Array = HEGoNode3D.new().output_handlers()
	check(handlers.find(HEGoGraphOutput) >= 0 and handlers.find(HEGoGraphOutput) < handlers.find(HEGoCurveOutput),
		"HEGoNode3D runs graph output before curve output")

	# --- attribute arrays -------------------------------------------------------
	check(HEGoGraphOutput._packed([1.5, 2.5]) is PackedFloat32Array, "floats become PackedFloat32Array")
	check(HEGoGraphOutput._packed([1, 2]) is PackedInt32Array, "ints become PackedInt32Array")
	check(HEGoGraphOutput._packed(["a"]) is PackedStringArray, "strings become PackedStringArray")
	var vectors: Variant = HEGoGraphOutput._packed([Vector3(0, 1, 0), Vector3(1, 0, 0)])
	check(vectors is PackedVector3Array and vectors[1] == Vector3(1, 0, 0), "vectors become PackedVector3Array")
	check(HEGoGraphOutput._packed([Vector2(1, 2)]) == null, "unsupported types are refused")
	var def := HEGoGraphOutput._def("up", HEGoGraphAttributeDef.Owner.POINT, vectors)
	check(def.value_type == HEGoGraphAttributeDef.ValueType.VECTOR3 and def.matches_array(vectors), "a vector array declares a VECTOR3 attribute")

	_graph_part.call_deferred()


## Deferred: nodes enter the tree only once the main loop runs.
func _graph_part() -> void:
	# --- vector attributes on a graph -------------------------------------------
	var graph := HEGoGraphInput3D.new()
	check(graph is HEGoGraph3D, "HEGoGraphInput3D is a HEGoGraph3D")
	var schema := HEGoGraphAttributes.new()
	var up := HEGoGraphAttributeDef.new()
	up.attribute_name = "up"
	up.value_type = HEGoGraphAttributeDef.ValueType.VECTOR3
	up.default_vector = Vector3.UP
	schema.attributes = [up]
	graph.add_child(schema)
	root.add_child(graph)
	var a := graph.add_point(Vector3(0, 0, 0))
	var b := graph.add_point(Vector3(10, 0, 0))
	graph.add_connection(a, b)
	check(graph.point_attribs.up is PackedVector3Array and graph.point_attribs.up[1] == Vector3.UP, "new points get the vector default")
	graph.set_point_attrib_on("up", PackedInt32Array([b]), Vector3.RIGHT)
	var mid := graph.split_connection(0, Vector3(5, 0, 0))
	var expected := Vector3.UP.lerp(Vector3.RIGHT, 0.5)
	check(mid >= 0 and graph.point_attribs.up[mid].is_equal_approx(expected), "splitting a connection interpolates vectors")
	var version := graph.graph_version
	graph.add_point(Vector3(1, 1, 1))
	check(graph.graph_version > version, "graph_version advances when the graph changes")
	graph.queue_free()

	print("\nfailures: %d" % failures)
	quit(1 if failures > 0 else 0)
