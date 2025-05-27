@tool
extends Control

var root_control
var hego_tool_node: Node
var hego_asset_node: HEGoAssetNode

var auto_recook_toggle: CheckButton

var input_nodes: Array

# Called when the node enters the scene tree for the first time.
func _ready():
	root_control = $"../.."
	auto_recook_toggle = $HSplitContainer/Settings/VBoxContainer/VBoxContainer/CheckButton
	var recook_button = $HSplitContainer/Settings/VBoxContainer/VBoxContainer/ButtonRecook
	recook_button.button_down.connect(_on_recook_button_pressed)
	root_control.selected_hego_node_changed.connect(_on_selection_changed)
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass


func update_ui():
	var parm_vbox = $HSplitContainer/Parameters/VBoxContainer/Control/ScrollContainer/VBoxContainer
	var input_vbox = $HSplitContainer/Inputs/VBoxContainer/ScrollContainer/VBoxContainer
	
	hego_asset_node = hego_tool_node.hego_get_asset_node()
	if hego_asset_node != null:
		var parm_dict = hego_asset_node.get_parms_dict()
		if parm_dict and parm_dict.keys().size() != 0:
			for child in parm_vbox.get_children():
				child.queue_free()
			for key in parm_dict.keys():
				add_parm_ui(parm_dict[key], parm_vbox)
				
		var input_names = hego_asset_node.get_input_names()
		for child in input_vbox.get_children():
			child.queue_free()
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

func add_parm_ui(parm_dict: Dictionary, parent: Control):
	var parm_ui: Control = null

	if parm_dict["type"] == 0:
		match parm_dict["size"]:
			1:
				parm_ui = preload("res://addons/hego/parm_controls/int_parm_ui.tscn").instantiate()
			2:
				parm_ui = preload("res://addons/hego/parm_controls/int2_parm_ui.tscn").instantiate()
			3:
				parm_ui = preload("res://addons/hego/parm_controls/int3_parm_ui.tscn").instantiate()
			4:
				parm_ui = preload("res://addons/hego/parm_controls/int4_parm_ui.tscn").instantiate()

	elif parm_dict["type"] == 2:
		parm_ui = preload("res://addons/hego/parm_controls/toggle_parm_ui.tscn").instantiate()

	elif parm_dict["type"] == 3:
		parm_ui = preload("res://addons/hego/parm_controls/button_parm_ui.tscn").instantiate()

	elif parm_dict["type"] == 4:
		match parm_dict["size"]:
			1:
				parm_ui = preload("res://addons/hego/parm_controls/float_parm_ui.tscn").instantiate()
			2:
				parm_ui = preload("res://addons/hego/parm_controls/float2_parm_ui.tscn").instantiate()
			3:
				parm_ui = preload("res://addons/hego/parm_controls/float3_parm_ui.tscn").instantiate()
			4:
				parm_ui = preload("res://addons/hego/parm_controls/float4_parm_ui.tscn").instantiate()

	elif parm_dict["type"] == 6:
		parm_ui = preload("res://addons/hego/parm_controls/string_parm_ui.tscn").instantiate()

	elif parm_dict["type"] == 13:
		parm_ui = preload("res://addons/hego/parm_controls/folder_parm_ui.tscn").instantiate()
		parent.add_child(parm_ui)
		parm_ui.setup(parm_dict)
		if parm_ui.has_signal("value_changed"):
			parm_ui.value_changed.connect(_on_value_changed)
		for child in parm_dict["children"]:
			add_parm_ui(child, parm_ui.get_container())
		return

	# Common setup for all types except multiparms
	if parm_ui:
		parent.add_child(parm_ui)
		parm_ui.setup(parm_dict)
		if parm_ui.has_signal("value_changed"):
			parm_ui.value_changed.connect(_on_value_changed)
	
	# Setup for multiparms
	if parm_dict["type"] == 1:
		var multiparm_ui = preload("res://addons/hego/parm_controls/multiparm_parm_ui.tscn").instantiate()
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
			var multiparm_instance_ui = preload("res://addons/hego/parm_controls/multiparm_instance_parm_ui.tscn").instantiate()
			multiparm_instance_container.add_child(multiparm_instance_ui)
			multiparm_instance_ui.setup(i+instance_start_offset, id, label)
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


func _on_selection_changed(node:Node):
	hego_tool_node = node
	update_ui()
	
func _on_value_changed(name, value):
	hego_asset_node.set_parm(name, value)
	if auto_recook_toggle.button_pressed:
		recook()
	pass
	
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
	recook()
	update_ui()
		
func recook():
	if hego_tool_node.has_method("cook"):
		hego_tool_node.cook()
	if hego_tool_node.has_method("hego_set_parm_stash"):
		if not hego_asset_node:
			hego_asset_node = hego_tool_node.hego_get_asset_node()
		hego_tool_node.hego_set_parm_stash(hego_asset_node.get_preset())
	
	
