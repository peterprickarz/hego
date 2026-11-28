@tool
extends VBoxContainer
## A leaf in the HDA parameter tree. Signals carry complete, validated-shape tuples.

signal value_requested(name: String, value: Variant, asset: HEGoAssetNode)
signal node_requested(name: String, source: Variant, asset: HEGoAssetNode)

enum Kind { INT, MULTIPARM, TOGGLE, BUTTON, FLOAT, COLOR, STRING, FILE, GEO_FILE, IMAGE_FILE, NODE, FOLDER_LIST, RADIO_LIST, FOLDER, LABEL, SEPARATOR, DIRECTORY }
enum Menu { NONE, NORMAL, MINI, REPLACE, TOGGLE }
enum ScriptType { ANGLE = 2, UV = 16, UVW = 17, OP_LIST = 23, GEOMETRY_DATA = 28, DICTIONARY = 29, RGBA_MASK = 31, FLOAT_LOG = 35, INT_LOG = 36, DATA = 37, FLOAT_MINMAX = 38, INT_MINMAX = 39, INT_STARTEND = 40, BUTTON_STRIP = 41, ICON_STRIP = 42 }
const DropField := preload("res://addons/hego/parm_controls/string_parm_line_edit.gd")

var descriptor: Dictionary
var asset: HEGoAssetNode
var node_candidates: Callable
var kind: int
var script_type: int
var locked: bool
var values: Array
var row: HBoxContainer
var _allow_local_files := true
var _icons: Dictionary


func setup(data: Dictionary, owner_asset: HEGoAssetNode, candidates: Callable, local_files: bool, icon_cache: Dictionary) -> void:
	descriptor = data
	asset = owner_asset
	node_candidates = candidates
	_allow_local_files = local_files
	_icons = icon_cache
	kind = data.type
	script_type = data.get("script_type", -1)
	locked = data.get("disabled", false)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var is_text := kind == Kind.STRING or _is_path()
	values = Array(data.get("raw_values", data.get("values", [])) if is_text else data.get("values", [])).duplicate()
	row = HBoxContainer.new()
	add_child(row)
	if not data.get("label_none", false) and kind not in [Kind.BUTTON, Kind.TOGGLE, Kind.SEPARATOR]:
		_label(row, data.get("label", data.name))
	match kind:
		Kind.SEPARATOR:
			var separator := HSeparator.new()
			separator.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(separator)
		Kind.LABEL:
			for value in values:
				if not str(value).is_empty():
					_label(self, str(value))
		Kind.BUTTON, Kind.TOGGLE:
			_action()
		Kind.NODE:
			_node_reference()
		_:
			_value_fields()
	apply_help(self, data.get("help", ""))


## Apply the authored help to each mouse target, including a SpinBox's built-in
## LineEdit. Keep action hints such as an icon strip button's choice label.
static func apply_help(control: Control, help: String) -> void:
	if help.is_empty():
		return
	if control.tooltip_text.is_empty():
		control.tooltip_text = help
	elif control.tooltip_text != help:
		control.tooltip_text += "\n\n" + help
	if control is Label:
		control.mouse_filter = Control.MOUSE_FILTER_PASS
	for child in control.get_children(true):
		if child is Control:
			apply_help(child, help)


func _is_path() -> bool:
	return kind in [Kind.FILE, Kind.GEO_FILE, Kind.IMAGE_FILE, Kind.DIRECTORY]


func _value_fields() -> void:
	var size: int = descriptor.get("size", 1)
	if size < 1 or values.size() != size or not str(descriptor.get("read_error", "")).is_empty():
		_read_only()
		return
	if kind == Kind.COLOR:
		if size in [3, 4]:
			_color()
		else:
			_read_only()
		return
	if kind not in [Kind.STRING, Kind.INT, Kind.FLOAT] and not _is_path():
		_read_only()
		return
	var fields := GridContainer.new()
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fields.columns = mini(size, 4) if not _is_path() and kind != Kind.STRING else 1
	row.add_child(fields)
	for i in size:
		var cell := HBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		fields.add_child(cell)
		if size > 1:
			_label(cell, _component_label(i, size))
		if _is_path():
			_text_field(cell, i)
			if _allow_local_files:
				_path_picker(cell, i)
		elif kind == Kind.INT and script_type == ScriptType.RGBA_MASK:
			_strip(cell, i, [{"label":"R"}, {"label":"G"}, {"label":"B"}, {"label":"A"}], Menu.TOGGLE)
		elif int(descriptor.get("choice_list_type", Menu.NONE)) != Menu.NONE and (not descriptor.get("choices", []).is_empty() or int(descriptor.choice_list_type) in [Menu.NORMAL, Menu.MINI]):
			_choices(cell, i)
		elif kind == Kind.INT or kind == Kind.FLOAT:
			_numeric(cell, i, size == 1)
		elif str(descriptor.get("tags", {}).get("editor", "")) == "1" or descriptor.get("tags", {}).has("editorlines"):
			_multiline(cell, i)
		else:
			_text_field(cell, i)


