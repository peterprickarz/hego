@tool
class_name StrataTerrain3D
extends Node3D
## Finite, deliberately simple ArrayMesh proof of the layered data model.

signal preview_updated
signal authoring_preview_changed
@export_group("Terrain rendering")
@export var render_settings: StrataRenderSettings = StrataRenderSettings.new():
	set(value):
		render_settings = value
		queue_preview_update()
## Actual spacing for the current editor camera. Budget/depth limits can make
## this coarser than the requested spacing. This diagnostic is never saved.
@export var near_displacement_status: String:
	get:
		if not is_instance_valid(editor_renderer): return "Textured editor preview is not active"
		var stats := editor_renderer.get_stats()
		if not stats.get("refinement_active", false): return String(stats.get("refinement_status", "Not configured"))
		var spacing := float(stats.get("refinement_effective_vertex_spacing", 0.0))
		var detail := "%s m; %d extra patches" % [String.num(spacing, 6), int(stats.get("refinement_patch_count", 0))]
		if stats.get("refinement_limited", false):
			return "Limited: %s (requested %s m)" % [detail, String.num(float(stats.get("refinement_requested_vertex_spacing", 0.0)), 6)]
		return detail
## The editor plugin uses the real Forward+ renderer when these are supplied.
@export var textured_editor_preview := false:
	set(value):
		textured_editor_preview = value
		queue_preview_update()
@export var editor_materials: Array[StrataMaterial] = []
@export var editor_control_ids: Image
@export var editor_control_weights: Image
## Ordered scalar channel names matching editor_materials IDs. When supplied,
## editor controls are composed from the enabled stack through its cutoff.
## Cached editor_control_* remain the separately saved complete result.
@export var editor_material_channels := PackedStringArray():
	set(value):
		editor_material_channels = value
		queue_preview_update()
## Minimum camera clip distance while viewing this terrain in the editor.
## This changes the editor camera only, not global EditorSettings.
@export_range(100.0, 100000.0, 100.0) var editor_far_clip := 24000.0
## Deprecated alias of [member region_spacing] (same storage), kept so existing scenes and
## scripts keep working. It is no longer shown in the inspector.
@export_range(0.25, 8.0, 0.25) var editor_compile_spacing: float:
	get: return region_spacing
	set(value): region_spacing = value
@export_group("Regions")
## Metres between height samples of the editor's region maps. Heights, holes and material
## IDs and weights are composed at this spacing; the macro tint at a quarter of the sample
## density (about 4 m). The same value is the default bake spacing of the island.
@export_range(0.0625, 16.0, 0.0625) var region_spacing := 1.0:
	set(value):
		if is_finite(value) and value > 0.0: region_spacing = value
		queue_preview_update()
## Cells per region side, a power of two from 16 to 4096. A region is the unit the editor
## composes, uploads and re-composes after a brush dab.
@export_range(16, 4096, 1) var region_cells := 256:
	set(value):
		region_cells = clampi(nearest_po2(clampi(value, StrataRegions.MIN_CELLS, StrataRegions.MAX_CELLS)), StrataRegions.MIN_CELLS, StrataRegions.MAX_CELLS)
		queue_preview_update()
@export_group("")
var editor_renderer: StrataRenderer
var editor_preview_bridge: Node
var editor_show_channel := false


@export var base_bounds: Rect2 = Rect2(-32.0, -32.0, 64.0, 64.0):
	set(value):
		base_bounds = value
		queue_preview_update()
@export_range(0.25, 8.0, 0.25) var preview_spacing: float = 1.0:
	set(value):
		preview_spacing = value
		queue_preview_update()

var _preview: MeshInstance3D
var _queued := false
var _triangles := PackedVector3Array()
var _mesh_bounds := AABB()
var _preview_enabled := true
## Editor display/hit testing stops here. Public sampling still defaults to the
## complete stack, so callers explicitly choose their evaluation context.
var preview_through_layer: StrataLayer:
	set(value):
		var changed := preview_through_layer != value
		preview_through_layer = value
		if changed:
			queue_preview_update()
