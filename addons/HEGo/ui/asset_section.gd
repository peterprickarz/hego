@tool
class_name HEGoAssetSection
extends VBoxContainer

## One collapsible block of parameters in the bottom panel, for one HDA.
##
## A node that puts several HDAs in the panel gets one of these per HDA. A node with a
## single HDA gets its parameters directly and no header, so the common case looks exactly
## as it did.

## Emitted when the user opens or closes the section, so the panel can remember it.
signal open_changed(asset_label: String, is_open: bool)

## The label the node gave this HDA. The panel remembers the open state by it.
var asset_label: String

var _header: Button
var _body: VBoxContainer


## Builds the section for [param operator_name], titled with [param p_asset_label].
func setup(p_asset_label: String, operator_name: String, is_open: bool) -> void:
	asset_label = p_asset_label

	_header = Button.new()
	_header.toggle_mode = true
	_header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_header.text = "%s  (%s)" % [asset_label, operator_name]
	# Assigning button_pressed would emit toggled, which calls back into the panel and
	# rebuilds the section that is still being built. set_pressed_no_signal does not.
	_header.set_pressed_no_signal(is_open)
	_header.toggled.connect(_on_header_toggled)
	add_child(_header)

	_body = VBoxContainer.new()
	_body.visible = is_open
	add_child(_body)


## Where this section's parameter widgets go.
func get_container() -> VBoxContainer:
	return _body


## Opens the section without reporting it, for when a script asked for it rather than the
## user. The panel's remembered state is the user's, and highlighting should not overwrite it.
func open() -> void:
	_header.set_pressed_no_signal(true)
	_body.visible = true


## Draws attention to the section a script highlighted.
func mark_highlighted() -> void:
	_header.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	_header.add_theme_color_override("font_pressed_color", Color(1.0, 0.8, 0.2))
	_header.add_theme_color_override("font_hover_color", Color(1.0, 0.9, 0.5))


func _on_header_toggled(is_open: bool) -> void:
	_body.visible = is_open
	open_changed.emit(asset_label, is_open)
