@tool
class_name HEGoStrataOutput
extends HEGoOutputHandler
## Publishes the heightfields a cook outputs into Strata terrain layers.
##
## HEGo runs it because it extends [HEGoOutputHandler]; neither HEGo nor Strata names it.
## A volume names its target with the primitive attribute hegostrata_layer_path, a path
## resolved like an input path (relative to the HEGo node, or to the edited or running
## scene); the HDA usually writes it from a target_layer_path parameter. Volumes without it
## belong to other handlers and are left alone. Every target must be a procedural
## [StrataLayer] of a [StrataTerrain3D], and every channel the HDA emits for it is accepted.
##
## One cook is one [StrataProcedural] transaction over all its targets: every target
## receives a complete validated result, or none does and each keeps its previous one. The
## Strata layers the host read as inputs ([HEGoStrataInput]) are the transaction's read
## set, so a result built from an input that changed while Houdini cooked is rejected, as is
## one whose target is also one of its inputs. A committed layer records the host in
## [member StrataLayer.producer_path] and [member StrataLayer.producer_id], the inputs it was
## built from, and the host's [method signature]; the bridge's editor plugin uses these to
## mark it stale when the host changes ([method poll]), and Strata itself when an input does.

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
## Primitive attributes fetched with every field.
const FETCHED_ATTRS := [TARGET_ATTR, EMPTY_ATTR, COMPOSITION_ATTR, ROLE_ATTR, CHANNEL_ATTR]
## Key the bridge keeps its per-cook state under in the shared cook dictionary
## ([member HEGoOutputContext.cook_state]): [code]inputs[/code], the snapshots
## [HEGoStrataInput] uploaded.
const COOK_KEY := "hego_strata"
## Category this file logs under, shown in the session panel filter.
const LOG_CATEGORY := "terrain"
## Status a published layer gets when its producer's inputs or parameters change.
const STALE_PRODUCER := "Producer inputs/parameters changed; explicit recook required"


# ─────────────────────────────────────────────
# HEGoOutputHandler
# ─────────────────────────────────────────────

func output_phase() -> String:
	return "strata_output"


## Any cook with volumes may carry Strata targets; [method handle] looks for them.
func should_handle(summary: Dictionary) -> bool:
	return HEGoNodeUtil.output_has(summary, "has_volumes")


## Fetches the volumes that name a Strata layer and publishes them as one transaction. A
## rejected result is logged and recorded on the layers it was meant for, or the layers this
## host published before when none could be resolved; their previous results stay in place.
func handle(context: HEGoOutputContext) -> void:
	var host := context.host
	# A cheap metadata probe first, so a cook whose volumes are not Strata's never pays for
	# the full strict sample fetch.
	var layers: Variant = await context.await_task(context.asset.get_heightfield_layers(PackedStringArray([TARGET_ATTR])))
	if layers is Array and not layers.any(_names_target):
		return
	var fetched := await HEGoNodeUtil.checked_task(host, context.asset.get_heightfield_fields(PackedStringArray(FETCHED_ATTRS)))
	if not fetched.ok or not fetched.value is Array:
		_report(host, _refuse(host, [], "Strict heightfield fetch failed: " + String(fetched.get("message", "unreadable result"))))
		return
	var fields: Array = fetched.value.filter(func(field): return field is Dictionary and not String(field.get("attrs", {}).get(TARGET_ATTR, "")).is_empty())
	if fields.is_empty():
		return
	# What the cook started from, as HEGoNode3D.cook recorded it. A host that changed while
	# Houdini cooked, or a Houdini node whose parameters no longer match, makes the result
	# stale before it is published.
	var cook := context.cook_state
	var cooked := _signature_of(_asset_name(host), cook.get("parm_stash", host.get("parm_stash")), cook.get("input_stash", host.get("input_stash")), cook.get("transform", _transform_of(host)))
	var unchanged := cooked == signature(host)
	if unchanged and cook.has("parm_stash"):
		var preset := await HEGoNodeUtil.checked_task(host, context.asset.get_preset())
		unchanged = preset.ok and preset.value is PackedByteArray and preset.value == cook.parm_stash
	if not unchanged:
		_report(host, _refuse(host, fields, "The HEGo node's parameters, inputs or transform changed during this cook"))
		return
	var guard := func() -> bool: return signature(host) == cooked
	_report(host, publish(host, fields, cook.get(COOK_KEY, {}).get("inputs", []), cooked, guard))


# ─────────────────────────────────────────────
# Publishing (also usable without Houdini)
# ─────────────────────────────────────────────

