## Covers the graph data model: topology, schema sync, and attribute arrays.
##
## No Houdini session. The viewport editor and cook path are tested elsewhere.
extends SceneTree

var failures := 0


func check(condition: bool, what: String) -> void:
	if condition:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func make_graph() -> HEGoGraphInput3D:
	var graph := HEGoGraphInput3D.new()
	root.add_child(graph)
	return graph


func make_def(name: String, owner: HEGoGraphAttributeDef.Owner, type: HEGoGraphAttributeDef.ValueType) -> HEGoGraphAttributeDef:
	var def := HEGoGraphAttributeDef.new()
	def.attribute_name = name
	def.owner = owner
	def.value_type = type
	return def


func _initialize() -> void:
	# --- points and undirected unique connections -------------------------
	var graph := make_graph()
	check(graph.add_point(Vector3(0, 0, 0)) == 0, "first point is index 0")
	check(graph.add_point(Vector3(1, 0, 0)) == 1, "second point is index 1")
	check(graph.add_point(Vector3(0, 1, 0)) == 2, "third point is index 2")
	check(graph.points.size() == 3, "three points stored")

	check(graph.add_connection(0, 1) == 0, "first connection is index 0")
	check(graph.add_connection(1, 0) == -1, "the reverse of an existing pair is rejected")
	check(graph.add_connection(0, 0) == -1, "a self-connection is rejected")
	check(graph.add_connection(0, 9) == -1, "an out-of-range index is rejected")
	check(graph.add_connection(1, 2) == 1, "a second distinct pair is accepted")
	check(graph.connection_count() == 2, "two connections stored")
	check(graph.get_connection(0) == Vector2i(0, 1), "pairs are stored smaller index first")
	check(graph.has_connection(1, 0), "has_connection is undirected")

	# --- intersections: one point, three connections ----------------------
	var star := make_graph()
	star.add_point(Vector3.ZERO)
	star.add_point(Vector3(1, 0, 0))
	star.add_point(Vector3(0, 1, 0))
	star.add_point(Vector3(0, 0, 1))
	check(star.add_connection(0, 1) == 0, "star spoke 1")
	check(star.add_connection(0, 2) == 1, "star spoke 2")
	check(star.add_connection(0, 3) == 2, "star spoke 3")
	check(star.connection_count() == 3, "a point can have three connections")

	# --- split replaces one connection with two ---------------------------
	var split := make_graph()
	split.add_point(Vector3(0, 0, 0))
	split.add_point(Vector3(2, 0, 0))
	split.add_connection(0, 1)
	var mid := split.split_connection(0, Vector3(1, 0, 0))
	check(mid == 2, "split inserts a new point")
	check(split.points.size() == 3, "split leaves three points")
	check(split.connection_count() == 2, "split leaves two connections")
	check(not split.has_connection(0, 1), "the original connection is gone")
	check(split.has_connection(0, 2) and split.has_connection(2, 1), "the new point joins both ends")
	check(split.split_connection(9, Vector3.ZERO) == -1, "splitting a missing connection fails")

	# --- delete a connection, then a point with incident edges ------------
	var cut := make_graph()
	cut.add_point(Vector3(0, 0, 0))
	cut.add_point(Vector3(1, 0, 0))
	cut.add_point(Vector3(2, 0, 0))
	cut.add_connection(0, 1)
	cut.add_connection(1, 2)
	cut.remove_connections(PackedInt32Array([0]))
	check(cut.connection_count() == 1, "one connection remains after delete")
	check(cut.get_connection(0) == Vector2i(1, 2), "the remaining pair is the one not deleted")
	check(cut.points.size() == 3, "deleting a connection keeps the points")

	cut.remove_points(PackedInt32Array([1]))
	check(cut.points.size() == 2, "the middle point is gone")
	check(cut.connection_count() == 0, "incident connections go with the point")
	check(cut.points[0] == Vector3(0, 0, 0) and cut.points[1] == Vector3(2, 0, 0), "the other two points stay")

	# Removing a lower index remaps the surviving connection.
	var remap := make_graph()
	remap.add_point(Vector3(0, 0, 0))
	remap.add_point(Vector3(1, 0, 0))
	remap.add_point(Vector3(2, 0, 0))
	remap.add_connection(1, 2)
	remap.remove_points(PackedInt32Array([0]))
	check(remap.get_connection(0) == Vector2i(0, 1), "surviving endpoints are remapped down")

	# --- schema adds, fills, and drops attribute arrays -------------------
	var attributed := make_graph()
	attributed.add_point(Vector3.ZERO)
	attributed.add_point(Vector3(1, 0, 0))
	attributed.add_connection(0, 1)

	var schema := HEGoGraphAttributes.new()
	var width := make_def("width", HEGoGraphAttributeDef.Owner.POINT, HEGoGraphAttributeDef.ValueType.FLOAT)
	width.default_float = 0.5
	var kind := make_def("kind", HEGoGraphAttributeDef.Owner.POINT, HEGoGraphAttributeDef.ValueType.STRING)
	kind.default_string = "fence"
	kind.string_options = PackedStringArray(["fence", "wall"])
	var closed := make_def("closed", HEGoGraphAttributeDef.Owner.CONNECTION, HEGoGraphAttributeDef.ValueType.INT)
	closed.default_int = 0
	closed.int_as_toggle = true
	schema.attributes = [width, kind, closed]
	attributed.add_child(schema)
	attributed.sync_schema()

	check(attributed.point_attribs.has("width"), "a point float attrib is created")
	check(attributed.point_attribs["width"].size() == 2, "point attribs match the point count")
	check(is_equal_approx(attributed.point_attribs["width"][0], 0.5), "existing points get the default")
	check(attributed.point_attribs["kind"][1] == "fence", "existing points get the string default")
	check(attributed.connection_attribs.has("closed"), "a connection int attrib is created")
	check(attributed.connection_attribs["closed"].size() == 1, "connection attribs match the connection count")
	check(attributed.connection_attribs["closed"][0] == 0, "existing connections get the default")

	var extra := attributed.add_point(Vector3(0, 1, 0))
	check(attributed.point_attribs["width"].size() == 3, "adding a point grows point attribs")
	check(is_equal_approx(attributed.point_attribs["width"][extra], 0.5), "the new point gets the default")

	attributed.set_point_attrib_on("kind", PackedInt32Array([0, 2]), "wall")
	check(attributed.point_attribs["kind"][0] == "wall", "multi-assign writes the first index")
	check(attributed.point_attribs["kind"][1] == "fence", "multi-assign leaves the unlisted point")
	check(attributed.point_attribs["kind"][2] == "wall", "multi-assign writes the last index")

	# Split inherits the original connection's attributes onto both new ones.
	attributed.set_connection_attrib_on("closed", PackedInt32Array([0]), 1)
	attributed.split_connection(0, Vector3(0.5, 0, 0))
	check(attributed.connection_attribs["closed"].size() == 2, "split grows connection attribs")
	check(attributed.connection_attribs["closed"][0] == 1 and attributed.connection_attribs["closed"][1] == 1,
			"both new connections inherit the original value")

	# Dropping a def drops its stored values.
	schema.attributes = [width]
	check(not attributed.point_attribs.has("kind"), "a removed point attrib is dropped")
	check(not attributed.connection_attribs.has("closed"), "a removed connection attrib is dropped")
	check(attributed.point_attribs.has("width"), "an attrib still in the schema is kept")

	# Reserved names are skipped.
	var reserved := make_def("P", HEGoGraphAttributeDef.Owner.POINT, HEGoGraphAttributeDef.ValueType.FLOAT)
	var hego_meta := make_def("_hego_node_path", HEGoGraphAttributeDef.Owner.CONNECTION, HEGoGraphAttributeDef.ValueType.STRING)
	schema.attributes = [width, reserved, hego_meta]
	var names := []
	for def in attributed.collect_schema():
		names.append(def.attribute_name)
	check(names == ["width"], "reserved names are not collected, got %s" % str(names))

	# --- picking and placement, no camera needed --------------------------
	var projected := PackedVector2Array([Vector2(10, 10), Vector2(100, 10), Vector2(10, 100)])
	check(HEGoGraphPicking.closest_point(Vector2(12, 11), projected) == 0, "closest_point hits the nearby point")
	check(HEGoGraphPicking.closest_point(Vector2(500, 500), projected) == -1, "closest_point misses when outside the radius")
	var segs := PackedInt32Array([0, 1, 1, 2])
	check(HEGoGraphPicking.closest_connection(Vector2(55, 10), projected, segs) == 0, "closest_connection hits the horizontal segment")
	check(HEGoGraphPicking.closest_connection(Vector2(500, 500), projected, segs) == -1, "closest_connection misses when outside the radius")
	var on_seg := HEGoGraphPicking.closest_on_segment(Vector3(0, 0, 0), Vector3(2, 0, 0), Vector3(1, 5, 0))
	check(on_seg.is_equal_approx(Vector3(1, 0, 0)), "closest_on_segment projects onto the line")

	var cam_plane := HEGoGraphPlacement.camera_plane(Vector3(0, 0, 1), Vector3(0, 0, 5))
	var cam_hit: Variant = HEGoGraphPlacement.intersect_ray(Vector3(1, 2, 0), Vector3(0, 0, 1), cam_plane)
	check(cam_hit != null and cam_hit.is_equal_approx(Vector3(1, 2, 5)), "camera plane hit is at the anchor depth")
	var world := HEGoGraphPlacement.world_plane(HEGoGraphPlacement.Axis.XZ, Vector3(0, 3, 0), 1.0)
	var world_hit: Variant = HEGoGraphPlacement.intersect_ray(Vector3(2, 10, 4), Vector3(0, -1, 0), world)
	check(world_hit != null and is_equal_approx(world_hit.y, 4.0), "XZ plane offset sits at origin.y + offset")
	check(HEGoGraphPlacement.intersect_ray(Vector3(0, 0, 0), Vector3(0, 0, -1), cam_plane) == null, "a ray away from the plane misses")

	var restored := make_graph()
	restored.add_point(Vector3(1, 2, 3))
	restored.add_point(Vector3(4, 5, 6))
	restored.add_connection(0, 1)
	var snap: Dictionary = restored.capture_state()
	restored.add_point(Vector3.ZERO)
	restored.apply_state(snap)
	check(restored.points.size() == 2 and restored.connection_count() == 1, "apply_state restores topology")

	if failures == 0:
		print("All graph input tests passed.")
		quit(0)
	else:
		print("%d graph input test(s) failed." % failures)
		quit(1)
