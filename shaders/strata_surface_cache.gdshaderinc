// Reads the ground below a point from the published StrataSurfaceCache (strata_surface_cache.gd,
// StrataRenderSettings.surface_cache_enabled with surface_cache_publish_globals). For any
// spatial shader: rocks, props and cliffs that blend into the terrain. Needs the strata_cache_*
// global shader parameters in the project settings (the Strata plugin adds them; see
// StrataSurfaceCache.register_project_globals()).
//
//   StrataGround ground;
//   float footprint = strata_ground_footprint(world_position);   // in uniform control flow
//   if (strata_ground_sample(world_position, footprint, ground)) {
//       float w = strata_ground_blend_weight(ground, world_position, world_normal, 0.3, 1.0);
//       ...mix the surface toward ground.albedo / ground.normal / ground.roughness by w...
//   }
//
// The cache is a virtual texture of the terrain's material without custom fragment code, one
// cell per material texel in mip 0 (StrataRenderSettings.surface_cache_texels_per_metre). Its
// pages follow what the screen shows: the ground under any drawn pixel on or near it (within
// StrataVirtualTextureFeedback.GROUND_BAND metres, about) is requested at that pixel's footprint, and a read takes the finest resident mip at or above the footprint's
// (strata_virtual_texture.gdshaderinc). Cells are read as the terrain filters them
// (StrataRenderSettings.surface_cache_filter: the nearest cell, or bilinear); heights
// interpolate bilinearly.

global uniform sampler2D strata_cache_page_table;
global uniform sampler2DArray strata_cache_albedo;
global uniform sampler2DArray strata_cache_normal;
global uniform sampler2DArray strata_cache_height;
global uniform vec4 strata_cache_params;    // cell size of mip 0 (m), page size (cells), border (cells), top mip
global uniform ivec4 strata_cache_layout;   // first page of mip 0 (xy), table size at mip 0, slots per atlas side
global uniform vec4 strata_cache_camera;    // terrain-local camera position, displacement radius (0: none)
global uniform vec4 strata_cache_surface;   // displacement strength, specular, relief mip (-1: none), 1 when enabled
global uniform vec4 strata_cache_sampling;  // lod bias (added to the mip a footprint selects), 1 when cells are read bilinearly, base height decode (height at 0, range)
global uniform mat4 strata_cache_world_to_local;

#define STRATA_VT_TABLE strata_cache_page_table
#define STRATA_VT_PARAMS strata_cache_params
#define STRATA_VT_LAYOUT strata_cache_layout
#include "res://addons/strata/shaders/strata_virtual_texture.gdshaderinc"

struct StrataGround {
	vec3 albedo;      // linear, after the terrain macro tint
	float ao;         // material AO times the macro AO
	vec3 normal;      // unit world-space normal including the material normal maps
	float roughness;
	float metallic;
	float specular;   // the terrain's specular level (StrataRenderSettings.terrain_specular)
	float height;     // world Y of the rendered ground below the point (displacement included)
	int level;        // mip read
};

bool strata_cache_enabled() {
	return strata_cache_surface.w > 0.5;
}

// Metres per pixel at a world point. Call in uniform control flow (screen derivatives).
float strata_ground_footprint(vec3 world_position) {
	return max(length(dFdx(world_position)), length(dFdy(world_position)));
}

// The finest resident mip at or above the footprint's mip (with the cache's lod bias; the top
// mip for larger footprints)
// that holds the terrain-local XZ point, with the point's atlas position; -1 when none does.
int strata_cache_find_level(vec2 local_xz, float footprint, out vec3 atlas) {
	atlas = vec3(0.0);
	if (!strata_cache_enabled()) { return -1; }
	return strata_vt_find(local_xz, strata_vt_footprint_mip(footprint, strata_cache_sampling.x), atlas);
}

