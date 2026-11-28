@tool
extends RefCounted
## Interactive foliage/instance paint and erase brush controller for Copia:
## - Paints toggled CopiaSpecies and CopiaObjects onto any collider (terrain, meshes, other Copia
##   instances) with surface filters, min-spacing rejection, radial species falloff bands and
##   high-keep defaults.
## - Runs at 60 FPS via native CopiaBrush + CopiaEditOverlay + CopiaDrawer suppression, committing
##   atomically on mouse-up with EditorUndoRedoManager and async cell rebuilds.

const ObjectScript := preload("res://addons/copia/copia_object.gd")
const DockScript := preload("res://addons/copia/editor/copia_dock.gd")
const CursorScript := preload("res://addons/copia/editor/copia_brush_cursor.gd")
const RaycastScript := preload("res://addons/copia/editor/copia_surface_raycast.gd")

const RAY_MAX_DIST := 2000.0
const MAX_RAYS_PER_DAB := 96
const STROKE_LOAD_MARGIN := 32.0

var _plugin: EditorPlugin
var _dock: Control
var _toolbar: HBoxContainer
var _op_pick: OptionButton
var _radius_spin: SpinBox
var _density_spin: SpinBox
var _spacing_spin: SpinBox
var _filter_menu: MenuButton
var _cursor: RefCounted
var _raycaster: RefCounted
var _brush: Object  # native CopiaBrush
var _overlay: Object  # native CopiaEditOverlay
var _rng := RandomNumberGenerator.new()

var _bound_store: Node3D = null
var _paint_on_terrain := true
var _paint_on_meshes := true
var _paint_on_copia := false
var _avoid_generated := false
var _erase_all_in_set := false
var _collision_mask := 0xFFFFFFFF

var _stroking := false
var _stroke_erase := false
var _stroke_set := ""
var _stroke_specs: Array = []
var _stroke_object_radii := {}
var _stroke_loaded_rect := Rect2()
var _last_dab_pos := Vector3(INF, INF, INF)
var _stroke_added := {}  # accumulated apply-format dictionary
var _stroke_erased := {}  # accumulated apply-format dictionary
var _pending_clear_overlay := false
var _last_hover_pos := Vector3.ZERO
var _last_hover_normal := Vector3.UP
var _has_hover := false
var _dab_seed := 1


func _init(plugin: EditorPlugin, dock: Control) -> void:
	_plugin = plugin
	_dock = dock
	_rng.randomize()
	_dab_seed = int(_rng.randi())
	_cursor = CursorScript.new()
	_raycaster = RaycastScript.new()
	if ClassDB.class_exists("CopiaBrush"):
		_brush = ClassDB.instantiate("CopiaBrush")
	if ClassDB.class_exists("CopiaEditOverlay"):
		_overlay = ClassDB.instantiate("CopiaEditOverlay")
	_build_toolbar()
	_dock.set_brush_defaults_provider(get_brush_defaults)


func get_toolbar() -> Control:
	return _toolbar


func dispose() -> void:
	_cancel_stroke()
	_disconnect_store()
	if _cursor != null:
		_cursor.dispose()
	if _overlay != null:
		_overlay.clear_all()
	if _brush != null:
		_brush.clear()
	if is_instance_valid(_toolbar):
		_toolbar.queue_free()


func set_store(store: Node) -> void:
	var store3d := store as Node3D
	if store3d == _bound_store:
		return
	_cancel_stroke()
	_disconnect_store()
	_bound_store = store3d
	if _raycaster != null:
		_raycaster.invalidate()
	if is_instance_valid(_bound_store):
		if not _bound_store.build_finished.is_connected(_on_store_build_finished):
			_bound_store.build_finished.connect(_on_store_build_finished)
		if not _bound_store.streaming_settled.is_connected(_on_store_streaming_settled):
			_bound_store.streaming_settled.connect(_on_store_streaming_settled)
		if _bound_store.is_inside_tree():
			var scen := _bound_store.get_world_3d().scenario
			_cursor.set_scenario(scen)
			if _overlay != null:
				_overlay.set_scenario(scen)
				_overlay.set_transform(_bound_store.global_transform)


func on_mode_changed(mode: int) -> void:
	var is_paint := mode == DockScript.Mode.PAINT
	_toolbar.visible = is_paint
	if not is_paint:
		_cancel_stroke()
		_cursor.hide()


