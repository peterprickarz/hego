@tool
extends RefCounted
## Individual Copia instance placement and viewport gizmo editing:
## - Drag-and-drop any CopiaObject or CopiaSpecies from the Copia dock directly onto colliders
##   in the 3D viewport (live ghost preview, mouse-wheel yaw / variant cycle).
## - Click any authored instance in Place or Select mode (ray-vs-OBB via native CopiaBrush,
##   works even for objects without colliders, never picks procedural sets).
## - Spawns a transient unowned proxy Node3D (owner = null) so Godot's native 3D Move/Rotate/Scale
##   gizmo, snapping, multi-select and Transform inspector work natively.
## - Commits cross-cell transform updates, duplicates (Ctrl+D) and deletes (Delete) atomically
##   with EditorUndoRedoManager, and tears down all proxies before scene save.

const ObjectScript := preload("res://addons/copia/copia_object.gd")
const SpeciesScript := preload("res://addons/copia/copia_species.gd")
const PlacementScript := preload("res://addons/copia/copia_placement_settings.gd")
const DockScript := preload("res://addons/copia/editor/copia_dock.gd")
const RaycastScript := preload("res://addons/copia/editor/copia_surface_raycast.gd")

const PROXY_META := &"_copia_instance_proxy"
const PICK_LOAD_RADIUS := 192.0
const RAY_MAX_DIST := 2000.0

var _plugin: EditorPlugin
var _dock: Control
var _brush: Object  # native CopiaBrush
var _overlay: Object  # native CopiaEditOverlay
var _raycaster: RefCounted
var _rng := RandomNumberGenerator.new()

# Drag-from-dock state.
var _dragging := false
var _drag_asset_path := ""
var _drag_asset_kind := ""
var _drag_resolved_object: Resource = null
var _drag_yaw_offset := 0.0
var _drag_has_hit := false
var _drag_local_xform := Transform3D.IDENTITY
var _drag_keep := 1.0

# Active transient proxy nodes: Array[Dictionary] of
# {node, set_name, object_path, orig_floats, orig_xform, has_color, color, has_custom, custom, keep, is_new_copy}
var _proxies: Array[Dictionary] = []
var _committing := false
var _pending_clear_suppressions := false
var _bound_store: Node3D = null
var _aabb_cache := {}  # object_path -> AABB
var _brush_dirty := true
var _brush_center := Vector2(INF, INF)

# Unreal-style Alt + Drag gizmo duplication state.
var _alt_drag_armed := false
var _alt_drag_cloned := false
var _alt_drag_start_xforms: Array[Transform3D] = []
var _alt_stay_ghosts: Array[Node3D] = []


func _init(plugin: EditorPlugin, dock: Control) -> void:
	_plugin = plugin
	_dock = dock
	_raycaster = RaycastScript.new()
	_rng.randomize()
	if ClassDB.class_exists("CopiaBrush"):
		_brush = ClassDB.instantiate("CopiaBrush")
	if ClassDB.class_exists("CopiaEditOverlay"):
		_overlay = ClassDB.instantiate("CopiaEditOverlay")


func dispose() -> void:
	commit_and_clear_proxies(true)
	_disconnect_store()
	if _overlay != null:
		_overlay.clear_all()
	if _brush != null:
		_brush.clear()


func set_store(store: Node) -> void:
	var store3d := store as Node3D
	if store3d == _bound_store:
		return
	commit_and_clear_proxies(true)
	_disconnect_store()
	_bound_store = store3d
	_brush_dirty = true
	if _raycaster != null:
		_raycaster.invalidate()
	if is_instance_valid(_bound_store):
		if not _bound_store.build_finished.is_connected(_on_store_build_finished):
			_bound_store.build_finished.connect(_on_store_build_finished)
		if not _bound_store.streaming_settled.is_connected(_on_store_streaming_settled):
			_bound_store.streaming_settled.connect(_on_store_streaming_settled)
		if _overlay != null and _bound_store.is_inside_tree():
			_overlay.set_scenario(_bound_store.get_world_3d().scenario)
			_overlay.set_transform(_bound_store.global_transform)


func invalidate_pick_cache() -> void:
	_brush_dirty = true


func on_before_save() -> void:
	commit_and_clear_proxies(true)


