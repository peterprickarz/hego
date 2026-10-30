@tool
class_name HEGoStrataInput
extends HEGoInputHandler
## Sends Strata layers to HDA inputs as heightfield volumes.
##
## HEGo finds this handler because it extends [HEGoInputHandler]; neither HEGo nor the
## terrain addon names the other. A layer is sent either cumulatively (the composed terrain
## through that layer) or raw (its own values plus separate binary ownership), with the
## channels and spacing set in the input's settings: terrain_mode, terrain_channels,
## terrain_spacing, terrain_channel_spacings, terrain_max_samples and terrain_compact_empty.
## A host with a terrain input cooks only on request, and strictly: an input that cannot be
## sent fails the cook.

## Marks stored input settings as belonging to a terrain input, so its options and explicit
## cook rule stay in force while the source layer is missing.
const SETTINGS_MARKER := "terrain_input"


func handles(node: Node) -> bool:
	return node is StrataLayer and node.get_parent() is StrataTerrain3D


## Takes a snapshot of [param node] and uploads it. The snapshot is recorded in the cook
## dictionary ([constant HEGoStrataOutput.COOK_KEY]), so the cook's terrain publication
## can tell whether this input changed while Houdini cooked.
func sync(host: Node, existing_node: Variant, node: Node, settings: Dictionary) -> Dictionary:
	var source := snapshot(node, settings)
	var cook: Variant = settings.get("_cook")
	if cook is Dictionary and source.get("ok", false):
		HEGoStrataOutput.record_input(cook, source)
	return await upload(host, existing_node, node, source)


func claims_settings(settings: Dictionary) -> bool:
	return bool(settings.get(SETTINGS_MARKER, false))


## Terrain stages are expensive and publish into layers, so they cook only on request.
func requires_explicit_cook(_settings: Dictionary) -> bool:
	return true


## A terrain result is published all-or-nothing, so no input may be silently skipped.
func requires_strict_cook(_settings: Dictionary) -> bool:
	return true


func create_settings_editor() -> Control:
	return HEGoStrataInputSettings.new()


static func snapshot(layer: StrataLayer, settings: Dictionary) -> Dictionary:
	var channels := PackedStringArray()
	var configured: Variant = settings.get("terrain_channels", PackedStringArray(["height"]))
	if configured is String:
		for name in configured.split(",", false): channels.append(name.strip_edges())
	else:
		channels = PackedStringArray(configured)
	var options := {"channels": channels, "compact_empty": bool(settings.get("terrain_compact_empty", false))}
	if settings.has("terrain_max_samples"): options.max_samples = int(settings.terrain_max_samples)
	if settings.has("terrain_channel_spacings"): options.channel_spacings = settings.terrain_channel_spacings
	var mode := String(settings.get("terrain_mode", "cumulative"))
	# Optional cumulative resample lattice in metres (e.g. a coarse view through
	# a fine manual layer); 0 keeps the selected layer's native lattice.
	if mode == "cumulative" and settings.has("terrain_spacing"):
		var spacing := float(settings.terrain_spacing)
		if not is_finite(spacing) or spacing < 0.0: return {"ok": false, "message": "terrain_spacing must be 0 (native lattice) or positive metres"}
		if spacing > 0.0: options.spacing = spacing
	return StrataProcedural.create_snapshot(layer, mode, options)

static func upload(host: Node, existing: Variant, layer: StrataLayer, source: Dictionary) -> Dictionary:
	if not source.get("ok", false): return source
	if not StrataProcedural.token_is_current(source.token): return {"ok": false, "message": "Terrain input snapshot became stale before upload"}
	if not is_instance_valid(layer) or source.token.selected.get_ref() != layer: return {"ok": false, "message": "Terrain upload source no longer matches its snapshot"}
	var terrain := layer.get_parent() as StrataTerrain3D
	var source_transform := terrain.global_transform
	var node: HEGoHeightfieldInputNode = existing if existing is HEGoHeightfieldInputNode else HEGoHeightfieldInputNode.new()
	var fields: Array = []
	for source_field in source.fields:
		var field: Dictionary = source_field.duplicate(true)
		field.attrs = HEGoStrataOutput.to_houdini_attrs(source_field.attrs.duplicate(true))
		field.attrs[HEGoInputNodes.NODE_PATH_ATTRIB] = String(layer.get_path())
		fields.append(field)
	# Both engines use Y-up spatial coordinates here. This low-level API has no
	# implicit sign flip: images/bases stay terrain-local and the input object carries
	# the same global transform as an ordinary HEGo mesh input.
	var uploaded := await HEGoNodeUtil.checked_task(host, node.set_fields(fields))
	if not uploaded.ok: return uploaded
	if node.get_id() < 0: return {"ok": false, "message": "Could not instantiate terrain heightfield input"}
	if not StrataProcedural.token_is_current(source.token): return {"ok": false, "message": "Terrain source changed during field upload"}
	var transformed := await HEGoNodeUtil.checked_task(host, node.set_transform(source_transform, true))
	if not transformed.ok: return transformed
	if not StrataProcedural.token_is_current(source.token): return {"ok": false, "message": "Terrain input changed during upload"}
	return {"ok": true, "node": node, "message": source.message}
