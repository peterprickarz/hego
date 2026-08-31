@tool
class_name HEGoTerrain3DOutput
extends RefCounted

## Builds a Terrain3D node from the heightfield layers of a cooked HDA.
##
## The [code]height[/code] layer drives the terrain itself; the optional
## [code]hegot3d_*[/code] layers add region masks, holes, per-texture weights and
## colour maps. Everything is driven by detail attributes on the height layer, so an
## HDA that does not set [code]hegot3d_spawn_terrain[/code] is skipped entirely.

## Attributes read off the height layer.
const SPAWN_ATTRIB := "hegot3d_spawn_terrain"
const DATA_DIRECTORY_ATTRIB := "hegot3d_data_directory"
const NODE_PATH_ATTRIB := "hegot3d_node_path"
const REGION_SIZE_ATTRIB := "hegot3d_region_size"

## Optional layers.
const REGION_MAP_LAYER := "hegot3d_region_map"
const HOLE_LAYER := "hegot3d_hole"
const COLOR_LAYERS := {
	"r": "hegot3d_color_map_r",
	"g": "hegot3d_color_map_g",
	"b": "hegot3d_color_map_b",
	"roughness": "hegot3d_color_map_roughness",
}

## Attributes requested from the heightfield fetch.
const REQUESTED_ATTRIBS := [
	"hegot3d_spawn_terrain",
	"hegot3d_data_directory",
	"hegot3d_node_path",
	"hegot3d_region_size",
	"hegot3d_albedo_texture",
	"hegot3d_normal_texture",
	"hegot3d_ao_strength",
	"hegot3d_detiling_rotation",
	"hegot3d_detiling_shift",
	"hegot3d_id",
	"hegot3d_name",
	"hegot3d_normal_depth",
	"hegot3d_roughness",
	"hegot3d_uv_scale",
]

## Default node name and region size when the HDA does not specify them.
const DEFAULT_NODE_PATH := "Terrain3D"
const DEFAULT_REGION_SIZE := 256

## Rotation a Houdini heightfield is expected to have for the axis correction to hold.
const EXPECTED_HEIGHTFIELD_ROTATION := Vector3(-90.0, -90.0, 0.0)
const ROTATION_TOLERANCE := 0.5

## Terrain3DData.update_maps map type mask: height and control.
const UPDATE_MAPS_HEIGHT_AND_CONTROL := 3


## Fetches the heightfield layers of [param host]'s asset node and builds the terrain.
static func handle(host: Node) -> void:
	if not HEGoTerrain3DUtil.is_available():
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Terrain3D addon is not installed, skipping Terrain3D output.")
		return

	var layers: Variant = await HEGoNodeUtil.await_task(host, host.hego_asset_node.get_heightfield_layers(PackedStringArray(REQUESTED_ATTRIBS)))
	if not layers is Array:
		return

	var height_layer := HEGoTerrain3DUtil.get_layer_by_name(layers, HEGoTerrain3DUtil.HEIGHT_LAYER)
	if height_layer.is_empty():
		return

	var spawn_attr: Variant = HEGoTerrain3DUtil.get_attr_value(height_layer, SPAWN_ATTRIB)
	if spawn_attr == null or int(spawn_attr) != 1:
		return

	var config := _read_config(height_layer)
	if not config["ok"]:
		return

	# Texture layers have to be resolved before the terrain exists, because a failure
	# here only disables the control maps rather than the whole output.
	var texture_setup := _prepare_texture_layers(layers)

	var terrain := _spawn_terrain(host, config)
	if terrain == null:
		return

	var terrain_data: Object = terrain.get("data")
	if terrain_data == null:
		push_error(HEGoNodeUtil.LOG_PREFIX + "Terrain3D data object is not available.")
		return

	if texture_setup["enabled"]:
		texture_setup = await _apply_texture_assets(host, terrain, texture_setup)

	var hole_image: Image = null
	if texture_setup["enabled"]:
		var hole_layer := HEGoTerrain3DUtil.get_layer_by_name(layers, HOLE_LAYER)
		hole_image = await _fetch_layer_image(host, hole_layer)
		if hole_image == null and not hole_layer.is_empty():
			push_warning(HEGoNodeUtil.LOG_PREFIX + "Failed to fetch %s layer, continuing without hole control bits." % HOLE_LAYER)

	# Clear all regions to avoid stale content when reusing an existing data directory.
	for region in terrain_data.call("get_regions_active"):
		terrain_data.call("remove_region", region, false)
	terrain_data.call("update_maps", UPDATE_MAPS_HEIGHT_AND_CONTROL, true, false)

	var height_image := await _fetch_layer_image(host, height_layer)
	if height_image == null:
		push_error(HEGoNodeUtil.LOG_PREFIX + "Failed to fetch height image for Terrain3D output.")
		return

	var region_map_image := await _fetch_layer_image(host, HEGoTerrain3DUtil.get_layer_by_name(layers, REGION_MAP_LAYER))

	var color_images := {}
	for channel in COLOR_LAYERS.keys():
		color_images[channel] = await _fetch_layer_image(host, HEGoTerrain3DUtil.get_layer_by_name(layers, COLOR_LAYERS[channel]))
	var has_any_color := color_images.values().any(func(image): return image != null)

	_write_regions(terrain_data, config, height_layer, height_image, region_map_image, color_images, has_any_color, texture_setup, hole_image)

	terrain_data.call("calc_height_range", true)
	terrain_data.call("save_directory", config["data_directory"])


