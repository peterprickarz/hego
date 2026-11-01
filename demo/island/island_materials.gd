class_name HEGoIslandMaterials
extends HEGoIslandMaterialRegistry
## Houdini authoring adapter. Habitat placement is authored only in the HDA.
const CONTRACT := "res://island/hda/material_contract.json"
const LAYER := "MaterialDistribution"
const HOST := "HDA/MaterialCook"
const LAYER_ID := "bracken-isle-material-distribution-v1"
## The MaterialCook input lattice of scenes cooked before the regions work (1025 samples).
const LEGACY_SPACING := 4.0
## Largest lattice, per axis, one cook of the material HDA accepts (its MAX_SAMPLES); a larger
## one is cooked in tiles ([method cook]).
const TILE_SAMPLES := 4097
## Samples two neighbouring tiles share by default. The tile edges are cut in the middle of the
## overlap, so a tile owns everything but overlap/2 samples of each interior edge. This is a
## fast default, not an exact one: see [method exact_overlap].
const TILE_OVERLAP := 32
## Value storage of a tiled result: 8-bit channels (the shipped default, a quarter of the
## bytes) or 32-bit floats.
const STORAGE_UNORM8 := "unorm8"
const STORAGE_FLOAT := "float"
## The material HDA's widest smoothing (the 150 m shelter Gaussian) and its default shore
## width, the distances its weights depend on (docs/development/island_material_distribution.md).
const SHELTER_SIGMA := 150.0
const DEFAULT_SHORE_WIDTH := 60.0

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
		context.update(var_to_bytes([name, field.channel, field.sample_origin, field.sample_step_x, field.sample_step_y, field.resolution, field.attrs]))
		# Row bands in order hash exactly like one read; a field above 20 Mi samples needs more
		# than one band (images first, then ownership, as for the small ones).
		for key in ["image", "ownership"]:
			for band in row_bands(field.resolution):
				context.update((field.data.read_dense(field.channel, band.position, band.size)[key] as Image).get_data())
	return context.finish().hex_encode()

## Checks that [param layer] holds a complete MaterialDistribution result: every registry
## field, one common physical lattice, binary ownership on every sample. Inside a terrain the
## lattice must also be the final stack's: the terrain's [member StrataTerrain3D.region_spacing]
## (1 m for the island, 4097 x 4097 samples) covering the bounds. Nothing is packed or
## resampled: the editor preview and the bake compose the materials from these fields, with
## any manual layers above them, as regions. Returns [code]{ok, message, entries, first,
## images}[/code]; [param read_images] false skips reading the samples (lattice checks only).
static func validate(layer: StrataLayer, read_images: bool = true) -> Dictionary:
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
		if not read_images: continue
		# One read when the field fits StrataLayerData's 20 Mi dense limit; a larger one (a tiled
		# 0.5 m result) is only counted in row bands and its images are not returned.
		var bands := row_bands(field.resolution)
		var owned := 0
		for band in bands:
			var read := field.data.read_dense(field.channel, band.position, band.size)
			if not read.get("ok", false): return {"ok": false, "message": "Material field has missing owned samples: " + entry.channel}
			owned += int(read.get("owned_count", 0))
			if bands.size() == 1: images.append(read.image)
		if owned != field.resolution.x * field.resolution.y: return {"ok": false, "message": "Material field has missing owned samples: " + entry.channel}
	var terrain := layer.get_parent() as StrataTerrain3D
	if terrain != null:
		var span := terrain.base_bounds
		var spacing := terrain.region_spacing
		var end := first.sample_origin + first.sample_step_x * (first.resolution.x - 1) + first.sample_step_y * (first.resolution.y - 1)
		var origin := Vector2(first.sample_origin.x, first.sample_origin.z)
		var epsilon := spacing * 0.001
		if not first.sample_step_x.is_equal_approx(Vector3(spacing, 0, 0)) or not first.sample_step_y.is_equal_approx(Vector3(0, 0, spacing)):
			return {"ok": false, "message": "Island material fields must be on the terrain's %s m lattice (this result steps %s m); recook MaterialCook after Configure Stage Material Inputs" % [String.num(spacing), String.num(first.sample_step_x.x)]}
		if origin.x > span.position.x + epsilon or origin.y > span.position.y + epsilon or end.x < span.end.x - epsilon or end.z < span.end.y - epsilon: return {"ok": false, "message": "Island material fields must cover the complete terrain bounds"}
	return {"ok": true, "message": "%d material fields on one %s lattice" % [checked.entries.size(), first.resolution], "entries": checked.entries, "first": first, "images": images, "images_omitted": read_images and images.size() != checked.entries.size()}

