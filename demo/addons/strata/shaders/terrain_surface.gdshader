shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D color_maps[32] : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_maps[32] : filter_linear_mipmap, repeat_enable;
uniform sampler2D ormh_maps[32] : filter_linear_mipmap, repeat_enable;
uniform float uv_scales[32];
// Per-material axis-weight exponent, shared by color, normal and ORMH (1-64).
uniform float triplanar_sharpnesses[32];
uniform float material_displacement[32];
uniform float height_blend_contrasts[32];
uniform float height_blend_biases[32];
uniform float material_roughness_scales[32];
uniform float material_roughness_biases[32];
uniform bool height_blend_enabled = true;
uniform sampler2D height_field : filter_linear, repeat_disable;
uniform sampler2D control_ids : filter_nearest, repeat_disable;
uniform sampler2D control_weights : filter_nearest, repeat_disable;
uniform sampler2D ownership_field : filter_linear, repeat_disable;
uniform bool show_ownership = false;
uniform sampler2D terrain_macro_map : filter_linear, repeat_disable;
uniform bool has_terrain_macro_map = false;
uniform vec2 terrain_macro_origin = vec2(0.0);
uniform vec2 terrain_macro_size = vec2(1.0);
uniform float terrain_tint_strength = 1.0;
uniform float terrain_ao_strength = 1.0;
uniform sampler2D channel_preview_field : filter_linear, repeat_disable;
uniform bool show_channel_preview = false;
uniform vec2 channel_preview_origin = vec2(0.0);
uniform vec2 channel_preview_size = vec2(1.0);
uniform sampler2D cell_holes : filter_nearest, repeat_disable;
uniform bool has_holes = false;
uniform bool triangle_height_sampling = false;
uniform bool smooth_shading = true;
uniform float crease_cosine = -1.0;
uniform bool debug_shading_normals = false;
uniform vec2 ownership_origin = vec2(0.0);
uniform vec2 ownership_step_x = vec2(1.0, 0.0);
uniform vec2 ownership_step_y = vec2(0.0, 1.0);
uniform vec2 field_origin = vec2(-128.0);
uniform vec2 field_size = vec2(256.0);
uniform vec3 camera_position = vec3(0.0);
uniform bool displacement_enabled = true;
uniform float displacement_radius = 32.0;
uniform float displacement_strength = 0.2;
uniform bool distance_uv_enabled = false;
uniform float far_uv_factor = 0.125;
uniform float uv_near_distance = 16.0;
uniform float uv_far_distance = 128.0;
uniform bool debug_lod = false;
uniform bool debug_discarded = false;
instance uniform vec2 patch_uv_origin = vec2(0.0);
instance uniform float patch_uv_scale = 1.0;
instance uniform float patch_level = 0.0;
varying vec2 terrain_position;

#include "terrain_controls.gdshaderinc"
#include "terrain_texture_dispatch.gdshaderinc"
#include "terrain_normals.gdshaderinc"
#include "terrain_height_blend.gdshaderinc"
#include "terrain_triplanar.gdshaderinc"

vec2 field_uv(vec2 position) {
	return terrain_height_uv(position);
}

