## Exercises the parameter test scene, the panel's save/load actions, and a fresh HAPI session.
extends SceneTree

const Fixture := preload("res://tests/fixtures/parameters/parameter_types.tscn")
const PanelScene := preload("res://addons/hego/hego_control.tscn")

class TestTab extends "res://addons/hego/ui/hda_tab.gd":
	func get_preset_res_path():
		return "user://hego_parameter_preset_%d.tres" % OS.get_process_id()

class PairHost extends Node:
	var entries := []
	var stashes := {}

	func hego_get_panel_assets() -> Array:
		return entries

	func hego_set_asset_parm_stash(asset: HEGoAssetNode, preset: PackedByteArray) -> void:
		stashes[asset] = preset

var failures := 0
var api := HEGoAPI.get_singleton()


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


func value(asset: HEGoAssetNode, name: String) -> Dictionary:
	var data: Variant = await HEGoNodeUtil.await_task(root, asset.get_parms_dict())
	var pending: Array = data.values() if data is Dictionary else []
	while not pending.is_empty():
		var row: Dictionary = pending.pop_back()
		if row.name == name:
			return row
		pending.append_array(row.get("children", []))
		for group in row.get("instances", []):
			pending.append_array(group)
	return {}


func field(tab: Control, name: String, cls: String) -> Control:
	for control in tab.parm_vbox.find_children("*", cls, true, false):
		if control.get_meta("hego_parm_name", "") == name:
			return control
	return null


func surface_tabs(tab: Control) -> TabContainer:
	for control in tab.parm_vbox.find_children("*", "TabContainer", true, false):
		if control.get_tab_count() == 2 and control.get_tab_title(0) == "Surface":
			return control
	return null


func opaque_folder(tab: Control) -> FoldableContainer:
	for control in tab.parm_vbox.find_children("*", "FoldableContainer", true, false):
		if control.title == "Opaque data":
			return control
	return null


