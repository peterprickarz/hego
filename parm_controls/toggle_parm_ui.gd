@tool
extends VBoxContainer

signal value_changed(param_name: String, value: Variant)

@onready var label = $HBoxContainer/Label
@onready var check_box = $HBoxContainer/CheckBox

var param: Dictionary = {}

func _ready():
	if not label or not check_box:
		push_error("ToggleParmUI: One or more nodes are null. Check scene structure: Label=%s, CheckBox=%s" % [label, check_box])
		return
	
	if Engine.is_editor_hint():
		check_box.toggled.connect(_on_check_box_toggled)
	else:
		check_box.toggled.connect(_on_check_box_toggled)

func setup(_param: Dictionary):
	if not label:
		push_error("ToggleParmUI: Label node is null. Cannot set label text.")
		return
	if not check_box:
		push_error("ToggleParmUI: CheckBox node is null. Cannot set value.")
		return
	
	param = _param.duplicate()
	label.text = param.get("label", "Unnamed")
	check_box.button_pressed = param.get("values", [0])[0] == 1
	check_box.text = param.get("label", "On/Off")  # Use label for CheckBox text
	
	visible = param.get("visible", true)
	
	if param.get("help", ""):
		tooltip_text = param["help"]
	
	if Engine.is_editor_hint():
		queue_redraw()

func _on_check_box_toggled(button_pressed: bool):
	if not check_box:
		push_error("ToggleParmUI: CheckBox node is null. Cannot update value.")
		return
	
	param["values"] = [1 if button_pressed else 0]
	value_changed.emit(param.get("name", ""), int(button_pressed))
