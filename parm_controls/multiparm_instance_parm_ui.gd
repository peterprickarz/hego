@tool
extends VBoxContainer

var instance_index: int
var parm_id: int

@onready var instance_index_label = $PanelContainer/VBoxContainer/HBoxContainer2/InstanceIndexLabel
@onready var insert_button = $PanelContainer/VBoxContainer/HBoxContainer2/InsertButton
@onready var remove_button = $PanelContainer/VBoxContainer/HBoxContainer2/RemoveButton
@onready var instance_parm_container = $PanelContainer/VBoxContainer/InstanceParmContainer
@onready var multiparm_name_label = $PanelContainer/VBoxContainer/HBoxContainer2/MultiParmNameLabel

signal remove_instance(id: int, index: int)
signal insert_instance(id: int, index: int)

# Called when the node enters the scene tree for the first time.
func _ready():
	insert_button.button_down.connect(_on_insert_button_pressed)
	remove_button.button_down.connect(_on_remove_button_pressed)
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass
	
func setup(index: int, id: int, label: String):
	instance_index = index
	parm_id = id
	instance_index_label.text = str(instance_index)
	multiparm_name_label.text = label+":"
	
func _on_insert_button_pressed():
	insert_instance.emit(parm_id, instance_index)
	
func _on_remove_button_pressed():
	remove_instance.emit(parm_id, instance_index)
	
func get_container():
	return instance_parm_container

