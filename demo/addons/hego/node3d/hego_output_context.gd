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
