## Copia set ownership manifest, write-intent guards, locked sets, atomic point edits (including
## cross-cell moves) and sphere erase + Undo round-trip. Headless, no Houdini.
##
##   godot-4.7.2 --path demo --headless --script res://tests/copia_sets_ownership_test.gd
##
## Prints COPIA_SETS_OWNERSHIP_TEST PASS or FAIL and exits 0 or 1.
extends SceneTree

const EXTENSION := "res://addons/copia/bin/copia.gdextension"
const CELL := 64.0
const ALL := Rect2(-100000, -100000, 200000, 200000)

var failures: Array[String] = []
var scratch := "user://copia_sets_ownership_test_%d" % OS.get_process_id()


func _initialize() -> void:
	call_deferred("run")


func check(value: bool, description: String) -> void:
	if not value:
		failures.append(description)
		push_error("FAIL: " + description)


func remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for directory in DirAccess.get_directories_at(path):
		remove_tree(path.path_join(directory))
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)


func _pt(pos: Vector3, obj_path: String, set_name := "default", keep_v := 1.0, col := PackedFloat32Array([NAN, NAN, NAN, NAN])) -> Dictionary:
	return {
		"transform": PackedFloat32Array([1, 0, 0, 0, 1, 0, 0, 0, 1, pos.x, pos.y, pos.z]),
		"object": PackedInt32Array([0]),
		"object_paths": PackedStringArray([obj_path]),
		"set": PackedInt32Array([0]),
		"set_names": PackedStringArray([set_name]),
		"color": col,
		"keep": PackedFloat32Array([keep_v]),
	}


