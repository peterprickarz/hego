@tool
extends VBoxContainer
## The Copia authoring dock: target store & authored set selector, mode bar (Place / Paint / Select),
## Species | Objects library browser with prerendered thumbnails, Brush Palettes bar, active paint
## selection weights, and "+ New Object" / "+ New Species" creators.

signal store_changed(store: Node)
signal mode_changed(mode: int)
signal target_set_changed(set_name: String)
signal active_items_changed()
signal palette_loaded(palette: Resource)

enum Mode { OFF, PLACE, PAINT, SELECT }
enum LibraryView { SPECIES, OBJECTS }

const StoreScript := preload("res://addons/copia/copia_store_3d.gd")
const ObjectScript := preload("res://addons/copia/copia_object.gd")
const SpeciesScript := preload("res://addons/copia/copia_species.gd")
const PaletteScript := preload("res://addons/copia/copia_brush_palette.gd")
const LibraryScript := preload("res://addons/copia/editor/copia_library_index.gd")
const BakerScript := preload("res://addons/copia/editor/copia_thumbnail_baker.gd")
const CreatorsScript := preload("res://addons/copia/editor/copia_creators.gd")

const DEFAULT_PLACE_SET := "handplaced"
const DEFAULT_PAINT_SET := "handpainted"
const ICON_DISPLAY_SIZE := 64

var library: RefCounted
var baker: RefCounted
var active_store: Node = null
var active_mode: int = Mode.OFF
var active_view: int = LibraryView.SPECIES
var active_set := DEFAULT_PLACE_SET
var selected_place_path := ""
# Active paint items: path -> {path, kind ("species"|"object"), weight: float}
var active_paint_items := {}

var _stores: Array[Node] = []
var _store_pick: OptionButton
var _set_pick: OptionButton
var _lock_btn: Button
var _mode_buttons := {}  # Mode -> Button
var _palette_row: HBoxContainer
var _palette_pick: OptionButton
var _view_species_btn: Button
var _view_objects_btn: Button
var _search: LineEdit
var _category_pick: OptionButton
var _grid: ItemList
var _active_panel: VBoxContainer
var _active_list: VBoxContainer
var _status: Label
var _context_menu: PopupMenu
var _context_path := ""
var _visible_paths: Array[String] = []
var _path_to_grid_idx := {}

var _new_set_dialog: ConfirmationDialog
var _new_set_edit: LineEdit
var _new_object_dialog: ConfirmationDialog
var _new_species_dialog: ConfirmationDialog
var _save_palette_dialog: EditorFileDialog
var _placeholder_icon: Texture2D
var _paint_brush_defaults_provider := Callable()
var _library_dirty := false
var _last_fs_refresh_msec := 0


class _AssetGrid extends ItemList:
	var dock: Control

	func _get_drag_data(at_position: Vector2) -> Variant:
		var idx := get_item_at_position(at_position, true)
		if idx < 0:
			return null
		var meta: Variant = get_item_metadata(idx)
		if not meta is Dictionary:
			return null
		var preview := HBoxContainer.new()
		var tex := get_item_icon(idx)
		if tex != null:
			var icon := TextureRect.new()
			icon.texture = tex
			icon.custom_minimum_size = Vector2(40, 40)
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			preview.add_child(icon)
		var lbl := Label.new()
		lbl.text = get_item_text(idx)
		preview.add_child(lbl)
		set_drag_preview(preview)
		return {
			"type": "copia_asset",
			"path": str(meta.get("path", "")),
			"kind": str(meta.get("kind", "object")),
		}


func _init() -> void:
	name = "Copia"
	custom_minimum_size.x = 260
	library = LibraryScript.new()
	_placeholder_icon = _make_placeholder_icon()
	_build_ui()


