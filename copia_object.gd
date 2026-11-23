@tool
class_name CopiaObject
extends Resource
## The thing to instance: a mesh with its render settings, optional physics settings and an
## optional impostor. Points of a store name an object by resource path. A game can extend this
## class and override the [code]_get_*[/code] hooks to derive values from its own conventions.
## Build inputs are the mesh bounds, the defaults, the draw mode and batch size, the physics
## minimum scale and whether there is a collider, and the impostor settings; everything else
## applies when a cell loads and needs no build.

## Emitted when something that changes the build descriptor changes, including in the render
## or physics settings. [signal Resource.changed] is emitted too, for any change.
signal build_inputs_changed

# The other Copia scripts are named by preloaded constants, not by their class_name, so this
# script parses in a project whose class cache has not scanned the addon yet. This script cannot
# preload itself; its own class is reached with load() at call time (see _self_script).
const RenderScript := preload("res://addons/copia/copia_render_settings.gd")
const PhysicsScript := preload("res://addons/copia/copia_physics_settings.gd")
const SELF_PATH := "res://addons/copia/copia_object.gd"

# Resolved objects by path.
static var _cache := {}

var _default_render: RenderScript
# The mesh copy carrying the per-surface materials (get_surface_material_mesh) and what it was
# made from.
var _surface_mesh: Mesh
var _surface_mesh_key := []

## The mesh to draw. Its bounds are a build input.
@export var mesh: Mesh:
	set(value):
		if mesh == value: return
		var old_bounds := mesh.get_aabb() if mesh != null else AABB()
		mesh = value
		var new_bounds := mesh.get_aabb() if mesh != null else AABB()
		emit_changed()
		if old_bounds != new_bounds:
			build_inputs_changed.emit()
## Replaces the mesh's own materials on every surface when set.
@export var material_override: Material:
	set(value):
		material_override = value
		emit_changed()
## Materials per surface of [member mesh]: entry i replaces the material of surface i; a null or
## missing entry keeps the mesh's own. Ignored when [member material_override] is set. A game can
## supply them at load instead, without saving material files, by overriding
## [method _get_surface_materials]. Single instances get them as per-surface override materials.
## A MultiMesh has no per-surface materials in Godot (the RenderingServer rejects them on a
## multimesh instance), so batches are drawn with a copy of the mesh whose surfaces carry the
## materials (see [method get_surface_material_mesh]); that copy holds the mesh's vertex data a
## second time.
@export var surface_materials: Array[Material] = []:
	set(value):
		surface_materials = value
		emit_changed()
## Draw settings, shared by the variations of a thing. Without one the drawer uses a default
## [CopiaRenderSettings].
@export var render: RenderScript:
	set(value):
		if render == value: return
		_swap(render, value)
		render = value
		_sub_resource_changed()
## Collider settings. Without them the object has no collider.
@export var physics: PhysicsScript:
	set(value):
		if physics == value: return
		_swap(physics, value)
		physics = value
		_sub_resource_changed()
## Mesh drawn instead of [member mesh] beyond the near cells, in the far grid. Without one the
## object has no impostor.
@export var impostor_mesh: Mesh:
	set(value):
		if impostor_mesh == value: return
		impostor_mesh = value
		emit_changed()
		build_inputs_changed.emit()
## Material override of the impostor mesh.
@export var impostor_material: Material:
	set(value):
		impostor_material = value
		emit_changed()
## Instances whose scale (the length of the transform's basis Y column) is below this get no
## impostor. 0 gives every instance one when [member impostor_mesh] is set. A build input.
@export_range(0.0, 100.0, 0.01, "or_greater") var impostor_min_scale := 0.0:
	set(value):
		value = maxf(value, 0.0)
		if is_equal_approx(impostor_min_scale, value): return
		impostor_min_scale = value
		emit_changed()
		build_inputs_changed.emit()
