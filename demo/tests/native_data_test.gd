extends SceneTree

var failures: Array[String] = []

var checks := 0

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func close_to(actual: float, expected: float, message: String) -> void:
	check(is_equal_approx(actual, expected), "%s (got %s, expected %s)" % [message, actual, expected])

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var layer = ClassDB.instantiate("StrataLayerData")
	check(layer != null, "native StrataLayerData class is registered")
	if layer == null:
		quit(1)
		return

	layer.set_sample(&"height", Vector2i(-257, -256), 8.0)
	check(layer.has_sample(&"height", Vector2i(-257, -256)), "negative tile-border sample exists")
	check(layer.get_owned_samples(&"height").has(Vector2i(-257, -256)), "negative tile-border sample is listed")
	layer.set_sample(&"border", Vector2i(-256, 0), 3.0)
	layer.set_sample(&"border", Vector2i(-257, 0), 4.0)
	check(layer.get_sample(&"border", Vector2i(-256, 0)) == 3.0 and layer.get_sample(&"border", Vector2i(-257, 0)) == 4.0, "samples on both sides of a negative tile boundary remain distinct")

	# All four bilinear corners contribute in proportion to their weights.
	for sample in [[Vector2i(0, 0), 0.0], [Vector2i(1, 0), 10.0], [Vector2i(0, 1), 20.0], [Vector2i(1, 1), 30.0]]:
		layer.set_sample(&"four_corner", sample[0], sample[1])
	var four_corner: Dictionary = layer.sample_channel(&"four_corner", Vector2(0.25, 0.75))
	close_to(float(four_corner.get("value", 0.0)), 17.5, "bilinear interpolation combines all four corners")
	close_to(float(four_corner.get("coverage", 0.0)), 1.0, "four owned corners provide full coverage")

	layer.set_sample(&"height", Vector2i(1, 1), 4.0)
	var revision_after_touch: int = layer.get_revision()
	layer.set_sample(&"height", Vector2i(1, 1), 4.0)
	check(layer.get_owned_samples(&"height").count(Vector2i(1, 1)) == 1, "same-value writes keep one owned sample")
	check(layer.get_revision() == revision_after_touch, "same-value write does not advance revision")

	var weighted: Dictionary = layer.sample_channel(&"height", Vector2(1.25, 1.0))
	close_to(float(weighted.get("value", 0.0)), 4.0, "weighted sample preserves constant value")
	close_to(float(weighted.get("coverage", 0.0)), 0.75, "coverage reports partial bilinear ownership")
	var empty: Dictionary = layer.sample_channel(&"height", Vector2(20.0, 20.0))
	close_to(float(empty.get("coverage", -1.0)), 0.0, "unowned area has zero coverage")

	layer.erase_sample(&"height", Vector2i(1, 1))
	check(not layer.has_sample(&"height", Vector2i(1, 1)), "erase removes sample ownership")
	var erased: Dictionary = layer.sample_channel(&"height", Vector2(1.0, 1.0))
	close_to(float(erased.get("coverage", -1.0)), 0.0, "erased sample has no coverage")

	layer.set_sample(&"weight", Vector2i(5, 6), 0.25)
	var saved: Dictionary = layer.snapshot()
	layer.set_sample(&"weight", Vector2i(5, 6), 0.9)
	layer.set_sample(&"weight", Vector2i(7, 8), 0.5)
	layer.restore(saved)
	close_to(float(layer.get_sample(&"weight", Vector2i(5, 6))), 0.25, "restore returns saved value")
	check(not layer.has_sample(&"weight", Vector2i(7, 8)), "restore removes post-snapshot sample")

	# Grid resolution is locked while data exists, then editable once its channel is cleared.
	var revision_before_grid: int = layer.get_revision()
	layer.sample_spacing = 2.0
	layer.grid_origin = Vector2(1.5, -2.5)
	close_to(layer.sample_spacing, 1.0, "populated terrain data rejects spacing changes")
	check(layer.grid_origin == Vector2.ZERO and layer.get_revision() == revision_before_grid, "populated terrain rejects origin changes without advancing revision")
	layer.clear_channel(&"height")
	layer.clear_channel(&"weight")
	layer.clear_channel(&"border")
	layer.clear_channel(&"four_corner")
	layer.sample_spacing = 2.0
	layer.grid_origin = Vector2(1.5, -2.5)
	close_to(layer.sample_spacing, 2.0, "empty terrain data accepts a new spacing")
	layer.set_sample(&"weight", Vector2i(5, 6), 0.25)

	var path := "user://strata_native_data_test.tres"
	var save_error := ResourceSaver.save(layer, path)
	check(save_error == OK, "ResourceSaver saves terrain data")
	if save_error == OK:
		var serialized_text := FileAccess.get_file_as_string(path)
		check(serialized_text.contains("\"format_version\": 2"), "ResourceSaver persists an explicit format version in the complete payload")
		var loaded = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		check(loaded != null, "ResourceLoader loads terrain data")
		if loaded != null:
			close_to(float(loaded.get_sample(&"weight", Vector2i(5, 6))), 0.25, "loaded resource retains saved values")
			check(loaded.get_format_version() == 2 and loaded.sample_spacing == 2.0 and loaded.grid_origin == Vector2(1.5, -2.5), "ResourceLoader retains version and nondefault native grid")
		var future_path := "user://strata_future_data_test.tres"
		var future_file := FileAccess.open(future_path, FileAccess.WRITE)
		check(future_file != null, "future-version resource fixture can be written")
		if future_file != null:
			future_file.store_string(serialized_text.replace("\"format_version\": 2", "\"format_version\": 99"))
			future_file.close()
			var future = ResourceLoader.load(future_path, "", ResourceLoader.CACHE_MODE_IGNORE)
			check(future != null and future.get_channel_names().is_empty() and future.sample_spacing == 1.0 and future.grid_origin == Vector2.ZERO and future.get_revision() == 0, "future serialized payload rejects its samples and nondefault grid atomically")

	_run_layer_composition_and_brush_checks()
	_run_native_edge_cases()
	_run_grid_and_first_touch_checks()
	_run_value_format_checks()
	_run_serialization_v2_checks()
	_run_pack_checks()

	print("NATIVE_DATA checks=%d failures=%d" % [checks, failures.size()])
	if failures.is_empty():
		print("Strata native data tests passed")
		quit(0)
	else:
		push_error("%d Strata native data test(s) failed" % failures.size())
		quit(1)

