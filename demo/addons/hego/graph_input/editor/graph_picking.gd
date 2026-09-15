class_name HEGoGraphPicking
extends RefCounted

## Screen-space picking for graph points and connections.

## Pixel radius a click must be within to hit a point.
const POINT_RADIUS := 12.0

## Pixel radius a click must be within to hit a connection.
const CONNECTION_RADIUS := 8.0


## Index of the projected point closest to [param mouse] within [param radius], or -1.
static func closest_point(mouse: Vector2, projected: PackedVector2Array, radius: float = POINT_RADIUS) -> int:
	var best := -1
	var best_dist := radius
	for i in projected.size():
		var dist := projected[i].distance_to(mouse)
		if dist <= best_dist:
			best_dist = dist
			best = i
	return best


## Distance from [param mouse] to the segment [param a]–[param b] in 2D.
static func distance_to_segment(mouse: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length_sq := ab.length_squared()
	if length_sq < 0.000001:
		return mouse.distance_to(a)
	var t := clampf((mouse - a).dot(ab) / length_sq, 0.0, 1.0)
	return mouse.distance_to(a + ab * t)


## Index of the connection whose projected segment is closest to [param mouse], or -1.
static func closest_connection(mouse: Vector2, projected: PackedVector2Array, connections: PackedInt32Array, radius: float = CONNECTION_RADIUS) -> int:
	var best := -1
	var best_dist := radius
	var count := connections.size() / 2
	for c in count:
		var ia: int = connections[c * 2]
		var ib: int = connections[c * 2 + 1]
		if ia < 0 or ib < 0 or ia >= projected.size() or ib >= projected.size():
			continue
		var dist := distance_to_segment(mouse, projected[ia], projected[ib])
		if dist <= best_dist:
			best_dist = dist
			best = c
	return best


## Closest point on segment [param a]–[param b] to [param point].
static func closest_on_segment(a: Vector3, b: Vector3, point: Vector3) -> Vector3:
	var ab := b - a
	var length_sq := ab.length_squared()
	if length_sq < 0.000001:
		return a
	var t := clampf((point - a).dot(ab) / length_sq, 0.0, 1.0)
	return a + ab * t
