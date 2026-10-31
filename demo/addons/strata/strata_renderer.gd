@tool
class_name StrataRenderer
extends Node3D
## Forward+ experiment: bounded native quadtree geometry, individual source
## textures, and a global shader heightfield. No paging or collision backend.

@export_range(4, 64, 2) var cells_per_patch := 64
## Optional persisted quality settings, shared by editor and play mode.
@export var render_settings: StrataRenderSettings:
	set(value):
		if render_settings == value: return
		if render_settings != null and render_settings.changed.is_connected(_quality_changed): render_settings.changed.disconnect(_quality_changed)
		render_settings = value
		if render_settings != null: render_settings.changed.connect(_quality_changed)
		_quality_changed()
@export var min_patch_size := 8.0
@export var split_ratio := 3.0
@export var max_patches := 1024
## Lighting normals use the continuous field; geometry/collision keep their
## canonical triangle interpolation. False retains the previous faceted shading.
@export var smooth_shading := true:
	set(value):
		smooth_shading = value
		_update_material_settings()
## 180 disables crease processing. Lower angles preserve discontinuities between
## adjacent canonical field triangles; the threshold is unrelated to slope.
@export_range(0.0, 180.0, 1.0) var crease_angle_degrees := 180.0:
	set(value):
		if not is_finite(value) or value < 0.0 or value > 180.0:
			push_warning("Crease angle must be finite and within 0..180 degrees; previous value retained.")
			return
		crease_angle_degrees = value
		_update_material_settings()
@export var debug_shading_normals := false:
	set(value):
		debug_shading_normals = value
		_update_material_settings()
## ORMH alpha redistributes existing painted material contributions only.
@export var height_blend_enabled := true:
	set(value):
		height_blend_enabled = value
		_update_material_settings()
## Optional distance-dependent texture scaling; disabled keeps physical UV size.
@export var distance_uv_enabled := false:
	set(value):
		distance_uv_enabled = value
		_update_material_settings()
@export_range(0.01, 1.0, 0.01) var far_uv_factor := 0.125:
	set(value):
		if not is_finite(value) or value <= 0.0 or value > 1.0: return
		far_uv_factor = value
		_update_material_settings()
@export var uv_near_distance := 16.0:
	set(value):
		if not is_finite(value) or value < 0.0: return
		uv_near_distance = value
		_update_material_settings()
@export var uv_far_distance := 128.0:
	set(value):
		if not is_finite(value) or value <= 0.0: return
		uv_far_distance = value
		_update_material_settings()
@export_group("Near displacement geometry")
@export var displacement_refinement_enabled := true:
	set(value):
		if displacement_refinement_enabled == value: return
		displacement_refinement_enabled = value
		_invalidate_geometry_lod()
		_update_material_settings()
@export_range(0.001, 8.0, 0.001, "or_greater") var displacement_vertex_spacing := 0.0625:
	set(value):
		if not is_finite(value) or value <= 0.0: return
		if displacement_vertex_spacing == value: return
		displacement_vertex_spacing = value
		_invalidate_geometry_lod()
@export_range(0.0, 512.0, 1.0, "or_greater") var displacement_refinement_radius := 32.0:
	set(value):
		if not is_finite(value) or value < 0.0: return
		if displacement_refinement_radius == value: return
		displacement_refinement_radius = value
		_invalidate_geometry_lod()
		_update_material_settings()
@export_range(0, 4096, 16) var displacement_refinement_budget := 1024:
	set(value):
		if value < 0 or value > 4096: return
		if displacement_refinement_budget == value: return
		displacement_refinement_budget = value
		_invalidate_geometry_lod()
@export_group("Visual displacement")
@export var displacement_enabled := true:
	set(value):
		if displacement_enabled == value: return
		displacement_enabled = value
		_invalidate_geometry_lod()
		_update_material_settings()
## Compatibility alias: this is the same visual/geometry radius, not a second
## fade zone. Toggling subdivision never changes the displacement appearance.
@export var displacement_radius: float = 32.0:
	get: return displacement_refinement_radius
	set(value):
		if not is_finite(value) or value < 0.0:
			push_warning("Displacement radius must be finite and nonnegative; previous value retained.")
			return
		displacement_refinement_radius = value
		if render_settings != null: render_settings.displacement_refinement_radius = value
@export var displacement_strength := 0.2:
	set(value):
		if not is_finite(value) or value < 0.0:
			push_warning("Displacement strength must be finite and nonnegative; previous value retained.")
			return
		displacement_strength = value
		_update_material_settings()
@export var debug_lod := false:
	set(value):
		debug_lod = value
		_update_material_settings()
@export var debug_discarded := false:
	set(value):
		debug_discarded = value
		_update_material_settings()
@export var wireframe := false:
	set(value):
		wireframe = value
		if is_inside_tree():
			_apply_wireframe_state()

const SURFACE_SHADER_PATH := "res://addons/strata/shaders/terrain_surface.gdshader"
const _HOOK_MARKER := "STRATA_MATERIAL_HOOK_FUNCTIONS"
## Seconds of editor idle time after a custom_fragment_code edit before the
## shader is regenerated, so typing does not compile every keystroke.
const _HOOK_REBUILD_DELAY := 0.5
const _RESERVED_HOOK_NAMES := ["s", "c", "bool", "int", "uint", "float", "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4", "bvec2", "bvec3", "bvec4", "mat2", "mat3", "mat4", "void", "true", "false", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "discard", "in", "out", "inout", "const", "uniform", "varying", "struct", "flat", "smooth", "lowp", "mediump", "highp", "instance", "global", "precision"]
# Generated surface shaders by complete source, shared by every renderer
# (editor preview and runtime) so a reconfigure never recompiles known code.
# A null value records source that failed to compile.
static var _generated_shaders := {}
static var _hook_name_pattern: RegEx

var _source: Node3D
var _runtime_bounds := Rect2()
var _runtime_mode := false
var _camera: Camera3D
var _mesher: RefCounted
var _shader_material: ShaderMaterial
var _crease_shader: Shader
var _active_crease_variant := false
# "smooth|" or "creases|" plus the applied custom-code key: the shader in use.
var _active_shader_key := ""
# Custom fragment code requested by the materials, the request the shader was
# last generated for, and the entries that compiled into the current shader.
var _hook_spec_pending: Array = []
var _hook_key_pending := ""
var _hook_spec_applied: Array = []
var _hook_key_applied := ""
var _hook_spec_bound: Array = []
var _hook_rebuild_serial := 0
var _materials: Array[StrataMaterial] = []
var _watched_materials: Array[StrataMaterial] = []
var _material_refresh_queued := false
var _patches: Dictionary = {}
var _mesh_cache: Dictionary = {}
var _mesh_triangles: Dictionary = {}
var _patch_state: Dictionary = {}
var _patch_pool: Array[MeshInstance3D] = []
# Region state: the spec in effect, the CPU region of every grid index, one Texture2DArray
# per map (a layer per grid index) and the table texel per region. See set_regions().
var _region_spec: Dictionary = {}
var _regions: Dictionary = {}
var _region_layers: Dictionary = {}
var _region_arrays: Dictionary = {}
var _region_table_image: Image
var _region_table_texture: ImageTexture
var _window_cache: Dictionary = {}
# Aliases of the region arrays, kept for tests and tools that compare texture identity.
var _height_texture: Texture2DArray
var _control_ids_texture: Texture2DArray
var _control_weights_texture: Texture2DArray
var _hole_texture: Texture2DArray
var _macro_texture: Texture2DArray
# Transitional whole-terrain inputs of the image adapters (set_compiled_field, set_control_maps,
# set_hole_image, set_macro_map); regions are sliced from them. Null after set_regions().
var _height_image: Image
var _compiled_input: Dictionary = {}
var _hole_image: Image
var _control_ids: Image
var _control_weights: Image
var _macro_image: Image
var _macro_bounds := Rect2()
var _controls_resampled := false
var _holes_enabled := false
var _macro_enabled := false
var _ownership_texture: ImageTexture
var _channel_preview_texture: ImageTexture
var _triangle_height_sampling := false
var _height_spacing := 1.0
var _render_bounds := Rect2()
var _height_min := 0.0
var _height_max := 0.0
var _bound_displacement_multiplier := 1.0
var _last_camera := Vector2(INF, INF)
var _last_projection_scale := -1.0
var _last_refinement_active := false
var _refinement_warning_emitted := false
var _lod_settings_dirty := false
var _pending_plan_stats: Dictionary = {}
var _owns_preview_disable := false
var _owns_wireframe := false
var _previous_debug_draw := Viewport.DEBUG_DRAW_DISABLED
var _stats := {"patches": 0, "triangles": 0, "mesh_cache_entries": 0, "lod_updates": 0, "last_lod_cpu_ms": 0.0, "process_cpu_ms": 0.0, "lod_updated_this_frame": false, "height_refresh_cpu_ms": 0.0, "height_resolution": Vector2i.ZERO, "material_count": 0, "binding_backend": "direct Texture2D[32]", "control_resolution": Vector2i.ZERO, "max_discarded_weight": 0.0, "discarded_diagnostic": "sampled control-cell midpoints; not a worst-case bound", "base_patch_count": 0, "refinement_patch_count": 0, "refinement_supported": false, "refinement_active": false, "refinement_limited": false, "refinement_effective_vertex_spacing": 0.0, "refinement_requested_vertex_spacing": 0.0625, "refinement_selection_radius": 0.0, "refinement_guard_band": 0.0, "refinement_status": "Not configured"}

func configure(source: StrataTerrain3D, materials: Array[StrataMaterial], height_spacing: float = 1.0, compiled: Dictionary = {}) -> bool:
	return _configure(source, materials, height_spacing, compiled, source.base_bounds if is_instance_valid(source) else Rect2(), false)

## Compiled-only runtime path: no authoring layers or Houdini session required.
func configure_runtime(source: Node3D, data: StrataRuntimeData, materials: Array[StrataMaterial]) -> bool:
	if data == null or not data.validate().get("ok", false) or not data.is_resident(): return false
	if render_settings == null: render_settings = data.get("render_settings") if data.get("render_settings") != null else StrataRenderSettings.new()
	var input := _runtime_region_input(data, materials.size())
	if input.is_empty(): return false
	return _configure(source, materials, data.get_spacing(), {}, data.bounds, true, input)

## The region spec (shader maps only) and the region set of the whole grid of a runtime
## manifest, or {} after a warning. Material ids are checked against the pool size.
func _runtime_region_input(data: StrataRuntimeData, material_count: int) -> Dictionary:
	var spec := data.get_spec().duplicate(true)
	var maps := {}
	for name in spec.maps:
		if _SHADER_MAPS.has(name): maps[name] = spec.maps[name]
	spec.maps = maps
	var regions := {}
	var grid := data.grid
	for y in range(grid.y):
		for x in range(grid.x):
			var region := data.get_region(Vector2i(x, y))
			if region == null:
				push_warning("Runtime region (%d, %d) is unavailable; renderer not configured." % [x, y])
				return {}
			regions[Vector2i(x, y)] = region
	if maps.has(StrataRegions.MAP_MATERIAL_IDS) and maps.has(StrataRegions.MAP_MATERIAL_WEIGHTS):
		var native := ClassDB.class_has_method(&"StrataLayerData", &"prepare_control_maps")
		for region: StrataRegionData in regions.values():
			var ids := region.get_image(StrataRegions.MAP_MATERIAL_IDS, 0)
			var weights := region.get_image(StrataRegions.MAP_MATERIAL_WEIGHTS, 0)
			if ids == null or weights == null: return {}
			if native:
				var checked: Dictionary = ClassDB.class_call_static(&"StrataLayerData", &"prepare_control_maps", ids, weights, material_count)
				if not checked.get("ok", false):
					push_warning("Region %s: %s" % [region.region, checked.get("message", "invalid material controls")])
					return {}
			elif not _validate_control_images(ids, weights, material_count):
				return {}
	return {"spec": spec, "regions": regions}

func _bounds_for_source() -> Rect2:
	return _runtime_bounds if _runtime_mode else (_source as StrataTerrain3D).base_bounds

static func _valid_transform(source: Node3D) -> bool:
	var basis := source.global_basis
	return source.global_transform.is_finite() and basis.x.is_equal_approx(Vector3(basis.x.x, 0.0, basis.x.z).normalized()) and basis.y.is_equal_approx(Vector3.UP) and basis.z.is_equal_approx(Vector3(basis.z.x, 0.0, basis.z.z).normalized()) and absf(basis.determinant() - 1.0) < 0.0001

