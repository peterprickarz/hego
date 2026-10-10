## Driven by scripts/test_named_pipe_sessions.py using disposable HAPI servers.
extends SceneTree

var state_dir: String
var pipe_name: String

func task_result(task: HEGoTask) -> Variant:
	while task.get_status() < HEGoTask.COMPLETED:
		await process_frame
	assert(task.get_status() == HEGoTask.COMPLETED, task.get_error_message())
	return task.get_result()

func write_state(name: String, state: Dictionary) -> void:
	var file := FileAccess.open(state_dir.path_join(name + ".json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(state))
	file.close()

func wait_flag(name: String) -> void:
	while not FileAccess.file_exists(state_dir.path_join(name)):
		await process_frame

func connect_and_cook() -> Dictionary:
	var api := HEGoAPI.get_singleton()
	if not api.start_session(HEGoAPI.SESSION_NAMED_PIPE, pipe_name):
		return {"connected": false}
	var asset := HEGoAssetNode.new()
	asset.op_name = "Sop/box"
	await task_result(asset.instantiate())
	await task_result(asset.cook())
	var output: HEGoSurfaceOutput = await task_result(asset.get_surface_output())
	return {"connected": true, "node_id": asset.get_id(), "geometry": output != null and output.is_valid()}

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		push_error("Run via scripts/test_named_pipe_sessions.py")
		quit(2)
		return
	pipe_name = args[0]
	state_dir = args[1]
	call_deferred("run")

func run() -> void:
	write_state("connected", await connect_and_cook())
	await wait_flag("disconnect")
	HEGoAPI.get_singleton().stop_session()
	write_state("disconnected", {"active": HEGoAPI.get_singleton().is_session_active()})
	await wait_flag("reconnect")
	write_state("reconnected", await connect_and_cook())
	await wait_flag("finish")
	HEGoAPI.get_singleton().stop_session()
	quit()
