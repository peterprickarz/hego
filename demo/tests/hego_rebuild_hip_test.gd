## Real-session regression driven by scripts/test_rebuild_hip.py, which creates
## two temporary versions of the same two-input HDA and reopens the exported HIP.
extends SceneTree

var api := HEGoAPI.get_singleton()
var failures := 0


func _initialize() -> void:
	run.call_deferred()


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


func geometry_version(host: HEGoNode3D) -> int:
	var asset := host.hego_get_asset_node()
	var output: HEGoPointOutput = await host.agent.task(asset.get_point_output(["fixture_version"]))
	if output == null or output.get_point_count() == 0:
		return -1
	return output.get_attribute("fixture_version")[0]


func parameter_labels(tab: Control) -> Array:
	var labels := []
	for label in tab.parm_vbox.find_children("*", "Label", true, false):
		labels.append(label.text)
	return labels


func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 3 or not api.start_session(HEGoAPI.SESSION_NAMED_PIPE, "rebuild_%d" % OS.get_process_id()):
		push_error("Run with scripts/test_rebuild_hip.py and a working Houdini installation")
		quit(1)
		return

	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var host := HEGoNode3D.new()
	scene.add_child(host)
	host.asset_name = "Sop/hego_test_rebuild"
	for index in 2:
		var source := MeshInstance3D.new()
		source.name = "Mesh%d" % index
		source.mesh = BoxMesh.new()
		scene.add_child(source)
		host.agent.set_input(index, source)

	await host.cook()
	check(host.hego_did_last_cook_succeed() and await geometry_version(host) == 1, "First cook reads version one")
	var panel := preload("res://addons/hego/hego_control.tscn").instantiate()
	root.add_child(panel)
	var tab := panel.get_node("TabContainer/HDA")
	await tab.set_selected_node(host)
	check("Lift" in parameter_labels(tab) and "Fine Detail" not in parameter_labels(tab), "Panel shows version one")
	var original := host.hego_get_asset_node()
	var original_id := original.get_id()
	await host.agent.task(original.set_parm("lift", 3.5))
	# Simulate a partial external HDA write, using only the runner's disposable fixture.
	var broken := FileAccess.open(args[0], FileAccess.WRITE)
	check(broken != null, "Opened the temporary fixture for the corrupt-file check")
	if broken != null:
		broken.store_string("Intentionally corrupt HEGo rebuild test fixture")
		broken.close()
	print("Expected rebuild error follows for the deliberately corrupt test HDA")
	await tab._on_recook_button_pressed(true)
	check(not host.hego_did_last_cook_succeed(), "Rebuild rejects a corrupt HDA")
	check(host.hego_get_asset_node() == original and original.get_id() == original_id, "Failed rebuild keeps the live instance")
	check(await geometry_version(host) == 1 and "Lift" in parameter_labels(tab), "The original output and parameters remain available")

	check(DirAccess.copy_absolute(args[1], args[0]) == OK, "Replaced the installed fixture on disk")
	api.clear_completed_task_history()
	await tab._on_recook_button_pressed(true)
	check(host.hego_did_last_cook_succeed(), "Rebuild completed")
	check(host.hego_get_asset_node().get_id() != original_id, "Rebuild replaced the HAPI asset")
	check("Fine Detail" in parameter_labels(tab), "Rebuild displays the new control from version two")
	var mesh_uploads := 0
	for task: HEGoTask in api.get_completed_task_history():
		if task.get_description() == "Set geo from Mesh" and task.get_status() == HEGoTask.COMPLETED:
			mesh_uploads += 1
	check(mesh_uploads == 2, "Rebuild uploaded both unchanged meshes")
	check(await geometry_version(host) == 2, "Rebuilt asset cooks the updated definition")

	var path := args[2].path_join("saved session." + api.get_hip_file_extension())
	var saved: Variant = await host.agent.task(api.save_hip_file(path))
	check(saved is String and saved == path and FileAccess.file_exists(path), "Saved the current session to the selected path")
	api.stop_session()
	api.clear_completed_task_history()
	panel.free()
	current_scene = null
	scene.free()
	if failures == 0:
		print("HEGO_REBUILD_HIP_PASS")
	quit(1 if failures else 0)