## Reads and validates the terrain settings stored on the height layer.
static func _read_config(height_layer: Dictionary) -> Dictionary:
	var transform_rotation: Vector3 = height_layer.get("transform_rotation", Vector3.ZERO)
	if not HEGoTerrain3DUtil.approx_equal_vec3(transform_rotation, EXPECTED_HEIGHTFIELD_ROTATION, ROTATION_TOLERANCE):
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Heightfield rotation is not default (-90,-90,0). Terrain3D output may be incorrect.")

	var voxel_scale_x := float(height_layer.get("voxel_scale_x", 1.0))
	var voxel_scale_y := float(height_layer.get("voxel_scale_y", voxel_scale_x))
	if absf(voxel_scale_x - voxel_scale_y) > 0.0001:
		push_warning(HEGoNodeUtil.LOG_PREFIX + "voxel_scale_x and voxel_scale_y differ. Terrain3D uses uniform vertex spacing.")
	if voxel_scale_x <= 0.0:
		push_error(HEGoNodeUtil.LOG_PREFIX + "Invalid voxel_scale_x for Terrain3D output.")
		return {"ok": false}

	var data_directory := HEGoTerrain3DUtil.get_attr_string(height_layer, DATA_DIRECTORY_ATTRIB)
	if data_directory.is_empty():
		push_error(HEGoNodeUtil.LOG_PREFIX + "%s is required for Terrain3D output." % DATA_DIRECTORY_ATTRIB)
		return {"ok": false}

	var node_path := HEGoTerrain3DUtil.get_attr_string(height_layer, NODE_PATH_ATTRIB)
	if node_path.is_empty():
		node_path = DEFAULT_NODE_PATH

	var region_size := DEFAULT_REGION_SIZE
	var region_size_attr: Variant = HEGoTerrain3DUtil.get_attr_value(height_layer, REGION_SIZE_ATTRIB)
	if HEGoTerrain3DUtil.is_valid_region_size(region_size_attr):
		region_size = int(region_size_attr)
	elif region_size_attr != null:
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Invalid %s. Using default value %d." % [REGION_SIZE_ATTRIB, DEFAULT_REGION_SIZE])

	var region_world_size := float(region_size) * voxel_scale_x
	if region_world_size <= 0.0:
		push_error(HEGoNodeUtil.LOG_PREFIX + "Invalid region world size for Terrain3D output.")
		return {"ok": false}

	return {
		"ok": true,
		"voxel_scale": voxel_scale_x,
		"data_directory": data_directory,
		"node_path": node_path,
		"region_size": region_size,
		"region_world_size": region_world_size,
	}


