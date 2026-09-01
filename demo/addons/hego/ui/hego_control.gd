## HEGo session control provides UI for starting/stopping HEGo sessions, monitoring connection
## status, and displaying session logs.
##
## The log view reads [HEGoLog]'s in-memory buffer on a timer and appends only what
## arrived since the last tick, so a chatty cook costs a handful of appends per
## second instead of one full-document rebuild per message.
@tool
extends Control

signal selected_hego_node_changed(node: Node)

## How often the log view picks up new entries.
const LOG_POLL_INTERVAL := 0.25

## Lines kept in the view. Older ones are dropped; the full buffer is still in
## HEGoLog and lands in the log file when file logging is on.
const MAX_VISIBLE_LINES := 500

## Colour per level, keyed by HEGoLog.LEVEL_* value (TRACE 0 ... ERROR 4).
## Spelled numerically because a const cannot reference another class's constants.
const LEVEL_COLORS := {
	0: "808080", # TRACE
	1: "8fbcbb", # DEBUG
	2: "d8dee9", # INFO
	3: "ebcb8b", # WARNING
	4: "bf616a", # ERROR
}

const ALL_CATEGORIES := "All categories"

@onready var start_button: Button = %Session/%ButtonStartSession
@onready var stop_button: Button = %Session/%ButtonStopSession
@onready var connection_type: OptionButton = %Session/%ConnectionType
@onready var connection_data: TextEdit = %Session/%ConnectionData
@onready var session_sync_status: RichTextLabel = %Session/%SessionSyncStatusLabel
@onready var logs: RichTextLabel = %Session/%Logs
@onready var log_toolbar: HBoxContainer = %Session/%LogToolbar
@onready var library_control: Control = $TabContainer/Library

var hego_tool_node: Node

var _log_cursor: int = 0
var _visible_lines: int = 0
var _level_filter: OptionButton
var _category_filter: OptionButton
var _known_categories: PackedStringArray


## Initialize the control and set up connections
func _ready():
	start_button.pressed.connect(_on_start_session_button_pressed)
	stop_button.pressed.connect(_on_stop_session_button_pressed)
	_build_log_toolbar()
	# Defer log capture setup to ensure the HEGoLog singleton is fully initialized
	call_deferred("_setup_log_capture")


func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		# Emergency cleanup when control is being destroyed
		if HEGoAPI.get_singleton() and HEGoAPI.get_singleton().is_session_active():
			HEGoLog.get_singleton().info("session", "Control cleanup - stopping active session")
			HEGoAPI.get_singleton().stop_session()


## Update the currently selected HEGo asset node
func update_hego_asset_node(node: Node):
	hego_tool_node = node
	selected_hego_node_changed.emit(node)


# ─────────────────────────────────────────────
# Session
# ─────────────────────────────────────────────

## Handle start session button press - stops current session and starts new one
func _on_start_session_button_pressed():
	var connection_type_id = connection_type.selected
	var connection_data_text = connection_data.text
	var log := HEGoLog.get_singleton()

	log.info("session", "Starting session (type: %s, data: %s)" % [connection_type.get_item_text(connection_type_id), connection_data_text])

	await get_tree().process_frame
	var stop_success = HEGoAPI.get_singleton().stop_session()
	log.debug("session", "Stopped previous session: " + ("success" if stop_success else "nothing to stop"))

	await get_tree().process_frame

	# Map UI connection type to HEGoAPI.SessionType (the UI is 0-based, the enum 1-based).
	var session_type = connection_type_id + 1
	if HEGoAPI.get_singleton().start_session(session_type, connection_data_text):
		log.info("session", "Session started successfully.")
		_set_session_status_connected()
	else:
		log.error("session", "Session failed to start.")
		_set_session_status_disconnected()


## Handle stop session button press
func _on_stop_session_button_pressed():
	var log := HEGoLog.get_singleton()
	if HEGoAPI.get_singleton().stop_session():
		log.info("session", "Session stopped.")
	else:
		log.error("session", "Failed to stop session.")
	_set_session_status_disconnected()


## Update session status based on actual HEGoAPI session state.
##
## Only called on session start/stop and when the panel opens: it asks Houdini
## whether the session is alive, which is a round trip and must not be done per
## log line.
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


# ─────────────────────────────────────────────
# Log view
# ─────────────────────────────────────────────

