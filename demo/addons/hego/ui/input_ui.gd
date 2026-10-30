@tool
extends VBoxContainer

signal inputs_changed()

@onready var spin_box = $HBoxContainer/SpinBox
@onready var input_container = $InputContainer
@onready var label = $HBoxContainer/Label
@onready var include_children: CheckBox = $InputOptions/IncludeChildren
@onready var input_visible: CheckBox = $InputOptions/InputVisible
var _updating := false
var _input_host: Node
var _visibility_undo: Object
var _visibility_elapsed := 0.0
# The settings this row was set up with, and the editors of the extension input handlers
# it uses, keyed by handler script path. A handler stays active once the row has seen one
# of its nodes, so its options survive a referenced node being briefly missing.
var _stored_settings: Dictionary = {}
var _extension_editors: Dictionary = {}
var _active_handlers: Dictionary = {}

# Called when the node enters the scene tree for the first time.
func _ready():
	spin_box.value_changed.connect(_on_spin_box_value_changed)
	include_children.toggled.connect(func(_enabled: bool): _on_input_line_value_changed())
	input_visible.toggled.connect(_on_visibility_toggled)


## Shows [param in_label] with one line per entry in [param inputs].
func setup(in_label: String, inputs: PackedStringArray, settings: Dictionary = {}, host: Node = null, undo_manager: Object = null):
	_updating = true
	_input_host = host
	_visibility_undo = undo_manager
	label.text = in_label
	# Assigning the value only emits when it actually changes, so rebuild explicitly
	# as well; _on_spin_box_value_changed is idempotent.
	spin_box.value = inputs.size()
	_on_spin_box_value_changed(inputs.size())

	var input_lines := input_container.get_children()
	for i in range(mini(inputs.size(), input_lines.size())):
		input_lines[i].text = inputs[i]
	include_children.set_pressed_no_signal(bool(settings.get("include_children", false)))
	_stored_settings = settings.duplicate(true)
	_active_handlers.clear()
	for editor in _extension_editors.values():
		editor.load_settings(_stored_settings)
	_updating = false
	refresh_visibility()


## Brings the number of input lines in line with the spin box.
func _on_spin_box_value_changed(value: float):
	var wanted := maxi(int(value), 0)
	var lines := input_container.get_children()
	var current := lines.size()

	# Drop the extras from the end.
	for i in range(wanted, current):
		lines[i].free()

	# Add every missing line, not just one: an input wired to several nodes needs
	# one line per node, and adding a single line per call left the rest missing.
	for i in range(current, wanted):
		var new_line := HEGoInputLineEdit.new()
		input_container.add_child(new_line)
		new_line.input_changed.connect(_on_input_line_value_changed)

	_on_input_line_value_changed()

func _on_input_line_value_changed():
	if not _updating:
		inputs_changed.emit()
		refresh_visibility()
	
func get_inputs():
	var inputs = PackedStringArray()
	for child in input_container.get_children():
		inputs.append(child.text)
	return inputs


# Reflect scene-tree visibility edits and undo/redo without rebuilding the HDA UI.
func _process(delta: float) -> void:
	_visibility_elapsed += delta
	if _visibility_elapsed >= 0.25 and is_visible_in_tree():
		_visibility_elapsed = 0.0
		refresh_visibility()


func _visibility_targets() -> Array[Node3D]:
	var targets: Array[Node3D] = []
	if not is_instance_valid(_input_host):
		return targets
	for path in get_inputs():
		var node := HEGoInputNodes._resolve_input_node(_input_host, path)
		_collect_visibility_targets(node, targets)
	return targets


func _collect_visibility_targets(node: Node, targets: Array[Node3D]) -> void:
	if not is_instance_valid(node) or node.is_queued_for_deletion():
		return
	if node is Node3D:
		if not targets.has(node):
			targets.append(node)
		# Toggle a parent, preserving each descendant's individual visible flag.
		return
	if include_children.button_pressed:
		for child in node.get_children():
			_collect_visibility_targets(child, targets)


