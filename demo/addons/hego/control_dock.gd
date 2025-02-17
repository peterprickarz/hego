@tool
extends Control


# Called when the node enters the scene tree for the first time.
func _ready():
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass




func _on_start_session_pressed():
	HEGoAPI.get_singleton().start_session()
	pass


func _on_stop_session_pressed():
	HEGoAPI.get_singleton().stop_session()
	pass # Replace with function body.


func _on_houdini_dir_file_picker_pressed():
	$FileDialog.popup_centered()
	pass # Replace with function body.


func _on_file_dialog_dir_selected(dir):
	$VBoxContainer/HBoxContainer/HoudiniDir.text = dir
	pass # Replace with function body.


func _on_line_edit_text_changed(line_edit: LineEdit, new_text: String) -> void:
	print("Text changed in LineEdit: ", line_edit.name, " to: ", new_text)

func _on_button_pressed():
	var line_edit = LineEdit.new()
	# Set some properties (optional)
	line_edit.placeholder_text = "Enter text here..."
	line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line_edit.text_changed.connect(func(new_text: String) -> void:
			_on_line_edit_text_changed(line_edit, new_text)
	)
	$VBoxContainer.add_child(line_edit)
	pass # Replace with function body.