func _enter_tree() -> void:
	if baker == null:
		baker = BakerScript.new(self)
		baker.thumbnail_ready.connect(_on_thumbnail_ready)
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		var fs := EditorInterface.get_resource_filesystem()
		if fs != null and not fs.filesystem_changed.is_connected(_on_filesystem_changed):
			fs.filesystem_changed.connect(_on_filesystem_changed)
	refresh_all()


func _exit_tree() -> void:
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		var fs := EditorInterface.get_resource_filesystem()
		if fs != null and fs.filesystem_changed.is_connected(_on_filesystem_changed):
			fs.filesystem_changed.disconnect(_on_filesystem_changed)
	if baker != null:
		baker.dispose()
		baker = null


func set_brush_defaults_provider(provider: Callable) -> void:
	_paint_brush_defaults_provider = provider


func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


func set_mode(mode: int) -> void:
	if active_mode == mode:
		return
	active_mode = mode
	for m in _mode_buttons:
		(_mode_buttons[m] as Button).set_pressed_no_signal(m == active_mode)
	_palette_row.visible = active_mode == Mode.PAINT
	_active_panel.visible = active_mode == Mode.PAINT
	# Switch default authored set nicely between Place and Paint if the user hasn't picked a custom set.
	if active_mode == Mode.PLACE and active_set == DEFAULT_PAINT_SET:
		_select_or_ensure_set(DEFAULT_PLACE_SET)
	elif active_mode == Mode.PAINT and active_set == DEFAULT_PLACE_SET:
		_select_or_ensure_set(DEFAULT_PAINT_SET)
	_refresh_grid_highlights()
	mode_changed.emit(active_mode)


## Returns flattened dab specs for CopiaBrush.sample_dab() from all active paint items.
func build_active_dab_specs() -> Array:
	var specs := []
	for path in active_paint_items:
		var entry: Dictionary = active_paint_items[path]
		var w := float(entry.get("weight", 1.0))
		if w <= 0.0 or not ResourceLoader.exists(path):
			continue
		var res := ResourceLoader.load(path)
		if res == null:
			continue
		if is_instance_of(res, SpeciesScript):
			specs.append_array(res.to_dab_specs(w))
		elif is_instance_of(res, ObjectScript):
			var cfg: Resource = res.placement if res.placement != null else preload("res://addons/copia/copia_placement_settings.gd").new()
			specs.append(cfg.to_dab_spec(res, {"weight": w}))
	return specs


## All CopiaObject paths referenced by the currently toggled paint items (for filtered Erase).
func active_paint_object_paths() -> PackedStringArray:
	var seen := {}
	for path in active_paint_items:
		if not ResourceLoader.exists(path):
			continue
		var res := ResourceLoader.load(path)
		if res == null:
			continue
		if is_instance_of(res, SpeciesScript):
			for op in res.object_paths():
				seen[op] = true
		elif is_instance_of(res, ObjectScript):
			seen[path] = true
	var out := seen.keys()
	out.sort()
	return PackedStringArray(out)


## Ensures [param set_name] exists as an authored set in the active store's manifest.
func ensure_authored_set(set_name: String) -> bool:
	if not is_instance_valid(active_store) or str(active_store.data_directory).is_empty():
		return false
	var meta: Dictionary = active_store.get_sets_meta()
	if meta.has(set_name):
		return str(meta[set_name].get("kind", "generated")) == "authored"
	var res: Dictionary = active_store.configure_set(set_name, "authored", false)
	return bool(res.get("ok", false))


func refresh_all() -> void:
	refresh_stores()
	refresh_library()


