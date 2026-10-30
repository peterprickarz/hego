@tool
extends EditorPlugin
## The bridge between HEGo and Strata, and the only code that names both.
##
## HEGo picks up HEGoStrataInput and HEGoStrataTargets through its extension points
## (HEGoInputHandler and HEGoCookExtension), so this plugin registers nothing. It exists
## to state the dependency: enabling it checks that both addons are installed and says
## which one is missing. Neither HEGo nor Strata depends on this addon.
##
## Nothing here names a class from either addon, so this script still loads, and can
## report the problem, when one of them is missing.

const REQUIRED := [
	{"name": "HEGo", "folder": "hego", "script": "res://addons/hego/HEGoNode3D.gd", "native_class": "HEGoAPI"},
	{"name": "Strata", "folder": "strata", "script": "res://addons/strata/strata_layer.gd", "native_class": "StrataLayerData"},
]


func _enter_tree() -> void:
	for dependency in REQUIRED:
		if not FileAccess.file_exists(dependency.script) or not ClassDB.class_exists(dependency.native_class):
			push_error("HEGo Strata requires the %s addon at addons/%s, including its native library. Install it, or disable this bridge." % [dependency.name, dependency.folder])
		elif not EditorInterface.is_plugin_enabled(dependency.folder):
			push_warning("HEGo Strata: the %s plugin is installed but not enabled. Enable it in Project Settings > Plugins to use its editor tools." % dependency.name)
