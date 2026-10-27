@tool
class_name HEGoTerrain3DUtil
extends RefCounted

## Helpers shared by the Terrain3D input, output and instancer paths.
##
## Terrain3D is an optional addon, so nothing here refers to its types directly:
## everything goes through [ClassDB], [method Object.call] and [method Object.get],
## and every entry point degrades to a warning when the addon or a method is missing.

## Category this file logs under, shown in the session panel filter.
const LOG_CATEGORY := "terrain3d"

## Prefix of every heightfield layer and attribute HEGo exchanges with Terrain3D.
const ATTRIB_PREFIX := "hegot3d_"

## Layer holding the terrain height.
const HEIGHT_LAYER := "height"

## Layer name prefix of the per-texture weight layers.
const TEXTURE_LAYER_PREFIX := ATTRIB_PREFIX + "texture_layer_"

## Highest texture slot Terrain3D control maps can address.
const MAX_TEXTURE_SLOT := 31

## Region sizes Terrain3D accepts.
const MIN_REGION_SIZE := 64
const MAX_REGION_SIZE := 2048

## Optional Terrain3DTextureAsset properties an HDA can drive, keyed by attribute name.
const TEXTURE_ASSET_ATTRIBS := {
	"hegot3d_ao_strength": "ao_strength",
	"hegot3d_detiling_rotation": "detiling_rotation",
	"hegot3d_detiling_shift": "detiling_shift",
	"hegot3d_id": "id",
	"hegot3d_name": "name",
	"hegot3d_normal_depth": "normal_depth",
	"hegot3d_roughness": "roughness",
	"hegot3d_uv_scale": "uv_scale",
}


## Whether the Terrain3D addon is present in this project.
static func is_available() -> bool:
	return ClassDB.class_exists("Terrain3D")


# ─────────────────────────────────────────────
# Layer and attribute access
# ─────────────────────────────────────────────

## Returns the heightfield layer called [param layer_name], or an empty dictionary.
static func get_layer_by_name(layers: Array, layer_name: String) -> Dictionary:
	for layer in layers:
		if layer is Dictionary and layer.get("layer_name", "") == layer_name:
			return layer
	return {}


## Value of one of a layer's attributes, or [code]null[/code] when it is missing.
static func get_attr_value(layer: Dictionary, attr_name: String) -> Variant:
	return HEGoNodeUtil.get_attrib_value(layer, "attrs", attr_name)


## Same as [method get_attr_value], but always returns a stripped string.
static func get_attr_string(layer: Dictionary, attr_name: String) -> String:
	var value: Variant = get_attr_value(layer, attr_name)
	if value == null:
		return ""
	return str(value).strip_edges()


## Whether [param value] is a region size Terrain3D accepts: a power of two
## between [constant MIN_REGION_SIZE] and [constant MAX_REGION_SIZE].
static func is_valid_region_size(value: Variant) -> bool:
	if not value is int and not value is float:
		return false
	var size := int(value)
	if size < MIN_REGION_SIZE or size > MAX_REGION_SIZE:
		return false
	return size > 0 and (size & (size - 1)) == 0


## Component-wise comparison with a tolerance.
static func approx_equal_vec3(a: Vector3, b: Vector3, tolerance: float) -> bool:
	return absf(a.x - b.x) <= tolerance and absf(a.y - b.y) <= tolerance and absf(a.z - b.z) <= tolerance


# ─────────────────────────────────────────────
# Texture layers
# ─────────────────────────────────────────────

## Collects the hegot3d_texture_layer_N layers, sorted by slot.
static func collect_texture_layers(layers: Array) -> Array:
	var texture_layers: Array = []
	for layer in layers:
		if not layer is Dictionary:
			continue
		var layer_name := str(layer.get("layer_name", ""))
		if not layer_name.begins_with(TEXTURE_LAYER_PREFIX):
			continue
		var slot := parse_texture_layer_index(layer_name)
		if slot < 0 or slot > MAX_TEXTURE_SLOT:
			HEGoLog.get_singleton().warning(LOG_CATEGORY, "Ignoring invalid Terrain3D texture layer name %s." % layer_name)
			continue
		texture_layers.append({
			"slot": slot,
			"layer": layer,
			"layer_name": layer_name,
			"part_id": int(layer.get("part_id", -1)),
		})
	texture_layers.sort_custom(func(a, b): return int(a["slot"]) < int(b["slot"]))
	return texture_layers


