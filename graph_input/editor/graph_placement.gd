class_name HEGoGraphPlacement
extends RefCounted

## Ray hits against the camera plane or a world-aligned plane.

enum Mode {
	CAMERA,
	WORLD,
	GEOMETRY,
}

enum Axis {
	XZ,
	XY,
	YZ,
}


## Plane facing the camera and passing through [param anchor].
static func camera_plane(camera_forward: Vector3, anchor: Vector3) -> Plane:
	var normal := camera_forward.normalized()
	if normal.length_squared() < 0.000001:
		normal = Vector3.FORWARD
	return Plane(normal, anchor)


## World-aligned plane through [param origin] offset along its normal.
static func world_plane(axis: Axis, origin: Vector3, offset: float) -> Plane:
	match axis:
		Axis.XY:
			return Plane(Vector3.FORWARD, origin + Vector3(0, 0, offset))
		Axis.YZ:
			return Plane(Vector3.RIGHT, origin + Vector3(offset, 0, 0))
		_:
			return Plane(Vector3.UP, origin + Vector3(0, offset, 0))


## Nearest hit against physics, meshes, CSG, and Terrain3D under [param root].
## [param exclude] and its descendants are skipped. Returns a Vector3 or null.
static func intersect_scene(root: Node, origin: Vector3, direction: Vector3, exclude: Node = null) -> Variant:
	var best: Variant = null
	var best_dist := INF
	var far := origin + direction * 100000.0

	if root is Node3D:
		var world: World3D = (root as Node3D).get_world_3d()
		if world != null:
			var space := world.direct_space_state
			if space != null:
				var query := PhysicsRayQueryParameters3D.create(origin, far)
				var hit := space.intersect_ray(query)
				if not hit.is_empty() and not _is_under(hit.get("collider"), exclude):
					best = hit.position
					best_dist = origin.distance_to(hit.position)

	best = _walk_geometry(root, origin, direction, exclude, best, best_dist)
	return best


static func _walk_geometry(node: Node, origin: Vector3, direction: Vector3, exclude: Node, best: Variant, best_dist: float) -> Variant:
	if node == null or _is_under(node, exclude):
		return best

	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var hit: Variant = _intersect_mesh(node, origin, direction)
		if hit != null:
			var dist: float = origin.distance_to(hit)
			if dist < best_dist:
				best = hit
				best_dist = dist

	if node is CSGShape3D:
		var baked: Mesh = node.bake_static_mesh()
		if baked != null:
			var mi := MeshInstance3D.new()
			mi.mesh = baked
			mi.global_transform = (node as Node3D).global_transform
			var hit: Variant = _intersect_mesh(mi, origin, direction)
			mi.free()
			if hit != null:
				var dist: float = origin.distance_to(hit)
				if dist < best_dist:
					best = hit
					best_dist = dist

	if node.is_class("Terrain3D") and node.has_method("get_intersection"):
		var terrain_hit: Variant = node.call("get_intersection", origin, direction, true)
		if terrain_hit is Vector3 and not is_nan(terrain_hit.y) and terrain_hit.z < 3.4e38:
			var dist: float = origin.distance_to(terrain_hit)
			if dist < best_dist:
				best = terrain_hit
				best_dist = dist

	for child in node.get_children():
		var walked: Variant = _walk_geometry(child, origin, direction, exclude, best, best_dist)
		if walked != null:
			var dist: float = origin.distance_to(walked)
			if best == null or dist < best_dist:
				best = walked
				best_dist = dist
	return best


static func _intersect_mesh(mi: MeshInstance3D, origin: Vector3, direction: Vector3) -> Variant:
	var mesh := mi.mesh
	if mesh == null:
		return null
	var inv := mi.global_transform.affine_inverse()
	var local_origin := inv * origin
	var local_dir := (inv.basis * direction).normalized()
	var aabb := mesh.get_aabb()
	if not aabb.intersects_segment(local_origin, local_origin + local_dir * 100000.0):
		return null

	var best: Variant = null
	var best_dist := INF
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		if arrays.is_empty():
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if indices.size() >= 3:
			for i in range(0, indices.size() - 2, 3):
				var hit: Variant = Geometry3D.ray_intersects_triangle(
						local_origin, local_dir, verts[indices[i]], verts[indices[i + 1]], verts[indices[i + 2]])
				if hit != null:
					var dist: float = local_origin.distance_to(hit)
					if dist < best_dist:
						best = hit
						best_dist = dist
		else:
			for i in range(0, verts.size() - 2, 3):
				var hit: Variant = Geometry3D.ray_intersects_triangle(
						local_origin, local_dir, verts[i], verts[i + 1], verts[i + 2])
				if hit != null:
					var dist: float = local_origin.distance_to(hit)
					if dist < best_dist:
						best = hit
						best_dist = dist
	if best == null:
		return null
	return mi.global_transform * best


static func _is_under(node: Object, ancestor: Node) -> bool:
	if ancestor == null or node == null or not node is Node:
		return false
	var current: Node = node
	while current != null:
		if current == ancestor:
			return true
		current = current.get_parent()
	return false


## Intersection of a ray with [param plane], or [code]null[/code] if it misses
## or hits behind the origin.
static func intersect_ray(origin: Vector3, direction: Vector3, plane: Plane) -> Variant:
	var hit: Variant = plane.intersects_ray(origin, direction)
	if hit == null:
		return null
	if direction.dot(hit - origin) < -0.0001:
		return null
	return hit
