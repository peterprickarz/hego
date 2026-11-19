## HEGo Copia round trip through a real Houdini session. Needs a licensed Houdini Engine
## installation; starts its own named-pipe session and stops it at the end.
##
##   godot-4.7.2 --headless --path <project> --script res://tests/hego_copia_roundtrip_test.gd
##
## The project must have the hego, copia and hego_copia addons with their classes registered
## in the class cache (HEGo discovers the bridge's handlers by class), and the TEST FIXTURE
## tests/fixtures/hego_test_copia.hda (built by make_copia_fixture.py). The scene is built in
## code: a CopiaStore3D with a scratch data directory under user:// (deleted afterwards), a
## HEGoNode3D cooking the fixture with a Copia input row naming the store, and a probe
## HEGoCookExtension that keeps the cook state. Every step goes through HEGoNode3D.cook();
## nothing in the bridge is called by hand.
##
## Contracts checked: a first cook into an empty store writes exactly `count` points with the
## transforms Houdini's instancing rule gives (orient, scale, pscale; the fixture writes that
## basis as reference attributes), colour, custom data, keep and a pass-through column; cells
## are built and nothing is stale. An unchanged recook clears and respawns and rewrites no file.
## Spawning without clearing adds; clearing with a new seed replaces; count 0 with clearing
## empties the set; one cook writes two sets and leaves a third set alone; instance points sent
## with points_of_sets come back with the same basis; the fixture's `store` parameter names
## the store on every output point: blank with one store works, naming the empty B writes into
## B only on the first cook, naming A writes into A only, and blank with two stores is an
## error that writes nothing; errors reach HEGo's log and the report sits in the cook state.
##
## Prints HEGO_COPIA_ROUNDTRIP_TEST PASS or FAIL and exits 0 or 1. Run time: about 20 s (15 to 21 s measured).
extends SceneTree

const FIXTURE_DIR := "res://tests/fixtures"
const ASSET := "Sop/hego_test_copia"
const OutputScript := preload("res://addons/hego_copia/hego_copia_output.gd")
const InputScript := preload("res://addons/hego_copia/hego_copia_input.gd")
const StoreScript := preload("res://addons/copia/copia_store_3d.gd")
const ObjectScript := preload("res://addons/copia/copia_object.gd")
const ALL := Rect2(-100000, -100000, 200000, 200000)
const EPSILON := 1e-3
const COUNT := 24
const COPY_OFFSET := 100000.0
## HEGoLog's error level (not bound as a constant).
const LOG_ERROR := 4


## Keeps the cook state of the host's last cook, and why it failed.
class Probe extends HEGoCookExtension:
	var state := {}
	var failure := ""

	func cook_prepare(_host: Node, cook: Dictionary) -> Dictionary:
		state = cook
		failure = ""
		return {"ok": true}

	func cook_failed(_host: Node, _cook: Dictionary, message: String) -> void:
		failure = message


var failures: Array[String] = []
var scratch := "user://hego_copia_roundtrip_%d" % OS.get_process_id()
var api: HEGoAPI
var scene: Node3D
var host: HEGoNode3D
var probe: Probe
var store_a: Node3D
var store_b: Node3D
var object_path := ""


func _initialize() -> void:
	call_deferred("run")


func check(value: bool, description: String) -> void:
	print("  %s %s" % ["ok" if value else "FAIL", description])
	if not value:
		failures.append(description)


func remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for directory in DirAccess.get_directories_at(path):
		remove_tree(path.path_join(directory))
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)


## Every file under [param path] with its MD5 and modification time.
func snapshot(path: String, into := {}) -> Dictionary:
	if DirAccess.dir_exists_absolute(path):
		for directory in DirAccess.get_directories_at(path):
			snapshot(path.path_join(directory), into)
		for file in DirAccess.get_files_at(path):
			var full := path.path_join(file)
			into[full] = [FileAccess.get_md5(full), FileAccess.get_modified_time(full)]
	return into


