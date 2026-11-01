extends "res://tests/runtime_test_base.gd"
## Terrain-wide tint/AO: neutral missing channels, per-channel ownership and
## Replace/Add, mixed lattices, packing/clamping, the shader lattice contract,
## optional runtime persistence, bake wiring and runtime export. Writes
## res://export/macro_* for the runtime-only roundtrip project.


const HALF := 0.002

var terrain: StrataTerrain3D
var host: Node

func _initialize() -> void:
	call_deferred("run")

func layer(label: String, procedural := false) -> StrataLayer:
	var result := StrataLayer.new()
	result.name = label
	result.procedural = procedural
	terrain.add_child(result)
	result.owner = terrain
	return result

func fill(layer_node: StrataLayer, channel: StringName, spacing: float, first: Vector2i, last: Vector2i, value: Callable) -> void:
	layer_node.data.sample_spacing = spacing
	for z in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			layer_node.data.set_sample(channel, Vector2i(x, z), value.call(x, z))

## Independent GDScript reference: neutral 1 base, then each enabled layer.
func reference(channel: StringName, position: Vector2, through: StrataLayer = null) -> float:
	var value := 1.0
	for entry in terrain.get_layers():
		if entry.enabled:
			var sampled: Dictionary = entry.sample_channel(channel, position)
			var coverage := clampf(float(sampled.get("coverage", 0.0)), 0.0, 1.0)
			var upper := float(sampled.get("value", 0.0))
			if entry.get_composition(channel) == StrataLayer.Composition.ADD: value += upper * coverage
			else: value = lerpf(value, upper, coverage)
		if entry == through: break
	return value

func max_error(composed: Dictionary, through: StrataLayer = null) -> Array:
	var worst := [0.0, 0.0, 0.0, 0.0]
	var image: Image = composed.image
	for j in range(composed.resolution.y):
		for i in range(composed.resolution.x):
			var p: Vector2 = composed.bounds.position + Vector2(i, j) * composed.spacing
			var texel := image.get_pixel(i, j)
			for c in range(4):
				var expected := reference(StrataMacro.CHANNELS[c], p, through)
				expected = clampf(expected, 0.0, 1.0 if c == 3 else 2.0)
				worst[c] = maxf(worst[c], absf(texel[c] - expected))
	return worst

func all_texels(image: Image, color: Color) -> bool:
	return image.get_data() == StrataMacro.neutral_image(image.get_size()).get_data() if color == Color(1, 1, 1, 1) else false

