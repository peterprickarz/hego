## HDA Asset Picker Dialog
## Allows users to select HDA assets from cached libraries
@tool
extends AcceptDialog

signal asset_selected(asset_name: String)

@onready var asset_tree: Tree = %AssetTree
@onready var refresh_button: Button = %RefreshButton
@onready var selected_label: Label = $VBoxContainer/HBoxContainer/Label2
@onready var search_line_edit: LineEdit = $VBoxContainer/SearchLineEdit

var selected_asset: String = ""
var search_filter: String = ""
const CACHE_FILE_PATH = "res://hego_library.json"

func _ready():
	refresh_button.pressed.connect(_on_refresh_pressed)
	asset_tree.item_selected.connect(_on_asset_selected)
	asset_tree.item_activated.connect(_on_asset_activated)
	confirmed.connect(_on_confirmed)
	search_line_edit.text_changed.connect(_on_search_changed)
	
	_populate_tree()

func _load_cached_libraries() -> Dictionary:
	var cached_libraries = {}
	
	var file = FileAccess.open(CACHE_FILE_PATH, FileAccess.READ)
	if file:
		var json_string = file.get_as_text()
		file.close()
		
		var json = JSON.new()
		var parse_result = json.parse(json_string)
		if parse_result == OK:
			cached_libraries = json.get_data()
		else:
			print("[AssetPicker]: Failed to parse cached libraries JSON")
	else:
		print("[AssetPicker]: No cached libraries file found at: ", CACHE_FILE_PATH)
	
	return cached_libraries

func _fuzzy_match(text: String, pattern: String) -> bool:
	if pattern.is_empty():
		return true
	
	text = text.to_lower()
	pattern = pattern.to_lower()
	
	var text_index = 0
	var pattern_index = 0
	
	while text_index < text.length() and pattern_index < pattern.length():
		if text[text_index] == pattern[pattern_index]:
			pattern_index += 1
		text_index += 1
	
	return pattern_index == pattern.length()

func _on_search_changed(new_text: String):
	search_filter = new_text
	_populate_tree()

func _populate_tree():
	asset_tree.clear()
	var root = asset_tree.create_item()
	
	var cached_libraries = _load_cached_libraries()
	
	if cached_libraries.is_empty():
		var no_data_item = asset_tree.create_item(root)
		no_data_item.set_text(0, "No cached libraries found")
		no_data_item.set_selectable(0, false)
		return
	
	for library_name in cached_libraries.keys():
		var library_data = cached_libraries[library_name]
		var assets = library_data.get("assets", [])
		
		# Filter assets based on search
		var filtered_assets = []
		for asset_name in assets:
			if _fuzzy_match(asset_name, search_filter):
				filtered_assets.append(asset_name)
		
		# Only create library item if it has matching assets or no search filter
		if filtered_assets.size() > 0:
			var library_item = asset_tree.create_item(root)
			library_item.set_text(0, library_name + " (" + str(filtered_assets.size()) + " assets)")
			library_item.set_selectable(0, false)
			
			for asset_name in filtered_assets:
				var asset_item = asset_tree.create_item(library_item)
				asset_item.set_text(0, asset_name)
				asset_item.set_metadata(0, asset_name)

func _on_refresh_pressed():
	# Simply reload the tree from the JSON file
	_populate_tree()

func _on_asset_selected():
	var selected_item = asset_tree.get_selected()
	if selected_item and selected_item.get_metadata(0):
		selected_asset = selected_item.get_metadata(0)
		selected_label.text = "Selected: " + selected_asset
	else:
		selected_asset = ""
		selected_label.text = "Selected: None"

func _on_asset_activated():
	# Double-click to confirm
	if selected_asset != "":
		_on_confirmed()

func _on_confirmed():
	if selected_asset != "":
		asset_selected.emit(selected_asset)
		hide()

# Public method to show the dialog and return the selected asset
func pick_asset() -> String:
	_populate_tree()
	popup_centered()
	
	# Wait for the dialog to be closed
	await asset_selected
	return selected_asset

# Static method to easily show asset picker
static func show_asset_picker(parent: Node) -> String:
	var picker_scene = preload("res://addons/hego/ui/asset_picker_dialog.tscn")
	var picker = picker_scene.instantiate()
	parent.add_child(picker)
	
	var selected = await picker.pick_asset()
	picker.queue_free()
	return selected
