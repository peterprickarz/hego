@tool
extends EditorPlugin
## The bridge between HEGo and Terrain3D, and the only code that knows about both.
##
## HEGo picks up HEGoTerrain3DInput, HEGoTerrain3DOutput and HEGoTerrain3DInstancer through
## its extension points (HEGoInputHandler and HEGoOutputHandler), so this plugin registers
## nothing. It exists to state the dependency: enabling it checks that both addons are
## installed and says which one is missing. Neither HEGo nor Terrain3D depends on this addon.
##
## Nothing here names a class from either addon, so this script still loads, and can
## report the problem, when one of them is missing. The bridge's own scripts reach Terrain3D
## only through ClassDB and dynamic calls, never by class name, for the same reason.

const REQUIRED := [
	{"name": "HEGo", "folder": "hego", "script": "res://addons/hego/HEGoNode3D.gd", "native_class": "HEGoAPI"},
	{"name": "Terrain3D", "folder": "terrain_3d", "script": "res://addons/terrain_3d/terrain.gdextension", "native_class": "Terrain3D"},
]


func _enter_tree() -> void:
	for dependency in REQUIRED:
		if not FileAccess.file_exists(dependency.script) or not ClassDB.class_exists(dependency.native_class):
			push_error("HEGo Terrain3D requires the %s addon at addons/%s, including its native library. Install it, or disable this bridge." % [dependency.name, dependency.folder])
		elif not EditorInterface.is_plugin_enabled(dependency.folder):
			push_warning("HEGo Terrain3D: the %s plugin is installed but not enabled. Enable it in Project Settings > Plugins to use its editor tools." % dependency.name)
