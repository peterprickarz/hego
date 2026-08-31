@tool
class_name HEGoTerrain3DInstancer
extends RefCounted

## Scatters scenes onto an existing Terrain3D through its instancer.
##
## The point fetch groups points by terrain node path and then by scene path, so one
## HDA can populate several terrains with several scenes each. Slots HEGo generated on
## a previous cook are recognised by their [code]hegot3d_[/code] name prefix and reused,
## which keeps hand-authored mesh assets untouched.

## Config the point fetch is driven by.
const FETCH_CONFIG_PATH := "res://addons/hego/point_filters/fetch_points_default_terrain3d.tres"

## Name prefix of the mesh asset slots HEGo owns.
const GENERATED_MESH_PREFIX := "hegot3d_"

## Terrain3DMeshAsset properties an HDA can drive, keyed by point attribute name.
const MESH_ASSET_ATTRIBS := {
	"hegot3d_lod0_range": "lod0_range",
	"hegot3d_lod1_range": "lod1_range",
	"hegot3d_lod2_range": "lod2_range",
	"hegot3d_lod3_range": "lod3_range",
	"hegot3d_lod4_range": "lod4_range",
	"hegot3d_lod5_range": "lod5_range",
	"hegot3d_lod6_range": "lod6_range",
	"hegot3d_lod7_range": "lod7_range",
	"hegot3d_lod8_range": "lod8_range",
	"hegot3d_lod9_range": "lod9_range",
	"hegot3d_shadow_impostor": "shadow_impostor",
	"hegot3d_last_lod": "last_lod",
	"hegot3d_last_shadow_lod": "last_shadow_lod",
	"hegot3d_fade_margin": "fade_margin",
}


## Fetches the instancing points of [param host]'s asset node and populates the terrains.
static func handle(host: Node) -> void:
	if not HEGoTerrain3DUtil.is_available():
		return

	var fetch_config: Resource = load(FETCH_CONFIG_PATH)
	if fetch_config == null:
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Terrain3D instancer fetch config could not be loaded.")
		return

	var outputs: Variant = await HEGoNodeUtil.await_task(host, host.hego_asset_node.fetch_points(fetch_config))
	if not outputs is Dictionary or outputs.is_empty():
		return

	for terrain_path_value in outputs.keys():
		if terrain_path_value == null:
			continue
		var terrain_path := str(terrain_path_value).strip_edges()
		if terrain_path.is_empty():
			continue

		var per_scene_points: Variant = outputs[terrain_path_value]
		if not per_scene_points is Dictionary:
			push_warning(HEGoNodeUtil.LOG_PREFIX + "Unexpected Terrain3D instancer fetch structure for %s." % terrain_path)
			continue

		_populate_terrain(host, terrain_path, per_scene_points)


