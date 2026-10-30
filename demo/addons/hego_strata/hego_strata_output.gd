@tool
class_name HEGoStrataOutput
extends RefCounted
## Routes a cook's heightfields into the terrain layers an [HEGoStrataTargets] binds, and
## publishes them in one transaction. A volume names its target with the primitive
## attribute hegostrata_layer_path; the other attributes below describe its role.

## Strata stores its field metadata under plain keys (role, channel, ...). In Houdini the
## same values are primitive attributes with this prefix, so they cannot collide with an
## HDA's own attributes.
const ATTR_PREFIX := "hegostrata_"
const STRATA_KEYS := ["layer_path", "empty", "role", "channel", "composition", "snapshot_mode", "resampled_spacing"]
const TARGET_ATTR := "hegostrata_layer_path"
const EMPTY_ATTR := "hegostrata_empty"
const COMPOSITION_ATTR := "hegostrata_composition"
const ROLE_ATTR := "hegostrata_role"
const CHANNEL_ATTR := "hegostrata_channel"

## Strata field metadata as Houdini primitive attributes. Other keys pass through as-is.
static func to_houdini_attrs(attrs: Dictionary) -> Dictionary:
	var result := {}
	for key in attrs:
		result[ATTR_PREFIX + String(key) if STRATA_KEYS.has(String(key)) else key] = attrs[key]
	return result

## Fetched primitive attributes as Strata stores them, with the prefix removed.
static func from_houdini_attrs(attrs: Dictionary) -> Dictionary:
	var result := {}
	for key in attrs:
		var name := String(key)
		result[name.trim_prefix(ATTR_PREFIX) if name.begins_with(ATTR_PREFIX) else key] = attrs[key]
	return result

## Prebind every target to an instance and stable layer ID before asynchronous
## upload/cooking. Missing terrain input references fail a procedural cook.
static func prepare(host: Node, rows: Array, declarations: Array, producer: String, guard: Callable = Callable()) -> Dictionary:
	if declarations.is_empty(): return {"ok": true, "active": false, "snapshots": {}, "inputs": []}
	if not host is Node3D or not _valid_transform(host.global_transform): return {"ok": false, "message": "HEGo terrain hosts require translation/yaw with unit scale"}
	var targets: Array = []; var prebound: Dictionary = {}
	for declaration in declarations:
		var node := HEGoInputNodes._resolve_input_node(host, declaration.get("path", ""))
		if not node is StrataLayer: return {"ok": false, "message": "A declared terrain target path is missing or has the wrong type"}
		var target := {"layer": node, "channels": declaration.get("channels", PackedStringArray(["height"]))}
		if declaration.has("required_channels"): target.required_channels = declaration.required_channels
		targets.append(target)
		prebound[node.get_instance_id()] = {"ref": weakref(node), "id": node.ensure_identity()}
	var snapshots: Dictionary = {}; var inputs: Array = []
	for row in rows:
		if not row is Dictionary: continue
		var paths: Array = Array(row.get("inputs", []))
		var settings: Dictionary = row.get("settings", {})
		for path in paths:
			if not String(path).is_empty() and HEGoInputNodes._resolve_input_node(host, path) == null:
				return {"ok": false, "message": "A referenced input is missing; refusing a partial terrain cook: " + String(path)}
		for path in HEGoInputNodes.resolve_paths(host, paths, settings):
			var node := HEGoInputNodes._resolve_input_node(host, path)
			if node is StrataLayer:
				var snapshot := HEGoStrataInput.snapshot(node, settings)
				if not snapshot.ok: return snapshot
				if snapshots.has(node.get_instance_id()): return {"ok": false, "message": "One terrain layer cannot be uploaded twice with ambiguous input settings"}
				snapshots[node.get_instance_id()] = snapshot
				inputs.append(snapshot)
	var ticket := StrataProcedural.begin_transaction(host, producer, targets, inputs, {"guard": guard})
	if not ticket.ok: return ticket
	return {"ok": true, "active": true, "ticket": ticket, "snapshots": snapshots, "inputs": inputs, "prebound": prebound, "preset_before": PackedByteArray()}

static func _valid_transform(transform: Transform3D) -> bool:
	var basis := transform.basis
	return transform.origin.is_finite() and basis.y.is_equal_approx(Vector3.UP) and is_equal_approx(basis.x.length(), 1.0) and is_equal_approx(basis.z.length(), 1.0) and is_equal_approx(basis.determinant(), 1.0)

static func fail(state: Dictionary, message: String) -> Dictionary:
	if state.get("active", false): return StrataProcedural.reject(state.ticket, message)
	return {"ok": false, "message": message}

static func capture_preset(host: Node, asset: HEGoAssetNode, state: Dictionary) -> Dictionary:
	if not state.get("active", false): return {"ok": true}
	var fetched := await HEGoNodeUtil.checked_task(host, asset.get_preset())
	if not fetched.ok or not fetched.value is PackedByteArray: return fail(state, "Could not capture pre-cook HAPI parameters")
	state.preset_before = fetched.value.duplicate()
	return {"ok": true}