## Coverage is computed from explicit owned samples of the selected layer.
## It is an interpolated display mask, never a second kind of ownership.
@export var show_overrides := false:
	set(value):
		show_overrides = value
		queue_preview_update()
var override_channel: StringName = &"height":
	set(value):
		override_channel = value
		queue_preview_update()

@export_group("Storage")
## Project directory this terrain's data lives in, one file per manual layer, per cooked
## channel and for the bake; see [StrataStorage]. A cook overwrites its layer's files here,
## and the bake is loaded from here rather than stored in the scene. Empty keeps everything
## in the scene, which suits small terrains.
@export_dir var storage_directory := "":
	set(value):
		storage_directory = value
		notify_property_list_changed()
## Writes every layer and the current bake to the storage directory.
@export_tool_button("Save layers to storage", "Save") var save_to_storage_button = save_to_storage
@export_group("")

## Runtime bake of the complete enabled stack, published only by
## StrataBake.bake(). With a storage directory it is saved there; otherwise it is
## stored in the scene.
signal runtime_data_changed
signal runtime_bake_stale_changed(stale: bool)
@export var runtime_data: StrataRuntimeData
@export var runtime_bake_stale := true
var _runtime_signature: Variant = null
## Seconds between checks of the procedural layers' [member StrataLayer.source_tokens].
const SOURCE_POLL_INTERVAL := 0.25
var _source_poll_elapsed := 0.0

func _ready() -> void:
	set_notify_transform(true)
	child_order_changed.connect(_children_changed)
	if StrataStorage.has_storage(self):
		StrataStorage.load_layers(self)
		if runtime_data == null:
			runtime_data = StrataStorage.load_runtime_data(self)
		if editor_control_ids == null or editor_control_weights == null:
			var controls := StrataStorage.load_control_maps(self)
			if not controls.is_empty():
				editor_control_ids = controls.ids
				editor_control_weights = controls.weights
	# Saved together with its layers, a fresh bake stays fresh after reload.
	if runtime_data != null and not runtime_bake_stale:
		_runtime_signature = StrataBake.stack_signature(self)
	queue_preview_update()

func save_to_storage() -> void:
	var result := StrataStorage.save_all(self)
	if result.ok:
		print("Strata: ", result.message)
	else:
		push_error("Strata: " + String(result.message))

func _children_changed() -> void:
	_sanitize_preview_layer()
	queue_preview_update()

func _sanitize_preview_layer() -> void:
	if not is_instance_valid(preview_through_layer):
		preview_through_layer = null
	elif preview_through_layer.get_parent() != self:
		preview_through_layer = null

func is_transform_valid() -> bool:
	var basis := global_transform.basis
	return basis.y.is_equal_approx(Vector3.UP) and is_equal_approx(basis.x.length(), 1.0) and is_equal_approx(basis.z.length(), 1.0) and is_equal_approx(basis.determinant(), 1.0)

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if is_inside_tree() and not is_transform_valid():
		warnings.append("Terrain supports translation and yaw with unit scale, including its parents. Sculpting is disabled for pitch, roll, shear or scale.")
	var extent := float(region_cells) * region_spacing
	var regions_across := base_bounds.size / extent
	if base_bounds.size.x > 0.0 and base_bounds.size.y > 0.0 and (absf(regions_across.x - roundf(regions_across.x)) > 1e-6 or absf(regions_across.y - roundf(regions_across.y)) > 1e-6):
		warnings.append("The bounds are not a multiple of the region extent (%s m = region_cells x region_spacing); the last regions extend past the bounds, where they compose to the channel defaults." % String.num(extent, 4))
	var checked := StrataRegions.validate_spec(region_spec())
	if not checked.ok: warnings.append("Region settings are invalid: " + String(checked.message))
	return warnings

