## CopiaBrush native tests: spatial hash min-spacing rejection, species radial falloff bands,
## slope filtering, NaN color/custom preservation, ray-vs-OBB picking (including benchmark) and
## sphere query. Headless, no Houdini.
##
##   godot-4.7.2 --path demo --headless --script res://tests/copia_brush_test.gd
##
## Prints COPIA_BRUSH_TEST PASS or FAIL and exits 0 or 1.
extends SceneTree

const EXTENSION := "res://addons/copia/bin/copia.gdextension"
const PlacementScript := preload("res://addons/copia/copia_placement_settings.gd")
const SpeciesScript := preload("res://addons/copia/copia_species.gd")
const EntryScript := preload("res://addons/copia/copia_species_entry.gd")
const ObjectScript := preload("res://addons/copia/copia_object.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("run")


func check(value: bool, description: String) -> void:
	if not value:
		failures.append(description)
		push_error("FAIL: " + description)


func run() -> void:
	if not ClassDB.class_exists("CopiaBrush"):
		GDExtensionManager.load_extension(EXTENSION)
	check(ClassDB.class_exists("CopiaBrush"), "CopiaBrush native class loaded")
	check(ClassDB.class_exists("CopiaEditOverlay"), "CopiaEditOverlay native class loaded")
	if not failures.is_empty():
		_finish()
		return

	var brush: Object = ClassDB.instantiate("CopiaBrush")

	# 1. Species radial falloff bands: large only in center [0.6..1.0], small only in rim [0.0..0.4].
	var large_obj := ObjectScript.new()
	large_obj.resource_path = "res://test/fern_large.tres"
	var small_obj := ObjectScript.new()
	small_obj.resource_path = "res://test/fern_small.tres"

	var placement := PlacementScript.new()
	placement.min_spacing = 1.0
	placement.slope_max_deg = 35.0
	placement.keep_min = 0.9
	placement.keep_max = 1.0
	placement.color_mode = PlacementScript.ColorMode.NONE

	var e_large := EntryScript.new()
	e_large.object = large_obj
	e_large.weight = 1.0
	e_large.brush_strength_min = 0.6
	e_large.brush_strength_max = 1.0

	var e_small := EntryScript.new()
	e_small.object = small_obj
	e_small.weight = 1.0
	e_small.brush_strength_min = 0.0
	e_small.brush_strength_max = 0.4

	var species := SpeciesScript.new()
	species.display_name = "Test Fern"
	species.placement = placement
	species.entries = [e_large, e_small]

	var specs: Array = species.to_dab_specs()
	check(specs.size() == 2, "species produces 2 dab specs")

	# Hits: center (t=0.9), close duplicate of center (should be rejected by min_spacing=1.0),
	# rim (t=0.2), and steep cliff (60 deg, should be rejected by slope_max_deg=35).
	var steep_n := Vector3(sin(deg_to_rad(60.0)), cos(deg_to_rad(60.0)), 0.0).normalized()
	var hits := {
		"positions": PackedVector3Array([
			Vector3(0, 0, 0),
			Vector3(0.3, 0, 0.2),
			Vector3(5, 0, 0),
			Vector3(10, 0, 0),
		]),
		"normals": PackedVector3Array([
			Vector3.UP,
			Vector3.UP,
			Vector3.UP,
			steep_n,
		]),
		"radial_t": PackedFloat32Array([0.9, 0.9, 0.2, 0.9]),
	}
	var dab: Dictionary = brush.sample_dab(hits, specs, {"seed": 42, "spacing_scale": 1.0, "set_name": "handpainted"})
	check(int(dab.count) == 2, "sample_dab accepts center + rim, rejects close duplicate and steep slope (got %d)" % int(dab.count))
	if int(dab.count) == 2:
		var path0: String = dab.object_paths[dab.object[0]]
		var path1: String = dab.object_paths[dab.object[1]]
		check(path0 == "res://test/fern_large.tres", "brush center spawns large variant (got %s)" % path0)
		check(path1 == "res://test/fern_small.tres", "brush rim spawns small variant (got %s)" % path1)
		check(not dab.has("color"), "ColorMode.NONE omits color column so object defaults apply")
		check(not dab.has("custom"), "write_custom=false omits custom column so object defaults apply")
		check(dab.keep[0] >= 0.9 and dab.keep[0] <= 1.0, "keep stays in configured high priority range")

	# 2. Ray-vs-OBB picking (works without colliders, ignores non-editable avoidance points).
	brush.clear()
	var authored := {
		"transform": PackedFloat32Array([
			1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -5,
			1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -10,
		]),
		"object": PackedInt32Array([0, 1]),
		"object_paths": PackedStringArray(["res://test/near.tres", "res://test/far.tres"]),
		"set": PackedInt32Array([0, 0]),
		"set_names": PackedStringArray(["handplaced"]),
	}
	var procedural := {
		"transform": PackedFloat32Array([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -2]),
		"object": PackedInt32Array([0]),
		"object_paths": PackedStringArray(["res://test/proc.tres"]),
		"set": PackedInt32Array([0]),
		"set_names": PackedStringArray(["vegetation"]),
	}
	brush.load_points(procedural, false, {})
	brush.load_points(authored, true, {})
	var aabbs := {
		"res://test/near.tres": AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 2, 1)),
		"res://test/far.tres": AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 2, 1)),
		"res://test/proc.tres": AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 2, 1)),
	}
	var pick: Dictionary = brush.pick_ray(Vector3(0, 1, 0), Vector3(0, 0, -1), 100.0, aabbs)
	check(bool(pick.hit) and pick.object_path == "res://test/near.tres", "pick_ray skips procedural point at z=-2 and hits closest authored point at z=-5")

	# 3. query_sphere marks erased so repeated dab skips already-erased points.
	var q1: Dictionary = brush.query_sphere(Vector3(0, 0, -5), 1.5, PackedStringArray(), true)
	check(int(q1.count) == 1 and q1.persistent.object.size() == 1, "query_sphere finds persistent authored point")
	var q2: Dictionary = brush.query_sphere(Vector3(0, 0, -5), 1.5, PackedStringArray(), true)
	check(int(q2.count) == 0, "second query_sphere skips already-erased point")
	var pick2: Dictionary = brush.pick_ray(Vector3(0, 1, 0), Vector3(0, 0, -1), 100.0, aabbs)
	check(bool(pick2.hit) and pick2.object_path == "res://test/far.tres", "pick_ray skips erased near point and hits far point")

	# 4. Ray-pick performance check with 10,000 authored points.
	brush.clear()
	var n := 10000
	var t_arr := PackedFloat32Array()
	t_arr.resize(n * 12)
	var o_arr := PackedInt32Array()
	o_arr.resize(n)
	o_arr.fill(0)
	var s_arr := PackedInt32Array()
	s_arr.resize(n)
	s_arr.fill(0)
	for i in n:
		var gx := float(i % 100) * 2.0
		var gz := float(i / 100) * 2.0
		var base := i * 12
		t_arr[base + 0] = 1.0
		t_arr[base + 4] = 1.0
		t_arr[base + 8] = 1.0
		t_arr[base + 9] = gx
		t_arr[base + 10] = 0.0
		t_arr[base + 11] = gz
	brush.load_points({
		"transform": t_arr,
		"object": o_arr,
		"object_paths": PackedStringArray(["res://test/near.tres"]),
		"set": s_arr,
		"set_names": PackedStringArray(["handpainted"]),
	}, true, {})
	var t0 := Time.get_ticks_usec()
	var bench_pick: Dictionary = brush.pick_ray(Vector3(50, 10, 50), Vector3(0, -1, 0), 100.0, aabbs)
	var dt_usec := Time.get_ticks_usec() - t0
	check(bool(bench_pick.hit), "10k-point ray pick hits target")
	print("CopiaBrush 10k ray-OBB pick: %.3f ms" % (dt_usec / 1000.0))

	# 5. CopiaDrawer suppression works on queued MultiMesh batches (before step) and created ones.
	var drawer: Object = ClassDB.instantiate("CopiaDrawer")
	var scenario := RenderingServer.scenario_create()
	var box_mesh := BoxMesh.new()
	drawer.set_scenario(scenario)
	var mm_buf := PackedFloat32Array([
		1, 0, 0, 2.0,  0, 1, 0, 0.5,  0, 0, 1, -3.0,  1, 1, 1, 1,  0, 0, 0, 0,
	])
	var mm_sec := {
		"kind": "multimesh",
		"origins": PackedVector3Array([Vector3(10.0, 0.0, 20.0)]),
		"bounds": [AABB(Vector3(-5, -5, -5), Vector3(10, 10, 10))],
		"counts": PackedInt32Array([1]),
		"keep_counts": PackedInt32Array([1, 1, 1, 1, 1]),
		"buffers": [mm_buf],
	}
	var gid: int = drawer.add_multimesh_group(mm_sec, {"mesh": box_mesh.get_rid()})
	# Queued suppression BEFORE step() (exact scenario after drag-drop/rebuild).
	var target_xform := PackedFloat32Array([1, 0, 0, 0, 1, 0, 0, 0, 1, 12.0, 0.5, 17.0])
	var sup_queued: int = drawer.suppress_transforms(PackedInt64Array([gid]), target_xform)
	check(sup_queued == 1, "suppress_transforms hides queued MultiMesh instance before step() (got %d)" % sup_queued)
	drawer.step(100000)
	drawer.clear_suppressions()
	# Suppression AFTER step() on a live GPU MultiMesh.
	var sup_live: int = drawer.suppress_transforms(PackedInt64Array([gid]), target_xform)
	check(sup_live == 1, "suppress_transforms hides live MultiMesh instance after step() (got %d)" % sup_live)
	drawer.clear_suppressions()
	drawer.remove_group(gid)
	drawer.step(100000)
	RenderingServer.free_rid(scenario)

	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("COPIA_BRUSH_TEST PASS")
		quit(0)
	else:
		print("COPIA_BRUSH_TEST FAIL (%d)" % failures.size())
		quit(1)
