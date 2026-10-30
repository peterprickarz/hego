@tool
class_name StrataEditorPreview
extends Node
## Editor/authoring-view bridge: compose the live authoring stack, never run a producer.
signal refreshed
var terrain: StrataTerrain3D
var renderer: StrataRenderer
var status := "Waiting for editor camera"
var _token: Dictionary = {}
var _cutoff: StrataLayer
var _pending := false
var _camera: Camera3D
var _aux_dirty := true
var _last_channel: StringName
var _last_channel_visible := false
var _compile_count := 0
var _region_count := 0
var _configuration: Array = []
var _configuration_dirty := true
var _macro_image: Image
var _macro_bounds := Rect2()
var _material_signature: Array = []
var _material_controls: Dictionary = {}
var _material_status := ""
var _material_compositions := 0

func setup(source: StrataTerrain3D) -> void:
	terrain = source
	terrain.editor_preview_bridge = self
	terrain.authoring_preview_changed.connect(request_refresh)
	sync_configuration()
	request_refresh()

func sync_configuration() -> void:
	if not is_instance_valid(terrain): return
	var state: Array = [terrain.editor_compile_spacing, terrain.editor_control_ids, terrain.editor_control_weights, terrain.editor_material_channels.duplicate()]
	for material in terrain.editor_materials: state.append(material.get_instance_id() if is_instance_valid(material) else 0)
	if state != _configuration:
		_configuration = state
		_configuration_dirty = true
		request_refresh()

func set_camera(camera: Camera3D) -> void:
	_camera = camera
	if is_instance_valid(_camera) and is_instance_valid(terrain) and Engine.is_editor_hint():
		_camera.far = maxf(_camera.far, terrain.editor_far_clip)
	if is_instance_valid(renderer): renderer.set_camera(camera)
	elif not _pending: request_refresh()

func request_refresh() -> void:
	_aux_dirty = true
	if _pending: return
	_pending = true
	_refresh.call_deferred()

func _refresh() -> void:
	_pending = false
	if not is_instance_valid(terrain) or not terrain.is_inside_tree() or not is_instance_valid(_camera): return
	terrain._sanitize_preview_layer()
	var selected := terrain.preview_through_layer
	var materials_changed := _compose_material_controls(selected)
	if renderer == null or _configuration_dirty or selected != _cutoff or _token.is_empty() or not StrataProcedural.token_is_current(_token):
		status = "Composing live terrain stack (no Houdini cook)"
		var compiled: Dictionary
		var fresh_height := renderer == null or selected != _cutoff or _token.is_empty() or not StrataProcedural.token_is_current(_token) or float(renderer._height_spacing) != terrain.editor_compile_spacing
		if fresh_height:
			compiled = StrataProcedural.compile_heightfield(terrain, selected, terrain.editor_compile_spacing)
		else: compiled = renderer._compiled_input
		if not compiled.get("ok", false):
			status = String(compiled.get("message", "Height compilation failed; previous preview retained"))
			return
		if not is_instance_valid(renderer):
			renderer = StrataRenderer.new()
			renderer.name = "TexturedEditorPreview"
			renderer.render_settings = terrain.render_settings
			terrain.add_child(renderer, false, Node.INTERNAL_MODE_BACK)
			renderer.set_camera(_camera)
			renderer.set_control_maps(_material_controls.ids, _material_controls.weights)
			if not renderer.configure_compiled_field(terrain, terrain.editor_materials, compiled):
				renderer.queue_free(); renderer = null
				status = "Textured preview requires Forward+ and valid materials"
				return
			terrain.editor_renderer = renderer
			materials_changed = false
		elif _configuration_dirty:
			# A smaller pool must not validate against the previous pool's IDs.
			var previous_ids: Image = renderer._control_ids
			var previous_weights: Image = renderer._control_weights
			var neutral := StrataMaterialControls.unassigned()
			renderer.set_control_maps(neutral.ids, neutral.weights)
			if not renderer.configure_compiled_field(terrain, terrain.editor_materials, compiled):
				# Configuration is transactional, including the preview's controls.
				renderer.set_control_maps(previous_ids, previous_weights)
				status = "Invalid material/control configuration; previous rendered terrain retained"
				return
			renderer.set_control_maps(_material_controls.ids, _material_controls.weights)
			materials_changed = false
		else:
			renderer.render_settings = terrain.render_settings
			if not renderer.set_compiled_field(compiled): return
		if fresh_height: _compile_count += 1
		_configuration_dirty = false
		_token = compiled.token
		_cutoff = selected
	if is_instance_valid(renderer):
		renderer.render_settings = terrain.render_settings
		if materials_changed: renderer.set_control_maps(_material_controls.ids, _material_controls.weights)
		if _aux_dirty:
			var masks := StrataProcedural.compile_cell_masks(terrain, selected, terrain.editor_compile_spacing)
			if masks.get("ok", false): renderer.set_hole_image(masks.hole_image)
			var macro_path := "res://addons/strata/strata_macro.gd"
			if FileAccess.file_exists(macro_path):
				var macro_helper: Script = load(macro_path)
				if macro_helper.has_macro_channels(terrain, selected):
					var macro: Dictionary = macro_helper.compose(terrain, {"through_layer": selected})
					if macro.get("ok", false):
						_macro_image = macro.image; _macro_bounds = macro.bounds
						renderer.set_macro_map(_macro_image, _macro_bounds)
				else:
					_macro_image = null
					renderer.set_macro_map(null, terrain.base_bounds)
		if _aux_dirty or _last_channel != terrain.override_channel or _last_channel_visible != terrain.editor_show_channel:
			_refresh_channel()
		_aux_dirty = false
		renderer.set_ownership_overlay(selected, terrain.override_channel, terrain.show_overrides and selected != null)
		status = "Live stack through %s · %d patches · no automatic cook" % [selected.name if selected != null else "final layer", renderer.get_stats().patches]
		if not _material_status.is_empty(): status += " · " + _material_status
		refreshed.emit()