func make_store(store_name: String) -> Node3D:
	var store: Node3D = StoreScript.new()
	store.name = store_name
	store.data_directory = scratch.path_join("data_" + store_name)
	store.cell_size = 64.0
	store.visible = false  # nothing streams in this test
	scene.add_child(store)
	store.owner = scene
	return store


## Store points as {origin, basis, set, object, keep, color, custom, id}, keyed by fixture_id.
func points_by_id(store: Node, set_name := "") -> Dictionary:
	var read: Dictionary = store.read_points(ALL, PackedStringArray([set_name]) if not set_name.is_empty() else PackedStringArray())
	var transform: PackedFloat32Array = read.transform
	var colors: PackedFloat32Array = read.get("color", PackedFloat32Array())
	var customs: PackedFloat32Array = read.get("custom", PackedFloat32Array())
	var keeps: PackedFloat32Array = read.get("keep", PackedFloat32Array())
	var ids: Variant = read.get("extra", {}).get("fixture_id")
	var result := {}
	for i in int(read["count"]):
		var k := i * 12
		var id: float = ids[i] if ids != null else -1.0 - i
		result[id] = {
			"origin": Vector3(transform[k + 9], transform[k + 10], transform[k + 11]),
			"basis": Basis(Vector3(transform[k], transform[k + 1], transform[k + 2]), Vector3(transform[k + 3], transform[k + 4], transform[k + 5]), Vector3(transform[k + 6], transform[k + 7], transform[k + 8])),
			"set": read.set_names[read["set"][i]], "object": read.object_paths[read["object"][i]],
			"keep": keeps[i] if keeps.size() > i else 1.0,
			"color": Vector4(colors[i * 4], colors[i * 4 + 1], colors[i * 4 + 2], colors[i * 4 + 3]) if colors.size() > i * 4 else Vector4(NAN, NAN, NAN, NAN),
			"custom": Vector4(customs[i * 4], customs[i * 4 + 1], customs[i * 4 + 2], customs[i * 4 + 3]) if customs.size() > i * 4 else Vector4(NAN, NAN, NAN, NAN),
		}
	return result


func count_of(store: Node, set_name: String) -> int:
	return int(store.read_points(ALL, PackedStringArray([set_name])).get("count", -1))


func same_vector(a: Vector3, b: Vector3) -> bool:
	return (a - b).length() <= EPSILON * maxf(1.0, b.length())


func same_basis(a: Basis, b: Basis) -> bool:
	return same_vector(a.x, b.x) and same_vector(a.y, b.y) and same_vector(a.z, b.z)


## The cooked output of the host's asset, straight from Houdini: {name: Array}.
func houdini_points() -> Dictionary:
	var names := ["fixture_id", "fixture_basis_x", "fixture_basis_y", "fixture_basis_z", "orient", "scale", "pscale", "Cd",
		"hegocopia_custom", "hegocopia_keep", "hegocopia_set", "hegocopia_store", "hegocopia_clear", "hegocopia_object"]
	var asset := host.hego_get_asset_node()
	var output: HEGoPointOutput = await host.agent.task(asset.get_point_output(PackedStringArray(names)))
	var result := {}
	if output == null or not output.is_valid():
		return result
	result["P"] = output.get_attribute("P")
	for name in names:
		result[name] = output.get_attribute(name)
	return result


func set_parms(values: Dictionary) -> void:
	var asset := host.agent.asset(host.asset_name)
	if not await host.agent.instantiate(asset, host.parm_stash):
		check(false, "the fixture instantiates")
		return
	var applied = await host.agent.task(asset.set_parms_batch(values))
	check(applied != null, "parameters set: %s" % [values])


func set_input(store: Node, settings := {}) -> void:
	var row_settings := {"copia_input": true}
	row_settings.merge(settings, true)
	host.hego_set_input_stash([{"inputs": [str(scene.get_path_to(store))] if store != null else [], "settings": row_settings}])


