@tool
class_name HEGoCookExtension
extends Node

## A child of an [HEGoNode3D] that takes part in its cooks.
##
## A cook normally ends by rebuilding the [code]Outputs[/code] subtree. An extension makes
## it do more, or do it differently: it can refuse to start a cook, prepare state for the
## input handlers, or check the result and keep the previous output when it is not right.
## Add one as a direct child of the HEGo node. HEGo calls the hooks below on every such
## child, in child order, and never needs to know which addon it came from. To turn a kind
## of cook result into something, write an [HEGoOutputHandler] instead; it needs no child.
##
## Every hook has a default that does nothing, so an extension overrides only what it needs.
## Hooks that return a Dictionary report [code]{ok, message}[/code]. Returning
## [code]ok: false[/code] stops the cook and leaves the previous output in place. The
## extension that stops a cook records its own reason; the others are told through
## [method cook_failed].
##
## [param cook] is one dictionary shared by every extension, input handler and output
## handler for the duration of one cook. HEGo reads [code]strict[/code] from it and collects
## input failures in [code]errors[/code]. It also records what the cook started from:
## [code]input_stash[/code] (a copy), [code]transform[/code] and, once the parameters are in
## place, [code]parm_stash[/code], the preset the HDA cooks with. Keep anything of your own
## under your own key.


## The cook is about to start, before anything is sent to Houdini. Set
## [code]cook.strict = true[/code] to make any input that cannot be sent fail the whole cook,
## rather than being skipped with a warning. It is already true when an input handler asks
## for it; see [method HEGoInputHandler.requires_strict_cook].
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


## Whether this cook should skip the output handler [param handler], one entry of
## [method HEGoNode3D.output_handlers], for example because the extension produces that kind
## of output itself. [param handler] is either one of HEGo's own handler scripts or an
## [HEGoOutputHandler] instance. Output handlers already ignore the parts of a result that
## do not carry their own attributes, so this is only for an extension that wants a handler
## not to run at all.
func skips_output_handler(_handler: Variant, _cook: Dictionary) -> bool:
	return false


## The host's inputs or parameters changed since the last cook.
func inputs_changed() -> void:
	pass


## Whether the host should only cook when asked, rather than recooking automatically on
## every change the panel makes.
func requires_explicit_cook() -> bool:
	return false
