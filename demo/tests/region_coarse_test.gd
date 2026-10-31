extends "res://tests/runtime_test_base.gd"
## Coarse maps of the bake (Phase B, D2): every map of the spec is stitched into the manifest
## from the regions' level cores, byte for byte, for every map kind (height, material ids and
## weights, holes and exclusions, a retained channel and its coverage, a navigation profile),
## at coarse level 0, 1 and 2 (forced through coarse_max_side); mip_levels is raised to cover
## the far and coarse levels.

var terrain: StrataTerrain3D

func _initialize() -> void:
	call_deferred("run")

func layer(label: String) -> StrataLayer:
	var result := StrataLayer.new()
	result.name = label
	terrain.add_child(result)
	result.owner = terrain
	return result

func build_terrain() -> void:
	terrain = StrataTerrain3D.new()
	terrain.name = "Terrain"
	terrain.base_bounds = Rect2(-32.0, -32.0, 64.0, 64.0)
	terrain.editor_material_channels = PackedStringArray(["mat_a", "mat_b", "mat_c"])
	terrain.set_preview_enabled(false)
	root.add_child(terrain)
	var base := layer("Base")
	base.data.sample_spacing = 2.0
	base.data.grid_origin = Vector2(-32.0, -32.0)
	for j in range(33):
		for i in range(33):
			base.data.set_sample(&"height", Vector2i(i, j), 2.0 * sin(i * 0.5) - 1.5 + j * 0.3 + 0.01 * i * j)
			base.data.set_sample(&"mat_a", Vector2i(i, j), 1.0 if i < 17 else 0.0)
			base.data.set_sample(&"mat_b", Vector2i(i, j), 0.6 if j < 12 else 0.2)
			base.data.set_sample(&"mask", Vector2i(i, j), 0.03 * i - 0.5)
	var detail := layer("Detail")
	for j in range(-6, 24):
		for i in range(-6, 8):
			detail.data.set_sample(&"hole", Vector2i(i, j), 1.0)
	for j in range(14, 30):
		for i in range(-20, 6):
			detail.data.set_sample(&"nav_exclusion", Vector2i(i, j), 1.0)

func bake(extra: Dictionary) -> Dictionary:
	var options := {"spacing": 1.0, "region_cells": 16, "cell_masks": true, "channels": PackedStringArray(["mask"]), "nav_profiles": [{"name": &"wet", "rule": {"channel": "mask", "min": 0.3}}], "macro": false}
	options.merge(extra, true)
	return StrataBake.compile(terrain, options)

## Every coarse texel equals the matching texel of the region that owns it.
func verify(data: StrataRuntimeData, label: String) -> void:
	var spec := data.get_spec()
	var level := data.coarse_level
	var kinds := {}
	for name in data.maps:
		var description := data.description(name)
		var size := StrataRegions.coarse_map_size(spec, description, level)
		var bytes: PackedByteArray = data.coarse_maps.get(name, PackedByteArray())
		var bpt := StrataRegions.bytes_per_texel(int(description.format))
		check(bytes.size() == size.x * size.y * bpt, "%s: %s coarse map is %s texels" % [label, name, size])
		if bytes.size() != size.x * size.y * bpt: continue
		kinds[description.kind] = true
		var n := StrataRegions.texels_per_axis(data.cells, description, level)
		var apron := int(description.apron)
		var level_size := StrataRegions.map_size(data.cells, description, level)
		var mismatches := 0
		for ty in range(size.y):
			for tx in range(size.x):
				var owner := Vector2i(mini(tx / n, data.grid.x - 1), mini(ty / n, data.grid.y - 1))
				var local := Vector2i(tx, ty) - owner * n + Vector2i.ONE * apron
				var from := (ty * size.x + tx) * bpt
				var source := data.get_region(owner).level_bytes(name, level)
				var at := (local.y * level_size.x + local.x) * bpt
				if bytes.slice(from, from + bpt) != source.slice(at, at + bpt): mismatches += 1
		check(mismatches == 0, "%s: %s coarse texels equal the owning region's level-%d texels (%d differ)" % [label, name, level, mismatches])
	check(kinds.has(StrataRegions.KIND_SAMPLE) and kinds.has(StrataRegions.KIND_CELL), "%s: both map kinds were checked" % label)

func run() -> void:
	build_terrain()
	await process_frame
	for entry in [[{}, 0], [{"coarse_max_side": 32}, 1], [{"coarse_max_side": 16}, 2]]:
		var label := "coarse_max_side %s" % entry[0].get("coarse_max_side", "default")
		var result := bake(entry[0])
		check(result.ok, "%s: bake succeeds: %s" % [label, result.get("message")])
		if not result.ok: continue
		var data: StrataRuntimeData = result.data
		check(data.coarse_level == entry[1] and result.report.coarse_level == entry[1], "%s: coarse_level %d (got %d)" % [label, entry[1], data.coarse_level])
		check(data.mip_levels == maxi(3, entry[1] + 1) and result.report.mip_levels == data.mip_levels, "%s: mip_levels covers far and coarse levels (%d)" % [label, data.mip_levels])
		check(data.coarse_maps.size() == data.maps.size() and result.report.coarse_sizes.size() == data.maps.size(), "%s: every map has a coarse image" % label)
		for name in ["height", "material_ids", "material_weights", "holes", "nav_exclusion", "nav_wet", "mask", "mask__coverage"]:
			check(data.coarse_maps.has(name), "%s: coarse map %s exists" % [label, name])
		check(data.validate().ok, "%s: baked manifest validates: %s" % [label, data.validate()])
		check(result.report.manifest.coarse_level == entry[1] and result.report.manifest.coarse_bytes == data.coarse_bytes(), "%s: report manifest lists the coarse maps" % label)
		verify(data, label)
		if entry[1] == 0:
			# At level 0 the coarse height is the terrain lattice itself.
			var image := data.coarse_image("height")
			var worst := 0.0
			for j in range(data.resolution.y):
				for i in range(data.resolution.x):
					worst = maxf(worst, absf(image.get_pixel(i, j).r - data.get_height_at(Vector2i(i, j))))
			check(image.get_size() == data.resolution and worst == 0.0, "%s: level 0 coarse heights are the lattice (max %s)" % [label, worst])
		var copy := data.duplicate_runtime()
		check(copy != null and copy.coarse_level == data.coarse_level and copy.coarse_maps == data.coarse_maps and copy.validate().ok, "%s: duplicate carries the coarse maps" % label)
	finish("region_coarse_test")
