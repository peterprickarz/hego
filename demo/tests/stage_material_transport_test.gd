extends SceneTree
## Artificial transport/transaction fixtures only. No HAPI, showcase generation,
## saved authoring scene, cache manifest or source material resources are touched.
var checks := 0
var failures := 0

func _initialize() -> void: run.call_deferred()
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures += 1; push_error("STAGE_MATERIAL_TRANSPORT: " + message)

func field(channel: String, value: float) -> Dictionary:
	var image := Image.create(3, 3, false, Image.FORMAT_RF); image.fill(Color(value, 0, 0, 1))
	return {"name": channel, "image": image, "sample_origin": Vector3(-4, 0, -4), "sample_step_x": Vector3(4, 0, 0), "sample_step_y": Vector3(0, 0, 4)}

func assign(layer: StrataLayer, channel: String, value: float) -> void:
	layer.procedural_fields[channel] = StrataFieldData.from_field(field(channel, value))

func lookup(snapshot: Dictionary, channel: String) -> Dictionary:
	for entry in snapshot.get("fields", []):
		if entry.name == channel: return entry
	return {}

func scalar(snapshot: Dictionary, channel: String) -> float:
	var found := lookup(snapshot, channel)
	return found.image.get_pixel(1, 1).r if not found.is_empty() else NAN

