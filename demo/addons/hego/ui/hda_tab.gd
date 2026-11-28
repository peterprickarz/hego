@tool
extends Control

const ParameterEditor := preload("res://addons/hego/ui/parameter_editor.gd")
const ParameterLinks := preload("res://addons/hego/core/parameter_links.gd")
const HelpPage := preload("res://addons/hego/ui/asset_help.gd")

var _editor := ParameterEditor.new()
var _containers := {}
var _parameter_data := {}
var _edit_revisions := {}
var _changing_layout := {}
var _rendering_parameters := false

var hego_tool_node: Node
## Latest eligible scene selection, including changes made while the panel is locked.
var _scene_selection: Node
## The HDA the preset controls act on: the first one the node puts in the panel. A node
## showing several still has one set of preset buttons, and they belong to the first.
var hego_asset_node: HEGoAssetNode
var input_nodes: Array
var input_visibility_undo_redo: EditorUndoRedoManager
var _rebuild_generation := 0
## Whether a cook started from this panel is still running. Recook is disabled meanwhile, so
## a second cook cannot be fired into a node that is already cooking.
var _cooking: bool = false
var _pending_input_recook: Node
## Which asset sections the user has open, keyed by label. Kept here rather than on the node
## because it is the user's choice about this panel, not part of what the node cooks.
var _open_sections: Dictionary = {}
var new_preset_name_diag: ConfirmationDialog
var new_preset_name_line_edit: LineEdit

@onready var lock_button: CheckButton = %LockPanelButton
@onready var asset_help_button: Button = %AssetHelpButton
@onready var help_notice: AcceptDialog = %HelpNotice
@onready var auto_recook_toggle: CheckButton = $HSplitContainer2/Settings/PanelContainer/VBoxContainer/VBoxContainer/CheckButton
@onready var auto_start_session_toggle: CheckButton = $HSplitContainer2/Settings/PanelContainer/VBoxContainer/HBoxContainer2/CheckButton
@onready var asset_picker_button: Button = $HSplitContainer2/Settings/PanelContainer/VBoxContainer/AssetPickerButton
@onready var recook_button: Button = %ButtonRecook
@onready var rebuild_button: Button = %ButtonRebuild
@onready var load_preset_button: Button = $HSplitContainer2/Settings/PanelContainer/VBoxContainer/MarginContainer/PanelContainer/VBoxContainer/HBoxContainer3/LoadPresetButton
@onready var save_preset_button: Button = $HSplitContainer2/Settings/PanelContainer/VBoxContainer/MarginContainer/PanelContainer/VBoxContainer/HBoxContainer3/SavePresetButton
@onready var new_preset_button: Button = $HSplitContainer2/Settings/PanelContainer/VBoxContainer/MarginContainer/PanelContainer/VBoxContainer/HBoxContainer3/NewPresetButton
@onready var preset_dropdown: OptionButton = $HSplitContainer2/Settings/PanelContainer/VBoxContainer/MarginContainer/PanelContainer/VBoxContainer/HBoxContainer/PresetDropdownOptionButton
@onready var parm_vbox = $HSplitContainer2/HSplitContainer3/Parameters/PanelContainer/VBoxContainer/Control/ScrollContainer/VBoxContainer
@onready var input_vbox = $HSplitContainer2/HSplitContainer3/HSplitContainer4/Inputs/PanelContainer/VBoxContainer/ScrollContainer/VBoxContainer
@onready var queued_tasks_vbox = $HSplitContainer2/HSplitContainer3/HSplitContainer4/TaskQueue/PanelContainer/VBoxContainer/QueuedScroll/VBoxContainer
@onready var finished_tasks_vbox = $HSplitContainer2/HSplitContainer3/HSplitContainer4/TaskQueue/PanelContainer/VBoxContainer/FinishedScroll/VBoxContainer
@onready var root_control = $"../.."

var _last_pending_count: int = 0
var _last_current_status: int = -1
var _last_history_size: int = 0
## The section the selected node last asked to have highlighted. Watched so that a script
## calling highlight() partway through a cook moves the panel to that HDA on its own.
var _last_highlight: String = ""


func _await_task(task: HEGoTask) -> Variant:
	return await HEGoNodeUtil.await_task(self, task)


func _elapsed_msec(start_usec: int) -> float:
	return float(Time.get_ticks_usec() - start_usec) / 1000.0


func _print_bottom_panel_timing(trigger: String, session_start_msec: float, recook_msec: float, ui_rebuild_msec: float, total_msec: float):
	var lines = PackedStringArray()
	lines.append("[HEGoBottomPanel]: Timing summary (%s)" % trigger)
	lines.append("[HEGoBottomPanel]:   Session start: %.3f ms" % session_start_msec)
	lines.append("[HEGoBottomPanel]:   Asset operation: %.3f ms" % recook_msec)
	lines.append("[HEGoBottomPanel]:   UI rebuild: %.3f ms" % ui_rebuild_msec)
	lines.append("[HEGoBottomPanel]:   Total bottom-panel flow: %.3f ms" % total_msec)
	print("\n".join(lines))

