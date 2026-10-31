// Per-material custom fragment code. Only shaders that StrataRenderer generates
// for a pool with StrataMaterial.custom_fragment_code include this file; the
// plain terrain_surface.gdshader never does.
//
// Each material with code gets a generated function
//   void strata_material_<id>(inout StrataSurface s, in StrataContext c)
// whose body is that code. It runs once per fragment for each of the (at most
// four) blended materials that has code, before the blend: what it writes to s
// is weighted by the material's final blend weight like its textures are.
// Vectors are terrain-local (the StrataTerrain3D node's space, Y up).

// This material's surface at the fragment. Written values are blended.
struct StrataSurface {
	vec3 albedo;    // linear colour from color_texture, before the terrain tint map
	vec3 normal;    // unit normal including this material's normal map
	float roughness; // after roughness_scale and roughness_bias
	float metallic;
	float ao;
	vec3 emission;  // starts at 0; added to the terrain's emission
};

// Read-only facts about the fragment and this material.
struct StrataContext {
	vec3 position;         // surface point before material displacement, metres
	vec3 world_position;   // rendered point in world space
	vec3 view;             // unit vector from the surface toward the camera
	vec3 geometric_normal; // lighting normal without any material normal map
	vec2 uv;               // top-projection texture UV: position.xz * uv_scale
	vec2 screen_uv;        // SCREEN_UV
	vec3 axis_weights;     // this material's triplanar weights for the X, Y (top) and Z projections
	float weight;          // this material's final blend weight here, in (0, 1]
	float height;          // this material's ORMH height (alpha), 0.5 neutral
	int id;                // material ID: the index in the material list
};