func run() -> void:
	host = Node.new(); host.name = "Host"; root.add_child(host)
	terrain = StrataTerrain3D.new(); terrain.name = "Terrain"
	terrain.base_bounds = Rect2(-20.0, -12.0, 40.0, 24.0)
	terrain.position = Vector3(5.0, 1.0, -3.0); terrain.rotation.y = 0.4
	root.add_child(terrain)
	var base := layer("Base")
	fill(base, &"height", 4.0, Vector2i(-5, -3), Vector2i(5, 3), func(x, z): return x * 0.5 + z * 0.25)
	await process_frame

	# 1. Missing channels are exactly neutral; auto bake stores no map.
	check(not StrataMacro.has_macro_channels(terrain), "height-only stack owns no macro channel")
	var empty := StrataMacro.compose(terrain)
	check(empty.ok and empty.empty and empty.resolution == Vector2i(11, 7) and empty.spacing == Vector2(4, 4), "empty compose is ok on the 4 m endpoint lattice: %s" % [empty.get("resolution")])
	check(empty.ok and all_texels(empty.image, Color(1, 1, 1, 1)), "missing tint/AO channels pack to exactly neutral (1,1,1,1)")
	check(empty.ok and empty.image.get_format() == Image.FORMAT_RGBAH and not empty.image.has_mipmaps(), "packed map is RGBAH without mipmaps")
	var plain := StrataBake.bake(terrain, {"spacing": 4.0})
	check(plain.ok and not plain.data.has_macro() and plain.report.macro == null, "auto bake without macro channels stores no macro map (backward compatible)")
	check(plain.ok and plain.data.sample_macro(Vector2.ZERO).status == StrataRuntimeData.Status.ABSENT and plain.data.sample_macro(Vector2.ZERO).tint == Color(1, 1, 1, 1), "absent macro samples neutral")
	var forced := StrataBake.compile(terrain, {"spacing": 4.0, "macro": true})
	check(forced.ok and forced.data.has_macro() and all_texels(forced.data.get_macro_image(), Color(1, 1, 1, 1)), "macro=true bakes a neutral map")
	var snapshot := StrataProcedural.create_snapshot(base, "cumulative", {"channels": ["terrain_ao"]})
	if snapshot.ok:
		var ao_field: Dictionary = snapshot.fields[0]; var ao_cover: Dictionary = snapshot.fields[1]
		var ao_values: Image = ao_field.image; var ao_coverage: Image = ao_cover.image
		check(StrataLayerData.validate_dense(ao_values).min == 1.0 and StrataLayerData.validate_dense(ao_values).max == 1.0 and StrataLayerData.validate_dense(ao_coverage).min == 1.0, "cumulative snapshot of an unowned macro channel is neutral 1 with full coverage")
	else: check(false, "cumulative macro snapshot: %s" % snapshot.message)

	# 2. Per-channel ownership and Replace/Add.
	var shade := layer("Shade")
	fill(shade, &"terrain_ao", 2.0, Vector2i(-6, -3), Vector2i(-2, 3), func(_x, _z): return 0.5)
	var warm := layer("Warm")
	warm.set_composition(&"terrain_tint_r", StrataLayer.Composition.ADD)
	fill(warm, &"terrain_tint_r", 2.0, Vector2i(1, -3), Vector2i(6, 3), func(_x, _z): return 0.25)
	var override := layer("Override")
	fill(override, &"terrain_tint_r", 2.0, Vector2i(4, -1), Vector2i(8, 1), func(_x, _z): return 0.6)
	await process_frame
	check(StrataMacro.has_macro_channels(terrain) and Array(StrataMacro.owned_channels(terrain)) == ["terrain_ao", "terrain_tint_r"], "owned macro channels are reported per channel: %s" % [StrataMacro.owned_channels(terrain)])
	var owned := StrataMacro.compose(terrain, {"spacing": 2.0})
	check(owned.ok and not owned.empty and owned.resolution == Vector2i(21, 13), "2 m compose resolution")
	if owned.ok:
		var image: Image = owned.image
		var at := func(p: Vector2) -> Color: return image.get_pixelv(Vector2i(((p - owned.bounds.position) / 2.0).round()))
		near(at.call(Vector2(-8, 0)).a, 0.5, HALF, "AO-only layer sets AO inside its ownership")
		near(at.call(Vector2(-8, 0)).r, 1.0, 0.0, "AO-only layer leaves tint r untouched")
		near(at.call(Vector2(-8, 0)).g, 1.0, 0.0, "AO-only layer leaves tint g untouched")
		near(at.call(Vector2(16, 10)).a, 1.0, 0.0, "AO is neutral outside every owner")
		near(at.call(Vector2(4, 4)).r, 1.25, HALF, "Add tint offsets the neutral base")
		near(at.call(Vector2(4, 4)).a, 1.0, 0.0, "tint-only Add layer leaves AO neutral")
		near(at.call(Vector2(10, 0)).r, 0.6, HALF, "upper Replace overrides the lower Add")
		near(at.call(Vector2(14, 0)).r, 0.6, HALF, "Replace outside the Add region replaces the neutral base")
		near(at.call(Vector2(10, 0)).b, 1.0, 0.0, "unowned tint b stays neutral")
		var errors := max_error(owned)
		check(errors.max() <= HALF, "every texel equals the per-channel neutral-base reference (max %s)" % [errors])
		var through := StrataMacro.compose(terrain, {"spacing": 2.0, "through_layer": warm})
		check(through.ok and max_error(through, warm).max() <= HALF and absf(through.image.get_pixel(15, 6).r - 1.25) <= HALF, "through_layer cutoff omits upper layers")
		var cumulative := StrataProcedural.create_snapshot(override, "cumulative", {"channels": ["terrain_tint_r"]})
		var field_image: Image = cumulative.fields[0].image if cumulative.ok else null
		var field_origin: Vector3 = cumulative.fields[0].sample_origin if cumulative.ok else Vector3.ZERO
		var cumulative_error := 0.0
		if field_image != null:
			for j in range(field_image.get_height()):
				for i in range(field_image.get_width()):
					var p := Vector2(field_origin.x, field_origin.z) + Vector2(i, j) * 2.0
					if terrain.contains_position(p): cumulative_error = maxf(cumulative_error, absf(field_image.get_pixel(i, j).r - reference(&"terrain_tint_r", p)))
		check(field_image != null and cumulative_error < 0.00001, "cumulative snapshots compose macro channels over the same neutral base (max %s)" % cumulative_error)

	# 3. Mixed lattices: a transposed, offset 3 m procedural field plus a 0.5 m manual layer.
	var generated := layer("Generated", true)
	var source := Image.create(9, 15, false, Image.FORMAT_RF)
	for y in range(15):
		for x in range(9): source.set_pixel(x, y, Color(0.4 + 0.05 * x + 0.02 * y, 0, 0, 1))
	var ticket := StrataProcedural.begin_transaction(host, "macro-test", [{"layer": generated, "channels": ["terrain_ao", "terrain_tint_g"], "required_channels": []}], [])
	var tint_g := Image.create(9, 15, false, Image.FORMAT_RF); tint_g.fill(Color(1.3, 0, 0, 1))
	var committed := StrataProcedural.commit_fields(ticket, [{"layer_id": generated.layer_id, "fields": [
		{"name": "terrain_ao", "image": source, "sample_origin": Vector3(-13.0, 7.0, 15.0), "sample_step_x": Vector3(0.0, 0.0, -3.0), "sample_step_y": Vector3(3.0, 0.0, 0.0)},
		{"name": "terrain_tint_g", "image": tint_g, "sample_origin": Vector3(-13.0, 0.0, 15.0), "sample_step_x": Vector3(0.0, 0.0, -3.0), "sample_step_y": Vector3(3.0, 0.0, 0.0), "composition": "add"}]}]) if ticket.ok else ticket
	check(committed.ok, "transposed procedural macro fields commit: %s" % committed.get("message"))
	generated.set_composition(&"terrain_tint_g", StrataLayer.Composition.REPLACE)
	var fine := layer("Fine")
	fill(fine, &"terrain_ao", 0.5, Vector2i(-11, -7), Vector2i(9, 13), func(x, z): return 0.2 + 0.01 * (x + z))
	fill(fine, &"terrain_tint_b", 0.5, Vector2i(0, 0), Vector2i(17, 3), func(_x, _z): return 1.7)
	fine.set_composition(&"terrain_tint_b", StrataLayer.Composition.REPLACE)
	await process_frame
	var mixed := StrataMacro.compose(terrain, {"spacing": 1.5})
	check(mixed.ok and mixed.resolution == Vector2i(28, 17) and is_equal_approx(mixed.spacing.x, 40.0 / 27.0) and is_equal_approx(mixed.spacing.y, 1.5), "non-divisible spacing returns the actual endpoint-aligned step: %s" % [mixed.get("spacing")])
	if mixed.ok:
		var errors := max_error(mixed)
		check(errors.max() <= HALF, "mixed-lattice composition matches the reference at every texel (max %s)" % [errors])

	# 4. Clamping to the packed ranges.
	var hot := layer("Hot")
	fill(hot, &"terrain_tint_r", 4.0, Vector2i(-5, -3), Vector2i(-4, 3), func(_x, _z): return 3.5)
	fill(hot, &"terrain_ao", 4.0, Vector2i(-5, -3), Vector2i(-4, 3), func(_x, _z): return -0.75)
	await process_frame
	var clamped := StrataMacro.compose(terrain)
	check(clamped.ok and Array(clamped.report.clamped) == ["terrain_tint_r", "terrain_ao"], "out-of-range channels are clamped and reported: %s" % [clamped.get("report", {}).get("clamped")])
	check(clamped.ok and clamped.image.get_pixel(0, 0).r == 2.0 and clamped.image.get_pixel(0, 0).a == 0.0 and StrataMacro.validate_image(clamped.image, clamped.bounds).ok, "clamped values are 2 / 0 and validate")
	hot.free()
	await process_frame

	# 5. Packing order and the shader lattice contract.
	var plane := func(value: float) -> Image:
		var result := Image.create(3, 2, false, Image.FORMAT_RF); result.fill(Color(value, 0, 0, 1)); return result
	var packed := StrataMacro.pack(plane.call(0.25), plane.call(0.5), null, plane.call(0.75))
	check(packed.ok and packed.image.get_pixel(2, 1) == Color(0.25, 0.5, 1.0, 0.75), "pack keeps r,g,b,a order and fills a null plane neutral")
	var bounds := Rect2(-30.0, 10.0, 60.0, 20.0)
	var gradient := Image.create(4, 3, false, Image.FORMAT_RGBAH)
	for j in range(3):
		for i in range(4): gradient.set_pixel(i, j, Color(0.5 * i, 0.25 * j, 1.0, 1.0 - 0.25 * j))
	var binding := StrataMacro.binding(gradient, bounds)
	check(binding.ok, "binding of a valid map")
	if binding.ok:
		var uv_first: Vector2 = bounds.position * binding.uv_scale + binding.uv_offset
		var uv_last: Vector2 = bounds.end * binding.uv_scale + binding.uv_offset
		check(uv_first.is_equal_approx(Vector2(0.5 / 4.0, 0.5 / 3.0)) and uv_last.is_equal_approx(Vector2(3.5 / 4.0, 2.5 / 3.0)), "bounds endpoints map to the first/last texel centres: %s %s" % [uv_first, uv_last])
	near(StrataMacro.sample(gradient, bounds, Vector2(-10.0, 20.0)).r, 0.5, 0.00001, "texel centre sample")
	near(StrataMacro.sample(gradient, bounds, Vector2(0.0, 15.0)).r, 0.75, 0.00001, "bilinear midpoint x")
	near(StrataMacro.sample(gradient, bounds, Vector2(0.0, 15.0)).a, 0.875, 0.00001, "bilinear midpoint z")
	near(StrataMacro.sample(gradient, bounds, Vector2(1000.0, 1000.0)).r, 1.5, 0.00001, "outside clamps to the edge")

	# 6. Runtime validation of the macro layout and range, and the region lookup. A baked
	# map is checked against the shader lattice contract and the image reference.
	var rejected := 0
	var bad_rgbaf := gradient.duplicate(); bad_rgbaf.convert(Image.FORMAT_RGBAF)
	var bad_tint := gradient.duplicate(); bad_tint.set_pixel(1, 1, Color(2.5, 1, 1, 1))
	var bad_ao := gradient.duplicate(); bad_ao.set_pixel(1, 1, Color(1, 1, 1, 1.5))
	var bad_nan := gradient.duplicate(); bad_nan.set_pixel(3, 2, Color(1, NAN, 1, 1))
	var bad_negative := gradient.duplicate(); bad_negative.set_pixel(0, 0, Color(1, 1, -0.5, 1))
	var tiny := Image.create(1, 4, false, Image.FORMAT_RGBAH)
	var mipmapped := gradient.duplicate(); mipmapped.generate_mipmaps()
	for case in [[bad_rgbaf, bounds, false], [bad_tint, bounds, true], [bad_ao, bounds, true], [bad_nan, bounds, true], [bad_negative, bounds, true], [tiny, bounds, false], [mipmapped, bounds, false], [gradient, Rect2(0, 0, 0, 5), false], [gradient, Rect2(INF, 0, 5, 5), false]]:
		var layout := StrataRuntimeData.validate_macro_layout(case[0], case[1])
		var scanned := StrataRuntimeData.scan_macro_image(case[0]) if layout.ok else {"ok": true}
		if not layout.ok or not scanned.ok: rejected += 1
	check(rejected == 9, "nine invalid maps/bounds are rejected by layout or range checks (%d)" % rejected)
	check(StrataRuntimeData.validate_macro_layout(gradient, bounds).ok and StrataRuntimeData.scan_macro_image(gradient).ok, "the gradient map is valid")

	# 7. Persistence: binary and text resources keep exact bounds and every macro byte.
	var baked_macro := StrataBake.compile(terrain, {"spacing": 4.0, "region_cells": 16})
	var data: StrataRuntimeData = baked_macro.data
	var settings := StrataRenderSettings.new(); settings.terrain_tint_strength = 0.35; data.render_settings = settings
	var macro_before := data.get_macro_image()
	check(baked_macro.ok and data.validate().ok and data.grid == Vector2i(1, 1) and data.maps.macro.scale == 1 and data.maps.macro.apron == 1 and data.get_macro_bounds() == terrain.base_bounds, "macro bake at the lattice spacing is a scale-1 map: %s" % baked_macro.get("message", ""))
	var sampled := data.sample_macro(terrain.base_bounds.position + Vector2(12.0, 8.0))
	var reference_color := StrataMacro.sample(macro_before, data.get_macro_bounds(), terrain.base_bounds.position + Vector2(12.0, 8.0))
	check(sampled.status == StrataRuntimeData.Status.OK and sampled.tint.is_equal_approx(Color(reference_color.r, reference_color.g, reference_color.b, 1.0)) and is_equal_approx(sampled.ao, reference_color.a), "runtime sample_macro matches the image reference lookup")
	check(data.sample_macro(Vector2(-31.0, 20.0)).status == StrataRuntimeData.Status.OUTSIDE and data.sample_macro(Vector2(-31.0, 20.0)).tint == Color(1, 1, 1, 1), "outside macro bounds is OUTSIDE and neutral")
	var macro_binding := data.get_macro_binding()
	check(macro_binding.ok and macro_binding.resolution == Vector2i(11, 7), "the assembled macro map binds to the shader lattice contract")
	for path in ["user://macro_data.res", "user://macro_data.tres"]:
		check(ResourceSaver.save(data, path) == OK, "save %s" % path)
		var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as StrataRuntimeData
		check(loaded != null and loaded.validate().ok, "%s reloads and validates" % path)
		if loaded != null:
			check(loaded.has_macro() and loaded.get_macro_image().get_format() == Image.FORMAT_RGBAH and loaded.get_macro_image().get_data() == macro_before.get_data(), "%s macro bytes roundtrip exactly" % path)
			check(loaded.get_macro_bounds() == data.get_macro_bounds() and loaded.render_settings != null and is_equal_approx(loaded.render_settings.terrain_tint_strength, 0.35), "%s bounds and render settings roundtrip" % path)
	var odd := StrataRuntimeData.new()
	odd.bounds = Rect2(-2048.1, 1234.567891, 4096.3, 0.1)
	odd.spacing = 0.123456789
	odd.height_min = -3.0000001
	odd.height_max = 7.7777777
	check(ResourceSaver.save(odd, "user://macro_odd.tres") == OK, "save odd manifest")
	var odd_loaded := ResourceLoader.load("user://macro_odd.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as StrataRuntimeData
	check(odd_loaded != null and odd_loaded.bounds == odd.bounds and odd_loaded.spacing == odd.spacing and odd_loaded.height_min == odd.height_min and odd_loaded.height_max == odd.height_max, "bounds, spacing and extrema roundtrip bit-exactly through text: %s" % [odd_loaded.bounds if odd_loaded else null])
	var plain_data: StrataRuntimeData = StrataBake.compile(terrain, {"spacing": 4.0, "macro": false}).data
	check(not plain_data.has_macro() and plain_data.sample_macro(Vector2.ZERO).status == StrataRuntimeData.Status.ABSENT and plain_data.get_macro_image() == null and not plain_data.get_macro_binding().ok, "a bake without macro has no map, samples neutral and has no binding")

	# 8. Bake wiring: auto macro, report, settings snapshot, stale tracking, token checks.
	terrain.render_settings.terrain_ao_strength = 0.6
	var baked := StrataBake.bake(terrain, {"spacing": 4.0})
	check(baked.ok and baked.data.has_macro() and baked.data.get_macro_bounds() == terrain.base_bounds and baked.data.get_macro_image().get_size() == Vector2i(11, 7), "auto bake composes the 4 m macro map: %s" % baked.get("message", ""))
	check(baked.ok and baked.report.macro != null and Array(baked.report.macro.owned_channels).size() == 4, "bake report lists the macro channels")
	if baked.ok:
		var reference_map := StrataMacro.compose(terrain)
		check(baked.data.get_macro_image().get_data() == reference_map.image.get_data(), "baked map equals compose()")
		check(baked.data.render_settings != terrain.render_settings and is_equal_approx(baked.data.render_settings.terrain_ao_strength, 0.6), "bake stores a duplicate of the render settings")
		terrain.render_settings.terrain_ao_strength = 0.1
		check(is_equal_approx(baked.data.render_settings.terrain_ao_strength, 0.6), "later authoring settings edits do not mutate the baked artifact")
	var fixed := StrataBake.compile(terrain, {"spacing": 4.0, "macro": {"spacing": 8.0}})
	check(fixed.ok and fixed.data.get_macro_image().get_size() == Vector2i(6, 4) and fixed.data.maps.macro.scale == 2, "macro compose options select the spacing (a power-of-two multiple of the bake spacing)")
	check(not StrataBake.compile(terrain, {"spacing": 4.0, "macro": {"spacing": 6.0}}).ok, "a macro spacing that is not a power-of-two multiple is rejected")
	var off := StrataBake.compile(terrain, {"spacing": 4.0, "macro": false})
	check(off.ok and not off.data.has_macro(), "macro=false bakes without a map")
	var precompiled := StrataMacro.compose(terrain, {"through_layer": shade})
	check(not StrataBake.compile(terrain, {"spacing": 4.0, "macro": precompiled}).ok, "a compose result is not accepted: the macro map composes per region")
	fine.data.set_sample(&"terrain_ao", Vector2i(0, 0), 0.9)
	check(terrain.is_runtime_bake_stale(), "editing a macro channel stales the published bake")
	var retained := StrataBake.compile(terrain, {"spacing": 4.0, "channels": ["terrain_ao"], "macro": false})
	if retained.ok:
		var corner_expected := reference(&"terrain_ao", terrain.base_bounds.end)
		var corner: Dictionary = retained.data.sample_channel(&"terrain_ao", terrain.base_bounds.end)
		check(corner.ok and corner.coverage == 1.0, "the neutral base covers the retained macro channel completely")
		near(corner.value, corner_expected, 0.00001, "a retained terrain_ao channel uses the neutral base")
	else: check(false, "retained macro channel bake: %s" % retained.message)
	check(not StrataMacro.compose(terrain, {"spacing": 0.005}).ok and not StrataMacro.compose(terrain, {"bounds": Rect2(-30, 0, 10, 10)}).ok, "oversized and out-of-terrain macro requests are rejected")

	# 9. Snapshot spacing: a coarse cumulative lattice through a fine layer.
	var coarse := StrataProcedural.create_snapshot(fine, "cumulative", {"channels": ["height"], "spacing": 4.0})
	var compiled := StrataProcedural.compile_heightfield(terrain, fine, 4.0)
	check(coarse.ok and coarse.fields[0].image.get_size() == Vector2i(11, 7) and coarse.fields[0].sample_origin == Vector3(-20, 0, -12) and coarse.fields[0].image.get_data() == compiled.image.get_data(), "spacing snapshot equals compile_heightfield on the same lattice")
	check(not StrataProcedural.create_snapshot(fine, "raw", {"spacing": 4.0}).ok, "spacing is rejected for raw snapshots")

	# 10. Export: the runtime scene carries the macro map.
	var rebaked := StrataBake.bake(terrain, {"spacing": 4.0})
	var saved := StrataBake.save_runtime_scene(terrain, "res://export/macro_level.scn", {"data_path": "res://export/macro_data.res", "share_data": true}) if rebaked.ok else rebaked
	check(saved.ok, "runtime scene with macro saved: %s" % saved.get("message", ""))
	var scene := ResourceLoader.load("res://export/macro_level.scn", "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var instance := scene.instantiate() if scene != null else null
	var exported: StrataRuntimeData = instance.get_meta("strata_runtime_data") if instance != null else null
	check(exported != null and exported.has_macro() and exported.get_macro_image().get_data() == terrain.runtime_data.get_macro_image().get_data() and exported.get_macro_bounds() == terrain.base_bounds, "exported runtime scene includes the macro map")
	if instance != null: instance.free()
	var probe := {"bounds": [terrain.base_bounds.position.x, terrain.base_bounds.position.y, terrain.base_bounds.size.x, terrain.base_bounds.size.y], "samples": []}
	for p in [Vector2(-8, 0), Vector2(4, 4), Vector2(10, 0), Vector2(0, 0)]:
		var value := StrataMacro.sample(terrain.runtime_data.get_macro_image(), terrain.runtime_data.get_macro_bounds(), p)
		probe.samples.append([p.x, p.y, value.r, value.g, value.b, value.a])
	var probe_file := FileAccess.open("res://export/macro_probe.json", FileAccess.WRITE); probe_file.store_string(JSON.stringify(probe)); probe_file.close()
	finish("RUNTIME_MACRO_TEST")
