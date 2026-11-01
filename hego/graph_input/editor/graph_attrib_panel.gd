@tool
extends VBoxContainer

signal attrib_changed(owner_kind: int, name: String, value: Variant)

const OWNER_POINT := 0
const OWNER_CONNECTION := 1

## Status line; always shown so the strip keeps its height.
var _status: Label


func _ready() -> void:
	_status = Label.new()
	_status.text = "Select points or connections to edit attributes."
	add_child(_status)


## Every schema row is always built, disabled when nothing of its owner is
## selected, so the strip (and the viewport above it) never changes height
## as the selection changes.
func rebuild(graph: HEGoGraphInput3D, selected_points: PackedInt32Array, selected_connections: PackedInt32Array) -> void:
	for child in get_children():
		if child != _status:
			# Detach now: queue_free alone leaves the old rows in the layout
			# for a frame, and the strip would briefly double in height.
			remove_child(child)
			child.queue_free()

	var has_points := selected_points.size() > 0
	var has_conns := selected_connections.size() > 0
	_status.text = _status_text(selected_points.size(), selected_connections.size())
	if graph == null:
		return

	for def in graph.collect_schema(false):
		if def.owner == HEGoGraphAttributeDef.Owner.POINT:
			_add_row(def, OWNER_POINT, _mixed(graph.point_attribs.get(def.attribute_name), selected_points), has_points)
		elif def.owner == HEGoGraphAttributeDef.Owner.CONNECTION:
			_add_row(def, OWNER_CONNECTION, _mixed(graph.connection_attribs.get(def.attribute_name), selected_connections), has_conns)


func _status_text(points: int, conns: int) -> String:
	if points == 0 and conns == 0:
		return "Select points or connections to edit attributes."
	var parts := PackedStringArray()
	if points > 0:
		parts.append("%d point%s" % [points, "" if points == 1 else "s"])
	if conns > 0:
		parts.append("%d connection%s" % [conns, "" if conns == 1 else "s"])
	return ", ".join(parts) + " selected."


func _mixed(array: Variant, indices: PackedInt32Array) -> Variant:
	if array == null or indices.is_empty():
		return null
	var first: Variant = null
	var have_first := false
	for index in indices:
		if index < 0 or index >= array.size():
			continue
		if not have_first:
			first = array[index]
			have_first = true
		elif array[index] != first:
			return null
	return first if have_first else null


func _add_row(def: HEGoGraphAttributeDef, owner_kind: int, value: Variant, enabled: bool) -> void:
	var row := HBoxContainer.new()
	var owner_label := Label.new()
	owner_label.text = "Point" if owner_kind == OWNER_POINT else "Connection"
	owner_label.custom_minimum_size.x = 90
	owner_label.modulate.a = 0.6
	row.add_child(owner_label)
	var label := Label.new()
	label.text = def.attribute_name
	label.custom_minimum_size.x = 100
	row.add_child(label)
	if not enabled:
		label.modulate.a = 0.5

	var mixed := value == null or not enabled
	if def.value_type == HEGoGraphAttributeDef.ValueType.INT and def.int_as_toggle:
		var box := CheckBox.new()
		if not mixed:
			box.button_pressed = bool(value)
		box.disabled = not enabled
		box.toggled.connect(func(pressed: bool) -> void:
			attrib_changed.emit(owner_kind, def.attribute_name, 1 if pressed else 0)
		)
		row.add_child(box)
	elif def.value_type == HEGoGraphAttributeDef.ValueType.STRING and def.string_options.size() > 0:
		var options := OptionButton.new()
		for i in def.string_options.size():
			options.add_item(def.string_options[i], i)
		if not mixed:
			var idx := def.string_options.find(str(value))
			options.selected = idx
		options.disabled = not enabled
		options.item_selected.connect(func(index: int) -> void:
			attrib_changed.emit(owner_kind, def.attribute_name, def.string_options[index])
		)
		row.add_child(options)
	elif def.value_type == HEGoGraphAttributeDef.ValueType.STRING:
		var edit := LineEdit.new()
		edit.custom_minimum_size.x = 160
		if mixed:
			edit.placeholder_text = "—"
		else:
			edit.text = str(value)
		edit.editable = enabled
		edit.text_submitted.connect(func(text: String) -> void:
			attrib_changed.emit(owner_kind, def.attribute_name, text)
		)
		row.add_child(edit)
	else:
		var spin := SpinBox.new()
		spin.allow_greater = true
		spin.allow_lesser = true
		spin.step = 1.0 if def.value_type == HEGoGraphAttributeDef.ValueType.INT else 0.01
		spin.rounded = def.value_type == HEGoGraphAttributeDef.ValueType.INT
		if not mixed:
			spin.value = float(value)
		spin.editable = enabled
		spin.value_changed.connect(func(v: float) -> void:
			if def.value_type == HEGoGraphAttributeDef.ValueType.INT:
				attrib_changed.emit(owner_kind, def.attribute_name, int(v))
			else:
				attrib_changed.emit(owner_kind, def.attribute_name, v)
		)
		row.add_child(spin)

	add_child(row)
