## CopiaSource3D contracts: two sources far apart load the union of their neighbourhoods and nothing
## between; disabling or freeing one unloads only what the other does not need; moving a source
## moves its loaded set; a source entering makes the store update without waiting for its
## interval; with overlapping sources a group takes the largest density and range scale among the
## sources that need it and goes back to the reduced values when the full source leaves, without
## being recreated; a reduced-density source alone draws the keep counts of its density; range
## scale 0.5 loads fewer cells and scales the range end of groups and the impostor swap distance;
## colliders exist only around sources with colliders, shadows follow sources with shadows;
## use_default_source off with no source loads nothing; load_sources_now loads every source in one
## call; streaming_settled fires once per load with two sources.
## Headless: the renderer is a dummy, so only bookkeeping is asserted. Objects are created in code
## and saved under a scratch directory in user://, which is deleted afterwards.
##
##   godot-4.7.2 --path demo --headless --script res://tests/copia_sources_test.gd
##
## Prints COPIA_SOURCES_TEST PASS or FAIL and exits 0 or 1. Run time: about 5 s.
extends SceneTree

const EXTENSION := "res://addons/copia/bin/copia.gdextension"
const ObjectScript := preload("res://addons/copia/copia_object.gd")
const RenderScript := preload("res://addons/copia/copia_render_settings.gd")
const PhysicsScript := preload("res://addons/copia/copia_physics_settings.gd")
const StoreScript := preload("res://addons/copia/copia_store_3d.gd")
const SourceScript := preload("res://addons/copia/copia_source_3d.gd")
const CELL := 64.0
const NEAR_A := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const MIDDLE := [Vector2i(10, 0)]
const NEAR_B := [Vector2i(20, 0), Vector2i(21, 0), Vector2i(20, 1)]
const A := Vector3(32, 0, 32)
const B := Vector3(20 * 64 + 32, 0, 32)
const C := Vector3(10 * 64 + 32, 0, 32)
const P := Vector3(10, 0, 10)  # 54 m from cells 1_0 and 0_1: within full ranges, beyond half

var failures: Array[String] = []
var scratch := "user://copia_sources_test_%d" % OS.get_process_id()
var data := ""
var grass_path := ""
var tree_path := ""
var rock_path := ""
var rng := RandomNumberGenerator.new()


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


func make_objects() -> void:
	DirAccess.make_dir_recursive_absolute(scratch.path_join("objects"))
	grass_path = scratch.path_join("objects/grass.tres")
	tree_path = scratch.path_join("objects/tree.tres")
	rock_path = scratch.path_join("objects/rock.tres")
	var grass := ObjectScript.new()
	grass.mesh = BoxMesh.new()
	grass.render = RenderScript.new()
	grass.render.batch_size = 16.0
	grass.render.visibility_range_end = 40.0
	grass.render.shadow_range = 30.0
	check(ResourceSaver.save(grass, grass_path) == OK, "grass object saved")
	var tree := ObjectScript.new()
	tree.mesh = CylinderMesh.new()
	tree.impostor_mesh = QuadMesh.new()
	tree.render = RenderScript.new()
	tree.render.draw_mode = RenderScript.DrawMode.INSTANCE
	tree.render.visibility_range_end = 60.0
	tree.render.impostor_range_end = 150.0
	check(ResourceSaver.save(tree, tree_path) == OK, "tree object saved")
	var rock := ObjectScript.new()
	rock.mesh = BoxMesh.new()
	rock.render = RenderScript.new()
	rock.render.batch_size = 32.0
	rock.render.visibility_range_end = 50.0
	rock.physics = PhysicsScript.new()
	check(ResourceSaver.save(rock, rock_path) == OK, "rock object saved")
	ObjectScript.clear_cache()


func points_for(cells: Array) -> Dictionary:
	var transform := PackedFloat32Array()
	var object := PackedInt32Array()
	var keep := PackedFloat32Array()
	var add := func(index: int, origin: Vector3) -> void:
		transform.append_array(PackedFloat32Array([1, 0, 0, 0, 1, 0, 0, 0, 1, origin.x, origin.y, origin.z]))
		object.append(index)
		keep.append(rng.randf())
	for cell: Vector2i in cells:
		var base := Vector3(cell.x * CELL, 0, cell.y * CELL)
		for i in 300:
			add.call(0, base + Vector3(rng.randf() * CELL, 0, rng.randf() * CELL))
		for i in 8:
			add.call(1, base + Vector3(rng.randf_range(5, 59), 0, rng.randf_range(5, 59)))
		for i in 10:
			add.call(2, base + Vector3(rng.randf() * CELL, 0, rng.randf() * CELL))
	return {"transform": transform, "object": object, "keep": keep, "object_paths": PackedStringArray([grass_path, tree_path, rock_path])}


