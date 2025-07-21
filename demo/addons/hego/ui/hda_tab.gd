@tool
extends Control

## Represents a Parm Type from Houdini
enum HEGoParmType {
	INT = 0,
	MULTIPARM = 1,
	TOGGLE = 2,
	BUTTON = 3,
	FLOAT = 4,
	STRING = 6,
	FOLDER = 13,
}

# These mappings are used to instantiate the correct UI controls for each parameter type.
const PARM_UI_SCENES = {
	HEGoParmType.INT: [
		preload("res://addons/hego/parm_controls/int_parm_ui.tscn"),
		preload("res://addons/hego/parm_controls/int2_parm_ui.tscn"),
		preload("res://addons/hego/parm_controls/int3_parm_ui.tscn"),
		preload("res://addons/hego/parm_controls/int4_parm_ui.tscn"),
	],
	HEGoParmType.TOGGLE: [preload("res://addons/hego/parm_controls/toggle_parm_ui.tscn")],
	HEGoParmType.BUTTON: [preload("res://addons/hego/parm_controls/button_parm_ui.tscn")],
	HEGoParmType.FLOAT: [
		preload("res://addons/hego/parm_controls/float_parm_ui.tscn"),
		preload("res://addons/hego/parm_controls/float2_parm_ui.tscn"),
		preload("res://addons/hego/parm_controls/float3_parm_ui.tscn"),
		preload("res://addons/hego/parm_controls/float4_parm_ui.tscn"),
	],
	HEGoParmType.STRING: [preload("res://addons/hego/parm_controls/string_parm_ui.tscn")],
	HEGoParmType.FOLDER: [preload("res://addons/hego/parm_controls/folder_parm_ui.tscn")],
	HEGoParmType.MULTIPARM: [
		preload("res://addons/hego/parm_controls/multiparm_parm_ui.tscn"),
		preload("res://addons/hego/parm_controls/multiparm_instance_parm_ui.tscn")
	]
}

var hego_tool_node: Node
var hego_asset_node: HEGoAssetNode
var input_nodes: Array
var allow_cook: bool = false
var new_preset_name_diag: ConfirmationDialog
var new_preset_name_line_edit: LineEdit

@onready var auto_recook_toggle: CheckButton = $HSplitContainer2/Settings/PanelContainer/VBoxContainer/VBoxContainer/CheckButton
@onready var auto_start_session_toggle: CheckButton = $HSplitContainer2/Settings/PanelContainer/VBoxContainer/HBoxContainer2/CheckButton
@onready var asset_picker_button: Button = $HSplitContainer2/Settings/PanelContainer/VBoxContainer/AssetPickerButton
@onready var recook_button: Button = $HSplitContainer2/Settings/PanelContainer/VBoxContainer/ButtonRecook
@onready var load_preset_button: Button = $HSplitContainer2/Settings/PanelContainer/VBoxContainer/MarginContainer/PanelContainer/VBoxContainer/HBoxContainer3/LoadPresetButton
@onready var save_preset_button: Button = $HSplitContainer2/Settings/PanelContainer/VBoxContainer/MarginContainer/PanelContainer/VBoxContainer/HBoxContainer3/SavePresetButton
@onready var new_preset_button: Button = $HSplitContainer2/Settings/PanelContainer/VBoxContainer/MarginContainer/PanelContainer/VBoxContainer/HBoxContainer3/NewPresetButton
@onready var preset_dropdown: OptionButton = $HSplitContainer2/Settings/PanelContainer/VBoxContainer/MarginContainer/PanelContainer/VBoxContainer/HBoxContainer/PresetDropdownOptionButton
@onready var parm_vbox = $HSplitContainer2/HSplitContainer3/Parameters/PanelContainer/VBoxContainer/Control/ScrollContainer/VBoxContainer
@onready var input_vbox = $HSplitContainer2/HSplitContainer3/Inputs/PanelContainer/VBoxContainer/ScrollContainer/VBoxContainer


