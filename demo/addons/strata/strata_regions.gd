@tool
class_name StrataRegions
extends RefCounted
## Region geometry: the one implementation of the formulas in
## docs/development/strata_regions_plan.md ("Geometry"). Every map of every region is addressed
## through these functions; nothing else may compute region texel positions.
##
## A region spec is a Dictionary:
##   {bounds: Rect2, spacing: float, cells: int, apron: int, maps: {name: map}}
## and a map description is a Dictionary:
##   {format: Image.Format, kind: KIND_SAMPLE | KIND_CELL, scale: int, apron: int}
## Only built-in types are used, so runtime-only projects can load this script.

const DEFAULT_CELLS := 256
const DEFAULT_APRON := 2
const MIN_CELLS := 16
const MAX_CELLS := 4096

const KIND_SAMPLE := "sample"
const KIND_CELL := "cell"

const MAP_HEIGHT := "height"
const MAP_MATERIAL_IDS := "material_ids"
const MAP_MATERIAL_WEIGHTS := "material_weights"
const MAP_HOLES := "holes"
const MAP_NAV_EXCLUSION := "nav_exclusion"
const MAP_MACRO := "macro"
## Baked navigation-profile masks are cell maps named NAV_PROFILE_PREFIX + profile.
const NAV_PROFILE_PREFIX := "nav_"

## Formats a region map may use, with bytes per texel.
const FORMAT_BYTES := {
	Image.FORMAT_L8: 1, Image.FORMAT_R8: 1, Image.FORMAT_RH: 2, Image.FORMAT_RF: 4,
	Image.FORMAT_RGBA8: 4, Image.FORMAT_RGBAH: 8, Image.FORMAT_RGBAF: 16,
}

static func map(format: int, kind: String, scale: int = 1, apron: int = DEFAULT_APRON) -> Dictionary:
	return {"format": format, "kind": kind, "scale": scale, "apron": apron}

## The standard set of composed maps: height, material ids and weights, holes at the sample
## spacing, macro tint and AO at a quarter of it.
static func standard_spec(bounds: Rect2, spacing: float, cells: int = DEFAULT_CELLS, apron: int = DEFAULT_APRON) -> Dictionary:
	return {
		"bounds": bounds, "spacing": spacing, "cells": cells, "apron": apron,
		"maps": {
			MAP_HEIGHT: map(Image.FORMAT_RF, KIND_SAMPLE, 1, apron),
			MAP_MATERIAL_IDS: map(Image.FORMAT_RGBA8, KIND_SAMPLE, 1, apron),
			MAP_MATERIAL_WEIGHTS: map(Image.FORMAT_RGBA8, KIND_SAMPLE, 1, apron),
			MAP_HOLES: map(Image.FORMAT_L8, KIND_CELL, 1, apron),
			MAP_MACRO: map(Image.FORMAT_RGBAH, KIND_SAMPLE, 4, 1),
		},
	}

static func _error(message: String) -> Dictionary:
	return {"ok": false, "message": message}

static func valid_cells(cells: int) -> bool:
	return cells >= MIN_CELLS and cells <= MAX_CELLS and (cells & (cells - 1)) == 0

static func validate_map(cells: int, description: Dictionary) -> Dictionary:
	if not description.has("format") or not FORMAT_BYTES.has(int(description.format)):
		return _error("Region map format must be L8, R8, RH, RF, RGBA8, RGBAH or RGBAF")
	if String(description.get("kind", "")) not in [KIND_SAMPLE, KIND_CELL]:
		return _error("Region map kind must be sample or cell")
	var scale := int(description.get("scale", 1))
	if scale < 1 or (scale & (scale - 1)) != 0 or scale > cells:
		return _error("Region map scale must be a power of two dividing the region cells")
	var apron := int(description.get("apron", DEFAULT_APRON))
	if apron < 0 or apron * scale > cells / 2:
		return _error("Region map apron must be nonnegative and at most half a region")
	return {"ok": true, "message": ""}

static func validate_spec(spec: Dictionary) -> Dictionary:
	var bounds: Rect2 = spec.get("bounds", Rect2())
	if not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return _error("Region spec needs finite positive bounds")
	var spacing := float(spec.get("spacing", 0.0))
	if not is_finite(spacing) or spacing <= 0.0:
		return _error("Region spec needs a positive finite spacing")
	var cells := int(spec.get("cells", 0))
	if not valid_cells(cells):
		return _error("Region cells must be a power of two between %d and %d" % [MIN_CELLS, MAX_CELLS])
	var apron := int(spec.get("apron", -1))
	if apron < 0 or apron > cells / 2:
		return _error("Region apron must be nonnegative and at most half a region")
	var maps: Dictionary = spec.get("maps", {})
	for name in maps:
		if String(name).is_empty(): return _error("Region map names must not be empty")
		var checked := validate_map(cells, maps[name])
		if not checked.ok: return _error("%s: %s" % [name, checked.message])
	var grid := grid_size(spec)
	if grid.x < 1 or grid.y < 1 or grid.x * grid.y > 1 << 20:
		return _error("Region grid must hold between one and 1,048,576 regions")
	return {"ok": true, "message": ""}

## Metres covered by one region along each axis.
static func extent(spec: Dictionary) -> float:
	return float(spec.cells) * float(spec.spacing)

## Regions along each axis; the last ones may extend past the bounds.
static func grid_size(spec: Dictionary) -> Vector2i:
	var size: Vector2 = (spec.bounds as Rect2).size / extent(spec)
	# Bounds that are an exact multiple must not gain an empty region through rounding.
	return Vector2i(ceili(size.x - 1e-6), ceili(size.y - 1e-6)).max(Vector2i.ONE)

