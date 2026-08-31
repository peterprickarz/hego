@tool
class_name HEGoCurveOutput
extends RefCounted

## Turns the curves of a cooked HDA into [Path3D] nodes under [code]Outputs/[/code].
##
## The curve geometry itself is built by [HEGoCurveBuilder]; this only decides where
## the nodes go and reuses existing ones so anything referencing a path keeps working.

## Prim attribute naming the node a curve should end up at.
const NODE_PATH_ATTRIB := "hego_node_path"

## Folder generated curves go into when a curve does not name its own path.
const DEFAULT_CURVE_FOLDER := "Curves"


## Fetches the curves of [param host]'s asset node and builds the Path3D output.
static func handle(host: Node) -> void:
	var curves: Variant = await HEGoNodeUtil.await_task(host, host.hego_asset_node.fetch_curves([NODE_PATH_ATTRIB], []))
	if not curves is Array:
		return

	var outputs_root := HEGoNodeUtil.ensure_outputs_root(host)

	for i in range(curves.size()):
		var curve: Dictionary = curves[i]
		var output_curve := HEGoCurveBuilder.build(curve)

		var node_path: Variant = HEGoNodeUtil.get_attrib_value(curve, "prim_attribs", NODE_PATH_ATTRIB)
		if not node_path is String or node_path.is_empty():
			node_path = "%s/Curve3D_%s_%d" % [DEFAULT_CURVE_FOLDER, HEGoCurveBuilder.curve_type_to_string(int(curve.get("type", -1))), i]

		var path_parts := str(node_path).split("/", false)
		var parent_node := HEGoNodeUtil.ensure_parent_path(host, outputs_root, path_parts)
		var final_name := path_parts[path_parts.size() - 1] if path_parts.size() > 0 else "Curve3D_" + str(i)

		# Reuse an existing Path3D at this location so followers keep their reference.
		var path_node := parent_node.get_node_or_null(final_name)
		if path_node != null and not path_node is Path3D:
			path_node.queue_free()
			path_node = null
		if path_node == null:
			path_node = Path3D.new()
			path_node.name = final_name
			parent_node.add_child(path_node)
			HEGoNodeUtil.set_editor_owner(host, path_node)

		path_node.curve = output_curve
