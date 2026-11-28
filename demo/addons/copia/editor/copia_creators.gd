@tool
extends RefCounted
## Modal creator dialogs for the Copia dock:
## - "+ New Object": quickly wraps a Mesh or PackedScene into a CopiaObject (or configured subclass)
##   with existing or new render, physics and placement settings.
## - "+ New Species": groups a folder or selection of CopiaObjects into a CopiaSpecies with
##   auto-suggested radial brush falloff bands (large in centre, small on rim).

const LibraryScript := preload("res://addons/copia/editor/copia_library_index.gd")
const ObjectScript := preload("res://addons/copia/copia_object.gd")
const SpeciesScript := preload("res://addons/copia/copia_species.gd")
const EntryScript := preload("res://addons/copia/copia_species_entry.gd")
const PlacementScript := preload("res://addons/copia/copia_placement_settings.gd")


class NewObjectDialog extends ConfirmationDialog:
	signal created(resource_path: String)

	var _library: RefCounted
	var _source_path: LineEdit
	var _render_pick: OptionButton
	var _physics_pick: OptionButton
	var _placement_pick: OptionButton
	var _save_path: LineEdit
	var _status: Label
	var _file_dialog: EditorFileDialog
	var _save_dialog: EditorFileDialog

	func _init(library: RefCounted) -> void:
		_library = library
		title = "New CopiaObject"
		ok_button_text = "Create"
		min_size = Vector2i(500, 260)

		var root := VBoxContainer.new()
		add_child(root)

		var src_row := HBoxContainer.new()
		root.add_child(src_row)
		var src_lbl := Label.new()
		src_lbl.text = "Mesh / Scene:"
		src_lbl.custom_minimum_size.x = 115
		src_row.add_child(src_lbl)
		_source_path = LineEdit.new()
		_source_path.placeholder_text = "res://... (.mesh, .res, .glb, .tscn)"
		_source_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_source_path.text_changed.connect(_on_source_changed)
		src_row.add_child(_source_path)
		var browse := Button.new()
		browse.text = "Browse..."
		browse.pressed.connect(_browse_source)
		src_row.add_child(browse)

		_render_pick = _option_row(root, "Render settings:")
		_physics_pick = _option_row(root, "Physics settings:")
		_placement_pick = _option_row(root, "Placement settings:")

		var save_row := HBoxContainer.new()
		root.add_child(save_row)
		var save_lbl := Label.new()
		save_lbl.text = "Save as:"
		save_lbl.custom_minimum_size.x = 115
		save_row.add_child(save_lbl)
		_save_path = LineEdit.new()
		_save_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		save_row.add_child(_save_path)
		var save_btn := Button.new()
		save_btn.text = "Browse..."
		save_btn.pressed.connect(_browse_save)
		save_row.add_child(save_btn)

		_status = Label.new()
		_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		root.add_child(_status)

		_file_dialog = EditorFileDialog.new()
		_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.filters = PackedStringArray(["*.mesh, *.res, *.tres, *.glb, *.gltf, *.tscn, *.scn ; Meshes & Scenes"])
		_file_dialog.file_selected.connect(func(p: String) -> void:
			_source_path.text = p
			_on_source_changed(p))
		add_child(_file_dialog)

		_save_dialog = EditorFileDialog.new()
		_save_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
		_save_dialog.filters = PackedStringArray(["*.tres ; CopiaObject Resource"])
		_save_dialog.file_selected.connect(func(p: String) -> void: _save_path.text = p)
		add_child(_save_dialog)

		confirmed.connect(_on_confirmed)

	func open_fresh() -> void:
		_fill_picker(_render_pick, _library.render_settings, true)
		_fill_picker(_physics_pick, _library.physics_settings, true)
		_fill_picker(_placement_pick, _library.placement_settings, true)
		_source_path.text = ""
		_save_path.text = LibraryScript.default_directory(LibraryScript.SETTING_OBJECT_DIR).path_join("new_object.tres")
		_status.text = "Class: %s" % LibraryScript.default_object_script_path().get_file()
		popup_centered()

	func _option_row(parent: Control, label_text: String) -> OptionButton:
		var row := HBoxContainer.new()
		parent.add_child(row)
		var lbl := Label.new()
		lbl.text = label_text
		lbl.custom_minimum_size.x = 115
		row.add_child(lbl)
		var opt := OptionButton.new()
		opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		opt.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(opt)
		return opt

	func _fill_picker(picker: OptionButton, paths: PackedStringArray, include_none: bool) -> void:
		picker.clear()
		if include_none:
			picker.add_item("<None>")
			picker.set_item_metadata(0, "")
		for p in paths:
			var idx := picker.item_count
			picker.add_item("%s (%s)" % [p.get_file().get_basename(), p.get_base_dir().trim_prefix("res://")])
			picker.set_item_metadata(idx, p)

	func _browse_source() -> void:
		_file_dialog.popup_centered_ratio(0.6)

	func _browse_save() -> void:
		_save_dialog.current_path = _save_path.text
		_save_dialog.popup_centered_ratio(0.6)

	func _on_source_changed(path: String) -> void:
		if path.is_empty():
			return
		var base := path.get_file().get_basename().to_snake_case()
		var dir := LibraryScript.default_directory(LibraryScript.SETTING_OBJECT_DIR)
		_save_path.text = dir.path_join(base + ".tres")

	func _on_confirmed() -> void:
		var save_to := _save_path.text.strip_edges()
		if save_to.is_empty() or not save_to.ends_with(".tres"):
			_status.text = "Save path must end with .tres"
			popup_centered()
			return
		var script_path := LibraryScript.default_object_script_path()
		var script := load(script_path) as Script
		var obj: Resource = script.new() if script != null else ObjectScript.new()
		var src := _source_path.text.strip_edges()
		if not src.is_empty() and ResourceLoader.exists(src):
			var loaded := load(src)
			if loaded is Mesh:
				obj.set("mesh", loaded)
			elif loaded is PackedScene:
				if "mesh_scene" in obj:
					obj.set("mesh_scene", loaded)
				else:
					var mesh := _first_mesh_in_scene(loaded)
					if mesh != null:
						obj.set("mesh", mesh)
		var rpath := str(_render_pick.get_selected_metadata())
		if not rpath.is_empty():
			obj.set("render", load(rpath))
		var ppath := str(_physics_pick.get_selected_metadata())
		if not ppath.is_empty():
			obj.set("physics", load(ppath))
		var plpath := str(_placement_pick.get_selected_metadata())
		if not plpath.is_empty():
			obj.set("placement", load(plpath))
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(save_to.get_base_dir()))
		var err := ResourceSaver.save(obj, save_to)
		if err != OK:
			_status.text = "Failed to save %s (%s)" % [save_to, error_string(err)]
			popup_centered()
			return
		created.emit(save_to)

	static func _first_mesh_in_scene(scene: PackedScene) -> Mesh:
		var inst := scene.instantiate()
		if inst == null:
			return null
		var found: Mesh = _find_mesh(inst)
		inst.free()
		return found

	static func _find_mesh(node: Node) -> Mesh:
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			return (node as MeshInstance3D).mesh
		for child in node.get_children():
			var m := _find_mesh(child)
			if m != null:
				return m
		return null


