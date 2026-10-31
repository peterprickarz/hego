class_name HEGoIslandMaterials
extends HEGoIslandMaterialRegistry
## Houdini authoring adapter. Habitat placement is authored only in the HDA.
const CONTRACT := "res://island/hda/material_contract.json"
const LAYER := "MaterialDistribution"
const HOST := "HDA/MaterialCook"
const LAYER_ID := "bracken-isle-material-distribution-v1"

## Includes every stored property, including appearance controls omitted by
## the geometry-only parameters() snapshot. No Resource identity/RID hashing.
static func resource_state_hash(resource: Resource) -> String:
	var values := []
	var names := PackedStringArray()
	for property in resource.get_property_list():
		if int(property.usage) & PROPERTY_USAGE_STORAGE and property.name != "script": names.append(property.name)
	names.sort()
	for name in names: values.append([name, resource.get(name)])
	var context := HashingContext.new(); context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(values))
	return context.finish().hex_encode()

static func bytes_hash(bytes: PackedByteArray) -> String:
	var context := HashingContext.new(); context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()

## Everything a host's cook depends on besides its inputs' content: HDA, parameters (which
## include the target layer path), input rows and transform.
static func host_state_hash(host: HEGoNode3D) -> String:
	return bytes_hash(var_to_bytes([host.asset_name, host.parm_stash, host.input_stash, host.transform]))

## Content identity of one stage: native samples/ownership, composition and,
## for procedural stages, every cached field's values, ownership and basis.
const LAYER_CONTENT_HASH_VERSION := 2

static func layer_content_hash(layer: StrataLayer) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	# JSON metadata roundtrips reorder Dictionary keys and turn int modes into
	# floats. Composition semantics are integer modes, not insertion/number
	# representation. Native samples/ownership and field payloads stay exact.
	var mode_names := layer.composition_modes.keys()
	mode_names.sort()
	var modes: Array = []
	for name in mode_names: modes.append([String(name), int(layer.composition_modes[name])])
	context.update(var_to_bytes([LAYER_CONTENT_HASH_VERSION, String(layer.name), layer.layer_id, modes, layer.procedural, layer.producer_id, layer.procedural_revision]))
	context.update(var_to_bytes(layer.data.snapshot()))
	var names := layer.procedural_fields.keys()
	names.sort()
	for name in names:
		var field: StrataFieldData = layer.procedural_fields[name]
		var dense := field.data.read_dense(field.channel, Vector2i.ZERO, field.resolution)
		context.update(var_to_bytes([name, field.channel, field.sample_origin, field.sample_step_x, field.sample_step_y, field.resolution, field.attrs]))
		context.update((dense.image as Image).get_data())
		context.update((dense.ownership as Image).get_data())
	return context.finish().hex_encode()

## A complete result must use one common physical lattice. No channel is
## invented/resampled; binary ownership must cover every exported sample.
static func pack(layer: StrataLayer) -> Dictionary:
	var started := Time.get_ticks_usec()
	if not is_instance_valid(layer) or not layer.procedural: return {"ok": false, "message": "MaterialDistribution must be a procedural target"}
	var checked := registry()
	if not checked.ok: return checked
	if layer.procedural_fields.size() != checked.entries.size() or layer.procedural_fields.has("height"): return {"ok": false, "message": "MaterialDistribution requires all %d registry mask fields and no height" % checked.entries.size()}
	var images: Array[Image] = []
	var first: StrataFieldData
	for entry in checked.entries:
		var field: StrataFieldData = layer.procedural_fields.get(entry.channel)
		if field == null or field.data == null or field.channel != StringName(entry.channel) or layer.get_composition(field.channel) != StrataLayer.Composition.REPLACE: return {"ok": false, "message": "Missing or invalid material field: " + entry.channel}
		if first == null: first = field
		elif field.resolution != first.resolution or field.sample_origin != first.sample_origin or field.sample_step_x != first.sample_step_x or field.sample_step_y != first.sample_step_y: return {"ok": false, "message": "Material fields must share exactly one physical lattice"}
		var read := field.data.read_dense(field.channel, Vector2i.ZERO, field.resolution)
		if not read.get("ok", false) or read.get("owned_count", 0) != field.resolution.x * field.resolution.y: return {"ok": false, "message": "Material field has missing owned samples: " + entry.channel}
		images.append(read.image)
	var terrain := layer.get_parent() as StrataTerrain3D
	if terrain != null:
		var span := terrain.base_bounds
		var end := first.sample_origin + first.sample_step_x * (first.resolution.x - 1) + first.sample_step_y * (first.resolution.y - 1)
		if first.resolution != Vector2i(1025, 1025) or not Vector2(first.sample_origin.x, first.sample_origin.z).is_equal_approx(span.position) or not Vector2(end.x, end.z).is_equal_approx(span.end) or not first.sample_step_x.is_equal_approx(Vector3(4, 0, 0)) or not first.sample_step_y.is_equal_approx(Vector3(0, 0, 4)): return {"ok": false, "message": "Island material controls must cover the complete endpoint-aligned 4m terrain lattice"}
	var native := StrataLayerData.new()
	if not native.has_method("pack_material_weights"): return {"ok": false, "message": "This terrain native library cannot pack material fields; rebuild it before cooking"}
	var packed: Dictionary = native.call("pack_material_weights", images)
	if not packed.get("ok", false): return packed
	packed["source"] = "Houdini MaterialDistribution: %d distinct ambientCG sources" % checked.entries.size()
	packed["registry_sha256"] = FileAccess.get_sha256(REGISTRY)
	packed["resolution"] = first.resolution
	packed["sample_origin"] = first.sample_origin
	packed["sample_step_x"] = first.sample_step_x
	packed["sample_step_y"] = first.sample_step_y
	packed["pack_cpu_ms"] = (Time.get_ticks_usec() - started) / 1000.0
	return packed

