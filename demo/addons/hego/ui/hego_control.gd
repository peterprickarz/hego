@tool
extends Control

signal selected_hego_node_changed(node: Node)

@onready var start_button: Button = %ButtonStartSession
@onready var stop_button: Button = %ButtonStopSession
@onready var connection_type: OptionButton = %ConnectionType
@onready var connection_data: TextEdit = %ConnectionData
@onready var logs: TextEdit = %Logs

var hego_tool_node: Node


# Called when the node enters the scene tree for the first time.
func _ready():
	start_button.pressed.connect(_on_start_session_button_pressed)
	stop_button.pressed.connect(_on_stop_session_button_pressed)

	
func update_hego_asset_node(node: Node):
	hego_tool_node = node
	selected_hego_node_changed.emit(node)


func _on_start_session_button_pressed():
	# Stop it then start it again to ensure a clean session
	HEGoAPI.get_singleton().stop_session()
	HEGoAPI.get_singleton().start_session()


func _on_stop_session_button_pressed():
	HEGoAPI.get_singleton().stop_session()
