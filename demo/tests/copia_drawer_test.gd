## Copia run-time contracts: CopiaDrawer and CopiaColliders on sections of a real built cell.
## Groups are created and freed in budgeted steps, counts match, nothing is left after removal or
## after the owner is dropped, params round-trip, density follows the keep counts, shadow range
## switches by camera distance (one position or several) with a hysteresis margin (a source moving
## out across the band and back, per instance and per batch), the stats count server objects and
## drawn instances apart, set_groups_params reaches every listed group, group density scales the global one,
## per-surface materials round-trip, an impostor only hides near the camera while its linked child
## group is fully created (and goes back before any child is freed), instances below the impostor
## min scale keep their own range, warm-up objects go away, and a ray hit on a collider resolves
## to its group and instance with the instance's scale.
## Headless: the renderer is a dummy, so nothing about drawing is asserted. Step overshoot over
## the budget is printed, not asserted.
##
##   godot-4.7.2 --path demo --headless --script res://tests/copia_drawer_test.gd
##
## Prints COPIA_DRAWER_TEST PASS or FAIL and exits 0 or 1. Run time: about 2 s.
extends SceneTree

const EXTENSION := "res://addons/copia/bin/copia.gdextension"
const CELL := 64.0
const GRASS := "res://objects/grass.tres"
const TREE := "res://objects/tree.tres"

var failures: Array[String] = []
var scratch := "user://copia_drawer_test_%d" % OS.get_process_id()
var rng := RandomNumberGenerator.new()
var owner_node: Node3D
var scenario: RID
var mesh: BoxMesh
var objects := {
	GRASS: {"draw": "multimesh", "mesh_aabb": AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 1, 1)), "batch_size": 16.0},
	TREE: {"draw": "instance", "mesh_aabb": AABB(Vector3(-2, 0, -2), Vector3(4, 10, 4)), "collider": true, "impostor": true, "impostor_cell_size": CELL},
}
var overshoot := {}  # class -> [max overshoot usec, its step's created + freed, steps]


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


func make_store() -> String:
	var transform := PackedFloat32Array()
	var object := PackedInt32Array()
	var keep := PackedFloat32Array()
	for i in 600:
		var tree := i % 10 == 0
		var scale := rng.randf_range(0.8, 1.6)
		var origin := Vector3(rng.randf() * CELL, rng.randf() * 4.0, rng.randf() * CELL)
		transform.append_array(PackedFloat32Array([scale, 0, 0, 0, scale, 0, 0, 0, scale, origin.x, origin.y, origin.z]))
		object.append(1 if tree else 0)
		keep.append([1.0, 0.8, 0.6, 0.3, 0.1, rng.randf()][rng.randi() % 6])
	var result: Dictionary = ClassDB.instantiate("CopiaSets").apply(scratch, CELL, [], {"transform": transform, "object": object, "object_paths": PackedStringArray([GRASS, TREE]), "keep": keep})
	check(result.ok, "apply: " + str(result.get("error")))
	result = ClassDB.instantiate("CopiaBuild").build_cells(scratch, CELL, [Vector2i.ZERO], objects)
	check(result.ok, "build: " + str(result.get("error")))
	return scratch.path_join("cells/0_0.copiacell")


## Steps until nothing is pending; returns created and freed totals.
func drain(target: Object, budget: int) -> Vector2i:
	var totals := Vector2i.ZERO
	for i in 100000:
		var step: Dictionary = target.step(budget)
		totals += Vector2i(step.created, step.freed)
		var name: String = target.get_class()
		var entry: Array = overshoot.get(name, [0, 0, 0])
		entry[2] += 1
		if step.usec - budget > entry[0]:
			entry[0] = step.usec - budget
			entry[1] = step.created + step.freed
		overshoot[name] = entry
		if step.pending_create == 0 and step.pending_free == 0:
			break
	return totals


## Object ids of the drawer instances the scene culler finds in the cell.
func culled_ids() -> int:
	var found := 0
	for id in RenderingServer.instances_cull_aabb(AABB(Vector3(-10, -10, -10), Vector3(100, 40, 100)), scenario):
		if id == owner_node.get_instance_id():
			found += 1
	return found


