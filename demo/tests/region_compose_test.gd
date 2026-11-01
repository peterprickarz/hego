extends "res://tests/runtime_test_base.gd"
## Region composition (docs/development/strata_regions_plan.md, "Composition"): a region
## composed alone equals the matching window of a whole-terrain composition bit for bit, for
## height, material ids and weights, cell masks, macro tint, retained channels and navigation
## profiles; mips follow their filters; embedded and external regions behave identically.
## 64 m terrain, 16-cell regions (a 4 x 4 grid), apron 2.

const CELLS := 16
const APRON := 2

var terrain: StrataTerrain3D
var host: Node
var rough: StrataLayer
var fine: StrataLayer
var generated: StrataLayer
var upper: StrataLayer

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

func build_terrain() -> void:
	terrain = StrataTerrain3D.new()
	terrain.name = "Terrain"
	terrain.base_bounds = Rect2(-32.0, -32.0, 64.0, 64.0)
	terrain.editor_material_channels = PackedStringArray(["mat_a", "mat_b", "mat_c"])
	terrain.set_preview_enabled(false)
	root.add_child(terrain)
	rough = layer("Rough")
	rough.data.sample_spacing = 4.0
	rough.data.grid_origin = Vector2(-32.0, -32.0)
	for j in range(17):
		for i in range(17):
			rough.data.set_sample(&"height", Vector2i(i, j), 2.0 * sin(i * 0.5) - 1.5 + j * 0.3)
	# Material coverage on the same 4 m lattice: a_ over the west, b_ over the north, c_ a patch.
	for j in range(17):
		for i in range(17):
			rough.data.set_sample(&"mat_a", Vector2i(i, j), 1.0 if i < 9 else 0.0)
			rough.data.set_sample(&"mat_b", Vector2i(i, j), 0.6 if j < 6 else 0.0)
	generated = layer("Generated", true)
	var field := {"name": "height", "image": rf(Vector2i(33, 33), func(x: int, y: int) -> float: return 0.3 * cos(x * 0.4 + y * 0.2)), "ownership": rf(Vector2i(33, 33), func(x: int, _y: int) -> float: return 1.0 if x < 20 else 0.0), "sample_origin": Vector3(-32.0, 0.25, -32.0), "sample_step_x": Vector3(2, 0, 0), "sample_step_y": Vector3(0, 0, 2), "composition": "add"}
	var ticket := StrataProcedural.begin_transaction(host, "region-compose-test", [{"layer": generated, "channels": ["height"]}], [])
	check(ticket.ok and StrataProcedural.commit_fields(ticket, [{"layer_id": generated.layer_id, "fields": [field]}]).ok, "procedural height field commits")
	fine = layer("Fine")
	fine.data.sample_spacing = 0.5
	fine.set_composition(&"height", StrataLayer.Composition.ADD)
	for j in range(-10, 11):
		for i in range(-10, 11):
			fine.data.set_sample(&"height", Vector2i(i, j), 0.4 - 0.01 * (i * i + j * j))
	for j in range(-4, 40):
		for i in range(-30, 30):
			fine.data.set_sample(&"mat_c", Vector2i(i, j), 0.5 if (i + j) % 3 == 0 else 0.0)
	# A signed generic channel with partial coverage across region borders.
	for j in range(-12, 13):
		for i in range(-12, 13):
			fine.data.set_sample(&"mask", Vector2i(i * 2, j * 2), 0.25 * i - 1.0)
	# Holes and navigation exclusions that straddle the region borders at x = 0 and z = 0.
	for j in range(-6, 4):
		for i in range(-6, 3):
			fine.data.set_sample(&"hole", Vector2i(i, j), 1.0)
	for j in range(14, 22):
		for i in range(-3, 6):
			fine.data.set_sample(&"nav_exclusion", Vector2i(i, j), 1.0)
	upper = layer("Upper")
	for j in range(-2, 2):
		for i in range(-3, 0):
			upper.data.set_sample(&"hole", Vector2i(i, j), 0.0)
	# Macro: AO over a 2 m lattice (Replace), tint r added on 4 m.
	var shade := layer("Shade")
	shade.data.sample_spacing = 2.0
	for j in range(-16, 17):
		for i in range(-16, 5):
			shade.data.set_sample(&"terrain_ao", Vector2i(i, j), 0.5 + 0.01 * i)
			shade.data.set_sample(&"terrain_tint_r", Vector2i(i, j), 1.2)

func spec_with_everything() -> Dictionary:
	var spec := StrataRegions.standard_spec(terrain.base_bounds, 1.0, CELLS, APRON)
	spec.maps[StrataRegions.MAP_NAV_EXCLUSION] = StrataRegions.map(Image.FORMAT_L8, StrataRegions.KIND_CELL, 1, APRON)
	spec.maps["mask"] = StrataRegions.map(Image.FORMAT_RF, StrataRegions.KIND_SAMPLE, 1, APRON)
	spec.maps["mask" + StrataRegions.COVERAGE_SUFFIX] = StrataRegions.map(Image.FORMAT_RF, StrataRegions.KIND_SAMPLE, 1, APRON)
	spec.maps["nav_wet"] = StrataRegions.map(Image.FORMAT_L8, StrataRegions.KIND_CELL, 1, APRON)
	spec.maps["nav_flat"] = StrataRegions.map(Image.FORMAT_L8, StrataRegions.KIND_CELL, 1, APRON)
	return spec

func region_options() -> Dictionary:
	return {"channels": PackedStringArray(["mask"]), "nav_profiles": [{"name": &"wet", "rule": {"channel": "mask", "min": 0.5}}, {"name": &"flat", "rule": {"all": [{"slope_max": 12.0}, {"exclusion": true}]}}]}

## Reference quantization of weights the way compose_region promises: round(w * 255), largest
## slot absorbs the remainder, unassigned stay 0.
func quantize(weights: PackedFloat32Array, texel: int) -> PackedByteArray:
	var out := PackedByteArray([0, 0, 0, 0])
	var total := 0.0
	for slot in range(4): total += weights[texel * 4 + slot]
	if total <= 0.0: return out
	var sum := 0
	var largest := 0
	for slot in range(4):
		out[slot] = clampi(roundi(weights[texel * 4 + slot] / total * 255.0), 0, 255)
		sum += out[slot]
		if out[slot] > out[largest]: largest = slot
	out[largest] = clampi(out[largest] + 255 - sum, 0, 255)
	return out

