@tool
extends VBoxContainer

signal inputs_changed(inputs: PackedStringArray)

@onready var spin_box = $HBoxContainer/SpinBox
@onready var input_container = $InputContainer
@onready var label = $HBoxContainer/Label

# Called when the node enters the scene tree for the first time.
func _ready():
	spin_box.value_changed.connect(_on_spin_box_value_changed)
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass

func setup(in_label: String, inputs: PackedStringArray):
	label.text = in_label
	spin_box.value = inputs.size()
	_on_spin_box_value_changed(inputs.size())
	var input_lines = input_container.get_children()
	for i in range(inputs.size()):
		input_lines[i].text = inputs[i]
	pass

func _on_spin_box_value_changed(value: float):
	var lines = input_container.get_children()
	if lines.size() > value:
		for i in range(lines.size()-value):
			lines[i+value].free()
	if lines.size()<value:
		var new_line = HEGoInputLineEdit.new()
		input_container.add_child(new_line)
		new_line.input_changed.connect(_on_input_line_value_changed)
	inputs_changed.emit()

func _on_input_line_value_changed():
	inputs_changed.emit()
	
func get_inputs():
	var inputs = PackedStringArray()
	for child in input_container.get_children():
		inputs.append(child.text)
	return inputs
