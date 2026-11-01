class_name HEGoIslandTransition
extends RefCounted
## Acceptance measurements use actual owned sample boundaries, not a guessed pad radius.

static func _p95(sorted: PackedFloat32Array) -> float:
	return sorted[mini(int(ceil(sorted.size() * 0.95)) - 1, sorted.size() - 1)] if not sorted.is_empty() else 0.0

static func manual_hash(layer: StrataLayer) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(layer.data.snapshot()))
	context.update(var_to_bytes(layer.composition_modes))
	return context.finish().hex_encode()

static func _valid_metrics(value: Variant) -> bool:
	if not value is Dictionary or value.get("ok") != true: return false
	var edges: Variant = value.get("edges")
	if not (edges is int or edges is float) or not is_finite(float(edges)) or float(edges) < 1.0 or float(edges) != floor(float(edges)): return false
	for key in ["mean_step_m", "p95_step_m", "max_step_m"]:
		var number: Variant = value.get(key)
		if not (number is int or number is float) or not is_finite(float(number)) or float(number) < 0.0: return false
	return float(value.mean_step_m) <= float(value.max_step_m) and float(value.p95_step_m) <= float(value.max_step_m)

static func _beats_baseline(result: Dictionary, baseline: Dictionary) -> bool:
	return result.edges == baseline.edges and float(result.mean_step_m) < float(baseline.mean_step_m) * 0.8 and float(result.p95_step_m) < float(baseline.p95_step_m) and float(result.max_step_m) <= float(baseline.max_step_m) * 1.1 + 0.05

static func _same_measurement(a: Dictionary, b: Dictionary) -> bool:
	if a.edges != b.edges: return false
	for key in ["mean_step_m", "p95_step_m", "max_step_m"]:
		if absf(float(a[key]) - float(b[key])) > 0.00001: return false
	return true

static func _no_material_regression(result: Dictionary, accepted: Dictionary) -> bool:
	for key in ["mean_step_m", "p95_step_m", "max_step_m"]:
		if float(result[key]) > float(accepted[key]) * 1.1 + 0.05: return false
	return true

## Policy only: immutable numeric evidence, no scene/cache/Houdini access.
## Old first-migration reports use before/runtime_before as their reference.
static func acceptance_policy(before: Dictionary, after: Dictionary, runtime_before: Dictionary, runtime_after: Dictionary, hashes: Dictionary, prior: Variant = {}) -> Dictionary:
	if not prior is Dictionary: prior = {}
	for metrics in [before, after, runtime_before, runtime_after]:
		if not _valid_metrics(metrics): return {"ok": false, "message": "Transition measurements are missing or invalid"}
	var reference := {"authoring": before.duplicate(true), "runtime": runtime_before.duplicate(true)}
	var repeat := false
	var matching_hashes := true
	for key in ["manual_fine_sha256", "building_sha256"]:
		var digest: Variant = hashes.get(key)
		if not digest is String or digest.length() != 64 or not digest.is_valid_hex_number(false) or prior.get(key) != digest:
			matching_hashes = false
	if matching_hashes and prior.get("protected_layers_identical") == true and prior.get("detail_only") == true:
		var old_reference: Variant = prior.get("reference_baseline", {"authoring": prior.get("before"), "runtime": prior.get("runtime_before"), "source_generation": prior.get("source_generation", "")})
		if old_reference is Dictionary and _valid_metrics(old_reference.get("authoring")) and _valid_metrics(old_reference.get("runtime")) and _valid_metrics(prior.get("after")) and _valid_metrics(prior.get("runtime_after")):
			if _beats_baseline(prior.after, old_reference.authoring) and _beats_baseline(prior.runtime_after, old_reference.runtime) and _same_measurement(before, prior.after) and _same_measurement(runtime_before, prior.runtime_after):
				reference = old_reference.duplicate(true)
				repeat = true
	var accepted := _beats_baseline(after, reference.authoring) and _beats_baseline(runtime_after, reference.runtime)
	if repeat: accepted = accepted and _no_material_regression(after, before) and _no_material_regression(runtime_after, runtime_before)
	return {
		"ok": accepted, "mode": "previously_accepted" if repeat else "fresh_improvement",
		"reference_baseline": reference,
		"current_mean_step_reduction": 1.0 - float(after.mean_step_m) / maxf(float(before.mean_step_m), 0.0000001),
		"reference_mean_step_reduction": 1.0 - float(after.mean_step_m) / maxf(float(reference.authoring.mean_step_m), 0.0000001),
		"message": "Both grids must beat the reference baseline; repeats also retain accepted residuals within 10% + 0.05 m",
	}

