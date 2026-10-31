@tool
class_name StrataProcedural
extends RefCounted
## Standalone snapshot/transaction API. No HEGo or Houdini dependency.

## Bounds apply before native allocation. Value/coverage transport images share this
## aggregate budget (64 Mi by default, at most 512 Mi: nine 4097² channels with their
## companions); each individual image also has a 20 Mi sample cap.
const MAX_SAMPLES := 512 * 1024 * 1024
const MAX_FIELD_SAMPLES := 20 * 1024 * 1024
const DEFAULT_SAMPLES := 64 * 1024 * 1024
const OWNERSHIP_SUFFIX := "__ownership"
static var _tickets: Dictionary = {}
static var _generations: Dictionary = {}
static var _owners: Dictionary = {}
static var _reads: Dictionary = {}
static var _next_ticket := 1

static func _error(message: String) -> Dictionary:
	return {"ok": false, "message": message}

static func _fingerprint(layer: StrataLayer) -> Dictionary:
	var fields := {}
	for name in layer.procedural_fields:
		var field: StrataFieldData = layer.procedural_fields[name]
		fields[name] = field.signature() if field != null else {}
	return {"instance": layer.get_instance_id(), "parent": layer.get_parent().get_instance_id() if layer.get_parent() != null else 0, "id": layer.ensure_identity(), "data": layer.data.get_instance_id(), "revision": layer.data.get_revision(), "fields": fields, "enabled": layer.enabled, "modes": layer.composition_modes.duplicate(true), "procedural": layer.procedural, "producer": layer.producer_id, "cook_revision": layer.procedural_revision}

static func _token(layer: StrataLayer, mode: String) -> Dictionary:
	var terrain := layer.get_parent() as StrataTerrain3D
	var dependencies: Array = []
	var order: Array = []
	for entry in terrain.get_layers():
		if mode == "cumulative" or entry == layer:
			dependencies.append({"ref": weakref(entry), "state": _fingerprint(entry)})
			order.append(entry.get_instance_id())
		if mode == "cumulative" and entry == layer:
			break
	return {"terrain": weakref(terrain), "selected": weakref(layer), "mode": mode, "layers": dependencies, "order": order, "bounds": terrain.base_bounds, "transform": terrain.global_transform}

static func revision_token(layer: StrataLayer, mode: String = "raw") -> Dictionary:
	return _token(layer, mode)

## Small captured descriptor list; native code performs all per-pixel work.
## Macro tint/AO channels start from their full-coverage neutral 1 base.
static func _capture_layers(terrain: StrataTerrain3D, channel: StringName, through_layer: StrataLayer) -> Array:
	var descriptors: Array = []
	if StrataMacro.is_macro_channel(channel):
		descriptors.append(StrataMacro.neutral_descriptor(channel, terrain.base_bounds))
	for layer in terrain.get_layers():
		if layer.enabled:
			var field: StrataFieldData = layer.procedural_fields.get(String(channel))
			var storage := layer.get_channel_data(channel)
			var origin := field.sample_origin if field != null else Vector3(storage.grid_origin.x, 0.0, storage.grid_origin.y)
			var sx := field.sample_step_x if field != null else Vector3(storage.sample_spacing, 0.0, 0.0)
			var sy := field.sample_step_y if field != null else Vector3(0.0, 0.0, storage.sample_spacing)
			descriptors.append({"data": storage, "origin": origin, "step_x": sx, "step_y": sy, "mode": layer.get_composition(channel), "imported_field": field != null, "height_offset": origin.y if field != null and channel == &"height" and layer.get_composition(channel) == StrataLayer.Composition.REPLACE else 0.0})
		if layer == through_layer: break
	return descriptors

