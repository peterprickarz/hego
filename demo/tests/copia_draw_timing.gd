## Copia draw timing measurement (not a pass/fail test; needs a real renderer).
##
## Measures, through CopiaDrawer, the main-thread cost of creating and freeing RenderingServer
## multimeshes and instances, the frame times that follow, and for two cases the same calls made
## from GDScript. Then: case A loaded under a 500 us budget per frame (worst frame during the
## load), the first-use stall of a multimesh format with or without warm_up(), and the impostor
## swap read back from the rendered image. With --only=surface it checks instead, from the image,
## that per-surface materials show on single instances and on batches. Run windowed with Forward+
## and vsync off:
##
##   godot-4.7.2 --path demo --audio-driver Dummy --disable-vsync --resolution 1280x720 \
##       --script res://tests/copia_draw_timing.gd [-- --warm-up=on|off] [-- --only=stall|swap|surface]
##
## The stall is measured first, on the first multimesh of the run; the pipeline cache persists
## between runs, so compare runs in the same state. Prints COPIA_RUN, COPIA_MEDIAN, COPIA_STEP,
## COPIA_STALL and COPIA_SWAP lines (or COPIA_SURFACE), then quits.
extends SceneTree

const RUNS := 3
const BASELINE_FRAMES := 30
const SETTLE_FRAMES := 10
const AFTER_FRAMES := 3
const CELL_SIZE := 16.0
const BATCHES_PER_GROUP := 16  # one 64 m cell of 16 m batches
const INSTANCES_PER_GROUP := 100
const VISIBILITY_END := 3000.0
const STEP_BUDGET := 500

# name, mode, objects, instances per multimesh, implementation
const CASES := [
	["A", "multimesh", 2000, 15, "drawer"],
	["A", "multimesh", 2000, 15, "gdscript"],
	["B", "multimesh", 8000, 4, "drawer"],
	["C", "multimesh", 500, 60, "drawer"],
	["D", "instance", 1500, 1, "drawer"],
	["D", "instance", 1500, 1, "gdscript"],
	["E", "instance", 15000, 1, "drawer"],
]

const EXTENSION := "res://addons/copia/bin/copia.gdextension"

var scenario: RID
var mesh: ArrayMesh
var camera: Camera3D
var last_frame_usec := 0
var frame_usec := 0
var rng := RandomNumberGenerator.new()


func _initialize() -> void:
	call_deferred("run")


func next_frame() -> int:
	await process_frame
	var now := Time.get_ticks_usec()
	frame_usec = now - last_frame_usec
	last_frame_usec = now
	return frame_usec


func median(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	if sorted.is_empty():
		return 0.0
	var middle := sorted.size() / 2
	if sorted.size() % 2 == 1:
		return float(sorted[middle])
	return 0.5 * (float(sorted[middle - 1]) + float(sorted[middle]))


func build_scene() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var world_root := Node3D.new()
	root.add_child(world_root)
	camera = Camera3D.new()
	camera.far = 4000.0
	world_root.add_child(camera)
	camera.look_at_from_position(Vector3(0, 300, 500), Vector3.ZERO, Vector3.UP)
	camera.make_current()
	var light := DirectionalLight3D.new()
	light.shadow_enabled = true
	light.directional_shadow_max_distance = 500.0
	world_root.add_child(light)
	light.look_at_from_position(Vector3.ZERO, Vector3(-1, -2, -0.5), Vector3.UP)
	scenario = world_root.get_world_3d().scenario

	var sphere := SphereMesh.new()
	sphere.radial_segments = 16
	sphere.rings = 8
	mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sphere.surface_get_arrays(0))
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, material)
	var indices: PackedInt32Array = sphere.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	print("COPIA_MESH triangles=%d renderer=%s window=%s" % [indices.size() / 3,
			ProjectSettings.get_setting("rendering/renderer/rendering_method"), DisplayServer.window_get_size()])


func random_basis() -> Basis:
	var scale := rng.randf_range(0.5, 1.5)
	return Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(scale, scale, scale))