func refresh_stores() -> void:
	var prev := active_store
	_stores.clear()
	_store_pick.clear()
	var root := _edited_scene_root()
	if root != null:
		_collect_stores(root, _stores)
	if _stores.is_empty():
		_store_pick.add_item("<No CopiaStore3D in scene>")
		_store_pick.disabled = true
		active_store = null
	else:
		_store_pick.disabled = false
		var pick_idx := 0
		for i in _stores.size():
			var st := _stores[i]
			var rel := str(root.get_path_to(st)) if root != null else str(st.name)
			var hidden_tag := " (hidden)" if not st.visible or st.process_mode == Node.PROCESS_MODE_DISABLED else ""
			_store_pick.add_item(rel + hidden_tag)
			if st == prev:
				pick_idx = i
		# Default to the first visible, enabled store (skipping hidden scratch stores like RoadPlantCandidates).
		if prev == null or not _stores.has(prev):
			for i in _stores.size():
				if _stores[i].visible and _stores[i].process_mode != Node.PROCESS_MODE_DISABLED:
					pick_idx = i
					break
		_store_pick.select(pick_idx)
		active_store = _stores[pick_idx]
	refresh_sets()
	if active_store != prev:
		store_changed.emit(active_store)


func refresh_sets() -> void:
	_set_pick.clear()
	if not is_instance_valid(active_store) or str(active_store.data_directory).is_empty():
		_set_pick.add_item("<No store>")
		_set_pick.disabled = true
		_lock_btn.disabled = true
		return
	_set_pick.disabled = false
	_lock_btn.disabled = false
	var meta: Dictionary = active_store.get_sets_meta()
	var authored: Array[String] = []
	for sname in meta:
		if str(meta[sname].get("kind", "generated")) == "authored":
			authored.append(sname)
	for def_name in [DEFAULT_PLACE_SET, DEFAULT_PAINT_SET]:
		if not authored.has(def_name) and not meta.has(def_name):
			authored.append(def_name)
	authored.sort()
	var target_idx := 0
	for i in authored.size():
		var sname := authored[i]
		var locked := bool(meta.get(sname, {}).get("locked", false))
		_set_pick.add_item(sname + (" [locked]" if locked else ""))
		_set_pick.set_item_metadata(i, sname)
		if sname == active_set:
			target_idx = i
	if not authored.is_empty():
		_set_pick.select(target_idx)
		active_set = authored[target_idx]
		var is_locked := bool(meta.get(active_set, {}).get("locked", false))
		_lock_btn.text = "Unlock" if is_locked else "Lock"


func refresh_library() -> void:
	library.refresh()
	_rebuild_palettes()
	# Default to Objects view automatically if project has Objects but no Species yet.
	if active_view == LibraryView.SPECIES and library.species.is_empty() and not library.objects.is_empty():
		active_view = LibraryView.OBJECTS
		_view_species_btn.set_pressed_no_signal(false)
		_view_objects_btn.set_pressed_no_signal(true)
	_rebuild_categories()
	_rebuild_grid()
	_rebuild_active_list()
	set_status("%d species, %d objects" % [library.species.size(), library.objects.size()])


