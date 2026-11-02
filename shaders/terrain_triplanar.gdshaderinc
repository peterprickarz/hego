// Terrain-local triplanar projection. Uniform-free: every input is explicit.
// Axis 0 projects along X, axis 1 along Y (top), axis 2 along Z.
//
// A frame's columns are (image right, image up, outward projection axis). All
// three are right-handed, matching OpenGL green-up normal maps and the BINORMAL
// Godot generates for ordinary meshes. The top projection keeps u = +X, v = +Z
// at one UV unit per terrain metre before uv_scale. Side projections take their
// sign from the projection normal so cliff images are never mirrored; their
// image up is terrain +Y. A sign flip occurs only where that axis weight is 0.

// pow(|n|, sharpness), normalized. The largest component is divided out first
// so the dominant axis cannot underflow at sharpness 64; exact zeros stay zero.
vec3 terrain_triplanar_weights(vec3 normal, float sharpness) {
	vec3 magnitude = abs(normal);
	magnitude /= max(magnitude.x, max(magnitude.y, magnitude.z));
	// ShaderMaterial arrays start at zero before renderer binding, including
	// existing editor instances when this uniform is added by shader hot reload.
	float exponent = sharpness > 0.0 ? clamp(sharpness, 1.0, 64.0) : 4.0;
	vec3 weights = pow(magnitude, vec3(exponent));
	return weights / (weights.x + weights.y + weights.z);
}

// Per-material projection mode on top of terrain_triplanar_weights. Mode 0 is
// the unchanged triplanar path. Unused axes get exactly zero weight, so callers
// skip their fetches. ShaderMaterial int arrays start at zero (triplanar).
vec3 terrain_projection_weights(vec3 normal, float sharpness, int mode) {
	if (mode <= 0 || mode > 3) { return terrain_triplanar_weights(normal, sharpness); }
	if (mode == 3) { return vec3(0.0, 1.0, 0.0); }
	vec3 magnitude = abs(normal);
	if (mode == 2) {
		// Near-horizontal surface: no meaningful side direction, so use one side
		// axis instead of smearing between two noisy ones.
		if (max(magnitude.x, magnitude.z) < 0.0001) { return vec3(0.0, 0.0, 1.0); }
		magnitude.y = 0.0;
	} else {
		// Biplanar: drop the weakest axis (ties keep Y, then X).
		if (magnitude.y <= magnitude.x && magnitude.y <= magnitude.z) { magnitude.y = 0.0; }
		else if (magnitude.x <= magnitude.z) { magnitude.x = 0.0; }
		else { magnitude.z = 0.0; }
	}
	magnitude /= max(magnitude.x, max(magnitude.y, magnitude.z));
	float exponent = sharpness > 0.0 ? clamp(sharpness, 1.0, 64.0) : 4.0;
	vec3 weights = pow(magnitude, vec3(exponent));
	return weights / (weights.x + weights.y + weights.z);
}

mat3 terrain_triplanar_frame(int axis, vec3 normal) {
	if (axis == 0) {
		float side = normal.x < 0.0 ? -1.0 : 1.0;
		return mat3(vec3(0.0, 0.0, -side), vec3(0.0, 1.0, 0.0), vec3(side, 0.0, 0.0));
	}
	if (axis == 2) {
		float side = normal.z < 0.0 ? -1.0 : 1.0;
		return mat3(vec3(side, 0.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, side));
	}
	return mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, 0.0, -1.0), vec3(0.0, 1.0, 0.0));
}

// Image v grows downward, opposite the frame's up column. Linear, so it maps
// both points and their screen derivatives.
vec2 terrain_triplanar_uv(mat3 frame, vec3 point) {
	return vec2(dot(frame[0], point), -dot(frame[1], point));
}

// Reoriented normal mapping (Barré-Brisebois and Hill): rotates tangent-space
// detail by the arc from the projection axis to the base lighting normal. It is
// linear in detail, so weighted sums can be reoriented once per axis, and a
// flat (0, 0, w) detail returns exactly w * base for every axis and weight.
vec3 terrain_reoriented_normal(mat3 frame, vec3 base, vec3 detail) {
	vec3 rotated = transpose(frame) * base;
	// A heightfield normal cannot oppose an axis it has positive weight on;
	// the guard only bounds a degenerate input.
	rotated.z = max(rotated.z + 1.0, 0.00001);
	detail *= vec3(-1.0, -1.0, 1.0);
	return frame * (rotated * (dot(rotated, detail) / rotated.z) - detail);
}
