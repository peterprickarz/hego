extends SceneTree
## Licensed integration test for the empty-output HDAs in the parameter test scene.

const SCENE := "res://tests/fixtures/parameters/parameter_types.tscn"
const PROBE_VEX := """
int point = addpoint(0, {0, 0, 0});
float ramp_sample = detail(0, "fixture_float_sample", 0);
int source_marker = detail(0, "fixture_source_marker", 0);
vector rgb = detail(0, "fixture_color_sample", 0);
setpointattrib(0, "sample", point, ramp_sample);
setpointattrib(0, "marker", point, source_marker);
setpointattrib(0, "red", point, rgb.x);
"""

var failures: Array[String] = []
var api: HEGoAPI


func _initialize() -> void:
	run.call_deferred()


func check(ok: bool, message: String) -> bool:
	if not ok:
		failures.append(message)
		push_error(message)
	return ok


func task_result(task: HEGoTask, success := true) -> Variant:
	if not check(task != null, "API returned a task"):
		return null
	while task.get_status() < HEGoTask.COMPLETED:
		await process_frame
	var status := HEGoTask.COMPLETED if success else HEGoTask.FAILED
	if not check(task.get_status() == status, "%s: expected status %s, got %s (%s)" % [
			task.get_description(), status, task.get_status(), task.get_error_message()]):
		return null
	if not success:
		check(not task.get_error_message().is_empty(), "Rejected task provides an error")
		return null
	return task.get_result()


func collect(row: Dictionary, result: Dictionary) -> void:
	result[row.name] = row
	for child in row.get("children", []):
		collect(child, result)
	for instance in row.get("instances", []):
		for child in instance:
			collect(child, result)


func snapshot(asset: HEGoAssetNode) -> Dictionary:
	var rows = await task_result(asset.get_parms_dict())
	var result := {}
	if rows is Dictionary:
		for row in rows.values():
			collect(row, result)
	return result


func make_asset(operator: String) -> HEGoAssetNode:
	var asset := HEGoAssetNode.new()
	asset.op_name = operator
	await task_result(asset.instantiate())
	check(asset.get_id() >= 0, operator + " instantiated")
	return asset


