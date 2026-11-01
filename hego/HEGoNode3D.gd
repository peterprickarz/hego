@icon('res://addons/hego/assets/houdini.svg')
@tool
extends Node3D
class_name HEGoNode3D

## Brings a Houdini Digital Asset into a Godot scene.
##
## Pick an HDA with [b]Select HDA[/b], set its parameters in the HEGo bottom panel, and
## recook. Cooking instantiates the HDA in the running Houdini session, feeds it the nodes
## wired up as inputs, cooks it, and turns the result into Godot nodes under a child called
## [code]Outputs[/code].
##
## This node handles the great majority of cases. When you want one that does something it
## does not - its own attributes, its own output nodes, several HDAs chained together -
## write your own and use [HEGoAssetAgent], which is what this node uses. Read
## [method cook] below first: it is the worked example, and there is nothing in it a script
## of your own cannot do.

## Opens the HDA picker. The chosen operator is written to [member asset_name].
@export_tool_button('Select HDA', "FileDialog") var select_hda_btn = _show_select_hda_dialog
## The asset definition name in Houdini, e.g. Sop/my_tool
@export var asset_name: String
## The HDA's parameters as a blob, so they survive a session restart and a scene reload.
@export var parm_stash: PackedByteArray
## References to the Godot nodes wired into the HDA's inputs, one entry per input.
@export var input_stash: Array

## Emitted by [method hego_notify_cook_inputs_changed]: this node's inputs or parameters
## changed since its last cook, so anything built from that cook may be out of date. Lets
## another addon react at once without HEGo knowing about it; the HEGo Strata bridge, for
## example, marks the terrain layers this node published as stale.
signal cook_inputs_changed

# Whether the last cook ran to the end, for the bottom panel; see hego_did_last_cook_succeed().
var _last_cook_succeeded := false

## Category this file logs under, shown in the session panel filter.
const LOG_CATEGORY := "cook"

## The tedious parts of driving an HDA. Everything it does is an ordinary call on
## [HEGoAssetNode]; see [HEGoAssetAgent].
var agent := HEGoAssetAgent.new(self)


# ─────────────────────────────────────────────
# Cooking
# ─────────────────────────────────────────────

## Instantiates the HDA if needed, pushes inputs and parameters, cooks it and rebuilds the
## [code]Outputs[/code] subtree from the result.
##
## Children that extend [HEGoCookExtension] take part at each step; see
## [method cook_extensions]. Without any, this is the whole of a cook.
func cook() -> void:
	_last_cook_succeeded = false
	if asset_name.is_empty():
		return

	# The extensions and input handlers share one dictionary for the whole cook. An input
	# handler or an extension can make the cook strict, so that an input that cannot be sent
	# fails it instead of being skipped. It also records what the cook started from, so a
	# handler can tell whether the node changed while Houdini was cooking.
	var extensions := cook_extensions()
	var cook_state := {
		"strict": _input_rows_require(&"requires_strict_cook"),
		"errors": [],
		"input_stash": input_stash.duplicate(true),
		"transform": global_transform if is_inside_tree() else transform,
	}
	for extension in extensions:
		var prepared: Dictionary = await extension.cook_prepare(self, cook_state)
		if not prepared.get("ok", false):
			_cook_failed(extensions, cook_state, String(prepared.get("message", "A cook extension refused to start")), extension)
			return
	var strict: bool = cook_state.strict

	var timings := HEGoCookTimings.new()
	var asset := agent.asset(asset_name)

	timings.begin_phase()
	if not await agent.instantiate(asset, parm_stash, strict):
		_cook_failed(extensions, cook_state, "HDA instantiation failed")
		HEGoLog.get_singleton().info(LOG_CATEGORY, timings.format_summary())
		return
	timings.end_phase("instantiation")

	timings.begin_phase()
	if not await agent.sync_inputs(asset, [], cook_state):
		var errors: Array = cook_state.errors
		var reason := "Input synchronization failed"
		if not errors.is_empty():
			reason += ": " + "; ".join(PackedStringArray(errors))
		_cook_failed(extensions, cook_state, reason)
		return
	timings.end_phase("input_setup")

	timings.begin_phase()
	parm_stash = await agent.save_parameters(asset)
	cook_state.parm_stash = parm_stash
	timings.end_phase("parm_stash")
	for extension in extensions:
		var primed: Dictionary = await extension.cook_before(self, asset, cook_state)
		if not primed.get("ok", false):
			_cook_failed(extensions, cook_state, String(primed.get("message", "A cook extension stopped the cook")), extension)
			return

	timings.begin_phase()
	var cook_result = await agent.task(asset.cook())
	timings.end_phase("cook")
	# A cook Houdini rejects fails its task, so null covers both a cook that could not run
	# and one that ran and came back with fatal errors.
	if cook_result == null:
		_cook_failed(extensions, cook_state, "Houdini cook failed")
		HEGoLog.get_singleton().error(LOG_CATEGORY, "Cook failed, leaving the previous output in place")
		HEGoLog.get_singleton().info(LOG_CATEGORY, timings.format_summary())
		return

	# One look at what the cook produced, so a handler with nothing to do is skipped rather
	# than asking Houdini for attributes that are not there. An unreadable summary means they
	# all run, which costs time rather than output.
	timings.begin_phase()
	var context := await agent.output_context(asset, cook_state)
	timings.end_phase("output_summary")

	# Extensions publish first, so one that rejects the result leaves every previous output
	# in place, including the Outputs subtree below.
	for extension in extensions:
		var committed: Dictionary = await extension.cook_commit(context)
		if not committed.get("ok", false):
			_cook_failed(extensions, cook_state, String(committed.get("message", "A cook extension rejected the result")), extension)
			return

	# Cleared only now the cook has succeeded, so a failure leaves the last result visible.
	var outputs_node := get_node_or_null(HEGoNodeUtil.OUTPUTS_ROOT_NAME)
	if outputs_node:
		outputs_node.free()

	var skipped := PackedStringArray()
	for handler in output_handlers():
		if _skipped_by_extension(extensions, handler, cook_state):
			continue
		var phase: String = handler.output_phase()
		timings.begin_phase()
		if handler.should_handle(context.summary):
			await handler.handle(context)
		else:
			skipped.append(phase.trim_suffix("_output").replace("_", " "))
		timings.end_phase(phase)

	if not skipped.is_empty():
		HEGoLog.get_singleton().debug(LOG_CATEGORY, "Nothing to do for: " + ", ".join(skipped))
	HEGoLog.get_singleton().info(LOG_CATEGORY, timings.format_summary())
	_last_cook_succeeded = true