## Bounded compiled runtime field. Includes both endpoints, so nonintegral
## requested spacings return their actual endpoint-aligned step explicitly.
## No live resources or images are exposed through the independent output RF.
static func compile_heightfield(terrain: StrataTerrain3D, through_layer: StrataLayer = null, spacing: float = 1.0, options: Dictionary = {}) -> Dictionary:
	if not is_instance_valid(terrain) or not terrain.is_inside_tree() or not terrain.is_transform_valid() or not is_finite(spacing) or spacing <= 0.0:
		return _error("Compilation requires a live valid terrain and positive finite spacing")
	var layers := terrain.get_layers()
	if through_layer != null and (not is_instance_valid(through_layer) or through_layer.get_parent() != terrain or not layers.has(through_layer)):
		return _error("Compilation cutoff must be a live direct terrain layer")
	var bounds: Rect2 = options.get("bounds", terrain.base_bounds)
	if not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite() or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return _error("Compilation bounds must be finite and positive")
	var limit := clampi(int(options.get("max_samples", MAX_FIELD_SAMPLES)), 1, MAX_FIELD_SAMPLES)
	var columns := bounds.size.x / spacing
	var rows := bounds.size.y / spacing
	if not is_finite(columns) or not is_finite(rows) or columns >= limit or rows >= limit:
		return _error("Compiled field exceeds its bounded sample budget")
	var width := ceili(columns) + 1
	var height := ceili(rows) + 1
	if width < 2 or height < 2 or width > limit or height > limit or width * height > limit:
		return _error("Compiled field exceeds its bounded sample budget")
	var sx := Vector3(bounds.size.x / (width - 1), 0.0, 0.0)
	var sy := Vector3(0.0, 0.0, bounds.size.y / (height - 1))
	var origin := Vector3(bounds.position.x, 0.0, bounds.position.y)
	var output: Dictionary = StrataLayerData.compose_dense(_capture_layers(terrain, &"height", through_layer), &"height", origin, sx, sy, Vector2i(width, height), terrain.base_bounds, bool(options.get("include_coverage", false)), 0.0)
	if not output.ok: return output
	var token := _token(through_layer if through_layer != null else layers[-1], "cumulative") if not layers.is_empty() else {"terrain": weakref(terrain), "mode": "empty", "bounds": terrain.base_bounds, "transform": terrain.global_transform}
	output.merge({"bounds": bounds, "resolution": Vector2i(width, height), "sample_origin": origin, "sample_step_x": sx, "sample_step_y": sy, "token": token}, true)
	return output

## Canonical categorical cell masks. Authored Hole/Solid are binary Replace
## regions, not bilinear intensities. Continuous sources need explicit mapping.
## Ownership is resolved before conservative overlap reduction, so upper Solid
## can restore lower holes while very narrow remaining exclusions still survive.
static func compile_cell_masks(terrain: StrataTerrain3D, through_layer: StrataLayer = null, spacing: float = 1.0, options: Dictionary = {}) -> Dictionary:
	if not is_instance_valid(terrain) or not terrain.is_inside_tree() or not terrain.is_transform_valid() or not is_finite(spacing) or spacing <= 0:
		return _error("Cell compilation requires a live valid terrain and positive finite spacing")
	var layers := terrain.get_layers()
	if through_layer != null and (not is_instance_valid(through_layer) or through_layer.get_parent() != terrain or not layers.has(through_layer)):
		return _error("Cell compilation cutoff must be a live direct terrain layer")
	var bounds: Rect2 = options.get("bounds", terrain.base_bounds)
	if not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite() or bounds.size.x <= 0 or bounds.size.y <= 0:
		return _error("Cell compilation bounds must be finite and positive")
	var limit := clampi(int(options.get("max_samples", MAX_FIELD_SAMPLES)), 1, MAX_FIELD_SAMPLES)
	var nx := bounds.size.x / spacing
	var ny := bounds.size.y / spacing
	if not is_finite(nx) or not is_finite(ny) or nx >= limit or ny >= limit:
		return _error("Canonical cell grid exceeds its bounded sample budget")
	var resolution := Vector2i(ceili(nx) + 1, ceili(ny) + 1)
	if resolution.x * resolution.y > limit: return _error("Canonical cell grid exceeds its bounded sample budget")
	var converted := PackedStringArray(options.get("continuous_channels", []))
	var thresholds: Dictionary = options.get("thresholds", {})
	var results: Array[Dictionary] = []
	for channel in [String(options.get("hole_channel", "hole")), String(options.get("nav_exclusion_channel", "nav_exclusion"))]:
		if channel.strip_edges().is_empty(): return _error("Canonical mask channel names must be nonempty")
		var captured := _capture_layers(terrain, StringName(channel), through_layer)
		for descriptor in captured:
			descriptor.mapping = "threshold" if converted.has(channel) and descriptor.imported_field else "binary"
			descriptor.threshold = float(thresholds.get(channel, 0.5))
		var compiled: Dictionary = StrataLayerData.compile_cell_mask(captured, StringName(channel), bounds, resolution, int(options.get("max_work", 268435456)), int(options.get("max_fragments", 4096)))
		if not compiled.ok: return compiled
		results.append(compiled)
	var token := _token(through_layer if through_layer != null else layers[-1], "cumulative") if not layers.is_empty() else {"terrain": weakref(terrain), "mode": "empty", "bounds": terrain.base_bounds, "transform": terrain.global_transform}
	return {"ok": true, "bounds": bounds, "resolution": resolution, "holes": results[0].mask, "nav_exclusions": results[1].mask, "hole_image": results[0].image, "nav_exclusion_image": results[1].image, "token": token, "report": {"hole_cells": results[0].count, "nav_excluded_cells": results[1].count, "work": int(results[0].work) + int(results[1].work), "policy": results[0].policy, "boundary_expansion": results[0].boundary_expansion, "cell_size": bounds.size / Vector2(resolution - Vector2i.ONE), "continuous_channels": converted, "thresholds": thresholds.duplicate(true)}}

