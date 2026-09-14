@icon('res://addons/hego/assets/houdini.svg')
@tool
extends MeshInstance3D
class_name HDAPigHead

## A custom HEGo node in a dozen lines: cook one HDA, put its mesh on itself.
##
## The HDA is fixed in the script rather than picked in the editor, which is the usual shape
## for a tool built around one specific asset. Because no [code]hego_set_asset_name()[/code]
## is implemented, the bottom panel leaves out its asset picker but still shows this node's
## parameters and its Recook button.
##
## Everything here is an ordinary call on [HEGoAssetNode]; [HEGoHelpers] only supplies the
## parts that are tedious to repeat.

## The asset definition name in Houdini.
const ASSET_NAME := "Sop/hego_testpighead_tool"

## Name this script gives the HDA, used to look it back up and to label it in the panel.
const ASSET_LABEL := "pighead"

@export_tool_button("Cook", "Bake") var action_cook = func(): cook()
## The HDA's parameters as a blob, so they survive a session restart and a scene reload.
@export var parm_stash: PackedByteArray

var hego := HEGoHelpers.new(self)


## Cooks the HDA and puts the mesh it produced on this node.
func cook() -> void:
	var pighead := hego.asset(ASSET_NAME, ASSET_LABEL)
	if not await hego.instantiate(pighead, parm_stash):
		return

	# A cook Houdini rejects fails its task, so null is the whole check.
	if await hego.task(pighead.cook()) == null:
		return

	# This HDA writes a hego_lod primitive attribute, which fetch_meshes turns into Godot
	# LODs on the mesh it builds. One mesh instance, so take the first.
	var meshes := await HEGoMeshOutput.fetch_meshes(await hego.output_context(pighead))
	mesh = meshes.values()[0] if not meshes.is_empty() else null

	parm_stash = await hego.save_parameters(pighead)


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
