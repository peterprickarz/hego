@tool
extends LineEdit
class_name HEGoInputLineEdit

## A field in the panel's Inputs pane that a scene node can be dragged onto.
##
## Dropping a node writes its path relative to the edited scene, which is the form the input
## rows are stored in; typing a path by hand works the same way.

## Emitted when a node was dropped on the field, after [member text] has been rewritten.
signal input_changed()

## Unused. The dropped path is written straight to [member text], which is what the panel
## reads back.
var node_path = ""


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
