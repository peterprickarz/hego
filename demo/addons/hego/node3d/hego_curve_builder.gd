@tool
class_name HEGoCurveBuilder
extends RefCounted

## Converts the curve dictionaries a curve fetch returns into [Curve3D]s.
##
## Pure geometry, no scene access: [HEGoCurveOutput] handles the nodes. A curve
## dictionary holds [code]positions[/code], [code]type[/code], [code]order[/code],
## [code]is_closed[/code] and, for NURBS, [code]knots[/code].

## Category this file logs under, shown in the session panel filter.
const LOG_CATEGORY := "output"

## Number of samples used for the shortest NURBS curves.
const MIN_NURBS_SAMPLES := 50

## NURBS samples generated per control point, when that is more than [constant MIN_NURBS_SAMPLES].
const NURBS_SAMPLES_PER_POINT := 10

## Positions per Bezier segment in Houdini's flat control point list:
## one on-curve point followed by two off-curve handles.
const BEZIER_STRIDE := 3


## Builds the [Curve3D] matching [param curve]'s type, falling back to a poly curve
## for types this build does not know about.
static func build(curve: Dictionary) -> Curve3D:
	match int(curve.get("type", HEGoAssetNode.CURVE_TYPE_LINEAR)):
		HEGoAssetNode.CURVE_TYPE_LINEAR:
			return build_linear_curve(curve)
		HEGoAssetNode.CURVE_TYPE_NURBS:
			return build_nurbs_curve(curve)
		HEGoAssetNode.CURVE_TYPE_BEZIER:
			return build_bezier_curve(curve)
	HEGoLog.get_singleton().warning(LOG_CATEGORY, "Unsupported curve type %s, building a poly curve instead." % str(curve.get("type", "?")))
	return build_linear_curve(curve)


## Name of a curve type, used to name generated nodes.
static func curve_type_to_string(curve_type: int) -> String:
	match curve_type:
		HEGoAssetNode.CURVE_TYPE_BEZIER:
			return "Bezier"
		HEGoAssetNode.CURVE_TYPE_NURBS:
			return "NURBS"
		HEGoAssetNode.CURVE_TYPE_LINEAR:
			return "Linear"
	return "Unknown"


## Poly curve: every control point becomes a [Curve3D] point.
static func build_linear_curve(curve: Dictionary) -> Curve3D:
	var curve_out := Curve3D.new()
	for position in curve["positions"]:
		curve_out.add_point(position)
	if curve.get("is_closed", false):
		curve_out.set_closed(true)
	return curve_out


## NURBS curve, approximated by sampling.
##
## Curve3D's in/out handles cannot represent NURBS control points, so the curve is
## evaluated at a fixed number of parameter values and rebuilt from those samples.
static func build_nurbs_curve(curve: Dictionary) -> Curve3D:
	var curve_out := Curve3D.new()
	var positions: Array = curve["positions"]
	var order := int(curve.get("order", 4))

	if positions.size() < 2:
		HEGoLog.get_singleton().warning(LOG_CATEGORY, "NURBS curve has fewer than 2 control points, returning empty curve.")
		return curve_out

	var knots: Array = curve["knots"] if curve.has("knots") and curve["knots"] is Array and not curve["knots"].is_empty() else generate_uniform_knots(positions.size(), order)

	if order < 2:
		HEGoLog.get_singleton().warning(LOG_CATEGORY, "NURBS curve has an invalid order (%d), building a poly curve instead." % order)
		return build_linear_curve(curve)

	# The evaluation reads knots up to index positions.size() + order - 2, so a knot
	# vector shorter than that would read out of bounds. Houdini normally sends
	# positions.size() + order knots; anything shorter falls back to a poly curve.
	var required_knots := positions.size() + order - 1
	if knots.size() < required_knots:
		HEGoLog.get_singleton().warning(LOG_CATEGORY, "NURBS curve has too few knots (%d, expected at least %d), building a poly curve instead." % [knots.size(), required_knots])
		return build_linear_curve(curve)

	var degree := order - 1
	var last_idx := positions.size()

	var u_min := float(knots[degree])
	var u_max := float(knots[last_idx])

	var num_samples: int = max(MIN_NURBS_SAMPLES, positions.size() * NURBS_SAMPLES_PER_POINT)
	for sample in range(num_samples):
		# t_param walks the curve's parameter range from u_min to u_max.
		var t_param := u_min + (u_max - u_min) * sample / float(num_samples - 1) if num_samples > 1 else u_min
		curve_out.add_point(evaluate_spline_at_t(t_param, positions, knots, order))

	if curve.get("is_closed", false):
		curve_out.set_closed(true)
	return curve_out