static func boundary_metrics(terrain: StrataTerrain3D, layer: StrataLayer) -> Dictionary:
	var rect := layer.data.get_owned_rect(&"height")
	if not rect.has_area(): return {"ok": false, "message": "No owned manual height boundary"}
	if rect.size.x * rect.size.y > 1048576:
		return {"ok": false, "message": "Transition acceptance bounds exceed one million native samples"}
	var dense := layer.data.read_dense(&"height", rect.position - Vector2i.ONE, rect.size + Vector2i(2, 2))
	if not dense.get("ok", false): return dense
	var values: Image = dense.image
	var ownership: Image = dense.ownership
	var differences := PackedFloat32Array()
	var maximum := 0.0
	var total := 0.0
	var inward_slopes := PackedFloat32Array()
	var inward_total := 0.0
	var inward_max := 0.0
	var directions := [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]
	for y in range(1, rect.size.y + 1):
		for x in range(1, rect.size.x + 1):
			var pixel := Vector2i(x, y)
			if ownership.get_pixelv(pixel).r < 0.5: continue
			var target := values.get_pixelv(pixel).r
			for direction in directions:
				if ownership.get_pixelv(pixel + direction).r >= 0.5: continue
				if ownership.get_pixelv(pixel - direction).r >= 0.5:
					var slope := absf(target - values.get_pixelv(pixel - direction).r) / layer.data.sample_spacing
					inward_slopes.append(slope); inward_total += slope; inward_max = maxf(inward_max, slope)
				var index: Vector2i = rect.position - Vector2i.ONE + pixel + direction
				var point := layer.data.grid_origin + Vector2(index) * layer.data.sample_spacing
				var difference := absf(terrain.sample_height(point) - target)
				if not is_finite(difference): return {"ok": false, "message": "Nonfinite boundary surface"}
				differences.append(difference)
				maximum = maxf(maximum, difference)
				total += difference
	if differences.is_empty(): return {"ok": false, "message": "No measurable boundary edges"}
	differences.sort()
	inward_slopes.sort()
	return {
		"ok": true, "edges": differences.size(), "mean_step_m": total / differences.size(),
		"p95_step_m": _p95(differences), "max_step_m": maximum,
		"sample_spacing_m": layer.data.sample_spacing,
		"authored_inward_mean_slope": inward_total / inward_slopes.size() if not inward_slopes.is_empty() else 0.0,
		"authored_inward_p95_slope": _p95(inward_slopes), "authored_inward_max_slope": inward_max,
		"method": "absolute height step from each owned boundary sample to its adjacent unowned native sample",
	}

static func procedural_identity(layer: StrataLayer) -> Dictionary:
	var result := {"revision": layer.procedural_revision, "fields": {}}
	for name in layer.procedural_fields:
		var field: StrataFieldData = layer.procedural_fields[name]
		result.fields[name] = [field.get_instance_id(), field.data.get_revision(), field.sample_origin, field.sample_step_x, field.sample_step_y, field.resolution]
	return result

