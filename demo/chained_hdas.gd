@icon('res://addons/hego/assets/houdini.svg')
@tool
extends Node3D
class_name ChainedHDAs

## Two HDAs chained inside Houdini: the first builds geometry, the second scatters over it.
##
## Chaining needs nothing from HEGo beyond [method HEGoAssetNode.connect_input] - the
## geometry never comes back to Godot in between, Houdini hands one node's output straight to
## the next. Only the last stage is cooked, because cooking it makes Houdini pull everything
## upstream by itself.
##
## The two things worth copying here are the skip list handed to
## [method HEGoHelpers.sync_inputs], which keeps the input stash from overwriting the chained
## input with a merge node, and the stage buttons: a tool with several stages can put its own
## switcher in the inspector and point the bottom panel at whichever stage the user is
## working on.

## The HDAs this node chains, and what it calls them in the panel.
const BASE_ASSET := "Sop/hego_testpighead_tool"
const BASE_LABEL := "base"
const SCATTER_ASSET := "Sop/hego_testscatter_tool"
const SCATTER_LABEL := "scatter"

## The HDA input the chain is wired into. sync_inputs is told to leave it alone.
const CHAINED_INPUT := 0

## What is instanced at every scattered point.
const INSTANCED_MESH := "res://models/test_grass_subnet1.res"

## Name of the node the multimesh is built under.
const MULTIMESH_NAME := "scattered_grass"

@export_tool_button("Cook", "Bake") var action_cook = func(): cook()
@export_tool_button("Edit base", "Edit") var action_edit_base = func(): hego.highlight(BASE_LABEL)
@export_tool_button("Edit scatter", "Edit") var action_edit_scatter = func(): hego.highlight(SCATTER_LABEL)

## Each stage keeps its own parameters. One blob per HDA, because a preset belongs to the
## HDA it was read from and there is nothing sensible to do with another one's.
@export var base_parm_stash: PackedByteArray
@export var scatter_parm_stash: PackedByteArray
## References to the Godot nodes wired into the scatter stage's remaining inputs.
@export var input_stash: Array

var hego := HEGoHelpers.new(self)


## Cooks the chain and rebuilds the multimesh of scattered instances under Outputs/.
func cook() -> void:
	var base := hego.asset(BASE_ASSET, BASE_LABEL)
	var scatter := hego.asset(SCATTER_ASSET, SCATTER_LABEL)

	# The scatter stage goes first in the panel because it is the one being tuned, and
	# because the panel shows the input rows of the first stage listed - which are this
	# node's inputs, and it is the scatter that is fed them.
	hego.show_in_panel([SCATTER_LABEL, BASE_LABEL])

	if not await hego.instantiate(base, base_parm_stash):
		return
	if not await hego.instantiate(scatter, scatter_parm_stash):
		return

	# The chain itself. Both stages carry this node's transform, which instantiate() does:
	# leaving an upstream stage at the origin moves everything downstream of it by however
	# far this node is from the origin.
	await hego.task(scatter.connect_input(base, CHAINED_INPUT))

	# Everything except the chained input comes from the stash as usual. Without the skip the
	# next cook would replace the chain with an empty merge node and the scatter would have
	# nothing to scatter over.
	await hego.sync_inputs(scatter, [CHAINED_INPUT])

	# Only the last stage is cooked. Houdini cooks base because scatter asks it for geometry.
	var cook_result = await hego.task(scatter.cook())
	if cook_result == null or int(cook_result) != 0:
		return

	# Cleared only now the cook has succeeded, so a failure leaves the last result visible.
	var outputs_node := get_node_or_null(HEGoNodeUtil.OUTPUTS_ROOT_NAME)
	if outputs_node:
		outputs_node.free()

	var context := await hego.output_context(scatter)
	var points := await _fetch_points(scatter)
	if not points.is_empty():
		HEGoMultiMeshOutput.setup_multimesh(context, load(INSTANCED_MESH), MULTIMESH_NAME, points)

	base_parm_stash = await hego.save_parameters(base)
	scatter_parm_stash = await hego.save_parameters(scatter)


## Every point of the cook, with the attributes an instance transform is built from.
func _fetch_points(scatter: HEGoAssetNode) -> Dictionary:
	var output: HEGoGeoOutput = await hego.task(scatter.get_geo_output())
	if output == null or not output.is_valid():
		return {}

	var attribs := PackedStringArray(HEGoPointUtil.ORIENTATION_ATTRIBS + [HEGoPointUtil.COLOR_ATTRIB])
	await hego.task(output.load_attributes(attribs))
	return output.select_all().get_points(attribs)


# ─────────────────────────────────────────────
# Bottom panel interface
# ─────────────────────────────────────────────

## Tells the plugin this node can be edited from the HEGo bottom panel.
func hego_use_bottom_panel() -> bool:
	return true


## The HDAs the panel shows, in the order this node wants them, with whichever stage the
## buttons above last asked for marked to be opened and scrolled to.
##
## Answering this instead of hego_get_asset_node() is the whole of what a multi-HDA node has
## to do differently.
func hego_get_panel_assets() -> Array:
	return hego.panel_assets()


## The stored input references. Input rows belong to this node rather than to one HDA, and
## the panel shows them against the first stage listed, which is the scatter.
func hego_get_input_stash() -> Array:
	return input_stash


## Stores the input references the bottom panel collected.
func hego_set_input_stash(input_array: Array) -> void:
	input_stash = input_array