func on_mode_changed(mode: int) -> void:
	if mode != DockScript.Mode.PLACE and mode != DockScript.Mode.SELECT:
		commit_and_clear_proxies(true)
		_cancel_drag()


func on_selection_changed() -> void:
	if _committing or _proxies.is_empty():
		return
	var sel := EditorInterface.get_selection().get_selected_nodes()
	var any_proxy := false
	for p in _proxies:
		if is_instance_valid(p.node) and sel.has(p.node):
			any_proxy = true
			break
	if not any_proxy:
		commit_and_clear_proxies(true)


func process(_delta: float) -> void:
	if not is_instance_valid(_bound_store) or not _bound_store.is_inside_tree():
		return
	# Unreal-style Alt + Drag on the native transform gizmo: once a proxy actually moves while
	# Alt + Left-Mouse is held, leave the original behind and turn the dragged proxy into a new copy.
	if not _proxies.is_empty():
		var left_down := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		if _alt_drag_armed and not _alt_drag_cloned:
			if not left_down:
				_alt_drag_armed = false
				_alt_drag_start_xforms.clear()
			elif _proxies_moved_from(_alt_drag_start_xforms):
				_trigger_alt_drag_clone()
		elif _alt_drag_cloned and not left_down:
			_finish_alt_drag_clone()
	# Detect drag-and-drop started from the Copia dock without hijacking Godot's FileSystem drops.
	var vp := _dock.get_viewport()
	if vp != null and vp.gui_is_dragging():
		var data: Variant = vp.gui_get_drag_data()
		if data is Dictionary and str(data.get("type", "")) == "copia_asset":
			if not _dragging:
				_begin_drag(str(data.get("path", "")), str(data.get("kind", "object")))
			_update_drag_preview()
			return
	if _dragging:
		_finish_drag()


func handle_3d_input(camera: Camera3D, event: InputEvent) -> int:
	if not is_instance_valid(_bound_store) or not _bound_store.is_inside_tree():
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var mode: int = _dock.active_mode
	if mode != DockScript.Mode.PLACE and mode != DockScript.Mode.SELECT:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	# Hotkeys while a Copia proxy is selected.
	if not _proxies.is_empty() and event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode == KEY_DELETE or key.keycode == KEY_BACKSPACE:
			_delete_selected_proxies()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if key.keycode == KEY_D and key.ctrl_pressed:
			_duplicate_selected_proxies()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if key.keycode == KEY_ESCAPE:
			commit_and_clear_proxies(true)
			return EditorPlugin.AFTER_GUI_INPUT_STOP

	# Mouse wheel rotates drag ghost or cycles species variant.
	if _dragging and event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var step := 1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			if mb.shift_pressed and _drag_asset_kind == "species":
				_resolve_drag_object()
			else:
				_drag_yaw_offset += step * deg_to_rad(15.0)
			return EditorPlugin.AFTER_GUI_INPUT_STOP

	# Left click in viewport:
	# - Alt+Left-Press while proxies are selected arms Unreal-style Alt+Drag gizmo duplication
	#   (never consumes the event so Godot's gizmo drag or Alt-orbit camera works normally).
	# - Ctrl+Click in Place mode drops the currently selected dock item onto the surface.
	# - Plain click picks an authored instance (Shift adds to selection), letting gizmo drags pass
	#   through when clicking on an active proxy's gizmo.
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed and mb.alt_pressed and not _proxies.is_empty():
				_arm_alt_drag()
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			if not mb.pressed:
				if _alt_drag_cloned:
					_finish_alt_drag_clone()
				_alt_drag_armed = false
				_alt_drag_start_xforms.clear()
				return EditorPlugin.AFTER_GUI_INPUT_PASS
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and not mb.alt_pressed:
			if mode == DockScript.Mode.PLACE and mb.ctrl_pressed and not str(_dock.selected_place_path).is_empty():
				return _quick_place_at_cursor(camera, mb.position)
			if not _proxies.is_empty():
				# Let Godot's native gizmo handle clicks when proxies are active unless Shift-picking
				# or clicking a different authored instance clearly away from the gizmo.
				if not mb.shift_pressed:
					return EditorPlugin.AFTER_GUI_INPUT_PASS
			return _try_pick_instance(camera, mb.position, mb.shift_pressed)

	return EditorPlugin.AFTER_GUI_INPUT_PASS