func test_drawer(path: String) -> void:
	var cells: Object = ClassDB.instantiate("CopiaCells")
	var grass: Dictionary = cells.read_section(path, GRASS, "draw")
	var trees: Dictionary = cells.read_section(path, TREE, "draw")
	check(grass.get("kind") == "multimesh" and trees.get("kind") == "transforms", "sections read")
	var drawer: Object = ClassDB.instantiate("CopiaDrawer")
	drawer.set_scenario(scenario)
	var params := {"mesh": mesh.get_rid(), "visibility_begin": 1.5, "visibility_end": 300.0, "visibility_begin_margin": 0.5,
			"visibility_end_margin": 4.0, "fade_mode": RenderingServer.VISIBILITY_RANGE_FADE_SELF, "cast_shadows": RenderingServer.SHADOW_CASTING_SETTING_ON,
			"low_lod_shadows": false, "shadow_range": 0.0, "lod_bias": 2.0, "layers": 5, "gi_mode": 2, "extra_cull_margin": 1.0,
			"object_id": owner_node.get_instance_id(), "priority": 3.0}
	var batches: int = grass.batch_count
	var tree_count: int = trees.count
	var group_grass: int = drawer.add_multimesh_group(grass, params)
	var group_trees: int = drawer.add_instance_group(trees, {"mesh": mesh.get_rid(), "object_id": owner_node.get_instance_id(), "priority": 1.0})
	var info: Dictionary = drawer.get_group_info(group_grass)
	check(info.state == "queued" and info.count == batches, "multimesh group queued with one entry per batch")
	for key in params:
		check(info.params[key] == params[key], "param %s round-trips (%s against %s)" % [key, info.params[key], params[key]])
	var totals := drain(drawer, 20)
	var stats: Dictionary = drawer.get_stats()
	check(totals.x == batches + tree_count, "created %d objects, expected %d" % [totals.x, batches + tree_count])
	check(stats.multimeshes == batches and stats.objects == batches + tree_count, "RID counts after creation: %s" % stats)
	check(stats.instances == 600, "instances counts the points drawn (%d of 600)" % stats.instances)
	check(drawer.get_group_rids(group_trees).size() == tree_count, "instance group RIDs")
	check(drawer.get_group_info(group_grass).ready and drawer.get_group_info(group_trees).ready, "groups ready")
	# The dummy renderer gives meshes empty bounds, so the culler finds only the batches (custom AABB).
	check(culled_ids() >= batches, "scene culler finds the batches by object id (%d)" % culled_ids())

	# Live params: changed without recreating.
	drawer.set_group_params(group_grass, {"lod_bias": 0.5, "layers": 1, "low_lod_shadows": true})
	info = drawer.get_group_info(group_grass)
	check(info.params.lod_bias == 0.5 and info.params.layers == 1 and info.params.visibility_end == 300.0, "set_group_params merges")
	check(drawer.get_stats().objects == 2 * batches + tree_count and drawer.get_stats().instances == 600, "low-LOD shadow twins created, instances unchanged")
	drawer.set_group_params(group_grass, {"low_lod_shadows": false})
	check(drawer.get_stats().objects == batches + tree_count, "low-LOD shadow twins freed")

	# Per-surface materials: carried by single instances (the dummy renderer has no surfaces, so the
	# drawing itself is checked windowed by copia_draw_timing.gd --only=surface); a params update
	# replaces or clears them; a multimesh group keeps them as params only.
	var red := StandardMaterial3D.new()
	drawer.set_group_params(group_trees, {"surface_materials": [red.get_rid(), RID()]})
	check(drawer.get_group_info(group_trees).params.surface_materials == [red.get_rid(), RID()], "surface_materials round-trip")
	drawer.set_group_params(group_trees, {"lod_bias": 1.5})
	check(drawer.get_group_info(group_trees).params.surface_materials == [red.get_rid(), RID()], "an update without surface_materials keeps them")
	drawer.set_group_params(group_trees, {"surface_materials": []})
	check(drawer.get_group_info(group_trees).params.surface_materials == [], "surface_materials cleared")
	drawer.set_group_params(group_grass, {"surface_materials": [red.get_rid()]})
	drawer.set_group_params(group_grass, {"surface_materials": []})

	# Density from keep counts.
	var keep: PackedInt32Array = grass.keep_counts
	for level in [[1.0, 4], [0.75, 3], [0.5, 2], [0.25, 1], [0.0, 0]]:
		drawer.set_density(level[0])
		var visible: PackedInt32Array = drawer.get_group_info(group_grass).visible_counts
		var expected := PackedInt32Array()
		for b in batches:
			expected.append(keep[b * 5 + level[1]])
		check(visible == expected, "density %.2f shows keep counts at threshold %d" % [level[0], level[1]])
	drawer.set_density(1.0)
	# Group density: the global density times the group's share, by the same rule.
	for level in [[1.0, 0.5, 2], [0.5, 0.5, 1], [0.5, 1.0, 2], [1.0, 1.0, 4]]:
		drawer.set_density(level[0])
		drawer.set_group_density(group_grass, level[1])
		var visible: PackedInt32Array = drawer.get_group_info(group_grass).visible_counts
		var expected := PackedInt32Array()
		for b in batches:
			expected.append(keep[b * 5 + level[2]])
		check(visible == expected and drawer.get_group_density(group_grass) == level[1], "density %.2f x group density %.2f shows keep counts at threshold %d" % [level[0], level[1], level[2]])
	check(drawer.get_group_info(group_grass).density == 1.0, "group density reported")
	drawer.set_density(0.5)
	var drawn := tree_count
	for count in drawer.get_group_info(group_grass).visible_counts:
		drawn += count
	check(drawer.get_stats().instances == drawn and drawn < 600, "instances honours density (%d drawn at 0.5, stats %d)" % [drawn, drawer.get_stats().instances])
	drawer.set_density(1.0)
	check(drawer.get_stats().instances == 600 and drawer.get_stats().objects == batches + tree_count, "instances back to every point at density 1")

	# Shadow range by camera distance.
	drawer.set_group_params(group_trees, {"shadow_range": 50.0})
	drawer.update_camera(Vector3(32, 0, 32) + Vector3(5000, 0, 0))
	check(drawer.get_group_info(group_trees).shadows_on == 0, "no shadows far away")
	drawer.update_camera(Vector3(32, 0, 32))
	check(drawer.get_group_info(group_trees).shadows_on == tree_count, "all shadows near")
	drawer.update_camera(Vector3(-40, 0, 32))
	var partial: int = drawer.get_group_info(group_trees).shadows_on
	check(partial > 0 and partial < tree_count, "some shadows at the edge (%d of %d)" % [partial, tree_count])
	# Several positions: an object casts while within range of any of them.
	drawer.update_cameras(PackedVector3Array([Vector3(5000, 0, 0), Vector3(32, 0, 32)]))
	check(drawer.get_group_info(group_trees).shadows_on == tree_count, "all shadows near one of two positions")
	drawer.update_cameras(PackedVector3Array([Vector3(5000, 0, 0), Vector3(-5000, 0, 0)]))
	check(drawer.get_group_info(group_trees).shadows_on == 0, "no shadows far from both positions")
	drawer.update_cameras(PackedVector3Array([Vector3(-40, 0, 32), Vector3(5000, 0, 0)]))
	check(drawer.get_group_info(group_trees).shadows_on == partial, "the edge of one position casts as with it alone (%d)" % partial)
	drawer.update_cameras(PackedVector3Array([Vector3(-40, 0, 32), Vector3(104, 0, 32)]))
	var both: int = drawer.get_group_info(group_trees).shadows_on
	check(both > partial and both <= tree_count, "two edges cast the union (%d, one edge %d)" % [both, partial])
	drawer.update_cameras(PackedVector3Array())
	check(drawer.get_group_info(group_trees).shadows_on == 0, "no position: nothing within a shadow range casts")
	drawer.update_camera(Vector3(32, 0, 32))
	check(drawer.get_group_info(group_trees).shadows_on == tree_count, "update_camera is the one-position form")

	# Removal frees what was created; nothing left.
	drawer.remove_group(group_grass)
	drawer.remove_group(group_trees)
	totals = drain(drawer, 20)
	stats = drawer.get_stats()
	check(totals.y == batches + tree_count, "freed %d objects" % totals.y)
	check(stats.objects == 0 and stats.instances == 0 and stats.multimeshes == 0 and stats.pending_free == 0 and stats.groups == 0, "nothing left: %s" % stats)
	check(stats.created_total == stats.freed_total + 0, "created and freed totals match")

	# A dropped drawer frees everything it holds, created or queued.
	drawer.add_multimesh_group(grass, params)
	drawer.add_instance_group(trees, {"mesh": mesh.get_rid(), "object_id": owner_node.get_instance_id()})
	drawer.step(1)
	drain(drawer, 1000000)
	drawer.add_instance_group(trees, {"mesh": mesh.get_rid()})
	check(culled_ids() >= batches, "objects exist before the drop")
	drawer = null
	check(culled_ids() == 0, "a dropped drawer leaves no instance (%d found)" % culled_ids())

	# Warm-up objects are freed after two drawn frames, or 60 process frames headless.
	drawer = ClassDB.instantiate("CopiaDrawer")
	drawer.set_scenario(scenario)
	drawer.warm_up(mesh.get_rid(), RID(), true, true)
	check(drawer.get_stats().warm_up == 2, "warm-up objects exist")
	for i in 65:
		await process_frame
		drawer.step(1000)
	var after: Dictionary = drawer.get_stats()
	check(after.warm_up == 0 and after.objects == 0 and after.multimeshes == 0, "warm-up objects freed: %s (frames drawn %d)" % [after, Engine.get_frames_drawn()])


