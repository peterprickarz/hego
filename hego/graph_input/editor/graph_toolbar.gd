@tool
extends HBoxContainer

signal mode_changed(mode: int)
signal placement_changed(mode: int)
signal world_axis_changed(axis: int)
signal world_offset_changed(offset: float)

var _select: Button
var _draw: Button
var _placement: OptionButton
var _axis: OptionButton
var _offset: SpinBox


func _ready() -> void:
	add_theme_constant_override("separation", 8)

	_select = _toggle("Select")
	_draw = _toggle("Draw")
	_select.tooltip_text = "Select points or connections. C connects two selected points."
	_draw.tooltip_text = "Ctrl+click to draw. C connects two selected points."
	_select.button_group = ButtonGroup.new()
	_draw.button_group = _select.button_group
	_draw.button_pressed = true
	_select.pressed.connect(func() -> void: mode_changed.emit(0))
	_draw.pressed.connect(func() -> void: mode_changed.emit(1))

	add_child(VSeparator.new())

	_placement = OptionButton.new()
	_placement.add_item("Camera plane")
	_placement.add_item("World plane")
	_placement.add_item("Geometry")
	_placement.item_selected.connect(func(index: int) -> void:
		_axis.visible = index == 1
		_offset.visible = index == 1
		placement_changed.emit(index)
	)
	add_child(_placement)

	_axis = OptionButton.new()
	_axis.add_item("XZ")
	_axis.add_item("XY")
	_axis.add_item("YZ")
	_axis.item_selected.connect(func(index: int) -> void: world_axis_changed.emit(index))
	_axis.visible = false
	add_child(_axis)

	_offset = SpinBox.new()
	_offset.prefix = "off "
	_offset.min_value = -1000
	_offset.max_value = 1000
	_offset.step = 0.1
	_offset.allow_greater = true
	_offset.allow_lesser = true
	_offset.value_changed.connect(func(value: float) -> void: world_offset_changed.emit(value))
	_offset.visible = false
	add_child(_offset)


func set_mode(mode: int) -> void:
	_draw.button_pressed = mode == 1
	_select.button_pressed = mode == 0


func _toggle(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.toggle_mode = true
	add_child(button)
	return button