func refresh_visibility() -> void:
	_refresh_extension_editors()
	var targets := _visibility_targets()
	var shown := 0
	var parent_hidden := false
	for node in targets:
		if node.visible:
			shown += 1
			parent_hidden = parent_hidden or not node.is_visible_in_tree()
	input_visible.disabled = targets.is_empty()
	input_visible.set_pressed_no_signal(shown > 0)
	input_visible.text = "Mixed" if shown > 0 and shown < targets.size() else "Visible"
	input_visible.tooltip_text = "Show or hide the referenced input nodes. Hidden inputs still cook. Child visibility settings are preserved."
	if targets.is_empty():
		input_visible.tooltip_text = "No referenced 3D nodes to show or hide."
	elif shown > 0 and shown < targets.size():
		input_visible.tooltip_text += " Some inputs are visible; click to hide all."
	if parent_hidden:
		input_visible.tooltip_text += " A referenced node is also hidden by an ancestor."

## Settings the row's extension editors hold, for the panel to merge into this input's
## stored settings. Empty when the row uses no extension input kinds.
func get_extension_settings() -> Dictionary:
	_refresh_extension_editors()
	var result := {}
	for key in _active_handlers:
		if _extension_editors.has(key):
			result.merge(_extension_editors[key].get_settings(), true)
	return result


## Whether a kind of input this row uses asks to be recooked only on request.
func requires_explicit_cook() -> bool:
	var settings := _stored_settings.duplicate()
	settings.merge(get_extension_settings(), true)
	for key in _active_handlers:
		if _active_handlers[key].requires_explicit_cook(settings):
			return true
	return false


## The extension settings editors this row has created, shown or not.
func get_extension_editors() -> Array:
	return _extension_editors.values()


## Shows the settings editor of each extension input handler the row uses, creating it the
## first time. See [HEGoInputHandler.create_settings_editor].
func _refresh_extension_editors() -> void:
	var nodes_by_handler := {}
	if is_instance_valid(_input_host):
		for path in get_inputs():
			var node := HEGoInputNodes._resolve_input_node(_input_host, path)
			var handler := HEGoInputNodes.handler_for(node)
			if handler != null:
				var key := _handler_key(handler)
				if not nodes_by_handler.has(key):
					nodes_by_handler[key] = []
				nodes_by_handler[key].append(node)
	for handler in HEGoInputNodes.extension_handlers():
		var key := _handler_key(handler)
		if nodes_by_handler.has(key) or handler.claims_settings(_stored_settings):
			_active_handlers[key] = handler
		var editor: Control = _extension_editors.get(key)
		if editor == null and _active_handlers.has(key):
			editor = handler.create_settings_editor()
			if editor != null:
				add_child(editor)
				# Directly below the input lines, above the row's own options.
				move_child(editor, 2)
				editor.load_settings(_stored_settings)
				editor.changed.connect(_on_input_line_value_changed)
				_extension_editors[key] = editor
		if editor != null:
			editor.visible = _active_handlers.has(key)
			if editor.visible:
				editor.refresh(_input_host, nodes_by_handler.get(key, []))


static func _handler_key(handler: HEGoInputHandler) -> String:
	return handler.get_script().resource_path


func _on_visibility_toggled(shown: bool) -> void:
	var targets := _visibility_targets()
	var changed: Array[Node3D] = []
	for node in targets:
		if node.visible != shown:
			changed.append(node)
	if not changed.is_empty():
		if is_instance_valid(_visibility_undo):
			var action := "Show HEGo inputs" if shown else "Hide HEGo inputs"
			if _visibility_undo is EditorUndoRedoManager:
				_visibility_undo.create_action(action, UndoRedo.MERGE_DISABLE, _input_host)
			else:
				_visibility_undo.create_action(action)
			for node in changed:
				_visibility_undo.add_do_property(node, "visible", shown)
				_visibility_undo.add_undo_property(node, "visible", node.visible)
			_visibility_undo.commit_action()
		else:
			for node in changed:
				node.visible = shown
	refresh_visibility()