## The region spec the editor preview composes and a bake of the same settings would use:
## [method StrataRegions.standard_spec] over the bounds with [member region_spacing] and
## [member region_cells]. Material ids and weights are present only when
## [member editor_material_channels] is not empty and the macro map only when an enabled
## layer owns a tint or AO channel (as StrataBake decides). The editor always keeps the
## holes map, and its macro map has the scale that comes closest to 4 m.
func region_spec() -> Dictionary:
	var spec := StrataRegions.standard_spec(base_bounds, region_spacing, region_cells)
	var maps: Dictionary = spec.maps
	if editor_material_channels.is_empty():
		maps.erase(StrataRegions.MAP_MATERIAL_IDS)
		maps.erase(StrataRegions.MAP_MATERIAL_WEIGHTS)
	if StrataMacro.has_macro_channels(self):
		var scale := 1 << clampi(roundi(log(StrataMacro.DEFAULT_SPACING / region_spacing) / log(2.0)), 0, 5)
		maps[StrataRegions.MAP_MACRO] = StrataRegions.map(Image.FORMAT_RGBAH, StrataRegions.KIND_SAMPLE, scale, 1)
	else:
		maps.erase(StrataRegions.MAP_MACRO)
	return spec

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and Engine.is_editor_hint():
		update_configuration_warnings()

func contains_position(position: Vector2) -> bool:
	return position.x >= base_bounds.position.x and position.y >= base_bounds.position.y and position.x <= base_bounds.end.x and position.y <= base_bounds.end.y

func get_layers() -> Array[StrataLayer]:
	var layers: Array[StrataLayer] = []
	for child in get_children():
		if child is StrataLayer:
			layers.append(child)
	return layers

func sample_channel(channel: StringName, position: Vector2, through_layer: Variant = null) -> float:
	if typeof(through_layer) != TYPE_NIL:
		if typeof(through_layer) != TYPE_OBJECT or not is_instance_valid(through_layer) or not through_layer is StrataLayer or through_layer.get_parent() != self:
			push_warning("Terrain sample cutoff must be a live direct child layer; returning NAN for invalid cutoff.")
			return NAN
	if not contains_position(position):
		return channel_default(channel)
	var result := channel_default(channel)
	for layer in get_layers():
		if layer.enabled:
			var sampled: Dictionary = layer.sample_channel(channel, position)
			var coverage := clampf(float(sampled.get("coverage", 0.0)), 0.0, 1.0)
			var value := float(sampled.get("value", 0.0))
			if layer.get_composition(channel) == StrataLayer.Composition.ADD:
				result += value * coverage
			else:
				result = lerpf(result, value, coverage)
		if layer == through_layer:
			break
	return result

static func channel_default(channel: StringName) -> float:
	return 1.0 if channel in [&"terrain_tint_r", &"terrain_tint_g", &"terrain_tint_b", &"terrain_ao"] else 0.0

func sample_height(position: Vector2, through_layer: Variant = null) -> float:
	return sample_channel(&"height", position, through_layer)

## Coverage of the composed channel's explicit sample support. The finite flat
## height base is defined; other channels start undefined until a layer owns them.
func sample_channel_coverage(channel: StringName, position: Vector2, through_layer: StrataLayer = null) -> Dictionary:
	if not contains_position(position): return {"value": channel_default(channel), "coverage": 0.0}
	var coverage := 1.0 if channel == &"height" or channel_default(channel) == 1.0 else 0.0
	for layer in get_layers():
		if layer.enabled:
			var upper := clampf(float(layer.sample_channel(channel, position).coverage), 0.0, 1.0)
			coverage = upper + coverage * (1.0 - upper)
		if layer == through_layer: break
	return {"value": sample_channel(channel, position, through_layer), "coverage": coverage}

func sample_below(channel: StringName, position: Vector2, layer: StrataLayer) -> float:
	var previous: StrataLayer = null
	for entry in get_layers():
		if entry == layer:
			return sample_channel(channel, position, previous) if previous != null else channel_default(channel)
		previous = entry
	return channel_default(channel)