## Slot number encoded in a hegot3d_texture_layer_N name, or -1 if there is none.
static func parse_texture_layer_index(layer_name: String) -> int:
	var suffix := layer_name.trim_prefix(TEXTURE_LAYER_PREFIX)
	if suffix.is_empty() or not suffix.is_valid_int():
		return -1
	return int(suffix)


## Checks that every texture layer can actually be turned into a Terrain3DTextureAsset.
##
## Control maps address textures by slot, so a single unusable layer would shift every
## other one: validation is all-or-nothing. Returns
## [code]{ ok, layers, lowest_slot }[/code] on success and [code]{ ok, warning }[/code]
## on failure.
static func validate_texture_layers(texture_layers: Array) -> Dictionary:
	var validated_layers: Array = []
	var albedo_reference := {}
	var normal_reference := {}

	for texture_layer in texture_layers:
		var layer: Dictionary = texture_layer["layer"]
		var layer_name := str(texture_layer["layer_name"])
		var part_id := int(texture_layer["part_id"])
		if part_id < 0:
			return _validation_error("Terrain3D texture layer %s has invalid part_id" % layer_name)

		var albedo_path := get_attr_string(layer, ATTRIB_PREFIX + "albedo_texture")
		if albedo_path.is_empty():
			return _validation_error("Terrain3D texture layer %s is missing %salbedo_texture" % [layer_name, ATTRIB_PREFIX])

		var normal_path := get_attr_string(layer, ATTRIB_PREFIX + "normal_texture")
		if normal_path.is_empty():
			return _validation_error("Terrain3D texture layer %s is missing %snormal_texture" % [layer_name, ATTRIB_PREFIX])

		var albedo_texture := load_texture_resource(albedo_path)
		if albedo_texture == null:
			return _validation_error("Failed to load Terrain3D albedo texture %s for layer %s" % [albedo_path, layer_name])

		var normal_texture := load_texture_resource(normal_path)
		if normal_texture == null:
			return _validation_error("Failed to load Terrain3D normal texture %s for layer %s" % [normal_path, layer_name])

		var albedo_image := get_texture_image(albedo_texture)
		if albedo_image == null:
			return _validation_error("Failed to inspect Terrain3D albedo texture %s for layer %s" % [albedo_path, layer_name])

		var normal_image := get_texture_image(normal_texture)
		if normal_image == null:
			return _validation_error("Failed to inspect Terrain3D normal texture %s for layer %s" % [normal_path, layer_name])

		# Terrain3D packs all albedo textures into one array texture, and all normal
		# maps into another, so within each set the size and format have to match.
		var albedo_info := get_image_signature(albedo_image)
		if albedo_reference.is_empty():
			albedo_reference = albedo_info
		elif not image_signature_matches(albedo_reference, albedo_info):
			return _validation_error("All Terrain3D albedo textures must share the same resolution and format")

		var normal_info := get_image_signature(normal_image)
		if normal_reference.is_empty():
			normal_reference = normal_info
		elif not image_signature_matches(normal_reference, normal_info):
			return _validation_error("All Terrain3D normal textures must share the same resolution and format")

		var optional_properties := {}
		for attr_name in TEXTURE_ASSET_ATTRIBS.keys():
			var attr_value: Variant = get_attr_value(layer, attr_name)
			if attr_value != null:
				optional_properties[TEXTURE_ASSET_ATTRIBS[attr_name]] = attr_value

		validated_layers.append({
			"slot": int(texture_layer["slot"]),
			"layer_name": layer_name,
			"part_id": part_id,
			"albedo_texture": albedo_texture,
			"normal_texture": normal_texture,
			"optional_properties": optional_properties,
			"weight_image": null,
		})

	validated_layers.sort_custom(func(a, b): return int(a["slot"]) < int(b["slot"]))
	return {
		"ok": true,
		"layers": validated_layers,
		"lowest_slot": int(validated_layers[0]["slot"]) if not validated_layers.is_empty() else -1,
	}


