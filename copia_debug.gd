@tool
extends RefCounted
## Viewport debug views of Copia ([enum CopiaRenderSettings.DebugView]): static helpers and the
## caches they share across stores. [CopiaStore3D] calls [method apply] on an object's final draw
## params (after the object's hooks and the store's draw overrides), which replaces
## [code]material_override[/code] (and [code]mesh[/code] for the LOD view) and leaves every other
## value as it was, so the drawer swaps them on the live groups like any other params change.
## Every material and mesh is cached, so the same params give the same RIDs and an unchanged
## object passes no change. A cache is released when no store uses its view any more
## ([method set_store_views]).
##
## The HIDDEN view also needs the depth of the frame: a [CompositorEffect]
## (copia_hidden_effect.gd) is put on the compositor of every camera that draws while some
## store uses the view (the 3D editor viewports in the editor, the stores' viewport cameras in a
## game; [method sync_hidden]) and taken off again afterwards.

# The other Copia scripts are named by preloaded constants (see copia_object.gd).
const RenderScript := preload("res://addons/copia/copia_render_settings.gd")
const HiddenEffectScript := preload("res://addons/copia/copia_hidden_effect.gd")
const FLAT_SHADER := preload("res://addons/copia/shaders/copia_debug_flat.gdshader")
const BATCHES_SHADER := preload("res://addons/copia/shaders/copia_debug_batches.gdshader")
const LOD_SHADER := preload("res://addons/copia/shaders/copia_debug_lod.gdshader")
const SHADOW_SHADER := preload("res://addons/copia/shaders/copia_debug_shadow.gdshader")
const HIDDEN_SHADER := preload("res://addons/copia/shaders/copia_debug_hidden.gdshader")

const OFF := RenderScript.DebugView.OFF
const HIGHLIGHT := RenderScript.DebugView.HIGHLIGHT
const BATCHES := RenderScript.DebugView.BATCHES
const LOD := RenderScript.DebugView.LOD
const SHADOW_RANGE := RenderScript.DebugView.SHADOW_RANGE
const HIDDEN := RenderScript.DebugView.HIDDEN

const GREEN := Color(0.1, 0.8, 0.1)
const BLACK := Color(0.02, 0.02, 0.02)
const GREY := Color(0.25, 0.25, 0.25)

static var _flat := {}  # Color -> ShaderMaterial
static var _batches := {}  # [batch size, store inverse transform, seed] -> ShaderMaterial
static var _lod_material: ShaderMaterial
static var _lod_meshes := {}  # source mesh instance id -> [WeakRef, signature, ArrayMesh or null]
static var _shadow := {}  # [mode, range, margin, batch size, store inverse] -> ShaderMaterial
static var _hidden := {}  # mesh AABB -> ShaderMaterial (with the overlay as next pass)
static var _store_views := {}  # store instance id -> {view: true}
static var _effect: HiddenEffectScript
# Per camera the effect was put on: {camera: WeakRef, hosts: compositors found or made holding
# the effect, created: the compositor made for the camera (or null), previous: the camera's
# compositor before it}.
static var _hosts: Array[Dictionary] = []
static var _synced_frame := -1


## The view an object is drawn with: its render settings' [code]debug_view[/code] unless off, else
## [param store_view].
static func effective_view(object, store_view: int) -> int:
	var render = object.render if object != null else null
	if render != null and render.debug_view != OFF:
		return render.debug_view
	return store_view


