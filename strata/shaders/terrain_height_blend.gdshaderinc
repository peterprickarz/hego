// Painted weights already contain the by-ID merge and top-four selection.
// Multiplicative height gain cannot introduce an unpainted material. A common
// log shift keeps exp2 bounded without threshold pruning or order dependence.
float terrain_finite_height(float value) {
	return isnan(value) || isinf(value) ? 0.5 : clamp(value, 0.0, 1.0);
}

vec4 terrain_height_blend_weights(vec4 painted, vec4 heights, vec4 contrasts, vec4 biases) {
	if (!height_blend_enabled) { return painted; }
	vec4 gains = vec4(0.0);
	float maximum = -100.0;
	float minimum = 100.0;
	float influence = 0.0;
	for (int i = 0; i < 4; i++) {
		if (painted[i] > 0.0) {
			float alpha = isnan(heights[i]) || isinf(heights[i]) ? 0.5 : heights[i];
			float height = clamp(alpha + biases[i], 0.0, 1.0);
			gains[i] = contrasts[i] * (height - 0.5);
			maximum = max(maximum, gains[i]); minimum = min(minimum, gains[i]);
			influence = max(influence, contrasts[i]);
		}
	}
	// Preserve exact identities rather than round-tripping through normalization.
	if (influence == 0.0 || maximum == minimum) { return painted; }
	vec4 adjusted = vec4(0.0);
	for (int i = 0; i < 4; i++) {
		if (painted[i] > 0.0) { adjusted[i] = painted[i] * exp2(gains[i] - maximum); }
	}
	float total = dot(adjusted, vec4(1.0));
	return total > 0.0 ? adjusted / total : painted;
}
