shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// STRATA_PIXEL_SAMPLING (StrataRenderSettings.pixel_sampling) switches colour,
// ORMH and normals to nearest-mipmap filtering; the dispatch functions also
// snap UV to texel centres while retaining continuous derivatives.
#ifdef STRATA_PIXEL_SAMPLING
uniform sampler2D color_maps[32] : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D ormh_maps[32] : filter_nearest_mipmap, repeat_enable;
uniform sampler2D normal_maps[32] : filter_nearest_mipmap, repeat_enable;
#else
uniform sampler2D color_maps[32] : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D ormh_maps[32] : filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_maps[32] : filter_linear_mipmap, repeat_enable;
#endif
uniform float uv_scales[32];
// Optional top layer per material (StrataMaterial.top_*): texture slot + 1 of the set the
// upward (+Y) projection uses (0: none, the material's own set on every axis) and its scale.
uniform int top_texture_slots[32];
uniform float top_uv_scales[32];
// Per-material axis-weight exponent, shared by color, normal and ORMH (1-64).
uniform float triplanar_sharpnesses[32];
// Per-material projection: 0 triplanar, 1 biplanar, 2 sides (X+Z), 3 top (Y).
uniform int projection_modes[32];
uniform float material_displacement[32];
uniform float height_blend_contrasts[32];
uniform float height_blend_biases[32];
uniform float material_roughness_scales[32];
uniform float material_roughness_biases[32];
uniform bool height_blend_enabled = true;
// Region addressing: one Texture2DArray per map (a layer per resident region), a table
// from region index to layer, and the geometry to split a position into region and texel.
uniform vec2 region_origin = vec2(-128.0);
uniform float region_extent = 256.0;
uniform float region_spacing = 1.0;
uniform int region_cells = 256;
uniform ivec2 region_grid = ivec2(1);
// Height sample intervals along each axis at scale 1: the terrain's last lattice index.
uniform ivec2 region_lattice = ivec2(256);
uniform sampler2D region_table : filter_nearest, repeat_disable;
uniform sampler2DArray height_regions : filter_linear, repeat_disable;
uniform int height_scale = 1;
uniform int height_apron = 2;
uniform sampler2DArray material_ids_regions : filter_nearest, repeat_disable;
uniform int material_ids_scale = 1;
uniform int material_ids_apron = 2;
// Weights share the IDs' scale and apron.
uniform sampler2DArray material_weights_regions : filter_nearest, repeat_disable;
uniform bool has_material_maps = false;
uniform sampler2DArray holes_regions : filter_nearest, repeat_disable;
uniform int holes_scale = 1;
uniform int holes_apron = 2;
uniform bool has_holes = false;
uniform sampler2DArray macro_regions : filter_linear, repeat_disable;
uniform int macro_scale = 4;
uniform int macro_apron = 1;
uniform bool has_terrain_macro_map = false;
// Residency tiers (Phase B): far arrays hold the regions bound at far_level, coarse_<map> are
// terrain-wide images at coarse_level that draw every region without a tier.
uniform int far_level = 1;
uniform int coarse_level = 0;
uniform bool has_far_tier = false;
uniform bool has_coarse_maps = false;
uniform sampler2DArray height_far_regions : filter_linear, repeat_disable;
uniform sampler2DArray material_ids_far_regions : filter_nearest, repeat_disable;
uniform sampler2DArray material_weights_far_regions : filter_nearest, repeat_disable;
uniform sampler2DArray holes_far_regions : filter_nearest, repeat_disable;
uniform sampler2DArray macro_far_regions : filter_linear, repeat_disable;
uniform sampler2D coarse_height : filter_linear, repeat_disable;
uniform sampler2D coarse_material_ids : filter_nearest, repeat_disable;
uniform sampler2D coarse_material_weights : filter_nearest, repeat_disable;
uniform sampler2D coarse_holes : filter_nearest, repeat_disable;
uniform sampler2D coarse_macro : filter_linear, repeat_disable;
uniform sampler2D ownership_field : filter_linear, repeat_disable;
uniform bool show_ownership = false;
uniform float terrain_tint_strength = 1.0;
uniform float terrain_ao_strength = 1.0;
// Dielectric specular level (Godot SPECULAR, F0 = 0.16 * specular^2), set through
// StrataRenderSettings.terrain_specular. Godot also derives the grazing Fresnel limit from F0,
// so lower values remove the bright sheen the ground otherwise shows towards the sun.
uniform float terrain_specular : hint_range(0.0, 1.0) = 0.5;
// Rain wetness, set through StrataRenderer.surface_wetness (0 = dry, the default).
// Darkens albedo, lowers roughness and raises specular towards a water film's (wet_specular),
// fully on upward faces, partly on steep ones.
uniform float surface_wetness : hint_range(0.0, 1.0) = 0.0;
uniform float wet_darkening : hint_range(0.0, 1.0) = 0.42;
uniform float wet_roughness : hint_range(0.0, 1.0) = 0.55;
uniform float wet_specular : hint_range(0.0, 1.0) = 0.5;
uniform float wet_steep_factor : hint_range(0.0, 1.0) = 0.45;
// Optional world-space AO overlay, set through StrataRenderer.set_ao_overlay (off by
// default). World XZ tiles of ao_overlay_tile_size metres from ao_overlay_origin; the table
// holds each tile's layer + 1 (R8, 0 = no map). Layers are single-channel occlusion, 1 = none.
uniform bool ao_overlay_enabled = false;
uniform sampler2DArray ao_overlay_layers : filter_linear_mipmap, repeat_disable;
uniform sampler2D ao_overlay_table : filter_nearest, repeat_disable;
uniform vec2 ao_overlay_origin = vec2(0.0);
uniform vec2 ao_overlay_tile_size = vec2(256.0);
uniform float ao_overlay_ao_strength = 1.0;
uniform float ao_overlay_albedo_strength = 0.0;
// Occluded ground (litter, shelter) is rougher: roughness moves towards 1 by (1 - overlay) * this.
uniform float ao_overlay_roughness_strength = 0.0;
uniform float ao_overlay_fade_start = 40.0;
uniform float ao_overlay_fade_end = 60.0;
uniform sampler2D channel_preview_field : filter_linear, repeat_disable;
uniform bool show_channel_preview = false;
uniform vec2 channel_preview_origin = vec2(0.0);
uniform vec2 channel_preview_size = vec2(1.0);
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
uniform bool debug_surface_writers = false;
uniform bool debug_discarded = false;
instance uniform vec2 patch_uv_origin = vec2(0.0);
instance uniform float patch_uv_scale = 1.0;
instance uniform float patch_level = 0.0;
varying vec2 terrain_position;