func apply_palette_defaults(palette: Resource) -> void:
	if palette == null:
		return
	_radius_spin.value = float(palette.get("brush_radius"))
	_density_spin.value = float(palette.get("density_scale"))
	_spacing_spin.value = float(palette.get("spacing_scale"))
	_collision_mask = int(palette.get("collision_mask"))
	_paint_on_terrain = bool(palette.get("paint_on_terrain"))
	_paint_on_meshes = bool(palette.get("paint_on_meshes"))
	_paint_on_copia = bool(palette.get("paint_on_copia"))
	_avoid_generated = bool(palette.get("avoid_generated_sets"))
	_sync_filter_menu()


func get_brush_defaults() -> Dictionary:
	return {
		"brush_radius": _radius_spin.value,
		"density_scale": _density_spin.value,
		"spacing_scale": _spacing_spin.value,
		"collision_mask": _collision_mask,
		"paint_on_terrain": _paint_on_terrain,
		"paint_on_meshes": _paint_on_meshes,
		"paint_on_copia": _paint_on_copia,
		"avoid_generated_sets": _avoid_generated,
	}


func handle_3d_input(camera: Camera3D, event: InputEvent) -> int:
	if _dock.active_mode != DockScript.Mode.PAINT:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if not is_instance_valid(_bound_store) or not _bound_store.is_inside_tree():
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	# Hotkeys: [ / ] resize brush radius, Esc exits Paint mode.
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode == KEY_BRACKETLEFT:
			_radius_spin.value = maxf(_radius_spin.min_value, _radius_spin.value * 0.8)
			_refresh_cursor_in_place(key.shift_pressed)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if key.keycode == KEY_BRACKETRIGHT:
			_radius_spin.value = minf(_radius_spin.max_value, _radius_spin.value * 1.25)
			_refresh_cursor_in_place(key.shift_pressed)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if key.keycode == KEY_ESCAPE:
			_dock.set_mode(DockScript.Mode.OFF)
			return EditorPlugin.AFTER_GUI_INPUT_STOP

	# Shift+Scroll resizes brush radius without zooming the camera.
	if event is InputEventMouseButton and event.pressed and event.shift_pressed:
		var mb_s := event as InputEventMouseButton
		if mb_s.button_index == MOUSE_BUTTON_WHEEL_UP or mb_s.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var factor := 1.15 if mb_s.button_index == MOUSE_BUTTON_WHEEL_UP else 0.87
			_radius_spin.value = clampf(_radius_spin.value * factor, _radius_spin.min_value, _radius_spin.max_value)
			_refresh_cursor_in_place(true)
			return EditorPlugin.AFTER_GUI_INPUT_STOP

	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.alt_pressed:
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		var hit := _raycast_surface(camera, mm.position, _is_erase_active(mm.shift_pressed))
		if hit.is_empty():
			_has_hover = false
			_cursor.hide()
		else:
			_has_hover = true
			_last_hover_pos = hit.position
			_last_hover_normal = hit.normal
			_cursor.set_scenario(_bound_store.get_world_3d().scenario)
			_cursor.update(hit.position, hit.normal, _radius_spin.value, _is_erase_active(mm.shift_pressed))
			if _stroking:
				var step := clampf(_radius_spin.value * 0.25, 0.25, 4.0)
				if _last_dab_pos.distance_to(hit.position) >= step:
					_apply_dab(camera, hit.position, hit.normal)
		return EditorPlugin.AFTER_GUI_INPUT_STOP if _stroking else EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.alt_pressed:
			if mb.pressed:
				var erase := _is_erase_active(mb.shift_pressed)
				var hit := _raycast_surface(camera, mb.position, erase)
				if hit.is_empty():
					return EditorPlugin.AFTER_GUI_INPUT_PASS
				if _begin_stroke(erase, hit.position):
					_apply_dab(camera, hit.position, hit.normal)
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			elif _stroking:
				_commit_stroke()
				return EditorPlugin.AFTER_GUI_INPUT_STOP

	return EditorPlugin.AFTER_GUI_INPUT_PASS


# --- Stroke lifecycle -------------------------------------------------------------------------


