## CopiaSource3D measurement with two views (not a pass/fail test; needs a real renderer).
##
## The million-point setup of copia_store_timing.gd (impostors drawn with an unshaded magenta
## material so they can be told apart in a read-back), a main camera and a 320 x 180 SubViewport
## whose camera, 600 m away, carries a CopiaSource3D with density 0.5, range scale 0.5, colliders
## and shadows off; the SubViewport has a raised mesh_lod_threshold. Prints:
##
## - COPIA_SOURCES_LOAD: groups, instances and bodies for main only, preview only and both, with
##   the groups each source needs (load_sources_now).
## - COPIA_SOURCES_UPDATE: main-thread time of one streaming update with nothing left to load,
##   with the sources still and with them stepping 2 m back and forth (median, p99, worst).
## - COPIA_SOURCES_FRAMES: median and p99 frame time over 10 s for main only, main + preview with
##   both cameras still, and main + preview with the preview camera moving at 10 m/s.
## - COPIA_SOURCES_PREVIEW: the preview image read back with its source on, with it off, and with
##   the store hidden: pixels that differ from the empty view, split into impostor (magenta) and
##   other pixels, overall and in the lower half (the ground near the camera).
## - COPIA_SOURCES_PER_VIEW: a small second store of LOD spheres (unshaded red, range 50 m) seen by
##   the main camera from 120 m through a narrow lens and by the preview camera from 12 m: red
##   pixels in each view; then the same with an unlimited range (the main view's control); and the
##   primitives each viewport drew at mesh_lod_threshold 1 and raised.
##
##   godot-4.7.2 --path demo --audio-driver Dummy --disable-vsync --resolution 1280x720 \
##       --script res://tests/copia_sources_timing.gd
##
## - COPIA_SOURCES_STRESS: a separate store of 180 objects in each of 56 cells (10,080 cell-object
##   records) with four sources of different range scales, densities, collider flags and
##   priorities: groups loaded, then the update times as in COPIA_SOURCES_UPDATE.
##
## Add [code]-- --images=DIR[/code] to save the three preview images as PNG files in DIR, or
## [code]-- --updates-only[/code] to print only the loads, the update times and the stress case.
## Scratch data goes to user:// and is deleted afterwards. Run time: about three minutes (one
## with --updates-only).
extends SceneTree

const EXTENSION := "res://addons/copia/bin/copia.gdextension"
const ObjectScript := preload("res://addons/copia/copia_object.gd")
const RenderScript := preload("res://addons/copia/copia_render_settings.gd")
const PhysicsScript := preload("res://addons/copia/copia_physics_settings.gd")
const StoreScript := preload("res://addons/copia/copia_store_3d.gd")
const SourceScript := preload("res://addons/copia/copia_source_3d.gd")
const SIDE := 1000.0
const POINTS := 1000000
const SINGLE_OBJECTS := 13
const BATCH_OBJECTS := 27
const SINGLE_POINTS := 30000
const HEIGHT := 2.0
const MAIN_X := 150.0
const PREVIEW_X := 750.0  # 600 m from the main camera
const MEASURE_SECONDS := 10.0
const PREVIEW_LOD_THRESHOLD := 8.0
const PROBE := Vector3(-2992, 0, 0)  # centre of the per-view probe patch
const UPDATE_WARMUP := 10
const UPDATE_CALLS := 200
const STRESS_OBJECTS := 180
const STRESS_CELLS := Vector2i(8, 7)  # 56 cells x 180 objects = 10,080 cell-object records
const STRESS_ORIGIN := Vector3(0, 0, 4096)  # on cell borders

var scratch := "user://copia_sources_timing_%d" % OS.get_process_id()
var rng := RandomNumberGenerator.new()
var store: Node3D
var probe: Node3D
var probe_object: Resource
var camera: Camera3D
var preview: SubViewport
var preview_camera: Camera3D
var source: Node3D
var paths := PackedStringArray()


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


func unshaded(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	return material


func make_objects() -> void:
	DirAccess.make_dir_recursive_absolute(scratch.path_join("objects"))
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	var magenta := unshaded(Color(1, 0, 1))
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
			object.impostor_mesh = card
			object.impostor_material = magenta
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
	# The probe: a sphere with generated LODs, unshaded red, batches of 16 m, range 50 m.
	var sphere := SphereMesh.new()
	sphere.radial_segments = 96
	sphere.rings = 48
	sphere.radius = 0.8
	sphere.height = 1.6
	var importer := ImporterMesh.new()
	importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, sphere.get_mesh_arrays())
	importer.generate_lods(25.0, 60.0, [])
	var lod_mesh: ArrayMesh = importer.get_mesh()
	lod_mesh.surface_set_material(0, unshaded(Color(1, 0, 0)))
	var object := ObjectScript.new()
	object.mesh = lod_mesh
	object.render = RenderScript.new()
	object.render.batch_size = 16.0
	object.render.visibility_range_end = 50.0
	ResourceSaver.save(object, scratch.path_join("objects/probe.tres"))
	ObjectScript.clear_cache()
	print("COPIA_SOURCES_SETUP probe_sphere_triangles=%d probe_lods=%d" % [sphere.get_mesh_arrays()[Mesh.ARRAY_INDEX].size() / 3, importer.get_surface_lod_count(0)])


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


