// Three-cell texture bombing (hex tiling): each material texture read blends three copies of
// the tile, from the corners of the triangle-grid cell around the point, each with its own
// random offset and orientation, so the tile grid stops repeating. Heitz and Neyret's
// triangle grid, weighted per corner as in Mikkelsen's hex tiling; the corners compete by the
// material's ORMH height (terrain_height_blend_weights, the material's height-blend contrast),
// so a point usually shows one copy and the seams follow the texture's own relief.
//
// Offsets are multiples of 1/256 of a tile and orientations are the eight rotations by 90
// degrees and mirrors about the tile origin, so texel centres land on texel centres: pixel
// sampling (STRATA_PIXEL_SAMPLING) keeps its grid for textures of 256 texels or more.
// Host uniforms: cell_bombing (bool), cell_bombing_size (corner spacing in tile repeats),
// height_blend_contrasts, material_bombing (per material: 0 plain tiling, 1 offsets and mirrors,
// which keep the texture's direction, 2 also 90-degree turns). Needs terrain_texture_dispatch and terrain_height_blend first.

// A host may define STRATA_DIRECT_BOMBING as a bool expression that also gates bombing (the
// terrain shader turns it off for pixels it shades itself while the surface cache holds the
// bombed surface; the cache's fill leaves it undefined).
#ifndef STRATA_DIRECT_BOMBING
#define STRATA_DIRECT_BOMBING true
#endif

// Whether material id's texture reads are bombed.
bool terrain_bombed(int id) {
	return cell_bombing && STRATA_DIRECT_BOMBING && material_bombing[id] > 0.5;
}

uint terrain_bomb_hash(ivec2 p) {
	uint h = uint(p.x) * 2246822519u ^ uint(p.y) * 3266489917u;
	h ^= h >> 15u; h *= 2654435761u; h ^= h >> 13u; h *= 3266489917u; h ^= h >> 16u;
	return h;
}

// Orientation k (0-7): bit 0 rotates by 90 degrees, bit 1 by 180, bit 2 mirrors x.
vec2 terrain_bomb_orient(int k, vec2 v) {
	vec2 r = (k & 1) != 0 ? vec2(-v.y, v.x) : v;
	r = (k & 2) != 0 ? -r : r;
	return (k & 4) != 0 ? vec2(-r.x, r.y) : r;
}

// The inverse of terrain_bomb_orient (tangent-space normals go back through it).
vec2 terrain_bomb_unorient(int k, vec2 v) {
	vec2 r = (k & 4) != 0 ? vec2(-v.x, v.y) : v;
	r = (k & 2) != 0 ? -r : r;
	return (k & 1) != 0 ? vec2(r.y, -r.x) : r;
}

// The three corners of the cell around uv (tile repeats): orientation and offset of each
// corner's copy, and the barycentric weights. Without turns the orientation keeps only its
// mirror bit.
void terrain_bomb_cell(vec2 uv, bool turns, out ivec3 orient, out vec2 offset0, out vec2 offset1, out vec2 offset2, out vec3 bary) {
	vec2 st = uv * (1.7320508 / max(cell_bombing_size, 0.01));
	vec2 skewed = mat2(vec2(1.0, -0.57735027), vec2(0.0, 1.15470054)) * st;
	ivec2 base = ivec2(floor(skewed));
	vec3 t = vec3(fract(skewed), 0.0);
	t.z = 1.0 - t.x - t.y;
	float s = step(0.0, -t.z);
	float s2 = 2.0 * s - 1.0;
	bary = vec3(-t.z * s2, s - t.y * s2, s - t.x * s2);
	ivec2 v0 = base + ivec2(int(s), int(s));
	ivec2 v1 = base + ivec2(int(s), 1 - int(s));
	ivec2 v2 = base + ivec2(1 - int(s), int(s));
	uint h0 = terrain_bomb_hash(v0); uint h1 = terrain_bomb_hash(v1); uint h2 = terrain_bomb_hash(v2);
	orient = ivec3(int((h0 >> 16u) & 7u), int((h1 >> 16u) & 7u), int((h2 >> 16u) & 7u));
	if (!turns) { orient = orient & ivec3(4); }
	offset0 = vec2(float(h0 & 255u), float((h0 >> 8u) & 255u)) / 256.0;
	offset1 = vec2(float(h1 & 255u), float((h1 >> 8u) & 255u)) / 256.0;
	offset2 = vec2(float(h2 & 255u), float((h2 >> 8u) & 255u)) / 256.0;
}

// Corner weights from the barycentric weights (sharpened so a corner dominates its region)
// and the three copies' heights.
vec3 terrain_bomb_weights(vec3 bary, vec3 heights, float contrast) {
	vec3 w = bary * bary * bary;
	w /= max(dot(w, vec3(1.0)), 0.00001);
	vec4 blended = terrain_height_blend_weights(vec4(w, 0.0), vec4(heights, 0.5), vec4(max(contrast, 4.0)), vec4(0.0));
	return blended.xyz;
}

