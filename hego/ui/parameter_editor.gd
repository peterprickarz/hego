@tool
extends RefCounted
## Builds one asset's descriptor tree. Only the panel performs HAPI writes and cooks.

const Field := preload("res://addons/hego/parm_controls/parameter_value_editor.gd")
const Kind := Field.Kind
const COLLAPSIBLE := 1001
const SIMPLE := 1002

signal value_requested(name: String, value: Variant, asset: HEGoAssetNode)
signal instance_count_requested(name: String, value: int, asset: HEGoAssetNode)
signal instance_requested(name: String, parm_id: int, position: int, insert: bool, asset: HEGoAssetNode)
signal node_requested(name: String, source: Variant, asset: HEGoAssetNode)

var node_candidates: Callable
var local_filesystem := true
var _folder_state := {}
var _icons := {}


func add_parameters(descriptors: Array, parent: Control, asset: HEGoAssetNode, inherited_disabled := false) -> void:
	# HAPI lists and their folder descriptors are siblings in presentation order.
	# Other HAPI clients can also supply nested children on the list descriptor.
	var by_id := {}
	for data in descriptors:
		if data is Dictionary and data.has("id"):
			by_id[data.id] = data
	var consumed := {}
	var joined: HBoxContainer
	for i in descriptors.size():
		var data: Dictionary = descriptors[i]
		if consumed.has(data.get("id", -1)):
			continue
		if data.type in [Kind.FOLDER_LIST, Kind.RADIO_LIST]:
			var folders := _list_members(data, i, descriptors, by_id)
			for folder in folders:
				consumed[folder.id] = true
			if data.get("visible", true):
				_folder_list(data, folders, parent, asset, inherited_disabled or data.get("disabled", false))
			joined = null
			continue
		if not data.get("visible", true):
			continue
		if data.get("join_next", false) and joined == null:
			joined = HBoxContainer.new()
			parent.add_child(joined)
		add_parameter(data, joined if joined else parent, asset, inherited_disabled)
		if not data.get("join_next", false): joined = null


func add_parameter(data: Dictionary, parent: Control, asset: HEGoAssetNode, inherited_disabled := false) -> void:
	if not data.get("visible", true):
		return
	var disabled: bool = inherited_disabled or data.get("disabled", false)
	match int(data.type):
		Kind.FOLDER:
			_folder(data, parent, asset, disabled)
		Kind.FOLDER_LIST, Kind.RADIO_LIST:
			_folder_list(data, data.get("children", []), parent, asset, disabled)
		Kind.MULTIPARM:
			_multiparm(data, parent, asset, disabled)
		_:
			var field := Field.new()
			parent.add_child(field)
			if inherited_disabled:
				data = data.duplicate()
				data.disabled = true
			field.setup(data, asset, node_candidates, local_filesystem, _icons)
			field.value_requested.connect(value_requested.emit)
			field.node_requested.connect(node_requested.emit)
			if data.has("children"):
				add_parameters(data.children, parent, asset, disabled)


func _list_members(data: Dictionary, start: int, siblings: Array, by_id: Dictionary) -> Array:
	var members := []
	if data.has("folder_ids"):
		for ordinal in data.folder_ids.size():
			var id: int = data.folder_ids[ordinal]
			if by_id.has(id):
				var child: Dictionary = by_id[id].duplicate()
				child["_tab_ordinal"] = ordinal
				members.append(child)
	elif not data.get("children", []).is_empty():
		members = data.children
	else:
		for i in range(start + 1, mini(start + 1 + int(data.get("size", 0)), siblings.size())):
			if siblings[i].type != Kind.FOLDER:
				break
			members.append(siblings[i])
	return members


func _key(data: Dictionary, asset: HEGoAssetNode) -> String:
	return "%d/%s" % [asset.get_instance_id() if asset else 0, data.name]


func _box(parent: Control) -> VBoxContainer:
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(body)
	return body


func _heading(parent: Control, label: String, help: String) -> void:
	var title := Label.new()
	title.text = label
	parent.add_child(title)
	Field.apply_help(title, help)


func _group_default(data: Dictionary, fallback: int) -> int:
	return int(data.get("tags", {}).get("group_default", fallback))


