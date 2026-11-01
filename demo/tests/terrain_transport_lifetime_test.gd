extends SceneTree
## Requires both extensions but never starts or uses a Houdini session.

var failures := 0
func _initialize() -> void: _run.call_deferred()
func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _remove_host(host: Node) -> void:
	root.remove_child(host)

func _run() -> void:
	check(not HEGoAPI.get_singleton().is_session_active(), "Lifetime test must not start a Houdini session")
	var host := Node3D.new(); root.add_child(host)
	var pending := HEGoTask.new()
	_remove_host.call_deferred(host)
	var removed := await HEGoNodeUtil.checked_task(host, pending)
	check(not removed.ok and removed.message.contains("removed"), "Pending task rejects when its host leaves the scene tree")
	host.free()
	var gone := Node3D.new(); root.add_child(gone)
	gone.queue_free()
	var deleted := await HEGoNodeUtil.checked_task(gone, HEGoTask.new())
	check(not deleted.ok, "Pending task safely rejects a deleted host")
	var asset := HEGoAssetNode.new()
	var source := HEGoAssetNode.new()
	check(asset.set_transform(Transform3D.IDENTITY).get_status() == HEGoTask.FAILED, "Uninstantiated transform returns a failed task")
	check(asset.connect_input(null, 0).get_status() == HEGoTask.FAILED, "Null connection source returns a failed task")
	check(asset.connect_input(source, 0).get_status() == HEGoTask.FAILED, "Uninstantiated connection returns a failed task")
	var merge := HEGoMergeNode.new()
	check(merge.connect_inputs([null]).get_status() == HEGoTask.FAILED, "Invalid merge reference cannot become a successful cached task")
	check(not HEGoAPI.get_singleton().is_session_active(), "No-session failure checks leave Houdini stopped")
	print("TERRAIN_TRANSPORT_LIFETIME_TEST: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(0 if failures == 0 else 1)