# --- Drag-and-drop placement ------------------------------------------------------------------


func _begin_drag(asset_path: String, kind: String) -> void:
	_dragging = true
	_drag_asset_path = asset_path
	_drag_asset_kind = kind
	_drag_yaw_offset = 0.0
	_drag_has_hit = false
	_resolve_drag_object()
	if _overlay != null and is_instance_valid(_bound_store) and _bound_store.is_inside_tree():
		_overlay.set_scenario(_bound_store.get_world_3d().scenario)
		_overlay.set_transform(_bound_store.global_transform)


func _resolve_drag_object() -> void:
	_drag_resolved_object = null
	if _drag_asset_path.is_empty() or not ResourceLoader.exists(_drag_asset_path):
		return
	var res := ResourceLoader.load(_drag_asset_path)
	if res == null:
		return
	if is_instance_of(res, SpeciesScript):
		var entry = res.pick_entry(_rng, 1.0)
		if entry != null and entry.object != null:
			_drag_resolved_object = entry.object
	elif is_instance_of(res, ObjectScript):
		_drag_resolved_object = res
	if _drag_resolved_object != null:
		_register_overlay_visual(_drag_resolved_object)


func _update_drag_preview() -> void:
	if _drag_resolved_object == null or _overlay == null or not is_instance_valid(_bound_store):
		return
	var hit_info := _raycast_hovered_3d_viewport()
	if hit_info.is_empty():
		_drag_has_hit = false
		_overlay.hide_ghost()
		return
	var cfg := _placement_for(_drag_asset_path, _drag_resolved_object)
	var world_pos: Vector3 = hit_info.position
	var world_normal: Vector3 = hit_info.normal
	var local_pos: Vector3 = _bound_store.to_local(world_pos)
	var local_n: Vector3 = (_bound_store.global_transform.basis.inverse() * world_normal).normalized()
	var up := Vector3.UP.lerp(local_n, cfg.align_to_normal).normalized()
	var align_q := Quaternion(Vector3.UP, up)
	var yaw_q := Quaternion(Vector3.UP, _drag_yaw_offset)
	var basis := Basis(align_q * yaw_q)
	var scale_avg := (cfg.scale_min + cfg.scale_max) * 0.5
	basis = basis.scaled_local(Vector3.ONE * scale_avg)
	var y_off := (cfg.y_offset_min + cfg.y_offset_max) * 0.5
	_drag_local_xform = Transform3D(basis, local_pos + up * y_off)
	_drag_keep = clampf(cfg.keep_max, 0.0, 1.0)
	_drag_has_hit = true
	_overlay.set_ghost(_drag_resolved_object.resource_path, _drag_local_xform, true)


func _finish_drag() -> void:
	var placed_obj := _drag_resolved_object
	var had_hit := _drag_has_hit
	var xform := _drag_local_xform
	var keep_v := _drag_keep
	_cancel_drag()
	if not had_hit or placed_obj == null or placed_obj.resource_path.is_empty():
		return
	_commit_single_placement(placed_obj, xform, keep_v)


func _cancel_drag() -> void:
	_dragging = false
	_drag_has_hit = false
	_drag_resolved_object = null
	if _overlay != null:
		_overlay.hide_ghost()


func _quick_place_at_cursor(camera: Camera3D, screen_pos: Vector2) -> int:
	var path := str(_dock.selected_place_path)
	if path.is_empty() or not ResourceLoader.exists(path):
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var hit := _raycast_camera(camera, screen_pos)
	if hit.is_empty():
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var res := ResourceLoader.load(path)
	var obj: Resource = null
	if is_instance_of(res, SpeciesScript):
		var entry = res.pick_entry(_rng, 1.0)
		obj = entry.object if entry != null else null
	elif is_instance_of(res, ObjectScript):
		obj = res
	if obj == null or obj.resource_path.is_empty():
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var cfg := _placement_for(path, obj)
	var local_pos: Vector3 = _bound_store.to_local(hit.position)
	var local_n: Vector3 = (_bound_store.global_transform.basis.inverse() * hit.normal).normalized()
	var up := Vector3.UP.lerp(local_n, cfg.align_to_normal).normalized()
	var align_q := Quaternion(Vector3.UP, up)
	var yaw := _rng.randf() * TAU if cfg.random_yaw else 0.0
	var basis := Basis(align_q * Quaternion(Vector3.UP, yaw))
	var sc := _rng.randf_range(minf(cfg.scale_min, cfg.scale_max), maxf(cfg.scale_min, cfg.scale_max))
	basis = basis.scaled_local(Vector3.ONE * sc)
	var y_off := _rng.randf_range(minf(cfg.y_offset_min, cfg.y_offset_max), maxf(cfg.y_offset_min, cfg.y_offset_max))
	var xform := Transform3D(basis, local_pos + up * y_off)
	_commit_single_placement(obj, xform, _rng.randf_range(minf(cfg.keep_min, cfg.keep_max), maxf(cfg.keep_min, cfg.keep_max)))
	return EditorPlugin.AFTER_GUI_INPUT_STOP


