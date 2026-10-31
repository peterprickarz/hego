@tool
class_name StrataBrush
extends RefCounted
## One dab operates on the selected layer's own lattice. All targets are read
## before writes, so smoothing never feeds its own partially updated results.
## A dab writes its samples as one region edit, so the layer emits one change.

const MAX_CANDIDATE_SAMPLES := 65536
const MAX_RADIUS_METERS := 4096.0
# At most 255 samples per axis, including both endpoints, at any grid phase.
const SAFE_RADIUS_IN_SAMPLES := 127.0

## Empty means the clipped dab fits the budget (or has no valid candidates).
## Both editor and runtime display this before attempting a dense dab.
static func sample_limit_message(layer: StrataLayer, position: Vector2, radius: float) -> String:
	var grid := candidate_grid(layer, position, radius)
	if grid.is_empty() or not _exceeds_sample_limit(grid):
		return ""
	return "Brush exceeds 65,536 samples. Use radius ≤ %s m at %s m spacing, or a NEW manual layer with spacing ≥ %s m. No samples changed." % [snappedf(layer.data.sample_spacing * SAFE_RADIUS_IN_SAMPLES, 0.001), layer.data.sample_spacing, snappedf(ceil(radius / SAFE_RADIUS_IN_SAMPLES * 1000.0) / 1000.0, 0.001)]

static func _exceeds_sample_limit(grid: Dictionary) -> bool:
	return grid.width > MAX_CANDIDATE_SAMPLES or grid.height > MAX_CANDIDATE_SAMPLES or grid.width * grid.height > MAX_CANDIDATE_SAMPLES

## The sample-index rectangle a dab can touch: [code]{first, last, width, height}[/code] in the
## layer's lattice, clipped to the terrain bounds; empty when the dab touches nothing.
static func candidate_grid(layer: StrataLayer, position: Vector2, radius: float) -> Dictionary:
	if not is_instance_valid(layer) or not position.is_finite() or not is_finite(radius) or radius <= 0.0:
		return {}
	var terrain := layer.get_parent() as StrataTerrain3D
	if terrain == null:
		return {}
	var spacing: float = layer.data.sample_spacing
	if not is_finite(spacing) or spacing <= 0.0:
		return {}
	var origin: Vector2 = layer.data.grid_origin
	var bounds := terrain.base_bounds
	if not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite() or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return {}
	# Clip before integer conversion; a huge radius on a tiny terrain is safe.
	var minimum := Vector2(maxf(position.x - radius, bounds.position.x), maxf(position.y - radius, bounds.position.y))
	var maximum := Vector2(minf(position.x + radius, bounds.end.x), minf(position.y + radius, bounds.end.y))
	if minimum.x > maximum.x or minimum.y > maximum.y:
		return {}
	var first_x := ceil((minimum.x - origin.x) / spacing)
	var first_y := ceil((minimum.y - origin.y) / spacing)
	var last_x := floor((maximum.x - origin.x) / spacing)
	var last_y := floor((maximum.y - origin.y) / spacing)
	# Native indices are Vector2i; out-of-domain coordinates are never wrapped.
	if first_x > 2147483647.0 or first_y > 2147483647.0 or last_x < -2147483648.0 or last_y < -2147483648.0:
		return {}
	var first := Vector2i(int(maxf(first_x, -2147483648.0)), int(maxf(first_y, -2147483648.0)))
	var last := Vector2i(int(minf(last_x, 2147483647.0)), int(minf(last_y, 2147483647.0)))
	var width := last.x - first.x + 1
	var height := last.y - first.y + 1
	if width <= 0 or height <= 0:
		return {}
	return {"first": first, "last": last, "width": width, "height": height}