// Bombed ORMH of texture tid (material id for the height-blend contrast) at uv with screen
// derivatives dx, dy. weights receives the corner weights for the colour and normal reads.
vec4 terrain_bomb_ormh(int tid, int id, vec2 uv, vec2 dx, vec2 dy, out vec3 weights) {
	ivec3 o; vec2 f0; vec2 f1; vec2 f2; vec3 bary;
	terrain_bomb_cell(uv, material_bombing[id] > 1.5, o, f0, f1, f2, bary);
	vec4 a = terrain_ormh_grad(tid, terrain_bomb_orient(o.x, uv) + f0, terrain_bomb_orient(o.x, dx), terrain_bomb_orient(o.x, dy));
	vec4 b = terrain_ormh_grad(tid, terrain_bomb_orient(o.y, uv) + f1, terrain_bomb_orient(o.y, dx), terrain_bomb_orient(o.y, dy));
	vec4 c = terrain_ormh_grad(tid, terrain_bomb_orient(o.z, uv) + f2, terrain_bomb_orient(o.z, dx), terrain_bomb_orient(o.z, dy));
	weights = terrain_bomb_weights(bary, vec3(a.a, b.a, c.a), height_blend_contrasts[id]);
	return a * weights.x + b * weights.y + c * weights.z;
}

// Bombed colour of texture tid (material id) with the corner weights of terrain_bomb_ormh().
vec3 terrain_bomb_color(int tid, int id, vec2 uv, vec2 dx, vec2 dy, vec3 weights) {
	ivec3 o; vec2 f0; vec2 f1; vec2 f2; vec3 bary;
	terrain_bomb_cell(uv, material_bombing[id] > 1.5, o, f0, f1, f2, bary);
	vec3 color = vec3(0.0);
	if (weights.x > 0.0) { color += terrain_color_grad(tid, terrain_bomb_orient(o.x, uv) + f0, terrain_bomb_orient(o.x, dx), terrain_bomb_orient(o.x, dy)).rgb * weights.x; }
	if (weights.y > 0.0) { color += terrain_color_grad(tid, terrain_bomb_orient(o.y, uv) + f1, terrain_bomb_orient(o.y, dx), terrain_bomb_orient(o.y, dy)).rgb * weights.y; }
	if (weights.z > 0.0) { color += terrain_color_grad(tid, terrain_bomb_orient(o.z, uv) + f2, terrain_bomb_orient(o.z, dx), terrain_bomb_orient(o.z, dy)).rgb * weights.z; }
	return color;
}

// Bombed tangent-space normal xy (-1..1) of texture tid, in uv's own frame.
vec2 terrain_bomb_normal_rg(int tid, int id, vec2 uv, vec2 dx, vec2 dy, vec3 weights) {
	ivec3 o; vec2 f0; vec2 f1; vec2 f2; vec3 bary;
	terrain_bomb_cell(uv, material_bombing[id] > 1.5, o, f0, f1, f2, bary);
	vec2 rg = vec2(0.0);
	if (weights.x > 0.0) { rg += terrain_bomb_unorient(o.x, terrain_normal_grad(tid, terrain_bomb_orient(o.x, uv) + f0, terrain_bomb_orient(o.x, dx), terrain_bomb_orient(o.x, dy)).rg * 2.0 - 1.0) * weights.x; }
	if (weights.y > 0.0) { rg += terrain_bomb_unorient(o.y, terrain_normal_grad(tid, terrain_bomb_orient(o.y, uv) + f1, terrain_bomb_orient(o.y, dx), terrain_bomb_orient(o.y, dy)).rg * 2.0 - 1.0) * weights.y; }
	if (weights.z > 0.0) { rg += terrain_bomb_unorient(o.z, terrain_normal_grad(tid, terrain_bomb_orient(o.z, uv) + f2, terrain_bomb_orient(o.z, dx), terrain_bomb_orient(o.z, dy)).rg * 2.0 - 1.0) * weights.z; }
	return rg;
}

// Bombed ORMH height (alpha) at a fixed mip level, for the displacement relief.
float terrain_bomb_height_lod(int tid, int id, vec2 uv, float level) {
	ivec3 o; vec2 f0; vec2 f1; vec2 f2; vec3 bary;
	terrain_bomb_cell(uv, material_bombing[id] > 1.5, o, f0, f1, f2, bary);
	float a = terrain_ormh_lod(tid, terrain_bomb_orient(o.x, uv) + f0, level).a;
	float b = terrain_ormh_lod(tid, terrain_bomb_orient(o.y, uv) + f1, level).a;
	float c = terrain_ormh_lod(tid, terrain_bomb_orient(o.z, uv) + f2, level).a;
	vec3 w = terrain_bomb_weights(bary, vec3(a, b, c), height_blend_contrasts[id]);
	return a * w.x + b * w.y + c * w.z;
}
