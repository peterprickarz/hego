@tool
class_name StrataBake
extends RefCounted
## Explicit runtime bake and export. Compiles the complete enabled stack (never
## the preview cutoff) into an StrataRuntimeData, validates every part,
## then publishes it on the terrain in one step. A failed bake leaves the
## previous runtime data and stale state untouched.

const CONTROL_MAX := 1025
## Preloaded so bakes parse before the editor has registered the class name.
const NavProfiles := preload("strata_nav_profiles.gd")

## Cheap in-session identity of everything that affects the compiled stack.
## Stored on the terrain after a bake; any difference marks the bake stale.
static func stack_signature(terrain: StrataTerrain3D) -> Array:
	var signature: Array = [terrain.base_bounds]
	for layer in terrain.get_layers():
		var fields := {}
		for name in layer.procedural_fields:
			var field: StrataFieldData = layer.procedural_fields[name]
			fields[name] = field.signature() if field != null else {}
		signature.append([layer.get_instance_id(), layer.enabled, layer.composition_modes.duplicate(true), layer.data.get_instance_id(), layer.data.get_revision(), layer.procedural, layer.procedural_revision, layer.procedural_stale if layer.procedural else false, layer.producer_id, layer.producer_intent_revision, fields])
	return signature

static func _error(message: String) -> Dictionary:
	return {"ok": false, "message": message}

