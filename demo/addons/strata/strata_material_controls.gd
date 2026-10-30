@tool
class_name StrataMaterialControls
extends RefCounted
## Stage-aware material controls. Composition uses ordinary scalar ownership
## and Add/Replace rules; packing only selects/normalizes the strongest four.
const DEFAULT_SPACING := 4.0
const MAX_SIDE := 1025

static func unassigned() -> Dictionary:
	var ids := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	var weights := Image.create(2, 2, false, Image.FORMAT_RGBAF)
	return {"ok": true, "empty": true, "ids": ids, "weights": weights}

## Only material-bearing layers affect this key. Height-only brush edits do
## not invalidate 32 material planes. Keep order, cutoff, enablement and modes.
static func signature(terrain: StrataTerrain3D, channels: PackedStringArray, through_layer: StrataLayer = null) -> Array:
	var state: Array = [terrain.base_bounds, terrain.global_transform, channels.duplicate(), through_layer.get_instance_id() if through_layer != null else 0]
	for layer in terrain.get_layers():
		var names := layer.get_channel_names()
		var entries: Array = []
		for channel in channels:
			if not names.has(channel): continue
			var field: StrataFieldData = layer.procedural_fields.get(channel)
			entries.append([channel, layer.get_composition(StringName(channel)), field.signature() if field != null else [layer.data.get_instance_id(), layer.data.get_revision()]])
		if not entries.is_empty(): state.append([layer.get_instance_id(), layer.enabled, entries])
		if layer == through_layer: break
	return state

static func compose(terrain: StrataTerrain3D, channels: PackedStringArray, through_layer: StrataLayer = null, spacing: float = DEFAULT_SPACING) -> Dictionary:
	if not is_instance_valid(terrain) or not terrain.is_inside_tree() or not terrain.is_transform_valid():
		return {"ok": false, "message": "Material composition requires a live valid terrain"}
	if channels.is_empty() or channels.size() > 32:
		return {"ok": false, "message": "Material mapping needs one to 32 ordered scalar channels"}
	var unique := {}
	for channel in channels:
		if channel.is_empty() or unique.has(channel): return {"ok": false, "message": "Material channels must be nonempty and unique"}
		unique[channel] = true
	var layers := terrain.get_layers()
	if through_layer != null and (not is_instance_valid(through_layer) or not layers.has(through_layer)):
		return {"ok": false, "message": "Material cutoff must be a live direct terrain layer"}
	var owned := {}
	for layer in layers:
		if layer.enabled:
			for channel in layer.get_channel_names():
				if unique.has(channel): owned[channel] = true
		if layer == through_layer: break
	if owned.is_empty(): return unassigned()
	var bounds := terrain.base_bounds
	if not is_finite(spacing) or spacing <= 0.0 or not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite() or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return {"ok": false, "message": "Material composition needs positive finite bounds and spacing"}
	if bounds.size.x / spacing > MAX_SIDE - 1 or bounds.size.y / spacing > MAX_SIDE - 1:
		return {"ok": false, "message": "Material controls exceed the bounded 1025 texel lattice"}
	var resolution := Vector2i(ceili(bounds.size.x / spacing) + 1, ceili(bounds.size.y / spacing) + 1)
	var origin := Vector3(bounds.position.x, 0.0, bounds.position.y)
	var step_x := Vector3(bounds.size.x / (resolution.x - 1), 0.0, 0.0)
	var step_y := Vector3(0.0, 0.0, bounds.size.y / (resolution.y - 1))
	var zero := Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
	var planes: Array[Image] = []
	for channel in channels:
		if not owned.has(channel): planes.append(zero); continue
		var field: Dictionary = StrataLayerData.compose_dense(StrataProcedural._capture_layers(terrain, StringName(channel), through_layer), StringName(channel), origin, step_x, step_y, resolution, bounds, false, 0.0)
		if not field.get("ok", false): return field
		planes.append(field.image)
	while planes.size() < 32: planes.append(zero)
	var packed := _pack_sparse(planes)
	if packed.get("ok", false) and channels.size() < 4:
		# The strict native 32-way pack may put unused IDs into zero slots.
		# Keep every stored ID valid for a smaller generic material pool too.
		var ids: PackedByteArray = packed.ids.get_data()
		for index in range(ids.size()):
			if ids[index] >= channels.size(): ids[index] = 0
		packed.ids = Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RGBA8, ids)
	return packed

## The original native producer pack deliberately rejects unassigned texels.
## Keep that contract unchanged. Fully assigned maps take its fast path; only
## sparse editor maps need a compatibility pass. Zero texels are temporarily
## made packable, then restored to exact zero weights/IDs in the output.
static func _pack_sparse(planes: Array[Image]) -> Dictionary:
	var native := StrataLayerData.new()
	if not native.has_method("pack_material_weights"):
		return {"ok": false, "message": "Native material packing is unavailable"}
	var packed: Dictionary = native.call("pack_material_weights", planes)
	if packed.get("ok", false): return packed
	if not String(packed.get("message", "")).begins_with("Every material texel needs positive total weight"):
		return packed
	var count := planes[0].get_width() * planes[0].get_height()
	var assigned := PackedByteArray(); assigned.resize(count)
	var scanned := {}
	for plane in planes:
		if scanned.has(plane.get_instance_id()): continue
		scanned[plane.get_instance_id()] = true
		var values := plane.get_data().to_float32_array()
		for index in range(count):
			if not is_finite(values[index]) or values[index] < 0.0:
				return {"ok": false, "message": "Composed material weights must be finite and nonnegative"}
			if values[index] > 0.0: assigned[index] = 1
	var first := planes[0].get_data().to_float32_array()
	var missing := PackedInt32Array()
	for index in range(count):
		if assigned[index] == 0: first[index] = 1.0; missing.append(index)
	var prepared := planes.duplicate()
	prepared[0] = Image.create_from_data(planes[0].get_width(), planes[0].get_height(), false, Image.FORMAT_RF, first.to_byte_array())
	packed = native.call("pack_material_weights", prepared)
	if not packed.get("ok", false): return packed
	var ids: PackedByteArray = packed.ids.get_data()
	var weights: PackedFloat32Array = packed.weights.get_data().to_float32_array()
	for index in missing:
		for slot in range(4): ids[index * 4 + slot] = 0; weights[index * 4 + slot] = 0.0
	packed.ids = Image.create_from_data(planes[0].get_width(), planes[0].get_height(), false, Image.FORMAT_RGBA8, ids)
	packed.weights = Image.create_from_data(planes[0].get_width(), planes[0].get_height(), false, Image.FORMAT_RGBAF, weights.to_byte_array())
	# Native coverage diagnostics describe its strict producer input, not this
	# sparse editor view. Do not publish the temporary packing diagnostics.
	for key in ["coverage", "discarded_weight_max", "discarded_weight_mean"]: packed.erase(key)
	packed.empty = missing.size() == count
	return packed