## Sections as CopiaCells.read_section returns them: multimesh sections of BATCHES_PER_GROUP
## batches on a grid of CELL_SIZE batch cells, or transform sections of INSTANCES_PER_GROUP.
func make_sections(mode: String, objects: int, per_multimesh: int) -> Array:
	var sections: Array = []
	var aabb := mesh.get_aabb()
	if mode == "multimesh":
		var side := int(ceil(sqrt(objects)))
		var half := 0.5 * side * CELL_SIZE
		var section := {}
		for index in objects:
			if index % BATCHES_PER_GROUP == 0:
				section = {"kind": "multimesh", "batch_count": 0, "batch_cells": PackedInt32Array(), "origins": PackedVector3Array(), "bounds": [], "first": PackedInt32Array(), "counts": PackedInt32Array(), "keep_counts": PackedInt32Array(), "buffers": []}
				sections.append(section)
			var cell := Vector3((index % side) * CELL_SIZE - half, 0, (index / side) * CELL_SIZE - half)
			var transforms: Array[Transform3D] = []
			var bounds := AABB()
			for i in per_multimesh:
				var t := Transform3D(random_basis(), cell + Vector3(rng.randf() * CELL_SIZE, rng.randf() * 2.0, rng.randf() * CELL_SIZE))
				transforms.append(t)
				bounds = t * aabb if i == 0 else bounds.merge(t * aabb)
			var centre := bounds.get_center()
			var buffer := PackedFloat32Array()
			buffer.resize(per_multimesh * 20)
			for i in per_multimesh:
				var t := transforms[i]
				var o := t.origin - centre
				var row := i * 20
				for axis in 3:
					buffer[row + axis * 4] = t.basis[0][axis]
					buffer[row + axis * 4 + 1] = t.basis[1][axis]
					buffer[row + axis * 4 + 2] = t.basis[2][axis]
					buffer[row + axis * 4 + 3] = o[axis]
				for channel in 4:
					buffer[row + 12 + channel] = rng.randf()
					buffer[row + 16 + channel] = rng.randf()
			section.batch_count += 1
			section.batch_cells.append_array([index % side, index / side])
			section.origins.append(centre)
			section.bounds.append(AABB(bounds.position - centre, bounds.size))
			section.first.append(0)
			section.counts.append(per_multimesh)
			section.keep_counts.append_array([per_multimesh, per_multimesh, per_multimesh, per_multimesh, per_multimesh])
			section.buffers.append(buffer)
	else:
		var area := ceilf(sqrt(2000.0)) * CELL_SIZE
		var section := {}
		for index in objects:
			if index % INSTANCES_PER_GROUP == 0:
				section = {"kind": "transforms", "count": 0, "transforms": PackedFloat32Array()}
				sections.append(section)
			var b := random_basis()
			var p := Vector3(rng.randf_range(-0.5, 0.5) * area, rng.randf() * 2.0, rng.randf_range(-0.5, 0.5) * area)
			section.transforms.append_array([b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z, p.x, p.y, p.z])
			section.count += 1
	return sections


func add_groups(drawer: Object, mode: String, sections: Array) -> Array:
	var groups: Array = []
	var params := {"mesh": mesh.get_rid(), "visibility_end": VISIBILITY_END}
	for section: Dictionary in sections:
		groups.append(drawer.add_multimesh_group(section, params) if mode == "multimesh" else drawer.add_instance_group(section, params))
	return groups


