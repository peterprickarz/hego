@tool
class_name StrataRegionData
extends Resource
## One region's composed maps (see docs/development/strata_regions_plan.md). Built-in types
## only, so runtime-only projects can load region files without the Strata extension.
##
## [member maps] holds, per map name, {format: Image.Format, kind: String, scale: int,
## apron: int, levels: Array[PackedByteArray]}: levels[0] is the full-resolution map, later
## entries are the precomputed mips. Sizes follow StrataRegions.map_size exactly; raw bytes
## keep bakes byte-identical across resource formats.

const FORMAT_VERSION := 1

@export var format_version: int = FORMAT_VERSION
## Region grid index.
@export var region: Vector2i = Vector2i.ZERO
@export var cells: int = StrataRegions.DEFAULT_CELLS
@export var apron: int = StrataRegions.DEFAULT_APRON
@export var spacing: float = 1.0
## Terrain-local XZ of the region's first sample (no apron).
@export var origin: Vector2 = Vector2.ZERO
@export var maps: Dictionary = {}
## Height extrema over this region's height map (apron excluded), for bounds and culling.
@export var height_min: float = 0.0
@export var height_max: float = 0.0
## Advances whenever a map changes; the renderer and caches compare it.
@export var revision: int = 0

func spec_fragment() -> Dictionary:
	return {"cells": cells, "apron": apron, "spacing": spacing}

func has_map(name: String) -> bool:
	return maps.has(name)

func map_names() -> PackedStringArray:
	var names := PackedStringArray()
	for name in maps: names.append(String(name))
	return names

func description(name: String) -> Dictionary:
	var entry: Dictionary = maps.get(name, {})
	return {"format": int(entry.get("format", Image.FORMAT_RF)), "kind": String(entry.get("kind", StrataRegions.KIND_SAMPLE)), "scale": int(entry.get("scale", 1)), "apron": int(entry.get("apron", apron))}

func level_count(name: String) -> int:
	var entry: Dictionary = maps.get(name, {})
	return (entry.get("levels", []) as Array).size()

## Raw bytes of a level, empty when absent.
func level_bytes(name: String, level: int = 0) -> PackedByteArray:
	var entry: Dictionary = maps.get(name, {})
	var levels: Array = entry.get("levels", [])
	return levels[level] if level >= 0 and level < levels.size() else PackedByteArray()

## A level as an Image (copy), or null when absent or malformed.
func get_image(name: String, level: int = 0) -> Image:
	if not maps.has(name) or level_count(name) <= level: return null
	return StrataRegions.image_from_level(description(name), cells, level, level_bytes(name, level))

## Stores a level from an image whose size and format match the map description.
## [param description] is required when the map does not exist yet. Returns false and changes
## nothing on a mismatch.
func set_image(name: String, image: Image, level: int = 0, new_description: Dictionary = {}) -> bool:
	if image == null or name.is_empty() or level < 0: return false
	var entry: Dictionary = maps.get(name, {})
	if entry.is_empty():
		if new_description.is_empty() or not StrataRegions.validate_map(cells, new_description).ok: return false
		entry = {"format": int(new_description.format), "kind": String(new_description.kind), "scale": int(new_description.get("scale", 1)), "apron": int(new_description.get("apron", apron)), "levels": []}
	var expected := StrataRegions.map_size(cells, entry, level)
	if image.get_size() != expected or image.get_format() != int(entry.format) or image.is_compressed() or image.has_mipmaps(): return false
	var levels: Array = entry.levels
	while levels.size() <= level: levels.append(PackedByteArray())
	levels[level] = image.get_data()
	entry["levels"] = levels
	maps[name] = entry
	revision += 1
	emit_changed()
	return true

## Replaces a texel rectangle of a level in place. The patch must have the map's format and
## lie inside the map.
func blit(name: String, level: int, patch: Image, texel_origin: Vector2i) -> bool:
	var image := get_image(name, level)
	if image == null or patch == null or patch.get_format() != image.get_format(): return false
	if texel_origin.x < 0 or texel_origin.y < 0 or texel_origin.x + patch.get_width() > image.get_width() or texel_origin.y + patch.get_height() > image.get_height(): return false
	image.blit_rect(patch, Rect2i(Vector2i.ZERO, patch.get_size()), texel_origin)
	return set_image(name, image, level)

func remove_map(name: String) -> void:
	if maps.erase(name):
		revision += 1
		emit_changed()

func payload_bytes() -> int:
	var total := 0
	for name in maps:
		for level in (maps[name].get("levels", []) as Array): total += (level as PackedByteArray).size()
	return total

## Checks that every stored level has exactly the bytes its geometry demands.
func validate() -> Dictionary:
	if format_version != FORMAT_VERSION: return {"ok": false, "message": "Unsupported region format version %d" % format_version}
	if not StrataRegions.valid_cells(cells): return {"ok": false, "message": "Region cells must be a power of two between %d and %d" % [StrataRegions.MIN_CELLS, StrataRegions.MAX_CELLS]}
	if not is_finite(spacing) or spacing <= 0.0 or not origin.is_finite(): return {"ok": false, "message": "Region needs a positive spacing and finite origin"}
	if not is_finite(height_min) or not is_finite(height_max) or height_min > height_max: return {"ok": false, "message": "Region height extrema must be finite and ordered"}
	for name in maps:
		var entry: Dictionary = maps[name]
		var checked := StrataRegions.validate_map(cells, entry)
		if not checked.ok: return {"ok": false, "message": "%s: %s" % [name, checked.message]}
		var levels: Array = entry.get("levels", [])
		if levels.is_empty(): return {"ok": false, "message": "%s has no levels" % name}
		for level in range(levels.size()):
			var expected := StrataRegions.map_bytes(cells, entry, level)
			if (levels[level] as PackedByteArray).size() != expected:
				return {"ok": false, "message": "%s level %d holds %d bytes, expected %d" % [name, level, (levels[level] as PackedByteArray).size(), expected]}
	return {"ok": true, "message": ""}