static func token_is_current(token: Dictionary) -> bool:
	if not token.has("terrain") or not token.terrain is WeakRef: return false
	var terrain: StrataTerrain3D = token.terrain.get_ref()
	if token.get("mode") == "empty":
		return is_instance_valid(terrain) and terrain.is_inside_tree() and terrain.get_layers().is_empty() and terrain.base_bounds == token.bounds and terrain.global_transform == token.transform
	if not token.has("selected"): return false
	var selected: StrataLayer = token.selected.get_ref()
	if not is_instance_valid(terrain) or not is_instance_valid(selected) or not terrain.is_inside_tree() or not selected.is_inside_tree() or selected.get_parent() != terrain or terrain.base_bounds != token.bounds or terrain.global_transform != token.transform:
		return false
	var current := _token(selected, token.mode)
	if current.order != token.order:
		return false
	for dependency in token.layers:
		var layer: StrataLayer = dependency.ref.get_ref()
		if not is_instance_valid(layer) or _fingerprint(layer) != dependency.state:
			return false
	return true

## A snapshot is independent RF images plus a read-set revision token. Cumulative
## images sample through the selected layer; raw images preserve native values.
## Separate `<channel>__ownership` fields are binary, with an explicit role.
## Cumulative option spacing: sample every channel on one endpoint-aligned
## lattice over bounds (default base_bounds) instead of the selected layer's
## native lattice, e.g. a coarse view through a fine 0.25 m manual layer.
## channel_spacings overrides spacing for named channels only; omitted channels
## keep spacing or their existing native lattice. Value/coverage stay paired.
static func create_snapshot(layer: StrataLayer, mode: String = "cumulative", options: Dictionary = {}) -> Dictionary:
	if not is_instance_valid(layer) or not layer.is_inside_tree() or not layer.get_parent() is StrataTerrain3D or mode not in ["cumulative", "raw"]:
		return _error("A snapshot needs a live terrain layer and cumulative/raw mode")
	var terrain := layer.get_parent() as StrataTerrain3D
	if not terrain.is_transform_valid():
		return _error("Terrain snapshots require translation/yaw and unit scale")
	var channels := PackedStringArray(options.get("channels", []))
	if channels.is_empty():
		if mode == "raw":
			channels = layer.get_channel_names()
		else:
			for entry in terrain.get_layers():
				for name in entry.get_channel_names():
					if not channels.has(name): channels.append(name)
				if entry == layer: break
	if channels.is_empty(): channels.append("height")
	var limit := clampi(int(options.get("max_samples", DEFAULT_SAMPLES)), 1, MAX_SAMPLES)
	var overrides: Variant = options.get("channel_spacings", {})
	if not overrides is Dictionary: return _error("Snapshot channel_spacings must map channel names to positive metres")
	if (options.has("spacing") or not overrides.is_empty()) and mode != "cumulative": return _error("Snapshot spacing applies to cumulative snapshots only")
	for name in overrides:
		if not channels.has(String(name)): return _error("Snapshot spacing override names must be exported channels")
	var grids := {}
	for name in channels:
		if not overrides.has(name) and not options.has("spacing"): continue
		var spacing := float(overrides.get(name, options.get("spacing", 0.0)))
		var region: Rect2 = options.get("bounds", terrain.base_bounds)
		if not is_finite(spacing) or spacing <= 0.0 or not region.position.is_finite() or not region.size.is_finite() or not region.end.is_finite() or region.size.x <= 0.0 or region.size.y <= 0.0:
			return _error("Snapshot spacing and bounds must be finite and positive")
		var columns := region.size.x / spacing
		var rows := region.size.y / spacing
		if not is_finite(columns) or not is_finite(rows) or columns >= MAX_FIELD_SAMPLES or rows >= MAX_FIELD_SAMPLES:
			return _error("Snapshot exceeds its bounded sample budget; choose coarser input spacing/bounds")
		var size := Vector2i(ceili(columns) + 1, ceili(rows) + 1)
		grids[name] = {"origin": Vector3(region.position.x, 0.0, region.position.y), "step_x": Vector3(region.size.x / (size.x - 1), 0.0, 0.0), "step_y": Vector3(0.0, 0.0, region.size.y / (size.y - 1)), "maximum": size - Vector2i.ONE}
	# Preflight every value and companion lattice before native allocation.
	var layouts: Array = []
	var sample_count := 0
	var seen_channels := {}
	for name in channels:
		if name.strip_edges().is_empty() or name.ends_with(OWNERSHIP_SUFFIX) or seen_channels.has(name):
			return _error("Blank/reserved ownership channel names cannot be exported")
		seen_channels[name] = true
		var resampled: Dictionary = grids.get(name, {})
		var imported: StrataFieldData = layer.procedural_fields.get(name)
		var storage := layer.get_channel_data(StringName(name))
		var origin := imported.sample_origin if imported != null else Vector3(storage.grid_origin.x, 0.0, storage.grid_origin.y)
		var step_x := imported.sample_step_x if imported != null else Vector3(storage.sample_spacing, 0.0, 0.0)
		var step_y := imported.sample_step_y if imported != null else Vector3(0.0, 0.0, storage.sample_spacing)
		if not resampled.is_empty():
			origin = resampled.origin; step_x = resampled.step_x; step_y = resampled.step_y
		if not origin.is_finite() or not step_x.is_finite() or not step_y.is_finite() or step_x.length_squared() <= 0.0 or step_y.length_squared() <= 0.0 or absf(step_x.dot(step_y)) > step_x.length() * step_y.length() * 0.00001:
			return _error("Snapshot source has an invalid native sampling basis")
		var basis := Transform2D(Vector2(step_x.x, step_x.z), Vector2(step_y.x, step_y.z), Vector2(origin.x, origin.z))
		var minimum := Vector2i.ZERO
		var maximum := imported.resolution - Vector2i.ONE if imported != null else Vector2i.ZERO
		var owned_rect := storage.get_owned_rect(StringName(name)) if mode == "raw" and imported == null else Rect2i()
		if mode == "raw" and imported == null:
			if owned_rect.has_area():
				minimum = owned_rect.position; maximum = owned_rect.end - Vector2i.ONE
			elif storage.get_channel_names().has(name):
				return _error("Raw owned sample rectangle exceeds signed coordinate range")
			# Keep the established full-bounds empty raw field by default. UI
			# overlays can request compact_empty for a single unowned sample.
		if not resampled.is_empty():
			maximum = resampled.maximum
		elif mode == "cumulative" or (mode == "raw" and imported == null and not owned_rect.has_area() and not bool(options.get("compact_empty", false))):
			var bounds: Rect2 = options.get("bounds", terrain.base_bounds)
			if not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size.x < 0.0 or bounds.size.y < 0.0:
				return _error("Invalid snapshot bounds")
			var inverse := basis.affine_inverse()
			var low := Vector2(INF, INF); var high := Vector2(-INF, -INF)
			for corner in [bounds.position, bounds.end, Vector2(bounds.position.x, bounds.end.y), Vector2(bounds.end.x, bounds.position.y)]:
				var logical: Vector2 = inverse * corner
				low = low.min(logical); high = high.max(logical)
			if not low.is_finite() or not high.is_finite() or low.x < -2147483648.0 or low.y < -2147483648.0 or high.x > 2147483646.0 or high.y > 2147483646.0:
				return _error("Snapshot lattice exceeds integer coordinate range")
			minimum = Vector2i(floor(low.x), floor(low.y)); maximum = Vector2i(ceil(high.x), ceil(high.y))
		var width := maximum.x - minimum.x + 1
		var height := maximum.y - minimum.y + 1
		if width < 1 or height < 1 or width > MAX_FIELD_SAMPLES or height > MAX_FIELD_SAMPLES or width * height > MAX_FIELD_SAMPLES or width * height * 2 + sample_count > limit:
			return _error("Snapshot exceeds its bounded sample budget; choose coarser input spacing/bounds")
		sample_count += width * height * 2
		var start := origin + step_x * minimum.x + step_y * minimum.y
		var attrs := imported.attrs.duplicate(true) if imported != null and resampled.is_empty() else {}
		if not resampled.is_empty(): attrs["resampled_spacing"] = step_x.x
		attrs.merge({"role": "value", "channel": name, "snapshot_mode": mode, "composition": "add" if mode == "raw" and layer.get_composition(StringName(name)) == StrataLayer.Composition.ADD else "replace"}, true)
		layouts.append({"name": name, "storage": storage, "minimum": minimum, "resolution": Vector2i(width, height), "origin": start, "step_x": step_x, "step_y": step_y, "height_offset": origin.y if name == "height" else 0.0, "attrs": attrs})
	var fields: Array = []
	for layout in layouts:
		var name: String = layout.name
		var dense: Dictionary
		if mode == "raw":
			dense = layout.storage.read_dense(StringName(name), layout.minimum, layout.resolution)
		else:
			dense = StrataLayerData.compose_dense(_capture_layers(terrain, StringName(name), layer), StringName(name), layout.origin, layout.step_x, layout.step_y, layout.resolution, terrain.base_bounds, true, layout.height_offset)
		if not dense.ok: return dense
		fields.append({"name": name, "image": dense.image, "sample_origin": layout.origin, "sample_step_x": layout.step_x, "sample_step_y": layout.step_y, "attrs": layout.attrs})
		fields.append({"name": name + OWNERSHIP_SUFFIX, "image": dense.ownership if mode == "raw" else dense.coverage, "sample_origin": layout.origin, "sample_step_x": layout.step_x, "sample_step_y": layout.step_y, "attrs": {"role": "ownership" if mode == "raw" else "coverage", "channel": name, "snapshot_mode": mode}})
	return {"ok": true, "message": "%s snapshot: %d fields, %d samples" % [mode, fields.size(), sample_count], "fields": fields, "token": _token(layer, mode), "mode": mode}