func _commit_single_placement(obj: Resource, local_xform: Transform3D, keep_v: float) -> void:
	if not is_instance_valid(_bound_store):
		return
	var target_set: String = _dock.active_set
	if not _dock.ensure_authored_set(target_set):
		_dock.set_status("Cannot write to set \"%s\"" % target_set)
		return
	var pts := _pack_single_point(obj.resource_path, local_xform, false, Color.WHITE, false, Color(0, 0, 0, 0), keep_v)
	var ur := _plugin.get_undo_redo()
	ur.create_action("Copia Place " + obj.resource_path.get_file().get_basename())
	ur.add_do_method(self, "_apply_edit_op", _bound_store, target_set, {}, pts)
	ur.add_undo_method(self, "_apply_edit_op", _bound_store, target_set, pts, {})
	ur.commit_action()
	# Immediately select the newly placed instance with a gizmo proxy for fine tuning.
	commit_and_clear_proxies(true)
	_spawn_proxy(target_set, obj.resource_path, local_xform, _xform_to_floats(local_xform), false, Color.WHITE, false, Color(0, 0, 0, 0), keep_v, false)
	_dock.set_status("Placed %s in \"%s\"" % [obj.resource_path.get_file().get_basename(), target_set])


# --- Picking & transient proxy gizmo ----------------------------------------------------------


func _try_pick_instance(camera: Camera3D, screen_pos: Vector2, additive: bool) -> int:
	if _brush == null or not is_instance_valid(_bound_store):
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	_ensure_pick_cache(camera.global_position)
	var world_origin := camera.project_ray_origin(screen_pos)
	var world_dir := camera.project_ray_normal(screen_pos)
	var inv := _bound_store.global_transform.affine_inverse()
	var local_origin := inv * world_origin
	var local_dir := (inv.basis * world_dir).normalized()
	var pick: Dictionary = _brush.pick_ray(local_origin, local_dir, RAY_MAX_DIST, _aabb_cache)
	if not bool(pick.get("hit", false)):
		if not additive and not _proxies.is_empty():
			commit_and_clear_proxies(true)
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if not additive:
		commit_and_clear_proxies(true)
	_spawn_proxy(
		str(pick.set),
		str(pick.object_path),
		pick.transform,
		pick.transform_floats,
		bool(pick.has_color),
		pick.color,
		bool(pick.has_custom),
		pick.custom,
		float(pick.keep),
		additive,
	)
	_dock.set_status("Selected %s [%s] (Move/Rotate/Scale, Ctrl+D, Delete)" % [str(pick.object_path).get_file().get_basename(), str(pick.set)])
	return EditorPlugin.AFTER_GUI_INPUT_STOP


func _spawn_proxy(set_name: String, object_path: String, xform: Transform3D, orig_floats: PackedFloat32Array,
		has_color: bool, color: Color, has_custom: bool, custom: Color, keep_v: float, additive: bool) -> void:
	if not is_instance_valid(_bound_store):
		return
	var proxy := Node3D.new()
	proxy.name = "CopiaProxy_" + object_path.get_file().get_basename().validate_node_name()
	proxy.set_meta(PROXY_META, true)
	proxy.transform = xform
	# Never set proxy.owner so it can never be serialized into the .tscn scene.
	var obj = ObjectScript.resolve(object_path)
	if obj != null and obj.mesh != null:
		var mi := MeshInstance3D.new()
		mi.mesh = obj.get_surface_material_mesh()
		mi.material_override = obj.material_override
		proxy.add_child(mi)
	_bound_store.add_child(proxy)
	_bound_store.suppress_transforms(object_path, orig_floats)
	_proxies.append({
		"node": proxy,
		"set_name": set_name,
		"object_path": object_path,
		"orig_floats": orig_floats,
		"orig_xform": xform,
		"has_color": has_color,
		"color": color,
		"has_custom": has_custom,
		"custom": custom,
		"keep": keep_v,
		"is_new_copy": false,
	})
	_committing = true
	var sel := EditorInterface.get_selection()
	if not additive:
		sel.clear()
	sel.add_node(proxy)
	_committing = false


