extends "res://tests/runtime_test_base.gd"
## Read-only main-scene integration check. Loads the actual saved authoring scene
## without entering the tree, then checks explicit preparation preserves its bytes.
const AUTHORING_SCENE := "res://scenes/terrain_island.tscn"

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	check(ProjectSettings.get_setting("application/run/main_scene", "") == AUTHORING_SCENE, "demo opens the canonical editable terrain island directly")
	var packed := load(AUTHORING_SCENE) as PackedScene
	check(packed != null, "saved authoring scene and its external resources load")
	if packed == null: finish("TERRAIN_DEMO_SCENE_TEST"); return
	# Scene-local resources deliberately lose their external path when instanced.
	# Read source payloads from the saved state before checking instance content.
	var saved_data := {}
	var state := packed.get_state()
	for index in range(state.get_node_count()):
		for property in range(state.get_node_property_count(index)):
			if state.get_node_property_name(index, property) == &"data":
				var payload := state.get_node_property_value(index, property) as StrataLayerData
				if payload != null: saved_data[String(state.get_node_path(index)).trim_prefix("./")] = payload
	var scene := packed.instantiate() as Node3D
	check(scene != null and scene.get_script() == load("res://island/authoring_level.gd"), "main scene uses the saved-authoring bootstrap")
	if scene == null: finish("TERRAIN_DEMO_SCENE_TEST"); return
	var terrain := scene.get_node_or_null("Terrain") as StrataTerrain3D
	check(terrain != null, "main scene retains its editable terrain stack")
	if terrain != null:
		check(terrain.get_layers().size() >= 5, "main scene retains authored terrain stages")
		check(StrataStorage.directory(terrain) == "res://island/terrain", "main scene stores its terrain under res://island/terrain")
		for layer in terrain.get_layers():
			if not layer.procedural:
				var original := saved_data.get(String(scene.get_path_to(layer))) as StrataLayerData
				check(original != null and original.resource_path == StrataStorage.layer_data_path(terrain, layer), "manual layer references its storage file: " + String(layer.name))
				if original != null:
					check(layer.data.snapshot() == original.snapshot(), "localized manual layer preserves saved source content: " + String(layer.name))
	check(not HEGoAPI.get_singleton().is_session_active(), "loading saved authoring resources starts no Houdini session")
	scene.free()
	finish("TERRAIN_DEMO_SCENE_TEST")
