@tool
extends EditorPlugin

const CANONICAL_MASKS: PackedStringArray = ["hole", "nav_exclusion"]

var _layer: StrataLayer
var _toolbar: HBoxContainer
var _radius: SpinBox
var _strength: SpinBox
var _operation: OptionButton
var _channel: LineEdit
var _channel_menu: MenuButton
# Channel name per popup item id; rebuilt every time the menu opens.
var _channel_items := PackedStringArray()
var _overrides: CheckButton
var _channel_view: CheckButton
# One entry per dab that changed something; see StrataBrush.begin_record().
var _stroke_records: Array = []
var _stroke_layer: StrataLayer
var _flatten := NAN
var _last_point := Vector2(INF, INF)
var _scene: Node
var _bridges: Array[StrataEditorPreview] = []
var _scan_elapsed := 0.0
var _status: Label
var _editor_camera: Camera3D
var _cursor: StrataBrushCursor
# Terrain-local point under the pointer, so a radius change redraws the cursor in place.
var _hover_point := Vector2(INF, INF)

func _enter_tree() -> void:
	_toolbar = HBoxContainer.new()
	var title := Label.new()
	title.text = "Terrain brush"
	_toolbar.add_child(title)
	_operation = OptionButton.new()
	for operation in ["raise", "lower", "flatten", "smooth", "erase"]:
		_operation.add_item(operation.capitalize())
	_toolbar.add_child(_operation)
	_radius = _number("Radius", 0.25, StrataBrush.MAX_RADIUS_METERS, 4.0)
	_radius.step = 0.25
	_radius.suffix = "m"
	_radius.custom_minimum_size.x = 112.0
	_radius.tooltip_text = "Type a radius up to 4096 m. Dabs keep the 65,536-sample budget; select a coarse manual layer or add a new one for broad mountains. Existing layer spacing must not be changed to resize a brush."
	_radius.value_changed.connect(func(_value: float): _update_cursor())
	_strength = _number("Strength", 0.01, 10.0, 0.6)
	_channel = LineEdit.new()
	_channel.text = "height"
	_channel.placeholder_text = "Channel"
	_channel.custom_minimum_size.x = 160.0
	_channel.tooltip_text = "Named scalar channel. Type a new name or pick an existing one from the list. Show channel displays values. hole/nav_exclusion: Raise=1, Lower=0, Erase=reveal. Material channels paint coverage: Raise/Lower move that material's share of the mix, Erase reveals the materials below."
	_toolbar.add_child(_channel)
	_channel.text_changed.connect(_apply_channel)
	_channel_menu = MenuButton.new()
	_channel_menu.text = "▾"
	_channel_menu.flat = false
	_channel_menu.tooltip_text = "Channels already in this terrain: height, the material weight channels, the canonical masks and whatever the layers hold."
	_channel_menu.about_to_popup.connect(_fill_channel_menu)
	_channel_menu.get_popup().id_pressed.connect(func(id: int):
		if id >= 0 and id < _channel_items.size(): set_channel(_channel_items[id]))
	_toolbar.add_child(_channel_menu)
	_overrides = CheckButton.new()
	_overrides.text = "Show overrides"
	_overrides.tooltip_text = "Orange tint interpolates the selected channel's explicit owned samples, including unchanged values."
	_overrides.toggled.connect(func(value: bool):
		if is_instance_valid(_layer) and _layer.get_parent() is StrataTerrain3D:
			_layer.get_parent().show_overrides = value)
	_toolbar.add_child(_overrides)
	_channel_view = CheckButton.new()
	_channel_view.text = "Show channel"
	_channel_view.tooltip_text = "Grayscale scalar values; terrain geometry remains height. Alt + mouse navigates."
	_channel_view.toggled.connect(func(value: bool):
		if is_instance_valid(_layer) and _layer.get_parent() is StrataTerrain3D:
			_layer.get_parent().editor_show_channel = value
			_layer.get_parent().queue_preview_update())
	_toolbar.add_child(_channel_view)
	_status = Label.new()
	_status.text = "Select a manual layer; Alt + mouse navigates"
	_toolbar.add_child(_status)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
	_toolbar.hide()
	set_input_event_forwarding_always_enabled()

func _number(label_text: String, minimum: float, maximum: float, initial: float) -> SpinBox:
	var label := Label.new()
	label.text = label_text
	_toolbar.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = 0.05
	spin.value = initial
	_toolbar.add_child(spin)
	return spin

