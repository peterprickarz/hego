## CopiaStore3D fly-through measurement (not a pass/fail test; needs a real renderer).
##
## Writes about a million synthetic points over a 1 km square with 40 objects (13 drawn as single
## instances with impostors, 27 as MultiMesh batches of 16 m with ranges of 30 to 90 m), then flies
## a camera across at 5 m/s and at 20 m/s for 20 s each and prints, per speed: median, p99 and
## worst frame time, groups created and freed per second, the worst main-thread step of the
## store, and the time from "section requested" to "group ready" (median and worst). Scratch data
## goes to user:// and is deleted afterwards. Run windowed with vsync off:
##
##   godot-4.7.2 --path demo --audio-driver Dummy --disable-vsync --resolution 1280x720 \
##       --script res://tests/copia_store_timing.gd
##
## Then flies back at 20 m/s (COPIA_STORE_PHASES: each store phase's median, p99 and worst). Every
## fly runs the store's frame itself with each phase timed (see [method fly]) and prints its five
## worst frames with what happened in them (COPIA_STORE_WORST: store phases, groups created,
## render CPU and GPU time, pipelines compiled) and the pipelines compiled during it
## (COPIA_STORE_PIPELINES, from RenderingServer.get_rendering_info). Prints COPIA_STORE_SETUP,
## COPIA_STORE_LOAD, COPIA_STORE_FLY, COPIA_STORE_WORST, COPIA_STORE_PIPELINES and
## COPIA_STORE_PHASES lines, then quits. Run time: about a minute and a half.
extends SceneTree

const EXTENSION := "res://addons/copia/bin/copia.gdextension"
const ObjectScript := preload("res://addons/copia/copia_object.gd")
const RenderScript := preload("res://addons/copia/copia_render_settings.gd")
const StoreScript := preload("res://addons/copia/copia_store_3d.gd")
const SourceScript := preload("res://addons/copia/copia_source_3d.gd")
const SIDE := 1000.0
const POINTS := 1000000
const SINGLE_OBJECTS := 13
const BATCH_OBJECTS := 27
const SINGLE_POINTS := 30000  # of POINTS, shared by the single-instance objects
const FLY_SECONDS := 20.0
const HEIGHT := 2.0
const PIPELINE_KINDS := ["canvas", "mesh", "surface", "draw", "specialization"]

var scratch := "user://copia_store_timing_%d" % OS.get_process_id()
var rng := RandomNumberGenerator.new()
var store: Node3D
var camera: Camera3D
var paths := PackedStringArray()
var created := 0
var freed := 0
var waiting := {}  # drawer group id -> requested usec
var latencies: Array[int] = []


func _initialize() -> void:
	call_deferred("run")


func remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for directory in DirAccess.get_directories_at(path):
		remove_tree(path.path_join(directory))
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)


func percentile(values: Array, fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[mini(int(sorted.size() * fraction), sorted.size() - 1)])


func make_objects() -> void:
	DirAccess.make_dir_recursive_absolute(scratch.path_join("objects"))
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	for i in SINGLE_OBJECTS + BATCH_OBJECTS:
		var object := ObjectScript.new()
		object.render = RenderScript.new()
		if i < SINGLE_OBJECTS:
			var trunk := CylinderMesh.new()
			trunk.radial_segments = 8
			trunk.rings = 1
			trunk.height = 8.0 + i
			trunk.top_radius = 0.3
			trunk.bottom_radius = 0.5
			trunk.material = material
			object.mesh = trunk
			var card := QuadMesh.new()
			card.size = Vector2(3, 8 + i)
			card.material = material
			object.impostor_mesh = card
			object.render.draw_mode = RenderScript.DrawMode.INSTANCE
			object.render.visibility_range_end = 150.0
			object.render.visibility_range_margin = 5.0
			object.render.impostor_range_end = 0.0
		else:
			var j := i - SINGLE_OBJECTS
			var mesh: PrimitiveMesh
			if j % 2 == 0:
				var box := BoxMesh.new()
				box.size = Vector3(0.4, 0.6, 0.4)
				mesh = box
			else:
				var sphere := SphereMesh.new()
				sphere.radial_segments = 8
				sphere.rings = 4
				sphere.radius = 0.3
				sphere.height = 0.6
				mesh = sphere
			mesh.material = material
			object.mesh = mesh
			object.render.batch_size = 16.0
			object.render.visibility_range_end = 30.0 + 60.0 * j / (BATCH_OBJECTS - 1)
			object.default_color = Color.from_hsv(float(j) / BATCH_OBJECTS, 0.6, 0.8)
		var path := scratch.path_join("objects/object_%02d.tres" % i)
		ResourceSaver.save(object, path)
		paths.append(path)
	ObjectScript.clear_cache()


