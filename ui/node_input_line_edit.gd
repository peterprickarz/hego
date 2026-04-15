@tool
extends LineEdit
class_name HEGoInputLineEdit

signal input_changed()

var node_path = ""

# Called when the node is ready
func _ready():
	pass
	# Ensure the LineEdit can receive drop events

func _can_drop_data(position: Vector2, data) -> bool:
	if data is Dictionary and data.has("nodes") and data["nodes"] is Array and data["nodes"].size() > 0:
		return true
	return false

func _drop_data(position: Vector2, data) -> void:
	var node = get_node_or_null(data["nodes"][0])
	if node is Node:
		var scene_root = get_tree().edited_scene_root
		if scene_root:
			var node_path = scene_root.get_path_to(node)
			text = str(node_path)
		else:
			text = "Error: No scene root"
	else:
		text = "Error: Invalid node path"
	input_changed.emit()