func _ready():
	new_preset_name_diag = preload("res://addons/hego/ui/new_preset_name_diag.tscn").instantiate()
	new_preset_name_line_edit = new_preset_name_diag.get_node("%LineEdit")
	add_child(new_preset_name_diag)
	recook_button.button_down.connect(_on_recook_button_pressed)
	asset_picker_button.pressed.connect(_on_asset_picker_button_pressed)
	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
	new_preset_button.pressed.connect(_on_new_preset_button_pressed)
	new_preset_name_diag.confirmed.connect(_on_preset_dialog_confirmed)
	load_preset_button.pressed.connect(_on_load_preset_button_pressed)
	save_preset_button.pressed.connect(_on_save_preset_button_pressed)
	_set_buttons_disabled(true)


func _set_buttons_disabled(disabled: bool):
	recook_button.disabled = disabled
	asset_picker_button.disabled = disabled
	load_preset_button.disabled = disabled
	save_preset_button.disabled = disabled
	new_preset_button.disabled = disabled


func _on_new_preset_button_pressed():
	new_preset_name_diag.dialog_text = "Please enter a name for the preset:"
	new_preset_name_line_edit.text = ""
	new_preset_name_line_edit.placeholder_text = "Preset Name"
	new_preset_name_diag.popup_centered()
	new_preset_name_line_edit.grab_focus()


func _on_preset_dialog_confirmed():
	var preset_name = new_preset_name_line_edit.text.strip_edges()
	if preset_name != "":
		create_preset_file(preset_name)
	else:
		print("No preset name entered")


func update_ui():
	if allow_cook:
		_set_buttons_disabled(false)
	else:
		return _set_buttons_disabled(true)

	for child in parm_vbox.get_children():
		child.queue_free()
	for child in input_vbox.get_children():
			child.queue_free()
	hego_asset_node = hego_tool_node.hego_get_asset_node()
	if hego_asset_node != null:
		var parm_dict = hego_asset_node.get_parms_dict()
		
		if parm_dict and parm_dict.keys().size() != 0:
			for key in parm_dict.keys():
				add_parm_ui(parm_dict[key], parm_vbox)
				
		var input_names = hego_asset_node.get_input_names()
		
		input_nodes = Array()
		for i in range(input_names.size()):
			var input_node = preload("res://addons/hego/ui/input_ui.tscn").instantiate()
			input_vbox.add_child(input_node)
			var inputs = PackedStringArray()
			if hego_tool_node.has_method("hego_get_input_stash"):
				var input_stash = hego_tool_node.hego_get_input_stash()
				if input_stash.size() > i:
					inputs = input_stash[i]["inputs"]
			input_node.setup(input_names[i], inputs)
			input_node.inputs_changed.connect(_on_input_changed)
			input_nodes.append(input_node)
	else:
		var hint_label = Label.new()
		hint_label.text = "HDA not instantiated. Recook to see parameters!"
		parm_vbox.add_child(hint_label)
	update_preset_dropdown()


func add_parm_ui(parm_dict: Dictionary, parent: Control):
	var parm_type = parm_dict["type"]
	
	# Handle special cases that need custom logic
	if parm_type == HEGoParmType.FOLDER:
		_handle_folder_parm(parm_dict, parent)
		return
	elif parm_type == HEGoParmType.MULTIPARM:
		_handle_multiparm_parm(parm_dict, parent)
		return
	
	# Handle regular parameters using mapping
	var parm_ui = _create_parm_ui(parm_type, parm_dict.get("size", 1))
	if parm_ui:
		_setup_common_parm(parm_ui, parm_dict, parent)


func _create_parm_ui(parm_type: int, size: int) -> Control:
	if not parm_type in PARM_UI_SCENES:
		return null
		
	var scenes = PARM_UI_SCENES[parm_type]
	var scene_index = 0
	
	# For types with size-based variants (INT, FLOAT), select based on size
	if parm_type in [HEGoParmType.INT, HEGoParmType.FLOAT]:
		scene_index = max(0, min(size - 1, scenes.size() - 1))
	
	return scenes[scene_index].instantiate()


func _setup_common_parm(parm_ui: Control, parm_dict: Dictionary, parent: Control):
	parent.add_child(parm_ui)
	parm_ui.setup(parm_dict)
	if parm_ui.has_signal("value_changed"):
		parm_ui.value_changed.connect(_on_value_changed)