## [param region_input] ({spec, regions}) binds a region set instead of a heightfield.
func _configure(source: Node3D, materials: Array[StrataMaterial], height_spacing: float, compiled: Dictionary, bounds: Rect2, runtime_mode: bool, region_input: Dictionary = {}) -> bool:
	var device := RenderingServer.get_rendering_device()
	if device == null or RenderingServer.get_current_rendering_method() != "forward_plus":
		push_error("Terrain renderer experiment requires a real Forward+ RenderingDevice.")
		return false
	var texture_limit := device.limit_get(RenderingDevice.LIMIT_MAX_TEXTURES_PER_SHADER_STAGE)
	var sampler_limit := device.limit_get(RenderingDevice.LIMIT_MAX_SAMPLERS_PER_SHADER_STAGE)
	if texture_limit < 256 or sampler_limit < 256:
		push_error("Prototype direct-material backend conservatively requires 256 per-stage texture/sampler bindings, reserving room for engine bindings; device reports %d/%d. No alternate texture layout is selected automatically." % [texture_limit, sampler_limit])
		return false
	_stats.texture_limit_per_stage = texture_limit
	_stats.sampler_limit_per_stage = sampler_limit
	if not is_instance_valid(source) or get_parent() != source or not _valid_transform(source):
		push_error("Renderer must be an identity child of a terrain with translation/yaw and unit scale.")
		return false
	if not transform.is_equal_approx(Transform3D.IDENTITY):
		push_error("Terrain renderer requires identity local transform.")
		return false
	if not is_finite(height_spacing) or height_spacing <= 0.0 or materials.is_empty() or materials.size() > 32:
		push_error("Renderer requires positive height spacing and one to 32 materials.")
		return false
	if not _validate_lod_parameters(bounds) or region_input.is_empty() and _height_dimensions(bounds, height_spacing) == Vector2i.ZERO:
		return false
	for material in materials:
		if not _valid_material(material):
			push_error("Terrain material UV/triplanar/displacement/height-blend parameters are invalid.")
			return false
	if region_input.is_empty() and _control_ids != null and not _validate_control_images(_control_ids, _control_weights, materials.size()):
		return false
	if not ClassDB.class_exists("StrataMesher"):
		push_error("Native StrataMesher is unavailable; rebuild the standalone extension.")
		return false
	var candidate_mesher: RefCounted = ClassDB.instantiate("StrataMesher")
	if _refinement_requested() and not candidate_mesher.has_method("select_refined_patches"):
		_stats.refinement_supported = false
		_stats.refinement_status = "Native refinement unavailable: rebuild the terrain extension or disable Displacement Refinement Enabled."
		push_error(_stats.refinement_status)
		return false
	var previous := {"active_crease_variant": _active_crease_variant, "active_shader_key": _active_shader_key, "hook_spec_applied": _hook_spec_applied, "hook_key_applied": _hook_key_applied, "hook_spec_bound": _hook_spec_bound, "source": _source, "runtime_mode": _runtime_mode, "runtime_bounds": _runtime_bounds, "spacing": _height_spacing, "materials": _materials, "mesher": _mesher, "shader": _shader_material, "bound_multiplier": _bound_displacement_multiplier, "compiled": _compiled_input, "stats": _stats.duplicate(true), "hole_image": _hole_image, "macro_image": _macro_image, "macro_bounds": _macro_bounds, "holes_enabled": _holes_enabled, "macro_enabled": _macro_enabled, "control_ids": _control_ids, "control_weights": _control_weights}
	_source = source
	_runtime_mode = runtime_mode
	_runtime_bounds = bounds
	_height_spacing = height_spacing
	_compiled_input = compiled
	_materials = materials.duplicate()
	_mesher = candidate_mesher
	_shader_material = ShaderMaterial.new()
	_shader_material.shader = load(SURFACE_SHADER_PATH)
	_active_crease_variant = false
	_active_shader_key = "smooth|"
	_hook_spec_bound = []
	_shader_material.set_shader_parameter("field_origin", bounds.position)
	_shader_material.set_shader_parameter("field_size", bounds.size)
	# A new material starts without holes or terrain macro; the maps are set again after it.
	_hole_image = null; _macro_image = null; _holes_enabled = false; _macro_enabled = false
	_bind_region_uniforms()
	_bind_material_pool()
	_apply_hook_spec()
	_update_material_settings()
	var empty_ownership := Image.create(1, 1, false, Image.FORMAT_RF)
	_ownership_texture = ImageTexture.create_from_image(empty_ownership)
	_shader_material.set_shader_parameter("ownership_field", _ownership_texture)
	_shader_material.set_shader_parameter("show_ownership", false)
	_triangle_height_sampling = not compiled.is_empty() or not region_input.is_empty()
	_shader_material.set_shader_parameter("triangle_height_sampling", _triangle_height_sampling)
	if not region_input.is_empty():
		_control_ids = null; _control_weights = null
	elif _control_ids == null:
		_make_control_fixture()
	if not (set_regions(region_input.spec, region_input.regions) if not region_input.is_empty() else refresh_heightfield()):
		_source = previous.source
		_runtime_mode = previous.runtime_mode
		_runtime_bounds = previous.runtime_bounds
		_height_spacing = previous.spacing
		_materials = previous.materials
		_mesher = previous.mesher
		_shader_material = previous.shader
		_active_crease_variant = previous.active_crease_variant
		_active_shader_key = previous.active_shader_key
		_hook_spec_applied = previous.hook_spec_applied
		_hook_key_applied = previous.hook_key_applied
		_hook_spec_bound = previous.hook_spec_bound
		_bound_displacement_multiplier = previous.bound_multiplier
		_compiled_input = previous.compiled
		_stats = previous.stats
		_hole_image = previous.hole_image; _macro_image = previous.macro_image; _macro_bounds = previous.macro_bounds
		_holes_enabled = previous.holes_enabled; _macro_enabled = previous.macro_enabled
		_control_ids = previous.control_ids; _control_weights = previous.control_weights
		_bind_region_uniforms()
		_update_material_settings()
		return false
	if not _runtime_mode:
		_owns_preview_disable = _owns_preview_disable or (_source as StrataTerrain3D).is_preview_enabled()
		(_source as StrataTerrain3D).set_preview_enabled(false)
	_watch_materials()
	set_process(true)
	return true

## Bind an already compiled native/baked RF field without scanning millions of
## pixels in GDScript. The compiler owns finite-value/extrema validation.
func configure_compiled_field(source: StrataTerrain3D, materials: Array[StrataMaterial], compiled: Dictionary) -> bool:
	if render_settings == null and is_instance_valid(source): render_settings = source.render_settings
	var resolution: Vector2i = compiled.get("resolution", Vector2i.ZERO)
	var spacing := float(compiled.get("sample_step_x", Vector3.RIGHT).length())
	if resolution.x < 2 or resolution.y < 2: return false
	return configure(source, materials, spacing, compiled)

func _ready() -> void:
	if wireframe:
		_apply_wireframe_state()

func _enter_tree() -> void:
	if _shader_material != null:
		_watch_materials()
		_material_changed()
	if not _runtime_mode and _shader_material != null and is_instance_valid(_source) and get_parent() == _source:
		_owns_preview_disable = (_source as StrataTerrain3D).is_preview_enabled()
		(_source as StrataTerrain3D).set_preview_enabled(false)
	if wireframe:
		_apply_wireframe_state()

func _apply_wireframe_state() -> void:
	if wireframe:
		if not _owns_wireframe:
			_previous_debug_draw = get_viewport().debug_draw
			_owns_wireframe = true
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
	elif _owns_wireframe:
		if get_viewport().debug_draw == Viewport.DEBUG_DRAW_WIREFRAME:
			get_viewport().debug_draw = _previous_debug_draw
		_owns_wireframe = false

func _exit_tree() -> void:
	_unwatch_materials()
	if _owns_preview_disable and is_instance_valid(_source) and not (_source as StrataTerrain3D).is_preview_enabled():
		(_source as StrataTerrain3D).set_preview_enabled(true)
	if _owns_wireframe and get_viewport().debug_draw == Viewport.DEBUG_DRAW_WIREFRAME:
		get_viewport().debug_draw = _previous_debug_draw
	_owns_preview_disable = false
	_owns_wireframe = false

func set_camera(camera: Camera3D) -> void:
	if _camera == camera: return
	_camera = camera
	_last_camera = Vector2(INF, INF)
	if _shader_material != null:
		force_lod_update()

func _process(_delta: float) -> void:
	var started := Time.get_ticks_usec()
	_stats.lod_updated_this_frame = false
	_stats.process_cpu_ms = 0.0
	if not is_instance_valid(_source) or not is_instance_valid(_camera) or _shader_material == null:
		return
	var local_camera := _source.to_local(_camera.global_position)
	if not local_camera.is_finite():
		return
	_shader_material.set_shader_parameter("camera_position", local_camera)
	if _refinement_requested() and _mesher != null and not _mesher.has_method("select_refined_patches") and _refinement_warning_emitted and not _lod_settings_dirty: return
	if _lod_settings_dirty or not _last_camera.is_finite() or _last_camera.distance_to(Vector2(local_camera.x, local_camera.z)) >= _camera_update_threshold(_render_bounds) or _last_refinement_active != _refinement_zone_active() or not is_equal_approx(_last_projection_scale, _projection_scale()):
		_stats.lod_updated_this_frame = force_lod_update()
	_stats.process_cpu_ms = (Time.get_ticks_usec() - started) / 1000.0

static func _valid_material(material: StrataMaterial) -> bool:
	return material != null and is_finite(material.uv_scale) and material.uv_scale > 0.0 and is_finite(material.triplanar_sharpness) and material.triplanar_sharpness >= 1.0 and material.triplanar_sharpness <= 64.0 and is_finite(material.displacement_strength) and material.displacement_strength >= 0.0 and is_finite(material.height_blend_contrast) and material.height_blend_contrast >= 0.0 and material.height_blend_contrast <= 16.0 and is_finite(material.height_blend_bias) and material.height_blend_bias >= -0.5 and material.height_blend_bias <= 0.5

func _unwatch_materials() -> void:
	for material in _watched_materials:
		if material.changed.is_connected(_material_changed): material.changed.disconnect(_material_changed)
	_watched_materials.clear()

func _watch_materials() -> void:
	_unwatch_materials()
	for material in _materials:
		if material != null and not _watched_materials.has(material):
			_watched_materials.append(material)
			material.changed.connect(_material_changed)

func _material_changed() -> void:
	if _material_refresh_queued: return
	_material_refresh_queued = true
	_refresh_materials_deferred.call_deferred()

func _refresh_materials_deferred() -> void:
	_material_refresh_queued = false
	if not is_inside_tree() or _shader_material == null: return
	for material in _materials:
		if not _valid_material(material):
			push_warning("Invalid material edit; previous terrain bindings retained.")
			return
	_bind_material_pool()
	if _hook_key_pending != _hook_key_applied:
		if Engine.is_editor_hint(): _schedule_hook_rebuild()
		else: _apply_hook_spec()
	_update_material_settings()
	_stats.material_binding_updates = int(_stats.get("material_binding_updates", 0)) + 1

func _bind_material_pool() -> void:
	var colors: Array[Texture2D] = []
	var normals: Array[Texture2D] = []
	var packed: Array[Texture2D] = []
	var scales := PackedFloat32Array()
	var sharpnesses := PackedFloat32Array()
	var displacements := PackedFloat32Array()
	var contrasts := PackedFloat32Array()
	var biases := PackedFloat32Array()
	var roughness_scales := PackedFloat32Array()
	var roughness_biases := PackedFloat32Array()
	_bound_displacement_multiplier = 1.0
	var default_color := _solid_texture(Color(0.25, 0.35, 0.18, 1.0))
	var default_normal := _solid_texture(Color(0.5, 0.5, 1.0, 1.0))
	var default_ormh := _solid_texture(Color(1.0, 0.85, 0.0, 0.5))
	for index in range(32):
		var source := _materials[index] if index < _materials.size() and _materials[index] != null else StrataMaterial.new()
		colors.append(source.color_texture if source.color_texture != null else default_color)
		normals.append(source.normal_texture if source.normal_texture != null else default_normal)
		packed.append(source.ormh_texture if source.ormh_texture != null else default_ormh)
		scales.append(maxf(0.001, source.uv_scale))
		sharpnesses.append(source.triplanar_sharpness)
		displacements.append(maxf(0.0, source.displacement_strength))
		contrasts.append(source.height_blend_contrast)
		biases.append(source.height_blend_bias)
		roughness_scales.append(float(source.get("roughness_scale")) if "roughness_scale" in source else 1.0)
		roughness_biases.append(float(source.get("roughness_bias")) if "roughness_bias" in source else 0.0)
		_bound_displacement_multiplier = maxf(_bound_displacement_multiplier, displacements[-1])
	_shader_material.set_shader_parameter("color_maps", colors)
	_shader_material.set_shader_parameter("normal_maps", normals)
	_shader_material.set_shader_parameter("ormh_maps", packed)
	_shader_material.set_shader_parameter("uv_scales", scales)
	_shader_material.set_shader_parameter("triplanar_sharpnesses", sharpnesses)
	_shader_material.set_shader_parameter("material_displacement", displacements)
	_shader_material.set_shader_parameter("height_blend_contrasts", contrasts)
	_shader_material.set_shader_parameter("height_blend_biases", biases)
	_shader_material.set_shader_parameter("material_roughness_scales", roughness_scales)
	_shader_material.set_shader_parameter("material_roughness_biases", roughness_biases)
	_stats.material_count = _materials.size()
	_hook_spec_pending = _material_hook_spec()
	_hook_key_pending = "" if _hook_spec_pending.is_empty() else var_to_str(_hook_spec_pending.map(func(entry: Dictionary) -> Array: return [entry.id, entry.code, entry.parameters.map(func(parameter: Dictionary) -> Array: return [parameter.name, parameter.type])]))
	_bind_hook_parameters()

static func _solid_texture(color: Color) -> ImageTexture:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)

func _update_shading_variant() -> void:
	var wants_creases := smooth_shading and crease_angle_degrees < 180.0
	var key := ("creases|" if wants_creases else "smooth|") + _hook_key_applied
	if key == _active_shader_key: return
	var target := _surface_shader(wants_creases)
	# Rebinding happens only on explicit variant or custom-code changes, never
	# per frame. Uniforms the target lacks (removed custom parameters) are dropped.
	var target_names := {}
	for uniform in target.get_shader_uniform_list(): target_names[uniform.name] = true
	var parameters := {}
	var dropped: Array[String] = []
	for uniform in _shader_material.shader.get_shader_uniform_list():
		if target_names.has(uniform.name): parameters[uniform.name] = _shader_material.get_shader_parameter(uniform.name)
		elif String(uniform.name).begins_with("strata_material_"): dropped.append(uniform.name)
	_shader_material.shader = target
	for name in parameters: _shader_material.set_shader_parameter(name, parameters[name])
	for name in dropped: _shader_material.set_shader_parameter(name, null)
	_active_crease_variant = wants_creases
	_active_shader_key = key
	_bind_hook_parameters()

## The plain shader file, its cached crease variant, or a shader generated for
## the applied custom fragment code. Code that does not compile is reported per
## material and left out; if nothing compiles the plain shader is used.
func _surface_shader(creases: bool) -> Shader:
	_hook_spec_bound = []
	var failed_ids := PackedInt32Array()
	_stats.custom_shader_material_ids = PackedInt32Array()
	_stats.custom_shader_failed_ids = failed_ids
	if not _hook_spec_applied.is_empty():
		var entries := _hook_spec_applied
		var shader := _compiled_shader(_hook_shader_code(entries, creases))
		if shader == null:
			entries = []
			for entry: Dictionary in _hook_spec_applied:
				if _compiled_shader(_hook_shader_code([entry], creases)) != null:
					entries.append(entry)
				else:
					failed_ids.append(entry.id)
					push_error("%s: custom_fragment_code does not compile, so this material renders without it. The SHADER ERROR printed above (when this code was first compiled) gives the reason." % entry.label)
			_stats.custom_shader_failed_ids = failed_ids
			if not entries.is_empty():
				shader = _compiled_shader(_hook_shader_code(entries, creases))
				if shader == null:
					push_error("The custom_fragment_code of materials %s compiles separately but not together; the terrain uses its plain shader." % ", ".join(entries.map(func(entry: Dictionary) -> String: return entry.label)))
		if shader != null:
			_hook_spec_bound = entries
			_stats.custom_shader_material_ids = PackedInt32Array(entries.map(func(entry: Dictionary) -> int: return entry.id))
			return shader
	if not creases:
		return load(SURFACE_SHADER_PATH)
	if _crease_shader == null:
		_crease_shader = Shader.new()
		var base_shader: Shader = load(SURFACE_SHADER_PATH)
		var code := base_shader.code
		# A generated wrapper shares the entire source. Absolute include paths
		# are required because this cached Shader has no separate source file.
		code = code.replace('#include "', '#include "res://addons/strata/shaders/')
		_crease_shader.code = "#define HEGO_TERRAIN_CREASES\n" + code
	return _crease_shader

static func _compiled_shader(code: String) -> Shader:
	if _generated_shaders.has(code): return _generated_shaders[code]
	var shader := Shader.new()
	shader.code = code
	# Godot reports no compile status; a failed spatial shader has no uniforms,
	# while every terrain shader declares many.
	var compiled: Shader = shader if not code.is_empty() and not shader.get_shader_uniform_list().is_empty() else null
	if _generated_shaders.size() >= 32: _generated_shaders.erase(_generated_shaders.keys()[0])
	_generated_shaders[code] = compiled
	return compiled