func probe_points() -> Dictionary:
	var transform := PackedFloat32Array()
	var object := PackedInt32Array()
	for i in 40:
		var at := PROBE + Vector3(rng.randf_range(-6, 6), 0.8, rng.randf_range(-6, 6))
		transform.append_array(PackedFloat32Array([1, 0, 0, 0, 1, 0, 0, 0, 1, at.x, at.y, at.z]))
		object.append(0)
	return {"transform": transform, "object": object, "object_paths": PackedStringArray([scratch.path_join("objects/probe.tres")])}


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
	# The preview: a small SubViewport of the same world with its own camera and a source.
	preview = SubViewport.new()
	preview.size = Vector2i(320, 180)
	preview.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	preview.mesh_lod_threshold = PREVIEW_LOD_THRESHOLD
	root.add_child(preview)
	preview_camera = Camera3D.new()
	preview_camera.far = 3000.0
	preview.add_child(preview_camera)
	preview_camera.current = true
	source = SourceScript.new()
	source.density = 0.5
	source.range_scale = 0.5
	source.colliders = false
	source.shadows = false
	preview_camera.add_child(source)


func place_main(at: Vector3, look: Vector3) -> void:
	camera.look_at_from_position(at, look, Vector3.UP)


func place_preview(at: Vector3, look: Vector3) -> void:
	preview_camera.look_at_from_position(at, look, Vector3.UP)


func frames(count: int) -> void:
	for i in count:
		await process_frame


func load_all(label: String) -> void:
	var result: Dictionary = store.load_sources_now(60.0)
	await frames(3)
	var stats: Dictionary = store.get_stats()
	var per_source := []
	for entry in stats.sources:
		per_source.append("%s:%d/%d/%d" % [entry.name, entry.groups.draw, entry.groups.impostor, entry.groups.collider])
	# Main-thread time of one streaming update with nothing to load (the bookkeeping per update).
	var update_times := measure_updates(store, [camera, preview_camera])
	print("COPIA_SOURCES_UPDATE config=%s sources=%d live_records=%d cells_cached=%d %s" % [
			label, stats.sources.size(), stats.groups, stats.cells_cached, update_times])
	print("COPIA_SOURCES_LOAD config=%s ok=%s load_ms=%.1f groups=%d draw=%d impostor=%d collider=%d objects=%d instances=%d multimeshes=%d bodies=%d sources(draw/impostor/collider)=%s" % [
			label, result.ok, result.usec / 1000.0, stats.groups, stats.groups_by_kind.draw, stats.groups_by_kind.impostor, stats.groups_by_kind.collider,
			stats.drawer.objects, stats.drawer.instances, stats.drawer.multimeshes, stats.colliders.bodies, " ".join(per_source)])


## Main-thread time of [method CopiaStore3D.update_streaming_all], as "still_* moving_*" fields
## (median, p99 and worst in microseconds over UPDATE_CALLS calls each): still with every source
## where it is, then moving, where every node of [param movers] steps 2 m along X and back
## between calls (beyond the store's movement threshold, so each call evaluates; within the
## margins, so nothing is loaded or freed after the first step). No frame runs in between.
func measure_updates(node: Node3D, movers: Array) -> String:
	var still: Array[int] = []
	var moving: Array[int] = []
	for i in UPDATE_WARMUP + UPDATE_CALLS:
		var t := Time.get_ticks_usec()
		node.update_streaming_all()
		if i >= UPDATE_WARMUP:
			still.append(Time.get_ticks_usec() - t)
	var origins := movers.map(func(mover: Node3D) -> Vector3: return mover.global_position)
	for i in UPDATE_WARMUP + UPDATE_CALLS:
		var offset := Vector3(2.0 if i % 2 == 0 else 0.0, 0.0, 0.0)
		for m in movers.size():
			movers[m].global_position = origins[m] + offset
		var t := Time.get_ticks_usec()
		node.update_streaming_all()
		if i >= UPDATE_WARMUP:
			moving.append(Time.get_ticks_usec() - t)
	for m in movers.size():
		movers[m].global_position = origins[m]
	node.update_streaming_all()
	return "still_median_us=%d still_p99_us=%d still_worst_us=%d moving_median_us=%d moving_p99_us=%d moving_worst_us=%d" % [
			percentile(still, 0.5), percentile(still, 0.99), percentile(still, 1.0),
			percentile(moving, 0.5), percentile(moving, 0.99), percentile(moving, 1.0)]