func _ready():
	_editor.value_requested.connect(_on_value_changed)
	_editor.instance_requested.connect(_on_instance_requested)
	_editor.instance_count_requested.connect(_on_instance_count_requested)
	_editor.node_requested.connect(_on_node_requested)
	_editor.node_candidates = _node_candidates
	new_preset_name_diag = preload("res://addons/hego/ui/new_preset_name_diag.tscn").instantiate()
	new_preset_name_line_edit = new_preset_name_diag.get_node("%LineEdit")
	add_child(new_preset_name_diag)
	recook_button.pressed.connect(_on_recook_button_pressed)
	rebuild_button.pressed.connect(_on_recook_button_pressed.bind(true))
	asset_picker_button.pressed.connect(_on_asset_picker_button_pressed)
	asset_help_button.pressed.connect(func(): _on_asset_help_pressed(hego_asset_node, asset_help_button))
	lock_button.toggled.connect(_on_lock_toggled)
	root_control.selected_hego_node_changed.connect(set_selected_node)
	new_preset_button.pressed.connect(_on_new_preset_button_pressed)
	new_preset_name_diag.confirmed.connect(_on_preset_dialog_confirmed)
	load_preset_button.pressed.connect(_on_load_preset_button_pressed)
	save_preset_button.pressed.connect(_on_save_preset_button_pressed)
	_set_buttons_disabled(true)

	var task_queue_timer = Timer.new()
	task_queue_timer.wait_time = 0.25
	task_queue_timer.autostart = true
	task_queue_timer.timeout.connect(_update_task_queue)
	task_queue_timer.timeout.connect(_poll_highlight)
	add_child(task_queue_timer)


## Drops every parameter and input widget on screen.
##
## Detached before being freed: queue_free() defers the removal, so the old widgets would
## otherwise stay in the tree for a frame, still able to take input and still wired to the
## node that is no longer selected.
func _clear_widgets():
	asset_help_button.hide()
	help_notice.hide()
	_containers.clear()
	_parameter_data.clear()
	_rendering_parameters = true
	for child in parm_vbox.get_children():
		parm_vbox.remove_child(child)
		child.queue_free()
	for child in input_vbox.get_children():
		input_vbox.remove_child(child)
		child.queue_free()
	input_nodes = []
	_rendering_parameters = false


func _set_buttons_disabled(disabled: bool):
	recook_button.disabled = disabled
	rebuild_button.disabled = disabled or not is_instance_valid(hego_tool_node) or not hego_tool_node.has_method("hego_rebuild")
	asset_picker_button.disabled = disabled
	load_preset_button.disabled = disabled
	save_preset_button.disabled = disabled
	new_preset_button.disabled = disabled


func _on_new_preset_button_pressed():
	new_preset_name_diag.dialog_text = "Please enter a name for the preset:"
	new_preset_name_line_edit.text = ""
	new_preset_name_line_edit.placeholder_text = "Preset Name"
	new_preset_name_diag.popup_centered()
	new_preset_name_line_edit.grab_focus()


func _on_preset_dialog_confirmed():
	var preset_name = new_preset_name_line_edit.text.strip_edges()
	if preset_name != "":
		create_preset_file(preset_name)
	else:
		print("No preset name entered")


## The HDAs to show, in the order the node asked for, as
## [code]{ "label", "asset", "highlight" }[/code] entries.
##
## A node that cooks several HDAs implements [code]hego_get_panel_assets()[/code] and decides
## which of them belong in the panel, in what order, and which one the panel should open and
## scroll to. A node with one HDA implements only [code]hego_get_asset_node()[/code] and is
## answered here, so it never has to know any of that exists.
func _panel_assets() -> Array:
	if not is_instance_valid(hego_tool_node):
		return []

	return ParameterLinks.panel_assets(hego_tool_node).filter(func(entry): return _is_instantiated(entry.get("asset")))


## Whether [param asset] is an HDA that exists in Houdini.
##
## The id rather than the object, because a node that keeps its assets around creates them
## before it cooks them. Asking one that does not exist yet for its parameters queues work
## that nothing will ever run, and the panel would wait on it forever.
func _is_instantiated(asset) -> bool:
	return asset is HEGoAssetNode and asset.get_id() >= 0


## The label the selected node is asking to have highlighted, or empty for none.
##
## Read straight off the node rather than from [method _panel_assets], so the request is
## still seen before the HDAs behind it have been cooked into existence.
func _requested_highlight() -> String:
	if not is_instance_valid(hego_tool_node) or not hego_tool_node.has_method("hego_get_panel_assets"):
		return ""

	var entries = hego_tool_node.hego_get_panel_assets()
	if not entries is Array:
		return ""
	for entry in entries:
		if entry is Dictionary and entry.get("highlight", false):
			return str(entry.get("label", ""))
	return ""


func _exit_tree() -> void:
	_rebuild_generation += 1


func _is_rebuild_current(generation: int, selected_node) -> bool:
	return generation == _rebuild_generation and is_inside_tree() and not is_queued_for_deletion() \
		and is_instance_valid(selected_node) and not selected_node.is_queued_for_deletion() \
		and selected_node.is_inside_tree() and selected_node == hego_tool_node


