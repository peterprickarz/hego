@tool
class_name StrataMaterialControls
extends RefCounted
## Stage-aware material controls. Composition uses ordinary scalar ownership
## and Add/Replace rules; packing only selects/normalizes the strongest four.
## Deprecated for the editor: StrataEditorPreview composes regions with
## StrataRegions.compose_region (materials at the region spacing) and no longer uses the
## 4 m / 1025 lattice below. compose(), compose_region() and the pack helpers stay for the
## legacy 4 m / 1025 fixtures and tests (the island binding is retired); signature() is still the editor's material cache key.
const DEFAULT_SPACING := 4.0
const MAX_SIDE := 1025

static func unassigned() -> Dictionary:
	var ids := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	var weights := Image.create(2, 2, false, Image.FORMAT_RGBAF)
	return {"ok": true, "empty": true, "ids": ids, "weights": weights}

## Only material-bearing layers affect this key, and only through the material
## channels they hold: a height or mask dab on a layer that also holds material
## samples leaves it unchanged. Keep order, cutoff, enablement and modes.
static func signature(terrain: StrataTerrain3D, channels: PackedStringArray, through_layer: StrataLayer = null) -> Array:
	var state: Array = [terrain.base_bounds, terrain.global_transform, channels.duplicate(), through_layer.get_instance_id() if through_layer != null else 0]
	for layer in terrain.get_layers():
		var names := layer.get_channel_names()
		var entries: Array = []
		for channel in channels:
			if not names.has(channel): continue
			entries.append([channel, layer.get_composition(StringName(channel)), channel_signature(layer, channel)])
		if not entries.is_empty(): state.append([layer.get_instance_id(), layer.enabled, entries])
		if layer == through_layer: break
	return state

## Cache key of one channel of [param layer]: its procedural field's signature, or the
## manual data's identity and the revision at which that channel last changed.
static func channel_signature(layer: StrataLayer, channel: String) -> Variant:
	var field: StrataFieldData = layer.procedural_fields.get(channel)
	if field != null: return field.signature()
	# Builds without per-channel revisions fall back to the whole-layer revision.
	var revision: int = layer.data.call("get_channel_revision", StringName(channel)) if _native("get_channel_revision") else layer.data.get_revision()
	return [layer.data.get_instance_id(), revision]

static var _native_methods := {}

static func _native(method: StringName) -> bool:
	if not _native_methods.has(method):
		var available := ClassDB.class_has_method(&"StrataLayerData", method)
		# compose_dense gained a trailing index_offset; older builds take nine arguments.
		if method == &"compose_dense_window":
			available = ClassDB.class_get_method_argument_count(&"StrataLayerData", &"compose_dense") >= 10
		_native_methods[method] = available
	return _native_methods[method]

## The lattice compose() fills, and which channels any enabled layer through the cutoff owns.
static func _prepare(terrain: StrataTerrain3D, channels: PackedStringArray, through_layer: StrataLayer, spacing: float) -> Dictionary:
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
	var bounds := terrain.base_bounds
	if not owned.is_empty():
		if not is_finite(spacing) or spacing <= 0.0 or not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite() or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
			return {"ok": false, "message": "Material composition needs positive finite bounds and spacing"}
		if bounds.size.x / spacing > MAX_SIDE - 1 or bounds.size.y / spacing > MAX_SIDE - 1:
			return {"ok": false, "message": "Material controls exceed the bounded 1025 texel lattice"}
	var resolution := Vector2i(ceili(bounds.size.x / spacing) + 1, ceili(bounds.size.y / spacing) + 1) if not owned.is_empty() else Vector2i.ZERO
	return {"ok": true, "owned": owned, "bounds": bounds, "resolution": resolution, "origin": Vector3(bounds.position.x, 0.0, bounds.position.y), "step_x": Vector3(bounds.size.x / (resolution.x - 1), 0.0, 0.0) if not owned.is_empty() else Vector3.ZERO, "step_y": Vector3(0.0, 0.0, bounds.size.y / (resolution.y - 1)) if not owned.is_empty() else Vector3.ZERO}

static func compose(terrain: StrataTerrain3D, channels: PackedStringArray, through_layer: StrataLayer = null, spacing: float = DEFAULT_SPACING) -> Dictionary:
	var lattice := _prepare(terrain, channels, through_layer, spacing)
	if not lattice.ok: return lattice
	if lattice.owned.is_empty(): return unassigned()
	return _compose_window(terrain, channels, through_layer, lattice, Rect2i(Vector2i.ZERO, lattice.resolution))

