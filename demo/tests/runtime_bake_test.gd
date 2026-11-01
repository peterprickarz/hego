extends "res://tests/runtime_test_base.gd"
## Explicit bake, stale tracking, failure retention and runtime export against
## a real layered stack (native layer data, real procedural transactions; no
## Houdini). Writes res://export/* for the runtime-only roundtrip project.

const S := StrataRuntimeData.Status

var terrain: StrataTerrain3D
var host: Node
var rough: StrataLayer
var coarse: StrataLayer
var fine: StrataLayer
var detail: StrataLayer
var flatten: StrataLayer
var stale_signals: Array = []

func _initialize() -> void:
	call_deferred("run")

func layer(label: String, procedural := false) -> StrataLayer:
	var result := StrataLayer.new()
	result.name = label
	result.procedural = procedural
	terrain.add_child(result)
	result.owner = terrain
	return result

func rf(size: Vector2i, value: Callable) -> Image:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RF)
	for y in range(size.y):
		for x in range(size.x):
			image.set_pixel(x, y, Color(value.call(x, y), 0, 0, 1))
	return image

func cook(target: StrataLayer, field: Dictionary) -> Dictionary:
	var ticket := StrataProcedural.begin_transaction(host, "runtime-bake-test", [{"layer": target, "channels": ["height"]}], [])
	if not ticket.ok:
		return ticket
	return StrataProcedural.commit_fields(ticket, [{"layer_id": target.layer_id, "fields": [field]}])

func lattice_matches_stack(data: StrataRuntimeData, label: String) -> void:
	var worst := 0.0
	for j in range(data.resolution.y):
		for i in range(data.resolution.x):
			var point := data.lattice_to_local(Vector2(i, j))
			worst = maxf(worst, absf(data.get_height_at(Vector2i(i, j)) - terrain.sample_height(point)))
	# float32 storage of composed float64 heights.
	check(worst <= 0.000002, "%s: baked heights equal the full-stack composition at every lattice point (max %s)" % [label, worst])