#include "terrain_regions.gdshaderinc"
#include "terrain_controls.gdshaderinc"
#include "terrain_texture_dispatch.gdshaderinc"
#include "terrain_normals.gdshaderinc"
#include "terrain_height_blend.gdshaderinc"
#include "terrain_triplanar.gdshaderinc"
#include "terrain_surface_core.gdshaderinc"

float uv_blend(vec3 base_point) {
	if (!distance_uv_enabled) { return 0.0; }
	return smoothstep(uv_near_distance, uv_far_distance, distance(base_point, camera_position));
}

vec2 endpoint_field_uv(vec2 position, vec2 origin, vec2 size, ivec2 dimensions) {
	vec2 logical = clamp((position - origin) / size, vec2(0.0), vec2(1.0));
	return (logical * vec2(dimensions - ivec2(1)) + vec2(0.5)) / vec2(dimensions);
}

#ifdef STRATA_SURFACE_CACHE
// Relief from StrataSurfaceCache (StrataRenderSettings.surface_cache_*): the cache's relief
// layers hold terrain_material_relief() at texel corners (cell g at g * texel), so a vertex on
// that lattice reads its own value and others interpolate bilinearly. surface_cache_params:
// level-0 texel size (m), resolution (power of two), level count, relief level. The window of
// level k starts at cell surface_cache_origins[k] (a huge value while the level is unfilled).
uniform sampler2DArray surface_cache_height : filter_nearest, repeat_disable;
uniform vec4 surface_cache_params = vec4(0.0);
uniform vec2 surface_cache_origins[8];