func _terrain() -> StrataTerrain3D:
	return _layer.get_parent() as StrataTerrain3D if is_instance_valid(_layer) else null

## Sets the brush channel as if it had been typed into the toolbar.
func set_channel(channel: String) -> void:
	_channel.text = channel
	_apply_channel(channel)

func _apply_channel(value: String) -> void:
	var terrain := _terrain()
	if terrain != null: terrain.override_channel = StringName(value)
	_update_cursor()

## Lists the channels that already exist for the selected terrain, grouped: height, the
## material weight channels (with their material's file name), the canonical masks and
## every other channel some layer holds or cooks. Typing in the field still names a new one.
func _fill_channel_menu() -> void:
	var popup := _channel_menu.get_popup()
	popup.clear()
	_channel_items = PackedStringArray()
	var current := _channel.text.strip_edges()
	var listed := {}
	_add_channel_item(popup, "height", "height", current, listed)
	var terrain := _terrain()
	if terrain == null: return
	if not terrain.editor_material_channels.is_empty():
		popup.add_separator("Materials")
		for index in range(terrain.editor_material_channels.size()):
			var channel: String = terrain.editor_material_channels[index]
			var label := channel
			var material: StrataMaterial = terrain.editor_materials[index] if index < terrain.editor_materials.size() else null
			if is_instance_valid(material) and not material.resource_path.is_empty():
				label += "  (%s)" % material.resource_path.get_file().get_basename()
			_add_channel_item(popup, channel, label, current, listed)
	popup.add_separator("Masks")
	for mask in CANONICAL_MASKS: _add_channel_item(popup, mask, mask, current, listed)
	var others: Array[String] = []
	for layer in terrain.get_layers():
		for channel in layer.get_channel_names():
			if not listed.has(channel) and not others.has(channel): others.append(channel)
	if others.is_empty(): return
	others.sort()
	popup.add_separator("Other channels in the stack")
	for channel in others: _add_channel_item(popup, channel, channel, current, listed)

func _add_channel_item(popup: PopupMenu, channel: String, label: String, current: String, listed: Dictionary) -> void:
	if listed.has(channel): return
	listed[channel] = true
	var id := _channel_items.size()
	_channel_items.append(channel)
	popup.add_radio_check_item(label, id)
	popup.set_item_checked(popup.get_item_index(id), channel == current)

func _process(delta: float) -> void:
	_scan_elapsed += delta
	if _scan_elapsed < 0.2: return
	_scan_elapsed = 0.0
	var scene := EditorInterface.get_edited_scene_root()
	if scene != _scene:
		for bridge in _bridges:
			if is_instance_valid(bridge): bridge.queue_free()
		_bridges.clear()
		_scene = scene
		if is_instance_valid(scene): _discover_terrains(scene)
	elif is_instance_valid(scene): _discover_terrains(scene)
	for bridge in _bridges:
		if is_instance_valid(bridge) and (not is_instance_valid(bridge.terrain) or not bridge.terrain.textured_editor_preview): bridge.queue_free()
	var viewport := EditorInterface.get_editor_viewport_3d(0)
	if viewport != null:
		for bridge in _bridges:
			if is_instance_valid(bridge):
				bridge.sync_configuration()
				bridge.set_camera(_editor_camera if is_instance_valid(_editor_camera) else viewport.get_camera_3d())

func _discover_terrains(node: Node) -> void:
	if node is StrataTerrain3D and node.textured_editor_preview and not node.editor_materials.is_empty() and not is_instance_valid(node.editor_preview_bridge):
		var bridge := StrataEditorPreview.new()
		node.add_child(bridge, false, Node.INTERNAL_MODE_BACK)
		bridge.setup(node)
		_bridges.append(bridge)
	for child in node.get_children(): _discover_terrains(child)

func _exit_tree() -> void:
	_finish_stroke()
	_free_cursor()
	for bridge in _bridges:
		if is_instance_valid(bridge): bridge.queue_free()
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
	_toolbar.queue_free()

func _handles(object: Object) -> bool:
	return object is StrataLayer

func _edit(object: Object) -> void:
	_finish_stroke()
	_hide_cursor()
	if is_instance_valid(_layer) and _layer.get_parent() is StrataTerrain3D:
		_layer.get_parent().preview_through_layer = null
	_layer = object as StrataLayer
	if _layer != null and _layer.get_parent() is StrataTerrain3D:
		_layer.get_parent().preview_through_layer = _layer
		_layer.get_parent().override_channel = StringName(_channel.text)
		_overrides.set_pressed_no_signal(_layer.get_parent().show_overrides)

