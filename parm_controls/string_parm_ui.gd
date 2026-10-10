@tool
extends Control

signal value_changed(param_name: String, value: Variant)

@onready var label = $HBoxContainer/Label
@onready var line_edit = $HBoxContainer/LineEdit

var param: Dictionary = {}
var initializing = true
func _ready():
	if not label or not line_edit:
		push_error("StringParmUI: One or more nodes are null. Check scene structure: Label=%s, LineEdit=%s" % [label, line_edit])
		return
	
	if Engine.is_editor_hint():
		line_edit.text_changed.connect(_on_text_changed)
	else:
		line_edit.text_changed.connect(_on_text_changed)

func setup(_param: Dictionary):
	initializing = true
	if not label:
		push_error("StringParmUI: Label node is null. Cannot set label text.")
		return
	if not line_edit:
		push_error("StringParmUI: LineEdit node is null. Cannot set value.")
		return
	
	param = _param.duplicate()
	label.text = param.get("label", "Unnamed")
	line_edit.text = param.get("values", [""])[0]
	
	if param.get("has_max", false):
		line_edit.max_length = int(param.get("max", 0))
	if param.get("has_min", false):
		line_edit.placeholder_text = "Min length: " + str(param.get("min", 0))
	
	visible = param.get("visible", true)
	
	if param.get("help", ""):
		tooltip_text = param["help"]
	
	if Engine.is_editor_hint():
		queue_redraw()
	initializing = false

func _on_text_changed(new_text: String):
	if initializing:
		return
	if not line_edit:
		push_error("StringParmUI: LineEdit node is null. Cannot update value.")
		return
	
	if param.get("has_min", false) and new_text.length() < param.get("min", 0):
		line_edit.add_theme_color_override("font_color", Color.RED)
	else:
		line_edit.remove_theme_color_override("font_color")
	
	param["values"] = [new_text]
	value_changed.emit(param.get("name", ""), new_text)
	
	
