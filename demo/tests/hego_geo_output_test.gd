## Shape checks for the code-based output API.
##
## Everything that needs real geometry needs a Houdini session, so this covers what
## can be checked without one: the classes are registered, the methods are bound with
## the signatures the handlers rely on, and the empty states behave.
extends SceneTree

var failures := 0


func check(condition: bool, what: String) -> void:
	if condition:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func has_method_bound(class_name_str: String, method: String) -> bool:
	for m in ClassDB.class_get_method_list(class_name_str, true):
		if m["name"] == method:
			return true
	return false


func _initialize() -> void:
	# --- classes registered ------------------------------------------------
	check(ClassDB.class_exists("HEGoGeoOutput"), "HEGoGeoOutput is registered")
	check(ClassDB.class_exists("HEGoGeoSelection"), "HEGoGeoSelection is registered")

	# --- the API the handlers will call ------------------------------------
	for method in ["is_valid", "get_point_count", "get_attribute_names", "has_attribute",
			"get_attribute_names_with_prefix", "load_attributes", "get_attribute",
			"select_all", "filter_by", "split_by"]:
		check(has_method_bound("HEGoGeoOutput", method), "HEGoGeoOutput.%s is bound" % method)

	for method in ["size", "get_indices", "filter_by", "split_by", "get_points"]:
		check(has_method_bound("HEGoGeoSelection", method), "HEGoGeoSelection.%s is bound" % method)

	check(has_method_bound("HEGoAssetNode", "get_geo_output"), "HEGoAssetNode.get_geo_output is bound")

	# --- owner constants ----------------------------------------------------
	# HAPI_AttributeOwner: VERTEX 0, POINT 1, PRIM 2, DETAIL 3.
	check(HEGoGeoOutput.OWNER_VERTEX == 0, "OWNER_VERTEX matches HAPI_ATTROWNER_VERTEX")
	check(HEGoGeoOutput.OWNER_POINT == 1, "OWNER_POINT matches HAPI_ATTROWNER_POINT")
	check(HEGoGeoOutput.OWNER_PRIM == 2, "OWNER_PRIM matches HAPI_ATTROWNER_PRIM")
	check(HEGoGeoOutput.OWNER_DETAIL == 3, "OWNER_DETAIL matches HAPI_ATTROWNER_DETAIL")

	# --- empty states -------------------------------------------------------
	var output := HEGoGeoOutput.new()
	check(not output.is_valid(), "a bare output is not valid")
	check(output.get_point_count() == 0, "a bare output has no points")
	check(output.get_attribute_names().is_empty(), "a bare output lists no attributes")
	check(output.get_attribute("P").is_empty(), "a bare output has no P")
	check(output.select_all().size() == 0, "select_all on a bare output is empty")

	var selection := HEGoGeoSelection.new()
	check(selection.size() == 0, "a bare selection is empty")
	check(selection.get_points().is_empty(), "a bare selection yields no points")
	check(selection.split_by("anything").is_empty(), "splitting a bare selection yields nothing")

	# --- an uninstantiated node fails cleanly rather than crashing -----------
	var node := HEGoAssetNode.new()
	var task: HEGoTask = node.get_geo_output()
	check(task != null, "get_geo_output returns a task")
	check(task.get_status() == HEGoTask.FAILED, "get_geo_output fails without an instantiated HDA")
	check(not task.get_error_message().is_empty(), "the failure explains itself")

	print("")
	print("failures: ", failures)
	quit(1 if failures > 0 else 0)