## Cooks the host and returns the bridge's report (empty when there is none).
func cook(label: String) -> Dictionary:
	print("- " + label)
	await host.cook()
	if not host.hego_did_last_cook_succeed():
		print("    cook failed: " + probe.failure)
	var report: Variant = probe.state.get(OutputScript.REPORT_KEY, {})
	return report if report is Dictionary else {}


func run() -> void:
	var started := Time.get_ticks_msec()
	var watchdog := create_timer(600.0)
	watchdog.timeout.connect(func() -> void:
		push_error("HEGO_COPIA_ROUNDTRIP_TEST FAIL: timed out")
		quit(1))
	var separator := ";" if OS.get_name() == "Windows" else ":"
	# The named-pipe server inherits this, so it finds the fixture HDA.
	OS.set_environment("HOUDINI_OTLSCAN_PATH", ProjectSettings.globalize_path(FIXTURE_DIR) + separator + "&")
	api = HEGoAPI.get_singleton()
	if not api.start_session(HEGoAPI.SESSION_NAMED_PIPE, "hego_copia_roundtrip_%d" % OS.get_process_id()):
		push_error("HEGO_COPIA_ROUNDTRIP_TEST FAIL: could not start the test's Houdini session")
		quit(1)
		return
	remove_tree(scratch)
	DirAccess.make_dir_recursive_absolute(scratch.path_join("objects"))
	object_path = scratch.path_join("objects/fixture_box.tres")
	var object := ObjectScript.new()
	object.mesh = BoxMesh.new()
	check(ResourceSaver.save(object, object_path) == OK, "the fixture object is saved")
	ObjectScript.clear_cache()

	scene = Node3D.new()
	scene.name = "Scene"
	root.add_child(scene)
	current_scene = scene
	store_a = make_store("StoreA")
	host = HEGoNode3D.new()
	host.name = "Generator"
	scene.add_child(host)
	host.owner = scene
	host.asset_name = ASSET
	host.set_meta(OutputScript.META_KEY, {"extra_attributes": PackedStringArray(["fixture_id"])})
	probe = Probe.new()
	probe.name = "Probe"
	host.add_child(probe)

	var discovered := HEGoOutputHandler.extension_handlers().map(func(h: Object) -> String: return h.get_script().resource_path)
	var discovered_inputs := HEGoInputNodes.extension_handlers().map(func(h: Object) -> String: return h.get_script().resource_path)
	check(discovered.has("res://addons/hego_copia/hego_copia_output.gd") and discovered_inputs.has("res://addons/hego_copia/hego_copia_input.gd"), "HEGo discovers both bridge handlers")

	await test_first_and_unchanged()
	await test_clear_rules()
	await test_two_sets()
	await test_copy()
	await test_two_stores()
	await test_input_error()

	scene.queue_free()
	await process_frame
	api.stop_session()
	remove_tree(scratch)
	var elapsed := Time.get_ticks_msec() - started
	if failures.is_empty():
		print("HEGO_COPIA_ROUNDTRIP_TEST PASS (%d ms)" % elapsed)
		quit(0)
	else:
		print("HEGO_COPIA_ROUNDTRIP_TEST FAIL: %d failures" % failures.size())
		for failure in failures:
			print("  - " + failure)
		quit(1)


