extends SceneTree
## HEGo's Terrain3D support, which lives in the HEGo Terrain3D bridge (addons/hego_terrain3d)
## and reaches HEGo only through its extension points. Never starts Houdini.
##
## Needs addons/hego, addons/terrain_3d and addons/hego_terrain3d: the demo project, or the
## hego_terrain3d project demo/tests/addon_split_runner.py stages.

var checks := 0
var failures := 0


func _initialize() -> void:
	run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("HEGO_TERRAIN3D_BRIDGE_TEST: " + message)


## A cook that produced nothing at all.
func no_output() -> Dictionary:
	return {
		"has_mesh": false, "has_points": false, "has_curves": false, "has_volumes": false,
		"point_attributes": PackedStringArray(), "prim_attributes": PackedStringArray(),
	}


func summary_with(overrides: Dictionary) -> Dictionary:
	var summary := no_output()
	for key in overrides:
		summary[key] = overrides[key]
	return summary


func run() -> void:
	check(ClassDB.class_exists("Terrain3D"), "the Terrain3D addon is installed")

	# --- output handlers: built-ins, then the bridge's, sorted, then curves ------
	var host := HEGoNode3D.new()
	var handlers := host.output_handlers()
	check(handlers.slice(0, 3) == [HEGoMeshOutput, HEGoMultiMeshOutput, HEGoObjectOutput] and handlers.back() == HEGoCurveOutput, "HEGo's own handlers keep their places around the extension handlers")
	var extensions := handlers.slice(3, handlers.size() - 1)
	var names: Array = []
	for handler in extensions:
		names.append(String((handler.get_script() as Script).get_global_name()) if handler is HEGoOutputHandler else "")
	var sorted_names := names.duplicate()
	sorted_names.sort()
	check(names == sorted_names and not names.has(""), "extension output handlers are HEGoOutputHandler instances in class name order, got %s" % str(names))
	var outputs := extensions.filter(func(handler): return handler is HEGoTerrain3DOutput)
	var instancers := extensions.filter(func(handler): return handler is HEGoTerrain3DInstancer)
	check(outputs.size() == 1 and instancers.size() == 1, "the cook runs one Terrain3D output and one Terrain3D instancer")
	check(HEGoOutputHandler.extension_handlers() == HEGoOutputHandler.extension_handlers() and host.output_handlers()[3] == handlers[3], "handler instances are reused while the class list is unchanged")
	host.free()
	if outputs.size() != 1 or instancers.size() != 1:
		finish()
		return
	var terrain_output: HEGoTerrain3DOutput = outputs[0]
	var instancer: HEGoTerrain3DInstancer = instancers[0]
	check(terrain_output.output_phase() == "terrain3d_output" and instancer.output_phase() == "terrain3d_instancer_output", "the handlers keep their cook phase names")

	# --- which cooks the handlers act on (an unreadable summary runs them) -------
	check(terrain_output.should_handle({}), "empty summary still runs Terrain3D output")
	check(instancer.should_handle({}), "empty summary still runs the Terrain3D instancer")
	check(not terrain_output.should_handle(no_output()), "no volume parts, no Terrain3D output")
	check(not instancer.should_handle(no_output()), "no points, no Terrain3D instancing")
	check(not instancer.should_handle(summary_with({"has_points": true, "point_attributes": PackedStringArray(["P", "N"])})), "points without the instancing flag are not instanced")
	check(terrain_output.should_handle(summary_with({"has_volumes": true})), "a volume part turns Terrain3D output on")
	check(instancer.should_handle(summary_with({
		"has_points": true, "point_attributes": PackedStringArray(["P", "hegot3d_use_terrain3d_instancer"])})),
		"hegot3d_use_terrain3d_instancer turns Terrain3D instancing on")

	# --- inputs ---------------------------------------------------------------
	var scene := Node3D.new(); root.add_child(scene)
	var terrain: Node = ClassDB.instantiate("Terrain3D")
	terrain.name = "Terrain3D"; scene.add_child(terrain)
	check(HEGoInputNodes.handler_for(terrain) is HEGoTerrain3DInput, "a Terrain3D node is sent by the bridge's input handler")
	check(HEGoInputNodes.is_compatible_source(terrain), "a Terrain3D node is a compatible input source")
	var mesh := MeshInstance3D.new(); mesh.mesh = BoxMesh.new(); scene.add_child(mesh)
	check(HEGoInputNodes.handler_for(mesh) == null and HEGoInputNodes.is_compatible_source(mesh), "built-in input kinds are unaffected")

	# --- the demo scene built on this output still loads -----------------------
	const DEMO_SCENE := "res://scenes/Terrain3DOutput.tscn"
	if ResourceLoader.exists(DEMO_SCENE):
		var packed := load(DEMO_SCENE) as PackedScene
		var demo: Node = packed.instantiate() if packed != null else null
		check(demo != null, DEMO_SCENE + " instantiates")
		if demo != null:
			var demo_terrain := demo.get_node_or_null("HEGoNode3D/Terrain3D")
			check(demo.get_node_or_null("HEGoNode3D") is HEGoNode3D and demo_terrain != null and demo_terrain.is_class("Terrain3D"), "the demo scene keeps its HEGo node and Terrain3D")
			check(HEGoInputNodes.handler_for(demo_terrain) is HEGoTerrain3DInput, "the demo scene's Terrain3D input goes through the bridge")
			demo.free()
	else:
		print("  note: %s is not in this project, it was not loaded" % DEMO_SCENE)

	scene.free()
	finish()


func finish() -> void:
	print("HEGO_TERRAIN3D_BRIDGE_TEST: %s (%d checks, %d failures)" % ["PASS" if failures == 0 else "FAIL", checks, failures])
	quit(0 if failures == 0 else 1)