bool surface_cache_relief(vec2 position, out float relief) {
	relief = 0.0;
	int level = int(surface_cache_params.w);
	int resolution = int(surface_cache_params.y);
	if (resolution <= 0 || level < 0 || level >= int(surface_cache_params.z)) { return false; }
	float texel = surface_cache_params.x * exp2(float(level));
	vec2 grid = position / texel;
	ivec2 first = ivec2(floor(grid));
	ivec2 origin = ivec2(surface_cache_origins[level]);
	// Two cells of margin: the window edge may be refilled this frame.
	if (any(lessThan(first, origin + ivec2(2))) || any(greaterThanEqual(first + ivec2(1), origin + ivec2(resolution - 2)))) { return false; }
	vec2 f = grid - vec2(first);
	ivec2 mask = ivec2(resolution - 1);
	int layer = level * 2 + 1;
	float a = texelFetch(surface_cache_height, ivec3(first & mask, layer), 0).r;
	float b = texelFetch(surface_cache_height, ivec3((first + ivec2(1, 0)) & mask, layer), 0).r;
	float c = texelFetch(surface_cache_height, ivec3((first + ivec2(0, 1)) & mask, layer), 0).r;
	float d = texelFetch(surface_cache_height, ivec3((first + ivec2(1, 1)) & mask, layer), 0).r;
	relief = mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
	return true;
}

// Parallax (prototype, StrataRenderSettings.parallax_*): per-pixel relief finer than the
// displaced mesh. The mesh already carries the relief of the relief level, bilinear between its
// vertices, so the ray is marched through the residual: the relief of the level matching the
// pixel footprint minus the relief level's, inside a shell of +-parallax_depth metres around the
// mesh surface along the smooth normal. Mode 1 reads the fine level bilinearly (a smooth
// surface; the texel grid shears with the view), mode 2 per cell (flat-topped columns of one
// cache cell, with walls). With displacement off the whole relief is marched instead. No depth
// is written and nothing is cast into shadow maps.
uniform sampler2DArray surface_cache_height_linear : filter_linear, repeat_enable;
uniform int parallax_mode = 0;
uniform float parallax_radius = 8.0;
uniform float parallax_depth = 0.02;
// Share of the residual the ray sees. Material displacement is tuned for lumps of the mesh's
// vertex spacing; at full strength single texels stand out as spikes several centimetres tall.
uniform float parallax_strength = 0.25;
// Finest cache level the ray reads. Level 0 is one material texel: scanned height maps are
// noisy at that size. Level 2 keeps features of about 3 cm and up.
uniform int parallax_min_level = 0;
uniform int parallax_steps = 24;
uniform float parallax_wall_shade = 0.75;
// 1: hit height (red above the mesh, blue below), walls green. 2: cache level and step count.
uniform int parallax_debug = 0;

bool surface_cache_level_covers(vec2 position, int level, float margin) {
	float texel = surface_cache_params.x * exp2(float(level));
	vec2 grid = position / texel;
	vec2 origin = surface_cache_origins[level];
	float cells = 3.0 + margin / texel;
	return all(greaterThanEqual(grid, origin + vec2(cells))) && all(lessThan(grid, origin + vec2(surface_cache_params.y - cells)));
}

// Relief of a level, bilinear between its cell corners like surface_cache_relief().
float surface_cache_relief_linear(vec2 position, int level) {
	float resolution = surface_cache_params.y;
	vec2 grid = position / (surface_cache_params.x * exp2(float(level)));
	vec2 cell = floor(grid);
	// Wrapped before the division, which keeps the fraction's precision far from the origin.
	vec2 wrapped = mod(cell, resolution) + (grid - cell);
	return textureLod(surface_cache_height_linear, vec3((wrapped + vec2(0.5)) / resolution, float(level * 2 + 1)), 0.0).r;
}

float surface_cache_relief_cell(vec2 position, int level) {
	ivec2 cell = ivec2(floor(position / (surface_cache_params.x * exp2(float(level)))));
	return texelFetch(surface_cache_height, ivec3(cell & ivec2(int(surface_cache_params.y) - 1), level * 2 + 1), 0).r;
}

// Height of the fine surface above the displaced mesh, in metres along the normal.
float terrain_parallax_residual(vec2 position, int level, int mesh_level, float mesh_fade, float amplitude) {
	float fine = parallax_mode == 2 ? surface_cache_relief_cell(position, level) : surface_cache_relief_linear(position, level);
	float mesh = mesh_fade > 0.0 ? surface_cache_relief_linear(position, mesh_level) * mesh_fade : 0.0;
	return clamp((fine - mesh) * amplitude, -parallax_depth, parallax_depth);
}

