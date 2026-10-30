@tool
class_name HEGoInputHandler
extends RefCounted

## Teaches HEGo to send another kind of Godot node to an HDA input.
##
## HEGo itself handles paths, meshes, CSG shapes, graph inputs and Terrain3D. Another addon
## adds a kind by extending this class and giving it a [code]class_name[/code]: HEGo finds
## every global class that extends it, in the editor and in exported games alike, so
## installing that addon is all it takes. The dependency only runs one way. The extending
## addon names HEGo's classes; HEGo never names the addon's.
##
## Every method has a default that handles nothing, so a handler overrides only what it
## needs. Handlers are created once and reused, so keep per-input state in the input node
## [method sync] returns, not on the handler.


## Whether this handler turns [param node] into an input. Also decides whether the node
## counts as a compatible source when the panel or a cook resolves input paths.
func handles(_node: Node) -> bool:
	return false


## Creates or updates the HEGo input node for [param node].
##
## [param existing_node] is the input node this HDA input used last cook, possibly of
## another type; reuse it when it fits. [param settings] is the input's settings dictionary
## from the input stash. During a cook it also carries [code]_cook[/code], the dictionary
## the host's [HEGoCookExtension]s share, so a handler can pick up what an extension
## prepared for this cook.
##
## Returns [code]{ok: true, node}[/code], or [code]{ok: false, message}[/code] when the
## input could not be sent, which stops the cook with the previous output left in place.
func sync(_host: Node, _existing_node: Variant, _node: Node, _settings: Dictionary) -> Dictionary:
	return {"ok": false, "message": "This input handler does not implement sync()"}


## Whether stored [param settings] were written for this handler's kind of input, even if
## the source node is currently missing. Keeps the handler's options in the panel, and its
## explicit-cook rule in force, while a referenced node is renamed or deleted.
func claims_settings(_settings: Dictionary) -> bool:
	return false


## Whether an input of this kind should wait for an explicit recook rather than recooking
## automatically whenever the panel changes it.
func requires_explicit_cook(_settings: Dictionary) -> bool:
	return false


## An editor for this kind of input's settings, shown in the panel's input row, or null for
## none. HEGo creates one per input row.
##
## The control must provide [code]load_settings(settings: Dictionary)[/code],
## [code]get_settings() -> Dictionary[/code], which the panel merges into the input's
## stored settings, and [code]refresh(host: Node, nodes: Array)[/code], called with the
## row's current source nodes of this kind; and it must emit a [code]changed[/code] signal
## when the user edits it.
func create_settings_editor() -> Control:
	return null
