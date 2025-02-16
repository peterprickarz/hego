@tool
extends EditorPlugin

var dock
var import_plugin

const ImportPlugin = preload("hda_import_plugin.gd")


func _enter_tree():
	# Initialization of the plugin goes here.
	dock = preload("res://addons/hego/control_dock.tscn").instantiate()
	add_control_to_dock(DOCK_SLOT_LEFT_UR, dock)
	
	import_plugin = ImportPlugin.new()
	add_import_plugin(import_plugin)

func _exit_tree():
	# Clean-up of the plugin goes here.
	remove_control_from_docks(dock)
	dock.free()
	
	remove_import_plugin(import_plugin)
	import_plugin = null