## [param params] (an object's final draw params, or its impostor draw params when
## [param impostor]) drawn in [param view]: a copy with [code]material_override[/code] replaced,
## and for the LOD view of a mesh with LODs [code]mesh[/code] too. [param params] itself for
## [constant OFF]. A material override wins over per-surface materials in the
## [RenderingServer], so single instances need nothing else. The BATCHES and SHADOW_RANGE views
## find an instance's batch from its position as the build does: [param batch_size] is the batch cell
## edge (the far cell edge for impostors, 0 for single instances) and [param store_inverse] maps
## world space to store space; [param seed] tells the objects apart (the store passes a hash of the
## object's path).
static func apply(params: Dictionary, object, impostor: bool, view: int, batch_size := 0.0,
		store_inverse := Transform3D.IDENTITY, seed := 0) -> Dictionary:
	if view == OFF:
		return params
	var result := params.duplicate()
	var material: Material = null
	match view:
		HIGHLIGHT:
			material = _flat_material(GREEN)
		BATCHES:
			material = _batches_material(batch_size, store_inverse, seed)
		LOD:
			material = _flat_material(BLACK if impostor else GREEN)
			if not impostor:
				var debug_mesh := lod_mesh(object.mesh)
				if debug_mesh != null:
					result["mesh"] = debug_mesh.get_rid()
					material = _lod_shader_material()
		SHADOW_RANGE:
			material = _shadow_material(result, batch_size, store_inverse)
		HIDDEN:
			var mesh: Mesh = object.impostor_mesh if impostor else object.mesh
			material = _hidden_material(mesh.get_aabb() if mesh != null else AABB())
	if material != null:
		result["material_override"] = material.get_rid()
	return result


## Records the views store [param store_id] draws with now ([code]{view: true}[/code]; empty
## when it draws none or leaves the world) and releases what no store uses any more: the cached
## materials and LOD meshes of a view, and for HIDDEN the compositor effect on every camera.
## A store calls it after the drawer has the new params, so nothing released is still drawn.
static func set_store_views(store_id: int, views: Dictionary) -> void:
	if views.is_empty():
		_store_views.erase(store_id)
	else:
		_store_views[store_id] = views
	var used := {}
	for id in _store_views:
		used.merge(_store_views[id])
	if not used.has(HIGHLIGHT) and not used.has(LOD):
		_flat.clear()
	if not used.has(BATCHES):
		_batches.clear()
	if not used.has(LOD):
		_lod_material = null
		_lod_meshes.clear()
	if not used.has(SHADOW_RANGE):
		_shadow.clear()
	if not used.has(HIDDEN):
		_hidden.clear()
		_stop_hidden()


## Whether any store draws with [param view].
static func is_used(view: int) -> bool:
	for id in _store_views:
		if _store_views[id].has(view):
			return true
	return false


# --- LOD view ---------------------------------------------------------------------------------


## The LOD view's copy of [param mesh], or null when no surface of it has LODs. Each surface holds
## one copy of its vertices per level (the base and each LOD) with the level in UV2.x, and each
## LOD's indices are those of the mesh moved to its own copy, under the same edge lengths, so
## Godot selects exactly the LOD it selects for the mesh. Normals, tangents and UVs are kept;
## colours, bones, custom channels and blend shapes are dropped. Cached per mesh (by instance
## id, checked against the mesh and its surface count and bounds) until LOD view is off
## everywhere.
static func lod_mesh(mesh: Mesh) -> ArrayMesh:
	if mesh == null:
		return null
	var id := mesh.get_instance_id()
	var signature := [mesh.get_surface_count(), mesh.get_aabb()]
	var entry = _lod_meshes.get(id)
	if entry != null and entry[0].get_ref() == mesh and entry[1] == signature:
		return entry[2]
	for key in _lod_meshes.keys():
		if _lod_meshes[key][0].get_ref() == null:
			_lod_meshes.erase(key)
	var built := build_lod_mesh(mesh)
	_lod_meshes[id] = [weakref(mesh), signature, built]
	return built