static func _validation_error(reason: String) -> Dictionary:
	return {
		"ok": false,
		"warning": reason + ", skipping Terrain3D control maps.",
	}


## Loads a [Texture2D] from [param resource_path], or null if there is none.
static func load_texture_resource(resource_path: String) -> Texture2D:
	if resource_path.is_empty() or not ResourceLoader.exists(resource_path):
		return null
	var resource: Resource = load(resource_path)
	if resource is Texture2D:
		return resource
	return null


## The [Image] behind a texture, or null when it cannot be read.
static func get_texture_image(texture: Texture2D) -> Image:
	if texture == null or not texture.has_method("get_image"):
		return null
	return texture.get_image()


## Size and format of an image, used to compare textures against each other.
static func get_image_signature(image: Image) -> Dictionary:
	return {
		"width": image.get_width(),
		"height": image.get_height(),
		"format": image.get_format(),
	}


## Whether two [method get_image_signature] results describe the same layout.
static func image_signature_matches(a: Dictionary, b: Dictionary) -> bool:
	return (
		int(a.get("width", -1)) == int(b.get("width", -2))
		and int(a.get("height", -1)) == int(b.get("height", -2))
		and int(a.get("format", -1)) == int(b.get("format", -2))
	)


## Sets a property only if the object has it, for properties whose availability
## depends on the installed Terrain3D version.
static func set_optional_property(obj: Object, property_name: String, value: Variant) -> void:
	if HEGoPropertyUtil.has_property(obj, property_name):
		obj.set(property_name, value)


# ─────────────────────────────────────────────
# Control map bits
# ─────────────────────────────────────────────

## Builds the Terrain3D control map value for one pixel.
##
## Terrain3D blends exactly two textures per pixel, so the two heaviest weight layers
## become base and overlay and the rest are dropped. Pass -1 for [param pixel_x] and
## [param pixel_z] to get the value used for pixels outside every weight image.
static func build_control_bits_for_pixel(texture_layers: Array, terrain3d_util: Object, pixel_x: int, pixel_z: int, lowest_valid_texture_slot: int, hole_image: Image) -> int:
	var best_slot := lowest_valid_texture_slot
	var second_slot := lowest_valid_texture_slot
	var best_weight := 0.0
	var second_weight := 0.0

	for texture_layer in texture_layers:
		var weight_image: Image = texture_layer.get("weight_image", null)
		if weight_image == null:
			continue
		if pixel_x < 0 or pixel_z < 0 or pixel_x >= weight_image.get_width() or pixel_z >= weight_image.get_height():
			continue
		var layer_weight := clampf(weight_image.get_pixel(pixel_x, pixel_z).r, 0.0, 1.0)
		if layer_weight > best_weight:
			second_weight = best_weight
			second_slot = best_slot
			best_weight = layer_weight
			best_slot = int(texture_layer["slot"])
		elif layer_weight > second_weight:
			second_weight = layer_weight
			second_slot = int(texture_layer["slot"])

	var base_slot := lowest_valid_texture_slot
	var overlay_slot := lowest_valid_texture_slot
	var normalized_overlay_weight := 0.0

	if best_weight <= 0.0:
		# Nothing painted here: fall back to the lowest slot, fully opaque.
		pass
	elif second_weight <= 0.0:
		base_slot = best_slot
		overlay_slot = best_slot
	else:
		# Terrain3D blends from base towards overlay, so the lower slot has to be
		# the base for the blend factor to mean the same thing on every pixel.
		var combined_weight := best_weight + second_weight
		if best_slot <= second_slot:
			base_slot = best_slot
			overlay_slot = second_slot
			normalized_overlay_weight = second_weight / combined_weight
		else:
			base_slot = second_slot
			overlay_slot = best_slot
			normalized_overlay_weight = best_weight / combined_weight

	var blend_value := clampi(int(round(normalized_overlay_weight * 255.0)), 0, 255)
	var is_hole := false
	if hole_image != null and pixel_x >= 0 and pixel_z >= 0 and pixel_x < hole_image.get_width() and pixel_z < hole_image.get_height():
		is_hole = hole_image.get_pixel(pixel_x, pixel_z).r >= 0.5

	return encode_control_bits(terrain3d_util, base_slot, overlay_slot, blend_value, is_hole)