func run() -> void:
	var scene := Node3D.new(); root.add_child(scene); current_scene = scene
	var terrain := StrataTerrain3D.new(); terrain.base_bounds = Rect2(-4, -4, 8, 8); scene.add_child(terrain)
	var base := StrataLayer.new(); terrain.add_child(base)
	base.data.sample_spacing = 4.0; base.data.grid_origin = Vector2(-4, -4)
	base.data.replace_dense(&"height", Vector2i.ZERO, field("height", 10.0).image)
	var coarse := StrataLayer.new(); coarse.procedural = true; terrain.add_child(coarse)
	assign(coarse, "height", 9.0); assign(coarse, "sediment", 0.7); assign(coarse, "debris", 0.2); assign(coarse, "flow", 0.4); assign(coarse, "erosion_delta", -1.0)
	var materials := HEGoIslandMaterials.channels()
	for index in range(materials.size()): assign(coarse, materials[index], 0.75 if index == 1 else 0.25 if index == 2 else 0.0)
	var hand := StrataLayer.new(); hand.data.sample_spacing = 0.25; terrain.add_child(hand)
	hand.set_composition(&"height", StrataLayer.Composition.ADD)
	hand.data.set_sample(&"height", Vector2i.ZERO, 2.0)
	var channels := PackedStringArray(["height", "sediment", "debris", "flow", "erosion_delta"]); channels.append_array(materials)
	var settings := {"terrain_mode": "cumulative", "terrain_channels": channels, "terrain_spacing": 4.0, "terrain_max_samples": StrataProcedural.MAX_SAMPLES}
	var before_hand := HEGoIslandTransition.manual_hash(hand)
	var snapshot := HEGoStrataInput.snapshot(hand, settings)
	check(snapshot.ok and snapshot.fields.size() == channels.size() * 2, "all simulation/material values have independent coverage companions")
	if snapshot.ok:
		check(scalar(snapshot, "height") == 11.0, "fine hand height composes on the explicit coarse input lattice")
		check(is_equal_approx(scalar(snapshot, "sediment"), 0.7) and is_equal_approx(scalar(snapshot, "debris"), 0.2) and is_equal_approx(scalar(snapshot, "flow"), 0.4) and scalar(snapshot, "erosion_delta") == -1.0, "actual simulation masks survive a height-only hand layer")
		check(is_equal_approx(scalar(snapshot, materials[1]), 0.75) and is_equal_approx(scalar(snapshot, materials[2]), 0.25), "prior material weights survive independent hand heights")
		check(scalar(snapshot, materials[0]) == 0.0 and scalar(snapshot, materials[0] + "__ownership") == 1.0, "authored zero material remains owned zero")
		for entry in snapshot.fields:
			check(entry.image.get_size() == Vector2i(3, 3) and entry.sample_origin == Vector3(-4, 0, -4) and entry.sample_step_x == Vector3(4, 0, 0) and entry.sample_step_y == Vector3(0, 0, 4), "common endpoint lattice: " + entry.name)
		check(lookup(snapshot, "flow__ownership").attrs.role == "coverage", "cumulative coverage is metadata rather than editable ownership")
	check(HEGoIslandTransition.manual_hash(hand) == before_hand, "snapshot leaves hand values and ownership unchanged")
	var raw := HEGoStrataInput.snapshot(hand, {"terrain_mode": "raw", "terrain_channels": "height,constraint", "terrain_compact_empty": true})
	check(raw.ok and lookup(raw, "height__ownership").attrs.role == "ownership" and lookup(raw, "height").image.get_pixel(0, 0).r == 2.0 and lookup(raw, "constraint__ownership").image.get_pixel(0, 0).r == 0.0, "raw manual constraints keep binary ownership and their native values")
	var mixed := HEGoStrataInput.snapshot(hand, HEGoIslandStageMaterials.input_settings(4.0, {"terrain_spacing": 2.0}))
	check(mixed.ok and lookup(mixed, "height").image.get_size() == Vector2i(5, 5) and lookup(mixed, "height").sample_step_x == Vector3(2, 0, 0) and lookup(mixed, materials[1]).image.get_size() == Vector2i(3, 3), "per-channel4m masks preserve existing2m height input fidelity")
	check(HEGoIslandStageMaterials.input_settings(4.0, {"terrain_max_samples": 123456}).terrain_max_samples == 123456, "explicitly authored stricter aggregate budget is preserved")
	var native_height := HEGoStrataInput.snapshot(hand, HEGoIslandStageMaterials.input_settings(4.0))
	check(native_height.ok and lookup(native_height, "height").sample_step_x == Vector3(.25, 0, 0) and lookup(native_height, "flow").sample_step_x == Vector3(4, 0, 0), "absent global spacing preserves native fine hand height grid")
	var roundtrip_path := "user://stage_material_transport_%d.res" % OS.get_process_id()
	for channel in ["height", materials[1]]:
		var original := StrataFieldData.from_field(lookup(mixed, channel))
		check(ResourceSaver.save(original, roundtrip_path, ResourceSaver.FLAG_COMPRESS) == OK, "mixed lattice field saves independently: " + channel)
		var reopened := ResourceLoader.load(roundtrip_path, "", ResourceLoader.CACHE_MODE_IGNORE) as StrataFieldData
		var before := original.data.read_dense(original.channel, Vector2i.ZERO, original.resolution)
		var after := reopened.data.read_dense(reopened.channel, Vector2i.ZERO, reopened.resolution)
		check(reopened.sample_origin == original.sample_origin and reopened.sample_step_x == original.sample_step_x and reopened.sample_step_y == original.sample_step_y and reopened.resolution == original.resolution and before.image.get_data() == after.image.get_data() and before.ownership.get_data() == after.ownership.get_data(), "mixed lattice field roundtrip retains basis, values and ownership: " + channel)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(roundtrip_path))
	check(not HEGoStrataInput.snapshot(hand, {"terrain_mode": "raw", "terrain_channels": "height", "terrain_channel_spacings": {"height": 4.0}}).ok, "raw native ownership cannot be silently resampled")
	check(not HEGoStrataInput.snapshot(hand, {"terrain_channels": "height", "terrain_channel_spacings": {"misspelled": 4.0}}).ok, "unknown spacing override channels reject explicitly")
	check(not HEGoStrataInput.snapshot(hand, {"terrain_channels": "height", "terrain_channel_spacings": {"height": NAN}}).ok, "nonfinite spacing override rejects explicitly")
	var unassigned := HEGoStrataInput.snapshot(base, settings)
	check(unassigned.ok and scalar(unassigned, materials[0]) == 0.0 and scalar(unassigned, materials[0] + "__ownership") == 0.0, "missing upstream material is explicit unassigned zero, with no invented habitat")
	var detail := StrataLayer.new(); detail.procedural = true; terrain.add_child(detail)
	var required := PackedStringArray(["height"]); required.append_array(materials)
	var declarations := [{"layer": detail, "channels": channels, "required_channels": required}]
	var transaction := StrataProcedural.begin_transaction(scene, "stage-fixture", declarations, [snapshot])
	var incomplete := StrataProcedural.commit_fields(transaction, [{"layer_id": detail.layer_id, "fields": [field("height", 8.0)]}])
	check(not incomplete.ok and detail.procedural_fields.is_empty(), "missing required material fields reject the entire height/material generation")
	transaction = StrataProcedural.begin_transaction(scene, "stage-fixture", declarations, [snapshot])
	var outputs: Array = [field("height", 8.0), field("sediment", 0.1), field("debris", 0.3), field("flow", 0.6), field("erosion_delta", -3.0)]
	for index in range(materials.size()): outputs.append(field(materials[index], 1.0 if index == 3 else 0.0))
	var published := StrataProcedural.commit_fields(transaction, [{"layer_id": detail.layer_id, "fields": outputs}])
	check(published.ok and detail.procedural_fields.size() == channels.size() and detail.procedural_revision == 1, "height, simulation fields and every material publish together")
	var downstream := HEGoStrataInput.snapshot(detail, settings)
	check(downstream.ok and scalar(downstream, "height") == 8.0 and is_equal_approx(scalar(downstream, "debris"), 0.3) and scalar(downstream, materials[3]) == 1.0 and scalar(downstream, materials[1]) == 0.0, "next stage receives latest simulation fields and prior stage mixture")
	var controls := StrataMaterialControls.compose(terrain, materials, coarse)
	check(controls.ok and roundi(controls.ids.get_pixel(0, 0).r * 255.0) == 1, "stage preview uses stable IDs before final distribution")
	var stage_scene := PackedScene.new()
	var stage_path := "user://stage_material_noop_%d.scn" % OS.get_process_id()
	check(stage_scene.pack(detail) == OK and ResourceSaver.save(stage_scene, stage_path, ResourceSaver.FLAG_COMPRESS) == OK, "mixed height/material stage persists as a complete cached result")
	var packed_before := StrataMaterialControls.compose(terrain, materials, detail)
	var reopened_scene := ResourceLoader.load(stage_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var reopened_stage := reopened_scene.instantiate() as StrataLayer
	var reopened_terrain := StrataTerrain3D.new(); reopened_terrain.base_bounds = terrain.base_bounds; scene.add_child(reopened_terrain); reopened_terrain.add_child(reopened_stage)
	var packed_after := StrataMaterialControls.compose(reopened_terrain, materials, reopened_stage)
	check(reopened_stage.procedural_fields.size() == detail.procedural_fields.size() and reopened_stage.procedural_fields.has("height") and packed_before.ok and packed_after.ok and packed_before.ids.get_data() == packed_after.ids.get_data() and packed_before.weights.get_data() == packed_after.weights.get_data(), "unchanged mixed stage retains exact material controls through persistence and composition")
	check(not HEGoIslandMaterials.pack(detail).ok, "strict final mask-only pack is not used for mixed erosion stages")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(stage_path))
	var cached_field: StrataFieldData = detail.procedural_fields[materials[3]]
	transaction = StrataProcedural.begin_transaction(scene, "stage-fixture", declarations, [snapshot])
	coarse.procedural_fields[materials[1]].data.set_sample(StringName(materials[1]), Vector2i.ZERO, 0.5)
	var stale := StrataProcedural.commit_fields(transaction, [{"layer_id": detail.layer_id, "fields": outputs}])
	check(not stale.ok and detail.procedural_fields[materials[3]] == cached_field and detail.procedural_revision == 1, "upstream material change rejects stale cook and retains complete cached result")
	check(HEGoIslandTransition.manual_hash(hand) == before_hand, "publishing or rejecting a stage never changes hand ownership")
	# Real production dimensions, checked before any large native allocation.
	terrain.base_bounds = Rect2(-2048, -2048, 4096, 4096)
	var fits := HEGoStrataInput.snapshot(base, {"terrain_mode": "cumulative", "terrain_channels": channels, "terrain_spacing": 4.0})
	check(fits.ok and fits.fields.size() == channels.size() * 2, "%d channels on the 1025-square 4 m lattice fit the default sample budget" % channels.size())
	check(1025 * 1025 * channels.size() * 2 <= StrataProcedural.DEFAULT_SAMPLES and StrataProcedural.DEFAULT_SAMPLES == 64 * 1024 * 1024, "the generic default budget is unchanged")
	var bounded := HEGoStrataInput.snapshot(base, {"terrain_mode": "cumulative", "terrain_channels": channels, "terrain_spacing": 1.0, "terrain_max_samples": StrataProcedural.MAX_SAMPLES})
	check(not bounded.ok and "sample budget" in bounded.message, "large multichannel input still rejects before allocation")
	check_bindings()
	current_scene = null; scene.free()
	print("STAGE_MATERIAL_TRANSPORT checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)


func check_bindings() -> void:
	var scene := Node3D.new(); root.add_child(scene)
	var terrain := StrataTerrain3D.new(); terrain.name = "Terrain"; scene.add_child(terrain)
	for label in ["RoughBase", "CoarseErosion", "ManualFine", "DetailErosion", "BuildingFlatten", "MaterialDistribution"]:
		var layer := StrataLayer.new(); layer.name = label; layer.procedural = label in ["CoarseErosion", "DetailErosion", "MaterialDistribution"]; terrain.add_child(layer)
	var group := Node3D.new(); group.name = "HDA"; scene.add_child(group)
	for index in range(3):
		var label: String = ["CoarseCook", "DetailCook", "MaterialCook"][index]
		var target: String = ["CoarseErosion", "DetailErosion", "MaterialDistribution"][index]
		var host := HEGoNode3D.new(); host.name = label; group.add_child(host)
		host.asset_name = HEGoIslandStageMaterials.EROSION_OPERATOR if index < 2 else HEGoIslandStageMaterials.MATERIAL_OPERATOR
		host.parm_stash = PackedByteArray([index, 19, 42])
		# As an earlier commit by this host records it; the editor plugin watches the host.
		var layer := terrain.get_node(target) as StrataLayer
		layer.producer_path = layer.get_path_to(host); layer.producer_id = HEGoStrataOutput.producer_id(host)
		HEGoStrataOutput.watch(host)
		var settings := {"terrain_mode": "cumulative", "terrain_channels": "height"}
		if index == 2: settings.terrain_spacing = 4.0
		host.input_stash = [{"inputs": ["../../Terrain/" + ["RoughBase", "ManualFine", "BuildingFlatten"][index]], "settings": settings}]
		if index == 1: host.input_stash.append({"inputs": ["../../Terrain/BuildingFlatten"], "settings": {"terrain_mode": "raw", "terrain_channels": "height,constraint", "terrain_compact_empty": true}})
	var coarse := group.get_node("CoarseCook") as HEGoNode3D
	var detail := group.get_node("DetailCook") as HEGoNode3D
	var material := group.get_node("MaterialCook") as HEGoNode3D
	var cached := terrain.get_node("CoarseErosion") as StrataLayer
	assign(cached, "height", 19.0)
	var cached_height: StrataFieldData = cached.procedural_fields.height
	var hand := terrain.get_node("ManualFine") as StrataLayer
	hand.data.set_sample(&"height", Vector2i.ZERO, 0.0)
	var hand_hash := HEGoIslandTransition.manual_hash(hand)
	var preserved := HEGoIslandMaterials.host_state_hash(coarse)
	detail.input_stash[0].settings.terrain_channels = "height,user_mask"
	check(not HEGoIslandStageMaterials.migrate(scene).ok and HEGoIslandMaterials.host_state_hash(coarse) == preserved, "custom downstream input rows reject migration before any upstream mutation")
	detail.input_stash[0].settings.terrain_channels = "height"
	var raw: Dictionary = detail.input_stash[1].duplicate(true)
	var migrated := HEGoIslandStageMaterials.migrate(scene)
	check(migrated.ok and migrated.changed and coarse.get_child_count() == 0 and HEGoIslandMaterials.host_state_hash(coarse) != preserved, "explicit migration changes only the hosts' input rows")
	check(coarse.input_stash[0].settings.terrain_channel_spacings.flow == 8.0 and detail.input_stash[0].settings.terrain_channel_spacings.flow == 4.0 and not detail.input_stash[0].settings.has("terrain_spacing"), "migration sets bounded mask grids and preserves native height input spacing")
	check(detail.input_stash[1] == raw and detail.parm_stash == PackedByteArray([1, 19, 42]) and terrain.get_node("DetailErosion").producer_id == HEGoStrataOutput.producer_id(detail), "raw building input, saved parameters and producer identity survive migration")
	check(material.input_stash[0].settings.terrain_channels.size() == 5 + HEGoIslandMaterialRegistry.count() and material.input_stash[0].settings.terrain_spacing == terrain.region_spacing and terrain.region_spacing == 1.0 and material.input_stash[0].settings.terrain_max_samples == StrataProcedural.MAX_SAMPLES, "final material input carries actual masks and prior weights on4m grid")
	check(cached.procedural_fields.height == cached_height and cached_height.data.get_sample(&"height", Vector2i.ZERO) == 19.0 and terrain.get_node("DetailErosion").procedural_revision == 0 and cached.procedural_stale and cached.producer_intent_revision == 1 and HEGoIslandTransition.manual_hash(hand) == hand_hash, "migration leaves cached fields/revisions and owned hand zero alone and requests explicit cooks")
	var row: Variant = load("res://addons/hego/ui/input_ui.tscn").instantiate()
	scene.add_child(row)
	row.setup("Detail stage", PackedStringArray(["../../Terrain/ManualFine"]), detail.input_stash[0].settings, detail)
	var terrain_editors: Array = row.get_extension_editors().filter(func(editor): return editor is HEGoStrataInputSettings)
	var terrain_editor: HEGoStrataInputSettings = terrain_editors[0] if not terrain_editors.is_empty() else null
	check(terrain_editor != null and terrain_editor.visible, "a terrain input row shows the bridge's terrain options")
	check(terrain_editor != null and "%d named channel spacing overrides" % (4 + HEGoIslandMaterialRegistry.count()) in terrain_editor.status_label.text and "4.000 m" in terrain_editor.status_label.text, "HEGo editing workflow explicitly labels mixed channel spacing overrides")
	var retained: Dictionary = detail.input_stash[0].settings.duplicate(true)
	retained.merge(row.get_extension_settings(), true)
	check(retained.terrain_channel_spacings == detail.input_stash[0].settings.terrain_channel_spacings and retained.terrain_max_samples == StrataProcedural.MAX_SAMPLES, "editing visible input options preserves mixed lattice overrides and budget")
	migrated = HEGoIslandStageMaterials.migrate(scene)
	check(migrated.ok and not migrated.changed, "binding migration is idempotent")
	scene.free()