func run() -> void:
	var scene := Node3D.new()
	scene.name = "Authoring"
	get_root().add_child(scene)
	host = Node.new()
	host.name = "Producer"
	scene.add_child(host)
	terrain = StrataTerrain3D.new()
	terrain.name = "Terrain"
	terrain.base_bounds = Rect2(-24.0, -16.0, 48.0, 32.0)
	terrain.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(30.0)), Vector3(10.0, 2.0, -5.0))
	terrain.set_preview_enabled(false)
	terrain.editor_material_channels = PackedStringArray(["mat_a", "mat_b"])
	scene.add_child(terrain)
	terrain.runtime_bake_stale_changed.connect(func(stale: bool) -> void: stale_signals.append(stale))

	# RoughBase: manual Replace on a 4 m grid, signed heights.
	rough = layer("RoughBase")
	rough.data.sample_spacing = 4.0
	rough.data.grid_origin = Vector2(-24.0, -16.0)
	for j in range(9):
		for i in range(13):
			rough.data.set_sample(&"height", Vector2i(i, j), 2.0 * sin(i * 0.5) - 1.5 + j * 0.3)
	for j in range(9):
		for i in range(13):
			rough.data.set_sample(&"mat_a", Vector2i(i, j), 1.0 if i < 8 else 0.25)
			rough.data.set_sample(&"mat_b", Vector2i(i, j), 0.75 if i >= 4 else 0.0)
	# CoarseErosion: procedural Replace at 2 m with partial ownership.
	coarse = layer("CoarseErosion", true)
	# ManualFine: manual Add at 0.5 m, plus a generic signed "mask" channel.
	fine = layer("ManualFine")
	fine.data.sample_spacing = 0.5
	fine.set_composition(&"height", StrataLayer.Composition.ADD)
	for j in range(-6, 7):
		for i in range(-6, 7):
			fine.data.set_sample(&"height", Vector2i(i, j), 0.4 - 0.01 * (i * i + j * j))
	for entry in [[0, 0.0], [2, 2.5], [4, -1.0], [6, 0.0]]:
		fine.data.set_sample(&"mask", Vector2i(entry[0], 0), entry[1])
	# DetailErosion: procedural Add, left uncooked at first.
	detail = layer("DetailErosion", true)
	# BuildingFlatten: manual Replace pad.
	flatten = layer("BuildingFlatten")
	for j in range(8, 13):
		for i in range(12, 19):
			flatten.data.set_sample(&"height", Vector2i(i, j), 1.25)

	var coarse_field := {"name": "height", "image": rf(Vector2i(25, 17), func(x: int, y: int) -> float: return -0.4 + 0.2 * cos(x * 0.6 + y)), "ownership": rf(Vector2i(25, 17), func(x: int, _y: int) -> float: return 1.0 if x < 12 else 0.0), "sample_origin": Vector3(-24.0, 0.5, -16.0), "sample_step_x": Vector3(2, 0, 0), "sample_step_y": Vector3(0, 0, 2), "composition": "replace"}
	check(cook(coarse, coarse_field).ok, "CoarseErosion commits through the real transaction API")
	await process_frame

	# Stale/uncooked procedural results are rejected by default.
	var rejected := StrataBake.bake(terrain)
	check(not rejected.ok and "DetailErosion" in rejected.message and terrain.runtime_data == null, "uncooked procedural layer rejects the bake: %s" % rejected.get("message"))
	var cached := StrataBake.bake(terrain, {"allow_stale_procedural": true})
	check(cached.ok and cached.report.stale_procedural_used == PackedStringArray(["DetailErosion"]), "explicit opt-in bakes cached results and reports them: %s" % cached.get("report", cached))
	check(terrain.runtime_data != null and terrain.runtime_data.bake_revision == 1 and not terrain.is_runtime_bake_stale(), "first bake published")

	var detail_field := {"name": "height", "image": rf(Vector2i(49, 33), func(x: int, y: int) -> float: return 0.05 * sin(x) * cos(y)), "sample_origin": Vector3(-24.0, 0.0, -16.0), "sample_step_x": Vector3(1, 0, 0), "sample_step_y": Vector3(0, 0, 1), "composition": "add"}
	check(cook(detail, detail_field).ok, "DetailErosion commits as an Add field")
	check(terrain.is_runtime_bake_stale() and stale_signals == [false, true], "first publish reports fresh, a procedural recook marks it stale: %s" % [stale_signals])

	# Complete bake with holes, exclusions, a retained channel and controls.
	var cells := Vector2i(48, 32)
	var holes := Image.create(cells.x, cells.y, false, Image.FORMAT_L8)
	holes.fill_rect(Rect2i(30, 4, 3, 2), Color(1, 1, 1))
	holes.set_pixel(5, 5, Color(127.0 / 255.0, 0, 0))
	var exclusions := Image.create(cells.x, cells.y, false, Image.FORMAT_RF)
	exclusions.fill_rect(Rect2i(36, 8, 6, 6), Color(0.5, 0, 0))
	exclusions.set_pixel(1, 1, Color(0.49, 0, 0))
	var ids := Image.create(5, 5, false, Image.FORMAT_RGBA8)
	var weights := Image.create(5, 5, false, Image.FORMAT_RGBAF)
	# Two static navigation profiles; the slope threshold has more digits than a
	# text resource keeps, so the roundtrip proves exact rule storage.
	var profiles := [{"name": &"wet", "rule": {"channel": "mask", "min": 0.5}}, {"name": &"flat_dry", "rule": {"all": [{"slope_max": 20.123456789}, {"not": {"channel": "mask", "min": 1.0}}, {"exclusion": true}]}}]
	var options := {"holes": holes, "nav_exclusions": exclusions, "channels": PackedStringArray(["mask"]), "nav_profiles": profiles, "region_cells": 16}
	var deprecated_options := options.duplicate()
	deprecated_options.material_ids = ids
	deprecated_options.material_weights = weights
	var deprecated := StrataBake.compile(terrain, deprecated_options)
	check(deprecated.ok and deprecated.report.deprecated.size() == 2 and payload_hashes(deprecated.data) == payload_hashes(StrataBake.compile(terrain, options).data), "material_ids/weights options are ignored with a deprecation note: %s" % [deprecated.get("report", {}).get("deprecated")])
	var baked := StrataBake.bake(terrain, options)
	check(baked.ok, "complete bake: %s" % baked.get("message", ""))
	var data := terrain.runtime_data
	check(data.bake_revision == 2 and not terrain.is_runtime_bake_stale() and stale_signals == [false, true, false], "revision 2, fresh: %s" % [stale_signals])
	check(data.resolution == Vector2i(49, 33) and data.get_spacing() == 1.0 and data.grid == Vector2i(3, 2) and data.cells == 16 and data.apron == 2 and data.mip_levels == 3 and data.format_version == 2, "1 m lattice over the full bounds in a 3 x 2 grid of 16-cell regions")
	check(data.regions.size() == 6 and data.region_directory.is_empty() and data.region_extrema.size() == 12 and data.get_region(Vector2i(2, 1)).level_count("height") == 3, "six embedded regions with three levels and per-region extrema")
	lattice_matches_stack(data, "full stack")
	check(data.height_min < 0.0 and data.height_max > 0.0, "signed heights retained")
	near(data.sample_height(Vector2(15.0, 10.0)).value, 1.25, 0.000001, "BuildingFlatten pad is the top Replace")
	var all_cells := Rect2i(Vector2i.ZERO, cells)
	check(data.cell_mask_window("holes", all_cells).count(255) == 6 and data.is_hole_cell(Vector2i(31, 5)) and not data.is_hole_cell(Vector2i(5, 5)), "holes canonicalized with byte >= 128")
	check(data.cell_mask_window("nav_exclusion", all_cells).count(255) == 36 and data.is_nav_excluded_cell(Vector2i(36, 8)) and not data.is_nav_excluded_cell(Vector2i(1, 1)), "exclusions canonicalized with value >= 0.5")
	check(data.get_hole_image().get_pixel(31, 5).r == 1.0, "hole image matches the canonical mask")
	var channel_ok := true
	var absent := 0
	for j in range(data.resolution.y):
		for i in range(data.resolution.x):
			var point := data.lattice_to_local(Vector2(i, j))
			var reference := terrain.sample_channel_coverage(&"mask", point)
			var sampled := data.sample_channel(&"mask", point)
			if reference.coverage > 0.0:
				channel_ok = channel_ok and sampled.status == S.OK and absf(sampled.value - reference.value) < 0.000001
			else:
				channel_ok = channel_ok and sampled.status == S.ABSENT
				absent += 1
	check(channel_ok and absent > 0, "retained mask matches the composed channel; uncovered samples ABSENT (%d)" % absent)
	var zero := data.sample_channel(&"mask", Vector2(0, 0))
	check(zero.status == S.OK and zero.value == 0.0, "owned zero mask value is a defined zero")
	near(data.sample_channel(&"mask", Vector2(1, 0)).value, 2.5, 0.0, "generic mask stays unclamped above one")
	near(data.sample_channel(&"mask", Vector2(2, 0)).value, -1.0, 0.0, "generic mask stays signed")
	# Materials come from the stack: mat_a everywhere, mat_b from column 16 on, quantized to 255.
	var region := data.get_region(Vector2i(1, 0))
	var ids_bytes := region.level_bytes("material_ids")
	var weights_bytes := region.level_bytes("material_weights")
	var sums_ok := true
	for texel in range(weights_bytes.size() / 4):
		var total: int = weights_bytes[texel * 4] + weights_bytes[texel * 4 + 1] + weights_bytes[texel * 4 + 2] + weights_bytes[texel * 4 + 3]
		sums_ok = sums_ok and (total == 255 or total == 0)
	var centre_texel := (2 + 8) * 21 + 2 + 3
	check(sums_ok and ids_bytes[centre_texel * 4] == 0 and ids_bytes[centre_texel * 4 + 1] == 1 and weights_bytes.slice(centre_texel * 4, centre_texel * 4 + 4) == PackedByteArray([146, 109, 0, 0]), "material maps compose from editor_material_channels and sum to 255 where assigned (%s)" % [weights_bytes.slice(centre_texel * 4, centre_texel * 4 + 4)])

	# Blended materials and surface tags at a point.
	check(data.has_materials() and data.material_channels == PackedStringArray(["mat_a", "mat_b"]), "the bake records the material channel order (%s)" % [data.material_channels])
	var centre_local := data.lattice_to_local(Vector2(16 + 3, 8))
	var mats := data.sample_materials(centre_local)
	check(mats.ok and mats.status == S.OK and mats.ids == PackedInt32Array([0, 1]) and mats.dominant == 0 and mats.channels == PackedStringArray(["mat_a", "mat_b"]) and absf(mats.weights[0] - 146.0 / 255.0) < 0.000001 and absf(mats.weights[0] + mats.weights[1] - 1.0) < 0.000001 and absf(mats.coverage - 1.0) < 0.000001, "sample_materials blends the texel's ids heaviest first (%s)" % [mats])
	var between := data.sample_materials(centre_local + Vector2(0.5, 0.0) * data.spacing, StrataRuntimeData.Interpolation.TRIANGLE)
	check(between.ok and between.ids[0] == 0 and between.weights[0] > 0.5, "sample_materials interpolates between texels (%s)" % [between])
	check(data.sample_materials(Vector2(1000.0, 1000.0)).status == S.OUTSIDE and data.sample_materials(Vector2(NAN, 0.0)).status == S.OUTSIDE, "sample_materials reports OUTSIDE beyond the bounds")
	var sand := StrataMaterial.new()
	sand.surface_type = &"sand"
	var tagged: Array[StrataMaterial] = [sand, StrataMaterial.new()]
	terrain.editor_materials = tagged
	var centre_world: Vector3 = terrain.global_transform * Vector3(centre_local.x, 3.0, centre_local.y)
	var resolved := terrain.sample_runtime_materials(centre_world)
	check(resolved.ok and resolved.material == sand and resolved.materials.size() == 2 and resolved.materials[1] == terrain.editor_materials[1] and resolved.surface_type == &"sand" and terrain.runtime_surface_type(centre_world) == &"sand", "the terrain resolves the dominant material and its surface_type (%s)" % [resolved.surface_type])
	check(terrain.runtime_surface_type(terrain.global_transform * Vector3(1000.0, 0.0, 0.0)) == &"" and terrain.runtime_surface_type(terrain.global_transform * Vector3(centre_local.x + 20.0 * data.spacing, 0.0, centre_local.y)) == &"", "runtime_surface_type is empty outside and for untagged materials")
	terrain.editor_materials = []
	check(terrain.runtime_surface_type(centre_world) == &"" and terrain.sample_runtime_materials(centre_world).material == null, "runtime_surface_type is empty without resolvable materials")

	# Static navigation profiles: per-region cell maps (255 = blocked), rules, default.
	var D := StrataRuntimeData.DEFAULT_NAV_PROFILE
	check(data.get_nav_profile_names() == [D, &"flat_dry", &"wet"] and data.maps.has("nav_wet") and data.maps.has("nav_flat_dry") and not data.maps.has("nav_default"), "profiles are cell maps by name; default is the nav_exclusion map: %s" % [data.get_nav_profile_names()])
	check(data.nav_profile_rules == {D: {"exclusion": true}, &"wet": profiles[0].rule, &"flat_dry": profiles[1].rule}, "the bake records every rule, including the default: %s" % [data.nav_profile_rules])
	check(data.has_nav_profile(D) and data.get_nav_profile_mask(D) == data.cell_mask_window("nav_exclusion", all_cells) and data.get_nav_profile_image(D).get_data() == data.get_nav_exclusion_image().get_data(), "the default profile equals the nav_exclusion mask")
	check(data.validate().ok, "profiled bake validates")
	var full_samples := Rect2i(Vector2i.ZERO, cells)
	var mask_values := data.map_window_bytes("mask", full_samples).to_float32_array()
	var mask_coverage := data.map_window_bytes("mask__coverage", full_samples).to_float32_array()
	var uncovered_zero := mask_values.size() == 49 * 33
	for index in range(mask_values.size()):
		uncovered_zero = uncovered_zero and (mask_coverage[index] > 0.0 or mask_values[index] == 0.0)
	check(uncovered_zero, "uncovered mask samples store 0, the value profile rules read")
	var wet_expected := PackedByteArray(); wet_expected.resize(cells.x * cells.y)
	for z in range(cells.y):
		for x in range(cells.x):
			var i := z * 49 + x
			var mean := (float(mask_values[i]) + mask_values[i + 1] + mask_values[i + 49] + mask_values[i + 50]) * 0.25
			wet_expected[z * cells.x + x] = 0 if mean >= 0.5 else 255
	var wet_mask := data.get_nav_profile_mask(&"wet")
	check(wet_mask == wet_expected and wet_expected.count(0) > 0, "wet profile is the cell-mean threshold of the retained mask across all regions (%d walkable cells)" % wet_expected.count(0))
	var flat_dry_mask := data.get_nav_profile_mask(&"flat_dry")
	var reproducible := true
	for ry in range(2):
		for rx in range(3):
			var region_xy := data.get_region(Vector2i(rx, ry))
			for name in [&"wet", &"flat_dry"]:
				reproducible = reproducible and StrataNavProfiles.evaluate_region(region_xy, data.get_nav_profile_rule(name), data.channel_names) == region_xy.level_bytes(StrataRegions.nav_map_name(name))
	check(reproducible and flat_dry_mask.count(0) > 0 and flat_dry_mask.count(255) > 36, "every region's profile maps re-evaluate from its stored maps and rules")
	check(StrataNavProfiles.evaluate(data, data.get_nav_profile_rule(&"wet")) == wet_mask and StrataNavProfiles.evaluate(data, data.get_nav_profile_rule(&"flat_dry")) == flat_dry_mask, "the whole-terrain evaluation stitches the regions into the same masks")
	check(data.is_nav_blocked_cell(Vector2i(36, 8), &"flat_dry") and data.is_nav_blocked_cell(Vector2i(36, 8), &"wet") == (wet_expected[8 * 48 + 36] == 255), "excluded cells block flat_dry; wet ignores exclusions")
	check(data.is_nav_blocked_cell(Vector2i(31, 5), &"wet") and data.is_nav_blocked_cell(Vector2i(31, 5), &"flat_dry"), "holes block every profile")
	var profile_manifest := data.get_manifest()
	check(profile_manifest.map_bytes.nav_wet == 20 * 20 + 12 * 12 + 8 * 8 and profile_manifest.nav_profiles.size() == 3 and profile_manifest.nav_profiles[0].name == D, "manifest lists default + both profiles with their mip bytes: %s" % [profile_manifest.nav_profiles])
	check(baked.report.nav_profiles.has(&"wet") and baked.report.nav_profiles[&"flat_dry"].terms == 3 and baked.report.nav_profiles[&"wet"].blocked_cells == wet_expected.count(255), "bake report lists profile evaluation: %s" % [baked.report.nav_profiles])
	var copied := data.duplicate_runtime()
	check(copied.nav_profile_rules == data.nav_profile_rules and copied.material_channels == data.material_channels and payload_hashes(copied) == payload_hashes(data) and copied.regions[Vector2i(0, 0)] != data.regions[Vector2i(0, 0)], "duplicate_runtime copies profiles, rules, material channels and regions independently")
	var unavailable := StrataNavProfiles.evaluate_region_checked(data.get_region(Vector2i(0, 0)), {"channel": "water", "min": 0.5}, PackedStringArray(["water"]))
	check(not unavailable.ok and "not in the region" in unavailable.message, "evaluating a channel the region lacks is an error: %s" % unavailable.get("message"))

	# Layered categorical holes: ManualFine authors a Hole region, the upper
	# BuildingFlatten owns Solid over part of it; the native compiler resolves
	# ownership before conservative reduction and the bake checks its token.
	for j in range(20, 28):
		for i in range(-20, -10):
			fine.data.set_sample(&"hole", Vector2i(i, j), 1.0)
	for j in range(10, 13):
		for i in range(-10, -7):
			flatten.data.set_sample(&"hole", Vector2i(i, j), 0.0)
	check(not StrataBake.bake(terrain, {"cell_masks": true, "holes": holes}).ok, "cell_masks and explicit holes are mutually exclusive")
	var layered := StrataBake.bake(terrain, {"cell_masks": true, "region_cells": 16})
	check(layered.ok and layered.report.mask_source == "layers", "bake compiles layered masks: %s" % layered.get("message", ""))
	var reference_masks := StrataProcedural.compile_cell_masks(terrain, null, 1.0)
	# The native compiler returns an empty array for an empty mask; the regions store full maps.
	var reference_exclusions: PackedByteArray = reference_masks.nav_exclusions
	if reference_exclusions.is_empty(): reference_exclusions.resize(cells.x * cells.y)
	check(layered.ok and terrain.runtime_data.cell_mask_window("holes", all_cells) == reference_masks.holes and terrain.runtime_data.cell_mask_window("nav_exclusion", all_cells) == reference_exclusions and reference_masks.holes.count(255) > 0, "baked holes are exactly the native canonical mask (%d cells)" % reference_masks.holes.count(255))
	flatten.enabled = false
	var without_solid := StrataProcedural.compile_cell_masks(terrain, null, 1.0)
	flatten.enabled = true
	check(without_solid.holes.count(255) > reference_masks.holes.count(255), "the upper Solid override restores cells before reduction (%d -> %d)" % [without_solid.holes.count(255), reference_masks.holes.count(255)])
	# Inside the ManualFine Hole region, outside the BuildingFlatten Solid.
	var hole_cell := terrain.runtime_data.lattice_to_local(Vector2(17.5, 28.5))
	check(terrain.runtime_data.is_hole_at(hole_cell) and terrain.runtime_data.sample_height(hole_cell).status == S.HOLE, "a layered hole is a runtime HOLE")
	var early_masks := StrataProcedural.compile_cell_masks(terrain, null, 1.0)
	fine.data.set_sample(&"hole", Vector2i(-21, 20), 1.0)
	var stale_masks := StrataBake.bake(terrain, {"cell_masks": early_masks})
	check(not stale_masks.ok and "Cell masks" in stale_masks.message, "precompiled masks from before an edit are rejected: %s" % stale_masks.get("message"))
	var cutoff_masks := StrataProcedural.compile_cell_masks(terrain, rough, 1.0)
	check(not StrataBake.bake(terrain, {"cell_masks": cutoff_masks}).ok, "preview-cutoff masks are rejected")
	for j in range(19, 28):
		for i in range(-21, -10):
			fine.data.erase_sample(&"hole", Vector2i(i, j))
	for j in range(10, 13):
		for i in range(-10, -7):
			flatten.data.erase_sample(&"hole", Vector2i(i, j))
	check(StrataBake.bake(terrain, options).ok, "explicit-mask bake restored")
	data = terrain.runtime_data

	# Preview cutoff never changes the bake or its freshness.
	terrain.preview_through_layer = rough
	terrain.show_overrides = true
	check(not terrain.is_runtime_bake_stale(), "preview cutoff/overlay settings do not stale the bake")
	var again := StrataBake.compile(terrain, options)
	check(again.ok and payload_hashes(again.data) == payload_hashes(data), "bake with a preview cutoff set still compiles the complete stack")
	var through_rough := StrataProcedural.compile_heightfield(terrain, rough, 1.0)
	check((through_rough.image as Image).get_data().to_float32_array() != data.heights_window(all_cells), "the preview cutoff would have produced different heights")
	var cutoff_bake := StrataBake.bake(terrain, {"compiled": through_rough})
	check(not cutoff_bake.ok and terrain.runtime_data == data, "a compiled preview-cutoff field is rejected: %s" % cutoff_bake.get("message"))
	terrain.preview_through_layer = null
	terrain.show_overrides = false

	var forged := StrataProcedural.compile_heightfield(terrain)
	forged.min = 0.0; forged.max = 0.0
	var verified := StrataBake.compile(terrain, {"compiled": forged})
	check(verified.ok and verified.data.height_min < 0 and verified.data.height_max > 0, "bake uses actual native RF extrema instead of forged finite metadata")
	var deduplicated := StrataBake.compile(terrain, {"channels": PackedStringArray(["mask", "mask"])})
	check(deduplicated.ok and deduplicated.data.channel_names == PackedStringArray(["mask"]), "requested runtime channels are deduplicated before allocation")
	var with_channel := StrataBake.compile(terrain, {"channels": PackedStringArray(["mask"]), "region_cells": 16})
	var channel_total: int = with_channel.data.get_manifest().total_bytes
	var denied := StrataBake.compile(terrain, {"channels": PackedStringArray(["mask"]), "region_cells": 16, "max_runtime_bytes": channel_total - 1})
	check(denied.ok == false and "budget" in denied.message and terrain.runtime_data == data, "aggregate runtime budget over regions and mips rejects without publishing a partial bake: %s" % denied.get("message"))
	check(StrataBake.compile(terrain, {"channels": PackedStringArray(["mask"]), "region_cells": 16, "max_runtime_bytes": channel_total}).ok, "a budget of exactly the planned bytes fits")
	# Each profile costs one cell map (its mips included) per region against the same budget.
	var profile_free := options.duplicate()
	profile_free.erase("nav_profiles")
	var base_total: int = StrataBake.compile(terrain, profile_free).data.get_manifest().total_bytes
	var profile_cost := 2 * 6 * (20 * 20 + 12 * 12 + 8 * 8)
	var with_budget := options.duplicate()
	with_budget.max_runtime_bytes = base_total + profile_cost - 1
	var over := StrataBake.compile(terrain, with_budget)
	check(not over.ok and "budget" in over.message, "two profiles one byte over the budget are rejected: %s" % over.get("message"))
	with_budget.max_runtime_bytes = base_total + profile_cost
	var exact := StrataBake.compile(terrain, with_budget)
	check(exact.ok and exact.data.get_manifest().total_bytes == base_total + profile_cost, "profiles fit a budget of exactly their mask bytes")
	check(StrataBake.compile(terrain, {"mip_levels": 1, "far_level": 0, "coarse_max_side": 1 << 20, "region_cells": 16}).data.get_manifest().total_bytes < StrataBake.compile(terrain, {"mip_levels": 3, "region_cells": 16}).data.get_manifest().total_bytes, "mip_levels changes the planned payload")
	detail.procedural_stale = true
	check(terrain.is_runtime_bake_stale(), "procedural stale intent invalidates an otherwise unchanged bake")
	var accepted_options := options.duplicate(); accepted_options.allow_stale_procedural = true
	check(StrataBake.bake(terrain, accepted_options).ok and not terrain.is_runtime_bake_stale(), "explicitly accepted cached stale state can be freshly baked")
	# The inspector's Bake runtime data button: cell masks on, saved cooks accepted, published.
	var inspector_bake := terrain.bake_runtime()
	check(inspector_bake.get("ok", false) and terrain.runtime_data == inspector_bake.data and not terrain.is_runtime_bake_stale() and terrain.runtime_data.has_map("holes") and inspector_bake.report.mask_source == "layers", "the inspector bake publishes the stack with layer-derived cell masks")
	detail.mark_producer_intent()
	check(terrain.is_runtime_bake_stale(), "a new intent revision invalidates a deliberately accepted cache even while already procedural-stale")
	detail.procedural_stale = false
	check(StrataBake.bake(terrain, options).ok, "fresh result restored after intent checks")
	data = terrain.runtime_data

	# Failures keep the previous bake and state.
	var revision := data.bake_revision
	var bad_holes := StrataBake.bake(terrain, {"holes": Image.create(10, 10, false, Image.FORMAT_L8)})
	check(not bad_holes.ok and terrain.runtime_data == data and data.bake_revision == revision and not terrain.is_runtime_bake_stale(), "invalid holes reject without touching the bake")
	check(not StrataBake.bake(terrain, {"region_cells": 100}).ok and not StrataBake.bake(terrain, {"mip_levels": 0}).ok and terrain.runtime_data == data, "invalid region cells and mip levels reject")
	check(not StrataBake.bake(terrain, {"channels": PackedStringArray(["nav_x"])}).ok and not StrataBake.bake(terrain, {"channels": PackedStringArray(["a__coverage"])}).ok and not StrataBake.bake(terrain, {"channels": PackedStringArray(["macro"])}).ok, "channel names may not collide with nav, coverage or standard maps")
	check(not StrataBake.bake(terrain, {"nav_profiles": [{"name": &"exclusion", "rule": {"exclusion": true}}]}).ok, "a profile named exclusion would collide with nav_exclusion")
	check(not StrataBake.bake(terrain, {"spacing": 0.7}).ok and terrain.runtime_data == data, "spacing that does not divide the bounds is rejected")
	check(not StrataBake.bake(terrain, {"channels": PackedStringArray(["height"])}).ok, "height cannot be retained as a custom channel")
	# Invalid profiles fail the bake, name the profile, and keep the old bake.
	var many_terms := []
	for index in range(9): many_terms.append({"height_min": float(index)})
	for invalid in [
		[{"name": &"swim", "rule": {"channel": "water", "min": 0.5}}, ["swim", "water", "not retained"]],
		[{"name": &"typo", "rule": {"channel": "mask", "minimum": 0.5}}, ["typo", "unknown key minimum"]],
		[{"name": &"nan", "rule": {"channel": "mask", "min": NAN}}, ["nan", "finite"]],
		[{"name": &"inf", "rule": {"all": [{"height_max": INF}]}}, ["inf", "finite"]],
		[{"name": &"mixed", "rule": {"channel": "mask", "min": 0.5, "slope_max": 30.0}}, ["mixed", "mixes"]],
		[{"name": &"steep", "rule": {"slope_max": 120.0}}, ["steep", "0..90"]],
		[{"name": &"inverted", "rule": {"height_min": 2.0, "height_max": 1.0}}, ["inverted", "above"]],
		[{"name": &"empty", "rule": {"any": []}}, ["empty", "nonempty"]],
		[{"name": &"flag", "rule": {"exclusion": false}}, ["flag", "must be true"]],
		[{"name": &"text", "rule": {"not": "exclusion"}}, ["text", "Dictionary"]],
		[{"name": &"wide", "rule": {"all": many_terms}}, ["wide", "at most 8"]],
		[{"name": &"default", "rule": {"exclusion": true}}, ["reserved"]],
		[{"name": &"norule"}, ["norule", "no rule"]],
		[{"name": &"extra", "rule": {"exclusion": true}, "layers": 2}, ["extra", "unknown key layers"]]]:
		var invalid_options := options.duplicate()
		invalid_options.nav_profiles = [invalid[0]]
		var failed := StrataBake.bake(terrain, invalid_options)
		var named: bool = not failed.ok
		for fragment in invalid[1]: named = named and fragment in String(failed.get("message", ""))
		check(named and terrain.runtime_data == data and data.bake_revision == revision, "invalid profile %s rejected: %s" % [invalid[0].get("name"), failed.get("message")])
	var duplicate_names := options.duplicate()
	duplicate_names.nav_profiles = [profiles[0], profiles[0]]
	check(not StrataBake.bake(terrain, duplicate_names).ok and terrain.runtime_data == data, "duplicate profile names are rejected")
	var unretained := options.duplicate()
	unretained.channels = PackedStringArray()
	var unretained_result := StrataBake.bake(terrain, unretained)
	check(not unretained_result.ok and "not retained" in unretained_result.message and terrain.runtime_data == data, "a rule may only read channels retained by this bake: %s" % unretained_result.get("message"))
	check(not StrataBake.bake(terrain, {"nav_profiles": {"wet": {}}}).ok, "nav_profiles must be an Array")
	var plain := StrataBake.compile(terrain)
	check(plain.ok and plain.data.nav_profile_rules == {D: {"exclusion": true}} and plain.data.get_nav_profile_names() == [D] and not plain.data.maps.has("holes"), "a bake without profiles still documents the default profile")

	# A compiled field from before an edit is stale.
	var early := StrataProcedural.compile_heightfield(terrain, null, 1.0)
	fine.data.set_sample(&"height", Vector2i(0, 0), 0.9)
	check(terrain.is_runtime_bake_stale() and stale_signals.back() == true, "a manual sculpt marks the bake stale")
	var stale_compiled := StrataBake.bake(terrain, {"compiled": early})
	check(not stale_compiled.ok and terrain.runtime_data == data, "a compiled field with an outdated token is rejected: %s" % stale_compiled.get("message"))
	check(not StrataBake.export_runtime(terrain).ok, "a stale bake cannot be exported")
	check(StrataBake.bake(terrain, options).ok and terrain.runtime_data.bake_revision == revision + 1, "rebake after sculpting")
	lattice_matches_stack(terrain.runtime_data, "after sculpt")
	data = terrain.runtime_data

	# Every other stack edit also marks it stale.
	for edit in [
		func() -> void: detail.enabled = false,
		func() -> void: detail.enabled = true,
		func() -> void: fine.set_composition(&"height", StrataLayer.Composition.REPLACE),
		func() -> void: fine.set_composition(&"height", StrataLayer.Composition.ADD),
		func() -> void: terrain.move_child(flatten, 0),
		func() -> void: terrain.move_child(flatten, terrain.get_child_count() - 1),
		func() -> void: terrain.base_bounds = Rect2(-24.0, -16.0, 48.0, 30.0),
		func() -> void: terrain.base_bounds = Rect2(-24.0, -16.0, 48.0, 32.0)]:
		# Cell masks only fit the original 48 x 32 bounds.
		var rebake := StrataBake.bake(terrain, options if terrain.base_bounds.size == Vector2(48, 32) else {})
		check(rebake.ok and not terrain.is_runtime_bake_stale(), "rebake before edit: %s" % rebake.get("message", ""))
		edit.call()
		check(terrain.is_runtime_bake_stale(), "stack edit marks the bake stale")
	check(StrataBake.bake(terrain, options).ok, "final bake")
	data = terrain.runtime_data
	lattice_matches_stack(data, "final")

	# Runtime export: new nodes and data, authoring scene unchanged.
	var authoring_children := terrain.get_children().map(func(child: Node) -> String: return child.name)
	var exported := StrataBake.export_runtime(terrain, {"name": "IslandRuntime", "collision": {"chunk_cells": 16, "collision_layer": 4}, "navigation": {"tile_cells": 16, "use_async": false}})
	check(exported.ok, "export: %s" % exported.get("message", ""))
	if not exported.ok:
		finish("RUNTIME_BAKE_TEST")
		return
	var runtime_root: Node3D = exported.root
	check(terrain.get_children().map(func(child: Node) -> String: return child.name) == authoring_children and terrain.runtime_data == data, "authoring terrain is unchanged by export")
	check(exported.data != data and payload_hashes(exported.data) == payload_hashes(data) and exported.data.regions.size() == 6 and exported.data.regions[Vector2i(0, 0)] != data.regions[Vector2i(0, 0)], "export owns an independent copy of the compiled data (regions embedded)")
	check(not StrataBake.export_runtime(terrain, {"embed_regions": false}).ok, "referencing external regions needs a storage directory")
	var shared := StrataBake.export_runtime(terrain, {"share_data": true})
	check(shared.ok and shared.data == data and shared.root.get_meta(&"strata_runtime_data") == data, "share_data references the published resource")
	shared.root.free()
	check(runtime_root.transform == terrain.transform, "runtime root keeps the terrain transform")
	var authoring_leak := []
	for node in [runtime_root] + runtime_root.find_children("*", "", true, false):
		if node is StrataTerrain3D or node is StrataLayer or node is StrataRenderer:
			authoring_leak.append(node.name)
	check(authoring_leak.is_empty(), "no authoring nodes in the runtime export: %s" % [authoring_leak])
	var authoring_properties := []
	for property in exported.data.get_property_list():
		if property.name in ["producer_id", "layer_id", "procedural_fields", "composition_modes"] or "ownership" in property.name:
			authoring_properties.append(property.name)
	check(authoring_properties.is_empty(), "runtime data carries no ownership/producer/authoring state: %s" % [authoring_properties])
	check(runtime_root.get_node("Collision").chunk_cells == 16 and runtime_root.get_node("Collision").collision_layer == 4, "collision settings applied")
	check(not StrataBake.export_runtime(terrain, {"collision": {"no_such_setting": 1}}).ok, "unknown export settings rejected")
	check(not StrataBake.export_runtime(terrain, {"collision": {"chunk_cells": 0}}).ok, "invalid collision export settings cannot silently fall back to defaults")
	get_root().add_child(runtime_root)
	var runtime_collision: StrataCollision = runtime_root.get_node("Collision")
	check(runtime_collision.prepare_region(exported.data.bounds).ok, "exported collision builds")
	await physics_frame
	await physics_frame
	var probe := Vector2(-10.3, 7.6)
	var from := runtime_root.global_transform * Vector3(probe.x, 50, probe.y)
	var hit := runtime_root.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 200.0))
	var expected: Dictionary = exported.data.sample_height_world(from, runtime_root.global_transform)
	check(not hit.is_empty() and absf(hit.position.y - expected.position.y) < 0.0005, "exported collision matches the bake (%s vs %s)" % [hit.get("position"), expected.get("position")])
	runtime_root.free()

	# Authoring scene save/load keeps the bake fresh; edits then stale it.
	for node in [host, terrain] + terrain.get_children():
		if node != terrain and node != host:
			node.owner = scene
	host.owner = scene
	terrain.owner = scene
	var authoring_scene := PackedScene.new()
	check(authoring_scene.pack(scene) == OK and ResourceSaver.save(authoring_scene, "res://export/authoring.scn") == OK, "authoring scene saved")
	var reloaded: Node3D = (ResourceLoader.load("res://export/authoring.scn", "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	get_root().add_child(reloaded)
	var reloaded_terrain: StrataTerrain3D = reloaded.get_node("Terrain")
	check(reloaded_terrain.runtime_data != null and payload_hashes(reloaded_terrain.runtime_data) == payload_hashes(data) and not reloaded_terrain.is_runtime_bake_stale(), "reloaded authoring scene keeps a fresh bake")
	check(not StrataBake.bake(reloaded_terrain).ok and reloaded_terrain.runtime_data.bake_revision == data.bake_revision, "reloaded procedural caches need a recook (or explicit opt-in) to rebake")
	(reloaded_terrain.get_node("ManualFine") as StrataLayer).data.set_sample(&"height", Vector2i(1, 1), 0.3)
	check(reloaded_terrain.is_runtime_bake_stale(), "editing a reloaded layer stales its bake")
	reloaded.free()

	# Runtime scene + external data for the runtime-only roundtrip project.
	var saved := StrataBake.save_runtime_scene(terrain, "res://export/runtime_terrain.scn", {"name": "IslandRuntime", "data_path": "res://export/runtime_data.res", "collision": {"chunk_cells": 16, "collision_layer": 4}, "navigation": {"tile_cells": 16, "use_async": false}})
	check(saved.ok, "runtime scene saved: %s" % saved.get("message", ""))
	check(ResourceSaver.save(data.duplicate_runtime(), "res://export/runtime_data_text.tres") == OK, "text resource saved")
	var points := []
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	for index in range(200):
		points.append(Vector2(rng.randf_range(-24.0, 24.0), rng.randf_range(-16.0, 16.0)))
	# Hole cells (30..32, 4..5) are local (6..9, -12..-10); pad, mask samples, outside.
	points.append_array([Vector2(7.5, -11.5), Vector2(8.2, -10.9), Vector2(6.01, -11.99), Vector2(15.0, 10.0), Vector2(0, 0), Vector2(1, 0), Vector2(30, 0)])
	var expected_rows := []
	for point in points:
		var sampled := data.sample_height(point)
		var mask := data.sample_channel(&"mask", point)
		var world_mask := terrain.sample_runtime_channel(&"mask", terrain.global_transform * Vector3(point.x, 7.0, point.y))
		check(world_mask.status == mask.status and (not mask.ok or absf(world_mask.value - mask.value) < 0.00001), "sample_runtime_channel maps world to local at %s" % point)
		expected_rows.append({"x": point.x, "z": point.y, "status": sampled.status, "height": sampled.value if sampled.status == S.OK else 0.0, "mask_status": mask.status, "mask": mask.value if mask.status == S.OK else 0.0})
	var file := FileAccess.open("res://export/expected.json", FileAccess.WRITE)
	# Path from open ground past the hole block (the raised pad is unreachable).
	file.store_string(JSON.stringify({"transform": var_to_str(terrain.transform), "revision": data.bake_revision, "rows": expected_rows, "nav_from": [-18.0, -10.0], "nav_to": [20.0, -13.0], "profiles": data.get_nav_profile_names().map(func(name: StringName) -> String: return String(name)), "hashes": payload_hashes(data)}))
	file.close()
	# Storage: publishing with a storage directory writes the regions next to the manifest, the
	# terrain keeps working from them, a rebake with fewer regions removes the stale files and
	# a format 1 manifest is refused.
	var storage := "user://bake_storage_test"
	if DirAccess.dir_exists_absolute(storage.path_join("regions")):
		for stale_file in DirAccess.get_files_at(storage.path_join("regions")): DirAccess.remove_absolute(ProjectSettings.globalize_path(storage.path_join("regions").path_join(stale_file)))
	terrain.storage_directory = storage
	var stored := StrataBake.bake(terrain, options)
	check(stored.ok and terrain.runtime_data.regions.is_empty() and terrain.runtime_data.region_directory == storage + "/regions", "a storage directory moves the regions into files: %s" % stored.get("message"))
	var stored_files := DirAccess.get_files_at(storage + "/regions")
	check(stored_files.size() == 12 and FileAccess.file_exists(storage + "/runtime_data.res") and stored_files.has("region_2_1.res") and stored_files.has("region_2_1.lod.res"), "manifest, six region files and six lod files exist: %s" % [stored_files])
	check(terrain.runtime_data.validate(true).ok and payload_hashes(terrain.runtime_data) == payload_hashes(data), "the published bake serves identical bytes from memory")
	var loaded_bake := StrataStorage.load_runtime_data(terrain)
	check(loaded_bake != null and loaded_bake.regions.is_empty() and loaded_bake.validate(true).ok and payload_hashes(loaded_bake) == payload_hashes(data), "the saved manifest reloads and loads its regions from files")
	var moved := loaded_bake.duplicate_runtime()
	moved.region_directory = "res://nowhere"
	check(moved.validate(true).ok == false, "a manifest pointing at a missing directory fails a deep validation")
	var exported_external := StrataBake.export_runtime(terrain, {"embed_regions": false})
	check(exported_external.ok and exported_external.data.regions.is_empty() and exported_external.data.region_directory == storage + "/regions", "an export may keep pointing at the region directory")
	exported_external.root.free()
	var exported_embedded := StrataBake.export_runtime(terrain)
	check(exported_embedded.ok and exported_embedded.data.regions.size() == 6 and payload_hashes(exported_embedded.data) == payload_hashes(data), "an export of an external bake embeds its regions by default")
	exported_embedded.root.free()
	var smaller := StrataBake.bake(terrain, {"region_cells": 32})
	check(smaller.ok and DirAccess.get_files_at(storage + "/regions").size() == 4, "a rebake with a 2 x 1 grid removes the stale region files: %s" % [DirAccess.get_files_at(storage + "/regions")])
	directory_bakes(options, data)
	var legacy := FileAccess.open(storage + "/runtime_data.res", FileAccess.WRITE)
	legacy.close()
	var v1 := StrataRuntimeData.new()
	v1.format_version = 1
	ResourceSaver.save(v1, storage + "/runtime_data.res")
	check(StrataStorage.load_runtime_data(terrain) == null and not v1.validate().ok, "a format 1 manifest is not loaded")
	for stale_file in DirAccess.get_files_at(storage + "/regions"): DirAccess.remove_absolute(ProjectSettings.globalize_path(storage + "/regions/" + stale_file))
	terrain.storage_directory = ""
	scene.free()
	finish("RUNTIME_BAKE_TEST")

static func scratch(name: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("../build/test-scratch").path_join(name).simplify_path()

static func clear_directory(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path): return
	for file in DirAccess.get_files_at(path): DirAccess.remove_absolute(path.path_join(file))
	for folder in DirAccess.get_directories_at(path): clear_directory(path.path_join(folder))
	DirAccess.remove_absolute(path)

static func same_region(a: String, b: String) -> bool:
	var left := ResourceLoader.load(a, "", ResourceLoader.CACHE_MODE_IGNORE) as StrataRegionData
	var right := ResourceLoader.load(b, "", ResourceLoader.CACHE_MODE_IGNORE) as StrataRegionData
	if left == null or right == null: return false
	if left.region != right.region or left.first_level != right.first_level or left.origin != right.origin or left.height_min != right.height_min or left.height_max != right.height_max or left.map_names() != right.map_names(): return false
	for name in left.map_names():
		if left.maps[name].levels != right.maps[name].levels: return false
	return true

static func file_bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path)

## Directory bakes (Phase C, D3): batches, lod files, equality with the embedded bake, budgets and
## the rejection path. [param options] is the embedded test bake; [param embedded] its data.
func directory_bakes(options: Dictionary, embedded: StrataRuntimeData) -> void:
	var root_path := scratch("runtime_bake_directory")
	clear_directory(root_path)
	var reference := StrataBake.compile(terrain, options)
	check(reference.ok and not reference.report.has("error"), "reference embedded compile")
	var progress: Array = []
	var small := options.duplicate()
	small.region_directory = root_path.path_join("small/regions")
	small.bake_batch = 2
	small.progress = func(done: int, total: int) -> void: progress.append([done, total])
	var compiled := StrataBake.compile(terrain, small)
	check(compiled.ok, "a directory bake compiles: %s" % compiled.get("message", ""))
	var data: StrataRuntimeData = compiled.data
	var report: Dictionary = compiled.report
	check(data.regions.is_empty() and data.region_directory == small.region_directory and data.is_resident() and data.validate().ok, "the manifest holds no embedded regions and points at the directory")
	check(report.batches == 3 and report.peak_regions_in_memory == 2 and report.written_files == 12 and report.disk_bytes > 0 and progress == [[2, 6], [4, 6], [6, 6]], "report: %d batches, peak %d, %d files, %d bytes, progress %s" % [report.batches, report.peak_regions_in_memory, report.written_files, report.disk_bytes, progress])
	check(not DirAccess.dir_exists_absolute(small.region_directory + StrataBake.STAGING_SUFFIX), "the staging directory is gone")
	var listed := DirAccess.get_files_at(small.region_directory)
	var total_size := 0
	for file in listed: total_size += file_bytes(small.region_directory.path_join(file)).size()
	check(listed.size() == 12 and total_size == report.disk_bytes, "twelve files whose sizes add up to disk_bytes (%d / %d)" % [total_size, report.disk_bytes])
	var lod_ok := true
	var lod_partial := true
	for y in range(data.grid.y):
		for x in range(data.grid.x):
			var xy := Vector2i(x, y)
			var full := ResourceLoader.load(small.region_directory.path_join(StrataRuntimeData.REGION_FILE % [x, y]), "", ResourceLoader.CACHE_MODE_IGNORE) as StrataRegionData
			var lod := ResourceLoader.load(small.region_directory.path_join(StrataRuntimeData.LOD_REGION_FILE % [x, y]), "", ResourceLoader.CACHE_MODE_IGNORE) as StrataRegionData
			if full == null or lod == null or not full.validate().ok or not lod.validate().ok or full.first_level != 0 or lod.first_level != 2: lod_ok = false; continue
			var source: StrataRegionData = reference.data.regions[xy]
			for name in source.map_names():
				if full.level_bytes(name, 1) != source.level_bytes(name, 1): lod_ok = false
				if lod.level_bytes(name, 2) != source.level_bytes(name, 2) or not lod.level_bytes(name, 0).is_empty() or not lod.level_bytes(name, 1).is_empty() or lod.get_image(name, 1) != null or lod.get_image(name, 2) == null or lod.level_count(name) != 3: lod_partial = false
			if lod.payload_bytes() >= full.payload_bytes(): lod_partial = false
	check(lod_ok, "every region file loads, validates and equals the embedded region")
	check(lod_partial, "every lod file holds only levels >= lod_level, equal to the embedded levels")
	check(data.lod_level == 2 and report.lod_level == 2 and data.get_manifest().lod_level == 2, "the manifest records lod_level 2")
	check(data.region_extrema == reference.data.region_extrema and data.height_min == reference.data.height_min and data.height_max == reference.data.height_max, "per-region extrema equal the embedded bake")
	check(data.coarse_level == reference.data.coarse_level and data.coarse_maps == reference.data.coarse_maps and not data.coarse_maps.is_empty(), "coarse maps are byte-exact")
	check(report.nav_profiles == reference.report.nav_profiles and report.hole_cells == reference.report.hole_cells and report.nav_excluded_cells == reference.report.nav_excluded_cells and report.hole_cells > 0, "navigation, hole and exclusion counts equal the embedded bake: %s" % [report.nav_profiles])
	check(payload_hashes(data) == payload_hashes(reference.data) and payload_hashes(data) == payload_hashes(embedded), "the files serve the same bytes as the embedded bake")
	# One huge batch writes identical files.
	var large := options.duplicate()
	large.region_directory = root_path.path_join("large/regions")
	large.bake_batch = 1000
	var large_bake := StrataBake.compile(terrain, large)
	var identical: bool = large_bake.ok and large_bake.report.batches == 1 and large_bake.report.peak_regions_in_memory == 6 and DirAccess.get_files_at(large.region_directory) == listed
	# Files carry their own path inside, so they are compared by what they load as.
	for file in listed:
		if not same_region(large.region_directory.path_join(file), small.region_directory.path_join(file)): identical = false
	check(identical and large_bake.data.coarse_maps == data.coarse_maps and large_bake.data.region_extrema == data.region_extrema, "a 2-region batch and a 1000-region batch write identical files (same loaded content)")
	# A rejected bake keeps the previous files and removes its staging directory.
	var before := file_bytes(large.region_directory.path_join("region_0_0.res"))
	var rejecting := large.duplicate()
	rejecting.bake_batch = 2
	rejecting.progress = func(done: int, _total: int) -> void:
		if done == 2: rough.data.set_sample(&"height", Vector2i(0, 0), 9.0)
	var rejected := StrataBake.compile(terrain, rejecting)
	check(not rejected.ok and "changed" in String(rejected.message), "a stack edit during the bake is rejected: %s" % rejected.get("message", ""))
	check(not DirAccess.dir_exists_absolute(large.region_directory + StrataBake.STAGING_SUFFIX) and file_bytes(large.region_directory.path_join("region_0_0.res")) == before and DirAccess.get_files_at(large.region_directory) == listed, "the rejected bake left the previous files and no staging directory")
	rough.data.set_sample(&"height", Vector2i(0, 0), 2.0 * sin(0.0) - 1.5)
	# Level options and budgets.
	var one := options.duplicate()
	one.region_directory = root_path.path_join("one/regions")
	one.lod_level = 1
	var lod_one := StrataBake.compile(terrain, one)
	var lod_one_region := ResourceLoader.load(one.region_directory.path_join("region_1_1.lod.res"), "", ResourceLoader.CACHE_MODE_IGNORE) as StrataRegionData
	check(lod_one.ok and lod_one.data.lod_level == 1 and lod_one_region != null and lod_one_region.first_level == 1 and lod_one_region.validate().ok and lod_one_region.get_image("height", 1) != null and lod_one_region.get_image("height", 0) == null, "lod_level 1 writes lod files from level 1")
	var none := options.duplicate()
	none.region_directory = root_path.path_join("none/regions")
	none.lod_level = 0
	var no_lod := StrataBake.compile(terrain, none)
	check(no_lod.ok and no_lod.report.written_files == 6 and not FileAccess.file_exists(none.region_directory.path_join("region_0_0.lod.res")), "lod_level 0 writes no lod files")
	for bad in [3, 5, -1]:
		var rejected_level := options.duplicate()
		rejected_level.region_directory = root_path.path_join("bad/regions")
		rejected_level.lod_level = bad
		check(not StrataBake.compile(terrain, rejected_level).ok, "lod_level %d is rejected" % bad)
	var capped := options.duplicate()
	capped.region_directory = root_path.path_join("capped/regions")
	capped.max_directory_bytes = 1000
	var over := StrataBake.compile(terrain, capped)
	check(not over.ok and "max_directory_bytes" in String(over.message) and not DirAccess.dir_exists_absolute(capped.region_directory), "max_directory_bytes rejects before writing: %s" % over.get("message", ""))
	var too_big := options.duplicate()
	too_big.max_runtime_bytes = 1000
	check(not StrataBake.compile(terrain, too_big).ok, "the embedded payload budget still applies without a directory")
	too_big.region_directory = root_path.path_join("budget/regions")
	check(StrataBake.compile(terrain, too_big).ok, "a directory bake is not bound by the embedded payload budget")
	for bad_batch in [0, -3]:
		var rejected_batch := options.duplicate()
		rejected_batch.region_directory = root_path.path_join("batch/regions")
		rejected_batch.bake_batch = bad_batch
		check(not StrataBake.compile(terrain, rejected_batch).ok, "bake_batch %d is rejected" % bad_batch)
	# Exports from a directory manifest embed the full files.
	terrain.publish_runtime_data(data, StrataBake.stack_signature(terrain))
	var exported := StrataBake.export_runtime(terrain)
	check(exported.ok and exported.data.regions.size() == 6 and payload_hashes(exported.data) == payload_hashes(embedded) and exported.data.get_region(Vector2i(0, 0)).first_level == 0, "an export of a directory bake embeds the full files")
	if exported.ok: exported.root.free()
	var kept := StrataBake.export_runtime(terrain, {"embed_regions": false})
	check(kept.ok and kept.data.regions.is_empty() and kept.data.region_directory == data.region_directory and kept.data.lod_level == 2, "an export may keep pointing at the directory")
	if kept.ok: kept.root.free()
	clear_directory(root_path)
