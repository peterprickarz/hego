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