func _make_visible(visible: bool) -> void:
	_toolbar.visible = visible
	if not visible:
		_finish_stroke()
		_hide_cursor()
		if is_instance_valid(_layer) and _layer.get_parent() is StrataTerrain3D:
			_layer.get_parent().preview_through_layer = null
		_layer = null

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	_editor_camera = camera
	if is_instance_valid(_layer) and _layer.get_parent() is StrataTerrain3D and is_instance_valid(_layer.get_parent().editor_preview_bridge): _layer.get_parent().editor_preview_bridge.set_camera(camera)
	if not is_instance_valid(_layer) or not (_layer.get_parent() is StrataTerrain3D):
		return AFTER_GUI_INPUT_PASS
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		if _stroke_layer != null:
			_finish_stroke()
			return AFTER_GUI_INPUT_STOP
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and not event.alt_pressed:
		var hit := _pick(camera, event.position)
		if hit.is_empty():
			return AFTER_GUI_INPUT_PASS
		if _layer.procedural:
			_status.text = "Procedural cache: select a manual layer to paint; explicit cook only"
			return AFTER_GUI_INPUT_STOP
		_stroke_layer = _layer
		_stroke_records = []
		_flatten = StrataBrush.flatten_target(_layer, StringName(_channel.text), hit.local_position)
		_last_point = Vector2(INF, INF)
		_dab(hit.local_position)
		return AFTER_GUI_INPUT_STOP
	if event is InputEventMouseMotion:
		# The cursor follows the pointer whether or not a stroke is in progress.
		if event.alt_pressed:
			_hide_cursor()
		else:
			var hover := _pick(camera, event.position)
			_hover_point = hover.local_position if not hover.is_empty() else Vector2(INF, INF)
			_update_cursor()
		if _stroke_layer != null:
			if event.button_mask & MOUSE_BUTTON_MASK_LEFT == 0:
				_finish_stroke()
				return AFTER_GUI_INPUT_PASS
			if _hover_point.is_finite():
				_dab(_hover_point)
			return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS

func _pick(camera: Camera3D, point: Vector2) -> Dictionary:
	return (_layer.get_parent() as StrataTerrain3D).raycast_surface(camera.project_ray_origin(point), camera.project_ray_normal(point))

## Redraws the brush footprint at the last hover point, red when the dab would be refused.
func _update_cursor() -> void:
	var terrain := _terrain()
	if terrain == null or not _hover_point.is_finite() or not _toolbar.visible:
		_hide_cursor()
		return
	if not is_instance_valid(_cursor) or _cursor.get_parent() != terrain:
		_free_cursor()
		_cursor = StrataBrushCursor.new()
		terrain.add_child(_cursor, false, Node.INTERNAL_MODE_BACK)
	var blocked := _layer.procedural or not StrataBrush.sample_limit_message(_layer, _hover_point, _radius.value).is_empty()
	var band := 0.25
	if is_instance_valid(_editor_camera):
		var world := terrain.to_global(Vector3(_hover_point.x, terrain.sample_height(_hover_point, _layer), _hover_point.y))
		band = clampf(_editor_camera.global_position.distance_to(world) * 0.003, 0.02, 4.0)
	_cursor.show_at(terrain, _layer, _hover_point, _radius.value, blocked, band)

func _hide_cursor() -> void:
	if is_instance_valid(_cursor): _cursor.hide_cursor()

func _free_cursor() -> void:
	if is_instance_valid(_cursor): _cursor.queue_free()
	_cursor = null

