@tool
class_name HEGoIslandStageMaterials
extends RefCounted
## Explicit input migration only. No HAPI, field edits, scene saves or cache IO.
const EROSION_OPERATOR := "Sop/HEGo_IslandErosion"
const MATERIAL_OPERATOR := "Sop/HEGo_MaterialDistribution"
const LEGACY_OUTPUTS := ["height", "erosion_delta", "sediment", "debris", "flow", "grass", "rock", "sand", "scree"]
const SIMULATION := ["erosion_delta", "sediment", "debris", "flow"]

static func input_channels() -> PackedStringArray:
	var names := PackedStringArray(["height"]); names.append_array(PackedStringArray(SIMULATION)); names.append_array(HEGoIslandMaterialRegistry.channels())
	return names

static func output_channels() -> PackedStringArray:
	var names := PackedStringArray(LEGACY_OUTPUTS); names.append_array(HEGoIslandMaterialRegistry.channels())
	return names

static func channel_names(value: Variant) -> PackedStringArray:
	if value is String:
		var names := PackedStringArray()
		for name in value.split(",", false): names.append(name.strip_edges())
		return names
	return PackedStringArray(value) if value is Array or value is PackedStringArray else PackedStringArray()

static func input_settings(mask_spacing: float, previous: Dictionary = {}, final_pass: bool = false) -> Dictionary:
	var settings := previous.duplicate(true)
	settings.terrain_mode = "cumulative"
	settings.terrain_channels = input_channels()
	settings.terrain_max_samples = previous.get("terrain_max_samples", StrataProcedural.MAX_SAMPLES)
	if final_pass:
		settings.terrain_spacing = 4.0
		settings.erase("terrain_channel_spacings")
	else:
		# Preserve existing height input spacing, including an absent/native value.
		var spacings := {}
		for name in input_channels():
			if name != "height": spacings[name] = mask_spacing
		settings.terrain_channel_spacings = spacings
	return settings

static func _error(message: String) -> Dictionary:
	return {"ok": false, "message": message + "; no input rows were changed"}

## Upgrades the input rows of the shipped island hosts so every stage reads height, the
## simulation fields and the material weights on bounded grids. Recognizes only the shipped
## legacy or current rows and preflights every host before changing any, so conflicting user
## rows stay available for review. Each host's output is its HDA's target_layer_path
## parameter, which this never touches; every channel the HDA emits is published.
static func migrate(scene: Node3D) -> Dictionary:
	if HEGoIslandMaterialRegistry.channels().is_empty(): return _error("The material registry is unavailable")
	var terrain := scene.get_node_or_null("Terrain") as StrataTerrain3D
	if terrain == null: return _error("The authoring scene has no Terrain")
	var pending: Array = []
	for index in range(3):
		var label: String = ["CoarseCook", "DetailCook", "MaterialCook"][index]
		var host := scene.get_node_or_null("HDA/" + label) as HEGoNode3D
		var target_name: String = ["CoarseErosion", "DetailErosion", "MaterialDistribution"][index]
		var target := terrain.get_node_or_null(target_name) as StrataLayer
		if host == null or target == null or not target.procedural: return _error(label + " or its procedural layer %s is missing" % target_name)
		if host.asset_name != (EROSION_OPERATOR if index < 2 else MATERIAL_OPERATOR): return _error(label + " uses a different HDA")
		var rows: Array = host.input_stash.duplicate(true)
		if rows.size() != (2 if index == 1 else 1) or not rows[0] is Dictionary or not rows[0].get("settings", {}) is Dictionary: return _error(label + " has custom input rows")
		var below := terrain.get_layers()[-2] if index == 2 and terrain.get_layers().size() > 1 else terrain.get_node_or_null("RoughBase" if index == 0 else "ManualFine")
		if below == null or index == 2 and terrain.get_layers()[-1] != target: return _error("MaterialDistribution must follow the authored stack")
		var inputs: Variant = rows[0].get("inputs", [])
		if not (inputs is Array or inputs is PackedStringArray) or inputs.size() != 1 or host.get_node_or_null(NodePath(String(inputs[0]))) != below: return _error(label + " reads a different source layer")
		var settings: Dictionary = rows[0].get("settings", {})
		if settings.get("terrain_mode", "cumulative") != "cumulative" or channel_names(settings.get("terrain_channels", "height")) not in [PackedStringArray(["height"]), input_channels()]: return _error(label + " uses custom input channels/mode")
		var next_settings := input_settings(8.0 if index == 0 else 4.0, settings, index == 2)
		if settings.has("terrain_channel_spacings") and settings.terrain_channel_spacings != next_settings.get("terrain_channel_spacings", {}): return _error(label + " has custom channel spacing overrides")
		if index == 2 and float(settings.get("terrain_spacing", 0.0)) != 4.0: return _error("MaterialCook requires its existing 4 m input lattice")
		rows[0].settings = next_settings
		pending.append({"host": host, "rows": rows})
	var changed := false
	for entry in pending:
		var host: HEGoNode3D = entry.host
		if host.input_stash == entry.rows: continue
		host.input_stash = entry.rows
		host.hego_notify_cook_inputs_changed()
		changed = true
	return {"ok": true, "changed": changed, "message": "Stage material inputs configured; cached fields retained. Explicitly cook CoarseCook, DetailCook, then MaterialCook; save the scene to retain the inputs."}
