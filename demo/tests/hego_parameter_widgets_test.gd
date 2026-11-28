## Artificial HAPI descriptors exercise the bottom-panel widgets without a Houdini license.
extends SceneTree

const Editor := preload("res://addons/hego/ui/parameter_editor.gd")
const Kind := Editor.Kind
var renderer := Editor.new()
var asset := HEGoAssetNode.new()
var other := HEGoAssetNode.new()
var writes := []
var structures := []
var counts := []
var sources := []
var failures := 0
var next_id := 1


func _initialize() -> void:
	run.call_deferred()


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)


func parm(name: String, kind: int, values: Array, extra := {}) -> Dictionary:
	var descriptor := {"name": name, "label": name, "id": next_id, "type": kind, "size": values.size(), "values": values}
	next_id += 1
	descriptor.merge(extra, true)
	return descriptor


func mount(descriptors: Array, host: HEGoAssetNode = asset) -> VBoxContainer:
	var box := VBoxContainer.new()
	root.add_child(box)
	renderer.add_parameters(descriptors, box, host)
	return box


func field(box: Control, parm_name: String, index: Variant = 0) -> Control:
	for item in box.find_children("*", "Control", true, false):
		if item.get_meta("hego_parm_name", "") == parm_name and item.get_meta("hego_parm_component", "") == str(index):
			return item
	return null


func folder(name: String, style: int, child: Dictionary) -> Dictionary:
	return parm(name, Kind.FOLDER, [], {"children": [child], "script_type": style})


func check_folders() -> void:
	var a := folder("first", 1003, parm("first_field", Kind.STRING, ["A"]))
	var b := folder("second", 1003, parm("second_field", Kind.STRING, ["B"]))
	var wrapper := parm("pages", Kind.FOLDER_LIST, [], {"size": 2, "folder_ids": [a.id, b.id]})
	var simple := folder("simple", 1002, parm("simple_field", Kind.INT, [2]))
	var fold := folder("collapsible", 1001, parm("folded_field", Kind.INT, [4]))
	var descriptors := [wrapper, a, b, simple, fold]
	var box := mount(descriptors)
	var tabs: TabContainer = box.find_children("*", "TabContainer", true, false)[0]
	check(tabs.get_tab_count() == 2 and tabs.get_tab_title(1) == "second", "Tab set consumes two following sibling folders")
	check(field(box, "first_field") != null and field(box, "second_field") != null, "Both folders have their authored fields")
	check(box.find_children("*", "LineEdit", true, false).filter(func(f): return f.get_meta("hego_parm_name", "") == "first_field").size() == 1, "Folder child renders once")
	var coll: FoldableContainer = box.find_children("*", "FoldableContainer", true, false)[0]
	check(coll.title == "collapsible" and box.find_children("*", "PanelContainer", true, false).size() == 1, "Simple is a labeled frame, collapsible is independently foldable")
	tabs.current_tab = 1
	coll.expand()
	box.free()
	box = mount(descriptors)
	tabs = box.find_children("*", "TabContainer", true, false)[0]
	coll = box.find_children("*", "FoldableContainer", true, false)[0]
	check(tabs.current_tab == 1 and not coll.folded, "Local tabs and folding survive metadata refresh")
	check(writes.is_empty(), "Local layout and programmatic setup never write parameters")
	box.free()
	box = mount(descriptors, other)
	check(box.find_children("*", "TabContainer", true, false)[0].current_tab == 0, "Local tab selection is per asset")
	box.free()
	wrapper = parm("radio", Kind.RADIO_LIST, [0], {"size": 3, "folder_ids": [a.id, -100, b.id]})
	box = mount([wrapper, a, b])
	tabs = box.find_children("*", "TabContainer", true, false)[0]
	check(tabs.get_tab_icon(0) != null, "Radio tabs display their selection control")
	tabs.current_tab = 1
	check(writes == [["radio", 2, asset]], "Radio sends original ordinal including hidden tabs")
	writes.clear()
	box.free()
	wrapper["values"] = [1]
	box = mount([wrapper, a])
	tabs = box.find_children("*", "TabContainer", true, false)[0]
	check(tabs.current_tab == -1 and writes.is_empty(), "A hidden active radio page leaves the visible choices unselected")
	tabs.current_tab = 0
	check(writes == [["radio", 0, asset]], "The remaining visible radio page can be chosen")
	writes.clear()
	box.free()


