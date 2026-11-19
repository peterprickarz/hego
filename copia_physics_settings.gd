@tool
class_name CopiaPhysicsSettings
extends Resource
## The collider of a [CopiaObject]. Objects can share one resource (every rock: convex hull,
## same layer and mask); a variant with its own shapes has its own. An object without physics
## settings has no collider. Only [member min_scale] and whether the settings produce a collider
## are build inputs; the rest applies when a cell loads.

enum Kind {
	## The shapes listed in [member shapes].
	SHAPES,
	## The convex hull of the object's mesh, built once per mesh and cached, simplified when
	## [member simplify_hull] is on.
	MESH_CONVEX,
	## The object's mesh as a triangle mesh, built once per mesh and cached.
	MESH_TRIMESH,
	## One box fitted to the mesh's bounds.
	FIT_BOX,
	## One capsule along Y fitted to the mesh's bounds.
	FIT_CAPSULE,
	## One sphere fitted to the mesh's bounds.
	FIT_SPHERE,
	## One cylinder along Y fitted to the mesh's bounds.
	FIT_CYLINDER,
}

## Emitted when [member min_scale] is set, or when the settings start or stop producing a
## collider ([member kind] or [member shapes] switches between having shapes and not).
## [signal Resource.changed] is emitted too.
signal build_inputs_changed

# Mesh-derived shapes per mesh: {Mesh: {key: Shape3D}}, the key being the kind, and for a convex
# hull the kind and whether the hull is simplified.
static var _mesh_shapes := {}

var _had_collider := true

## Where the shapes come from.
@export var kind: Kind = Kind.MESH_CONVEX:
	set(value):
		kind = value
		_shapes_changed()
## For [constant Kind.MESH_CONVEX]: whether Godot reduces the hull to a small number of points.
## Off keeps the hull of the whole mesh, which for a detailed mesh has hundreds of points. The
## hull is always cleaned (duplicate and interior points removed). Changes the shapes, not the
## build descriptor, so it emits [signal Resource.changed] only.
@export var simplify_hull := true:
	set(value):
		if simplify_hull == value: return
		simplify_hull = value
		emit_changed()
## The shapes for [constant Kind.SHAPES]. Entry i is placed by entry i of [member shape_transforms].
@export var shapes: Array[Shape3D] = []:
	set(value):
		shapes = value
		_shapes_changed()
## Local transform of each shape, parallel to [member shapes]. A missing entry is the identity.
@export var shape_transforms: Array[Transform3D] = []:
	set(value):
		shape_transforms = value
		emit_changed()
## Physics layers the colliders are on.
@export_flags_3d_physics var collision_layer := 1:
	set(value):
		collision_layer = value
		emit_changed()
## Physics layers the colliders detect.
@export_flags_3d_physics var collision_mask := 1:
	set(value):
		collision_mask = value
		emit_changed()
## Instances whose scale (the length of the transform's basis Y column) is below this get no
## collider. 0 gives every instance one. A build input.
@export_range(0.0, 100.0, 0.01, "or_greater") var min_scale := 0.0:
	set(value):
		value = maxf(value, 0.0)
		if is_equal_approx(min_scale, value): return
		min_scale = value
		emit_changed()
		build_inputs_changed.emit()
## Horizontal distance in metres from a store source with colliders (the store's target or a
## [CopiaSource3D] with [code]colliders[/code] on) within which colliders exist. 0 uses
## the store's [member CopiaStore3D.collider_distance].
@export_range(0.0, 100000.0, 1.0, "or_greater", "suffix:m") var distance := 0.0:
	set(value):
		distance = maxf(value, 0.0)
		emit_changed()


## Whether these settings produce a collider: every kind but [constant Kind.SHAPES] does, and
## [constant Kind.SHAPES] does when it lists at least one shape.
func has_collider() -> bool:
	if kind != Kind.SHAPES:
		return true
	for shape in shapes:
		if shape != null:
			return true
	return false


## The shapes of a collider for [param mesh], as [code][{shape: Shape3D, transform: Transform3D}][/code].
## A pure function of the settings and the mesh, usable without a scene. Mesh-derived shapes are
## cached per mesh and shared between calls; fitted primitives are centred on the mesh's bounds,
## with capsule and cylinder along Y. A kind that needs a mesh gives an empty array without one;
## [constant Kind.SHAPES] ignores the mesh.
func resolve_shapes(mesh: Mesh) -> Array:
	var result := []
	if kind == Kind.SHAPES:
		for i in shapes.size():
			if shapes[i] == null:
				continue
			var placement := shape_transforms[i] if i < shape_transforms.size() else Transform3D.IDENTITY
			result.append({"shape": shapes[i], "transform": placement})
		return result
	if mesh == null:
		return result
	if kind == Kind.MESH_CONVEX or kind == Kind.MESH_TRIMESH:
		var per_mesh: Dictionary = _mesh_shapes.get_or_add(mesh, {})
		var key: Variant = kind
		if kind == Kind.MESH_CONVEX:
			key = "convex_simplified" if simplify_hull else "convex_full"
		if not per_mesh.has(key):
			per_mesh[key] = mesh.create_convex_shape(true, simplify_hull) if kind == Kind.MESH_CONVEX else mesh.create_trimesh_shape()
		if per_mesh[key] != null:
			result.append({"shape": per_mesh[key], "transform": Transform3D.IDENTITY})
		return result
	var bounds := mesh.get_aabb()
	var size := bounds.size.max(Vector3.ONE * 0.001)
	var radius := maxf(size.x, size.z) * 0.5
	var shape: Shape3D
	match kind:
		Kind.FIT_BOX:
			var box := BoxShape3D.new()
			box.size = size
			shape = box
		Kind.FIT_CAPSULE:
			var capsule := CapsuleShape3D.new()
			capsule.radius = radius
			capsule.height = maxf(size.y, radius * 2.0)
			shape = capsule
		Kind.FIT_SPHERE:
			var sphere := SphereShape3D.new()
			sphere.radius = maxf(size.x, maxf(size.y, size.z)) * 0.5
			shape = sphere
		Kind.FIT_CYLINDER:
			var cylinder := CylinderShape3D.new()
			cylinder.radius = radius
			cylinder.height = size.y
			shape = cylinder
	if shape != null:
		result.append({"shape": shape, "transform": Transform3D(Basis.IDENTITY, bounds.get_center())})
	return result


## Frees the cached mesh-derived shapes.
static func clear_cache() -> void:
	_mesh_shapes.clear()


func _shapes_changed() -> void:
	emit_changed()
	var now := has_collider()
	if now != _had_collider:
		_had_collider = now
		build_inputs_changed.emit()
