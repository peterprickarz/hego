class_name HEGoGraphSurface
extends RefCounted

## Finds the ground under a [HEGoGraphInput3D] point, for snapping and for draping the
## path visualisation.
##
## The surface is, in order:
## [br]1. the graph's [member HEGoGraphInput3D.surface_provider] node, when it has a
## [code]sample_height(Vector2) -> float[/code] method (height in the provider's local
## space at a local x/z position). A [code]contains_position(Vector2) -> bool[/code]
## method, when present, limits where it answers. Nothing here depends on a particular
## terrain addon.
## [br]2. a physics ray straight down, when the graph's world has colliders.
##
## A query that finds nothing returns an empty dictionary and callers keep the point's
## height.

const RAY_HEIGHT := 20000.0
## Sample spacing for estimating a normal from a height provider.
const NORMAL_STEP := 1.5

var _graph: Node3D
var _provider: Node
var _space: PhysicsDirectSpaceState3D


func _init(graph: Node3D = null, provider_path: NodePath = NodePath()) -> void:
	_graph = graph
	if graph == null or not graph.is_inside_tree():
		return
	if not provider_path.is_empty():
		var found := graph.get_node_or_null(provider_path)
		if found != null and found.has_method("sample_height"):
			_provider = found
	if _provider == null:
		var world := graph.get_world_3d()
		if world != null:
			_space = world.direct_space_state


## Whether any surface source is available.
func is_available() -> bool:
	return _provider != null or _space != null


## Surface under [param world_position] (only x and z matter). Returns
## [code]{"position": Vector3, "normal": Vector3}[/code] in world space, or an empty
## dictionary when there is no ground there.
func query(world_position: Vector3) -> Dictionary:
	if _provider != null:
		return _query_provider(world_position)
	if _space != null:
		return _query_physics(world_position)
	return {}


## Same as [method query], but in the graph's local space.
func query_local(local_position: Vector3) -> Dictionary:
	var hit := query(_graph.to_global(local_position))
	if hit.is_empty():
		return hit
	var basis_inv := _graph.global_transform.basis.inverse()
	return {
		"position": _graph.to_local(hit.position),
		"normal": (basis_inv.transposed() * hit.normal).normalized(),
	}


func _height(local: Vector3) -> Variant:
	var xz := Vector2(local.x, local.z)
	if _provider.has_method("contains_position") and not _provider.call("contains_position", xz):
		return null
	var h: Variant = _provider.call("sample_height", xz)
	if h == null or is_nan(h) or is_inf(h):
		return null
	return float(h)


func _query_provider(world_position: Vector3) -> Dictionary:
	var node := _provider as Node3D
	var local := node.to_local(world_position) if node != null else world_position
	var h: Variant = _height(local)
	if h == null:
		return {}
	var step := NORMAL_STEP
	var hx0: Variant = _height(local - Vector3(step, 0, 0))
	var hx1: Variant = _height(local + Vector3(step, 0, 0))
	var hz0: Variant = _height(local - Vector3(0, 0, step))
	var hz1: Variant = _height(local + Vector3(0, 0, step))
	var local_normal := Vector3.UP
	if hx0 != null and hx1 != null and hz0 != null and hz1 != null:
		local_normal = Vector3(hx0 - hx1, 2.0 * step, hz0 - hz1).normalized()
	var local_hit := Vector3(local.x, h, local.z)
	if node == null:
		return {"position": local_hit, "normal": local_normal}
	var normal := (node.global_transform.basis.inverse().transposed() * local_normal).normalized()
	return {"position": node.to_global(local_hit), "normal": normal}


func _query_physics(world_position: Vector3) -> Dictionary:
	var from := Vector3(world_position.x, RAY_HEIGHT, world_position.z)
	var to := Vector3(world_position.x, -RAY_HEIGHT, world_position.z)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var hit := _space.intersect_ray(query)
	if hit.is_empty():
		return {}
	return {"position": hit.position, "normal": hit.normal}