## Returns how many samples changed. Writes happen as one region edit per dab.
static func apply_brush(layer: StrataLayer, position: Vector2, radius: float, strength: float, operation: String, channel: StringName = &"height", flatten_height: float = NAN) -> int:
	if not position.is_finite() or not is_finite(radius) or not is_finite(strength) or (not is_nan(flatten_height) and not is_finite(flatten_height)):
		push_warning("Terrain brush requires finite position, radius, strength and flatten target.")
		return 0
	if String(channel).strip_edges().is_empty():
		push_warning("Terrain brush requires a nonempty channel name; no samples were changed.")
		return 0
	if not is_instance_valid(layer):
		return 0
	if layer.procedural:
		push_warning("Procedural terrain caches cannot be sculpted. Select or add a manual layer above this stage.")
		return 0
	var terrain := layer.get_parent() as StrataTerrain3D
	if terrain == null or not terrain.is_transform_valid() or not layer.enabled or radius <= 0.0 or (strength <= 0.0 and operation != "erase"):
		return 0
	var data := layer.data
	var spacing: float = data.sample_spacing
	if not is_finite(spacing) or spacing <= 0.0:
		return 0
	var origin: Vector2 = data.grid_origin
	var grid := candidate_grid(layer, position, radius)
	if grid.is_empty():
		return 0
	if _exceeds_sample_limit(grid):
		push_warning(sample_limit_message(layer, position, radius))
		return 0
	if is_material_channel(layer, channel):
		return _erase_material_channels(layer, position, radius, grid) if operation == "erase" else _apply_material_brush(layer, position, radius, strength, operation, channel, flatten_height, grid)
	var first: Vector2i = grid.first
	var last: Vector2i = grid.last
	var target_flat := terrain.sample_channel(channel, position, layer) if is_nan(flatten_height) else flatten_height
	# Every target is decided before anything is written, from the terrain as it was.
	var values := Image.create(grid.width, grid.height, false, Image.FORMAT_RF)
	var mask := Image.create(grid.width, grid.height, false, Image.FORMAT_RF)
	var count := 0
	for z in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			var index := Vector2i(x, z)
			var point := origin + Vector2(index) * spacing
			if not terrain.contains_position(point):
				continue
			var distance := point.distance_to(position)
			if distance >= radius:
				continue
			var influence := 1.0 - smoothstep(0.0, 1.0, distance / radius)
			if influence <= 0.0:
				continue
			if operation == "erase":
				if data.has_sample(channel, index):
					mask.set_pixel(x - first.x, z - first.y, Color(1.0, 0.0, 0.0, 1.0))
					count += 1
				continue
			var current := terrain.sample_channel(channel, point, layer)
			var desired := current
			match operation:
				"raise": desired += strength * influence
				"lower": desired -= strength * influence
				"flatten": desired = lerpf(current, target_flat, clampf(strength * influence, 0.0, 1.0))
				"smooth":
					var total := 0.0
					var neighbours := 0
					for offset in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
						var neighbour: Vector2 = point + offset * spacing
						if terrain.contains_position(neighbour):
							total += terrain.sample_channel(channel, neighbour, layer)
							neighbours += 1
					if neighbours > 0:
						desired = lerpf(current, total / neighbours, clampf(strength * influence, 0.0, 1.0))
				_: return 0
			if layer.get_composition(channel) == StrataLayer.Composition.ADD:
				desired -= terrain.sample_below(channel, point, layer)
			# Explicit first touch, even if desired equals the procedural surface.
			values.set_pixel(x - first.x, z - first.y, Color(desired, 0.0, 0.0, 1.0))
			mask.set_pixel(x - first.x, z - first.y, Color(1.0, 0.0, 0.0, 1.0))
			count += 1
	if count == 0:
		return 0
	var written: bool = data.erase_dense(channel, first, mask) if operation == "erase" else data.patch_dense(channel, first, values, mask)
	return count if written else 0


# ─────────────────────────────────────────────
# Material weight channels
#
# The renderer keeps the four strongest materials at each point and normalizes their
# weights, so a weight only means something relative to the others. Adding metres to one
# channel therefore never converges: a weight pushed to 100 by many dabs makes a later 0.6
# dab of another material invisible. Material channels (the terrain's
# editor_material_channels) paint coverage instead: the dab moves the painted material's
# share of the mix toward its target at a rate of strength × falloff and rescales the other
# materials so the shares still sum to one. Every material channel is written at the touched
# samples, so the layer owns the complete mix there and nothing below can shift it.
# ─────────────────────────────────────────────