## Builds the LOD view's copy of [param mesh] (see [method lod_mesh]) without caching it.
static func build_lod_mesh(mesh: Mesh) -> ArrayMesh:
	var copy := ArrayMesh.new()
	copy.resource_name = mesh.resource_name
	var any_lods := false
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		# Only an ArrayMesh can hold other primitives; a PrimitiveMesh is triangles.
		var primitive := (mesh as ArrayMesh).surface_get_primitive_type(s) if mesh is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var count := vertices.size()
		var indices = arrays[Mesh.ARRAY_INDEX]
		var indexed: bool = indices is PackedInt32Array and not indices.is_empty()
		var lods := []
		if primitive == Mesh.PRIMITIVE_TRIANGLES and indexed:
			lods = surface_lods(mesh.get_rid(), s)
		var levels := 1 + lods.size()
		var out := []
		out.resize(Mesh.ARRAY_MAX)
		out[Mesh.ARRAY_VERTEX] = _repeated(vertices, levels)
		for kind in [Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_TEX_UV]:
			var values = arrays[kind]
			var per_vertex := 4 if kind == Mesh.ARRAY_TANGENT else 1
			if values != null and values.size() == count * per_vertex and count > 0:
				out[kind] = _repeated(values, levels)
		var uv2 := PackedVector2Array()
		for level in levels:
			var block := PackedVector2Array()
			block.resize(count)
			block.fill(Vector2(level, 0.0))
			uv2.append_array(block)
		out[Mesh.ARRAY_TEX_UV2] = uv2
		var lod_indices := {}
		if indexed:
			out[Mesh.ARRAY_INDEX] = indices
			for k in lods.size():
				var offset := (k + 1) * count
				var moved: PackedInt32Array = lods[k][1]
				for i in moved.size():
					moved[i] += offset
				lod_indices[lods[k][0]] = moved
		copy.add_surface_from_arrays(primitive, out, [], lod_indices)
		if not lods.is_empty():
			any_lods = true
	return copy if any_lods else null


## The LODs of surface [param surface] of the mesh [param mesh_rid] as the [RenderingServer]
## keeps them: [code][[edge_length, PackedInt32Array indices], ...][/code], empty when it has none.
## The index size (2 or 4 bytes) is the base index buffer's size over its index count. Needs a
## rendering driver: the headless server keeps no surface data.
static func surface_lods(mesh_rid: RID, surface: int) -> Array:
	var data: Dictionary = RenderingServer.mesh_get_surface(mesh_rid, surface)
	var index_count: int = data.get("index_count", 0)
	var index_bytes: PackedByteArray = data.get("index_data", PackedByteArray())
	if index_count <= 0 or index_bytes.is_empty():
		return []
	# A buffer may be padded to four bytes, so a 2-byte buffer can be slightly over count * 2.
	var stride := 4 if index_bytes.size() >= index_count * 4 else 2
	var result := []
	for lod in data.get("lods", []):
		var bytes: PackedByteArray = lod.get("index_data", PackedByteArray())
		var total := bytes.size() / stride
		total -= total % 3
		var indices := PackedInt32Array()
		if stride == 4:
			indices = bytes.to_int32_array()
			indices.resize(total)
		else:
			indices.resize(total)
			for i in total:
				indices[i] = bytes.decode_u16(i * 2)
		if total > 0:
			result.append([float(lod.get("edge_length", 0.0)), indices])
	return result


static func _repeated(values, times: int):
	var result = values.duplicate()
	for i in times - 1:
		result.append_array(values)
	return result


# --- Materials --------------------------------------------------------------------------------


static func _flat_material(color: Color) -> ShaderMaterial:
	var material: ShaderMaterial = _flat.get(color)
	if material == null:
		material = _new_material(FLAT_SHADER)
		material.set_shader_parameter("color", color)
		_flat[color] = material
	return material


static func _batches_material(batch_size: float, store_inverse: Transform3D, seed: int) -> ShaderMaterial:
	var key := [batch_size, store_inverse, seed]
	if not _batches.has(key):
		var material := _new_material(BATCHES_SHADER)
		material.set_shader_parameter(&"batch_size", batch_size)
		material.set_shader_parameter(&"store_inverse", store_inverse)
		material.set_shader_parameter(&"object_seed", seed)
		_batches[key] = material
	return _batches[key]


static func _lod_shader_material() -> ShaderMaterial:
	if _lod_material == null:
		_lod_material = _new_material(LOD_SHADER)
	return _lod_material


