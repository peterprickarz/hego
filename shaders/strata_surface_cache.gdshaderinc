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
// The cache holds the terrain's near material without custom fragment code, at one cell per
// material texel in level 0 (StrataRenderSettings.surface_cache_texels_per_metre), with levels
// chosen by footprint like mipmaps. Cells are read without filtering (texel-exact, matching
// pixel sampling); heights interpolate bilinearly.

global uniform sampler2DArray strata_cache_albedo;
global uniform sampler2DArray strata_cache_normal;
global uniform sampler2DArray strata_cache_height;
global uniform vec4 strata_cache_params;
global uniform vec4 strata_cache_windows_a;
global uniform vec4 strata_cache_windows_b;
global uniform vec4 strata_cache_windows_c;
global uniform vec4 strata_cache_windows_d;
global uniform vec4 strata_cache_camera;
global uniform vec4 strata_cache_surface;   // displacement strength, specular, relief level (-1: none), 0
global uniform mat4 strata_cache_world_to_local;

struct StrataGround {
	vec3 albedo;      // linear, after the terrain macro tint
	float ao;         // material AO times the macro AO
	vec3 normal;      // unit world-space normal including the material normal maps
	float roughness;
	float metallic;
	float specular;   // the terrain's specular level (StrataRenderSettings.terrain_specular)
	float height;     // world Y of the rendered ground below the point (displacement included)
	int level;        // cache level read
};

bool strata_cache_enabled() {
	return strata_cache_params.w > 0.5;
}

// First cell of a level's window (a huge value while the level is unfilled).
ivec2 strata_cache_window(int level) {
	vec4 pair = level < 2 ? strata_cache_windows_a : (level < 4 ? strata_cache_windows_b : (level < 6 ? strata_cache_windows_c : strata_cache_windows_d));
	return ivec2((level % 2) == 0 ? pair.xy : pair.zw);
}

// Metres per pixel at a world point. Call in uniform control flow (screen derivatives).
float strata_ground_footprint(vec3 world_position) {
	return max(length(dFdx(world_position)), length(dFdy(world_position)));
}

