@tool
extends VBoxContainer

signal value_changed(param_name: String, value: Variant)

@onready var label = $HBoxContainer/Label
@onready var button = $HBoxContainer/Button

var param: Dictionary = {}

func _ready():
	if not label or not button:
		push_error("ButtonParmUI: One or more nodes are null. Check scene structure: Label=%s, Button=%s" % [label, button])
		return

	button.pressed.connect(_on_button_pressed)

func setup(_param: Dictionary):
	if not label:
		push_error("ButtonParmUI: Label node is null. Cannot set label text.")
		return
	if not button:
		push_error("ButtonParmUI: Button node is null. Cannot set value.")
		return
	
	param = _param.duplicate()
	label.text = param.get("label", "Unnamed")
	button.text = param.get("label", "Press")
	
	visible = param.get("visible", true)
	
	if param.get("help", ""):
		tooltip_text = param["help"]
	
	if Engine.is_editor_hint():
		queue_redraw()

func _on_button_pressed():
	if not button:
		push_error("ButtonParmUI: Button node is null. Cannot process press.")
		return
	
	# A single integer write invokes the Houdini callback, regardless of its value.
	value_changed.emit(param.get("name", ""), 0)