func update_ui():
	_rebuild_generation += 1
	var generation := _rebuild_generation
	var selected_node := hego_tool_node
	_clear_widgets()

	if not is_instance_valid(hego_tool_node):
		preset_dropdown.clear()
		preset_dropdown.add_item("No HEGo node selected")
		preset_dropdown.set_item_disabled(0, true)
		_set_buttons_disabled(true)
		return

	_set_buttons_disabled(_cooking)
	asset_picker_button.visible = _can_pick_asset()

	var entries := _panel_assets()
	hego_asset_node = entries[0]["asset"] if not entries.is_empty() else null

	if entries.is_empty():
		var hint_label = Label.new()
		hint_label.text = "HDA not instantiated. Recook to see parameters!"
		parm_vbox.add_child(hint_label)
		update_preset_dropdown()
		return

	var use_sections := entries.size() > 1
	if not use_sections:
		asset_help_button.tooltip_text = "Open help for %s" % hego_asset_node.op_name
		asset_help_button.disabled = false
		asset_help_button.show()
	var highlighted_section: Control = null
	# Recorded so the highlight poll does not read this rebuild as a fresh request and run
	# straight into another one.
	_last_highlight = ""

	for entry in entries:
		var asset: HEGoAssetNode = entry["asset"]
		var asset_label := str(entry.get("label", ""))
		var container: Control = parm_vbox

		if use_sections:
			var section := HEGoAssetSection.new()
			parm_vbox.add_child(section)
			section.setup(asset_label, asset.op_name, _open_sections.get(asset_label, true))
			section.open_changed.connect(_on_section_open_changed)
			section.help_button.tooltip_text = "Open help for %s" % asset.op_name
			section.help_button.pressed.connect(_on_asset_help_pressed.bind(asset, section.help_button))
			container = section.get_container()
			if entry.get("highlight", false):
				section.open()
				section.mark_highlighted()
				highlighted_section = section
				_last_highlight = asset_label

		var parm_dict = await _await_task(asset.get_parms_dict())
		if not _is_rebuild_current(generation, selected_node):
			return
		_containers[asset.get_instance_id()] = container
		if parm_dict is Dictionary:
			_render_parameters(parm_dict, container, asset)

	# Input rows belong to the node rather than to one HDA - there is a single input stash -
	# so they are shown against the first HDA the node listed. A node chaining several takes
	# its inputs on that one and wires the rest together itself.
	await _build_input_rows(entries[0]["asset"], selected_node, generation)
	if not _is_rebuild_current(generation, selected_node):
		return

	if highlighted_section != null:
		# One frame, so the sections built above have a real size to scroll to.
		await get_tree().process_frame
		if not _is_rebuild_current(generation, selected_node):
			return
		if is_instance_valid(highlighted_section):
			(parm_vbox.get_parent() as ScrollContainer).ensure_control_visible(highlighted_section)

	update_preset_dropdown()


func _load_asset_help(asset: HEGoAssetNode) -> Dictionary:
	return await HEGoNodeUtil.checked_task(self, asset.get_help_page())


func _open_asset_help_page(page: Dictionary, can_open: Callable) -> Error:
	return await HelpPage.open_page(page, can_open)


func _on_asset_help_pressed(asset: HEGoAssetNode, button: Button) -> void:
	if not asset or not button.visible or button.disabled:
		return
	var generation := _rebuild_generation
	var selected_node := hego_tool_node
	button.disabled = true
	var reply := await _load_asset_help(asset)
	if not _is_rebuild_current(generation, selected_node):
		return
	var message := ""
	if not reply.ok:
		message = "Could not read help for %s. %s" % [asset.op_name, reply.message]
	else:
		# Embedded pages render asynchronously. Check ownership at launch time too.
		var can_open := _is_rebuild_current.bind(generation, selected_node)
		var error := await _open_asset_help_page(reply.value, can_open)
		if not _is_rebuild_current(generation, selected_node):
			return
		if error == ERR_UNAVAILABLE:
			message = "%s has no help page." % asset.op_name
		elif error != OK and error != ERR_SKIP:
			message = "Could not open help for %s. %s" % [asset.op_name, error_string(error)]
	button.disabled = false
	if not message.is_empty():
		help_notice.dialog_text = message
		help_notice.popup_centered()


## Builds one row per input of [param asset], filled from the node's input stash.
func _build_input_rows(asset: HEGoAssetNode, selected_node: Node, generation: int) -> void:
	var input_names = await _await_task(asset.get_input_names())
	if not _is_rebuild_current(generation, selected_node) or not input_names is PackedStringArray:
		return

	input_nodes = Array()
	for i in range(input_names.size()):
		var input_node = preload("res://addons/hego/ui/input_ui.tscn").instantiate()
		input_vbox.add_child(input_node)
		var inputs = PackedStringArray()
		var settings := {}
		var textures: Variant = []
		if selected_node.has_method("hego_get_input_stash"):
			var input_stash = selected_node.hego_get_input_stash()
			if input_stash.size() > i:
				inputs = input_stash[i]["inputs"]
				settings = input_stash[i].get("settings", {})
				textures = input_stash[i].get("textures", [])
		input_node.setup(input_names[i], inputs, settings, selected_node, input_visibility_undo_redo, textures if textures is Array else [])
		input_node.inputs_changed.connect(_on_input_changed)
		input_nodes.append(input_node)


## Remembers a section the user opened or closed, so the next rebuild leaves it as they left it.
func _on_section_open_changed(asset_label: String, is_open: bool) -> void:
	_open_sections[asset_label] = is_open


## Rebuilds the panel when the selected node starts asking for a different highlight.
##
## A multi-stage tool moving the user on to its next stage calls highlight() from its own
## code, which this panel has no way of hearing about; the node list it would have to be told
## through is cheap to read, so it is read on the timer that is already running.
func _poll_highlight() -> void:
	if not is_instance_valid(hego_tool_node) or _cooking:
		return

	var wanted := _requested_highlight()
	if wanted == _last_highlight:
		return
	_last_highlight = wanted
	await update_ui()