## Compares every spawned point of the last cook with the store, by fixture_id.
func check_spawned(label: String) -> void:
	var cooked := await houdini_points()
	check(not cooked.is_empty() and cooked.fixture_id.size() > 0, label + ": the cooked points can be read back")
	if cooked.is_empty():
		return
	var stored := points_by_id(store_a)
	var compared := 0
	var bad := []
	for i in cooked.fixture_id.size():
		if int(cooked.hegocopia_clear[i]) == 1 or float(cooked.fixture_id[i]) >= COPY_OFFSET:
			continue
		compared += 1
		var point: Dictionary = stored.get(float(cooked.fixture_id[i]), {})
		if point.is_empty():
			bad.append("id %d missing" % cooked.fixture_id[i])
			continue
		var reference := Basis(cooked.fixture_basis_x[i], cooked.fixture_basis_y[i], cooked.fixture_basis_z[i])
		var o: Vector4 = cooked.orient[i]
		var by_rule := Basis(Quaternion(o.x, o.y, o.z, o.w)) * Basis.from_scale(cooked.scale[i] * float(cooked.pscale[i]))
		var cd: Vector3 = cooked.Cd[i]
		if not same_vector(point.origin, cooked.P[i]):
			bad.append("id %d origin %s, Houdini %s" % [cooked.fixture_id[i], point.origin, cooked.P[i]])
		if not same_basis(point.basis, reference):
			bad.append("id %d basis %s, Houdini %s" % [cooked.fixture_id[i], point.basis, reference])
		if not same_basis(by_rule, reference):
			bad.append("id %d: the rule rotation(orient) * scale * pscale gives %s, Houdini %s" % [cooked.fixture_id[i], by_rule, reference])
		if (Vector4(cd.x, cd.y, cd.z, 1.0) - point.color).length() > EPSILON or (point.custom - cooked.hegocopia_custom[i]).length() > EPSILON \
				or absf(point.keep - cooked.hegocopia_keep[i]) > EPSILON or point.object != cooked.hegocopia_object[i] or point.set != cooked.hegocopia_set[i]:
			bad.append("id %d data %s / %s %s %s" % [cooked.fixture_id[i], point, cd, cooked.hegocopia_custom[i], cooked.hegocopia_keep[i]])
	var tilted := 0
	var stretched := 0
	for i in cooked.fixture_id.size():
		if int(cooked.hegocopia_clear[i]) == 0:
			tilted += int(absf((cooked.fixture_basis_y[i] as Vector3).normalized().y) < 0.99)
			stretched += int(cooked.scale[i] != Vector3.ONE and absf(float(cooked.pscale[i]) - 1.0) > 0.05)
	check(compared > 0 and bad.is_empty(), "%s: %d spawned points have Houdini's transform, colour, custom, keep, object, set and fixture_id %s" % [label, compared, bad.slice(0, 3)])
	check(tilted == compared and stretched > 0, "%s: the points are tilted and some have non-uniform scale and pscale, so orient order, scale order and pscale matter" % label)


