@tool
extends RefCounted
## Unified editor surface raycaster for Copia placement and painting:
## - Queries Godot's PhysicsServer3D (direct_space_state) for meshes, cliffs, Copia colliders
##   and any terrain with editor physics bodies.
## - Also queries any visible heightfield terrain node in the edited scene that implements
##   `raycast_surface(origin, direction, max_distance)` (for terrains whose collision is
##   runtime-only and has no editor physics bodies), with zero hard dependency on any terrain addon.
## - Returns the closest allowed hit: {position, normal, distance, kind ("terrain"|"mesh"|"copia"), rid, collider}.

var _scene_root: Node = null
var _terrains: Array[Node3D] = []
var _last_scan_msec := 0


func invalidate() -> void:
	_scene_root = null
	_terrains.clear()
	_last_scan_msec = 0


## Casts a world-space ray from [param origin] along normalised [param direction] up to
## [param max_distance] and returns the closest hit permitted by the surface flags.
func raycast(store: Node3D, origin: Vector3, direction: Vector3, max_distance: float,
		collision_mask := 0xFFFFFFFF, allow_terrain := true, allow_meshes := true, allow_copia := true) -> Dictionary:
	if not is_instance_valid(store) or not store.is_inside_tree():
		return {}
	var dir := direction.normalized()
	if dir.length_squared() < 1e-8:
		return {}

	var best := {}
	var best_dist := max_distance

	# 1. PhysicsServer3D raycast (meshes, cliffs, Copia colliders, physics-backed terrains).
	var space := store.get_world_3d().direct_space_state
	if space != null and (allow_meshes or allow_copia or allow_terrain):
		var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * max_distance, collision_mask)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			var kind := _classify_physics_hit(store, hit)
			if _kind_allowed(kind, allow_terrain, allow_meshes, allow_copia):
				var pos: Vector3 = hit.position
				var dist := origin.distance_to(pos)
				if dist < best_dist:
					best_dist = dist
					best = {
						"position": pos,
						"normal": (hit.normal as Vector3).normalized(),
						"distance": dist,
						"kind": kind,
						"rid": hit.get("rid", RID()),
						"collider": hit.get("collider"),
					}

	# 2. Heightfield terrain nodes exposing raycast_surface() in the editor.
	if allow_terrain:
		_ensure_terrains(store)
		for terrain in _terrains:
			if not is_instance_valid(terrain) or not terrain.is_visible_in_tree():
				continue
			var thit: Variant = terrain.call(&"raycast_surface", origin, dir, best_dist)
			if not (thit is Dictionary) or (thit as Dictionary).is_empty():
				continue
			var pos: Vector3 = thit.get("position", Vector3.ZERO)
			var dist := float(thit.get("distance", origin.distance_to(pos)))
			if dist < best_dist:
				best_dist = dist
				best = {
					"position": pos,
					"normal": _terrain_normal(terrain, thit),
					"distance": dist,
					"kind": "terrain",
					"rid": RID(),
					"collider": terrain,
				}

	return best


func _ensure_terrains(store: Node3D) -> void:
	var root := _root_of(store)
	var now := Time.get_ticks_msec()
	if root == _scene_root and (now - _last_scan_msec) < 5000:
		return
	_scene_root = root
	_last_scan_msec = now
	_terrains.clear()
	if root != null:
		_collect_terrains(root, _terrains)


static func _root_of(node: Node) -> Node:
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		var edited := EditorInterface.get_edited_scene_root()
		if edited != null:
			return edited
	if node.owner != null:
		return node.owner
	var cur := node
	while cur.get_parent() != null and not cur.get_parent() is Window:
		cur = cur.get_parent()
	return cur


static func _collect_terrains(node: Node, out: Array[Node3D]) -> void:
	if node is Node3D and node.has_method(&"raycast_surface"):
		out.append(node as Node3D)
	for child in node.get_children():
		_collect_terrains(child, out)


static func _terrain_normal(terrain: Node3D, hit: Dictionary) -> Vector3:
	if hit.has("normal") and hit.normal is Vector3 and (hit.normal as Vector3).length_squared() > 1e-6:
		return (hit.normal as Vector3).normalized()
	if not hit.has("local_position"):
		return Vector3.UP
	var lp: Vector2 = hit.local_position
	var eps := 0.5
	var hx0 := _sample_terrain_height(terrain, lp + Vector2(-eps, 0.0))
	var hx1 := _sample_terrain_height(terrain, lp + Vector2(eps, 0.0))
	var hz0 := _sample_terrain_height(terrain, lp + Vector2(0.0, -eps))
	var hz1 := _sample_terrain_height(terrain, lp + Vector2(0.0, eps))
	if not (is_finite(hx0) and is_finite(hx1) and is_finite(hz0) and is_finite(hz1)):
		return Vector3.UP
	var local_n := Vector3(hx0 - hx1, 2.0 * eps, hz0 - hz1).normalized()
	return (terrain.global_transform.basis * local_n).normalized()


static func _sample_terrain_height(terrain: Node3D, xz: Vector2) -> float:
	# Prefer editor_renderer.sample_render_height when present (matches raycast_heightfield),
	# falling back to terrain.sample_height().
	var renderer: Variant = terrain.get("editor_renderer")
	if renderer != null and is_instance_valid(renderer) and renderer.has_method(&"sample_render_height"):
		return float(renderer.call(&"sample_render_height", xz))
	if terrain.has_method(&"sample_height"):
		return float(terrain.call(&"sample_height", xz))
	return NAN


static func _classify_physics_hit(store: Node3D, hit: Dictionary) -> String:
	var rid: RID = hit.get("rid", RID())
	if rid.is_valid() and store.has_method(&"get_collider_info"):
		var cinfo: Dictionary = store.call(&"get_collider_info", rid)
		if not cinfo.is_empty():
			return "copia"
	var collider: Object = hit.get("collider")
	if collider == null:
		return "terrain"
	if collider.get_class().contains("Strata") or (collider is Node and str((collider as Node).name).to_lower().contains("terrain")):
		return "terrain"
	return "mesh"


static func _kind_allowed(kind: String, allow_terrain: bool, allow_meshes: bool, allow_copia: bool) -> bool:
	match kind:
		"terrain": return allow_terrain
		"copia": return allow_copia
		_: return allow_meshes
