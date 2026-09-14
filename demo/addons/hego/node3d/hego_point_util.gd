@tool
class_name HEGoPointUtil
extends RefCounted

## Point attribute maths shared by every handler that scatters something.
##
## Multimesh instancing, object spawning and Terrain3D instancing all turn the same four
## point attributes - [code]N[/code], [code]up[/code], [code]pscale[/code] and
## [code]scale[/code] - into the same orientation. Having it in one place is what keeps an
## HDA's points landing identically whichever of the three reads them, and is where to
## look when they do not.

## Attributes [method basis_from_point] reads. A point missing any of them falls back to
## the defaults below, so loading them is optional but everything ends up unrotated.
const ORIENTATION_ATTRIBS := ["N", "up", "pscale", "scale"]

## Attribute [method read_color] reads. Handlers that tint their output add this to
## [constant ORIENTATION_ATTRIBS]; object spawning does not, because it does not tint.
const COLOR_ATTRIB := "Cd"

## Direction a point faces when it carries no N.
const DEFAULT_NORMAL := Vector3(0, 0, 1)

## Direction treated as up when a point carries no up.
const DEFAULT_UP := Vector3(0, 1, 0)


## Orientation and scale for point [param index], from its N, up, scale and pscale.
##
## An N and up that are collinear leave no frame to build, so such a point keeps an
## unrotated basis. That is reported by [method is_orientation_collinear] rather than from
## here, so a caller can count the points it happened to and say so once instead of once
## per point.
static func basis_from_point(points: Dictionary, index: int) -> Basis:
	var normal: Vector3 = HEGoNodeUtil.get_typed_point_attrib(points, "N", index, TYPE_VECTOR3, DEFAULT_NORMAL).normalized()
	var up: Vector3 = HEGoNodeUtil.get_typed_point_attrib(points, "up", index, TYPE_VECTOR3, DEFAULT_UP).normalized()
	var point_scale: Vector3 = HEGoNodeUtil.get_typed_point_attrib(points, "scale", index, TYPE_VECTOR3, Vector3.ONE)
	var pscale := float(HEGoNodeUtil.get_typed_point_attrib(points, "pscale", index, TYPE_FLOAT, 1.0))

	var basis := Basis()
	var right := up.cross(normal).normalized()
	if right != Vector3.ZERO:
		basis.x = right
		basis.y = up
		basis.z = normal

	return basis.scaled(point_scale * pscale)


## The transform for point [param index], oriented by [method basis_from_point] and placed
## at [param position].
static func transform_from_point(points: Dictionary, index: int, position: Vector3) -> Transform3D:
	return Transform3D(basis_from_point(points, index), position)


## Whether point [param index] carries an N and up that are collinear, which leaves no
## frame to build and gives the point an unrotated basis.
static func is_orientation_collinear(points: Dictionary, index: int) -> bool:
	var normal: Vector3 = HEGoNodeUtil.get_typed_point_attrib(points, "N", index, TYPE_VECTOR3, DEFAULT_NORMAL).normalized()
	var up: Vector3 = HEGoNodeUtil.get_typed_point_attrib(points, "up", index, TYPE_VECTOR3, DEFAULT_UP).normalized()
	return up.cross(normal).normalized() == Vector3.ZERO


## Whether these points carry a usable Cd attribute at all, so a caller can skip setting up
## per-instance colour when nothing would use it.
static func has_any_color(points: Dictionary) -> bool:
	if not points.has(COLOR_ATTRIB) or not points[COLOR_ATTRIB] is Array:
		return false
	var colors: Array = points[COLOR_ATTRIB]
	return not colors.is_empty() and colors[0] != null


## Reads Cd for point [param index], accepting both [Color] and [Vector3] and defaulting to
## white. Houdini hands colour back as either depending on how the attribute was created.
static func read_color(points: Dictionary, index: int) -> Color:
	var value: Variant = HEGoNodeUtil.get_point_attrib(points, COLOR_ATTRIB, index, null)
	if value is Color:
		return value
	if value is Vector3:
		return Color(value.x, value.y, value.z, 1.0)
	return Color(1.0, 1.0, 1.0, 1.0)