func test_first_and_unchanged() -> void:
	await set_parms({"seed": 1, "count": COUNT, "size": 128.0, "object": object_path, "set": "fixture", "second_set": "", "copy_set": "", "clear": 1})
	set_input(store_a)
	var report := await cook("cook 1 into an empty store")
	check(host.hego_did_last_cook_succeed(), "cook 1 succeeds (%s)" % probe.failure)
	check(report.get("point_count") == COUNT and report.get("clear_count") == 0 and report.get("errors", [1]).is_empty() and report.get("stores", {}).keys() == ["StoreA"], "cook 1: the report in the cook state: %s" % [report])
	check(count_of(store_a, "fixture") == COUNT, "cook 1: the store holds exactly %d points (%d)" % [COUNT, count_of(store_a, "fixture")])
	await check_spawned("cook 1")
	var ids := points_by_id(store_a).keys()
	ids.sort()
	check(ids.size() == COUNT and ids[0] == 1.0 and ids[-1] == float(COUNT), "cook 1: fixture_id passes through")
	var built := Array(DirAccess.get_files_at(store_a.data_directory.path_join("cells"))).filter(func(f: String) -> bool: return f.ends_with(".copiacell"))
	check(not built.is_empty() and store_a.stale_cells().is_empty(), "cook 1: cells are built (%d) and none is stale" % built.size())
	var cooked := await houdini_points()
	check(cooked.get("hegocopia_store", []).count("") == COUNT, "cook 1: with the store parameter blank the spawned points name no store, which one store allows")

	var before := snapshot(store_a.data_directory)
	await create_timer(1.1).timeout  # modification times have a resolution of one second
	report = await cook("cook 2, unchanged")
	check(host.hego_did_last_cook_succeed(), "cook 2 succeeds (%s)" % probe.failure)
	var cells_with_points: int = (store_a.cell_points(Rect2(), PackedStringArray(["fixture"])).cell as PackedStringArray).size()
	check(report.get("clear_count") == cells_with_points and report.get("point_count") == COUNT, "cook 2: the cell points come back as %d clear points with %d spawned (%s)" % [cells_with_points, COUNT, report])
	check(count_of(store_a, "fixture") == COUNT, "cook 2: still %d points, not twice as many (%d)" % [COUNT, count_of(store_a, "fixture")])
	var after := snapshot(store_a.data_directory)
	var changed := []
	for path in after:
		if before.get(path) != after[path]:
			changed.append(path.get_file())
	for path in before:
		if not after.has(path):
			changed.append(path.get_file() + " (deleted)")
	var write: Dictionary = report.get("stores", {}).get("StoreA", {}).get("write", {})
	check(changed.is_empty() and write.get("apply", {}).get("written", [1]).is_empty(), "cook 2: no file was rewritten (%s; apply: %s)" % [changed, write.get("apply", {}).get("written")])
	cooked = await houdini_points()
	check(not cooked.get("hegocopia_store", []).is_empty() and cooked.get("hegocopia_store", []).count("") == cooked.get("hegocopia_store", []).size(), "cook 2: every output point, spawned or clear, carries the blank store parameter")


func test_clear_rules() -> void:
	await set_parms({"seed": 2, "clear": 0})
	var report := await cook("clear off, seed 2")
	check(report.get("clear_count") == 0 and count_of(store_a, "fixture") == 2 * COUNT, "spawning without clearing adds: %d points" % count_of(store_a, "fixture"))

	await set_parms({"seed": 3, "clear": 1})
	var old := points_by_id(store_a, "fixture").values().map(func(p: Dictionary) -> Vector3: return p.origin)
	report = await cook("clear on, seed 3")
	var now := points_by_id(store_a, "fixture").values().map(func(p: Dictionary) -> Vector3: return p.origin)
	var kept := now.filter(func(o: Vector3) -> bool: return old.has(o))
	check(count_of(store_a, "fixture") == COUNT and kept.is_empty(), "clearing with a new seed replaces: %d points, %d old ones left" % [now.size(), kept.size()])
	await check_spawned("seed 3")

	# Nothing is cleared implicitly: no instances and no clear points leave the set as it was.
	await set_parms({"count": 0, "clear": 0})
	var before := snapshot(store_a.data_directory)
	var held := count_of(store_a, "fixture")
	await create_timer(1.1).timeout  # modification times have a resolution of one second
	var cursor := HEGoLog.get_singleton().get_cursor()
	report = await cook("count 0, clear off")
	var logged := HEGoLog.get_singleton().get_entries_since(cursor, LOG_ERROR).filter(func(e: Dictionary) -> bool: return str(e.message).begins_with("Copia"))
	var changed := []
	var after := snapshot(store_a.data_directory)
	for path in after:
		if before.get(path) != after[path]:
			changed.append(path.get_file())
	for path in before:
		if not after.has(path):
			changed.append(path.get_file() + " (deleted)")
	check(host.hego_did_last_cook_succeed() and count_of(store_a, "fixture") == held and held == COUNT, "count 0, clear off: the set keeps its %d points (%d)" % [held, count_of(store_a, "fixture")])
	check(changed.is_empty() and store_a.stale_cells().is_empty(), "count 0, clear off: no set file or built cell changed (%s)" % [changed])
	# An output with no points at all: HEGo's output summary then lists no hegocopia_ attribute,
	# so should_handle() skips the bridge and there is no report. When there is one, it is empty.
	var quiet: bool = report.is_empty() or (report.get("point_count") == 0 and report.get("clear_count") == 0 and report.get("errors", [1]).is_empty() and report.get("warnings", [1]).is_empty())
	check(quiet and logged.is_empty(), "count 0, clear off: no points, no clears and no error (report %s, handler %s)" % [report, "skipped" if report.is_empty() else "ran"])

	await set_parms({"count": 0, "clear": 1})
	report = await cook("count 0, clear on")
	check(host.hego_did_last_cook_succeed() and report.get("point_count") == 0 and report.get("clear_count", 0) > 0, "count 0: only clear points are sent (%s)" % [report])
	check(count_of(store_a, "fixture") == 0, "count 0 with clearing empties the set in those cells (%d)" % count_of(store_a, "fixture"))