## Collects and validates the texture weight layers.
##
## Returns [code]{ enabled, layers, lowest_slot, util }[/code]; when [code]enabled[/code]
## is false the terrain is still built, just without control maps.
static func _prepare_texture_layers(layers: Array) -> Dictionary:
	var disabled := {"enabled": false, "layers": [], "lowest_slot": -1, "util": null}

	var texture_layers := HEGoTerrain3DUtil.collect_texture_layers(layers)
	if texture_layers.is_empty():
		return disabled

	var validation_result := HEGoTerrain3DUtil.validate_texture_layers(texture_layers)
	if not validation_result.get("ok", false):
		push_warning(validation_result.get("warning", HEGoNodeUtil.LOG_PREFIX + "Skipping Terrain3D control maps."))
		return disabled

	if not ClassDB.class_exists("Terrain3DUtil"):
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Terrain3DUtil is unavailable, skipping Terrain3D control maps.")
		return disabled

	var terrain3d_util: Object = ClassDB.instantiate("Terrain3DUtil")
	if terrain3d_util == null:
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Failed to instantiate Terrain3DUtil, skipping Terrain3D control maps.")
		return disabled

	var lowest_slot := int(validation_result.get("lowest_slot", -1))
	if lowest_slot < 0:
		return disabled

	return {
		"enabled": true,
		"layers": validation_result.get("layers", []),
		"lowest_slot": lowest_slot,
		"util": terrain3d_util,
	}


## Creates the Terrain3D node at the path the HDA asked for, replacing any node
## already sitting there, and applies the terrain-wide settings.
static func _spawn_terrain(host: Node, config: Dictionary) -> Node:
	var path_parts: PackedStringArray = str(config["node_path"]).split("/", false)
	if path_parts.is_empty():
		push_error(HEGoNodeUtil.LOG_PREFIX + "%s is invalid." % NODE_PATH_ATTRIB)
		return null

	var parent_node := HEGoNodeUtil.ensure_parent_path(host, host, path_parts)
	var terrain_name := path_parts[path_parts.size() - 1]

	var existing_terrain := parent_node.get_node_or_null(terrain_name)
	if existing_terrain != null:
		existing_terrain.free()

	var terrain: Node = ClassDB.instantiate("Terrain3D")
	if terrain == null:
		push_error(HEGoNodeUtil.LOG_PREFIX + "Failed to instantiate Terrain3D.")
		return null

	terrain.name = terrain_name
	parent_node.add_child(terrain)
	HEGoNodeUtil.set_editor_owner(host, terrain)

	terrain.set("region_size", config["region_size"])
	terrain.set("vertex_spacing", config["voxel_scale"])
	terrain.set("data_directory", config["data_directory"])

	var terrain_material: Object = terrain.get("material")
	if terrain_material != null:
		# 0 corresponds to Terrain3DMaterial.WorldBackground.NONE.
		if terrain_material.has_method("set_world_background"):
			terrain_material.call("set_world_background", 0)
		else:
			terrain_material.set("world_background", 0)

	return terrain


## Builds a Terrain3DTextureAsset per validated layer and fetches its weight image.
##
## Returns the texture setup with the weight images filled in, or with
## [code]enabled[/code] cleared when any part of it failed.
static func _apply_texture_assets(host: Node, terrain: Node, texture_setup: Dictionary) -> Dictionary:
	var disabled := {"enabled": false, "layers": [], "lowest_slot": -1, "util": null}

	var terrain_assets := HEGoTerrain3DUtil.get_terrain_assets(terrain)
	if terrain_assets == null and ClassDB.class_exists("Terrain3DAssets"):
		terrain_assets = ClassDB.instantiate("Terrain3DAssets")
		terrain.set("assets", terrain_assets)
	if terrain_assets == null:
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Terrain3D assets object is unavailable, skipping Terrain3D control maps.")
		return disabled

	for texture_layer in texture_setup["layers"]:
		var texture_asset: Object = ClassDB.instantiate("Terrain3DTextureAsset")
		if texture_asset == null:
			push_warning(HEGoNodeUtil.LOG_PREFIX + "Failed to instantiate Terrain3DTextureAsset, skipping Terrain3D control maps.")
			return disabled

		texture_asset.call("set_albedo_texture", texture_layer["albedo_texture"])
		if texture_asset.has_method("set_normal_texture"):
			texture_asset.call("set_normal_texture", texture_layer["normal_texture"])
		else:
			HEGoTerrain3DUtil.set_optional_property(texture_asset, "normal_texture", texture_layer["normal_texture"])

		for optional_property in texture_layer["optional_properties"].keys():
			HEGoTerrain3DUtil.set_optional_property(texture_asset, optional_property, texture_layer["optional_properties"][optional_property])

		terrain_assets.call("set_texture", int(texture_layer["slot"]), texture_asset)

		var weight_image := await _fetch_image_for_part(host, int(texture_layer["part_id"]))
		if weight_image == null:
			push_warning(HEGoNodeUtil.LOG_PREFIX + "Failed to fetch weight image for layer %s, skipping Terrain3D control maps." % texture_layer["layer_name"])
			return disabled
		texture_layer["weight_image"] = weight_image

	if terrain_assets.has_signal("textures_changed"):
		terrain_assets.emit_signal("textures_changed")

	return texture_setup


