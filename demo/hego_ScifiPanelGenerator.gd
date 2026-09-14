@icon('res://addons/hego/assets/houdini.svg')
@tool
extends MeshInstance3D
class_name HDAScifiPanelGenerator

## A custom HEGo node that panels whatever meshes it is given.
##
## Its inputs come from an exported array rather than from the bottom panel's Inputs pane,
## so [method cook] pushes them into the input stash itself and lets [HEGoHelpers] build the
## merge chain. The HDA tags its output with material names of its own rather than with
## resource paths, so this node maps them to materials instead of using
## [method HEGoMeshOutput.fetch_meshes], which expects the path convention.

## The asset definition name in Houdini.
const ASSET_NAME := "Sop/hego_scifipanelgenerator"

## Name this script gives the HDA, used to look it back up and to label it in the panel.
const ASSET_LABEL := "scifi_panels"

## What this HDA's hego_material attribute values mean. An output surface tagged with a
## name that is not here is left without a material.
const MATERIALS := {
	"Main": "res://materials/m_main.tres",
	"DarkGrey": "res://materials/m_dark_grey.tres",
	"Accent": "res://materials/m_accent.tres",
	"DarkAccent": "res://materials/m_dark_accent.tres",
	"Black": "res://materials/m_black.tres",
	"default": "res://materials/m_default.tres",
}

@export_tool_button("Cook", "Bake") var action_cook = func(): cook()
## The meshes to panel. They are merged into the HDA's first input.
@export var input_nodes: Array[MeshInstance3D] = []
## The HDA's parameters as a blob, so they survive a session restart and a scene reload.
@export var parm_stash: PackedByteArray

var hego := HEGoHelpers.new(self)

## Where the helper reads and writes input references. Not exported, because input_nodes is
## what this node is driven by; the panel's Inputs pane shows these rows but every cook
## overwrites them from input_nodes.
var input_stash: Array = []


## Sends the input meshes to Houdini, cooks the HDA and puts the panelled mesh on this node.
func cook() -> void:
	var panels := hego.asset(ASSET_NAME, ASSET_LABEL)
	if not await hego.instantiate(panels, parm_stash):
		return

	# One input taking several meshes: set_input records them all and sync_inputs wires them
	# through a merge node, reusing the Houdini input nodes it made last cook.
	hego.set_input(0, input_nodes)
	await hego.sync_inputs(panels)

	# A null result means the task failed. A result of -1 means Houdini rejected the cook
	# while the task itself completed, which a null check alone misses.
	var cook_result = await hego.task(panels.cook())
	if cook_result == null or int(cook_result) != 0:
		return

	mesh = await _build_mesh(await hego.output_context(panels))
	parm_stash = await hego.save_parameters(panels)


## One surface per material name the HDA tagged its geometry with.
func _build_mesh(context: HEGoOutputContext) -> ArrayMesh:
	var groups := await HEGoMeshOutput.fetch_surface_groups(context)
	var array_mesh := ArrayMesh.new()
	for mesh_instance_key in groups:
		var surfaces: Dictionary = groups[mesh_instance_key]
		for material_key in surfaces:
			array_mesh.add_surface_from_arrays(
				Mesh.PRIMITIVE_TRIANGLES, surfaces[material_key]["surface_array"])
			if MATERIALS.has(material_key):
				array_mesh.surface_set_material(
					array_mesh.get_surface_count() - 1, load(MATERIALS[material_key]))
	return array_mesh


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


## The stored input references, which [method cook] rewrites from input_nodes.
func hego_get_input_stash() -> Array:
	return input_stash


## Stores input references. The helper writes here when [method cook] pushes input_nodes in.
func hego_set_input_stash(input_array: Array) -> void:
	input_stash = input_array