func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	var pipe := "hego_parameter_scene_%d" % OS.get_process_id()
	if not api.start_session(HEGoAPI.SESSION_NAMED_PIPE, pipe):
		push_error("Parameter scene requires a licensed Houdini session")
		quit(1)
		return
	var scene: Node = Fixture.instantiate()
	root.add_child(scene)
	current_scene = scene
	var producer: HEGoNode3D = scene.get_node("ValuesFixture")
	var consumer: HEGoNode3D = scene.get_node("StructureFixture")
	await producer.cook()
	await consumer.cook()
	check(producer.hego_did_last_cook_succeed() and consumer.hego_did_last_cook_succeed(), "The scene registers and cooks both HDAs")
	var panel := PanelScene.instantiate()
	var tab = panel.get_node("TabContainer/HDA")
	tab.set_script(TestTab)
	root.add_child(panel)
	tab.auto_recook_toggle.set_pressed_no_signal(false)
	await tab.set_selected_node(producer)
	var source := producer.hego_get_asset_node()
	check(field(tab, "ordinal_menu", "OptionButton") != null, "Ordered menu is reachable on the real HDA")
	var draft := field(tab, "conditional_text", "LineEdit") as LineEdit
	if draft:
		draft.grab_focus()
		draft.text = "Draft in progress"
		draft.text_changed.emit(draft.text)
		draft.caret_column = 5
	await tab._on_value_changed("marker", 19, source)
	draft = field(tab, "conditional_text", "LineEdit") as LineEdit
	check(draft != null and draft.has_focus() and draft.text == "Draft in progress" and draft.caret_column == 5,
			"A refresh preserves text being typed and the caret in another field")
	check((await value(source, "conditional_text")).raw_values[0] == "Visible while enabled", "Refreshing the UI does not commit the draft")
	await tab._on_value_changed("enabled", false, source)
	var amount := field(tab, "conditional_amount", "LineEdit") as LineEdit
	check(amount != null and not amount.editable and field(tab, "conditional_text", "LineEdit") == null, "Manual cook mode refreshes conditional fields")
	await tab._on_value_changed("press_action", 0, source)
	check((await value(source, "action_count")).get("values") == [1], "One button write invokes the callback exactly once")
	await tab.set_selected_node(consumer)
	var target := consumer.hego_get_asset_node()
	var tabs := surface_tabs(tab)
	var foldout := opaque_folder(tab)
	check(tabs != null and tabs.current_tab == 1 and foldout != null and not foldout.folded,
			"Real HDA opens the authored Pattern tab and expands Opaque data")
	if tabs and foldout:
		tabs.current_tab = 0
		foldout.fold()
	var options: Array = await tab._node_candidates(target, {"name": "source_node"})
	check(options.size() == 1 and options[0].node == source, "The picker offers the other live compatible fixture")
	await tab._on_node_requested("source_node", source, target)
	tabs = surface_tabs(tab)
	foldout = opaque_folder(tab)
	check(tabs != null and tabs.current_tab == 0 and foldout != null and foldout.folded,
			"Manual tab and fold selections survive a parameter refresh")
	check((await value(target, "source_node")).get("node_id", -1) == source.get_id(), "The panel connects the selected source")
	# A literal path and a scene binding can resolve to exactly the same live SOP.
	# Middle edits must carry only the explicitly bound row into the scene stash.
	var source_path: String = (await value(target, "source_node")).raw_values[0]
	await tab._on_value_changed("entry_source1", source_path, target)
	await tab._on_node_requested("entry_source2", source, target)
	await tab._on_node_requested("child2_source1", source, target)
	var block: Dictionary = await value(target, "entries")
	await tab._on_instance_requested("entries", block.id, 1, true, target)
	var link_key: String = tab.ParameterLinks.asset_key(consumer, target)
	var links: Dictionary = tab.ParameterLinks.saved(consumer, link_key)
	check(links.has("entry_source3") and links.has("child3_source1") and not links.has("entry_source2"), "Middle insertion shifts bound outer and nested rows and preserves literal paths")
	block = await value(target, "entries")
	await tab._on_instance_requested("entries", block.id, 2, false, target)
	await tab._on_instance_count_requested("entries", 1, target)
	links = tab.ParameterLinks.saved(consumer, link_key)
	check((await value(target, "entries")).instance_count == 1 and links.size() == 1 and links.has("source_node"), "Resizing removes deleted scene bindings and keeps unrelated links")
	await tab._on_node_requested("child1_source1", source, target)
	await tab.create_preset_file("linked")
	await tab._on_node_requested("source_node", null, target)
	check((await value(target, "source_node")).get("node_id", 0) == -1, "The panel clears the source")
	tab._select_preset_in_dropdown("linked")
	await tab._on_load_preset_button_pressed()
	check((await value(target, "source_node")).get("node_id", -1) == source.get_id(), "Named preset restores the scene reference")
	await producer.hego_rebuild()
	tab.auto_recook_toggle.set_pressed_no_signal(true)
	await tab._on_value_changed("radio_mode", 1, target)
	check(consumer.hego_did_last_cook_succeed() and (await value(target, "source_node")).get("node_id", -1) == producer.hego_get_asset_node().get_id(), "Auto-recook follows a rebuilt source")
	# Exercise the same secondary section and snapshot hook used by multi-HDA hosts.
	var pair := PairHost.new()
	pair.entries = [{"asset": producer.hego_get_asset_node(), "label": "Values"}, {"asset": target, "label": "Structure"}]
	root.add_child(pair)
	tab.auto_recook_toggle.set_pressed_no_signal(false)
	await tab.set_selected_node(pair)
	await tab._on_value_changed("radio_mode", 0, target)
	check(pair.stashes.has(target) and pair.stashes.size() == 1 and (await value(target, "radio_mode")).get("values") == [0], "Second section edits and stashes its own asset")
	await tab.set_selected_node(consumer)
	await tab._on_value_changed("radio_mode", 1, target)
	pair.free()
	var saved := PackedScene.new()
	var path := "user://hego_parameter_scene_%d.tscn" % OS.get_process_id()
	check(saved.pack(scene) == OK and ResourceSaver.save(saved, path) == OK, "Edited parameters and durable source can be saved to a scene")
	await tab.set_selected_node(null)
	api.stop_session()
	current_scene = null
	scene.free()
	if api.start_session(HEGoAPI.SESSION_NAMED_PIPE, pipe + "_fresh"):
		var reopened: PackedScene = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		scene = reopened.instantiate()
		root.add_child(scene)
		current_scene = scene
		consumer = scene.get_node("StructureFixture")
		producer = scene.get_node("ValuesFixture")
		await consumer.cook()
		target = consumer.hego_get_asset_node()
		source = producer.hego_get_asset_node()
		check(source != null and consumer.hego_did_last_cook_succeed(), "Cooking the restored consumer first resolves its scene source")
		if source:
			check((await value(target, "source_node")).get("node_id", -1) == source.get_id(), "Restored scene connects the source in a new session")
			check((await value(target, "child1_source1")).get("node_id", -1) == source.get_id(), "Source inside the resized nested multiparm survives a fresh session")
			check((await value(source, "action_count")).get("values") == [1], "Preset restore does not replay button actions")
		check((await value(target, "radio_mode")).get("values") == [1], "Scene preserves the authored radio selection")
		api.stop_session()
		current_scene = null
		scene.free()
	else:
		check(false, "Fresh Houdini session started")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tab.get_preset_res_path()))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	panel.free()
	api.clear_completed_task_history()
	if failures == 0:
		print("HEGO_PARAMETER_SCENE_PASS")
	quit(1 if failures else 0)