// The finest level at or above the footprint's level (the coarsest level for larger footprints)
// whose window holds the cell containing the terrain-local XZ point (two cells of margin); -1
// when none does.
int strata_cache_find_level(vec2 local_xz, float footprint, out ivec2 cell) {
	cell = ivec2(0);
	if (!strata_cache_enabled()) { return -1; }
	int levels = int(strata_cache_params.z);
	int resolution = int(strata_cache_params.y);
	// Nearest level, as nearest-mipmap filtering picks mips.
	int first = clamp(int(floor(log2(max(footprint, 0.000001) / strata_cache_params.x) + 0.5)), 0, levels - 1);
	for (int k = first; k < levels; k++) {
		float texel = strata_cache_params.x * exp2(float(k));
		ivec2 candidate = ivec2(floor(local_xz / texel));
		ivec2 origin = strata_cache_window(k);
		if (all(greaterThanEqual(candidate, origin + ivec2(2))) && all(lessThan(candidate, origin + ivec2(resolution - 2)))) {
			cell = candidate;
			return k;
		}
	}
	return -1;
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

// The ground below world_position at a footprint (metres per pixel; 0 for the finest level).
// False outside the cache, in terrain holes and while the cache is disabled.
bool strata_ground_sample(vec3 world_position, float footprint, out StrataGround ground) {
	ground = StrataGround(vec3(0.0), 1.0, vec3(0.0, 1.0, 0.0), 1.0, 0.0, 0.5, -1.0e30, -1);
	ivec2 cell;
	vec3 local = (strata_cache_world_to_local * vec4(world_position, 1.0)).xyz;
	int level = strata_cache_find_level(local.xz, footprint, cell);
	if (level < 0) { return false; }
	ivec2 mask = ivec2(int(strata_cache_params.y) - 1);
	vec4 albedo = texelFetch(strata_cache_albedo, ivec3(cell & mask, level), 0);
	vec4 normal_data = texelFetch(strata_cache_normal, ivec3(cell & mask, level), 0);
	// Heights sit at cell corners: bilinear between this cell's four corners.
	float texel = strata_cache_params.x * exp2(float(level));
	vec2 f = local.xz / texel - vec2(cell);
	int base_layer = level * 2;
	float h00 = texelFetch(strata_cache_height, ivec3(cell & mask, base_layer), 0).r;
	float h10 = texelFetch(strata_cache_height, ivec3((cell + ivec2(1, 0)) & mask, base_layer), 0).r;
	float h01 = texelFetch(strata_cache_height, ivec3((cell + ivec2(0, 1)) & mask, base_layer), 0).r;
	float h11 = texelFetch(strata_cache_height, ivec3((cell + ivec2(1, 1)) & mask, base_layer), 0).r;
	if (min(min(h00, h10), min(h01, h11)) < -1.0e29) { return false; }
	float base = mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
	vec3 local_normal = strata_cache_octahedral_decode(normal_data.rg);
	float radius = strata_cache_camera.w;
	float offset = 0.0;
	int relief_level = int(strata_cache_surface.z);
	if (radius > 0.0 && relief_level >= 0) {
		float fade = 1.0 - smoothstep(radius * 0.55, radius, distance(vec3(local.x, base, local.z), strata_cache_camera.xyz));
		if (fade > 0.0) {
			// As the terrain displaces its mesh: relief sampled at the displaced vertices (the
			// relief level's cell corners, one per displacement_vertex_spacing), interpolated
			// between them, along the smooth terrain normal.
			float rt = strata_cache_params.x * exp2(float(relief_level));
			ivec2 rc = ivec2(floor(local.xz / rt));
			ivec2 ro = strata_cache_window(relief_level);
			if (all(greaterThanEqual(rc, ro + ivec2(2))) && all(lessThan(rc, ro + ivec2(int(strata_cache_params.y) - 2)))) {
				vec2 rf = local.xz / rt - vec2(rc);
				int rl = relief_level * 2;
				float b00 = texelFetch(strata_cache_height, ivec3(rc & mask, rl), 0).r;
				float b10 = texelFetch(strata_cache_height, ivec3((rc + ivec2(1, 0)) & mask, rl), 0).r;
				float b01 = texelFetch(strata_cache_height, ivec3((rc + ivec2(0, 1)) & mask, rl), 0).r;
				float r00 = texelFetch(strata_cache_height, ivec3(rc & mask, rl + 1), 0).r;
				float r10 = texelFetch(strata_cache_height, ivec3((rc + ivec2(1, 0)) & mask, rl + 1), 0).r;
				float r01 = texelFetch(strata_cache_height, ivec3((rc + ivec2(0, 1)) & mask, rl + 1), 0).r;
				float r11 = texelFetch(strata_cache_height, ivec3((rc + ivec2(1, 1)) & mask, rl + 1), 0).r;
				vec2 slope = vec2(b10 - b00, b01 - b00) / rt;
				float vertical = inversesqrt(1.0 + dot(slope, slope));
				offset = mix(mix(r00, r10, rf.x), mix(r01, r11, rf.x), rf.y) * strata_cache_surface.x * fade * vertical;
			}
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
// its height: two texel reads. Fills those fields of ground and leaves the others; false where
// the cache holds no data. For looking the material up elsewhere than below the point (e.g.
// folding a side face out onto the ground) after strata_ground_sample() gave the height.
bool strata_ground_surface(vec3 world_position, float footprint, inout StrataGround ground) {
	ivec2 cell;
	vec3 local = (strata_cache_world_to_local * vec4(world_position, 1.0)).xyz;
	int level = strata_cache_find_level(local.xz, footprint, cell);
	if (level < 0) { return false; }
	ivec2 mask = ivec2(int(strata_cache_params.y) - 1);
	vec4 albedo = texelFetch(strata_cache_albedo, ivec3(cell & mask, level), 0);
	vec4 normal_data = texelFetch(strata_cache_normal, ivec3(cell & mask, level), 0);
	mat3 to_local = mat3(strata_cache_world_to_local);
	ground.albedo = strata_cache_srgb_to_linear(albedo.rgb);
	ground.ao = albedo.a;
	ground.normal = normalize(transpose(to_local) * strata_cache_octahedral_decode(normal_data.rg));
	ground.roughness = normal_data.b;
	ground.metallic = normal_data.a;
	return true;
}

// 1 well inside the cache's coarsest window, fading to 0 over its outer quarter: multiply
// blend weights by it so effects fade out with distance instead of popping at the window edge.
float strata_cache_edge_fade(vec3 world_position) {
	if (!strata_cache_enabled()) { return 0.0; }
	vec3 local = (strata_cache_world_to_local * vec4(world_position, 1.0)).xyz;
	// Half the coarsest window, less the margin and the window's snap offset (16 cells).
	float reach = strata_cache_params.x * exp2(strata_cache_params.z - 1.0) * (strata_cache_params.y * 0.5 - 18.0);
	float d = max(abs(local.x - strata_cache_camera.x), abs(local.z - strata_cache_camera.z));
	return 1.0 - smoothstep(reach * 0.75, reach, d);
}

// Weight (0..1) with which a surface takes the ground's material: 1 at and below the ground,
// fading to 0 at band metres above it. facing (0..1) removes it from surfaces turned away from
// the sky (downward faces keep their own material).
float strata_ground_blend_weight(StrataGround ground, vec3 world_position, vec3 world_normal, float band, float facing) {
	float above = world_position.y - ground.height;
	float weight = 1.0 - smoothstep(0.0, max(band, 0.0001), above);
	return weight * mix(1.0, smoothstep(-0.35, 0.65, world_normal.y), clamp(facing, 0.0, 1.0));
}
