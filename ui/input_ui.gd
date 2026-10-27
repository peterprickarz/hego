@tool
extends VBoxContainer

signal inputs_changed(inputs: PackedStringArray)

@onready var spin_box = $HBoxContainer/SpinBox
@onready var input_container = $InputContainer
@onready var label = $HBoxContainer/Label

# Called when the node enters the scene tree for the first time.
func _ready():
	spin_box.value_changed.connect(_on_spin_box_value_changed)


## Shows [param in_label] with one line per entry in [param inputs].
func setup(in_label: String, inputs: PackedStringArray):
	label.text = in_label
	# Assigning the value only emits when it actually changes, so rebuild explicitly
	# as well; _on_spin_box_value_changed is idempotent.
	spin_box.value = inputs.size()
	_on_spin_box_value_changed(inputs.size())

	var input_lines := input_container.get_children()
	for i in range(mini(inputs.size(), input_lines.size())):
		input_lines[i].text = inputs[i]


## Brings the number of input lines in line with the spin box.
func _on_spin_box_value_changed(value: float):
	var wanted := maxi(int(value), 0)
	var lines := input_container.get_children()
	var current := lines.size()

	# Drop the extras from the end.
	for i in range(wanted, current):
		lines[i].free()

	# Add every missing line, not just one: an input wired to several nodes needs
	# one line per node, and adding a single line per call left the rest missing.
	for i in range(current, wanted):
		var new_line := HEGoInputLineEdit.new()
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