static func _target_order(layer: StrataLayer) -> Array:
	var result: Array = []
	for entry in (layer.get_parent() as StrataTerrain3D).get_layers(): result.append(entry.get_instance_id())
	return result

## Whether [param layer] is claimed by a producer other than [param host] and
## [param producer]. With a recorded [member StrataLayer.producer_path] the claim lasts only
## while that path names another node, so a renamed or deleted producer does not lock its
## layers; without one the recorded identity alone decides.
static func _claimed_by_other(layer: StrataLayer, host: Node, producer: String) -> bool:
	if layer.producer_id.is_empty() or layer.producer_id == producer: return false
	if layer.producer_path.is_empty(): return true
	var recorded := layer.get_node_or_null(layer.producer_path)
	return recorded != null and recorded != host

## Prepares one all-or-nothing publication by [param producer], a live [param host], into
## [param targets] ([code]{layer, channels, required_channels}[/code] each; with no
## [code]channels[/code] every channel is accepted and none is required) from [param inputs],
## the snapshots it read. [param context] may hold a [code]guard[/code] Callable that must
## still return true at commit, and a [code]signature[/code] Dictionary recorded on every
## published layer as [member StrataLayer.producer_signature].
static func begin_transaction(host: Node, producer: String, targets: Array, inputs: Array, context: Dictionary = {}) -> Dictionary:
	if not is_instance_valid(host) or not host.is_inside_tree() or producer.is_empty() or targets.is_empty(): return _error("Declare a live scene host, producer and expected procedural targets")
	var key := "%d/%s" % [host.get_instance_id(), producer]
	var declared: Dictionary = {}
	var target_instances: Array = []
	for target in targets:
		var layer: StrataLayer = target.get("layer")
		if not is_instance_valid(layer) or not layer.is_inside_tree() or not layer.get_parent() is StrataTerrain3D or not layer.procedural:
			return _error("Every target must be an explicitly procedural terrain layer")
		if not layer.data.get_channel_names().is_empty(): return _error("A procedural target contains manual data; move those edits to a manual layer")
		var identity := layer.ensure_identity()
		for sibling in (layer.get_parent() as StrataTerrain3D).get_layers():
			if sibling != layer and sibling.ensure_identity() == identity: return _error("Duplicate persistent layer identity in one terrain")
		if declared.has(identity): return _error("Ambiguous/duplicate target identity")
		if _claimed_by_other(layer, host, producer): return _error("A target already belongs to another producer")
		var owner: Dictionary = _owners.get(layer.get_instance_id(), {})
		if not owner.is_empty() and is_instance_valid(owner.host.get_ref()) and owner.key != key: return _error("One live producer already owns this target")
		var channels := PackedStringArray(target.get("channels", []))
		for name in channels:
			if name.strip_edges().is_empty() or name.ends_with(OWNERSHIP_SUFFIX): return _error("Target channel names cannot be blank or reserved ownership names")
		var required := PackedStringArray(target.get("required_channels", ["height"] if channels.has("height") else []))
		for name in required:
			if name.strip_edges().is_empty() or not channels.is_empty() and not channels.has(name): return _error("Required channels must be declared as permitted channels")
		var terrain := layer.get_parent() as StrataTerrain3D
		declared[identity] = {"ref": weakref(layer), "state": _fingerprint(layer), "order": _target_order(layer), "channels": channels, "required": required, "terrain_bounds": terrain.base_bounds, "terrain_transform": terrain.global_transform}
		target_instances.append(layer.get_instance_id())
	var read_layers: Array = []
	var tokens: Array = []
	for input in inputs:
		if not input.get("ok", false) or not token_is_current(input.token): return _error("Input snapshot is already stale or invalid")
		tokens.append(input.token.duplicate(true))
		for dependency in input.token.layers:
			var layer: StrataLayer = dependency.ref.get_ref()
			if target_instances.has(layer.get_instance_id()): return _error("Terrain dependency cycle: an output occurs in its own input read set")
			read_layers.append(dependency.ref)
	var proposed_owners := _owners.duplicate()
	for id in target_instances: proposed_owners[id] = {"host": weakref(host), "key": key}
	var proposed_reads := _reads.duplicate()
	proposed_reads[key] = read_layers
	if _cycle(key, proposed_owners, proposed_reads, [], {}): return _error("Terrain producer dependency cycle")
	_owners = proposed_owners; _reads = proposed_reads
	_generations[key] = int(_generations.get(key, 0)) + 1
	var id := _next_ticket; _next_ticket += 1
	_tickets[id] = {"host": weakref(host), "producer": producer, "key": key, "generation": _generations[key], "targets": declared, "inputs": tokens, "context": context.duplicate(true)}
	for target in declared.values():
		var layer: StrataLayer = target.ref.get_ref()
		layer.procedural_stale = true
		layer.procedural_status = "Cooking generation %d; previous cache retained" % _generations[key]
	return {"ok": true, "message": "Transaction prepared", "id": id, "generation": _generations[key], "target_ids": PackedStringArray(declared.keys())}