## Reference for one material mip step: the up to four heaviest ids over the 2 x 2 block
## starting at the centre texel, ties to the lower id, weights renormalised to 255.
func reference_materials(ids: PackedByteArray, weights: PackedByteArray, source_size: Vector2i, target_size: Vector2i, apron: int) -> Dictionary:
	var out_ids := PackedByteArray(); out_ids.resize(target_size.x * target_size.y * 4)
	var out_weights := PackedByteArray(); out_weights.resize(target_size.x * target_size.y * 4)
	for v in range(target_size.y):
		for u in range(target_size.x):
			var sums := {}
			for dy in range(2):
				var y := clampi(2 * v - apron, 0, source_size.y - 1) + dy
				if y >= source_size.y: continue
				for dx in range(2):
					var x := clampi(2 * u - apron, 0, source_size.x - 1) + dx
					if x >= source_size.x: continue
					var base := (y * source_size.x + x) * 4
					for slot in range(4):
						var weight := weights[base + slot]
						if weight > 0: sums[ids[base + slot]] = int(sums.get(ids[base + slot], 0)) + weight
			if sums.is_empty(): continue
			var ranked: Array = sums.keys()
			ranked.sort_custom(func(a: int, b: int) -> bool: return sums[a] > sums[b] or sums[a] == sums[b] and a < b)
			var total := 0
			for slot in range(mini(4, ranked.size())): total += int(sums[ranked[slot]])
			var assigned := 0
			var target := (v * target_size.x + u) * 4
			for slot in range(mini(4, ranked.size())):
				var weight := int(roundf(float(sums[ranked[slot]]) * 255.0 / float(total)))
				out_ids[target + slot] = ranked[slot]
				out_weights[target + slot] = weight
				assigned += weight
			out_weights[target] = clampi(int(out_weights[target]) + 255 - assigned, 0, 255)
	return {"ids": out_ids, "weights": out_weights}