## The output handlers a cook runs, in the order it runs them: HEGo's mesh, multimesh and
## object output, then every [HEGoOutputHandler] other addons provide (see
## [method HEGoOutputHandler.extension_handlers]), then curve output.
##
## Each has [code]output_phase()[/code], [code]should_handle(summary)[/code] and
## [code]handle(context)[/code]: HEGo's own are scripts with those as static functions, the
## extension handlers are instances. Override this in a subclass to add one of your own, to
## drop one this node does not need, or to change the order.
##
## A function rather than a constant, because GDScript cannot build a constant out of other
## classes' references, and because the extension handlers are discovered at run time.
func output_handlers() -> Array:
	var handlers: Array = [
		HEGoMeshOutput,
		HEGoMultiMeshOutput,
		HEGoObjectOutput,
	]
	handlers.append_array(HEGoOutputHandler.extension_handlers())
	handlers.append(HEGoCurveOutput)
	return handlers


## The children that take part in this node's cooks, in child order: every direct child
## that extends [HEGoCookExtension].
##
## This is how another addon adds to what a cook does without HEGo knowing about it, for
## example by checking or publishing the cook's result before the [code]Outputs[/code]
## subtree is replaced.
func cook_extensions() -> Array[HEGoCookExtension]:
	var result: Array[HEGoCookExtension] = []
	for child in get_children():
		if child is HEGoCookExtension and not child.is_queued_for_deletion():
			result.append(child)
	return result


## Tells every extension except [param reporter], which recorded its own reason, that the
## cook stopped.
func _cook_failed(extensions: Array[HEGoCookExtension], cook_state: Dictionary, message: String, reporter: HEGoCookExtension = null) -> void:
	for extension in extensions:
		if extension != reporter and is_instance_valid(extension):
			extension.cook_failed(self, cook_state, message)


func _skipped_by_extension(extensions: Array[HEGoCookExtension], handler: Variant, cook_state: Dictionary) -> bool:
	for extension in extensions:
		if extension.skips_output_handler(handler, cook_state):
			return true
	return false


# ─────────────────────────────────────────────
# Bottom panel interface
#
# The HEGo bottom panel talks to whatever node is selected through these methods, so any
# script implementing them can be driven by it.
# ─────────────────────────────────────────────

## Tells the plugin this node can be edited from the HEGo bottom panel.
func hego_use_bottom_panel() -> bool:
	return true