## The plain shader source with STRATA_MATERIAL_HOOKS defined and its marker
## replaced by one function per material plus constant-ID dispatch, in the
## style of terrain_texture_dispatch.gdshaderinc.
static func _hook_shader_code(entries: Array, creases: bool) -> String:
	var base_shader: Shader = load(SURFACE_SHADER_PATH)
	var code := base_shader.code.replace('#include "', '#include "res://addons/strata/shaders/')
	var marker := code.find("\n" + _HOOK_MARKER + "\n")
	if marker < 0:
		push_error("terrain_surface.gdshader has no %s line; custom fragment code is ignored." % _HOOK_MARKER)
		return ""
	var block := PackedStringArray(['#include "res://addons/strata/shaders/terrain_material_hooks.gdshaderinc"'])
	var has_cases := ""
	var call_cases := ""
	for entry: Dictionary in entries:
		for parameter: Dictionary in entry.parameters:
			block.append("uniform %s %s%s;" % [parameter.glsl, parameter.uniform, " : source_color" if parameter.type == "color" else ""])
		block.append("// custom_fragment_code of material ID %d" % entry.id)
		block.append("void strata_material_%d(inout StrataSurface s, in StrataContext c) {" % entry.id)
		for parameter: Dictionary in entry.parameters:
			block.append("\t%s %s = %s;" % [parameter.glsl, parameter.name, parameter.uniform])
		block.append(entry.code)
		block.append("}")
		has_cases += "\t\tcase %d: return true;\n" % entry.id
		call_cases += "\t\tcase %d: strata_material_%d(s, c); break;\n" % [entry.id, entry.id]
	block.append("bool strata_material_has_hook(int id) {\n\tswitch (id) {\n%s\t}\n\treturn false;\n}" % has_cases)
	block.append("void strata_material_hook(int id, inout StrataSurface s, in StrataContext c) {\n\tswitch (id) {\n%s\t}\n}" % call_cases)
	code = code.substr(0, marker + 1) + "\n".join(block) + code.substr(marker + 1 + _HOOK_MARKER.length())
	return "#define STRATA_MATERIAL_HOOKS\n" + ("#define HEGO_TERRAIN_CREASES\n" if creases else "") + code

## The custom fragment code of the current materials, by material ID. Invalid
## parameter entries are reported and left out.
func _material_hook_spec() -> Array:
	var spec := []
	for id in range(_materials.size()):
		var material := _materials[id]
		if material == null or material.custom_fragment_code.strip_edges().is_empty(): continue
		var label := "%s (material ID %d)" % [material.resource_path if not material.resource_path.is_empty() else "Unsaved StrataMaterial", id]
		var keys := material.custom_fragment_parameters.keys()
		keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
		var parameters := []
		var seen := {}
		for key: Variant in keys:
			var name := str(key)
			var type := _hook_parameter_type(material.custom_fragment_parameters[key])
			if type.is_empty() or not _valid_hook_parameter_name(name) or seen.has(name):
				push_warning("%s: custom fragment parameter \"%s\" is ignored. Names are unique snake_case GLSL identifiers other than s, c, keywords and strata_*; values are float, int, bool, Vector2, Vector3, Vector4 or Color." % [label, name])
				continue
			seen[name] = true
			# The material ID prefix keeps every name distinct from the plain
			# shader's uniforms (none start with strata_) and from other materials.
			parameters.append({"name": name, "key": key, "type": type, "glsl": "vec4" if type == "color" else type, "uniform": "strata_material_%d_%s" % [id, name]})
		spec.append({"id": id, "code": material.custom_fragment_code, "parameters": parameters, "label": label})
	return spec

static func _hook_parameter_type(value: Variant) -> String:
	match typeof(value):
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_VECTOR2: return "vec2"
		TYPE_VECTOR3: return "vec3"
		TYPE_VECTOR4: return "vec4"
		TYPE_COLOR: return "color"
	return ""

static func _valid_hook_parameter_name(name: String) -> bool:
	if _hook_name_pattern == null:
		_hook_name_pattern = RegEx.create_from_string("^[a-z][a-z0-9_]*$")
	return _hook_name_pattern.search(name) != null and not name.begins_with("strata_") and not name.begins_with("gl_") and not _RESERVED_HOOK_NAMES.has(name)

func _apply_hook_spec() -> void:
	_hook_spec_applied = _hook_spec_pending
	_hook_key_applied = _hook_key_pending

func _schedule_hook_rebuild() -> void:
	_hook_rebuild_serial += 1
	if is_inside_tree():
		get_tree().create_timer(_HOOK_REBUILD_DELAY).timeout.connect(_rebuild_hooks_after_edit.bind(_hook_rebuild_serial))

func _rebuild_hooks_after_edit(serial: int) -> void:
	if serial != _hook_rebuild_serial or _shader_material == null: return
	_apply_hook_spec()
	_update_material_settings()

## Uploads custom parameter values for the code compiled into the current
## shader. A value whose type changed waits for the regenerated shader.
func _bind_hook_parameters() -> void:
	if _shader_material == null: return
	for entry: Dictionary in _hook_spec_bound:
		var id: int = entry.id
		if id >= _materials.size() or _materials[id] == null: continue
		var values := _materials[id].custom_fragment_parameters
		for parameter: Dictionary in entry.parameters:
			var value: Variant = values.get(parameter.key)
			if value != null and _hook_parameter_type(value) == parameter.type:
				_shader_material.set_shader_parameter(parameter.uniform, value)

func _update_material_settings() -> void:
	if _shader_material == null:
		return
	_update_shading_variant()
	_shader_material.set_shader_parameter("smooth_shading", smooth_shading)
	_shader_material.set_shader_parameter("crease_cosine", cos(deg_to_rad(crease_angle_degrees)))
	_shader_material.set_shader_parameter("debug_shading_normals", debug_shading_normals)
	_shader_material.set_shader_parameter("height_blend_enabled", height_blend_enabled)
	_shader_material.set_shader_parameter("terrain_tint_strength", render_settings.terrain_tint_strength if render_settings != null else 1.0)
	_shader_material.set_shader_parameter("terrain_ao_strength", render_settings.terrain_ao_strength if render_settings != null else 1.0)
	_shader_material.set_shader_parameter("distance_uv_enabled", distance_uv_enabled)
	_shader_material.set_shader_parameter("far_uv_factor", far_uv_factor)
	_shader_material.set_shader_parameter("uv_near_distance", uv_near_distance)
	_shader_material.set_shader_parameter("uv_far_distance", maxf(uv_far_distance, uv_near_distance + 0.01))
	_shader_material.set_shader_parameter("displacement_enabled", displacement_enabled and displacement_refinement_radius > 0.0)
	_shader_material.set_shader_parameter("displacement_radius", maxf(displacement_refinement_radius, 0.0001))
	_shader_material.set_shader_parameter("displacement_strength", maxf(displacement_strength, 0.0))
	_shader_material.set_shader_parameter("debug_lod", debug_lod)
	_shader_material.set_shader_parameter("debug_discarded", debug_discarded)
	for patch in _patches.values():
		_update_patch_bounds(patch)

func refresh_heightfield() -> bool:
	if not is_instance_valid(_source) or _shader_material == null:
		return false
	if not _compiled_input.is_empty():
		return set_compiled_field(_compiled_input)
	var started := Time.get_ticks_usec()
	var bounds := _bounds_for_source()
	var dimensions := _height_dimensions(bounds, _height_spacing)
	if dimensions.x > 2049 or dimensions.y > 2049:
		push_warning("Large terrain fields must use configure_compiled_field() with the native compiler; GDScript fallback is capped at 2049 per axis.")
		return false
	if dimensions == Vector2i.ZERO or not _validate_lod_parameters(bounds):
		return false
	var camera_position := _source.to_local(_camera.global_position) if is_instance_valid(_camera) else Vector3.ZERO
	var image := Image.create(dimensions.x, dimensions.y, false, Image.FORMAT_RF)
	var minimum := INF
	var maximum := -INF
	for z in range(dimensions.y):
		for x in range(dimensions.x):
			var point := bounds.position + bounds.size * Vector2(float(x) / (dimensions.x - 1), float(z) / (dimensions.y - 1))
			var height := (_source as StrataTerrain3D).sample_height(point)
			# RF and Color store float32, while composition returns a float64.
			var stored_height := float(Color(height, 0.0, 0.0, 1.0).r)
			if not is_finite(stored_height):
				push_warning("Invalid source height; previous heightfield and patch set retained.")
				return false
			minimum = minf(minimum, stored_height)
			maximum = maxf(maximum, stored_height)
			image.set_pixel(x, z, Color(stored_height, 0.0, 0.0, 1.0))
	var plan := _select_patch_plan(bounds, Vector2(camera_position.x, camera_position.z), Vector2(minimum, maximum))
	if plan.is_empty() or not _prepare_patch_meshes(plan): return false
	if not _install_height_image(image, bounds, _compiled_input): return false
	_shader_material.set_shader_parameter("camera_position", camera_position)
	_apply_patch_plan(plan, true)
	_stats.height_refresh_cpu_ms = (Time.get_ticks_usec() - started) / 1000.0
	return true

## Transitional adapter: binds a whole-terrain RF image by slicing it into regions. The
## image is kept as the CPU reference of the adapters (update_compiled_region, tests).
func set_compiled_field(compiled: Dictionary) -> bool:
	if _shader_material == null or not is_instance_valid(_source): return false
	var started := Time.get_ticks_usec()
	var image: Image = compiled.get("image")
	var bounds: Rect2 = compiled.get("bounds", Rect2())
	var minimum := float(compiled.get("min", NAN))
	var maximum := float(compiled.get("max", NAN))
	if not compiled.get("ok", false) or image == null or image.get_format() != Image.FORMAT_RF or image.get_width() < 2 or image.get_height() < 2 or image.get_width() > 4097 or image.get_height() > 4097 or bounds != _bounds_for_source() or not is_finite(minimum) or not is_finite(maximum) or maximum < minimum:
		push_warning("Invalid compiled RF terrain contract; previous renderer field retained.")
		return false
	var validation: Dictionary = StrataLayerData.validate_dense(image)
	if not validation.get("ok", false): return false
	minimum = float(validation.min); maximum = float(validation.max)
	var camera_position := _source.to_local(_camera.global_position) if is_instance_valid(_camera) else Vector3.ZERO
	var plan := _select_patch_plan(bounds, Vector2(camera_position.x, camera_position.z), Vector2(minimum, maximum))
	if plan.is_empty() or not _prepare_patch_meshes(plan): return false
	if not _install_height_image(image, bounds, compiled): return false
	_shader_material.set_shader_parameter("camera_position", camera_position)
	_apply_patch_plan(plan, true)
	_stats.height_refresh_cpu_ms = (Time.get_ticks_usec() - started) / 1000.0
	return true

## Swaps in a whole-terrain height image: restores the previous image, bounds and input when
## the region build fails, so a rejected field changes nothing.
func _install_height_image(image: Image, bounds: Rect2, compiled: Dictionary) -> bool:
	var previous_image := _height_image
	var previous_bounds := _render_bounds
	var previous_input := _compiled_input
	_height_image = image
	_render_bounds = bounds
	_compiled_input = compiled
	if not _sync_regions(["height"]):
		_height_image = previous_image
		_render_bounds = previous_bounds
		_compiled_input = previous_input
		return false
	_shader_material.set_shader_parameter("field_origin", bounds.position)
	_shader_material.set_shader_parameter("field_size", bounds.size)
	return true

## A brush can compile only its affected rectangle. The RF CPU image is patched natively and
## only the regions the rectangle touches (their aprons included) are uploaded, layer by layer.
func update_compiled_region(compiled: Dictionary) -> bool:
	if _height_image == null or not compiled.get("ok", false) or _region_spec.is_empty(): return false
	var patch: Image = compiled.get("image")
	if patch == null or patch.get_format() != Image.FORMAT_RF: return false
	var bounds: Rect2 = compiled.get("bounds", Rect2())
	var step := _render_bounds.size / Vector2(_height_image.get_size() - Vector2i.ONE)
	var offset := (bounds.position - _render_bounds.position) / step
	var destination := Vector2i(roundi(offset.x), roundi(offset.y))
	if not offset.is_equal_approx(Vector2(destination)) or destination.x < 0 or destination.y < 0 or destination.x + patch.get_width() > _height_image.get_width() or destination.y + patch.get_height() > _height_image.get_height(): return false
	var expected := Vector2(patch.get_size() - Vector2i.ONE) * step
	if not bounds.size.is_equal_approx(expected): return false
	var validation: Dictionary = StrataLayerData.validate_dense(patch)
	if not validation.get("ok", false): return false
	var height_description: Dictionary = _region_spec.maps.get(StrataRegions.MAP_HEIGHT, {})
	var scale := int(height_description.get("scale", 1))
	if scale != 1: return _sync_regions_after_height_patch(patch, destination)
	if not _blit_lattice_patch(StrataRegions.MAP_HEIGHT, patch, destination): return false
	var was_active := _refinement_zone_active()
	_height_image.blit_rect(patch, Rect2i(Vector2i.ZERO, patch.get_size()), destination)
	_after_height_change(was_active)
	return true

func _sync_regions_after_height_patch(patch: Image, destination: Vector2i) -> bool:
	var was_active := _refinement_zone_active()
	_height_image.blit_rect(patch, Rect2i(Vector2i.ZERO, patch.get_size()), destination)
	if not _sync_regions(["height"]): return false
	_after_height_change(was_active)
	return true

func _after_height_change(was_active: bool) -> void:
	_refresh_height_extrema()
	if not _compiled_input.is_empty(): _compiled_input.min = _height_min; _compiled_input.max = _height_max
	if was_active != _refinement_zone_active(): _invalidate_geometry_lod()
	for instance in _patches.values(): _update_patch_bounds(instance)

func set_ownership_overlay(layer: StrataLayer, channel: StringName = &"height", enabled: bool = true) -> bool:
	if _shader_material == null: return false
	_shader_material.set_shader_parameter("show_ownership", enabled)
	if not enabled: return true
	var snapshot := StrataProcedural.create_snapshot(layer, "raw", {"channels": PackedStringArray([String(channel)]), "max_samples": 40 * 1024 * 1024, "compact_empty": true})
	if not snapshot.get("ok", false):
		_shader_material.set_shader_parameter("show_ownership", false)
		return false
	var value: Dictionary = snapshot.fields[0]
	var mask: Image = snapshot.fields[1].image
	# Zero padding reproduces ownership-weighted bilinear edge support.
	var padded := Image.create(mask.get_width() + 2, mask.get_height() + 2, false, Image.FORMAT_RF)
	padded.blit_rect(mask, Rect2i(Vector2i.ZERO, mask.get_size()), Vector2i.ONE)
	_ownership_texture = ImageTexture.create_from_image(padded)
	var origin: Vector3 = value.sample_origin - value.sample_step_x - value.sample_step_y
	_shader_material.set_shader_parameter("ownership_field", _ownership_texture)
	_shader_material.set_shader_parameter("ownership_origin", Vector2(origin.x, origin.z))
	_shader_material.set_shader_parameter("ownership_step_x", Vector2(value.sample_step_x.x, value.sample_step_x.z))
	_shader_material.set_shader_parameter("ownership_step_y", Vector2(value.sample_step_y.x, value.sample_step_y.z))
	return true