static func contains_region(spec: Dictionary, xy: Vector2i) -> bool:
	var grid := grid_size(spec)
	return xy.x >= 0 and xy.y >= 0 and xy.x < grid.x and xy.y < grid.y

## Terrain-local XZ of the region's first sample (no apron).
static func region_origin(spec: Dictionary, xy: Vector2i) -> Vector2:
	return (spec.bounds as Rect2).position + Vector2(xy) * extent(spec)

static func region_bounds(spec: Dictionary, xy: Vector2i) -> Rect2:
	return Rect2(region_origin(spec, xy), Vector2.ONE * extent(spec))

## The region containing a terrain-local position; may lie outside the grid, check with
## [method contains_region]. Positions on a shared edge belong to the higher region.
static func region_at(spec: Dictionary, position: Vector2) -> Vector2i:
	var relative := (position - (spec.bounds as Rect2).position) / extent(spec)
	return Vector2i(floori(relative.x), floori(relative.y))

## Texels per cell axis of a map at a level: cells / (scale << level).
static func texels_per_axis(cells: int, description: Dictionary, level: int) -> int:
	return cells / (int(description.get("scale", 1)) << level)

## Metres between two texels of a map at a level.
static func texel_step(spec: Dictionary, description: Dictionary, level: int) -> float:
	return float(spec.spacing) * float(int(description.get("scale", 1)) << level)

## Deepest level at which the map still has at least one texel per region.
static func max_level(cells: int, description: Dictionary) -> int:
	var level := 0
	while texels_per_axis(cells, description, level + 1) >= 1: level += 1
	return level

## Size in texels of a region's map at a level, apron included.
static func map_size(cells: int, description: Dictionary, level: int = 0) -> Vector2i:
	var n := texels_per_axis(cells, description, level)
	var apron := int(description.get("apron", DEFAULT_APRON))
	var side := n + 2 * apron + (1 if String(description.kind) == KIND_SAMPLE else 0)
	return Vector2i(side, side)

static func bytes_per_texel(format: int) -> int:
	return int(FORMAT_BYTES.get(format, 0))

static func map_bytes(cells: int, description: Dictionary, level: int = 0) -> int:
	var size := map_size(cells, description, level)
	return size.x * size.y * bytes_per_texel(int(description.format))

## The composition window of a region's map at a level, in the indices of that map's lattice
## (sample 0 at bounds.position, one index per texel step): {first: Vector2i, size: Vector2i,
## origin: Vector2 (terrain-local XZ of texel (0,0), apron included), step: float}.
static func map_window(spec: Dictionary, xy: Vector2i, description: Dictionary, level: int = 0) -> Dictionary:
	var n := texels_per_axis(spec.cells, description, level)
	var apron := int(description.get("apron", DEFAULT_APRON))
	var step := texel_step(spec, description, level)
	var first := xy * n - Vector2i.ONE * apron
	return {"first": first, "size": map_size(spec.cells, description, level), "origin": (spec.bounds as Rect2).position + Vector2(first) * step, "step": step}

## Terrain-local XZ of a texel of a region's map. For a cell map this is the cell's minimum
## corner.
static func texel_position(spec: Dictionary, xy: Vector2i, description: Dictionary, texel: Vector2i, level: int = 0) -> Vector2:
	var window := map_window(spec, xy, description, level)
	return window.origin + Vector2(texel) * window.step

## Fractional texel coordinate of a terrain-local position in a region's map; texel (u, v) is
## at integer coordinates, so sampling at (coordinate + 0.5) / size with linear filtering
## interpolates correctly.
static func texel_at(spec: Dictionary, xy: Vector2i, description: Dictionary, position: Vector2, level: int = 0) -> Vector2:
	var window := map_window(spec, xy, description, level)
	return (position - window.origin) / window.step

## The texel rectangle of a region's map that a terrain-local rectangle can affect, clipped to
## the map; empty when they do not overlap.
static func texel_rect(spec: Dictionary, xy: Vector2i, description: Dictionary, area: Rect2, level: int = 0) -> Rect2i:
	var window := map_window(spec, xy, description, level)
	var begin := Vector2i(((area.position - window.origin) / window.step).floor()).max(Vector2i.ZERO)
	var end := Vector2i(((area.end - window.origin) / window.step).ceil()).min(window.size - Vector2i.ONE)
	if end.x < begin.x or end.y < begin.y: return Rect2i()
	return Rect2i(begin, end - begin + Vector2i.ONE)

## Regions whose maps (apron included, at level 0 of [param description]) overlap a
## terrain-local rectangle, clipped to the grid.
static func regions_touching(spec: Dictionary, area: Rect2, description: Dictionary = {}) -> Array[Vector2i]:
	var margin := 0.0
	if not description.is_empty():
		margin = float(int(description.get("apron", DEFAULT_APRON))) * texel_step(spec, description, 0)
	var grown := area.grow(margin)
	var first := region_at(spec, grown.position).max(Vector2i.ZERO)
	var last := region_at(spec, grown.end).min(grid_size(spec) - Vector2i.ONE)
	var result: Array[Vector2i] = []
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			result.append(Vector2i(x, y))
	return result

## Image over a level's bytes; the bytes are copied by Image.
static func image_from_level(description: Dictionary, cells: int, level: int, bytes: PackedByteArray) -> Image:
	var size := map_size(cells, description, level)
	if bytes.size() != size.x * size.y * bytes_per_texel(int(description.format)): return null
	return Image.create_from_data(size.x, size.y, false, int(description.format), bytes)

static func level_from_image(image: Image) -> PackedByteArray:
	return image.get_data()
