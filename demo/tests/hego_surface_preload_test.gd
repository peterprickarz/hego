## Integration test: requires a licensed Houdini Engine installation and rebuilt extension.
## Starts its own named-pipe server; it never attaches to an editor's Session Sync.
extends SceneTree

var failures := 0

func check(condition: bool, message: String) -> void:
	print("  %s %s" % ["ok" if condition else "FAIL", message])
	if not condition:
		failures += 1

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

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var api := HEGoAPI.get_singleton()
	if not api.start_session(HEGoAPI.SESSION_NAMED_PIPE, "hego_preload_test_%d" % OS.get_process_id()):
		push_error("Could not start the test's Houdini session")
		quit(1)
		return
	var surface_asset := await make_geometry('int a=addpoint(0,{0,0,0}); int b=addpoint(0,{1,0,0}); int c=addpoint(0,{0,1,0}); int p=addprim(0,"poly",a,b,c); setprimattrib(0,"group_id",p,7); setprimattrib(0,"late",p,9);')
	if surface_asset == null:
		api.stop_session()
		quit(1)
		return
	api.clear_completed_task_history()
	var surfaces: HEGoSurfaceOutput = await task_result(surface_asset.get_surface_output([], ["group_id"]))
	# A barrier makes any erroneously queued nested preload visible in history.
	await task_result(surface_asset.get_input_names())
	var nested_preload := false
	for task: HEGoTask in api.get_completed_task_history():
		nested_preload = nested_preload or task.get_description() == "load_attributes"
	check(not nested_preload, "output preloads inline without submitting a nested task")
	check(surfaces != null and surfaces.is_valid(), "surface output is valid")
	if surfaces != null and surfaces.is_valid():
		check(surfaces.has_attribute("late"), "attribute names are available without loading values")
		check(surfaces.get_attribute("group_id") == [7], "preload is ready when the output task completes")
		check(surfaces.split_by("group_id").has(7), "preloaded output can be split immediately")
		check(surfaces.get_attribute("late").is_empty(), "unloaded getter does not fetch through HAPI")
		var loading := surfaces.load_attributes(["late"])
		var reads_ok := true
		for i in range(1000):
			reads_ok = reads_ok and surfaces.get_attribute_names().has("group_id") and surfaces.get_attribute("group_id") == [7]
		check(reads_ok, "cached reads during preload")
		await task_result(loading)
		check(surfaces.get_attribute("late") == [9], "explicit loading makes the attribute available")
	var point_asset := await make_geometry('int p=addpoint(0,{1,2,3}); setpointattrib(0,"weight",p,2.0);')
	if point_asset == null:
		api.stop_session()
		quit(1)
		return
	var points: HEGoPointOutput = await task_result(point_asset.get_point_output())
	check(points != null and points.is_valid(), "point output is valid")
	if points != null and points.is_valid():
		check(points.select_all().get_points().has("P"), "point selections always include P without explicit preloads")
		check(points.has_attribute("weight"), "point attribute names are preloaded")
		check(points.get_attribute("weight").is_empty(), "point getters also avoid lazy HAPI reads")
		await task_result(points.load_attributes(["weight"]))
		check(points.get_attribute("weight") == [2.0], "point loading remains supported")
	api.stop_session()
	if surfaces != null and surfaces.is_valid():
		check(surfaces.get_attribute("group_id") == [7] and surfaces.has_attribute("late"), "published cache can be read after its session closes")
	print("preload integration failures: ", failures)
	quit(1 if failures else 0)