## Recomposes only [param window], a texel rectangle of the lattice [method compose]
## fills, clipped to it. Texels compose and pack independently, so the result equals the
## same rectangle of a complete composition: {ok, ids, weights, window, empty}. Not ok
## when no layer through the cutoff owns a material channel (the complete map is then
## [method unassigned], not a lattice) or when the native window composition is missing.
static func compose_region(terrain: StrataTerrain3D, channels: PackedStringArray, through_layer: StrataLayer, window: Rect2i, spacing: float = DEFAULT_SPACING) -> Dictionary:
	if not _native(&"compose_dense_window"): return {"ok": false, "message": "Native windowed composition is unavailable"}
	var lattice := _prepare(terrain, channels, through_layer, spacing)
	if not lattice.ok: return lattice
	if lattice.owned.is_empty(): return {"ok": false, "message": "No layer owns a material channel; the complete map is unassigned"}
	window = window.intersection(Rect2i(Vector2i.ZERO, lattice.resolution))
	if not window.has_area(): return {"ok": false, "message": "The material window lies outside the lattice"}
	var packed := _compose_window(terrain, channels, through_layer, lattice, window)
	if packed.get("ok", false): packed["window"] = window
	return packed

static func _compose_window(terrain: StrataTerrain3D, channels: PackedStringArray, through_layer: StrataLayer, lattice: Dictionary, window: Rect2i) -> Dictionary:
	var zero := Image.create(window.size.x, window.size.y, false, Image.FORMAT_RF)
	# Only the mapped channels are packed: an all-zero plane can never displace one of them
	# from the top four, so padding to 32 IDs would change no ID or weight.
	var planes: Array[Image] = []
	for channel in channels:
		if not lattice.owned.has(channel): planes.append(zero); continue
		var captured := StrataProcedural._capture_layers(terrain, StringName(channel), through_layer)
		var field: Dictionary
		if window.position == Vector2i.ZERO:
			field = StrataLayerData.compose_dense(captured, StringName(channel), lattice.origin, lattice.step_x, lattice.step_y, window.size, lattice.bounds, false, 0.0)
		else:
			field = ClassDB.class_call_static(&"StrataLayerData", &"compose_dense", captured, StringName(channel), lattice.origin, lattice.step_x, lattice.step_y, window.size, lattice.bounds, false, 0.0, window.position)
		if not field.get("ok", false): return field
		planes.append(field.image)
	return _pack_sparse(planes)

## The original native producer pack deliberately rejects unassigned texels.
## Keep that contract unchanged: sparse editor maps use the native sparse pack,
## which gives unassigned texels exact zero weights/IDs. A fully assigned map
## returns exactly what the strict pack returns.
static func _pack_sparse(planes: Array[Image]) -> Dictionary:
	if _native(&"pack_material_weights_sparse"):
		var sparse: Dictionary = ClassDB.class_call_static(&"StrataLayerData", &"pack_material_weights_sparse", planes)
		if not sparse.get("ok", false):
			if String(sparse.get("message", "")).begins_with("Material weights must be finite"):
				return {"ok": false, "message": "Composed material weights must be finite"}
			return sparse
		var unassigned := int(sparse.unassigned)
		sparse.erase("unassigned")
		if unassigned == 0:
			sparse.erase("empty")
			return sparse
		# Native coverage diagnostics describe its strict producer input, not this
		# sparse editor view. Do not publish them.
		for key in ["coverage", "discarded_weight_max", "discarded_weight_mean"]: sparse.erase(key)
		return sparse
	return _pack_sparse_compat(planes)

## Builds without pack_material_weights_sparse: zero texels are temporarily made
## packable, then restored to exact zero weights/IDs in the output.
static func _pack_sparse_compat(planes: Array[Image]) -> Dictionary:
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
	# Material channels are coverage: negative values (a channel painted as a generic signed
	# channel) count as no coverage, like the native pack does.
	var prepared := planes.duplicate()
	for slot in range(prepared.size()):
		var plane: Image = prepared[slot]
		var values := plane.get_data().to_float32_array()
		var clamped := false
		for index in range(count):
			if not is_finite(values[index]):
				return {"ok": false, "message": "Composed material weights must be finite"}
			if values[index] < 0.0: values[index] = 0.0; clamped = true
			elif values[index] > 0.0: assigned[index] = 1
		if clamped: prepared[slot] = Image.create_from_data(plane.get_width(), plane.get_height(), false, Image.FORMAT_RF, values.to_byte_array())
	var first := (prepared[0] as Image).get_data().to_float32_array()
	var missing := PackedInt32Array()
	for index in range(count):
		if assigned[index] == 0: first[index] = 1.0; missing.append(index)
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