func gd_create(mode: String, sections: Array, per_multimesh: int, rids: Array) -> Dictionary:
	var mesh_rid := mesh.get_rid()
	var start := Time.get_ticks_usec()
	for section: Dictionary in sections:
		if mode == "multimesh":
			for b in section.batch_count:
				var multimesh := RenderingServer.multimesh_create()
				RenderingServer.multimesh_set_mesh(multimesh, mesh_rid)
				RenderingServer.multimesh_allocate_data(multimesh, per_multimesh, RenderingServer.MULTIMESH_TRANSFORM_3D, true, true)
				RenderingServer.multimesh_set_buffer(multimesh, section.buffers[b])
				RenderingServer.multimesh_set_custom_aabb(multimesh, section.bounds[b])
				var instance := RenderingServer.instance_create2(multimesh, scenario)
				RenderingServer.instance_set_transform(instance, Transform3D(Basis.IDENTITY, section.origins[b]))
				RenderingServer.instance_geometry_set_visibility_range(instance, 0.0, VISIBILITY_END, 0.0, 0.0, RenderingServer.VISIBILITY_RANGE_FADE_DISABLED)
				RenderingServer.instance_geometry_set_cast_shadows_setting(instance, RenderingServer.SHADOW_CASTING_SETTING_ON)
				RenderingServer.instance_geometry_set_lod_bias(instance, 1.0)
				rids.append(instance)
				rids.append(multimesh)
		else:
			var values: PackedFloat32Array = section.transforms
			for i: int in section.count:
				var k: int = i * 12
				var t := Transform3D(Basis(Vector3(values[k], values[k + 1], values[k + 2]), Vector3(values[k + 3], values[k + 4], values[k + 5]), Vector3(values[k + 6], values[k + 7], values[k + 8])), Vector3(values[k + 9], values[k + 10], values[k + 11]))
				var instance := RenderingServer.instance_create2(mesh_rid, scenario)
				RenderingServer.instance_set_transform(instance, t)
				RenderingServer.instance_geometry_set_visibility_range(instance, 0.0, VISIBILITY_END, 0.0, 0.0, RenderingServer.VISIBILITY_RANGE_FADE_DISABLED)
				RenderingServer.instance_geometry_set_cast_shadows_setting(instance, RenderingServer.SHADOW_CASTING_SETTING_ON)
				RenderingServer.instance_geometry_set_lod_bias(instance, 1.0)
				rids.append(instance)
	return {"usec": Time.get_ticks_usec() - start}


func gd_free(rids: Array) -> int:
	var start := Time.get_ticks_usec()
	for rid: RID in rids:  # each instance before its multimesh
		RenderingServer.free_rid(rid)
	rids.clear()
	return Time.get_ticks_usec() - start


func run_case(case: Array) -> void:
	var name: String = case[0]
	var mode: String = case[1]
	var objects: int = case[2]
	var per_multimesh: int = case[3]
	var implementation: String = case[4]
	var columns := {"total": [], "queue": [], "baseline": [], "f1": [], "f2": [], "f3": [], "free": []}
	for run in RUNS:
		rng.seed = 1 + run
		var sections := make_sections(mode, objects, per_multimesh)
		for frame in SETTLE_FRAMES:
			await next_frame()
		var baseline: Array = []
		for frame in BASELINE_FRAMES:
			baseline.append(await next_frame())
		var drawer: Object = ClassDB.instantiate("CopiaDrawer")
		drawer.set_scenario(scenario)
		var rids: Array = []
		var create_usec := 0
		var queue_usec := 0
		var groups: Array = []
		if implementation == "drawer":
			var start := Time.get_ticks_usec()
			groups = add_groups(drawer, mode, sections)
			queue_usec = Time.get_ticks_usec() - start
			var step: Dictionary = drawer.step(1_000_000_000)
			create_usec = step.usec
			assert(step.created == objects)
		else:
			create_usec = gd_create(mode, sections, per_multimesh, rids).usec
		# The first interval runs from the end of creation to the next frame, so it holds
		# the rendering of the frame in which the objects were created, not the creation.
		last_frame_usec = Time.get_ticks_usec()
		var after: Array = []
		for frame in AFTER_FRAMES:
			after.append(await next_frame())
		var free_usec := 0
		if implementation == "drawer":
			for group in groups:
				drawer.remove_group(group)
			var step: Dictionary = drawer.step(1_000_000_000)
			free_usec = step.usec
			var stats: Dictionary = drawer.get_stats()
			assert(stats.objects == 0 and stats.instances == 0 and stats.multimeshes == 0)
		else:
			free_usec = gd_free(rids)
		drawer = null
		for frame in SETTLE_FRAMES:
			await next_frame()
		var baseline_median := median(baseline)
		print("COPIA_RUN case=%s impl=%s run=%d objects=%d instances=%d create_us=%d queue_us=%d per_object_us=%.3f baseline_frame_us=%d frames_after_us=%d,%d,%d free_us=%d" % [
				name, implementation, run, objects, objects * per_multimesh, create_usec, queue_usec, float(create_usec) / objects,
				baseline_median, after[0], after[1], after[2], free_usec])
		columns.total.append(create_usec)
		columns.queue.append(queue_usec)
		columns.baseline.append(baseline_median)
		columns.f1.append(after[0])
		columns.f2.append(after[1])
		columns.f3.append(after[2])
		columns.free.append(free_usec)
	var total := median(columns.total)
	print("COPIA_MEDIAN case=%s mode=%s impl=%s objects=%d per_multimesh=%d create_us=%d queue_us=%d per_object_us=%.3f baseline_frame_us=%d frames_after_us=%d,%d,%d free_us=%d free_per_object_us=%.3f" % [
			name, mode, implementation, objects, per_multimesh, total, median(columns.queue), total / objects,
			median(columns.baseline), median(columns.f1), median(columns.f2), median(columns.f3), median(columns.free),
			median(columns.free) / objects])