func _run_layer_composition_and_brush_checks() -> void:
	var terrain := StrataTerrain3D.new()
	terrain.base_bounds = Rect2(-4.0, -4.0, 8.0, 8.0)
	root.add_child(terrain)
	var base := StrataLayer.new()
	var overlay := StrataLayer.new()
	terrain.add_child(base)
	terrain.add_child(overlay)
	base.data.set_sample(&"height", Vector2i.ZERO, 5.0)
	overlay.data.set_sample(&"height", Vector2i.ZERO, 9.0)
	close_to(terrain.sample_height(Vector2.ZERO), 9.0, "replace layer overrides lower layer at full coverage")
	overlay.set_composition(&"height", StrataLayer.Composition.ADD)
	close_to(terrain.sample_height(Vector2.ZERO), 14.0, "add layer adds its authored value")
	overlay.enabled = false
	close_to(terrain.sample_height(Vector2.ZERO), 5.0, "disabled layer does not contribute")
	overlay.enabled = true

	var brush_terrain := StrataTerrain3D.new()
	brush_terrain.base_bounds = Rect2(-4.0, -4.0, 8.0, 8.0)
	root.add_child(brush_terrain)
	var ground := StrataLayer.new()
	var edits := StrataLayer.new()
	brush_terrain.add_child(ground)
	brush_terrain.add_child(edits)
	_fill_flat(ground.data, 10.0)
	var ground_before := ground.data.snapshot()

	var empty_layer := StrataLayer.new()
	brush_terrain.add_child(empty_layer)
	var revision_before_zero := empty_layer.data.get_revision()
	var touched_zero := StrataBrush.apply_brush(empty_layer, Vector2.ZERO, 1.5, 0.0, "raise")
	check(touched_zero == 0 and empty_layer.data.get_owned_samples(&"height").is_empty(), "zero-strength brush leaves ownership untouched")
	check(empty_layer.data.get_revision() == revision_before_zero, "zero-strength brush leaves revision untouched")

	var touched := StrataBrush.apply_brush(edits, Vector2.ZERO, 1.5, 2.0, "raise")
	check(touched > 0, "raise brush authors samples on the selected layer")
	close_to(brush_terrain.sample_height(Vector2.ZERO), 12.0, "Replace raise brush changes the base surface")
	check(ground.data.snapshot() == ground_before, "brush does not write to lower layers")
	var soft_before := brush_terrain.sample_height(Vector2(1.0, 0.0))
	check(soft_before > 10.0 and soft_before < 12.0, "brush preserves a soft falloff away from its center")
	var owned_value := edits.data.get_sample(&"height", Vector2i(1, 0))
	edits.data.set_sample(&"height", Vector2i(1, 0), owned_value)
	_fill_flat(ground.data, 20.0)
	close_to(brush_terrain.sample_height(Vector2.ZERO), 12.0, "Replace sculpted center survives base regeneration")
	close_to(brush_terrain.sample_height(Vector2(1.0, 0.0)), soft_before, "Replace falloff survives regeneration and same-value touch")
	var erased := StrataBrush.apply_brush(edits, Vector2.ZERO, 1.5, 1.0, "erase")
	check(erased > 0 and not edits.data.has_sample(&"height", Vector2i.ZERO), "erase brush removes selected-layer ownership")
	close_to(brush_terrain.sample_height(Vector2.ZERO), 20.0, "erasing edit reveals the regenerated lower layer")

	var additive_terrain := StrataTerrain3D.new()
	additive_terrain.base_bounds = Rect2(-4.0, -4.0, 8.0, 8.0)
	root.add_child(additive_terrain)
	var additive_base := StrataLayer.new()
	var additive_edits := StrataLayer.new()
	additive_terrain.add_child(additive_base)
	additive_terrain.add_child(additive_edits)
	_fill_flat(additive_base.data, 10.0)
	additive_edits.set_composition(&"height", StrataLayer.Composition.ADD)
	StrataBrush.apply_brush(additive_edits, Vector2.ZERO, 1.5, 2.0, "raise")
	close_to(additive_terrain.sample_height(Vector2.ZERO), 12.0, "Add brush authors a delta over the base")
	_fill_flat(additive_base.data, 20.0)
	close_to(additive_terrain.sample_height(Vector2.ZERO), 22.0, "Add delta survives base regeneration")

	terrain.queue_free()
	brush_terrain.queue_free()
	additive_terrain.queue_free()

