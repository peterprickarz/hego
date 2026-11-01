@tool
class_name StrataBrushCursor
extends MeshInstance3D
## Brush footprint drawn on the previewed surface: an outer band at the dab radius and a
## fainter inner band where the falloff reaches half strength. The editor plugin owns it,
## adds it as an internal child of the terrain and never saves it with the scene.

## Fraction of the radius at which the smoothstep falloff reaches 0.5 (see StrataBrush).
const HALF_INFLUENCE := 0.5
const SEGMENTS_MIN := 48
const SEGMENTS_MAX := 192
## Bands sit this far above the surface so they do not z-fight with it.
const LIFT := 0.05

var _mesh := ImmediateMesh.new()
var _material := StandardMaterial3D.new()

func _init() -> void:
	name = "BrushCursor"
	mesh = _mesh
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.no_depth_test = true
	_material.render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false

## Draws the footprint of a dab of [param radius] metres around [param centre], given in the
## terrain's local XZ plane, following the surface shown for [param layer]. [param blocked]
## colours it red when the dab would be refused. [param band_width] is the band thickness
## in metres; pass a value scaled by the camera distance to keep it a few pixels wide.
func show_at(terrain: StrataTerrain3D, layer: StrataLayer, centre: Vector2, radius: float, blocked: bool, band_width: float = 0.25) -> void:
	if not is_instance_valid(terrain) or not centre.is_finite() or not is_finite(radius) or radius <= 0.0:
		hide_cursor()
		return
	var segments := clampi(int(radius * 4.0), SEGMENTS_MIN, SEGMENTS_MAX)
	var colour := Color(1.0, 0.32, 0.22, 0.95) if blocked else Color(1.0, 0.86, 0.25, 0.95)
	var width := maxf(band_width, 0.01)
	_mesh.clear_surfaces()
	_band(terrain, layer, centre, radius, width, segments, colour)
	_band(terrain, layer, centre, radius * HALF_INFLUENCE, width * 0.6, segments, Color(colour, 0.4))
	visible = true

func hide_cursor() -> void:
	visible = false

func _band(terrain: StrataTerrain3D, layer: StrataLayer, centre: Vector2, radius: float, width: float, segments: int, colour: Color) -> void:
	var inner := maxf(radius - width * 0.5, 0.0)
	var outer := radius + width * 0.5
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	_mesh.surface_set_color(colour)
	for i in range(segments + 1):
		var angle := TAU * float(i) / float(segments)
		var direction := Vector2(cos(angle), sin(angle))
		_mesh.surface_add_vertex(_surface_point(terrain, layer, centre + direction * inner))
		_mesh.surface_add_vertex(_surface_point(terrain, layer, centre + direction * outer))
	_mesh.surface_end()

## Terrain-local point on the surface the viewport shows: the textured preview's height
## when it is live, otherwise the stack composed through [param layer].
static func _surface_point(terrain: StrataTerrain3D, layer: StrataLayer, point: Vector2) -> Vector3:
	var height: float
	if is_instance_valid(terrain.editor_renderer):
		height = terrain.editor_renderer.sample_render_height(point)
	else:
		height = terrain.sample_height(point, layer if is_instance_valid(layer) and layer.get_parent() == terrain else null)
	if not is_finite(height): height = 0.0
	return Vector3(point.x, height + LIFT, point.y)