## Diagnostic and fixture packer: [method validate] plus the native strongest-four pack of the
## fields into an RGBA8 ID image and an RGBAF weight image. The island no longer uses it (its
## regions are composed from the stack).
static func pack(layer: StrataLayer) -> Dictionary:
	var started := Time.get_ticks_usec()
	var checked := validate(layer)
	if not checked.ok: return checked
	if checked.images_omitted: return {"ok": false, "message": "Material fields above %d samples cannot be packed in one piece; the regions compose them from the stack" % StrataProcedural.MAX_FIELD_SAMPLES}
	var first: StrataFieldData = checked.first
	var native := StrataLayerData.new()
	if not native.has_method("pack_material_weights"): return {"ok": false, "message": "This terrain native library cannot pack material fields; rebuild it before cooking"}
	var packed: Dictionary = native.call("pack_material_weights", checked.images)
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
			entries.append([channel, layer.get_composition(StringName(channel)), StrataMaterialControls.channel_signature(layer, channel)])
		state.append([layer.get_instance_id(), entries])
	return state

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
	if host.input_stash.is_empty(): host.input_stash = [{"inputs": ["../../Terrain/" + String(below.name)], "settings": {"terrain_mode": "cumulative", "terrain_channels": HEGoIslandStageMaterials.input_channels(), "terrain_spacing": terrain.region_spacing, "terrain_max_samples": StrataProcedural.MAX_SAMPLES}}]
	var input_spacing: float = host.input_stash[0].get("settings", {}).get("terrain_spacing", 0.0) if host.input_stash.size() == 1 else 0.0
	if host.input_stash.size() != 1 or host.input_stash[0].get("inputs", []) != ["../../Terrain/" + String(below.name)] or host.input_stash[0].get("settings", {}).get("terrain_mode") != "cumulative" or HEGoIslandStageMaterials.channel_names(host.input_stash[0].get("settings", {}).get("terrain_channels", [])) not in [PackedStringArray(["height"]), HEGoIslandStageMaterials.input_channels()] or not (is_equal_approx(input_spacing, terrain.region_spacing) or is_equal_approx(input_spacing, LEGACY_SPACING)): return {"ok": false, "message": "MaterialCook requires the final cumulative height/material/simulation input at the terrain's %s m region spacing (or the saved legacy 4 m / height-only binding); use the explicit stage input migration to upgrade" % String.num(terrain.region_spacing)}
	var legacy_input := HEGoIslandStageMaterials.channel_names(host.input_stash[0].settings.terrain_channels) == PackedStringArray(["height"]) or not is_equal_approx(input_spacing, terrain.region_spacing)
	if upgrade_legacy_input and legacy_input:
		var rows := host.input_stash.duplicate(true)
		rows[0].settings = HEGoIslandStageMaterials.input_settings(4.0, rows[0].settings, true, terrain.region_spacing)
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

# ─────────────────────────────────────────────
# Tiled cook
# ─────────────────────────────────────────────