## Evaluates the B-spline defined by [param positions] and [param knots] at [param t_param].
static func evaluate_spline_at_t(t_param: float, positions: Array, knots: Array, order: int) -> Vector3:
	var degree := order - 1
	var last_idx := positions.size()

	var u_min := float(knots[degree])
	var u_max := float(knots[last_idx])
	t_param = clamp(t_param, u_min, u_max)

	# Find the knot span t_param falls into; the basis functions are non-zero only there.
	var k := degree
	for i in range(degree, last_idx):
		if t_param >= knots[i] and t_param < knots[i + 1]:
			k = i
			break
	if t_param == u_max:
		k = last_idx - 1

	var basis := compute_basis_functions(k, t_param, order, knots)

	# The point is the weighted sum of the control points of this span.
	var result := Vector3.ZERO
	for i in range(order):
		var control_point_idx := k - order + 1 + i
		if control_point_idx >= 0 and control_point_idx < positions.size():
			result += basis[i] * positions[control_point_idx]
	return result


## Cox-de Boor basis functions for the span [param k_param], returning [param order] weights.
static func compute_basis_functions(k_param: int, t_param: float, order: int, knots: Array) -> Array:
	var basis_values := []
	var left_distances := []
	var right_distances := []
	for idx in range(order):
		basis_values.append(0.0)
		left_distances.append(0.0)
		right_distances.append(0.0)

	basis_values[0] = 1.0

	for degree_level in range(1, order):
		left_distances[degree_level] = t_param - float(knots[k_param + 1 - degree_level])
		right_distances[degree_level] = float(knots[k_param + degree_level]) - t_param
		var saved_basis := 0.0
		for basis_idx in range(degree_level):
			var basis_ratio: float = basis_values[basis_idx] / (right_distances[basis_idx + 1] + left_distances[degree_level - basis_idx])
			basis_values[basis_idx] = saved_basis + right_distances[basis_idx + 1] * basis_ratio
			saved_basis = left_distances[degree_level - basis_idx] * basis_ratio
		basis_values[degree_level] = saved_basis

	return basis_values


## Clamped uniform knot vector for [param num_control_points] points of [param order].
static func generate_uniform_knots(num_control_points: int, order: int) -> Array:
	var knots := []
	for i in range(num_control_points + order):
		if i < order:
			knots.append(0.0)
		elif i >= num_control_points:
			knots.append(float(num_control_points - order + 1))
		else:
			knots.append(float(i - order + 1))
	return knots


## Bezier curve: every third control point is on the curve, the two in between are
## its handles. Falls back to a poly curve when there are not enough points.
static func build_bezier_curve(curve: Dictionary) -> Curve3D:
	var curve_out := Curve3D.new()
	var positions: Array = curve["positions"]

	if positions.size() < 4:
		HEGoLog.get_singleton().warning(LOG_CATEGORY, "Bezier curve has fewer than the minimum 4 expected control points, returning linear curve.")
		return build_linear_curve(curve)

	@warning_ignore("integer_division")
	var num_points := (positions.size() + 2) / BEZIER_STRIDE

	for idx in range(num_points):
		var pos_idx := BEZIER_STRIDE * idx
		var point_position: Vector3 = positions[pos_idx]
		var in_vec := Vector3()
		var out_vec := Vector3()

		# Houdini control point positions are in global space so we need
		# to convert them to be relative to the current point's position
		if idx > 0:
			in_vec = positions[pos_idx - 1] - point_position
		if pos_idx + 1 < positions.size():
			out_vec = positions[pos_idx + 1] - point_position

		curve_out.add_point(point_position, in_vec, out_vec)

	if curve.get("is_closed", false):
		curve_out.set_closed(true)
	return curve_out
