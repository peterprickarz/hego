extends SceneTree

var failures := 0
var finished := false

func wait_for_task(host: Node, task: HEGoTask) -> void:
	var result = await HEGoNodeUtil.await_task(host, task)
	if result != null:
		failures += 1
	finished = true

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	for delete_host in [false, true]:
		var host := Node.new()
		root.add_child(host)
		var task := HEGoTask.new() # Deliberately pending; it is not submitted.
		finished = false
		wait_for_task(host, task)
		if delete_host:
			host.free()
		else:
			root.remove_child(host)
		await process_frame
		await process_frame
		if not finished or task.get_status() != HEGoTask.PENDING:
			failures += 1
		if not delete_host:
			host.free()
	print("await_task lifecycle failures: ", failures)
	quit(1 if failures else 0)
