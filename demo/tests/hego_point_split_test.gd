## Integration test: requires a licensed Houdini Engine installation and rebuilt extension.
## Starts its own named-pipe server; it never attaches to an editor's Session Sync.
##
## Checks split_by and filter_by on a large point output against groups built here from
## the raw attribute values: the keys, their first-seen order, the indices and their
## order in each group, nested splits, and the null-keyed group of an attribute the
## output does not have. A smaller primitive output checks the surface selections the
## same way. Times are printed as information only.
extends SceneTree

const POINT_COUNT := 250000
const CELLS := 300
const TRIANGLES := 6000

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  %s %s" % ["ok" if condition else "FAIL", message])
	if not condition:
		failures += 1


func info(message: String) -> void:
	print("  info ", message)


func task_result(task: HEGoTask) -> Variant:
	while task.get_status() < HEGoTask.COMPLETED:
		await process_frame
	check(task.get_status() == HEGoTask.COMPLETED, task.get_description())
	return task.get_result()


func make_geometry(snippet: String) -> HEGoAssetNode:
	var asset := HEGoAssetNode.new()
	asset.op_name = "Sop/attribwrangle"
	await task_result(asset.instantiate())
	if asset.get_id() < 0:
		return null
	await task_result(asset.set_parms_batch({"class": 0, "snippet": snippet}))
	await task_result(asset.cook())
	return asset


func elapsed_ms(start: int) -> float:
	return (Time.get_ticks_usec() - start) / 1000.0


## { value: [indices] } in first-seen order, from the values at [param indices].
func expected_groups(values: Array, indices: PackedInt32Array) -> Dictionary:
	var groups := {}
	for index in indices:
		var key: Variant = values[index]
		if not groups.has(key):
			groups[key] = []
		groups[key].append(index)
	return groups


func range_indices(count: int) -> PackedInt32Array:
	var indices := PackedInt32Array()
	indices.resize(count)
	for i in count:
		indices[i] = i
	return indices