## The stress case: STRESS_OBJECTS objects in every cell of a STRESS_CELLS grid (one record per
## object and cell, about 10,000), every one within range of four sources with different range
## scales, densities, collider flags and priorities; loaded with load_sources_now, then the
## update measured as in [method measure_updates].
func stress() -> void:
	var objects := PackedStringArray()
	for i in STRESS_OBJECTS:
		var object := ObjectScript.new()
		object.render = RenderScript.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.3, 0.3, 0.3)
		object.mesh = box
		if i % 3 == 0:
			object.render.batch_size = 16.0
		else:
			object.render.draw_mode = RenderScript.DrawMode.INSTANCE
		object.render.visibility_range_end = 350.0 + 350.0 * i / (STRESS_OBJECTS - 1)
		if i % 6 == 1:
			object.impostor_mesh = QuadMesh.new()
			object.render.impostor_range_end = 1500.0
		if i % 9 == 2:
			object.physics = PhysicsScript.new()
		var path := scratch.path_join("objects/stress_%03d.tres" % i)
		ResourceSaver.save(object, path)
		objects.append(path)
	ObjectScript.clear_cache()
	var transform := PackedFloat32Array()
	var object_index := PackedInt32Array()
	for cx in STRESS_CELLS.x:
		for cz in STRESS_CELLS.y:
			for i in STRESS_OBJECTS:
				var at := Vector3((cx + rng.randf()) * 64.0, 0.0, (cz + rng.randf()) * 64.0) + STRESS_ORIGIN
				transform.append_array(PackedFloat32Array([1, 0, 0, 0, 1, 0, 0, 0, 1, at.x, at.y, at.z]))
				object_index.append(i)
	var node: Node3D = StoreScript.new()
	node.data_directory = scratch.path_join("stress_data")
	node.cell_size = 64.0
	node.impostor_cell_size = 256.0
	node.use_default_source = false
	camera.get_parent().add_child(node)
	var t := Time.get_ticks_usec()
	var report: Dictionary = node.write([], {"transform": transform, "object": object_index, "object_paths": objects})
	var write_s := (Time.get_ticks_usec() - t) / 1e6
	var centre := STRESS_ORIGIN + Vector3(STRESS_CELLS.x * 32.0, HEIGHT, STRESS_CELLS.y * 32.0)
	var settings := [
		{"range_scale": 1.0, "density": 1.0, "colliders": true, "priority": 1.0, "offset": Vector3(0, 0, 0)},
		{"range_scale": 0.5, "density": 0.5, "colliders": false, "priority": 1.0, "offset": Vector3(-150, 0, -120)},
		{"range_scale": 1.5, "density": 0.75, "colliders": true, "priority": 2.0, "offset": Vector3(160, 0, 100)},
		{"range_scale": 0.75, "density": 0.25, "colliders": false, "priority": 0.5, "offset": Vector3(-60, 0, 170)},
	]
	var sources := []
	for entry in settings:
		var stress_source: Node3D = SourceScript.new()
		for name in ["range_scale", "density", "colliders", "priority"]:
			stress_source.set(name, entry[name])
		camera.get_parent().add_child(stress_source)
		stress_source.store = stress_source.get_path_to(node)
		stress_source.global_position = centre + entry.offset
		sources.append(stress_source)
	source.enabled = false  # the preview source applies to every store
	var loaded: Dictionary = node.load_sources_now(120.0)
	await frames(3)
	var stats: Dictionary = node.get_stats()
	var records := STRESS_CELLS.x * STRESS_CELLS.y * STRESS_OBJECTS
	print("COPIA_SOURCES_STRESS write_ok=%s write_s=%.1f load_ok=%s load_ms=%.0f cell_object_records=%d sources=%d groups=%d draw=%d impostor=%d collider=%d cells_cached=%d far_cached=%d %s" % [
			report.ok, write_s, loaded.ok, loaded.usec / 1000.0, records, stats.sources.size(), stats.groups, stats.groups_by_kind.draw,
			stats.groups_by_kind.impostor, stats.groups_by_kind.collider, stats.cells_cached, stats.far_cached, measure_updates(node, sources)])
	for stress_source in sources:
		stress_source.free()
	source.enabled = true
	node.queue_free()
	await frames(2)