func check_values(asset: HEGoAssetNode) -> void:
	var rows := await snapshot(asset)
	if not check(rows.has("wide_ints"), "Values fixture exposes the complete interface"):
		return
	check(rows.enabled.help == "Show the conditional text field and enable the amount slider.",
			"Help-page ID takes precedence over an explicit hint, even with a different display label")
	check(rows.conditional_amount.help == "Adjust the sample amount while conditional controls are enabled.",
			"A label-only entry supplies its first paragraph across wrapped lines")
	check(rows.marker.help == "Set the detail marker read by the Structure fixture.",
			"Direct parameter help survives when its entry is absent from the page")
	var page: Variant = await task_result(asset.get_help_page())
	check(page is Dictionary and str(page.get("text", "")).contains("Turn off Auto Recook")
			and page.get("op_name") == asset.op_name and page.has("url"), "Full help retains later paragraphs")
	check(rows.fixture_legend["values"] == ["Controls and values", "Empty geometry output"], "Authored label columns")
	check(rows.directory_path.type == 16 and rows.directory_path.raw_values == ["$HIP"]
			and rows.directory_path["values"] != [""], "Directory uses raw and evaluated string storage")
	check(rows.geo_path.type_info == "*.bgeo.sc *.obj" and rows.geo_path.permissions != rows.file_path.permissions,
			"File parameters expose the pattern and authored read/write mode")
	check(rows.geo_path.raw_values == ["$HIP/fixture.$F4.bgeo.sc"]
			and not "$F" in rows.geo_path["values"][0], "Raw frame expression survives discovery")
	check(rows.conditional_amount.has_ui_max and not rows.conditional_amount.has_max, "Slider and strict ranges differ")
	check(rows.ordinal_menu.choices[1] == {"value": "high", "label": "High detail"}
			and not rows.ordinal_menu.use_menu_item_token_as_value and rows.token_menu.use_menu_item_token_as_value,
			"Ordinal and token-valued integer metadata differ")
	check(rows.mini_menu.choice_list_type == 2 and rows.replace_menu.choice_list_type == 3
			and rows.toggle_menu.choice_list_type == 4, "Mini, replace and toggle menu semantics")
	await task_result(asset.set_parms_batch({
		"enabled": false, "ordinal_menu": 1, "token_menu": 40, "string_menu": "ice",
		"press_action": 1, "replace_menu": "unlisted", "toggle_menu": "clay ice",
		"rgb": Color(1.5, 0.5, 0.25), "rgba": Color(0.75, 0.25, 2.0, 0.5),
		"words": PackedStringArray(["alpha", "$HIP"]),
		"wide_floats": PackedFloat64Array([9, 8, 7, 6, 5, 4, 3, 2, 1]),
		"wide_ints": PackedInt32Array([9, 8, 7, 6, 5, 4]),
		"directory_path": "$HIP/fixtures",
	}))
	rows = await snapshot(asset)
	if not check(rows.has("enabled"), "Can read edited values"):
		return
	check(rows.enabled["values"] == [0] and rows.conditional_amount.disabled
			and not rows.get("conditional_text", {}).get("visible", false),
			"Boolean updates effective conditions without cooking geometry")
	check(rows.dynamic_menu.choices.size() == 1 and rows.dynamic_menu.choices[0].value == "base", "Dynamic choice list refreshed")
	check(rows.ordinal_menu["values"] == [1] and rows.token_menu["values"] == [40]
			and rows.string_menu["values"] == ["ice"], "Menus store their declared values")
	check(rows.action_count["values"] == [1], "Button callback ran once")
	check(rows.rgb["values"] == [1.5, 0.5, 0.25] and rows.rgba["values"] == [0.75, 0.25, 2.0, 0.5], "HDR color and alpha survive")
	check(rows.words.raw_values == ["alpha", "$HIP"], "All string tuple components: %s" % [rows.words.raw_values])
	check(rows.wide_floats["values"] == [9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0],
			"All float tuple components: %s" % [rows.wide_floats["values"]])
	check(rows.wide_ints["values"] == [9, 8, 7, 6, 5, 4], "All integer tuple components: %s" % [rows.wide_ints["values"]])
	check(rows.directory_path.raw_values == ["$HIP/fixtures"], "Directory accepts literal Houdini variables")
	await task_result(asset.set_parms_batch({"marker": 27, "wide_floats": PackedFloat64Array([0,0,0,0,0,0,0,0,INF])}), false)
	await task_result(asset.set_parm("words", PackedStringArray(["short"])), false)
	var after := await snapshot(asset)
	check(not after.is_empty() and after.marker["values"] == [17] and after.wide_floats["values"] == rows.wide_floats["values"]
			and after.words.raw_values == rows.words.raw_values, "Invalid trailing components and sizes leave neighboring values intact")
	var restore := await make_asset(asset.op_name)
	var preset = await task_result(asset.get_preset())
	if preset is PackedByteArray and not preset.is_empty():
		await task_result(restore.set_preset(preset))
		var restored := await snapshot(restore)
		check(not restored.is_empty() and restored.action_count["values"] == [1] and restored.rgba["values"] == rows.rgba["values"]
				and restored.words.raw_values == rows.words.raw_values, "Restoring a preset preserves colors, text and the callback count")
	else:
		check(false, "Values binary preset captured")


