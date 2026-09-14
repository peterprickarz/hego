@icon('res://addons/hego/assets/houdini.svg')
@tool
extends MeshInstance3D
class_name HDATestScatterNodes

## A custom HEGo node that scatters grass over its input meshes.
##
## Its parameters are exported properties rather than panel widgets, so [method cook] pushes
## them into the HDA on every cook. That is the shape to copy when a tool should look like an
## ordinary Godot node in the inspector and the HDA behind it is an implementation detail.
##
## The points come back as a plain geometry output and are turned into a [MultiMesh] by
## [method HEGoMultiMeshOutput.setup_multimesh], the same call the standard multimesh
## handler makes.

## The asset definition name in Houdini.
const ASSET_NAME := "Sop/hego_testscatter_tool"

## Name this script gives the HDA, used to look it back up and to label it in the panel.
const ASSET_LABEL := "scatter"

## Parameters on the HDA that the exported properties below drive.
const PARM_SPIKE_DENSITY := "spike_density"
const PARM_NORMAL_ALIGNED := "normal_aligned"
const PARM_DENSITY_BIAS := "density_bias"
const PARM_MIN_SCALE := "min_scale"
const PARM_MAX_SCALE := "max_scale"

## What is instanced at every scattered point, and what it is shaded with.
const INSTANCED_MESH := "res://models/test_grass_subnet1.res"
const INSTANCE_SHADER := "res://grass_shader.tres"

## Name of the node the multimesh is built under.
const MULTIMESH_NAME := "scattered_grass"

@export_tool_button("Cook", "Bake") var action_cook = func(): cook()
## The meshes to scatter over, merged into the HDA's first input.
@export var input_nodes: Array[Node] = []
## The meshes the scatter density is biased towards, merged into the HDA's second input.
@export var dist_input_nodes: Array[Node] = []
@export var normal_aligned := true
@export var spike_density := 1.0
@export var density_bias := 1.0
@export var min_scale := 1.0
@export var max_scale := 1.0
## The HDA's parameters as a blob, so they survive a session restart and a scene reload.
@export var parm_stash: PackedByteArray

var hego := HEGoHelpers.new(self)

## Where the helper reads and writes input references. Not exported, because the two input
## arrays above are what this node is driven by; every cook rewrites these rows from them.
var input_stash: Array = []


## Cooks the HDA and rebuilds the multimesh of scattered instances under Outputs/.
func cook() -> void:
	var scatter := hego.asset(ASSET_NAME, ASSET_LABEL)
	if not await hego.instantiate(scatter, parm_stash):
		return

	hego.set_input(0, input_nodes)
	hego.set_input(1, dist_input_nodes)
	await hego.sync_inputs(scatter)

	# Pushed after instantiate(), which is where a stashed preset would have been restored,
	# so these properties are what the HDA ends up cooking with.
	await hego.task(scatter.set_parm(PARM_DENSITY_BIAS, density_bias))
	await hego.task(scatter.set_parm(PARM_MIN_SCALE, min_scale))
	await hego.task(scatter.set_parm(PARM_MAX_SCALE, max_scale))
	await hego.task(scatter.set_parm(PARM_SPIKE_DENSITY, spike_density))
	await hego.task(scatter.set_parm(PARM_NORMAL_ALIGNED, int(normal_aligned)))

	# A null result means the task failed. A result of -1 means Houdini rejected the cook
	# while the task itself completed, which a null check alone misses.
	var cook_result = await hego.task(scatter.cook())
	if cook_result == null or int(cook_result) != 0:
		return

	# Cleared only now the cook has succeeded, so a failure leaves the last result visible.
	var outputs_node := get_node_or_null(HEGoNodeUtil.OUTPUTS_ROOT_NAME)
	if outputs_node:
		outputs_node.free()

	var context := await hego.output_context(scatter)
	var points := await _fetch_points(scatter)
	if points.is_empty():
		return

	HEGoMultiMeshOutput.setup_multimesh(context, load(INSTANCED_MESH), MULTIMESH_NAME, points)

	var multimesh_instance := context.outputs_root().get_node_or_null(MULTIMESH_NAME)
	if multimesh_instance:
		var shader_material := ShaderMaterial.new()
		shader_material.shader = load(INSTANCE_SHADER)
		multimesh_instance.material_override = shader_material

	parm_stash = await hego.save_parameters(scatter)


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


## The asset node the bottom panel reads parameters from, or null before the first cook.
func hego_get_asset_node() -> HEGoAssetNode:
	return hego.assets.get(ASSET_LABEL)


## The HDA this node cooks, which is what the panel's preset list is keyed by.
func hego_get_asset_name() -> String:
	return ASSET_NAME


## Stores a parameter preset so it survives session restarts and scene reloads.
func hego_set_parm_stash(preset: PackedByteArray) -> void:
	parm_stash = preset


## The stored input references, which [method cook] rewrites from the two input arrays.
func hego_get_input_stash() -> Array:
	return input_stash


## Stores input references. The helper writes here when [method cook] pushes the arrays in.
func hego_set_input_stash(input_array: Array) -> void:
	input_stash = input_array