static func _cycle(key: String, owners: Dictionary, reads: Dictionary, stack: Array, complete: Dictionary) -> bool:
	if stack.has(key): return true
	if complete.has(key): return false
	var path := stack.duplicate(); path.append(key)
	for reference in reads.get(key, []):
		var layer: StrataLayer = reference.get_ref()
		if is_instance_valid(layer) and owners.has(layer.get_instance_id()):
			var owner: Dictionary = owners[layer.get_instance_id()]
			if is_instance_valid(owner.host.get_ref()) and _cycle(owner.key, owners, reads, path, complete): return true
	complete[key] = true
	return false

static func _current(state: Dictionary) -> bool:
	if not is_instance_valid(state.host.get_ref()) or not state.host.get_ref().is_inside_tree() or _generations.get(state.key) != state.generation: return false
	for token in state.inputs:
		if not token_is_current(token): return false
	for target in state.targets.values():
		var layer: StrataLayer = target.ref.get_ref()
		if not is_instance_valid(layer) or not layer.is_inside_tree() or _fingerprint(layer) != target.state or _target_order(layer) != target.order: return false
		var terrain := layer.get_parent() as StrataTerrain3D
		if terrain.base_bounds != target.terrain_bounds or terrain.global_transform != target.terrain_transform: return false
	var guard: Callable = state.context.get("guard", Callable())
	return not guard.is_valid() or bool(guard.call())