## Routes [param fields], as [method HEGoAssetNode.get_heightfield_fields] returns them, to
## the layers their hegostrata_layer_path names and publishes them in one transaction by
## [param host]. [param inputs] are the snapshots the result was built from
## ([method HEGoStrataInput.snapshot]); [param host_signature] is recorded on every published
## layer; [param guard], when valid, must still return true at commit. Fields without a
## target path are ignored. Needs no Houdini session, so tests and fixtures publish through
## it with fields of their own. Returns the transaction's [code]{ok, message}[/code].
static func publish(host: Node, fields: Array, inputs: Array, host_signature: Dictionary = {}, guard: Callable = Callable()) -> Dictionary:
	if not host is Node3D or not host.is_inside_tree() or not _valid_transform(host.global_transform):
		return _refuse(host, fields, "HEGo terrain hosts must be in the scene with translation/yaw and unit scale")
	var routed := route_fields(host, fields)
	if not routed.ok:
		return _refuse(host, fields, routed.message)
	if routed.targets.is_empty():
		return {"ok": true, "message": "No Strata targets in this cook"}
	if guard.is_valid() and not bool(guard.call()):
		return _refuse(host, fields, "The HEGo node changed during this cook")
	var ticket := StrataProcedural.begin_transaction(host, producer_id(host), routed.targets, inputs, {"guard": guard, "signature": host_signature})
	if not ticket.ok:
		return _refuse(host, fields, ticket.message)
	return StrataProcedural.commit_fields(ticket, routed.results)


## Groups [param fields] per target layer and converts each to the target terrain's frame.
## Returns [code]{ok, targets, results}[/code]: [code]targets[/code] as
## [method StrataProcedural.begin_transaction] takes them, [code]results[/code] as
## [method StrataProcedural.commit_fields] takes them; or [code]{ok: false, message}[/code].
static func route_fields(host: Node, fields: Array) -> Dictionary:
	var results: Dictionary = {}; var layers: Dictionary = {}; var companions: Array = []
	for source in fields:
		if not source is Dictionary: continue
		var attrs: Dictionary = source.get("attrs", {})
		var path := String(attrs.get(TARGET_ATTR, ""))
		if path.is_empty(): continue
		var node := HEGoInputNodes.resolve_input_node(host, path)
		if node == null: return {"ok": false, "message": "Cook routed a volume to a missing terrain layer: " + path}
		if not node is StrataLayer or not node.get_parent() is StrataTerrain3D or not node.procedural:
			return {"ok": false, "message": "Cook routed a volume to %s, which is not a procedural layer of a Strata terrain" % path}
		var identity: String = node.ensure_identity()
		if layers.has(identity) and layers[identity] != node: return {"ok": false, "message": "Two routed terrain targets share one layer identity"}
		layers[identity] = node
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
			var converted := _to_target_frame(host, layers[companion.target], source, true)
			if not converted.ok: return converted
			var mask: Dictionary = converted.field
			if value.sample_origin != mask.sample_origin or value.sample_step_x != mask.sample_step_x or value.sample_step_y != mask.sample_step_y or value.image.get_size() != mask.image.get_size() or value.has("ownership"): return {"ok": false, "message": "Ownership companion has a mismatched or duplicate native grid"}
			value.ownership = mask.image
		if not paired: return {"ok": false, "message": "Ownership/coverage metadata has no matching value channel"}
	var targets: Array = []
	for identity in layers:
		targets.append({"layer": layers[identity]})
	return {"ok": true, "targets": targets, "results": results.values()}


## Records [param snapshot], one Strata input uploaded for this cook, in the shared cook
## dictionary, so the transaction checks it is still current when it commits.
static func record_input(cook: Dictionary, snapshot: Dictionary) -> void:
	if not cook.get(COOK_KEY) is Dictionary: cook[COOK_KEY] = {}
	if not cook[COOK_KEY].get("inputs") is Array: cook[COOK_KEY].inputs = []
	cook[COOK_KEY].inputs.append(snapshot)


## The producer identity a publication by [param host] records on its layers: the host's path
## from the root of the scene it belongs to, or its absolute path when it belongs to none.
static func producer_id(host: Node) -> String:
	return String(host.owner.get_path_to(host)) if host.owner != null else String(host.get_path())


# ─────────────────────────────────────────────
# Freshness
# ─────────────────────────────────────────────

## What a published result depends on in [param host] besides its terrain inputs: the HDA,
## its parameters (as a hash of [member HEGoNode3D.parm_stash]), its input rows and its
## transform. Recorded on the layers it publishes as [member StrataLayer.producer_signature].
static func signature(host: Node) -> Dictionary:
	return _signature_of(_asset_name(host), host.get("parm_stash"), host.get("input_stash"), _transform_of(host))


## Whether the HEGo node that published [param layer] has changed since: its
## [method signature] differs from the one recorded on the layer. False when the layer
## records no producer or its producer is not an HEGo node in the tree.
static func producer_changed(layer: StrataLayer) -> bool:
	var host := _producer_of(layer)
	return host != null and not layer.producer_signature.is_empty() and signature(host) != layer.producer_signature


## The procedural layers under [param root] whose recorded producer is [param host].
static func published_layers(host: Node, root: Node = null) -> Array[StrataLayer]:
	var result: Array[StrataLayer] = []
	if host == null or not host.is_inside_tree(): return result
	_collect_layers(root if root != null else _scene_root(host), func(layer: StrataLayer): if _producer_of(layer) == host: result.append(layer))
	return result


