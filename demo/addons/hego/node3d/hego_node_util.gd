@tool
class_name HEGoNodeUtil
extends RefCounted

## Shared plumbing for [HEGoNode3D] and its output handlers.
##
## Every handler needs the same three things: a way to wait for a [HEGoTask],
## a way to build the [code]Outputs/...[/code] node hierarchy a cook writes into,
## and a way to read the attribute dictionaries HAPI hands back. They live here so
## the handlers only contain the logic that is actually specific to their output type.

## Category the cook path logs under, shown in the session panel filter.
const LOG_CATEGORY := "cook"

## Name of the node all cook output is parented under.
const OUTPUTS_ROOT_NAME := "Outputs"


## Waits for [param task] to finish and returns its result, or [code]null[/code]
## if it failed. [param host] is only needed for its scene tree, to yield a frame.
static func await_task(host: Node, task: HEGoTask) -> Variant:
	if task == null:
		HEGoLog.get_singleton().error(LOG_CATEGORY, "Task was null, the session is probably not running.")
		return null
	while task.get_status() < HEGoTask.COMPLETED:
		await host.get_tree().process_frame
	if task.get_status() == HEGoTask.FAILED:
		HEGoLog.get_singleton().error(LOG_CATEGORY, "Task failed: " + task.get_error_message())
		return null
	return task.get_result()


## Whether the cook produced the kind of geometry a handler needs.
##
## [param summary] is [method HEGoAssetNode.get_output_summary]'s result and
## [param key] one of its has_* flags. An unknown summary or a missing key means
## the handler runs: skipping is only ever done on positive knowledge that there is
## nothing to do, so a failed summary costs time rather than output.
static func output_has(summary: Dictionary, key: String) -> bool:
	if summary.is_empty() or not summary.has(key):
		return true
	return bool(summary[key])


## Whether the cooked geometry carries an attribute a handler keys off, for example
## hego_spawn. Follows the same "unknown means run it" rule as [method output_has].
static func output_has_attribute(summary: Dictionary, list_key: String, attribute: String) -> bool:
	if summary.is_empty() or not summary.has(list_key):
		return true
	var names: PackedStringArray = summary[list_key]
	return names.has(attribute)


## Makes [param node] show up in the saved scene while running in the editor.
##
## Nodes created at runtime need no owner, and a node whose owner is left unset in
## the editor silently disappears on save, so every node a cook spawns goes through here.
static func set_editor_owner(host: Node, node: Node) -> void:
	if not Engine.is_editor_hint():
		return
	var tree := host.get_tree()
	if tree == null:
		return
	node.owner = tree.edited_scene_root if tree.edited_scene_root else host


## Returns the [code]Outputs[/code] node under [param host], creating it if needed.
static func ensure_outputs_root(host: Node) -> Node3D:
	var outputs_node := host.get_node_or_null(OUTPUTS_ROOT_NAME) as Node3D
	if outputs_node == null:
		outputs_node = Node3D.new()
		outputs_node.name = OUTPUTS_ROOT_NAME
		host.add_child(outputs_node)
		set_editor_owner(host, outputs_node)
	return outputs_node


## Walks [param path_parts] under [param root], creating plain [Node3D]s for every
## part except the last one, and returns the node the leaf should be added to.
##
## The leaf itself is left to the caller, because each output type creates a
## different node for it (MeshInstance3D, Path3D, MultiMeshInstance3D, ...).
static func ensure_parent_path(host: Node, root: Node, path_parts: PackedStringArray) -> Node:
	var current_node := root
	for i in range(path_parts.size() - 1):
		var part := path_parts[i]
		if part.is_empty():
			continue
		var next_node := current_node.get_node_or_null(part)
		if next_node == null:
			var new_node := Node3D.new()
			new_node.name = part
			current_node.add_child(new_node)
			set_editor_owner(host, new_node)
			next_node = new_node
		current_node = next_node
	return current_node


## Returns a name based on [param base_name] that is not taken under [param parent] yet,
## by appending [code]_001[/code], [code]_002[/code], ... to it.
static func unique_child_name(parent: Node, base_name: String) -> String:
	var candidate := base_name
	var suffix := 0
	while parent.get_node_or_null(candidate) != null:
		suffix += 1
		candidate = base_name + "_" + str(suffix).pad_zeros(3)
	return candidate


## Reads a named attribute out of one of HAPI's attribute lists.
##
## The fetch results store attributes as [code]{ "name": ..., "value": ... }[/code]
## dictionaries under a key such as [code]prim_attribs[/code] or [code]attrs[/code].
## Returns [code]null[/code] when the list or the attribute is missing.
static func get_attrib_value(dict: Dictionary, dict_key: String, attr_name: String) -> Variant:
	if not dict.has(dict_key) or not dict[dict_key] is Array:
		return null
	for attr_pair in dict[dict_key]:
		if attr_pair is Dictionary and attr_pair.get("name", "") == attr_name:
			return attr_pair.get("value", null)
	return null


## Reads element [param index] of the array stored under [param key], falling back to
## [param fallback] when the attribute is missing, too short or holds a null.
##
## Point fetches return one array per attribute, and an HDA is free to leave any of
## them out, so every read of a per-point attribute has to be defensive.
static func get_point_attrib(point_dict: Dictionary, key: String, index: int, fallback: Variant) -> Variant:
	if not point_dict.has(key) or not point_dict[key] is Array:
		return fallback
	var values: Array = point_dict[key]
	if index < 0 or index >= values.size() or values[index] == null:
		return fallback
	return values[index]


## Same as [method get_point_attrib], but only accepts values of [param expected_type]
## (a [enum Variant.Type] value) and falls back otherwise.
static func get_typed_point_attrib(point_dict: Dictionary, key: String, index: int, expected_type: int, fallback: Variant) -> Variant:
	var value: Variant = get_point_attrib(point_dict, key, index, fallback)
	if typeof(value) != expected_type:
		return fallback
	return value