static func reject(ticket: Dictionary, message: String) -> Dictionary:
	var state: Dictionary = _tickets.get(ticket.get("id", -1), {})
	if not state.is_empty():
		for target in state.targets.values() if _generations.get(state.key) == state.generation else []:
			var layer: StrataLayer = target.ref.get_ref()
			if is_instance_valid(layer):
				layer.procedural_stale = true
				layer.procedural_status = "Cook rejected; previous cache retained: " + message
		_tickets.erase(ticket.id)
	return _error(message)

static func validate_field(field: Dictionary) -> Dictionary:
	if not field.get("name") is String or String(field.name).strip_edges().is_empty() or String(field.name).ends_with(OWNERSHIP_SUFFIX): return _error("Invalid/reserved result channel name")
	var image: Image = field.get("image")
	if image == null or image.get_format() != Image.FORMAT_RF or image.get_width() < 1 or image.get_height() < 1 or image.get_width() * image.get_height() > MAX_FIELD_SAMPLES: return _error("Each result needs a bounded, nonempty RF image")
	for property in ["sample_origin", "sample_step_x", "sample_step_y"]:
		if not field.get(property) is Vector3 or not field[property].is_finite(): return _error("Result field basis must be finite Vector3 values")
	var x: Vector3 = field.sample_step_x; var y: Vector3 = field.sample_step_y
	if absf(x.y) > 0.000001 or absf(y.y) > 0.000001 or x.length_squared() <= 0.0 or y.length_squared() <= 0.0 or absf(x.dot(y)) > x.length() * y.length() * 0.00001: return _error("Terrain fields require nonzero horizontal orthogonal sample steps")
	if field.get("composition", "replace") not in ["replace", "add"]: return _error("Unknown field composition; expected replace/add")
	if not field.get("attrs", {}) is Dictionary: return _error("Field attrs must be a Dictionary")
	if field.get("attrs", {}).get("role", "value") != "value": return _error("Ownership/coverage metadata volumes cannot become ordinary scalar channels")
	var owned: Image = field.get("ownership")
	if owned != null and (owned.get_format() != Image.FORMAT_RF or owned.get_size() != image.get_size()): return _error("Ownership must be an independent matching RF image")
	return StrataLayerData.validate_dense(image, owned)