func _render_parameters(parameters: Dictionary, container: Control, asset: HEGoAssetNode) -> void:
	_parameter_data[asset.get_instance_id()] = parameters
	_editor.add_parameters(parameters.values(), container, asset)
	for control in container.find_children("*", "Control", true, false):
		if not control.has_meta("hego_parm_name"):
			continue
		if control is LineEdit:
			control.text_changed.connect(func(_text: String): control.set_meta("hego_draft", true))
			control.text_submitted.connect(func(_text: String): control.set_meta("hego_draft", false))
		elif control is TextEdit:
			control.text_changed.connect(func(): control.set_meta("hego_draft", true))


func _node_candidates(asset: HEGoAssetNode, descriptor: Dictionary) -> Array:
	var host := hego_tool_node
	if not is_instance_valid(host):
		return []
	var entries := ParameterLinks.candidates(host, asset)
	if entries.is_empty():
		return []
	var nodes := []
	for entry in entries:
		nodes.append(entry.node)
	var result := await HEGoNodeUtil.checked_task(self, asset.get_node_parm_candidates(descriptor.name, nodes))
	if not result.ok or hego_tool_node != host:
		return []
	var matches := []
	for i in mini(entries.size(), result.value.size()):
		if result.value[i]:
			matches.append(entries[i])
	return matches


func _on_instance_requested(name: String, id: int, position: int, insert: bool, asset: HEGoAssetNode) -> void:
	if not _accepts_edit(asset):
		return
	var task := asset.insert_multiparm_instance(id, position) if insert else asset.remove_multiparm_instance(id, position)
	await _change_layout(asset, task, {"block": name, "position": position, "delta": 1 if insert else -1})


func _on_instance_count_requested(name: String, count: int, asset: HEGoAssetNode) -> void:
	if _accepts_edit(asset):
		await _change_layout(asset, asset.set_parm(name, count), {"block": name, "position": 0, "delta": 0})


func _change_layout(asset: HEGoAssetNode, task: HEGoTask, change: Dictionary) -> void:
	var key := asset.get_instance_id()
	var host := hego_tool_node
	var container: Control = _containers[key]
	_changing_layout[key] = true
	container.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_DISABLED
	container.focus_behavior_recursive = Control.FOCUS_BEHAVIOR_DISABLED
	var previous: Dictionary = _parameter_data.get(key, {})
	await _finish_edit(asset, task, "", {}, previous, change)
	_changing_layout.erase(key)
	if is_instance_valid(container) and host == hego_tool_node and _containers.get(key) == container:
		container.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_INHERITED
		container.focus_behavior_recursive = Control.FOCUS_BEHAVIOR_INHERITED


func _on_node_requested(name: String, source: Variant, asset: HEGoAssetNode) -> void:
	if not _accepts_edit(asset):
		return
	var binding := {}
	if source != null:
		for entry in ParameterLinks.candidates(hego_tool_node, asset):
			if entry.node == source:
				binding = entry.source
				break
		if binding.is_empty():
			return
	await _finish_edit(asset, asset.set_node_parm(name, source), name, binding)


## The plugin supplies the selected node that opted into the panel, or null.
func set_selected_node(node: Node) -> void:
	_scene_selection = node
	if not lock_button.button_pressed:
		await _follow_scene_selection()


func _follow_scene_selection() -> void:
	if is_instance_valid(hego_tool_node) and hego_tool_node.tree_exiting.is_connected(_on_selected_node_exiting):
		hego_tool_node.tree_exiting.disconnect(_on_selected_node_exiting)
		hego_tool_node.renamed.disconnect(_update_lock_button)
	if is_instance_valid(_scene_selection) and _scene_selection.is_inside_tree() and not _scene_selection.is_queued_for_deletion():
		hego_tool_node = _scene_selection
		hego_tool_node.tree_exiting.connect(_on_selected_node_exiting, CONNECT_ONE_SHOT)
		hego_tool_node.renamed.connect(_update_lock_button)
	else:
		hego_tool_node = null
	_update_lock_button()
	hego_asset_node = null
	await update_ui()


func _on_lock_toggled(locked: bool) -> void:
	if not locked and _scene_selection != hego_tool_node:
		_follow_scene_selection()
	else:
		_update_lock_button()


func _update_lock_button() -> void:
	lock_button.disabled = not is_instance_valid(hego_tool_node)
	lock_button.text = "Locked to %s" % hego_tool_node.name if lock_button.button_pressed else "Lock Panel"


func _on_selected_node_exiting() -> void:
	if _scene_selection == hego_tool_node:
		_scene_selection = null
	lock_button.set_pressed_no_signal(false)
	_follow_scene_selection()


func _mark_scene_changed(host: Node) -> void:
	if not Engine.is_editor_hint() or not is_instance_valid(host) or not is_inside_tree():
		return
	var scene := get_tree().edited_scene_root
	var editor := Engine.get_singleton("EditorInterface")
	if scene and editor and (host == scene or scene.is_ancestor_of(host)):
		editor.mark_scene_as_unsaved()


func _accepts_edit(asset: HEGoAssetNode) -> bool:
	var key := asset.get_instance_id()
	return not _rendering_parameters and _containers.has(key) and not _changing_layout.has(key) and is_instance_valid(hego_tool_node)


func _on_value_changed(name: String, value: Variant, asset: HEGoAssetNode) -> void:
	if not _accepts_edit(asset):
		return
	# A literal Houdini path replaces any scene-node binding for the same parameter.
	await _finish_edit(asset, asset.set_parm(name, value), name)