func _build_ui() -> void:
	# Row 1: Target store picker.
	var store_row := HBoxContainer.new()
	add_child(store_row)
	var store_lbl := Label.new()
	store_lbl.text = "Store:"
	store_row.add_child(store_lbl)
	_store_pick = OptionButton.new()
	_store_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_store_pick.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_store_pick.item_selected.connect(_on_store_selected)
	store_row.add_child(_store_pick)
	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	refresh_btn.tooltip_text = "Rescans scene stores and project Copia resources."
	refresh_btn.pressed.connect(refresh_all)
	store_row.add_child(refresh_btn)

	# Row 2: Mode bar (Place / Paint / Select).
	var mode_row := HBoxContainer.new()
	add_child(mode_row)
	for entry in [
		[Mode.PLACE, "Place", "Drag items into the viewport or click authored instances to transform with the gizmo."],
		[Mode.PAINT, "Paint", "Toggle Species/Objects below and paint on any collider (hold Shift to erase)."],
		[Mode.SELECT, "Select", "Click authored instances in the viewport to move/rotate/scale/delete."],
	]:
		var btn := Button.new()
		btn.text = entry[1]
		btn.tooltip_text = entry[2]
		btn.toggle_mode = true
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_mode_button_pressed.bind(entry[0]))
		mode_row.add_child(btn)
		_mode_buttons[entry[0]] = btn

	# Row 3: Authored target set selector.
	var set_row := HBoxContainer.new()
	add_child(set_row)
	var set_lbl := Label.new()
	set_lbl.text = "Set:"
	set_row.add_child(set_lbl)
	_set_pick = OptionButton.new()
	_set_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_set_pick.item_selected.connect(_on_set_selected)
	set_row.add_child(_set_pick)
	var add_set_btn := Button.new()
	add_set_btn.text = "+"
	add_set_btn.tooltip_text = "Create a new hand-authored set in sets/manifest.json."
	add_set_btn.pressed.connect(_open_new_set_dialog)
	set_row.add_child(add_set_btn)
	_lock_btn = Button.new()
	_lock_btn.text = "Lock"
	_lock_btn.tooltip_text = "Toggle write protection on the active authored set."
	_lock_btn.pressed.connect(_toggle_active_set_lock)
	set_row.add_child(_lock_btn)

	# Row 4: Brush Palettes bar (Paint mode).
	_palette_row = HBoxContainer.new()
	_palette_row.visible = false
	add_child(_palette_row)
	var pal_lbl := Label.new()
	pal_lbl.text = "Palette:"
	_palette_row.add_child(pal_lbl)
	_palette_pick = OptionButton.new()
	_palette_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_palette_pick.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_palette_pick.item_selected.connect(_on_palette_selected)
	_palette_row.add_child(_palette_pick)
	var save_pal_btn := Button.new()
	save_pal_btn.text = "Save..."
	save_pal_btn.tooltip_text = "Save current toggled items and brush settings as a CopiaBrushPalette."
	save_pal_btn.pressed.connect(_open_save_palette_dialog)
	_palette_row.add_child(save_pal_btn)

	add_child(HSeparator.new())

	# Row 5: Library view toggle (Species | Objects) + Actions menu.
	var view_row := HBoxContainer.new()
	add_child(view_row)
	_view_species_btn = Button.new()
	_view_species_btn.text = "Species"
	_view_species_btn.toggle_mode = true
	_view_species_btn.button_pressed = true
	_view_species_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view_species_btn.pressed.connect(_set_library_view.bind(LibraryView.SPECIES))
	view_row.add_child(_view_species_btn)

	_view_objects_btn = Button.new()
	_view_objects_btn.text = "Objects"
	_view_objects_btn.toggle_mode = true
	_view_objects_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view_objects_btn.pressed.connect(_set_library_view.bind(LibraryView.OBJECTS))
	view_row.add_child(_view_objects_btn)

	var new_menu := MenuButton.new()
	new_menu.text = "+ New"
	new_menu.flat = false
	var pop := new_menu.get_popup()
	pop.add_item("New CopiaObject...", 0)
	pop.add_item("New CopiaSpecies (from folder)...", 1)
	pop.add_separator()
	pop.add_item("Rebuild Thumbnails", 2)
	pop.id_pressed.connect(_on_new_menu_id)
	view_row.add_child(new_menu)

	# Row 6: Search + Category filter.
	var filter_row := HBoxContainer.new()
	add_child(filter_row)
	_search = LineEdit.new()
	_search.placeholder_text = "Filter..."
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_t: String) -> void: _rebuild_grid())
	filter_row.add_child(_search)
	_category_pick = OptionButton.new()
	_category_pick.custom_minimum_size.x = 110
	_category_pick.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_category_pick.item_selected.connect(func(_i: int) -> void: _rebuild_grid())
	filter_row.add_child(_category_pick)

	# Main thumbnail grid.
	var grid := _AssetGrid.new()
	grid.dock = self
	grid.icon_mode = ItemList.ICON_MODE_TOP
	grid.fixed_icon_size = Vector2i(ICON_DISPLAY_SIZE, ICON_DISPLAY_SIZE)
	grid.fixed_column_width = ICON_DISPLAY_SIZE + 28
	grid.max_columns = 0
	grid.same_column_width = true
	grid.select_mode = ItemList.SELECT_SINGLE
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.custom_minimum_size.y = 180
	grid.item_clicked.connect(_on_grid_item_clicked)
	grid.item_activated.connect(_on_grid_item_activated)
	add_child(grid)
	_grid = grid

	# Active paint selection panel (visible in Paint mode).
	_active_panel = VBoxContainer.new()
	_active_panel.visible = false
	add_child(_active_panel)
	var active_header := HBoxContainer.new()
	_active_panel.add_child(active_header)
	var active_lbl := Label.new()
	active_lbl.text = "Active Brush Items"
	active_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	active_header.add_child(active_lbl)
	var clear_btn := Button.new()
	clear_btn.text = "Clear"
	clear_btn.pressed.connect(_clear_paint_items)
	active_header.add_child(clear_btn)
	var active_scroll := ScrollContainer.new()
	active_scroll.custom_minimum_size.y = 95
	active_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_active_panel.add_child(active_scroll)
	_active_list = VBoxContainer.new()
	_active_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	active_scroll.add_child(_active_list)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	# Context menu for grid items.
	_context_menu = PopupMenu.new()
	_context_menu.add_item("Inspect Resource", 0)
	_context_menu.add_item("Edit Placement Settings", 1)
	_context_menu.add_item("Create Species from Category", 2)
	_context_menu.add_separator()
	_context_menu.add_item("Rebuild Thumbnail", 3)
	_context_menu.add_item("Reveal in FileSystem", 4)
	_context_menu.id_pressed.connect(_on_context_menu_id)
	add_child(_context_menu)

	# Dialogs.
	_new_set_dialog = ConfirmationDialog.new()
	_new_set_dialog.title = "New Authored Set"
	var ns_box := VBoxContainer.new()
	var ns_lbl := Label.new()
	ns_lbl.text = "Set name (snake_case: a-z, 0-9, _):"
	ns_box.add_child(ns_lbl)
	_new_set_edit = LineEdit.new()
	_new_set_edit.placeholder_text = "e.g. village_props"
	ns_box.add_child(_new_set_edit)
	_new_set_dialog.add_child(ns_box)
	_new_set_dialog.confirmed.connect(_on_new_set_confirmed)
	add_child(_new_set_dialog)

	_new_object_dialog = CreatorsScript.NewObjectDialog.new(library)
	_new_object_dialog.created.connect(_on_asset_created)
	add_child(_new_object_dialog)

	_new_species_dialog = CreatorsScript.NewSpeciesDialog.new(library)
	_new_species_dialog.created.connect(_on_species_created)
	add_child(_new_species_dialog)

	_save_palette_dialog = EditorFileDialog.new()
	_save_palette_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_save_palette_dialog.filters = PackedStringArray(["*.tres ; CopiaBrushPalette"])
	_save_palette_dialog.file_selected.connect(_on_save_palette_file)
	add_child(_save_palette_dialog)