float base_height(vec2 position) {
	if (!triangle_height_sampling) { return textureLod(height_field, field_uv(position), 0.0).r; }
	ivec2 dimensions = textureSize(height_field, 0);
	vec2 grid = clamp((position - field_origin) / field_size, vec2(0.0), vec2(1.0)) * vec2(dimensions - ivec2(1));
	ivec2 first = min(ivec2(floor(grid)), dimensions - ivec2(2));
	vec2 f = grid - vec2(first);
	float a = texelFetch(height_field, first, 0).r;
	float b = texelFetch(height_field, first + ivec2(1, 0), 0).r;
	float c = texelFetch(height_field, first + ivec2(0, 1), 0).r;
	float d = texelFetch(height_field, first + ivec2(1, 1), 0).r;
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

float uv_blend(vec3 base_point) {
	if (!distance_uv_enabled) { return 0.0; }
	return smoothstep(uv_near_distance, uv_far_distance, distance(base_point, camera_position));
}

vec2 endpoint_field_uv(vec2 position, vec2 origin, vec2 size, ivec2 dimensions) {
	vec2 logical = clamp((position - origin) / size, vec2(0.0), vec2(1.0));
	return (logical * vec2(dimensions - ivec2(1)) + vec2(0.5)) / vec2(dimensions);
}

vec4 terrain_macro_sample(vec2 position) {
	if (!has_terrain_macro_map) { return vec4(1.0); }
	return texture(terrain_macro_map, endpoint_field_uv(position, terrain_macro_origin, terrain_macro_size, textureSize(terrain_macro_map, 0)));
}

// Signed material relief in metres along the terrain normal. The fade uses the
// undisplaced surface point; outside it no material texture is fetched. The
// projections match fragment(): same base point, smooth normal and per-material
// axis weights, sampled at LOD0.
float material_height_offset(vec3 base_point, vec3 projection_normal) {
	float fade = displacement_enabled ? 1.0 - smoothstep(displacement_radius * 0.55, displacement_radius, distance(base_point, camera_position)) : 0.0;
	if (fade <= 0.0) { return 0.0; }
	ivec4 ids; vec4 weights; float discarded;
	terrain_blend(base_point.xz, ids, weights, discarded);
	float height_detail = 0.0;
	float far_mix = uv_blend(base_point);
	mat3 frames[3];
	for (int axis = 0; axis < 3; axis++) { frames[axis] = terrain_triplanar_frame(axis, projection_normal); }
	vec4 heights = vec4(0.5); vec4 blend_heights = vec4(0.5); vec4 contrasts = vec4(0.0); vec4 biases = vec4(0.0);
	for (int slot = 0; slot < 4; slot++) {
		if (weights[slot] > 0.0) {
			int id = ids[slot];
			vec3 axis_weights = terrain_triplanar_weights(projection_normal, triplanar_sharpnesses[id]);
			blend_heights[slot] = 0.0; heights[slot] = 0.0;
			for (int axis = 0; axis < 3; axis++) {
				float axis_weight = axis_weights[axis];
				if (axis_weight > 0.0) {
					vec2 uv = terrain_triplanar_uv(frames[axis], base_point) * uv_scales[id];
					vec2 sampled_alpha = vec2(terrain_ormh_lod(id, uv, 0.0).a);
					if (far_mix > 0.0) { sampled_alpha.y = terrain_ormh_lod(id, uv * far_uv_factor, 0.0).a; }
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
	return height_detail * displacement_strength * fade;
}

void vertex() {
	// Dyadic normalized coordinates reconstruct the same global point on both
	// sides of every patch boundary, even with a fractional terrain origin.
	terrain_position = field_origin + field_size * (patch_uv_origin + UV * patch_uv_scale);
	float height = base_height(terrain_position);
	// Relief and its triplanar projections follow the continuous RF normal, so
	// cliffs bulge outward. It is a function of terrain position alone: shared
	// boundary vertices agree for every patch, LOD, crease angle and shading
	// mode. Crease and legacy triangle normals jump at face edges and would split
	// fine displaced geometry there.
	vec2 smooth_gradient = terrain_smooth_gradient(terrain_position);
	vec3 direction = normalize(vec3(-smooth_gradient.x, 1.0, -smooth_gradient.y));
	// Shared vertex shadow bias remains smooth even when fragment creases are enabled.
	NORMAL = direction;
#ifndef HEGO_TERRAIN_CREASES
	if (!smooth_shading) {
		vec2 gradient = base_shading_gradient(terrain_position, smooth_gradient);
		NORMAL = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	}
#endif
	float offset = material_height_offset(vec3(terrain_position.x, height, terrain_position.y), direction);
	VERTEX = vec3(terrain_position.x, height, terrain_position.y) + direction * offset;
}

void fragment() {
	// Projections use the undisplaced terrain-local point and the continuous RF
	// normal, functions of terrain position alone: displacement, patch/LOD and
	// shading settings cannot move UV phase or axis weights. TextureGrad
	// derivatives are taken here, before holes and all per-ID/per-axis flow.
	vec3 base_point = vec3(terrain_position.x, base_height(terrain_position), terrain_position.y);
	vec3 point_dx = dFdx(base_point);
	vec3 point_dy = dFdy(base_point);
	vec2 smooth_gradient = terrain_smooth_gradient(terrain_position);
	vec3 projection_normal = normalize(vec3(-smooth_gradient.x, 1.0, -smooth_gradient.y));
	if (has_holes) {
		ivec2 dimensions = textureSize(cell_holes, 0);
		ivec2 cell = clamp(ivec2(floor((terrain_position - field_origin) / field_size * vec2(dimensions))), ivec2(0), dimensions - ivec2(1));
		if (texelFetch(cell_holes, cell, 0).r >= 0.5) { discard; }
	}
	ivec4 ids; vec4 weights; float discarded;
	terrain_blend(terrain_position, ids, weights, discarded);
	vec3 color = vec3(0.0); vec3 orm = vec3(0.0);
	float far_mix = uv_blend(base_point);
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
			vec3 axis_weights = terrain_triplanar_weights(projection_normal, triplanar_sharpnesses[id]);
			slot_axis_weights[slot] = axis_weights;
			for (int axis = 0; axis < 3; axis++) {
				float axis_weight = axis_weights[axis];
				if (axis_weight > 0.0) {
					vec2 uv = terrain_triplanar_uv(frames[axis], base_point) * scale;
					vec2 dx = terrain_triplanar_uv(frames[axis], point_dx) * scale; vec2 dy = terrain_triplanar_uv(frames[axis], point_dy) * scale;
					vec4 projected = terrain_ormh_grad(id, uv, dx, dy);
					if (far_mix > 0.0) { projected = mix(projected, terrain_ormh_grad(id, uv * far_uv_factor, dx * far_uv_factor, dy * far_uv_factor), far_mix); }
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
					vec2 uv = terrain_triplanar_uv(frames[axis], base_point) * scale;
					vec2 dx = terrain_triplanar_uv(frames[axis], point_dx) * scale; vec2 dy = terrain_triplanar_uv(frames[axis], point_dy) * scale;
					vec3 sampled_color = terrain_color_grad(id, uv, dx, dy).rgb;
					vec2 near_rg = terrain_normal_grad(id, uv, dx, dy).rg * 2.0 - 1.0;
					vec3 near_normal = vec3(near_rg, sqrt(max(0.0, 1.0 - dot(near_rg, near_rg))));
					if (far_mix > 0.0) {
						sampled_color = mix(sampled_color, terrain_color_grad(id, uv * far_uv_factor, dx * far_uv_factor, dy * far_uv_factor).rgb, far_mix);
						vec2 far_rg = terrain_normal_grad(id, uv * far_uv_factor, dx * far_uv_factor, dy * far_uv_factor).rg * 2.0 - 1.0;
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
	// Keep lighting smooth independently of canonical triangle height sampling.
	// Each projection's detail is reoriented onto this lighting normal, so a flat
	// normal map reproduces it exactly for every sharpness and crease setting.
	vec2 gradient = base_shading_gradient(terrain_position, smooth_gradient);
	vec3 geometric_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	vec3 final_normal = vec3(0.0);
	for (int axis = 0; axis < 3; axis++) { final_normal += terrain_reoriented_normal(frames[axis], geometric_normal, axis_details[axis]); }
	float final_length_squared = dot(final_normal, final_normal);
	final_normal = final_length_squared > 0.00000001 ? final_normal * inversesqrt(final_length_squared) : geometric_normal;
	NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(final_normal, 0.0)).xyz);
	ALBEDO = color;
	// RGBAH is linear terrain-scale data, separate from repeating source UVs.
	// AO affects indirect occlusion only; it is not baked into albedo here.
	vec4 terrain_macro = terrain_macro_sample(terrain_position);
	ALBEDO *= mix(vec3(1.0), terrain_macro.rgb, terrain_tint_strength);
	float ownership_coverage = 0.0;
	if (show_ownership) {
		vec2 logical = inverse(mat2(ownership_step_x, ownership_step_y)) * (terrain_position - ownership_origin);
		vec2 dimensions = vec2(textureSize(ownership_field, 0));
		vec2 mask_uv = (logical + vec2(0.5)) / dimensions;
		if (all(greaterThanEqual(logical, vec2(0.0))) && all(lessThanEqual(logical, dimensions - vec2(1.0)))) {
			ownership_coverage = clamp(textureLod(ownership_field, mask_uv, 0.0).r, 0.0, 1.0);
		}
		ALBEDO = mix(ALBEDO, vec3(0.95, 0.24, 0.055), ownership_coverage * 0.8);
	}
	ROUGHNESS = clamp(orm.g, 0.04, 1.0); METALLIC = clamp(orm.b, 0.0, 1.0);
	AO = clamp(orm.r, 0.0, 1.0) * mix(1.0, terrain_macro.a, terrain_ao_strength);
	if (debug_shading_normals) { EMISSION = final_normal * 0.5 + 0.5; ALBEDO = vec3(0.0); ROUGHNESS = 1.0; METALLIC = 0.0; AO = 1.0; }
	if (debug_lod) { ALBEDO = mix(ALBEDO, vec3(fract(patch_level * 0.37), fract(patch_level * 0.61 + 0.3), fract(patch_level * 0.19 + 0.6)), 0.65); }
	if (debug_discarded) { ALBEDO = mix(vec3(0.05, 0.15, 0.05), vec3(1.0, 0.0, 0.25), clamp(discarded * 2.0, 0.0, 1.0)); }
	if (show_channel_preview) {
		vec2 uv = endpoint_field_uv(terrain_position, channel_preview_origin, channel_preview_size, textureSize(channel_preview_field, 0));
		float value = clamp(texture(channel_preview_field, uv).r, 0.0, 1.0);
		EMISSION = mix(vec3(value), vec3(0.95, 0.24, 0.055), ownership_coverage * 0.8);
		ALBEDO = vec3(0.0); ROUGHNESS = 1.0; METALLIC = 0.0; AO = 1.0;
	}
}
