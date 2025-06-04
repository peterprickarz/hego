@tool
extends EditorPlugin

var bottom_panel
var import_plugin
var editor_selection: EditorSelection

const ImportPlugin = preload("hda_import_plugin.gd")


func _enter_tree():
	# Initialization of the plugin goes here.
	bottom_panel = preload("res://addons/hego/hego_control.tscn").instantiate()
	add_control_to_bottom_panel(bottom_panel, "HEGo")
	
	editor_selection = get_editor_interface().get_selection()
	editor_selection.selection_changed.connect(_on_selection_changed)
	
	import_plugin = ImportPlugin.new()
	add_import_plugin(import_plugin)

func _exit_tree():
	# Clean-up of the plugin goes here.
	
	if editor_selection and editor_selection.selection_changed.is_connected(_on_selection_changed):
		editor_selection.selection_changed.disconnect(_on_selection_changed)
	
	remove_import_plugin(import_plugin)
	import_plugin = null

func _on_selection_changed():
	var selected_nodes = editor_selection.get_selected_nodes()
	if selected_nodes.size() > 0:
		var selected_node = selected_nodes[0]
		if selected_node.has_method("hego_use_bottom_panel"):
			if selected_node.hego_use_bottom_panel():
				if bottom_panel:
					bottom_panel.update_hego_asset_node(selected_node)