func check_authored_folder_defaults() -> void:
	var first := folder("default_tabs_0", 1003, parm("surface_field", Kind.STRING, ["surface"]))
	var second := folder("default_tabs_1", 1003, parm("pattern_field", Kind.STRING, ["pattern"]))
	var tabs_parm := parm("default_tabs", Kind.FOLDER_LIST, [], {"folder_ids": [first.id, second.id], "tags": {"group_default": "1"}})
	var opaque := folder("opaque_0", 1001, parm("opaque_field", Kind.STRING, ["data"]))
	opaque.tags = {"group_default": "1"}
	var opaque_list := parm("opaque", Kind.FOLDER_LIST, [], {"folder_ids": [opaque.id], "tags": {"group_default": "1"}})
	var tuples := folder("tuples_0", 1001, parm("tuple_field", Kind.INT, [2]))
	var tuples_list := parm("tuples", Kind.FOLDER_LIST, [], {"folder_ids": [tuples.id], "tags": {"group_default": "0"}})
	var descriptors := [tabs_parm, first, second, opaque_list, opaque, tuples_list, tuples]
	var box := mount(descriptors)
	await process_frame
	await process_frame
	var tabs: TabContainer = box.find_children("*", "TabContainer", true, false)[0]
	var foldouts := box.find_children("*", "FoldableContainer", true, false)
	check(tabs.current_tab == 1 and field(box, "pattern_field").is_visible_in_tree(), "The second page opens from the authored tab index")
	check(not foldouts[0].folded and field(box, "opaque_field").is_visible_in_tree(), "An authored initially-open folder displays its fields")
	check(foldouts[1].folded and not field(box, "tuple_field").is_visible_in_tree(), "An authored initially-closed folder hides its fields")
	tabs.current_tab = 0
	foldouts[0].fold()
	foldouts[1].expand()
	box.free()
	box = mount(descriptors)
	await process_frame
	await process_frame
	tabs = box.find_children("*", "TabContainer", true, false)[0]
	foldouts = box.find_children("*", "FoldableContainer", true, false)
	check(tabs.current_tab == 0 and foldouts[0].folded and not foldouts[1].folded, "User choices supersede authored folder defaults after refresh")
	check(writes.is_empty(), "Opening, overriding and refreshing ordinary folder defaults sends no HAPI writes")
	box.free()


func check_menus() -> void:
	var options := [{"label": "Ten", "value": "10"}, {"label": "Forty", "value": "40"}]
	var fields := []
	for name in ["ordinal", "token", "string", "mini", "replace", "toggles"]:
		var mode: int = {"mini": 2, "replace": 3, "toggles": 4}.get(name, 1)
		var text: bool = name in ["string", "replace", "toggles"]
		fields.append(parm(name, Kind.STRING if text else Kind.INT, ["custom" if text else 0], {"choices": options, "choice_list_type": mode, "use_menu_item_token_as_value": name == "token"}))
	fields.append(parm("check", Kind.TOGGLE, [0], {"choices": options, "choice_list_type": 1}))
	fields.append(parm("button", Kind.BUTTON, [0]))
	var box := mount(fields)
	check(field(box, "check") is CheckBox, "Toggle takes precedence over choice data")
	for name in ["ordinal", "token", "string"]:
		var menu: OptionButton = field(box, name)
		check(menu.get_item_text(1) == "Forty", "Displays authored menu label")
		if name == "string": check(menu.get_item_text(menu.selected) == "custom", "Unknown stored token is displayed without a write")
		menu.item_selected.emit(1)
	var mini: MenuButton = field(box, "mini")
	check(mini.get_popup().get_item_text(1) == "Forty", "Mini menu exposes labeled items behind its compact control")
	mini.get_popup().id_pressed.emit(1)
	check(writes == [["ordinal", 1, asset], ["token", 40, asset], ["string", "40", asset], ["mini", 1, asset]], "Each menu commits its own storage type once")
	writes.clear()
	var replace: LineEdit = field(box, "replace")
	replace.text_submitted.emit("free entry")
	var toggles: LineEdit = field(box, "toggles")
	var toggle_menu: MenuButton = toggles.get_parent().find_children("*", "MenuButton", false, false)[0]
	toggle_menu.get_popup().id_pressed.emit(1)
	field(box, "button").pressed.emit()
	check(writes == [["replace", "free entry", asset], ["toggles", "custom 40", asset], ["button", 0, asset]], "Editable menus retain free tokens, one button gesture emits one action")
	writes.clear()
	box.free()