## The layer immediately preceding [param target] in the terrain stack, or null.
static func layer_below(terrain: StrataTerrain3D, target: StrataLayer) -> StrataLayer:
	var layers := terrain.get_layers()
	var index := layers.find(target)
	return layers[index - 1] if index > 0 else null

## Enabled layers above [param target] that own at least one material channel.
static func material_layers_above(terrain: StrataTerrain3D, target: StrataLayer) -> Array[StrataLayer]:
	var result: Array[StrataLayer] = []
	var names := channels()
	var layers := terrain.get_layers()
	for index in range(layers.find(target) + 1, layers.size()):
		var layer: StrataLayer = layers[index]
		if not layer.enabled: continue
		var owned := layer.get_channel_names()
		for channel in names:
			if owned.has(channel): result.append(layer); break
	return result

## Cheap identity of what manual layers above [param target] contribute to the material
## channels; unrelated channels such as height do not change it.
static func above_state(terrain: StrataTerrain3D, target: StrataLayer) -> Array:
	var names := channels()
	var state: Array = []
	for layer in material_layers_above(terrain, target):
		var entries: Array = []
		var owned := layer.get_channel_names()
		for channel in names:
			if not owned.has(channel): continue
			var field: StrataFieldData = layer.procedural_fields.get(channel)
			entries.append([channel, layer.get_composition(StringName(channel)), field.signature() if field != null else [layer.data.get_instance_id(), layer.data.get_revision()]])
		state.append([layer.get_instance_id(), entries])
	return state

## Control maps for the terrain. Without material-owning layers above the procedural pass
## this is the strict [method pack] of [param target]; with them, the procedural pass is
## still validated by [method pack], and the maps come from the stack composed through the
## final layer so hand-painted weights win where they own a texel.
static func controls(terrain: StrataTerrain3D, target: StrataLayer) -> Dictionary:
	var packed := pack(target)
	if not packed.get("ok", false) or material_layers_above(terrain, target).is_empty(): return packed
	var composed := StrataMaterialControls.compose(terrain, channels(), null)
	if not composed.get("ok", false): return composed
	if composed.get("empty", false): return {"ok": false, "message": "Composed material controls are empty"}
	composed["source"] = packed.get("source", "") + " with manual material layers"
	return composed

## Adds only a missing mask stage/producer. Existing layer identity, input rows,
## user material edits, parameters and every preexisting node are retained. The host's
## target is its HDA's target_layer_path parameter, which [method cook_explicit] sets.
static func attach(scene: Node3D, contract: Dictionary, upgrade_legacy_input: bool = false) -> Dictionary:
	var terrain := scene.get_node_or_null("Terrain") as StrataTerrain3D
	if terrain == null or not contract.get("operator") is String or String(contract.operator).is_empty(): return {"ok": false, "message": "Material HDA contract or terrain is missing"}
	var names := channels()
	if names.is_empty(): return {"ok": false, "message": "Material registry is invalid"}
	var target := terrain.get_node_or_null(LAYER) as StrataLayer
	if target == null:
		if terrain.get_node_or_null(LAYER) != null: return {"ok": false, "message": "MaterialDistribution path is occupied"}
		target = StrataLayer.new(); target.name = LAYER; target.procedural = true; target.layer_id = LAYER_ID
		terrain.add_child(target); target.owner = scene
	elif not target.procedural or target.layer_id != LAYER_ID: return {"ok": false, "message": "MaterialDistribution identity conflicts with an existing authored layer"}
	var group := scene.get_node_or_null("HDA")
	if group == null: return {"ok": false, "message": "The authoring scene has no HDA group"}
	var host := scene.get_node_or_null(HOST) as HEGoNode3D
	if host == null:
		if scene.get_node_or_null(HOST) != null: return {"ok": false, "message": "MaterialCook path is occupied"}
		host = HEGoNode3D.new(); host.name = "MaterialCook"
		group.add_child(host); host.owner = scene
	if host.asset_name.is_empty(): host.asset_name = contract.operator
	elif host.asset_name != contract.operator: return {"ok": false, "message": "MaterialCook uses a different HDA"}
	# The cook reads the cumulative stack directly below the layer. Manual layers above it
	# (hand-painted material touch-ups) are composed after the cook and never fed back in.
	var below := layer_below(terrain, target)
	if below == null: return {"ok": false, "message": "MaterialDistribution needs an earlier cumulative height source"}
	if host.input_stash.is_empty(): host.input_stash = [{"inputs": ["../../Terrain/" + String(below.name)], "settings": {"terrain_mode": "cumulative", "terrain_channels": HEGoIslandStageMaterials.input_channels(), "terrain_spacing": 4.0, "terrain_max_samples": StrataProcedural.MAX_SAMPLES}}]
	if host.input_stash.size() != 1 or host.input_stash[0].get("inputs", []) != ["../../Terrain/" + String(below.name)] or host.input_stash[0].get("settings", {}).get("terrain_mode") != "cumulative" or HEGoIslandStageMaterials.channel_names(host.input_stash[0].get("settings", {}).get("terrain_channels", [])) not in [PackedStringArray(["height"]), HEGoIslandStageMaterials.input_channels()] or host.input_stash[0].get("settings", {}).get("terrain_spacing", 0.0) != 4.0: return {"ok": false, "message": "MaterialCook requires the final cumulative height/material/simulation input at 4 m (or the saved legacy height-only binding); use the explicit stage input migration to upgrade"}
	if upgrade_legacy_input and HEGoIslandStageMaterials.channel_names(host.input_stash[0].settings.terrain_channels) == PackedStringArray(["height"]):
		var rows := host.input_stash.duplicate(true)
		rows[0].settings = HEGoIslandStageMaterials.input_settings(4.0, rows[0].settings, true)
		host.input_stash = rows
		host.hego_notify_cook_inputs_changed()
		target.mark_stale("Inputs changed; explicit recook required")
	return {"ok": true, "terrain": terrain, "target": target, "host": host}