func _dab(point: Vector2) -> void:
	if _last_point.is_finite() and _last_point.distance_to(point) < _radius.value * 0.1:
		return
	_last_point = point
	var limit_message := StrataBrush.sample_limit_message(_stroke_layer, point, _radius.value)
	if not limit_message.is_empty():
		_status.text = "Brush too dense; hover for radius / spacing limits"
		_status.tooltip_text = limit_message
		return
	_status.tooltip_text = ""
	var bridge: Node = _stroke_layer.get_parent().editor_preview_bridge
	var can_patch: bool = is_instance_valid(bridge) and bridge.can_patch_region()
	var channel := StringName(_channel.text)
	var operation := _operation.get_item_text(_operation.selected).to_lower()
	var grid := StrataBrush.candidate_grid(_stroke_layer, point, _radius.value)
	if grid.is_empty(): return
	# A material dab writes every material channel, so undo must capture all of them.
	var records: Array = []
	for written in StrataBrush.written_channels(_stroke_layer, channel):
		records.append(StrataBrush.begin_record(_stroke_layer.data, written, grid))
	var touched: int
	if channel in [&"hole", &"nav_exclusion"] and operation != "erase":
		if operation not in ["raise", "lower"]:
			_status.text = "Binary mask: Raise paints 1, Lower paints 0, Erase reveals below"
			return
		if _stroke_layer.get_composition(channel) != StrataLayer.Composition.REPLACE:
			_status.text = "Canonical masks require Replace composition"
			return
		touched = _paint_binary(point, 1.0 if operation == "raise" else 0.0, channel)
	else:
		touched = StrataBrush.apply_brush(_stroke_layer, point, _radius.value, _strength.value, operation, channel, _flatten)
	if touched > 0:
		for record in records:
			if StrataBrush.finish_record(_stroke_layer.data, record): _stroke_records.append(record)
	_status.text = "%d touched samples" % touched if touched > 0 else "No samples changed; check layer, strength or channel"
	if touched > 0 and is_instance_valid(bridge): bridge.refresh_region(point, _radius.value, _stroke_layer.data.sample_spacing, StringName(_channel.text), can_patch)

## Canonical cell masks are categorical: every touched sample owns exact 0/1.
## A soft brush falloff must never introduce fractional Hole/Solid values.
func _paint_binary(point: Vector2, value: float, channel: StringName) -> int:
	var terrain := _stroke_layer.get_parent() as StrataTerrain3D
	var data := _stroke_layer.data
	var spacing: float = data.sample_spacing
	if not point.is_finite() or not is_finite(spacing) or spacing <= 0.0 or not terrain.is_transform_valid() or not _stroke_layer.enabled: return 0
	if _stroke_layer.get_composition(channel) != StrataLayer.Composition.REPLACE:
		_status.text = "Canonical masks require Replace composition"
		return 0
	var bounds := terrain.base_bounds
	var minimum := (point - Vector2.ONE * _radius.value).max(bounds.position)
	var maximum := (point + Vector2.ONE * _radius.value).min(bounds.end)
	if minimum.x > maximum.x or minimum.y > maximum.y: return 0
	var first_value := ((minimum - data.grid_origin) / spacing).ceil()
	var last_value := ((maximum - data.grid_origin) / spacing).floor()
	if first_value.x < -2147483648.0 or first_value.y < -2147483648.0 or last_value.x > 2147483647.0 or last_value.y > 2147483647.0: return 0
	var first := Vector2i(first_value); var last := Vector2i(last_value)
	var width := last.x - first.x + 1; var height := last.y - first.y + 1
	if width <= 0 or height <= 0 or width > StrataBrush.MAX_CANDIDATE_SAMPLES or height > StrataBrush.MAX_CANDIDATE_SAMPLES or width * height > StrataBrush.MAX_CANDIDATE_SAMPLES: return 0
	var values := Image.create(width, height, false, Image.FORMAT_RF)
	values.fill(Color(value, 0.0, 0.0, 1.0))
	var mask := Image.create(width, height, false, Image.FORMAT_RF)
	var count := 0
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			var sample := data.grid_origin + Vector2(x, y) * spacing
			if sample.distance_to(point) < _radius.value:
				mask.set_pixel(x - first.x, y - first.y, Color(1.0, 0.0, 0.0, 1.0))
				count += 1
	if count > 0 and not data.patch_dense(channel, first, values, mask): return 0
	return count

func _finish_stroke() -> void:
	if not is_instance_valid(_stroke_layer):
		_stroke_layer = null
		_stroke_records = []
		return
	if not _stroke_records.is_empty():
		# The stroke is already applied; the action only records how to take it back.
		var undo := get_undo_redo()
		undo.create_action("Sculpt terrain layer", UndoRedo.MERGE_DISABLE, _stroke_layer)
		undo.add_do_method(StrataBrush, "restore_records", _stroke_layer.data, _stroke_records, "after")
		undo.add_undo_method(StrataBrush, "restore_records", _stroke_layer.data, _stroke_records, "before")
		undo.commit_action(false)
	_stroke_layer = null
	_stroke_records = []