## Instance colour of points that carry none. A build input.
@export var default_color := Color.WHITE:
	set(value):
		if default_color == value: return
		default_color = value
		emit_changed()
		build_inputs_changed.emit()
## Instance custom data of points that carry none. A build input.
@export var default_custom := Color(0, 0, 0, 0):
	set(value):
		if default_custom == value: return
		default_custom = value
		emit_changed()
		build_inputs_changed.emit()


## The instance colour of points that carry none. Override to derive it from the object; the
## default returns [member default_color].
func _get_default_color() -> Color:
	return default_color


## The instance custom data of points that carry none. Override to derive it from the object;
## the default returns [member default_custom].
func _get_default_custom() -> Color:
	return default_custom


## The per-surface materials drawn, as [member surface_materials] describes them. Override to
## supply them at load (for example copies of the mesh's materials with a parameter set), without
## saving material files; the default returns [member surface_materials]. Called whenever draw
## params are built, so an override should cache what it creates.
func _get_surface_materials() -> Array[Material]:
	return surface_materials


## The values the drawer applies when it creates this object's rendering instances: the
## render settings' [method CopiaRenderSettings.draw_params] plus [code]mesh[/code] and
## [code]material_override[/code] as [RID]s (empty when unset), [code]surface_materials[/code]
## (an [Array] of [RID]s, empty [RID] for the mesh's own) and [code]impostor_min_scale[/code]
## (0 without an impostor mesh). In [constant CopiaRenderSettings.DrawMode.MULTIMESH] the
## per-surface materials travel in [code]mesh[/code] instead (the copy from
## [method get_surface_material_mesh]) and [code]surface_materials[/code] is empty. Override to
## add or change values.
func _get_draw_params() -> Dictionary:
	var settings := _render_settings()
	var params := settings.draw_params()
	var surfaces := []
	var drawn := mesh
	if material_override == null and _has_surface_materials():
		if settings.draw_mode == RenderScript.DrawMode.MULTIMESH:
			drawn = get_surface_material_mesh()
		else:
			for material in _get_surface_materials():
				surfaces.append(material.get_rid() if material != null else RID())
	params["mesh"] = drawn.get_rid() if drawn != null else RID()
	params["material_override"] = material_override.get_rid() if material_override != null else RID()
	params["surface_materials"] = surfaces
	params["impostor_min_scale"] = impostor_min_scale if impostor_mesh != null else 0.0
	return params


## The values the drawer applies to this object's impostor batches: [method _get_draw_params]
## with [member impostor_mesh] as [code]mesh[/code], [member impostor_material] as
## [code]material_override[/code], no per-surface materials, begin 0 (the store sets the swap
## distance through the impostor link), [member CopiaRenderSettings.impostor_range_end] as end,
## no fade and no low-LOD shadows. Override to change values, for example to supply the impostor
## material at load or to turn the impostor's shadows off.
func _get_impostor_draw_params() -> Dictionary:
	var params := _get_draw_params()
	params["mesh"] = impostor_mesh.get_rid() if impostor_mesh != null else RID()
	params["material_override"] = impostor_material.get_rid() if impostor_material != null else RID()
	params["surface_materials"] = []
	params["impostor_min_scale"] = 0.0
	params["visibility_begin"] = 0.0
	params["visibility_end"] = _render_settings().impostor_range_end
	params["fade_mode"] = RenderingServer.VISIBILITY_RANGE_FADE_DISABLED
	params["low_lod_shadows"] = false
	return params