## Whether a split result has exactly the expected keys, in order, with the same indices.
func same_groups(actual: Dictionary, expected: Dictionary) -> bool:
	if actual.keys() != expected.keys():
		return false
	for key in expected:
		if actual[key].get_indices() != PackedInt32Array(expected[key]):
			return false
	return true


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var api := HEGoAPI.get_singleton()
	if not api.start_session(HEGoAPI.SESSION_NAMED_PIPE, "hego_point_split_test_%d" % OS.get_process_id()):
		push_error("Could not start the test's Houdini session")
		quit(1)
		return

	# kind cycles through seven values in a scrambled first-seen order, cell takes 300
	# values spread over the points, and constant has one value for every point.
	var point_asset := await make_geometry(
			'for (int i = 0; i < %d; i++) {' % POINT_COUNT
			+ ' int p = addpoint(0, set(i, 0, 0));'
			+ ' setpointattrib(0, "kind", p, sprintf("k%d", (i * 3) % 7));'
			+ ' setpointattrib(0, "cell", p, (i * 7919) %% %d);' % CELLS
			+ ' setpointattrib(0, "constant", p, "one");'
			+ ' setpointattrib(0, "unloaded", p, i % 2); }')
	if point_asset == null:
		api.stop_session()
		quit(1)
		return
	var output: HEGoPointOutput = await task_result(point_asset.get_point_output())
	check(output != null and output.is_valid(), "point output is valid")
	if output == null or not output.is_valid():
		api.stop_session()
		quit(1)
		return
	await task_result(output.load_attributes(["kind", "cell", "constant"]))
	var count := output.get_point_count()
	check(count == POINT_COUNT, "point output holds %d points" % POINT_COUNT)
	var all := range_indices(count)
	var kinds := output.get_attribute("kind")
	var cells := output.get_attribute("cell")

	var start := Time.get_ticks_usec()
	var by_constant := output.split_by("constant")
	info("split_by, one value: %.1f ms" % elapsed_ms(start))
	check(by_constant.keys() == ["one"], "a single value gives a single group")
	check(by_constant.has("one") and by_constant["one"].get_indices() == all, "the single group holds every point in order")

	start = Time.get_ticks_usec()
	var by_cell := output.split_by("cell")
	info("split_by, %d values: %.1f ms" % [CELLS, elapsed_ms(start)])
	var expected_cells := expected_groups(cells, all)
	check(by_cell.size() == CELLS, "one group per cell value")
	check(same_groups(by_cell, expected_cells), "cell groups match in keys, key order and indices")

	var by_kind := output.split_by("kind")
	check(by_kind.keys() == ["k0", "k3", "k6", "k2", "k5", "k1", "k4"], "keys keep their first-seen order")
	check(same_groups(by_kind, expected_groups(kinds, all)), "kind groups match in keys and indices")

	# A split of a split, as the MultiMesh output splits by output name, then by mesh.
	start = Time.get_ticks_usec()
	var nested := {}
	for kind in by_kind:
		nested[kind] = by_kind[kind].split_by("cell")
	info("nested split_by, kind then cell: %.1f ms" % elapsed_ms(start))
	var nested_ok := true
	var leaf_total := 0
	for kind in nested:
		nested_ok = nested_ok and same_groups(nested[kind], expected_groups(cells, by_kind[kind].get_indices()))
		for cell in nested[kind]:
			leaf_total += nested[kind][cell].size()
	check(nested_ok, "nested groups match the groups of each outer group")
	check(leaf_total == count, "nested groups hold every point once")

	start = Time.get_ticks_usec()
	var cell_17 := output.filter_by("cell", 17)
	info("filter_by: %.1f ms" % elapsed_ms(start))
	check(cell_17.get_indices() == PackedInt32Array(expected_cells[17]), "filter_by keeps the matching points in order")
	var filtered_split := cell_17.split_by("kind")
	check(same_groups(filtered_split, expected_groups(kinds, cell_17.get_indices())), "a filtered selection splits like any other")
	check(output.filter_by("cell", CELLS).size() == 0, "filter_by with no match is empty")

	start = Time.get_ticks_usec()
	var leaf_points_ok := true
	for cell in nested["k3"]:
		var group: HEGoPointSelection = nested["k3"][cell]
		var points := group.get_points(["cell", "kind"])
		leaf_points_ok = leaf_points_ok and points["P"].size() == group.size() \
				and points["cell"].count(cell) == group.size() and points["kind"].count("k3") == group.size()
	info("get_points on %d nested groups: %.1f ms" % [nested["k3"].size(), elapsed_ms(start)])
	check(leaf_points_ok, "get_points on nested groups returns their own values")

	# An attribute the output does not have puts everything under one null key; one it
	# has but that was not loaded does the same, with a warning.
	var missing := output.split_by("no_such_attribute")
	check(missing.keys() == [null], "a missing attribute gives one null-keyed group")
	check(missing.has(null) and missing[null].get_indices() == all, "the null-keyed group holds every point in order")
	var unloaded := output.split_by("unloaded")
	check(unloaded.keys() == [null] and unloaded[null].size() == count, "an unloaded attribute gives one null-keyed group")

	# Surfaces: TRIANGLES triangles with part = (i * 5) % 4 and band = i % 3.
	var surface_asset := await make_geometry(
			'for (int i = 0; i < %d; i++) {' % TRIANGLES
			+ ' int a = addpoint(0, set(i, 0, 0)); int b = addpoint(0, set(i + 1, 0, 0)); int c = addpoint(0, set(i, 1, 0));'
			+ ' int p = addprim(0, "poly", a, b, c);'
			+ ' setprimattrib(0, "part", p, (i * 5) % 4);'
			+ ' setprimattrib(0, "band", p, i % 3); }')
	if surface_asset != null:
		var surfaces: HEGoSurfaceOutput = await task_result(surface_asset.get_surface_output([], ["part", "band"]))
		check(surfaces != null and surfaces.is_valid(), "surface output is valid")
		if surfaces != null and surfaces.is_valid():
			var prims := range_indices(surfaces.get_primitive_count())
			var parts := surfaces.get_attribute("part")
			var bands := surfaces.get_attribute("band")
			check(prims.size() == TRIANGLES, "surface output holds %d primitives" % TRIANGLES)
			var by_part := surfaces.split_by("part")
			check(by_part.keys() == [0, 1, 2, 3], "surface keys keep their first-seen order")
			check(same_groups(by_part, expected_groups(parts, prims)), "surface groups match in keys and indices")
			var nested_surfaces := true
			for part in by_part:
				nested_surfaces = nested_surfaces and same_groups(by_part[part].split_by("band"), expected_groups(bands, by_part[part].get_indices()))
			check(nested_surfaces, "nested surface groups match")
			check(surfaces.filter_by("band", 2).get_indices() == PackedInt32Array(expected_groups(bands, prims)[2]), "surface filter_by keeps the matching primitives in order")
			var surface_missing := surfaces.split_by("no_such_attribute")
			check(surface_missing.keys() == [null] and surface_missing[null].size() == TRIANGLES, "a missing primitive attribute gives one null-keyed group")
			var surface: Dictionary = by_part[1].get_surface(["band"])
			check(surface.get("band", []).size() == by_part[1].size(), "get_surface on a group returns one value per primitive")

	api.stop_session()
	print("point split failures: ", failures)
	quit(1 if failures else 0)
