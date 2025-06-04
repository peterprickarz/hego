@tool
extends Control

signal selected_hego_node_changed(node: Node)

var hego_tool_node: Node

# Called when the node enters the scene tree for the first time.
func _ready():
	var start_button = $"TabContainer/Houdini Engine/ButtonStartSession"
	var stop_button = $"TabContainer/Houdini Engine/ButtonStopSession"
	start_button.pressed.connect(_on_start_session_button_pressed)
	stop_button.pressed.connect(_on_stop_session_button_pressed)
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass
	
func update_hego_asset_node(node:Node):
	hego_tool_node = node
	selected_hego_node_changed.emit(node)
	
func _on_start_session_button_pressed():
	HEGoAPI.get_singleton().start_session()
	
func _on_stop_session_button_pressed():
	HEGoAPI.get_singleton().stop_session()
	