func _handle_folder_parm(parm_dict: Dictionary, parent: Control):
	var parm_ui = PARM_UI_SCENES[HEGoParmType.FOLDER][0].instantiate()
	parent.add_child(parm_ui)
	parm_ui.setup(parm_dict)
	if parm_ui.has_signal("value_changed"):
		parm_ui.value_changed.connect(_on_value_changed)
	for child in parm_dict["children"]:
		add_parm_ui(child, parm_ui.get_container())


func _handle_multiparm_parm(parm_dict: Dictionary, parent: Control):
	var multiparm_ui = PARM_UI_SCENES[HEGoParmType.MULTIPARM][0].instantiate()
	parent.add_child(multiparm_ui)
	multiparm_ui.setup(parm_dict)
	multiparm_ui.instance_count_changed.connect(_on_multiparm_instance_count_changed)
	var multiparm_instance_container = multiparm_ui.get_instance_container()
	var instance_containers = Array()
	var instance_start_offset = parm_dict["instance_start_offset"]
	if instance_start_offset == 1:
		instance_containers.append(null)
	for i in range(parm_dict["instance_count"]):
		var label = parm_dict["label"]
		var id = parm_dict["id"]
		var multiparm_instance_ui = PARM_UI_SCENES[HEGoParmType.MULTIPARM][1].instantiate()
		multiparm_instance_container.add_child(multiparm_instance_ui)
		multiparm_instance_ui.setup(i + instance_start_offset, id, label)
		var instance_parm_container = multiparm_instance_ui.get_container()
		instance_containers.append(instance_parm_container)
		multiparm_instance_ui.insert_instance.connect(_on_insert_multiparm_instance)
		multiparm_instance_ui.remove_instance.connect(_on_remove_multiparm_instance)
	for instance in parm_dict["instances"]:
		for instance_parm_dict in instance:
			var instance_index = instance_parm_dict["instance_num"]
			add_parm_ui(instance_parm_dict, instance_containers[instance_index])
			
			
func _on_multiparm_instance_count_changed(value: int, parm_dict: Dictionary):
	hego_asset_node.set_parm(parm_dict["name"], value)
	update_ui()
	

func _on_insert_multiparm_instance(id: int, index: int):
	hego_asset_node.insert_multiparm_instance(id, index)
	update_ui()
	

func _on_remove_multiparm_instance(id: int, index: int):
	hego_asset_node.remove_multiparm_instance(id, index)
	update_ui()


func _on_selection_changed():
	# These are the only nodes that can be cooked by the HEGo HDA Tab
	var nodes = EditorInterface.get_selection().get_selected_nodes()
	if nodes.size() == 0:
		_set_buttons_disabled(true)
		return
	var node = nodes[0]
	allow_cook = node is HEGoNode3D
	hego_tool_node = node
	update_ui()
	

func _on_value_changed(name, value):
	hego_asset_node.set_parm(name, value)
	if auto_recook_toggle.button_pressed:
		recook()
	

func _on_input_changed():
	var inputs = Array()
	for input_node in input_nodes:
		var input_node_inputs = input_node.get_inputs()
		var input_node_settings = Dictionary()
		var inputs_dict = Dictionary()
		inputs_dict["inputs"] = input_node_inputs
		inputs_dict["settings"] = input_node_settings
		inputs.append(inputs_dict)
	if hego_tool_node.has_method("hego_set_input_stash"):
		hego_tool_node.hego_set_input_stash(inputs)
	if auto_recook_toggle.button_pressed:
		recook()
	

func _on_recook_button_pressed():
	if auto_start_session_toggle.button_pressed:
		HEGoAPI.get_singleton().start_session(2, 'hapi')
	recook()
	var preset_index = preset_dropdown.get_selected_id()
	update_ui()
	preset_dropdown.select(preset_index)
		
		
func recook():
	if hego_tool_node.has_method("cook"):
		hego_tool_node.cook()
	if hego_tool_node.has_method("hego_set_parm_stash"):
		if not hego_asset_node:
			hego_asset_node = hego_tool_node.hego_get_asset_node()
		hego_tool_node.hego_set_parm_stash(hego_asset_node.get_preset())
		

