@tool
class_name StrataSurfaceWriterRegistry
extends RefCounted
## Every StrataSurfaceWriter in the process, drawn in one private World3D that only the writer
## passes of StrataSurfaceCache render (top-down, one SubViewport per output). Writers report
## their global bounds here; each StrataRenderer's writer pass listens to [signal changed] and
## refills the cache where a writer was added, moved, changed or removed. See "Surface
## writers" in README.md.

## Global AABB that changed (a writer's old and new bounds merged).
signal changed(bounds: AABB)
## The set of writer ShaderMaterials changed: renderers push their terrain material uniforms
## (for the terrain material helper of strata_surface_writer.gdshaderinc) into new ones.
signal materials_changed

## Writer outputs, each drawn by its own instance into its third of a writer tile: albedo,
## normal + roughness, AO + relief + metallic.
const PASS_COUNT := 3
## Edge in metres of the cells of an entry's footprint grid (see add_entry()).
const FOOTPRINT_CELL := 16.0
const _MAX_FOOTPRINT_CELLS := 1 << 20
const _MAX_LOOKUP_CELLS := 1024
const _META := &"strata_surface_writer_registry"

var world := World3D.new()
var _entries := {}
var _next_id := 1
## Material RID -> [Material, reference count]
var _materials := {}


## Writer passes using the registry (StrataRenderer surface caches).
var users := 0


## The process-wide registry (kept in Engine metadata so it survives script reloads). It is
## dropped again once no writer and no writer pass uses it (release_if_unused()), so its
## World3D is freed with the scene tree, before the RenderingServer shuts down.
static func shared() -> StrataSurfaceWriterRegistry:
	if Engine.has_meta(_META):
		var existing: Variant = Engine.get_meta(_META)
		if existing is StrataSurfaceWriterRegistry: return existing
	var registry := StrataSurfaceWriterRegistry.new()
	Engine.set_meta(_META, registry)
	return registry


## Drops the shared registry when nothing uses it any more.
static func release_if_unused() -> void:
	if not Engine.has_meta(_META): return
	var existing: Variant = Engine.get_meta(_META)
	if not (existing is StrataSurfaceWriterRegistry) or ((existing as StrataSurfaceWriterRegistry).entry_count() == 0 and (existing as StrataSurfaceWriterRegistry).users <= 0):
		Engine.remove_meta(_META)


func _init() -> void:
	# Unshaded writers output exactly what they write: no tonemapping curve, no ambient or fog.
	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.background_color = Color(0, 0, 0, 0)
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.tonemap_exposure = 1.0
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	world.environment = environment


func scenario() -> RID:
	return world.scenario


## Adds an entry; returns its id. [param boxes] are the global boxes of its meshes: with them,
## overlaps_xz() tests the FOOTPRINT_CELL cells they touch instead of [param bounds] alone (a
## writer of many meshes spread over the terrain does not claim the ground between them).
func add_entry(bounds: AABB, materials: Array, boxes: Array = []) -> int:
	var id := _next_id
	_next_id += 1
	_entries[id] = {"bounds": bounds, "materials": [], "cells": _footprint(boxes)}
	_set_materials(id, materials)
	if bounds.has_volume() or bounds.size != Vector3.ZERO: changed.emit(bounds)
	return id


## Moves or reshapes an entry; emits the union of its old and new bounds.
func update_entry(id: int, bounds: AABB, materials: Array, boxes: Array = []) -> void:
	if not _entries.has(id): return
	var old: AABB = _entries[id].bounds
	_entries[id].bounds = bounds
	_entries[id].cells = _footprint(boxes)
	_set_materials(id, materials)
	changed.emit(old.merge(bounds))


## Content of an entry changed in place (material parameters, priority).
func touch_entry(id: int) -> void:
	if _entries.has(id): changed.emit(_entries[id].bounds)


func remove_entry(id: int) -> void:
	if not _entries.has(id): return
	var old: AABB = _entries[id].bounds
	_set_materials(id, [])
	_entries.erase(id)
	changed.emit(old)


func entry_count() -> int:
	return _entries.size()


## True when any writer's XZ footprint intersects the global XZ rectangle. Never false where a
## writer draws; true for some ground beside one.
func overlaps_xz(rect: Rect2) -> bool:
	for entry: Dictionary in _entries.values():
		var bounds: AABB = entry.bounds
		if not Rect2(bounds.position.x, bounds.position.z, bounds.size.x, bounds.size.z).intersects(rect, true): continue
		var cells: Variant = entry.get("cells")
		if cells == null: return true
		var first := Vector2i((rect.position / FOOTPRINT_CELL).floor())
		var last := Vector2i((rect.end / FOOTPRINT_CELL).floor())
		if (last.x - first.x + 1) * (last.y - first.y + 1) > _MAX_LOOKUP_CELLS: return true
		for y in range(first.y, last.y + 1):
			for x in range(first.x, last.x + 1):
				if (cells as Dictionary).has(Vector2i(x, y)): return true
	return false


## The footprint grid cells the boxes touch, or null (the entry's bounds are its footprint)
## without boxes or when they would take too many cells.
static func _footprint(boxes: Array) -> Variant:
	if boxes.is_empty(): return null
	var cells := {}
	for box: AABB in boxes:
		var first := Vector2i((Vector2(box.position.x, box.position.z) / FOOTPRINT_CELL).floor())
		var last := Vector2i((Vector2(box.end.x, box.end.z) / FOOTPRINT_CELL).floor())
		if cells.size() + (last.x - first.x + 1) * (last.y - first.y + 1) > _MAX_FOOTPRINT_CELLS: return null
		for y in range(first.y, last.y + 1):
			for x in range(first.x, last.x + 1):
				cells[Vector2i(x, y)] = true
	return cells


## The writer ShaderMaterials currently in use.
func materials() -> Array[Material]:
	var result: Array[Material] = []
	for pair: Array in _materials.values():
		if is_instance_valid(pair[0]): result.append(pair[0])
	return result


func _set_materials(id: int, materials: Array) -> void:
	var before := _materials.size()
	var added := false
	for material: Material in _entries[id].materials:
		var rid := material.get_rid()
		if _materials.has(rid):
			_materials[rid][1] -= 1
			if _materials[rid][1] <= 0: _materials.erase(rid)
	var kept: Array[Material] = []
	for material: Variant in materials:
		if not (material is Material): continue
		kept.append(material)
		var rid := (material as Material).get_rid()
		if _materials.has(rid): _materials[rid][1] += 1
		else:
			_materials[rid] = [material, 1]
			added = true
	_entries[id].materials = kept
	if added or _materials.size() != before: materials_changed.emit()