vec3 strata_cache_srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec3 strata_cache_octahedral_decode(vec2 encoded) {
	vec2 e = encoded * 2.0 - 1.0;
	vec3 n = vec3(e.x, 1.0 - abs(e.x) - abs(e.y), e.y);
	if (n.y < 0.0) { n.xz = (vec2(1.0) - abs(n.zx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.z >= 0.0 ? 1.0 : -1.0); }
	return normalize(n);
}

// Albedo with AO and the normal texel at an atlas position: the cell holding it, or bilinear
// between the four nearest cell centres when the terrain filters its cache.
void strata_cache_texels(vec3 atlas, out vec4 albedo, out vec4 normal_data) {
	int layer = int(atlas.z);
	if (strata_cache_sampling.y < 0.5) {
		ivec3 texel = ivec3(ivec2(floor(atlas.xy)), layer);
		albedo = texelFetch(strata_cache_albedo, texel, 0);
		normal_data = texelFetch(strata_cache_normal, texel, 0);
		return;
	}
	vec2 centre = atlas.xy - vec2(0.5);
	ivec2 first = ivec2(floor(centre));
	vec2 f = centre - vec2(first);
	albedo = mix(mix(texelFetch(strata_cache_albedo, ivec3(first, layer), 0), texelFetch(strata_cache_albedo, ivec3(first + ivec2(1, 0), layer), 0), f.x),
		mix(texelFetch(strata_cache_albedo, ivec3(first + ivec2(0, 1), layer), 0), texelFetch(strata_cache_albedo, ivec3(first + ivec2(1, 1), layer), 0), f.x), f.y);
	normal_data = mix(mix(texelFetch(strata_cache_normal, ivec3(first, layer), 0), texelFetch(strata_cache_normal, ivec3(first + ivec2(1, 0), layer), 0), f.x),
		mix(texelFetch(strata_cache_normal, ivec3(first + ivec2(0, 1), layer), 0), texelFetch(strata_cache_normal, ivec3(first + ivec2(1, 1), layer), 0), f.x), f.y);
}

// The ground below world_position at a footprint (metres per pixel; 0 for the finest mip).
// False outside the terrain, in terrain holes, before a page holding the point is resident
// and while the cache is disabled.
bool strata_ground_sample(vec3 world_position, float footprint, out StrataGround ground) {
	ground = StrataGround(vec3(0.0), 1.0, vec3(0.0, 1.0, 0.0), 1.0, 0.0, 0.5, -1.0e30, -1);
	vec3 at;
	vec3 local = (strata_cache_world_to_local * vec4(world_position, 1.0)).xyz;
	int level = strata_cache_find_level(local.xz, footprint, at);
	if (level < 0) { return false; }
	vec4 albedo; vec4 normal_data;
	strata_cache_texels(at, albedo, normal_data);
	// Heights sit at cell corners: bilinear between this cell's four corners.
	ivec2 cell = ivec2(floor(at.xy));
	vec2 f = at.xy - vec2(cell);
	int base_layer = int(at.z);
	vec2 decode = strata_cache_sampling.zw;
	float h00 = texelFetch(strata_cache_height, ivec3(cell, base_layer), 0).r;
	float h10 = texelFetch(strata_cache_height, ivec3(cell + ivec2(1, 0), base_layer), 0).r;
	float h01 = texelFetch(strata_cache_height, ivec3(cell + ivec2(0, 1), base_layer), 0).r;
	float h11 = texelFetch(strata_cache_height, ivec3(cell + ivec2(1, 1), base_layer), 0).r;
	if (strata_vt_height_hole(min(min(h00, h10), min(h01, h11)))) { return false; }
	h00 = strata_vt_base_height(h00, decode); h10 = strata_vt_base_height(h10, decode);
	h01 = strata_vt_base_height(h01, decode); h11 = strata_vt_base_height(h11, decode);
	float base = mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
	vec3 local_normal = strata_cache_octahedral_decode(normal_data.rg);
	float radius = strata_cache_camera.w;
	float offset = 0.0;
	int relief_mip = int(strata_cache_surface.z);
	if (radius > 0.0 && relief_mip >= 0) {
		float fade = 1.0 - smoothstep(radius * 0.55, radius, distance(vec3(local.x, base, local.z), strata_cache_camera.xyz));
		vec3 rat;
		if (fade > 0.0 && strata_vt_locate(local.xz, relief_mip, rat)) {
			// As the terrain displaces its mesh: relief sampled at the displaced vertices (the
			// relief mip's cell corners, one per displacement_vertex_spacing), interpolated
			// between them, along the smooth terrain normal.
			float rt = strata_cache_params.x * exp2(float(relief_mip));
			ivec2 rc = ivec2(floor(rat.xy));
			vec2 rf = rat.xy - vec2(rc);
			int rl = int(rat.z);
			vec2 e00 = texelFetch(strata_cache_height, ivec3(rc, rl), 0).rg;
			vec2 e10 = texelFetch(strata_cache_height, ivec3(rc + ivec2(1, 0), rl), 0).rg;
			vec2 e01 = texelFetch(strata_cache_height, ivec3(rc + ivec2(0, 1), rl), 0).rg;
			float r11 = strata_vt_relief(texelFetch(strata_cache_height, ivec3(rc + ivec2(1, 1), rl), 0).g);
			float b00 = strata_vt_base_height(e00.r, decode), b10 = strata_vt_base_height(e10.r, decode), b01 = strata_vt_base_height(e01.r, decode);
			float r00 = strata_vt_relief(e00.g), r10 = strata_vt_relief(e10.g), r01 = strata_vt_relief(e01.g);
			vec2 slope = vec2(b10 - b00, b01 - b00) / rt;
			float vertical = inversesqrt(1.0 + dot(slope, slope));
			offset = mix(mix(r00, r10, rf.x), mix(r01, r11, rf.x), rf.y) * strata_cache_surface.x * fade * vertical;
		}
	}
	// world_to_local is a rigid transform (translation and yaw): its inverse is the transpose.
	mat3 to_local = mat3(strata_cache_world_to_local);
	vec3 local_ground = vec3(local.x, base + offset, local.z);
	vec3 world_ground = transpose(to_local) * (local_ground - strata_cache_world_to_local[3].xyz);
	ground.albedo = strata_cache_srgb_to_linear(albedo.rgb);
	ground.ao = albedo.a;
	ground.normal = normalize(transpose(to_local) * local_normal);
	ground.roughness = normal_data.b;
	ground.metallic = normal_data.a;
	ground.specular = strata_cache_surface.y;
	ground.height = world_ground.y;
	ground.level = level;
	return true;
}

// The ground's surface (albedo, AO, normal, roughness, metallic) at world_position's XZ, without
// its height. Fills those fields of ground and leaves the others; false where the cache holds
// no data. For looking the material up elsewhere than below the point (e.g. folding a side
// face out onto the ground) after strata_ground_sample() gave the height.
bool strata_ground_surface(vec3 world_position, float footprint, inout StrataGround ground) {
	vec3 at;
	vec3 local = (strata_cache_world_to_local * vec4(world_position, 1.0)).xyz;
	if (strata_cache_find_level(local.xz, footprint, at) < 0) { return false; }
	vec4 albedo; vec4 normal_data;
	strata_cache_texels(at, albedo, normal_data);
	mat3 to_local = mat3(strata_cache_world_to_local);
	ground.albedo = strata_cache_srgb_to_linear(albedo.rgb);
	ground.ao = albedo.a;
	ground.normal = normalize(transpose(to_local) * strata_cache_octahedral_decode(normal_data.rg));
	ground.roughness = normal_data.b;
	ground.metallic = normal_data.a;
	return true;
}

// 1 while the cache is enabled, 0 otherwise. The cache covers the whole terrain at every
// distance (coarser pages further away), so blends need no fade toward an edge; shaders that
// multiply their blend weight by this keep working.
float strata_cache_edge_fade(vec3 world_position) {
	return strata_cache_enabled() ? 1.0 : 0.0;
}

// Weight (0..1) with which a surface takes the ground's material: 1 at and below the ground,
// fading to 0 at band metres above it. facing (0..1) removes it from surfaces turned away from
// the sky (downward faces keep their own material).
float strata_ground_blend_weight(StrataGround ground, vec3 world_position, vec3 world_normal, float band, float facing) {
	float above = world_position.y - ground.height;
	float weight = 1.0 - smoothstep(0.0, max(band, 0.0001), above);
	return weight * mix(1.0, smoothstep(-0.35, 0.65, world_normal.y), clamp(facing, 0.0, 1.0));
}
