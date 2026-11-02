@tool
class_name HEGoAssetAgent
extends RefCounted

## Holds the HDAs one Godot node owns, and does the fiddly parts of driving them.
##
## Using one is optional. Every method below is a short sequence of ordinary
## [HEGoAssetNode] calls that a node can make itself, and the manual form of each is in the
## documentation; the agent exists because a few of those sequences are tedious to repeat
## and two are easy to get silently wrong. What it holds is the point of holding it: the
## assets by label, and the merge and input nodes behind each HDA input, all of which have
## to survive from one cook to the next for the Houdini node ids to stay valid.
##
## [codeblock]
## @tool
## extends MeshInstance3D
##
## var agent := HEGoAssetAgent.new(self)
## @export var parm_stash: PackedByteArray
## @export var input_stash: Array
##
## func cook() -> void:
##     var fence := agent.asset("Sop/my_fence")
##     if not await agent.instantiate(fence, parm_stash):
##         return
##     await agent.sync_inputs(fence)
##     if await agent.task(fence.cook()) == null:
##         return
##
##     var meshes := await HEGoMeshOutput.fetch_meshes(await agent.output_context(fence))
##     mesh = meshes.values()[0] if not meshes.is_empty() else null
##     parm_stash = await agent.save_parameters(fence)
## [/codeblock]
##
## Everything the HDA does is still an ordinary call on [HEGoAssetNode], in the order the
## script writes it. The agent never stands between the two.

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

## Labels the bottom panel shows, in the order it shows them. Empty means every asset, in
## creation order. Set it with [method show_in_panel].
var panel_labels: Array = []

## Label of the asset the panel opens and scrolls to after a rebuild, or empty for none.
## Set it with [method highlight].
var highlighted_label: String = ""

# Live merge and input nodes per asset, so an input node is reused across cooks rather than
# rebuilt. Keyed by label, then by HDA input index.
var _input_nodes: Dictionary = {}


func _init(p_owner_node: Node) -> void:
	owner_node = p_owner_node


## Waits for [param task] and returns its result, or [code]null[/code] if it failed.
##
## [code]null[/code] is not a general failure signal: a task that legitimately did nothing
## also completes with null, which is what HEGo returns for work it could skip. It does mean
## failure after [code]cook()[/code], which returns 0 when it succeeds and fails its task
## when Houdini rejects it.
func task(task: HEGoTask) -> Variant:
	var completed := await HEGoNodeUtil.checked_task(owner_node, task)
	if not completed.ok:
		HEGoLog.get_singleton().error(LOG_CATEGORY, completed.message)
		return null
	return completed.value


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
##
## With [param strict], a failed transform or parameter restore also returns false, rather
## than carrying on with an asset that is not in the state the stash describes.
func instantiate(asset: HEGoAssetNode, stashed_parameters := PackedByteArray(), strict := false) -> bool:
	var existed := asset.get_id() != UNINSTANTIATED_NODE_ID
	if strict:
		var created := await HEGoNodeUtil.checked_task(owner_node, asset.instantiate())
		if not created.ok or asset.get_id() == UNINSTANTIATED_NODE_ID: return false
		if owner_node is Node3D:
			var placed := await HEGoNodeUtil.checked_task(owner_node, asset.set_transform(owner_node.global_transform))
			if not placed.ok: return false
		if not existed and stashed_parameters.size() > 0:
			var restored := await HEGoNodeUtil.checked_task(owner_node, asset.set_preset(stashed_parameters))
			if not restored.ok: return false
		return true

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
##
## [param cook] is the dictionary a host's [HEGoCookExtension]s share, and its
## [code]errors[/code] collects what went wrong. An input an [HEGoInputHandler] could not
## send always counts as an error. When [code]strict[/code] is true, so does any input that
## is missing, incompatible or fails to upload, rather than being skipped with a warning.
## Returns false when the input names could not be read or any error was recorded.
func sync_inputs(asset: HEGoAssetNode, skip_indices := [], cook: Dictionary = {}) -> bool:
	var names = await task(asset.get_input_names())
	if not names is PackedStringArray:
		return false
	var strict := bool(cook.get("strict", false))
	if not cook.get("errors") is Array:
		cook["errors"] = []
	var errors: Array = cook["errors"]

	var rows := _input_rows()
	if strict:
		for index in range(names.size(), rows.size()):
			if rows[index] is Dictionary:
				for path in rows[index].get("inputs", []):
					if not String(path).is_empty():
						errors.append("A configured input exceeds this HDA's %d inputs" % names.size())
						HEGoLog.get_singleton().error(LOG_CATEGORY, errors[-1])
						return false
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
			paths = Array(rows[index].get("inputs", []))
			settings = rows[index].get("settings", {})
		settings = settings.duplicate()
		settings["_cook"] = cook
		settings["_errors"] = errors
		settings["_strict"] = strict
		if strict:
			for path in paths:
				if String(path).is_empty(): continue
				var source := HEGoInputNodes._resolve_input_node(owner_node, path)
				if source == null or (not HEGoInputNodes.is_compatible_source(source) and not settings.get("include_children", false)):
					errors.append("Input %s is missing or is not a kind HEGo can send" % str(path))
					HEGoLog.get_singleton().error(LOG_CATEGORY, errors[-1])
					return false
		paths = HEGoInputNodes.resolve_paths(owner_node, paths, settings)

		if chains.has(index):
			if not await _update_chain(asset, chains, index, paths, settings): return false
		elif not paths.is_empty():
			if not await _create_chain(asset, chains, index, paths, settings): return false
	return errors.is_empty()


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


