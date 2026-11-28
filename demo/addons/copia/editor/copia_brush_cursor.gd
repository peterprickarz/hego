@tool
extends RefCounted
## Lightweight RenderingServer 3D brush ring cursor for Copia Paint / Erase mode.
## Draws an outer brush ring and inner core ring conforming to the hit surface normal, without
## adding any nodes to the edited scene.

const SEGMENTS := 48
const PAINT_COLOR := Color(0.25, 0.92, 0.55, 0.95)
const ERASE_COLOR := Color(0.95, 0.30, 0.28, 0.95)

var _scenario := RID()
var _instance := RID()
var _mesh: ImmediateMesh
var _material: StandardMaterial3D
var _visible := false
var _last_radius := -1.0
var _last_erase := false


func set_scenario(scenario: RID) -> void:
	if _scenario == scenario:
		return
	_scenario = scenario
	if _instance.is_valid():
		RenderingServer.instance_set_scenario(_instance, _scenario)


func update(world_pos: Vector3, world_normal: Vector3, radius: float, erase: bool) -> void:
	if not _scenario.is_valid():
		return
	_ensure_created()
	if not is_equal_approx(_last_radius, radius) or _last_erase != erase:
		_rebuild_mesh(radius, erase)
		_last_radius = radius
		_last_erase = erase
	var n := world_normal.normalized() if world_normal.length_squared() > 1e-6 else Vector3.UP
	var q := Quaternion(Vector3.UP, n)
	var xform := Transform3D(Basis(q), world_pos + n * 0.05)
	RenderingServer.instance_set_transform(_instance, xform)
	if not _visible:
		RenderingServer.instance_set_visible(_instance, true)
		_visible = true


func hide() -> void:
	if _visible and _instance.is_valid():
		RenderingServer.instance_set_visible(_instance, false)
	_visible = false


func dispose() -> void:
	if _instance.is_valid():
		RenderingServer.free_rid(_instance)
		_instance = RID()
	_mesh = null
	_material = null
	_visible = false


func _ensure_created() -> void:
	if _instance.is_valid():
		return
	_mesh = ImmediateMesh.new()
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.no_depth_test = true
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_instance = RenderingServer.instance_create()
	RenderingServer.instance_set_base(_instance, _mesh.get_rid())
	RenderingServer.instance_set_scenario(_instance, _scenario)
	RenderingServer.instance_geometry_set_cast_shadows_setting(_instance, RenderingServer.SHADOW_CASTING_SETTING_OFF)
	RenderingServer.instance_set_visible(_instance, false)


func _rebuild_mesh(radius: float, erase: bool) -> void:
	_mesh.clear_surfaces()
	var outer_col := ERASE_COLOR if erase else PAINT_COLOR
	var inner_col := Color(outer_col.r, outer_col.g, outer_col.b, 0.45)
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _material)
	_add_ring(radius, outer_col)
	_add_ring(radius * 0.5, inner_col)
	# Small centre cross.
	var c := clampf(radius * 0.08, 0.06, 0.4)
	_mesh.surface_set_color(outer_col)
	_mesh.surface_add_vertex(Vector3(-c, 0, 0))
	_mesh.surface_add_vertex(Vector3(c, 0, 0))
	_mesh.surface_add_vertex(Vector3(0, 0, -c))
	_mesh.surface_add_vertex(Vector3(0, 0, c))
	_mesh.surface_end()


func _add_ring(r: float, col: Color) -> void:
	_mesh.surface_set_color(col)
	for i in SEGMENTS:
		var a0 := TAU * float(i) / float(SEGMENTS)
		var a1 := TAU * float(i + 1) / float(SEGMENTS)
		_mesh.surface_add_vertex(Vector3(cos(a0) * r, 0.0, sin(a0) * r))
		_mesh.surface_add_vertex(Vector3(cos(a1) * r, 0.0, sin(a1) * r))
