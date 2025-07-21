@tool
extends VBoxContainer

signal value_changed(param_name: String, value: Variant)

@onready var label = $HBoxContainer/Label
@onready var button = $HBoxContainer/Button

var param: Dictionary = {}
var hego_node = null  # Reference to HEGoAssetNode

func _ready():
	if not label or not button:
		push_error("ButtonParmUI: One or more nodes are null. Check scene structure: Label=%s, Button=%s" % [label, button])
		return
	
	if Engine.is_editor_hint():
		button.pressed.connect(_on_button_pressed)
	else:
		button.pressed.connect(_on_button_pressed)
	
	# Find HEGoAssetNode in the scene tree (adjust path as needed)
	hego_node = get_tree().get_root().find_child("HEGoAssetNode", true, false)
	if not hego_node:
		push_warning("ButtonParmUI: HEGoAssetNode not found in scene tree.")

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
	
	if hego_node and hego_node.has_method("pressButton"):
		hego_node.pressButton()
	else:
		push_error("ButtonParmUI: HEGoAssetNode not set or pressButton() not found.")
	
	# Emit value_changed for consistency, but value is ignored
	value_changed.emit(param.get("name", ""), 0)