func check_structure(asset: HEGoAssetNode) -> void:
	var rows := await snapshot(asset)
	if not check(rows.has("zero_entries"), "Structure fixture exposes its interface"):
		return
	check(rows.entry_value1.help == "Edit the value on this list row." and rows.entry_value2.help == rows.entry_value1.help,
			"Every instance resolves its authored template ID")
	check(rows.tab_name1.help == "Name this tabbed instance." and rows.scroll_name1.help.is_empty(),
			"A documented ID does not lend its tooltip to another parameter with the same label")
	check(rows.display_tabs.folder_ids == [rows.display_tabs_0.id, rows.display_tabs_1.id]
			and rows.surface_name.parent_id == rows.display_tabs_0.id and rows.pattern_name.parent_id == rows.display_tabs_1.id,
			"Tab set points to sibling descriptors in authored order")
	check(rows.display_tabs.tags.get("group_default") == "1" and rows.opaque_0.tags.get("group_default") == "1",
			"The saved HDA opens on the Pattern tab with the Opaque data foldout expanded")
	check(rows.radio_mode.folder_ids == [rows.radio_mode_0.id, rows.radio_mode_1.id]
			and rows.radio_mode["values"].size() == 1, "Radio set reads one value for two choices")
	check(rows.entries.multiparm_style == "list" and rows.scroll_entries.multiparm_style == "scroll"
			and rows.tab_entries.multiparm_style == "tabs", "Untagged saved folder styles are recovered")
	check(rows.entries.instance_start_offset == 1 and rows.zero_entries.instance_start_offset == 0
			and rows.zero_entries.instances.is_empty(), "Both start offsets and empty list")
	check(rows.float_ramp.ramp_type == 0 and rows.color_ramp.ramp_type == 1
			and rows.color_ramp1c.template_name == "color_ramp#c", "Ramp kind and child template names survive discovery")
	check(rows.dictionary_data.size == 0 and rows.geometry_data.size == 0
			and rows.dictionary_data.script_type != rows.geometry_data.script_type, "Opaque fields retain distinct types")
	await task_result(asset.set_parm("dictionary_data", 0), false)
	await task_result(asset.set_parm("radio_mode", 1))
	await task_result(asset.insert_multiparm_instance(rows.zero_entries.id, 0))
	rows = await snapshot(asset)
	if not check(rows.has("zero_value0"), "First zero-based row exists after insert"):
		return
	await task_result(asset.set_parms_batch({"zero_value0": 9, "entry_value1": 1.25, "entry_value2": 2.5, "child2_name1": "nested"}))
	await task_result(asset.insert_multiparm_instance(rows.entries.id, 2))
	rows = await snapshot(asset)
	if not check(rows.has("child3_name1"), "Middle insertion shifted the nested subtree"):
		return
	check(rows.entry_value1["values"] == [1.25] and rows.entry_value3["values"] == [2.5] and rows.child3_name1["values"] == ["nested"],
			"Middle insertion preserves ordinary and nested multiparm values")
	await task_result(asset.remove_multiparm_instance(rows.entries.id, 2))
	rows = await snapshot(asset)
	await task_result(asset.remove_multiparm_instance(rows.entries.id, 0), false)
	await task_result(asset.remove_multiparm_instance(rows.zero_entries.id, 0))
	rows = await snapshot(asset)
	check(rows.radio_mode["values"] == [1] and rows.zero_entries.instances.is_empty() and rows.child2_name1["values"] == ["nested"],
			"Radio choice, zero-based removal and one-based nested removal")
	await task_result(asset.insert_multiparm_instance(rows.float_ramp.id, 2))
	rows = await snapshot(asset)
	if not check(rows.float_ramp.instances.size() == 4, "Float ramp inserted a middle key"):
		return
	await task_result(asset.set_parms_batch({"float_ramp2pos": 0.2, "float_ramp2value": 0.75, "float_ramp2interp": 0,
			"color_ramp1c": Color(0.5, 0.25, 1), "color_ramp1interp": 0}))
	rows = await snapshot(asset)
	await task_result(asset.remove_multiparm_instance(rows.float_ramp.id, 3))
	rows = await snapshot(asset)
	check(rows.float_ramp.instances.size() == 3 and rows.float_ramp2interp["values"] == [0]
			and rows.float_ramp2value["values"] == [0.75], "Ramp key deletion preserves surviving interpolation and values")


func samples(probe: HEGoAssetNode, structure: HEGoAssetNode) -> Array:
	await task_result(structure.cook())
	await task_result(probe.connect_input(structure, 0))
	await task_result(probe.cook())
	var output = await task_result(probe.get_point_output(PackedStringArray(["sample", "marker", "red"])))
	if not check(output != null and output.get_point_count() == 1, "One downstream diagnostic sample"):
		return []
	return [output.get_attribute("sample")[0], output.get_attribute("marker")[0], output.get_attribute("red")[0]]


func check_node_and_ramp_output(structure: HEGoAssetNode, values: HEGoAssetNode) -> void:
	var unsuitable := await make_asset("Object/geo")
	var alternate := await make_asset(values.op_name)
	await task_result(alternate.set_parm("marker", 81))
	await task_result(alternate.cook())
	var allowed = await task_result(structure.get_node_parm_candidates("source_node", [structure, unsuitable, values, alternate]))
	check(allowed == [false, false, true, true], "SOP filter rejects the owning node and an Object/geo")
	await task_result(structure.set_node_parm("source_node", values))
	await task_result(structure.set_node_parm("source_node", unsuitable), false)
	var rows := await snapshot(structure)
	check(not rows.is_empty() and rows.source_node.node_id == values.get_id(), "Rejected reference preserves the selected source")
	var probe := await make_asset("Sop/attribwrangle")
	await task_result(probe.set_parms_batch({"class": 0, "snippet": PROBE_VEX}))
	check(await samples(probe, structure) == [0.75, 17, 0.5], "Cooked float and color ramp sample plus referenced SOP value")
	var ordered: PackedByteArray = await task_result(structure.get_preset())
	await task_result(structure.set_parm("color_ramp3pos", 0.1))
	var reordered := await samples(probe, structure)
	check(reordered.size() == 3 and reordered[2] > 0.5, "Moving the last color key past its neighbor changes the sampled color")
	await task_result(structure.set_preset(ordered))
	check(await samples(probe, structure) == [0.75, 17, 0.5], "Restoring the original ramp ordering restores the sampled color")
	await task_result(structure.set_node_parm("source_node", alternate))
	check(await samples(probe, structure) == [0.75, 81, 0.5], "Replacing the referenced SOP updates cooked output")
	await task_result(structure.set_node_parm("source_node"))
	check(await samples(probe, structure) == [0.75, -1, 0.5], "Clearing the reference updates cooked output")
	var preset = await task_result(structure.get_preset())
	var fresh := await make_asset(structure.op_name)
	if preset is PackedByteArray and not preset.is_empty():
		await task_result(fresh.set_preset(preset))
		var restored := await snapshot(fresh)
		check(not restored.is_empty() and restored.float_ramp2interp["values"] == [0] and restored.child2_name1["values"] == ["nested"],
				"Fresh instance restores nested list values and ramp interpolation")
		check(await samples(probe, fresh) == [0.75, -1, 0.5], "Fresh preset instance cooks identical ramp samples")
	else:
		check(false, "Structure binary preset captured")