static func compiled_boundary_metrics(layer: StrataLayer, compiled: Dictionary, neighborhood_width: float = 32.0) -> Dictionary:
	if not compiled.get("ok", false) or not compiled.get("image") is Image or not compiled.get("bounds") is Rect2:
		return {"ok": false, "message": "Compiled field is missing"}
	var image: Image = compiled.image
	var bounds: Rect2 = compiled.bounds
	if image.get_format() != Image.FORMAT_RF or image.get_width() < 2 or image.get_height() < 2:
		return {"ok": false, "message": "Compiled height grid is invalid"}
	var spacing := bounds.size / Vector2(image.get_size() - Vector2i.ONE)
	var owned := layer.data.get_owned_rect(&"height")
	if not owned.has_area() or spacing.x <= 0.0 or spacing.y <= 0.0:
		return {"ok": false, "message": "Compiled boundary needs positive grid and owned height"}
	var native_low := layer.data.grid_origin + Vector2(owned.position) * layer.data.sample_spacing
	var native_high := layer.data.grid_origin + Vector2(owned.end) * layer.data.sample_spacing
	if not is_finite(neighborhood_width) or neighborhood_width < 0.0 or neighborhood_width > 1024.0:
		return {"ok": false, "message": "Invalid acceptance neighborhood width"}
	var margin := Vector2i((Vector2.ONE * neighborhood_width / spacing).ceil()) + Vector2i(2, 2)
	var minimum := Vector2i(((native_low - bounds.position) / spacing).floor()) - margin
	var maximum := Vector2i(((native_high - bounds.position) / spacing).ceil()) + margin
	minimum = minimum.clamp(Vector2i.ZERO, image.get_size() - Vector2i.ONE)
	maximum = maximum.clamp(Vector2i.ZERO, image.get_size() - Vector2i.ONE)
	if (maximum.x - minimum.x + 1) * (maximum.y - minimum.y + 1) > 1048576:
		return {"ok": false, "message": "Compiled acceptance region exceeds one million samples"}
	var differences := PackedFloat32Array()
	var total := 0.0
	var max_step := 0.0
	var nearby_steps := PackedFloat32Array()
	var nearby_max_step := 0.0
	var nearby_max_second_difference := 0.0
	var outside_steps := PackedFloat32Array()
	var outside_max_step := 0.0
	var outside_max_second_difference := 0.0
	for y in range(minimum.y, maximum.y + 1):
		for x in range(minimum.x, maximum.x + 1):
			var pixel := Vector2i(x, y)
			var point := bounds.position + Vector2(pixel) * spacing
			var inside: bool = float(layer.data.sample_channel(&"height", point).coverage) >= 0.5
			for direction in [Vector2i.RIGHT, Vector2i.DOWN]:
				var adjacent: Vector2i = pixel + direction
				if adjacent.x >= image.get_width() or adjacent.y >= image.get_height(): continue
				var next := bounds.position + Vector2(adjacent) * spacing
				var next_inside: bool = float(layer.data.sample_channel(&"height", next).coverage) >= 0.5
				var difference := absf(image.get_pixelv(pixel).r - image.get_pixelv(adjacent).r)
				if not is_finite(difference): return {"ok": false, "message": "Nonfinite compiled boundary"}
				nearby_steps.append(difference); nearby_max_step = maxf(nearby_max_step, difference)
				if not inside and not next_inside:
					outside_steps.append(difference); outside_max_step = maxf(outside_max_step, difference)
				var previous: Vector2i = pixel - direction
				if previous.x >= 0 and previous.y >= 0:
					var second_difference := absf(image.get_pixelv(previous).r - 2.0 * image.get_pixelv(pixel).r + image.get_pixelv(adjacent).r)
					nearby_max_second_difference = maxf(nearby_max_second_difference, second_difference)
					if not inside and not next_inside and float(layer.data.sample_channel(&"height", bounds.position + Vector2(previous) * spacing).coverage) < 0.5:
						outside_max_second_difference = maxf(outside_max_second_difference, second_difference)
				if inside == next_inside: continue
				differences.append(difference); total += difference; max_step = maxf(max_step, difference)
	if differences.is_empty(): return {"ok": false, "message": "Manual footprint has no boundary on the compiled lattice"}
	differences.sort()
	nearby_steps.sort()
	outside_steps.sort()
	return {
		"ok": true, "edges": differences.size(), "mean_step_m": total / differences.size(),
		"p95_step_m": _p95(differences), "max_step_m": max_step,
		"spacing_m": [spacing.x, spacing.y], "neighborhood_width_m": neighborhood_width,
		"nearby_max_step_m": nearby_max_step, "nearby_p95_step_m": _p95(nearby_steps),
		"nearby_max_second_difference_m": nearby_max_second_difference,
		"outside_max_step_m": outside_max_step, "outside_p95_step_m": _p95(outside_steps),
		"outside_max_second_difference_m": outside_max_second_difference,
		"method": "actual compiled lattice edges crossing the manual coverage >= 0.5 boundary; nearby includes footprint plus width; outside excludes all manual-owned endpoints",
	}