## [param state] is what [method prepare] returned for this cook.
static func handle(context: HEGoOutputContext, state: Dictionary) -> Dictionary:
	if not state.get("active", false): return {"ok": true, "message": "No procedural terrain bindings"}
	var fetched := await HEGoNodeUtil.checked_task(context.host, context.asset.get_heightfield_fields(PackedStringArray([TARGET_ATTR, EMPTY_ATTR, COMPOSITION_ATTR, ROLE_ATTR, CHANNEL_ATTR])))
	if not fetched.ok or not fetched.value is Array: return fail(state, "Strict heightfield fetch failed: " + fetched.get("message", "unreadable result"))
	var routed := route_fields(context.host, state, fetched.value)
	if not routed.ok: return fail(state, routed.message)
	var after := await HEGoNodeUtil.checked_task(context.host, context.asset.get_preset())
	if not after.ok or not after.value is PackedByteArray or after.value != state.preset_before:
		return fail(state, "Houdini parameters changed during this cook")
	return StrataProcedural.commit_fields(state.ticket, routed.results)

## This function also supports fixture/tests without starting a Houdini session.
static func route_fields(host: Node, state: Dictionary, fields: Array) -> Dictionary:
	var results: Dictionary = {}; var companions: Array = []
	for source in fields:
		var attrs: Dictionary = source.get("attrs", {})
		var path := String(attrs.get(TARGET_ATTR, ""))
		if path.is_empty(): continue
		var node := HEGoInputNodes._resolve_input_node(host, path)
		if not node is StrataLayer or not state.prebound.has(node.get_instance_id()): return {"ok": false, "message": "Cook routed a volume to an unbound or replaced terrain target: " + path}
		var binding: Dictionary = state.prebound[node.get_instance_id()]
		if binding.ref.get_ref() != node or node.ensure_identity() != binding.id: return {"ok": false, "message": "A bound terrain target changed identity"}
		var identity := String(binding.id)
		if not results.has(identity): results[identity] = {"layer_id": identity, "fields": [], "explicit_empty": false}
		var role := String(attrs.get(ROLE_ATTR, "value"))
		if int(attrs.get(EMPTY_ATTR, 0)) == 1:
			if role != "empty" or results[identity].explicit_empty or not results[identity].fields.is_empty(): return {"ok": false, "message": "An explicit-empty marker must be unique, have role empty and no value volumes"}
			results[identity].explicit_empty = true
			continue
		if results[identity].explicit_empty: return {"ok": false, "message": "An explicit-empty target also contains output fields"}
		if role in ["ownership", "coverage"]:
			companions.append({"target": identity, "source": source, "role": role})
			continue
		if role != "value" or String(source.get("name", "")).ends_with(StrataProcedural.OWNERSHIP_SUFFIX): return {"ok": false, "message": "Invalid scalar/ownership volume role or reserved name"}
		var field := _to_target_frame(host, node, source)
		if not field.ok: return field
		results[identity].fields.append(field.field)
	for companion in companions:
		var source: Dictionary = companion.source
		var channel := String(source.get("attrs", {}).get(CHANNEL_ATTR, ""))
		var paired := false
		for value in results[companion.target].fields:
			if value.name != channel: continue
			paired = true
			# Cumulative coverage is informational. An output owns its complete grid
			# unless the HDA explicitly returns a matching binary ownership role.
			if companion.role == "coverage": continue
			var target: StrataLayer = state.prebound.values().filter(func(entry): return entry.id == companion.target)[0].ref.get_ref()
			var converted := _to_target_frame(host, target, source, true)
			if not converted.ok: return converted
			var mask: Dictionary = converted.field
			if value.sample_origin != mask.sample_origin or value.sample_step_x != mask.sample_step_x or value.sample_step_y != mask.sample_step_y or value.image.get_size() != mask.image.get_size() or value.has("ownership"): return {"ok": false, "message": "Ownership companion has a mismatched or duplicate native grid"}
			value.ownership = mask.image
		if not paired: return {"ok": false, "message": "Ownership/coverage metadata has no matching value channel"}
	return {"ok": true, "results": results.values()}

static func _to_target_frame(host: Node3D, target: StrataLayer, source: Dictionary, metadata := false) -> Dictionary:
	if source.get("coordinate_space", "sop_local") != "sop_local": return {"ok": false, "message": "Unknown fetched heightfield coordinate space"}
	if source.get("grid_valid", true) == false: return {"ok": false, "message": source.get("grid_error", "Invalid heightfield grid")}
	for key in ["sample_origin", "sample_step_x", "sample_step_y"]:
		if not source.get(key) is Vector3: return {"ok": false, "message": "Fetched field lacks exact sample basis metadata"}
	var terrain := target.get_parent() as StrataTerrain3D
	if terrain == null or not terrain.is_transform_valid() or not _valid_transform(host.global_transform): return {"ok": false, "message": "Terrain/host transforms must remain translation/yaw and unit scale"}
	var transform := terrain.global_transform.affine_inverse() * host.global_transform
	var field := {"name": String(source.get("name", "")), "image": source.get("image"), "sample_origin": transform * source.sample_origin, "sample_step_x": transform.basis * source.sample_step_x, "sample_step_y": transform.basis * source.sample_step_y, "attrs": from_houdini_attrs(source.get("attrs", {}).duplicate(true)), "composition": String(source.get("attrs", {}).get(COMPOSITION_ATTR, "replace"))}
	if metadata: field.attrs["role"] = "value"
	return {"ok": true, "field": field}
