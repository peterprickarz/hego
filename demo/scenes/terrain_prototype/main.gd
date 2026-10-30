extends Node3D
## Standalone demonstration: synthetic procedural base plus two manual lattices.

var terrain: StrataTerrain3D
var layers: Array[StrataLayer] = []
var camera: Camera3D
var cursor: MeshInstance3D
var selected := 1
var operation := "raise"
var channel: StringName = &"height"
var radius := 4.0
var strength := 0.65
var generation := 0
var _status: Label
var _message := "Paint a hill, then regenerate the base. Owned samples stay yours."
var _stroke_layer: StrataLayer
var _before: Dictionary
var _flatten := NAN
var _last_point := Vector2(INF, INF)
var _undo: Array = []
var _redo: Array = []
var _yaw := 0.55
var _pitch := 0.78
var _distance := 78.0
var _target := Vector3(0.0, 0.0, 0.0)
var _layer_choice: OptionButton
var _overrides_toggle: CheckButton
## Injectable paths let the integration check avoid a user's saved layers.
var save_path := "user://strata_layers.bin"
var editor_example_directory := "res://generated"

func _ready() -> void:
	RenderingServer.set_default_clear_color(Color("172324"))
	terrain = StrataTerrain3D.new()
	terrain.name = "LayeredTerrain"
	add_child(terrain)
	for spec in [["Synthetic procedural base", 1.0], ["Fine manual · 1 m · Replace", 1.0], ["Coarse manual · 2 m · Add", 2.0]]:
		var layer := StrataLayer.new()
		layer.name = spec[0]
		layer.data.sample_spacing = spec[1]
		terrain.add_child(layer)
		layers.append(layer)
	layers[2].set_composition(&"height", StrataLayer.Composition.ADD)
	terrain.preview_through_layer = layers[selected]
	terrain.show_overrides = true
	_regenerate(false)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, -30.0, 0.0)
	sun.light_energy = 0.9
	sun.shadow_enabled = true
	add_child(sun)
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("172324")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("adc4b8")
	environment.ambient_light_energy = 0.22
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world.environment = environment
	add_child(world)
	camera = Camera3D.new()
	camera.fov = 52.0
	add_child(camera)
	_update_camera()
	cursor = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.96
	ring.outer_radius = 1.0
	ring.rings = 48
	ring.ring_segments = 8
	cursor.mesh = ring
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("f0c982")
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	cursor.material_override = material
	cursor.visible = false
	add_child(cursor)
	_build_ui()
	terrain.preview_updated.connect(_update_status)
	_update_status()
	if OS.get_cmdline_user_args().has("--prepare-editor-example"):
		var error := _save_editor_example()
		if error == OK:
			print("Editor authoring example: res://generated/editor_example.tscn")
		get_tree().quit(error)

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var panel := PanelContainer.new()
	panel.position = Vector2(18.0, 18.0)
	panel.custom_minimum_size = Vector2(330.0, 0.0)
	panel.size = Vector2(330.0, maxf(180.0, get_viewport().get_visible_rect().size.y - 36.0))
	get_viewport().size_changed.connect(func(): panel.size.y = maxf(180.0, get_viewport().get_visible_rect().size.y - 36.0))
	var style := StyleBoxFlat.new()
	style.bg_color = Color("f2eddf")
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 18
	style.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", style)
	var theme := Theme.new()
	theme.default_font_size = 15
	theme.set_color("font_color", "Label", Color("263b35"))
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		theme.set_color(state, "CheckButton", Color("263b35"))
	panel.theme = theme
	canvas.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 9)
	scroll.add_child(box)
	_label(box, "HEGo / Terrain lab", 26)
	var intro := _label(box, "A finite terrain. Independent edit layers.\nSynthetic base · no Houdini connection", 14)
	intro.modulate = Color("6b796a")
	_separator(box)
	_label(box, "ACTIVE LAYER", 12)
	_layer_choice = OptionButton.new()
	_layer_choice.add_item("Fine manual · 1 m · Replace", 1)
	_layer_choice.add_item("Coarse manual · 2 m · Add", 2)
	_layer_choice.item_selected.connect(func(index: int):
		_finish_stroke()
		selected = _layer_choice.get_item_id(index)
		terrain.preview_through_layer = layers[selected]
		_update_status())
	box.add_child(_layer_choice)
	var channel_row := HBoxContainer.new()
	box.add_child(channel_row)
	_label(channel_row, "Channel", 14)
	var channel_edit := LineEdit.new()
	channel_edit.text = "height"
	channel_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	channel_edit.tooltip_text = "Named scalar channels are independent; the mesh previews height."
	channel_edit.text_changed.connect(func(value: String):
		channel = StringName(value if not value.is_empty() else "height")
		terrain.override_channel = channel
		_update_status())
	channel_row.add_child(channel_edit)
	_overrides_toggle = CheckButton.new()
	_overrides_toggle.text = "Show overrides"
	_overrides_toggle.button_pressed = terrain.show_overrides
	_overrides_toggle.tooltip_text = "Orange marks owned samples on the selected layer and channel, including unchanged values. Tint interpolates between samples; ownership itself is binary."
	_overrides_toggle.toggled.connect(func(value: bool): terrain.show_overrides = value)
	box.add_child(_overrides_toggle)
	var tools := OptionButton.new()
	for name in ["Raise", "Lower", "Flatten", "Smooth", "Erase ownership"]:
		tools.add_item(name)
	tools.item_selected.connect(func(index: int):
		_finish_stroke()
		operation = ["raise", "lower", "flatten", "smooth", "erase"][index])
	box.add_child(tools)
	_slider(box, "Radius", 0.5, 14.0, radius, func(value: float): radius = value)
	_slider(box, "Strength / dab", 0.05, 2.0, strength, func(value: float): strength = value)
	_separator(box)
	_button(box, "↻  Regenerate synthetic base", func(): _regenerate(true))
	var history := HBoxContainer.new()
	box.add_child(history)
	_button(history, "Undo", _undo_stroke)
	_button(history, "Redo", _redo_stroke)
	var storage := HBoxContainer.new()
	box.add_child(storage)
	_button(storage, "Save layers", _save_layers)
	_button(storage, "Reload layers", _load_layers)
	_status = _label(box, "", 13)
	_status.custom_minimum_size.x = 294.0
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_separator(box)
	_label(box, "Left drag  sculpt\nRight drag  orbit   ·   Wheel  zoom\nCtrl+Z / Ctrl+Shift+Z  undo / redo", 13)
	var footer := Label.new()
	footer.text = "ARRAYMESH PROTOTYPE  /  64 × 64 m  /  explicit sample ownership"
	footer.add_theme_color_override("font_color", Color("e7dfc6"))
	footer.position = Vector2(370.0, 22.0)
	canvas.add_child(footer)