func _compose_material_controls(selected: StrataLayer) -> bool:
	var channels := terrain.editor_material_channels
	var state := StrataMaterialControls.signature(terrain, channels, selected)
	state.append([terrain.editor_materials.size(), terrain.editor_control_ids, terrain.editor_control_weights])
	if not _material_controls.is_empty() and state == _material_signature: return false
	_material_signature = state
	_material_status = ""
	if channels.is_empty():
		if selected == null and terrain.editor_control_ids != null and terrain.editor_control_weights != null:
			_material_controls = {"ids": terrain.editor_control_ids, "weights": terrain.editor_control_weights}
		else:
			_material_controls = StrataMaterialControls.unassigned()
			_material_status = "Materials unassigned; configure ordered material channels for stage previews"
	elif channels.size() != terrain.editor_materials.size():
		_material_controls = StrataMaterialControls.unassigned()
		_material_status = "Materials unassigned; channel mapping must match the material pool"
	else:
		var composed := StrataMaterialControls.compose(terrain, channels, selected)
		_material_compositions += 1
		if composed.get("ok", false):
			_material_controls = composed
			if composed.get("empty", false): _material_status = "Materials unassigned at this stage"
		else:
			_material_controls = StrataMaterialControls.unassigned()
			_material_status = "Materials unassigned: " + String(composed.get("message", "composition failed"))
	return true

## Small brush dirty rectangle; token now describes exactly the updated cutoff.
func can_patch_region() -> bool:
	sync_configuration()
	return is_instance_valid(renderer) and not _configuration_dirty and _cutoff == terrain.preview_through_layer and renderer._render_bounds == terrain.base_bounds and is_equal_approx(renderer._height_spacing, terrain.editor_compile_spacing) and not _token.is_empty() and StrataProcedural.token_is_current(_token)

func refresh_region(point: Vector2, radius: float, native_spacing: float, channel: StringName = &"height", was_current: bool = false) -> void:
	# Only a dab that began on the current complete surface may update its token.
	# A queued cutoff/configuration/external edit must first compose the full view.
	if not was_current or not is_instance_valid(renderer) or _configuration_dirty or _cutoff != terrain.preview_through_layer or renderer._render_bounds != terrain.base_bounds or not is_equal_approx(renderer._height_spacing, terrain.editor_compile_spacing): request_refresh(); return
	var step := terrain.editor_compile_spacing
	if not is_finite(step) or step <= 0.0: return
	var margin := radius + maxf(step * 2.0, native_spacing * 2.0)
	var start := terrain.base_bounds.position
	var minimum := start + ((point - Vector2.ONE * margin - start) / step).floor() * step
	var maximum := start + ((point + Vector2.ONE * margin - start) / step).ceil() * step
	minimum = minimum.max(start); maximum = maximum.min(terrain.base_bounds.end)
	var patch := StrataProcedural.compile_heightfield(terrain, terrain.preview_through_layer, step, {"bounds": Rect2(minimum, maximum - minimum)})
	if renderer.update_compiled_region(patch):
		_region_count += 1
		_aux_dirty = channel in [&"hole", &"nav_exclusion"]
		if terrain.editor_material_channels.has(String(channel)): request_refresh()
		if terrain.channel_default(channel) == 1.0: _refresh_macro_region(point, margin)
		if terrain.editor_show_channel: _refresh_channel()
		_token = patch.token
		_cutoff = terrain.preview_through_layer
		if terrain.show_overrides: renderer.set_ownership_overlay(_cutoff, terrain.override_channel)
	else: request_refresh()

