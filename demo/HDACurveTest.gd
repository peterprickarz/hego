@icon('res://addons/hego/assets/houdini.svg')
@tool
extends MeshInstance3D
class_name HDACurveTest

## A custom HEGo node that takes a [Path3D] and builds a fence along it.
##
## Unlike [HEGoNode3D], this node's input is an exported property rather than a row in the
## bottom panel's Inputs pane, so it wires the curve up itself. That is what the raw input
## classes are for: [HEGoHelpers] handles the HDA, and anything the script wants to control
## it keeps.

## The asset definition name in Houdini.
const ASSET_NAME := "Sop/hego_curvetests"

## Name this script gives the HDA, used to look it back up and to label it in the panel.
const ASSET_LABEL := "curve_test"

## Spacing, in metres, the input curve is resampled at before it is sent to Houdini.
const CURVE_SAMPLE_LENGTH := 2.0

@export_tool_button("Cook", "Bake") var action_cook = func(): cook()
## The path the fence follows.
@export var input_node: Node = null
## The HDA's parameters as a blob, so they survive a session restart and a scene reload.
@export var parm_stash: PackedByteArray

var hego := HEGoHelpers.new(self)

## The Houdini node the curve is sent through, kept so a recook reuses it.
var curve_input: HEGoCurveInputNode


## Sends the curve to Houdini, cooks the HDA and puts the mesh it produced on this node.
func cook() -> void:
	var fence := hego.asset(ASSET_NAME, ASSET_LABEL)
	if not await hego.instantiate(fence, parm_stash):
		return

	if input_node is Path3D:
		if curve_input == null:
			curve_input = HEGoCurveInputNode.new()
		await hego.task(curve_input.instantiate())
		await hego.task(curve_input.set_curve_from_path_3d(input_node, CURVE_SAMPLE_LENGTH))
		await hego.task(fence.connect_input(curve_input, 0))

	# A cook Houdini rejects fails its task, so null is the whole check.
	if await hego.task(fence.cook()) == null:
		return

	var meshes := await HEGoMeshOutput.fetch_meshes(await hego.output_context(fence))
	mesh = meshes.values()[0] if not meshes.is_empty() else null

	parm_stash = await hego.save_parameters(fence)


# ─────────────────────────────────────────────
# Bottom panel interface
# ─────────────────────────────────────────────

## Tells the plugin this node can be edited from the HEGo bottom panel.
func hego_use_bottom_panel() -> bool:
	return true


## The asset node the bottom panel reads parameters from, or null before the first cook.
func hego_get_asset_node() -> HEGoAssetNode:
	return hego.assets.get(ASSET_LABEL)


## The HDA this node cooks, which is what the panel's preset list is keyed by.
func hego_get_asset_name() -> String:
	return ASSET_NAME


## Stores a parameter preset so it survives session restarts and scene reloads.
func hego_set_parm_stash(preset: PackedByteArray) -> void:
	parm_stash = preset
