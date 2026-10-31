extends SceneTree
## Tiled material cook, without Houdini: the tile grid, the assembly of tile results into one
## native field per channel (float or 8-bit), the one-transaction publication of prebuilt
## fields, validation of lattices above one image's 20 Mi samples, and the tile bounds of the
## Strata input snapshot. The tile results are ARTIFICIAL fixtures (an analytic function of the
## world position) that stand in for the HDA's cooked tiles; scripts/houdini/test_material_tiling.py
## proves, with real cooks, that real tiles equal a whole cook.
var checks := 0
var failures := 0

func _initialize() -> void: run.call_deferred()
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures += 1; push_error("MATERIAL_TILING: " + message)

## The fixture's weight of [param channel] at lattice sample [param at]: smooth, in 0..1, different per channel.
func weight(channel: int, at: Vector2i) -> float:
	return 0.5 + 0.5 * sin(at.x * 0.37 + channel * 1.7) * cos(at.y * 0.23 - channel)

func image_of(channel: int, start: Vector2i, size: Vector2i) -> Image:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RF)
	for y in range(size.y):
		for x in range(size.x): image.set_pixel(x, y, Color(weight(channel, start + Vector2i(x, y)), 0, 0))
	return image

## The routed fields one tile cook returns: every material channel over the tile, in the terrain frame.
func tile_results(tile: Dictionary, origin: Vector2, spacing: float, names: PackedStringArray) -> Array:
	var results: Array = []
	for index in range(names.size()):
		results.append({"name": names[index], "image": image_of(index, tile.start, tile.size),
				"sample_origin": Vector3(origin.x + tile.start.x * spacing, 0.0, origin.y + tile.start.y * spacing),
				"sample_step_x": Vector3(spacing, 0, 0), "sample_step_y": Vector3(0, 0, spacing), "attrs": {"role": "value", "channel": names[index]}, "composition": "replace"})
	return results

func assemble(resolution: Vector2i, tile: int, overlap: int, unorm8: bool, origin := Vector2(-8, -8), spacing := 2.0) -> HEGoIslandMaterials.TileAssembler:
	var names := HEGoIslandMaterials.channels()
	var assembler := HEGoIslandMaterials.TileAssembler.new(origin, spacing, resolution, unorm8)
	for entry in HEGoIslandMaterials.tile_grid(resolution, tile, overlap):
		var added := assembler.add(entry, tile_results(entry, origin, spacing, names))
		if not added.ok: check(false, "tile %s assembles: %s" % [entry.index, added.message]); break
	return assembler

