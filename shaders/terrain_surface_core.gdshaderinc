// Terrain material evaluation shared by terrain_surface.gdshader and the compute fill of
// StrataSurfaceCache (strata_surface_cache.gd), which splices this file into GLSL. Keep it in
// the common subset of the Godot shading language and GLSL 450: no uniform declarations, hints,
// built-ins or render-mode dependent code. Every value comes from a parameter or from the
// host's uniforms of the same names (see terrain_surface.gdshader):
//   triangle_height_sampling, smooth_shading, crease_cosine, field_origin, uv_scales,
//   top_texture_slots, top_uv_scales, triplanar_sharpnesses, projection_modes,
//   material_displacement, height_blend_contrasts, height_blend_biases, far_uv_factor,
//   material_roughness_scales, material_roughness_biases
// plus the uniforms of terrain_regions, terrain_controls, terrain_texture_dispatch,
// terrain_normals, terrain_height_blend and terrain_triplanar, included before this file.

float base_height(vec2 position) {
	if (!triangle_height_sampling) { return terrain_linear_height(position); }
	ivec2 lattice_max = terrain_lattice_max();
	vec2 grid = clamp((position - field_origin) / terrain_lattice_step(), vec2(0.0), vec2(lattice_max));
	ivec2 first = min(ivec2(floor(grid)), lattice_max - ivec2(1));
	vec2 f = grid - vec2(first);
	float a = terrain_texel_height(first);
	float b = terrain_texel_height(first + ivec2(1, 0));
	float c = terrain_texel_height(first + ivec2(0, 1));
	float d = terrain_texel_height(first + ivec2(1, 1));
	return f.x + f.y <= 1.0 ? a + (b - a) * f.x + (c - a) * f.y : d + (c - d) * (1.0 - f.x) + (b - d) * (1.0 - f.y);
}

// The default smooth path returns the caller's continuous gradient without
// further fetches. Crease and legacy lighting replace it for lighting only.
vec2 base_shading_gradient(vec2 position, vec2 smooth_gradient) {
	if (smooth_shading) {
#ifdef HEGO_TERRAIN_CREASES
		vec3 normal = terrain_crease_normal(position, crease_cosine);
		return -normal.xz / normal.y;
#else
		return smooth_gradient;
#endif
	}
	// Compatibility/A-B mode: the previous triangle-constant field derivatives.
	float epsilon = 0.08;
	return vec2(
		(base_height(position + vec2(epsilon, 0.0)) - base_height(position - vec2(epsilon, 0.0))) / (2.0 * epsilon),
		(base_height(position + vec2(0.0, epsilon)) - base_height(position - vec2(0.0, epsilon))) / (2.0 * epsilon));
}

// Texture slot and UV scale of material id's projection along axis: the top layer set for the
// upward (+Y) projection when the material has one, otherwise the material's own set.
int terrain_axis_texture(int id, int axis, vec3 projection_normal, inout float scale) {
	int top = top_texture_slots[id];
	if (axis == 1 && top > 0 && projection_normal.y >= 0.0) { scale = top_uv_scales[id]; return top - 1; }
	return id;
}

