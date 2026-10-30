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

static func payload_hashes(data: StrataRuntimeData) -> Dictionary:
	var result := {}
	var payloads := {"heights": data.heights.to_byte_array(), "holes": data.holes, "nav_exclusions": data.nav_exclusions, "lattice": PackedFloat64Array([data.bounds.position.x, data.bounds.position.y, data.bounds.size.x, data.bounds.size.y, data.height_min, data.height_max]).to_byte_array()}
	for name in data.channels:
		payloads["channel:" + name] = data.channels[name].values.to_byte_array() + data.channels[name].coverage.to_byte_array()
	for name in data.nav_profiles:
		payloads["profile:" + name] = data.nav_profiles[name]
	payloads["profile_rules"] = var_to_bytes(data.nav_profile_rules)
	for key in payloads:
		var context := HashingContext.new()
		context.start(HashingContext.HASH_SHA256)
		context.update(payloads[key])
		result[key] = context.finish().hex_encode()
	return result

func lattice_matches_stack(data: StrataRuntimeData, label: String) -> void:
	var worst := 0.0
	for j in range(data.resolution.y):
		for i in range(data.resolution.x):
			var point := data.lattice_to_local(Vector2(i, j))
			worst = maxf(worst, absf(data.heights[j * data.resolution.x + i] - terrain.sample_height(point)))
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
	scene.add_child(terrain)
	terrain.runtime_bake_stale_changed.connect(func(stale: bool) -> void: stale_signals.append(stale))

	# RoughBase: manual Replace on a 4 m grid, signed heights.
	rough = layer("RoughBase")
	rough.data.sample_spacing = 4.0
	rough.data.grid_origin = Vector2(-24.0, -16.0)
	for j in range(9):
		for i in range(13):
			rough.data.set_sample(&"height", Vector2i(i, j), 2.0 * sin(i * 0.5) - 1.5 + j * 0.3)
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
	ids.fill(Color(3.0 / 255.0, 7.0 / 255.0, 0, 0))
	var weights := Image.create(5, 5, false, Image.FORMAT_RGBAF)
	weights.fill(Color(0.75, 0.25, 0, 0))
	# Two static navigation profiles; the slope threshold has more digits than a
	# text resource keeps, so the roundtrip proves exact rule storage.
	var profiles := [{"name": &"wet", "rule": {"channel": "mask", "min": 0.5}}, {"name": &"flat_dry", "rule": {"all": [{"slope_max": 20.123456789}, {"not": {"channel": "mask", "min": 1.0}}, {"exclusion": true}]}}]
	var options := {"holes": holes, "nav_exclusions": exclusions, "channels": PackedStringArray(["mask"]), "material_ids": ids, "material_weights": weights, "nav_profiles": profiles}
	var baked := StrataBake.bake(terrain, options)
	check(baked.ok, "complete bake: %s" % baked.get("message", ""))
	var data := terrain.runtime_data
	check(data.bake_revision == 2 and not terrain.is_runtime_bake_stale() and stale_signals == [false, true, false], "revision 2, fresh: %s" % [stale_signals])
	check(data.resolution == Vector2i(49, 33) and data.get_spacing() == 1.0, "1 m lattice over the full bounds")
	lattice_matches_stack(data, "full stack")
	check(data.height_min < 0.0 and data.height_max > 0.0, "signed heights retained")
	near(data.sample_height(Vector2(15.0, 10.0)).value, 1.25, 0.000001, "BuildingFlatten pad is the top Replace")
	check(data.holes.count(255) == 6 and data.is_hole_cell(Vector2i(31, 5)) and not data.is_hole_cell(Vector2i(5, 5)), "holes canonicalized with byte >= 128")
	check(data.nav_exclusions.count(255) == 36 and data.is_nav_excluded_cell(Vector2i(36, 8)) and not data.is_nav_excluded_cell(Vector2i(1, 1)), "exclusions canonicalized with value >= 0.5")
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
	check(data.material_ids.get_pixel(2, 2).g8 == 7 and is_equal_approx(data.material_weights.get_pixel(2, 2).r, 0.75), "material controls retained")

	# Static navigation profiles: stored masks (255 = blocked), rules, default.
	var D := StrataRuntimeData.DEFAULT_NAV_PROFILE
	check(data.nav_profiles.keys() == [&"wet", &"flat_dry"] and not data.nav_profiles.has(D) and data.get_nav_profile_names() == [D, &"flat_dry", &"wet"], "profiles stored by name; default is not a stored copy: %s" % [data.nav_profiles.keys()])
	check(data.nav_profile_rules == {D: {"exclusion": true}, &"wet": profiles[0].rule, &"flat_dry": profiles[1].rule}, "the bake records every rule, including the default: %s" % [data.nav_profile_rules])
	check(data.has_nav_profile(D) and data.get_nav_profile_mask(D) == data.nav_exclusions and data.get_nav_profile_image(D).get_data() == data.get_nav_exclusion_image().get_data(), "the default profile equals the nav_exclusions mask")
	check(data.validate().ok, "profiled bake validates")
	var mask_values: PackedFloat32Array = data.channels["mask"].values
	var mask_coverage: PackedFloat32Array = data.channels["mask"].coverage
	var uncovered_zero := true
	for index in range(mask_values.size()):
		uncovered_zero = uncovered_zero and (mask_coverage[index] > 0.0 or mask_values[index] == 0.0)
	check(uncovered_zero, "uncovered mask samples store 0, the value profile rules read")
	var wet_expected := PackedByteArray(); wet_expected.resize(cells.x * cells.y)
	for z in range(cells.y):
		for x in range(cells.x):
			var i := z * 49 + x
			var mean := (float(mask_values[i]) + mask_values[i + 1] + mask_values[i + 49] + mask_values[i + 50]) * 0.25
			wet_expected[z * cells.x + x] = 0 if mean >= 0.5 else 255
	check(data.nav_profiles[&"wet"] == wet_expected and wet_expected.count(0) > 0, "wet profile is the cell-mean threshold of the retained mask (%d walkable cells)" % wet_expected.count(0))
	check(data.nav_profiles[&"flat_dry"] == StrataNavProfiles.evaluate(data, profiles[1].rule) and data.nav_profiles[&"flat_dry"].count(0) > 0 and data.nav_profiles[&"flat_dry"].count(255) > 36, "flat_dry is reproducible from the stored data")
	check(data.is_nav_blocked_cell(Vector2i(36, 8), &"flat_dry") and data.is_nav_blocked_cell(Vector2i(36, 8), &"wet") == (wet_expected[8 * 48 + 36] == 255), "excluded cells block flat_dry; wet ignores exclusions")
	check(data.is_nav_blocked_cell(Vector2i(31, 5), &"wet") and data.is_nav_blocked_cell(Vector2i(31, 5), &"flat_dry"), "holes block every profile")
	var profile_manifest := data.get_manifest()
	check(profile_manifest.nav_profile_bytes == 2 * 48 * 32 and profile_manifest.nav_profiles.size() == 3 and profile_manifest.nav_profiles[0].name == D and profile_manifest.nav_profiles[0].blocked_cells == 36, "manifest lists default + both profiles: %s" % [profile_manifest.nav_profiles])
	check(baked.report.nav_profiles.has(&"wet") and baked.report.nav_profiles[&"flat_dry"].terms == 3 and baked.report.nav_profiles[&"wet"].blocked_cells == wet_expected.count(255), "bake report lists profile evaluation: %s" % [baked.report.nav_profiles])
	var evicted := data.duplicate_runtime()
	check(evicted.nav_profiles == data.nav_profiles and evicted.nav_profile_rules == data.nav_profile_rules, "duplicate_runtime copies profiles and rules")
	evicted.evict_channel(&"mask")
	var not_resident := StrataNavProfiles.evaluate_checked(evicted, profiles[0].rule)
	check(not not_resident.ok and "not resident" in not_resident.message, "evaluating an evicted channel is an error: %s" % not_resident.get("message"))

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
	var layered := StrataBake.bake(terrain, {"cell_masks": true})
	check(layered.ok and layered.report.mask_source == "layers", "bake compiles layered masks: %s" % layered.get("message", ""))
	var reference_masks := StrataProcedural.compile_cell_masks(terrain, null, 1.0)
	check(layered.ok and terrain.runtime_data.holes == reference_masks.holes and reference_masks.holes.count(255) > 0, "baked holes are exactly the native canonical mask (%d cells)" % reference_masks.holes.count(255))
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
	check(again.ok and again.data.heights == data.heights, "bake with a preview cutoff set still compiles the complete stack")
	var through_rough := StrataProcedural.compile_heightfield(terrain, rough, 1.0)
	check((through_rough.image as Image).get_data().to_float32_array() != data.heights, "the preview cutoff would have produced different heights")
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
	var denied := StrataBake.compile(terrain, {"channels": PackedStringArray(["mask"]), "max_runtime_bytes": 49 * 33 * 12 - 1})
	check(not denied.ok and terrain.runtime_data == data, "aggregate runtime channel budget rejects without publishing a partial bake")
	# Each profile costs one byte per cell of the same budget.
	var profile_free := options.duplicate()
	profile_free.erase("nav_profiles")
	var base_total: int = StrataBake.compile(terrain, profile_free).data.get_manifest().total_bytes
	var with_budget := options.duplicate()
	with_budget.max_runtime_bytes = base_total + 2 * 48 * 32 - 1
	var over := StrataBake.compile(terrain, with_budget)
	check(not over.ok and "budget" in over.message, "two profiles one byte over the budget are rejected: %s" % over.get("message"))
	with_budget.max_runtime_bytes = base_total + 2 * 48 * 32
	var exact := StrataBake.compile(terrain, with_budget)
	check(exact.ok and exact.data.get_manifest().total_bytes == base_total + 2 * 48 * 32, "profiles fit a budget of exactly one byte per cell each")
	detail.procedural_stale = true
	check(terrain.is_runtime_bake_stale(), "procedural stale intent invalidates an otherwise unchanged bake")
	var accepted_options := options.duplicate(); accepted_options.allow_stale_procedural = true
	check(StrataBake.bake(terrain, accepted_options).ok and not terrain.is_runtime_bake_stale(), "explicitly accepted cached stale state can be freshly baked")
	detail.mark_producer_intent()
	check(terrain.is_runtime_bake_stale(), "a new intent revision invalidates a deliberately accepted cache even while already procedural-stale")
	detail.procedural_stale = false
	check(StrataBake.bake(terrain, options).ok, "fresh result restored after intent checks")
	data = terrain.runtime_data

	# Failures keep the previous bake and state.
	var revision := data.bake_revision
	var bad_holes := StrataBake.bake(terrain, {"holes": Image.create(10, 10, false, Image.FORMAT_L8)})
	check(not bad_holes.ok and terrain.runtime_data == data and data.bake_revision == revision and not terrain.is_runtime_bake_stale(), "invalid holes reject without touching the bake")
	var bad_ids := ids.duplicate()
	bad_ids.set_pixel(0, 0, Color(40.0 / 255.0, 0, 0, 0))
	check(not StrataBake.bake(terrain, {"material_ids": bad_ids, "material_weights": weights}).ok and terrain.runtime_data == data, "invalid material ids reject without touching the bake")
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
	check(plain.ok and plain.data.nav_profiles.is_empty() and plain.data.nav_profile_rules == {D: {"exclusion": true}} and plain.data.get_nav_profile_names() == [D], "a bake without profiles still documents the default profile")

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
	check(exported.data != data and exported.data.heights == data.heights, "export owns an independent copy of the compiled data")
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
	check(reloaded_terrain.runtime_data != null and reloaded_terrain.runtime_data.heights == data.heights and not reloaded_terrain.is_runtime_bake_stale(), "reloaded authoring scene keeps a fresh bake")
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
	scene.free()
	finish("RUNTIME_BAKE_TEST")
