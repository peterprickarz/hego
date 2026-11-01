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
	
	# Button parameters are not wired through to Houdini yet. Pressing one used to look up
	# a scene node named "HEGoAssetNode" and call pressButton() on it. Neither can exist:
	# HEGoAssetNode is RefCounted and never enters the scene tree, and no HEGo class binds
	# pressButton. So every rendered button logged a warning and every press an error.
	push_warning("HEGo: button parameter '%s' is not supported yet." % param.get("label", param.get("name", "")))

	# Emitted for consistency with the other parm widgets; the value is ignored.
	value_changed.emit(param.get("name", ""), 0)