func check_nested_preset_shrink(operator: String) -> void:
	var source := await make_asset(operator)
	var target := await make_asset(operator)
	await task_result(source.set_parm("entries", 1))
	await task_result(source.set_parm("children1", 3))
	await task_result(source.set_parms_batch({"radio_mode": 1, "child1_name3": "last nested value"}))
	var preset = await task_result(source.get_preset())
	if not check(preset is PackedByteArray and not preset.is_empty(), "Captured a preset with one outer and three nested rows"):
		return
	await task_result(target.set_preset(preset))
	var rows := await snapshot(target)
	check(rows.get("entries", {}).get("instance_count") == 1 and rows.get("children1", {}).get("instance_count") == 3
			and rows.get("child1_name3", {}).get("values") == ["last nested value"] and rows.get("radio_mode", {}).get("values") == [1],
			"A fresh target with two default rows restores the smaller outer block and complete nested values")
	await task_result(target.set_preset(PackedByteArray([4, 16, 64, 127])), false)


func check_failed_scene_restore(values: HEGoAssetNode) -> void:
	var scene := (load(SCENE) as PackedScene).instantiate()
	root.add_child(scene)
	var host := scene.get_node("ValuesFixture") as HEGoNode3D
	var bad := PackedByteArray([4, 16, 64, 127])
	host.parm_stash = bad.duplicate()
	for retry in 2:
		await host.cook()
		check(not host.hego_did_last_cook_succeed() and host.parm_stash == bad and host.hego_get_asset_node().get_id() == -1,
				"Invalid stash survives failed restore %d and the incomplete instance is released" % (retry + 1))
	host.parm_stash = await task_result(values.get_preset())
	await host.cook()
	var repaired := await snapshot(host.hego_get_asset_node())
	check(host.hego_did_last_cook_succeed() and repaired.get("action_count", {}).get("values") == [1],
			"Retrying with a valid stash restores the saved control values")
	scene.free()


func check_preset_filenames() -> void:
	var tab := preload("res://addons/hego/ui/hda_tab.gd").new()
	var host := HEGoNode3D.new()
	tab.hego_tool_node = host
	host.asset_name = "Sop/sample"
	check(tab.get_preset_res_path() == "res://hego/presets/sample.tres", "Simple operator preserves its existing preset filename")
	host.asset_name = "Sop/acme::sample::2.0"
	var version_two: String = tab.get_preset_res_path()
	host.asset_name = "acme::sample::2.0"
	check(version_two.get_file().is_valid_filename() and tab.get_preset_res_path() == version_two,
			"The same namespaced SOP resolves to one portable filename with or without the table prefix")
	host.asset_name = "Sop/acme::sample::1.0"
	check(tab.get_preset_res_path() != version_two, "Different operator versions have distinct preset files")
	host.asset_name = "Sop/CON"
	check(not String(tab.get_preset_res_path()).ends_with("/CON.tres"), "Reserved Windows device name has a portable preset filename")
	host.free()
	tab.free()


func run() -> void:
	check_preset_filenames()
	api = HEGoAPI.get_singleton()
	if not check(api.start_session(HEGoAPI.SESSION_NAMED_PIPE, "hego_fixture_parms_%d" % OS.get_process_id()), "Private Houdini session started"):
		quit(1)
		return
	var scene := (load(SCENE) as PackedScene).instantiate()
	root.add_child(scene)
	var values_host := scene.get_node("ValuesFixture") as HEGoNode3D
	var structure_host := scene.get_node("StructureFixture") as HEGoNode3D
	await values_host.cook()
	await structure_host.cook()
	if check(values_host.hego_did_last_cook_succeed() and structure_host.hego_did_last_cook_succeed(), "Both real test scene hosts load and cook their own HDAs"):
		var values := values_host.hego_get_asset_node()
		var structure := structure_host.hego_get_asset_node()
		await check_values(values)
		await check_structure(structure)
		await check_nested_preset_shrink(structure.op_name)
		await check_node_and_ramp_output(structure, values)
		await check_failed_scene_restore(values)
	scene.free()
	api.stop_session()
	api.clear_completed_task_history()
	if failures.is_empty():
		print("HEGO_PARAMETER_FIXTURES_PASS")
	quit(0 if failures.is_empty() else 1)
