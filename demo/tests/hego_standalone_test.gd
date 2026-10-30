extends SceneTree
## HEGo with no other addon installed. Its scripts must load, its extension points must
## stay empty, and settings a terrain input once stored must be inert. Never starts
## Houdini. Needs a project containing only addons/hego; demo/tests/addon_split_runner.py
## stages one.

var checks := 0
var failures := 0


func _initialize() -> void:
	run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("HEGO_STANDALONE_TEST: " + message)


func run() -> void:
	check(not DirAccess.dir_exists_absolute("res://addons/strata") and not ClassDB.class_exists("StrataLayerData"), "this project really has no Strata addon")
	for path in ["res://addons/hego/HEGoNode3D.gd", "res://addons/hego/core/hego_asset_agent.gd", "res://addons/hego/node3d/hego_input_nodes.gd", "res://addons/hego/node3d/hego_cook_extension.gd", "res://addons/hego/node3d/hego_input_handler.gd", "res://addons/hego/ui/input_ui.gd", "res://addons/hego/ui/hda_tab.gd"]:
		var script := load(path) as GDScript
		check(script != null and script.can_instantiate(), path + " compiles without Strata")
	check(HEGoInputNodes.extension_handlers().is_empty(), "no extension input handlers are found")

	var host := HEGoNode3D.new(); host.name = "Host"; root.add_child(host)
	check(host.cook_extensions().is_empty() and not host.hego_requires_explicit_cook(), "an HEGo node has no extensions and recooks automatically")
	host.hego_notify_cook_inputs_changed()
	var mesh := MeshInstance3D.new(); mesh.name = "Mesh"; mesh.mesh = BoxMesh.new(); root.add_child(mesh)
	check(HEGoInputNodes.is_compatible_source(mesh) and HEGoInputNodes.handler_for(mesh) == null, "built-in input kinds are unaffected")

	var row: Variant = load("res://addons/hego/ui/input_ui.tscn").instantiate()
	root.add_child(row)
	row.setup("Input", PackedStringArray(["../Mesh"]), {"terrain_input": true, "terrain_mode": "raw"}, host)
	check(row.get_extension_editors().is_empty() and row.get_extension_settings().is_empty() and not row.requires_explicit_cook(), "stored terrain settings are inert without the bridge")

	row.free(); host.free(); mesh.free()
	print("HEGO_STANDALONE_TEST: %s (%d checks, %d failures)" % ["PASS" if failures == 0 else "FAIL", checks, failures])
	quit(0 if failures == 0 else 1)