func _begin_stroke(erase: bool, world_pos: Vector3) -> bool:
	if _brush == null or _overlay == null or not is_instance_valid(_bound_store):
		return false
	_stroke_set = _dock.active_set
	if not _dock.ensure_authored_set(_stroke_set):
		_dock.set_status("Set \"%s\" is not an authored set" % _stroke_set)
		return false
	var meta: Dictionary = _bound_store.get_sets_meta()
	if bool(meta.get(_stroke_set, {}).get("locked", false)):
		_dock.set_status("Set \"%s\" is locked" % _stroke_set)
		return false
	_stroke_erase = erase
	_stroke_specs = [] if erase else _dock.build_active_dab_specs()
	if not erase and _stroke_specs.is_empty():
		_dock.set_status("Toggle one or more Species/Objects in the Copia dock first.")
		return false

	_stroke_object_radii.clear()
	for spec in _stroke_specs:
		var p := str(spec.get("object_path", ""))
		_stroke_object_radii[p] = maxf(float(_stroke_object_radii.get(p, 0.0)), float(spec.get("min_spacing", 0.0)))
		var obj = ObjectScript.resolve(p)
		if obj != null:
			_register_overlay_visual(obj)

	_overlay.set_scenario(_bound_store.get_world_3d().scenario)
	_overlay.set_transform(_bound_store.global_transform)
	_overlay.clear_stroke()
	_stroke_added.clear()
	_stroke_erased.clear()
	_stroke_loaded_rect = Rect2()
	_brush.clear()
	_ensure_brush_loaded_around(world_pos)
	_stroking = true
	_last_dab_pos = Vector3(INF, INF, INF)
	return true


func _ensure_brush_loaded_around(world_pos: Vector3) -> void:
	var local := _bound_store.to_local(world_pos)
	var r := float(_radius_spin.value) + STROKE_LOAD_MARGIN
	var needed := Rect2(Vector2(local.x - r, local.z - r), Vector2(r * 2.0, r * 2.0))
	if _stroke_loaded_rect.has_area() and _stroke_loaded_rect.encloses(needed):
		return
	var load_r := maxf(r * 2.0, 64.0)
	_stroke_loaded_rect = Rect2(Vector2(local.x - load_r, local.z - load_r), Vector2(load_r * 2.0, load_r * 2.0))
	_brush.clear()
	var editable_pts: Dictionary = _bound_store.read_points(_stroke_loaded_rect, PackedStringArray([_stroke_set]), PackedStringArray())
	if int(editable_pts.get("count", 0)) > 0:
		_brush.load_points(editable_pts, true, _stroke_object_radii)
	if _avoid_generated and not _stroke_erase:
		var avoid_pts: Dictionary = _bound_store.read_points(_stroke_loaded_rect, PackedStringArray(), PackedStringArray([_stroke_set]))
		if int(avoid_pts.get("count", 0)) > 0:
			_brush.load_points(avoid_pts, false, _stroke_object_radii)
	# Re-add any points already staged in this stroke so spacing remains consistent.
	if not _stroke_added.is_empty():
		_brush.add_staging_points(_stroke_added, _stroke_set, _stroke_object_radii)