func _finish_edit(asset: HEGoAssetNode, task: HEGoTask, name := "", binding := {}, previous_layout := {}, change := {}) -> void:
	var host := hego_tool_node
	var key := asset.get_instance_id()
	var revision := int(_edit_revisions.get(key, 0)) + 1
	_edit_revisions[key] = revision
	var result := await HEGoNodeUtil.checked_task(self, task)
	if not result.ok:
		HEGoLog.get_singleton().error("parm", result.message)
	elif is_instance_valid(host):
		var asset_key := ParameterLinks.asset_key(host, asset)
		var links := ParameterLinks.saved(host, asset_key)
		if not previous_layout.is_empty() and not links.is_empty():
			var current = await _await_task(asset.get_parms_dict())
			if current is Dictionary and is_instance_valid(host):
				links = ParameterLinks.remap_instances(links, previous_layout, current, change)
				ParameterLinks.store(host, asset_key, links)
		if not name.is_empty() and not asset_key.is_empty():
			if not binding.is_empty():
				links[name] = binding
			else:
				links.erase(name)
			ParameterLinks.store(host, asset_key, links)
		if host.has_method("hego_notify_cook_inputs_changed"):
			host.hego_notify_cook_inputs_changed()
		# Manual cook still saves the edit. Custom multi-asset hosts may own a stash per section.
		var entries := ParameterLinks.panel_assets(host)
		var primary: bool = not entries.is_empty() and entries[0].get("asset") == asset
		if host.has_method("hego_set_asset_parm_stash") or (primary and host.has_method("hego_set_parm_stash")):
			var snapshot := await HEGoNodeUtil.checked_task(self, asset.get_preset())
			if snapshot.ok and is_instance_valid(host) and ParameterLinks.asset_key(host, asset) == asset_key and snapshot.value is PackedByteArray:
				if host.has_method("hego_set_asset_parm_stash"):
					host.hego_set_asset_parm_stash(asset, snapshot.value)
				else:
					host.hego_set_parm_stash(snapshot.value)
		_mark_scene_changed(host)
	if not is_instance_valid(host) or hego_tool_node != host or _edit_revisions.get(key) != revision:
		return
	if result.ok and auto_recook_toggle.button_pressed and not _requires_explicit_recook():
		while _cooking:
			await get_tree().process_frame
			if not is_inside_tree() or not is_instance_valid(host) or hego_tool_node != host or _edit_revisions.get(key) != revision:
				return
		await recook()
	await _refresh_parameters(asset, host, revision)


func _refresh_parameters(asset: HEGoAssetNode, host: Node, revision: int) -> void:
	var key := asset.get_instance_id()
	var generation := _rebuild_generation
	var data = await _await_task(asset.get_parms_dict())
	if not _is_rebuild_current(generation, host) or _edit_revisions.get(key) != revision or not _containers.has(key) or not data is Dictionary:
		return
	var container: Control = _containers[key]
	var focus := get_viewport().gui_get_focus_owner()
	var field: Control = focus
	while field and not field.has_meta("hego_parm_name"):
		field = field.get_parent_control()
	var restore_focus := field != null and container.is_ancestor_of(field)
	var name := str(field.get_meta("hego_parm_name")) if restore_focus else ""
	var component: Variant = field.get_meta("hego_parm_component") if restore_focus else null
	var draft: Variant = null
	if restore_focus and focus.get_meta("hego_draft", false) and (focus is LineEdit or focus is TextEdit):
		draft = focus.text
	var caret: int = focus.caret_column if focus is LineEdit else (focus.get_caret_column() if focus is TextEdit else -1)
	var line: int = focus.get_caret_line() if focus is TextEdit else 0
	var scroll := parm_vbox.get_parent() as ScrollContainer
	var offset := scroll.scroll_vertical
	_rendering_parameters = true
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()
	_render_parameters(data, container, asset)
	_rendering_parameters = false
	if restore_focus:
		for control in container.find_children("*", "Control", true, false):
			if control.get_meta("hego_parm_name", "") == name and control.get_meta("hego_parm_component", -1) == component and control.is_visible_in_tree():
				if control is SpinBox:
					control = control.get_line_edit()
				if (control is LineEdit or control is TextEdit) and not control.editable:
					break
				control.grab_focus()
				if draft != null and (control is LineEdit or control is TextEdit):
					control.text = draft
					control.set_meta("hego_draft", true)
				if control is LineEdit and caret >= 0:
					control.caret_column = caret
				elif control is TextEdit and caret >= 0:
					control.set_caret_line(line)
					control.set_caret_column(caret)
				break
	scroll.set_deferred("scroll_vertical", offset)


func _on_input_changed():
	# The per-input settings dictionary belongs to the node, not to this panel. Building a
	# fresh empty one here threw away whatever the node had stored the moment anyone
	# touched an input row, so read the current stash and carry each entry through.
	var stashed = []
	if hego_tool_node and hego_tool_node.has_method("hego_get_input_stash"):
		stashed = hego_tool_node.hego_get_input_stash()

	var inputs = Array()
	for i in range(input_nodes.size()):
		var settings = {}
		if i < stashed.size() and stashed[i] is Dictionary:
			settings = stashed[i].get("settings", {}).duplicate()
		settings["include_children"] = input_nodes[i].include_children.button_pressed
		# Settings an extension input handler edits in this row, see HEGoInputHandler.
		settings.merge(input_nodes[i].get_extension_settings(), true)
		var row := {
			"inputs": input_nodes[i].get_inputs(),
			"settings": settings,
		}
		var textures: Array = input_nodes[i].get_textures()
		if not textures.is_empty():
			row["textures"] = textures
		inputs.append(row)
	if hego_tool_node.has_method("hego_set_input_stash"):
		hego_tool_node.hego_set_input_stash(inputs)
		_mark_scene_changed(hego_tool_node)
	if auto_recook_toggle.button_pressed and not _requires_explicit_recook():
		if _cooking:
			_pending_input_recook = hego_tool_node
		else:
			await recook()


