class_name HEGoGraphPicking
extends RefCounted

## Screen-space picking for graph points and connections.

## Editor settings for the on-screen size of the markers, in pixels.
const SETTING_POINT_SIZE := "hego/graph/point_size"
const SETTING_LINE_WIDTH := "hego/graph/line_width"
const DEFAULT_POINT_SIZE := 10.0
const DEFAULT_LINE_WIDTH := 2.5

## Pixel radius a click must be within to hit a point, at least; see [method point_radius].
const POINT_RADIUS := 12.0

## Pixel radius a click must be within to hit a connection, at least.
const CONNECTION_RADIUS := 8.0


## Adds the marker size settings to the editor settings if they are missing.
static func register_settings() -> void:
	if not Engine.is_editor_hint():
		return
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting(SETTING_POINT_SIZE):
		settings.set_setting(SETTING_POINT_SIZE, DEFAULT_POINT_SIZE)
	if not settings.has_setting(SETTING_LINE_WIDTH):
		settings.set_setting(SETTING_LINE_WIDTH, DEFAULT_LINE_WIDTH)
	settings.add_property_info({"name": SETTING_POINT_SIZE, "type": TYPE_FLOAT,
			"hint": PROPERTY_HINT_RANGE, "hint_string": "2,64,0.5,suffix:px"})
	settings.add_property_info({"name": SETTING_LINE_WIDTH, "type": TYPE_FLOAT,
			"hint": PROPERTY_HINT_RANGE, "hint_string": "1,16,0.5,suffix:px"})


## Diameter of point markers on screen, in pixels.
static func point_size() -> float:
	if not Engine.is_editor_hint():
		return DEFAULT_POINT_SIZE
	return float(EditorInterface.get_editor_settings().get_setting(SETTING_POINT_SIZE))


## Width of connection lines on screen, in pixels.
static func line_width() -> float:
	if not Engine.is_editor_hint():
		return DEFAULT_LINE_WIDTH
	return float(EditorInterface.get_editor_settings().get_setting(SETTING_LINE_WIDTH))


## Pixel radius for picking a point: the marker radius plus a margin.
static func point_radius() -> float:
	return maxf(POINT_RADIUS, point_size() * 0.5 + 6.0)


## Pixel radius for picking a connection: half the line width plus a margin.
static func connection_radius() -> float:
	return maxf(CONNECTION_RADIUS, line_width() * 0.5 + 5.0)


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


## Indices whose projected positions lie inside [param rect].
static func points_in_rect(rect: Rect2, projected: PackedVector2Array) -> PackedInt32Array:
	var hits := PackedInt32Array()
	for i in projected.size():
		if rect.has_point(projected[i]):
			hits.append(i)
	return hits


## Connection indices whose projected midpoint lies inside [param rect].
static func connections_in_rect(rect: Rect2, projected: PackedVector2Array, connections: PackedInt32Array) -> PackedInt32Array:
	var hits := PackedInt32Array()
	var count := connections.size() / 2
	for c in count:
		var ia: int = connections[c * 2]
		var ib: int = connections[c * 2 + 1]
		if ia < 0 or ib < 0 or ia >= projected.size() or ib >= projected.size():
			continue
		if rect.has_point((projected[ia] + projected[ib]) * 0.5):
			hits.append(c)
	return hits


## Closest point on segment [param a]–[param b] to [param point].
static func closest_on_segment(a: Vector3, b: Vector3, point: Vector3) -> Vector3:
	var ab := b - a
	var length_sq := ab.length_squared()
	if length_sq < 0.000001:
		return a
	var t := clampf((point - a).dot(ab) / length_sq, 0.0, 1.0)
	return a + ab * t