func run() -> void:
	_grid()
	_assembly()
	await _publication()
	_snapshot_bounds()
	await _large_lattice()
	print("MATERIAL_TILING checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)


func _grid() -> void:
	var single := HEGoIslandMaterials.axis_tiles(4097, 4097, 32)
	check(single.size() == 1 and single[0] == {"start": 0, "end": 4096, "owned_start": 0, "owned_end": 4096}, "a lattice of exactly tile_samples is one tile")
	check(HEGoIslandMaterials.tile_grid(Vector2i(100, 30), 4097, 32).size() == 1, "a small lattice is one tile")
	# The island at 0.5 m with the default overlap: 8193 samples do not fit two 4097-sample tiles
	# (they would need 4113), so 3 x 3 balanced tiles of 2753 samples. Two tiles of 4113 would be 4 tiles.
	var island := HEGoIslandMaterials.axis_tiles(8193, 4097, 32)
	check(island.size() == 3 and island[0].start == 0 and island[0].end == 2752 and island[1].start == 2721 and island[2].start == 5440 and island[2].end == 8192, "8193 samples, tile limit 4097, overlap 32: 3 balanced tiles of 2753, the last clamped to the end")
	var wide := HEGoIslandMaterials.axis_tiles(8193, 4113, 32)
	check(wide.size() == 2 and wide[0].end == 4112 and wide[1].start == 4080, "with a 4113-sample limit the island needs only 2 tiles per axis")
	var exact := HEGoIslandMaterials.exact_overlap(0.5)
	check(exact == 1804 and HEGoIslandMaterials.exact_overlap(4.0) == 226, "the exact overlap is 2 x (dependency radius + 2): 1804 samples at 0.5 m, 226 at 4 m (%d)" % exact)
	for case in [[1025, 545, 64], [8193, 4097, 32], [8193, 4097, exact], [1026, 100, 20], [300, 100, 0], [101, 100, 50]]:
		var tiles := HEGoIslandMaterials.axis_tiles(case[0], case[1], case[2])
		var owned := 0
		var ok: bool = tiles[0].owned_start == 0 and tiles[-1].owned_end == case[0] - 1
		for index in range(tiles.size()):
			var tile := tiles[index]
			owned += tile.owned_end - tile.owned_start + 1
			ok = ok and tile.end - tile.start + 1 <= case[1] and tile.end - tile.start + 1 == tiles[0].end - tiles[0].start + 1 and tile.start <= tile.owned_start and tile.owned_end <= tile.end
			if index > 0: ok = ok and tile.owned_start == tiles[index - 1].owned_end + 1 and tile.owned_start - tile.start >= case[2] / 2 and tiles[index - 1].end - tiles[index - 1].owned_end >= case[2] / 2
		check(ok and owned == case[0], "%d samples, tile %d, overlap %d: %d tiles own every sample once, at least overlap/2 inside each interior edge" % [case[0], case[1], case[2], tiles.size()])
	var grid := HEGoIslandMaterials.tile_grid(Vector2i(70, 45), 32, 8)
	var area := 0
	for entry in grid: area += entry.owned.get_area()
	check(grid.size() == 6 and area == 70 * 45 and grid[0].index == Vector2i(0, 0) and grid[1].index == Vector2i(1, 0) and grid[3].index == Vector2i(0, 1), "a 2-D grid is row-major and its owned rectangles tile the lattice")
	var bands := HEGoIslandMaterials.row_bands(Vector2i(8193, 8193))
	var rows := 0
	for band in bands: rows += band.size.y
	check(rows == 8193 and bands[0].size.x * bands[0].size.y <= StrataProcedural.MAX_FIELD_SAMPLES and bands.size() == 4, "an 8193 x 8193 lattice reads and writes in %d row bands under 20 Mi samples" % bands.size())
	check(HEGoIslandMaterials.row_bands(Vector2i(4097, 4097)).size() == 1, "a lattice the single cook makes is one band")
	var island_terrain := _terrain(Rect2(-2048, -2048, 4096, 4096)); var odd_terrain := _terrain(Rect2(0, 0, 10, 10))
	check(HEGoIslandMaterials.material_lattice(island_terrain, 0.5).resolution == Vector2i(8193, 8193) and not HEGoIslandMaterials.material_lattice(odd_terrain, 3.0).ok, "the lattice is a whole number of samples over the bounds")
	island_terrain.free(); odd_terrain.free()


func _terrain(bounds: Rect2) -> StrataTerrain3D:
	var terrain := StrataTerrain3D.new(); terrain.base_bounds = bounds
	return terrain


func _assembly() -> void:
	var names := HEGoIslandMaterials.channels()
	var resolution := Vector2i(70, 45)
	var assembler := assemble(resolution, 32, 8, false)
	var whole := assemble(resolution, 4097, 8, false)
	check(assembler.fields.size() == names.size() and whole.fields.size() == names.size(), "every channel is assembled")
	var identical := true
	var covered := true
	for index in range(names.size()):
		var tiled: StrataFieldData = assembler.fields[names[index]]
		var read := tiled.data.read_dense(tiled.channel, Vector2i.ZERO, resolution)
		var reference: Dictionary = whole.fields[names[index]].data.read_dense(tiled.channel, Vector2i.ZERO, resolution)
		covered = covered and read.owned_count == resolution.x * resolution.y
		identical = identical and (read.image as Image).get_data() == (reference.image as Image).get_data() and (read.image as Image).get_data() == image_of(index, Vector2i.ZERO, resolution).get_data()
		check(tiled.resolution == resolution and tiled.sample_origin == Vector3(-8, 0, -8) and tiled.sample_step_x == Vector3(2, 0, 0) and tiled.data.get_channel_format(tiled.channel) == StrataLayerData.VALUE_FLOAT32, "channel %s sits on the full lattice in float storage" % names[index])
	check(covered, "every sample of every assembled channel is owned")
	check(identical, "tiles of 32 with overlap 8 assemble byte-exact to the untiled field (float)")
	var quantized := assemble(resolution, 32, 8, true)
	var worst := 0.0
	for index in range(names.size()):
		var field: StrataFieldData = quantized.fields[names[index]]
		var read := field.data.read_dense(field.channel, Vector2i.ZERO, resolution)
		var reference := image_of(index, Vector2i.ZERO, resolution)
		for y in range(resolution.y):
			for x in range(resolution.x): worst = maxf(worst, absf((read.image as Image).get_pixel(x, y).r - reference.get_pixel(x, y).r))
		check(field.data.get_channel_format(field.channel) == StrataLayerData.VALUE_UNORM8, "8-bit storage selected for " + names[index])
	check(worst <= 1.0 / 255.0, "8-bit storage round-trips within 1/255 (worst %.5f)" % worst)
	var float_bytes: int = (assembler.fields[names[0]] as StrataFieldData).data.get_memory_bytes(StringName(names[0]))
	var byte_bytes: int = (quantized.fields[names[0]] as StrataFieldData).data.get_memory_bytes(StringName(names[0]))
	check(byte_bytes * 2 < float_bytes, "8-bit values take less than half the native bytes (%d of %d)" % [byte_bytes, float_bytes])
	# A tile that is not on the lattice is refused rather than written somewhere else.
	var misplaced := HEGoIslandMaterials.TileAssembler.new(Vector2(-8, -8), 2.0, resolution, true)
	var grid := HEGoIslandMaterials.tile_grid(resolution, 32, 8)
	var results := tile_results(grid[1], Vector2(-8, -8), 2.0, names)
	results[0].sample_origin.x += 1.0
	check(not misplaced.add(grid[1], results).ok, "a tile result off the lattice is rejected")
	results = tile_results(grid[1], Vector2(-8, -8), 2.0, names)
	results[0].sample_step_x = Vector3(1, 0, 0)
	check(not misplaced.add(grid[1], results).ok, "a tile result on another spacing is rejected")
	var short := tile_results(grid[1], Vector2(-8, -8), 2.0, names)
	short.pop_back()
	var partial := HEGoIslandMaterials.TileAssembler.new(Vector2(-8, -8), 2.0, resolution, true)
	partial.add(grid[1], short)
	check(not partial.result_fields(names).ok, "a result missing a channel is refused")


func _publication() -> void:
	var names := HEGoIslandMaterials.channels()
	var resolution := Vector2i(70, 45)
	var scene := Node3D.new(); root.add_child(scene); current_scene = scene
	var terrain := StrataTerrain3D.new(); terrain.name = "Terrain"; terrain.base_bounds = Rect2(-8, -8, 138, 88); terrain.region_spacing = 2.0; terrain.region_cells = 16
	terrain.set_preview_enabled(false)
	scene.add_child(terrain)
	var below := StrataLayer.new(); below.name = "Below"; terrain.add_child(below)
	var target := StrataLayer.new(); target.name = HEGoIslandMaterials.LAYER; target.procedural = true; terrain.add_child(target)
	var host := Node3D.new(); host.name = "Host"; scene.add_child(host)
	await process_frame
	var assembler := assemble(resolution, 32, 8, true)
	var entries: Array = assembler.result_fields(names).fields
	var snapshot := StrataProcedural.create_snapshot(below, "raw", {"channels": ["height"]})
	var tokens: Array = [{"ok": true, "token": snapshot.token}]
	var ticket := StrataProcedural.begin_transaction(host, "tiled-test", [{"layer": target, "channels": names}], tokens, {})
	check(ticket.ok, "one transaction opens for the assembled result: " + String(ticket.get("message")))
	var committed := StrataProcedural.commit_fields(ticket, [{"layer_id": target.ensure_identity(), "fields": entries, "explicit_empty": false}])
	check(committed.ok and target.procedural_fields.size() == names.size() and not target.procedural_stale and target.procedural_revision == 1, "the prebuilt native fields are published in that one transaction: " + String(committed.get("message")))
	check(target.procedural_fields[names[0]] == assembler.fields[names[0]], "the published field is the assembled resource itself, not a copy")
	var valid := HEGoIslandMaterials.validate(target)
	check(valid.ok and valid.first.resolution == resolution and not valid.images_omitted, "validate accepts the assembled 8-bit layer on the terrain lattice: " + String(valid.get("message")))
	var hashed := HEGoIslandMaterials.layer_content_hash(target)
	check(hashed == HEGoIslandMaterials.layer_content_hash(target) and not hashed.is_empty(), "the content hash reads the native fields")
	# Samples no tile wrote are caught before any transaction; a prebuilt field whose owned
	# rectangle is short is refused by the transaction itself, with the previous result kept.
	var partial := assemble(resolution, 32, 8, true)
	var broken: StrataFieldData = partial.fields[names[1]]
	broken.data.erase_dense(broken.channel, Vector2i(3, 3), _mask(Vector2i(2, 2)))
	check(not partial.result_fields(names).ok, "the assembler refuses a field with unwritten samples")
	var short := assemble(resolution, 32, 8, true)
	var trimmed: StrataFieldData = short.fields[names[2]]
	trimmed.data.erase_dense(trimmed.channel, Vector2i(0, 0), _mask(Vector2i(resolution.x, 1)))
	var second := StrataProcedural.begin_transaction(host, "tiled-test", [{"layer": target, "channels": names}], tokens, {})
	var entries_short: Array = []
	for name in names: entries_short.append({"name": name, "field_data": short.fields[name], "composition": "replace"})
	var refused := StrataProcedural.commit_fields(second, [{"layer_id": target.ensure_identity(), "fields": entries_short, "explicit_empty": false}])
	check(second.ok and not refused.ok and target.procedural_fields[names[0]] == assembler.fields[names[0]], "a prebuilt field that does not own its lattice rectangle is rejected and the previous result stays")
	scene.free()


func _mask(size: Vector2i) -> Image:
	var mask := Image.create(size.x, size.y, false, Image.FORMAT_RF)
	mask.fill(Color(1, 0, 0))
	return mask


func _snapshot_bounds() -> void:
	var terrain := StrataTerrain3D.new(); terrain.base_bounds = Rect2(-8, -8, 64, 64); terrain.set_preview_enabled(false); root.add_child(terrain)
	var layer := StrataLayer.new(); layer.data.sample_spacing = 4.0; layer.data.grid_origin = Vector2(-8, -8); terrain.add_child(layer)
	layer.data.replace_dense(&"height", Vector2i.ZERO, image_of(0, Vector2i.ZERO, Vector2i(17, 17)))
	var settings := {"terrain_mode": "cumulative", "terrain_channels": PackedStringArray(["height"]), "terrain_spacing": 2.0}
	var whole := HEGoStrataInput.snapshot(layer, settings)
	var tile_settings := settings.duplicate(); tile_settings.terrain_bounds = Rect2(8, -8, 24, 32)
	var tile := HEGoStrataInput.snapshot(layer, tile_settings)
	check(whole.ok and tile.ok, "snapshots with and without terrain_bounds succeed")
	if whole.ok and tile.ok:
		var whole_height: Dictionary = whole.fields[0]; var tile_height: Dictionary = tile.fields[0]
		check(whole_height.image.get_size() == Vector2i(33, 33) and tile_height.image.get_size() == Vector2i(13, 17), "terrain_bounds limits the lattice to the tile (%s)" % tile_height.image.get_size())
		check(tile_height.sample_origin == Vector3(8, 0, -8) and tile_height.sample_step_x == Vector3(2, 0, 0) and tile_height.sample_step_y == Vector3(0, 0, 2), "the tile lattice is the full lattice's: same steps, origin on a full-lattice sample")
		var same := true
		for y in range(tile_height.image.get_height()):
			for x in range(tile_height.image.get_width()): same = same and tile_height.image.get_pixel(x, y).r == whole_height.image.get_pixel(x + 8, y).r
		check(same, "tile samples equal the full snapshot's at the same positions")
	tile_settings.terrain_bounds = "not a rect"
	check(not HEGoStrataInput.snapshot(layer, tile_settings).ok, "terrain_bounds must be a Rect2")
	check(not HEGoIslandStageMaterials.input_settings(4.0, {"terrain_bounds": Rect2(0, 0, 1, 1)}, true, 1.0).has("terrain_bounds"), "migrated input rows never keep a tile's terrain_bounds")
	root.remove_child(terrain); terrain.free()


## A lattice just above one image's 20 Mi samples, assembled from four 2300-sample tiles in 8-bit
## storage: validate reads it in row bands, and the single-image packer refuses it.
func _large_lattice() -> void:
	var names := HEGoIslandMaterials.channels()
	var side := 4600
	var resolution := Vector2i(side, side)
	var terrain := StrataTerrain3D.new(); terrain.name = "Terrain"; terrain.base_bounds = Rect2(0, 0, side - 1, side - 1); terrain.region_spacing = 1.0; terrain.region_cells = 16
	terrain.set_preview_enabled(false); root.add_child(terrain)
	var below := StrataLayer.new(); below.name = "Below"; terrain.add_child(below)
	var target := StrataLayer.new(); target.name = HEGoIslandMaterials.LAYER; target.procedural = true; terrain.add_child(target)
	var started := Time.get_ticks_msec()
	var assembler := HEGoIslandMaterials.TileAssembler.new(Vector2.ZERO, 1.0, resolution, true)
	for entry in HEGoIslandMaterials.tile_grid(resolution, 2400, 200):
		var results: Array = []
		for index in range(names.size()): results.append({"name": names[index], "image": _flat(entry.size, 0.25 * (index + 1)), "sample_origin": Vector3(entry.start.x, 0, entry.start.y), "sample_step_x": Vector3.RIGHT, "sample_step_y": Vector3.BACK, "attrs": {"role": "value"}})
		var added := assembler.add(entry, results)
		if not added.ok: check(false, "large tile assembles: " + String(added.message)); break
	for index in range(names.size()): target.procedural_fields[names[index]] = assembler.fields[names[index]]
	var valid := HEGoIslandMaterials.validate(target)
	check(valid.ok and valid.images_omitted and valid.first.resolution == resolution, "a %s lattice above 20 Mi samples validates in row bands (%d ms): %s" % [resolution, Time.get_ticks_msec() - started, valid.get("message")])
	check(not HEGoIslandMaterials.pack(target).ok, "the single-image packer refuses a lattice above 20 Mi samples")
	var field: StrataFieldData = assembler.fields[names[3]]
	var corner := field.data.read_dense(field.channel, Vector2i(side - 2, side - 2), Vector2i(2, 2))
	check(corner.owned_count == 4 and absf((corner.image as Image).get_pixel(1, 1).r - 1.0) < 1.0 / 255.0, "the last sample of the last tile is written")
	check(HEGoIslandMaterials.layer_content_hash(target).length() == 64, "the content hash covers a field above 20 Mi samples in bands")
	terrain.free()


func _flat(size: Vector2i, value: float) -> Image:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RF)
	image.fill(Color(value, 0, 0))
	return image