func measure(label: String, preview_speed: float) -> void:
	var times: Array[int] = []
	var started := Time.get_ticks_usec()
	var last := started
	var z := 500.0
	while Time.get_ticks_usec() - started < int(MEASURE_SECONDS * 1e6):
		await process_frame
		var now := Time.get_ticks_usec()
		times.append(now - last)
		if preview_speed > 0.0:
			z += preview_speed * (now - last) / 1e6
			place_preview(Vector3(PREVIEW_X, HEIGHT, z), Vector3(PREVIEW_X + 50.0, 0.0, z + 10.0))
		last = now
	var stats: Dictionary = store.get_stats()
	print("COPIA_SOURCES_FRAMES config=%s frames=%d median_ms=%.2f p99_ms=%.2f worst_ms=%.2f groups=%d instances=%d" % [
			label, times.size(), percentile(times, 0.5) / 1000.0, percentile(times, 0.99) / 1000.0, percentile(times, 1.0) / 1000.0,
			stats.groups, stats.drawer.instances])


func image_of(viewport: Viewport) -> Image:
	await frames(4)
	return viewport.get_texture().get_image()


## Pixels of [param image] that differ from [param empty] (summed channel difference above 0.03):
## [differing, magenta, other] over the whole image, then the same over its lower half.
func classify(image: Image, empty: Image) -> Array:
	var counts := [0, 0, 0, 0, 0, 0]
	var size := image.get_size()
	for y in size.y:
		for x in size.x:
			var c := image.get_pixel(x, y)
			var e := empty.get_pixel(x, y)
			if absf(c.r - e.r) + absf(c.g - e.g) + absf(c.b - e.b) < 0.03:
				continue
			var kind := 1 if c.r > 0.8 and c.g < 0.2 and c.b > 0.8 else 2
			counts[0] += 1
			counts[kind] += 1
			if y >= size.y / 2:
				counts[3] += 1
				counts[3 + kind] += 1
	return counts


func red_pixels(image: Image) -> int:
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x, y)
			if c.r > 0.8 and c.g < 0.2 and c.b < 0.2:
				count += 1
	return count


func primitives(viewport: Viewport) -> int:
	return viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)


func settle(node: Node3D) -> void:
	var deadline := Time.get_ticks_msec() + 30000
	var quiet := 0
	while Time.get_ticks_msec() < deadline and quiet < 10:
		await process_frame
		quiet = quiet + 1 if node.get_stats().pending == 0 and node.is_settled() else 0