func _fill_flat(data: StrataLayerData, value: float) -> void:
	data.clear_channel(&"height")
	for z in range(-4, 5):
		for x in range(-4, 5):
			data.set_sample(&"height", Vector2i(x, z), value)

func _run_native_edge_cases() -> void:
	var data := StrataLayerData.new()
	check(data.resource_local_to_scene, "terrain resources default to scene-local ownership")
	# This cell straddles four distinct tiles, including both negative seams.
	var corners := [Vector2i(-257, -257), Vector2i(-256, -257), Vector2i(-257, -256), Vector2i(-256, -256)]
	for i in range(corners.size()):
		data.set_sample(&"height", corners[i], 2.0 + i * 2.0)
	check(data.get_owned_samples(&"height").size() == 4, "four negative tile corners have unique ownership")
	var seam := data.sample_channel(&"height", Vector2(-256.75, -256.25))
	close_to(seam.value, 5.5, "interpolation crosses four negative tiles without cracks")
	check(seam.coverage == 1.0, "four negative tile corners give full coverage")
	data.erase_sample(&"height", corners[0])
	for i in range(1, corners.size()):
		check(data.has_sample(&"height", corners[i]), "erasing one negative corner preserves its neighbors")

	var source := StrataLayerData.new()
	var revision := source.get_revision()
	source.set_sample(&"height", Vector2i(2, 3), 7.0)
	check(source.get_revision() > revision, "first native write advances revision")
	var saved := source.snapshot()
	check(saved.format_version == 2, "snapshots explicitly declare format version 2")
	source.set_sample(&"height", Vector2i(2, 3), 9.0)
	check(saved.channels["height"].tiles[Vector2i.ZERO].values[770] == 7.0, "snapshot arrays do not alias later source writes")
	var exported: Dictionary = source.channels
	_set_serialized_sample(exported, 12.0, 0)
	check(source.get_sample(&"height", Vector2i(2, 3)) == 9.0 and source.has_sample(&"height", Vector2i(2, 3)), "mutating exported arrays cannot change native values or ownership")
	var restored := StrataLayerData.new()
	restored.restore(saved)
	var restored_revision := restored.get_revision()
	_set_serialized_sample(saved.channels, -8.0, 0)
	check(restored.get_sample(&"height", Vector2i(2, 3)) == 7.0 and restored.has_sample(&"height", Vector2i(2, 3)), "restoring copies input arrays independently")
	check(restored.get_revision() == restored_revision, "mutating a restore input cannot change native revision")

	var before := restored.snapshot()
	for invalid_version in [99, 0, 1.0, null]:
		var invalid := before.duplicate(true)
		if invalid_version == null:
			invalid.erase("format_version")
		else:
			invalid.format_version = invalid_version
		invalid.sample_spacing = 3.0
		invalid.grid_origin = Vector2(9.0, 9.0)
		invalid.channels = {}
		restored.restore(invalid)
		check(restored.snapshot() == before and restored.get_revision() == restored_revision, "invalid snapshot version rejects grid, samples and revision atomically: %s" % str(invalid_version))
	var invalid_arrays := before.duplicate(true)
	_set_serialized_sample(invalid_arrays.channels, 7.0, 2)
	restored.restore(invalid_arrays)
	check(restored.snapshot() == before and restored.get_revision() == restored_revision, "nonbinary ownership rejects a snapshot atomically")
	restored.erase_sample(&"height", Vector2i(2, 3))
	var erased_revision := restored.get_revision()
	restored.restore(before)
	check(restored.get_revision() > erased_revision and erased_revision > restored_revision, "erase and restoring older content keep revision monotonic")
	var unchanged_revision := restored.get_revision()
	restored.restore(before)
	check(restored.get_revision() == unchanged_revision, "restoring identical content does not advance revision")

	for grid in [[0.1, Vector2(0.3, -0.3)], [0.3, Vector2(0.1, -0.1)]]:
		var decimal := StrataLayerData.new()
		decimal.sample_spacing = grid[0]
		decimal.grid_origin = grid[1]
		var index := Vector2i(3, -3)
		decimal.set_sample(&"height", index, 7.0)
		var point := decimal.grid_origin + Vector2(index) * decimal.sample_spacing
		var native := decimal.sample_channel(&"height", point)
		check(native.value == 7.0 and native.coverage == 1.0, "decimal grid native point has exact value and coverage: %s" % str(grid[0]))
		var fractional := decimal.sample_channel(&"height", point + Vector2(decimal.sample_spacing * 0.25, 0.0))
		close_to(fractional.value, 7.0, "decimal grid reconstruction excludes unwritten zero values")
		close_to(fractional.coverage, 0.75, "decimal grid retains partial coverage off native points")

	var tiny := StrataLayerData.new()
	tiny.set_sample(&"height", Vector2i.ZERO, 6.0)
	var tiny_coverage := tiny.sample_channel(&"height", Vector2(0.9999999, 0.9999999))
	check(tiny_coverage.coverage > 0.0 and tiny_coverage.coverage < 0.000001, "tiny positive bilinear ownership coverage is retained")
	close_to(tiny_coverage.value, 6.0, "tiny coverage still reconstructs the owned value")