## True when [param channel] is one of the terrain's material weight channels.
static func is_material_channel(layer: StrataLayer, channel: StringName) -> bool:
	if not is_instance_valid(layer): return false
	var terrain := layer.get_parent() as StrataTerrain3D
	return terrain != null and terrain.editor_material_channels.has(String(channel))

## The channels one dab on [param channel] writes or erases: every material channel for a
## material channel, otherwise the channel itself. Undo records must cover all of them.
static func written_channels(layer: StrataLayer, channel: StringName) -> Array[StringName]:
	var result: Array[StringName] = []
	if is_material_channel(layer, channel):
		for name in (layer.get_parent() as StrataTerrain3D).editor_material_channels: result.append(StringName(name))
	else: result.append(channel)
	return result

## The value Flatten pulls toward when a stroke starts at [param position]: the material's
## share of the mix (0 to 1) for a material channel, the composed value otherwise.
static func flatten_target(layer: StrataLayer, channel: StringName, position: Vector2) -> float:
	if not is_instance_valid(layer) or not position.is_finite(): return NAN
	var terrain := layer.get_parent() as StrataTerrain3D
	if terrain == null: return NAN
	if is_material_channel(layer, channel): return _material_share(terrain, layer, channel, position)
	return terrain.sample_channel(channel, position, layer)

## [param channel]'s share of the material weights composed through [param layer] at
## [param position]; 0 where no material has any weight.
static func _material_share(terrain: StrataTerrain3D, layer: StrataLayer, channel: StringName, position: Vector2) -> float:
	var total := 0.0
	var own := 0.0
	for name in terrain.editor_material_channels:
		var value := maxf(0.0, terrain.sample_channel(StringName(name), position, layer))
		total += value
		if StringName(name) == channel: own = value
	return own / total if total > 0.0 else 0.0

static func _apply_material_brush(layer: StrataLayer, position: Vector2, radius: float, strength: float, operation: String, channel: StringName, flatten_share: float, grid: Dictionary) -> int:
	if operation not in ["raise", "lower", "flatten", "smooth"]: return 0
	var terrain := layer.get_parent() as StrataTerrain3D
	var data := layer.data
	var spacing: float = data.sample_spacing
	var origin: Vector2 = data.grid_origin
	var channels: PackedStringArray = terrain.editor_material_channels
	var own := channels.find(String(channel))
	var first: Vector2i = grid.first
	var last: Vector2i = grid.last
	var values: Array[Image] = []
	for index in range(channels.size()): values.append(Image.create(grid.width, grid.height, false, Image.FORMAT_RF))
	var mask := Image.create(grid.width, grid.height, false, Image.FORMAT_RF)
	var count := 0
	for z in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			var point := origin + Vector2(x, z) * spacing
			if not terrain.contains_position(point): continue
			var distance := point.distance_to(position)
			if distance >= radius: continue
			var influence := 1.0 - smoothstep(0.0, 1.0, distance / radius)
			if influence <= 0.0: continue
			var rate := clampf(strength * influence, 0.0, 1.0)
			# The complete mix as composed through this layer before the dab; a negative
			# weight somewhere below counts as none.
			var current := PackedFloat32Array()
			var total := 0.0
			for name in channels:
				var value := maxf(0.0, terrain.sample_channel(StringName(name), point, layer))
				current.append(value)
				total += value
			var share := current[own] / total if total > 0.0 else 0.0
			var target := share
			match operation:
				"raise": target = 1.0
				"lower": target = 0.0
				"flatten": target = clampf(flatten_share, 0.0, 1.0) if not is_nan(flatten_share) else share
				"smooth":
					var sum := 0.0
					var neighbours := 0
					for offset in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
						var neighbour: Vector2 = point + offset * spacing
						if terrain.contains_position(neighbour):
							sum += _material_share(terrain, layer, channel, neighbour)
							neighbours += 1
					if neighbours > 0: target = sum / neighbours
			var desired := lerpf(share, target, rate)
			# The other materials keep their proportions. Once a material was saturated the
			# layer holds exact zeros for the rest, so their proportions come from the stack
			# below the layer: lowering then reveals that mix again.
			var proportions := current
			var others := total - current[own]
			if others <= 0.0:
				proportions = PackedFloat32Array()
				others = 0.0
				for index in range(channels.size()):
					var below := maxf(0.0, terrain.sample_below(StringName(channels[index]), point, layer)) if index != own else 0.0
					proportions.append(below)
					others += below
			for index in range(channels.size()):
				var value: float
				if index == own: value = desired
				elif others > 0.0: value = proportions[index] * (1.0 - desired) / others
				else: value = 0.0
				if layer.get_composition(StringName(channels[index])) == StrataLayer.Composition.ADD:
					value -= terrain.sample_below(StringName(channels[index]), point, layer)
				values[index].set_pixel(x - first.x, z - first.y, Color(value, 0.0, 0.0, 1.0))
			mask.set_pixel(x - first.x, z - first.y, Color(1.0, 0.0, 0.0, 1.0))
			count += 1
	if count == 0:
		return 0
	for index in range(channels.size()):
		if not data.patch_dense(StringName(channels[index]), first, values[index], mask): return 0
	return count