## Transitional adapter: an independent endpoint-aligned terrain-local XZ image. It is
## resampled onto the region macro lattice (a straight copy when it already matches), so
## the shader addresses it through the regions like every other map.
func set_macro_map(image: Image, bounds: Rect2) -> bool:
	if _shader_material == null: return false
	if image == null:
		_macro_image = null
		_shader_material.set_shader_parameter("has_terrain_macro_map", false)
		return true
	if image.get_format() != Image.FORMAT_RGBAH or image.get_width() < 2 or image.get_height() < 2 or image.get_width() > 4097 or image.get_height() > 4097 or not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size.x <= 0.0 or bounds.size.y <= 0.0: return false
	var previous_image := _macro_image
	var previous_bounds := _macro_bounds
	_macro_image = image
	_macro_bounds = bounds
	if not _sync_regions(["macro"]):
		_macro_image = previous_image
		_macro_bounds = previous_bounds
		return false
	_bind_region_flags()
	return true

func set_channel_preview(image: Image, bounds: Rect2, enabled: bool) -> bool:
	if _shader_material == null: return false
	if enabled:
		if image == null or image.get_format() != Image.FORMAT_RF: return false
		_channel_preview_texture = ImageTexture.create_from_image(image)
		_shader_material.set_shader_parameter("channel_preview_field", _channel_preview_texture)
		_shader_material.set_shader_parameter("channel_preview_origin", bounds.position)
		_shader_material.set_shader_parameter("channel_preview_size", bounds.size)
	_shader_material.set_shader_parameter("show_channel_preview", enabled)
	return true

## Transitional adapter: one L8 texel per cell of the height lattice.
func set_hole_image(image: Image) -> bool:
	if _shader_material == null: return false
	if image == null:
		_hole_image = null
		_bind_region_flags()
		return true
	if _height_image == null or image.get_format() != Image.FORMAT_L8 or image.get_size() != _height_image.get_size() - Vector2i.ONE: return false
	var previous := _hole_image
	_hole_image = image
	if not _sync_regions(["holes"]):
		_hole_image = previous
		return false
	_bind_region_flags()
	return true

func sample_render_height(position: Vector2) -> float:
	if _region_spec.is_empty() or position.x < _render_bounds.position.x or position.y < _render_bounds.position.y or position.x > _render_bounds.end.x or position.y > _render_bounds.end.y: return 0.0
	var description: Dictionary = _region_spec.maps[StrataRegions.MAP_HEIGHT]
	var step := StrataRegions.texel_step(_region_spec, description, 0)
	var lattice_max := _lattice_max(StrataRegions.MAP_HEIGHT)
	var grid := ((position - _render_bounds.position) / step).clamp(Vector2.ZERO, Vector2(lattice_max))
	var first := Vector2i(floor(grid.x), floor(grid.y))
	var last := (first + Vector2i.ONE).min(lattice_max)
	var fraction := grid - Vector2(first)
	if _triangle_height_sampling:
		var a := _lattice_height(first)
		var b := _lattice_height(Vector2i(last.x, first.y))
		var c := _lattice_height(Vector2i(first.x, last.y))
		var d := _lattice_height(last)
		return a + (b - a) * fraction.x + (c - a) * fraction.y if fraction.x + fraction.y <= 1.0 else d + (c - d) * (1.0 - fraction.x) + (b - d) * (1.0 - fraction.y)
	return lerpf(lerpf(_lattice_height(first), _lattice_height(Vector2i(last.x, first.y)), fraction.x), lerpf(_lattice_height(Vector2i(first.x, last.y)), _lattice_height(last), fraction.x), fraction.y)

func raycast_heightfield(origin: Vector3, direction: Vector3, max_distance: float = 8000.0) -> Dictionary:
	if _region_spec.is_empty() or not is_instance_valid(_source): return {}
	var local_origin := _source.to_local(origin)
	var local_direction := (_source.global_basis.inverse() * direction).normalized()
	var box := AABB(Vector3(_render_bounds.position.x, _height_min - 1.0, _render_bounds.position.y), Vector3(_render_bounds.size.x, _height_max - _height_min + 2.0, _render_bounds.size.y))
	var entry: Variant = box.intersects_ray(local_origin, local_direction)
	if entry == null: return {}
	var distance := maxf(0.0, local_origin.distance_to(entry) - 2.0)
	var previous := distance
	for iteration in range(4096):
		var point := local_origin + local_direction * distance
		var xz := Vector2(point.x, point.z)
		if distance > max_distance: break
		if _render_bounds.has_point(xz) and point.y <= sample_render_height(xz):
			var low := previous; var high := distance
			for refine in range(16):
				var middle := (low + high) * 0.5
				var probe := local_origin + local_direction * middle
				if probe.y > sample_render_height(Vector2(probe.x, probe.z)): low = middle
				else: high = middle
			var hit := local_origin + local_direction * high
			if _holes_enabled and _cell_is_hole(Vector2(hit.x, hit.z)): return {}
			return {"position": _source.to_global(hit), "local_position": Vector2(hit.x, hit.z), "distance": high}
		previous = distance
		distance += 2.0
	return {}

static func _height_dimensions(bounds: Rect2, spacing: float) -> Vector2i:
	if not bounds.size.is_finite() or not is_finite(spacing) or spacing <= 0.0 or bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.x / spacing > 4096.0 or bounds.size.y / spacing > 4096.0:
		push_warning("Prototype height texture requires finite positive bounds/spacing and at most 4097 samples per axis; previous field retained.")
		return Vector2i.ZERO
	return Vector2i(ceili(bounds.size.x / spacing) + 1, ceili(bounds.size.y / spacing) + 1)

## IDs: RGBA8, one byte per categorical ID 0..31. Weights: RGBAF/RGBAH.
## Transitional adapter: the lattice covers the complete source bounds including both
## endpoints. When its step is the region spacing times a power of two it becomes a region
## map of that scale (a straight slice); otherwise it is resampled, see [method _adapter_plan].
func set_control_maps(ids: Image, weights: Image) -> bool:
	var previous_ids := _control_ids
	var previous_weights := _control_weights
	if not _store_control_maps(ids, weights): return false
	if not _sync_regions(["material_ids", "material_weights"]):
		_control_ids = previous_ids
		_control_weights = previous_weights
		return false
	_update_discarded_diagnostic()
	return true

func _store_control_maps(ids: Image, weights: Image) -> bool:
	if ids == null or weights == null or ids.get_size() != weights.get_size() or ids.get_width() < 2 or ids.get_height() < 2 or ids.get_width() > 1025 or ids.get_height() > 1025:
		push_warning("Control maps need matching 2..1025 dimensions; previous maps retained.")
		return false
	var prepared := _prepare_control_weights(ids, weights, _materials.size() if not _materials.is_empty() else 32)
	if prepared == null:
		return false
	_control_ids = ids.duplicate()
	_control_ids.convert(Image.FORMAT_RGBA8)
	_control_weights = prepared
	return true

## Replaces the texel rectangle at [param origin] of the maps [method set_control_maps]
## accepted with [param ids]/[param weights], a region of complete maps in the same
## formats. Only the region is validated and normalized, as set_control_maps does for every
## texel, so a brush dab costs its rectangle rather than the whole lattice. Only the region
## layers it touches are updated. False (previous maps retained) for an invalid or
## out-of-range region.
func update_control_region(ids: Image, weights: Image, origin: Vector2i) -> bool:
	if _control_ids == null or _control_weights == null: return false
	if ids == null or weights == null or ids.get_size() != weights.get_size() or ids.get_width() < 1 or ids.get_height() < 1: return false
	if origin.x < 0 or origin.y < 0 or origin.x + ids.get_width() > _control_ids.get_width() or origin.y + ids.get_height() > _control_ids.get_height(): return false
	var region_weights := _prepare_control_weights(ids, weights, _materials.size() if not _materials.is_empty() else 32)
	if region_weights == null:
		return false
	var region_ids := ids.duplicate()
	region_ids.convert(Image.FORMAT_RGBA8)
	# Before the first region build (an unconfigured renderer) only the images exist.
	if not _region_spec.get("maps", {}).has(StrataRegions.MAP_MATERIAL_IDS):
		_control_ids.blit_rect(region_ids, Rect2i(Vector2i.ZERO, ids.get_size()), origin)
		_control_weights.blit_rect(region_weights, Rect2i(Vector2i.ZERO, ids.get_size()), origin)
		return true
	# The adapter lattice of the stored images may differ from the region lattice (resampled
	# controls); those fall back to a whole-map refresh.
	if _controls_resampled:
		_control_ids.blit_rect(region_ids, Rect2i(Vector2i.ZERO, ids.get_size()), origin)
		_control_weights.blit_rect(region_weights, Rect2i(Vector2i.ZERO, ids.get_size()), origin)
		return _sync_regions(["material_ids", "material_weights"])
	if not _blit_lattice_patch(StrataRegions.MAP_MATERIAL_IDS, region_ids, origin): return false
	_blit_lattice_patch(StrataRegions.MAP_MATERIAL_WEIGHTS, region_weights, origin)
	_control_ids.blit_rect(region_ids, Rect2i(Vector2i.ZERO, ids.get_size()), origin)
	_control_weights.blit_rect(region_weights, Rect2i(Vector2i.ZERO, ids.get_size()), origin)
	return true

## Validates a control-map pair and returns its weights as RGBAF with every texel that has a
## positive sum divided by that sum (zero-sum texels untouched), or null after a warning.
## Normalization runs in double precision so finite large inputs cannot overflow the shader's
## float sum; the shader repeats it after gathering. The native StrataLayerData.prepare_control_maps
## does this in one pass; builds without it use the equivalent per-texel GDScript below.
static func _prepare_control_weights(ids: Image, weights: Image, material_count: int) -> Image:
	if ClassDB.class_has_method(&"StrataLayerData", &"prepare_control_maps"):
		var result: Dictionary = ClassDB.class_call_static(&"StrataLayerData", &"prepare_control_maps", ids, weights, material_count)
		if not result.get("ok", false):
			push_warning(String(result.get("message", "Control maps rejected; previous maps retained.")))
			return null
		return result.weights
	return _prepare_control_weights_script(ids, weights, material_count)

static func _prepare_control_weights_script(ids: Image, weights: Image, material_count: int) -> Image:
	if not _validate_control_images(ids, weights, material_count):
		return null
	var result: Image = weights.duplicate()
	result.convert(Image.FORMAT_RGBAF)
	for z in range(result.get_height()):
		for x in range(result.get_width()):
			var value := result.get_pixel(x, z)
			var total := float(value.r) + float(value.g) + float(value.b) + float(value.a)
			if total > 0.0:
				result.set_pixel(x, z, Color(value.r / total, value.g / total, value.b / total, value.a / total))
	return result

static func _validate_control_images(ids: Image, weights: Image, material_count: int) -> bool:
	if ids.get_format() != Image.FORMAT_RGBA8:
		push_warning("Control IDs must use categorical RGBA8 bytes; previous maps retained.")
		return false
	for z in range(ids.get_height()):
		for x in range(ids.get_width()):
			var pixel_ids := ids.get_pixel(x, z)
			var pixel_weights := weights.get_pixel(x, z)
			for slot in range(4):
				var id := roundi(pixel_ids[slot] * 255.0)
				if id < 0 or id >= material_count or not is_finite(pixel_weights[slot]) or pixel_weights[slot] < 0.0:
					push_warning("Control maps require valid pool IDs and finite nonnegative weights; previous maps retained.")
					return false
	return true

## Synthetic palette fixture only (a renderer configured without control maps); authoring
## layers do not yet store these maps. Each texel owns one categorical ID, so ordinary cell
## interpolation has <=4. Stored before the first region build, which slices it.
func _make_control_fixture() -> void:
	var ids := Image.create(65, 65, false, Image.FORMAT_RGBA8)
	var weights := Image.create(65, 65, false, Image.FORMAT_RGBAF)
	weights.fill(Color(1.0, 0.0, 0.0, 0.0))
	for z in range(65):
		for x in range(65):
			var id := (mini(7, x / 8) + mini(3, z / 16) * 8) % _materials.size()
			ids.set_pixel(x, z, Color(float(id) / 255.0, 0.0, 0.0, 0.0))
	_store_control_maps(ids, weights)

func _validate_lod_parameters(bounds: Rect2) -> bool:
	if not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite() or bounds.size.x <= 0.0 or bounds.size.x != bounds.size.y:
		push_warning("Renderer requires finite positive square bounds; previous patches retained.")
		return false
	if cells_per_patch < 4 or cells_per_patch > 64 or (cells_per_patch & (cells_per_patch - 1)) != 0 or not is_finite(min_patch_size) or min_patch_size <= 0.0 or not is_finite(split_ratio) or split_ratio <= 0.0 or max_patches < 1 or max_patches > 4096:
		push_warning("Renderer requires power-of-two patch cells 4..64, positive finite LOD sizes/ratio, and budget 1..4096; previous patches retained.")
		return false
	var ratio := bounds.size.x / min_patch_size
	if not is_finite(ratio) or ratio < 1.0 or ratio > 4096.0 or absf(log(ratio) / log(2.0) - round(log(ratio) / log(2.0))) > 0.000001:
		push_warning("Terrain size/minimum patch size must be a power of two with depth at most twelve; previous patches retained.")
		return false
	# Godot's default single-precision Vector/vertex/uniform fields use float32. Dyadic
	# reconstruction removes cracks, but cannot recover collapsed local vertices.
	var minimum_vertex_step := min_patch_size / float(cells_per_patch)
	if not vertex_spacing_is_representable(bounds, minimum_vertex_step):
		push_warning("Terrain-local coordinates exceed float32 vertex precision at this resolution; use a local origin or coarser patches. Previous patches retained.")
		return false
	return true

func _quality_changed() -> void:
	if render_settings == null: return
	var values := render_settings.parameters()
	var requested_cells := int(values.cells)
	if requested_cells < 4 or requested_cells > 64 or (requested_cells & (requested_cells - 1)) != 0 or not is_finite(float(values.minimum)) or float(values.minimum) <= 0 or not is_finite(float(values.ratio)) or float(values.ratio) <= 0 or int(values.budget) < 1 or int(values.budget) > 4096:
		push_warning("Invalid custom render quality; previous renderer settings retained.")
		return
	var previous: Array = [cells_per_patch, min_patch_size, split_ratio, max_patches]
	cells_per_patch = int(values.cells)
	min_patch_size = float(values.minimum)
	split_ratio = float(values.ratio)
	max_patches = int(values.budget)
	if is_instance_valid(_source) and not _validate_lod_parameters(_bounds_for_source()):
		cells_per_patch = previous[0]; min_patch_size = previous[1]; split_ratio = previous[2]; max_patches = previous[3]
		return
	distance_uv_enabled = render_settings.distance_uv_enabled
	far_uv_factor = render_settings.far_uv_factor
	uv_near_distance = render_settings.uv_near_distance
	uv_far_distance = render_settings.uv_far_distance
	displacement_refinement_enabled = render_settings.displacement_refinement_enabled
	displacement_vertex_spacing = render_settings.displacement_vertex_spacing
	displacement_refinement_radius = render_settings.displacement_refinement_radius
	displacement_refinement_budget = render_settings.displacement_refinement_budget
	_invalidate_geometry_lod()