static func commit_fields(ticket: Dictionary, results: Array) -> Dictionary:
	var state: Dictionary = _tickets.get(ticket.get("id", -1), {})
	if state.is_empty(): return _error("Unknown or completed terrain transaction")
	if not _current(state): return reject(ticket, "Stale inputs, target, bindings, parameters or cook generation")
	var prepared: Dictionary = {}
	var complete_samples := 0
	for result in results:
		var identity := String(result.get("layer_id", ""))
		if not state.targets.has(identity) or prepared.has(identity): return reject(ticket, "Unexpected or duplicate output target")
		var fields: Array = result.get("fields", [])
		if fields.is_empty() and not result.get("explicit_empty", false): return reject(ticket, "Empty results require an explicit-empty marker")
		var candidate: Dictionary = {}; var modes := {}; var sample_count := 0
		for field in fields:
			var validation := validate_field(field)
			if not validation.ok: return reject(ticket, validation.message)
			var name := String(field.name)
			var permitted: PackedStringArray = state.targets[identity].channels
			if candidate.has(name) or not permitted.is_empty() and not permitted.has(name): return reject(ticket, "Unexpected or duplicate result channel")
			sample_count += field.image.get_width() * field.image.get_height()
			complete_samples += field.image.get_width() * field.image.get_height() * (2 if field.get("ownership") != null else 1)
			if sample_count > MAX_SAMPLES or complete_samples > MAX_SAMPLES: return reject(ticket, "Complete result exceeds sample budget")
			candidate[name] = StrataFieldData.from_field(field)
			if candidate[name] == null: return reject(ticket, "Native dense import rejected the field allocation or data")
			modes[name] = StrataLayer.Composition.ADD if field.get("composition", "replace") == "add" else StrataLayer.Composition.REPLACE
		if not fields.is_empty():
			for required in state.targets[identity].required:
				if not candidate.has(required): return reject(ticket, "A required result channel is missing: " + required)
		prepared[identity] = {"fields": candidate, "modes": modes}
	if prepared.size() != state.targets.size(): return reject(ticket, "A declared output target is missing; previous caches retained")
	# Final check and publication have no awaits or notifications in between.
	if not _current(state): return reject(ticket, "Cook became stale during result validation")
	var notifications: Array = []
	var host: Node = state.host.get_ref()
	var signature: Dictionary = state.context.get("signature", {})
	for identity in prepared:
		var layer: StrataLayer = state.targets[identity].ref.get_ref()
		var next_fields: Dictionary = prepared[identity].fields
		for name in next_fields:
			notifications.append(next_fields[name])
		layer.procedural_fields = next_fields
		layer.composition_modes = prepared[identity].modes
		layer.producer_id = state.producer
		layer.producer_path = layer.get_path_to(host)
		layer.producer_signature = signature.duplicate(true)
		layer.source_tokens.assign(state.inputs)
		layer.procedural_revision += 1
		layer.procedural_stale = false
		layer.procedural_status = "Committed generation %d; %d native channel fields" % [state.generation, next_fields.size()]
	_tickets.erase(ticket.id)
	for field in notifications: field.emit_changed()
	# Published results go to their fixed files when the terrain has storage. A save
	# failure does not undo the publication; the layer says it is unsaved.
	var unsaved: PackedStringArray = []
	for target in state.targets.values():
		var layer: StrataLayer = target.ref.get_ref()
		var terrain := layer.get_parent() as StrataTerrain3D
		if terrain != null and StrataStorage.has_storage(terrain):
			var saved := StrataStorage.save_procedural_fields(terrain, layer)
			if saved.ok: layer.procedural_status += "; saved to " + StrataStorage.layer_directory(terrain, layer)
			else:
				layer.procedural_status += "; NOT SAVED: " + String(saved.message)
				unsaved.append(String(layer.name))
		layer._data_changed()
	var message := "All procedural targets published atomically"
	if not unsaved.is_empty(): message += "; not saved to storage: " + ", ".join(unsaved)
	return {"ok": true, "message": message, "revision": state.generation}