func run() -> void:
	host = Node.new(); host.name = "Producer"; root.add_child(host)
	build_terrain()
	await process_frame
	var spec := spec_with_everything()
	check(StrataRegions.validate_spec(spec).ok and StrataRegions.grid_size(spec) == Vector2i(4, 4), "the 64 m spec is a 4 x 4 grid: %s" % StrataRegions.validate_spec(spec))

	# Whole-terrain references over the grid plus one apron of lattice: 69 x 69 samples from -34 m.
	var extended := Rect2(-34.0, -34.0, 68.0, 68.0)
	var whole_height := StrataProcedural.compile_heightfield(terrain, null, 1.0, {"bounds": extended})
	var plain_height := StrataProcedural.compile_heightfield(terrain, null, 1.0)
	var whole_masks := StrataProcedural.compile_cell_masks(terrain, null, 1.0, {"bounds": extended})
	check(whole_height.ok and whole_masks.ok and plain_height.ok, "whole-terrain references compose: %s %s" % [whole_height.get("message"), whole_masks.get("message")])
	var whole_height_floats: PackedFloat32Array = (whole_height.image as Image).get_data().to_float32_array()
	var material_channels := terrain.editor_material_channels
	var reference_controls := StrataMaterialControls.compose(terrain, material_channels, null, 1.0)
	check(reference_controls.ok and reference_controls.ids.get_size() == Vector2i(65, 65), "reference material controls compose on the 1 m lattice")
	var reference_ids: PackedByteArray = reference_controls.ids.get_data()
	var reference_weights: PackedFloat32Array = reference_controls.weights.get_data().to_float32_array()
	var macro_reference := StrataMacro.compose(terrain, {"spacing": 4.0})
	var macro_floats: PackedByteArray = (macro_reference.image as Image).get_data()
	# Retained channel reference: the descriptor contract of the bake, one 69 x 69 window.
	var descriptors: Array = []
	for entry in terrain.get_layers():
		if entry.enabled:
			var storage := entry.get_channel_data(&"mask")
			descriptors.append({"data": storage, "origin": Vector3(storage.grid_origin.x, 0.0, storage.grid_origin.y), "step_x": Vector3(storage.sample_spacing, 0.0, 0.0), "step_y": Vector3(0.0, 0.0, storage.sample_spacing), "mode": entry.get_composition(&"mask"), "height_offset": 0.0})
	var mask_reference: Dictionary = StrataLayerData.compose_dense(descriptors, &"mask", Vector3(-34, 0, -34), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector2i(69, 69), terrain.base_bounds, true, 0.0)
	var mask_values: PackedFloat32Array = (mask_reference.image as Image).get_data().to_float32_array()
	var mask_coverage: PackedFloat32Array = (mask_reference.coverage as Image).get_data().to_float32_array()

	var options := region_options()
	var regions := {}
	var mismatches := {"height": 0, "ids": 0, "weights": 0, "holes": 0, "nav_exclusion": 0, "macro": 0, "mask": 0, "coverage": 0}
	var compared := {"height": 0, "ids": 0, "weights": 0, "holes": 0, "nav_exclusion": 0, "macro": 0, "mask": 0, "coverage": 0}
	for y in range(4):
		for x in range(4):
			var xy := Vector2i(x, y)
			var composed := StrataRegions.compose_region(terrain, null, xy, spec, options)
			check(composed.ok and composed.region is StrataRegionData, "region %s composes: %s" % [xy, composed.get("message")])
			if not composed.ok: finish("REGION_COMPOSE_TEST"); return
			var region: StrataRegionData = composed.region
			regions[xy] = region
			check(region.validate().ok and region.region == xy and region.origin == StrataRegions.region_origin(spec, xy), "region %s is a valid region resource" % xy)
			# Height, apron included, against the extended whole composition.
			var height_window := StrataRegions.map_window(spec, xy, spec.maps.height)
			var heights := region.level_bytes("height").to_float32_array()
			var hsize: Vector2i = height_window.size
			var hfirst: Vector2i = height_window.first
			for v in range(hsize.y):
				for u in range(hsize.x):
					var g: Vector2i = hfirst + Vector2i(u, v) + Vector2i(2, 2)
					compared.height += 1
					if heights[v * hsize.x + u] != whole_height_floats[g.y * 69 + g.x]: mismatches.height += 1
			# Masks, apron included.
			for name in ["holes", "nav_exclusion"]:
				var window := StrataRegions.map_window(spec, xy, spec.maps[name])
				var wsize: Vector2i = window.size
				var wfirst: Vector2i = window.first
				var bytes := region.level_bytes(name)
				var whole: PackedByteArray = whole_masks.holes if name == "holes" else whole_masks.nav_exclusions
				for v in range(wsize.y):
					for u in range(wsize.x):
						var g: Vector2i = wfirst + Vector2i(u, v) + Vector2i(2, 2)
						compared[name] += 1
						if bytes[v * wsize.x + u] != whole[g.y * 68 + g.x]: mismatches[name] += 1
			# Materials: interior of the 65 x 65 reference lattice.
			var ids := region.level_bytes("material_ids")
			var weights := region.level_bytes("material_weights")
			for v in range(hsize.y):
				for u in range(hsize.x):
					var g: Vector2i = hfirst + Vector2i(u, v)
					if g.x < 0 or g.y < 0 or g.x > 64 or g.y > 64: continue
					var texel: int = v * hsize.x + u
					var reference_texel := g.y * 65 + g.x
					compared.ids += 1
					for slot in range(4):
						if ids[texel * 4 + slot] != reference_ids[reference_texel * 4 + slot] and weights[texel * 4 + slot] > 0: mismatches.ids += 1
					compared.weights += 1
					if weights.slice(texel * 4, texel * 4 + 4) != quantize(reference_weights, reference_texel): mismatches.weights += 1
			# Macro tint: interior of the 4 m lattice (17 x 17).
			var macro_window := StrataRegions.map_window(spec, xy, spec.maps.macro)
			var macro_bytes := region.level_bytes("macro")
			var msize: Vector2i = macro_window.size
			var mfirst: Vector2i = macro_window.first
			for v in range(msize.y):
				for u in range(msize.x):
					var g: Vector2i = mfirst + Vector2i(u, v)
					if g.x < 0 or g.y < 0 or g.x > 16 or g.y > 16: continue
					compared.macro += 1
					if macro_bytes.slice((v * msize.x + u) * 8, (v * msize.x + u) * 8 + 8) != macro_floats.slice((g.y * 17 + g.x) * 8, (g.y * 17 + g.x) * 8 + 8): mismatches.macro += 1
			# Retained channel and its coverage, apron included.
			var channel_values := region.level_bytes("mask").to_float32_array()
			var channel_coverage := region.level_bytes("mask" + StrataRegions.COVERAGE_SUFFIX).to_float32_array()
			for v in range(hsize.y):
				for u in range(hsize.x):
					var g: Vector2i = hfirst + Vector2i(u, v) + Vector2i(2, 2)
					compared.mask += 1
					if channel_values[v * hsize.x + u] != mask_values[g.y * 69 + g.x]: mismatches.mask += 1
					compared.coverage += 1
					if channel_coverage[v * hsize.x + u] != mask_coverage[g.y * 69 + g.x]: mismatches.coverage += 1
	for key in mismatches:
		check(compared[key] > 0 and mismatches[key] == 0, "a region equals the whole-terrain %s window bit for bit (%d of %d texels differ)" % [key, mismatches[key], compared[key]])
	var any_hole := false
	var any_nav := false
	var any_covered := false
	var any_material := false
	for xy in regions:
		any_hole = any_hole or regions[xy].level_bytes("holes").count(255) > 0
		any_nav = any_nav or regions[xy].level_bytes("nav_exclusion").count(255) > 0
		any_covered = any_covered or regions[xy].level_bytes("mask__coverage").to_float32_array().has(1.0)
		any_material = any_material or regions[xy].level_bytes("material_weights").count(0) < regions[xy].level_bytes("material_weights").size()
	check(any_hole and any_nav and any_covered and any_material, "the fixture exercises holes, exclusions, coverage and materials")
	# Weights of assigned texels sum to 255, unassigned stay 0.
	var sums_ok := true
	var unassigned := 0
	var weights0: PackedByteArray = regions[Vector2i(1, 1)].level_bytes("material_weights")
	for texel in range(weights0.size() / 4):
		var total: int = weights0[texel * 4] + weights0[texel * 4 + 1] + weights0[texel * 4 + 2] + weights0[texel * 4 + 3]
		sums_ok = sums_ok and (total == 255 or total == 0)
		unassigned += 1 if total == 0 else 0
	check(sums_ok, "assigned material texels sum to 255 and unassigned ones are 0 (%d unassigned)" % unassigned)

	# Extrema come from the region's own samples; shared edges agree between neighbours.
	var extrema_ok := true
	for xy in regions:
		var region: StrataRegionData = regions[xy]
		var lo := INF; var hi := -INF
		for v in range(CELLS + 1):
			for u in range(CELLS + 1):
				var value := region.level_bytes("height").decode_float(((v + APRON) * (CELLS + 1 + 2 * APRON) + u + APRON) * 4)
				lo = minf(lo, value); hi = maxf(hi, value)
		extrema_ok = extrema_ok and region.height_min == lo and region.height_max == hi
	check(extrema_ok, "height_min/max are the extrema of the region's own samples (apron excluded)")
	var edge_ok := true
	for v in range(CELLS + 1):
		var left: float = regions[Vector2i(1, 2)].level_bytes("height").decode_float(((v + APRON) * (CELLS + 1 + 2 * APRON) + CELLS + APRON) * 4)
		var right: float = regions[Vector2i(2, 2)].level_bytes("height").decode_float(((v + APRON) * (CELLS + 1 + 2 * APRON) + APRON) * 4)
		edge_ok = edge_ok and left == right
	check(edge_ok, "neighbouring regions agree on their shared edge samples")

	# A cutoff composes only the layers through it.
	var through := StrataRegions.compose_region(terrain, rough, Vector2i(2, 1), spec, {"channels": PackedStringArray(["mask"])})
	var through_height := StrataProcedural.compile_heightfield(terrain, rough, 1.0, {"bounds": extended})
	var cutoff_ok: bool = through.ok
	if through.ok:
		var cutoff_floats: PackedFloat32Array = (through_height.image as Image).get_data().to_float32_array()
		var window := StrataRegions.map_window(spec, Vector2i(2, 1), spec.maps.height)
		var wsize: Vector2i = window.size
		var wfirst: Vector2i = window.first
		var composed_floats: PackedFloat32Array = through.region.level_bytes("height").to_float32_array()
		for v in range(wsize.y):
			for u in range(wsize.x):
				var g: Vector2i = wfirst + Vector2i(u, v) + Vector2i(2, 2)
				cutoff_ok = cutoff_ok and composed_floats[v * wsize.x + u] == cutoff_floats[g.y * 69 + g.x]
		check(through.region.level_bytes("holes").count(255) == 0 and through.region.level_bytes("material_weights") != regions[Vector2i(2, 1)].level_bytes("material_weights"), "a cutoff omits the upper layers' holes and materials")
	check(cutoff_ok, "composing through a cutoff layer equals the editor's cutoff composition")

	# Sources override whole-lattice inputs; a missing channel request is an error.
	var sliced := StrataRegions.compose_region(terrain, null, Vector2i(1, 1), spec, {"channels": PackedStringArray(["mask"]), "sources": {"height": plain_height.image, "holes": whole_masks.holes.slice(0, 0)}})
	check(sliced.ok, "a precompiled height lattice is sliced: %s" % sliced.get("message"))
	if sliced.ok:
		var window := StrataRegions.map_window(spec, Vector2i(1, 1), spec.maps.height)
		var wsize: Vector2i = window.size
		var wfirst: Vector2i = window.first
		var plain_floats: PackedFloat32Array = (plain_height.image as Image).get_data().to_float32_array()
		var sliced_floats: PackedFloat32Array = sliced.region.level_bytes("height").to_float32_array()
		var slice_ok := true
		for v in range(wsize.y):
			for u in range(wsize.x):
				var g: Vector2i = wfirst + Vector2i(u, v)
				slice_ok = slice_ok and sliced_floats[v * wsize.x + u] == plain_floats[g.y * 65 + g.x]
		check(slice_ok, "sliced heights equal the lattice texels")
	check(not StrataRegions.compose_region(terrain, null, Vector2i(0, 0), spec, {}).ok, "a channel map the options do not request is an error")
	check(not StrataRegions.compose_region(terrain, null, Vector2i(4, 0), spec, region_options()).ok, "a region outside the grid is an error")

	# Navigation profiles: re-evaluating the stored rule reproduces the stored mask, and the
	# wet profile is the cell-mean threshold of the region's own channel map.
	var profiles_ok := true
	var walkable := 0
	for xy in regions:
		var region: StrataRegionData = regions[xy]
		for entry in options.nav_profiles:
			var name := String(entry.name)
			var stored := region.level_bytes("nav_" + name)
			profiles_ok = profiles_ok and stored.size() == (CELLS + 2 * APRON) * (CELLS + 2 * APRON) and StrataNavProfiles.evaluate_region(region, entry.rule, PackedStringArray(["mask"])) == stored
			walkable += stored.count(0)
		var side := CELLS + 1 + 2 * APRON
		var values := region.level_bytes("mask").to_float32_array()
		var expected := PackedByteArray()
		for z in range(side - 1):
			for xx in range(side - 1):
				var i := z * side + xx
				var mean := (float(values[i]) + values[i + 1] + values[i + side] + values[i + side + 1]) * 0.25
				expected.append(0 if mean >= 0.5 else 255)
		profiles_ok = profiles_ok and region.level_bytes("nav_wet") == expected
	check(profiles_ok and walkable > 0, "per-region navigation masks match the cell-mean reference and re-evaluate (%d walkable cells)" % walkable)
	var flat_blocked_by_exclusion := 0
	var flat: PackedByteArray = regions[Vector2i(1, 2)].level_bytes("nav_flat")
	var exclusion: PackedByteArray = regions[Vector2i(1, 2)].level_bytes("nav_exclusion")
	for index in range(flat.size()):
		if exclusion[index] == 255 and flat[index] == 255: flat_blocked_by_exclusion += 1
	check(exclusion.count(255) > 0 and flat_blocked_by_exclusion == exclusion.count(255), "the exclusion term blocks every excluded cell of the flat profile")
	# A profile whose map the spec lacks, or a channel it cannot read, fails clearly.
	var no_map := StrataRegions.compose_region(terrain, null, Vector2i(0, 0), spec, {"channels": PackedStringArray(["mask"]), "nav_profiles": [{"name": &"missing", "rule": {"exclusion": true}}]})
	check(not no_map.ok, "a profile without a spec map is rejected: %s" % no_map.get("message"))

	# Mips: level counts, the [1 2 1] filter, cell maxima and material renormalisation.
	var mipped: StrataRegionData = StrataRuntimeData.clone_region(regions[Vector2i(1, 2)])
	StrataRegions.build_mips(mipped, 3)
	check(mipped.validate().ok, "mipped region validates: %s" % mipped.validate())
	check(mipped.level_count("height") == 3 and mipped.level_count("holes") == 3 and mipped.level_count("macro") == 3 and mipped.level_count("nav_wet") == 3, "every map gets three levels")
	var level0 := mipped.level_bytes("mask", 0).to_float32_array()
	var level1 := mipped.level_bytes("mask", 1).to_float32_array()
	var side0 := CELLS + 1 + 2 * APRON
	var side1 := CELLS / 2 + 1 + 2 * APRON
	var filter_ok := side1 * side1 == level1.size()
	for probe in [Vector2i(2, 2), Vector2i(4, 5), Vector2i(7, 7), Vector2i(0, 0), Vector2i(10, 9)]:
		var centre: Vector2i = probe * 2 - Vector2i(APRON, APRON)
		var tap := func(dx: int, dy: int) -> float:
			return level0[clampi(centre.y + dy, 0, side0 - 1) * side0 + clampi(centre.x + dx, 0, side0 - 1)]
		var horizontal := func(dy: int) -> float: return (tap.call(-1, dy) + 2.0 * tap.call(0, dy) + tap.call(1, dy)) * 0.25
		var expected_value: float = (horizontal.call(-1) + 2.0 * horizontal.call(0) + horizontal.call(1)) * 0.25
		filter_ok = filter_ok and absf(level1[probe.y * side1 + probe.x] - expected_value) <= 1.0e-5
	check(filter_ok, "scalar channel level 1 is the [1 2 1] / 4 filter at the coarse texel's own position")
	var holes0 := mipped.level_bytes("holes", 0)
	var holes1 := mipped.level_bytes("holes", 1)
	var holes_side0 := CELLS + 2 * APRON
	var holes_side1 := CELLS / 2 + 2 * APRON
	var any_ok := holes1.size() == holes_side1 * holes_side1
	for v in range(holes_side1):
		for u in range(holes_side1):
			var covered := false
			for dy in range(2):
				for dx in range(2):
					var sx := 2 * u - APRON + dx
					var sy := 2 * v - APRON + dy
					if sx >= 0 and sy >= 0 and sx < holes_side0 and sy < holes_side0 and holes0[sy * holes_side0 + sx] == 255: covered = true
			any_ok = any_ok and holes1[v * holes_side1 + u] == (255 if covered else 0)
	check(any_ok, "a coarse cell is set when any of the cells it covers is set")
	var ids1 := mipped.level_bytes("material_ids", 1)
	var weights1 := mipped.level_bytes("material_weights", 1)
	var renormalised := true
	for texel in range(weights1.size() / 4):
		var total := weights1[texel * 4] + weights1[texel * 4 + 1] + weights1[texel * 4 + 2] + weights1[texel * 4 + 3]
		renormalised = renormalised and (total == 255 or total == 0)
	check(renormalised and ids1.size() == weights1.size(), "material level 1 weights are renormalised to 255 from the chosen ids")
	var macro0 := mipped.level_bytes("macro", 0)
	check(mipped.level_bytes("macro", 1).size() == StrataRegions.map_bytes(CELLS, spec.maps.macro, 1) and macro0.size() == StrataRegions.map_bytes(CELLS, spec.maps.macro, 0), "macro levels have the sizes the geometry demands")
	var level_zero_kept: bool = mipped.level_bytes("height", 0) == regions[Vector2i(1, 2)].level_bytes("height", 0) and mipped.level_bytes("material_ids", 0) == regions[Vector2i(1, 2)].level_bytes("material_ids", 0)
	check(level_zero_kept, "mips never change level 0")
	check(StrataRegions.region_bytes(spec, 3) > StrataRegions.region_bytes(spec, 1), "planned region bytes count the mips")

	# Height mips are decimated: level l texel u is level-0 texel ((u - apron) << l) + apron (edges
	# clamped), the sample at the same lattice point.
	var decimated_ok := true
	var decimated_problem := ""
	var height0 := mipped.level_bytes("height", 0).to_float32_array()
	for level in range(1, 3):
		var level_values := mipped.level_bytes("height", level).to_float32_array()
		var level_side := (CELLS >> level) + 1 + 2 * APRON
		decimated_ok = decimated_ok and level_values.size() == level_side * level_side
		for v in range(level_side):
			for u in range(level_side):
				var x := clampi(((u - APRON) << level) + APRON, 0, side0 - 1)
				var y := clampi(((v - APRON) << level) + APRON, 0, side0 - 1)
				if decimated_ok and level_values[v * level_side + u] != height0[y * side0 + x]:
					decimated_ok = false
					decimated_problem = "level %d texel %s" % [level, Vector2i(u, v)]
	check(decimated_ok, "height level l texel u is the level-0 sample at lattice index (u - apron) << l: " + decimated_problem)
	var extrema_kept: bool = mipped.height_min == regions[Vector2i(1, 2)].height_min and mipped.height_max == regions[Vector2i(1, 2)].height_max
	check(extrema_kept, "mips leave the region's height extrema alone")
	# The native mip helpers equal the script implementations (and the old material reference).
	var parity_ok := true
	for planes in [1, 4]:
		for case in [[0, false], [1, false], [2, false]]:
			var source_size := Vector2i(21, 21)
			var source := PackedFloat32Array()
			for index in range(source_size.x * source_size.y * planes): source.append(float((index * 7919) % 101) * 0.37 - 3.0)
			var target_size := Vector2i(13, 13)
			var native: PackedFloat32Array = StrataLayerData.downsample_samples(source, planes, source_size, target_size, APRON, case[0])
			var script := StrataRegions._downsample_script(source, planes, case[0] == 1, case[0] == 2, source_size, target_size, APRON)
			parity_ok = parity_ok and native == script and native.size() == script.size() and not native.is_empty()
	check(parity_ok, "native downsample_samples equals the script implementation for tent, cell and decimation modes")
	var material_ids := PackedByteArray()
	var material_weights := PackedByteArray()
	var material_size := Vector2i(11, 11)
	for texel in range(material_size.x * material_size.y):
		var picks := [(texel * 3) % 7, (texel * 5 + 1) % 7, (texel * 2 + 3) % 5, (texel + 4) % 7]
		for slot in range(4):
			material_ids.append(picks[slot])
			material_weights.append(0 if (texel + slot) % 5 == 0 else 20 + ((texel * 13 + slot * 29) % 80))
	var material_target := Vector2i(8, 8)
	var native_materials: Dictionary = StrataLayerData.downsample_materials(material_ids, material_weights, material_size, material_target, APRON)
	var reference := reference_materials(material_ids, material_weights, material_size, material_target, APRON)
	check(native_materials.ok and native_materials.ids == reference.ids and native_materials.weights == reference.weights, "native downsample_materials equals the reference ranking and renormalisation")

	# compose_map at a level: heights decimate the level-0 composition exactly.
	var full_height_window := {"first": Vector2i.ZERO, "size": StrataRegions.terrain_samples(spec), "origin": terrain.base_bounds.position, "step": 1.0, "level": 0}
	var full_height := StrataRegionCompose.compose_map(terrain, null, "height", full_height_window, spec)
	check(full_height.ok and (full_height.image as Image).get_size() == Vector2i(65, 65), "the whole 65 x 65 height lattice composes")
	var full_floats: PackedFloat32Array = (full_height.image as Image).get_data().to_float32_array()
	for level in range(1, 3):
		var coarse_window := StrataRegions.coarse_window(spec, spec.maps.height, level)
		var coarse := StrataRegionCompose.compose_map(terrain, null, "height", coarse_window, spec)
		check(coarse.ok and (coarse.image as Image).get_size() == StrataRegions.coarse_map_size(spec, spec.maps.height, level), "the coarse height window at level %d composes: %s" % [level, coarse.get("message")])
		if not coarse.ok: continue
		var coarse_floats: PackedFloat32Array = (coarse.image as Image).get_data().to_float32_array()
		var coarse_side: int = (coarse_window.size as Vector2i).x
		var equal := true
		for v in range(coarse_side):
			for u in range(coarse_side):
				equal = equal and coarse_floats[v * coarse_side + u] == full_floats[(v << level) * 65 + (u << level)]
		check(equal, "coarse height at level %d equals the decimated full composition" % level)
		# A region window at the level equals the decimated mip texels wherever the mip is not clamped.
		var level_window := StrataRegions.map_window(spec, Vector2i(1, 2), spec.maps.height, level)
		var composed_level := StrataRegionCompose.compose_map(terrain, null, "height", level_window, spec)
		var mip_values := mipped.level_bytes("height", level).to_float32_array()
		var level_floats: PackedFloat32Array = (composed_level.image as Image).get_data().to_float32_array()
		var level_side := (level_window.size as Vector2i).x
		var level_equal: bool = composed_level.ok and level_floats.size() == mip_values.size()
		for v in range(level_side):
			for u in range(level_side):
				var x0 := ((u - APRON) << level) + APRON
				var y0 := ((v - APRON) << level) + APRON
				if x0 < 0 or y0 < 0 or x0 >= side0 or y0 >= side0: continue
				level_equal = level_equal and level_floats[v * level_side + u] == mip_values[v * level_side + u]
		check(level_equal, "a region height window at level %d equals that level of the decimated mips" % level)
	# The other maps compose directly on the coarse lattice (a preview, not the mip downsample).
	var coarse_ok := true
	var coarse_problem := ""
	for name in ["material_ids", "material_weights", "holes", "nav_exclusion", "macro", "mask"]:
		var coarse_description: Dictionary = spec.maps[name]
		var coarse_window := StrataRegions.coarse_window(spec, coarse_description, 1)
		var composed_coarse := StrataRegionCompose.compose_map(terrain, null, name, coarse_window, spec)
		if not composed_coarse.ok or (composed_coarse.image as Image).get_size() != coarse_window.size or (composed_coarse.image as Image).get_format() != int(coarse_description.format):
			coarse_ok = false; coarse_problem = "%s: %s" % [name, composed_coarse.get("message")]; break
	check(coarse_ok, "every map composes over its coarse window: " + coarse_problem)
	var coarse_holes := StrataRegionCompose.compose_map(terrain, null, "holes", StrataRegions.coarse_window(spec, spec.maps.holes, 1), spec)
	check(coarse_holes.ok and (coarse_holes.image as Image).get_data().count(255) > 0, "the coarse hole mask keeps the painted holes")
	var bad_level := StrataRegions.coarse_window(spec, spec.maps.height, 1)
	bad_level.step = 3.0
	check(not StrataRegionCompose.compose_map(terrain, null, "height", bad_level, spec).ok, "a window whose step does not match its level is rejected")
	var too_deep := StrataRegions.coarse_window(spec, spec.maps.height, 1)
	too_deep.level = 9
	check(not StrataRegionCompose.compose_map(terrain, null, "height", too_deep, spec).ok, "a level past the map's deepest is rejected")
	check(not StrataRegionCompose.compose_map(terrain, null, "height", StrataRegions.coarse_window(spec, spec.maps.height, 1), spec, {"sources": {"height": Image.create(65, 65, false, Image.FORMAT_RF)}}).ok, "level-0 sources are rejected at a coarser level")

	# Parallel composition: every region of an 8 x 8 grid (8 m regions of 16 cells at 0.5 m)
	# composed concurrently equals the serial result byte for byte, three times over.
	var fine_spec := StrataRegions.standard_spec(terrain.base_bounds, 0.5, CELLS, APRON)
	for key in ["nav_exclusion", "mask", "mask__coverage", "nav_wet", "nav_flat"]:
		fine_spec.maps[key] = spec.maps[key]
	check(StrataRegions.validate_spec(fine_spec).ok and StrataRegions.grid_size(fine_spec) == Vector2i(8, 8), "the 0.5 m spec is an 8 x 8 grid")
	var all_regions: Array[Vector2i] = []
	for y in range(8):
		for x in range(8): all_regions.append(Vector2i(x, y))
	var serial := StrataRegions.compose_regions(terrain, null, fine_spec, all_regions, options.merged({"threads": false}))
	check(serial.ok and serial.regions.size() == 64, "serial compose_regions composes 64 regions: %s" % serial.get("message"))
	var identical_runs := 0
	for run_index in range(3):
		var parallel := StrataRegions.compose_regions(terrain, null, fine_spec, all_regions, options)
		var same: bool = parallel.ok and parallel.regions.size() == 64
		if same:
			for xy in all_regions:
				var a: StrataRegionData = serial.regions[xy]
				var b: StrataRegionData = parallel.regions[xy]
				same = same and a.map_names() == b.map_names() and a.height_min == b.height_min and a.height_max == b.height_max and a.origin == b.origin
				for name in a.map_names():
					same = same and a.level_bytes(name) == b.level_bytes(name)
		if same: identical_runs += 1
	check(identical_runs == 3, "concurrent compose of all 64 regions equals the serial result byte for byte, 3 of 3 runs (%d)" % identical_runs)
	var single := StrataRegions.compose_region(terrain, null, Vector2i(5, 2), fine_spec, options)
	check(single.ok and single.region.level_bytes("height") == serial.regions[Vector2i(5, 2)].level_bytes("height") and single.region.level_bytes("material_weights") == serial.regions[Vector2i(5, 2)].level_bytes("material_weights"), "compose_regions equals compose_region")
	var outside := StrataRegions.compose_regions(terrain, null, fine_spec, [Vector2i(0, 0), Vector2i(9, 9)] as Array[Vector2i], options)
	check(not outside.ok and String(outside.message).contains("outside"), "a region outside the grid fails the batch: %s" % outside.get("message"))
	# Mips built concurrently equal serial mips.
	var pool: Array = []
	var pool_reference: Array = []
	for xy in all_regions:
		pool.append(StrataRuntimeData.clone_region(serial.regions[xy]))
		pool_reference.append(StrataRuntimeData.clone_region(serial.regions[xy]))
	for region: StrataRegionData in pool_reference: StrataRegions.build_mips(region, 3)
	var mips_group := WorkerThreadPool.add_group_task(func(index: int) -> void: StrataRegions.build_mips(pool[index], 3), pool.size())
	WorkerThreadPool.wait_for_group_task_completion(mips_group)
	var mips_same := true
	for index in range(pool.size()):
		for name in pool[index].map_names():
			for level in range(pool[index].level_count(name)):
				mips_same = mips_same and pool[index].level_bytes(name, level) == pool_reference[index].level_bytes(name, level)
	check(mips_same, "mips built on worker threads equal serial mips")
	# An explicit capture works off the main thread.
	var captured := StrataRegionCompose.capture(terrain, null, fine_spec, options)
	var off_thread: Array = []
	var off_group := WorkerThreadPool.add_task(func() -> void: off_thread.append(StrataRegionCompose.compose(terrain, null, Vector2i(3, 3), fine_spec, options.merged({"capture": captured}))))
	WorkerThreadPool.wait_for_task_completion(off_group)
	check(captured.ok and off_thread.size() == 1 and off_thread[0].ok and off_thread[0].region.level_bytes("height") == serial.regions[Vector2i(3, 3)].level_bytes("height"), "a captured composition runs on a worker thread")

	# Embedded and external regions behave identically through the manifest.
	var baked := StrataBake.compile(terrain, {"region_cells": CELLS, "mip_levels": 2, "cell_masks": true, "channels": PackedStringArray(["mask"]), "nav_profiles": options.nav_profiles})
	check(baked.ok, "bake composes the grid: %s" % baked.get("message"))
	if baked.ok:
		var embedded: StrataRuntimeData = baked.data
		check(embedded.validate().ok and embedded.grid == Vector2i(4, 4) and embedded.regions.size() == 16, "embedded manifest validates: %s" % embedded.validate())
		var manifest := embedded.get_manifest()
		print("64 m terrain, 4 x 4 regions of 16 cells, apron 2, 2 levels: %d bytes per region, %d bytes total; per map: %s" % [manifest.region_bytes, manifest.total_bytes, manifest.map_bytes])
		var directory := "user://region_compose_test"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		var external := embedded.duplicate_runtime()
		for xy in embedded.regions:
			check(ResourceSaver.save(embedded.regions[xy], directory.path_join("region_%d_%d.res" % [xy.x, xy.y]), ResourceSaver.FLAG_COMPRESS) == OK, "region %s saves" % xy)
		external.regions = {}
		external.region_directory = directory
		ResourceSaver.save(external, directory.path_join("manifest.res"), ResourceSaver.FLAG_COMPRESS)
		print("on disk (compressed .res): region_1_1.res %d bytes, manifest %d bytes" % [FileAccess.get_file_as_bytes(directory.path_join("region_1_1.res")).size(), FileAccess.get_file_as_bytes(directory.path_join("manifest.res")).size()])
		var reloaded := ResourceLoader.load(directory.path_join("manifest.res"), "", ResourceLoader.CACHE_MODE_IGNORE) as StrataRuntimeData
		check(reloaded != null and reloaded.regions.is_empty() and reloaded.region_directory == directory and reloaded.validate(true).ok, "external manifest reloads and every region file loads")
		var identical := reloaded != null
		var probes := PackedVector2Array([Vector2(0.3, 0.6), Vector2(-15.5, 7.25), Vector2(15.99, -15.99), Vector2(31.9, 31.9), Vector2(-4.5, -1.5), Vector2(1.5, 17.5)])
		if identical:
			for point in probes:
				identical = identical and var_to_bytes(reloaded.sample_height(point)) == var_to_bytes(embedded.sample_height(point)) and var_to_bytes(reloaded.sample_channel(&"mask", point)) == var_to_bytes(embedded.sample_channel(&"mask", point)) and reloaded.is_hole_at(point) == embedded.is_hole_at(point)
			var full := Rect2i(Vector2i.ZERO, embedded.cells_resolution())
			identical = identical and reloaded.heights_window(full) == embedded.heights_window(full) and reloaded.cell_mask_window("holes", full) == embedded.cell_mask_window("holes", full) and reloaded.cell_mask_window("nav_wet", full) == embedded.cell_mask_window("nav_wet", full)
			for xy in embedded.regions:
				for name in embedded.regions[xy].map_names():
					for level in range(embedded.regions[xy].level_count(name)):
						identical = identical and reloaded.get_region(xy).level_bytes(name, level) == embedded.regions[xy].level_bytes(name, level)
		check(identical, "external regions give identical samples, windows and bytes")
		check(embedded.validate().ok and reloaded.get_region(Vector2i(9, 9)) == null, "a region outside the grid is null")
		check(embedded.get_region(Vector2i(2, 3)) == embedded.regions[Vector2i(2, 3)], "get_region returns the embedded resource")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(directory.path_join("manifest.res")))
		for xy in embedded.regions: DirAccess.remove_absolute(ProjectSettings.globalize_path(directory.path_join("region_%d_%d.res" % [xy.x, xy.y])))
	# compose_map: any sub-window equals the matching texels of the region's composed map.
	var map_ok := true
	var map_problem := ""
	var probe_xy := Vector2i(1, 2)
	var probe: StrataRegionData = regions[probe_xy]
	for name in ["height", "material_ids", "material_weights", "holes", "nav_exclusion", "macro", "mask", "mask__coverage"]:
		var base_name: String = name.trim_suffix(StrataRegions.COVERAGE_SUFFIX)
		var description: Dictionary = spec.maps[base_name]
		var full_window := StrataRegions.map_window(spec, probe_xy, description)
		var full: Dictionary = StrataRegionCompose.compose_map(terrain, null, base_name, full_window, spec)
		var size: Vector2i = full_window.size
		var rect := Rect2i(Vector2i(3, 2), Vector2i(mini(5, size.x - 3), mini(5, size.y - 2)))
		var sub_window: Dictionary = full_window.duplicate()
		sub_window.first = (full_window.first as Vector2i) + rect.position
		sub_window.size = rect.size
		sub_window.origin = (full_window.origin as Vector2) + Vector2(rect.position) * float(full_window.step)
		var sub: Dictionary = StrataRegionCompose.compose_map(terrain, null, base_name, sub_window, spec)
		if not full.ok or not sub.ok:
			map_ok = false; map_problem = "%s: %s %s" % [name, full.get("message"), sub.get("message")]; break
		var key := "coverage" if name.ends_with(StrataRegions.COVERAGE_SUFFIX) else ("ids" if name == "material_ids" else ("weights" if name == "material_weights" else "image"))
		var whole_image: Image = full[key]
		var sub_image: Image = sub[key]
		if whole_image.get_data() != probe.get_image(name).get_data():
			map_ok = false; map_problem = name + ": the full window differs from compose_region"; break
		if sub_image.get_data() != whole_image.get_region(rect).get_data():
			map_ok = false; map_problem = name + ": the sub-window differs from the full window"; break
	check(map_ok, "compose_map windows equal the region composition (height, materials, masks, macro, channel and coverage): " + map_problem)
	var both := StrataRegionCompose.compose_map(terrain, null, "material_weights", StrataRegions.map_window(spec, probe_xy, spec.maps.material_weights), spec)
	check(both.ok and both.has("ids") and both.has("weights") and both.image == both.weights, "material maps return ids and weights together")
	var rectangular := StrataRegions.map_window(spec, probe_xy, spec.maps.holes)
	rectangular.size = Vector2i(6, 4)
	var rejected := StrataRegionCompose.compose_map(terrain, null, "holes", rectangular, spec)
	check(not rejected.ok and String(rejected.message).contains("square"), "a rectangular cell-mask window is rejected: %s" % rejected.get("message"))
	var thin := StrataRegions.map_window(spec, probe_xy, spec.maps.macro)
	thin.size = Vector2i(1, 5)
	rejected = StrataRegionCompose.compose_map(terrain, null, "macro", thin, spec)
	check(not rejected.ok and String(rejected.message).contains("2 x 2"), "a macro window under 2 texels is rejected: %s" % rejected.get("message"))
	check(not StrataRegionCompose.compose_map(terrain, null, "nav_wet", rectangular, spec).ok and not StrataRegionCompose.compose_map(terrain, null, "unknown", rectangular, spec).ok, "derived and unknown maps are rejected")
	# A material channel painted as a generic signed channel (negative values) counts as no
	# coverage instead of failing the composition (the island's "test" channel case).
	var signed_scene := Node3D.new(); get_root().add_child(signed_scene)
	var signed_terrain := StrataTerrain3D.new(); signed_terrain.base_bounds = Rect2(-8, -8, 16, 16); signed_terrain.set_preview_enabled(false); signed_scene.add_child(signed_terrain)
	signed_terrain.editor_materials = [StrataMaterial.new(), StrataMaterial.new()]
	var signed_base := StrataLayer.new(); signed_base.name = "Base"; signed_terrain.add_child(signed_base); signed_base.data.grid_origin = Vector2(-8, -8)
	var signed_hand := StrataLayer.new(); signed_hand.name = "Hand"; signed_terrain.add_child(signed_hand); signed_hand.data.grid_origin = Vector2(-8, -8)
	for j in range(17):
		for i in range(17):
			signed_base.data.set_sample(&"height", Vector2i(i, j), 1.0)
			signed_base.data.set_sample(&"material_a", Vector2i(i, j), 1.0)
			signed_hand.data.set_sample(&"test", Vector2i(i, j), -3.0 if i < 8 else 1.0)
	signed_terrain.editor_material_channels = PackedStringArray(["test", "material_a"])
	var signed_spec := signed_terrain.region_spec()
	var signed_ids := StrataRegionCompose.compose_map(signed_terrain, null, "material_ids", StrataRegions.map_window(signed_spec, Vector2i.ZERO, signed_spec.maps.material_ids), signed_spec)
	var signed_weights := StrataRegionCompose.compose_map(signed_terrain, null, "material_weights", StrataRegions.map_window(signed_spec, Vector2i.ZERO, signed_spec.maps.material_weights), signed_spec)
	check(signed_ids.get("ok", false) and signed_weights.get("ok", false), "negative material values do not fail the composition: %s" % signed_weights.get("message", ""))
	if signed_ids.get("ok", false) and signed_weights.get("ok", false):
		var a: int = signed_spec.apron
		var negative_side: Color = signed_weights.image.get_pixel(a + 2, a + 8) * 255.0
		var negative_ids: Color = signed_ids.image.get_pixel(a + 2, a + 8) * 255.0
		var positive_side: Color = signed_weights.image.get_pixel(a + 12, a + 8) * 255.0
		check(roundi(negative_side.r) == 255 and roundi(negative_ids.r) == 1 and roundi(negative_side.g) == 0, "a negative value is no coverage: material_a alone where test is negative")
		check(absi(roundi(positive_side.r) - 128) <= 1 and absi(roundi(positive_side.g) - 127) <= 1, "a positive value shares as usual")
	var nan_plane := Image.create(4, 4, false, Image.FORMAT_RF); nan_plane.fill(Color(NAN, 0, 0))
	var full_plane := Image.create(4, 4, false, Image.FORMAT_RF); full_plane.fill(Color(1.0, 0, 0))
	var nan_pack: Dictionary = StrataLayerData.pack_material_weights_sparse([nan_plane, full_plane])
	check(not nan_pack.get("ok", false) and String(nan_pack.get("message", "")).begins_with("Material weights must be finite"), "non-finite material values still fail the pack")
	signed_scene.free()
	finish("REGION_COMPOSE_TEST")