func _set_serialized_sample(channels: Dictionary, value: float, ownership: int) -> void:
	var entry: Dictionary = channels["height"]
	var tile: Dictionary = entry.tiles[Vector2i.ZERO] if entry.has("tiles") else entry[Vector2i.ZERO]
	var values: PackedFloat32Array = tile.values
	var owners: PackedByteArray = tile.ownership
	values[770] = value
	owners[770] = ownership
	tile.values = values
	tile.ownership = owners

func _run_grid_and_first_touch_checks() -> void:
	var terrain := StrataTerrain3D.new()
	terrain.base_bounds = Rect2(-4.0, -4.0, 8.0, 8.0)
	root.add_child(terrain)
	var base := StrataLayer.new()
	var edits := StrataLayer.new()
	base.data.sample_spacing = 2.0
	edits.data.sample_spacing = 0.5
	edits.data.grid_origin = Vector2(0.25, 0.25)
	terrain.add_child(base)
	terrain.add_child(edits)
	_fill_flat(base.data, 10.0)
	edits.data.set_sample(&"height", Vector2i.ZERO, 15.0)
	var fine_before := edits.data.snapshot()
	close_to(terrain.sample_height(Vector2(0.25, 0.25)), 15.0, "fine authored point overrides a coarser base")
	close_to(terrain.sample_height(Vector2(0.5, 0.25)), 12.5, "mixed grids blend lower terrain once using ownership coverage")
	_fill_flat(base.data, 20.0)
	close_to(terrain.sample_height(Vector2(0.25, 0.25)), 15.0, "fine authored point survives coarse base regeneration")
	close_to(terrain.sample_height(Vector2(0.5, 0.25)), 17.5, "unowned fraction tracks regenerated coarse terrain")
	base.data.clear_channel(&"height")
	base.data.sample_spacing = 3.0
	_fill_flat(base.data, 30.0)
	close_to(terrain.sample_height(Vector2(0.25, 0.25)), 15.0, "authored point survives rebuilding a base at different resolution")
	check(edits.data.snapshot() == fine_before, "base regeneration and grid changes preserve fine layer grid, values and ownership")
	terrain.queue_free()

	var touch_terrain := StrataTerrain3D.new()
	touch_terrain.base_bounds = Rect2(-4.0, -4.0, 8.0, 8.0)
	root.add_child(touch_terrain)
	var ground := StrataLayer.new()
	var flatten := StrataLayer.new()
	var feather := StrataLayer.new()
	touch_terrain.add_child(ground)
	touch_terrain.add_child(flatten)
	touch_terrain.add_child(feather)
	_fill_flat(ground.data, 10.0)
	var before_touch := flatten.data.get_revision()
	StrataBrush.apply_brush(flatten, Vector2.ZERO, 1.1, 1.0, "flatten", &"height", 10.0)
	check(flatten.data.has_sample(&"height", Vector2i.ZERO) and flatten.data.get_sample(&"height", Vector2i.ZERO) == 10.0, "flatten first touch claims ownership even when the visible height is unchanged")
	check(flatten.data.get_revision() > before_touch, "same-value flatten first touch advances revision")
	# The point at x=1 lies just inside the footprint: its positive influence
	# rounds the value back to float32 10, but it still must become fully owned.
	StrataBrush.apply_brush(feather, Vector2.ZERO, 1.00001, 2.0, "raise")
	check(feather.data.has_sample(&"height", Vector2i(1, 0)), "tiny positive brush falloff claims binary ownership")
	check(feather.data.sample_channel(&"height", Vector2(1.0, 0.0)).coverage == 1.0, "tiny positive brush falloff never becomes fractional native ownership")
	var feathered_height := feather.data.get_sample(&"height", Vector2i(1, 0))
	_fill_flat(ground.data, 20.0)
	close_to(touch_terrain.sample_height(Vector2(1.0, 0.0)), feathered_height, "tiny positive brush touch survives regeneration")
	feather.enabled = false
	close_to(touch_terrain.sample_height(Vector2.ZERO), 10.0, "same-value flatten ownership survives regeneration")
	touch_terrain.queue_free()

