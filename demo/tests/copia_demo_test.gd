## Copia demo smoke test: every demo object loads and CopiaObject.resolve returns it, the demo
## scene instantiates, generates a small store into a scratch directory (point count and
## directory are the scene's exported properties), the sets and built cells exist, and streaming
## around a position creates groups. Also loads the inspector script and builds its panel for the
## demo's store, whose build buttons run background builds. Headless: the renderer is a dummy, so only bookkeeping is asserted. The scratch
## directory under user:// is deleted afterwards.
##
##   godot-4.7.2 --path demo --headless --script res://tests/copia_demo_test.gd
##
## Prints COPIA_DEMO_TEST PASS or FAIL and exits 0 or 1. Run time: about 5 s.
extends SceneTree

const EXTENSION := "res://addons/copia/bin/copia.gdextension"
const ObjectScript := preload("res://addons/copia/copia_object.gd")
const InspectorScript := preload("res://addons/copia/copia_inspector.gd")
const OBJECTS := "res://copia_demo/objects/"
const POINTS := 6000

var failures: Array[String] = []
var scratch := "user://copia_demo_test_%d" % OS.get_process_id()


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


func settle(store: Node3D, seconds := 10.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	var quiet_since := -1
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if store.get_stats().pending != 0:
			quiet_since = -1
		elif quiet_since < 0:
			quiet_since = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - quiet_since >= 200:
			return true
	return false


func run() -> void:
	if not ClassDB.class_exists("CopiaDrawer"):
		GDExtensionManager.load_extension(EXTENSION)
	if not ClassDB.class_exists("CopiaDrawer"):
		push_error("Copia is not available")
		quit(1)
		return
	remove_tree(scratch)

	# Objects.
	var count := 0
	for file in DirAccess.get_files_at(OBJECTS):
		if file.begins_with("render_") or file.begins_with("physics_") or not file.ends_with(".tres"):
			continue
		var path := OBJECTS + file
		var object = ObjectScript.resolve(path)
		check(object != null and object is ObjectScript, "%s resolves to a CopiaObject" % file)
		if object == null:
			continue
		count += 1
		check(object.mesh != null, "%s has a mesh" % file)
		check(object.render != null and object.render.batch_size > 0.0, "%s has render settings" % file)
		check(object.descriptor(128.0).has("draw"), "%s gives a descriptor" % file)
		if file.begins_with("tree_"):
			check(object.impostor_mesh != null and object.physics != null and object.physics.min_scale > 0.0, "%s has an impostor and capsule colliders with a minimum scale" % file)
		if file.begins_with("rock_"):
			check(object.physics != null and object.physics.has_collider(), "%s has a collider" % file)
	check(count == 8, "eight demo objects are present (found %d)" % count)
	check(ObjectScript.resolve(OBJECTS + "rock_slab.tres").physics == ObjectScript.resolve(OBJECTS + "rock_boulder.tres").physics, "rocks share one physics settings resource")
	check(ObjectScript.resolve(OBJECTS + "grass_tuft.tres").render == ObjectScript.resolve(OBJECTS + "fern.tres").render, "ground cover shares one render settings resource")

	# The scene, generated small into a scratch directory.
	var packed: PackedScene = load("res://copia_demo/copia_demo.tscn")
	check(packed != null, "the demo scene loads")
	var demo: Node3D = packed.instantiate()
	demo.set("point_count", POINTS)
	demo.set("data_dir", scratch)
	root.add_child(demo)
	var store: Node3D = demo.get_store()
	check(store.data_directory == scratch, "the demo uses the overridden data directory")
	var sets: PackedStringArray = store.list_sets()
	check(sets.size() == 3 and sets.has("ground") and sets.has("rocks") and sets.has("trees"), "three sets were written: %s" % [sets])
	check(demo.points_written == int(POINTS * 0.8) + int(POINTS * 0.16) + int(POINTS * 0.04), "the written point count is the three sets' sum (%d)" % demo.points_written)
	check(DirAccess.dir_exists_absolute(scratch.path_join("cells")) and DirAccess.get_files_at(scratch.path_join("cells")).size() > 1, "built cells exist")
	check(store.stale_cells().is_empty(), "nothing is stale after generating")
	check(not store.read_points(Rect2(0, 0, 512, 512)).is_empty(), "the points read back")

	# Streaming around a position creates groups of every kind.
	store.update_streaming(Vector3(256, 3, 256))
	check(await settle(store), "streaming settled")
	var kinds: Dictionary = store.get_stats().groups_by_kind
	check(kinds.draw > 0, "draw groups were created (%s)" % [kinds])
	check(kinds.impostor > 0, "impostor groups were created (%s)" % [kinds])
	check(kinds.collider > 0, "collider groups were created (%s)" % [kinds])

	# A partial rewrite replaces what is drawn and keeps the store consistent.
	demo.get_node("FlyCamera").position = Vector3(256, 3, 256)
	var report: Dictionary = demo.regenerate_rocks()
	check(report.ok, "the rock rewrite wrote: %s" % report.error)
	check(store.stale_cells().is_empty(), "nothing is stale after the rewrite")
	store.update_streaming(Vector3(256, 3, 256))
	check(await settle(store), "streaming settled after the rewrite")
	store.density = 0.5
	check(is_equal_approx(store.density, 0.5), "density can be set")

	check(load("res://addons/copia/plugin.gd") != null and load("res://addons/copia/copia_inspector.gd") != null, "plugin and inspector scripts load")
	# The inspector script loads and makes its panel.
	# (EditorInspectorPlugin cannot be instantiated outside the editor, so only the panel is made.)
	var panel: Control = InspectorScript.make_panel(store)
	root.add_child(panel)
	await process_frame
	check(panel.get_child_count() > 0, "the inspector panel has content")
	var text := _label_texts(panel)
	check(text.contains("3 sets"), "the panel shows the totals: %s" % text)
	await panel._on_refresh()
	check(panel._status.text.begins_with("0 stale cells"), "Refresh reports the stale cells: %s" % panel._status.text)
	# The build buttons start a background build: the buttons are disabled until it is done, then
	# the status line gives the counts.
	panel._on_build_stale()
	check(store.is_building() and panel._build_stale.disabled and panel._rebuild.disabled, "Build stale cells runs in the background with the buttons disabled")
	check(await build_done(store), "the background build of the stale cells finishes")
	check(panel._status.text.contains("built 0 cells") and not panel._build_stale.disabled, "Build stale cells with nothing stale: %s" % panel._status.text)
	panel._on_rebuild()
	check(store.is_building(), "Rebuild all runs in the background")
	check(await build_done(store), "the background rebuild finishes")
	check(panel._status.text.contains("built ") and panel._status.text.contains("unchanged") and not panel._build_stale.disabled, "Rebuild all: %s" % panel._status.text)
	panel._pending_set = "trees"
	await panel._on_remove_confirmed()
	check(store.list_sets().size() == 2 and panel._status.text.begins_with("removed set trees"), "Remove deletes the set: %s" % panel._status.text)
	panel.queue_free()

	demo.queue_free()
	await process_frame
	await process_frame
	remove_tree(scratch)
	if failures.is_empty():
		print("COPIA_DEMO_TEST PASS")
		quit(0)
	else:
		print("COPIA_DEMO_TEST FAIL: %d failures" % failures.size())
		quit(1)


## Frames until the store's background build is done and applied (one more frame for the panel).
func build_done(store: Node3D, seconds := 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while store.is_building() and Time.get_ticks_msec() < deadline:
		await process_frame
	await process_frame
	return not store.is_building()


func _label_texts(node: Node) -> String:
	var text := ""
	if node is Label:
		text += node.text + "\n"
	for child in node.get_children():
		text += _label_texts(child)
	return text