func commit_and_clear_proxies(commit_changes: bool) -> void:
	_alt_drag_armed = false
	_alt_drag_cloned = false
	_alt_drag_start_xforms.clear()
	_clear_alt_stay_ghosts()
	if _proxies.is_empty():
		return
	_committing = true
	var snapshot := _proxies.duplicate()
	_proxies.clear()

	# Group moved / newly-copied instances by authored set.
	var edits_by_set := {}  # set_name -> {removes: Array, adds: Array}
	for entry in snapshot:
		var node: Node3D = entry.node
		var valid := is_instance_valid(node)
		var new_xform: Transform3D = node.transform if valid else entry.orig_xform
		var is_new := bool(entry.get("is_new_copy", false))
		if commit_changes and valid and (is_new or not _xform_approx(entry.orig_xform, new_xform)):
			var bucket: Dictionary = edits_by_set.get_or_add(entry.set_name, {"removes": [], "adds": []})
			if not is_new:
				bucket.removes.append(entry)
			bucket.adds.append({
				"object_path": entry.object_path,
				"xform": new_xform,
				"has_color": entry.has_color,
				"color": entry.color,
				"has_custom": entry.has_custom,
				"custom": entry.custom,
				"keep": entry.keep,
			})
		if valid:
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.queue_free()

	if not edits_by_set.is_empty() and is_instance_valid(_bound_store):
		var ur := _plugin.get_undo_redo()
		ur.create_action("Copia Transform Instance(s)")
		for set_name in edits_by_set:
			var bucket: Dictionary = edits_by_set[set_name]
			var rem_dict := {} if bucket.removes.is_empty() else _pack_entries(bucket.removes, true)
			var add_dict := _pack_entries(bucket.adds, false)
			ur.add_do_method(self, "_apply_edit_op", _bound_store, set_name, rem_dict, add_dict)
			ur.add_undo_method(self, "_apply_edit_op", _bound_store, set_name, add_dict, rem_dict)
		_pending_clear_suppressions = true
		ur.commit_action()
	elif is_instance_valid(_bound_store):
		_bound_store.clear_suppressions()
	_committing = false


func _arm_alt_drag() -> void:
	_alt_drag_armed = true
	_alt_drag_cloned = false
	_alt_drag_start_xforms.clear()
	for entry in _proxies:
		var node: Node3D = entry.node
		_alt_drag_start_xforms.append(node.transform if is_instance_valid(node) else entry.orig_xform)


func _proxies_moved_from(start_xforms: Array[Transform3D]) -> bool:
	if start_xforms.size() != _proxies.size():
		return false
	for i in _proxies.size():
		var node: Node3D = _proxies[i].node
		if is_instance_valid(node) and not _xform_approx(start_xforms[i], node.transform):
			return true
	return false


