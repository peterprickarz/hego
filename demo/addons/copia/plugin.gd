@tool
extends EditorPlugin
## Copia's editor plugin:
## - Inspector panel on CopiaStore3D (totals, set ownership/locking, build buttons).
## - Copia dock (Species | Objects library with prerendered thumbnails, creators, palettes).
## - Drag-and-drop placement & native gizmo editing of hand-authored instances.
## - Interactive foliage/instance paint & erase brush with 3D cursor and spatial editor toolbar.

const InspectorScript := preload("res://addons/copia/copia_inspector.gd")
const LibraryScript := preload("res://addons/copia/editor/copia_library_index.gd")
const DockScript := preload("res://addons/copia/editor/copia_dock.gd")
const PlaceToolScript := preload("res://addons/copia/editor/copia_place_tool.gd")
const PaintToolScript := preload("res://addons/copia/editor/copia_paint_tool.gd")

var _inspector: EditorInspectorPlugin
var _dock: Control
var _place_tool: RefCounted
var _paint_tool: RefCounted


func _enter_tree() -> void:
	LibraryScript.register_project_settings()
	_inspector = InspectorScript.new()
	add_inspector_plugin(_inspector)

	_dock = DockScript.new()
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)

	_place_tool = PlaceToolScript.new(self, _dock)
	_paint_tool = PaintToolScript.new(self, _dock)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _paint_tool.get_toolbar())

	_dock.store_changed.connect(_on_store_changed)
	_dock.mode_changed.connect(_on_mode_changed)
	_dock.palette_loaded.connect(_paint_tool.apply_palette_defaults)
	_on_store_changed(_dock.active_store)

	scene_changed.connect(_on_scene_changed)
	var sel := EditorInterface.get_selection()
	if sel != null and not sel.selection_changed.is_connected(_on_selection_changed):
		sel.selection_changed.connect(_on_selection_changed)

	set_input_event_forwarding_always_enabled()
	set_process(true)


func _exit_tree() -> void:
	set_process(false)
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	var sel := EditorInterface.get_selection()
	if sel != null and sel.selection_changed.is_connected(_on_selection_changed):
		sel.selection_changed.disconnect(_on_selection_changed)
	if _paint_tool != null:
		var tb: Control = _paint_tool.get_toolbar()
		if is_instance_valid(tb):
			remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, tb)
		_paint_tool.dispose()
		_paint_tool = null
	if _place_tool != null:
		_place_tool.dispose()
		_place_tool = null
	if is_instance_valid(_dock):
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
	if _inspector != null:
		remove_inspector_plugin(_inspector)
		_inspector = null


func _process(delta: float) -> void:
	if _place_tool != null:
		_place_tool.process(delta)


func _save_external_data() -> void:
	if _place_tool != null:
		_place_tool.on_before_save()


func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	if _dock == null or _dock.active_mode == DockScript.Mode.OFF:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if _dock.active_mode == DockScript.Mode.PAINT and _paint_tool != null:
		return _paint_tool.handle_3d_input(viewport_camera, event)
	if _place_tool != null:
		return _place_tool.handle_3d_input(viewport_camera, event)
	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _on_store_changed(store: Node) -> void:
	if _place_tool != null:
		_place_tool.set_store(store)
	if _paint_tool != null:
		_paint_tool.set_store(store)


func _on_mode_changed(mode: int) -> void:
	if _place_tool != null:
		_place_tool.on_mode_changed(mode)
	if _paint_tool != null:
		_paint_tool.on_mode_changed(mode)


func _on_scene_changed(_scene_root: Node) -> void:
	if _place_tool != null:
		_place_tool.on_before_save()
	if _dock != null:
		_dock.refresh_stores()


func _on_selection_changed() -> void:
	if _place_tool != null:
		_place_tool.on_selection_changed()