// The terrain position a pixel shows: where its view ray meets the fine relief. position and
// base_point are the pixel's undisplaced surface point, view the unit terrain-local direction
// to the camera, footprint the pixel's size on the surface in metres. info: hit height above
// the mesh in shell units (-1..1), 1 on a column wall, cache level, share of parallax_steps.
vec2 terrain_parallax(vec2 position, vec3 base_point, vec3 normal, vec3 view, float footprint, out vec4 info) {
	info = vec4(0.0);
	int levels = int(surface_cache_params.z);
	if (parallax_mode == 0 || parallax_depth <= 0.0 || surface_cache_params.y <= 0.0 || levels <= 0) { return position; }
	float view_distance = distance(base_point, camera_position);
	float fade = 1.0 - smoothstep(parallax_radius * 0.6, parallax_radius, view_distance);
	if (fade <= 0.0) { return position; }
	float mesh_fade = displacement_enabled ? 1.0 - smoothstep(displacement_radius * 0.55, displacement_radius, view_distance) : 0.0;
	int mesh_level = int(surface_cache_params.w);
	if (mesh_level < 0) {
		// Without cached displacement the mesh evaluates its relief itself: only the
		// undisplaced terrain is handled here.
		if (mesh_fade > 0.0) { return position; }
		mesh_level = min(4, levels - 1);
	}
	// Travel across the surface per metre of height along the normal. The limit on the cosine
	// keeps grazing rays short: they flatten instead of sliding far.
	float cosine = dot(view, normal);
	vec2 slide = (view - normal * cosine).xz / max(cosine, 0.25);
	float reach = length(slide) * parallax_depth;
	int level = clamp(int(floor(log2(max(footprint, 0.000001) / surface_cache_params.x) + 0.5)), max(parallax_min_level, 0), levels - 1);
	while (level < mesh_level && !surface_cache_level_covers(position, level, reach)) { level++; }
	if (level >= mesh_level) { return position; }
	if (mesh_fade > 0.0 && !surface_cache_level_covers(position, mesh_level, reach)) { return position; }
	float texel = surface_cache_params.x * exp2(float(level));
	// One step per cell crossed (columns: finer, so thin ones are not stepped over).
	float crossed = 2.0 * reach / texel * (parallax_mode == 2 ? 1.5 : 1.0);
	int count = clamp(int(ceil(crossed)) + 2, 4, max(parallax_steps, 4));
	float amplitude = displacement_strength * parallax_strength * fade;
	// At height h above the mesh the ray is over position + slide * h. It starts on top of the
	// shell and always ends inside the surface at the bottom (the residual is clamped).
	float above = parallax_depth;
	float below = -parallax_depth;
	float step_height = 2.0 * parallax_depth / float(count);
	for (int i = 1; i < count; i++) {
		float h = parallax_depth - step_height * float(i);
		if (terrain_parallax_residual(position + slide * h, level, mesh_level, mesh_fade, amplitude) >= h) { below = h; break; }
		above = h;
	}
	for (int i = 0; i < 5; i++) {
		float h = 0.5 * (above + below);
		if (terrain_parallax_residual(position + slide * h, level, mesh_level, mesh_fade, amplitude) >= h) { below = h; } else { above = h; }
	}
	// Columns take the point inside the surface, so a wall shows its own column's texel.
	float hit = parallax_mode == 2 ? below : 0.5 * (above + below);
	vec2 shown = position + slide * hit;
	float wall = 0.0;
	if (parallax_mode == 2) {
		wall = step(step_height * 0.125 + 0.0003, terrain_parallax_residual(shown, level, mesh_level, mesh_fade, amplitude) - hit);
	}
	info = vec4(hit / parallax_depth, wall, float(level), float(count) / float(max(parallax_steps, 4)));
	return shown;
}

// Surface writers (StrataSurfaceWriter): where they covered a cell, the cache holds the
// composited surface, and the terrain takes it from there instead of its own evaluation (as an
// Unreal landscape samples its runtime virtual texture). The level follows the pixel footprint
// like nearest mipmap selection; beyond the coarsest window writers fade out.
uniform sampler2DArray surface_cache_albedo : filter_nearest, repeat_disable;
uniform sampler2DArray surface_cache_normal : filter_nearest, repeat_disable;
uniform sampler2DArray surface_cache_cover : filter_nearest, repeat_disable;