func _refresh_channel() -> void:
	_last_channel = terrain.override_channel
	_last_channel_visible = terrain.editor_show_channel
	if not terrain.editor_show_channel:
		renderer.set_channel_preview(null, terrain.base_bounds, false)
		return
	# Scalar diagnostic only: bounded 4 m lattice, independent of exact cell holes.
	var resolution := Vector2i(ceili(terrain.base_bounds.size.x / 4.0) + 1, ceili(terrain.base_bounds.size.y / 4.0) + 1)
	var step := terrain.base_bounds.size / Vector2(resolution - Vector2i.ONE)
	var origin := Vector3(terrain.base_bounds.position.x, 0.0, terrain.base_bounds.position.y)
	var field: Dictionary = StrataLayerData.compose_dense(StrataProcedural._capture_layers(terrain, terrain.override_channel, terrain.preview_through_layer), terrain.override_channel, origin, Vector3(step.x, 0, 0), Vector3(0, 0, step.y), resolution, terrain.base_bounds, false, 0.0)
	if field.get("ok", false): renderer.set_channel_preview(field.image, terrain.base_bounds, true)

func _refresh_macro_region(point: Vector2, margin: float) -> void:
	var path := "res://addons/strata/strata_macro.gd"
	if not FileAccess.file_exists(path): return
	var helper: Script = load(path)
	if not helper.has_macro_channels(terrain, terrain.preview_through_layer):
		_macro_image = null
		renderer.set_macro_map(null, terrain.base_bounds)
		return
	if _macro_image == null:
		_macro_bounds = terrain.base_bounds
		var dimensions := Vector2i(ceili(_macro_bounds.size.x / 4.0) + 1, ceili(_macro_bounds.size.y / 4.0) + 1)
		_macro_image = Image.create(dimensions.x, dimensions.y, false, Image.FORMAT_RGBAH)
		_macro_image.fill(Color(1, 1, 1, 1))
	var step := _macro_bounds.size / Vector2(_macro_image.get_size() - Vector2i.ONE)
	var begin := ((point - Vector2.ONE * margin - _macro_bounds.position) / step).floor().max(Vector2.ZERO)
	var end := ((point + Vector2.ONE * margin - _macro_bounds.position) / step).ceil().min(Vector2(_macro_image.get_size() - Vector2i.ONE))
	var bounds := Rect2(_macro_bounds.position + begin * step, (end - begin) * step)
	if bounds.size.x <= 0 or bounds.size.y <= 0: return
	var patch: Dictionary = helper.compose(terrain, {"through_layer": terrain.preview_through_layer, "bounds": bounds, "spacing": step.x})
	if patch.get("ok", false) and patch.resolution != Vector2i(end - begin) + Vector2i.ONE:
		# Non-dyadic endpoint rounding can create an extra interval. Recompose
		# the exact full map rather than blitting data from a different lattice.
		var full: Dictionary = helper.compose(terrain, {"through_layer": terrain.preview_through_layer})
		if full.get("ok", false):
			_macro_image = full.image; _macro_bounds = full.bounds
			renderer.set_macro_map(_macro_image, _macro_bounds)
		return
	if patch.get("ok", false):
		_macro_image.blit_rect(patch.image, Rect2i(Vector2i.ZERO, patch.image.get_size()), Vector2i(begin))
		renderer.set_macro_map(_macro_image, _macro_bounds)

func get_stats() -> Dictionary:
	return {"full_compiles": _compile_count, "region_compiles": _region_count, "material_compositions": _material_compositions, "status": status}

func _exit_tree() -> void:
	if is_instance_valid(terrain):
		terrain.editor_renderer = null
		terrain.editor_preview_bridge = null
	if is_instance_valid(renderer): renderer.queue_free()