func _label(parent: Node, text: String, size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	parent.add_child(label)
	return label

func _separator(parent: Node) -> void:
	parent.add_child(HSeparator.new())

func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _slider(parent: Node, text: String, minimum: float, maximum: float, initial: float, changed: Callable) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := _label(row, "%s  %.2f" % [text, initial], 14)
	label.custom_minimum_size.x = 155.0
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = 0.05
	slider.value = initial
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(func(value: float): label.text = "%s  %.2f" % [text, value]; changed.call(value))
	row.add_child(slider)

func _regenerate(advance: bool) -> void:
	_finish_stroke()
	if advance:
		generation += 1
	var base := layers[0].data
	var next := {"format_version": 1, "sample_spacing": 1.0, "grid_origin": Vector2.ZERO, "channels": {}}
	base.restore(next)
	var phase := generation * 1.3
	for z in range(-32, 33):
		for x in range(-32, 33):
			var h := 1.6 * sin(x * 0.13 + phase) * cos(z * 0.11 - phase * 0.6)
			h += 5.0 * exp(-Vector2(x + 10.0 * cos(phase), z + 8.0).length_squared() / 150.0)
			base.set_sample(&"height", Vector2i(x, z), h)
	_message = "Base generation %d. Manual ownership and deltas are preserved." % generation
	_update_status()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.ctrl_pressed and event.keycode == KEY_Z:
		if event.shift_pressed: _redo_stroke()
		else: _undo_stroke()
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = maxf(22.0, _distance * 0.9)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = minf(150.0, _distance * 1.1)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if not event.pressed:
				_finish_stroke()
				return
			var hit := _pick(event.position)
			if not hit.is_empty():
				_stroke_layer = layers[selected]
				_before = _stroke_layer.data.snapshot()
				_flatten = terrain.sample_channel(channel, hit.local_position, _stroke_layer)
				_last_point = Vector2(INF, INF)
				_dab(hit.local_position)
	elif event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
			_yaw -= event.relative.x * 0.007
			_pitch = clampf(_pitch + event.relative.y * 0.006, 0.18, 1.4)
			_update_camera()
		var hit := _pick(event.position)
		cursor.visible = not hit.is_empty()
		if not hit.is_empty():
			cursor.position = hit.position + Vector3.UP * 0.08
			cursor.scale = Vector3(radius, 1.0, radius)
			if _stroke_layer != null and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
				_dab(hit.local_position)

func _input(event: InputEvent) -> void:
	# A release over the panel still closes a stroke started over the terrain.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_finish_stroke()

func _pick(point: Vector2) -> Dictionary:
	return terrain.raycast_surface(camera.project_ray_origin(point), camera.project_ray_normal(point))

func _update_camera() -> void:
	camera.position = _target + Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * _distance
	camera.look_at(_target)

func _dab(point: Vector2) -> void:
	if _last_point.is_finite() and _last_point.distance_to(point) < radius * 0.1:
		return
	_last_point = point
	var touched := StrataBrush.apply_brush(_stroke_layer, point, radius, strength, operation, channel, _flatten)
	_message = "%s · %d native samples touched. Evaluation stops at the active layer." % [operation.capitalize(), touched]
	_update_status()

func _finish_stroke() -> void:
	if _stroke_layer == null:
		return
	var after := _stroke_layer.data.snapshot()
	if after != _before:
		_undo.append({"layer": _stroke_layer, "before": _before, "after": after})
		if _undo.size() > 64:
			_undo.pop_front()
		_redo.clear()
	_stroke_layer = null
	_update_status()

func _undo_stroke() -> void:
	_finish_stroke()
	if _undo.is_empty(): return
	var entry: Dictionary = _undo.pop_back()
	entry.layer.data.restore(entry.before)
	_redo.append(entry)
	_message = "Undid one stroke, including sample ownership."
	_update_status()

func _redo_stroke() -> void:
	_finish_stroke()
	if _redo.is_empty(): return
	var entry: Dictionary = _redo.pop_back()
	entry.layer.data.restore(entry.after)
	_undo.append(entry)
	_message = "Redid one complete stroke."
	_update_status()

func _save_layers() -> void:
	_finish_stroke()
	var saved_layers: Array = []
	for i in range(layers.size()):
		saved_layers.append({"data": layers[i].data.snapshot(), "modes": layers[i].composition_modes.duplicate(true)})
	# Binary Variant storage preserves the exact native float values and key types.
	var file := FileAccess.open(save_path, FileAccess.WRITE)
	var error := FileAccess.get_open_error()
	if file != null:
		file.store_var({"format_version": 1, "generation": generation, "layers": saved_layers})
		file.flush()
		error = file.get_error()
		file.close()
	_message = "Saved all native layer samples to %s" % save_path if error == OK else "Save failed: %s" % error_string(error)
	if error == OK:
		var scene_error := _save_editor_example()
		_message += "\nEditor scene: %s/editor_example.tscn" % editor_example_directory if scene_error == OK else "\nEditor scene export failed: %s" % error_string(scene_error)
	_update_status()

## An editor authoring fixture with real selectable scene-tree layer children
## and external native Resource files. Internal preview meshes are not packed.
func _save_editor_example() -> Error:
	var folder := editor_example_directory
	var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	if directory_error != OK:
		return directory_error
	var example := StrataTerrain3D.new()
	example.name = "EditableLayeredTerrain"
	example.base_bounds = terrain.base_bounds
	example.preview_spacing = terrain.preview_spacing
	for i in range(layers.size()):
		var layer := StrataLayer.new()
		layer.name = layers[i].name
		layer.data.restore(layers[i].data.snapshot())
		layer.composition_modes = layers[i].composition_modes.duplicate(true)
		var error := ResourceSaver.save(layer.data, "%s/layer_%d.res" % [folder, i], ResourceSaver.FLAG_CHANGE_PATH)
		if error != OK:
			example.free()
			layer.free()
			return error
		example.add_child(layer)
		layer.owner = example
	var scene := PackedScene.new()
	var error := scene.pack(example)
	if error == OK:
		error = ResourceSaver.save(scene, folder + "/editor_example.tscn")
	example.free()
	return error

func _load_layers() -> void:
	_finish_stroke()
	var file := FileAccess.open(save_path, FileAccess.READ)
	if file == null:
		_message = "No saved layers yet. Use Save layers first."
		_update_status()
		return
	var saved: Variant = file.get_var()
	file.close()
	if not saved is Dictionary or saved.get("format_version", 0) != 1 or not saved.get("layers") is Array or saved.layers.size() != layers.size():
		_message = "Saved terrain file has an unsupported format."
		_update_status()
		return
	for i in range(layers.size()):
		layers[i].data.restore(saved.layers[i].data)
		layers[i].composition_modes = saved.layers[i].modes
	generation = saved.get("generation", 0)
	_undo.clear()
	_redo.clear()
	_message = "Reloaded saved layers, resolutions, modes, values and ownership."
	_update_status()

func _update_status() -> void:
	if _status == null or layers.is_empty(): return
	var owned := layers[selected].data.get_owned_samples(channel).size()
	_status.text = "%d owned %s samples · %d undo / %d redo\n\n%s\n\nOrange tint shows selected ownership, interpolated between samples. Erase reveals the lower stack. Named channels persist; preview shows height." % [owned, channel, _undo.size(), _redo.size(), _message]