## Case A loaded and unloaded under STEP_BUDGET per frame: frames used and the worst frame.
func run_stepped() -> void:
	rng.seed = 7
	var sections := make_sections("multimesh", 2000, 15)
	for frame in SETTLE_FRAMES:
		await next_frame()
	var baseline: Array = []
	for frame in BASELINE_FRAMES:
		baseline.append(await next_frame())
	var drawer: Object = ClassDB.instantiate("CopiaDrawer")
	drawer.set_scenario(scenario)
	var groups := add_groups(drawer, "multimesh", sections)
	for phase in ["load", "unload"]:
		if phase == "unload":
			for group in groups:
				drawer.remove_group(group)
		var frames: Array = []
		var step_usec: Array = []
		var worst_step := 0
		last_frame_usec = Time.get_ticks_usec()
		while true:
			var step: Dictionary = drawer.step(STEP_BUDGET)
			step_usec.append(step.usec)
			worst_step = max(worst_step, step.usec)
			frames.append(await next_frame())
			if step.pending_create == 0 and step.pending_free == 0:
				break
		for frame in AFTER_FRAMES:  # the renderer's share of the last step
			frames.append(await next_frame())
		var sorted := frames.duplicate()
		sorted.sort()
		print("COPIA_STEP phase=%s budget_us=%d frames=%d baseline_frame_us=%d median_frame_us=%d worst_frame_us=%d p95_frame_us=%d median_step_us=%d worst_step_us=%d" % [
				phase, STEP_BUDGET, step_usec.size(), median(baseline), median(frames), sorted[-1], sorted[int(sorted.size() * 0.95)],
				median(step_usec), worst_step])
	drawer = null


## The first multimesh with colour and custom data of the run, with or without warm_up() first.
func run_stall(warm: bool) -> void:
	rng.seed = 5
	var sections := make_sections("multimesh", BATCHES_PER_GROUP, 15)
	var drawer: Object = ClassDB.instantiate("CopiaDrawer")
	drawer.set_scenario(scenario)
	drawer.update_camera(camera.global_position)
	var warm_frames: Array = []
	if warm:
		var start := Time.get_ticks_usec()
		drawer.warm_up(mesh.get_rid(), RID(), true, true)
		var warm_call := Time.get_ticks_usec() - start
		last_frame_usec = Time.get_ticks_usec()
		for frame in 5:
			warm_frames.append(await next_frame())
			drawer.step(1000)
		print("COPIA_STALL warm_up_call_us=%d frames_after_warm_up_us=%s warm_up_left=%d" % [warm_call, warm_frames, drawer.get_stats().warm_up])
		for frame in SETTLE_FRAMES:
			await next_frame()
	var baseline: Array = []
	for frame in BASELINE_FRAMES:
		baseline.append(await next_frame())
	drawer.add_multimesh_group(sections[0], {"mesh": mesh.get_rid(), "visibility_end": VISIBILITY_END})
	var step: Dictionary = drawer.step(1_000_000)
	last_frame_usec = Time.get_ticks_usec()
	var after: Array = []
	for frame in 4:
		after.append(await next_frame())
	print("COPIA_STALL warm_up=%s create_us=%d baseline_frame_us=%d frames_after_first_batch_us=%s worst_us=%d" % [
			"on" if warm else "off", step.usec, median(baseline), after, after.max()])
	drawer = null
	for frame in SETTLE_FRAMES:
		await next_frame()


## Share of red (impostor) and green (child) pixels in the last rendered image.
func read_colours() -> Vector2i:
	var image := root.get_texture().get_image()
	image.resize(160, 90, Image.INTERPOLATE_NEAREST)
	var red := 0
	var green := 0
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x, y)
			if c.r > 0.5 and c.g < 0.3:
				red += 1
			elif c.g > 0.5 and c.r < 0.3:
				green += 1
	return Vector2i(red, green)


