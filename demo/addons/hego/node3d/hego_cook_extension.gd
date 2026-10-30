@tool
class_name HEGoCookExtension
extends Node

## A child of an [HEGoNode3D] that takes part in its cooks.
##
## A cook normally ends by rebuilding the [code]Outputs[/code] subtree. An extension makes
## it do more, or do it differently: the HEGo Strata bridge, for example, publishes the cook's
## heightfields into terrain layers. Add one as a direct child of the HEGo node. HEGo calls
## the hooks below on every such child, in child order, and never needs to know which addon
## it came from.
##
## Every hook has a default that does nothing, so an extension overrides only what it needs.
## Hooks that return a Dictionary report [code]{ok, message}[/code]. Returning
## [code]ok: false[/code] stops the cook and leaves the previous output in place. The
## extension that stops a cook records its own reason; the others are told through
## [method cook_failed].
##
## [param cook] is one dictionary shared by every extension and input handler for the
## duration of one cook. HEGo reads [code]strict[/code] from it and collects input failures
## in [code]errors[/code]. Keep anything of your own under your own key.


## The cook is about to start, before anything is sent to Houdini. Set
## [code]cook.strict = true[/code] to make any input that cannot be sent fail the whole cook,
## rather than being skipped with a warning.
func cook_prepare(_host: Node, _cook: Dictionary) -> Dictionary:
	return {"ok": true}


## Inputs and parameters are in place and the HDA is about to cook.
func cook_before(_host: Node, _asset: HEGoAssetNode, _cook: Dictionary) -> Dictionary:
	return {"ok": true}


## The HDA cooked and nothing has been replaced yet. [code]context.cook_state[/code] is the
## shared cook dictionary. Return [code]ok: false[/code] to keep the previous output.
func cook_commit(_context: HEGoOutputContext) -> Dictionary:
	return {"ok": true}


## The cook stopped before finishing, at any step, with [param message] saying why.
func cook_failed(_host: Node, _cook: Dictionary, _message: String) -> void:
	pass


## Whether this cook should skip the standard output handler [param handler], for example
## because the extension produces that kind of output itself.
func skips_output_handler(_handler: Variant, _cook: Dictionary) -> bool:
	return false


## The host's inputs or parameters changed since the last cook.
func inputs_changed() -> void:
	pass


## Whether the host should only cook when asked, rather than recooking automatically on
## every change the panel makes.
func requires_explicit_cook() -> bool:
	return false
