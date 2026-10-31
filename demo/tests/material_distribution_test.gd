extends SceneTree
## Mechanical packing/identity tests. No HAPI, terrain regeneration or assets.
var checks := 0
var failures := 0

func _initialize() -> void: run.call_deferred()
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures += 1; push_error("MATERIAL_DISTRIBUTION: " + message)

var count := HEGoIslandMaterialRegistry.count()

func fields(size: Vector2i, value: float = 0.0) -> Array[Image]:
	var result: Array[Image] = []
	for index in range(count):
		var image := Image.create(size.x, size.y, false, Image.FORMAT_RF)
		image.fill(Color(value, 0, 0, 1)); result.append(image)
	return result

func pack(images: Array) -> Dictionary: return StrataLayerData.pack_material_weights(images)

func run() -> void:
	var contract: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://island/hda/material_contract.json"))
	check(contract.get("contract_version", 0) == 3 and contract.parameters.prior_materials.type == "menu", "actualv3 material contract declares its prior-material menu")
	var menu: Dictionary = contract.parameters.prior_materials
	check(HEGoIslandMaterials.menu_parameter_index(menu, menu.default).get("value", -1) == 0, "contract inherit token default becomes the native integer menu index")
	check(HEGoIslandMaterials.menu_parameter_index(menu, "regenerate").get("value", -1) == 1, "explicit regenerate token becomes the native integer menu index")
	check(HEGoIslandMaterials.menu_parameter_index(menu, 0).get("value", -1) == 0 and HEGoIslandMaterials.menu_parameter_index(menu, 1).get("value", -1) == 1 and HEGoIslandMaterials.menu_parameter_index(menu, 1.0).get("value", -1) == 1, "existing integer menu selections and integral JSON numbers retain their index")
	check(not HEGoIslandMaterials.menu_parameter_index(menu, "typo").ok, "unknown menu token rejects without a cook")
	check(not HEGoIslandMaterials.menu_parameter_index(menu, -1).ok and not HEGoIslandMaterials.menu_parameter_index(menu, 2).ok, "out-of-range menu indices reject without a cook")
	check(not HEGoIslandMaterials.menu_parameter_index(menu, 0.5).ok and not HEGoIslandMaterials.menu_parameter_index(menu, NAN).ok, "fractional/nonfinite menu indices reject without a cook")
	check(not HEGoIslandMaterials.menu_parameter_index(menu, true).ok and not HEGoIslandMaterials.menu_parameter_index({"items": []}, 0).ok, "invalid menu value types and empty contracts reject")
	var entries: Array = JSON.parse_string(FileAccess.get_file_as_string("res://island/materials/material_registry.json"))
	check(count == 4 and HEGoIslandMaterialRegistry.validate_registry(entries).ok, "the four registry entries are unique")
	var duplicate := entries.duplicate(true); duplicate[count - 1].ambientcg_id = duplicate[0].ambientcg_id
	check(not HEGoIslandMaterialRegistry.validate_registry(duplicate).ok, "same source cannot masquerade as a distinct material")
	duplicate = entries.duplicate(true); duplicate[count - 1].resource = duplicate[0].resource
	check(not HEGoIslandMaterialRegistry.validate_registry(duplicate).ok, "resource aliases rejected")
	duplicate = entries.duplicate(true); duplicate[count - 1].channel = "material_wrong"
	check(not HEGoIslandMaterialRegistry.validate_registry(duplicate).ok, "channel identity exact")
	var images := fields(Vector2i(count, 1))
	for index in range(count): images[index].set_pixel(index, 0, Color(1, 0, 0, 1))
	var result := pack(images)
	check(result.ok and result.ids.get_format() == Image.FORMAT_RGBA8 and result.weights.get_format() == Image.FORMAT_RGBAF, "native output formats")
	if result.ok:
		for index in range(count):
			check(roundi(result.ids.get_pixel(index, 0).r * 255) == index and result.weights.get_pixel(index, 0) == Color(1, 0, 0, 0), "single material exact for ID%d" % index)
			check(result.coverage[index].positive_texels == 1 and result.coverage[index].dominant_texels == 1 and result.coverage[index].retained_texels == 1, "perID coverage ID%d" % index)
		check(result.discarded_weight_max == 0.0, "onehot no discarded mass")
	var dispatch := StrataLayerData.new()
	check(dispatch.has_method("pack_material_weights") and dispatch.call("pack_material_weights", images).get("ok", false), "guarded native dispatch supports explicit old-build refusal")
	images = fields(Vector2i.ONE, 1.0)
	result = pack(images)
	check(result.ok and result.ids.get_pixel(0, 0).is_equal_approx(Color(0, 1.0 / 255, 2.0 / 255, 3.0 / 255)), "equal-weight top4 uses ascending ID")
	check(result.weights.get_pixel(0, 0) == Color(.25, .25, .25, .25) and result.discarded_weight_max == 0.0, "normalized retained weights; four materials never discard mass")
	images = fields(Vector2i.ONE)
	images[1].fill(Color(2, 0, 0)); images[3].fill(Color(6, 0, 0))
	result = pack(images)
	check(result.ok and roundi(result.ids.get_pixel(0, 0).r * 255.0) == 3 and result.weights.get_pixel(0, 0) == Color(.75, .25, 0, 0), "positive weights sorted; zero weights never resurrect")
	check(images[3].get_pixel(0, 0).r == 6.0, "inputs untouched")
	var half := images[3].duplicate() as Image; half.convert(Image.FORMAT_RH); images[3] = half
	check(pack(images).ok, "half-float source accepted")
	images[count - 1] = Image.create(2, 1, false, Image.FORMAT_RF)
	check(not pack(images).ok, "mismatched dimensions rejected")
	check(not pack(fields(Vector2i.ONE)).ok, "zero total rejected without fallback")
	images = fields(Vector2i.ONE, 1)
	images[2].fill(Color(-.01, 0, 0)); check(not pack(images).ok, "negative weight rejected")
	images[2].fill(Color(NAN, 0, 0)); check(not pack(images).ok, "nonfinite weight rejected")
	images[2] = Image.create(1, 1, false, Image.FORMAT_RGBAF); check(not pack(images).ok, "color field rejected")
	check(not pack([]).ok, "missing channels rejected")
	images = fields(Vector2i(1026, 1), 1); check(pack(images).ok, "the native pack has no 1025 side cap any more")
	var settings := StrataRenderSettings.new()
	var geometry := settings.parameters().duplicate()
	var settings_hash := HEGoIslandMaterials.resource_state_hash(settings)
	settings.distance_uv_enabled = true; settings.far_uv_factor = .19; settings.terrain_tint_strength = .97
	check(settings.parameters() == geometry and HEGoIslandMaterials.resource_state_hash(settings) != settings_hash, "stored appearance settings protected beyond geometry parameters")
	settings_hash = HEGoIslandMaterials.resource_state_hash(settings)
	var settings_path := "user://material_distribution_%d.res" % OS.get_process_id()
	check(ResourceSaver.save(settings, settings_path) == OK, "settings snapshot saves")
	var reopened := ResourceLoader.load(settings_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	check(HEGoIslandMaterials.resource_state_hash(reopened) == settings_hash, "complete settings hash survives resource reopen")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(settings_path))
	if FileAccess.file_exists(entries[count - 1].resource):
		var pool := HEGoIslandMaterialRegistry.pool()
		var source_paths := {}; var color_paths := {}
		for material in pool:
			source_paths[material.resource_path] = true
			color_paths[material.color_texture.resource_path] = true
		check(pool.size() == count and source_paths.size() == count and color_paths.size() == count, "actual installed pool uses separate resources and Color textures")
	var field_layer := StrataLayer.new(); field_layer.procedural = true
	for index in range(count - 1, -1, -1):
		var field := StrataFieldData.new()
		field.channel = StringName(entries[index].channel); field.resolution = Vector2i.ONE
		field.sample_origin = Vector3.ZERO; field.sample_step_x = Vector3.RIGHT; field.sample_step_y = Vector3.BACK
		var image := Image.create(1, 1, false, Image.FORMAT_RF); image.fill(Color(1, 0, 0))
		field.data.replace_dense(field.channel, Vector2i.ZERO, image)
		field_layer.procedural_fields[entries[index].channel] = field
	var packed_fields := HEGoIslandMaterials.pack(field_layer)
	check(packed_fields.get("ok", false) and packed_fields.ids.get_pixel(0, 0).is_equal_approx(Color(0, 1.0 / 255, 2.0 / 255, 3.0 / 255)), "field Dictionary insertion order cannot change registry ties")
	# Saving goes through the terrain's storage directory, so the cooked fields become one
	# file per channel beside the control maps, in a disposable user:// directory.
	var directory := "user://material_persistence_%d" % OS.get_process_id()
	var storage_terrain := StrataTerrain3D.new(); storage_terrain.name = "Terrain"; storage_terrain.storage_directory = directory
	field_layer.name = HEGoIslandMaterials.LAYER; storage_terrain.add_child(field_layer)
	# The deprecated control-map properties are never written by save_all.
	storage_terrain.editor_control_ids = packed_fields.ids; storage_terrain.editor_control_weights = packed_fields.weights
	var saved_fields := StrataStorage.save_procedural_fields(storage_terrain, field_layer)
	var saved_all := StrataStorage.save_all(storage_terrain)
	check(saved_fields.ok and saved_all.ok, "the cooked fields save as binary resources under the storage directory")
	var external := true
	for channel in field_layer.procedural_fields:
		var field: StrataFieldData = field_layer.procedural_fields[channel]
		external = external and field.resource_path == StrataStorage.field_path(storage_terrain, field_layer, String(channel)) and FileAccess.file_exists(field.resource_path)
	check(external and not FileAccess.file_exists(StrataStorage.control_ids_path(storage_terrain)) and not FileAccess.file_exists(StrataStorage.control_weights_path(storage_terrain)), "every payload sits at its fixed storage path and no control-map files are written (retired)")
	var fixture := PackedScene.new()
	var fixture_path := directory + "/fixture.tscn"
	check(fixture.pack(field_layer) == OK and ResourceSaver.save(fixture, fixture_path) == OK, "text scene can save the stored material layer")
	check(FileAccess.get_file_as_bytes(fixture_path).size() < 30000, "text scene contains references rather than native field tile payloads")
	var loaded_fixture := ResourceLoader.load(fixture_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var loaded_layer := loaded_fixture.instantiate() as StrataLayer
	var loaded_pack := HEGoIslandMaterials.pack(loaded_layer)
	check(loaded_pack.ok and loaded_pack.ids.get_data() == packed_fields.ids.get_data() and loaded_pack.weights.get_data() == packed_fields.weights.get_data(), "reopened binary fields preserve all values/ownership and packed controls")
	loaded_layer.free()
	var layer_folder := StrataStorage.layer_directory(storage_terrain, field_layer)
	storage_terrain.remove_child(field_layer); storage_terrain.free()
	for folder in [layer_folder, directory]:
		for name in DirAccess.get_files_at(folder): DirAccess.remove_absolute(ProjectSettings.globalize_path(folder + "/" + name))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(folder))
	field_layer.get_channel_data(StringName(entries[count - 1].channel)).erase_sample(StringName(entries[count - 1].channel), Vector2i.ZERO)
	check(not HEGoIslandMaterials.pack(field_layer).ok, "unowned result texel rejected rather than invented")
	field_layer.free()
	var terrain := StrataTerrain3D.new(); terrain.name = "Terrain"
	var scene := Node3D.new(); scene.add_child(terrain); var group := Node3D.new(); group.name = "HDA"; scene.add_child(group)
	var base := StrataLayer.new(); base.name = "UserHand"; terrain.add_child(base)
	var attached := HEGoIslandMaterials.attach(scene, {"operator": "Sop/test_materials::1.0"})
	check(attached.ok and terrain.get_layers().size() == 2, "only adds a mask stage/producer")
	if attached.ok:
		check(attached.host.input_stash[0].inputs == ["../../Terrain/UserHand"] and attached.host.input_stash[0].settings.terrain_spacing == terrain.region_spacing and terrain.region_spacing == 1.0, "final cumulative input is at the terrain's region spacing (1 m)")
		check(attached.host.get_child_count() == 0 and attached.host.hego_requires_explicit_cook(), "the producer needs no binding child; its terrain input makes it cook only on request")
		attached.host.parm_stash = PackedByteArray([1, 2, 3])
		var again := HEGoIslandMaterials.attach(scene, {"operator": "Sop/test_materials::1.0"})
		check(again.ok and again.host == attached.host and again.host.parm_stash == PackedByteArray([1, 2, 3]) and terrain.get_layers().size() == 2, "repeat preserves host/preset and target")
		check(not HEGoIslandMaterials.pack(attached.target).ok, "missing result cannot invent distribution")
		# A saved 4 m input row (the pre-regions pinned lattice) is still recognized.
		attached.host.input_stash[0].settings.terrain_spacing = 4.0
		check(HEGoIslandMaterials.attach(scene, {"operator": "Sop/test_materials::1.0"}).ok and attached.host.input_stash[0].settings.terrain_spacing == 4.0, "ordinary attachment preserves a saved legacy 4 m input row")
		attached.host.input_stash[0].settings.terrain_spacing = 2.0
		check(not HEGoIslandMaterials.attach(scene, {"operator": "Sop/test_materials::1.0"}).ok, "an input row at any other spacing is rejected")
		attached.host.input_stash[0].settings.terrain_spacing = 4.0
		attached.host.input_stash[0].settings.terrain_channels = "height"
		var legacy := HEGoIslandMaterials.attach(scene, {"operator": "Sop/test_materials::1.0"})
		check(legacy.ok and legacy.host.input_stash[0].settings.terrain_channels == "height", "ordinary attachment preserves saved legacy input until an explicit migration")
		var upgraded := HEGoIslandMaterials.attach(scene, {"operator": "Sop/test_materials::1.0"}, true)
		check(upgraded.ok and upgraded.host.input_stash[0].settings.terrain_channels.size() == 5 + count and upgraded.host.input_stash[0].settings.terrain_max_samples == StrataProcedural.MAX_SAMPLES and upgraded.host.parm_stash == PackedByteArray([1, 2, 3]), "explicit material-only migration transports masks/priorweights without resetting parameters")
		check(upgraded.host.input_stash[0].settings.terrain_spacing == terrain.region_spacing and upgraded.target.procedural_stale and upgraded.target.procedural_status == "Inputs changed; explicit recook required", "an upgraded input marks the cached distribution stale until an explicit recook")
		attached.host.input_stash[0].inputs = ["../../Terrain/" + HEGoIslandMaterials.LAYER]
		check(not HEGoIslandMaterials.attach(scene, {"operator": "Sop/test_materials::1.0"}).ok and attached.host.input_stash[0].inputs == ["../../Terrain/" + HEGoIslandMaterials.LAYER], "conflicting user input row rejected without overwriting it")
	# A manual layer may sit above MaterialDistribution: the cook still reads the layer below it.
	var touch := StrataLayer.new(); touch.name = "TouchUp"; terrain.add_child(touch)
	check(attached.ok and HEGoIslandMaterials.layer_below(terrain, attached.target) == base and HEGoIslandMaterials.material_layers_above(terrain, attached.target).is_empty(), "a layer above without material channels is allowed and not a material layer")
	var plain_state := HEGoIslandMaterials.above_state(terrain, attached.target)
	touch.data.sample_spacing = 4.0
	touch.data.set_sample(&"height", Vector2i.ZERO, 1.0)
	check(HEGoIslandMaterials.above_state(terrain, attached.target) == plain_state, "height edits above MaterialDistribution do not change the material watch state")
	attached.host.input_stash[0].inputs = ["../../Terrain/UserHand"]
	var reattached := HEGoIslandMaterials.attach(scene, {"operator": "Sop/test_materials::1.0"})
	check(reattached.ok and reattached.host.input_stash[0].inputs == ["../../Terrain/UserHand"], "attach with a manual layer above keeps the cook input on the layer below MaterialDistribution")
	touch.set_composition(StringName(entries[1].channel), StrataLayer.Composition.ADD)
	touch.data.set_sample(StringName(entries[1].channel), Vector2i.ZERO, 5.0)
	check(HEGoIslandMaterials.material_layers_above(terrain, attached.target).size() == 1 and HEGoIslandMaterials.material_layers_above(terrain, attached.target)[0] == touch and HEGoIslandMaterials.above_state(terrain, attached.target) != plain_state, "a material-owning layer above is detected and changes the watch state")
	var moved := HEGoIslandMaterials.attach(scene, {"operator": "Sop/test_materials::1.0"})
	check(moved.ok and moved.host.input_stash[0].inputs == ["../../Terrain/UserHand"], "the manual material layer is never fed back into the cook")
	check(HEGoIslandStageMaterials.migrate(scene).message.find("authored stack") < 0, "stage migration no longer demands MaterialDistribution be last")
	base.data.set_sample(&"height", Vector2i.ZERO, 42.0)
	base.composition_modes = {"terrain_tint_r": 0, "terrain_ao": 1}
	var layer_hash := HEGoIslandMaterials.layer_content_hash(base)
	base.composition_modes = {"terrain_ao": 1.0, "terrain_tint_r": 0.0}
	check(HEGoIslandMaterials.layer_content_hash(base) == layer_hash, "composition hash is stable across JSON key order and integer/float mode representation")
	base.composition_modes.terrain_ao = 0
	check(HEGoIslandMaterials.layer_content_hash(base) != layer_hash, "a real composition change still changes the preservation hash")
	scene.free()
	var scaffold_scene := Node3D.new()
	var scaffold_terrain := StrataTerrain3D.new(); scaffold_terrain.name = "Terrain"; scaffold_scene.add_child(scaffold_terrain)
	var hand := StrataLayer.new(); hand.name = "ExistingHand"; scaffold_terrain.add_child(hand)
	var scaffold_group := Node3D.new(); scaffold_group.name = "HDA"; scaffold_scene.add_child(scaffold_group)
	var scaffold := HEGoNode3D.new(); scaffold.name = "MaterialCook"; scaffold_group.add_child(scaffold)
	var initialized := HEGoIslandMaterials.attach(scaffold_scene, {"operator": "Sop/test_materials::1.0"})
	check(initialized.ok and initialized.host == scaffold and scaffold.asset_name == "Sop/test_materials::1.0" and scaffold.input_stash.size() == 1 and scaffold.get_child_count() == 0, "an existing blank MaterialCook scaffold initializes safely")
	scaffold_scene.free()
	await _controls_with_manual_layer(entries)
	print("MATERIAL_DISTRIBUTION checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)


## The island's material path on a small terrain with the same structure: result fields must be
## on the terrain's region lattice and cover its bounds; the maps come from the stack
## composition (StrataRegions.compose_region), where a manual layer above the procedural pass
## wins at the texels it owns. Nothing is packed into terrain control maps.
func _controls_with_manual_layer(entries: Array) -> void:
	var terrain := StrataTerrain3D.new(); terrain.name = "Terrain"; terrain.base_bounds = Rect2(0, 0, 64, 64); terrain.region_cells = 16; terrain.set_preview_enabled(false)
	var names := HEGoIslandMaterials.channels()
	terrain.editor_material_channels = names
	var below := StrataLayer.new(); below.name = "Below"; terrain.add_child(below)
	var target := StrataLayer.new(); target.name = HEGoIslandMaterials.LAYER; target.procedural = true; terrain.add_child(target)
	var fields := func(step: float, size: int) -> void:
		target.procedural_fields.clear()
		for index in range(count):
			var image := Image.create(size, size, false, Image.FORMAT_RF); image.fill(Color(1.0 if index == 0 else 0.0, 0, 0))
			target.procedural_fields[entries[index].channel] = StrataFieldData.from_field({"name": StringName(entries[index].channel), "image": image, "sample_origin": Vector3.ZERO, "sample_step_x": Vector3(step, 0, 0), "sample_step_y": Vector3(0, 0, step)})
	root.add_child(terrain)
	await process_frame
	fields.call(1.0, 65)
	var valid := HEGoIslandMaterials.validate(target)
	check(valid.ok and valid.first.resolution == Vector2i(65, 65), "fields on the terrain's 1 m lattice covering the bounds validate (any size up to 4097, no 1025 cap)")
	check(HEGoIslandMaterials.validate(target, false).ok, "the lattice-only validation skips reading samples")
	fields.call(4.0, 17)
	var coarse := HEGoIslandMaterials.validate(target)
	check(not coarse.ok and "lattice" in String(coarse.get("message", "")), "a legacy 4 m result is rejected: " + String(coarse.get("message", "")))
	fields.call(1.0, 33)
	check(not HEGoIslandMaterials.validate(target).ok, "fields that do not cover the bounds are rejected")
	fields.call(1.0, 65)
	# Stack composition: the procedural pass gives material 0 everywhere; a hand layer above it
	# paints material 1 at the first sample.
	var spec := terrain.region_spec()
	var apron: int = spec.maps.material_ids.apron
	var plain := StrataRegions.compose_region(terrain, null, Vector2i.ZERO, spec)
	check(plain.get("ok", false), "region composes from the procedural pass: " + str(plain.get("message")))
	if plain.get("ok", false):
		var ids: Image = plain.region.get_image(StrataRegions.MAP_MATERIAL_IDS, 0)
		var weights: Image = plain.region.get_image(StrataRegions.MAP_MATERIAL_WEIGHTS, 0)
		check(ids.get_pixel(apron, apron).r8 == 0 and weights.get_pixel(apron, apron).r8 == 255, "composed region carries the procedural material")
	var hand := StrataLayer.new(); hand.name = "Hand"; hand.data.sample_spacing = 1.0; terrain.add_child(hand)
	hand.set_composition(StringName(entries[1].channel), StrataLayer.Composition.REPLACE)
	hand.data.set_sample(StringName(entries[1].channel), Vector2i.ZERO, 1.0)
	hand.data.set_sample(StringName(entries[0].channel), Vector2i.ZERO, 0.0)
	var touched := StrataRegions.compose_region(terrain, null, Vector2i.ZERO, spec)
	check(touched.get("ok", false), "region composes with a manual material layer above")
	if touched.get("ok", false):
		var ids: Image = touched.region.get_image(StrataRegions.MAP_MATERIAL_IDS, 0)
		var weights: Image = touched.region.get_image(StrataRegions.MAP_MATERIAL_WEIGHTS, 0)
		check(ids.get_pixel(apron, apron).r8 == 1 and weights.get_pixel(apron, apron).r8 == 255, "hand-painted material replaces the procedural weight at its texel")
		check(ids.get_pixel(apron + 5, apron + 5).r8 == 0 and weights.get_pixel(apron + 5, apron + 5).r8 == 255, "unowned texels keep the procedural result")
	check(terrain.editor_control_ids == null and terrain.editor_control_weights == null, "no control maps are produced or needed")
	root.remove_child(terrain); terrain.free()