func _projection_scale() -> float:
	if render_settings == null or not render_settings.screen_relative or not is_instance_valid(_camera): return 1.0
	var height := float(_camera.get_viewport().get_visible_rect().size.y)
	# Reference: 1080 pixels and 75 degree vertical FOV. This is a projected
	# density heuristic, not a measured terrain height-error guarantee.
	if _camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		var vertical_size := _camera.size
		if _camera.keep_aspect == Camera3D.KEEP_WIDTH:
			vertical_size *= height / maxf(float(_camera.get_viewport().get_visible_rect().size.x), 1.0)
		return clampf((height / 1080.0) * 128.0 / maxf(vertical_size, 0.01), 1.0, 3.0)
	var fov := clampf(_camera.fov, 5.0, 150.0)
	if _camera.keep_aspect == Camera3D.KEEP_WIDTH:
		var aspect := float(_camera.get_viewport().get_visible_rect().size.x) / maxf(height, 1.0)
		fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(fov) * 0.5) / maxf(aspect, 0.01)))
	return clampf(sqrt(maxf(height, 1.0) / 1080.0) * tan(deg_to_rad(75.0) * 0.5) / tan(deg_to_rad(fov) * 0.5), 1.0, 3.0)

func _invalidate_geometry_lod() -> void:
	_lod_settings_dirty = true
	_refinement_warning_emitted = false
	if is_inside_tree(): update_configuration_warnings()

func _refinement_requested() -> bool:
	return displacement_enabled and displacement_refinement_enabled

func _refinement_zone_active(height_range: Vector2 = Vector2(NAN, NAN)) -> bool:
	if not _refinement_requested() or displacement_refinement_radius <= 0.0: return false
	# Conservative cheap height cull: no base surface point can enter the shader
	# sphere outside the complete heightfield extrema. No local-slope assumption.
	if (height_range.is_finite() or _height_image != null or not _regions.is_empty()) and is_instance_valid(_source) and is_instance_valid(_camera):
		var minimum := float(height_range.x) if height_range.is_finite() else _height_min
		var maximum := float(height_range.y) if height_range.is_finite() else _height_max
		var camera_y := _source.to_local(_camera.global_position).y
		if camera_y > maximum + displacement_refinement_radius or camera_y < minimum - displacement_refinement_radius: return false
	return true

static func vertex_spacing_is_representable(bounds: Rect2, spacing: float) -> bool:
	if not is_finite(spacing) or spacing <= 0.0: return false
	var maximum_coordinate := maxf(maxf(absf(bounds.position.x), absf(bounds.position.y)), maxf(absf(bounds.end.x), absf(bounds.end.y)))
	if not is_finite(maximum_coordinate): return false
	if maximum_coordinate == 0.0: return true
	var exponent := floori(log(maximum_coordinate) / log(2.0))
	# An endpoint exactly at a power of two uses the preceding bin's ULP for
	# the adjacent interval inside the bounds. Equal-ULP dyadic grids are valid.
	if maximum_coordinate == pow(2.0, float(exponent)): exponent -= 1
	var ulp := pow(2.0, float(maxi(exponent, -126) - 23))
	return spacing >= ulp

static func refinement_target_patch_size(bounds: Rect2, cells: int, requested_spacing: float) -> float:
	if not is_finite(bounds.size.x) or bounds.size.x <= 0.0 or cells < 1 or not is_finite(requested_spacing) or requested_spacing <= 0.0: return NAN
	# Subtract logarithms to avoid overflow for finite extreme spacing values.
	var requested_depth := (log(bounds.size.x) - log(requested_spacing) - log(float(cells))) / log(2.0)
	var nearest := round(requested_depth)
	if absf(requested_depth - nearest) <= 0.000000000001: requested_depth = nearest
	var depth := clampi(ceili(requested_depth), 0, 12)
	return bounds.size.x / float(1 << depth)

func _camera_update_threshold(bounds: Rect2, active_override: Variant = null) -> float:
	var patch_size := min_patch_size
	var active := _refinement_zone_active() if active_override == null else bool(active_override)
	if active:
		# Keep the movement threshold at least as strict as the requested snapped
		# lattice even when budget pressure returns coarser leaves. The same band
		# is added to the native selection radius, not the shader fade radius.
		patch_size = minf(patch_size, refinement_target_patch_size(bounds, cells_per_patch, displacement_vertex_spacing))
	return maxf(patch_size * 0.25, 0.000001)

func get_patch_capacity() -> int:
	return mini(4096, max_patches + (displacement_refinement_budget if _refinement_requested() else 0))

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if _refinement_requested() and _mesher != null and not _mesher.has_method("select_refined_patches"):
		warnings.append("Near displacement geometry needs the updated native terrain extension. Rebuild/restart Godot, or disable displacement refinement.")
	return warnings

func _select_patch_plan(bounds: Rect2, camera_position: Vector2, height_range: Vector2 = Vector2(NAN, NAN)) -> Array:
	if not _validate_lod_parameters(bounds) or not camera_position.is_finite(): return []
	var active := _refinement_zone_active(height_range)
	var plan_stats: Dictionary = {}
	plan_stats.refinement_supported = _mesher.has_method("select_refined_patches")
	plan_stats.refinement_active = active
	plan_stats.refinement_requested_vertex_spacing = displacement_vertex_spacing
	plan_stats.refinement_radius = displacement_refinement_radius
	plan_stats.refinement_selection_radius = 0.0
	plan_stats.refinement_guard_band = 0.0
	plan_stats.refinement_limited = false
	plan_stats.refinement_depth_limited = false
	plan_stats.refinement_effective_vertex_spacing = 0.0
	plan_stats.refinement_patch_count = 0
	plan_stats.refinement_status = "Disabled" if not _refinement_requested() else "Outside the vertical displacement range"
	var plan: Array
	if _refinement_requested() and not plan_stats.refinement_supported:
		plan_stats.refinement_status = "Native refinement unavailable: rebuild the terrain extension or disable refinement."
		if not _refinement_warning_emitted:
			push_warning(plan_stats.refinement_status)
			_refinement_warning_emitted = true
		_stats.refinement_supported = false
		_stats.refinement_status = plan_stats.refinement_status
		_last_refinement_active = active
		_lod_settings_dirty = false
		return []
	if active:
		var target := refinement_target_patch_size(bounds, cells_per_patch, displacement_vertex_spacing)
		var guard := _camera_update_threshold(bounds, active)
		var selection_radius := displacement_refinement_radius + guard
		var result: Dictionary = _mesher.call("select_refined_patches", bounds, camera_position, min_patch_size, split_ratio * _projection_scale(), max_patches, target, selection_radius, displacement_refinement_budget)
		if result.is_empty():
			push_warning("Native near-displacement selection failed; previous visible patches retained.")
			return []
		plan = result.get("patches", [])
		plan_stats.base_patch_count = int(result.get("base_patch_count", 0))
		plan_stats.refinement_patch_count = int(result.get("refinement_patch_count", 0))
		plan_stats.refinement_effective_vertex_spacing = float(result.get("effective_refinement_patch_size", 0.0)) / float(cells_per_patch)
		plan_stats.refinement_selection_radius = selection_radius
		plan_stats.refinement_guard_band = guard
		plan_stats.refinement_depth_limited = target / float(cells_per_patch) > displacement_vertex_spacing * 1.000001
		plan_stats.refinement_limited = bool(result.get("refinement_limited", false)) or plan_stats.refinement_depth_limited
		plan_stats.refinement_status = "Limited by extra patch budget or depth" if plan_stats.refinement_limited else "Active"
	else:
		plan = _mesher.call("select_patches", bounds, camera_position, min_patch_size, split_ratio * _projection_scale(), max_patches)
		plan_stats.base_patch_count = plan.size()
	if plan.is_empty():
		push_warning("Native LOD selector returned no valid patches; previous visible patch set retained.")
		return []
	# Refined interior vertices can collapse before patch boundaries do. Validate
	# the actual finest selected leaf, so a coarser budget fallback remains valid.
	var finest := bounds.size.x
	for leaf in plan: finest = minf(finest, float(leaf.size))
	if not vertex_spacing_is_representable(bounds, finest / float(cells_per_patch)):
		push_warning("Refined terrain vertices exceed local float32 precision; use a local origin or coarser spacing. Previous patches retained.")
		return []
	_pending_plan_stats = plan_stats
	return plan

func _prepare_patch_meshes(plan: Array) -> bool:
	for leaf in plan:
		var key := Vector3(float(leaf.size), float(leaf.stitch_mask), float(cells_per_patch))
		if not _mesh_cache.has(key):
			var mesh: ArrayMesh = _mesher.call("build_patch", cells_per_patch, leaf.size, leaf.stitch_mask)
			if mesh == null:
				push_warning("Native patch mesh failed; previous visible patches retained.")
				return false
			_mesh_cache[key] = mesh
			_mesh_triangles[key] = mesh.surface_get_array_index_len(0) / 3
	return true

func force_lod_update() -> bool:
	if _mesher == null or not is_instance_valid(_source) or _shader_material == null:
		return false
	var started := Time.get_ticks_usec()
	var camera_position := _source.to_local(_camera.global_position) if is_instance_valid(_camera) else Vector3.ZERO
	var leaves := _select_patch_plan(_render_bounds, Vector2(camera_position.x, camera_position.z))
	_stats.last_lod_select_cpu_ms = (Time.get_ticks_usec() - started) / 1000.0
	var mesh_started := Time.get_ticks_usec()
	if leaves.is_empty() or not _prepare_patch_meshes(leaves):
		return false
	_stats.last_mesh_prepare_cpu_ms = (Time.get_ticks_usec() - mesh_started) / 1000.0
	_shader_material.set_shader_parameter("camera_position", camera_position)
	_last_camera = Vector2(camera_position.x, camera_position.z)
	_last_projection_scale = _projection_scale()
	_last_refinement_active = _refinement_zone_active()
	_lod_settings_dirty = false
	var apply_started := Time.get_ticks_usec()
	_apply_patch_plan(leaves)
	_stats.last_patch_apply_cpu_ms = (Time.get_ticks_usec() - apply_started) / 1000.0
	_stats.last_lod_cpu_ms = (Time.get_ticks_usec() - started) / 1000.0
	return true

func _apply_patch_plan(leaves: Array, refresh_bounds: bool = false) -> void:
	var keep: Dictionary = {}
	# Integer lattice keys avoid float/string formatting and stay exact for
	# fractional world origins. Release first so a teleport can reuse the same
	# bounded set of render instances without scene-tree allocation churn.
	for leaf in leaves:
		var origin: Vector2i = leaf.lattice_origin
		keep[Vector4i(origin.x, origin.y, int(leaf.lattice_span), int(leaf.lattice_units))] = leaf
	for key in _patches.keys():
		if not keep.has(key):
			var released: MeshInstance3D = _patches[key]
			released.visible = false
			_patches.erase(key)
			_patch_state.erase(key)
			if _patch_pool.size() < get_patch_capacity():
				_patch_pool.append(released)
			else:
				released.free()
	var triangles := 0
	var allocated := 0; var reused := 0; var retained := 0; var changed := 0
	var material_id := _shader_material.get_instance_id()
	for key in keep:
		var leaf: Dictionary = keep[key]
		var cache_key := Vector3(float(leaf.size), float(leaf.stitch_mask), float(cells_per_patch))
		var mesh: ArrayMesh = _mesh_cache[cache_key]
		var instance: MeshInstance3D
		var fresh := not _patches.has(key)
		if fresh:
			if _patch_pool.is_empty():
				instance = MeshInstance3D.new(); add_child(instance); allocated += 1
			else:
				instance = _patch_pool.pop_back(); reused += 1
			_patches[key] = instance
		else:
			instance = _patches[key]; retained += 1
		var state: Dictionary = {} if fresh else _patch_state[key]
		var material_changed: bool = fresh or state.get("material") != material_id
		var mesh_changed: bool = fresh or state.get("mesh") != cache_key
		var bounds_changed: bool = fresh or state.get("root_bounds") != _render_bounds
		if material_changed: instance.material_override = _shader_material
		if mesh_changed: instance.mesh = mesh; changed += 1
		if fresh or bounds_changed:
			var uv_origin := Vector2(leaf.lattice_origin) / float(leaf.lattice_units)
			var uv_scale := float(leaf.lattice_span) / float(leaf.lattice_units)
			if fresh:
				instance.set_instance_shader_parameter("patch_uv_origin", uv_origin)
				instance.set_instance_shader_parameter("patch_uv_scale", uv_scale)
				instance.set_instance_shader_parameter("patch_level", float(leaf.level))
			var start := _render_bounds.position + _render_bounds.size * uv_origin
			var end := _render_bounds.position + _render_bounds.size * (uv_origin + Vector2.ONE * uv_scale)
			instance.set_meta("terrain_patch_bounds", Rect2(start, end - start))
		if fresh or refresh_bounds or bounds_changed: _update_patch_bounds(instance)
		if fresh: instance.visible = true
		if material_changed or mesh_changed or bounds_changed:
			_patch_state[key] = {"mesh": cache_key, "material": material_id, "root_bounds": _render_bounds}
		triangles += int(_mesh_triangles[cache_key])
	while _patch_pool.size() + _patches.size() > get_patch_capacity() and not _patch_pool.is_empty(): _patch_pool.pop_back().free()
	_stats.merge(_pending_plan_stats, true)
	_last_refinement_active = bool(_stats.get("refinement_active", false))
	_stats.patches = _patches.size()
	_stats.triangles = triangles
	_stats.mesh_cache_entries = _mesh_cache.size()
	_stats.lod_updates += 1
	_stats.last_patch_allocated = allocated; _stats.last_patch_reused = reused
	_stats.last_patch_retained = retained; _stats.last_patch_mesh_changes = changed
	_stats.pooled_instances = _patch_pool.size()

func _update_patch_bounds(patch: MeshInstance3D) -> void:
	if patch.mesh == null:
		return
	var bounds: Rect2 = patch.get_meta("terrain_patch_bounds", Rect2())
	# Matches the cached uniform values, even if a source Resource is edited later.
	# Relief moves along the unit terrain normal, so on cliffs its full reach is
	# lateral; pad X/Z by the same reach as Y.
	var reach := maxf(displacement_strength, 0.0) * _bound_displacement_multiplier * 0.5
	var lateral := reach + 0.01
	var padding := reach + 0.1
	var range := _patch_height_range(bounds)
	patch.custom_aabb = AABB(Vector3(bounds.position.x - lateral, range.x - padding, bounds.position.y - lateral), Vector3(bounds.size.x + lateral * 2.0, range.y - range.x + padding * 2.0, bounds.size.y + lateral * 2.0))

## Height extrema of the resident regions a patch overlaps; the global range when no region
## data exists yet. Patches overlapping only low regions keep a tight bound when another
## region is edited.
func _patch_height_range(bounds: Rect2) -> Vector2:
	if _region_spec.is_empty() or _regions.is_empty(): return Vector2(_height_min, _height_max)
	var minimum := INF; var maximum := -INF
	for xy in StrataRegions.regions_touching(_region_spec, bounds):
		var data: StrataRegionData = _regions.get(xy)
		if data == null: continue
		minimum = minf(minimum, data.height_min); maximum = maxf(maximum, data.height_max)
	return Vector2(minimum, maximum) if is_finite(minimum) else Vector2(_height_min, _height_max)

func get_stats() -> Dictionary:
	return _stats.duplicate(true)

# ---------------------------------------------------------------------------------------
# Regions (docs/development/terrain_renderer_regions.md)
# ---------------------------------------------------------------------------------------