## Whether the last cook ran to the end. The panel only reads parameters back after one
## that did, so a failed cook cannot overwrite the stash with a half-restored asset.
func hego_did_last_cook_succeed() -> bool:
	return _last_cook_succeeded


## Tells this node's cook extensions that its inputs or parameters changed, and emits
## [signal cook_inputs_changed]. The panel calls it on every edit, and
## [method hego_set_input_stash] calls it too.
func hego_notify_cook_inputs_changed() -> void:
	for extension in cook_extensions():
		extension.inputs_changed()
	cook_inputs_changed.emit()


## Whether recooking should wait for an explicit request rather than following every edit,
## because one of this node's cook extensions, or the input handler of one of its input rows
## (see [method HEGoInputHandler.requires_explicit_cook]), asks for that. The panel's auto
## recook is skipped while this is true.
func hego_requires_explicit_cook() -> bool:
	for extension in cook_extensions():
		if extension.requires_explicit_cook():
			return true
	return _input_rows_require(&"requires_explicit_cook")


# Whether the input handler of any input row answers true to [param rule], one of the
# HEGoInputHandler methods that take the row's settings.
func _input_rows_require(rule: StringName) -> bool:
	for row in input_stash:
		if not row is Dictionary:
			continue
		var settings: Variant = row.get("settings", {})
		for handler in HEGoInputNodes.row_handlers(self, row):
			if handler.call(rule, settings if settings is Dictionary else {}):
				return true
	return false


## The asset node the bottom panel reads parameters from, or null before the first cook.
func hego_get_asset_node() -> HEGoAssetNode:
	var existing: Array = agent.assets.values()
	return existing[0] if not existing.is_empty() else null


## The HDA this node cooks.
func hego_get_asset_name() -> String:
	return asset_name


## Stores a parameter preset so it survives session restarts and scene reloads.
func hego_set_parm_stash(preset: PackedByteArray) -> void:
	parm_stash = preset


## The stored input references.
func hego_get_input_stash() -> Array:
	return input_stash


## Stores the input references the bottom panel collected.
##
## Each HDA input can combine several Godot nodes, so [param input_array] holds one entry per
## HDA input, each with its own list of node paths and its settings.
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
	hego_notify_cook_inputs_changed()


## Lets the panel's asset picker change which HDA this node cooks.
##
## Implementing this is what tells the panel the picker applies at all; a node with an HDA
## written into its script leaves it out and gets no picker button.
func hego_set_asset_name(new_asset_name: String) -> void:
	_on_asset_selected(new_asset_name)


# ─────────────────────────────────────────────
# HDA selection
# ─────────────────────────────────────────────

func _show_select_hda_dialog() -> void:
	if not Engine.is_editor_hint():
		return

	# Looked up by name rather than referenced directly. EditorInterface exists only in an
	# editor build, so naming it here would fail this script's parse in an exported game and
	# take every method above down with it, leaving cooked scenes with a node that has lost
	# its script.
	var editor_interface := Engine.get_singleton("EditorInterface")
	if editor_interface == null:
		return

	var viewport := editor_interface.call("get_editor_viewport_3d") as Node
	if viewport == null:
		HEGoLog.get_singleton().error(LOG_CATEGORY, "No 3D editor viewport to show the HDA picker in")
		return

	var picker_scene := preload("res://addons/hego/ui/asset_picker_dialog.tscn")
	var picker := picker_scene.instantiate()

	# Parented to the viewport so the dialog lives as long as it is open.
	viewport.add_child(picker)
	picker.asset_selected.connect(_on_asset_selected)
	picker._populate_tree()
	picker.popup_centered()


func _on_asset_selected(selected_asset: String) -> void:
	_clear_hda_data()
	asset_name = selected_asset
	notify_property_list_changed()
	HEGoLog.get_singleton().info(LOG_CATEGORY, "Selected asset: " + selected_asset)


## Forgets everything tied to the previous HDA: the Houdini node, its parameters, its inputs
## and its output nodes.
func _clear_hda_data() -> void:
	for existing in agent.assets.values():
		existing.reset_node_id()
	agent.assets.clear()

	parm_stash = PackedByteArray()
	input_stash.clear()

	var outputs_node := get_node_or_null(HEGoNodeUtil.OUTPUTS_ROOT_NAME)
	if outputs_node:
		outputs_node.queue_free()

	HEGoLog.get_singleton().debug(LOG_CATEGORY, "Cleared old HDA data and reset node ID")