const FORMATS := [StrataLayerData.VALUE_FLOAT32, StrataLayerData.VALUE_UNORM8, StrataLayerData.VALUE_UNORM16]

func _near(a: float, b: float) -> bool:
	return absf(a - b) < 1e-6

func _quantize(value: float, format: int) -> float:
	if format == StrataLayerData.VALUE_FLOAT32:
		return value
	var levels := 255.0 if format == StrataLayerData.VALUE_UNORM8 else 65535.0
	return floorf(clampf(value, 0.0, 1.0) * levels + 0.5) / levels

func _rf(size: Vector2i, fn: Callable) -> Image:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RF)
	for y in range(size.y):
		for x in range(size.x):
			image.set_pixel(x, y, Color(fn.call(x, y), 0, 0, 1))
	return image

func _fill_formats(data: StrataLayerData) -> void:
	for format in FORMATS:
		var channel := StringName("c%d" % format)
		check(data.set_channel_format(channel, format), "empty channel accepts format %d" % format)
		data.set_sample(channel, Vector2i(-3, 4), 0.3)
		data.set_sample(channel, Vector2i(260, 5), 1.0)
		data.set_sample(channel, Vector2i(2, -300), 0.0)
		data.set_sample(channel, Vector2i(2, 2), 0.123456)