const _SAMPLER_UNIFORMS := {
	StrataRegions.MAP_HEIGHT: "height",
	StrataRegions.MAP_MATERIAL_IDS: "material_ids",
	StrataRegions.MAP_MATERIAL_WEIGHTS: "material_weights",
	StrataRegions.MAP_HOLES: "holes",
	StrataRegions.MAP_MACRO: "macro",
}
## Maps the shader reads: format and kind each must have.
const _SHADER_MAPS := {
	StrataRegions.MAP_HEIGHT: [[Image.FORMAT_RF], StrataRegions.KIND_SAMPLE],
	StrataRegions.MAP_MATERIAL_IDS: [[Image.FORMAT_RGBA8], StrataRegions.KIND_SAMPLE],
	StrataRegions.MAP_MATERIAL_WEIGHTS: [[Image.FORMAT_RGBA8, Image.FORMAT_RGBAF], StrataRegions.KIND_SAMPLE],
	StrataRegions.MAP_HOLES: [[Image.FORMAT_L8], StrataRegions.KIND_CELL],
	StrataRegions.MAP_MACRO: [[Image.FORMAT_RGBAH], StrataRegions.KIND_SAMPLE],
}
## Region apron per adapter map, in that map's own texels. Height needs one texel for the
## hardware filter (two keep the plan's default); the point-sampled maps read no apron.
const _ADAPTER_APRON := {
	StrataRegions.MAP_HEIGHT: 2, StrataRegions.MAP_MATERIAL_IDS: 1, StrataRegions.MAP_MATERIAL_WEIGHTS: 1,
	StrataRegions.MAP_HOLES: 1, StrataRegions.MAP_MACRO: 1,
}
const _ADAPTER_MAX_CONTROL_SCALE := 32
const _ADAPTER_MAX_MACRO_SCALE := 4
const _ADAPTER_MAX_RESAMPLE_TEXELS := 4 * 1024 * 1024
static var _placeholder_arrays := {}
static var _placeholder_table: ImageTexture

## The region spec in effect (a copy); empty before any regions exist.
func region_spec() -> Dictionary:
	return _region_spec.duplicate(true)

## The CPU region at a grid index, or null.
func get_region(xy: Vector2i) -> StrataRegionData:
	return _regions.get(xy)

## Replaces every region at once. [param spec] is a StrataRegions spec whose bounds are the
## terrain's, [param regions] maps Vector2i -> StrataRegionData for the resident regions (a
## missing one is left non-resident and renders as height 0, no holes, no material). The
## shader reads height (RF), material_ids (RGBA8), material_weights (RGBA8 or RGBAF, same
## scale and apron as the ids), holes (L8 cell map) and macro (RGBAH); other maps are
## ignored. Everything is validated and built before anything is swapped, so a rejected
## call changes nothing. Whole-image adapters (set_compiled_field and friends) replace
## regions set here, and the other way round.
func set_regions(spec: Dictionary, regions: Dictionary) -> bool:
	if _shader_material == null or not is_instance_valid(_source):
		push_warning("set_regions needs a configured renderer; nothing changed.")
		return false
	var problem := _regions_problem(spec, regions)
	if not problem.is_empty():
		push_warning("Region set rejected, previous regions retained: " + problem)
		return false
	if spec.bounds != _bounds_for_source():
		push_warning("Region set rejected, previous regions retained: spec bounds differ from the terrain bounds.")
		return false
	var state := _build_region_state(spec, regions)
	if state.is_empty(): return false
	var camera_position := _source.to_local(_camera.global_position) if is_instance_valid(_camera) else Vector3.ZERO
	var plan := _select_patch_plan(spec.bounds, Vector2(camera_position.x, camera_position.z), Vector2(state.minimum, state.maximum))
	if plan.is_empty() or not _prepare_patch_meshes(plan): return false
	_height_image = null
	_control_ids = null; _control_weights = null; _hole_image = null; _macro_image = null
	_compiled_input = {}
	_controls_resampled = false
	_render_bounds = spec.bounds
	_commit_region_state(state)
	_holes_enabled = spec.maps.has(StrataRegions.MAP_HOLES)
	_macro_enabled = spec.maps.has(StrataRegions.MAP_MACRO)
	_bind_region_flags()
	_shader_material.set_shader_parameter("field_origin", spec.bounds.position)
	_shader_material.set_shader_parameter("field_size", spec.bounds.size)
	_shader_material.set_shader_parameter("camera_position", camera_position)
	_apply_patch_plan(plan, true)
	return true

## Replaces one region's data (all of its maps) in place: layers are rewritten, the table and
## texture arrays keep their identity. False and no change for an unknown region or data that
## does not match the spec.
func update_region(xy: Vector2i, data: StrataRegionData) -> bool:
	if _region_spec.is_empty() or data == null or not _regions.has(xy) and not StrataRegions.contains_region(_region_spec, xy): return false
	var problem := _region_problem(_region_spec, xy, data)
	if not problem.is_empty():
		push_warning("Region update rejected, previous region retained: " + problem)
		return false
	var images := {}
	for name in _region_spec.maps:
		images[name] = data.get_image(name, 0)
	var layer := int(_region_layers[xy])
	var was_active := _refinement_zone_active()
	for name in images:
		(_region_arrays[name] as Texture2DArray).update_layer(images[name], layer)
	_regions[xy] = data
	if not _region_resident(xy): _set_region_resident(xy, true)
	_region_changed(xy, was_active)
	return true

## Writes [param patch] into texels of one region's map starting at [param texel_origin]
## (apron included): the CPU region and the GPU layer are patched in place. The patch must
## have the map's format and lie inside the region's map; heights must be finite.
func update_region_window(xy: Vector2i, map: String, patch: Image, texel_origin: Vector2i) -> bool:
	if not _regions.has(xy) or not _region_spec.get("maps", {}).has(map) or patch == null: return false
	var description: Dictionary = _region_spec.maps[map]
	if patch.get_format() != int(description.format) or patch.is_compressed() or patch.has_mipmaps(): return false
	var size := StrataRegions.map_size(_region_spec.cells, description, 0)
	if texel_origin.x < 0 or texel_origin.y < 0 or texel_origin.x + patch.get_width() > size.x or texel_origin.y + patch.get_height() > size.y or patch.get_width() < 1 or patch.get_height() < 1: return false
	if map == StrataRegions.MAP_HEIGHT and not bool(StrataLayerData.validate_dense(patch).get("ok", false)): return false
	return _write_region_window(xy, map, patch, texel_origin)

func _write_region_window(xy: Vector2i, map: String, patch: Image, texel_origin: Vector2i) -> bool:
	var data: StrataRegionData = _regions[xy]
	var image := data.get_image(map, 0)
	if image == null: return false
	image.blit_rect(patch, Rect2i(Vector2i.ZERO, patch.get_size()), texel_origin)
	if not data.set_image(map, image, 0): return false
	var was_active := _refinement_zone_active()
	(_region_arrays[map] as Texture2DArray).update_layer(image, int(_region_layers[xy]))
	if map == StrataRegions.MAP_HEIGHT: _recompute_region_extrema(data)
	_region_changed(xy, was_active)
	return true

func _recompute_region_extrema(data: StrataRegionData) -> void:
	var description := data.description(StrataRegions.MAP_HEIGHT)
	var apron := int(description.apron)
	var side := StrataRegions.texels_per_axis(data.cells, description, 0) + 1
	var core := data.get_image(StrataRegions.MAP_HEIGHT, 0).get_region(Rect2i(apron, apron, side, side))
	var extrema: Dictionary = StrataLayerData.validate_dense(core)
	if extrema.get("ok", false):
		data.height_min = float(extrema.min); data.height_max = float(extrema.max)

func _region_changed(xy: Vector2i, was_active: bool) -> void:
	_refresh_height_extrema()
	if was_active != _refinement_zone_active(): _invalidate_geometry_lod()
	var area := StrataRegions.region_bounds(_region_spec, xy).grow(0.001)
	for instance: MeshInstance3D in _patches.values():
		if (instance.get_meta("terrain_patch_bounds", Rect2()) as Rect2).intersects(area): _update_patch_bounds(instance)

func _region_resident(xy: Vector2i) -> bool:
	return _region_table_image != null and _region_table_image.get_pixelv(xy).a > 0.0

func _set_region_resident(xy: Vector2i, resident: bool) -> void:
	var layer := int(_region_layers[xy])
	_region_table_image.set_pixelv(xy, Color8(layer & 255, layer >> 8, 0, 255 if resident else 0))
	_region_table_texture.update(_region_table_image)

## Height extrema of the resident regions (the global range that drives refinement culling).
func _refresh_height_extrema() -> void:
	var minimum := INF; var maximum := -INF
	for data: StrataRegionData in _regions.values():
		minimum = minf(minimum, data.height_min); maximum = maxf(maximum, data.height_max)
	_height_min = minimum if is_finite(minimum) else 0.0
	_height_max = maximum if is_finite(maximum) else 0.0

## Why a region set cannot be bound, or "" when it can.
func _regions_problem(spec: Dictionary, regions: Dictionary) -> String:
	var checked := StrataRegions.validate_spec(spec)
	if not checked.ok: return String(checked.message)
	var maps: Dictionary = spec.maps
	if not maps.has(StrataRegions.MAP_HEIGHT): return "the spec has no height map"
	for name in maps:
		if not _SHADER_MAPS.has(name): continue
		var rule: Array = _SHADER_MAPS[name]
		var description: Dictionary = maps[name]
		if int(description.format) not in rule[0] or String(description.kind) != rule[1]: return "%s has an unsupported format or kind" % name
	if maps.has(StrataRegions.MAP_MATERIAL_IDS) != maps.has(StrataRegions.MAP_MATERIAL_WEIGHTS): return "material ids and weights must come together"
	if maps.has(StrataRegions.MAP_MATERIAL_IDS) and (int(maps.material_ids.get("scale", 1)) != int(maps.material_weights.get("scale", 1)) or int(maps.material_ids.get("apron", spec.apron)) != int(maps.material_weights.get("apron", spec.apron))): return "material ids and weights must share scale and apron"
	var device := RenderingServer.get_rendering_device()
	var grid := StrataRegions.grid_size(spec)
	if device != null and grid.x * grid.y > device.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_ARRAY_LAYERS): return "%d regions exceed the device's %d array layers" % [grid.x * grid.y, device.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_ARRAY_LAYERS)]
	for key in regions:
		if typeof(key) != TYPE_VECTOR2I or not StrataRegions.contains_region(spec, key): return "region %s lies outside the grid" % str(key)
		if not regions[key] is StrataRegionData: return "region %s is not a StrataRegionData" % str(key)
		var problem := _region_problem(spec, key, regions[key])
		if not problem.is_empty(): return problem
	return ""

func _region_problem(spec: Dictionary, xy: Vector2i, data: StrataRegionData) -> String:
	var label := "region %s" % str(xy)
	var checked := data.validate()
	if not checked.ok: return "%s: %s" % [label, checked.message]
	if data.region != xy or data.cells != int(spec.cells) or data.apron != int(spec.apron) or not is_equal_approx(data.spacing, float(spec.spacing)) or not data.origin.is_equal_approx(StrataRegions.region_origin(spec, xy)):
		return "%s does not match the spec geometry" % label
	for name in spec.maps:
		if not data.has_map(name) or data.level_count(name) < 1: return "%s lacks map %s" % [label, name]
		var description: Dictionary = spec.maps[name]
		var held := data.description(name)
		if int(held.format) != int(description.format) or String(held.kind) != String(description.kind) or int(held.scale) != int(description.get("scale", 1)) or int(held.apron) != int(description.get("apron", spec.apron)):
			return "%s map %s differs from the spec" % [label, name]
	return ""

## Creates the texture arrays and table for a region set without touching renderer state.
func _build_region_state(spec: Dictionary, regions: Dictionary) -> Dictionary:
	var grid := StrataRegions.grid_size(spec)
	var table := Image.create(grid.x, grid.y, false, Image.FORMAT_RGBA8)
	var layers := {}
	var minimum := INF; var maximum := -INF
	for y in range(grid.y):
		for x in range(grid.x):
			var xy := Vector2i(x, y)
			var layer := y * grid.x + x
			layers[xy] = layer
			var resident := regions.has(xy)
			table.set_pixel(x, y, Color8(layer & 255, layer >> 8, 0, 255 if resident else 0))
			if resident:
				minimum = minf(minimum, (regions[xy] as StrataRegionData).height_min)
				maximum = maxf(maximum, (regions[xy] as StrataRegionData).height_max)
	var arrays := {}
	for name in spec.maps:
		if not _SHADER_MAPS.has(name): continue
		var description: Dictionary = spec.maps[name]
		var size := StrataRegions.map_size(spec.cells, description, 0)
		var images: Array[Image] = []
		for y in range(grid.y):
			for x in range(grid.x):
				var data: StrataRegionData = regions.get(Vector2i(x, y))
				var image: Image = data.get_image(name, 0) if data != null else null
				if image == null: image = Image.create(size.x, size.y, false, int(description.format))
				images.append(image)
		var array := Texture2DArray.new()
		var error := array.create_from_images(images)
		if error != OK:
			push_warning("Region texture array for %s could not be created (error %d); previous regions retained." % [name, error])
			return {}
		arrays[name] = array
	return {"spec": spec.duplicate(true), "regions": regions.duplicate(), "layers": layers, "arrays": arrays, "table_image": table, "table_texture": ImageTexture.create_from_image(table), "minimum": minimum if is_finite(minimum) else 0.0, "maximum": maximum if is_finite(maximum) else 0.0}

func _commit_region_state(state: Dictionary) -> void:
	_region_spec = state.spec
	_regions = state.regions
	_region_layers = state.layers
	_region_arrays = state.arrays
	_region_table_image = state.table_image
	_region_table_texture = state.table_texture
	_window_cache.clear()
	_height_min = state.minimum
	_height_max = state.maximum
	_height_texture = _region_arrays.get(StrataRegions.MAP_HEIGHT)
	_control_ids_texture = _region_arrays.get(StrataRegions.MAP_MATERIAL_IDS)
	_control_weights_texture = _region_arrays.get(StrataRegions.MAP_MATERIAL_WEIGHTS)
	_hole_texture = _region_arrays.get(StrataRegions.MAP_HOLES)
	_macro_texture = _region_arrays.get(StrataRegions.MAP_MACRO)
	_bind_region_uniforms()
	var grid := StrataRegions.grid_size(_region_spec)
	var per_region := 0
	for name in _region_spec.maps:
		if _SHADER_MAPS.has(name): per_region += StrataRegions.map_bytes(_region_spec.cells, _region_spec.maps[name], 0)
	_stats.regions = _regions.size()
	_stats.region_grid = grid
	_stats.region_cells = int(_region_spec.cells)
	_stats.region_bytes = per_region
	_stats.height_resolution = _map_resolution(StrataRegions.MAP_HEIGHT)
	_stats.control_resolution = _map_resolution(StrataRegions.MAP_MATERIAL_IDS)

## Samples per axis the regions imply for a sample map (the lattice over the terrain bounds).
func _map_resolution(map: String) -> Vector2i:
	if not _region_spec.get("maps", {}).has(map): return Vector2i.ZERO
	return _lattice_max(map) + (Vector2i.ONE if String(_region_spec.maps[map].kind) == StrataRegions.KIND_SAMPLE else Vector2i.ZERO)