func _trigger_alt_drag_clone() -> void:
	if not is_instance_valid(_bound_store) or _alt_drag_start_xforms.size() != _proxies.size():
		return
	_alt_drag_cloned = true
	# If any proxy was moved before Alt+Drag started, commit that prior move first so the
	# original stays right where the user left it.
	var prior_moves := {}  # set_name -> {removes, adds}
	for i in _proxies.size():
		var entry: Dictionary = _proxies[i]
		var stay_xform: Transform3D = _alt_drag_start_xforms[i]
		var was_new := bool(entry.get("is_new_copy", false))
		if was_new or not _xform_approx(entry.orig_xform, stay_xform):
			var bucket: Dictionary = prior_moves.get_or_add(entry.set_name, {"removes": [], "adds": []})
			if not was_new:
				bucket.removes.append(entry)
			bucket.adds.append({
				"object_path": entry.object_path,
				"xform": stay_xform,
				"has_color": entry.has_color,
				"color": entry.color,
				"has_custom": entry.has_custom,
				"custom": entry.custom,
				"keep": entry.keep,
			})
			# Show a temporary visual at stay_xform while the async cell rebuild finishes.
			_spawn_alt_stay_ghost(entry.object_path, stay_xform)
		entry["is_new_copy"] = true
	if not prior_moves.is_empty():
		var ur := _plugin.get_undo_redo()
		ur.create_action("Copia Transform Instance(s)")
		for set_name in prior_moves:
			var bucket: Dictionary = prior_moves[set_name]
			var rem_dict := {} if bucket.removes.is_empty() else _pack_entries(bucket.removes, true)
			var add_dict := _pack_entries(bucket.adds, false)
			ur.add_do_method(self, "_apply_edit_op", _bound_store, set_name, rem_dict, add_dict)
			ur.add_undo_method(self, "_apply_edit_op", _bound_store, set_name, add_dict, rem_dict)
		ur.commit_action()
	# Unsuppress the originals so they immediately remain visible at the starting location while
	# the dragged proxy moves away with the gizmo.
	_bound_store.clear_suppressions()
	_dock.set_status("Alt+Drag duplicating %d instance(s)..." % _proxies.size())


func _finish_alt_drag_clone() -> void:
	_alt_drag_armed = false
	_alt_drag_cloned = false
	_alt_drag_start_xforms.clear()
	if _proxies.is_empty() or not is_instance_valid(_bound_store):
		return
	var adds_by_set := {}
	for entry in _proxies:
		var node: Node3D = entry.node
		if not is_instance_valid(node):
			continue
		var new_xform: Transform3D = node.transform
		adds_by_set.get_or_add(entry.set_name, []).append({
			"object_path": entry.object_path,
			"xform": new_xform,
			"has_color": entry.has_color,
			"color": entry.color,
			"has_custom": entry.has_custom,
			"custom": entry.custom,
			"keep": entry.keep,
		})
		entry.orig_xform = new_xform
		entry.orig_floats = _xform_to_floats(new_xform)
		entry["is_new_copy"] = false
		_bound_store.suppress_transforms(entry.object_path, entry.orig_floats)
	if not adds_by_set.is_empty():
		var ur := _plugin.get_undo_redo()
		ur.create_action("Copia Alt+Drag Duplicate")
		for set_name in adds_by_set:
			var add_dict := _pack_entries(adds_by_set[set_name], false)
			ur.add_do_method(self, "_apply_edit_op", _bound_store, set_name, {}, add_dict)
			ur.add_undo_method(self, "_apply_edit_op", _bound_store, set_name, add_dict, {})
		ur.commit_action()
		_dock.set_status("Duplicated %d instance(s) via Alt+Drag" % _proxies.size())


func _spawn_alt_stay_ghost(object_path: String, local_xform: Transform3D) -> void:
	if not is_instance_valid(_bound_store):
		return
	var obj = ObjectScript.resolve(object_path)
	if obj == null or obj.mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.transform = local_xform
	mi.mesh = obj.get_surface_material_mesh()
	mi.material_override = obj.material_override
	_bound_store.add_child(mi)
	_alt_stay_ghosts.append(mi)


func _clear_alt_stay_ghosts() -> void:
	for g in _alt_stay_ghosts:
		if is_instance_valid(g):
			if g.get_parent() != null:
				g.get_parent().remove_child(g)
			g.queue_free()
	_alt_stay_ghosts.clear()


func _delete_selected_proxies() -> void:
	if _proxies.is_empty() or not is_instance_valid(_bound_store):
		return
	_committing = true
	var snapshot := _proxies.duplicate()
	_proxies.clear()
	var by_set := {}
	for entry in snapshot:
		if is_instance_valid(entry.node):
			if entry.node.get_parent() != null:
				entry.node.get_parent().remove_child(entry.node)
			entry.node.queue_free()
		by_set.get_or_add(entry.set_name, []).append(entry)
	var ur := _plugin.get_undo_redo()
	ur.create_action("Copia Delete Instance(s)")
	for set_name in by_set:
		var rem_dict := _pack_entries(by_set[set_name], true)
		ur.add_do_method(self, "_apply_edit_op", _bound_store, set_name, rem_dict, {})
		ur.add_undo_method(self, "_apply_edit_op", _bound_store, set_name, {}, rem_dict)
	_pending_clear_suppressions = true
	ur.commit_action()
	_committing = false
	_dock.set_status("Deleted %d instance(s)" % snapshot.size())