## Whether the selected node or one of its inputs asks to be recooked only on request,
## which turns auto recook off for it.
func _requires_explicit_recook() -> bool:
	if hego_tool_node and hego_tool_node.has_method("hego_requires_explicit_cook") and hego_tool_node.hego_requires_explicit_cook():
		return true
	for row in input_nodes:
		if row.requires_explicit_cook():
			return true
	return false


## Lets the selected node know its inputs or parameters changed, for anything that tracks
## whether its last result is still current.
func _notify_inputs_changed() -> void:
	if hego_tool_node and hego_tool_node.has_method("hego_notify_cook_inputs_changed"):
		hego_tool_node.hego_notify_cook_inputs_changed()
	

func _on_recook_button_pressed(rebuild_asset := false):
	if _cooking or not is_instance_valid(hego_tool_node):
		return
	var selected_node := hego_tool_node
	var total_start_usec = Time.get_ticks_usec()
	var session_start_msec = 0.0
	var recook_msec = 0.0
	var ui_rebuild_msec = 0.0

	if auto_start_session_toggle.button_pressed:
		var phase_start_usec = Time.get_ticks_usec()
		if not HEGoAPI.get_singleton().is_session_active():
			HEGoAPI.get_singleton().start_session(HEGoAPI.SESSION_NAMED_PIPE, "hapi")
		session_start_msec = _elapsed_msec(phase_start_usec)

	var recook_start_usec = Time.get_ticks_usec()
	await recook(rebuild_asset)
	recook_msec = _elapsed_msec(recook_start_usec)

	if not is_instance_valid(selected_node) or selected_node != hego_tool_node:
		return
	var preset_index := preset_dropdown.selected
	var ui_start_usec = Time.get_ticks_usec()
	await update_ui()
	if selected_node == hego_tool_node and preset_index >= 0 and preset_index < preset_dropdown.item_count:
		preset_dropdown.select(preset_index)
	ui_rebuild_msec = _elapsed_msec(ui_start_usec)

	_print_bottom_panel_timing("rebuild_button" if rebuild_asset else "recook_button", session_start_msec, recook_msec, ui_rebuild_msec, _elapsed_msec(total_start_usec))
		
		
func recook(rebuild_asset := false):
	if not is_instance_valid(hego_tool_node) or _cooking:
		return

	var selected_node := hego_tool_node
	_cooking = true
	_set_buttons_disabled(true)
	var succeeded := true
	if rebuild_asset:
		# Widgets from the old definition hold parameter IDs and input indices.
		_rebuild_generation += 1
		_clear_widgets()
		succeeded = selected_node.has_method("hego_rebuild") and await selected_node.hego_rebuild()
	elif selected_node.has_method("cook"):
		await selected_node.cook()
	if succeeded and is_instance_valid(selected_node) and selected_node == hego_tool_node:
		await _stash_cooked_parameters(selected_node)
	_cooking = false
	_set_buttons_disabled(not is_instance_valid(hego_tool_node))
	var pending := _pending_input_recook
	_pending_input_recook = null
	if is_instance_valid(pending) and pending == hego_tool_node and auto_recook_toggle.button_pressed and not _requires_explicit_recook():
		await recook()


func _stash_cooked_parameters(selected_node: Node) -> void:
	# A failed preset restore can leave a valid HAPI node ID. Do not replace
	# the saved stash with that incomplete instance or provoke a second error.
	if selected_node.has_method("hego_did_last_cook_succeed") and not selected_node.hego_did_last_cook_succeed():
		return

	# A rebuild may have replaced the instance that the panel previously displayed.
	if selected_node.has_method("hego_set_parm_stash"):
		var entries := _panel_assets()
		hego_asset_node = entries[0]["asset"] if not entries.is_empty() else null
		if hego_asset_node:
			var preset = await _await_task(hego_asset_node.get_preset())
			if preset != null and is_instance_valid(selected_node):
				selected_node.hego_set_parm_stash(preset)
		