func make_points() -> Dictionary:
	var transform := PackedFloat32Array()
	transform.resize(POINTS * 12)
	var object := PackedInt32Array()
	object.resize(POINTS)
	var keep := PackedFloat32Array()
	keep.resize(POINTS)
	for p in POINTS:
		var index := rng.randi_range(0, SINGLE_OBJECTS - 1) if p < SINGLE_POINTS else SINGLE_OBJECTS + rng.randi_range(0, BATCH_OBJECTS - 1)
		var angle := rng.randf() * TAU
		var scale := rng.randf_range(0.7, 1.4)
		var o := p * 12
		transform[o] = cos(angle) * scale
		transform[o + 2] = -sin(angle) * scale
		transform[o + 4] = scale
		transform[o + 6] = sin(angle) * scale
		transform[o + 8] = cos(angle) * scale
		transform[o + 9] = rng.randf() * SIDE
		transform[o + 11] = rng.randf() * SIDE
		object[p] = index
		keep[p] = rng.randf()
	return {"transform": transform, "object": object, "object_paths": paths, "keep": keep}


func build_scene() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var world_root := Node3D.new()
	root.add_child(world_root)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.5, 0.6, 0.7)
	world_root.add_child(environment)
	var light := DirectionalLight3D.new()
	light.shadow_enabled = true
	light.directional_shadow_max_distance = 150.0
	world_root.add_child(light)
	light.look_at_from_position(Vector3.ZERO, Vector3(-1, -2, -0.5), Vector3.UP)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(SIDE, SIDE)
	ground.mesh = plane
	ground.position = Vector3(SIDE / 2, 0, SIDE / 2)
	world_root.add_child(ground)
	camera = Camera3D.new()
	camera.name = "FlyCamera"
	camera.far = 3000.0
	world_root.add_child(camera)
	camera.make_current()


func on_added(info: Dictionary) -> void:
	created += 1
	if info.kind != "collider":
		waiting[info.group] = info.requested_usec


func on_removed(_info: Dictionary) -> void:
	freed += 1


func poll_ready() -> void:
	var drawer: Object = store.get_drawer()
	var now := Time.get_ticks_usec()
	for id in waiting.keys():
		var info: Dictionary = drawer.get_group_info(id)
		if info.is_empty():
			waiting.erase(id)
		elif info.ready:
			latencies.append(now - waiting[id])
			waiting.erase(id)


func place_camera(x: float) -> void:
	camera.look_at_from_position(Vector3(x, HEIGHT, SIDE / 2), Vector3(x + 50.0, 0.0, SIDE / 2 + 10.0), Vector3.UP)


## The store's frame as CopiaStore3D._process runs it, with each phase timed (microseconds):
## draining worker results (with the task, replacement and build checks), the streaming update
## (0 when none ran), the colliders' step, the drawer's step, the shadow and settled checks.
## Also what the frame did: groups created, worker results waiting, reads started.
func store_frame(delta: float) -> Dictionary:
	var before_tasks: int = store._tasks.size()
	var results: int = store._loader.results.size()
	var t0 := Time.get_ticks_usec()
	store._collect_tasks()
	store._drain_results()
	store._check_replacements()
	store._poll_build(delta)
	var t1 := Time.get_ticks_usec()
	var updated := false
	if SourceScript._revision != store._source_revision:
		store._update_needed = true
	store._timer += delta
	if store._timer >= store.update_interval or store._update_needed:
		store._timer = 0.0
		store.update_streaming_all()
		updated = true
	var t2 := Time.get_ticks_usec()
	var budget: int = store.frame_budget_usec
	var spent := int(store.get_colliders().step(maxi(budget / 2, 1)).usec)
	var t3 := Time.get_ticks_usec()
	var step: Dictionary = store.get_drawer().step(maxi(budget - spent, 1))
	var t4 := Time.get_ticks_usec()
	store._update_shadows()
	store._update_settled()
	var t5 := Time.get_ticks_usec()
	return {"drain": t1 - t0, "update": t2 - t1 if updated else 0, "updated": updated, "colliders_step": t3 - t2, "drawer_step": t4 - t3,
			"shadows_settled": t5 - t4, "created": step.created, "results": results, "reads_started": maxi(store._tasks.size() - before_tasks, 0)}


## Cumulative pipeline compilations by kind, as RenderingServer.get_rendering_info reports them
## (empty when the engine has no such counters).
func pipeline_counts() -> Dictionary:
	var result := {}
	for kind in PIPELINE_KINDS:
		var constant: String = "RENDERING_INFO_PIPELINE_COMPILATIONS_" + kind.to_upper()
		if ClassDB.class_has_integer_constant("RenderingServer", constant):
			result[kind] = RenderingServer.get_rendering_info(ClassDB.class_get_integer_constant("RenderingServer", constant))
	return result