## The impostor batch may hide near the camera only while its child group is fully created, and
## goes back to begin 0 before any child object is freed.
func test_impostor_link(path: String) -> void:
	var cells: Object = ClassDB.instantiate("CopiaCells")
	var impostor_section: Dictionary = cells.read_section(path, TREE, "impostor")
	var trees: Dictionary = cells.read_section(path, TREE, "draw")
	check(impostor_section.get("batch_count") == 1, "one impostor batch per object and cell")
	var swap := 120.0
	for order in ["impostor_first", "child_first"]:
		var drawer: Object = ClassDB.instantiate("CopiaDrawer")
		drawer.set_scenario(scenario)
		var impostor: int = drawer.add_multimesh_group(impostor_section, {"mesh": mesh.get_rid(), "visibility_end": 2000.0, "visibility_begin_margin": 5.0, "priority": 0.0 if order == "impostor_first" else 9.0})
		var parented := PackedByteArray()
		for i in trees.count:
			parented.append(0 if i == 0 else 1)
		var child: int = drawer.add_instance_group(trees, {"mesh": mesh.get_rid(), "visibility_end": 400.0, "parented": parented, "priority": 1.0})
		drawer.link_impostor(impostor, child, swap)
		var violations := 0
		var saw_partial := false
		for i in 1000:
			var step: Dictionary = drawer.step(1)  # one object per step
			var imp: Dictionary = drawer.get_group_info(impostor)
			var kid: Dictionary = drawer.get_group_info(child)
			if imp.created == 1:
				var begin: float = imp.visibility_begins[0]
				var expected := swap if kid.ready else 0.0
				if not is_equal_approx(begin, expected):
					violations += 1
				if not kid.ready:
					saw_partial = true
			if step.pending_create == 0:
				break
		check(violations == 0, "%s: impostor begin is the swap distance exactly when the child is ready (%d violations)" % [order, violations])
		check(order == "child_first" or saw_partial, "%s: the child was observed partly created" % order)
		var kid_info: Dictionary = drawer.get_group_info(child)
		check(kid_info.has("impostor_link") and kid_info.impostor_link.parent.is_valid(), "%s: child reports its link and parent" % order)
		check(drawer.get_group_info(impostor).linked_children == PackedInt64Array([child]), "%s: impostor reports its child" % order)
		var begins: PackedFloat32Array = kid_info.visibility_begins
		check(begins[1] == 0.0, "%s: parented child objects have no range of their own" % order)
		# Removing the child: the impostor's begin is 0 before any child object is freed.
		drawer.remove_group(child)
		var pending: int = drawer.get_stats().pending_free
		check(pending == trees.count, "%s: child frees are queued (%d)" % [order, pending])
		check(drawer.get_group_info(impostor).visibility_begins[0] == 0.0, "%s: impostor begin back to 0 ahead of the child's frees" % order)
		drain(drawer, 1)
		check(drawer.get_group_info(impostor).visibility_begins[0] == 0.0, "%s: impostor stays at begin 0 without its child" % order)
		# Removing the impostor while linked unparents the child and restores its own range.
		child = drawer.add_instance_group(trees, {"mesh": mesh.get_rid(), "visibility_begin": 7.0, "visibility_end": 400.0})
		drawer.link_impostor(impostor, child, swap)
		drain(drawer, 1000000)
		check(drawer.get_group_info(impostor).visibility_begins[0] == swap, "%s: relinked ready child lets the impostor swap" % order)
		drawer.remove_group(impostor)
		kid_info = drawer.get_group_info(child)
		check(not kid_info.has("impostor_link") and kid_info.visibility_begins[0] == 7.0, "%s: removing the impostor gives the child its own range" % order)
		drain(drawer, 1000000)
		drawer.remove_group(child)
		drain(drawer, 1000000)
		var stats: Dictionary = drawer.get_stats()
		check(stats.objects == 0 and stats.instances == 0 and stats.multimeshes == 0, "%s: nothing left: %s" % [order, stats])


