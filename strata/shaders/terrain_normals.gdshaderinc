// Lighting samples the continuous RF field independently of geometric triangle
// interpolation. Integer sample-spacing offsets make this equivalent in the
// interior to bilinearly interpolating central gradients at the sample vertices.
// The same terrain-local positions are used across every patch and LOD.
//
// The host shader defines, before including this file: field_origin, field_size,
//   vec2 terrain_lattice_step()       metres between height samples
//   ivec2 terrain_lattice_max()       last height sample index per axis
//   float terrain_linear_height(vec2) bilinear height at a terrain position
//   float terrain_texel_height(ivec2) height of one sample by lattice index
// (terrain_regions.gdshaderinc implements them over the region texture arrays.)

vec2 terrain_smooth_gradient(vec2 position) {
	vec2 spacing = terrain_lattice_step();
	vec2 point = clamp(position, field_origin, field_origin + field_size);
	vec2 low = max(point - spacing, field_origin);
	vec2 high = min(point + spacing, field_origin + field_size);
	// Actual spans give one-sided derivatives at the field edge, preserving a
	// planar ramp's normal instead of halving its slope through texture clamping.
	float dx = (terrain_linear_height(vec2(high.x, point.y)) - terrain_linear_height(vec2(low.x, point.y))) / (high.x - low.x);
	float dz = (terrain_linear_height(vec2(point.x, high.y)) - terrain_linear_height(vec2(point.x, low.y))) / (high.y - low.y);
	return vec2(dx, dz);
}

#ifdef HEGO_TERRAIN_CREASES
// Optional crease mode: six canonical triangles meet at an interior sample.
// Join only adjacent faces whose shared-edge dihedral is within the angle.
// Each triangle gets the area-weighted corner normal of its connected group.
vec3 terrain_corner_normal(ivec2 vertex, int face_index, float threshold_cosine) {
	ivec2 dimensions = terrain_lattice_max() + ivec2(1);
	vec2 spacing = terrain_lattice_step();
	ivec2 ring[6];
	ring[0] = ivec2(1, 0); ring[1] = ivec2(0, 1);
	ring[2] = ivec2(-1, 1); ring[3] = ivec2(-1, 0);
	ring[4] = ivec2(0, -1); ring[5] = ivec2(1, -1);
	vec3 edges[6]; bool neighbor_valid[6];
	float center = terrain_texel_height(vertex);
	for (int i = 0; i < 6; i++) {
		ivec2 neighbor = vertex + ring[i];
		neighbor_valid[i] = all(greaterThanEqual(neighbor, ivec2(0))) && all(lessThan(neighbor, dimensions));
		float height = center;
		if (neighbor_valid[i]) { height = terrain_texel_height(neighbor); }
		edges[i] = vec3(float(ring[i].x) * spacing.x, height - center, float(ring[i].y) * spacing.y);
	}
	vec3 areas[6]; vec3 normals[6]; bool face_valid[6];
	for (int i = 0; i < 6; i++) {
		int next = (i + 1) % 6;
		face_valid[i] = neighbor_valid[i] && neighbor_valid[next];
		areas[i] = cross(edges[next], edges[i]);
		normals[i] = normalize(areas[i]);
	}
	int included = 1 << face_index;
	int current = face_index;
	for (int i = 0; i < 5; i++) {
		int next = (current + 1) % 6;
		if (!face_valid[next] || dot(normals[current], normals[next]) < threshold_cosine - 0.000001) { break; }
		included = included | (1 << next); current = next;
	}
	current = face_index;
	for (int i = 0; i < 5; i++) {
		int next = (current + 5) % 6;
		if ((included & (1 << next)) != 0 || !face_valid[next] || dot(normals[current], normals[next]) < threshold_cosine - 0.000001) { break; }
		included = included | (1 << next); current = next;
	}
	// Fixed summation order makes a shared smoothing group identical from either
	// triangle, independent of its starting face or the geometry patch/LOD.
	vec3 sum = vec3(0.0);
	for (int i = 0; i < 6; i++) { if ((included & (1 << i)) != 0) { sum += areas[i]; } }
	return normalize(sum);
}

vec3 terrain_crease_normal(vec2 position, float threshold_cosine) {
	ivec2 dimensions = terrain_lattice_max() + ivec2(1);
	vec2 grid = clamp((position - field_origin) / terrain_lattice_step(), vec2(0.0), vec2(dimensions - ivec2(1)));
	ivec2 first = min(ivec2(floor(grid)), dimensions - ivec2(2));
	vec2 f = grid - vec2(first);
	if (f.x + f.y <= 1.0) {
		vec3 a = terrain_corner_normal(first, 0, threshold_cosine);
		vec3 b = terrain_corner_normal(first + ivec2(1, 0), 2, threshold_cosine);
		vec3 c = terrain_corner_normal(first + ivec2(0, 1), 4, threshold_cosine);
		return normalize(a * (1.0 - f.x - f.y) + b * f.x + c * f.y);
	}
	vec3 b = terrain_corner_normal(first + ivec2(1, 0), 1, threshold_cosine);
	vec3 c = terrain_corner_normal(first + ivec2(0, 1), 5, threshold_cosine);
	vec3 d = terrain_corner_normal(first + ivec2(1, 1), 3, threshold_cosine);
	return normalize(b * (1.0 - f.y) + c * (1.0 - f.x) + d * (f.x + f.y - 1.0));
}

#endif