class NewSpeciesDialog extends ConfirmationDialog:
	signal created(resource_path: String)

	var _library: RefCounted
	var _name_edit: LineEdit
	var _category_edit: LineEdit
	var _folder_edit: LineEdit
	var _placement_pick: OptionButton
	var _save_path: LineEdit
	var _auto_bands: CheckBox
	var _status: Label
	var _folder_dialog: EditorFileDialog
	var _save_dialog: EditorFileDialog
	var _explicit_objects: PackedStringArray = PackedStringArray()

	func _init(library: RefCounted) -> void:
		_library = library
		title = "New CopiaSpecies"
		ok_button_text = "Create"
		min_size = Vector2i(520, 300)

		var root := VBoxContainer.new()
		add_child(root)

		_name_edit = _line_row(root, "Display name:", "e.g. Bracken Fern")
		_category_edit = _line_row(root, "Category:", "e.g. ferns")

		var folder_row := HBoxContainer.new()
		root.add_child(folder_row)
		var flbl := Label.new()
		flbl.text = "Source folder:"
		flbl.custom_minimum_size.x = 120
		folder_row.add_child(flbl)
		_folder_edit = LineEdit.new()
		_folder_edit.placeholder_text = "res://... (scans subfolders for CopiaObjects)"
		_folder_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_folder_edit.text_changed.connect(_on_folder_changed)
		folder_row.add_child(_folder_edit)
		var browse := Button.new()
		browse.text = "Browse..."
		browse.pressed.connect(func() -> void: _folder_dialog.popup_centered_ratio(0.6))
		folder_row.add_child(browse)

		var prow := HBoxContainer.new()
		root.add_child(prow)
		var plbl := Label.new()
		plbl.text = "Placement settings:"
		plbl.custom_minimum_size.x = 120
		prow.add_child(plbl)
		_placement_pick = OptionButton.new()
		_placement_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		prow.add_child(_placement_pick)

		_auto_bands = CheckBox.new()
		_auto_bands.text = "Auto-assign radial falloff bands from size tier (large -> centre, small -> rim)"
		_auto_bands.button_pressed = true
		root.add_child(_auto_bands)

		var srow := HBoxContainer.new()
		root.add_child(srow)
		var slbl := Label.new()
		slbl.text = "Save as:"
		slbl.custom_minimum_size.x = 120
		srow.add_child(slbl)
		_save_path = LineEdit.new()
		_save_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		srow.add_child(_save_path)
		var sbtn := Button.new()
		sbtn.text = "Browse..."
		sbtn.pressed.connect(func() -> void:
			_save_dialog.current_path = _save_path.text
			_save_dialog.popup_centered_ratio(0.6))
		srow.add_child(sbtn)

		_status = Label.new()
		_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		root.add_child(_status)

		_folder_dialog = EditorFileDialog.new()
		_folder_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
		_folder_dialog.dir_selected.connect(func(d: String) -> void:
			_explicit_objects = PackedStringArray()
			_folder_edit.text = d
			_on_folder_changed(d))
		add_child(_folder_dialog)

		_save_dialog = EditorFileDialog.new()
		_save_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
		_save_dialog.filters = PackedStringArray(["*.tres ; CopiaSpecies Resource"])
		_save_dialog.file_selected.connect(func(p: String) -> void: _save_path.text = p)
		add_child(_save_dialog)

		confirmed.connect(_on_confirmed)

	func _line_row(parent: Control, text: String, placeholder: String) -> LineEdit:
		var row := HBoxContainer.new()
		parent.add_child(row)
		var lbl := Label.new()
		lbl.text = text
		lbl.custom_minimum_size.x = 120
		row.add_child(lbl)
		var edit := LineEdit.new()
		edit.placeholder_text = placeholder
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(edit)
		return edit

	func open_for_folder(folder := "") -> void:
		_explicit_objects = PackedStringArray()
		_fill_placement_picker()
		_folder_edit.text = folder
		_folder_edit.editable = true
		if not folder.is_empty():
			_on_folder_changed(folder)
		else:
			_name_edit.text = ""
			_category_edit.text = ""
			_save_path.text = LibraryScript.default_directory(LibraryScript.SETTING_SPECIES_DIR).path_join("new_species.tres")
			_status.text = "Pick a folder containing CopiaObject .tres files."
		popup_centered()

	func open_for_objects(object_paths: PackedStringArray, suggested_name := "") -> void:
		_explicit_objects = object_paths
		_fill_placement_picker()
		_folder_edit.text = "(%d selected objects)" % object_paths.size()
		_folder_edit.editable = false
		var base := suggested_name if not suggested_name.is_empty() else "new_species"
		_name_edit.text = base.capitalize()
		_category_edit.text = ""
		_save_path.text = LibraryScript.default_directory(LibraryScript.SETTING_SPECIES_DIR).path_join(base.to_snake_case() + ".tres")
		_status.text = "%d variants will be added." % object_paths.size()
		popup_centered()

	func _fill_placement_picker() -> void:
		_placement_pick.clear()
		_placement_pick.add_item("<New inline CopiaPlacementSettings>")
		_placement_pick.set_item_metadata(0, "")
		for p in _library.placement_settings:
			var idx := _placement_pick.item_count
			_placement_pick.add_item("%s (%s)" % [p.get_file().get_basename(), p.get_base_dir().trim_prefix("res://")])
			_placement_pick.set_item_metadata(idx, p)

	func _on_folder_changed(folder: String) -> void:
		if folder.is_empty():
			return
		var base := folder.get_file()
		_name_edit.text = base.capitalize()
		_category_edit.text = base
		_save_path.text = LibraryScript.default_directory(LibraryScript.SETTING_SPECIES_DIR).path_join(base.to_snake_case() + ".tres")
		var count := _matching_objects_in_folder(folder).size()
		_status.text = "Found %d CopiaObject(s) under %s." % [count, folder]

	func _matching_objects_in_folder(folder: String) -> PackedStringArray:
		var prefix := folder.trim_suffix("/") + "/"
		var out := PackedStringArray()
		for item in _library.objects:
			if str(item.path).begins_with(prefix):
				out.append(item.path)
		return out

	func _on_confirmed() -> void:
		var save_to := _save_path.text.strip_edges()
		if save_to.is_empty() or not save_to.ends_with(".tres"):
			_status.text = "Save path must end with .tres"
			popup_centered()
			return
		var paths := _explicit_objects if not _explicit_objects.is_empty() else _matching_objects_in_folder(_folder_edit.text.strip_edges())
		if paths.is_empty():
			_status.text = "No CopiaObjects found to add to this species."
			popup_centered()
			return
		var species := SpeciesScript.new()
		species.display_name = _name_edit.text.strip_edges()
		species.category = _category_edit.text.strip_edges()
		var plpath := str(_placement_pick.get_selected_metadata())
		species.placement = load(plpath) if not plpath.is_empty() else PlacementScript.new()
		var entries: Array[EntryScript] = []
		for p in paths:
			var obj := load(p)
			if obj == null or not is_instance_of(obj, ObjectScript):
				continue
			var entry := EntryScript.new()
			entry.object = obj
			if _auto_bands.button_pressed:
				var band := _guess_band(p)
				entry.brush_strength_min = band.x
				entry.brush_strength_max = band.y
			entries.append(entry)
		species.entries = entries
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(save_to.get_base_dir()))
		var err := ResourceSaver.save(species, save_to)
		if err != OK:
			_status.text = "Failed to save %s (%s)" % [save_to, error_string(err)]
			popup_centered()
			return
		created.emit(save_to)

	static func _guess_band(path: String) -> Vector2:
		var lower := path.to_lower()
		if lower.contains("/large/") or lower.contains("_large") or lower.contains("_tall") or lower.contains("_big"):
			return Vector2(0.55, 1.0)
		if lower.contains("/medium/") or lower.contains("_medium") or lower.contains("_med"):
			return Vector2(0.2, 0.85)
		if lower.contains("/small/") or lower.contains("_small") or lower.contains("_tiny") or lower.contains("_low") or lower.contains("seedling"):
			return Vector2(0.0, 0.55)
		return Vector2(0.0, 1.0)