func _label(parent: Control, text: String) -> Label:
	var label := Label.new()
	label.text = text
	parent.add_child(label)
	return label


func _read_only() -> void:
	var explanation: String = descriptor.get("read_error", "")
	if explanation.is_empty():
		match script_type:
			ScriptType.GEOMETRY_DATA: explanation = "Geometry data (read-only)"
			ScriptType.DICTIONARY: explanation = "Dictionary (read-only)"
			ScriptType.DATA: explanation = "Data (read-only)"
			_: explanation = "Read-only · type %d, size %d" % [kind, descriptor.get("size", 0)]
	_label(row, explanation)


func _identify(control: Control, component: Variant) -> void:
	control.set_meta("hego_parm_name", str(descriptor.name))
	control.set_meta("hego_parm_component", str(component))
	control.set_meta("hego_parm_asset", asset.get_instance_id() if asset else 0)


func _button(parent: Control, caption: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.disabled = locked
	parent.add_child(button)
	button.pressed.connect(action)
	return button


func _component_label(index: int, size: int) -> String:
	if script_type in [ScriptType.FLOAT_MINMAX, ScriptType.INT_MINMAX]:
		return ["Min", "Max"][index] if index < 2 else str(index + 1)
	if script_type == ScriptType.INT_STARTEND:
		return ["Start", "End"][index] if index < 2 else str(index + 1)
	if script_type in [ScriptType.UV, ScriptType.UVW] and index < 3:
		return ["U", "V", "W"][index]
	if kind in [Kind.INT, Kind.FLOAT] and size <= 4:
		return ["X", "Y", "Z", "W"][index]
	return str(index + 1)


func _commit(index: int, value: Variant) -> void:
	# Focus loss during removal must never write data from the previous panel generation.
	if locked or not is_inside_tree() or is_queued_for_deletion() or values[index] == value:
		return
	values[index] = value
	var result: Variant = value
	if values.size() > 1:
		if kind == Kind.INT:
			match values.size():
				2: result = Vector2i(values[0], values[1])
				3: result = Vector3i(values[0], values[1], values[2])
				4: result = Vector4i(values[0], values[1], values[2], values[3])
				_: result = PackedInt32Array(values)
		elif kind == Kind.FLOAT:
			match values.size():
				2: result = Vector2(values[0], values[1])
				3: result = Vector3(values[0], values[1], values[2])
				4: result = Vector4(values[0], values[1], values[2], values[3])
				_: result = PackedFloat64Array(values)
		else:
			result = PackedStringArray(values)
	value_requested.emit(descriptor.name, result, asset)


func _action() -> void:
	var caption: String = descriptor.get("label", descriptor.name)
	if kind == Kind.BUTTON:
		_identify(_button(row, caption, func(): value_requested.emit(descriptor.name, 0, asset)), 0)
	elif values.size() == 1:
		var checkbox := CheckBox.new()
		checkbox.text = caption if not descriptor.get("label_none", false) else ""
		checkbox.disabled = locked
		checkbox.set_pressed_no_signal(bool(values[0]))
		row.add_child(checkbox)
		_identify(checkbox, 0)
		checkbox.toggled.connect(func(pressed: bool): _commit(0, int(pressed)))
	else:
		_read_only()


func _numeric(parent: Control, index: int, slider_enabled: bool) -> void:
	var integer := kind == Kind.INT
	var value := float(values[index])
	var has_min: bool = descriptor.get("has_min", false)
	var has_max: bool = descriptor.get("has_max", false)
	var spin := SpinBox.new()
	spin.min_value = float(descriptor.min) if has_min else minf(0, value)
	spin.max_value = float(descriptor.max) if has_max else maxf(100, value)
	spin.allow_lesser = not has_min
	spin.allow_greater = not has_max
	# A fixed decimal step rounds valid HAPI float32 values, even when setting up
	# a field. Arrow increments are independent of rounding manually typed values.
	spin.step = 1 if integer else 0
	spin.custom_arrow_step = 1 if integer else 0.01
	if not integer and descriptor.get("has_ui_min", false) and descriptor.get("has_ui_max", false):
		var width := float(descriptor.ui_max) - float(descriptor.ui_min)
		if width > 0: spin.custom_arrow_step = minf(0.01, width / 100.0)
	spin.editable = not locked
	spin.suffix = "°" if script_type == ScriptType.ANGLE else ""
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.set_value_no_signal(value)
	# Godot's SpinBox formats in fixed decimals, which rounds very small values
	# to a literal zero. Keep its Range for hard bounds and show an exponent field.
	var exponent: LineEdit
	if not integer and ((value != 0 and absf(value) < 0.000001) or spin.custom_arrow_step < 0.00000001):
		exponent = LineEdit.new()
		exponent.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		exponent.editable = not locked
		exponent.text = _float_text(value)
		var accept := func(text: String):
			if text == _float_text(spin.value): return
			if text.is_valid_float() and is_finite(text.to_float()):
				spin.value = text.to_float()
			exponent.text = _float_text(spin.value)
		exponent.text_submitted.connect(accept)
		exponent.focus_exited.connect(func(): accept.call(exponent.text))
	var slider: HSlider
	if slider_enabled:
		slider = HSlider.new()
		slider.min_value = descriptor.get("ui_min", 0) if descriptor.get("has_ui_min", false) else spin.min_value
		slider.max_value = descriptor.get("ui_max", 1) if descriptor.get("has_ui_max", false) else (float(descriptor.max) if has_max else maxf(slider.min_value + 1, value))
		if has_min: slider.min_value = maxf(slider.min_value, descriptor.min)
		if has_max: slider.max_value = minf(slider.max_value, descriptor.max)
		slider.step = 1 if integer else 0
		slider.exp_edit = script_type in [ScriptType.INT_LOG, ScriptType.FLOAT_LOG] and slider.min_value > 0
		slider.editable = not locked
		slider.scrollable = false
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.custom_minimum_size.x = 64
		slider.set_value_no_signal(value)
		parent.add_child(slider)
		_identify(slider, "slider")
		slider.drag_started.connect(func(): slider.set_meta("dragging", true))
		slider.value_changed.connect(func(v: float):
			spin.set_value_no_signal(v)
			if exponent: exponent.text = _float_text(v)
			if not slider.get_meta("dragging", false):
				_commit(index, int(v) if integer else v))
		slider.drag_ended.connect(func(changed: bool):
			slider.set_meta("dragging", false)
			if changed:
				_commit(index, int(slider.value) if integer else slider.value))
	parent.add_child(spin)
	if exponent:
		spin.hide()
		parent.add_child(exponent)
		_identify(exponent, index)
	else:
		_identify(spin.get_line_edit(), index)
	spin.value_changed.connect(func(v: float):
		if slider: slider.set_value_no_signal(v)
		_commit(index, int(v) if integer else v))


func _float_text(value: float) -> String:
	if value == 0.0: return "0"
	var power := floori(log(absf(value)) / log(10.0))
	# Nine significant digits round-trip every finite HAPI single precision value.
	var mantissa := String.num(value / pow(10.0, power), 8).rstrip("0").trim_suffix(".")
	return "%se%d" % [mantissa, power]


func _text_field(parent: Control, index: int) -> LineEdit:
	var field: LineEdit
	if script_type == ScriptType.OP_LIST or (_is_path() and not _allow_local_files):
		field = LineEdit.new()
	else:
		var droppable := DropField.new()
		droppable.filesystem_path = _is_path()
		droppable.dropped.connect(func(v: String): _commit_text(index, v))
		field = droppable
	field.editable = not locked
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.text = str(values[index])
	parent.add_child(field)
	_identify(field, index)
	field.text_submitted.connect(func(v: String): _commit_text(index, v))
	field.focus_exited.connect(func(): _commit_text(index, field.text))
	return field


func _commit_text(index: int, text: String) -> void:
	if kind == Kind.INT:
		if text.is_valid_int(): _commit(index, text.to_int())
	else:
		_commit(index, text)


func _multiline(parent: Control, index: int) -> void:
	var field := TextEdit.new()
	field.text = str(values[index])
	field.editable = not locked
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var lines := str(descriptor.get("tags", {}).get("editorlines", "4")).to_int()
	field.custom_minimum_size.y = clampi(lines, 2, 20) * field.get_line_height() + 8
	parent.add_child(field)
	_identify(field, index)
	field.focus_exited.connect(func(): _commit(index, field.text))
	field.gui_input.connect(func(event: InputEvent):
		if event is InputEventKey and event.is_pressed() and event.keycode == KEY_ENTER and event.is_command_or_control_pressed():
			field.accept_event()
			_commit(index, field.text))


func _path_picker(parent: Control, index: int) -> void:
	var permissions: int = descriptor.get("permissions", 0)
	if kind != Kind.DIRECTORY and permissions == 1:
		var picker := MenuButton.new()
		picker.text = "Browse…"
		picker.disabled = locked
		parent.add_child(picker)
		var popup := picker.get_popup()
		popup.add_item("Open file", FileDialog.FILE_MODE_OPEN_FILE)
		popup.add_item("Save file", FileDialog.FILE_MODE_SAVE_FILE)
		popup.id_pressed.connect(func(mode: int): _browse(index, mode))
	else:
		var mode := FileDialog.FILE_MODE_OPEN_FILE
		if kind == Kind.DIRECTORY: mode = FileDialog.FILE_MODE_OPEN_DIR
		elif permissions == 3: mode = FileDialog.FILE_MODE_SAVE_FILE
		_button(parent, "Browse…", func(): _browse(index, mode))


func _browse(index: int, mode: int) -> void:
	if locked or not _allow_local_files: return
	var dialog := FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = mode
	var pattern := str(descriptor.get("type_info", "")).strip_edges()
	if kind != Kind.DIRECTORY and not pattern.is_empty():
		dialog.add_filter(",".join(pattern.split(" ", false)), pattern)
	var authored := str(values[index])
	if authored.is_absolute_path(): dialog.current_path = authored
	add_child(dialog)
	var select := func(path: String):
		_commit(index, ProjectSettings.globalize_path(path))
		dialog.queue_free()
	dialog.file_selected.connect(select)
	dialog.dir_selected.connect(select)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered_ratio(0.7)


func _color() -> void:
	var button := ColorPickerButton.new()
	button.edit_alpha = values.size() == 4
	button.edit_intensity = true
	button.disabled = locked
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var initial := Color(values[0], values[1], values[2], values[3] if button.edit_alpha else 1.0)
	button.color = initial
	row.add_child(button)
	_identify(button, 0)
	button.picker_created.connect(func(): button.get_picker().color_mode = ColorPicker.MODE_RAW)
	button.popup_closed.connect(func():
		if not locked and button.color != button.get_meta("previous_color", initial):
			button.set_meta("previous_color", button.color)
			value_requested.emit(descriptor.name, button.color, asset))


func _choice_value(choice: Dictionary, ordinal: int) -> Variant:
	if kind == Kind.STRING:
		return str(choice.value)
	if descriptor.get("use_menu_item_token_as_value", false):
		return str(choice.value).to_int() if str(choice.value).is_valid_int() else null
	return ordinal


func _choices(parent: Control, index: int) -> void:
	var choices: Array = descriptor.get("choices", [])
	var mode: int = descriptor.get("choice_list_type", Menu.NORMAL)
	if script_type in [ScriptType.BUTTON_STRIP, ScriptType.ICON_STRIP]:
		_strip(parent, index, choices, mode)
		return
	if mode in [Menu.MINI, Menu.REPLACE, Menu.TOGGLE]:
		var field: LineEdit
		if mode != Menu.MINI:
			field = _text_field(parent, index)
		var menu := MenuButton.new()
		menu.text = "▾"
		menu.tooltip_text = descriptor.get("label", descriptor.name)
		menu.disabled = locked or choices.is_empty()
		parent.add_child(menu)
		_identify(menu, index if mode == Menu.MINI else "menu_%d" % index)
		var popup := menu.get_popup()
		for i in choices.size():
			if mode == Menu.TOGGLE:
				popup.add_check_item(choices[i].label, i)
				popup.set_item_checked(i, _choice_checked(index, choices[i], i))
			else:
				popup.add_item(choices[i].label, i)
			if mode != Menu.TOGGLE:
				popup.set_item_disabled(i, _choice_value(choices[i], i) == null)
		popup.id_pressed.connect(func(i: int):
			var result = _toggled_value(index, choices[i], i) if mode == Menu.TOGGLE else _choice_value(choices[i], i)
			if result != null:
				if field: field.text = str(result)
				_commit(index, result))
		return
	var select := OptionButton.new()
	select.disabled = locked or choices.is_empty()
	select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(select)
	_identify(select, index)
	var selected := -1
	for i in choices.size():
		var token = _choice_value(choices[i], i)
		select.add_item(str(choices[i].label))
		select.set_item_metadata(i, token)
		select.set_item_disabled(i, token == null)
		if token == values[index]: selected = i
	if selected < 0:
		selected = select.item_count
		select.add_item(str(values[index]))
		select.set_item_disabled(selected, true)
	select.select(selected)
	select.item_selected.connect(func(i: int): _commit(index, select.get_item_metadata(i)))


func _choice_checked(index: int, choice: Dictionary, ordinal: int) -> bool:
	if kind == Kind.STRING:
		return str(choice.value) in str(values[index]).split(" ", false)
	return (int(values[index]) & (1 << ordinal)) != 0


func _toggled_value(index: int, choice: Dictionary, ordinal: int) -> Variant:
	if kind == Kind.INT:
		return int(values[index]) ^ (1 << ordinal)
	var tokens := Array(str(values[index]).split(" ", false))
	var value := str(choice.value)
	if value in tokens:
		tokens.erase(value)
	else:
		tokens.append(value)
	return " ".join(tokens)


func _strip(parent: Control, index: int, choices: Array, mode: int) -> void:
	var group := ButtonGroup.new() if mode != Menu.TOGGLE else null
	for i in choices.size():
		var choice: Dictionary = choices[i]
		var button := Button.new()
		button.text = str(choice.label)
		if script_type == ScriptType.ICON_STRIP:
			var icon := _strip_icon(str(choice.get("icon", choice.get("value", ""))))
			if icon:
				button.text = ""
				button.icon = icon
				button.tooltip_text = str(choice.label)
				button.add_theme_constant_override("icon_max_width", 22)
		button.toggle_mode = true
		button.button_group = group
		button.disabled = locked
		button.set_pressed_no_signal(_choice_checked(index, choice, i) if mode == Menu.TOGGLE else values[index] == _choice_value(choice, i))
		parent.add_child(button)
		_identify(button, "choice_%d_%d" % [index, i])
		button.pressed.connect(func():
			var result = _toggled_value(index, choice, i) if mode == Menu.TOGGLE else _choice_value(choice, i)
			if result != null: _commit(index, result))


func _strip_icon(token: String) -> Texture2D:
	if token.begins_with("res://"):
		return load(token) as Texture2D if ResourceLoader.exists(token, "Texture2D") else null
	var split_at := token.find("_")
	if split_at <= 0 or token != token.get_file(): return null
	# SideFX's SOP_box convention maps to SOP/box.svg inside the installed icon archive.
	var path := HEGoAPI.get_singleton().get_houdini_installation_path().path_join("houdini/config/Icons/icons.zip")
	var key := path + "|" + token
	if _icons.has(key): return _icons[key]
	_icons[key] = null
	var zip := ZIPReader.new()
	if not FileAccess.file_exists(path) or zip.open(path) != OK: return null
	var member := token.left(split_at) + "/" + token.substr(split_at + 1) + ".svg"
	if zip.file_exists(member):
		var image := Image.new()
		if image.load_svg_from_buffer(zip.read_file(member)) == OK:
			_icons[key] = ImageTexture.create_from_image(image)
	zip.close()
	return _icons[key]


func _node_reference() -> void:
	var menu := MenuButton.new()
	var path := str(values[0]) if not values.is_empty() else ""
	menu.text = path if not path.is_empty() else "Select Houdini node…"
	menu.disabled = locked or not node_candidates.is_valid()
	menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(menu)
	_identify(menu, 0)
	var popup := menu.get_popup()
	popup.about_to_popup.connect(_populate_candidates.bind(popup))
	popup.id_pressed.connect(func(id: int):
		node_requested.emit(descriptor.name, popup.get_item_metadata(popup.get_item_index(id)), asset))
	var clear := _button(row, "Clear", func(): node_requested.emit(descriptor.name, null, asset))
	clear.disabled = locked or (int(descriptor.get("node_id", -1)) < 0 and path.is_empty())


func _populate_candidates(popup: PopupMenu) -> void:
	popup.clear()
	popup.add_item("Loading…")
	popup.set_item_disabled(0, true)
	var candidates = await node_candidates.call(asset, descriptor)
	if not is_instance_valid(popup) or not popup.is_inside_tree(): return
	popup.clear()
	if candidates is Array:
		for candidate in candidates:
			if candidate is Dictionary and is_instance_valid(candidate.get("node")):
				popup.add_item(str(candidate.label))
				popup.set_item_metadata(popup.item_count - 1, candidate.node)
	if popup.item_count == 0:
		popup.add_item("No compatible live sources")
		popup.set_item_disabled(0, true)