vec3 surface_cache_srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec3 surface_cache_octahedral_decode(vec2 encoded) {
	vec2 e = encoded * 2.0 - 1.0;
	vec3 n = vec3(e.x, 1.0 - abs(e.x) - abs(e.y), e.y);
	if (n.y < 0.0) { n.xz = (vec2(1.0) - abs(n.zx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.z >= 0.0 ? 1.0 : -1.0); }
	return normalize(n);
}

// Writer coverage at a terrain-local point (0 outside the cache) and the cached surface there.
// reach: 1 where the cache has the point, fading to 0 over the outer quarter of the coarsest
// window and 0 outside every window (the far layer takes over there).
float surface_cache_writers(vec2 position, float footprint, out vec4 albedo, out vec4 normal_data, out float reach_weight) {
	albedo = vec4(0.0); normal_data = vec4(0.0); reach_weight = 0.0;
	int resolution = int(surface_cache_params.y);
	int levels = int(surface_cache_params.z);
	if (resolution <= 0 || levels <= 0) { return 0.0; }
	// Fade over the outer quarter of the coarsest window so writers do not pop.
	float reach = surface_cache_params.x * exp2(float(levels - 1)) * (float(resolution) * 0.5 - 18.0);
	float d = max(abs(position.x - camera_position.x), abs(position.y - camera_position.z));
	float fade = 1.0 - smoothstep(reach * 0.75, reach, d);
	int first = clamp(int(floor(log2(max(footprint, 0.000001) / surface_cache_params.x) + 0.5)), 0, levels - 1);
	for (int k = first; k < levels; k++) {
		float texel = surface_cache_params.x * exp2(float(k));
		ivec2 cell = ivec2(floor(position / texel));
		ivec2 origin = ivec2(surface_cache_origins[k]);
		if (any(lessThan(cell, origin + ivec2(2))) || any(greaterThanEqual(cell, origin + ivec2(resolution - 2)))) { continue; }
		ivec3 at = ivec3(cell & ivec2(resolution - 1), k);
		reach_weight = fade;
		float cover = texelFetch(surface_cache_cover, at, 0).r;
		if (cover <= 0.0) { return 0.0; }
		albedo = texelFetch(surface_cache_albedo, at, 0);
		normal_data = texelFetch(surface_cache_normal, at, 0);
		return cover;
	}
	return 0.0;
}

// Far writer layer (StrataSurfaceWriterFar): every writer over the whole terrain at a coarse
// texel, premultiplied. surface_writer_far_rect: terrain-local XZ origin and size (zero: none).
uniform sampler2D surface_writer_far_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D surface_writer_far_normal : filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec4 surface_writer_far_rect = vec4(0.0);

bool surface_writer_far_sample(vec2 position, vec2 position_dx, vec2 position_dy, out vec4 albedo, out vec4 normal_data) {
	albedo = vec4(0.0); normal_data = vec4(0.0);
	if (surface_writer_far_rect.z <= 0.0) { return false; }
	vec2 uv = (position - surface_writer_far_rect.xy) / surface_writer_far_rect.zw;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) { return false; }
	vec2 scale = 1.0 / surface_writer_far_rect.zw;
	albedo = textureGrad(surface_writer_far_albedo, uv, position_dx * scale, position_dy * scale);
	// Writers set albedo and normal together almost always: one fetch away from them.
	if (albedo.a <= 0.0005) { return false; }
	normal_data = textureGrad(surface_writer_far_normal, uv, position_dx * scale, position_dy * scale);
	return true;
}
#endif

// Signed material relief in metres along the terrain normal. The fade uses the
// undisplaced surface point; outside it no material texture is fetched. The
// projections match fragment(): same base point, smooth normal and per-material
// axis weights, sampled at LOD0.
float material_height_offset(vec3 base_point, vec3 projection_normal) {
	float fade = displacement_enabled ? 1.0 - smoothstep(displacement_radius * 0.55, displacement_radius, distance(base_point, camera_position)) : 0.0;
	if (fade <= 0.0) { return 0.0; }
	float far_mix = uv_blend(base_point);
#ifdef STRATA_SURFACE_CACHE
	// The cache holds the near-UV relief only.
	float cached = 0.0;
	if (far_mix <= 0.0 && surface_cache_relief(base_point.xz, cached)) { return cached * displacement_strength * fade; }
#endif
	float relief = terrain_material_relief(base_point, projection_normal, far_mix);
	return relief * displacement_strength * fade;
}