func _apply_dab(_camera: Camera3D, world_center: Vector3, world_normal: Vector3) -> void:
	_last_dab_pos = world_center
	_ensure_brush_loaded_around(world_center)
	var radius := float(_radius_spin.value)
	var inv := _bound_store.global_transform.affine_inverse()

	if _stroke_erase:
		var local_center := inv * world_center
		var obj_filter: PackedStringArray = PackedStringArray() if _erase_all_in_set else (_dock.active_paint_object_paths() as PackedStringArray)
		var q: Dictionary = _brush.query_sphere(local_center, radius, obj_filter, true)
		var persistent: Dictionary = q.get("persistent", {})
		if not persistent.is_empty() and persistent.has("object") and persistent.object.size() > 0:
			_append_point_columns(_stroke_erased, persistent)
			_suppress_columns_in_store(persistent)
			_dock.set_status("Erasing %d instances..." % int(_stroke_erased.object.size()))
		return

	# Paint dab: build surface-aligned tangent frame, cast stratified rays within disc.
	var n := world_normal.normalized() if world_normal.length_squared() > 1e-6 else Vector3.UP
	var tangent := n.cross(Vector3.FORWARD)
	if tangent.length_squared() < 1e-4:
		tangent = n.cross(Vector3.RIGHT)
	tangent = tangent.normalized()
	var bitangent := n.cross(tangent).normalized()

	var area := PI * radius * radius
	var mean_density := _estimate_density() * float(_density_spin.value)
	var ray_count := clampi(int(roundf(area * mean_density * 0.45)), 1, MAX_RAYS_PER_DAB)
	var ray_lift := clampf(radius * 1.5, 4.0, 40.0)
	if _raycaster == null:
		return

	var hit_positions := PackedVector3Array()
	var hit_normals := PackedVector3Array()
	var radial_t := PackedFloat32Array()
	var inv_basis := inv.basis
	var ray_dir := -n
	var ray_len := ray_lift * 2.5
	for _i in ray_count:
		var u := sqrt(_rng.randf())
		var ang := _rng.randf() * TAU
		var offset := (tangent * cos(ang) + bitangent * sin(ang)) * (u * radius)
		var origin := world_center + offset + n * ray_lift
		var res: Dictionary = _raycaster.raycast(
			_bound_store, origin, ray_dir, ray_len,
			_collision_mask, _paint_on_terrain, _paint_on_meshes, _paint_on_copia
		)
		if res.is_empty():
			continue
		hit_positions.append(inv * (res.position as Vector3))
		hit_normals.append((inv_basis * (res.normal as Vector3)).normalized())
		# 1.0 at centre, 0.0 at rim.
		radial_t.append(clampf(1.0 - u, 0.0, 1.0))

	if hit_positions.is_empty():
		return
	_dab_seed += 7919
	var dab: Dictionary = _brush.sample_dab(
		{"positions": hit_positions, "normals": hit_normals, "radial_t": radial_t},
		_stroke_specs,
		{
			"seed": _dab_seed,
			"spacing_scale": float(_spacing_spin.value),
			"check_avoidance": _avoid_generated,
			"set_name": _stroke_set,
			"add_to_staging": true,
		}
	)
	if int(dab.get("count", 0)) > 0:
		_overlay.append_points(dab)
		_append_point_columns(_stroke_added, dab)
		_dock.set_status("Painting %d instances..." % int(_stroke_added.object.size()))


func _commit_stroke() -> void:
	_stroking = false
	if not is_instance_valid(_bound_store):
		_cancel_stroke()
		return
	var has_adds: bool = not _stroke_added.is_empty() and _stroke_added.has("object") and (_stroke_added.object as PackedInt32Array).size() > 0
	var has_erases: bool = not _stroke_erased.is_empty() and _stroke_erased.has("object") and (_stroke_erased.object as PackedInt32Array).size() > 0
	if not has_adds and not has_erases:
		_overlay.clear_stroke()
		_bound_store.clear_suppressions()
		return

	var set_name := _stroke_set
	var adds := _stroke_added.duplicate(true) if has_adds else {}
	var erases := _stroke_erased.duplicate(true) if has_erases else {}
	_stroke_added.clear()
	_stroke_erased.clear()

	var action_name := "Copia Erase (%d)" % erases.object.size() if has_erases else "Copia Paint (%d)" % adds.object.size()
	var ur := _plugin.get_undo_redo()
	ur.create_action(action_name)
	ur.add_do_method(self, "_apply_stroke_op", _bound_store, set_name, erases, adds)
	ur.add_undo_method(self, "_apply_stroke_op", _bound_store, set_name, adds, erases)
	_pending_clear_overlay = true
	ur.commit_action()
	_dock.set_status(action_name + " in \"" + set_name + "\"")


func _apply_stroke_op(store: Node, set_name: String, removes: Dictionary, adds: Dictionary) -> void:
	if not is_instance_valid(store):
		return
	var res: Dictionary = store.edit_points(set_name, removes, adds, "authored", true)
	if not res.get("ok", false):
		_dock.set_status("Stroke commit failed: " + str(res.get("error", "")))
		_finish_overlay_handoff()
	elif res.get("cells", []).is_empty():
		_finish_overlay_handoff()


func _on_store_build_finished(_report: Dictionary) -> void:
	if _pending_clear_overlay and is_instance_valid(_bound_store) and _bound_store.is_settled():
		_finish_overlay_handoff()


func _on_store_streaming_settled() -> void:
	if _pending_clear_overlay:
		_finish_overlay_handoff()


func _finish_overlay_handoff() -> void:
	_pending_clear_overlay = false
	if _overlay != null:
		_overlay.clear_stroke()
	if is_instance_valid(_bound_store):
		_bound_store.clear_suppressions()


func _cancel_stroke() -> void:
	_stroking = false
	_stroke_added.clear()
	_stroke_erased.clear()
	_finish_overlay_handoff()


# --- Surface raycasting & filters -------------------------------------------------------------