func create_preset_file(preset_name: String) -> void:
	print("[HEGo]: Creating preset")
	if hego_asset_node and hego_tool_node.has_method("hego_get_asset_name"):
		var preset = hego_asset_node.get_preset()
		if preset:
			var asset_name = hego_tool_node.hego_get_asset_name()
			var res_path = "res://hego/presets/" + asset_name + ".tres"
			
			# Ensure directory exists
			var dir = DirAccess.open("res://")
			var asset_dir = asset_name.get_base_dir()
			if asset_dir != "":
				var preset_dir = "hego/presets/" + asset_dir
				if not dir.dir_exists(preset_dir):
					dir.make_dir_recursive(preset_dir)

			var presets_res: HEGoHDAPreset
			# Check if the resource exists
			if ResourceLoader.exists(res_path):
				print("[HEGo]: Adding preset to existing file at " + res_path)
				# Load existing resource
				presets_res = ResourceLoader.load(res_path)
				# Verify the resource is of type HEGoHDAPreset
				if presets_res is HEGoHDAPreset:
					# Check if preset_name already exists in presets dictionary
					if preset_name in presets_res.presets.keys():
						push_error("[HEGo]: Preset with this name already exists, aborting. Select the preset and save instead, or give a different name!")
						return
				else:
					push_error("[HEGo]: Failed to save preset. A file exists at the path, but it's not of type HEGoHDAPreset")
					return
			else:
				print("[HEGo]: Creating new preset file at " + res_path)
				# Create a new HEGoHDAPreset resource
				presets_res = HEGoHDAPreset.new()
				presets_res.presets = {} # Initialize the presets dictionary
			# Add the new preset to the presets dictionary
			presets_res.presets[preset_name] = preset
			# Save the resource to the specified path
			var error = ResourceSaver.save(presets_res, res_path)
			if error == OK:
				print("[HEGo]: Preset saved successfully")
				# Update UI to refresh dropdown
				update_ui()
				# Select the newly created preset in the dropdown
				_select_preset_in_dropdown(preset_name)
			else:
				print("[HEGo]: Failed to save preset. Error code: ", error)
		else:
			push_error("[HEGo]: Failed to retrieve parms from Houdini - Perhaps the node is not instantiated correctly?")
	else:
		push_error("[HEGo]: Invalid hego_asset_node or hego_tool_node. Cannot create preset.")
	
	
func update_preset_dropdown():
	if hego_tool_node and hego_tool_node.has_method("hego_get_asset_name"):
		var asset_name = hego_tool_node.hego_get_asset_name()
		var res_path = "res://hego/presets/" + asset_name + ".tres"
		
		# Clear existing items in the dropdown
		preset_dropdown.clear()
		
		# Add a default item
		preset_dropdown.add_item("Select Preset")
		preset_dropdown.set_item_disabled(0, true)
		
		# Check if the resource exists and is a HEGoHDAPreset
		if ResourceLoader.exists(res_path):
			var presets_res = ResourceLoader.load(res_path)
			if presets_res is HEGoHDAPreset and presets_res.presets is Dictionary:
				# Add each preset name to the dropdown
				for preset_name in presets_res.presets.keys():
					preset_dropdown.add_item(preset_name)
			else:
				print("[HEGo]: No valid HEGoHDAPreset at ", res_path)
	else:
		# Clear dropdown if no valid tool node
		preset_dropdown.clear()
		preset_dropdown.add_item("No Asset Selected")
		preset_dropdown.set_item_disabled(0, true)
		
