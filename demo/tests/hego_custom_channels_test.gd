## Integration test for custom vertex channels (ARRAY_CUSTOM0..3). Requires a licensed Houdini
## Engine installation and the rebuilt extension. Starts its own named-pipe server.
##
##   godot-4.7.2 --path demo --audio-driver Dummy --script res://tests/hego_custom_channels_test.gd
##
## With --headless (Dummy rendering keeps no LOD buffers) the LOD checks are skipped.
## The fixture, tests/fixtures/hego_test_custom_channels.hda (built by
## make_custom_channels_fixture.py), writes known per-point values into hego_custom0 (float4),
## hego_custom1 (float) and hego_custom3 (vector3), and leaves hego_custom2 out, over a quad
## with a reduced LOD triangle.
extends SceneTree

const FIXTURE_DIR := "res://tests/fixtures"
const SAVE_PATH := "user://hego_custom_channels_test.res"

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


func expected_custom0(point: int) -> PackedFloat32Array:
	return PackedFloat32Array([float(point), 10.0 + point, 0.25 * point, 7.0])


func custom_format(format: int, channel: int) -> int:
	return (format >> (Mesh.ARRAY_FORMAT_CUSTOM_BASE + channel * Mesh.ARRAY_FORMAT_CUSTOM_BITS)) & Mesh.ARRAY_FORMAT_CUSTOM_MASK