## HAPI integer menus store item indices, while the contract names tokens.
static func menu_parameter_index(parameter: Dictionary, value: Variant) -> Dictionary:
	var items := PackedStringArray(parameter.get("items", []))
	if items.is_empty(): return {"ok": false, "message": "Menu contract has no items"}
	if value is String or value is StringName:
		var index := items.find(String(value))
		if index >= 0: return {"ok": true, "value": index}
		return {"ok": false, "message": "Unknown menu token: " + String(value)}
	if value is int or value is float:
		var number := float(value)
		if is_finite(number) and number == floor(number) and number >= 0.0 and number < items.size(): return {"ok": true, "value": int(value)}
	return {"ok": false, "message": "Menu value must be a declared token or a valid integral item index"}

## Caller owns/exclusively starts a HAPI session. This never cooks another host.
static func cook_explicit(owner: Node, host: HEGoNode3D, target: StrataLayer, contract: Dictionary, overrides: Dictionary = {}) -> Dictionary:
	var asset := host.agent.asset(host.asset_name)
	var initialize := host.parm_stash.is_empty()
	var parameters: Dictionary = contract.get("parameters", {})
	var changes := {}
	if initialize:
		for key in parameters:
			if parameters[key].has("default"): changes[key] = parameters[key].default
	changes.target_layer_path = String(host.get_path_to(target)) if host.is_inside_tree() and target.is_inside_tree() else "../../Terrain/" + LAYER
	changes.merge(overrides, true)
	for key in changes:
		if not parameters.has(key): return {"ok": false, "message": "Unknown material parameter " + key}
		var kind := String(parameters[key].get("type", ""))
		if kind in ["int", "toggle"]: changes[key] = int(changes[key])
		elif kind == "float": changes[key] = float(changes[key])
		elif kind == "menu":
			var converted := menu_parameter_index(parameters[key], changes[key])
			if not converted.ok: return {"ok": false, "message": String(key) + ": " + converted.message}
			changes[key] = converted.value
	if not await host.agent.instantiate(asset, host.parm_stash, true): return {"ok": false, "message": "Material HDA instantiation failed"}
	var configured := await HEGoNodeUtil.checked_task(owner, asset.set_parms_batch(changes))
	if not configured.ok: return configured
	var values := await HEGoNodeUtil.checked_task(owner, asset.get_parms_dict())
	if not values.ok: return values
	var actual := {}; _collect_parms(values.value, actual, parameters)
	for key in changes:
		var matches: bool = actual.has(key) and (is_equal_approx(float(actual[key]), float(changes[key])) if changes[key] is float or changes[key] is int else actual[key] == changes[key])
		if not matches: return {"ok": false, "message": "Material parameter readback mismatch: " + key}
	var before := target.procedural_revision
	var started := Time.get_ticks_usec()
	await host.cook()
	return {"ok": target.procedural_revision > before and not target.procedural_stale, "message": target.procedural_status, "parameters": actual, "cook_ms": (Time.get_ticks_usec() - started) / 1000.0}

static func _collect_parms(value: Variant, result: Dictionary, parameters: Dictionary) -> void:
	if value is Dictionary:
		if value.has("name") and value.has("values") and parameters.has(String(value.name)) and not value["values"].is_empty(): result[String(value.name)] = value["values"][0]
		for child in value.values(): _collect_parms(child, result, parameters)
	elif value is Array:
		for child in value: _collect_parms(child, result, parameters)