// Signed material relief in metres along the terrain normal, before the renderer's
// displacement strength and camera fade. The projections match terrain_surface_evaluate():
// same base point, smooth normal and per-material axis weights, sampled at LOD0.
float terrain_material_relief(vec3 base_point, vec3 projection_normal, float far_mix) {
	ivec4 ids; vec4 weights; float discarded;
	terrain_blend(base_point.xz, ids, weights, discarded);
	float height_detail = 0.0;
	mat3 frames[3];
	for (int axis = 0; axis < 3; axis++) { frames[axis] = terrain_triplanar_frame(axis, projection_normal); }
	vec4 heights = vec4(0.5); vec4 blend_heights = vec4(0.5); vec4 contrasts = vec4(0.0); vec4 biases = vec4(0.0);
	for (int slot = 0; slot < 4; slot++) {
		if (weights[slot] > 0.0) {
			int id = ids[slot];
			vec3 axis_weights = terrain_projection_weights(projection_normal, triplanar_sharpnesses[id], projection_modes[id]);
			blend_heights[slot] = 0.0; heights[slot] = 0.0;
			for (int axis = 0; axis < 3; axis++) {
				float axis_weight = axis_weights[axis];
				if (axis_weight > 0.0) {
					float axis_scale = uv_scales[id];
					int tid = terrain_axis_texture(id, axis, projection_normal, axis_scale);
					vec2 uv = terrain_triplanar_uv(frames[axis], base_point) * axis_scale;
					vec2 sampled_alpha = vec2(terrain_ormh_lod(tid, uv, 0.0).a);
					if (far_mix > 0.0) { sampled_alpha.y = terrain_ormh_lod(tid, uv * far_uv_factor, 0.0).a; }
					blend_heights[slot] += mix(sampled_alpha.x, sampled_alpha.y, far_mix) * axis_weight;
					heights[slot] += mix(terrain_finite_height(sampled_alpha.x), terrain_finite_height(sampled_alpha.y), far_mix) * axis_weight;
				}
			}
			contrasts[slot] = height_blend_contrasts[id]; biases[slot] = height_blend_biases[id];
		}
	}
	weights = terrain_height_blend_weights(weights, blend_heights, contrasts, biases);
	for (int slot = 0; slot < 4; slot++) {
		if (weights[slot] > 0.0) { height_detail += (heights[slot] - 0.5) * material_displacement[ids[slot]] * weights[slot]; }
	}
	return height_detail;
}