func _run_value_format_checks() -> void:
	var data := StrataLayerData.new()
	check(data.get_channel_format(&"anything") == StrataLayerData.VALUE_FLOAT32, "channels default to float32")
	_fill_formats(data)
	for format in FORMATS:
		var channel := StringName("c%d" % format)
		check(data.get_channel_format(channel) == format, "format %d is reported" % format)
		check(not data.set_channel_format(channel, (format + 1) % 3) and data.get_channel_format(channel) == format, "format of a channel with samples cannot change (%d)" % format)
		check(_near(data.get_sample(channel, Vector2i(-3, 4)), _quantize(0.3, format)), "get_sample dequantizes format %d" % format)
		check(data.has_sample(channel, Vector2i(2, -300)) and data.get_sample(channel, Vector2i(2, -300)) == 0.0, "owned zero survives format %d" % format)
		check(data.get_sample(channel, Vector2i(260, 5)) == 1.0, "one is exact in format %d" % format)
	check(_near(data.get_sample(&"c1", Vector2i(2, 2)), 31.0 / 255.0), "unorm8 rounds to nearest")
	data.set_sample(&"c1", Vector2i(9, 9), 3.0)
	data.set_sample(&"c2", Vector2i(9, 9), -3.0)
	check(data.get_sample(&"c1", Vector2i(9, 9)) == 1.0 and data.get_sample(&"c2", Vector2i(9, 9)) == 0.0, "unorm set_sample clamps to 0..1")
	var before := data.get_revision()
	data.set_sample(&"c1", Vector2i(2, 2), 0.1224)
	check(data.get_revision() == before, "a write that quantizes to the stored byte is a no-op")
	check(not data.set_channel_format(&"c1", 7), "invalid format is rejected")
	var interp := data.sample_channel(&"c1", Vector2(-3.0, 4.5))
	check(interp.coverage == 0.5 and absf(interp.value - _quantize(0.3, 1)) < 1e-6, "sample_channel interpolates dequantized values")
	# Dense paths.
	for format in FORMATS:
		var channel := StringName("d%d" % format)
		var layer := StrataLayerData.new()
		check(layer.set_channel_format(channel, format), "dense channel format %d" % format)
		var image := _rf(Vector2i(300, 70), func(x, y): return 0.5 + 0.5 * sin(x * 0.1 + y * 0.3))
		var owner := _rf(Vector2i(300, 70), func(x, y): return 1.0 if (x + y) % 3 != 0 else 0.0)
		check(layer.replace_dense(channel, Vector2i(-100, -20), image, owner), "replace_dense into format %d" % format)
		var read := layer.read_dense(channel, Vector2i(-100, -20), Vector2i(300, 70))
		var exact: bool = read.ok and read.owned_count == 14000
		var matches := true
		for y in range(70):
			for x in range(300):
				var owned := (x + y) % 3 != 0
				var got: float = read.image.get_pixel(x, y).r
				var want: float = _quantize(image.get_pixel(x, y).r, format) if owned else 0.0
				if not _near(got, want) or (read.ownership.get_pixel(x, y).r == 1.0) != owned: matches = false
		check(exact and matches, "read_dense returns quantized values and exact ownership for format %d" % format)
		var other := StrataLayerData.new()
		other.set_channel_format(channel, format)
		check(other.restore_dense(channel, Vector2i(-100, -20), read.image, read.ownership) and other.read_dense(channel, Vector2i(-100, -20), Vector2i(300, 70)).image.get_data() == read.image.get_data(), "restore_dense round-trips format %d" % format)
		var patch := _rf(Vector2i(4, 4), func(x, y): return 2.0)
		check(layer.patch_dense(channel, Vector2i(0, 0), patch), "patch_dense into format %d" % format)
		check(layer.get_sample(channel, Vector2i(1, 1)) == (1.0 if format != 0 else 2.0), "patch_dense clamps only unorm channels (%d)" % format)
		var mask := _rf(Vector2i(4, 4), func(x, y): return 1.0)
		check(layer.erase_dense(channel, Vector2i(0, 0), mask) and not layer.has_sample(channel, Vector2i(1, 1)), "erase_dense works for format %d" % format)
		check(layer.get_owned_rect(channel).size.x > 100, "owned rect works for format %d" % format)
		var neg := _rf(Vector2i(2, 2), func(x, y): return -0.5)
		layer.replace_dense(channel, Vector2i.ZERO, neg)
		check(layer.get_sample(channel, Vector2i(0, 0)) == (-0.5 if format == 0 else 0.0), "replace_dense clamps below 0 only for unorm (%d)" % format)
	# Legacy get_channels/set_channels keep float tiles.
	var legacy := StrataLayerData.new()
	legacy.set_channel_format(&"u", StrataLayerData.VALUE_UNORM8)
	legacy.set_sample(&"u", Vector2i(1, 1), 0.5)
	var tile: Dictionary = legacy.get_channels()["u"][Vector2i.ZERO]
	check(tile.values is PackedFloat32Array and _near(tile.values[257], _quantize(0.5, 1)), "get_channels exposes dequantized float tiles")
	# Memory per sample.
	var sizes := {}
	for format in FORMATS:
		var layer := StrataLayerData.new()
		layer.set_channel_format(&"m", format)
		layer.replace_dense(&"m", Vector2i.ZERO, _rf(Vector2i(512, 512), func(x, y): return 0.25))
		sizes[format] = layer.get_memory_bytes(&"m")
		check(sizes[format] == layer.get_memory_bytes() and sizes[format] == 4 * 65536 * (4 + 1 if format == 0 else 1 + format), "memory bytes for format %d" % format)
		print("MEMORY format=%d bytes_per_sample=%.3f" % [format, float(sizes[format]) / (512.0 * 512.0)])
	check(sizes[1] * 5 == sizes[0] * 2 and sizes[2] * 5 == sizes[0] * 3, "unorm8 uses 2 and unorm16 3 bytes per sample against 5 for float32")
	# The dense memory budget is byte based: 4 Gi-sample-scale thin data fits more unorm tiles.
	var thin := StrataLayerData.new()
	thin.set_channel_format(&"t", StrataLayerData.VALUE_UNORM8)
	check(thin.replace_dense(&"t", Vector2i.ZERO, _rf(Vector2i(1, 420000), func(x, y): return 0.5)), "unorm8 fits 1641 thin tiles that float32 rejects")