func new_store(default_source := true) -> Node3D:
	var node: Node3D = StoreScript.new()
	node.data_directory = data
	node.cell_size = CELL
	node.impostor_cell_size = 128.0
	node.update_interval = 0.02
	node.collider_distance = 50.0
	node.use_default_source = default_source
	root.add_child(node)
	return node


## A source in the tree at [param position] that applies to [param store] only.
func new_source(store: Node3D, position: Vector3, settings := {}) -> Node3D:
	var source: Node3D = SourceScript.new()
	for name in settings:
		source.set(name, settings[name])
	root.add_child(source)
	source.global_position = position
	source.store = source.get_path_to(store)
	return source


## Frames until the store has nothing pending for 100 ms, or the time runs out.
func settle(node: Node3D, seconds := 10.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	var quiet_since := -1
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if node.get_stats().pending != 0 or not node.is_settled():
			quiet_since = -1
		elif quiet_since < 0:
			quiet_since = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - quiet_since >= 100:
			return true
	return false


func update(node: Node3D) -> bool:
	node.update_streaming_all()
	return await settle(node)


func key(kind: String, path: String, cell: Vector2i) -> String:
	return "%s|%s|%s" % [kind, path, cell]


## {"kind|path|cell": group id} of a store's live groups.
func ids_of(node: Node3D) -> Dictionary:
	var result := {}
	for info in node.get_loaded_groups():
		result[key(info.kind, info.object_path, info.cell)] = info.group
	return result


func sorted_keys(groups: Dictionary) -> Array:
	var keys := groups.keys()
	keys.sort()
	return keys


## The group keys a store with only the default source at [param position] loads.
func reference(position: Vector3) -> Dictionary:
	var node := new_store()
	var result: Dictionary = node.load_now(position)
	check(result.ok, "reference load at %s: %s" % [position, result])
	var groups := ids_of(node)
	node.free()
	return groups


func union(first: Dictionary, second: Dictionary) -> Array:
	var merged := first.duplicate()
	merged.merge(second)
	return sorted_keys(merged)


func cells_of(groups: Dictionary, kind: String) -> Dictionary:
	var result := {}
	for name in groups:
		if name.begins_with(kind + "|"):
			result[name.get_slice("|", 2)] = true
	return result


func info_of(node: Node3D, groups: Dictionary, kind: String, path: String, cell: Vector2i) -> Dictionary:
	var id: int = groups.get(key(kind, path, cell), 0)
	return node.get_drawer().get_group_info(id) if id != 0 else {}


func test_neighbourhoods(ref_a: Dictionary, ref_b: Dictionary, ref_c: Dictionary) -> void:
	# No default source and no source: nothing.
	var empty := new_store(false)
	empty.update_streaming(A)
	check(await settle(empty), "settled without sources")
	check(empty.get_stats().groups == 0 and empty.get_stats().cells_cached == 0, "use_default_source off with no source loads nothing (%d groups)" % empty.get_stats().groups)
	empty.free()

	# Two sources far apart: their two neighbourhoods, nothing between.
	var store := new_store(false)
	var a := new_source(store, A)
	var b := new_source(store, B)
	check(await update(store), "settled with two sources")
	var groups := ids_of(store)
	check(sorted_keys(groups) == union(ref_a, ref_b), "two sources load the union of their neighbourhoods (%d groups, expected %d)" % [groups.size(), union(ref_a, ref_b).size()])
	var middle := false
	for name in groups:
		var far: bool = name.begins_with("impostor|")
		middle = middle or (not far and name.ends_with(str(MIDDLE[0]))) or (far and name.ends_with(str(Vector2i(5, 0))))
	check(not middle, "nothing between the two sources is loaded")
	var stats: Dictionary = store.get_stats()
	check(stats.sources.size() == 2 and stats.sources[0].groups.draw > 0 and stats.sources[1].groups.draw > 0, "get_stats lists both sources with their groups (%s)" % [stats.sources.map(func(s): return s.groups)])

	# Disabling one unloads only its own; the other's groups stay as they are.
	var a_ids := {}
	for name in ref_a:
		a_ids[name] = groups[name]
	b.enabled = false
	check(await settle(store), "settled after disabling a source")
	groups = ids_of(store)
	check(sorted_keys(groups) == sorted_keys(ref_a), "disabling one source unloads only its neighbourhood (%d groups)" % groups.size())
	check(groups == a_ids, "the other source's groups are not recreated")

	# Freeing one: the same; then a moved source moves its loaded set.
	b.enabled = true
	check(await settle(store), "settled after enabling the source again")
	a.free()
	check(await settle(store), "settled after freeing a source")
	check(sorted_keys(ids_of(store)) == sorted_keys(ref_b), "freeing one source unloads only its neighbourhood")
	b.global_position = C
	check(await update(store), "settled after moving a source")
	check(sorted_keys(ids_of(store)) == sorted_keys(ref_c), "a moved source's loaded set moves with it")

	# A source entering makes the store update without waiting for its interval.
	store.update_interval = 10.0
	var entering := new_source(store, A)
	await process_frame
	await process_frame
	stats = store.get_stats()
	check(stats.sources.size() == 2, "a source entering is picked up in the next frame, not at the update interval (%d sources)" % stats.sources.size())
	store.update_interval = 0.02
	entering.free()
	b.free()
	store.free()


func test_quality() -> void:
	var store := new_store(false)
	var reduced := new_source(store, A, {"density": 0.5, "range_scale": 0.5})
	check(await update(store), "settled with the reduced source")
	var groups := ids_of(store)
	var grass := info_of(store, groups, "draw", grass_path, Vector2i(0, 0))
	check(grass.get("density") == 0.5 and is_equal_approx(grass.params.visibility_end, 20.0), "reduced source alone: density 0.5, range end 20 (%s, %s)" % [grass.get("density"), grass.get("params", {}).get("visibility_end")])
	# The visible counts are the keep counts at density 0.5 (threshold index 2).
	var section: Dictionary = ClassDB.class_call_static("CopiaCells", "read_section", data.path_join("cells/0_0.copiacell"), grass_path, "draw")
	var expected := PackedInt32Array()
	var total := 0
	for b in section.batch_count:
		expected.append(section.keep_counts[b * 5 + 2])
		total += section.counts[b]
	check(grass.get("visible_counts") == expected and total == 300, "a reduced-density source draws the keep counts of its density (%s vs %s)" % [grass.get("visible_counts"), expected])
	var tree := info_of(store, groups, "draw", tree_path, Vector2i(0, 0))
	check(is_equal_approx(tree.get("impostor_link", {}).get("swap_distance", 0.0), 30.0), "reduced source alone: impostor swap at half the range (%s)" % [tree.get("impostor_link")])
	var impostor := info_of(store, groups, "impostor", tree_path, Vector2i(0, 0))
	check(is_equal_approx(impostor.get("params", {}).get("visibility_end", 0.0), 75.0), "reduced source alone: impostor range end scaled (%s)" % [impostor.get("params", {}).get("visibility_end")])
	var grass_id: int = groups[key("draw", grass_path, Vector2i(0, 0))]
	var tree_id: int = groups[key("draw", tree_path, Vector2i(0, 0))]

	# A full source joins: the shared groups take full quality, same ids.
	var full := new_source(store, A)
	check(await update(store), "settled with both sources")
	groups = ids_of(store)
	grass = info_of(store, groups, "draw", grass_path, Vector2i(0, 0))
	tree = info_of(store, groups, "draw", tree_path, Vector2i(0, 0))
	check(groups.get(key("draw", grass_path, Vector2i(0, 0))) == grass_id and groups.get(key("draw", tree_path, Vector2i(0, 0))) == tree_id, "the shared groups are not recreated when the full source joins")
	check(grass.get("density") == 1.0 and is_equal_approx(grass.params.visibility_end, 40.0), "both sources: the larger density and range (%s, %s)" % [grass.get("density"), grass.params.visibility_end])
	check(is_equal_approx(tree.get("impostor_link", {}).get("swap_distance", 0.0), 60.0), "both sources: full swap distance (%s)" % [tree.get("impostor_link")])
	var total_visible := 0
	for count in grass.visible_counts:
		total_visible += count
	check(total_visible == 300, "both sources: every grass instance is drawn (%d)" % total_visible)

	# The full source leaves: the reduced values come back, still the same ids.
	full.free()
	check(await update(store), "settled after the full source left")
	groups = ids_of(store)
	grass = info_of(store, groups, "draw", grass_path, Vector2i(0, 0))
	tree = info_of(store, groups, "draw", tree_path, Vector2i(0, 0))
	check(groups.get(key("draw", grass_path, Vector2i(0, 0))) == grass_id and groups.get(key("draw", tree_path, Vector2i(0, 0))) == tree_id, "the shared groups are not recreated when the full source leaves")
	check(grass.get("density") == 0.5 and is_equal_approx(grass.params.visibility_end, 20.0) and grass.visible_counts == expected, "after the full source left: density 0.5, range end 20 again")
	check(is_equal_approx(tree.get("impostor_link", {}).get("swap_distance", 0.0), 30.0), "after the full source left: swap at half the range again")
	reduced.free()
	store.free()

	# range_scale 0.5 loads fewer cells than 1 at the same place.
	var counts := []
	for scale in [1.0, 0.5]:
		var node := new_store(false)
		var source := new_source(node, P, {"range_scale": scale})
		check(await update(node), "settled with range scale %.1f" % scale)
		counts.append(cells_of(ids_of(node), "draw").size())
		source.free()
		node.free()
	check(counts[1] < counts[0], "range scale 0.5 loads fewer cells (%d against %d)" % [counts[1], counts[0]])


func test_colliders_and_shadows() -> void:
	var store := new_store(false)
	var a := new_source(store, A, {"colliders": false})
	var b := new_source(store, B)
	check(await update(store), "settled for colliders")
	var collider_cells := cells_of(ids_of(store), "collider")
	var near_b := true
	for cell in collider_cells:
		near_b = near_b and cell.begins_with("(2")
	check(not collider_cells.is_empty() and near_b, "colliders only around the source with colliders (%s)" % [collider_cells.keys()])
	check(cells_of(ids_of(store), "draw").has(str(Vector2i(0, 0))), "the source without colliders still loads draw groups")

	# Shadows: the grass shadow range (30 m) follows the sources with shadows on.
	var grass_id: int = ids_of(store).get(key("draw", grass_path, Vector2i(0, 0)), 0)
	var shadows := func() -> int: return store.get_drawer().get_group_info(grass_id).get("shadows_on", -1)
	check(shadows.call() > 0, "a source with shadows: grass near it casts (%d)" % shadows.call())
	a.shadows = false
	check(await update(store), "settled after shadows off")
	check(shadows.call() == 0, "only a far source has shadows: grass near the other casts none (%d)" % shadows.call())
	b.shadows = false
	check(await update(store), "settled with no shadow source")
	check(shadows.call() == 0, "no source with shadows: no grass casts (%d)" % shadows.call())
	a.shadows = true
	check(await update(store), "settled after shadows on again")
	check(shadows.call() > 0, "shadows come back with the source (%d)" % shadows.call())
	a.free()
	b.free()
	store.free()


func test_load_and_settled(ref_a: Dictionary, ref_b: Dictionary) -> void:
	var store := new_store(false)
	var a := new_source(store, A)
	var b := new_source(store, B)
	var result: Dictionary = store.load_sources_now()
	check(result.ok and store.is_settled() and store.get_stats().pending == 0, "load_sources_now ok and settled (%s)" % [result])
	check(sorted_keys(ids_of(store)) == union(ref_a, ref_b), "load_sources_now loads every source's surroundings in one call")
	print("COPIA_SOURCES_TEST load_sources_now: %d groups, %d instances, %d bodies in %.1f ms" % [result.groups, result.instances, result.bodies, result.usec / 1000.0])
	a.free()
	b.free()
	store.free()

	store = new_store(false)
	var settled := [0]
	store.streaming_settled.connect(func() -> void: settled[0] += 1)
	a = new_source(store, A)
	b = new_source(store, B)
	check(await update(store), "settled store streamed two sources")
	for i in 10:
		await process_frame
	check(settled[0] == 1, "streaming_settled fired once for two sources (%d)" % settled[0])
	b.global_position = C
	store.update_streaming_all()
	check(not store.is_settled(), "not settled right after a source moved to unloaded ground")
	check(await settle(store), "settled after the move")
	for i in 10:
		await process_frame
	check(settled[0] == 2, "streaming_settled fired again after the move (%d)" % settled[0])
	a.free()
	b.free()
	store.free()


func run() -> void:
	if not ClassDB.class_exists("CopiaDrawer"):
		GDExtensionManager.load_extension(EXTENSION)
	if not ClassDB.class_exists("CopiaDrawer"):
		push_error("Copia is not available")
		quit(1)
		return
	var started := Time.get_ticks_msec()
	rng.seed = 5
	remove_tree(scratch)
	data = scratch.path_join("data")
	make_objects()
	var writer := new_store()
	var report: Dictionary = writer.write([], points_for(NEAR_A + MIDDLE + NEAR_B))
	check(report.ok, "write: %s" % report.error)
	writer.free()
	var ref_a := reference(A)
	var ref_b := reference(B)
	var ref_c := reference(C)
	check(not ref_a.is_empty() and not ref_b.is_empty() and not ref_c.is_empty(), "the reference neighbourhoods are not empty")
	await test_neighbourhoods(ref_a, ref_b, ref_c)
	await test_quality()
	await test_colliders_and_shadows()
	await test_load_and_settled(ref_a, ref_b)
	ObjectScript.clear_cache()
	PhysicsScript.clear_cache()
	remove_tree(scratch)
	if failures.is_empty():
		print("COPIA_SOURCES_TEST PASS (%d ms)" % (Time.get_ticks_msec() - started))
		quit(0)
	else:
		print("COPIA_SOURCES_TEST FAIL (%d failures)" % failures.size())
		for failure in failures:
			print("  " + failure)
		quit(1)
