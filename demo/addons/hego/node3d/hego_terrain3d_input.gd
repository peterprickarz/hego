@tool
class_name HEGoTerrain3DInput
extends RefCounted

## Reads an existing Terrain3D node into heightfield layers Houdini can consume.
##
## Terrain3D stores terrain as independent square regions; Houdini wants one
## rectangular heightfield. The regions are stitched into a single image, and the
## control map is unpacked into one weight layer per texture used, plus masks marking
## which pixels belong to a region at all and which are holes.

## Terrain3DData.get_maps() map types.
const MAP_TYPE_HEIGHT := 0
const MAP_TYPE_CONTROL := 1

## Layer names produced for the heightfield input.
const REGION_MAP_LAYER := "hegot3d_region_map"
const HOLE_LAYER := "hegot3d_hole"

## Attribute carrying the Godot node path back to Houdini.
const NODE_PATH_ATTRIB := "_hego_node_path"

## Attribute carrying a texture layer's Terrain3D texture name.
const TEXTURE_NAME_ATTRIB := "_hego_texture_name"


## Reads [param terrain3d_node] into a layer dictionary for
## [method HEGoHeightfieldInputNode.set_layers], or an empty dictionary on failure.
##
## [param input_node_path] is stored on every layer so the HDA can tell which Godot
## node the heightfield came from.
static func read_layers(terrain3d_node: Node, input_node_path: String = "") -> Dictionary:
	if not HEGoTerrain3DUtil.is_available():
		return {}

	var terrain_data: Object = terrain3d_node.get("data")
	if terrain_data == null:
		push_error(HEGoNodeUtil.LOG_PREFIX + "Failed to get Terrain3D data")
		return {}

	var region_locations: Array = terrain_data.call("get_region_locations")
	if region_locations.is_empty():
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Terrain3D has no regions")
		return {}

	var height_maps: Variant = terrain_data.call("get_maps", MAP_TYPE_HEIGHT)
	if not height_maps is Array or height_maps.is_empty():
		push_error(HEGoNodeUtil.LOG_PREFIX + "Failed to fetch Terrain3D height maps.")
		return {}

	var control_maps: Variant = terrain_data.call("get_maps", MAP_TYPE_CONTROL)
	if not control_maps is Array:
		control_maps = []

	if not ClassDB.class_exists("Terrain3DUtil"):
		push_error(HEGoNodeUtil.LOG_PREFIX + "Terrain3DUtil is unavailable.")
		return {}
	var terrain3d_util: Object = ClassDB.instantiate("Terrain3DUtil")
	if terrain3d_util == null:
		push_error(HEGoNodeUtil.LOG_PREFIX + "Failed to instantiate Terrain3DUtil.")
		return {}

	var region_pixel_size := _get_region_pixel_size(height_maps)
	if region_pixel_size <= 1:
		push_error(HEGoNodeUtil.LOG_PREFIX + "Invalid Terrain3D region image size.")
		return {}
	# Adjacent regions share one border sample, so stride is size-1 in pixel space.
	var region_pixel_stride := region_pixel_size - 1

	var region_count := mini(region_locations.size(), height_maps.size())
	if region_count != region_locations.size() or region_count != height_maps.size():
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Terrain3D region metadata and height maps count differ. Truncating to shared count.")

	# Regions sit on an integer grid; the stitched image spans its bounding box.
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for region_index in range(region_count):
		var region_loc: Vector2i = region_locations[region_index]
		min_x = minf(min_x, region_loc.x)
		max_x = maxf(max_x, region_loc.x)
		min_z = minf(min_z, region_loc.y)
		max_z = maxf(max_z, region_loc.y)

	var total_width := int(max_x - min_x + 1) * region_pixel_stride + 1
	var total_height := int(max_z - min_z + 1) * region_pixel_stride + 1

	# region_mask marks pixels covered by a region, hole_mask marks solid ground.
	var region_mask := Image.create(total_width, total_height, false, Image.FORMAT_RF)
	region_mask.fill(Color(0, 0, 0, 1))
	var hole_mask := Image.create(total_width, total_height, false, Image.FORMAT_RF)
	hole_mask.fill(Color(1, 1, 1, 1))
	var stitched_height := Image.create(total_width, total_height, false, Image.FORMAT_RF)

	# texture_id -> { Vector2i pixel: weight }
	var texture_weights: Dictionary = {}
	var used_texture_ids: Array = []

	for region_index in range(region_count):
		_stitch_region(
			region_locations[region_index],
			height_maps[region_index],
			control_maps[region_index] if region_index < control_maps.size() else null,
			terrain3d_util,
			min_x, min_z, region_pixel_size, region_pixel_stride,
			stitched_height, region_mask, hole_mask, texture_weights, used_texture_ids
		)

	var result := {}
	result["height"] = _make_layer(HEGoTerrain3DUtil.fix_heightfield_image_transform(stitched_height), input_node_path)
	result[REGION_MAP_LAYER] = _make_layer(HEGoTerrain3DUtil.fix_heightfield_image_transform(region_mask), input_node_path)
	result[HOLE_LAYER] = _make_layer(HEGoTerrain3DUtil.fix_heightfield_image_transform(hole_mask), input_node_path)

	for texture_id in used_texture_ids:
		var texture_image := _build_texture_layer(texture_weights, texture_id, total_width, total_height)
		var layer := _make_layer(HEGoTerrain3DUtil.fix_heightfield_image_transform(texture_image), input_node_path)
		layer["attrs"][TEXTURE_NAME_ATTRIB] = HEGoTerrain3DUtil.get_texture_name(terrain3d_node, texture_id)
		result[HEGoTerrain3DUtil.TEXTURE_LAYER_PREFIX + str(texture_id)] = layer

	return result


