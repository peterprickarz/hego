@tool
extends EditorPlugin
## Copia's editor plugin. It adds a panel to the inspector of a CopiaStore3D node (totals, sets
## and the build buttons); see copia_inspector.gd. The resource and node classes are part of the
## project as soon as the files are.

const InspectorScript := preload("res://addons/copia/copia_inspector.gd")

var _inspector: EditorInspectorPlugin


func _enter_tree() -> void:
	_inspector = InspectorScript.new()
	add_inspector_plugin(_inspector)


func _exit_tree() -> void:
	if _inspector != null:
		remove_inspector_plugin(_inspector)
		_inspector = null