## Shows only [param labels] in the bottom panel, in that order.
##
## The default is every asset this node has made, in creation order. A tool with several
## stages usually wants to say which of them a user should see, and put the one they are
## working on first. Pass an empty array to go back to showing all of them.
func show_in_panel(labels: Array) -> void:
	panel_labels = labels.duplicate()


## Makes the panel open [param label]'s section and scroll to it on the next rebuild.
##
## A recook rebuilds the panel, so a tool that moves the user on to its next stage can point
## them at it rather than leaving them to find it. Pass an empty string to highlight nothing.
func highlight(label: String) -> void:
	highlighted_label = label


## The assets the bottom panel should show, in order, as the panel wants them.
##
## Return this straight from a node's [code]hego_get_panel_assets()[/code]. Entries are
## [code]{ "label", "asset", "highlight" }[/code]; a label in [member panel_labels] that names
## no asset is skipped.
func panel_assets() -> Array:
	var labels := panel_labels if not panel_labels.is_empty() else assets.keys()
	var entries := []
	for label in labels:
		if not assets.has(label):
			continue
		entries.append({
			"label": label,
			"asset": assets[label],
			"highlight": label == highlighted_label,
		})
	return entries


## Whether the loaded HEGo binary can delete nodes from the session, which
## [method release] needs. Binaries older than [method HEGoBaseNode.delete_node] cannot.
static func can_release() -> bool:
	return ClassDB.class_has_method(&"HEGoBaseNode", &"delete_node")


## Deletes every Houdini node this agent made - the HDAs, and the merge and input nodes
## behind their inputs - and forgets them. True when all of them are gone.
##
## Houdini keeps a node's cooked geometry, and HEGo a copy of its output, for as long as
## the node exists, so a host that cooks a large asset once and keeps the result as Godot
## nodes can let them go. The next cook creates everything again: the HDA from the
## owner's stashed parameters and the inputs by a full upload. The bottom panel shows no
## parameters for a released host until then.
##
## Returns false, and deletes nothing, when [method can_release] is false.
func release() -> bool:
	if not can_release():
		return false
	var ok := true
	for label in _input_nodes:
		var chains: Dictionary = _input_nodes[label]
		for index in chains:
			var chain: Dictionary = chains[index]
			for input in chain.get("inputs", []):
				if input is HEGoBaseNode:
					ok = await _delete(input) and ok
			if chain.get("merge") is HEGoBaseNode:
				ok = await _delete(chain["merge"]) and ok
	_input_nodes.clear()
	for label in assets:
		ok = await _delete(assets[label]) and ok
	assets.clear()
	highlighted_label = ""
	return ok


## Fetches what [param asset]'s cook produced and wraps it for the output handlers.
##
## Needed by anything in the output library: [method HEGoMeshOutput.fetch_meshes],
## [method HEGoMultiMeshOutput.setup_multimesh], and a handler's own
## [code]handle(context)[/code].
##
## [param cook] becomes the context's [member HEGoOutputContext.cook_state].
func output_context(asset: HEGoAssetNode, cook: Dictionary = {}) -> HEGoOutputContext:
	var summary = await task(asset.get_output_summary())
	var context := HEGoOutputContext.create(owner_node, asset, summary if summary is Dictionary else {})
	context.cook_state = cook
	return context


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


func _create_chain(asset: HEGoAssetNode, chains: Dictionary, index: int, paths: Array, settings: Dictionary) -> bool:
	var merge_node := HEGoMergeNode.new()
	if not await _chain_task(merge_node.instantiate(), settings): return false

	var input_array := []
	for path in paths:
		input_array.append(await HEGoInputNodes.sync(owner_node, null, path, settings))
	if settings.get("_strict", false) and (input_array.has(null) or not settings.get("_errors", []).is_empty()): return false

	if not await _chain_task(merge_node.connect_inputs(input_array), settings): return false
	if not await _chain_task(asset.connect_input(merge_node, index), settings): return false
	chains[index] = {"merge": merge_node, "inputs": input_array}
	return true


func _update_chain(asset: HEGoAssetNode, chains: Dictionary, index: int, paths: Array, settings: Dictionary) -> bool:
	var chain: Dictionary = chains[index]
	var merge_node: HEGoMergeNode = chain["merge"]
	if not await _chain_task(merge_node.instantiate(), settings): return false

	# Resizing first drops the input nodes whose source is gone and pads with nulls, and
	# sync() creates a node wherever it finds one.
	var input_array: Array = chain["inputs"].duplicate()
	input_array.resize(paths.size())
	for i in range(paths.size()):
		input_array[i] = await HEGoInputNodes.sync(owner_node, input_array[i], paths[i], settings)
	if settings.get("_strict", false) and (input_array.has(null) or not settings.get("_errors", []).is_empty()): return false

	if not await _chain_task(merge_node.connect_inputs(input_array), settings): return false
	if not await _chain_task(asset.connect_input(merge_node, index), settings): return false
	chain["inputs"] = input_array
	return true

func _delete(node: HEGoBaseNode) -> bool:
	if node.get_id() == UNINSTANTIATED_NODE_ID:
		return true
	var deleted := await HEGoNodeUtil.checked_task(owner_node, node.call(&"delete_node"))
	if not deleted.ok:
		HEGoLog.get_singleton().warning(LOG_CATEGORY, "Could not release a Houdini node: " + str(deleted.message))
	return deleted.ok


func _chain_task(native_task: HEGoTask, settings: Dictionary) -> bool:
	if settings.get("_strict", false):
		var result := await HEGoNodeUtil.checked_task(owner_node, native_task)
		if not result.ok:
			settings["_errors"].append(result.message)
		return result.ok
	await task(native_task)
	return true
