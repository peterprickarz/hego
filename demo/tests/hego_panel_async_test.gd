## Delays native replies to reproduce obsolete UI rebuilds without a HAPI session.
extends SceneTree

var failures := 0

class Reply extends RefCounted:
	signal ready(value)

class DelayedTab extends "res://addons/hego/ui/hda_tab.gd":
	var replies: Array = []
	var help_requests: Array = []
	var help_replies: Array = []
	var opened_pages: Array = []
	var render_reply: Reply
	var open_result := OK
	func _panel_assets() -> Array:
		return [{"asset": hego_tool_node.asset}] + hego_tool_node.additional if is_instance_valid(hego_tool_node) else []
	func _await_task(_task: HEGoTask) -> Variant:
		var reply := Reply.new()
		replies.append(reply)
		return await reply.ready
	func _render_parameters(data: Dictionary, parent: Control, _asset: HEGoAssetNode) -> void:
		var label := Label.new()
		label.text = data.p.marker
		parent.add_child(label)
	func _load_asset_help(asset: HEGoAssetNode) -> Dictionary:
		help_requests.append(asset)
		var reply := Reply.new()
		help_replies.append(reply)
		return await reply.ready
	func _open_asset_help_page(page: Dictionary, can_open: Callable) -> Error:
		if render_reply != null:
			await render_reply.ready
		if not can_open.call():
			return ERR_SKIP
		opened_pages.append(page)
		return open_result

class ToolNode extends Node:
	var asset := HEGoAssetNode.new()
	var additional := []
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
	root.add_child(panel)
	check_help(tab, a)
	panel.free()
	a.free()
	print("panel async failures: ", failures)
	quit(1 if failures else 0)


func check_help(tab: DelayedTab, host: ToolNode) -> void:
	tab.set_selected_node(null)
	check(not tab.asset_help_button.visible, "an empty selection has no Help action")
	host.asset.op_name = "Sop/first"
	tab.set_selected_node(host)
	var single := tab.asset_help_button
	check(single.visible and single.tooltip_text.contains("Sop/first"), "single-asset Help identifies the displayed HDA")
	var first := {"text": "= First =", "url": "", "op_name": host.asset.op_name}
	single.pressed.emit()
	single.pressed.emit()
	check(tab.help_requests == [host.asset] and single.disabled, "one Help click queues one read for the displayed asset")
	tab.help_replies.back().ready.emit({"ok": true, "value": first})
	check(tab.opened_pages == [first] and not single.disabled, "the embedded page is handed to the browser opener")

	# Simulate switching hosts while a second Help request is still queued.
	single.pressed.emit()
	tab.set_selected_node(null)
	tab.help_replies.back().ready.emit({"ok": true, "value": first})
	check(tab.opened_pages == [first], "a late Help reply cannot open the prior selection")

	tab.set_selected_node(host)
	tab.render_reply = Reply.new()
	single.pressed.emit()
	tab.help_replies.back().ready.emit({"ok": true, "value": first})
	var request_count := tab.help_requests.size()
	single.pressed.emit()
	check(single.disabled and tab.help_requests.size() == request_count, "double clicking while rendering does not launch a duplicate")
	tab.set_selected_node(null)
	tab.set_selected_node(host)
	tab.render_reply.ready.emit(null)
	tab.render_reply = null
	check(tab.opened_pages == [first] and not single.disabled, "returning to the same asset while rendering still cancels the obsolete launch")
	tab.set_selected_node(null)

	var other := HEGoAssetNode.new()
	other.op_name = "Sop/second"
	host.additional.append({"asset": other, "label": "Second stage"})
	tab.set_selected_node(host)
	tab.replies.back().ready.emit({"p": {"marker": "First stage"}})
	var sections := tab.parm_vbox.get_children()
	check(sections.size() == 2 and not single.visible, "a multi-HDA host has a Help action per section")
	if sections.size() != 2: return
	sections[1]._header.button_pressed = false
	var second_button: Button = sections[1].help_button
	check(second_button.is_visible_in_tree() and second_button.tooltip_text.contains("Sop/second"), "the second stage can open its own help while folded")
	var second := {"text": "", "url": "https://example.org/second", "op_name": other.op_name}
	second_button.pressed.emit()
	tab.help_replies.back().ready.emit({"ok": true, "value": second})
	check(tab.help_requests.back() == other and tab.opened_pages == [first, second], "the second stage opens its own authored URL")
	tab.open_result = ERR_UNAVAILABLE
	second_button.pressed.emit()
	tab.help_replies.back().ready.emit({"ok": true, "value": {"text": "", "url": "", "op_name": other.op_name}})
	check(tab.help_notice.visible and tab.help_notice.dialog_text.contains("Sop/second has no help page"), "missing documentation gives feedback for the requested HDA")
	tab.help_notice.hide()
	second_button.pressed.emit()
	tab.help_replies.back().ready.emit({"ok": false, "message": "Session closed"})
	check(tab.help_notice.visible and tab.help_notice.dialog_text.contains("Session closed") and not second_button.disabled, "failed reads can be retried from the same Help action")
