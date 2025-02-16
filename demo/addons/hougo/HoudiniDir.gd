@tool
extends LineEdit

# Check if the data being dragged is a NodePath
func _can_drop_data(position, data):
	print(data)
	return true

# Handle the drop data and set the text to the node path
func _drop_data(position, data):
	print("test3")
	if _can_drop_data(position, data):
		text = data

# Called when the node is added to the scene
func _ready():
	set_custom_minimum_size(Vector2(200, 24))  # Optional: Set a custom size for the LineEdit