## Makes [param host]'s [signal HEGoNode3D.cook_inputs_changed] mark the layers it published
## stale at once, rather than at the next [method poll]. Connecting twice does nothing.
static func watch(host: Node) -> void:
	if not host is HEGoNode3D: return
	for connection in host.cook_inputs_changed.get_connections():
		if connection.callable.get_method() == &"inputs_changed": return
	host.cook_inputs_changed.connect(Callable(HEGoStrataOutput, &"inputs_changed").bind(host))


## Marks every layer [param host] published stale, with new producer intent, because its
## inputs or parameters changed. Also for layers that are already stale, so a runtime bake of
## them goes stale too.
static func inputs_changed(host: Node) -> void:
	for layer in published_layers(host):
		layer.mark_stale(STALE_PRODUCER)


## One pass of the bridge's editor watch over the scene under [param root]: [method watch]es
## every HEGo node, and marks every current procedural layer stale whose producer changed
## since it published ([method producer_changed]). The bridge's editor plugin runs this a few
## times a second; a changed input layer is Strata's own check
## ([method StrataTerrain3D.check_procedural_sources]).
static func poll(root: Node) -> void:
	if root == null: return
	_poll_node(root)


static func _poll_node(node: Node) -> void:
	if node is HEGoNode3D:
		watch(node)
	elif node is StrataLayer and node.procedural and not node.procedural_stale and producer_changed(node):
		node.mark_stale(STALE_PRODUCER)
	for child in node.get_children():
		_poll_node(child)


# ─────────────────────────────────────────────
# Houdini attribute names
# ─────────────────────────────────────────────

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


# ─────────────────────────────────────────────
# Internals
# ─────────────────────────────────────────────

static func _signature_of(asset: String, parameters: Variant, inputs: Variant, transform: Variant) -> Dictionary:
	var hashing := HashingContext.new(); hashing.start(HashingContext.HASH_SHA256)
	if parameters is PackedByteArray and not parameters.is_empty(): hashing.update(parameters)
	return {"asset": asset, "parameters": hashing.finish().hex_encode(), "inputs": inputs.duplicate(true) if inputs is Array else [], "transform": transform if transform is Transform3D else Transform3D()}

static func _names_target(layer: Variant) -> bool:
	var path: Variant = HEGoNodeUtil.get_attrib_value(layer, "attrs", TARGET_ATTR) if layer is Dictionary else null
	return path != null and not str(path).is_empty()

static func _asset_name(host: Node) -> String:
	var asset: Variant = host.get("asset_name")
	return String(asset) if asset is String else ""

static func _transform_of(host: Node) -> Transform3D:
	if not host is Node3D: return Transform3D()
	return host.global_transform if host.is_inside_tree() else host.transform

static func _producer_of(layer: StrataLayer) -> HEGoNode3D:
	if layer.producer_path.is_empty() or not layer.is_inside_tree(): return null
	return layer.get_node_or_null(layer.producer_path) as HEGoNode3D

static func _scene_root(host: Node) -> Node:
	var tree := host.get_tree()
	for scene in [tree.edited_scene_root, tree.current_scene]:
		if scene != null and (scene == host or scene.is_ancestor_of(host)): return scene
	return tree.root

static func _collect_layers(node: Node, visit: Callable) -> void:
	if node is StrataLayer: visit.call(node)
	for child in node.get_children():
		_collect_layers(child, visit)

## Rejects a result before or without a transaction: every procedural layer [param fields]
## name, or else every layer [param host] published before, says why and keeps its result.
static func _refuse(host: Node, fields: Array, message: String) -> Dictionary:
	var marked: Array = []
	if host != null and host.is_inside_tree():
		for source in fields:
			var path := String(source.get("attrs", {}).get(TARGET_ATTR, "")) if source is Dictionary else ""
			var node := HEGoInputNodes.resolve_input_node(host, path)
			if node is StrataLayer and node.procedural and not marked.has(node): marked.append(node)
		if marked.is_empty(): marked.assign(published_layers(host))
	for layer in marked:
		layer.procedural_stale = true
		layer.procedural_status = "Cook rejected; previous cache retained: " + message
	return {"ok": false, "message": message}

static func _report(host: Node, result: Dictionary) -> void:
	var message := String(result.get("message", "Unknown terrain cook status"))
	if result.get("ok", false): HEGoLog.get_singleton().info(LOG_CATEGORY, "%s: %s" % [host.name, message])
	else: HEGoLog.get_singleton().warning(LOG_CATEGORY, "%s: %s" % [host.name, message])

static func _valid_transform(transform: Transform3D) -> bool:
	var basis := transform.basis
	return transform.origin.is_finite() and basis.y.is_equal_approx(Vector3.UP) and is_equal_approx(basis.x.length(), 1.0) and is_equal_approx(basis.z.length(), 1.0) and is_equal_approx(basis.determinant(), 1.0)

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
