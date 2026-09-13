@tool
class_name HEGoHelpers
extends RefCounted

## The tedious parts of driving an HDA, for a node that writes its own [code]cook()[/code].
##
## This is not a layer over Houdini Engine. A script holds its own [HEGoAssetNode] and calls
## it directly; these are the handful of things that are either fiddly to repeat or subtle
## enough to get wrong silently.
##
## [codeblock]
## @tool
## extends MeshInstance3D
##
## var hego := HEGoHelpers.new(self)
## @export var parm_stash: PackedByteArray
## @export var input_stash: Array
##
## func cook() -> void:
##     var fence := hego.asset("Sop/my_fence")
##     if not await hego.instantiate(fence, parm_stash):
##         return
##     await hego.sync_inputs(fence)
##     if await hego.task(fence.cook()) == null:
##         return
##
##     var meshes := await HEGoMeshOutput.fetch_meshes(hego.output_context(fence))
##     mesh = meshes.values()[0] if not meshes.is_empty() else null
##     parm_stash = await hego.save_parameters(fence)
## [/codeblock]
##
## Everything the HDA does is still an ordinary call on [HEGoAssetNode], in the order the
## script writes it.

## Category this file logs under, shown in the session panel filter.
const LOG_CATEGORY := "cook"

## Operator table assumed when an operator name does not name one.
const DEFAULT_OPERATOR_TABLE := "Sop"

## Node id of an asset that does not exist in Houdini yet.
const UNINSTANTIATED_NODE_ID := -1

## The node these assets belong to.
var owner_node: Node

## Every asset this node has made, keyed by label, in creation order. The bottom panel reads
## this to know what to show and what to call each section.
var assets: Dictionary = {}

# Live merge and input nodes per asset, so an input node is reused across cooks rather than
# rebuilt. Keyed by label, then by HDA input index.
var _input_nodes: Dictionary = {}


func _init(p_owner_node: Node) -> void:
	owner_node = p_owner_node


## Waits for [param task] and returns its result, or [code]null[/code] if it failed.
##
## [code]null[/code] is not a general failure signal: a task that legitimately did nothing
## also completes with null, which is what HEGo returns for work it could skip. It reads as a
## failure check after [code]cook()[/code] because a successful cook returns 0.
func task(task: HEGoTask) -> Variant:
	return await HEGoNodeUtil.await_task(owner_node, task)


## The asset node for [param operator_name], created on first use and reused afterwards.
##
## Reusing it is what keeps the Houdini node id valid between cooks. [param label] names it
## for the bottom panel and defaults to the operator without its table.
func asset(operator_name: String, label := "") -> HEGoAssetNode:
	var key := label if not label.is_empty() else _default_label(operator_name)
	var full_name := operator_name if operator_name.contains("/") \
		else DEFAULT_OPERATOR_TABLE + "/" + operator_name

	if assets.has(key):
		var existing: HEGoAssetNode = assets[key]
		if existing.op_name != full_name:
			# The label now names a different HDA, so the Houdini node it holds is not the
			# one wanted. Forgetting the id makes the next instantiate create the right one.
			existing.reset_node_id()
			existing.op_name = full_name
		return existing

	var created := HEGoAssetNode.new()
	created.op_name = full_name
	assets[key] = created
	return created


## Makes [param asset] exist in Houdini. False when it could not be created.
##
## Pushes the owner's transform when it is spatial, and restores
## [param stashed_parameters] only when this call is what created the Houdini node. That
## condition is the subtle part: restoring on every cook would undo whatever the user has
## since changed in the panel.
##
## Returns false on a license failure, which Houdini reports by completing successfully with
## an id of -1 rather than by failing. An unknown operator name is not caught here, because
## Houdini hands back a valid id for one; the cook is what rejects it.
func instantiate(asset: HEGoAssetNode, stashed_parameters := PackedByteArray()) -> bool:
	var existed := asset.get_id() != UNINSTANTIATED_NODE_ID

	await task(asset.instantiate())
	if owner_node is Node3D:
		await task(asset.set_transform(owner_node.global_transform))

	if asset.get_id() == UNINSTANTIATED_NODE_ID:
		HEGoLog.get_singleton().error(LOG_CATEGORY, "Could not instantiate " + asset.op_name)
		return false

	if not existed and stashed_parameters.size() > 0:
		await task(asset.set_preset(stashed_parameters))
	return true


## The asset's current parameters, as a blob to store on the node so they survive a session
## restart and a scene reload. Empty when they could not be read.
func save_parameters(asset: HEGoAssetNode) -> PackedByteArray:
	var preset = await task(asset.get_preset())
	return preset if preset is PackedByteArray else PackedByteArray()