func _on_load_preset_button_pressed():
	print("load preset")
	
	# Early validation checks
	if not hego_asset_node or not hego_tool_node or not hego_tool_node.has_method("hego_get_asset_name"):
		push_error("[HEGo]: Invalid hego_asset_node or hego_tool_node. Cannot load preset.")
		return
	
	var selected_index = preset_dropdown.get_selected()
	if selected_index <= 0:
		push_error("[HEGo]: No valid preset selected")
		return
	
	var preset_name = preset_dropdown.get_item_text(selected_index)
	var asset_name = hego_tool_node.hego_get_asset_name()
	var res_path = "res://hego/presets/" + asset_name + ".tres"
	
	if not ResourceLoader.exists(res_path):
		push_error("[HEGo]: No preset resource found at ", res_path)
		return
	
	var presets_res = ResourceLoader.load(res_path)
	if not (presets_res is HEGoHDAPreset and presets_res.presets is Dictionary):
		push_error("[HEGo]: Failed to load preset. Resource at ", res_path, " is not a valid HEGoHDAPreset")
		return
	
	if not preset_name in presets_res.presets:
		push_error("[HEGo]: Selected preset '", preset_name, "' not found in resource")
		return
	
	# Load and apply the preset
	hego_asset_node.set_preset(presets_res.presets[preset_name])
	print("[HEGo]: Loaded preset: ", preset_name)
	update_ui()
	
	# Reselect the loaded preset in the dropdown
	_select_preset_in_dropdown(preset_name)
		
func _on_save_preset_button_pressed():
	print("save preset")
	
	# Early validation checks
	if not hego_asset_node or not hego_tool_node or not hego_tool_node.has_method("hego_get_asset_name"):
		push_error("[HEGo]: Invalid hego_asset_node or hego_tool_node. Cannot save preset.")
		return
	
	var selected_index = preset_dropdown.get_selected()
	if selected_index <= 0:
		push_error("[HEGo]: No valid preset selected")
		return
	
	var preset_name = preset_dropdown.get_item_text(selected_index)
	var asset_name = hego_tool_node.hego_get_asset_name()
	var res_path = "res://hego/presets/" + asset_name + ".tres"
	
	var preset = hego_asset_node.get_preset()
	if not preset:
		push_error("[HEGo]: Failed to retrieve parms from Houdini - Perhaps the node is not instantiated correctly?")
		return
	
	if not ResourceLoader.exists(res_path):
		push_error("[HEGo]: No preset resource found at ", res_path)
		return
	
	var presets_res = ResourceLoader.load(res_path)
	if not (presets_res is HEGoHDAPreset and presets_res.presets is Dictionary):
		push_error("[HEGo]: Failed to save preset. Resource at ", res_path, " is not a valid HEGoHDAPreset")
		return
	
	if not preset_name in presets_res.presets:
		push_error("[HEGo]: Selected preset '", preset_name, "' not found in resource")
		return
	
	# Save the preset
	presets_res.presets[preset_name] = preset
	var error = ResourceSaver.save(presets_res, res_path)
	if error != OK:
		push_error("[HEGo]: Failed to save preset '", preset_name, "'. Error code: ", error)
		return
	
	print("[HEGo]: Preset '", preset_name, "' saved successfully")
	update_ui()
	
	# Reselect the saved preset in the dropdown
	_select_preset_in_dropdown(preset_name)

# Helper function to select a preset in the dropdown by name
func _select_preset_in_dropdown(preset_name: String) -> void:
	for i in range(preset_dropdown.get_item_count()):
		if preset_dropdown.get_item_text(i) == preset_name:
			preset_dropdown.select(i)
			break

# Handle asset picker button press
func _on_asset_picker_button_pressed():
	if not hego_tool_node or not hego_tool_node is HEGoNode3D:
		push_error("[HEGo]: No HEGoNode3D selected. Please select a HEGoNode3D first.")
		return
	
	# Load the asset picker dialog
	var picker_scene = preload("res://addons/hego/ui/asset_picker_dialog.tscn")
	var picker = picker_scene.instantiate()
	add_child(picker)
	
	# Show the picker and wait for selection
	picker.asset_selected.connect(_on_asset_picked)
	picker.popup_centered()

# Handle asset selection from picker
func _on_asset_picked(asset_name: String):
	if hego_tool_node and hego_tool_node is HEGoNode3D:
		# Clear old HDA data before setting new asset
		if hego_tool_node.has_method("_clear_hda_data"):
			hego_tool_node._clear_hda_data()
		
		hego_tool_node.asset_name = asset_name
		print("[HEGo]: Set asset_name to: ", asset_name)
		
		# Optionally auto-recook if enabled
		if auto_recook_toggle.button_pressed:
			recook()