func _run_serialization_v2_checks() -> void:
	var data := StrataLayerData.new()
	_fill_formats(data)
	data.set_channel_format(&"empty_unorm", StrataLayerData.VALUE_UNORM16)
	var snap := data.snapshot()
	check(snap.format_version == 2 and snap.channels["c1"].format == 1 and snap.channels["c2"].format == 2 and snap.channels["c0"].format == 0, "v2 snapshot carries per-channel formats")
	var t0: Dictionary = snap.channels["c0"].tiles[Vector2i(0, 0)]
	var t1: Dictionary = snap.channels["c1"].tiles[Vector2i(0, 0)]
	var t2: Dictionary = snap.channels["c2"].tiles[Vector2i(0, 0)]
	check(t0.values is PackedFloat32Array and t0.values.size() == 65536, "float32 tiles stay PackedFloat32Array")
	check(t1.values is PackedByteArray and t1.values.size() == 65536 and t2.values is PackedByteArray and t2.values.size() == 131072, "unorm tiles use 1 and 2 bytes per sample")
	check(snap.channels["empty_unorm"].format == 2 and snap.channels["empty_unorm"].tiles.is_empty(), "an empty channel keeps its declared format")
	var again := StrataLayerData.new()
	again.restore(snap)
	check(again.snapshot() == snap and again.get_channel_format(&"c2") == 2 and again.get_channel_format(&"empty_unorm") == 2, "v2 snapshot round-trips exactly")
	for format in FORMATS:
		var channel := StringName("c%d" % format)
		check(again.get_sample(channel, Vector2i(2, 2)) == data.get_sample(channel, Vector2i(2, 2)), "v2 values survive restore for format %d" % format)
	# Resource save/load through serialized_data (binary and text).
	for path in ["user://strata_v2.res", "user://strata_v2.tres"]:
		check(ResourceSaver.save(data, path) == OK, "saves v2 resource " + path)
		var loaded = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		check(loaded != null and loaded.snapshot() == snap, "v2 resource round-trips byte exact " + path)
	# Tiles with no owned samples are dropped.
	var erase := StrataLayerData.new()
	erase.set_channel_format(&"e", StrataLayerData.VALUE_UNORM8)
	erase.set_sample(&"e", Vector2i(1000, 1000), 0.5)
	erase.erase_sample(&"e", Vector2i(1000, 1000))
	check(erase.snapshot().channels["e"].tiles.is_empty(), "tiles without owned samples are dropped")
	var hollow := snap.duplicate(true)
	hollow.channels["c1"].tiles[Vector2i(50, 50)] = {"values": PackedByteArray(), "ownership": PackedByteArray()}
	hollow.channels["c1"].tiles[Vector2i(50, 50)].values.resize(65536)
	hollow.channels["c1"].tiles[Vector2i(50, 50)].ownership.resize(65536)
	var dropped := StrataLayerData.new()
	dropped.restore(hollow)
	check(not dropped.snapshot().channels["c1"].tiles.has(Vector2i(50, 50)), "restore drops all-unowned tiles")
	# Bad v2 data is rejected atomically.
	var good := again.snapshot()
	var broken := good.duplicate(true)
	broken.channels["c1"].tiles[Vector2i(0, 0)].values = PackedByteArray([1, 2, 3])
	again.restore(broken)
	check(again.snapshot() == good, "wrong unorm byte count rejects the snapshot atomically")
	broken = good.duplicate(true)
	broken.channels["c1"].format = 9
	again.restore(broken)
	check(again.snapshot() == good, "unknown format rejects the snapshot atomically")
	# Version 1 dictionary built by hand: float tiles directly under the channel.
	var values := PackedFloat32Array()
	values.resize(65536)
	var owners := PackedByteArray()
	owners.resize(65536)
	values[770] = 7.5
	owners[770] = 1
	values[5] = -2.25
	owners[5] = 1
	var v1 := {"format_version": 1, "sample_spacing": 2.0, "grid_origin": Vector2(1, 2), "channels": {"height": {Vector2i(-1, 3): {"values": values, "ownership": owners}}}}
	var old := StrataLayerData.new()
	old.set_channel_format(&"height", StrataLayerData.VALUE_UNORM8)
	old.set_sample(&"stale", Vector2i.ZERO, 1.0)
	old.restore(v1)
	check(old.get_channel_format(&"height") == StrataLayerData.VALUE_FLOAT32 and old.sample_spacing == 2.0 and old.grid_origin == Vector2(1, 2), "v1 restore treats every channel as float32 and resets formats")
	check(old.get_sample(&"height", Vector2i(-256 + 2, 768 + 3)) == 7.5 and old.get_sample(&"height", Vector2i(-256 + 5, 768)) == -2.25 and not old.has_sample(&"stale", Vector2i.ZERO), "v1 values restore exactly")
	var upgraded := old.snapshot()
	check(upgraded.format_version == 2 and upgraded.channels["height"].format == 0, "a restored v1 snapshot re-serializes as v2")
	var back := StrataLayerData.new()
	back.restore(upgraded)
	check(back.snapshot() == upgraded, "v1 -> v2 round-trip is stable")
	# The committed island resources still load.
	var island := ["res://island/terrain/rough_base.res", "res://island/terrain/manual_fine.res"]
	for path in island:
		if ResourceLoader.exists(path):
			var res = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
			check(res != null, "committed resource loads: " + path)