func create_preset_file(preset_name: String) -> void:
	print("[HEGo]: Creating preset")
	if hego_asset_node and hego_tool_node.has_method("hego_get_asset_name"):
		var host := hego_tool_node
		var asset := hego_asset_node
		var preset = await _await_task(asset.get_preset())
		if hego_tool_node != host or hego_asset_node != asset:
			return
		if preset:
			var res_path = get_preset_res_path()
			
			# Ensure directory exists
			var dir = DirAccess.open("res://")
			var asset_dir = res_path.get_base_dir()
			if asset_dir != "":
				if not DirAccess.dir_exists_absolute(asset_dir):
					dir.make_dir_recursive(asset_dir)

			var presets_res: HEGoHDAPreset
			# Check if the resource exists
			if ResourceLoader.exists(res_path):
				print("[HEGo]: Adding preset to existing file at " + res_path)
				# Load existing resource
				presets_res = ResourceLoader.load(res_path)
				# Verify the resource is of type HEGoHDAPreset
				if presets_res is HEGoHDAPreset:
					# Check if preset_name already exists in presets dictionary
					if preset_name in presets_res.presets.keys():
						push_error("[HEGo]: Preset with this name already exists, aborting. Select the preset and save instead, or give a different name!")
						return
				else:
					push_error("[HEGo]: Failed to save preset. A file exists at the path, but it's not of type HEGoHDAPreset")
					return
			else:
				print("[HEGo]: Creating new preset file at " + res_path)
				# Create a new HEGoHDAPreset resource
				presets_res = HEGoHDAPreset.new()
				presets_res.presets = {} # Initialize the presets dictionary
			# Add the new preset to the presets dictionary
			presets_res.presets[preset_name] = preset
			presets_res.parameter_links[preset_name] = ParameterLinks.saved(host, ParameterLinks.asset_key(host, asset))
			# Save the resource to the specified path
			var error = ResourceSaver.save(presets_res, res_path)
			if error == OK:
				print("[HEGo]: Preset saved successfully")
				# Update UI to refresh dropdown
				await update_ui()
				# Select the newly created preset in the dropdown
				_select_preset_in_dropdown(preset_name)
			else:
				print("[HEGo]: Failed to save preset. Error code: ", error)
		else:
			push_error("[HEGo]: Failed to retrieve parms from Houdini - Perhaps the node is not instantiated correctly?")
	else:
		push_error("[HEGo]: Invalid hego_asset_node or hego_tool_node. Cannot create preset.")
	

func get_preset_res_path():
	var operator: String = hego_tool_node.hego_get_asset_name()
	var name := operator.trim_prefix("Sop/")
	var directory := "res://hego/presets/"
	var legacy := directory + name + ".tres"
	for part in name.split("/"):
		var stem := part.get_slice(".", 0).to_upper()
		var device := stem in ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"] or (
				stem.length() == 4 and stem.left(3) in ["COM", "LPT"] and stem.right(1) in "123456789¹²³")
		if part in [".", ".."] or not part.is_valid_filename() or device:
			# Existing Linux users can still load their namespaced library file.
			if OS.get_name() != "Windows" and not name.contains("/") and FileAccess.file_exists(legacy):
				return legacy
			# A separate directory avoids collisions with existing valid operator names.
			return directory + "encoded/" + name.sha256_text() + ".tres"
	return legacy
	
func update_preset_dropdown():
	if hego_tool_node and hego_tool_node.has_method("hego_get_asset_name"):
		var res_path = get_preset_res_path()
		
		# Clear existing items in the dropdown
		preset_dropdown.clear()
		
		# Add a default item
		preset_dropdown.add_item("Select Preset")
		preset_dropdown.set_item_disabled(0, true)
		
		# Check if the resource exists and is a HEGoHDAPreset
		if ResourceLoader.exists(res_path):
			var presets_res = ResourceLoader.load(res_path)
			if presets_res is HEGoHDAPreset and presets_res.presets is Dictionary:
				# Add each preset name to the dropdown
				for preset_name in presets_res.presets.keys():
					preset_dropdown.add_item(preset_name)
			else:
				print("[HEGo]: No valid HEGoHDAPreset at ", res_path)
	else:
		# Clear dropdown if no valid tool node
		preset_dropdown.clear()
		preset_dropdown.add_item("No Asset Selected")
		preset_dropdown.set_item_disabled(0, true)
		
func _on_load_preset_button_pressed():
	print("load preset")
	
	# Early validation checks
	if not hego_asset_node or not hego_tool_node or not hego_tool_node.has_method("hego_get_asset_name"):
		push_error("[HEGo]: Invalid hego_asset_node or hego_tool_node. Cannot load preset.")
		return
	
	var selected_index = preset_dropdown.get_selected()
	if selected_index <= 0:
		push_error("[HEGo]: No valid preset selected")
		return
	
	var preset_name = preset_dropdown.get_item_text(selected_index)
	var res_path = get_preset_res_path()
	
	if not ResourceLoader.exists(res_path):
		push_error("[HEGo]: No preset resource found at ", res_path)
		return
	
	var presets_res = ResourceLoader.load(res_path)
	if not (presets_res is HEGoHDAPreset and presets_res.presets is Dictionary):
		push_error("[HEGo]: Failed to load preset. Resource at ", res_path, " is not a valid HEGoHDAPreset")
		return
	
	if not preset_name in presets_res.presets:
		push_error("[HEGo]: Selected preset '", preset_name, "' not found in resource")
		return
	
	var host := hego_tool_node
	var asset := hego_asset_node
	var key := ParameterLinks.asset_key(host, asset)
	var links: Dictionary = presets_res.parameter_links.get(preset_name, {})
	var old_links := ParameterLinks.saved(host, key)
	var previous = await _await_task(asset.get_preset())
	if previous == null or hego_tool_node != host or hego_asset_node != asset:
		return
	var result := await HEGoNodeUtil.checked_task(self, asset.set_preset(presets_res.presets[preset_name]))
	if not is_instance_valid(host):
		return
	var applied: bool = result.ok
	if applied:
		applied = await ParameterLinks.restore(host, asset, links)
	else:
		HEGoLog.get_singleton().error("parm", result.message)
	if not applied:
		# HAPI can apply part of a preset before it reports an error.
		if await _await_task(asset.set_preset(previous)) != null:
			await ParameterLinks.restore(host, asset, old_links)
	else:
		ParameterLinks.store(host, key, links)
		if host.has_method("hego_set_parm_stash"):
			host.hego_set_parm_stash(presets_res.presets[preset_name])
		if host.has_method("hego_notify_cook_inputs_changed"):
			host.hego_notify_cook_inputs_changed()
		_mark_scene_changed(host)
	if host == hego_tool_node:
		await update_ui()
		_select_preset_in_dropdown(preset_name)