## Checks the custom arrays of one surface against the fixture's values. Points are matched
## by position, so this holds whatever order the surface's vertices come in.
func check_arrays(arrays: Array, label: String) -> void:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var c0 = arrays[Mesh.ARRAY_CUSTOM0]
	var c1 = arrays[Mesh.ARRAY_CUSTOM1]
	var c3 = arrays[Mesh.ARRAY_CUSTOM3]
	check(c0 is PackedFloat32Array and c0.size() == vertices.size() * 4, label + ": custom0 is RGBA float per vertex")
	check(c1 is PackedFloat32Array and c1.size() == vertices.size() * 4, label + ": custom1 is RGBA float per vertex")
	check(arrays[Mesh.ARRAY_CUSTOM2] == null, label + ": custom2 (absent attribute) is left out")
	check(c3 is PackedFloat32Array and c3.size() == vertices.size() * 4, label + ": custom3 is RGBA float per vertex")
	if not (c0 is PackedFloat32Array and c1 is PackedFloat32Array and c3 is PackedFloat32Array):
		return
	var positions := [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)]
	var all_match := true
	for v in vertices.size():
		var point := positions.find(vertices[v])
		if point < 0:
			all_match = false
			continue
		var want0 := expected_custom0(point)
		for k in 4:
			all_match = all_match and is_equal_approx(c0[v * 4 + k], want0[k])
		# Tuple size 1 and 3 attributes fill R / RGB; the rest stays 0.
		all_match = all_match and is_equal_approx(c1[v * 4], 0.5 + point) and c1[v * 4 + 1] == 0.0 and c1[v * 4 + 3] == 0.0
		all_match = all_match and is_equal_approx(c3[v * 4], -1.0 * point) and is_equal_approx(c3[v * 4 + 2], 3.0) and c3[v * 4 + 3] == 0.0
	check(all_match, label + ": every vertex carries its point's known values")


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	# The named-pipe server inherits this, so it finds the fixture HDA.
	OS.set_environment("HOUDINI_OTLSCAN_PATH", ProjectSettings.globalize_path(FIXTURE_DIR) + ":&")
	var api := HEGoAPI.get_singleton()
	if not api.start_session(HEGoAPI.SESSION_NAMED_PIPE, "hego_custom_channels_test_%d" % OS.get_process_id()):
		push_error("Could not start the test's Houdini session")
		quit(1)
		return
	var asset := HEGoAssetNode.new()
	asset.op_name = "Sop/hego_test_custom_channels"
	await task_result(asset.instantiate())
	if asset.get_id() < 0:
		check(false, "fixture HDA instantiates")
		api.stop_session()
		quit(1)
		return
	await task_result(asset.cook())

	# Low level: the surface output packs the named attributes.
	var custom := PackedStringArray(HEGoMeshOutput.CUSTOM_ATTRIBS)
	var output: HEGoSurfaceOutput = await task_result(asset.get_surface_output(["N"], ["hego_lod"], custom))
	check(output != null and output.is_valid(), "surface output is valid")
	if output != null and output.is_valid():
		var surface := output.select_all().get_surface(["hego_lod"])
		check_arrays(surface["surface_array"], "surface")
		var flags := int(surface.get("custom_format_flags", 0))
		check(custom_format(flags, 0) == Mesh.ARRAY_CUSTOM_RGBA_FLOAT and custom_format(flags, 1) == Mesh.ARRAY_CUSTOM_RGBA_FLOAT
			and custom_format(flags, 2) == 0 and custom_format(flags, 3) == Mesh.ARRAY_CUSTOM_RGBA_FLOAT, "surface names RGBA float for channels 0, 1 and 3")
		var plain: HEGoSurfaceOutput = await task_result(asset.get_surface_output(["N"]))
		var plain_surface := plain.select_all().get_surface()
		check(plain_surface["surface_array"][Mesh.ARRAY_CUSTOM0] == null and not plain_surface.has("custom_format_flags"), "no custom channels unless asked for")

	# The mesh output builds the mesh with the right formats and keeps them in its LODs.
	var meshes := {}
	var groups := await HEGoMeshOutput.fetch_surface_groups(_context(asset))
	for key in groups:
		meshes[key] = HEGoMeshOutput.build_array_mesh(groups[key])
	check(meshes.size() == 1 and meshes.values()[0] != null, "mesh output builds one mesh")
	if meshes.size() == 1 and meshes.values()[0] != null:
		var mesh: ArrayMesh = meshes.values()[0]
		var format := mesh.surface_get_format(0)
		check(custom_format(format, 0) == Mesh.ARRAY_CUSTOM_RGBA_FLOAT and format & Mesh.ARRAY_FORMAT_CUSTOM0, "mesh surface has CUSTOM0 as RGBA float")
		check(not (format & Mesh.ARRAY_FORMAT_CUSTOM2), "mesh surface has no CUSTOM2")
		check_arrays(mesh.surface_get_arrays(0), "mesh")
		var has_lods := DisplayServer.get_name() != "headless"
		if has_lods:
			var lods := HEGoMeshOutput._surface_lods(mesh, 0, mesh.surface_get_arrays(0))
			check(lods.size() == 1, "the reduced LOD survives next to the custom channels")
		else:
			print("  skip LOD checks (headless rendering keeps no LOD buffers)")
		# Saving twice takes the overwrite path, which rebuilds the surfaces in place.
		for attempt in 2:
			var saved := HEGoMeshOutput.save_mesh_resource(mesh, SAVE_PATH)
			check(saved["ok"], "save %d" % (attempt + 1))
		var reloaded := ResourceLoader.load(SAVE_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as ArrayMesh
		check(reloaded != null, "saved mesh reloads")
		if reloaded != null:
			check(custom_format(reloaded.surface_get_format(0), 0) == Mesh.ARRAY_CUSTOM_RGBA_FLOAT, "overwritten resource keeps the CUSTOM0 format")
			check_arrays(reloaded.surface_get_arrays(0), "reloaded")
			if has_lods:
				check(HEGoMeshOutput._surface_lods(reloaded, 0, reloaded.surface_get_arrays(0)).size() == 1, "overwritten resource keeps its LOD")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))

	api.stop_session()
	print("custom channel integration failures: ", failures)
	if failures == 0:
		print("HEGO_CUSTOM_CHANNELS_PASS")
	quit(1 if failures else 0)


func _context(asset: HEGoAssetNode) -> HEGoOutputContext:
	var host := Node3D.new()
	root.add_child(host)
	return HEGoOutputContext.create(host, asset, {})