func _duplicate_selected_proxies() -> void:
	if _proxies.is_empty() or not is_instance_valid(_bound_store):
		return
	# First commit any in-flight movement of the originals, then add duplicates at the same pose.
	var to_dup: Array[Dictionary] = []
	for entry in _proxies:
		if is_instance_valid(entry.node):
			to_dup.append({
				"set_name": entry.set_name,
				"object_path": entry.object_path,
				"xform": entry.node.transform,
				"has_color": entry.has_color,
				"color": entry.color,
				"has_custom": entry.has_custom,
				"custom": entry.custom,
				"keep": entry.keep,
			})
	commit_and_clear_proxies(true)
	var by_set := {}
	for d in to_dup:
		by_set.get_or_add(d.set_name, []).append(d)
	var ur := _plugin.get_undo_redo()
	ur.create_action("Copia Duplicate Instance(s)")
	for set_name in by_set:
		var add_dict := _pack_entries(by_set[set_name], false)
		ur.add_do_method(self, "_apply_edit_op", _bound_store, set_name, {}, add_dict)
		ur.add_undo_method(self, "_apply_edit_op", _bound_store, set_name, add_dict, {})
	ur.commit_action()
	for i in to_dup.size():
		var d := to_dup[i]
		_spawn_proxy(d.set_name, d.object_path, d.xform, _xform_to_floats(d.xform), d.has_color, d.color, d.has_custom, d.custom, d.keep, i > 0)
	_dock.set_status("Duplicated %d instance(s)" % to_dup.size())


func _apply_edit_op(store: Node, set_name: String, removes: Dictionary, adds: Dictionary) -> void:
	if not is_instance_valid(store):
		return
	var res: Dictionary = store.edit_points(set_name, removes, adds, "authored", true)
	_brush_dirty = true
	if not res.get("ok", false):
		_dock.set_status("Edit failed: " + str(res.get("error", "")))
		store.clear_suppressions()
		_pending_clear_suppressions = false
	elif res.get("cells", []).is_empty():
		store.clear_suppressions()
		_pending_clear_suppressions = false


func _on_store_build_finished(_report: Dictionary) -> void:
	_brush_dirty = true
	if is_instance_valid(_bound_store) and _bound_store.is_settled():
		_on_store_streaming_settled()


func _on_store_streaming_settled() -> void:
	_clear_alt_stay_ghosts()
	if _pending_clear_suppressions and is_instance_valid(_bound_store):
		_bound_store.clear_suppressions()
		_pending_clear_suppressions = false
	_brush_dirty = true


# --- Helpers ----------------------------------------------------------------------------------


func _ensure_pick_cache(world_cam_pos: Vector3) -> void:
	if _brush == null or not is_instance_valid(_bound_store):
		return
	var local_cam := _bound_store.to_local(world_cam_pos)
	var cam_xz := Vector2(local_cam.x, local_cam.z)
	if not _brush_dirty and cam_xz.distance_to(_brush_center) < PICK_LOAD_RADIUS * 0.35:
		return
	_brush.clear()
	var authored_sets: PackedStringArray = _bound_store.list_authored_sets()
	if not authored_sets.is_empty():
		var rect := Rect2(cam_xz - Vector2.ONE * PICK_LOAD_RADIUS, Vector2.ONE * (PICK_LOAD_RADIUS * 2.0))
		var pts: Dictionary = _bound_store.read_points(rect, authored_sets, PackedStringArray())
		if int(pts.get("count", 0)) > 0:
			_brush.load_points(pts, true, {})
			for p in pts.get("object_paths", PackedStringArray()):
				if not _aabb_cache.has(p):
					var obj = ObjectScript.resolve(p)
					if obj != null and obj.mesh != null:
						_aabb_cache[p] = obj.mesh.get_aabb()
	_brush_center = cam_xz
	_brush_dirty = false


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


func _raycast_hovered_3d_viewport() -> Dictionary:
	for i in 4:
		var vp := EditorInterface.get_editor_viewport_3d(i)
		if vp == null:
			continue
		var parent := vp.get_parent() as Control
		if parent == null or not parent.is_visible_in_tree():
			continue
		var local_mouse := parent.get_local_mouse_position()
		if not Rect2(Vector2.ZERO, parent.size).has_point(local_mouse):
			continue
		var cam := vp.get_camera_3d()
		if cam != null:
			return _raycast_camera(cam, local_mouse)
	return {}