// Occlusion of the world-space AO overlay at a terrain-local point (1 outside the tiles, in
// tiles without a map and beyond the fade). Explicit gradients from the caller's uniform
// derivatives, so it may run in any control flow.
float terrain_ao_overlay(vec3 local_point, vec3 local_dx, vec3 local_dy, float view_distance, mat4 model) {
	float fade = 1.0 - smoothstep(ao_overlay_fade_start, ao_overlay_fade_end, view_distance);
	if (fade <= 0.0) { return 1.0; }
	vec2 tile_position = ((model * vec4(local_point, 1.0)).xz - ao_overlay_origin) / ao_overlay_tile_size;
	ivec2 tile = ivec2(floor(tile_position));
	if (any(lessThan(tile, ivec2(0))) || any(greaterThanEqual(tile, textureSize(ao_overlay_table, 0)))) { return 1.0; }
	int layer = int(texelFetch(ao_overlay_table, tile, 0).r * 255.0 + 0.5) - 1;
	if (layer < 0) { return 1.0; }
	vec2 uv_dx = (mat3(model) * local_dx).xz / ao_overlay_tile_size;
	vec2 uv_dy = (mat3(model) * local_dy).xz / ao_overlay_tile_size;
	float occlusion = textureGrad(ao_overlay_layers, vec3(tile_position - vec2(tile), float(layer)), uv_dx, uv_dy).r;
	return mix(1.0, occlusion, fade);
}

#ifdef STRATA_MATERIAL_HOOKS
// StrataRenderer replaces the next line with terrain_material_hooks.gdshaderinc
// and the functions generated from StrataMaterial.custom_fragment_code.
STRATA_MATERIAL_HOOK_FUNCTIONS
#endif

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
	if (has_holes && terrain_cell_hole(terrain_position)) { discard; }
	// The position the pixel shows: the interpolated one, or where parallax moved it. Screen
	// derivatives stay those of the unmoved point (the moved one jumps between pixels).
	vec2 surface_position = terrain_position;
	vec4 parallax_info = vec4(0.0);
#ifdef STRATA_SURFACE_CACHE
	if (parallax_mode != 0) {
		vec3 local_view = normalize(transpose(mat3(MODEL_MATRIX)) * (mat3(INV_VIEW_MATRIX) * VIEW));
		surface_position = terrain_parallax(terrain_position, base_point, projection_normal, local_view, max(length(point_dx), length(point_dy)), parallax_info);
		base_point = vec3(surface_position.x, base_point.y + dot(smooth_gradient, surface_position - terrain_position), surface_position.y);
	}
#endif
	float far_mix = uv_blend(base_point);
	vec3 color; vec3 orm; vec3 final_normal; float discarded;
#ifdef STRATA_MATERIAL_HOOKS
	vec3 emission = vec3(0.0);
	// Materials with custom code are completed one by one before blending, so this
	// variant keeps the per-slot loop inline (terrain_surface_evaluate() is the plain path).
	ivec4 ids; vec4 weights;
	terrain_blend(surface_position, ids, weights, discarded);
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
	// Materials with custom code are completed one by one before blending, so
	// they need the lighting normal now. It depends on terrain position alone.
	vec2 gradient = base_shading_gradient(surface_position, smooth_gradient);
	vec3 geometric_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	vec3 hooked_normal = vec3(0.0);
	StrataContext context;
	context.position = base_point;
	context.world_position = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Translation/yaw with unit scale: the transposed basis is the inverse.
	context.view = normalize(transpose(mat3(MODEL_MATRIX)) * (mat3(INV_VIEW_MATRIX) * VIEW));
	context.geometric_normal = geometric_normal;
	context.screen_uv = SCREEN_UV;
	// Tangent-space detail is accumulated per projection axis across materials;
	// reorientation is linear in it, so each axis is reoriented once below.
	vec3 axis_details[3];
	for (int axis = 0; axis < 3; axis++) { axis_details[axis] = vec3(0.0); }
	for (int slot = 0; slot < 4; slot++) {
		if (weights[slot] > 0.0) {
			int id = ids[slot]; float scale = uv_scales[id];
			vec3 axis_weights = slot_axis_weights[slot];
			bool hooked = strata_material_has_hook(id);
			vec3 slot_color = vec3(0.0); vec3 slot_normal = vec3(0.0);
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
					// Reorientation is linear in detail, so this material's own sum
					// equals its share of the per-axis accumulation below.
					if (hooked) {
						slot_color += sampled_color * axis_weight;
						slot_normal += terrain_reoriented_normal(frames[axis], geometric_normal, near_normal * axis_weight);
						continue;
					}
					color += sampled_color * (weights[slot] * axis_weight);
					axis_details[axis] += near_normal * (weights[slot] * axis_weight);
				}
			}
			vec3 sampled_orm = packed_samples[slot].rgb;
			sampled_orm.g = clamp(sampled_orm.g * material_roughness_scales[id] + material_roughness_biases[id], 0.0, 1.0);
			if (hooked) {
				float normal_length = length(slot_normal);
				StrataSurface surface = StrataSurface(slot_color, normal_length > 0.00000001 ? slot_normal / normal_length : geometric_normal, sampled_orm.g, sampled_orm.b, sampled_orm.r, vec3(0.0));
				context.uv = base_point.xz * scale; context.axis_weights = axis_weights;
				context.weight = weights[slot]; context.height = packed_samples[slot].a; context.id = id;
				strata_material_hook(id, surface, context);
				float written_length = length(surface.normal);
				// An unchanged normal restores this material's exact contribution.
				vec3 written_normal = written_length > 0.00000001 ? surface.normal / written_length : geometric_normal;
				color += surface.albedo * weights[slot];
				hooked_normal += written_normal * (max(normal_length, 0.00000001) * weights[slot]);
				sampled_orm = vec3(surface.ao, surface.roughness, surface.metallic);
				emission += surface.emission * weights[slot];
			}
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
	final_normal = vec3(0.0);
	for (int axis = 0; axis < 3; axis++) { final_normal += terrain_reoriented_normal(frames[axis], geometric_normal, axis_details[axis]); }
	final_normal += hooked_normal;
	float final_length_squared = dot(final_normal, final_normal);
	final_normal = final_length_squared > 0.00000001 ? final_normal * inversesqrt(final_length_squared) : geometric_normal;