func check_fields() -> void:
	var box := mount([
		parm("nine", Kind.FLOAT, [0, 1, 2, 3, 4, 5, 6, 7, 8]),
		parm("pair", Kind.STRING, ["a", "b"]),
		parm("range", Kind.FLOAT, [1.5], {"has_ui_min": true, "ui_min": 0.25, "has_ui_max": true, "ui_max": 2, "has_min": true, "min": 0, "has_max": true, "max": 100}),
		parm("small", Kind.FLOAT, [3e-7], {"has_ui_min": true, "ui_min": 0.0, "has_ui_max": true, "ui_max": 9e-7}),
		parm("file", Kind.FILE, ["/evaluated/file"], {"raw_values": ["$HIP/raw"], "choice_list_type": 3}),
		parm("rgba", Kind.COLOR, [2.0, 0.5, 0.25, 0.75]), parm("rgb", Kind.COLOR, [1, 2, 3]),
		parm("off", Kind.INT, [3], {"disabled": true}), parm("absent", Kind.STRING, [""], {"visible": false}),
		parm("opaque", Kind.INT, [], {"script_type": 29}),
		parm("multiline", Kind.STRING, ["line 1\nline 2"], {"tags": {"editor": "1", "editorlines": "3"}}),
	], other)
	var last: Node = field(box, "nine", 8)
	while last and not last is SpinBox:
		last = last.get_parent()
	check(last != null, "Nine tuple exposes final spin box")
	last.value = 42
	field(box, "pair", 1).text_submitted.emit("new")
	check(writes == [["nine", PackedFloat64Array([0, 1, 2, 3, 4, 5, 6, 7, 42]), other], ["pair", PackedStringArray(["a", "new"]), other]], "Full tuple and owning asset are preserved")
	var small: LineEdit = field(box, "small")
	check(small.text.to_float() == 3e-7, "Small HAPI float stays visible at its authored precision")
	small.text_submitted.emit("5e-28")
	check(writes.back()[0] == "small" and writes.back()[1] == 5e-28, "Scientific notation preserves tiny typed float values")
	var slider: HSlider = field(box, "range", "slider")
	check(slider.min_value == 0.25 and slider.max_value == 2, "Slider has authored soft bounds")
	check(field(box, "off").editable == false and field(box, "absent") == null, "Hidden and disabled state respected")
	check(field(box, "file").text == "$HIP/raw" and field(box, "file").get_parent().find_children("*", "Button", false, false).size() == 1, "Authored path string and picker take precedence over empty Replace menu")
	check(field(box, "multiline") is TextEdit, "Multiline tag creates a multiline control")
	var rgba: ColorPickerButton = field(box, "rgba")
	check(rgba.color.r == 2 and rgba.edit_alpha and not field(box, "rgb").edit_alpha, "RGB(A) keep HDR and declared alpha")
	rgba.color = Color(4, 2, 1, 0.25)
	rgba.popup_closed.emit()
	check(writes.back() == ["rgba", Color(4, 2, 1, 0.25), other], "Color emits all components")
	writes.clear()
	box.free()


func check_lists() -> void:
	var descriptors := []
	for style in ["list", "scroll", "tabs", "ramp"]:
		var value := parm(style + "_weight", Kind.FLOAT, [0.5])
		var mode := {"instance_count": 1, "instance_start_offset": 0, "instances": [[value]], "multiparm_style": style}
		if style == "ramp": mode.ramp_type = 0
		descriptors.append(parm(style, Kind.MULTIPARM, [1], mode))
	var box := mount(descriptors)
	check(box.find_children("*", "TabContainer", true, false).size() == 1 and box.find_children("*", "ScrollContainer", true, false).size() == 1, "List, scrolling region and tabbed instances are distinct")
	var spin: SpinBox = box.get_child(0).find_children("*", "SpinBox", true, false)[0]
	spin.value = 3
	check(counts == [["list", 3, asset]] and writes.is_empty(), "Instance count goes through the structural edit path")
	for i in descriptors.size():
		var panel := box.get_child(i)
		var buttons := panel.find_children("*", "Button", true, false)
		for button in buttons:
			if button.text in ["Remove", "Insert before", "Add key"]: button.pressed.emit()
		check(field(panel, str(descriptors[i].name) + "_weight") != null, "Fields recurse inside each multiparm presentation")
	check(structures.has(["list", descriptors[0].id, 0, false, asset]) and structures.has(["ramp", descriptors[3].id, 1, true, asset]), "Actions use current id, owner and authored offset")
	box.free()
	var first := parm("ramp1pos", Kind.FLOAT, [0.8], {"template_name": "ramp#pos"})
	var second := parm("ramp2pos", Kind.FLOAT, [0.25], {"template_name": "ramp#pos"})
	var ramp := parm("ramp_keys", Kind.MULTIPARM, [2], {"ramp_type": 0, "instance_count": 2, "instance_start_offset": 1, "instances": [[first], [second]]})
	box = mount([ramp])
	var sliders := box.find_children("*", "HSlider", true, false)
	check(sliders[0].get_meta("hego_parm_name") == "ramp2pos", "Moved ramp keys appear in position order")
	var removals := box.find_children("*", "Button", true, false).filter(func(b): return b.text == "Remove")
	removals[0].pressed.emit()
	check(structures.back() == ["ramp_keys", ramp.id, 2, false, asset], "Deletion of a moved ramp key uses its actual HAPI instance")
	box.free()