## Fetches a layer's image and rotates it into Terrain3D orientation.
## Returns null for missing layers and failed fetches alike.
static func _fetch_layer_image(host: Node, layer: Dictionary) -> Image:
	if layer.is_empty() or not layer.has("part_id"):
		return null
	return await _fetch_image_for_part(host, int(layer["part_id"]))


static func _fetch_image_for_part(host: Node, part_id: int) -> Image:
	if part_id < 0:
		return null
	var image: Variant = await HEGoNodeUtil.await_task(host, host.hego_asset_node.fetch_heightfield_layer_image(part_id))
	if image == null:
		return null
	return HEGoTerrain3DUtil.fix_heightfield_image_transform(image)


## Slices the heightfield into Terrain3D regions and imports them.
static func _write_regions(
	terrain_data: Object,
	config: Dictionary,
	height_layer: Dictionary,
	height_image: Image,
	region_map_image: Image,
	color_images: Dictionary,
	has_any_color: bool,
	texture_setup: Dictionary,
	hole_image: Image
) -> void:
	var voxel_scale: float = config["voxel_scale"]
	var region_size: int = config["region_size"]
	var region_world_size: float = config["region_world_size"]

	var voxel_count_x := int(height_layer.get("voxel_count_x", height_image.get_width()))
	var voxel_count_y := int(height_layer.get("voxel_count_y", height_image.get_height()))
	var transform_position: Vector3 = height_layer.get("transform_position", Vector3.ZERO)

	# Houdini positions a heightfield by its centre-of-voxel origin, Terrain3D by the
	# outer corner of its first pixel, hence the half voxel shift.
	var corner_x := transform_position.x - (voxel_scale * 0.5)
	var corner_z := transform_position.z - (voxel_scale * 0.5)

	# Terrain3D regions live on a fixed world grid, so the heightfield corner is
	# snapped onto it and the pixel offsets are derived from the snapped position.
	var snapped_x := snappedf(corner_x, region_world_size)
	var snapped_z := snappedf(corner_z, region_world_size)
	if absf(snapped_x - corner_x) > 0.0001 or absf(snapped_z - corner_z) > 0.0001:
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Heightfield offset snapped to Terrain3D region grid.")

	var image_world_end_x := corner_x + (float(voxel_count_x) * voxel_scale)
	var image_world_end_z := corner_z + (float(voxel_count_y) * voxel_scale)
	var rx_start := int(floor((corner_x - snapped_x) / region_world_size))
	var rx_end := int(ceil((image_world_end_x - snapped_x) / region_world_size)) - 1
	var rz_start := int(floor((corner_z - snapped_z) / region_world_size))
	var rz_end := int(ceil((image_world_end_z - snapped_z) / region_world_size)) - 1

	var wrote_any_region := false
	for rz in range(rz_start, rz_end + 1):
		for rx in range(rx_start, rx_end + 1):
			var world_region_x := snapped_x + (float(rx) * region_world_size)
			var world_region_z := snapped_z + (float(rz) * region_world_size)

			var pixel_start_x := int(round((world_region_x - corner_x) / voxel_scale))
			var pixel_start_z := int(round((world_region_z - corner_z) / voxel_scale))
			if pixel_start_x + region_size <= 0 or pixel_start_z + region_size <= 0 or pixel_start_x >= voxel_count_x or pixel_start_z >= voxel_count_y:
				continue

			# The region map lets an HDA carve out which regions exist at all; it is
			# sampled at the centre of the region.
			if region_map_image != null:
				@warning_ignore("integer_division")
				var map_sample_x := clampi(pixel_start_x + (region_size / 2), 0, voxel_count_x - 1)
				@warning_ignore("integer_division")
				var map_sample_z := clampi(pixel_start_z + (region_size / 2), 0, voxel_count_y - 1)
				if region_map_image.get_pixel(map_sample_x, map_sample_z).r < 0.5:
					continue

			# Clip the region against the heightfield; partly covered regions keep
			# their default value outside the clipped area.
			var clip_x0 := maxi(pixel_start_x, 0)
			var clip_z0 := maxi(pixel_start_z, 0)
			var clip_x1 := mini(pixel_start_x + region_size, voxel_count_x)
			var clip_z1 := mini(pixel_start_z + region_size, voxel_count_y)
			if clip_x1 <= clip_x0 or clip_z1 <= clip_z0:
				continue

			var clipped_region := height_image.get_region(Rect2i(clip_x0, clip_z0, clip_x1 - clip_x0, clip_z1 - clip_z0))
			var dest_x := clip_x0 - pixel_start_x
			var dest_z := clip_z0 - pixel_start_z

			var region_image := Image.create(region_size, region_size, false, Image.FORMAT_RF)
			region_image.fill(Color(0.0, 0.0, 0.0, 1.0))
			region_image.blit_rect(clipped_region, Rect2i(0, 0, clipped_region.get_width(), clipped_region.get_height()), Vector2i(dest_x, dest_z))

			var imported_images: Array[Image] = [region_image, null, null]

			if texture_setup["enabled"]:
				imported_images[1] = _build_control_image(
					region_size, texture_setup, hole_image,
					clip_x0, clip_z0, dest_x, dest_z,
					clipped_region.get_width(), clipped_region.get_height()
				)

			if has_any_color:
				imported_images[2] = _build_color_image(
					region_size, color_images,
					clip_x0, clip_z0, dest_x, dest_z,
					clipped_region.get_width(), clipped_region.get_height()
				)

			terrain_data.call("import_images", imported_images, Vector3(world_region_x, 0.0, world_region_z), 0.0, 1.0)
			wrote_any_region = true

	if not wrote_any_region:
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Terrain3D output produced no regions.")