## impostor_min_scale: instances of a linked instance group below it keep their own range and
## take no visibility parent; the others swap with the impostor.
func test_impostor_min_scale(path: String) -> void:
	var cells: Object = ClassDB.instantiate("CopiaCells")
	var impostor_section: Dictionary = cells.read_section(path, TREE, "impostor")
	var trees: Dictionary = cells.read_section(path, TREE, "draw")
	var drawer: Object = ClassDB.instantiate("CopiaDrawer")
	drawer.set_scenario(scenario)
	var impostor: int = drawer.add_multimesh_group(impostor_section, {"mesh": mesh.get_rid(), "visibility_end": 2000.0})
	var child: int = drawer.add_instance_group(trees, {"mesh": mesh.get_rid(), "visibility_begin": 7.0, "visibility_end": 400.0, "impostor_min_scale": 1.2})
	drawer.link_impostor(impostor, child, 120.0)
	drain(drawer, 1000000)
	var begins: PackedFloat32Array = drawer.get_group_info(child).visibility_begins
	var t: PackedFloat32Array = trees.transforms
	var wrong := 0
	var below := 0
	for i in trees.count:
		var scale := Vector3(t[i * 12 + 3], t[i * 12 + 4], t[i * 12 + 5]).length()
		var expected := 0.0 if scale >= 1.2 else 7.0
		below += 1 if scale < 1.2 else 0
		if begins[i] != expected:
			wrong += 1
	check(below > 0 and below < trees.count, "both sides of the impostor min scale are present (%d of %d below)" % [below, trees.count])
	check(wrong == 0, "instances below impostor_min_scale keep their own range, the others are parented (%d wrong)" % wrong)
	check(drawer.get_group_info(impostor).visibility_begins[0] == 120.0, "the impostor swaps once the child is ready")
	drawer.set_group_params(child, {"impostor_min_scale": 0.0})
	begins = drawer.get_group_info(child).visibility_begins
	check(begins.count(0.0) == trees.count, "impostor_min_scale 0 parents every instance")


