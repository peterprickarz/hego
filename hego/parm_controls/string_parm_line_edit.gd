@tool
extends LineEdit


## Ordinary string parameters accept Godot scene-relative node paths and resource paths.
## File parameters instead require a path readable by the Houdini process.
signal dropped(value: String)
var filesystem_path := false

func _can_drop_data(position: Vector2, data) -> bool:
	if not editable:
		return false
	if not filesystem_path and data is Dictionary and data.has("nodes") and data["nodes"] is Array and data["nodes"].size() > 0:
		return true
	if data is Dictionary and data.has("files") and data["files"] is PackedStringArray and data["files"].size() > 0:
		return true
	return false

func _drop_data(position: Vector2, data) -> void:
	if not _can_drop_data(position, data):
		return
	if data.has("nodes"):
		var node = get_node_or_null(data["nodes"][0])
		var scene_root := get_tree().edited_scene_root
		if node == null or scene_root == null:
			return
		text = str(scene_root.get_path_to(node))
	else:
		var path: String = data["files"][0]
		text = ProjectSettings.globalize_path(path) if filesystem_path else path
	text_changed.emit(text)
	dropped.emit(text)
