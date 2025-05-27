@tool
extends VBoxContainer

var param: Dictionary = {}
var instantiating = true

@onready var instance_container = $PanelContainer/VBoxContainer/MarginContainer/InstanceContainer
@onready var spin_box = $PanelContainer/VBoxContainer/HBoxContainer/SpinBox
@onready var label = $PanelContainer/VBoxContainer/HBoxContainer/Label

signal instance_count_changed(value: int, parm_dict: Dictionary)
# Called when the node enters the scene tree for the first time.
func _ready():
	spin_box.value_changed.connect(_on_spin_box_value_changed)
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass
	
func setup(parm_dict):
	instantiating = true
	param = parm_dict.duplicate()
	
	spin_box.value = param["instance_count"]
	label.text = param["label"]
	
	instantiating = false
	

func get_instance_container():
	return instance_container

func _on_spin_box_value_changed(value: float):
	if not instantiating:
		instance_count_changed.emit(int(value), param)