## [param count] samples along one axis in as few tiles of at most [param tile] samples as can
## overlap by at least [param overlap]. The tiles are balanced to one size (about
## count / tiles, so 8193 samples in 4097-sample tiles are three tiles of 2753, not 4097) and the
## last is clamped to the end, so its overlap can be larger. Each entry is
## [code]{start, end, owned_start, owned_end}[/code], all inclusive sample indices: a tile owns
## the samples between the middle of its overlaps, so it owns all but [code]overlap / 2[/code]
## samples of each interior edge, and the owned parts partition the axis. The same algorithm as
## scripts/houdini/test_material_tiling.py.
static func axis_tiles(count: int, tile: int, overlap: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if count <= tile:
		result.append({"start": 0, "end": count - 1, "owned_start": 0, "owned_end": count - 1})
		return result
	overlap = clampi(overlap, 0, tile / 2)
	var number := 1 + ceili(float(count - tile) / (tile - overlap))
	var size := ceili(float(count + (number - 1) * overlap) / number)
	var starts: Array[int] = []
	for index in range(number): starts.append(mini(index * (size - overlap), count - size))
	var cuts: Array[int] = [0]
	for index in range(number - 1): cuts.append(starts[index + 1] + (starts[index] + size - starts[index + 1]) / 2)
	cuts.append(count)
	for index in range(number):
		result.append({"start": starts[index], "end": starts[index] + size - 1, "owned_start": cuts[index], "owned_end": cuts[index + 1] - 1})
	return result

## The tiles of a [param resolution] lattice, row by row: [code]{index, start, size, owned}[/code]
## with [code]start[/code] the tile's first sample, [code]size[/code] its samples and
## [code]owned[/code] the Rect2i of lattice samples it contributes to the result.
static func tile_grid(resolution: Vector2i, tile: int, overlap: int) -> Array[Dictionary]:
	var rows := axis_tiles(resolution.y, tile, overlap)
	var columns := axis_tiles(resolution.x, tile, overlap)
	var result: Array[Dictionary] = []
	for row in range(rows.size()):
		for column in range(columns.size()):
			var r := rows[row]; var c := columns[column]
			result.append({"index": Vector2i(column, row), "start": Vector2i(c.start, r.start), "size": Vector2i(c.end - c.start + 1, r.end - r.start + 1),
					"owned": Rect2i(c.owned_start, r.owned_start, c.owned_end - c.owned_start + 1, r.owned_end - r.owned_start + 1)})
	return result

## Samples of a box-filtered Gaussian of [param sigma] samples, one pass (the HDA's
## material_habitat.gaussian).
static func _box_radius(sigma: float) -> int:
	return roundi((sqrt(4.0 * sigma * sigma + 1.0) - 1.0) * 0.5)

## The overlap, in samples, at which a tile equals the whole cook exactly: twice the distance
## the material model reads around a sample. That is the larger of the 150 m shelter Gaussian
## (three box passes) and three shore widths of clamped coast distance, plus the gradient
## stencil. 900 samples at 0.5 m and the default shore width. [param shore_width] is the HDA's
## shore_width parameter. Proved by scripts/houdini/test_material_tiling.py.
static func exact_overlap(spacing: float, shore_width: float = DEFAULT_SHORE_WIDTH) -> int:
	var shelter := 3 * _box_radius(SHELTER_SIGMA / spacing)
	var shore := ceili((3.0 * shore_width + 3.0 * _box_radius(4.0 / spacing) * spacing) / spacing)
	return 2 * (maxi(shelter, shore) + 2)

## The material lattice of [param terrain] at [param spacing]: [code]{ok, origin, resolution}[/code],
## one sample every [param spacing] metres from the bounds' corner, the bounds a whole number
## of samples wide (the single cook's snapshot lattice for such bounds).
static func material_lattice(terrain: StrataTerrain3D, spacing: float) -> Dictionary:
	var bounds := terrain.base_bounds
	if not is_finite(spacing) or spacing <= 0.0: return {"ok": false, "message": "Material spacing must be positive"}
	var columns := bounds.size.x / spacing; var rows := bounds.size.y / spacing
	if absf(columns - roundf(columns)) > 1e-6 or absf(rows - roundf(rows)) > 1e-6:
		return {"ok": false, "message": "The terrain bounds %s must be a whole number of %s m material samples" % [bounds.size, String.num(spacing)]}
	return {"ok": true, "origin": bounds.position, "resolution": Vector2i(roundi(columns) + 1, roundi(rows) + 1), "spacing": spacing}

## Row bands of a [param resolution] lattice that each fit one dense read or write
## (StrataProcedural.MAX_FIELD_SAMPLES samples): one band for anything the single cook makes.
static func row_bands(resolution: Vector2i) -> Array[Rect2i]:
	var result: Array[Rect2i] = []
	var rows := maxi(1, StrataProcedural.MAX_FIELD_SAMPLES / maxi(1, resolution.x))
	var y := 0
	while y < resolution.y:
		var height := mini(rows, resolution.y - y)
		result.append(Rect2i(0, y, resolution.x, height))
		y += height
	return result


## Collects one tile's cook result instead of publishing it: skips the Strata output handler
## and keeps the routed volumes and the input tokens for the tiled cook to assemble.
class TileCapture extends HEGoCookExtension:
	var fields: Array = []
	var tokens: Array = []
	var failure := ""

	func reset() -> void:
		fields = []; tokens = []; failure = ""

	func skips_output_handler(handler: Variant, _cook: Dictionary) -> bool:
		return handler is HEGoStrataOutput

	func cook_commit(context: HEGoOutputContext) -> Dictionary:
		var fetched := await HEGoNodeUtil.checked_task(context.host, context.asset.get_heightfield_fields(PackedStringArray(HEGoStrataOutput.FETCHED_ATTRS)))
		if not fetched.ok or not fetched.value is Array:
			failure = "Strict heightfield fetch failed: " + String(fetched.get("message", "unreadable result"))
			return {"ok": false, "message": failure}
		fields = fetched.value.filter(func(field): return field is Dictionary and not String(field.get("attrs", {}).get(HEGoStrataOutput.TARGET_ATTR, "")).is_empty())
		for input in context.cook_state.get(HEGoStrataOutput.COOK_KEY, {}).get("inputs", []):
			tokens.append({"ok": true, "token": input.token})
		return {"ok": true}

	func cook_failed(_host: Node, _cook: Dictionary, message: String) -> void:
		failure = message


## Builds one StrataFieldData per material channel over the whole lattice from tile results.
## The fields' native storage is written window by window (StrataLayerData.patch_dense), so no
## Image of the full lattice ever exists, and uses 8-bit values when asked.
class TileAssembler extends RefCounted:
	var origin: Vector2
	var spacing: float
	var resolution: Vector2i
	var unorm8: bool
	var fields: Dictionary = {}
	var height := 0.0
	var written := 0

	func _init(lattice_origin: Vector2, lattice_spacing: float, lattice_resolution: Vector2i, as_unorm8: bool) -> void:
		origin = lattice_origin; spacing = lattice_spacing; resolution = lattice_resolution; unorm8 = as_unorm8

	## Writes the owned part of every field of [param tile] ([method HEGoIslandMaterials.tile_grid]
	## entry). [param results] are the tile's routed fields in the terrain frame; each must sit
	## exactly on the lattice at the tile's position. Returns [code]{ok, message}[/code].
	func add(tile: Dictionary, results: Array) -> Dictionary:
		var expected_origin := Vector2(origin.x + tile.start.x * spacing, origin.y + tile.start.y * spacing)
		var local_owned := Rect2i(tile.owned.position - tile.start, tile.owned.size)
		for result in results:
			var image: Image = result.image
			var name := String(result.name)
			var step_x: Vector3 = result.sample_step_x; var step_y: Vector3 = result.sample_step_y
			var tolerance := spacing * 0.01
			if image.get_size() != tile.size: return {"ok": false, "message": "Tile %s result %s is %s samples, expected %s" % [tile.index, name, image.get_size(), tile.size]}
			if absf(step_x.x - spacing) > tolerance * 0.01 or absf(step_y.z - spacing) > tolerance * 0.01 or absf(step_x.z) > tolerance * 0.01 or absf(step_y.x) > tolerance * 0.01 or absf(step_x.y) > tolerance * 0.01 or absf(step_y.y) > tolerance * 0.01:
				return {"ok": false, "message": "Tile %s result %s is not on the %s m lattice (steps %s, %s)" % [tile.index, name, String.num(spacing), step_x, step_y]}
			var at: Vector3 = result.sample_origin
			if absf(at.x - expected_origin.x) > tolerance or absf(at.z - expected_origin.y) > tolerance:
				return {"ok": false, "message": "Tile %s result %s starts at (%s, %s), expected %s" % [tile.index, name, at.x, at.z, expected_origin]}
			if not fields.has(name):
				var created := StrataFieldData.new()
				created.channel = StringName(name)
				created.sample_origin = Vector3(origin.x, at.y, origin.y)
				created.sample_step_x = Vector3(spacing, 0.0, 0.0); created.sample_step_y = Vector3(0.0, 0.0, spacing)
				created.resolution = resolution
				created.attrs = result.get("attrs", {}).duplicate(true)
				if unorm8 and not created.data.set_channel_format(created.channel, StrataLayerData.VALUE_UNORM8): return {"ok": false, "message": "Could not select 8-bit storage for " + name}
				fields[name] = created
			var field: StrataFieldData = fields[name]
			for band in HEGoIslandMaterials.row_bands(local_owned.size):
				var window := Rect2i(local_owned.position + band.position, band.size)
				if not field.data.patch_dense(field.channel, tile.start + window.position, image.get_region(window)): return {"ok": false, "message": "Native write of tile %s channel %s failed" % [tile.index, name]}
				written += window.size.x * window.size.y
		return {"ok": true, "message": "Tile %s assembled" % tile.index}

	## The assembled fields as publishable result entries, or an error unless exactly the
	## channels in [param names] were assembled and every sample of each was written.
	func result_fields(names: PackedStringArray) -> Dictionary:
		if fields.size() != names.size(): return {"ok": false, "message": "The tiles produced %d channels, expected %d" % [fields.size(), names.size()]}
		var entries: Array = []
		for name in names:
			if not fields.has(name): return {"ok": false, "message": "The tiles produced no channel " + name}
			var owned := 0
			for band in HEGoIslandMaterials.row_bands(resolution):
				owned += int(fields[name].data.read_dense(StringName(name), band.position, band.size).get("owned_count", 0))
			if owned != resolution.x * resolution.y: return {"ok": false, "message": "The tiles left %d samples of %s unwritten" % [resolution.x * resolution.y - owned, name]}
			entries.append({"name": name, "field_data": fields[name], "composition": "replace"})
		return {"ok": true, "fields": entries}


## Cooks the material distribution into [param target]. A lattice of at most
## [code]tile_samples[/code] samples per axis is the single cook of [method cook_explicit], unchanged.
## A larger one (the island at 0.5 m is 8193 x 8193) is cooked one tile at a time by the same HDA
## and the same input row, with [code]terrain_bounds[/code] set to the tile plus its overlap;
## the tiles are assembled into one field per channel and published in a single transaction, so
## the layer never holds a partial result and keeps its previous one if any tile fails.
##
## [param options]: [code]tile_samples[/code] (default [constant TILE_SAMPLES]), [code]tile_overlap[/code]
## (default [constant TILE_OVERLAP]; the String "exact" is [method exact_overlap], which makes tiles equal a whole cook),
## [code]storage[/code] ([constant STORAGE_UNORM8], the default, or [constant STORAGE_FLOAT]; tiled
## results only), [code]progress[/code] (a Callable taking a String) and [code]overrides[/code]
## (HDA parameters, as for [method cook_explicit]). Returns [code]{ok, message, tiles, cook_ms}[/code].
static func cook(owner: Node, host: HEGoNode3D, target: StrataLayer, contract: Dictionary, options: Dictionary = {}) -> Dictionary:
	var terrain := target.get_parent() as StrataTerrain3D
	var overrides: Dictionary = options.get("overrides", {})
	if terrain == null or host.input_stash.size() != 1: return {"ok": false, "message": "MaterialCook needs its terrain and exactly one input row"}
	var spacing := float(host.input_stash[0].get("settings", {}).get("terrain_spacing", terrain.region_spacing))
	var tile_samples := maxi(3, int(options.get("tile_samples", TILE_SAMPLES)))
	var requested: Variant = options.get("tile_overlap", TILE_OVERLAP)
	var overlap: int = exact_overlap(spacing) if requested is String and requested == "exact" else int(requested)
	var lattice := material_lattice(terrain, spacing)
	if not lattice.ok or lattice.resolution.x <= tile_samples and lattice.resolution.y <= tile_samples:
		return await cook_explicit(owner, host, target, contract, overrides)
	var tiles := tile_grid(lattice.resolution, tile_samples, overlap)
	var progress: Callable = options.get("progress", Callable())
	var storage := String(options.get("storage", STORAGE_UNORM8))
	if storage not in [STORAGE_UNORM8, STORAGE_FLOAT]: return {"ok": false, "message": "Unknown material storage " + storage}
	var started := Time.get_ticks_usec()
	var configured := await configure(owner, host, target, contract, overrides)
	if not configured.ok: return configured
	var original_rows: Array = host.input_stash.duplicate(true)
	var capture := TileCapture.new()
	host.add_child(capture)
	var assembler := TileAssembler.new(lattice.origin, spacing, lattice.resolution, storage == STORAGE_UNORM8)
	var tokens: Array = []
	var preset: PackedByteArray
	var failure := ""
	for position in range(tiles.size()):
		var tile: Dictionary = tiles[position]
		var bounds := Rect2(lattice.origin + Vector2(tile.start) * spacing, Vector2(tile.size - Vector2i.ONE) * spacing)
		if progress.is_valid(): progress.call("Cooking material tile %d/%d (%s samples, %.0f s elapsed)" % [position + 1, tiles.size(), tile.size, (Time.get_ticks_usec() - started) / 1000000.0])
		var rows: Array = original_rows.duplicate(true)
		rows[0].settings.terrain_bounds = bounds
		capture.reset()
		host.input_stash = rows
		await host.cook()
		host.input_stash = original_rows.duplicate(true)
		if capture.fields.is_empty() or not host.hego_did_last_cook_succeed():
			failure = "Material tile %d/%d did not cook: %s" % [position + 1, tiles.size(), capture.failure if not capture.failure.is_empty() else "no Strata volumes returned"]
			break
		if position == 0: preset = host.parm_stash
		elif host.parm_stash != preset:
			failure = "The material parameters changed between tiles"; break
		var routed := HEGoStrataOutput.route_fields(host, capture.fields)
		capture.fields = []
		if not routed.ok or routed.results.size() != 1 or routed.results[0].layer_id != target.ensure_identity():
			failure = String(routed.get("message", "A tile was routed to a layer other than MaterialDistribution")); break
		var added := assembler.add(tile, routed.results[0].fields)
		routed = {}
		if not added.ok:
			failure = String(added.message); break
		# The first tile's read set covers the whole sequence: if the stack changes after it, the
		# final transaction finds that token stale.
		if position == 0: tokens = capture.tokens.duplicate(true)
	capture.queue_free()
	host.input_stash = original_rows
	if not failure.is_empty():
		target.mark_stale("Tiled material cook failed; previous cache retained: " + failure)
		return {"ok": false, "message": failure}
	var names := channels()
	var assembled := assembler.result_fields(names)
	if not assembled.ok: return assembled
	# One short transaction at the end: begin and commit with no await between them. The tile
	# input tokens are its read set, so a stack that changed during the minutes of tile cooks
	# rejects the whole result.
	var signature := HEGoStrataOutput.signature(host)
	var guard := func() -> bool: return HEGoStrataOutput.signature(host) == signature
	var ticket := StrataProcedural.begin_transaction(host, HEGoStrataOutput.producer_id(host), [{"layer": target, "channels": names}], tokens, {"guard": guard, "signature": signature})
	if not ticket.ok:
		target.mark_stale("Tiled material cook rejected: " + String(ticket.message))
		return ticket
	if progress.is_valid(): progress.call("Publishing %d material channels from %d tiles" % [names.size(), tiles.size()])
	var published := StrataProcedural.commit_fields(ticket, [{"layer_id": target.ensure_identity(), "fields": assembled.fields, "explicit_empty": false}])
	return {"ok": published.ok and not target.procedural_stale, "message": target.procedural_status if published.ok else published.message, "parameters": configured.parameters, "tiles": tiles.size(), "storage": storage, "overlap": clampi(overlap, 0, tile_samples / 2), "cook_ms": (Time.get_ticks_usec() - started) / 1000.0}


## Caller owns/exclusively starts a HAPI session. This never cooks another host.
static func cook_explicit(owner: Node, host: HEGoNode3D, target: StrataLayer, contract: Dictionary, overrides: Dictionary = {}) -> Dictionary:
	var configured := await configure(owner, host, target, contract, overrides)
	if not configured.ok: return configured
	var before := target.procedural_revision
	var started := Time.get_ticks_usec()
	await host.cook()
	return {"ok": target.procedural_revision > before and not target.procedural_stale, "message": target.procedural_status, "parameters": configured.parameters, "cook_ms": (Time.get_ticks_usec() - started) / 1000.0}

## Instantiates the HDA and applies the contract's parameters (plus [param overrides]) with a
## readback check; the part of a cook before Houdini cooks. Returns [code]{ok, parameters}[/code].
static func configure(owner: Node, host: HEGoNode3D, target: StrataLayer, contract: Dictionary, overrides: Dictionary = {}) -> Dictionary:
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
	return {"ok": true, "parameters": actual}

static func _collect_parms(value: Variant, result: Dictionary, parameters: Dictionary) -> void:
	if value is Dictionary:
		if value.has("name") and value.has("values") and parameters.has(String(value.name)) and not value["values"].is_empty(): result[String(value.name)] = value["values"][0]
		for child in value.values(): _collect_parms(child, result, parameters)
	elif value is Array:
		for child in value: _collect_parms(child, result, parameters)
