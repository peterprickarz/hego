@icon('res://addons/hego/assets/houdini.svg')
@tool
extends Node3D
class_name HEGoNode3D

## Brings a Houdini Digital Asset into a Godot scene.
##
## [b]Cooking[/b] instantiates the HDA in the running Houdini session, feeds it the
## nodes wired up as inputs, cooks it, and turns the result into Godot nodes under a
## child called [code]Outputs[/code].
##
## The work itself lives in focused modules, so this node only orchestrates them:
## [HEGoInputNodes] for the input side, [HEGoMeshOutput], [HEGoMultiMeshOutput],
## [HEGoObjectOutput], [HEGoTerrain3DOutput], [HEGoTerrain3DInstancer] and
## [HEGoCurveOutput] for the outputs, with [HEGoNodeUtil] holding what they share.

@export_tool_button('Select HDA', "FileDialog") var select_hda_btn = _show_select_hda_dialog
## The asset definition name in Houdini, e.g. Sop/my_tool.hda
@export var asset_name: String
## Parm stash stores the parameters as a byte blob which stores parms between sessions
@export var parm_stash: PackedByteArray
## Input stash to store references to the inputs between sessions
@export var input_stash: Array

## Operator table used when [member asset_name] does not name one itself.
const DEFAULT_OPERATOR_TABLE := "Sop"

## Node id of an asset node that has not been instantiated in Houdini yet.
const UNINSTANTIATED_NODE_ID := -1

# Reference to the HEGoAssetNode this node drives in the session.
var hego_asset_node: HEGoAssetNode
# References to the input and merge nodes in the session, keyed by input index:
# { input_index: { "merge": HEGoMergeNode, "inputs": Array[HEGoInputNode] } }
var hego_input_nodes: Dictionary

# Names of the HDA's inputs, fetched once per instantiation.
var input_names: PackedStringArray


# ─────────────────────────────────────────────
# Cooking
# ─────────────────────────────────────────────

## Instantiates the HDA if needed, pushes inputs and parameters, cooks it and
## rebuilds the [code]Outputs[/code] subtree from the result.
func cook() -> void:
	var timings := HEGoCookTimings.new()

	timings.begin_phase()
	var was_instantiated := await _instantiate_asset_node()
	timings.end_phase("instantiation")

	timings.begin_phase()
	if not was_instantiated:
		# A failed fetch returns null, which must not end up in the typed member.
		var fetched_names = await _await_task(hego_asset_node.get_input_names())
		input_names = fetched_names if fetched_names is PackedStringArray else PackedStringArray()
	await _sync_inputs()
	timings.end_phase("input_setup")

	timings.begin_phase()
	var fetched_preset = await _await_task(hego_asset_node.get_preset())
	if fetched_preset is PackedByteArray:
		parm_stash = fetched_preset
	timings.end_phase("parm_stash")

	timings.begin_phase()
	var cook_result = await _await_task(hego_asset_node.cook())
	timings.end_phase("cook")
	if cook_result == null:
		push_error(HEGoNodeUtil.LOG_PREFIX + "Cook failed")
		print(timings.format_summary())
		return

	# Remove old output now that the cook is done (keeps previous output visible during cook)
	var outputs_node := get_node_or_null(HEGoNodeUtil.OUTPUTS_ROOT_NAME)
	if outputs_node:
		outputs_node.free()

	timings.begin_phase()
	await HEGoMeshOutput.handle(self)
	timings.end_phase("mesh_output")

	timings.begin_phase()
	await HEGoMultiMeshOutput.handle(self)
	timings.end_phase("multimesh_output")

	timings.begin_phase()
	await HEGoObjectOutput.handle(self)
	timings.end_phase("object_spawn_output")

	timings.begin_phase()
	await HEGoTerrain3DOutput.handle(self)
	timings.end_phase("terrain3d_output")

	timings.begin_phase()
	await HEGoTerrain3DInstancer.handle(self)
	timings.end_phase("terrain3d_instancer_output")

	timings.begin_phase()
	await HEGoCurveOutput.handle(self)
	timings.end_phase("path3d_output")

	print(timings.format_summary())


## Makes sure the asset node exists in the session and carries this node's transform
## and stashed parameters. Returns whether it was already instantiated beforehand.
func _instantiate_asset_node() -> bool:
	if not hego_asset_node:
		hego_asset_node = HEGoAssetNode.new()

	if asset_name.split("/").size() == 1:
		hego_asset_node.op_name = DEFAULT_OPERATOR_TABLE + "/" + asset_name
	else:
		hego_asset_node.op_name = asset_name

	# The id is -1 until the node exists in Houdini, which is also how we know
	# whether the stashed parameters still have to be restored.
	var was_instantiated := hego_asset_node.get_id() != UNINSTANTIATED_NODE_ID

	# instantiate() checks by itself whether the node already exists.
	await _await_task(hego_asset_node.instantiate())
	await _await_task(hego_asset_node.set_transform(global_transform))

	if not was_instantiated and parm_stash.size() > 0:
		await _await_task(hego_asset_node.set_preset(parm_stash))

	return was_instantiated


# ─────────────────────────────────────────────
# Inputs
# ─────────────────────────────────────────────

## Brings every HDA input in line with the Godot nodes stored in [member input_stash].
func _sync_inputs() -> void:
	for i in range(input_names.size()):
		var stash_entry := _input_stash_entry(i)
		var source_paths: Array = stash_entry["inputs"]
		var settings: Dictionary = stash_entry["settings"]

		if hego_input_nodes.has(i):
			await _update_input_chain(i, source_paths, settings)
		elif not source_paths.is_empty():
			await _create_input_chain(i, source_paths, settings)