func check_nodes() -> void:
	renderer.node_candidates = func(_owner, _descriptor): return [{"label": "Source", "node": other}]
	var box := mount([parm("node", Kind.NODE, ["/obj/current"], {"node_id": 20})])
	var menu: MenuButton = field(box, "node")
	var popup := menu.get_popup()
	popup.about_to_popup.emit()
	check(popup.item_count == 1 and popup.get_item_text(0) == "Source", "Node menu asks provider for compatible live candidates")
	popup.id_pressed.emit(popup.get_item_id(0))
	for button in menu.get_parent().find_children("*", "Button", false, false):
		if button.text == "Clear": button.pressed.emit()
	check(sources == [["node", other, asset], ["node", null, asset]], "Node connect and clear are separate typed requests")
	box.free()


func check_help() -> void:
	var amount := parm("amount", Kind.FLOAT, [2.5], {"help": "Height in metres.", "disabled": true})
	var first := folder("surface", 1003, amount)
	first.help = "Controls the surface."
	var second := folder("pattern", 1003, parm("pattern_name", Kind.STRING, [""]))
	var tabs := parm("pages", Kind.RADIO_LIST, [0], {"folder_ids": [first.id, second.id], "help": "Choose a page."})
	var fold := folder("advanced", 1001, parm("file", Kind.FILE, [""], {"help": "Choose a geometry file."}))
	fold.help = "Advanced settings."
	var section := folder("settings", 1002, parm("notes", Kind.LABEL, ["Remember me."]))
	section.help = "Common settings."
	var multiparm := parm("entries", Kind.MULTIPARM, [1], {"instance_count": 1, "instances": [[]], "multiparm_style": "tabs", "help": "One entry per object."})
	var box := mount([tabs, first, second, fold, section, multiparm])
	var pages := box.find_children("*", "TabContainer", true, false)
	check(pages[0].get_tab_bar().get_tab_tooltip(0) == first.help and pages[0].get_tab_bar().get_tab_tooltip(1) == tabs.help, "Tabs expose individual help with the folder-list text as fallback")
	var title: Label = box.find_children("*", "Label", true, false).filter(func(label): return label.text == "amount")[0]
	check(title.mouse_filter != Control.MOUSE_FILTER_IGNORE and title.get_tooltip() == amount.help, "A parameter label receives mouse hover and has authored help")
	check(field(box, "amount").get_tooltip() == amount.help and field(box, "amount", "slider").get_tooltip() == amount.help, "The internal spin field and disabled slider show the parameter's own help")
	check(box.find_children("*", "FoldableContainer", true, false)[0].tooltip_text == fold.help, "Collapsed folder titles expose their help")
	var simple: Label = box.find_children("*", "Label", true, false).filter(func(label): return label.text == "settings")[0]
	check(simple.tooltip_text == section.help and simple.mouse_filter != Control.MOUSE_FILTER_IGNORE, "Simple folder title receives help directly")
	var browse: Button = box.find_children("*", "Button", true, false).filter(func(button): return button.text == "Browse…")[0]
	check(browse.tooltip_text == "Choose a geometry file." and field(box, "file").tooltip_text == browse.tooltip_text, "A path and its Browse action expose the file parameter's help")
	check(pages[1].get_tab_tooltip(0) == multiparm.help and field(box, "entries", "count").tooltip_text == multiparm.help, "Multiparm tabs and count controls expose the list's help")
	check(field(box, "entries", "append").tooltip_text == "Append an instance\n\nOne entry per object.", "An action's existing hint is preserved alongside the author's help")
	box.free()


func run() -> void:
	renderer.value_requested.connect(func(n, v, a): writes.append([n, v, a]))
	renderer.instance_requested.connect(func(n, id, pos, insert, a): structures.append([n, id, pos, insert, a]))
	renderer.instance_count_requested.connect(func(n, count, a): counts.append([n, count, a]))
	renderer.node_requested.connect(func(n, source, a): sources.append([n, source, a]))
	check_folders()
	await check_authored_folder_defaults()
	check_menus()
	check_fields()
	check_lists()
	check_nodes()
	check_help()
	if failures == 0: print("HEGO_PARAMETER_WIDGETS_PASS")
	quit(1 if failures else 0)