func queue_preview_update() -> void:
	_check_runtime_bake()
	if is_inside_tree(): authoring_preview_changed.emit()
	if not _preview_enabled or not is_inside_tree() or _queued:
		return
	_queued = true
	_rebuild_deferred.call_deferred()

func _rebuild_deferred() -> void:
	_queued = false
	rebuild_preview()

func rebuild_preview() -> void:
	if not _preview_enabled or not is_inside_tree():
		return
	_sanitize_preview_layer()
	if not is_instance_valid(_preview):
		_preview = MeshInstance3D.new()
		_preview.name = "TerrainPreview"
		add_child(_preview, false, Node.INTERNAL_MODE_BACK)
		var material := StandardMaterial3D.new()
		material.vertex_color_use_as_albedo = true
		material.roughness = 0.94
		_preview.material_override = material
	_triangles.clear()
	if base_bounds.size.x <= 0.0 or base_bounds.size.y <= 0.0:
		_preview.mesh = null
		return
	# This is a bounded prototype preview, not production terrain LOD.
	var nx := clampi(ceili(base_bounds.size.x / maxf(preview_spacing, 0.25)), 1, 192)
	var nz := clampi(ceili(base_bounds.size.y / maxf(preview_spacing, 0.25)), 1, 192)
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for z in range(nz + 1):
		for x in range(nx + 1):
			var p := base_bounds.position + base_bounds.size * Vector2(float(x) / nx, float(z) / nz)
			var h := sample_height(p, preview_through_layer)
			vertices.append(Vector3(p.x, h, p.y))
			var color := Color("18382d").lerp(Color("4c6244"), clampf((h + 3.0) / 12.0, 0.0, 1.0))
			if show_overrides and is_instance_valid(preview_through_layer):
				var coverage := float(preview_through_layer.sample_channel(override_channel, p).get("coverage", 0.0))
				color = color.lerp(Color("c65c32"), clampf(coverage, 0.0, 1.0) * 0.88)
			colors.append(color)
			normals.append(Vector3.ZERO)
	for z in range(nz):
		for x in range(nx):
			var a := z * (nx + 1) + x
			for triangle in [[a, a + 1, a + nx + 1], [a + 1, a + nx + 2, a + nx + 1]]:
				var normal: Vector3 = (vertices[triangle[2]] - vertices[triangle[0]]).cross(vertices[triangle[1]] - vertices[triangle[0]]).normalized()
				for index in triangle:
					indices.append(index)
					_triangles.append(vertices[index])
					normals[index] += normal
	for index in range(normals.size()):
		normals[index] = normals[index].normalized()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_preview.mesh = mesh
	_mesh_bounds = mesh.get_aabb()
	preview_updated.emit()

func get_preview_mesh() -> ArrayMesh:
	return _preview.mesh as ArrayMesh if is_instance_valid(_preview) else null

func set_preview_enabled(enabled: bool) -> void:
	_preview_enabled = enabled
	if is_instance_valid(_preview):
		_preview.visible = enabled
	if enabled:
		queue_preview_update()

func is_preview_enabled() -> bool:
	return _preview_enabled

## Intersects the actual preview triangles, including sculpted hills and slopes.
func raycast_surface(origin: Vector3, direction: Vector3, max_distance: float = 8000.0) -> Dictionary:
	if is_instance_valid(editor_renderer): return editor_renderer.raycast_heightfield(origin, direction, max_distance)
	if not _preview_enabled or _triangles.is_empty() or not is_transform_valid():
		return {}
	var local_origin := to_local(origin)
	var local_direction := (global_transform.basis.inverse() * direction).normalized()
	if _mesh_bounds.grow(0.01).intersects_ray(local_origin, local_direction) == null:
		return {}
	var closest := max_distance
	var result: Dictionary = {}
	for i in range(0, _triangles.size(), 3):
		var hit: Variant = Geometry3D.ray_intersects_triangle(local_origin, local_direction, _triangles[i], _triangles[i + 1], _triangles[i + 2])
		if hit != null:
			var world_hit := to_global(hit)
			var distance := origin.distance_to(world_hit)
			if distance < closest:
				closest = distance
				result = {"position": world_hit, "local_position": Vector2(hit.x, hit.z), "distance": distance}
	return result