func _unit_images(count: int, size: Vector2i, seed_value: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var images: Array = []
	for i in range(count):
		var image := Image.create(size.x, size.y, false, Image.FORMAT_RF)
		for y in range(size.y):
			for x in range(size.x):
				var value := rng.randf()
				if value < 0.3: value = 0.0
				image.set_pixel(x, y, Color(value, 0, 0, 1))
		images.append(image)
	return images

func _run_pack_checks() -> void:
	var images := _unit_images(6, Vector2i(97, 61), 3)
	var f := StrataLayerData.pack_material_weights_sparse(images)
	var b := StrataLayerData.pack_material_weights_sparse(images, Image.FORMAT_RGBA8)
	check(f.ok and b.ok and f.weights.get_format() == Image.FORMAT_RGBAF and b.weights.get_format() == Image.FORMAT_RGBA8, "weights_format selects RGBAF (default) or RGBA8")
	check(f.ids.get_data() == b.ids.get_data(), "IDs do not depend on the weights format")
	var worst := 0.0
	var sum_ok := true
	for y in range(61):
		for x in range(97):
			var wf: Color = f.weights.get_pixel(x, y)
			var wb: Color = b.weights.get_pixel(x, y)
			var total: int = wb.r8 + wb.g8 + wb.b8 + wb.a8
			var assigned: bool = wf.r + wf.g + wf.b + wf.a > 0.0
			if assigned and total != 255: sum_ok = false
			if not assigned and total != 0: sum_ok = false
			for slot in range(4):
				worst = maxf(worst, absf(wb[slot] - wf[slot]))
	check(sum_ok, "RGBA8 weights sum to 255 on assigned texels and 0 on unassigned")
	check(worst <= 1.0 / 255.0 + 1e-6, "RGBA8 weights match RGBAF within 1/255 (worst %f)" % (worst * 255.0))
	var strict := StrataLayerData.pack_material_weights(_unit_images(3, Vector2i(8, 8), 4).map(func(i): i.fill(Color(0.2, 0, 0, 1)); return i), Image.FORMAT_RGBA8)
	check(strict.ok and strict.weights.get_pixel(0, 0).r8 + strict.weights.get_pixel(0, 0).g8 + strict.weights.get_pixel(0, 0).b8 == 255, "dense pack returns RGBA8 as well")
	check(not StrataLayerData.pack_material_weights(images, Image.FORMAT_RGBAH).ok, "other weights formats are rejected")
	# Larger than the old 1025 cap.
	var big := _unit_images(2, Vector2i(1500, 1500), 5)
	for image in big: image.fill(Color(0.5, 0, 0, 1))
	big[1].set_pixel(7, 7, Color(0.5, 0, 0, 1))
	var packed := StrataLayerData.pack_material_weights(big)
	check(packed.ok and packed.ids.get_size() == Vector2i(1500, 1500) and packed.samples == 2250000, "a 1500x1500 pack succeeds")
	check(packed.weights.get_pixel(1499, 1499).r == 0.5, "large pack weights are normalized")
	var wide := StrataLayerData.pack_material_weights([Image.create(5000, 3, false, Image.FORMAT_RF)])
	check(not wide.ok, "an all-zero dense pack still fails")
	check(StrataLayerData.pack_material_weights_sparse([Image.create(5000, 3, false, Image.FORMAT_RF)]).ok, "wide sparse pack passes the removed side cap")
	# prepare_control_maps with RGBA8 weights.
	var ids := Image.create(4, 1, false, Image.FORMAT_RGBA8)
	ids.fill(Color8(0, 1, 2, 3))
	var weights := Image.create(4, 1, false, Image.FORMAT_RGBA8)
	weights.set_pixel(0, 0, Color8(100, 100, 100, 100))
	weights.set_pixel(1, 0, Color8(255, 0, 0, 0))
	weights.set_pixel(2, 0, Color8(0, 0, 0, 0))
	weights.set_pixel(3, 0, Color8(10, 20, 30, 0))
	var prepared := StrataLayerData.prepare_control_maps(ids, weights, 4)
	check(prepared.ok and prepared.weights.get_format() == Image.FORMAT_RGBA8, "RGBA8 weights are accepted and returned as RGBA8")
	var sums := []
	for x in range(4):
		var p: Color = prepared.weights.get_pixel(x, 0)
		sums.append(p.r8 + p.g8 + p.b8 + p.a8)
	check(sums == [255, 255, 0, 255], "prepare_control_maps renormalizes bytes to 255 and keeps zero texels: %s" % str(sums))
	check(prepared.weights.get_pixel(1, 0).r8 == 255 and prepared.weights.get_pixel(3, 0).g8 == 85, "exact byte renormalization (10,20,30 -> 43,85,127)")
	check(not StrataLayerData.prepare_control_maps(ids, weights, 3).ok, "IDs beyond the material count still fail for RGBA8 weights")
	var float_weights := Image.create(4, 1, false, Image.FORMAT_RGBAF)
	float_weights.fill(Color(1, 1, 0, 0))
	var float_prepared := StrataLayerData.prepare_control_maps(ids, float_weights, 4)
	check(float_prepared.ok and float_prepared.weights.get_format() == Image.FORMAT_RGBAF and float_prepared.weights.get_pixel(0, 0).r == 0.5, "RGBAF weights still return RGBAF")
