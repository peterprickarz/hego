@tool
class_name HEGoStrataInputSettings
extends VBoxContainer
## The terrain options HEGo's panel shows in an input row that reads a terrain layer.
## [HEGoStrataInput] creates it; see [method HEGoInputHandler.create_settings_editor].

signal changed

var mode: OptionButton
var channels: LineEdit
var spacing: SpinBox
var status_label: Label
var _channel_spacings: Dictionary = {}
var _loading := false


func _init() -> void:
	name = "TerrainOptions"
	mode = OptionButton.new()
	mode.add_item("Terrain: cumulative through selected layer", 0)
	mode.add_item("Terrain: raw values + separate ownership", 1)
	mode.item_selected.connect(func(_index: int): _edited())
	add_child(mode)
	channels = LineEdit.new()
	channels.placeholder_text = "Channels: height, mask, ... (blank = all)"
	channels.tooltip_text = "Exact scalar names, comma-separated. Raw mode sends independent binary ownership volumes; cumulative coverage may be fractional. Terrain stages recook explicitly."
	channels.text_changed.connect(func(_text: String): _edited())
	add_child(channels)
	spacing = SpinBox.new()
	spacing.prefix = "Cumulative spacing"
	spacing.suffix = "m (0 = native)"
	spacing.min_value = 0.0
	spacing.max_value = 1024.0
	spacing.step = 0.25
	spacing.tooltip_text = "Cumulative mode only: sample the composed terrain on an endpoint-aligned lattice of this spacing over the terrain bounds, instead of the selected layer's native grid (for example a 4 m view through a 0.25 m manual layer). 0 keeps the native lattice. Raw mode ignores it."
	spacing.value_changed.connect(func(_value: float): _edited())
	add_child(spacing)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status_label)


func load_settings(settings: Dictionary) -> void:
	_loading = true
	mode.select(1 if settings.get("terrain_mode", "cumulative") == "raw" else 0)
	var stored := float(settings.get("terrain_spacing", 0.0))
	spacing.set_value_no_signal(stored if is_finite(stored) and stored > 0.0 else 0.0)
	var names: Variant = settings.get("terrain_channels", "height")
	channels.text = String(names) if names is String else ", ".join(PackedStringArray(names))
	_channel_spacings = settings.get("terrain_channel_spacings", {}).duplicate()
	_loading = false


## terrain_spacing is always written, so 0 replaces a spacing stored earlier. Per-channel
## spacings and the sample budget are not edited here and stay as stored.
func get_settings() -> Dictionary:
	return {
		HEGoStrataInput.SETTINGS_MARKER: true,
		"terrain_mode": "raw" if mode.selected == 1 else "cumulative",
		"terrain_channels": channels.text,
		"terrain_spacing": spacing.value,
	}


func refresh(_host: Node, nodes: Array) -> void:
	spacing.editable = mode.selected == 0
	var descriptions := PackedStringArray()
	if not _channel_spacings.is_empty():
		var spacings := PackedStringArray()
		for value in _channel_spacings.values():
			var text := "%.3f m" % float(value)
			if not spacings.has(text): spacings.append(text)
		descriptions.append("%d named channel spacing overrides: %s. Other channels use the spacing above/native grid. Overrides remain in Input Stash settings." % [_channel_spacings.size(), ", ".join(spacings)])
	for node in nodes:
		var layer := node as StrataLayer
		if layer == null: continue
		var shape := "%.3f m grid / origin %s" % [layer.data.sample_spacing, layer.data.grid_origin]
		if not layer.procedural_fields.is_empty():
			shape = "%d independent native channel grids" % layer.procedural_fields.size()
		descriptions.append("%s · %s · %s" % [layer.name, shape, layer.procedural_status if layer.procedural else "manual ownership"])
	status_label.text = "Explicit recook. Cached results remain visible.\n" + ("\n".join(descriptions) if not descriptions.is_empty() else "Terrain source is missing; cooking will reject the incomplete input.")


func _edited() -> void:
	if _loading: return
	spacing.editable = mode.selected == 0
	changed.emit()