# Per distinct shadow setting of the final params: none (cast_shadows off and no low-LOD
# shadows), casting at any distance (no shadow range), or a range and margin.
static func _shadow_material(params: Dictionary, batch_size: float, store_inverse: Transform3D) -> ShaderMaterial:
	var cast: int = params.get("cast_shadows", RenderingServer.SHADOW_CASTING_SETTING_ON)
	var low_lod: bool = params.get("low_lod_shadows", false)
	var shadow_range: float = params.get("shadow_range", 0.0)
	var margin: float = maxf(params.get("shadow_range_margin", 0.0), 0.0)
	var mode := 2
	if cast == RenderingServer.SHADOW_CASTING_SETTING_OFF and not low_lod:
		mode = 0
	elif shadow_range <= 0.0:
		mode = 1
	if mode != 2:
		batch_size = 0.0
		store_inverse = Transform3D.IDENTITY
	var key := [mode, shadow_range if mode == 2 else 0.0, margin if mode == 2 else 0.0, batch_size, store_inverse]
	var material: ShaderMaterial = _shadow.get(key)
	if material == null:
		material = _new_material(SHADOW_SHADER)
		material.set_shader_parameter("mode", mode)
		material.set_shader_parameter("shadow_range", key[1])
		material.set_shader_parameter("shadow_margin", key[2])
		material.set_shader_parameter("batch_size", batch_size)
		material.set_shader_parameter("store_inverse", store_inverse)
		material.set_shader_parameter("store_transform", store_inverse.affine_inverse())
		_shadow[key] = material
	return material


# Per mesh bounds: dim grey, with the overlay that marks hidden instances as its next pass.
static func _hidden_material(aabb: AABB) -> ShaderMaterial:
	var material: ShaderMaterial = _hidden.get(aabb)
	if material == null:
		var overlay := _new_material(HIDDEN_SHADER)
		overlay.set_shader_parameter("pyramid", _hidden_effect().pyramid)
		overlay.set_shader_parameter("aabb_position", aabb.position)
		overlay.set_shader_parameter("aabb_size", aabb.size)
		material = _new_material(FLAT_SHADER)
		material.set_shader_parameter("color", GREY)
		material.next_pass = overlay
		_hidden[aabb] = material
	return material


static func _new_material(shader: Shader) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	return material


# --- HIDDEN view: the depth pass on the cameras -------------------------------------------------


static func _hidden_effect() -> HiddenEffectScript:
	if _effect == null:
		_effect = HiddenEffectScript.new()
	return _effect


## Keeps the HIDDEN view's effect on the compositor of every camera that draws, once a frame
## (stores call it from their process step; later calls in the same frame return at once). A
## camera whose compositor already holds the effect needs nothing; otherwise the effect is put
## back, which also follows another addon that rebuilt the camera's compositor.
##
## In the editor the cameras are those of the 3D editor viewports (a scene camera being previewed
## is left alone, since it would be saved). An editor camera with a compositor of its own that is
## not a saved resource gets the effect added to it; otherwise the camera gets a new compositor
## holding the effects of the one it rendered with plus this one, and its previous compositor is
## given back when the view goes off, if the camera still uses the one made here. A saved
## [Compositor] or the scene's [WorldEnvironment] is never changed in the editor. In a game each
## store's viewport camera joins the compositor it renders with (its own, else its world
## environment's, created when there is none).
static func sync_hidden() -> void:
	var frame := Engine.get_process_frames()
	if frame == _synced_frame:
		return
	_synced_frame = frame
	if not is_used(HIDDEN):
		if not _hosts.is_empty() or _effect != null:
			_stop_hidden()
		return
	var effect := _hidden_effect()
	effect.update()
	var cameras := _hidden_cameras()
	for entry in _hosts.duplicate():
		var camera = entry.camera.get_ref()
		if camera == null or not cameras.has(camera):
			_detach(entry)
			_hosts.erase(entry)
	for camera in cameras:
		var entry := _entry_of(camera)
		var effective := _effective_compositor(camera)
		if effective != null and effective.compositor_effects.has(effect):
			if not entry.hosts.has(effective):
				entry.hosts.append(effective)
			continue
		_attach(camera, entry, effective)


