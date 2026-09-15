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


## Name of the cook phase this handler is timed under.
static func output_phase() -> String:
	return "path3d_output"


## Whether the cook produced curves.
static func should_handle(summary: Dictionary) -> bool:
	return HEGoNodeUtil.output_has(summary, "has_curves")


## Fetches the cooked curves and builds the Path3D output.
static func handle(context: HEGoOutputContext) -> void:
	var curves: Variant = await context.await_task(context.asset.fetch_curves([NODE_PATH_ATTRIB], []))
	if not curves is Array:
		return

	for i in range(curves.size()):
		var curve: Dictionary = curves[i]

		var node_path: Variant = HEGoNodeUtil.get_attrib_value(curve, "prim_attribs", NODE_PATH_ATTRIB)
		if not node_path is String or node_path.is_empty():
			node_path = "%s/Curve3D_%s_%d" % [DEFAULT_CURVE_FOLDER, HEGoCurveBuilder.curve_type_to_string(int(curve.get("type", -1))), i]

		# place() reuses a Path3D already at this location, so anything following the path
		# keeps its reference. In practice nothing is there to reuse yet, because a cook
		# frees the whole Outputs subtree before the handlers run.
		var path_node := context.place(str(node_path), "Curve3D_" + str(i), Path3D.new) as Path3D
		path_node.curve = HEGoCurveBuilder.build(curve)
