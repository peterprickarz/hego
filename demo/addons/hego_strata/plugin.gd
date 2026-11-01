@tool
extends EditorPlugin
## The bridge between HEGo and Strata, and the only code that names both.
##
## HEGo picks up HEGoStrataInput and HEGoStrataOutput through its extension points
## (HEGoInputHandler and HEGoOutputHandler), so this plugin registers nothing for cooking. It
## states the dependency: enabling it checks that both addons are installed and says which
## one is missing. Neither HEGo nor Strata depends on this addon.
##
## In the editor it also keeps published layers honest about their producer: a few times a
## second it runs HEGoStrataOutput.poll over the edited scene, which marks a procedural layer
## stale once the HEGo node that published it has other parameters, inputs or a new
## transform, and connects every HEGo node's cook_inputs_changed signal so an edit in the
## panel does so at once. A changed input layer is Strata's own check.
##
## Nothing here names a class from either addon, so this script still loads, and can
## report the problem, when one of them is missing.

const REQUIRED := [
	{"name": "HEGo", "folder": "hego", "script": "res://addons/hego/HEGoNode3D.gd", "native_class": "HEGoAPI"},
	{"name": "Strata", "folder": "strata", "script": "res://addons/strata/strata_layer.gd", "native_class": "StrataLayerData"},
]
## Script whose static poll() checks the published layers of a scene.
const OUTPUT_SCRIPT := "res://addons/hego_strata/hego_strata_output.gd"
## Seconds between two checks of the edited scene.
const POLL_INTERVAL := 0.25

var _output: Script
var _elapsed := 0.0


func _enter_tree() -> void:
	var installed := true
	for dependency in REQUIRED:
		if not FileAccess.file_exists(dependency.script) or not ClassDB.class_exists(dependency.native_class):
			push_error("HEGo Strata requires the %s addon at addons/%s, including its native library. Install it, or disable this bridge." % [dependency.name, dependency.folder])
			installed = false
		elif not EditorInterface.is_plugin_enabled(dependency.folder):
			push_warning("HEGo Strata: the %s plugin is installed but not enabled. Enable it in Project Settings > Plugins to use its editor tools." % dependency.name)
	_output = load(OUTPUT_SCRIPT) if installed else null


func _exit_tree() -> void:
	_output = null


func _process(delta: float) -> void:
	_elapsed += delta
	if _output == null or _elapsed < POLL_INTERVAL:
		return
	_elapsed = 0.0
	_output.call(&"poll", EditorInterface.get_edited_scene_root())
