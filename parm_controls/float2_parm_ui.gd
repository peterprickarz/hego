@tool
extends Control

signal value_changed(param_name: String, value: Variant)

@onready var label = $HBoxContainer/Label
@onready var x_spin_box = $HBoxContainer/XSpinBox
@onready var y_spin_box = $HBoxContainer/YSpinBox

var param: Dictionary = {}
var initializing = true
func _ready():
	if not label or not x_spin_box or not y_spin_box:
		push_error("Float2ParmUI: One or more nodes are null. Check scene structure: Label=%s, XSpinBox=%s, YSpinBox=%s" % [label, x_spin_box, y_spin_box])
		return
	
	if Engine.is_editor_hint():
		x_spin_box.value_changed.connect(_on_x_value_changed)
		y_spin_box.value_changed.connect(_on_y_value_changed)
	else:
		x_spin_box.value_changed.connect(_on_x_value_changed)
		y_spin_box.value_changed.connect(_on_y_value_changed)

func setup(_param: Dictionary):
	initializing = true
	if not label:
		push_error("Float2ParmUI: Label node is null. Cannot set label text.")
		return
	if not x_spin_box or not y_spin_box:
		push_error("Float2ParmUI: SpinBox nodes are null. Cannot set values.")
		return
	
	param = _param.duplicate()
	label.text = param.get("label", "Unnamed")
	

	
	# Always set min/max, as they are guaranteed to exist
	x_spin_box.min_value = param.get("min", -100.0)
	y_spin_box.min_value = param.get("min", -100.0)
	x_spin_box.max_value = param.get("max", 100.0)
	y_spin_box.max_value = param.get("max", 100.0)
	
	# Enforce limits only if has_min/has_max is true
	x_spin_box.allow_lesser = not param.get("has_min", false)
	y_spin_box.allow_lesser = not param.get("has_min", false)
	x_spin_box.allow_greater = not param.get("has_max", false)
	y_spin_box.allow_greater = not param.get("has_max", false)
	
	x_spin_box.step = 0.01
	y_spin_box.step = 0.01
	visible = param.get("visible", true)
	
	x_spin_box.value = param.get("values", [0.0, 0.0])[0]
	y_spin_box.value = param.get("values", [0.0, 0.0])[1]
	
	if param.get("help", ""):
		tooltip_text = param["help"]
	
	if Engine.is_editor_hint():
		queue_redraw()
	initializing = false

func _on_x_value_changed(value: float):
	if initializing:
		return
	param["values"][0] = value
	value_changed.emit(param.get("name", ""), Vector2(param["values"][0], param["values"][1]))

func _on_y_value_changed(value: float):
	if initializing:
		return
	param["values"][1] = value
	value_changed.emit(param.get("name", ""), Vector2(param["values"][0], param["values"][1]))