func unshaded(colour: Color) -> RID:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = colour
	materials.append(material)
	return material.get_rid()


var materials: Array = []


## Impostor swap read back from the image: a camera flies in across the swap distance and out
## again while the child group streams in (one object per frame) and later out. Each image
## should show the impostor (red) or the children (green), never neither and never both.
func run_swap() -> void:
	const SWAP := 100.0
	rng.seed = 9
	var drawer: Object = ClassDB.instantiate("CopiaDrawer")
	drawer.set_scenario(scenario)
	var red := unshaded(Color(1, 0, 0))
	var green := unshaded(Color(0, 1, 0))
	# The impostor: one batch of one instance beside the children, so both can show at once.
	var impostor_buffer := PackedFloat32Array([4, 0, 0, 0, 0, 4, 0, 0, 0, 0, 4, 0, 1, 1, 1, 1, 0, 0, 0, 0])
	var impostor_section := {"kind": "multimesh", "batch_count": 1, "batch_cells": PackedInt32Array([0, 0]), "origins": PackedVector3Array([Vector3(6, 2, 0)]),
			"bounds": [AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8))], "first": PackedInt32Array([0]), "counts": PackedInt32Array([1]),
			"keep_counts": PackedInt32Array([1, 1, 1, 1, 1]), "buffers": [impostor_buffer]}
	var impostor: int = drawer.add_multimesh_group(impostor_section, {"mesh": mesh.get_rid(), "material_override": red, "visibility_end": 3000.0, "visibility_begin_margin": 2.0, "cast_shadows": 0})
	var child_section := {"kind": "transforms", "count": 40, "transforms": PackedFloat32Array()}
	for i in 40:
		child_section.transforms.append_array([1, 0, 0, 0, 1, 0, 0, 0, 1, -6 + (i % 8) * 1.2, 1 + (i / 8) * 1.2, 0])
	drawer.step(1_000_000)
	camera.look_at_from_position(Vector3(0, 2, 220), Vector3(0, 2, 0), Vector3.UP)
	var neither := 0
	var both := 0
	var frames := 0
	var green_frames := 0
	var red_frames := 0
	var child := 0
	var events := ""
	# Frame plan: fly in from 220 m to 20 m at 2 m per frame (100 frames), hold 40 frames, fly
	# out to 220 m (100 frames). The child group is added at frame 30 (about 160 m) and removed
	# at frame 160 (near), each with one object per frame.
	for frame in 260:
		var z := 220.0 - 2.0 * frame if frame < 100 else (20.0 if frame < 140 else 20.0 + 2.0 * (frame - 140))
		camera.look_at_from_position(Vector3(0, 2, z), Vector3(0, 2, 0), Vector3.UP)
		# Ranges depend on distance only: keep the framing (about 18 m high) constant, so the
		# objects stay several pixels large in the read-back image at every distance.
		camera.fov = rad_to_deg(2.0 * atan(9.0 / z))
		if frame == 30:
			child = drawer.add_instance_group(child_section, {"mesh": mesh.get_rid(), "material_override": green, "visibility_end": 3000.0, "cast_shadows": 0})
			drawer.link_impostor(impostor, child, SWAP)
			events += " add@%d" % frame
		if frame == 160:
			drawer.remove_group(child)
			events += " remove@%d" % frame
		drawer.step(1)  # one object per frame
		await process_frame
		# The image read now shows the previous frame; count every image the same way.
		var colours := read_colours()
		frames += 1
		if colours.x > 0:
			red_frames += 1
		if colours.y > 0:
			green_frames += 1
		if colours.x == 0 and colours.y == 0:
			neither += 1
			events += " neither@%d(z=%.0f)" % [frame, z]
		elif colours.x > 0 and colours.y > 0:
			both += 1
			events += " both@%d(z=%.0f)" % [frame, z]
	print("COPIA_SWAP frames=%d impostor_frames=%d child_frames=%d neither_frames=%d both_frames=%d swap_distance=%.0f events=%s" % [
			frames, red_frames, green_frames, neither, both, SWAP, events])
	drawer = null
	for frame in SETTLE_FRAMES:
		await next_frame()
	camera.fov = 75.0
	camera.look_at_from_position(Vector3(0, 300, 500), Vector3.ZERO, Vector3.UP)


