## HEGo session control provides UI for starting/stopping HEGo sessions, monitoring connection
## status, and displaying session logs. It automatically captures logs from the HEGo
## LogManager and updates the session status indicator based on connection state.
@tool
extends Control

signal selected_hego_node_changed(node: Node)

@onready var start_button: Button = %Session/%ButtonStartSession
@onready var stop_button: Button = %Session/%ButtonStopSession
@onready var connection_type: OptionButton =  %Session/%ConnectionType
@onready var connection_data: TextEdit =  %Session/%ConnectionData
@onready var session_sync_status: RichTextLabel =  %Session/%SessionSyncStatusLabel
@onready var logs: TextEdit =  %Session/%Logs
@onready var library_control: Control = $TabContainer/Library

var hego_tool_node: Node


## Initialize the control and set up connections
func _ready():
	start_button.pressed.connect(_on_start_session_button_pressed)
	stop_button.pressed.connect(_on_stop_session_button_pressed)
	# Defer log capture setup to ensure HEGoLogManager singleton is fully initialized
	call_deferred("_setup_log_capture")

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		# Emergency cleanup when control is being destroyed
		if HEGoAPI.get_singleton() and HEGoAPI.get_singleton().is_session_active():
			print("[HEGo]: Control cleanup - stopping active session")
			HEGoAPI.get_singleton().stop_session()

	
## Update the currently selected HEGo asset node
func update_hego_asset_node(node: Node):
	hego_tool_node = node
	selected_hego_node_changed.emit(node)


## Handle start session button press - stops current session and starts new one
func _on_start_session_button_pressed():
	var connection_type_id = connection_type.selected
	var connection_data_text = connection_data.text
	
	logs.text += "Starting session...\n"
	logs.text += "Connection type: " + connection_type.get_item_text(connection_type_id) + "\n"
	logs.text += "Connection data: " + connection_data_text + "\n"
	logs.text += "Stopping previous session...\n"
	
	await get_tree().process_frame
	var stop_success = HEGoAPI.get_singleton().stop_session()
	logs.text += "Stop session result: " + ("Success" if stop_success else "Failed") + "\n"
	
	logs.text += "Starting new session (this may take a moment)...\n"
	await get_tree().process_frame
	
	# Map UI connection type to HEGoSessionManager enum values
	# InProcess=1, NewNamedPipe=2, NewTCPSocket=3, ExistingNamedPipe=4, ExistingTCPSocket=5, ExistingSharedMemory=6
	var session_type = connection_type_id + 1  # UI is 0-based, enum is 1-based
	var start_success = HEGoAPI.get_singleton().start_session(session_type, connection_data_text)
	
	if start_success:
		logs.text += "Session started successfully!\n"
		_set_session_status_connected()
	else:
		logs.text += "Session failed to start.\n"
		_set_session_status_disconnected()


## Handle stop session button press
func _on_stop_session_button_pressed():
	logs.text += "Stopping session...\n"
	var stop_success = HEGoAPI.get_singleton().stop_session()
	if stop_success:
		logs.text += "Session stopped successfully.\n"
		_set_session_status_disconnected()
	else:
		logs.text += "Failed to stop session.\n"


## Set up connection to HEGo LogManager for capturing session logs
func _setup_log_capture():
	var log_manager = HEGoLogManager.get_singleton()
	if log_manager and not log_manager.log_message.is_connected(_on_log_received):
		log_manager.log_message.connect(_on_log_received)
	_update_session_status()


## Handle incoming log messages from HEGo LogManager
func _on_log_received(message: String, level: String):
	logs.text += message + "\n"
	# Update session status whenever we receive a log message
	call_deferred("_update_session_status")
	call_deferred("_scroll_to_bottom")


## Auto-scroll log display to bottom
func _scroll_to_bottom():
	logs.scroll_vertical = logs.get_line_count() * logs.get_theme_default_font().get_height()


## Update session status based on actual HEGoAPI session state
func _update_session_status():
	if HEGoAPI.get_singleton().is_session_active():
		_set_session_status_connected()
	else:
		_set_session_status_disconnected()


## Set session status indicator to connected (green)
func _set_session_status_connected():
	session_sync_status.text = "SessionSync is connected"
	session_sync_status.add_theme_color_override("default_color", Color.GREEN)
	# Refresh library control when session becomes active
	if library_control and library_control.has_method("refresh_all"):
		library_control.refresh_all()


## Set session status indicator to disconnected (red)
func _set_session_status_disconnected():
	session_sync_status.text = "SessionSync is not connected"
	session_sync_status.add_theme_color_override("default_color", Color.RED)
	# Clear library control when session becomes inactive
	if library_control and library_control.has_method("refresh_all"):
		library_control.refresh_all()