func _raycast_camera(camera: Camera3D, screen_pos: Vector2) -> Dictionary:
	if camera == null or _raycaster == null or not is_instance_valid(_bound_store) or not _bound_store.is_inside_tree():
		return {}
	return _raycaster.raycast(_bound_store, camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos), RAY_MAX_DIST)


func _placement_for(asset_path: String, resolved_obj: Resource) -> PlacementScript:
	if not asset_path.is_empty() and ResourceLoader.exists(asset_path):
		var res := ResourceLoader.load(asset_path)
		if res != null and res.get("placement") != null:
			return res.get("placement")
	if resolved_obj != null and resolved_obj.get("placement") != null:
		return resolved_obj.get("placement")
	return PlacementScript.new()


func _disconnect_store() -> void:
	if is_instance_valid(_bound_store):
		if _bound_store.build_finished.is_connected(_on_store_build_finished):
			_bound_store.build_finished.disconnect(_on_store_build_finished)
		if _bound_store.streaming_settled.is_connected(_on_store_streaming_settled):
			_bound_store.streaming_settled.disconnect(_on_store_streaming_settled)


static func _xform_to_floats(xform: Transform3D) -> PackedFloat32Array:
	var cx := xform.basis.x
	var cy := xform.basis.y
	var cz := xform.basis.z
	var o := xform.origin
	return PackedFloat32Array([cx.x, cx.y, cx.z, cy.x, cy.y, cy.z, cz.x, cz.y, cz.z, o.x, o.y, o.z])


static func _xform_approx(a: Transform3D, b: Transform3D) -> bool:
	return a.origin.distance_squared_to(b.origin) < 1e-8 \
		and a.basis.x.distance_squared_to(b.basis.x) < 1e-8 \
		and a.basis.y.distance_squared_to(b.basis.y) < 1e-8 \
		and a.basis.z.distance_squared_to(b.basis.z) < 1e-8


static func _pack_single_point(object_path: String, xform: Transform3D, has_color: bool, color: Color,
		has_custom: bool, custom: Color, keep_v: float) -> Dictionary:
	var d := {
		"transform": _xform_to_floats(xform),
		"object": PackedInt32Array([0]),
		"object_paths": PackedStringArray([object_path]),
		"keep": PackedFloat32Array([keep_v]),
	}
	if has_color:
		d["color"] = PackedFloat32Array([color.r, color.g, color.b, color.a])
	if has_custom:
		d["custom"] = PackedFloat32Array([custom.r, custom.g, custom.b, custom.a])
	return d


static func _pack_entries(entries: Array, use_orig: bool) -> Dictionary:
	var transforms := PackedFloat32Array()
	var objects := PackedInt32Array()
	var paths: Array[String] = []
	var colors := PackedFloat32Array()
	var customs := PackedFloat32Array()
	var keeps := PackedFloat32Array()
	var any_color := false
	var any_custom := false
	for e in entries:
		var path := str(e.object_path)
		var pid := paths.find(path)
		if pid < 0:
			pid = paths.size()
			paths.append(path)
		objects.append(pid)
		var tf: PackedFloat32Array = e.orig_floats if use_orig else _xform_to_floats(e.xform)
		transforms.append_array(tf)
		if bool(e.has_color):
			any_color = true
			var c: Color = e.color
			colors.append_array(PackedFloat32Array([c.r, c.g, c.b, c.a]))
		else:
			colors.append_array(PackedFloat32Array([NAN, NAN, NAN, NAN]))
		if bool(e.has_custom):
			any_custom = true
			var u: Color = e.custom
			customs.append_array(PackedFloat32Array([u.r, u.g, u.b, u.a]))
		else:
			customs.append_array(PackedFloat32Array([NAN, NAN, NAN, NAN]))
		keeps.append(float(e.keep))
	var d := {
		"transform": transforms,
		"object": objects,
		"object_paths": PackedStringArray(paths),
		"keep": keeps,
	}
	if any_color:
		d["color"] = colors
	if any_custom:
		d["custom"] = customs
	return d
