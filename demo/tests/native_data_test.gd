extends SceneTree

var failures: Array[String] = []

func check(condition: bool, message: String) -> void:
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
		check(serialized_text.contains("\"format_version\": 1"), "ResourceSaver persists an explicit format version in the complete payload")
		var loaded = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		check(loaded != null, "ResourceLoader loads terrain data")
		if loaded != null:
			close_to(float(loaded.get_sample(&"weight", Vector2i(5, 6))), 0.25, "loaded resource retains saved values")
			check(loaded.get_format_version() == 1 and loaded.sample_spacing == 2.0 and loaded.grid_origin == Vector2(1.5, -2.5), "ResourceLoader retains version and nondefault native grid")
		var future_path := "user://strata_future_data_test.tres"
		var future_file := FileAccess.open(future_path, FileAccess.WRITE)
		check(future_file != null, "future-version resource fixture can be written")
		if future_file != null:
			future_file.store_string(serialized_text.replace("\"format_version\": 1", "\"format_version\": 2"))
			future_file.close()
			var future = ResourceLoader.load(future_path, "", ResourceLoader.CACHE_MODE_IGNORE)
			check(future != null and future.get_channel_names().is_empty() and future.sample_spacing == 1.0 and future.grid_origin == Vector2.ZERO and future.get_revision() == 0, "future serialized payload rejects its samples and nondefault grid atomically")

	_run_layer_composition_and_brush_checks()
	_run_native_edge_cases()
	_run_grid_and_first_touch_checks()

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
	check(saved.format_version == 1, "snapshots explicitly declare format version 1")
	source.set_sample(&"height", Vector2i(2, 3), 9.0)
	check(saved.channels["height"][Vector2i.ZERO].values[770] == 7.0, "snapshot arrays do not alias later source writes")
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
	for invalid_version in [2, 0, 1.0, null]:
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
	var tile: Dictionary = channels["height"][Vector2i.ZERO]
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
