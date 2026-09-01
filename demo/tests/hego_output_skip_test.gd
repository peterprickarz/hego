## Covers which output handlers run for a given cook result.
##
## HEGoNode3D asks HEGoAssetNode.get_output_summary() once and lets each handler
## decide whether it has anything to do. The rule that matters is the conservative
## one: anything unknown means the handler runs, so a summary that could not be read
## costs time rather than output.
extends SceneTree

var failures := 0


## A cook that produced nothing at all. Not a const: PackedStringArray() is not a
## constant expression.
func no_output() -> Dictionary:
	return {
		"has_mesh": false, "has_points": false, "has_curves": false, "has_volumes": false,
		"point_attributes": PackedStringArray(), "prim_attributes": PackedStringArray(),
	}


func check(condition: bool, what: String) -> void:
	if condition:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func summary_with(overrides: Dictionary) -> Dictionary:
	var summary := no_output()
	for key in overrides:
		summary[key] = overrides[key]
	return summary


func _initialize() -> void:
	var terrain3d := ClassDB.class_exists("Terrain3D")

	# --- an unreadable summary must never cost output ----------------------
	var unknown := {}
	check(HEGoMeshOutput.should_handle(unknown), "empty summary still runs mesh output")
	check(HEGoMultiMeshOutput.should_handle(unknown), "empty summary still runs multimesh output")
	check(HEGoObjectOutput.should_handle(unknown), "empty summary still runs object spawning")
	check(HEGoCurveOutput.should_handle(unknown), "empty summary still runs curve output")
	if terrain3d:
		check(HEGoTerrain3DOutput.should_handle(unknown), "empty summary still runs Terrain3D output")
		check(HEGoTerrain3DInstancer.should_handle(unknown), "empty summary still runs the Terrain3D instancer")

	# A summary missing a key it needs is unknown for that key alone.
	check(HEGoMeshOutput.should_handle({"has_points": true}), "a summary without has_mesh still runs mesh output")
	check(HEGoObjectOutput.should_handle({"has_points": true}),
		"points with an unknown attribute list still run object spawning")

	# --- a cook that produced nothing --------------------------------------
	check(not HEGoMeshOutput.should_handle(no_output()), "no mesh part, no mesh output")
	check(not HEGoMultiMeshOutput.should_handle(no_output()), "no points, no multimesh output")
	check(not HEGoObjectOutput.should_handle(no_output()), "no points, no object spawning")
	check(not HEGoCurveOutput.should_handle(no_output()), "no curve parts, no curve output")
	if terrain3d:
		check(not HEGoTerrain3DOutput.should_handle(no_output()), "no volume parts, no Terrain3D output")
		check(not HEGoTerrain3DInstancer.should_handle(no_output()), "no points, no Terrain3D instancing")

	# --- geometry present, flags absent ------------------------------------
	var bare_points := summary_with({"has_points": true, "point_attributes": PackedStringArray(["P", "N"])})
	check(not HEGoObjectOutput.should_handle(bare_points), "points without hego_spawn do not spawn objects")
	check(not HEGoMultiMeshOutput.should_handle(bare_points), "points without hego_use_multimesh do not instance")

	# --- the flags that switch a handler on --------------------------------
	check(HEGoObjectOutput.should_handle(summary_with({
		"has_points": true, "point_attributes": PackedStringArray(["P", "hego_spawn"])})),
		"hego_spawn turns object spawning on")
	check(HEGoMultiMeshOutput.should_handle(summary_with({
		"has_points": true, "point_attributes": PackedStringArray(["P", "hego_use_multimesh"])})),
		"hego_use_multimesh turns multimesh output on")
	check(HEGoMeshOutput.should_handle(summary_with({"has_mesh": true})), "a mesh part turns mesh output on")
	check(HEGoCurveOutput.should_handle(summary_with({"has_curves": true})), "a curve part turns curve output on")
	if terrain3d:
		check(HEGoTerrain3DOutput.should_handle(summary_with({"has_volumes": true})),
			"a volume part turns Terrain3D output on")
		check(HEGoTerrain3DInstancer.should_handle(summary_with({
			"has_points": true, "point_attributes": PackedStringArray(["P", "hegot3d_use_terrain3d_instancer"])})),
			"hegot3d_use_terrain3d_instancer turns Terrain3D instancing on")
	else:
		print("  note: Terrain3D is not installed, its handlers were not exercised")

	# --- one output does not drag the others along -------------------------
	var only_mesh := summary_with({"has_mesh": true})
	check(not HEGoObjectOutput.should_handle(only_mesh), "a mesh-only cook skips object spawning")
	check(not HEGoCurveOutput.should_handle(only_mesh), "a mesh-only cook skips curve output")

	print("")
	print("failures: ", failures)
	quit(1 if failures > 0 else 0)