func _set_library_view(view: int) -> void:
	active_view = view
	_view_species_btn.set_pressed_no_signal(view == LibraryView.SPECIES)
	_view_objects_btn.set_pressed_no_signal(view == LibraryView.OBJECTS)
	_rebuild_categories()
	_rebuild_grid()


func _rebuild_categories() -> void:
	var prev := str(_category_pick.get_selected_metadata()) if _category_pick.selected >= 0 else ""
	_category_pick.clear()
	_category_pick.add_item("All")
	_category_pick.set_item_metadata(0, "")
	var source: Array[Dictionary] = library.species if active_view == LibraryView.SPECIES else library.objects
	var cats: PackedStringArray = library.categories_for(source)
	var sel := 0
	for cat in cats:
		var idx := _category_pick.item_count
		_category_pick.add_item(cat)
		_category_pick.set_item_metadata(idx, cat)
		if cat == prev:
			sel = idx
	_category_pick.select(sel)


func _rebuild_palettes() -> void:
	_palette_pick.clear()
	_palette_pick.add_item("<None>")
	_palette_pick.set_item_metadata(0, "")
	for p in library.palettes:
		var idx := _palette_pick.item_count
		_palette_pick.add_item(str(p.name))
		_palette_pick.set_item_metadata(idx, str(p.path))