func run() -> void:
	if not ClassDB.class_exists("CopiaDrawer"):
		GDExtensionManager.load_extension(EXTENSION)
	rng.seed = 3
	remove_tree(scratch)
	build_scene()
	make_objects()
	var points := make_points()
	store = StoreScript.new()
	store.data_directory = scratch.path_join("data")
	store.cell_size = 64.0
	store.impostor_cell_size = 256.0
	store.target = NodePath("../FlyCamera")
	camera.get_parent().add_child(store)
	var t := Time.get_ticks_usec()
	var report: Dictionary = store.write([], points)
	print("COPIA_SOURCES_SETUP points=%d objects=%d write_and_build_s=%.2f ok=%s renderer=%s window=%s preview=%s preview_lod_threshold=%.1f" % [
			POINTS, paths.size(), (Time.get_ticks_usec() - t) / 1e6, report.ok, ProjectSettings.get_setting("rendering/renderer/rendering_method"),
			DisplayServer.window_get_size(), preview.size, preview.mesh_lod_threshold])

	var main_at := Vector3(MAIN_X, HEIGHT, SIDE / 2)
	var main_look := Vector3(MAIN_X + 50.0, 0.0, SIDE / 2 + 10.0)
	var preview_at := Vector3(PREVIEW_X, HEIGHT, SIDE / 2)
	var preview_look := Vector3(PREVIEW_X + 50.0, 0.0, SIDE / 2 + 10.0)
	place_main(main_at, main_look)
	place_preview(preview_at, preview_look)

	var updates_only := OS.get_cmdline_user_args().has("--updates-only")
	# Loads per configuration.
	source.enabled = false
	preview.render_target_update_mode = SubViewport.UPDATE_DISABLED
	await load_all("main_only")
	if not updates_only:
		await measure("main_only_still", 0.0)
	source.enabled = true
	preview.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await load_all("main_and_preview")
	if updates_only:
		await stress()
		store.queue_free()
		await frames(2)
		ObjectScript.clear_cache()
		remove_tree(scratch)
		quit(0)
		return
	await measure("main_and_preview_still", 0.0)
	await measure("main_and_preview_moving_10mps", 10.0)
	place_preview(preview_at, preview_look)
	store.use_default_source = false
	await load_all("preview_only")
	store.use_default_source = true
	await load_all("main_and_preview_again")

	# Preview read-back: source on, source off (main 600 m away), store hidden.
	var with_source := await image_of(preview)
	source.enabled = false
	await settle(store)
	var without_source := await image_of(preview)
	var stats: Dictionary = store.get_stats()
	store.visible = false
	await settle(store)
	var empty := await image_of(preview)
	store.visible = true
	source.enabled = true
	var on := classify(with_source, empty)
	var off := classify(without_source, empty)
	print("COPIA_SOURCES_PREVIEW source_on: differing=%d impostor=%d other=%d lower_half: differing=%d impostor=%d other=%d" % on)
	print("COPIA_SOURCES_PREVIEW source_off: differing=%d impostor=%d other=%d lower_half: differing=%d impostor=%d other=%d (groups=%d draw=%d impostor=%d)" % (off + [stats.groups, stats.groups_by_kind.draw, stats.groups_by_kind.impostor]))
	var images := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--images="):
			images = argument.trim_prefix("--images=")
	if not images.is_empty():
		DirAccess.make_dir_recursive_absolute(images)
		for pair in [[with_source, "preview_on"], [without_source, "preview_off"], [empty, "preview_empty"]]:
			pair[0].save_png(images.path_join("%s.png" % pair[1]))

	# Per view: visibility ranges and LODs.
	probe = StoreScript.new()
	probe.data_directory = scratch.path_join("probe_data")
	probe.cell_size = 64.0
	probe.impostor_cell_size = 256.0
	probe.target = NodePath("../FlyCamera")
	camera.get_parent().add_child(probe)
	report = probe.write([], probe_points())
	probe_object = ObjectScript.resolve(scratch.path_join("objects/probe.tres"))
	camera.fov = 6.0
	place_main(PROBE + Vector3(120, HEIGHT, 0), PROBE + Vector3(0, 0.8, 0))
	place_preview(PROBE + Vector3(-12, HEIGHT, 0), PROBE + Vector3(0, 0.8, 0))
	var loaded: Dictionary = probe.load_sources_now()
	await settle(probe)
	var probe_stats: Dictionary = probe.get_stats()
	var group_end := -1.0
	for info in probe.get_loaded_groups():
		group_end = probe.get_drawer().get_group_info(info.group).params.visibility_end
	var main_red := red_pixels(await image_of(root))
	var preview_red := red_pixels(await image_of(preview))
	print("COPIA_SOURCES_PER_VIEW range_50m: probe_write_ok=%s loaded=%s groups=%d needed_by=%s group_range_end=%.1f main_red=%d (camera 120 m away) preview_red=%d (camera 12 m away)" % [
			report.ok, loaded.ok, probe_stats.groups, probe_stats.sources.map(func(s): return "%s:%d" % [s.name, s.groups.draw]), group_end, main_red, preview_red])
	probe_object.render.visibility_range_end = 0.0  # unlimited: the main view's control
	probe.load_sources_now()
	main_red = red_pixels(await image_of(root))
	preview_red = red_pixels(await image_of(preview))
	var main_prims_1 := primitives(root)
	var preview_prims_raised := primitives(preview)
	preview.mesh_lod_threshold = 1.0
	await frames(4)
	var preview_prims_1 := primitives(preview)
	var main_prims_with_preview_1 := primitives(root)
	root.mesh_lod_threshold = PREVIEW_LOD_THRESHOLD
	await frames(4)
	var main_prims_raised := primitives(root)
	root.mesh_lod_threshold = 1.0
	preview.mesh_lod_threshold = PREVIEW_LOD_THRESHOLD
	print("COPIA_SOURCES_PER_VIEW range_unlimited: main_red=%d preview_red=%d" % [main_red, preview_red])
	print("COPIA_SOURCES_PER_VIEW lod: preview_primitives threshold_%.0f=%d threshold_1=%d; main_primitives threshold_1=%d (preview at %.0f) %d (preview at 1) threshold_%.0f=%d" % [
			PREVIEW_LOD_THRESHOLD, preview_prims_raised, preview_prims_1, main_prims_1, PREVIEW_LOD_THRESHOLD, main_prims_with_preview_1, PREVIEW_LOD_THRESHOLD, main_prims_raised])

	probe.queue_free()
	camera.fov = 75.0
	await stress()
	store.queue_free()
	await frames(2)
	ObjectScript.clear_cache()
	remove_tree(scratch)
	quit(0)
