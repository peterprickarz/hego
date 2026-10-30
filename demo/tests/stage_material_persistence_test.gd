extends SceneTree
## Artificial small cook fixtures in a disposable user:// storage directory only.
## Forced filesystem failures and zero-total material coverage are intentional;
## no HAPI or user saves.
var checks := 0
var failures := 0
var storage := "user://stage_persistence_%d" % OS.get_process_id()

func _initialize() -> void: run.call_deferred()
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures += 1; push_error("STAGE_MATERIAL_PERSISTENCE: " + message)

func outputs(value: float, mask_spacing := 4.0) -> Array:
	var result: Array = []
	var assigned := HEGoIslandMaterials.channels()[1]
	for name in HEGoIslandStageMaterials.output_channels():
		var spacing := 2.0 if name == "height" else mask_spacing
		var side := roundi(8.0 / spacing) + 1
		var image := Image.create(side, side, false, Image.FORMAT_RF)
		image.fill(Color(value if name == "height" else 1.0 if name == assigned else 0.0, 0, 0, 1))
		result.append({"name": String(name), "image": image, "sample_origin": Vector3(-4, 0, -4), "sample_step_x": Vector3(spacing, 0, 0), "sample_step_y": Vector3(0, 0, spacing)})
	return result

func publish(host: Node, stage: StrataLayer, fields: Array) -> Dictionary:
	var names := HEGoIslandStageMaterials.output_channels()
	var ticket := StrataProcedural.begin_transaction(host, "persistence-fixture", [{"layer": stage, "channels": names, "required_channels": names}], [])
	return StrataProcedural.commit_fields(ticket, [{"layer_id": stage.layer_id, "fields": fields}])

func publish_final(host: Node, target: StrataLayer, assigned: bool) -> Dictionary:
	# The strict island packer requires its real 1025-square 4 m lattice. Reuse the
	# same input images across zero channels; native field ownership stays separate.
	var zero := Image.create(1025, 1025, false, Image.FORMAT_RF)
	var one := Image.create(1025, 1025, false, Image.FORMAT_RF); one.fill(Color(1, 0, 0, 1))
	var names := HEGoIslandMaterials.channels()
	var fields: Array = []
	for index in range(names.size()):
		fields.append({"name": String(names[index]), "image": one if assigned and index == 1 else zero, "sample_origin": Vector3(-2048, 0, -2048), "sample_step_x": Vector3(4, 0, 0), "sample_step_y": Vector3(0, 0, 4)})
	var producer := target.producer_id if not target.producer_id.is_empty() else "final-persistence-fixture"
	var ticket := StrataProcedural.begin_transaction(host, producer, [{"layer": target, "channels": names, "required_channels": names}], [])
	if not ticket.ok: return ticket
	return StrataProcedural.commit_fields(ticket, [{"layer_id": target.layer_id, "fields": fields}])

func remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path): return
	for file in DirAccess.get_files_at(path): DirAccess.remove_absolute(ProjectSettings.globalize_path(path + "/" + file))
	for child in DirAccess.get_directories_at(path): remove_tree(path + "/" + child)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func file_hashes(directory: String) -> Dictionary:
	var result := {}
	for file in DirAccess.get_files_at(directory): result[file] = FileAccess.get_sha256(directory + "/" + file)
	return result