## Builds the control map of one region from the texture weight layers.
static func _build_control_image(
	region_size: int,
	texture_setup: Dictionary,
	hole_image: Image,
	clip_x0: int, clip_z0: int,
	dest_x: int, dest_z: int,
	copy_width: int, copy_height: int
) -> Image:
	var terrain3d_util: Object = texture_setup["util"]
	var texture_layers: Array = texture_setup["layers"]
	var lowest_slot: int = texture_setup["lowest_slot"]

	var control_image := Image.create(region_size, region_size, false, Image.FORMAT_RF)
	# Pixels the heightfield does not cover get the "nothing painted" value.
	var default_bits := HEGoTerrain3DUtil.build_control_bits_for_pixel(texture_layers, terrain3d_util, -1, -1, lowest_slot, hole_image)
	control_image.fill(Color(float(terrain3d_util.call("as_float", default_bits)), 0.0, 0.0, 1.0))

	for local_z in range(copy_height):
		for local_x in range(copy_width):
			var control_bits := HEGoTerrain3DUtil.build_control_bits_for_pixel(
				texture_layers, terrain3d_util, clip_x0 + local_x, clip_z0 + local_z, lowest_slot, hole_image
			)
			control_image.set_pixel(dest_x + local_x, dest_z + local_z, Color(float(terrain3d_util.call("as_float", control_bits)), 0.0, 0.0, 1.0))

	return control_image


## Builds the colour map of one region from the per-channel colour layers.
## Missing channels stay at the Terrain3D defaults: white with 0.5 roughness.
static func _build_color_image(
	region_size: int,
	color_images: Dictionary,
	clip_x0: int, clip_z0: int,
	dest_x: int, dest_z: int,
	copy_width: int, copy_height: int
) -> Image:
	var color_image := Image.create(region_size, region_size, false, Image.FORMAT_RGBA8)
	color_image.fill(Color(1.0, 1.0, 1.0, 0.5))

	for local_z in range(copy_height):
		for local_x in range(copy_width):
			var src_x := clip_x0 + local_x
			var src_z := clip_z0 + local_z
			color_image.set_pixel(
				dest_x + local_x,
				dest_z + local_z,
				Color(
					_sample_channel(color_images["r"], src_x, src_z, 1.0),
					_sample_channel(color_images["g"], src_x, src_z, 1.0),
					_sample_channel(color_images["b"], src_x, src_z, 1.0),
					_sample_channel(color_images["roughness"], src_x, src_z, 0.5)
				)
			)

	return color_image


## Reads the red channel of a colour layer, falling back for missing layers and
## for pixels outside the layer's image.
static func _sample_channel(image: Image, x: int, z: int, fallback: float) -> float:
	if image == null or x >= image.get_width() or z >= image.get_height():
		return fallback
	return clampf(image.get_pixel(x, z).r, 0.0, 1.0)