## shadow_range_margin: an object's shadows turn on within shadow_range of a position and off only
## beyond shadow_range + margin of every position; in the band between they keep their state. Per
## instance for a single-instance group, per batch for a multimesh group.
func test_shadow_margin() -> void:
	var drawer: Object = ClassDB.instantiate("CopiaDrawer")
	drawer.set_scenario(scenario)
	var params := {"mesh": mesh.get_rid(), "shadow_range": 50.0, "shadow_range_margin": 10.0}
	var single: int = drawer.add_instance_group({"kind": "transforms", "transforms": PackedFloat32Array([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0])}, params)
	var buffer := PackedFloat32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0])
	var batch_section := {"kind": "multimesh", "origins": PackedVector3Array([Vector3.ZERO]), "bounds": [AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))],
			"counts": PackedInt32Array([1]), "keep_counts": PackedInt32Array([1, 1, 1, 1, 1]), "buffers": [buffer]}
	var batched: int = drawer.add_multimesh_group(batch_section, params)
	drain(drawer, 1000000)
	check(drawer.get_group_info(single).params.shadow_range_margin == 10.0, "shadow_range_margin round-trips")
	var far := Vector3(5000, 0, 0)
	# [positions, expected state, what it shows]: a source moving out across the band and back.
	var sequence := [
		[[Vector3(40, 0, 0)], 1, "within the range: on"],
		[[Vector3(55, 0, 0)], 1, "in the band, coming from inside: stays on"],
		[[Vector3(59.5, 0, 0)], 1, "at the far edge of the band: still on"],
		[[Vector3(65, 0, 0)], 0, "beyond range + margin: off"],
		[[Vector3(55, 0, 0)], 0, "back in the band from outside: stays off"],
		[[Vector3(50.5, 0, 0)], 0, "just beyond the range: still off"],
		[[Vector3(45, 0, 0)], 1, "within the range again: on"],
		[[Vector3(55, 0, 0), far], 1, "in the band of one of two positions: stays on"],
		[[Vector3(65, 0, 0), Vector3(58, 0, 0)], 1, "beyond one, in the band of the other: stays on"],
		[[Vector3(65, 0, 0), far], 0, "beyond range + margin of both: off"],
		[[Vector3(55, 0, 0), Vector3(57, 0, 0)], 0, "in the band of both, coming from off: stays off"],
		[[Vector3(55, 0, 0), Vector3(49, 0, 0)], 1, "within the range of one: on"],
	]
	for entry in sequence:
		drawer.update_cameras(PackedVector3Array(entry[0]))
		for group in [single, batched]:
			var kind: String = "instance" if group == single else "batch"
			var on: int = drawer.get_group_info(group).shadows_on
			check(on == entry[1], "shadow margin, %s: %s (%d, expected %d)" % [kind, entry[2], on, entry[1]])
	# Margin 0 switches exactly at the range, as before.
	drawer.set_groups_params(PackedInt64Array([single, batched]), {"shadow_range_margin": 0.0})
	drawer.update_camera(Vector3(55, 0, 0))
	check(drawer.get_group_info(single).shadows_on == 0 and drawer.get_group_info(batched).shadows_on == 0, "margin 0: off just beyond the range")
	drawer.update_camera(Vector3(49.5, 0, 0))
	check(drawer.get_group_info(single).shadows_on == 1 and drawer.get_group_info(batched).shadows_on == 1, "margin 0: on just within the range")
	# set_groups_params gives every listed group the values; an unknown id is reported and skipped.
	drawer.set_groups_params(PackedInt64Array([single, batched]), {"extra_cull_margin": 3.0, "lod_bias": 2.0})
	check(drawer.get_group_info(single).params.extra_cull_margin == 3.0 and drawer.get_group_info(batched).params.extra_cull_margin == 3.0
			and drawer.get_group_info(batched).params.lod_bias == 2.0 and drawer.get_group_info(batched).params.shadow_range == 50.0,
			"set_groups_params merges the values into every listed group")
	drawer.set_group_params(single, {"extra_cull_margin": 3.0})
	check(drawer.get_group_info(single).params.extra_cull_margin == 3.0, "an unchanged value is accepted")


