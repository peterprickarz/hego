@tool
class_name StrataRegionData
extends Resource
## One region's composed maps (see docs/development/strata_regions_plan.md). Built-in types
## only, so runtime-only projects can load region files without the Strata extension.
##
## [member maps] holds, per map name, {format: Image.Format, kind: String, scale: int,
## apron: int, levels: Array[PackedByteArray]}: for a full region levels[0] is the
## full-resolution map and later entries are the precomputed mips. Sizes follow
## StrataRegions.map_size exactly; raw bytes keep bakes byte-identical across resource formats.
##
## A partial region (the lod file of a bake) sets [member first_level] above 0: the levels
## below it are absent and levels[i] of every map is level first_level + i. All public
## accessors take the real level number and translate; only code that reads
## maps[name].levels directly sees the shifted indexing.

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
## Lowest level held. 0 is a full region; a partial region holds first_level.. only (the
## entries of every map's levels array start at this level).
@export var first_level: int = 0
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

## The highest held level of a map plus one (0 for an absent or empty map). For a partial
## region this is first_level + the entries held, so it equals the full region's count and
## "level_count(name) > level" still means the level can exist; use [method has_level] or
## [member first_level] to know whether it is held.
func level_count(name: String) -> int:
	var held := (maps.get(name, {}).get("levels", []) as Array).size()
	return first_level + held if held > 0 else 0

## True when [param level] of the map is held (at or above first_level and within the stored levels).
func has_level(name: String, level: int) -> bool:
	return level >= first_level and level < level_count(name)

## Raw bytes of a level, empty when absent (below first_level included).
func level_bytes(name: String, level: int = 0) -> PackedByteArray:
	var levels: Array = maps.get(name, {}).get("levels", [])
	var index := level - first_level
	return levels[index] if index >= 0 and index < levels.size() else PackedByteArray()

## A level as an Image (copy), or null when absent (below first_level included) or malformed.
func get_image(name: String, level: int = 0) -> Image:
	if not maps.has(name) or not has_level(name, level): return null
	return StrataRegions.image_from_level(description(name), cells, level, level_bytes(name, level))

## Stores a level from an image whose size and format match the map description.
## [param description] is required when the map does not exist yet. Levels below first_level
## are rejected. Returns false and changes
## nothing on a mismatch.
func set_image(name: String, image: Image, level: int = 0, new_description: Dictionary = {}) -> bool:
	if image == null or name.is_empty() or level < first_level: return false
	var entry: Dictionary = maps.get(name, {})
	if entry.is_empty():
		if new_description.is_empty() or not StrataRegions.validate_map(cells, new_description).ok: return false
		entry = {"format": int(new_description.format), "kind": String(new_description.kind), "scale": int(new_description.get("scale", 1)), "apron": int(new_description.get("apron", apron)), "levels": []}
	var expected := StrataRegions.map_size(cells, entry, level)
	if image.get_size() != expected or image.get_format() != int(entry.format) or image.is_compressed() or image.has_mipmaps(): return false
	var levels: Array = entry.levels
	var index := level - first_level
	while levels.size() <= index: levels.append(PackedByteArray())
	levels[index] = image.get_data()
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

## A partial copy holding levels [param level].. of every map (the lod file of a bake), sharing
## the byte arrays copy-on-write. Null when [param level] is below this region's first_level or
## some map does not reach it.
func partial_copy(level: int) -> StrataRegionData:
	if level < first_level or maps.is_empty(): return null
	var copy := StrataRegionData.new()
	copy.format_version = format_version
	copy.region = region
	copy.cells = cells
	copy.apron = apron
	copy.spacing = spacing
	copy.origin = origin
	copy.height_min = height_min
	copy.height_max = height_max
	copy.revision = revision
	copy.first_level = level
	for name in maps:
		var entry: Dictionary = maps[name].duplicate()
		var levels: Array = entry.get("levels", [])
		if level - first_level >= levels.size(): return null
		entry["levels"] = levels.slice(level - first_level)
		copy.maps[name] = entry
	return copy

func remove_map(name: String) -> void:
	if maps.erase(name):
		revision += 1
		emit_changed()

func payload_bytes() -> int:
	var total := 0
	for name in maps:
		for level in (maps[name].get("levels", []) as Array): total += (level as PackedByteArray).size()
	return total

## Checks that every held level has exactly the bytes its geometry demands.
func validate() -> Dictionary:
	if format_version != FORMAT_VERSION: return {"ok": false, "message": "Unsupported region format version %d" % format_version}
	if not StrataRegions.valid_cells(cells): return {"ok": false, "message": "Region cells must be a power of two between %d and %d" % [StrataRegions.MIN_CELLS, StrataRegions.MAX_CELLS]}
	if not is_finite(spacing) or spacing <= 0.0 or not origin.is_finite(): return {"ok": false, "message": "Region needs a positive spacing and finite origin"}
	if first_level < 0 or first_level > 15: return {"ok": false, "message": "first_level must be 0..15"}
	if not is_finite(height_min) or not is_finite(height_max) or height_min > height_max: return {"ok": false, "message": "Region height extrema must be finite and ordered"}
	for name in maps:
		var entry: Dictionary = maps[name]
		var checked := StrataRegions.validate_map(cells, entry)
		if not checked.ok: return {"ok": false, "message": "%s: %s" % [name, checked.message]}
		var levels: Array = entry.get("levels", [])
		if levels.is_empty(): return {"ok": false, "message": "%s has no levels" % name}
		if first_level + levels.size() > StrataRegions.max_level(cells, entry) + 1: return {"ok": false, "message": "%s holds levels past its deepest" % name}
		for index in range(levels.size()):
			var level := first_level + index
			var expected := StrataRegions.map_bytes(cells, entry, level)
			if (levels[index] as PackedByteArray).size() != expected:
				return {"ok": false, "message": "%s level %d holds %d bytes, expected %d" % [name, level, (levels[index] as PackedByteArray).size(), expected]}
	return {"ok": true, "message": ""}