func _lattice_count(extent: float, step: float) -> int:
	var count := extent / step
	return roundi(count) if absf(count - roundf(count)) < 0.001 else ceili(count)

## Last sample index per axis of a map's lattice over the terrain bounds (cell maps: the
## number of cells).
func _lattice_max(map: String) -> Vector2i:
	var step := StrataRegions.texel_step(_region_spec, _region_spec.maps[map], 0)
	return Vector2i(_lattice_count(_render_bounds.size.x, step), _lattice_count(_render_bounds.size.y, step))

func _bind_region_uniforms() -> void:
	if _shader_material == null: return
	var material := _shader_material
	var spec := _region_spec
	if spec.is_empty():
		material.set_shader_parameter("region_table", _table_placeholder())
	else:
		var extent := StrataRegions.extent(spec)
		material.set_shader_parameter("region_origin", (spec.bounds as Rect2).position)
		material.set_shader_parameter("region_extent", extent)
		material.set_shader_parameter("region_spacing", float(spec.spacing))
		material.set_shader_parameter("region_cells", int(spec.cells))
		material.set_shader_parameter("region_grid", StrataRegions.grid_size(spec))
		var lattice := Vector2i(_lattice_count(_render_bounds.size.x, float(spec.spacing)), _lattice_count(_render_bounds.size.y, float(spec.spacing)))
		material.set_shader_parameter("region_lattice", lattice)
		material.set_shader_parameter("region_table", _region_table_texture)
	var layouts := [StrataRegions.MAP_HEIGHT, StrataRegions.MAP_MATERIAL_IDS, StrataRegions.MAP_HOLES, StrataRegions.MAP_MACRO]
	for name in _SAMPLER_UNIFORMS:
		var prefix: String = _SAMPLER_UNIFORMS[name]
		var array: Texture2DArray = _region_arrays.get(name)
		material.set_shader_parameter(prefix + "_regions", array if array != null else _array_placeholder(name))
		if name in layouts and spec.get("maps", {}).has(name):
			material.set_shader_parameter(prefix + "_scale", int(spec.maps[name].get("scale", 1)))
			material.set_shader_parameter(prefix + "_apron", int(spec.maps[name].get("apron", spec.apron)))
	_bind_region_flags()

## Which optional maps the shader reads. The adapters clear a flag without dropping the map.
func _bind_region_flags() -> void:
	if _shader_material == null: return
	var maps: Dictionary = _region_spec.get("maps", {})
	_shader_material.set_shader_parameter("has_material_maps", maps.has(StrataRegions.MAP_MATERIAL_IDS))
	_shader_material.set_shader_parameter("has_holes", _holes_enabled and maps.has(StrataRegions.MAP_HOLES))
	_shader_material.set_shader_parameter("has_terrain_macro_map", _macro_enabled and maps.has(StrataRegions.MAP_MACRO))

static func _array_placeholder(map: String) -> Texture2DArray:
	if not _placeholder_arrays.has(map):
		var image := Image.create(1, 1, false, int((_SHADER_MAPS[map] as Array)[0][0]))
		var array := Texture2DArray.new()
		array.create_from_images([image] as Array[Image])
		_placeholder_arrays[map] = array
	return _placeholder_arrays[map]

static func _table_placeholder() -> ImageTexture:
	if _placeholder_table == null: _placeholder_table = ImageTexture.create_from_image(Image.create(1, 1, false, Image.FORMAT_RGBA8))
	return _placeholder_table

# ---- CPU sampling over the regions ----

func _texel_bytes(map: String, xy: Vector2i) -> PackedByteArray:
	var data: StrataRegionData = _regions.get(xy)
	return data.level_bytes(map, 0) if data != null else PackedByteArray()

## Region and texel inside it for a lattice index of a sample map.
func _lattice_texel(map: String, index: Vector2i) -> Array:
	var description: Dictionary = _region_spec.maps[map]
	var per_region := StrataRegions.texels_per_axis(_region_spec.cells, description, 0)
	var grid := StrataRegions.grid_size(_region_spec)
	var xy := Vector2i(index / per_region).clamp(Vector2i.ZERO, grid - Vector2i.ONE)
	var first: Vector2i = _region_window(map, xy).first
	return [xy, index - first]

func _region_window(map: String, xy: Vector2i) -> Dictionary:
	var key := [map, xy]
	if not _window_cache.has(key): _window_cache[key] = StrataRegions.map_window(_region_spec, xy, _region_spec.maps[map], 0)
	return _window_cache[key]

func _lattice_height(index: Vector2i) -> float:
	var located := _lattice_texel(StrataRegions.MAP_HEIGHT, index)
	var bytes := _texel_bytes(StrataRegions.MAP_HEIGHT, located[0])
	if bytes.is_empty(): return 0.0
	var size: Vector2i = _region_window(StrataRegions.MAP_HEIGHT, located[0]).size
	var texel: Vector2i = located[1]
	return bytes.decode_float((texel.y * size.x + texel.x) * 4)

func _texel_color(map: String, xy: Vector2i, texel: Vector2i) -> Color:
	var bytes := _texel_bytes(map, xy)
	if bytes.is_empty(): return Color(0, 0, 0, 0)
	var size: Vector2i = _region_window(map, xy).size
	var offset := texel.y * size.x + texel.x
	match int(_region_spec.maps[map].format):
		Image.FORMAT_L8, Image.FORMAT_R8: return Color(bytes[offset] / 255.0, 0, 0, 1)
		Image.FORMAT_RGBA8: return Color(bytes[offset * 4] / 255.0, bytes[offset * 4 + 1] / 255.0, bytes[offset * 4 + 2] / 255.0, bytes[offset * 4 + 3] / 255.0)
		Image.FORMAT_RF: return Color(bytes.decode_float(offset * 4), 0, 0, 1)
		Image.FORMAT_RGBAF: return Color(bytes.decode_float(offset * 16), bytes.decode_float(offset * 16 + 4), bytes.decode_float(offset * 16 + 8), bytes.decode_float(offset * 16 + 12))
	return Color(0, 0, 0, 0)

func _cell_is_hole(position: Vector2) -> bool:
	if not _region_spec.get("maps", {}).has(StrataRegions.MAP_HOLES): return false
	var description: Dictionary = _region_spec.maps[StrataRegions.MAP_HOLES]
	var step := StrataRegions.texel_step(_region_spec, description, 0)
	var cells := _lattice_max(StrataRegions.MAP_HOLES)
	var cell := Vector2i(((position - _render_bounds.position) / step).floor()).clamp(Vector2i.ZERO, cells - Vector2i.ONE)
	var per_region := StrataRegions.texels_per_axis(_region_spec.cells, description, 0)
	var xy := Vector2i(cell / per_region).clamp(Vector2i.ZERO, StrataRegions.grid_size(_region_spec) - Vector2i.ONE)
	var first: Vector2i = _region_window(StrataRegions.MAP_HOLES, xy).first
	return _texel_color(StrataRegions.MAP_HOLES, xy, cell - first).r >= 0.5

## The shader's control blend at a terrain position, read from the regions: the CPU reference
## for what the terrain draws (IDs, normalized soft-limit weights, discarded mass).
func sample_control_blend(position: Vector2) -> Dictionary:
	var maps: Dictionary = _region_spec.get("maps", {})
	if not maps.has(StrataRegions.MAP_MATERIAL_IDS): return {"ids": PackedInt32Array([0, 0, 0, 0]), "weights": PackedFloat32Array([0, 0, 0, 0]), "discarded_weight": 0.0}
	var step := StrataRegions.texel_step(_region_spec, maps.material_ids, 0)
	var lattice_max := _lattice_max(StrataRegions.MAP_MATERIAL_IDS)
	var grid := ((position - _render_bounds.position) / step).clamp(Vector2.ZERO, Vector2(lattice_max))
	var base := Vector2i(floor(grid.x), floor(grid.y))
	var corner_ids: Array[Color] = []; var corner_weights: Array[Color] = []
	for corner in range(4):
		var located_ids := _lattice_texel(StrataRegions.MAP_MATERIAL_IDS, (base + Vector2i(corner % 2, corner / 2)).min(lattice_max))
		corner_ids.append(_texel_color(StrataRegions.MAP_MATERIAL_IDS, located_ids[0], located_ids[1]))
		corner_weights.append(_texel_color(StrataRegions.MAP_MATERIAL_WEIGHTS, located_ids[0], located_ids[1]))
	return _blend_corners(corner_ids, corner_weights, grid - Vector2(base))

# ---- Whole-image adapters: slicing into regions ----

## The region layout implied by the whole-terrain images, and the image each map slices
## from, or {} (after a warning) when it cannot be represented. The finest lattice among the
## height and control images becomes the region spacing; every other map is a power-of-two
## multiple of it. Controls whose step is no such multiple are resampled (bilinear weights,
## nearest IDs) and macro images that do not already match the lattice are resampled bilinearly
## (a transitional cost; the planned region producers write the maps directly).
func _adapter_plan() -> Dictionary:
	if _height_image == null or not _render_bounds.size.is_finite(): return {}
	var bounds := _render_bounds
	var dimensions := _height_image.get_size()
	var height_step := bounds.size.x / float(dimensions.x - 1)
	if absf(bounds.size.y / float(dimensions.y - 1) - height_step) > height_step * 0.0001:
		push_warning("Height lattice steps differ per axis; regions need a square lattice. Previous maps retained.")
		return {}
	var sources := {StrataRegions.MAP_HEIGHT: _height_image}
	var steps := {StrataRegions.MAP_HEIGHT: height_step}
	var spacing := height_step
	_controls_resampled = false
	if _control_ids != null:
		var ids := _control_ids
		var weights := _control_weights
		var control_step := bounds.size.x / float(ids.get_width() - 1)
		var aligned := absf(bounds.size.y / float(ids.get_height() - 1) - control_step) <= control_step * 0.0001
		var ratio := control_step / height_step
		if not aligned or not _is_power_of_two_ratio(ratio, 1.0 / 1024.0, float(_ADAPTER_MAX_CONTROL_SCALE)):
			# Resample onto a power-of-two multiple of the height lattice with about 1025 texels.
			var scale := 1
			while bounds.size.x / (height_step * scale) > 1025.0: scale *= 2
			control_step = height_step * scale
			var resampled := _resample_controls(ids, weights, Vector2i(Vector2(bounds.size / control_step).round()) + Vector2i.ONE)
			ids = resampled[0]; weights = resampled[1]
			_controls_resampled = true
		sources[StrataRegions.MAP_MATERIAL_IDS] = ids
		sources[StrataRegions.MAP_MATERIAL_WEIGHTS] = weights
		steps[StrataRegions.MAP_MATERIAL_IDS] = control_step
		steps[StrataRegions.MAP_MATERIAL_WEIGHTS] = control_step
		spacing = minf(spacing, control_step)
	if _hole_image != null and _hole_image.get_size() == dimensions - Vector2i.ONE:
		sources[StrataRegions.MAP_HOLES] = _hole_image
		steps[StrataRegions.MAP_HOLES] = height_step
	var scales := {}
	for name in steps: scales[name] = maxi(1, roundi(float(steps[name]) / spacing))
	var macro_scale := 1
	if _macro_image != null:
		if _macro_bounds == bounds:
			var macro_ratio := _macro_bounds.size.x / float(_macro_image.get_width() - 1) / spacing
			macro_scale = clampi(1 << maxi(0, roundi(log(maxf(macro_ratio, 1.0)) / log(2.0))), 1, _ADAPTER_MAX_MACRO_SCALE)
		else:
			# A macro map with its own extent never lies on the region lattice: resample it as
			# finely as the lattice stays near 1025 texels so its corners stay close to exact.
			while bounds.size.x / (spacing * macro_scale) > 1025.0 and macro_scale < _ADAPTER_MAX_MACRO_SCALE: macro_scale *= 2
		scales[StrataRegions.MAP_MACRO] = macro_scale
		steps[StrataRegions.MAP_MACRO] = spacing * macro_scale
	var lattice := maxi(_lattice_count(bounds.size.x, spacing), _lattice_count(bounds.size.y, spacing))
	var cells := clampi(_next_power_of_two(lattice), StrataRegions.MIN_CELLS, StrataRegions.DEFAULT_CELLS)
	var maps := {}
	for name in scales:
		var apron: int = _ADAPTER_APRON[name]
		cells = maxi(cells, _next_power_of_two(2 * int(scales[name]) * apron))
	if cells > StrataRegions.MAX_CELLS:
		push_warning("The control and height lattices differ too much to share a region size. Previous maps retained.")
		return {}
	var formats := {
		StrataRegions.MAP_HEIGHT: Image.FORMAT_RF, StrataRegions.MAP_MATERIAL_IDS: Image.FORMAT_RGBA8, StrataRegions.MAP_MATERIAL_WEIGHTS: Image.FORMAT_RGBAF,
		StrataRegions.MAP_HOLES: Image.FORMAT_L8, StrataRegions.MAP_MACRO: Image.FORMAT_RGBAH,
	}
	for name in scales:
		var kind := StrataRegions.KIND_CELL if name == StrataRegions.MAP_HOLES else StrataRegions.KIND_SAMPLE
		maps[name] = StrataRegions.map(formats[name], kind, int(scales[name]), int(_ADAPTER_APRON[name]))
	var spec := {"bounds": bounds, "spacing": spacing, "cells": cells, "apron": int(_ADAPTER_APRON[StrataRegions.MAP_HEIGHT]), "maps": maps}
	var checked := StrataRegions.validate_spec(spec)
	if not checked.ok:
		push_warning("Region layout rejected: %s. Previous maps retained." % checked.message)
		return {}
	if _macro_image != null:
		var macro := _macro_for_lattice(spec, maps[StrataRegions.MAP_MACRO])
		if macro == null: return {}
		sources[StrataRegions.MAP_MACRO] = macro
	return {"spec": spec, "sources": sources}

static func _is_power_of_two_ratio(ratio: float, minimum: float, maximum: float) -> bool:
	if not is_finite(ratio) or ratio < minimum * 0.999 or ratio > maximum * 1.001: return false
	var exponent := log(ratio) / log(2.0)
	return absf(exponent - roundf(exponent)) < 0.001

static func _next_power_of_two(value: int) -> int:
	var result := 1
	while result < value: result <<= 1
	return result

