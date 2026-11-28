@tool
extends HBoxContainer

signal changed
signal remove_requested

var texture: Texture2D
var encoding := OptionButton.new()


func setup(initial_texture: Texture2D, initial_encoding: int) -> void:
	var picker: Control
	if ClassDB.can_instantiate(&"EditorResourcePicker"):
		picker = ClassDB.instantiate(&"EditorResourcePicker")
		picker.set("base_type", "Texture2D")
		picker.set("edited_resource", initial_texture)
		picker.connect("resource_changed", _on_resource_changed)
		picker.connect("resource_selected", _on_resource_selected)
	else:
		# A detached panel can also be opened by runtime tools or headless tests.
		var preview := TextureRect.new()
		preview.texture = initial_texture
		preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		picker = preview
	picker.name = "Picker"
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.tooltip_text = "Texture2D to send as a point referencing its Houdini COP."
	add_child(picker)
	_set_texture(initial_texture)

	encoding.name = "Encoding"
	encoding.add_item("Linear", HEGoTextureInputNode.ENCODING_LINEAR)
	encoding.add_item("sRGB", HEGoTextureInputNode.ENCODING_SRGB)
	encoding.select(encoding.get_item_index(initial_encoding))
	encoding.tooltip_text = "Use Linear for masks, normals and linear pixels. Use sRGB for color pixels that need decoding."
	encoding.item_selected.connect(func(_index: int):
		if texture:
			changed.emit()
	)
	add_child(encoding)

	var remove := Button.new()
	remove.name = "Remove"
	remove.text = "Remove"
	remove.tooltip_text = "Remove this texture from the input."
	remove.pressed.connect(func(): remove_requested.emit())
	add_child(remove)


func _set_texture(value: Texture2D) -> void:
	if texture and texture.changed.is_connected(_on_texture_changed):
		texture.changed.disconnect(_on_texture_changed)
	texture = value
	if texture:
		texture.changed.connect(_on_texture_changed)


func _on_resource_changed(resource: Resource) -> void:
	_set_texture(resource as Texture2D)
	changed.emit()


func _on_texture_changed() -> void:
	changed.emit()


func _on_resource_selected(resource: Resource, _inspect: bool) -> void:
	var editor := Engine.get_singleton("EditorInterface")
	if editor and resource:
		editor.edit_resource(resource)