func _folder(data: Dictionary, parent: Control, asset: HEGoAssetNode, disabled: bool, wrapper_default := 0, wrapper_help := "") -> void:
	var content: VBoxContainer
	var help := _folder_help(data, wrapper_help)
	if data.get("script_type", SIMPLE) == COLLAPSIBLE:
		var group := FoldableContainer.new()
		group.title = data.get("label", data.name)
		group.tooltip_text = help
		var key := _key(data, asset)
		var initially_open := _group_default(data, wrapper_default) == 1
		group.folded = _folder_state.get(key, not initially_open)
		group.folding_changed.connect(func(folded: bool): _folder_state[key] = folded)
		parent.add_child(group)
		content = _box(group)
	else:
		var frame := PanelContainer.new()
		frame.tooltip_text = help
		frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		parent.add_child(frame)
		content = _box(frame)
		if not data.get("label_none", false):
			_heading(content, str(data.get("label", data.name)), help)
	add_parameters(data.get("children", []), content, asset, disabled)


func _folder_help(folder: Dictionary, list_help: String) -> String:
	var help: String = folder.get("help", "")
	return list_help if help.is_empty() else help


func _folder_list(data: Dictionary, folders: Array, parent: Control, asset: HEGoAssetNode, disabled: bool) -> void:
	var visible_folders: Array = []
	var ordinals: Array[int] = []
	for i in folders.size():
		var child: Dictionary = folders[i]
		if child.get("visible", true):
			visible_folders.append(child)
			ordinals.append(child.get("_tab_ordinal", i))
	if visible_folders.is_empty(): return
	var first_style: int = visible_folders[0].get("script_type", -1)
	var radio: bool = data.type == Kind.RADIO_LIST
	var help: String = data.get("help", "")
	if not radio and first_style in [COLLAPSIBLE, SIMPLE]:
		var wrapper_default := _group_default(data, 0) if folders.size() == 1 else 0
		for child in visible_folders:
			_folder(child, parent, asset, disabled or child.get("disabled", false), wrapper_default, help)
		return
	var tabs := TabContainer.new()
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(tabs)
	var key := _key(data, asset)
	var default_tab := _group_default(data, _group_default(folders[0], 0))
	var selected: int = int(data.get("values", [0])[0]) if radio and not data.get("values", []).is_empty() else int(_folder_state.get(key, default_tab))
	for i in visible_folders.size():
		var child: Dictionary = visible_folders[i]
		var body := _box(tabs)
		tabs.set_tab_title(i, child.get("label", child.name))
		tabs.set_tab_tooltip(i, _folder_help(child, help))
		tabs.set_tab_disabled(i, child.get("disabled", false) or (disabled and radio))
		add_parameters(child.get("children", []), body, asset, disabled or child.get("disabled", false))
	var selected_index := ordinals.find(selected)
	if selected_index >= 0:
		tabs.current_tab = selected_index
	elif radio:
		# HAPI retains the authored selection when that page becomes hidden.
		# Leave the visible tabs unselected until the artist actually chooses one.
		tabs.deselect_enabled = true
		tabs.current_tab = -1
	tabs.set_meta("radio_ordinal", selected)
	if radio:
		_radio_icons(tabs, selected_index)
	tabs.tab_changed.connect(func(i: int):
		if not tabs.is_inside_tree() or tabs.get_tab_count() != ordinals.size() or i < 0 or i >= ordinals.size(): return
		if radio:
			if not disabled and ordinals[i] != tabs.get_meta("radio_ordinal"):
				tabs.deselect_enabled = false
				tabs.set_meta("radio_ordinal", ordinals[i])
				_radio_icons(tabs, i)
				value_requested.emit(data.name, ordinals[i], asset)
		else:
			_folder_state[key] = ordinals[i])


func _radio_icons(tabs: TabContainer, selected: int) -> void:
	for index in tabs.get_tab_count():
		var icon := "radio_checked" if index == selected else "radio_unchecked"
		tabs.set_tab_icon(index, tabs.get_theme_icon(icon, "CheckBox"))


