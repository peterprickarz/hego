extends SceneTree
## Scoped controller profile; same 32-cell, 8 m, ratio1.8,512-patch quality.
func _initialize(): call_deferred("run")
func run():
	create_timer(90.0).timeout.connect(func(): push_error("Renderer profile watchdog"); quit(1))
	change_scene_to_file("res://island/island_showcase.tscn")
	while current_scene == null: await process_frame
	var level = current_scene
	while not level.ready_for_capture: await process_frame
	level.camera.input_enabled = false
	var report := {}
	for mode in ["fast", "teleport"]:
		var samples := {"total": [], "select": [], "mesh_prepare": [], "patch_apply": [], "patches": []}
		for frame in range(210):
			var point: Vector2
			if mode == "fast": point = Vector2(-1700.0, 1300.0).lerp(Vector2(1700.0, -1300.0), float(frame) / 210.0)
			else: point = [Vector2(-1800,-1800),Vector2(1800,-1800),Vector2(1800,1800),Vector2(-1800,1800),Vector2.ZERO,Vector2(900,-400)][frame % 6]
			level.camera.global_position = level.terrain.to_global(Vector3(point.x, level.renderer.sample_render_height(point) + 3.0, point.y))
			level.renderer.force_lod_update()
			var stats: Dictionary = level.renderer.get_stats()
			if frame >= 30:
				for pair in [["total","last_lod_cpu_ms"],["select","last_lod_select_cpu_ms"],["mesh_prepare","last_mesh_prepare_cpu_ms"],["patch_apply","last_patch_apply_cpu_ms"],["patches","patches"]]: samples[pair[0]].append(float(stats.get(pair[1],0)))
			await process_frame
			await RenderingServer.frame_post_draw
		var summary := {}
		for key in samples:
			samples[key].sort(); summary[key] = {"p50":samples[key][90],"p99":samples[key][178],"max":samples[key][-1]}
		report[mode] = summary
	print("ISLAND_RENDERER_PROFILE ",JSON.stringify(report))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--report="):
			var file := FileAccess.open(arg.trim_prefix("--report="),FileAccess.WRITE); file.store_string(JSON.stringify(report,"  ")); file.close()
	quit()