## A fly at [param speed] with the store's own processing off and its frame run here by
## [method store_frame], each phase timed. Prints COPIA_STORE_FLY (or, with [param label]
## "phases", COPIA_STORE_PHASES: the median, p99 and worst of each phase), COPIA_STORE_WORST (the
## five worst frames with what happened in them) and COPIA_STORE_PIPELINES (the pipelines compiled
## during the fly). A frame interval (from one process frame to the next) holds that frame's store
## work and the rendering of the frame; its line gives both, and the render time and pipeline
## compilations measured at its end.
func fly(speed: float, start_x: float, label := "fly") -> float:
	created = 0
	freed = 0
	latencies.clear()
	store.set_process(false)
	var viewport_rid := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	var names := ["drain", "update", "colliders_step", "drawer_step", "shadows_settled"]
	var times := {}
	for name in names:
		times[name] = []
	var frames: Array[int] = []
	var records := []
	var worst_step := 0
	var x := start_x
	var started := Time.get_ticks_usec()
	var last := started
	var pipelines := pipeline_counts()
	var previous: Dictionary = {}
	while Time.get_ticks_usec() - started < int(FLY_SECONDS * 1e6):
		await process_frame
		var now := Time.get_ticks_usec()
		var interval := now - last
		frames.append(interval)
		var delta := interval / 1e6
		var now_pipelines := pipeline_counts()
		var compiled := {}
		for kind in now_pipelines:
			if now_pipelines[kind] != pipelines.get(kind, 0):
				compiled[kind] = now_pipelines[kind] - pipelines.get(kind, 0)
		pipelines = now_pipelines
		var render_cpu := RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid) + RenderingServer.get_frame_setup_time_cpu()
		var render_gpu := RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
		# The interval that ended now holds the previous frame's store work and its rendering.
		records.append({"t": (now - started) / 1e6, "x": x, "interval": interval, "store": previous, "render_cpu_ms": render_cpu,
				"render_gpu_ms": render_gpu, "compiled": compiled, "groups": store.get_stats().groups})
		x += speed * delta
		last = now
		place_camera(x)
		poll_ready()
		var frame := store_frame(delta)
		for name in names:
			if name != "update" or frame.updated:
				times[name].append(frame[name])
		worst_step = maxi(worst_step, frame.colliders_step + frame.drawer_step)
		previous = frame
	var seconds := (Time.get_ticks_usec() - started) / 1e6
	store.set_process(true)
	var stats: Dictionary = store.get_stats()
	if label == "phases":
		var fields := []
		for name in names:
			fields.append("%s_us=%d/%d/%d" % [name, percentile(times[name], 0.5), percentile(times[name], 0.99), percentile(times[name], 1.0)])
		print("COPIA_STORE_PHASES speed=%.0fm/s frames=%d median_ms=%.2f p99_ms=%.2f worst_ms=%.2f updates=%d (median/p99/worst) %s" % [
				speed, frames.size(), percentile(frames, 0.5) / 1000.0, percentile(frames, 0.99) / 1000.0, percentile(frames, 1.0) / 1000.0,
				times.update.size(), " ".join(fields)])
	else:
		print("COPIA_STORE_FLY speed=%.0fm/s frames=%d median_ms=%.2f p99_ms=%.2f worst_ms=%.2f groups_created_per_s=%.1f groups_freed_per_s=%.1f worst_step_us=%d ready_latency_median_ms=%.1f ready_latency_worst_ms=%.1f ready_samples=%d live_groups=%d drawer_objects=%d drawer_instances=%d multimeshes=%d" % [
				speed, frames.size(), percentile(frames, 0.5) / 1000.0, percentile(frames, 0.99) / 1000.0, percentile(frames, 1.0) / 1000.0,
				created / seconds, freed / seconds, worst_step, percentile(latencies, 0.5) / 1000.0, percentile(latencies, 1.0) / 1000.0,
				latencies.size(), stats.groups, stats.drawer.objects, stats.drawer.instances, stats.drawer.multimeshes])
	print_worst(label, speed, records)
	var total := {}
	for record in records:
		for kind in record.compiled:
			total[kind] = total.get(kind, 0) + record.compiled[kind]
	print("COPIA_STORE_PIPELINES %s speed=%.0fm/s compiled_during_fly=%s" % [label, speed, total])
	return x