## [member mesh] with the materials of [method _get_surface_materials] set on its own surfaces:
## a copy made once and kept until the mesh or the materials change. [member mesh] itself when
## there are no per-surface materials or [member material_override] is set. Batches are drawn
## with it, because a MultiMesh cannot take per-surface materials; [method CopiaStore3D.to_nodes]
## uses it too. An [ArrayMesh] is duplicated with its LODs, blend shapes and shadow mesh; any other
## mesh becomes an [ArrayMesh] of its surface arrays (without LODs).
func get_surface_material_mesh() -> Mesh:
	if mesh == null or material_override != null or not _has_surface_materials():
		return mesh
	var materials := _get_surface_materials()
	var key := [mesh, materials.duplicate()]
	if _surface_mesh != null and _surface_mesh_key == key:
		return _surface_mesh
	var copy: ArrayMesh
	if mesh is ArrayMesh:
		copy = mesh.duplicate()
	else:
		copy = ArrayMesh.new()
		for s in mesh.get_surface_count():
			copy.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh.surface_get_arrays(s))
			copy.surface_set_material(s, mesh.surface_get_material(s))
	copy.resource_name = mesh.resource_name
	for s in mini(copy.get_surface_count(), materials.size()):
		if materials[s] != null:
			copy.surface_set_material(s, materials[s])
	_surface_mesh = copy
	_surface_mesh_key = key
	return copy


func _has_surface_materials() -> bool:
	for material in _get_surface_materials():
		if material != null:
			return true
	return false


## The descriptor the build reads, as in the design page's "Objects as the build sees them".
## [param impostor_cell_size] is the far grid's cell size, a property of the store
## ([member CopiaStore3D.impostor_cell_size]), which passes its own; it is used only when the
## object has an impostor mesh. [code]hash[/code] is left out, so the build hashes the fields as
## it reads them.
func descriptor(impostor_cell_size := 0.0) -> Dictionary:
	var settings := _render_settings()
	return {
		"draw": "instance" if settings.draw_mode == RenderScript.DrawMode.INSTANCE else "multimesh",
		"mesh_aabb": mesh.get_aabb() if mesh != null else AABB(),
		"batch_size": settings.batch_size,
		"default_color": _get_default_color(),
		"default_custom": _get_default_custom(),
		"collider": physics != null and physics.has_collider(),
		"collider_min_scale": physics.min_scale if physics != null else 0.0,
		"impostor": impostor_mesh != null,
		"impostor_cell_size": impostor_cell_size if impostor_mesh != null else 0.0,
		"impostor_min_scale": impostor_min_scale,
		"impostor_batch_size": settings.impostor_batch_size if impostor_mesh != null else 0.0,
	}


## Loads the object at [param path]. A path to a [Mesh] gives a temporary object with that mesh
## and default settings; anything else, or a missing file, gives null. Results are cached by path.
static func resolve(path: String) -> Resource:
	if _cache.has(path):
		return _cache[path]
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	var loaded := load(path)
	var result: Resource = null
	var object_script: GDScript = _self_script()
	if is_instance_of(loaded, object_script):
		result = loaded
	elif loaded is Mesh:
		result = object_script.new()
		result.mesh = loaded
	if result != null:
		_cache[path] = result
	return result


## Forgets every resolved object, so the next [method resolve] loads again.
static func clear_cache() -> void:
	_cache.clear()


# This script, by load() at call time: a script cannot preload itself (cyclic reference). The
# load is cached by the resource loader.
static func _self_script() -> GDScript:
	return load(SELF_PATH)


func _render_settings() -> RenderScript:
	if render != null:
		return render
	if _default_render == null:
		_default_render = RenderScript.new()
	return _default_render


func _swap(old: Resource, new: Resource) -> void:
	if old != null:
		if old.changed.is_connected(emit_changed):
			old.changed.disconnect(emit_changed)
		if old.build_inputs_changed.is_connected(_forward_build_inputs):
			old.build_inputs_changed.disconnect(_forward_build_inputs)
	if new != null:
		if not new.changed.is_connected(emit_changed):
			new.changed.connect(emit_changed)
		if not new.build_inputs_changed.is_connected(_forward_build_inputs):
			new.build_inputs_changed.connect(_forward_build_inputs)


func _forward_build_inputs() -> void:
	build_inputs_changed.emit()


# Replacing a sub-resource can change the descriptor, so it counts as a build input change.
func _sub_resource_changed() -> void:
	emit_changed()
	build_inputs_changed.emit()