## Resamples a control pair onto a coarser or finer endpoint-aligned lattice: nearest IDs and
## bilinear weights of the source's four surrounding texels.
func _resample_controls(ids: Image, weights: Image, size: Vector2i) -> Array:
	var out_ids := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	var out_weights := Image.create(size.x, size.y, false, Image.FORMAT_RGBAF)
	var source := ids.get_size() - Vector2i.ONE
	for z in range(size.y):
		for x in range(size.x):
			var grid := Vector2(float(x) / float(maxi(size.x - 1, 1)), float(z) / float(maxi(size.y - 1, 1))) * Vector2(source)
			var base := Vector2i(floor(grid.x), floor(grid.y)).min(source - Vector2i.ONE).max(Vector2i.ZERO)
			var f := grid - Vector2(base)
			var nearest := Vector2i(grid.round()).clamp(Vector2i.ZERO, source)
			out_ids.set_pixelv(Vector2i(x, z), ids.get_pixelv(nearest))
			# Bilinear weights follow the nearest texel's ID layout only where the layouts agree.
			var nearest_ids := ids.get_pixelv(nearest)
			var accumulated := Color(0, 0, 0, 0)
			for corner in range(4):
				var texel := (base + Vector2i(corner % 2, corner / 2)).min(source)
				var corner_ids := ids.get_pixelv(texel)
				var corner_weights := weights.get_pixelv(texel)
				var bilinear := (1.0 - f.x if corner % 2 == 0 else f.x) * (1.0 - f.y if corner / 2 == 0 else f.y)
				for slot in range(4):
					for target in range(4):
						if roundi(corner_ids[slot] * 255.0) == roundi(nearest_ids[target] * 255.0):
							accumulated[target] += corner_weights[slot] * bilinear
							break
			out_weights.set_pixelv(Vector2i(x, z), accumulated)
	return [out_ids, out_weights]

## The macro image on the region lattice of its map: the image itself when it already is,
## otherwise a bilinear resample clamped to the macro bounds. Null (after a warning) when the
## resample would be too large.
func _macro_for_lattice(spec: Dictionary, description: Dictionary) -> Image:
	var step := StrataRegions.texel_step(spec, description, 0)
	var size := Vector2i(_lattice_count(spec.bounds.size.x, step), _lattice_count(spec.bounds.size.y, step)) + Vector2i.ONE
	var macro_step := _macro_bounds.size / Vector2(_macro_image.get_size() - Vector2i.ONE)
	if _macro_image.get_size() == size and _macro_bounds == spec.bounds and absf(macro_step.x - step) <= step * 0.0001 and absf(macro_step.y - step) <= step * 0.0001: return _macro_image
	if size.x * size.y > _ADAPTER_MAX_RESAMPLE_TEXELS:
		push_warning("The macro map does not match the region lattice and is too large to resample. Previous maps retained.")
		return null
	var result := Image.create(size.x, size.y, false, Image.FORMAT_RGBAH)
	var last := _macro_image.get_size() - Vector2i.ONE
	var origin: Vector2 = spec.bounds.position
	for z in range(size.y):
		for x in range(size.x):
			var grid: Vector2 = ((origin + Vector2(x, z) * step - _macro_bounds.position) / macro_step).clamp(Vector2.ZERO, Vector2(last))
			var base := Vector2i(floor(grid.x), floor(grid.y)).min(last - Vector2i.ONE).max(Vector2i.ZERO)
			var f: Vector2 = grid - Vector2(base)
			var low := _macro_image.get_pixelv(base).lerp(_macro_image.get_pixelv(base + Vector2i(1, 0)), f.x)
			var high := _macro_image.get_pixelv(base + Vector2i(0, 1)).lerp(_macro_image.get_pixelv(base + Vector2i.ONE), f.x)
			result.set_pixel(x, z, low.lerp(high, f.y))
	return result

## A window of a whole-lattice image, with texels outside the image replicating its nearest
## edge texel.
static func _slice_clamped(source: Image, first: Vector2i, size: Vector2i) -> Image:
	var result := Image.create(size.x, size.y, false, source.get_format())
	var image_rect := Rect2i(Vector2i.ZERO, source.get_size())
	var clipped := Rect2i(first, size).intersection(image_rect)
	if clipped.size.x <= 0 or clipped.size.y <= 0: return result
	var offset := clipped.position - first
	result.blit_rect(source, clipped, offset)
	# Columns first (over the clipped rows), then whole rows, so corners replicate too.
	for column in range(0, offset.x):
		result.blit_rect(result, Rect2i(offset.x, offset.y, 1, clipped.size.y), Vector2i(column, offset.y))
	for column in range(offset.x + clipped.size.x, size.x):
		result.blit_rect(result, Rect2i(offset.x + clipped.size.x - 1, offset.y, 1, clipped.size.y), Vector2i(column, offset.y))
	for row in range(0, offset.y):
		result.blit_rect(result, Rect2i(0, offset.y, size.x, 1), Vector2i(0, row))
	for row in range(offset.y + clipped.size.y, size.y):
		result.blit_rect(result, Rect2i(0, offset.y + clipped.size.y - 1, size.x, 1), Vector2i(0, row))
	return result

## Makes the regions match the whole-terrain images. [param changed] names the maps whose
## content changed: when the layout in effect already covers the new one they are rewritten
## layer by layer in place (array and table keep their identity), otherwise every region is
## rebuilt and swapped in one step. False, with nothing changed, if it cannot be built.
func _sync_regions(changed: Array) -> bool:
	if _height_image == null or _shader_material == null: return true
	var plan := _adapter_plan()
	if plan.is_empty(): return false
	var spec: Dictionary = plan.spec
	var sources: Dictionary = plan.sources
	if _layout_covers(spec):
		for name in changed:
			if not sources.has(name) or not _region_spec.maps.has(name): continue
			if not _refresh_map(name, sources[name]): return false
		_regions_refreshed(changed)
		return true
	var regions := {}
	var grid := StrataRegions.grid_size(spec)
	for y in range(grid.y):
		for x in range(grid.x):
			var data := _slice_region(spec, Vector2i(x, y), sources)
			if data == null: return false
			regions[Vector2i(x, y)] = data
	var state := _build_region_state(spec, regions)
	if state.is_empty(): return false
	_commit_region_state(state)
	_regions_refreshed(changed)
	return true

func _layout_covers(spec: Dictionary) -> bool:
	if _region_spec.is_empty(): return false
	for key in ["bounds", "spacing", "cells", "apron"]:
		if _region_spec[key] != spec[key]: return false
	for name in spec.maps:
		if not _region_spec.maps.has(name) or _region_spec.maps[name] != spec.maps[name]: return false
	return true

func _slice_region(spec: Dictionary, xy: Vector2i, sources: Dictionary) -> StrataRegionData:
	var data := StrataRegionData.new()
	data.region = xy
	data.cells = int(spec.cells)
	data.apron = int(spec.apron)
	data.spacing = float(spec.spacing)
	data.origin = StrataRegions.region_origin(spec, xy)
	for name in spec.maps:
		var description: Dictionary = spec.maps[name]
		var window := StrataRegions.map_window(spec, xy, description, 0)
		if not data.set_image(name, _slice_clamped(sources[name], window.first, window.size), 0, description):
			push_warning("Region %s could not hold map %s. Previous maps retained." % [str(xy), name])
			return null
	_recompute_region_extrema(data)
	return data

func _refresh_map(name: String, source: Image) -> bool:
	var description: Dictionary = _region_spec.maps[name]
	var array: Texture2DArray = _region_arrays.get(name)
	if array == null: return false
	for xy in _regions:
		var window := StrataRegions.map_window(_region_spec, xy, description, 0)
		var image := _slice_clamped(source, window.first, window.size)
		var data: StrataRegionData = _regions[xy]
		if not data.set_image(name, image, 0): return false
		array.update_layer(image, int(_region_layers[xy]))
		if name == StrataRegions.MAP_HEIGHT: _recompute_region_extrema(data)
	return true

func _regions_refreshed(changed: Array) -> void:
	_refresh_height_extrema()
	if changed.has(StrataRegions.MAP_HOLES): _holes_enabled = _hole_image != null
	if changed.has(StrataRegions.MAP_MACRO): _macro_enabled = _macro_image != null
	_bind_region_flags()
	if changed.has(StrataRegions.MAP_MATERIAL_IDS): _update_discarded_diagnostic()

## Writes a patch of a map's lattice into every region whose window (apron included)
## overlaps it. Patches reaching the terrain edge are extended by edge replication over the
## rest of the last region and its apron, as the initial slicing does. [param origin] is in
## the map's lattice indices. Validates the patch first; false changes nothing.
func _blit_lattice_patch(map: String, patch: Image, origin: Vector2i) -> bool:
	var maps: Dictionary = _region_spec.get("maps", {})
	if not maps.has(map) or patch == null or patch.get_format() != int(maps[map].format): return false
	if map == StrataRegions.MAP_HEIGHT and not bool(StrataLayerData.validate_dense(patch).get("ok", false)): return false
	var description: Dictionary = maps[map]
	var sample := String(description.kind) == StrataRegions.KIND_SAMPLE
	var apron := int(description.get("apron", _region_spec.apron))
	var per_region := StrataRegions.texels_per_axis(_region_spec.cells, description, 0)
	var grid := StrataRegions.grid_size(_region_spec)
	var edge := _lattice_max(map) - (Vector2i.ZERO if sample else Vector2i.ONE)
	var reach := grid * per_region + Vector2i.ONE * apron - (Vector2i.ZERO if sample else Vector2i.ONE)
	var before := Vector2i(apron if origin.x == 0 else 0, apron if origin.y == 0 else 0)
	var last := origin + patch.get_size() - Vector2i.ONE
	var after := Vector2i(reach.x - edge.x if last.x == edge.x else 0, reach.y - edge.y if last.y == edge.y else 0)
	var extended := patch
	if before != Vector2i.ZERO or after != Vector2i.ZERO:
		extended = _slice_clamped(patch, -before, patch.get_size() + before + after)
	var start := origin - before
	var step := StrataRegions.texel_step(_region_spec, description, 0)
	var area := Rect2(_render_bounds.position + Vector2(start) * step, Vector2(extended.get_size()) * step)
	for xy in StrataRegions.regions_touching(_region_spec, area, description):
		if not _regions.has(xy): continue
		var window := StrataRegions.map_window(_region_spec, xy, description, 0)
		var destination := start - Vector2i(window.first)
		var clipped := Rect2i(destination, extended.get_size()).intersection(Rect2i(Vector2i.ZERO, window.size))
		if clipped.size.x <= 0 or clipped.size.y <= 0: continue
		var piece := extended.get_region(Rect2i(clipped.position - destination, clipped.size))
		if not _write_region_window(xy, map, piece, clipped.position): return false
	return true

## CPU reference for the GLSL by-ID merge and fifth-weight soft top-four rule. CPU accumulation
## uses doubles, GPU uses floats: rankings can differ for near-tied weights.
static func blend_control_samples(ids: Image, weights: Image, position: Vector2, bounds: Rect2) -> Dictionary:
	var dimensions := ids.get_size()
	var normalized := ((position - bounds.position) / bounds.size).clamp(Vector2.ZERO, Vector2.ONE)
	var grid := normalized * Vector2(dimensions - Vector2i.ONE)
	var base := Vector2i(floor(grid.x), floor(grid.y))
	var corner_ids: Array[Color] = []; var corner_weights: Array[Color] = []
	for corner in range(4):
		var texel := (base + Vector2i(corner % 2, corner / 2)).min(dimensions - Vector2i.ONE)
		corner_ids.append(ids.get_pixelv(texel))
		corner_weights.append(weights.get_pixelv(texel))
	return _blend_corners(corner_ids, corner_weights, grid - Vector2(base))

## The blend of the four corners (order x fastest) of a control cell at a fractional position.
static func _blend_corners(corner_ids: Array[Color], corner_weights: Array[Color], fraction: Vector2) -> Dictionary:
	var accumulated: Dictionary = {}
	for corner in range(4):
		var incoming_ids := corner_ids[corner]
		var incoming_weights := corner_weights[corner]
		var total := maxf(incoming_weights.r, 0.0) + maxf(incoming_weights.g, 0.0) + maxf(incoming_weights.b, 0.0) + maxf(incoming_weights.a, 0.0)
		var bilinear := (1.0 - fraction.x if corner % 2 == 0 else fraction.x) * (1.0 - fraction.y if corner / 2 == 0 else fraction.y)
		for slot in range(4):
			var contribution := maxf(incoming_weights[slot], 0.0) * bilinear / total if total > 0.0 else 0.0
			if contribution > 0.0:
				var id := clampi(roundi(incoming_ids[slot] * 255.0), 0, 31)
				accumulated[id] = float(accumulated.get(id, 0.0)) + contribution
	var sorted: Array = accumulated.keys()
	sorted.sort_custom(func(a: int, b: int): return a < b if accumulated[a] == accumulated[b] else accumulated[a] > accumulated[b])
	var result_ids := PackedInt32Array([0, 0, 0, 0])
	var result_weights := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	var total := 0.0
	var retained := 0.0
	var threshold: float = accumulated[sorted[4]] if sorted.size() > 4 else 0.0
	var softened_total := 0.0
	for id in sorted:
		total += accumulated[id]
	for slot in range(mini(4, sorted.size())):
		result_ids[slot] = sorted[slot]
		result_weights[slot] = accumulated[sorted[slot]]
		retained += accumulated[sorted[slot]]
		softened_total += maxf(float(accumulated[sorted[slot]]) - threshold, 0.0)
	if retained > 0.0:
		for slot in range(mini(4, sorted.size())):
			# No epsilon: a positive remainder is normalized even near a tie.
			# Equal maxima fall back to the deterministic hard selection.
			result_weights[slot] = maxf(float(accumulated[sorted[slot]]) - threshold, 0.0) / softened_total if softened_total > 0.0 else float(accumulated[sorted[slot]]) / retained
	return {"ids": result_ids, "weights": result_weights, "discarded_weight": maxf(0.0, total - retained) / total if total > 0.0 else 0.0}

func _update_discarded_diagnostic() -> void:
	if not _region_spec.get("maps", {}).has(StrataRegions.MAP_MATERIAL_IDS):
		return
	var maximum := 0.0
	var dimensions := _map_resolution(StrataRegions.MAP_MATERIAL_IDS)
	# Midpoint diagnostic is sampled, not a mathematical bound over every point.
	var stride := maxi(1, ceili(float(maxi(dimensions.x, dimensions.y)) / 65.0))
	for z in range(0, dimensions.y - 1, stride):
		for x in range(0, dimensions.x - 1, stride):
			var point := _render_bounds.position + _render_bounds.size * Vector2((x + 0.5) / (dimensions.x - 1), (z + 0.5) / (dimensions.y - 1))
			maximum = maxf(maximum, float(sample_control_blend(point).discarded_weight))
	_stats.max_discarded_weight = maximum

## Pure reference for valid normalized painted weights and validated parameters.
## Uses CPU doubles for exp/sum; GPU float results can differ in the last bits.
static func height_blend_weights(painted: Vector4, heights: Vector4, contrasts: Vector4, biases: Vector4 = Vector4.ZERO, enabled: bool = true) -> Vector4:
	if not enabled: return painted
	var gains := Vector4.ZERO
	var maximum := -100.0; var minimum := 100.0; var influence := 0.0
	for i in range(4):
		if painted[i] > 0.0:
			var height := float(heights[i]) if is_finite(heights[i]) else 0.5
			gains[i] = contrasts[i] * (clampf(height + biases[i], 0.0, 1.0) - 0.5)
			maximum = maxf(maximum, gains[i]); minimum = minf(minimum, gains[i]); influence = maxf(influence, contrasts[i])
	if influence == 0.0 or maximum == minimum: return painted
	var adjusted := Vector4.ZERO
	var total := 0.0
	for i in range(4):
		if painted[i] > 0.0:
			adjusted[i] = painted[i] * pow(2.0, gains[i] - maximum)
			total += adjusted[i]
	return adjusted / total if total > 0.0 else painted