## Fills one terrain's instancer with every scene in [param per_scene_points].
static func _populate_terrain(host: Node, terrain_path: String, per_scene_points: Dictionary) -> void:
	var terrain := HEGoTerrain3DUtil.find_node_from_path(host, terrain_path)
	if terrain == null:
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Terrain3D node %s was not found, skipping instancer output." % terrain_path)
		return

	if not terrain.has_method("get_instancer"):
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Node %s does not expose a Terrain3D instancer." % terrain_path)
		return

	var instancer: Object = terrain.call("get_instancer")
	if instancer == null:
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Terrain3D instancer is unavailable on %s." % terrain_path)
		return

	var assets := HEGoTerrain3DUtil.get_terrain_assets(terrain)
	if assets == null:
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Terrain3D assets are unavailable on %s." % terrain_path)
		return

	# Drop everything the previous cook generated, so removed scenes disappear.
	_clear_generated_mesh_slots(assets, instancer)
	if assets.has_signal("meshes_changed"):
		assets.emit_signal("meshes_changed")

	for scene_path_value in per_scene_points.keys():
		if scene_path_value == null:
			continue
		var scene_path := str(scene_path_value).strip_edges()
		if scene_path.is_empty():
			continue

		var point_dict: Variant = per_scene_points[scene_path_value]
		if not point_dict is Dictionary:
			push_warning(HEGoNodeUtil.LOG_PREFIX + "Invalid point dictionary for Terrain3D scene %s." % scene_path)
			continue
		if not point_dict.has("P") or not point_dict["P"] is Array:
			push_warning(HEGoNodeUtil.LOG_PREFIX + "Missing P attribute for Terrain3D scene %s." % scene_path)
			continue
		if point_dict["P"].is_empty():
			continue

		var mesh_slot := _find_mesh_slot_by_scene_path(assets, scene_path)
		if mesh_slot < 0:
			mesh_slot = _assign_generated_mesh_slot(assets, scene_path)
			if mesh_slot < 0:
				push_warning(HEGoNodeUtil.LOG_PREFIX + "Could not allocate Terrain3D mesh slot for %s." % scene_path)
				continue

		var mesh_asset: Object = assets.call("get_mesh_asset", mesh_slot)
		if mesh_asset != null:
			_apply_mesh_asset_settings(mesh_asset, point_dict)

		if instancer.has_method("clear_by_mesh"):
			instancer.call("clear_by_mesh", mesh_slot)

		var instances := _build_instances(point_dict)
		if instances["transforms"].is_empty():
			continue

		if not instancer.has_method("add_transforms"):
			push_warning(HEGoNodeUtil.LOG_PREFIX + "Terrain3D instancer on %s does not support add_transforms." % terrain_path)
			break

		instancer.call("add_transforms", mesh_slot, instances["transforms"], instances["colors"], false)

	if instancer.has_method("update_mmis"):
		instancer.call("update_mmis", false)


## Builds the per-point transforms and colours for one scene.
## Kept in sync with the multimesh output so both scatter modes orient points alike.
static func _build_instances(point_dict: Dictionary) -> Dictionary:
	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	var positions: Array = point_dict["P"]

	for i in range(positions.size()):
		var position: Variant = positions[i]
		if not position is Vector3:
			continue

		var normal: Vector3 = HEGoNodeUtil.get_typed_point_attrib(point_dict, "N", i, TYPE_VECTOR3, Vector3(0, 0, 1)).normalized()
		var up: Vector3 = HEGoNodeUtil.get_typed_point_attrib(point_dict, "up", i, TYPE_VECTOR3, Vector3(0, 1, 0)).normalized()
		var point_scale: Vector3 = HEGoNodeUtil.get_typed_point_attrib(point_dict, "scale", i, TYPE_VECTOR3, Vector3.ONE)
		var pscale := float(HEGoNodeUtil.get_typed_point_attrib(point_dict, "pscale", i, TYPE_FLOAT, 1.0))

		var basis := Basis()
		var right := up.cross(normal).normalized()
		if right != Vector3.ZERO:
			basis.x = right
			basis.y = up
			basis.z = normal
		transforms.append(Transform3D(basis.scaled(point_scale * pscale), position))

		colors.append(_read_color(point_dict, i))

	return {"transforms": transforms, "colors": colors}


## Reads Cd for one point, accepting both [Color] and [Vector3] and defaulting to white.
static func _read_color(point_dict: Dictionary, index: int) -> Color:
	var value: Variant = HEGoNodeUtil.get_point_attrib(point_dict, "Cd", index, null)
	if value is Color:
		return value
	if value is Vector3:
		return Color(value.x, value.y, value.z, 1.0)
	return Color(1.0, 1.0, 1.0, 1.0)


## Empties every mesh slot HEGo generated, returning the slots that were freed.
static func _clear_generated_mesh_slots(assets: Object, instancer: Object) -> Array:
	var removed_slots: Array = []
	if assets == null or not assets.has_method("get_mesh_count"):
		return removed_slots

	for slot in range(int(assets.call("get_mesh_count"))):
		var mesh_asset: Object = assets.call("get_mesh_asset", slot)
		if mesh_asset == null:
			continue
		if not _get_mesh_asset_name(mesh_asset).begins_with(GENERATED_MESH_PREFIX):
			continue

		if instancer != null and instancer.has_method("clear_by_mesh"):
			instancer.call("clear_by_mesh", slot)
		assets.call("set_mesh_asset", slot, null)
		removed_slots.append(slot)

	return removed_slots