func test_colliders(path: String) -> void:
	var cells: Object = ClassDB.instantiate("CopiaCells")
	var collider: Dictionary = cells.read_section(path, TREE, "collider")
	check(collider.get("kind") == "transforms", "collider section read")
	var box := BoxShape3D.new()
	box.size = Vector3.ONE
	var space: RID = owner_node.get_world_3d().space
	var colliders: Object = ClassDB.instantiate("CopiaColliders")
	colliders.set_space(space)
	colliders.set_transform(Transform3D(Basis(), Vector3(1000, 0, 0)))
	var shapes := [{"shape": box.get_rid(), "transform": Transform3D(Basis(), Vector3(0, 0.5, 0))}]
	var group_cell: int = colliders.add_group(collider.transforms, shapes, {"collision_layer": 2, "collision_mask": 0, "object_id": owner_node.get_instance_id()})
	# Hand-made instances: uniform scale 2 and non-uniform scale (1, 3, 1), both at the origin
	# of their own spot, so a ray from above hits the scaled box top.
	var scaled := PackedFloat32Array([2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 3, 0, 0, 0, 1, 10, 0, 0])
	var group_scaled: int = colliders.add_group(scaled, shapes, {"collision_layer": 2, "object_id": owner_node.get_instance_id(), "priority": -1.0})
	var totals := drain(colliders, 20)
	check(totals.x == collider.count + 2, "bodies created: %d" % totals.x)
	check(colliders.get_stats().bodies == collider.count + 2, "body count")
	var rids: Array = colliders.get_group_rids(group_cell)
	var resolved := 0
	for i in rids.size():
		var found: Dictionary = colliders.find_body(rids[i])
		if found.get("group") == group_cell and found.get("index") == i:
			resolved += 1
	check(resolved == rids.size(), "find_body resolves every body")
	await physics_frame
	await physics_frame
	var state := PhysicsServer3D.space_get_direct_state(space)
	for case in [[Vector3(1000, 10, 0), 2.0, 0], [Vector3(1010, 10, 0), 3.0, 1]]:
		var query := PhysicsRayQueryParameters3D.create(case[0], case[0] - Vector3(0, 20, 0), 2)
		var hit := state.intersect_ray(query)
		check(not hit.is_empty(), "ray hits instance %d" % case[2])
		if hit.is_empty():
			continue
		check(is_equal_approx(hit.position.y, case[1]), "instance %d top at y=%.3f, expected %.1f (scale baked into the shape)" % [case[2], hit.position.y, case[1]])
		check(hit.collider == owner_node, "ray collider is the owner node")
		var found: Dictionary = colliders.find_body(hit.rid)
		check(found.get("group") == group_scaled and found.get("index") == case[2], "ray hit resolves to group and instance: %s" % found)
	colliders.remove_group(group_cell)
	colliders.remove_group(group_scaled)
	totals = drain(colliders, 20)
	var stats: Dictionary = colliders.get_stats()
	check(totals.y == collider.count + 2 and stats.bodies == 0 and stats.pending_free == 0, "bodies freed: %s" % stats)
	# A dropped owner frees its bodies.
	colliders.add_group(scaled, shapes, {"collision_layer": 2})
	drain(colliders, 1000000)
	colliders = null
	await physics_frame
	await physics_frame
	state = PhysicsServer3D.space_get_direct_state(space)
	var miss := state.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(1000, 10, 0), Vector3(1000, -10, 0), 2))
	check(miss.is_empty(), "a dropped CopiaColliders leaves no body")