func run() -> void:
	remove_tree(storage)
	var scene := Node3D.new(); root.add_child(scene); current_scene = scene
	var terrain := StrataTerrain3D.new(); terrain.name = "Terrain"; terrain.base_bounds = Rect2(-4, -4, 8, 8); terrain.storage_directory = storage; scene.add_child(terrain)
	var hand := StrataLayer.new(); hand.name = "ManualFine"; terrain.add_child(hand)
	hand.data.set_sample(&"height", Vector2i.ZERO, 0.0)
	var coarse := StrataLayer.new(); coarse.name = "CoarseErosion"; coarse.procedural = true; terrain.add_child(coarse)
	var detail := StrataLayer.new(); detail.name = "DetailErosion"; detail.procedural = true; terrain.add_child(detail)
	var saved_ids := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	var saved_weights := Image.create(1, 1, false, Image.FORMAT_RGBAF)
	terrain.editor_control_ids = saved_ids; terrain.editor_control_weights = saved_weights
	var binding: Node = load("res://island/island_material_binding.gd").new(); scene.add_child(binding); binding.setup(terrain)
	await process_frame
	check(coarse.procedural_fields.is_empty() and detail.procedural_fields.is_empty() and not DirAccess.dir_exists_absolute(storage + "/coarse_erosion"), "opening/tracking stages never invents or persists a cook")
	var expected := 9 + HEGoIslandMaterialRegistry.count()
	for stage in [coarse, detail]:
		check(publish(scene, stage, outputs(19.0, 8.0 if stage == coarse else 4.0)).ok, "complete mixed-stage fixture commits: " + String(stage.name))
		var folder := StrataStorage.layer_directory(terrain, stage)
		var external := true
		for channel in stage.procedural_fields:
			var field: StrataFieldData = stage.procedural_fields[channel]
			external = external and field.resource_path == folder + "/" + String(channel) + ".res" and FileAccess.file_exists(field.resource_path)
		check(external and stage.procedural_fields.size() == expected and not stage.procedural_stale and DirAccess.get_files_at(folder).size() == expected, "a committed stage is saved as one file per channel at fixed paths: " + String(stage.name))
	check(terrain.editor_control_ids == saved_ids and terrain.editor_control_weights == saved_weights, "mixed-stage persistence leaves separately saved final controls unchanged")
	var before := HEGoIslandMaterials.layer_content_hash(detail)
	var packed_before := StrataMaterialControls.compose(terrain, HEGoIslandMaterials.channels(), detail)
	var fixture := PackedScene.new(); var fixture_path := "user://stage_persistence_%d.tscn" % OS.get_process_id()
	check(fixture.pack(detail) == OK and ResourceSaver.save(fixture, fixture_path) == OK, "mixed-stage text scene saves external field references")
	check(FileAccess.get_file_as_bytes(fixture_path).size() < 30000, "text scene does not embed native tile payloads")
	var loaded := ResourceLoader.load(fixture_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var reopened := loaded.instantiate() as StrataLayer
	var second_terrain := StrataTerrain3D.new(); second_terrain.base_bounds = terrain.base_bounds; scene.add_child(second_terrain); second_terrain.add_child(reopened)
	var packed_after := StrataMaterialControls.compose(second_terrain, HEGoIslandMaterials.channels(), reopened)
	check(HEGoIslandMaterials.layer_content_hash(reopened) == before and packed_after.ok and packed_before.ids.get_data() == packed_after.ids.get_data() and packed_before.weights.get_data() == packed_after.weights.get_data(), "text scene roundtrip preserves mixed lattices, values, ownership, modes and exact material controls")

	# A recook overwrites the same files; nothing new appears beside them.
	var detail_folder := StrataStorage.layer_directory(terrain, detail)
	var files_before := file_hashes(detail_folder)
	check(publish(scene, detail, outputs(25.0)).ok, "second explicit stage cook commits")
	var files_after := file_hashes(detail_folder)
	check(files_after.keys() == files_before.keys() and files_after["height.res"] != files_before["height.res"] and detail.procedural_fields.height.resource_path == detail_folder + "/height.res", "a recook overwrites the same channel files in place and creates no new ones")
	check(detail.sample_channel(&"height", Vector2.ZERO).value == 25.0, "the overwritten file holds the new result")

	# A save that fails part-way leaves every previous file intact: a directory sits where
	# one channel's temporary file would be written.
	var blocked := detail_folder + "/sediment" + StrataStorage.TEMPORARY_SUFFIX
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(blocked))
	var retained_files := file_hashes(detail_folder)
	hand.data.set_sample(&"height", Vector2i.ZERO, 5.0)
	var hand_hash := HEGoIslandTransition.manual_hash(hand)
	var failed := publish(scene, detail, outputs(27.0))
	check(failed.ok and "not saved to storage" in String(failed.message) and "NOT SAVED" in detail.procedural_status, "a persistence failure publishes in memory and says the result is unsaved")
	var same_files := true
	for name in retained_files:
		same_files = same_files and FileAccess.get_sha256(detail_folder + "/" + name) == retained_files[name]
	check(same_files and FileAccess.file_exists(detail_folder + "/height.res"), "a partial save failure leaves every previous channel file byte-identical")
	check(DirAccess.get_files_at(detail_folder).size() == expected, "no temporary files are left behind by the failed save")
	check(HEGoIslandTransition.manual_hash(hand) == hand_hash and hand.data.get_sample(&"height", Vector2i.ZERO) == 5.0, "a failed save never touches hand edits")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(blocked))
	check(publish(scene, detail, outputs(29.0)).ok and FileAccess.file_exists(detail_folder + "/sediment.res") and detail.sample_channel(&"height", Vector2.ZERO).value == 29.0 and not "NOT SAVED" in detail.procedural_status, "a later cook saves normally once the directory is writable again")

	# The final material stage packs into the terrain's control maps and saves them.
	terrain.base_bounds = Rect2(-2048, -2048, 4096, 4096)
	var final_target := StrataLayer.new(); final_target.name = HEGoIslandMaterials.LAYER; final_target.procedural = true; terrain.add_child(final_target)
	await process_frame
	var before_zero_revision := final_target.procedural_revision
	check(publish_final(scene, final_target, false).ok, "complete finite zero-total final fixture passes generic transaction validation")
	await process_frame
	await process_frame
	check(final_target.procedural_fields.is_empty() and final_target.procedural_stale and final_target.procedural_revision > before_zero_revision + 1 and "positive total weight" in final_target.procedural_status and "previous complete material fields and controls retained" in final_target.procedural_status, "strict pack failure restores the previous (empty) fields and reports the coverage error with a monotonic revision")
	check(terrain.editor_control_ids == saved_ids and terrain.editor_control_weights == saved_weights and not FileAccess.file_exists(StrataStorage.control_ids_path(terrain)), "zero-total failure keeps the previous controls and writes no control files")
	check(publish_final(scene, final_target, true).ok, "later explicit final cook can recover with a complete positive assignment")
	await process_frame
	await process_frame
	check(not final_target.procedural_stale and terrain.editor_control_ids != saved_ids and roundi(terrain.editor_control_ids.get_pixel(0, 0).r * 255.0) == 1 and terrain.editor_control_weights.get_pixel(0, 0).r == 1.0, "a complete material cook packs valid controls")
	check(FileAccess.file_exists(StrataStorage.control_ids_path(terrain)) and FileAccess.file_exists(StrataStorage.control_weights_path(terrain)) and terrain.editor_control_ids.resource_path == StrataStorage.control_ids_path(terrain), "the control maps are saved at their fixed storage paths")
	var saved_controls := StrataStorage.load_control_maps(terrain)
	check(not saved_controls.is_empty() and saved_controls.ids.get_data() == terrain.editor_control_ids.get_data(), "saved control maps reload byte-identical")
	for layer in terrain.get_layers():
		if layer.procedural: continue
		var saved := StrataStorage.save_layer_data(terrain, layer)
		check(saved.ok and FileAccess.file_exists(StrataStorage.layer_data_path(terrain, layer)), "a hand layer saves to its fixed file: " + String(layer.name))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(fixture_path))
	current_scene = null; scene.free()
	remove_tree(storage)
	print("STAGE_MATERIAL_PERSISTENCE checks=%d failures=%d (failure errors above are intentional fixtures)" % [checks, failures])
	quit(1 if failures else 0)