func _raycast_surface(camera: Camera3D, screen_pos: Vector2, erase: bool) -> Dictionary:
	if camera == null or _raycaster == null or not is_instance_valid(_bound_store) or not _bound_store.is_inside_tree():
		return {}
	return _raycaster.raycast(
		_bound_store,
		camera.project_ray_origin(screen_pos),
		camera.project_ray_normal(screen_pos),
		RAY_MAX_DIST,
		_collision_mask,
		true if erase else _paint_on_terrain,
		true if erase else _paint_on_meshes,
		true if erase else _paint_on_copia
	)


func _is_erase_active(shift_held: bool) -> bool:
	var base_erase := _op_pick.selected == 1
	return not base_erase if shift_held else base_erase


func _refresh_cursor_in_place(shift_held: bool) -> void:
	if _has_hover and is_instance_valid(_bound_store) and _bound_store.is_inside_tree():
		_cursor.update(_last_hover_pos, _last_hover_normal, _radius_spin.value, _is_erase_active(shift_held))


func _estimate_density() -> float:
	if _stroke_specs.is_empty():
		return 1.0
	var total := 0.0
	for s in _stroke_specs:
		total += float(s.get("weight", 1.0))
	return clampf(total / float(_stroke_specs.size()), 0.1, 20.0)


func _suppress_columns_in_store(cols: Dictionary) -> void:
	if not is_instance_valid(_bound_store) or cols.is_empty():
		return
	var paths: PackedStringArray = cols.get("object_paths", PackedStringArray())
	var objs: PackedInt32Array = cols.get("object", PackedInt32Array())
	var xforms: PackedFloat32Array = cols.get("transform", PackedFloat32Array())
	var by_path := {}
	for i in objs.size():
		var p := paths[objs[i]]
		var arr: PackedFloat32Array = by_path.get_or_add(p, PackedFloat32Array())
		for k in 12:
			arr.append(xforms[i * 12 + k])
	for p in by_path:
		_bound_store.suppress_transforms(p, by_path[p])


func _register_overlay_visual(obj: Resource) -> void:
	if _overlay == null or obj == null or obj.resource_path.is_empty():
		return
	var mesh: Mesh = obj.get_surface_material_mesh() if obj.has_method("get_surface_material_mesh") else obj.get("mesh")
	if mesh == null:
		return
	var mat_ov: Material = obj.get("material_override")
	var def_col: Color = obj._get_default_color() if obj.has_method("_get_default_color") else Color.WHITE
	var def_cust: Color = obj._get_default_custom() if obj.has_method("_get_default_custom") else Color(0, 0, 0, 0)
	_overlay.set_object_visual(
		obj.resource_path,
		mesh.get_rid(),
		mat_ov.get_rid() if mat_ov != null else RID(),
		def_col,
		def_cust,
		1,
		RenderingServer.SHADOW_CASTING_SETTING_ON,
	)


# --- Toolbar UI -------------------------------------------------------------------------------


func _build_toolbar() -> void:
	_toolbar = HBoxContainer.new()
	_toolbar.hide()
	var title := Label.new()
	title.text = "Copia Brush"
	_toolbar.add_child(title)

	_op_pick = OptionButton.new()
	_op_pick.add_item("Paint")
	_op_pick.add_item("Erase")
	_op_pick.tooltip_text = "Hold Shift while painting to temporarily erase (and vice versa). Alt + mouse navigates."
	_toolbar.add_child(_op_pick)

	_radius_spin = _spin("Radius", 0.25, 200.0, 5.0, 0.25, "m")
	_radius_spin.tooltip_text = "Brush radius in metres ([ / ] or Shift + Scroll)."
	_density_spin = _spin("Density", 0.05, 10.0, 1.0, 0.05, "x")
	_spacing_spin = _spin("Spacing", 0.1, 10.0, 1.0, 0.05, "x")

	_filter_menu = MenuButton.new()
	_filter_menu.text = "Filters"
	_filter_menu.flat = false
	var pop := _filter_menu.get_popup()
	pop.hide_on_checkable_item_selection = false
	pop.add_check_item("Paint on Terrain", 0)
	pop.add_check_item("Paint on Scene Meshes", 1)
	pop.add_check_item("Paint on Copia Instances", 2)
	pop.add_separator()
	pop.add_check_item("Avoid Procedural Sets", 3)
	pop.add_check_item("Erase All in Set (ignore toggle filter)", 4)
	pop.id_pressed.connect(_on_filter_toggled)
	_sync_filter_menu()
	_toolbar.add_child(_filter_menu)