#else
	// Keep lighting smooth independently of canonical triangle height sampling.
	vec2 gradient = base_shading_gradient(surface_position, smooth_gradient);
	vec3 geometric_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	terrain_surface_evaluate(surface_position, base_point, point_dx, point_dy, projection_normal, geometric_normal, far_mix, color, orm, final_normal, discarded);
#endif
	ALBEDO = color;
	// RGBAH is linear terrain-scale data, separate from repeating source UVs.
	// AO affects indirect occlusion only; it is not baked into albedo here.
	vec4 terrain_macro = terrain_macro_sample(surface_position);
	ALBEDO *= mix(vec3(1.0), terrain_macro.rgb, terrain_tint_strength);
	float writer_cover = 0.0;
	float far_writer_cover = 0.0;
	vec4 writer_albedo = vec4(0.0);
#ifdef STRATA_SURFACE_CACHE
	vec4 writer_normal;
	float cache_reach;
	float cached_cover = surface_cache_writers(surface_position, max(length(point_dx), length(point_dy)), writer_albedo, writer_normal, cache_reach);
	// Where the cache fades out, the far layer takes over: the same writers over the terrain's
	// own surface, as the cache's fill composites them.
	vec3 far_color = ALBEDO; vec3 far_shading_normal = final_normal; float far_roughness = orm.g;
	vec4 far_albedo; vec4 far_normal;
	if (cache_reach < 1.0 && surface_writer_far_sample(surface_position, point_dx.xz, point_dy.xz, far_albedo, far_normal)) {
		far_color = ALBEDO * (1.0 - far_albedo.a) + far_albedo.rgb;
		far_writer_cover = far_albedo.a * (1.0 - cache_reach);
		if (far_normal.a > 0.002) {
			vec2 xz = clamp((far_normal.rg - 0.5 * far_normal.a) * 2.0 / far_normal.a, vec2(-1.0), vec2(1.0));
			vec3 written = terrain_reoriented_normal(terrain_triplanar_frame(1, geometric_normal), geometric_normal, vec3(xz.x, -xz.y, sqrt(max(0.0, 1.0 - dot(xz, xz)))));
			far_shading_normal = normalize(mix(final_normal, normalize(written), far_normal.a));
			far_roughness = orm.g * (1.0 - far_normal.a) + far_normal.b;
		}
	}
	if (cached_cover > 0.0) {
		ALBEDO = mix(ALBEDO, surface_cache_srgb_to_linear(writer_albedo.rgb), cached_cover);
		final_normal = normalize(mix(final_normal, surface_cache_octahedral_decode(writer_normal.rg), cached_cover));
		orm.g = mix(orm.g, writer_normal.b, cached_cover);
		orm.b = mix(orm.b, writer_normal.a, cached_cover * cache_reach);
	}
	if (cache_reach < 1.0) {
		ALBEDO = mix(far_color, ALBEDO, cache_reach);
		final_normal = normalize(mix(far_shading_normal, final_normal, cache_reach));
		orm.g = mix(far_roughness, orm.g, cache_reach);
	}
	writer_cover = cached_cover * cache_reach;
	// Column walls have no texels of their own: they show their column's, darkened.
	ALBEDO *= mix(1.0, parallax_wall_shade, parallax_info.y);
