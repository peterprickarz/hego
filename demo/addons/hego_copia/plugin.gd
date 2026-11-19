@tool
extends EditorPlugin
## The bridge between HEGo and Copia, and the only code that names both.
##
## HEGo picks up HEGoCopiaOutput and HEGoCopiaInput through its extension points
## (HEGoOutputHandler and HEGoInputHandler), so this plugin registers nothing for cooking. It
## states the dependency: enabling it checks that both addons are installed and says which one
## is missing. Neither HEGo nor Copia depends on this addon.
##
## Nothing here names a class from either addon, so this script still loads, and can report
## the problem, when one of them is missing.

const REQUIRED := [
	{"name": "HEGo", "folder": "hego", "script": "res://addons/hego/HEGoNode3D.gd"},
	{"name": "Copia", "folder": "copia", "script": "res://addons/copia/copia_store_3d.gd"},
]


func _enter_tree() -> void:
	for dependency in REQUIRED:
		if not FileAccess.file_exists(dependency.script):
			push_error("HEGo Copia requires the %s addon at addons/%s. Install it, or disable this bridge." % [dependency.name, dependency.folder])
		elif not EditorInterface.is_plugin_enabled(dependency.folder):
			push_warning("HEGo Copia: the %s plugin is installed but not enabled. Enable it in Project Settings > Plugins." % dependency.name)