static func _stop_hidden() -> void:
	for entry in _hosts:
		_detach(entry)
	_hosts.clear()
	if _effect != null:
		_effect.release()
		_effect = null


static func _hidden_cameras() -> Array[Camera3D]:
	var cameras: Array[Camera3D] = []
	if Engine.is_editor_hint():
		if not Engine.has_singleton("EditorInterface"):
			return cameras
		var editor = Engine.get_singleton("EditorInterface")
		var root: Node = editor.get_edited_scene_root()
		for index in 4:
			var viewport = editor.get_editor_viewport_3d(index)
			var camera: Camera3D = viewport.get_camera_3d() if viewport != null else null
			if camera == null or cameras.has(camera):
				continue
			if root != null and (camera == root or root.is_ancestor_of(camera)):
				continue
			cameras.append(camera)
		return cameras
	for id in _store_views:
		if not _store_views[id].has(HIDDEN):
			continue
		var store = instance_from_id(id)
		if store is Node and store.is_inside_tree() and store.get_viewport() != null:
			var camera := store.get_viewport().get_camera_3d() as Camera3D
			if camera != null and not cameras.has(camera):
				cameras.append(camera)
	return cameras


static func _entry_of(camera: Camera3D) -> Dictionary:
	for entry in _hosts:
		if entry.camera.get_ref() == camera:
			return entry
	var entry := {"camera": weakref(camera), "hosts": [], "created": null, "previous": null}
	_hosts.append(entry)
	return entry


static func _attach(camera: Camera3D, entry: Dictionary, effective: Compositor) -> void:
	if Engine.is_editor_hint():
		var own := camera.compositor
		if own != null and own.resource_path.is_empty():
			_add_effect(own)
			if not entry.hosts.has(own):
				entry.hosts.append(own)
			return
		var effects: Array[CompositorEffect] = []
		if effective != null:
			effects.assign(effective.compositor_effects)
		effects.append(_effect)
		var host := Compositor.new()
		host.compositor_effects = effects
		entry.created = host
		entry.previous = own
		entry.hosts.append(host)
		camera.compositor = host
		return
	var target := effective
	if target == null:
		target = Compositor.new()
		var environment := _world_environment(camera)
		if environment != null:
			environment.compositor = target
		else:
			camera.compositor = target
	_add_effect(target)
	if not entry.hosts.has(target):
		entry.hosts.append(target)


# Takes the effect off every compositor recorded for the camera and, in the editor, gives the
# camera its previous compositor back when it still uses the one made for it.
static func _detach(entry: Dictionary) -> void:
	for host in entry.hosts:
		if host == null or (Engine.is_editor_hint() and not host.resource_path.is_empty()):
			continue
		var effects: Array[CompositorEffect] = []
		effects.assign(host.compositor_effects)
		if effects.has(_effect):
			effects.erase(_effect)
			host.compositor_effects = effects
	var camera = entry.camera.get_ref()
	if Engine.is_editor_hint() and entry.created != null and camera != null and camera.compositor == entry.created:
		camera.compositor = entry.previous
	entry.hosts.clear()


static func _add_effect(host: Compositor) -> void:
	var effects: Array[CompositorEffect] = []
	effects.assign(host.compositor_effects)
	if effects.has(_effect):
		return
	effects.append(_effect)
	host.compositor_effects = effects


# The compositor a camera renders with: its own, or its world environment's.
static func _effective_compositor(camera: Camera3D) -> Compositor:
	if camera.compositor != null:
		return camera.compositor
	var environment := _world_environment(camera)
	return environment.compositor if environment != null else null


# The WorldEnvironment of a camera's world: Godot keeps them in a group per scenario.
static func _world_environment(camera: Camera3D) -> WorldEnvironment:
	var world := camera.get_world_3d()
	if world == null or not camera.is_inside_tree():
		return null
	var nodes := camera.get_tree().get_nodes_in_group("_world_environment_%d" % world.scenario.get_id())
	return nodes[0] as WorldEnvironment if not nodes.is_empty() else null
