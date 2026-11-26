## Integration test: verifies HEGo surface UV V-flip and ARRAY_TANGENT handedness
## match Godot's native SurfaceTool.generate_tangents() for both right-handed and
## mirrored UV charts (OpenGL normal-map convention: BINORMAL = cross(N, T) * w points
## along -dP/dV_godot = +dP/dV_houdini = up in texture space).
## Starts its own named-pipe server; it never attaches to an editor's Session Sync.
extends SceneTree

var failures := 0
var checks_run := 0


func check(condition: bool, message: String) -> void:
	checks_run += 1
	print("  %s %s" % ["ok" if condition else "FAIL", message])
	if not condition:
		failures += 1


func task_result(task: HEGoTask) -> Variant:
	while task.get_status() < HEGoTask.COMPLETED:
		await process_frame
	check(task.get_status() == HEGoTask.COMPLETED, task.get_description())
	return task.get_result()


func make_quad_asset(mirror_u: bool) -> HEGoAssetNode:
	var asset := HEGoAssetNode.new()
	asset.op_name = "Sop/attribwrangle"
	await task_result(asset.instantiate())
	if asset.get_id() < 0:
		return null
	# +Z facing quad in Houdini (clockwise front-facing winding -> Godot CCW after HEGo export).
	# Bottom-left UV (0,0) -> top-right (1,1) when not mirrored; mirrored flips U horizontally.
	var u_left := 1.0 if mirror_u else 0.0
	var u_right := 0.0 if mirror_u else 1.0
	var tu_x := -1.0 if mirror_u else 1.0
	var snippet := (
		'int bl = addpoint(0, {-1, -1, 0}); int br = addpoint(0, {1, -1, 0});'
		+ ' int tr = addpoint(0, {1, 1, 0}); int tl = addpoint(0, {-1, 1, 0});'
		+ ' setpointattrib(0, "uv", bl, set(%f, 0.0, 0.0));'
		+ ' setpointattrib(0, "uv", br, set(%f, 0.0, 0.0));'
		+ ' setpointattrib(0, "uv", tr, set(%f, 1.0, 0.0));'
		+ ' setpointattrib(0, "uv", tl, set(%f, 1.0, 0.0));'
		+ ' for (int i = 0; i < 4; i++) {'
		+ '   setpointattrib(0, "N", i, set(0.0, 0.0, 1.0));'
		+ '   setpointattrib(0, "tangentu", i, set(%f, 0.0, 0.0));'
		+ '   setpointattrib(0, "tangentv", i, set(0.0, 1.0, 0.0));'
		+ ' }'
		+ ' addprim(0, "poly", bl, tl, tr); addprim(0, "poly", bl, tr, br);'
	) % [u_left, u_right, u_right, u_left, tu_x]
	await task_result(asset.set_parms_batch({"class": 0, "snippet": snippet}))
	await task_result(asset.cook())
	return asset


func verify_quad(label: String, mirror_u: bool, expected_w: float) -> void:
	var asset := await make_quad_asset(mirror_u)
	if asset == null:
		check(false, "%s: failed to instantiate wrangle" % label)
		return
	var surfaces: HEGoSurfaceOutput = await task_result(asset.get_surface_output(["N", "uv", "tangents"], []))
	check(surfaces != null and surfaces.is_valid(), "%s: surface output is valid" % label)
	if surfaces == null or not surfaces.is_valid():
		return
	var surf: Dictionary = surfaces.select_all().get_surface()
	var arr: Array = surf.get("surface_array", [])
	check(arr.size() == Mesh.ARRAY_MAX, "%s: surface array populated" % label)
	if arr.size() != Mesh.ARRAY_MAX:
		return

	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var uvs3: PackedVector3Array = arr[Mesh.ARRAY_TEX_UV]
	var tangs: PackedFloat32Array = arr[Mesh.ARRAY_TANGENT]
	var idxs: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	check(verts.size() == 4 and tangs.size() == 16 and uvs3.size() == 4, "%s: 4 verts with UVs and tangents" % label)

	# Verify ArrayMesh ingestion preserves UV.y and tangent.w.
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mesh_arr := mesh.surface_get_arrays(0)
	var uvs: PackedVector2Array = mesh_arr[Mesh.ARRAY_TEX_UV]

	# Top vertices (P.y > 0) must have Godot UV.y == 0.0; bottom vertices (P.y < 0) must have UV.y == 1.0.
	var uv_ok := true
	for i in range(verts.size()):
		var expect_v := 0.0 if verts[i].y > 0.0 else 1.0
		if abs(uvs[i].y - expect_v) > 1e-4 or abs(uvs3[i].y - expect_v) > 1e-4:
			uv_ok = false
	check(uv_ok, "%s: UV.y flipped to Godot top-left origin" % label)

	# Compare HEGo ARRAY_TANGENT directly against Godot's own SurfaceTool.generate_tangents().
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for ti in range(idxs.size() / 3):
		for k in range(3):
			var idx := idxs[ti * 3 + k]
			st.set_normal(norms[idx])
			st.set_uv(uvs[idx])
			st.add_vertex(verts[idx])
	st.generate_tangents()
	var st_arr := st.commit().surface_get_arrays(0)
	var st_tangs: PackedFloat32Array = st_arr[Mesh.ARRAY_TANGENT]

	var all_match := true
	var hego_w_ok := true
	for i in range(verts.size()):
		var hw := tangs[i * 4 + 3]
		if abs(hw - expected_w) > 1e-4:
			hego_w_ok = false
	for k in range(idxs.size()):
		var idx := idxs[k]
		var ht := Vector3(tangs[idx * 4], tangs[idx * 4 + 1], tangs[idx * 4 + 2])
		var hw := tangs[idx * 4 + 3]
		var gt := Vector3(st_tangs[k * 4], st_tangs[k * 4 + 1], st_tangs[k * 4 + 2])
		var gw := st_tangs[k * 4 + 3]
		if ht.dot(gt) < 0.99 or hw * gw <= 0.0:
			all_match = false
	check(hego_w_ok, "%s: HEGo tangent.w == %.1f" % [label, expected_w])
	check(all_match, "%s: HEGo ARRAY_TANGENT matches Godot SurfaceTool.generate_tangents()" % label)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var api := HEGoAPI.get_singleton()
	if not api.start_session(HEGoAPI.SESSION_NAMED_PIPE, "hego_tangent_test_%d" % OS.get_process_id()):
		push_error("Could not start the test's Houdini session")
		quit(1)
		return
	await verify_quad("right_handed", false, 1.0)
	await verify_quad("mirrored_u", true, -1.0)
	api.stop_session()
	check(checks_run >= 18, "all tangent handedness checks executed (%d)" % checks_run)
	print("tangent handedness failures: ", failures)
	quit(1 if failures else 0)