#endif
	NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(final_normal, 0.0)).xyz);
	float ownership_coverage = 0.0;
	if (show_ownership) {
		vec2 logical = inverse(mat2(ownership_step_x, ownership_step_y)) * (surface_position - ownership_origin);
		vec2 dimensions = vec2(textureSize(ownership_field, 0));
		vec2 mask_uv = (logical + vec2(0.5)) / dimensions;
		if (all(greaterThanEqual(logical, vec2(0.0))) && all(lessThanEqual(logical, dimensions - vec2(1.0)))) {
			ownership_coverage = clamp(textureLod(ownership_field, mask_uv, 0.0).r, 0.0, 1.0);
		}
		ALBEDO = mix(ALBEDO, vec3(0.95, 0.24, 0.055), ownership_coverage * 0.8);
	}
	float wet = 0.0;
	if (surface_wetness > 0.0) {
		wet = surface_wetness * mix(wet_steep_factor, 1.0, smoothstep(0.4, 0.9, final_normal.y));
		ALBEDO *= 1.0 - wet_darkening * wet;
		orm.g = mix(orm.g, min(orm.g, wet_roughness), wet);
	}
	ROUGHNESS = clamp(orm.g, 0.04, 1.0); METALLIC = clamp(orm.b, 0.0, 1.0);
	SPECULAR = mix(terrain_specular, max(terrain_specular, wet_specular), wet);
	AO = clamp(orm.r, 0.0, 1.0) * mix(1.0, terrain_macro.a, terrain_ao_strength);
	// The cache's AO already includes the macro AO.
	AO = mix(AO, writer_albedo.a, writer_cover);
	if (ao_overlay_enabled) {
		float overlay = terrain_ao_overlay(base_point, point_dx, point_dy, length(VERTEX), MODEL_MATRIX);
		AO *= mix(1.0, overlay, ao_overlay_ao_strength);
		ALBEDO *= mix(1.0, overlay, ao_overlay_albedo_strength);
		ROUGHNESS = mix(ROUGHNESS, 1.0, (1.0 - overlay) * ao_overlay_roughness_strength);
	}
#ifdef STRATA_MATERIAL_HOOKS
	EMISSION = emission;
#endif
	if (debug_shading_normals) { EMISSION = final_normal * 0.5 + 0.5; ALBEDO = vec3(0.0); ROUGHNESS = 1.0; METALLIC = 0.0; AO = 1.0; }
#ifdef STRATA_SURFACE_CACHE
	if (parallax_debug == 1) { EMISSION = vec3(max(parallax_info.x, 0.0), parallax_info.y, max(-parallax_info.x, 0.0)); ALBEDO = vec3(0.0); ROUGHNESS = 1.0; METALLIC = 0.0; AO = 1.0; }
	if (parallax_debug == 2) { EMISSION = vec3(parallax_info.z * 0.25, parallax_info.w, 0.0); ALBEDO = vec3(0.0); ROUGHNESS = 1.0; METALLIC = 0.0; AO = 1.0; }
#endif
	if (debug_surface_writers) { ALBEDO = mix(ALBEDO, vec3(0.0, 0.9, 1.0), writer_cover); ALBEDO = mix(ALBEDO, vec3(1.0, 0.0, 0.85), far_writer_cover); }
	if (debug_lod) { ALBEDO = mix(ALBEDO, vec3(fract(patch_level * 0.37), fract(patch_level * 0.61 + 0.3), fract(patch_level * 0.19 + 0.6)), 0.65); }
	if (debug_discarded) { ALBEDO = mix(vec3(0.05, 0.15, 0.05), vec3(1.0, 0.0, 0.25), clamp(discarded * 2.0, 0.0, 1.0)); }
	if (show_channel_preview) {
		vec2 uv = endpoint_field_uv(surface_position, channel_preview_origin, channel_preview_size, textureSize(channel_preview_field, 0));
		float value = clamp(texture(channel_preview_field, uv).r, 0.0, 1.0);
		EMISSION = mix(vec3(value), vec3(0.95, 0.24, 0.055), ownership_coverage * 0.8);
		ALBEDO = vec3(0.0); ROUGHNESS = 1.0; METALLIC = 0.0; AO = 1.0;
	}
}