## Builds the filter and action controls above the log view.
func _build_log_toolbar() -> void:
	_level_filter = OptionButton.new()
	_level_filter.tooltip_text = "Lowest level shown in this view"
	for level in [HEGoLog.LEVEL_TRACE, HEGoLog.LEVEL_DEBUG, HEGoLog.LEVEL_INFO, HEGoLog.LEVEL_WARNING, HEGoLog.LEVEL_ERROR]:
		_level_filter.add_item(HEGoLog.level_name(level), level)
	_level_filter.select(_level_filter.get_item_index(HEGoLog.LEVEL_DEBUG))
	_level_filter.item_selected.connect(func(_index): _rebuild_log_view())
	log_toolbar.add_child(_level_filter)

	_category_filter = OptionButton.new()
	_category_filter.tooltip_text = "Subsystem shown in this view"
	_category_filter.add_item(ALL_CATEGORIES)
	_category_filter.item_selected.connect(func(_index): _rebuild_log_view())
	log_toolbar.add_child(_category_filter)

	log_toolbar.add_child(_make_toolbar_button("Clear", _on_clear_log_pressed))
	log_toolbar.add_child(_make_toolbar_button("Save log...", _on_save_log_pressed))


func _make_toolbar_button(text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(handler)
	return button


## Start polling the log buffer and sync the session status once.
func _setup_log_capture():
	var timer := Timer.new()
	timer.wait_time = LOG_POLL_INTERVAL
	timer.timeout.connect(_poll_log)
	add_child(timer)
	timer.start()

	_rebuild_log_view()
	_update_session_status()


## Appends whatever has been logged since the last tick.
func _poll_log() -> void:
	var log := HEGoLog.get_singleton()
	if log == null:
		return

	# Entries logged from the scheduler thread are only printed to the Godot output
	# on the main thread, so give the logger a chance to do that here as well.
	log.flush()

	var entries: Array = log.get_entries_since(_log_cursor, _selected_level())
	_log_cursor = log.get_cursor()
	if entries.is_empty():
		return

	for entry in entries:
		_append_entry(entry)
	_trim_log_view()
	_refresh_category_filter()


## Re-reads the whole buffer, for when a filter changes.
func _rebuild_log_view() -> void:
	var log := HEGoLog.get_singleton()
	if log == null:
		return

	logs.clear()
	_visible_lines = 0
	for entry in log.get_entries_since(0, _selected_level()):
		_append_entry(entry)
	_log_cursor = log.get_cursor()
	_trim_log_view()
	_refresh_category_filter()


func _append_entry(entry: Dictionary) -> void:
	var category := str(entry["category"])
	var selected_category := _selected_category()
	if selected_category != ALL_CATEGORIES and category != selected_category:
		return

	var color: String = LEVEL_COLORS.get(int(entry["level"]), "d8dee9")
	logs.append_text(
		"[color=#707070]%s[/color] [color=#%s]%-7s[/color] [color=#707070]%s[/color]  %s\n"
		% [entry["time"], color, entry["level_name"], category, str(entry["message"]).replace("[", "[lb]")]
	)
	_visible_lines += 1


## Drops the oldest lines once the view grows past its cap.
func _trim_log_view() -> void:
	while _visible_lines > MAX_VISIBLE_LINES:
		logs.remove_paragraph(0)
		_visible_lines -= 1


func _selected_level() -> int:
	if _level_filter == null:
		return HEGoLog.LEVEL_DEBUG
	return _level_filter.get_item_id(_level_filter.selected)


func _selected_category() -> String:
	if _category_filter == null or _category_filter.selected < 0:
		return ALL_CATEGORIES
	return _category_filter.get_item_text(_category_filter.selected)


## Adds newly seen categories to the filter, keeping the current selection.
func _refresh_category_filter() -> void:
	var categories := HEGoLog.get_singleton().get_categories()
	if categories == _known_categories:
		return
	_known_categories = categories

	var selected := _selected_category()
	_category_filter.clear()
	_category_filter.add_item(ALL_CATEGORIES)
	for category in categories:
		_category_filter.add_item(category)

	for i in range(_category_filter.item_count):
		if _category_filter.get_item_text(i) == selected:
			_category_filter.select(i)
			return
	_category_filter.select(0)


func _on_clear_log_pressed() -> void:
	HEGoLog.get_singleton().clear()
	logs.clear()
	_visible_lines = 0
	_log_cursor = HEGoLog.get_singleton().get_cursor()


func _on_save_log_pressed() -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.current_file = "hego_session.log"
	dialog.add_filter("*.log ; Log files")
	dialog.add_filter("*.txt ; Text files")
	dialog.file_selected.connect(_on_save_log_path_selected)
	dialog.close_requested.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)


func _on_save_log_path_selected(path: String) -> void:
	var log := HEGoLog.get_singleton()
	if log.save_to_file(path):
		log.info("session", "Saved session log to " + path)
	else:
		log.error("session", "Could not write session log to " + path)