func run() -> void:
	if not ClassDB.class_exists("CopiaSets"):
		GDExtensionManager.load_extension(EXTENSION)
	check(ClassDB.class_exists("CopiaSets"), "CopiaSets native class loaded")
	if not failures.is_empty():
		_finish()
		return

	remove_tree(scratch)
	DirAccess.make_dir_recursive_absolute(scratch)

	# 1. Existing procedural set written with generated intent.
	var gen_pts := _pt(Vector3(10, 0, 10), "res://obj/fern.tres", "vegetation", 0.5)
	var r1: Dictionary = ClassDB.class_call_static("CopiaSets", "apply", scratch, CELL, [], gen_pts, "generated")
	check(bool(r1.ok), "generated apply into new vegetation set succeeds: " + str(r1.error))

	# 2. Authored intent must refuse writing to existing unregistered (generated) set.
	var r2: Dictionary = ClassDB.class_call_static("CopiaSets", "apply", scratch, CELL, [], gen_pts, "authored")
	check(not bool(r2.ok), "authored apply into generated vegetation set is refused")

	# 3. Declare empty authored set handplaced; survives reindex().
	var m1: Dictionary = ClassDB.class_call_static("CopiaSets", "set_meta", scratch, "handplaced", "authored", false)
	check(bool(m1.ok), "set_meta declares empty authored set handplaced")
	var reidx: Dictionary = ClassDB.class_call_static("CopiaSets", "reindex", scratch)
	check(bool(reidx.ok), "reindex succeeds")
	var meta: Dictionary = ClassDB.class_call_static("CopiaSets", "get_sets_meta", scratch)
	check(meta.has("handplaced") and meta.handplaced.kind == "authored", "handplaced stays authored after reindex")
	check(meta.has("vegetation") and meta.vegetation.kind == "generated", "vegetation defaults to generated")

	# 4. Generated intent cannot write or clear authored set.
	var bad_gen_clear: Dictionary = ClassDB.class_call_static("CopiaSets", "apply", scratch, CELL, [{"set": "handplaced", "cell": Vector2i(0, 0)}], {}, "generated")
	check(not bool(bad_gen_clear.ok), "generated clear on authored set handplaced is refused")
	var bad_gen_add: Dictionary = ClassDB.class_call_static("CopiaSets", "apply", scratch, CELL, [], _pt(Vector3(5, 0, 5), "res://obj/rock.tres", "handplaced"), "generated")
	check(not bool(bad_gen_add.ok), "generated write into authored set handplaced is refused")

	# 5. Authored edit_points adds a point and moves it across a 64m cell boundary.
	var p_cell0 := _pt(Vector3(12.5, 1.0, 20.0), "res://obj/rock.tres", "handplaced", 1.0)
	var add_res: Dictionary = ClassDB.class_call_static("CopiaSets", "edit_points", scratch, CELL, "handplaced", {}, p_cell0, "authored")
	check(bool(add_res.ok) and int(add_res.added_count) == 1, "edit_points adds 1 authored point")

	var p_cell1 := _pt(Vector3(80.25, 2.0, -10.5), "res://obj/rock.tres", "handplaced", 1.0)
	var move_res: Dictionary = ClassDB.class_call_static("CopiaSets", "edit_points", scratch, CELL, "handplaced", p_cell0, p_cell1, "authored")
	check(bool(move_res.ok) and int(move_res.removed_count) == 1 and int(move_res.added_count) == 1, "cross-cell move removes old & adds new")
	check(move_res.cells.has(Vector2i(0, 0)) and move_res.cells.has(Vector2i(1, -1)), "cross-cell move reports both old and new cells")
	var read_hp: Dictionary = ClassDB.class_call_static("CopiaSets", "read_points", scratch, CELL, ALL, PackedStringArray(["handplaced"]), PackedStringArray())
	check(int(read_hp.count) == 1 and is_equal_approx(read_hp.transform[9], 80.25), "only moved point remains in handplaced")

	# 6. Auto-registration of brand-new authored set handpainted + erase_in_sphere + Undo round-trip.
	var paint_pts := {
		"transform": PackedFloat32Array([
			1, 0, 0, 0, 1, 0, 0, 0, 1, 10.0, 0.0, 10.0,
			1, 0, 0, 0, 1, 0, 0, 0, 1, 11.0, 0.0, 10.0,
			1, 0, 0, 0, 1, 0, 0, 0, 1, 30.0, 0.0, 10.0,
		]),
		"object": PackedInt32Array([0, 1, 0]),
		"object_paths": PackedStringArray(["res://obj/fern.tres", "res://obj/rock.tres"]),
		"keep": PackedFloat32Array([0.9, 0.95, 0.85]),
	}
	var add_paint: Dictionary = ClassDB.class_call_static("CopiaSets", "edit_points", scratch, CELL, "handpainted", {}, paint_pts, "authored")
	check(bool(add_paint.ok) and int(add_paint.added_count) == 3, "edit_points auto-registers and populates handpainted")
	var meta2: Dictionary = ClassDB.class_call_static("CopiaSets", "get_sets_meta", scratch)
	check(meta2.has("handpainted") and meta2.handpainted.kind == "authored", "handpainted auto-registered as authored")

	# Erase only ferns within radius 3m of (10.5, 0, 10) -> removes fern at (10,0,10), keeps rock at (11,0,10) and fern at (30,0,10).
	var erase_res: Dictionary = ClassDB.class_call_static("CopiaSets", "erase_in_sphere", scratch, CELL, "handpainted", Vector3(10.5, 0.0, 10.0), 3.0, PackedStringArray(["res://obj/fern.tres"]), "authored")
	check(bool(erase_res.ok) and int(erase_res.removed_count) == 1, "erase_in_sphere removes only filtered fern inside sphere")
	var after_erase: Dictionary = ClassDB.class_call_static("CopiaSets", "read_points", scratch, CELL, ALL, PackedStringArray(["handpainted"]), PackedStringArray())
	check(int(after_erase.count) == 2, "2 points remain after filtered sphere erase")

	# Undo by re-adding removed_points.
	var undo_res: Dictionary = ClassDB.class_call_static("CopiaSets", "edit_points", scratch, CELL, "handpainted", {}, erase_res.removed_points, "authored")
	check(bool(undo_res.ok) and int(undo_res.added_count) == 1, "undo re-adds removed_points cleanly")
	var after_undo: Dictionary = ClassDB.class_call_static("CopiaSets", "read_points", scratch, CELL, ALL, PackedStringArray(["handpainted"]), PackedStringArray())
	check(int(after_undo.count) == 3, "all 3 points restored after undo")

	# 7. Locked set refuses all writes and removal.
	var lock_res: Dictionary = ClassDB.class_call_static("CopiaSets", "set_meta", scratch, "handplaced", "authored", true)
	check(bool(lock_res.ok) and bool(lock_res.locked), "set_meta locks handplaced")
	var locked_edit: Dictionary = ClassDB.class_call_static("CopiaSets", "edit_points", scratch, CELL, "handplaced", p_cell1, {}, "authored")
	check(not bool(locked_edit.ok), "edit_points refused on locked set")
	var locked_rm: Dictionary = ClassDB.class_call_static("CopiaSets", "remove_set_checked", scratch, "handplaced", "authored", false)
	check(not bool(locked_rm.ok), "remove_set_checked refused on locked set")

	# Unlock and verify remove_set_checked succeeds for authored, fails for generated.
	ClassDB.class_call_static("CopiaSets", "set_meta", scratch, "handplaced", "authored", false)
	var bad_rm: Dictionary = ClassDB.class_call_static("CopiaSets", "remove_set_checked", scratch, "handplaced", "generated", false)
	check(not bool(bad_rm.ok), "remove_set_checked with generated intent refused on authored set")
	var ok_rm: Dictionary = ClassDB.class_call_static("CopiaSets", "remove_set_checked", scratch, "handplaced", "authored", true)
	check(bool(ok_rm.ok) and ok_rm.cells.size() == 1, "remove_set_checked removes unlocked authored set")

	remove_tree(scratch)
	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("COPIA_SETS_OWNERSHIP_TEST PASS")
		quit(0)
	else:
		print("COPIA_SETS_OWNERSHIP_TEST FAIL (%d)" % failures.size())
		quit(1)
