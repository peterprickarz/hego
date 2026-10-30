extends SceneTree
## Declared HAPI parameter storage, JSON numbers, and fail-closed batches.
## Uses only private nodes/session. Optional --island-hda=PATH adds the original
## detail_stage/freeze_frame regression using the generated island HDA.

var failures: Array[String] = []
var api: HEGoAPI

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error(message)

func wait_task(task: HEGoTask, expect_success: bool = true) -> bool:
	if task == null:
		check(false, "Native parameter API returned no task")
		return false
	while task.get_status() < HEGoTask.COMPLETED:
		await process_frame
	var ok := task.get_status() == HEGoTask.COMPLETED if expect_success else task.get_status() == HEGoTask.FAILED
	check(ok, "Unexpected task status %s: %s" % [task.get_status(), task.get_error_message()])
	if not expect_success: check(not task.get_error_message().is_empty(), "Rejected parameter task includes an actionable error")
	return ok

func collect(value: Variant, out: Dictionary) -> void:
	if value is Dictionary:
		if value.has("name") and value.has("values"): out[String(value.name)] = value["values"].duplicate()
		for child in value.values(): collect(child, out)
	elif value is Array:
		for child in value: collect(child, out)

func read(asset: HEGoAssetNode) -> Dictionary:
	var task := asset.get_parms_dict()
	if not await wait_task(task): return {}
	var out := {}
	collect(task.get_result(), out)
	return out

func finish() -> void:
	if api != null and api.is_session_active(): api.stop_session()
	if failures.is_empty(): print("HEGO_PARAMETER_NATIVE_PASS")
	else: push_error("Native parameter regression failures: " + str(failures))
	quit(0 if failures.is_empty() else 1)

func run() -> void:
	var island_hda := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--island-hda="): island_hda = argument.trim_prefix("--island-hda=")
	if not island_hda.is_empty():
		check(FileAccess.file_exists(island_hda), "Optional island HDA exists")
		OS.set_environment("HOUDINI_OTLSCAN_PATH", island_hda.get_base_dir() + ":&")
	api = HEGoAPI.get_singleton()
	if not api.start_session(HEGoAPI.SESSION_NAMED_PIPE, "hego_parameter_%d" % OS.get_process_id()):
		check(false, "Private Houdini parameter session started"); finish(); return
	var asset := HEGoAssetNode.new(); asset.op_name = "Sop/xform"
	if not await wait_task(asset.instantiate()): finish(); return
	var mixed: Dictionary = JSON.parse_string('{"xOrd":2.0,"scale":3}')
	mixed.t = Vector3(1.25, -2.5, 3.75)
	if not await wait_task(asset.set_parms_batch(mixed)): finish(); return
	var values := await read(asset)
	check(values.get("xOrd") == [2] and values.get("scale") == [3.0] and values.get("t") == [1.25, -2.5, 3.75], "JSON float-to-int and integer-to-float reach the declared parameters without changing neighboring storage")
	check(await wait_task(asset.set_parm("t", Vector3i(4, 5, 6))), "Integer vectors safely convert to HAPI float tuples")
	check((await read(asset)).get("t") == [4.0, 5.0, 6.0], "All vector components round-trip")
	var before := await read(asset)
	for invalid in [
		{"scale": 7.0, "missing_parameter": 2.0},
		{"scale": 7.0, "xOrd": 1.5},
		{"scale": 7.0, "xOrd": 2147483648.0},
		{"scale": INF}, {"scale": NAN}, {"scale": 1e100}, {"scale": 1e-100},
		{"scale": 16777217}, {"t": Vector2.ONE}, {"t": 2.0},
		{"t": Vector3(NAN, 0, 0)}, {"t": [1.0, 2.0, 3.0]},
		{"xOrd": "2"}, {"scale": 7.0, 9: 1.0},
	]:
		await wait_task(asset.set_parms_batch(invalid), false)
		check((await read(asset)) == before, "Rejected batch leaves all parameter values unchanged: " + str(invalid))
	await wait_task(asset.set_parm("missing_parameter", 1), false)
	await wait_task(asset.set_parm("xOrd", 0.25), false)
	check((await read(asset)) == before, "Invalid scalar setter also leaves parameter storage unchanged")
	var pending: Dictionary = {"scale": 5}
	var captured := asset.set_parms_batch(pending)
	pending.scale = 9
	await wait_task(captured)
	check((await read(asset)).get("scale") == [5.0], "Async batch captures caller values independently before enqueue")
	var wrangle := HEGoAssetNode.new(); wrangle.op_name = "Sop/attribwrangle"
	if await wait_task(wrangle.instantiate()):
		await wait_task(wrangle.set_parms_batch({"class": 2.0, "snippet": "f@test = 17;"}))
		values = await read(wrangle)
		check(values.get("class") == [2] and values.get("snippet") == ["f@test = 17;"], "Integer menu and string UI semantics remain compatible")
	if not island_hda.is_empty():
		var island := HEGoAssetNode.new(); island.op_name = "Sop/hego_island_erosion::1.0"
		if await wait_task(island.instantiate()):
			var request: Dictionary = JSON.parse_string('{"detail_stage":1.0,"freeze_frame":16.0,"feature_size":3}')
			await wait_task(island.set_parms_batch(request))
			values = await read(island)
			check(values.get("detail_stage") == [1] and values.get("freeze_frame") == [16] and values.get("feature_size") == [3.0], "Original JSON detail_stage/freeze_frame requests change exactly their named HDA parameters")
	finish()