func test_file_loader(path: String) -> void:
	var set_path := scratch.path_join("sets/default/0_0.copiaset")
	check(ResourceLoader.exists(path) and ResourceLoader.exists(set_path), "ResourceLoader.exists for both kinds")
	var extensions := ResourceLoader.get_recognized_extensions_for_type("CopiaFile")
	check(extensions.has("copiaset") and extensions.has("copiacell"), "recognized extensions: %s" % extensions)
	var built: Resource = load(path)
	check(built != null and built.get_class() == "CopiaFile" and built.kind == "cell" and built.cell == Vector2i.ZERO, "load() of a built cell gives a CopiaFile")
	if built:
		check(built.counts.instances == 600 and built.hash.length() == 64, "built cell counts and hash: %s" % built.counts)
	var set_file: Resource = load(set_path)
	check(set_file != null and set_file.kind == "set" and set_file.counts.points == 600 and set_file.cell_size == CELL, "load() of a set file gives a CopiaFile")


func run() -> void:
	if not ClassDB.class_exists("CopiaDrawer"):
		GDExtensionManager.load_extension(EXTENSION)
	if not ClassDB.class_exists("CopiaDrawer"):
		push_error("Copia is not available")
		quit(1)
		return
	var started := Time.get_ticks_msec()
	rng.seed = 11
	remove_tree(scratch)
	owner_node = Node3D.new()
	root.add_child(owner_node)
	scenario = owner_node.get_world_3d().scenario
	mesh = BoxMesh.new()
	var path := make_store()
	await test_drawer(path)
	await test_impostor_link(path)
	test_impostor_min_scale(path)
	test_shadow_margin()
	await test_colliders(path)
	test_file_loader(path)
	for name in overshoot:
		print("COPIA_DRAWER_TEST %s step_overshoot_max_usec=%d (that step did %d objects) over %d steps" % [name, overshoot[name][0], overshoot[name][1], overshoot[name][2]])
	remove_tree(scratch)
	owner_node.queue_free()
	if failures.is_empty():
		print("COPIA_DRAWER_TEST PASS (%d ms)" % (Time.get_ticks_msec() - started))
		quit(0)
	else:
		print("COPIA_DRAWER_TEST FAIL (%d failures)" % failures.size())
		for failure in failures:
			print("  " + failure)
		quit(1)