func test_two_sets() -> void:
	# A third set, written from GDScript, in cells the HDA clears.
	var third := OutputScript.write_attributes({
		"P": [Vector3(10, 0, 10), Vector3(-20, 0, -30)], "hegocopia_object": [object_path, object_path], "hegocopia_set": ["third", "third"]}, store_a)
	check(third.ok and count_of(store_a, "third") == 2, "the third set is written with store.write")
	await set_parms({"seed": 4, "count": COUNT, "second_set": "fixture_b"})
	for attempt in 2:
		var report := await cook("second_set, cook %d" % (attempt + 1))
		check(count_of(store_a, "fixture") == COUNT / 2 and count_of(store_a, "fixture_b") == COUNT / 2, "second_set cook %d: both sets are written (%d + %d)" % [attempt + 1, count_of(store_a, "fixture"), count_of(store_a, "fixture_b")])
		check(count_of(store_a, "third") == 2, "second_set cook %d: clearing leaves the third set alone (%d)" % [attempt + 1, count_of(store_a, "third")])
		if attempt == 1:
			check(report.get("clear_count", 0) >= 2, "second_set cook 2: both sets are cleared (%s clear points)" % report.get("clear_count"))
	await set_parms({"seed": 5, "second_set": ""})
	await cook("back to one set")
	store_a.remove_set("fixture_b")
	check(count_of(store_a, "fixture") == COUNT and count_of(store_a, "fixture_b") == 0, "one set again: %d points" % count_of(store_a, "fixture"))


func test_copy() -> void:
	var originals := points_by_id(store_a, "fixture")
	await set_parms({"copy_set": "fixture"})
	set_input(store_a, {"points_of_sets": ["fixture"]})
	var report := await cook("copy_set with points_of_sets")
	check(host.hego_did_last_cook_succeed(), "the copy cook succeeds (%s)" % probe.failure)
	var after := points_by_id(store_a, "fixture")
	var copies := 0
	var bad := []
	for id in originals:
		var copy: Dictionary = after.get(id + COPY_OFFSET, {})
		if copy.is_empty():
			bad.append("id %d has no copy" % id)
			continue
		copies += 1
		var original: Dictionary = originals[id]
		if not same_vector(copy.origin, original.origin + Vector3(1000, 0, 0)) or not same_basis(copy.basis, original.basis) or copy.object != original.object:
			bad.append("id %d: %s %s, original %s %s" % [id, copy.origin, copy.basis, original.origin, original.basis])
		elif (copy.color - original.color).length() > EPSILON or (copy.custom - original.custom).length() > EPSILON or absf(copy.keep - original.keep) > EPSILON:
			bad.append("id %d data: %s, original %s" % [id, copy, original])
	check(originals.size() == COUNT and copies == COUNT and bad.is_empty(), "copied points land 1000 m along X with the same basis, object, colour, custom and keep (%d copies) %s" % [copies, bad.slice(0, 3)])
	check(count_of(store_a, "fixture") == 2 * COUNT and report.get("point_count") == 2 * COUNT, "the copy cook respawns %d and copies %d (%d)" % [COUNT, COUNT, count_of(store_a, "fixture")])
	# Tidy up: drop the copies (outside the square, so no clear point covers them).
	await set_parms({"copy_set": ""})
	set_input(store_a)
	store_a.remove_set("fixture")
	await cook("respawn without copies")
	check(count_of(store_a, "fixture") == COUNT, "without copy_set the set holds %d points again" % count_of(store_a, "fixture"))


