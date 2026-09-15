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


## Intersection of a ray with [param plane], or [code]null[/code] if it misses
## or hits behind the origin.
static func intersect_ray(origin: Vector3, direction: Vector3, plane: Plane) -> Variant:
	var hit: Variant = plane.intersects_ray(origin, direction)
	if hit == null:
		return null
	if direction.dot(hit - origin) < -0.0001:
		return null
	return hit