## Releases the layer's samples of every material channel inside the dab, so the mix below
## shows through. Returns the number of distinct samples released.
static func _erase_material_channels(layer: StrataLayer, position: Vector2, radius: float, grid: Dictionary) -> int:
	var terrain := layer.get_parent() as StrataTerrain3D
	var data := layer.data
	var first: Vector2i = grid.first
	var last: Vector2i = grid.last
	var masks := {}
	var released := {}
	for name in terrain.editor_material_channels:
		var mask := Image.create(grid.width, grid.height, false, Image.FORMAT_RF)
		var any := false
		for z in range(first.y, last.y + 1):
			for x in range(first.x, last.x + 1):
				var index := Vector2i(x, z)
				var point: Vector2 = data.grid_origin + Vector2(index) * data.sample_spacing
				if not terrain.contains_position(point) or point.distance_to(position) >= radius or not data.has_sample(StringName(name), index): continue
				mask.set_pixel(x - first.x, z - first.y, Color(1.0, 0.0, 0.0, 1.0))
				any = true
				released[index] = true
		if any: masks[name] = mask
	for name in masks:
		if not data.erase_dense(StringName(name), first, masks[name]): return 0
	return released.size()


# ─────────────────────────────────────────────
# Undo records
#
# A stroke is many dabs. Each record holds the dab's rectangle before and after, so undo
# stores and restores only what the stroke touched rather than whole-layer snapshots.
# ─────────────────────────────────────────────

## Captures [param grid] (from [method candidate_grid]) of [param channel] before a dab.
static func begin_record(data: StrataLayerData, channel: StringName, grid: Dictionary) -> Dictionary:
	var before: Dictionary = data.read_dense(channel, grid.first, Vector2i(grid.width, grid.height))
	return {"channel": channel, "origin": grid.first, "size": Vector2i(grid.width, grid.height), "before": before}

## Completes a record after the dab. Returns false when the dab changed nothing.
static func finish_record(data: StrataLayerData, record: Dictionary) -> bool:
	var after: Dictionary = data.read_dense(record.channel, record.origin, record.size)
	record["after"] = after
	return (after.image as Image).get_data() != (record.before.image as Image).get_data() or (after.ownership as Image).get_data() != (record.before.ownership as Image).get_data()

## Puts every record's "before" (undo) or "after" (redo) state back, one region edit each.
static func restore_records(data: StrataLayerData, records: Array, state: String) -> void:
	var ordered := records.duplicate()
	if state == "before":
		ordered.reverse()
	for record in ordered:
		var snapshot: Dictionary = record[state]
		data.restore_dense(record.channel, record.origin, snapshot.image, snapshot.ownership)