## World size of one terrain vertex. Convenience wrapper so callers only need this class.
static func get_vertex_spacing(terrain3d_node: Node) -> float:
	return HEGoTerrain3DUtil.get_vertex_spacing(terrain3d_node)


## One entry of the layer dictionary [method HEGoHeightfieldInputNode.set_layers] expects.
static func _make_layer(image: Image, node_path: String) -> Dictionary:
	return {
		"image": image,
		"attrs": {NODE_PATH_ATTRIB: node_path},
	}


## Side length in pixels of a region's height map.
static func _get_region_pixel_size(height_maps: Array) -> int:
	for height_image in height_maps:
		if height_image is Image:
			return height_image.get_width()
	return 0


## Copies one region's height, hole and texture weight data into the stitched images.
static func _stitch_region(
	region_loc: Vector2i,
	height_image: Image,
	control_image: Image,
	terrain3d_util: Object,
	min_x: float,
	min_z: float,
	region_pixel_size: int,
	region_pixel_stride: int,
	stitched_height: Image,
	region_mask: Image,
	hole_mask: Image,
	texture_weights: Dictionary,
	used_texture_ids: Array
) -> void:
	if height_image == null:
		return

	var offset_x := int((region_loc.x - min_x) * region_pixel_stride)
	var offset_z := int((region_loc.y - min_z) * region_pixel_stride)

	for y in range(region_pixel_size):
		for x in range(region_pixel_size):
			var stitch_x := offset_x + x
			var stitch_y := offset_z + y
			if stitch_x < 0 or stitch_x >= stitched_height.get_width() or stitch_y < 0 or stitch_y >= stitched_height.get_height():
				continue

			stitched_height.set_pixel(stitch_x, stitch_y, height_image.get_pixel(x, y))
			region_mask.set_pixel(stitch_x, stitch_y, Color(1, 1, 1, 1))

			if control_image == null:
				continue

			var control_bits := int(terrain3d_util.call("as_uint", control_image.get_pixel(x, y).r))
			var base_id := int(terrain3d_util.call("get_base", control_bits))
			var overlay_id := int(terrain3d_util.call("get_overlay", control_bits))
			var blend_value := float(terrain3d_util.call("get_blend", control_bits)) / 255.0
			var is_hole := bool(terrain3d_util.call("is_hole", control_bits))

			for texture_id in [base_id, overlay_id]:
				if texture_id >= 0 and not used_texture_ids.has(texture_id):
					used_texture_ids.append(texture_id)
					texture_weights[texture_id] = {}

			# Terrain3D blends from base towards overlay, so the base keeps 1-blend.
			var pixel_key := Vector2i(stitch_x, stitch_y)
			if base_id >= 0 and base_id == overlay_id:
				texture_weights[base_id][pixel_key] = 1.0
			else:
				if base_id >= 0:
					texture_weights[base_id][pixel_key] = 1.0 - blend_value
				if overlay_id >= 0:
					texture_weights[overlay_id][pixel_key] = blend_value

			# 1 = solid, 0 = hole.
			hole_mask.set_pixel(stitch_x, stitch_y, Color(0, 0, 0, 1) if is_hole else Color(1, 1, 1, 1))


## Turns the collected weights of one texture into a single channel image.
static func _build_texture_layer(texture_weights: Dictionary, texture_id: int, width: int, height: int) -> Image:
	var result := Image.create(width, height, false, Image.FORMAT_RF)
	result.fill(Color(0, 0, 0, 1))

	if texture_weights.has(texture_id):
		for pixel_key in texture_weights[texture_id].keys():
			var weight: float = texture_weights[texture_id][pixel_key]
			result.set_pixel(pixel_key.x, pixel_key.y, Color(weight, weight, weight, 1))

	return result