## Feeds [param asset] the Godot nodes stored in the owner's input stash.
##
## Every HDA input goes through a merge node, because one Houdini input can combine several
## Godot nodes, and the input nodes are kept between cooks so unchanged geometry is not
## re-sent. [param skip_indices] leaves inputs alone that something else fills, which is how
## an input fed by another HDA survives.
func sync_inputs(asset: HEGoAssetNode, skip_indices := []) -> void:
	var names = await task(asset.get_input_names())
	if not names is PackedStringArray:
		return

	var rows := _input_rows()
	var label := _label_of(asset)
	if not _input_nodes.has(label):
		_input_nodes[label] = {}
	var chains: Dictionary = _input_nodes[label]

	for index in range(names.size()):
		if skip_indices.has(index):
			continue

		var paths := []
		var settings := {}
		if index < rows.size() and rows[index] is Dictionary:
			paths = rows[index].get("inputs", [])
			settings = rows[index].get("settings", {})

		if chains.has(index):
			await _update_chain(asset, chains, index, paths, settings)
		elif not paths.is_empty():
			await _create_chain(asset, chains, index, paths, settings)


## Points HDA input [param index] at [param sources], which may be a [Node], a [NodePath], a
## path string, or an array of any of those.
##
## Writes to the same stash the panel's Inputs pane writes to, so an exported property and
## the panel agree rather than fighting.
func set_input(index: int, sources: Variant) -> void:
	var list: Array = sources if sources is Array else [sources]
	var paths := []
	for source in list:
		if source == null:
			continue
		paths.append(str(_scene_relative_path(source)) if source is Node else str(source))

	var rows := _input_rows()
	while rows.size() <= index:
		rows.append({"inputs": [], "settings": {}})
	rows[index] = {"inputs": paths, "settings": rows[index].get("settings", {})}

	if owner_node.has_method("hego_set_input_stash"):
		owner_node.hego_set_input_stash(rows)


## Fetches what [param asset]'s cook produced and wraps it for the output handlers.
##
## Needed by anything in the output library: [method HEGoMeshOutput.fetch_meshes],
## [method HEGoMultiMeshOutput.setup_multimesh], and a handler's own
## [code]handle(context)[/code].
func output_context(asset: HEGoAssetNode) -> HEGoOutputContext:
	var summary = await task(asset.get_output_summary())
	return HEGoOutputContext.create(owner_node, asset, summary if summary is Dictionary else {})


# ─────────────────────────────────────────────
# Internals
# ─────────────────────────────────────────────

func _default_label(operator_name: String) -> String:
	var parts := operator_name.split("/", false)
	return parts[parts.size() - 1] if not parts.is_empty() else "asset"


func _label_of(asset: HEGoAssetNode) -> String:
	for label in assets:
		if assets[label] == asset:
			return label
	return ""


## The owner's input rows, through the same methods the bottom panel uses.
func _input_rows() -> Array:
	if owner_node.has_method("hego_get_input_stash"):
		var rows = owner_node.hego_get_input_stash()
		if rows is Array:
			return rows
	return []


## A path relative to the edited scene, matching what the panel's input rows store. Using
## get_path_to() instead would give a path that resolves in the editor and not at runtime.
func _scene_relative_path(node: Node) -> NodePath:
	var tree := owner_node.get_tree()
	if tree != null and tree.edited_scene_root != null:
		return tree.edited_scene_root.get_path_to(node)
	return owner_node.get_path_to(node)


func _create_chain(asset: HEGoAssetNode, chains: Dictionary, index: int, paths: Array, settings: Dictionary) -> void:
	var merge_node := HEGoMergeNode.new()
	await task(merge_node.instantiate())

	var input_array := []
	for path in paths:
		input_array.append(await HEGoInputNodes.sync(owner_node, null, path, settings))

	await task(merge_node.connect_inputs(input_array))
	await task(asset.connect_input(merge_node, index))
	chains[index] = {"merge": merge_node, "inputs": input_array}


func _update_chain(asset: HEGoAssetNode, chains: Dictionary, index: int, paths: Array, settings: Dictionary) -> void:
	var chain: Dictionary = chains[index]
	var merge_node: HEGoMergeNode = chain["merge"]
	await task(merge_node.instantiate())

	# Resizing first drops the input nodes whose source is gone and pads with nulls, and
	# sync() creates a node wherever it finds one.
	var input_array: Array = chain["inputs"]
	input_array.resize(paths.size())
	for i in range(paths.size()):
		input_array[i] = await HEGoInputNodes.sync(owner_node, input_array[i], paths[i], settings)

	await task(merge_node.connect_inputs(input_array))
	await task(asset.connect_input(merge_node, index))