## Slot already holding [param scene_path], or -1 when there is none.
static func _find_mesh_slot_by_scene_path(assets: Object, scene_path: String) -> int:
	if assets == null or scene_path.is_empty() or not assets.has_method("get_mesh_count"):
		return -1

	for slot in range(int(assets.call("get_mesh_count"))):
		var mesh_asset: Object = assets.call("get_mesh_asset", slot)
		if mesh_asset == null:
			continue
		# Only reuse procedural slots owned by HEGo to avoid touching hand-authored mesh assets.
		if not _get_mesh_asset_name(mesh_asset).begins_with(GENERATED_MESH_PREFIX):
			continue
		if _get_mesh_asset_scene_path(mesh_asset) == scene_path:
			return slot

	return -1


## Creates a Terrain3DMeshAsset for [param scene_path] and puts it in a free slot,
## returning that slot or -1 if the scene or a slot is unavailable.
static func _assign_generated_mesh_slot(assets: Object, scene_path: String) -> int:
	if assets == null or scene_path.is_empty() or not assets.has_method("get_mesh_count"):
		return -1

	if not ResourceLoader.exists(scene_path):
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Terrain3D scene resource does not exist: %s" % scene_path)
		return -1

	var scene_res: Resource = load(scene_path)
	if not scene_res is PackedScene:
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Terrain3D mesh asset expects PackedScene at %s." % scene_path)
		return -1

	if not ClassDB.class_exists("Terrain3DMeshAsset"):
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Terrain3DMeshAsset class is unavailable, skipping %s." % scene_path)
		return -1

	var mesh_asset: Object = ClassDB.instantiate("Terrain3DMeshAsset")
	if mesh_asset == null:
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Failed to instantiate Terrain3DMeshAsset for %s." % scene_path)
		return -1

	mesh_asset.call("set_scene_file", scene_res)
	if mesh_asset.has_method("set_name"):
		mesh_asset.call("set_name", GENERATED_MESH_PREFIX + scene_path.get_file().get_basename())

	var mesh_count := int(assets.call("get_mesh_count"))
	for slot in range(mesh_count):
		if assets.call("get_mesh_asset", slot) == null:
			assets.call("set_mesh_asset", slot, mesh_asset)
			return slot

	if ClassDB.class_exists("Terrain3DAssets") and ClassDB.class_has_integer_constant("Terrain3DAssets", "MAX_MESHES"):
		if mesh_count >= int(ClassDB.class_get_integer_constant("Terrain3DAssets", "MAX_MESHES")):
			push_warning(HEGoNodeUtil.LOG_PREFIX + "Terrain3D mesh asset limit reached, cannot assign %s." % scene_path)
			return -1

	assets.call("set_mesh_asset", mesh_count, mesh_asset)
	return mesh_count


## Applies the LOD and shadow settings the points carry to the mesh asset.
static func _apply_mesh_asset_settings(mesh_asset: Object, point_dict: Dictionary) -> void:
	for attr_name in MESH_ASSET_ATTRIBS.keys():
		# These are detail-style settings, so the value of the first point wins.
		var value: Variant = HEGoNodeUtil.get_point_attrib(point_dict, attr_name, 0, null)
		if value != null:
			HEGoTerrain3DUtil.set_optional_property(mesh_asset, MESH_ASSET_ATTRIBS[attr_name], value)


## Name of a mesh asset, tolerating Terrain3D versions that only expose the property.
static func _get_mesh_asset_name(mesh_asset: Object) -> String:
	if mesh_asset == null:
		return ""
	if mesh_asset.has_method("get_name"):
		return str(mesh_asset.call("get_name"))
	return str(mesh_asset.get("name"))


## Scene path a mesh asset was built from, or an empty string.
static func _get_mesh_asset_scene_path(mesh_asset: Object) -> String:
	if mesh_asset == null:
		return ""

	if mesh_asset.has_method("get_scene_file"):
		var scene_res: Variant = mesh_asset.call("get_scene_file")
		if scene_res is Resource and not scene_res.resource_path.is_empty():
			return scene_res.resource_path

	var scene_prop: Variant = mesh_asset.get("scene_file")
	if scene_prop is Resource and not scene_prop.resource_path.is_empty():
		return scene_prop.resource_path

	return ""