func _process(delta: float) -> void:
	_source_poll_elapsed += delta
	if _source_poll_elapsed < SOURCE_POLL_INTERVAL: return
	_source_poll_elapsed = 0.0
	check_procedural_sources()

## Marks every current procedural layer stale whose result was built from an input that
## has changed since (see [member StrataLayer.source_tokens]). Runs a few times a second in
## the editor and at runtime alike; call it directly to check at once.
func check_procedural_sources() -> void:
	for layer in get_layers():
		if layer.procedural and not layer.procedural_stale and not layer.source_tokens.is_empty() and not layer.sources_current():
			layer.mark_stale("An input layer changed since this result was cooked; explicit recook required")

## Runtime bake state. Layer edits, enable/composition changes, reordering and
## bounds changes reach queue_preview_update(); preview cutoff and overlay
## settings do not change the signature, so they never stale the bake.
func _check_runtime_bake() -> void:
	if _runtime_signature == null or runtime_bake_stale:
		return
	if StrataBake.stack_signature(self) != _runtime_signature:
		runtime_bake_stale = true
		runtime_bake_stale_changed.emit(true)

func is_runtime_bake_stale() -> bool:
	_check_runtime_bake()
	return runtime_data == null or runtime_bake_stale

## Called by StrataBake.bake() after the complete result validated. With a storage
## directory the bake is also written to its fixed file there.
func publish_runtime_data(data: StrataRuntimeData, signature: Array) -> void:
	data.bake_revision = (runtime_data.bake_revision if runtime_data != null else 0) + 1
	var was_stale := runtime_bake_stale
	runtime_data = data
	_runtime_signature = signature
	runtime_bake_stale = false
	if StrataStorage.has_storage(self):
		var saved := StrataStorage.save_runtime_data(self)
		if not saved.ok:
			push_error("Strata: bake published but not saved: " + String(saved.message))
	runtime_data_changed.emit()
	if was_stale:
		runtime_bake_stale_changed.emit(false)

## Read-only CPU queries of the published bake ({status, value}; see
## StrataRuntimeData.Status). They never compose layers or read the GPU.
func sample_runtime_height(local_position: Vector2) -> Dictionary:
	if runtime_data == null:
		return {"status": StrataRuntimeData.Status.NOT_RESIDENT, "value": NAN}
	return runtime_data.sample_height(local_position)

func sample_runtime_height_world(world_position: Vector3) -> Dictionary:
	if runtime_data == null:
		return {"status": StrataRuntimeData.Status.NOT_RESIDENT, "value": NAN}
	return runtime_data.sample_height_world(world_position, global_transform)

## A retained channel of the published bake at a world position ({ok, status,
## value, coverage}; see StrataRuntimeData.sample_channel()).
func sample_runtime_channel(name: StringName, world_position: Vector3, interpolation: int = StrataRuntimeData.Interpolation.BILINEAR) -> Dictionary:
	if runtime_data == null:
		return {"ok": false, "status": StrataRuntimeData.Status.NOT_RESIDENT, "value": NAN, "coverage": 0.0}
	return runtime_data.sample_channel_world(name, world_position, global_transform, interpolation)

func _validate_property(property: Dictionary) -> void:
	if property.name == "editor_compile_spacing":
		property.usage = PROPERTY_USAGE_STORAGE
	if property.name in ["runtime_data", "runtime_bake_stale"]:
		property.usage |= PROPERTY_USAGE_READ_ONLY
	# With a storage directory the bake and control maps live in their files, not in the scene.
	if property.name in ["runtime_data", "editor_control_ids", "editor_control_weights"] and not storage_directory.strip_edges().is_empty():
		property.usage &= ~PROPERTY_USAGE_STORAGE
	if property.name == "near_displacement_status":
		property.usage = (property.usage | PROPERTY_USAGE_READ_ONLY) & ~PROPERTY_USAGE_STORAGE
