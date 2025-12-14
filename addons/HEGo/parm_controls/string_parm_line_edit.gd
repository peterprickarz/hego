@tool
extends LineEdit


# Called when the node enters the scene tree for the first time.
func _ready():
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass

func _can_drop_data(position: Vector2, data) -> bool:
	if data is Dictionary and data.has("nodes") and data["nodes"] is Array and data["nodes"].size() > 0:
		return true
	if data is Dictionary and data.has("files") and data["files"] is PackedStringArray and data["files"].size() > 0:
		return true
	return false

func _drop_data(position: Vector2, data) -> void:
	if data.has("nodes"):
		var node = get_node_or_null(data["nodes"][0])
		if node is Node:
			var scene_root = get_tree().edited_scene_root
			if scene_root:
				var node_path = scene_root.get_path_to(node)
				text = str(node)
			else:
				text = "Error: No scene root"
		else:
			text = "Error: Invalid node path"
	
		text_changed.emit(text)
	if data.has("files"):
		print("data has files")
		var file = data["files"][0]
		text = file
		text_changed.emit(text)