func _multiparm(data: Dictionary, parent: Control, asset: HEGoAssetNode, disabled: bool) -> void:
	var help: String = data.get("help", "")
	var frame := PanelContainer.new()
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.tooltip_text = help
	parent.add_child(frame)
	var body := _box(frame)
	var header := HBoxContainer.new()
	body.add_child(header)
	if not data.get("label_none", false):
		_heading(header, data.get("label", data.name), help)
	var count: int = data.get("instance_count", 0)
	var offset: int = data.get("instance_start_offset", 1)
	var is_ramp: bool = int(data.get("ramp_type", -1)) in [0, 1]
	var number := SpinBox.new()
	number.min_value = maxi(0, int(data.min)) if data.get("has_min", false) else 0
	number.max_value = int(data.max) if data.get("has_max", false) else maxi(100, count)
	number.allow_greater = not data.get("has_max", false)
	number.editable = not disabled
	number.step = 1
	number.set_value_no_signal(count)
	header.add_child(number)
	Field.apply_help(number, help)
	_mark_instance_control(number.get_line_edit(), data, asset, "count")
	number.value_changed.connect(func(v: float):
		if not disabled and int(v) != count:
			instance_count_requested.emit(data.name, int(v), asset))
	var add := Button.new()
	add.text = "Add key" if is_ramp else "+"
	add.tooltip_text = "Append a key" if is_ramp else "Append an instance"
	add.disabled = disabled or (data.get("has_max", false) and count >= data.max)
	header.add_child(add)
	Field.apply_help(add, help)
	_mark_instance_control(add, data, asset, "append")
	add.pressed.connect(func(): instance_requested.emit(data.name, data.id, offset + count, true, asset))
	var style := str(data.get("multiparm_style", data.get("tags", {}).get("hego_multiparm_style", "list")))
	var tabbed: TabContainer
	var scroll: ScrollContainer
	var key := _key(data, asset)
	if not is_ramp and style in ["tabs", "tabbed", "multiswitcher"]:
		tabbed = TabContainer.new()
		body.add_child(tabbed)
	elif not is_ramp and style in ["scroll", "scrolling", "multiscroll"]:
		scroll = ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.custom_minimum_size.y = 160
		body.add_child(scroll)
		body = _box(scroll)
	# Moving a ramp key past its neighbour changes its evaluated order. HAPI keeps the
	# original instance numbers and ids, which must still be used for edit/insert/remove.
	var order := range(count)
	if is_ramp:
		var positions := []
		for i in count:
			var position := float(i)
			for child in data.instances[i]:
				if child.get("template_name", "").ends_with("#pos") and not child.get("values", []).is_empty():
					position = float(child["values"][0])
					break
			positions.append(position)
		order.sort_custom(func(a: int, b: int):
			return a < b if positions[a] == positions[b] else positions[a] < positions[b])
	for display_index in order.size():
		var i: int = order[display_index]
		var children: Array = data.instances[i] if i < data.get("instances", []).size() else []
		var index := i + offset
		var title := str(display_index + offset) if is_ramp else _instance_label(data, children, index)
		var group := _box(tabbed if tabbed else body)
		if tabbed:
			tabbed.set_tab_title(i, title)
			tabbed.set_tab_tooltip(i, help)
		var actions := HBoxContainer.new()
		group.add_child(actions)
		if not tabbed:
			_heading(actions, ("Key %s" if is_ramp else "%s") % title, help)
		for insert in [true, false]:
			var action := Button.new()
			action.text = "Insert before" if insert else "Remove"
			action.disabled = disabled or (add.disabled if insert else count <= number.min_value)
			actions.add_child(action)
			Field.apply_help(action, help)
			_mark_instance_control(action, data, asset, ("insert_%d" if insert else "remove_%d") % index)
			action.pressed.connect(func(): instance_requested.emit(data.name, data.id, index, insert, asset))
		add_parameters(children, group, asset, disabled)
	if tabbed and count:
		tabbed.current_tab = clampi(int(_folder_state.get(key, 0)), 0, count - 1)
		tabbed.tab_changed.connect(func(i: int):
			if tabbed.is_inside_tree() and tabbed.get_tab_count() == count: _folder_state[key] = i)
	if scroll:
		scroll.set_deferred("scroll_vertical", int(_folder_state.get(key, 0)))
		scroll.get_v_scroll_bar().value_changed.connect(func(v: float): _folder_state[key] = int(v))


func _mark_instance_control(control: Control, data: Dictionary, asset: HEGoAssetNode, component: String) -> void:
	control.set_meta("hego_parm_name", str(data.name))
	control.set_meta("hego_parm_component", component)
	control.set_meta("hego_parm_asset", asset.get_instance_id() if asset else 0)


func _instance_label(data: Dictionary, children: Array, index: int) -> String:
	var pattern := str(data.get("tags", {}).get("sidefx::multi_label", ""))
	if not pattern.is_empty():
		for child in children:
			if child.get("template_name", "") == pattern and not child.get("values", []).is_empty():
				var title := str(child["values"][0])
				if not title.is_empty(): return title
	return str(index)