func test_two_stores() -> void:
	store_b = make_store("StoreB")
	var a_before := count_of(store_a, "fixture")

	await set_parms({"store": "StoreB"})
	set_input(store_b)
	var report := await cook("two stores, store B (empty), input from B")
	check(host.hego_did_last_cook_succeed() and report.get("errors", [1]).is_empty() and report.get("stores", {}).keys() == ["StoreB"], "a first cook naming the empty B goes to B only: %s %s" % [report.get("stores", {}).keys(), report.get("errors")])
	check(count_of(store_b, "fixture") == COUNT and count_of(store_a, "fixture") == a_before, "B holds the %d spawned points (%d) and A is unchanged (%d)" % [COUNT, count_of(store_b, "fixture"), count_of(store_a, "fixture")])
	var cooked := await houdini_points()
	check(cooked.get("hegocopia_store", []).count("StoreB") == COUNT, "the spawned points name StoreB from the store parameter")

	await set_parms({"store": "StoreA"})
	set_input(store_a)
	var b_before := count_of(store_b, "fixture")
	report = await cook("two stores, store A, input from A")
	check(report.get("stores", {}).keys() == ["StoreA"] and report.get("errors", [1]).is_empty(), "naming A the points go to A only: %s" % [report.get("stores", {}).keys()])
	check(count_of(store_a, "fixture") == a_before and count_of(store_b, "fixture") == b_before, "A is replaced in place (%d) and B is unchanged (%d)" % [count_of(store_a, "fixture"), count_of(store_b, "fixture")])

	await set_parms({"store": ""})
	var cursor := HEGoLog.get_singleton().get_cursor()
	report = await cook("two stores, blank store")
	var errors: Array = report.get("errors", [])
	check(not errors.is_empty() and "2 CopiaStore3D" in str(errors), "a blank store with two stores is an error: %s" % [errors])
	check(report.get("stores", {}).is_empty() and count_of(store_a, "fixture") == a_before and count_of(store_b, "fixture") == b_before, "that cook writes nothing to A or B")
	var logged := HEGoLog.get_singleton().get_entries_since(cursor, LOG_ERROR).filter(func(e: Dictionary) -> bool: return str(e.message).begins_with("Copia: "))
	check(not logged.is_empty(), "the bridge's error is in HEGo's log: %s" % [logged.map(func(e: Dictionary) -> String: return e.message)])
	print("    note: the cook itself reports success=%s with the bridge error" % host.hego_did_last_cook_succeed())


func test_input_error() -> void:
	var broken := Node3D.new()
	broken.set_script(StoreScript)
	broken.name = "Unset"
	broken.visible = false
	scene.add_child(broken)
	broken.owner = scene
	set_input(broken)
	var cursor := HEGoLog.get_singleton().get_cursor()
	await cook("input from a store with no data directory")
	var logged := HEGoLog.get_singleton().get_entries_since(cursor, LOG_ERROR).map(func(e: Dictionary) -> String: return e.message)
	check(not host.hego_did_last_cook_succeed() and "no data directory" in probe.failure, "an input the bridge cannot send fails the strict cook: %s" % probe.failure)
	check(logged.any(func(m: String) -> bool: return m.begins_with("Copia input:")), "the input error is in HEGo's log: %s" % [logged])
	set_input(store_a)