## The five worst frame intervals of a fly, each with the store phases of the frame before it
## (whose rendering the interval holds), the render time and the pipelines compiled.
func print_worst(label: String, speed: float, records: Array) -> void:
	var order := range(records.size())
	order.sort_custom(func(a, b): return records[a].interval > records[b].interval)
	for rank in mini(5, order.size()):
		var record: Dictionary = records[order[rank]]
		var phases: Dictionary = record.store
		var store_us := 0
		for name in ["drain", "update", "colliders_step", "drawer_step", "shadows_settled"]:
			store_us += int(phases.get(name, 0))
		print("COPIA_STORE_WORST %s speed=%.0fm/s rank=%d t=%.2fs x=%.1f frame_ms=%.1f store_us=%d (drain %d, update %d, colliders %d, drawer %d, shadows %d; created %d, results %d, reads %d) render_cpu_ms=%.1f render_gpu_ms=%.1f compiled=%s groups=%d" % [
				label, speed, rank, record.t, record.x, record.interval / 1000.0, store_us, phases.get("drain", 0), phases.get("update", 0),
				phases.get("colliders_step", 0), phases.get("drawer_step", 0), phases.get("shadows_settled", 0), phases.get("created", 0),
				phases.get("results", 0), phases.get("reads_started", 0), record.render_cpu_ms, record.render_gpu_ms, record.compiled, record.groups])


func run() -> void:
	if not ClassDB.class_exists("CopiaDrawer"):
		GDExtensionManager.load_extension(EXTENSION)
	rng.seed = 3
	remove_tree(scratch)
	build_scene()
	make_objects()
	var t := Time.get_ticks_usec()
	var points := make_points()
	var generated := (Time.get_ticks_usec() - t) / 1e6
	store = StoreScript.new()
	store.data_directory = scratch.path_join("data")
	store.cell_size = 64.0
	store.impostor_cell_size = 256.0
	store.target = NodePath("../FlyCamera")
	store.group_added.connect(on_added)
	store.group_removed.connect(on_removed)
	camera.get_parent().add_child(store)
	t = Time.get_ticks_usec()
	var report: Dictionary = store.write([], points)
	var written := (Time.get_ticks_usec() - t) / 1e6
	print("COPIA_STORE_SETUP points=%d objects=%d generate_s=%.2f write_and_build_s=%.2f ok=%s cells=%d far=%d renderer=%s window=%s" % [
			POINTS, paths.size(), generated, written, report.ok, report.build.get("cell_count", 0), report.build.get("far_count", 0),
			ProjectSettings.get_setting("rendering/renderer/rendering_method"), DisplayServer.window_get_size()])
	if not report.ok:
		print("COPIA_STORE_SETUP error=%s" % report.error)

	var start_x := 150.0
	place_camera(start_x)
	t = Time.get_ticks_usec()
	var frames := 0
	var load_pipelines := pipeline_counts()
	var load_last := t
	var load_worst := 0
	var load_frames := []  # [interval usec, pipelines compiled in it, groups created by then]
	var counts := load_pipelines
	while Time.get_ticks_usec() - t < 30000000:
		await process_frame
		var interval := Time.get_ticks_usec() - load_last
		load_worst = maxi(load_worst, interval)
		load_last = Time.get_ticks_usec()
		var now_counts := pipeline_counts()
		var compiled := 0
		for kind in now_counts:
			compiled += now_counts[kind] - counts.get(kind, 0)
		counts = now_counts
		load_frames.append([interval, compiled, created])
		frames += 1
		poll_ready()
		if frames > 10 and store.get_stats().pending == 0:
			break
	var stats: Dictionary = store.get_stats()
	var load_compiled := {}
	var after_load := pipeline_counts()
	for kind in after_load:
		load_compiled[kind] = after_load[kind] - load_pipelines.get(kind, 0)
	print("COPIA_STORE_LOAD initial_s=%.2f frames=%d worst_frame_ms=%.1f groups=%d objects=%d instances=%d multimeshes=%d cells_cached=%d far_cached=%d pipelines_compiled=%s" % [
			(Time.get_ticks_usec() - t) / 1e6, frames, load_worst / 1000.0, stats.groups, stats.drawer.objects, stats.drawer.instances, stats.drawer.multimeshes,
			stats.cells_cached, stats.far_cached, load_compiled])
	var load_order := range(load_frames.size())
	load_order.sort_custom(func(a, b): return load_frames[a][0] > load_frames[b][0])
	for rank in mini(3, load_order.size()):
		var entry: Array = load_frames[load_order[rank]]
		print("COPIA_STORE_LOAD_WORST rank=%d frame=%d frame_ms=%.1f pipelines_compiled=%d groups_added_by_then=%d" % [rank, load_order[rank], entry[0] / 1000.0, entry[1], entry[2]])
	var compile_frames := []
	for i in load_frames.size():
		if load_frames[i][1] > 0:
			compile_frames.append("frame %d: %d compiled, %.1f ms" % [i, load_frames[i][1], load_frames[i][0] / 1000.0])
	print("COPIA_STORE_LOAD_COMPILES %s" % ", ".join(compile_frames))

	var x := await fly(5.0, start_x)
	x = await fly(20.0, x)
	await fly(-20.0, x, "phases")  # back over the same ground

	store.queue_free()
	await process_frame
	await process_frame
	ObjectScript.clear_cache()
	remove_tree(scratch)
	quit(0)
