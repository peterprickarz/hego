## Covers what the bottom panel does with a selection.
##
## The panel used to gate everything on "node is HEGoNode3D", and update_ui() returned on
## that before building any parameter or input UI. Every has_method() guard in the file was
## therefore unreachable: a script could implement the whole documented interface, opt in,
## and still get an empty tab with every button disabled. It also never heard about
## deselection, so it kept driving the node from before.
##
## Both are what these checks exist to stop coming back. The panel is instantiated headlessly
## with stub nodes, so no Houdini session is needed.
extends SceneTree

var failures := 0


func check(condition: bool, what: String) -> void:
	if condition:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


## A node that is not a HEGoNode3D but implements the panel interface.
class StubNode extends Node3D:
	var asset_node: HEGoAssetNode = null
	var parm_stash: PackedByteArray
	var input_stash: Array
	var cooked := false

	func hego_use_bottom_panel() -> bool: return true
	func hego_get_asset_node() -> HEGoAssetNode: return asset_node
	func hego_get_asset_name() -> String: return "Sop/stub"
	func hego_get_input_stash() -> Array: return input_stash
	func hego_set_input_stash(rows: Array) -> void: input_stash = rows
	func hego_set_parm_stash(preset: PackedByteArray) -> void: parm_stash = preset
	func cook() -> void: cooked = true


## The same, but with a fixed HDA, so the picker should not apply to it.
class FixedHDANode extends StubNode:
	pass


## A node that lets the panel change its HDA.
class PickableNode extends StubNode:
	var chosen := ""
	func hego_set_asset_name(name: String) -> void: chosen = name


## A node that puts several HDAs in the panel and says which of them to show, in what order.
class MultiAssetNode extends Node3D:
	var hego := HEGoHelpers.new(self)
	var input_stash: Array

	func hego_use_bottom_panel() -> bool: return true
	func hego_get_panel_assets() -> Array: return hego.panel_assets()
	func hego_get_input_stash() -> Array: return input_stash
	func hego_set_input_stash(rows: Array) -> void: input_stash = rows


func _initialize() -> void:
	var panel = preload("res://addons/hego/hego_control.tscn").instantiate()
	root.add_child(panel)
	await process_frame
	var tab := panel.get_node("TabContainer/HDA")
	check(tab != null, "the HDA tab is reachable in the panel scene")

	# --- a node that is not a HEGoNode3D is driven ---------------------------
	var custom := StubNode.new()
	root.add_child(custom)
	await process_frame
	await tab.set_selected_node(custom)
	check(tab.hego_tool_node == custom, "a non-HEGoNode3D implementing the interface is accepted")
	check(not tab.recook_button.disabled, "its Recook button is enabled")

	# Its asset node is null until cooked, so the panel shows the hint rather than erroring.
	check(tab.parm_vbox.get_child_count() == 1, "an uninstantiated node shows one hint label")

	# --- Recook reaches the node --------------------------------------------
	await tab.recook()
	check(custom.cooked, "Recook calls cook() on a non-HEGoNode3D")

	# --- the picker only applies to a node that offers it --------------------
	check(not tab._can_pick_asset(), "a node with a fixed HDA does not offer the picker")
	check(not tab.asset_picker_button.visible, "so the picker button is hidden")

	var pickable := PickableNode.new()
	root.add_child(pickable)
	await process_frame
	await tab.set_selected_node(pickable)
	check(tab._can_pick_asset(), "a node implementing hego_set_asset_name offers the picker")
	check(tab.asset_picker_button.visible, "so the button is shown")
	await tab._on_asset_picked("Sop/chosen")
	check(pickable.chosen == "Sop/chosen", "picking an asset goes through the node, not around it")

	# --- deselection clears the panel ---------------------------------------
	await tab.set_selected_node(null)
	check(tab.hego_tool_node == null, "selecting nothing drops the node")
	check(tab.parm_vbox.get_child_count() == 0, "no parameter widget from the previous node survives")
	check(tab.input_vbox.get_child_count() == 0, "and no input row either")
	check(tab.recook_button.disabled, "Recook is disabled with nothing selected")

	# --- a cook already running is not started twice -------------------------
	var busy := StubNode.new()
	root.add_child(busy)
	await process_frame
	await tab.set_selected_node(busy)
	tab._cooking = true
	busy.cooked = false
	await tab.recook()
	check(not busy.cooked, "Recook is refused while a cook is already running")
	tab._cooking = false

	# --- several HDAs, ordered and highlighted by the node --------------------
	# The ordering itself is the helper's job, and it needs no session: an asset node exists
	# as an object long before Houdini has one.
	var multi := MultiAssetNode.new()
	root.add_child(multi)
	await process_frame
	multi.hego.asset("Sop/base", "base")
	multi.hego.asset("Sop/detail", "detail")

	var entries: Array = multi.hego.panel_assets()
	check(entries.size() == 2, "both HDAs are offered to the panel")
	check(entries[0]["label"] == "base", "in creation order by default")

	multi.hego.show_in_panel(["detail", "base"])
	entries = multi.hego.panel_assets()
	check(entries[0]["label"] == "detail", "and in the order the node asked for")

	multi.hego.show_in_panel(["detail", "nothing_by_that_name"])
	check(multi.hego.panel_assets().size() == 1, "a label naming no asset is skipped, not an error")

	multi.hego.show_in_panel([])
	multi.hego.highlight("detail")
	entries = multi.hego.panel_assets()
	check(entries.size() == 2, "an empty list goes back to showing all of them")
	check(entries[1]["highlight"], "the highlighted one is marked")
	check(not entries[0]["highlight"], "and only that one")

	# --- the panel waits for the HDAs to exist --------------------------------
	# Every asset above is still uninstantiated. Building parameter widgets for one would
	# queue work on a session that is not running, and the panel would wait on it forever.
	await tab.set_selected_node(multi)
	check(tab._panel_assets().is_empty(), "an HDA that Houdini does not have yet is not shown")
	check(tab.parm_vbox.get_child_count() == 1, "so the node gets the hint label")

	# The highlight is read off the node rather than off that list, so a script asking for one
	# before the first cook is not lost.
	tab._last_highlight = ""
	check(tab._requested_highlight() == "detail", "the highlight request is seen anyway")
	await tab._poll_highlight()
	check(tab._last_highlight == "detail", "and the panel picks it up on its own timer")

	# --- a node offering neither method is still safe -------------------------
	var plain := Node3D.new()
	root.add_child(plain)
	await process_frame
	await tab.set_selected_node(plain)
	check(tab._panel_assets().is_empty(), "a node with no assets lists none")
	check(tab._requested_highlight() == "", "and asks for no highlight")

	print("")
	print("failures: ", failures)
	quit(1 if failures > 0 else 0)
