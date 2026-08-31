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
	
	# Add HEGo project settings
	_add_project_settings()


func _exit_tree():
	# Clean-up of the plugin goes here.
	print("[HEGo]: Plugin exiting, cleaning up Houdini session...")
	
	# Stop any active Houdini session
	_cleanup_houdini_session()
	
	if editor_selection and editor_selection.selection_changed.is_connected(_on_selection_changed):
		editor_selection.selection_changed.disconnect(_on_selection_changed)
	
	remove_import_plugin(import_plugin)
	import_plugin = null
	
	# Remove bottom panel
	if bottom_panel:
		remove_control_from_bottom_panel(bottom_panel)
		bottom_panel = null
	
	print("[HEGo]: Plugin cleanup completed")


func _cleanup_houdini_session():
	if HEGoAPI.get_singleton() and HEGoAPI.get_singleton().is_session_active():
		print("[HEGo]: Stopping active Houdini session...")
		var stop_success = HEGoAPI.get_singleton().stop_session()
		if stop_success:
			print("[HEGo]: Houdini session stopped successfully")
		else:
			print("[HEGo]: Warning: Failed to stop Houdini session")


func _on_selection_changed():
	var selected_nodes = editor_selection.get_selected_nodes()
	if selected_nodes.size() > 0:
		var selected_node = selected_nodes[0]
		if selected_node.has_method("hego_use_bottom_panel"):
			if selected_node.hego_use_bottom_panel():
				if bottom_panel:
					bottom_panel.update_hego_asset_node(selected_node)


func _add_project_settings():
	# Add Houdini installation path setting if it doesn't exist
	var setting_name = "hego/houdini_installation_path"
	if not ProjectSettings.has_setting(setting_name):
		ProjectSettings.set_setting(setting_name, _default_houdini_path())

		# Set up property info for better UI in project settings
		var property_info = {
			"name": setting_name,
			"type": TYPE_STRING,
			"hint": PROPERTY_HINT_GLOBAL_DIR,
			"hint_string": ""
		}
		ProjectSettings.add_property_info(property_info)

		# Save the project settings
		ProjectSettings.save()

	# The setting is stored in project.godot, so a project set up on another OS
	# carries that machine's path. Point it out instead of letting the session fail
	# with a path that cannot exist here.
	var configured_path = str(ProjectSettings.get_setting(setting_name, ""))
	if not configured_path.is_empty() and not DirAccess.dir_exists_absolute(configured_path):
		push_warning(
			"[HEGo]: Houdini installation path '%s' does not exist. Set 'hego/houdini_installation_path' in Project Settings (%s expects something like '%s')."
			% [configured_path, OS.get_name(), _default_houdini_path()]
		)


## Stock install location of the Houdini version HEGo is built against.
## Kept in sync with SConstruct's default_hfs and HEGoPlatform::get_default_houdini_path().
func _default_houdini_path() -> String:
	match OS.get_name():
		"Linux":
			return "/opt/hfs22.0.368"
		"macOS":
			return "/Applications/Houdini/Houdini22.0.368/Frameworks/Houdini.framework/Versions/Current/Resources"
	return "C:/Program Files/Side Effects Software/Houdini 22.0.368"