func _spin(lbl_text: String, lo: float, hi: float, val: float, step: float, suffix: String) -> SpinBox:
	var lbl := Label.new()
	lbl.text = lbl_text
	_toolbar.add_child(lbl)
	var sp := SpinBox.new()
	sp.min_value = lo
	sp.max_value = hi
	sp.step = step
	sp.value = val
	sp.suffix = suffix
	_toolbar.add_child(sp)
	return sp


func _sync_filter_menu() -> void:
	var pop := _filter_menu.get_popup()
	pop.set_item_checked(pop.get_item_index(0), _paint_on_terrain)
	pop.set_item_checked(pop.get_item_index(1), _paint_on_meshes)
	pop.set_item_checked(pop.get_item_index(2), _paint_on_copia)
	pop.set_item_checked(pop.get_item_index(3), _avoid_generated)
	pop.set_item_checked(pop.get_item_index(4), _erase_all_in_set)


func _on_filter_toggled(id: int) -> void:
	match id:
		0: _paint_on_terrain = not _paint_on_terrain
		1: _paint_on_meshes = not _paint_on_meshes
		2: _paint_on_copia = not _paint_on_copia
		3: _avoid_generated = not _avoid_generated
		4: _erase_all_in_set = not _erase_all_in_set
	_sync_filter_menu()


func _disconnect_store() -> void:
	if is_instance_valid(_bound_store):
		if _bound_store.build_finished.is_connected(_on_store_build_finished):
			_bound_store.build_finished.disconnect(_on_store_build_finished)
		if _bound_store.streaming_settled.is_connected(_on_store_streaming_settled):
			_bound_store.streaming_settled.disconnect(_on_store_streaming_settled)


# Appends apply-format columns [param more] into [param into] (remapping object_paths cleanly).
static func _append_point_columns(into: Dictionary, more: Dictionary) -> void:
	if more.is_empty() or not more.has("object"):
		return
	var add_n: int = (more.object as PackedInt32Array).size()
	if add_n == 0:
		return
	if into.is_empty():
		into["transform"] = (more.transform as PackedFloat32Array).duplicate()
		into["object"] = (more.object as PackedInt32Array).duplicate()
		into["object_paths"] = (more.object_paths as PackedStringArray).duplicate()
		if more.has("color"):
			into["color"] = (more.color as PackedFloat32Array).duplicate()
		if more.has("custom"):
			into["custom"] = (more.custom as PackedFloat32Array).duplicate()
		if more.has("keep"):
			into["keep"] = (more.keep as PackedFloat32Array).duplicate()
		return
	var prev_n: int = (into.object as PackedInt32Array).size()
	var paths: Array = Array(into.object_paths)
	var more_paths: PackedStringArray = more.object_paths
	var remap: Array[int] = []
	for p in more_paths:
		var idx := paths.find(p)
		if idx < 0:
			idx = paths.size()
			paths.append(p)
		remap.append(idx)
	into["object_paths"] = PackedStringArray(paths)
	(into.transform as PackedFloat32Array).append_array(more.transform)
	var into_obj: PackedInt32Array = into.object
	for oid in more.object:
		into_obj.append(remap[oid])
	for opt_key in ["color", "custom"]:
		if into.has(opt_key) or more.has(opt_key):
			if not into.has(opt_key):
				var pad := PackedFloat32Array()
				pad.resize(prev_n * 4)
				pad.fill(NAN)
				into[opt_key] = pad
			if more.has(opt_key):
				(into[opt_key] as PackedFloat32Array).append_array(more[opt_key])
			else:
				var pad2 := PackedFloat32Array()
				pad2.resize(add_n * 4)
				pad2.fill(NAN)
				(into[opt_key] as PackedFloat32Array).append_array(pad2)
	if into.has("keep") or more.has("keep"):
		if not into.has("keep"):
			var kpad := PackedFloat32Array()
			kpad.resize(prev_n)
			kpad.fill(1.0)
			into["keep"] = kpad
		if more.has("keep"):
			(into.keep as PackedFloat32Array).append_array(more.keep)
		else:
			var kpad2 := PackedFloat32Array()
			kpad2.resize(add_n)
			kpad2.fill(1.0)
			(into.keep as PackedFloat32Array).append_array(kpad2)