## Per-surface materials, read back from the image: a mesh whose own surface material is green,
## drawn by the drawer as a single instance with a red surface material, as a batch through
## CopiaObject.surface_materials (a mesh copy carrying red), and as a plain batch (green, the
## control). Prints COPIA_SURFACE with the colour under each.
func run_surface() -> void:
	var red := StandardMaterial3D.new()
	red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	red.albedo_color = Color(1, 0, 0)
	var green := StandardMaterial3D.new()
	green.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	green.albedo_color = Color(0, 1, 0)
	var box := ArrayMesh.new()
	box.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, BoxMesh.new().get_mesh_arrays())
	box.surface_set_material(0, green)
	materials.append_array([red, green])
	var object = preload("res://addons/copia/copia_object.gd").new()
	object.mesh = box
	object.render = preload("res://addons/copia/copia_render_settings.gd").new()
	object.surface_materials = [red] as Array[Material]
	var drawer: Object = ClassDB.instantiate("CopiaDrawer")
	drawer.set_scenario(scenario)
	var one := PackedFloat32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0])
	var places := {"instance": -3.0, "multimesh_copy": 3.0, "control": 0.0}
	for name in ["multimesh_copy", "control"]:
		var section := {"kind": "multimesh", "batch_count": 1, "batch_cells": PackedInt32Array([0, 0]), "origins": PackedVector3Array([Vector3(places[name], 0, 0)]),
				"bounds": [AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))], "first": PackedInt32Array([0]), "counts": PackedInt32Array([1]),
				"keep_counts": PackedInt32Array([1, 1, 1, 1, 1]), "buffers": [one]}
		var params: Dictionary = object._get_draw_params() if name == "multimesh_copy" else {"mesh": box.get_rid()}
		params.cast_shadows = 0
		drawer.add_multimesh_group(section, params)
	object.render.draw_mode = 1  # INSTANCE
	var instance_params: Dictionary = object._get_draw_params()
	instance_params.cast_shadows = 0
	drawer.add_instance_group({"kind": "transforms", "count": 1, "transforms": PackedFloat32Array([1, 0, 0, 0, 1, 0, 0, 0, 1, places.instance, 0, 0])}, instance_params)
	drawer.step(1_000_000)
	camera.look_at_from_position(Vector3(0, 0, 9), Vector3.ZERO, Vector3.UP)
	for frame in 4:
		await process_frame
	var image := root.get_texture().get_image()
	var size := Vector2(image.get_size())
	var line := "COPIA_SURFACE"
	for name in places:
		var at: Vector2 = camera.unproject_position(Vector3(places[name], 0, 0)) * size / root.get_visible_rect().size
		var c := image.get_pixel(clampi(int(at.x), 0, image.get_width() - 1), clampi(int(at.y), 0, image.get_height() - 1))
		var seen := "red" if c.r > 0.5 and c.g < 0.3 else ("green" if c.g > 0.5 and c.r < 0.3 else "other %s" % c)
		line += " %s=%s" % [name, seen]
	print(line + " (expected instance=red multimesh_copy=red control=green)")
	drawer = null
	for frame in SETTLE_FRAMES:
		await next_frame()
	camera.look_at_from_position(Vector3(0, 300, 500), Vector3.ZERO, Vector3.UP)


func run() -> void:
	# Loaded here so the script also runs before the editor has listed the extension.
	if not ClassDB.class_exists("CopiaDrawer"):
		var status := GDExtensionManager.load_extension(EXTENSION)
		print("COPIA_EXTENSION load_status=%d" % status)
	if not ClassDB.class_exists("CopiaDrawer"):
		push_error("CopiaDrawer is not available")
		quit(1)
		return
	var warm := false
	var only := ""
	for argument in OS.get_cmdline_user_args():
		if argument == "--warm-up=on":
			warm = true
		elif argument.begins_with("--only="):
			only = argument.trim_prefix("--only=")
	build_scene()
	last_frame_usec = Time.get_ticks_usec()
	for frame in 60:  # let the window settle (no multimesh has been drawn yet)
		await next_frame()
	if only == "surface":
		await run_surface()
		quit(0)
		return
	await run_stall(warm)
	if only == "stall":
		quit(0)
		return
	if only != "swap":
		for case: Array in CASES:
			await run_case(case)
		await run_stepped()
	await run_swap()
	quit(0)
