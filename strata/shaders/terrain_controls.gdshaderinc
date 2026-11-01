// The host shader defines terrain_control_corner(position, offset, ids, weights, fraction)
// before including this file: the raw IDs and weights of one corner of the 2x2 control cell
// around the position, and the fractional position inside that cell.
// Categorical IDs are fetched exactly, never bilinearly interpolated.
// Bilinear interpolation applies to contribution weights. Up to 16 distinct
// IDs are merged before top-four selection. Subtracting the fifth weight from
// the retained four fades an ordinary fourth/fifth exchange to zero instead of
// dropping a nonzero contribution. With <=4 inputs the threshold is zero.
void terrain_blend(vec2 position, out ivec4 result_ids, out vec4 result_weights, out float discarded) {
	vec2 fraction = vec2(0.0);
	int ids[16];
	float weights[16];
	for (int i = 0; i < 16; i++) { ids[i] = -1; weights[i] = 0.0; }
	int count = 0;
	for (int corner = 0; corner < 4; corner++) {
		ivec2 offset = ivec2(corner % 2, corner / 2);
		ivec4 incoming_ids; vec4 incoming_weights;
		terrain_control_corner(position, offset, incoming_ids, incoming_weights, fraction);
		incoming_weights = max(incoming_weights, vec4(0.0));
		float incoming_total = dot(incoming_weights, vec4(1.0));
		if (incoming_total > 0.0) { incoming_weights /= incoming_total; }
		float bilinear = (offset.x == 0 ? 1.0 - fraction.x : fraction.x) * (offset.y == 0 ? 1.0 - fraction.y : fraction.y);
		for (int slot = 0; slot < 4; slot++) {
			float contribution = incoming_weights[slot] * bilinear;
			if (contribution > 0.0) {
				int id = clamp(incoming_ids[slot], 0, 31);
				int found = -1;
				for (int existing = 0; existing < 16; existing++) {
					if (existing < count && ids[existing] == id) { found = existing; }
				}
				if (found < 0 && count < 16) { found = count; ids[count] = id; count++; }
				if (found >= 0) { weights[found] += contribution; }
			}
		}
	}
	float total = 0.0;
	for (int i = 0; i < 16; i++) { total += weights[i]; }
	result_ids = ivec4(0); result_weights = vec4(0.0);
	float retained = 0.0;
	for (int output_slot = 0; output_slot < 4; output_slot++) {
		int best = -1;
		for (int candidate = 0; candidate < 16; candidate++) {
			if (weights[candidate] > 0.0) {
				if (best < 0) { best = candidate; }
				else if (weights[candidate] > weights[best] || (weights[candidate] == weights[best] && ids[candidate] < ids[best])) { best = candidate; }
			}
		}
		if (best >= 0) {
			result_ids[output_slot] = ids[best]; result_weights[output_slot] = weights[best];
			retained += weights[best]; weights[best] = 0.0;
		}
	}
	discarded = total > 0.0 ? max(0.0, total - retained) / total : 0.0;
	if (retained > 0.0) {
		float threshold = 0.0;
		for (int candidate = 0; candidate < 16; candidate++) { threshold = max(threshold, weights[candidate]); }
		if (threshold > 0.0) {
			vec4 softened = max(result_weights - vec4(threshold), vec4(0.0));
			float softened_total = dot(softened, vec4(1.0));
			// >=5 equal maxima have no positive remainder. Keep the deterministic
			// ascending-ID hard selection there; this degenerate tie is discontinuous.
			result_weights = softened_total > 0.0 ? softened / softened_total : result_weights / retained;
		} else { result_weights /= retained; }
	}
	// No assignment is represented by exact zero weights. In particular an
	// editor stage before its material producer must never acquire material 0.
}