func _rebuild_grid() -> void:
	_grid.clear()
	_visible_paths.clear()
	_path_to_grid_idx.clear()
	var query := _search.text.strip_edges().to_lower()
	var cat_filter := str(_category_pick.get_selected_metadata()) if _category_pick.selected >= 0 else ""
	var kind := "species" if active_view == LibraryView.SPECIES else "object"
	var source: Array[Dictionary] = library.species if active_view == LibraryView.SPECIES else library.objects
	for entry in source:
		if not cat_filter.is_empty() and str(entry.category) != cat_filter:
			continue
		if not query.is_empty():
			var hay := (str(entry.name) + " " + str(entry.category) + " " + str(entry.path)).to_lower()
			if not hay.contains(query):
				continue
		var path := str(entry.path)
		var tex: Texture2D = baker.request_thumbnail(path) if baker != null else null
		var idx := _grid.add_item(str(entry.name), tex if tex != null else _placeholder_icon)
		_grid.set_item_tooltip(idx, path)
		_grid.set_item_metadata(idx, {"path": path, "kind": kind, "folder": str(entry.folder)})
		_visible_paths.append(path)
		_path_to_grid_idx[path] = idx
	_refresh_grid_highlights()


func _refresh_grid_highlights() -> void:
	for i in _grid.item_count:
		var meta: Dictionary = _grid.get_item_metadata(i)
		var path := str(meta.get("path", ""))
		var on := active_mode == Mode.PAINT and active_paint_items.has(path)
		_grid.set_item_custom_bg_color(i, Color(0.22, 0.45, 0.28, 0.55) if on else Color(0, 0, 0, 0))


func _rebuild_active_list() -> void:
	for child in _active_list.get_children():
		_active_list.remove_child(child)
		child.queue_free()
	if active_paint_items.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "Click items above to add them to the paint brush."
		empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_active_list.add_child(empty_lbl)
		return
	var paths := active_paint_items.keys()
	paths.sort()
	for path in paths:
		var entry: Dictionary = active_paint_items[path]
		var row := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = path.get_file().get_basename()
		lbl.tooltip_text = path
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(lbl)
		var spin := SpinBox.new()
		spin.min_value = 0.05
		spin.max_value = 20.0
		spin.step = 0.1
		spin.value = float(entry.get("weight", 1.0))
		spin.custom_minimum_size.x = 68
		spin.tooltip_text = "Relative spawn weight"
		spin.value_changed.connect(func(v: float) -> void:
			if active_paint_items.has(path):
				active_paint_items[path].weight = v
				active_items_changed.emit())
		row.add_child(spin)
		var rm := Button.new()
		rm.text = "x"
		rm.pressed.connect(func() -> void:
			active_paint_items.erase(path)
			_refresh_grid_highlights()
			_rebuild_active_list()
			active_items_changed.emit())
		row.add_child(rm)
		_active_list.add_child(row)


func _on_mode_button_pressed(mode: int) -> void:
	if active_mode == mode:
		set_mode(Mode.OFF)
	else:
		set_mode(mode)


func _on_store_selected(index: int) -> void:
	if index >= 0 and index < _stores.size():
		active_store = _stores[index]
		refresh_sets()
		store_changed.emit(active_store)


