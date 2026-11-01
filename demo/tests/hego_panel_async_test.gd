## Delays native replies to reproduce obsolete UI rebuilds without a HAPI session.
extends SceneTree

var failures := 0

class Reply extends RefCounted:
	signal ready(value)

class DelayedTab extends "res://addons/hego/ui/hda_tab.gd":
	var replies: Array = []
	func _panel_assets() -> Array:
		return [{"asset": hego_tool_node.asset}] if is_instance_valid(hego_tool_node) else []
	func _await_task(_task: HEGoTask) -> Variant:
		var reply := Reply.new()
		replies.append(reply)
		return await reply.ready
	func add_parm_ui(data: Dictionary, parent: Control, _asset: HEGoAssetNode):
		var label := Label.new()
		label.text = data.marker
		parent.add_child(label)

class ToolNode extends Node:
	var asset := HEGoAssetNode.new()
	func hego_get_input_stash() -> Array: return []

func check(condition: bool, message: String) -> void:
	print("  %s %s" % ["ok" if condition else "FAIL", message])
	if not condition:
		failures += 1

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var panel = load("res://addons/hego/hego_control.tscn").instantiate()
	var tab = panel.get_node("TabContainer/HDA")
	tab.set_script(DelayedTab)
	root.add_child(panel)
	var a := ToolNode.new()
	var b := ToolNode.new()
	root.add_child(a)
	root.add_child(b)
	# All three rebuilds are waiting for parameters. Identity alone cannot reject
	# the first A's reply once A is selected again.
	tab.set_selected_node(a)
	tab.set_selected_node(b)
	tab.set_selected_node(a)
	check(tab.replies.size() == 3, "three parameter requests are pending")
	tab.replies[0].ready.emit({"p": {"marker": "stale A"}})
	tab.replies[1].ready.emit({"p": {"marker": "stale B"}})
	check(tab.parm_vbox.get_child_count() == 0 and tab.replies.size() == 3, "obsolete parameter replies neither add widgets nor request inputs")
	tab.replies[2].ready.emit({"p": {"marker": "current A"}})
	check(tab.parm_vbox.get_child(0).text == "current A", "latest parameter reply is displayed")
	check(tab.replies.size() == 4, "latest rebuild requests inputs")
	tab.set_selected_node(b)
	tab.replies[3].ready.emit(PackedStringArray(["stale input"]))
	check(tab.input_vbox.get_child_count() == 0, "old input reply cannot populate new selection")
	b.free()
	tab.replies[4].ready.emit({"p": {"marker": "deleted B"}})
	check(tab.hego_tool_node == null and tab.parm_vbox.get_child_count() == 0, "deleting the selected node invalidates pending replies")
	tab.set_selected_node(a)
	root.remove_child(panel)
	tab.replies[5].ready.emit({"p": {"marker": "detached panel"}})
	check(tab.parm_vbox.get_child_count() == 0, "detached panel rejects a pending reply")
	panel.free()
	a.free()
	print("panel async failures: ", failures)
	quit(1 if failures else 0)