// The blended terrain material at a terrain position without custom fragment code (materials
// with code are completed inline by terrain_surface.gdshader). base_point is the undisplaced
// surface point, point_dx/point_dy its screen (or cache texel) derivatives, projection_normal
// the continuous RF normal and geometric_normal the lighting normal the detail is reoriented
// onto. Returns linear albedo before the terrain macro tint, AO/roughness/metallic after the
// per-material roughness remap, and the unit terrain-local normal.
void terrain_surface_evaluate(vec2 position, vec3 base_point, vec3 point_dx, vec3 point_dy,
		vec3 projection_normal, vec3 geometric_normal, float far_mix,
		out vec3 color, out vec3 orm, out vec3 final_normal, out float discarded) {
	ivec4 ids; vec4 weights;
	terrain_blend(position, ids, weights, discarded);
	color = vec3(0.0); orm = vec3(0.0);
	mat3 frames[3];
	for (int axis = 0; axis < 3; axis++) { frames[axis] = terrain_triplanar_frame(axis, projection_normal); }
	// Cache the RGBA ORMH projections before weighting the other families. Each
	// material's axis weights are shared by all families and by height competition.
	// Exactly zero axis weights are skipped; no threshold is applied.
	vec4 packed_samples[4]; vec3 slot_axis_weights[4]; vec4 heights = vec4(0.5); vec4 contrasts = vec4(0.0); vec4 biases = vec4(0.0);
	for (int slot = 0; slot < 4; slot++) {
		packed_samples[slot] = vec4(0.0); slot_axis_weights[slot] = vec3(0.0);
		if (weights[slot] > 0.0) {
			int id = ids[slot]; float scale = uv_scales[id];
			vec3 axis_weights = terrain_projection_weights(projection_normal, triplanar_sharpnesses[id], projection_modes[id]);
			slot_axis_weights[slot] = axis_weights;
			for (int axis = 0; axis < 3; axis++) {
				float axis_weight = axis_weights[axis];
				if (axis_weight > 0.0) {
					float axis_scale = scale;
					int tid = terrain_axis_texture(id, axis, projection_normal, axis_scale);
					vec2 uv = terrain_triplanar_uv(frames[axis], base_point) * axis_scale;
					vec2 dx = terrain_triplanar_uv(frames[axis], point_dx) * axis_scale; vec2 dy = terrain_triplanar_uv(frames[axis], point_dy) * axis_scale;
					vec4 projected = terrain_ormh_grad(tid, uv, dx, dy);
					if (far_mix > 0.0) { projected = mix(projected, terrain_ormh_grad(tid, uv * far_uv_factor, dx * far_uv_factor, dy * far_uv_factor), far_mix); }
					packed_samples[slot] += projected * axis_weight;
				}
			}
			heights[slot] = packed_samples[slot].a;
			contrasts[slot] = height_blend_contrasts[id]; biases[slot] = height_blend_biases[id];
		}
	}
	weights = terrain_height_blend_weights(weights, heights, contrasts, biases);
	// Tangent-space detail is accumulated per projection axis across materials;
	// reorientation is linear in it, so each axis is reoriented once below.
	vec3 axis_details[3];
	for (int axis = 0; axis < 3; axis++) { axis_details[axis] = vec3(0.0); }
	for (int slot = 0; slot < 4; slot++) {
		if (weights[slot] > 0.0) {
			int id = ids[slot]; float scale = uv_scales[id];
			vec3 axis_weights = slot_axis_weights[slot];
			for (int axis = 0; axis < 3; axis++) {
				float axis_weight = axis_weights[axis];
				if (axis_weight > 0.0) {
					float axis_scale = scale;
					int tid = terrain_axis_texture(id, axis, projection_normal, axis_scale);
					vec2 uv = terrain_triplanar_uv(frames[axis], base_point) * axis_scale;
					vec2 dx = terrain_triplanar_uv(frames[axis], point_dx) * axis_scale; vec2 dy = terrain_triplanar_uv(frames[axis], point_dy) * axis_scale;
					vec3 sampled_color = terrain_color_grad(tid, uv, dx, dy).rgb;
					vec2 near_rg = terrain_normal_grad(tid, uv, dx, dy).rg * 2.0 - 1.0;
					vec3 near_normal = vec3(near_rg, sqrt(max(0.0, 1.0 - dot(near_rg, near_rg))));
					if (far_mix > 0.0) {
						sampled_color = mix(sampled_color, terrain_color_grad(tid, uv * far_uv_factor, dx * far_uv_factor, dy * far_uv_factor).rgb, far_mix);
						vec2 far_rg = terrain_normal_grad(tid, uv * far_uv_factor, dx * far_uv_factor, dy * far_uv_factor).rg * 2.0 - 1.0;
						vec3 far_normal = vec3(far_rg, sqrt(max(0.0, 1.0 - dot(far_rg, far_rg))));
						near_normal = mix(near_normal, far_normal, far_mix);
					}
					color += sampled_color * (weights[slot] * axis_weight);
					axis_details[axis] += near_normal * (weights[slot] * axis_weight);
				}
			}
			vec3 sampled_orm = packed_samples[slot].rgb;
			sampled_orm.g = clamp(sampled_orm.g * material_roughness_scales[id] + material_roughness_biases[id], 0.0, 1.0);
			orm += sampled_orm * weights[slot];
		}
	}
	// An unassigned authoring stage has no repeating source or displacement.
	// Show a neutral surface while retaining the normal terrain lighting.
	if (dot(weights, vec4(1.0)) <= 0.0) {
		color = vec3(0.45); orm = vec3(1.0, 0.94, 0.0);
	}
	// Each projection's detail is reoriented onto the lighting normal, so a flat
	// normal map reproduces it exactly for every sharpness and crease setting.
	final_normal = vec3(0.0);
	for (int axis = 0; axis < 3; axis++) { final_normal += terrain_reoriented_normal(frames[axis], geometric_normal, axis_details[axis]); }
	float final_length_squared = dot(final_normal, final_normal);
	final_normal = final_length_squared > 0.00000001 ? final_normal * inversesqrt(final_length_squared) : geometric_normal;
}