func _on_set_selected(index: int) -> void:
	var sname := str(_set_pick.get_item_metadata(index))
	if not sname.is_empty():
		active_set = sname
		refresh_sets()
		target_set_changed.emit(active_set)


func _select_or_ensure_set(set_name: String) -> void:
	active_set = set_name
	refresh_sets()
	target_set_changed.emit(active_set)


func _open_new_set_dialog() -> void:
	_new_set_edit.text = ""
	_new_set_dialog.popup_centered()
	_new_set_edit.grab_focus()


func _on_new_set_confirmed() -> void:
	if not is_instance_valid(active_store):
		return
	var sname := _new_set_edit.text.strip_edges().to_lower()
	var res: Dictionary = active_store.configure_set(sname, "authored", false)
	if not res.get("ok", false):
		set_status("Set error: " + str(res.get("error", "failed")))
		return
	active_set = sname
	refresh_sets()
	target_set_changed.emit(active_set)
	set_status("Created authored set \"%s\"" % sname)


func _toggle_active_set_lock() -> void:
	if not is_instance_valid(active_store) or active_set.is_empty():
		return
	var meta: Dictionary = active_store.get_sets_meta()
	var cur_locked := bool(meta.get(active_set, {}).get("locked", false))
	var res: Dictionary = active_store.configure_set(active_set, "authored", not cur_locked)
	if res.get("ok", false):
		refresh_sets()
		set_status("%s %s" % [active_set, "locked" if not cur_locked else "unlocked"])


func _on_grid_item_clicked(index: int, at_position: Vector2, mouse_button_index: int) -> void:
	var meta: Dictionary = _grid.get_item_metadata(index)
	var path := str(meta.get("path", ""))
	if mouse_button_index == MOUSE_BUTTON_RIGHT:
		_context_path = path
		_context_menu.position = Vector2i(_grid.get_screen_position() + at_position)
		_context_menu.popup()
		return
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	if active_mode == Mode.PAINT:
		if active_paint_items.has(path):
			active_paint_items.erase(path)
		else:
			active_paint_items[path] = {"path": path, "kind": str(meta.get("kind", "object")), "weight": 1.0}
		_refresh_grid_highlights()
		_rebuild_active_list()
		active_items_changed.emit()
	else:
		selected_place_path = path
		active_items_changed.emit()


func _on_grid_item_activated(index: int) -> void:
	var meta: Dictionary = _grid.get_item_metadata(index)
	var path := str(meta.get("path", ""))
	if not path.is_empty() and ResourceLoader.exists(path):
		EditorInterface.edit_resource(ResourceLoader.load(path))


func _on_context_menu_id(id: int) -> void:
	if _context_path.is_empty():
		return
	match id:
		0:
			if ResourceLoader.exists(_context_path):
				EditorInterface.edit_resource(ResourceLoader.load(_context_path))
		1:
			if ResourceLoader.exists(_context_path):
				var res := ResourceLoader.load(_context_path)
				var pl: Resource = res.get("placement")
				if pl == null:
					pl = preload("res://addons/copia/copia_placement_settings.gd").new()
					res.set("placement", pl)
					ResourceSaver.save(res, _context_path)
				EditorInterface.edit_resource(pl)
		2:
			_new_species_dialog.open_for_folder(_context_path.get_base_dir())
		3:
			if baker != null:
				baker.invalidate(_context_path)
				baker.request_thumbnail(_context_path)
		4:
			EditorInterface.select_file(_context_path)


func _on_new_menu_id(id: int) -> void:
	match id:
		0:
			_new_object_dialog.open_fresh()
		1:
			_new_species_dialog.open_for_folder("")
		2:
			if baker != null:
				baker.clear_cache()
				_rebuild_grid()
				set_status("Rebuilding thumbnails...")


func _on_asset_created(path: String) -> void:
	if Engine.has_singleton(&"EditorInterface"):
		EditorInterface.get_resource_filesystem().scan()
	refresh_library()
	if ResourceLoader.exists(path):
		EditorInterface.edit_resource(ResourceLoader.load(path))
	set_status("Created " + path.get_file())


