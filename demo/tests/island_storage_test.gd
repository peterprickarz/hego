extends SceneTree
## The saved island lives at fixed paths. No HAPI session, no scene or storage writes.
##
## Checks that every layer of scenes/terrain_island.tscn references its own file under the
## terrain's storage directory, that those files hold what the layers hold, and that the
## bake and control maps are the gitignored files StrataStorage names.
var checks := 0
var failures := 0

func _initialize() -> void: run.call_deferred()
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures += 1; push_error("ISLAND_STORAGE: " + message)

func run() -> void:
	var packed := load("res://scenes/terrain_island.tscn") as PackedScene
	check(packed != null, "saved authoring scene loads")
	if packed == null: finish(); return
	# Scene-local resources lose their file paths once instanced, so the saved state is
	# where the references live.
	var state := packed.get_state()
	var references := {}
	for index in range(state.get_node_count()):
		for property in range(state.get_node_property_count(index)):
			var name := String(state.get_node_property_name(index, property))
			var value: Variant = state.get_node_property_value(index, property)
			if name == "data" and value is Resource: references[String(state.get_node_name(index)) + "/data"] = value.resource_path
			if name == "procedural_fields" and value is Dictionary:
				for channel in value: references[String(state.get_node_name(index)) + "/" + String(channel)] = (value[channel] as Resource).resource_path
	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	var terrain := scene.get_node("Terrain") as StrataTerrain3D
	check(StrataStorage.has_storage(terrain) and StrataStorage.directory(terrain) == "res://island/terrain", "the island terrain stores its data under res://island/terrain")
	var directory := StrataStorage.directory(terrain)
	for layer in terrain.get_layers():
		if layer.procedural:
			if layer.name == HEGoIslandMaterials.LAYER and layer.procedural_fields.is_empty():
				check(layer.procedural_stale, "an uncooked material distribution says so")
				continue
			check(not layer.procedural_fields.is_empty(), "cooked stage has saved channels: " + String(layer.name))
			for channel in layer.procedural_fields:
				var expected := StrataStorage.field_path(terrain, layer, String(channel))
				check(references.get(String(layer.name) + "/" + String(channel), "") == expected and FileAccess.file_exists(expected), "channel %s/%s is the file %s" % [layer.name, channel, expected])
				var saved := ResourceLoader.load(expected, "", ResourceLoader.CACHE_MODE_IGNORE) as StrataFieldData
				var live: StrataFieldData = layer.procedural_fields[channel]
				check(saved != null and saved.channel == live.channel and saved.resolution == live.resolution and saved.data.snapshot() == live.data.snapshot(), "saved channel equals the loaded layer's: %s/%s" % [layer.name, channel])
		else:
			var expected := StrataStorage.layer_data_path(terrain, layer)
			check(references.get(String(layer.name) + "/data", "") == expected and FileAccess.file_exists(expected), "hand layer %s is the file %s" % [layer.name, expected])
			var saved := ResourceLoader.load(expected, "", ResourceLoader.CACHE_MODE_IGNORE) as StrataLayerData
			check(saved != null and saved.snapshot() == layer.data.snapshot(), "saved hand layer equals the loaded one: " + String(layer.name))
	check(StrataStorage.runtime_data_path(terrain) == directory + "/runtime_data.res" and StrataStorage.control_ids_path(terrain) == directory + "/material_ids.res", "bake and control maps have their fixed file names")
	for name in ["runtime_data.res", "material_ids.res", "material_weights.res"]:
		var scene_text := FileAccess.get_file_as_string("res://scenes/terrain_island.tscn")
		check(not scene_text.contains(name), "the scene does not reference the rebuildable file " + name)
	check(terrain.editor_materials.size() == HEGoIslandMaterialRegistry.count() and terrain.editor_material_channels.size() == HEGoIslandMaterialRegistry.count(), "the terrain binds exactly the registry's materials")
	var manual := terrain.get_node("ManualFine") as StrataLayer
	var before := manual.data.snapshot()
	var brushed := StrataBrush.apply_brush(manual, Vector2(-1000.0, 580.0), 6.0, 1.0, "raise")
	check(brushed > 0 and manual.data.snapshot() != before, "the loaded hand layer is editable in memory")
	manual.data.restore(before)
	check(not HEGoAPI.get_singleton().is_session_active(), "opening the saved island starts no Houdini session")
	scene.free()
	finish()

func finish() -> void:
	print("ISLAND_STORAGE_TEST checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
