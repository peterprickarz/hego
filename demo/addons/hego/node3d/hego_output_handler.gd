@tool
class_name HEGoOutputHandler
extends RefCounted

## Teaches HEGo to turn another kind of cook result into Godot nodes.
##
## HEGo itself builds meshes, multimeshes, spawned objects and curves. Another addon adds a
## kind by extending this class and giving it a [code]class_name[/code]: HEGo finds every
## global class that extends it, in the editor and in exported games alike, so installing
## that addon is all it takes. The dependency only runs one way. The extending addon names
## HEGo's classes; HEGo never names the addon's. The HEGo Terrain3D bridge, for example,
## builds Terrain3D terrains and instances this way.
##
## [method HEGoNode3D.output_handlers] runs these after HEGo's own mesh, multimesh and object
## output and before its curve output, sorted by class name. Every method has a default that
## handles nothing, so a handler overrides only what it needs. Handlers are created once and
## reused, so keep per-cook state in the [HEGoOutputContext] [method handle] is given, not on
## the handler.

## Class every extension output handler extends.
const HANDLER_BASE := &"HEGoOutputHandler"

# Script paths of the handlers found last time, in class name order, and one instance of each.
static var _handler_paths := PackedStringArray()
static var _handlers: Array[HEGoOutputHandler] = []


## Name of the cook phase this handler is timed under, shown in the cook timings. Ends in
## [code]_output[/code] by convention. Defaults to the class name in snake case.
func output_phase() -> String:
	var script := get_script() as Script
	var name := String(script.get_global_name()) if script != null else ""
	return name.to_snake_case() if not name.is_empty() else "extension_output"


## Whether the cook has anything for this handler, judged from [param summary], what
## [method HEGoAssetNode.get_output_summary] reported. Use [method HEGoNodeUtil.output_has]
## and [method HEGoNodeUtil.output_has_attribute], which run the handler whenever the summary
## could not be read: skipping is only for positive knowledge that there is nothing to do.
func should_handle(_summary: Dictionary) -> bool:
	return false


## Builds this handler's output for the cook in [param context]. May await. Runs after the
## host's [HEGoCookExtension]s have committed and the previous [code]Outputs[/code] subtree
## has been cleared.
func handle(_context: HEGoOutputContext) -> void:
	pass


## Whether this handler turns the cook's heightfield volumes into terrain. A
## [HEGoCookExtension] that consumes the heightfields itself skips such handlers through
## [method HEGoCookExtension.skips_output_handler] without having to name them.
func handles_heightfields() -> bool:
	return false


## The output handlers other addons provide: one instance of every global class that extends
## [HEGoOutputHandler], sorted by class name. Rescanned whenever the project's class list
## changes, so an addon installed in an open editor is picked up without a restart.
static func extension_handlers() -> Array[HEGoOutputHandler]:
	var classes := HEGoNodeUtil.global_subclasses(HANDLER_BASE)
	var names: Array = classes.keys()
	names.sort()
	var found := PackedStringArray()
	for name in names:
		found.append(classes[name])
	if found == _handler_paths:
		return _handlers
	_handler_paths = found
	_handlers.clear()
	for path in found:
		# A handler whose own dependencies are missing fails to load. That is reported once,
		# here, rather than on every cook.
		var script := load(path) as Script
		var handler: Variant = script.new() if script != null and script.can_instantiate() else null
		if handler is HEGoOutputHandler:
			_handlers.append(handler)
		else:
			HEGoLog.get_singleton().error(HEGoNodeUtil.LOG_CATEGORY, "Output handler %s could not be loaded; check that the addons it needs are installed." % path)
	return _handlers