func _on_species_created(path: String) -> void:
	_set_library_view(LibraryView.SPECIES)
	_on_asset_created(path)


func _on_palette_selected(index: int) -> void:
	var path := str(_palette_pick.get_item_metadata(index))
	if path.is_empty() or not ResourceLoader.exists(path):
		return
	var pal := ResourceLoader.load(path)
	if pal == null or not is_instance_of(pal, PaletteScript):
		return
	active_paint_items.clear()
	for i in pal.items.size():
		var item: Resource = pal.items[i]
		if item == null or item.resource_path.is_empty():
			continue
		var kind := "species" if is_instance_of(item, SpeciesScript) else "object"
		active_paint_items[item.resource_path] = {"path": item.resource_path, "kind": kind, "weight": pal.weight_for(i)}
	_refresh_grid_highlights()
	_rebuild_active_list()
	palette_loaded.emit(pal)
	active_items_changed.emit()
	set_status("Loaded palette \"%s\"" % pal.label())


func _open_save_palette_dialog() -> void:
	var dir := LibraryScript.default_directory(LibraryScript.SETTING_PALETTE_DIR)
	_save_palette_dialog.current_path = dir.path_join("new_palette.tres")
	_save_palette_dialog.popup_centered_ratio(0.6)


func _on_save_palette_file(path: String) -> void:
	var pal := PaletteScript.new()
	pal.display_name = path.get_file().get_basename().capitalize()
	var items: Array[Resource] = []
	var weights := PackedFloat32Array()
	var keys := active_paint_items.keys()
	keys.sort()
	for k in keys:
		if ResourceLoader.exists(k):
			items.append(ResourceLoader.load(k))
			weights.append(float(active_paint_items[k].get("weight", 1.0)))
	pal.items = items
	pal.weights = weights
	if _paint_brush_defaults_provider.is_valid():
		var defs: Dictionary = _paint_brush_defaults_provider.call()
		for prop in defs:
			if prop in pal:
				pal.set(prop, defs[prop])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var err := ResourceSaver.save(pal, path)
	if err == OK:
		refresh_library()
		set_status("Saved palette " + path.get_file())
	else:
		set_status("Failed to save palette: " + error_string(err))


func _clear_paint_items() -> void:
	active_paint_items.clear()
	_refresh_grid_highlights()
	_rebuild_active_list()
	active_items_changed.emit()


func _on_thumbnail_ready(path: String, texture: Texture2D) -> void:
	if _path_to_grid_idx.has(path):
		var idx: int = _path_to_grid_idx[path]
		if idx >= 0 and idx < _grid.item_count:
			_grid.set_item_icon(idx, texture)


func _on_filesystem_changed() -> void:
	if not is_inside_tree():
		return
	var now := Time.get_ticks_msec()
	if now - _last_fs_refresh_msec < 3000:
		_library_dirty = true
		return
	if not is_visible_in_tree():
		_library_dirty = true
		return
	_library_dirty = false
	_last_fs_refresh_msec = now
	refresh_library()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_visible_in_tree() and _library_dirty:
		_library_dirty = false
		_last_fs_refresh_msec = Time.get_ticks_msec()
		refresh_library()


static func _edited_scene_root() -> Node:
	if Engine.has_singleton(&"EditorInterface"):
		return EditorInterface.get_edited_scene_root()
	return null


static func _collect_stores(node: Node, out: Array[Node]) -> void:
	if is_instance_of(node, StoreScript):
		out.append(node)
	for child in node.get_children():
		_collect_stores(child, out)


static func _make_placeholder_icon() -> Texture2D:
	var img := Image.create(ICON_DISPLAY_SIZE, ICON_DISPLAY_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.22, 0.24, 0.27, 0.6))
	return ImageTexture.create_from_image(img)