## Packs base slot, overlay slot, blend and hole flag into a Terrain3D control value.
static func encode_control_bits(terrain3d_util: Object, base_slot: int, overlay_slot: int, blend_value: int, is_hole: bool) -> int:
	var bits := int(terrain3d_util.call("enc_base", base_slot))
	bits |= int(terrain3d_util.call("enc_overlay", overlay_slot))
	bits |= int(terrain3d_util.call("enc_blend", blend_value))
	bits |= int(terrain3d_util.call("enc_uv_rotation", 0))
	bits |= int(terrain3d_util.call("enc_uv_scale", 0))
	bits |= int(terrain3d_util.call("enc_auto", false))
	bits |= int(terrain3d_util.call("enc_nav", false))
	bits |= int(terrain3d_util.call("enc_hole", is_hole))
	return bits


# ─────────────────────────────────────────────
# Images
# ─────────────────────────────────────────────

## Rotates a Houdini heightfield image into Terrain3D's orientation.
##
## Houdini heightfields are stored rows-along-Z while Terrain3D expects rows-along-X,
## which is a 90 degree rotation; the import then mirrors along world X, so the result
## is flipped back here.
static func fix_heightfield_image_transform(image: Image) -> Image:
	if image == null:
		return null

	var orig_width := image.get_width()
	var orig_height := image.get_height()
	var corrected := Image.create(orig_height, orig_width, false, image.get_format())

	for orig_y in range(orig_height):
		for orig_x in range(orig_width):
			corrected.set_pixel(orig_height - 1 - orig_y, orig_x, image.get_pixel(orig_x, orig_y))

	corrected.flip_x()
	return corrected


# ─────────────────────────────────────────────
# Terrain3D node access
# ─────────────────────────────────────────────

## Resolves a Terrain3D node path, relative to [param host] first and to the edited
## scene root second, so HDAs can address terrains outside the HEGo node.
static func find_node_from_path(host: Node, node_path_text: String) -> Node:
	if node_path_text.is_empty():
		return null

	var direct_node := host.get_node_or_null(node_path_text)
	if direct_node != null:
		return direct_node

	var tree := host.get_tree()
	if tree != null and tree.edited_scene_root != null:
		return tree.edited_scene_root.get_node_or_null(node_path_text)

	return null


## The Terrain3DAssets of a terrain, or null when it has none.
static func get_terrain_assets(terrain: Node) -> Object:
	if terrain == null:
		return null
	if terrain.has_method("get_assets"):
		var assets: Object = terrain.call("get_assets")
		if assets != null:
			return assets
	return terrain.get("assets")


## World size of one terrain vertex, defaulting to 1.0 for terrains that do not say.
static func get_vertex_spacing(terrain3d_node: Node) -> float:
	if terrain3d_node == null:
		return 1.0
	var spacing := 1.0
	if terrain3d_node.has_method("get_vertex_spacing"):
		spacing = float(terrain3d_node.call("get_vertex_spacing"))
	else:
		spacing = float(terrain3d_node.get("vertex_spacing"))
	if spacing <= 0.0:
		return 1.0
	return spacing


## Name of the texture in [param texture_id]'s slot, or an empty string.
static func get_texture_name(terrain3d_node: Node, texture_id: int) -> String:
	var assets := get_terrain_assets(terrain3d_node)
	if assets == null or not assets.has_method("get_texture"):
		return ""
	var texture_asset: Object = assets.call("get_texture", texture_id)
	if texture_asset == null:
		return ""
	if texture_asset.has_method("get_name"):
		return str(texture_asset.call("get_name"))
	return str(texture_asset.get("name"))