## Options:
##   spacing (1.0): runtime lattice spacing; bounds must divide exactly.
##   cell_masks: true, a compile options Dictionary, or a precompiled
##     StrataProcedural.compile_cell_masks() result. Holes and navigation
##     exclusions then come from the layers' categorical hole/nav_exclusion
##     channels (ownership resolved before conservative reduction), checked
##     against the complete stack like the heights.
##   holes / nav_exclusions: explicit canonical cell masks instead, Image
##     (L8/R8/RF) or bytes, size (width - 1, height - 1). Float >= 0.5 /
##     byte >= 128 marks a cell.
##   channels: PackedStringArray of custom scalar channels to retain (deduplicated).
##   nav_profiles: Array of {"name": StringName, "rule": Dictionary} static
##     navigation profiles (StrataNavProfiles DSL), evaluated after the channels
##     and masks into data.nav_profiles (255 = blocked) with their rules in
##     data.nav_profile_rules. Rules may only reference channels retained by
##     this bake, so every mask is reproducible from the data. The "default"
##     profile is reserved and always the nav_exclusions mask. Each profile
##     costs one byte per cell of the payload budget; any invalid rule fails the
##     bake.
##   max_runtime_bytes: aggregate retained payload budget, default/max 512 MiB.
##   material_ids (RGBA8) + material_weights (RGBAF/RGBAH): optional controls.
##   allow_stale_procedural (false): accept cached procedural results that need
##     a recook (for example after a scene reload); listed in the report.
##   compiled: an existing compile_heightfield() result with a current token.
##   macro ("auto"): terrain-wide tint/AO map from the terrain_tint_r/g/b and
##     terrain_ao channels (StrataMacro). "auto" composes it only when an
##     enabled layer owns one of them; true always, false never. A Dictionary
##     is either compose options (spacing, default 4 m) or a precompiled
##     StrataMacro.compose() result with a current complete-stack token.
##   The terrain's render_settings are copied (deep duplicate) into the data.
static func compile(terrain: StrataTerrain3D, options: Dictionary = {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	if not is_instance_valid(terrain) or not terrain.is_inside_tree():
		return _error("Bake needs a live terrain inside the scene tree")
	if not terrain.is_transform_valid():
		return _error("Terrain bake requires translation/yaw and unit scale")
	var spacing := float(options.get("spacing", 1.0))
	var bounds := terrain.base_bounds
	if not is_finite(spacing) or spacing <= 0.0 or not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite() or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return _error("Bake needs positive finite spacing and terrain bounds")
	var columns := bounds.size.x / spacing
	var rows := bounds.size.y / spacing
	if not is_finite(columns) or not is_finite(rows) or columns >= StrataRuntimeData.MAX_SAMPLES or rows >= StrataRuntimeData.MAX_SAMPLES:
		return _error("Runtime bake exceeds the bounded sample budget")
	if absf(columns - roundf(columns)) > 0.0001 or absf(rows - roundf(rows)) > 0.0001:
		return _error("Terrain bounds %s are not a whole number of %s m intervals" % [bounds.size, spacing])
	var resolution := Vector2i(roundi(columns) + 1, roundi(rows) + 1)
	var sample_count := resolution.x * resolution.y
	if sample_count > StrataRuntimeData.MAX_SAMPLES: return _error("Runtime bake exceeds the bounded sample budget")
	var requested_channels := PackedStringArray()
	for name in PackedStringArray(options.get("channels", [])):
		if name == "height" or name.strip_edges().is_empty() or name.ends_with(StrataProcedural.OWNERSHIP_SUFFIX): return _error("Retained channel names must be custom, nonblank and not ownership companions")
		if not requested_channels.has(name): requested_channels.append(name)
	var payload_limit := int(options.get("max_runtime_bytes", StrataRuntimeData.MAX_PAYLOAD_BYTES))
	if payload_limit < 1 or payload_limit > StrataRuntimeData.MAX_PAYLOAD_BYTES: return _error("max_runtime_bytes must be positive and at most 512 MiB")
	var profiles: Variant = options.get("nav_profiles", [])
	var profile_check: Dictionary = NavProfiles.validate_profiles(profiles, requested_channels)
	if not profile_check.ok: return profile_check
	# Preflight the expensive full-grid custom fields before compiling heights or
	# allocating any of their value/coverage pairs. Exact mask/control bytes are
	# added below before the custom-channel loop; profiles count one byte per cell.
	var planned_bytes := sample_count * (4 + requested_channels.size() * 8) + (resolution.x - 1) * (resolution.y - 1) * (profiles as Array).size()
	if planned_bytes > payload_limit: return _error("Requested runtime heights/channels exceed the aggregate payload budget")
	var stale: PackedStringArray = []
	for layer in terrain.get_layers():
		if layer.enabled and layer.procedural and (layer.procedural_stale or layer.procedural_fields.is_empty()):
			stale.append(String(layer.name))
	if not stale.is_empty() and not options.get("allow_stale_procedural", false):
		return _error("Stale or uncooked procedural layers: %s. Recook them, or pass allow_stale_procedural to bake their cached results." % ", ".join(stale))
	var signature := stack_signature(terrain)
	var compiled: Dictionary = options.get("compiled", {})
	if compiled.is_empty():
		compiled = StrataProcedural.compile_heightfield(terrain, null, spacing, {"bounds": bounds})
	var checked := _check_compiled(terrain, compiled, resolution)
	if not checked.ok:
		return checked
	var data := StrataRuntimeData.new()
	data.bounds = bounds
	data.resolution = resolution
	data.heights = (compiled.image as Image).get_data().to_float32_array()
	data.height_min = float(checked.min)
	data.height_max = float(checked.max)
	var cells := resolution - Vector2i.ONE
	var hole_source: Variant = options.get("holes")
	var exclusion_source: Variant = options.get("nav_exclusions")
	var masks: Dictionary = {}
	var mask_request: Variant = options.get("cell_masks", false)
	if not (mask_request is bool and not mask_request):
		if hole_source != null or exclusion_source != null:
			return _error("Pass either cell_masks or explicit holes/nav_exclusions, not both")
		if mask_request is Dictionary and mask_request.has("token"):
			masks = mask_request
		else:
			var mask_options: Dictionary = mask_request.duplicate() if mask_request is Dictionary else {}
			mask_options.bounds = bounds
			masks = StrataProcedural.compile_cell_masks(terrain, null, spacing, mask_options)
		if not masks.get("ok", false):
			return _error("Cell mask compilation failed: %s" % masks.get("message", "no result"))
		if masks.get("resolution") != resolution or masks.get("bounds") != bounds:
			return _error("Compiled cell masks must use the bake's lattice")
		var mask_token := _check_token(terrain, masks.get("token"))
		if not mask_token.ok:
			return _error("Cell masks: " + mask_token.message)
		hole_source = masks.holes
		exclusion_source = masks.nav_exclusions
	var holes := StrataRuntimeData.canonicalize_cell_mask(hole_source, cells)
	if not holes.ok:
		return _error("Holes: " + holes.message)
	data.holes = holes.mask
	var exclusions := StrataRuntimeData.canonicalize_cell_mask(exclusion_source, cells)
	if not exclusions.ok:
		return _error("Navigation exclusions: " + exclusions.message)
	data.nav_exclusions = exclusions.mask
	planned_bytes += data.holes.size() + data.nav_exclusions.size()
	if options.get("material_ids") is Image: planned_bytes += (options.material_ids as Image).get_data().size()
	if options.get("material_weights") is Image: planned_bytes += (options.material_weights as Image).get_width() * (options.material_weights as Image).get_height() * 16
	if planned_bytes > payload_limit: return _error("Requested runtime masks/controls/channels exceed the aggregate payload budget")
	for name in requested_channels:
		var channel := _compile_channel(terrain, StringName(name), data)
		if not channel.ok:
			return channel
		data.channels[name] = {"values": channel.values, "coverage": channel.coverage}
		data.channel_names.append(name)
	var applied: Dictionary = NavProfiles.apply(data, profiles)
	if not applied.ok:
		return applied
	if options.has("material_ids") or options.has("material_weights"):
		var controls := _check_controls(options.get("material_ids"), options.get("material_weights"))
		if not controls.ok:
			return controls
		data.material_ids = controls.ids
		data.material_weights = controls.weights
	var macro := _compile_macro(terrain, options.get("macro", "auto"))
	if not macro.ok:
		return macro
	if macro.has("image"):
		var stored := data.set_macro(macro.image, macro.bounds)
		if not stored.ok:
			return _error("Macro map: " + stored.message)
		if data.get_manifest().total_bytes > payload_limit: return _error("Runtime macro map exceeds the aggregate payload budget")
	if terrain.render_settings != null:
		data.render_settings = terrain.render_settings.duplicate(true)
	var validation := data.validate()
	if not validation.ok:
		return validation
	# Nothing above awaits, but compile_heightfield's token is checked again so
	# an externally supplied result can never describe an older stack.
	if stack_signature(terrain) != signature or not StrataProcedural.token_is_current(compiled.token) or not masks.is_empty() and not StrataProcedural.token_is_current(masks.token) or macro.has("token") and not StrataProcedural.token_is_current(macro.token):
		return _error("Terrain stack changed while compiling; bake rejected")
	var report := {"resolution": resolution, "spacing": spacing, "stale_procedural_used": stale, "mask_source": "layers" if not masks.is_empty() else "explicit", "mask_report": masks.get("report", {}), "hole_cells": data.holes.count(StrataRuntimeData.MASK_SET), "nav_excluded_cells": data.nav_exclusions.count(StrataRuntimeData.MASK_SET), "nav_profiles": applied.report, "nav_profiles_ms": applied.ms, "macro": macro.get("report"), "manifest": data.get_manifest(), "cpu_ms": (Time.get_ticks_usec() - started) / 1000.0}
	return {"ok": true, "data": data, "signature": signature, "report": report}

## compile() and publish on success. The terrain's old bake survives failure.
static func bake(terrain: StrataTerrain3D, options: Dictionary = {}) -> Dictionary:
	var result := compile(terrain, options)
	if not result.ok:
		return result
	terrain.publish_runtime_data(result.data, result.signature)
	return result

static func _check_compiled(terrain: StrataTerrain3D, compiled: Dictionary, resolution: Vector2i) -> Dictionary:
	if not compiled.get("ok", false):
		return _error("Height compilation failed: %s" % compiled.get("message", "no result"))
	var image: Image = compiled.get("image")
	if image == null or image.get_format() != Image.FORMAT_RF or image.get_size() != resolution:
		return _error("Compiled heights must be an RF image of %s samples" % resolution)
	if compiled.get("bounds") != terrain.base_bounds:
		return _error("Compiled heights must cover the complete terrain bounds")
	if not is_finite(float(compiled.get("min", NAN))) or not is_finite(float(compiled.get("max", NAN))) or float(compiled.min) > float(compiled.max):
		return _error("Compiled heights need a finite min/max")
	var token := _check_token(terrain, compiled.get("token"))
	if not token.ok:
		return _error("Compiled heights: " + token.message)
	# Native compilation guarantees finite values; an external image is checked.
	var validation: Dictionary = StrataLayerData.validate_dense(image)
	if not validation.ok:
		return _error("Compiled heights: " + validation.message)
	return {"ok": true, "min": validation.min, "max": validation.max}

## A compile token must be current and cover the complete stack.
static func _check_token(terrain: StrataTerrain3D, token: Variant) -> Dictionary:
	if not token is Dictionary or not StrataProcedural.token_is_current(token):
		return _error("stale or missing revision token")
	var layers := terrain.get_layers()
	if token.get("mode") != "empty" and (layers.is_empty() or not token.has("selected") or token.selected.get_ref() != layers[-1] or token.get("mode") != "cumulative"):
		return _error("must include the complete stack, not a preview cutoff")
	return {"ok": true}

## Composed custom channel on the height lattice, using the native descriptor
## contract documented in terrain_layer_data.h (all per-pixel work is native).
static func _compile_channel(terrain: StrataTerrain3D, channel: StringName, data: StrataRuntimeData) -> Dictionary:
	if channel == &"height" or String(channel).strip_edges().is_empty() or String(channel).ends_with(StrataProcedural.OWNERSHIP_SUFFIX):
		return _error("Retained channel names must be custom, nonblank and not ownership companions")
	var descriptors: Array = []
	if StrataMacro.is_macro_channel(channel):
		descriptors.append(StrataMacro.neutral_descriptor(channel, terrain.base_bounds))
	for layer in terrain.get_layers():
		if not layer.enabled:
			continue
		var field: StrataFieldData = layer.procedural_fields.get(String(channel))
		var storage := layer.get_channel_data(channel)
		var origin := field.sample_origin if field != null else Vector3(storage.grid_origin.x, 0.0, storage.grid_origin.y)
		var step_x := field.sample_step_x if field != null else Vector3(storage.sample_spacing, 0.0, 0.0)
		var step_y := field.sample_step_y if field != null else Vector3(0.0, 0.0, storage.sample_spacing)
		descriptors.append({"data": storage, "origin": origin, "step_x": step_x, "step_y": step_y, "mode": layer.get_composition(channel), "height_offset": 0.0})
	var spacing := data.get_spacing()
	var origin := Vector3(data.bounds.position.x, 0.0, data.bounds.position.y)
	var composed: Dictionary = StrataLayerData.compose_dense(descriptors, channel, origin, Vector3(spacing, 0.0, 0.0), Vector3(0.0, 0.0, spacing), data.resolution, data.bounds, true, 0.0)
	if not composed.get("ok", false):
		return _error("Channel %s: %s" % [channel, composed.get("message", "composition failed")])
	return {"ok": true, "values": (composed.image as Image).get_data().to_float32_array(), "coverage": (composed.coverage as Image).get_data().to_float32_array()}

## {ok} without a map, or {ok, image, bounds, token, report}.
static func _compile_macro(terrain: StrataTerrain3D, request: Variant) -> Dictionary:
	if request is bool and not request or request is String and request == "auto" and not StrataMacro.has_macro_channels(terrain):
		return {"ok": true}
	if not (request is bool or request is Dictionary or request is String and request == "auto"):
		return _error("macro must be \"auto\", a bool, compose options or a compose() result")
	var composed: Dictionary = request if request is Dictionary and request.has("token") else StrataMacro.compose(terrain, request if request is Dictionary else {})
	if not composed.get("ok", false):
		return _error("Macro map: %s" % composed.get("message", "no result"))
	if composed.get("bounds") != terrain.base_bounds:
		return _error("Macro map must cover the complete terrain bounds")
	var token := _check_token(terrain, composed.get("token"))
	if not token.ok:
		return _error("Macro map: " + token.message)
	return {"ok": true, "image": composed.image, "bounds": composed.bounds, "token": composed.token, "report": {"resolution": composed.resolution, "spacing": composed.spacing, "owned_channels": composed.owned_channels, "min": composed.report.min, "max": composed.report.max}}

static func _check_controls(ids: Variant, weights: Variant) -> Dictionary:
	if not ids is Image or not weights is Image:
		return _error("Material controls need both an ids and a weights Image")
	var id_image: Image = ids
	var weight_image: Image = (weights as Image).duplicate()
	if id_image.get_size() != weight_image.get_size() or id_image.get_width() < 2 or id_image.get_height() < 2 or id_image.get_width() > CONTROL_MAX or id_image.get_height() > CONTROL_MAX:
		return _error("Material controls need matching 2..%d dimensions" % CONTROL_MAX)
	if id_image.get_format() != Image.FORMAT_RGBA8 or weight_image.get_format() not in [Image.FORMAT_RGBAF, Image.FORMAT_RGBAH]:
		return _error("Material ids must be RGBA8 and weights RGBAF/RGBAH")
	weight_image.convert(Image.FORMAT_RGBAF)
	for value in id_image.get_data():
		if value >= 32:
			return _error("Material ids must be in 0..31")
	for value in weight_image.get_data().to_float32_array():
		if not is_finite(value) or value < 0.0:
			return _error("Material weights must be finite and nonnegative")
	return {"ok": true, "ids": id_image.duplicate(), "weights": weight_image}

## Builds a new runtime terrain (no authoring layers, ownership or producers):
## a Node3D with the authoring terrain's local transform, the compiled data in
## meta "strata_runtime_data", and optional Collision / Navigation
## children. The authoring scene is not modified.
## Options: name, collision (bool or settings Dictionary), navigation (same),
## allow_stale_bake (false), share_data (false: copy the data; true: reference
## the terrain's published resource, avoiding a second large payload, e.g.
## when the export is saved right away).
static func export_runtime(terrain: StrataTerrain3D, options: Dictionary = {}) -> Dictionary:
	if not is_instance_valid(terrain) or terrain.runtime_data == null:
		return _error("Export needs a terrain with a published runtime bake")
	if terrain.is_runtime_bake_stale() and not options.get("allow_stale_bake", false):
		return _error("Runtime bake is stale; bake again before exporting")
	var data := terrain.runtime_data if options.get("share_data", false) else terrain.runtime_data.duplicate_runtime()
	var validation := data.validate()
	if not validation.ok:
		return validation
	var root := Node3D.new()
	root.name = String(options.get("name", String(terrain.name)))
	root.transform = terrain.transform
	root.set_meta(&"strata_runtime_data", data)
	for entry in [["collision", "Collision", StrataCollision], ["navigation", "Navigation", StrataNavigation]]:
		var settings: Variant = options.get(entry[0], false)
		if settings is bool and not settings:
			continue
		var node: Node3D = entry[2].new()
		node.name = entry[1]
		node.data = data
		if settings is Dictionary:
			for property in settings:
				if not property in node:
					node.free()
					root.free()
					return _error("Unknown %s setting %s" % [entry[0], property])
				node.set(property, settings[property])
				if node.get(property) != settings[property]:
					node.free(); root.free()
					return _error("Invalid %s setting %s" % [entry[0], property])
		root.add_child(node)
		node.owner = root
	return {"ok": true, "root": root, "data": data}

## Packs export_runtime() into a scene. With data_path, the compiled data is
## saved as its own resource and referenced by the scene.
static func save_runtime_scene(terrain: StrataTerrain3D, path: String, options: Dictionary = {}) -> Dictionary:
	var exported := export_runtime(terrain, options)
	if not exported.ok:
		return exported
	var root: Node3D = exported.root
	var data_path := String(options.get("data_path", ""))
	if not data_path.is_empty():
		var saved := ResourceSaver.save(exported.data, data_path)
		if saved != OK:
			root.free()
			return _error("Could not save runtime data to %s (%s)" % [data_path, error_string(saved)])
		exported.data.take_over_path(data_path)
	var packed := PackedScene.new()
	var packed_error := packed.pack(root)
	root.free()
	if packed_error != OK:
		return _error("Could not pack runtime terrain (%s)" % error_string(packed_error))
	var error := ResourceSaver.save(packed, path)
	if error != OK:
		return _error("Could not save runtime scene to %s (%s)" % [path, error_string(error)])
	return {"ok": true, "path": path, "data_path": data_path}
