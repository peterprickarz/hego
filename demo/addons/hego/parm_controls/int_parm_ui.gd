@tool
extends Control

signal value_changed(param_name: String, value: Variant)

@onready var label = $HBoxContainer/Label
@onready var slider = $HBoxContainer/HSlider
@onready var spin_box = $HBoxContainer/SpinBox

var param: Dictionary = {}
var initializing = true
func _ready():
	if not label or not slider or not spin_box:
		push_error("IntParmUI: One or more nodes are null. Check scene structure: Label=%s, HSlider=%s, SpinBox=%s" % [label, slider, spin_box])
		return
	
	if Engine.is_editor_hint():
		slider.value_changed.connect(_on_slider_value_changed)
		spin_box.value_changed.connect(_on_spin_box_value_changed)
	else:
		slider.value_changed.connect(_on_slider_value_changed)
		spin_box.value_changed.connect(_on_spin_box_value_changed)

func setup(_param: Dictionary):
	initializing = true
	if not label:
		push_error("IntParmUI: Label node is null. Cannot set label text.")
		return
	if not slider or not spin_box:
		push_error("IntParmUI: Slider or SpinBox node is null. Cannot set values.")
		return
	
	param = _param.duplicate()
	label.text = param.get("label", "Unnamed")
	
	# Always set min/max, as they are guaranteed to exist
	slider.min_value = param.get("min", 0)
	slider.max_value = param.get("max", 10)
	spin_box.min_value = param.get("min", 0)
	spin_box.max_value = param.get("max", 10)
	
	# Enforce limits only if has_min/has_max is true
	slider.allow_lesser = not param.get("has_min", false)
	slider.allow_greater = not param.get("has_max", false)
	spin_box.allow_lesser = not param.get("has_min", false)
	spin_box.allow_greater = not param.get("has_max", false)
	
	slider.step = 1
	spin_box.step = 1
	visible = param.get("visible", true)
	
	if param.get("help", ""):
		tooltip_text = param["help"]
	
	slider.value = param.get("values", [0])[0]
	spin_box.value = param.get("values", [0])[0]
	
	
	
	if Engine.is_editor_hint():
		queue_redraw()
	initializing = false

func _on_slider_value_changed(value: float):
	if initializing:
		return
	if not spin_box:
		push_error("IntParmUI: SpinBox node is null. Cannot update value.")
		return
	
	spin_box.value = value
	param["values"] = [int(value)]
	value_changed.emit(param.get("name", ""), int(value))

func _on_spin_box_value_changed(value: float):
	if initializing:
		return
	if not slider:
		push_error("IntParmUI: Slider node is null. Cannot update value.")
		return
	
	slider.value = value
	param["values"] = [int(value)]
	value_changed.emit(param.get("name", ""), int(value))