## Input stash entry for input [param index], or empty inputs and settings.
func _input_stash_entry(index: int) -> Dictionary:
	if index >= input_stash.size() or not input_stash[index] is Dictionary:
		return {"inputs": [], "settings": {}}
	var entry: Dictionary = input_stash[index]
	return {
		"inputs": entry.get("inputs", []),
		"settings": entry.get("settings", {}),
	}


## Builds a fresh merge node with one input node per source and connects it to the HDA.
##
## Every HDA input goes through a merge node, because a single Houdini input can
## combine several Godot nodes.
func _create_input_chain(index: int, source_paths: Array, settings: Dictionary) -> void:
	var merge_node := HEGoMergeNode.new()
	await _await_task(merge_node.instantiate())

	var input_array := []
	for source_path in source_paths:
		input_array.append(await HEGoInputNodes.sync(self, null, source_path, settings))

	await _await_task(merge_node.connect_inputs(input_array))
	await _await_task(hego_asset_node.connect_input(merge_node, index))

	hego_input_nodes[index] = {
		"merge": merge_node,
		"inputs": input_array,
	}


## Re-sends the sources of an input that already exists in the session.
func _update_input_chain(index: int, source_paths: Array, settings: Dictionary) -> void:
	var input_dict: Dictionary = hego_input_nodes[index]
	var merge_node: HEGoMergeNode = input_dict["merge"]
	await _await_task(merge_node.instantiate())

	# Resizing first drops input nodes whose source is gone and pads with nulls,
	# and sync() creates a node wherever it finds a null.
	var input_array: Array = input_dict["inputs"]
	input_array.resize(source_paths.size())
	for j in range(source_paths.size()):
		input_array[j] = await HEGoInputNodes.sync(self, input_array[j], source_paths[j], settings)

	await _await_task(merge_node.connect_inputs(input_array))
	await _await_task(hego_asset_node.connect_input(merge_node, index))


# ─────────────────────────────────────────────
# Bottom panel interface
#
# The HEGo bottom panel talks to whatever node is selected through these methods,
# so any script implementing them can be driven by it. See demo/HDACurveTest.gd.
# ─────────────────────────────────────────────

## Tells the plugin this node can be edited from the HEGo bottom panel.
func hego_use_bottom_panel() -> bool:
	return true


## The asset node the bottom panel reads parameters from.
func hego_get_asset_node() -> HEGoAssetNode:
	return hego_asset_node


## The HDA this node cooks.
func hego_get_asset_name() -> String:
	return asset_name


## Stores a parameter preset so it survives session restarts and scene reloads.
func hego_set_parm_stash(preset: PackedByteArray) -> void:
	parm_stash = preset


## Deprecated alias of [method hego_set_parm_stash].
func hego_stash_parms(preset: PackedByteArray) -> void:
	hego_set_parm_stash(preset)


## The stored parameter preset.
func hego_get_parm_stash() -> PackedByteArray:
	return parm_stash


## The stored input references.
func hego_get_input_stash() -> Array:
	return input_stash


## Stores the input references the bottom panel collected.
##
## Each HDA input can combine several Godot nodes, so [param input_array] holds one
## entry per HDA input, each with its own list of node paths and its settings.
func hego_set_input_stash(input_array: Array) -> void:
	var result := []
	for input in input_array:
		var ref_array := []
		for ref in input["inputs"]:
			if ref != "":
				ref_array.append(ref)
		result.append({
			"inputs": ref_array,
			"settings": input["settings"],
		})
	input_stash = result


# ─────────────────────────────────────────────
# HDA selection
# ─────────────────────────────────────────────

func _show_select_hda_dialog() -> void:
	if not Engine.is_editor_hint():
		return

	var viewport := EditorInterface.get_editor_viewport_3d()
	var picker_scene := preload("res://addons/hego/ui/asset_picker_dialog.tscn")
	var picker := picker_scene.instantiate()

	# Parented to the viewport so the dialog lives as long as it is open.
	viewport.add_child(picker)
	picker.asset_selected.connect(_on_asset_selected)
	picker._populate_tree()
	picker.popup_centered()


func _on_asset_selected(selected_asset: String) -> void:
	# Clear old HDA data when selecting a new asset
	_clear_hda_data()

	asset_name = selected_asset
	notify_property_list_changed()
	print(HEGoNodeUtil.LOG_PREFIX + "Selected asset: ", selected_asset)


## Forgets everything tied to the previous HDA: the Houdini node, its parameters,
## its inputs and its output nodes.
func _clear_hda_data() -> void:
	if hego_asset_node:
		hego_asset_node.reset_node_id()

	parm_stash = PackedByteArray()
	input_stash.clear()
	hego_input_nodes.clear()
	input_names = PackedStringArray()

	var outputs_node := get_node_or_null(HEGoNodeUtil.OUTPUTS_ROOT_NAME)
	if outputs_node:
		outputs_node.queue_free()

	print(HEGoNodeUtil.LOG_PREFIX + "Cleared old HDA data and reset node ID")


# ─────────────────────────────────────────────
# Internals
# ─────────────────────────────────────────────

## Waits for a [HEGoTask] and returns its result, or null if it failed.
## See [method HEGoNodeUtil.await_task].
func _await_task(task: HEGoTask) -> Variant:
	return await HEGoNodeUtil.await_task(self, task)
