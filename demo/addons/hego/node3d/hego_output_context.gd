@tool
class_name HEGoOutputContext
extends RefCounted

## Everything one output handler is given to work with.
##
## Handlers used to take the host node and reach into it for a member literally named
## [code]hego_asset_node[/code]. That coupled every handler to a naming convention: a node
## wanting to reuse one had to declare a member by that name whether or not the name suited
## it, and nothing said so anywhere except the handler's own source. They take this instead,
## which names what they actually need.

## The node this cook belongs to.
##
## Output normally goes under [method outputs_root] rather than directly here. A handler
## that must parent somewhere else needs the host itself, which is why it is exposed:
## [HEGoTerrain3DOutput] deliberately builds outside the subtree a cook rebuilds, so the
## terrain it spawns survives recooking.
var host: Node

## The Houdini node whose cook this is.
var asset: HEGoAssetNode

## What the cook produced, as [method HEGoAssetNode.get_output_summary] reported it.
##
## This is the same dictionary the handler's [code]should_handle()[/code] was asked about,
## so a handler no longer has to work out again what it was selected for.
var summary: Dictionary


## Builds a context for [param host_node]'s cook of [param asset_node].
static func create(host_node: Node, asset_node: HEGoAssetNode, cook_summary: Dictionary) -> HEGoOutputContext:
	var ctx := HEGoOutputContext.new()
	ctx.host = host_node
	ctx.asset = asset_node
	ctx.summary = cook_summary
	return ctx


## Waits for [param task] and returns its result, or [code]null[/code] if it failed.
func await_task(task: HEGoTask) -> Variant:
	return await HEGoNodeUtil.await_task(host, task)


## The node this cook's output is built under, created if it does not exist yet.
func outputs_root() -> Node3D:
	return HEGoNodeUtil.ensure_outputs_root(host)


## Creates the intermediate nodes of [param path_parts] under [param root] and returns the
## node the leaf should be added to. The leaf itself is left to the caller.
func ensure_parent(root: Node, path_parts: PackedStringArray) -> Node:
	return HEGoNodeUtil.ensure_parent_path(host, root, path_parts)


## Makes [param node] part of the saved scene while running in the editor. A spawned node
## whose owner is left unset silently disappears when the scene is saved, so every node a
## cook creates goes through here.
func own(node: Node) -> void:
	HEGoNodeUtil.set_editor_owner(host, node)


## Creates the node that [param node_path] names under this cook's output root, and returns
## it ready to use, named, parented and owned.
##
## [param node_path] may contain slashes; everything before the last part becomes plain
## [Node3D]s. [param default_name] is used when the path names nothing. [param factory] is
## only called when a node actually has to be created.
##
## An existing node at that location is reused when it is already the right class and
## replaced when it is not, so a handler that runs twice does not orphan what it built the
## first time. Pass [param unique] to suffix the name instead of reusing, which is what
## spawning one node per point needs.
##
## [param configure] runs on a newly created node after it is named and before it enters
## the tree. Anything that has to be set before the node's [code]_ready()[/code] sees it
## belongs there rather than on the returned node: a spawned scene reading a property the
## HDA meant to override would otherwise read the default.
func place(node_path: String, default_name: String, factory: Callable, unique := false, configure := Callable()) -> Node:
	var path_parts := node_path.split("/", false)
	var parent := ensure_parent(outputs_root(), path_parts)
	var base_name := path_parts[path_parts.size() - 1] if path_parts.size() > 0 else default_name

	if unique:
		var spawned: Node = factory.call()
		spawned.name = HEGoNodeUtil.unique_child_name(parent, base_name)
		if configure.is_valid():
			configure.call(spawned)
		parent.add_child(spawned)
		own(spawned)
		return spawned

	var created: Node = factory.call()
	var existing := parent.get_node_or_null(base_name)
	if existing != null:
		if existing.get_class() == created.get_class():
			created.free()
			return existing
		# Detached before being freed, so the name is free again this frame. queue_free()
		# alone defers the removal and Godot would rename the replacement to avoid a clash.
		parent.remove_child(existing)
		existing.queue_free()

	created.name = base_name
	if configure.is_valid():
		configure.call(created)
	parent.add_child(created)
	own(created)
	return created


## Fetches this cook's points, loads [param attribs], and returns the ones whose
## [param filter_attrib] is 1.
##
## Returns [code]null[/code] when the fetch failed, the output is unusable, or nothing
## matched, so a handler can bail on one check rather than the four this replaces.
## [param filter_attrib] is loaded whether or not [param attribs] names it.
func select_points(filter_attrib: String, attribs: PackedStringArray) -> HEGoGeoSelection:
	var output: HEGoGeoOutput = await await_task(asset.get_geo_output())
	if output == null or not output.is_valid():
		return null

	var wanted := attribs.duplicate()
	if not wanted.has(filter_attrib):
		wanted.append(filter_attrib)
	await await_task(output.load_attributes(wanted))

	var selection := output.filter_by(filter_attrib, 1)
	if selection == null or selection.size() == 0:
		return null
	return selection