func _on_save_preset_button_pressed():
	print("save preset")
	
	# Early validation checks
	if not hego_asset_node or not hego_tool_node or not hego_tool_node.has_method("hego_get_asset_name"):
		push_error("[HEGo]: Invalid hego_asset_node or hego_tool_node. Cannot save preset.")
		return
	
	var selected_index = preset_dropdown.get_selected()
	if selected_index <= 0:
		push_error("[HEGo]: No valid preset selected")
		return
	
	var preset_name = preset_dropdown.get_item_text(selected_index)
	var res_path = get_preset_res_path()
	
	var host := hego_tool_node
	var asset := hego_asset_node
	var preset = await _await_task(asset.get_preset())
	if hego_tool_node != host or hego_asset_node != asset:
		return
	if not preset:
		push_error("[HEGo]: Failed to retrieve parms from Houdini - Perhaps the node is not instantiated correctly?")
		return
	
	if not ResourceLoader.exists(res_path):
		push_error("[HEGo]: No preset resource found at ", res_path)
		return
	
	var presets_res = ResourceLoader.load(res_path)
	if not (presets_res is HEGoHDAPreset and presets_res.presets is Dictionary):
		push_error("[HEGo]: Failed to save preset. Resource at ", res_path, " is not a valid HEGoHDAPreset")
		return
	
	if not preset_name in presets_res.presets:
		push_error("[HEGo]: Selected preset '", preset_name, "' not found in resource")
		return
	
	# Save the preset
	presets_res.presets[preset_name] = preset
	presets_res.parameter_links[preset_name] = ParameterLinks.saved(host, ParameterLinks.asset_key(host, asset))
	var error = ResourceSaver.save(presets_res, res_path)
	if error != OK:
		push_error("[HEGo]: Failed to save preset '", preset_name, "'. Error code: ", error)
		return
	
	print("[HEGo]: Preset '", preset_name, "' saved successfully")
	await update_ui()
	
	# Reselect the saved preset in the dropdown
	_select_preset_in_dropdown(preset_name)

# Helper function to select a preset in the dropdown by name
func _select_preset_in_dropdown(preset_name: String) -> void:
	for i in range(preset_dropdown.get_item_count()):
		if preset_dropdown.get_item_text(i) == preset_name:
			preset_dropdown.select(i)
			break

# Handle asset picker button press
func _on_asset_picker_button_pressed():
	if not _can_pick_asset():
		push_error("[HEGo]: This node's HDA is fixed and cannot be chosen from the panel.")
		return
	
	# Load the asset picker dialog
	var picker_scene = preload("res://addons/hego/ui/asset_picker_dialog.tscn")
	var picker = picker_scene.instantiate()
	add_child(picker)
	
	# Show the picker and wait for selection
	picker.asset_selected.connect(_on_asset_picked)
	picker.popup_centered()

## Whether the selected node lets the panel choose its HDA.
##
## A node whose operator is written into its script has no use for the picker, and answering
## this with a method probe rather than a type check is what lets any script say so.
func _can_pick_asset() -> bool:
	return hego_tool_node != null and hego_tool_node.has_method("hego_set_asset_name")


# Handle asset selection from picker
func _on_asset_picked(asset_name: String):
	if not _can_pick_asset():
		return

	# The node decides what changing its HDA means, including forgetting the old one.
	hego_tool_node.hego_set_asset_name(asset_name)

	if auto_recook_toggle.button_pressed and not _requires_explicit_recook():
		await recook()


func _update_task_queue():
	var api = HEGoAPI.get_singleton()
	if not api:
		return

	var pending_count = api.get_task_pending_count()
	var current_task = api.get_current_task()
	var current_status = current_task.get_status() if current_task else -1
	var history = api.get_completed_task_history()
	var history_size = history.size()

	# Dirty check — skip rebuild if nothing changed
	if pending_count == _last_pending_count and current_status == _last_current_status and history_size == _last_history_size:
		return

	_last_pending_count = pending_count
	_last_current_status = current_status
	_last_history_size = history_size

	# Clear queued section
	for child in queued_tasks_vbox.get_children():
		child.queue_free()

	# Clear finished section
	for child in finished_tasks_vbox.get_children():
		child.queue_free()

	# Populate queued section: pending tasks in reverse order, then current at bottom
	var pending = api.get_pending_tasks()
	for i in range(pending.size() - 1, -1, -1):
		queued_tasks_vbox.add_child(_create_task_label(pending[i], false))

	if current_task:
		queued_tasks_vbox.add_child(_create_task_label(current_task, true))

	# Populate finished section: newest at top
	for i in range(history_size - 1, -1, -1):
		finished_tasks_vbox.add_child(_create_task_label(history[i], false))


func _create_task_label(task: HEGoTask, is_running: bool) -> Label:
	var label = Label.new()
	var text = task.get_description()
	var node_id = task.get_node_id()
	if node_id >= 0:
		text += "  (node: %d)" % node_id

	var status = task.get_status()
	if status == HEGoTask.FAILED:
		var err = task.get_error_message()
		if err != "":
			text += " - " + err
		label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	elif status == HEGoTask.COMPLETED:
		label.add_theme_color_override("font_color", Color(0.4, 0.8, 0.4))
	elif is_running:
		label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))

	label.text = text
	return label
