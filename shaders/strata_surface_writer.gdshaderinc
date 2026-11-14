// Writer material contract for StrataSurfaceWriter (strata_surface_writer.gd): a spatial
// shader that includes this file is drawn top-down into StrataSurfaceCache and composited over
// the terrain material there, like an Unreal Runtime Virtual Texture output. Use it as:
//
//   shader_type spatial;
//   #define STRATA_WRITER_TERRAIN_MATERIALS   // optional: strata_writer_terrain_material()
//   #include "res://addons/strata/shaders/strata_surface_writer.gdshaderinc"
//   void fragment() {
//       StrataWriterOutput o = strata_writer_output();
//       o.albedo = ...; o.alpha = ...;              // see the struct
//       strata_writer_emit(o, ALBEDO, ALPHA);       // always, as the last statement
//   }
//
// A writer that needs its own vertex() defines STRATA_WRITER_CUSTOM_VERTEX before the include
// and ends vertex() with STRATA_WRITER_VERTEX; (it sets POSITION; leave VERTEX in model space).
//
// Each writer is drawn once per output (albedo / normal + roughness / AO + relief + metallic,
// the instance uniform strata_writer_pass) into its third of the writer tile, with
// premultiplied over-blending; alpha is the coverage of every output. Overlapping writers sort by StrataSurfaceWriter.priority, then the
// material's render_priority, then height (the higher wins). The render modes below are part
// of the contract (unshaded, alpha blended, no depth); add nothing that changes them.
//
// View space here is the terrain's local frame seen from above: VIEW x = terrain +X,
// VIEW y = terrain -Z, VIEW z = terrain +Y (up). One pixel is one cache cell, so screen
// derivatives (dFdx/dFdy) are per cell and textureGrad picks the mip of the cache level.

render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled, ambient_light_disabled, fog_disabled, specular_disabled;

instance uniform int strata_writer_pass = 0;

// The camera frames the tile as the middle third of the viewport; each output's copy moves to
// its own third (0 left, 1 middle, 2 right).
vec4 strata_writer_position(vec3 vertex, mat4 modelview, mat4 projection) {
	vec4 position = projection * (modelview * vec4(vertex, 1.0));
	position.x += (2.0 * float(strata_writer_pass) - 2.0) / 3.0 * position.w;
	return position;
}

#define STRATA_WRITER_VERTEX POSITION = strata_writer_position(VERTEX, MODELVIEW_MATRIX, PROJECTION_MATRIX)

#ifndef STRATA_WRITER_CUSTOM_VERTEX
void vertex() {
	STRATA_WRITER_VERTEX;
}
#endif

struct StrataWriterOutput {
	vec3 albedo;      // linear albedo (source_color textures are already linear)
	vec3 normal;      // unit normal in ground space: terrain-local axes with Y up over flat ground;
	                  // laid onto the terrain's own slope like a normal map (0, 1, 0 keeps the slope)
	float roughness;
	float metallic;
	float ao;
	float relief;     // material relief in metres along the normal, before the renderer's
	                  // displacement strength (as StrataMaterial ORMH height x displacement)
	float alpha;      // coverage 0..1 of all outputs
};

StrataWriterOutput strata_writer_output() {
	return StrataWriterOutput(vec3(0.5), vec3(0.0, 1.0, 0.0), 1.0, 0.0, 1.0, 0.0, 1.0);
}

// Writes the output of the pass being drawn; nothing outside its third of the tile (geometry
// beyond the tile edge would spill into the neighbouring output). Use strata_writer_emit(o,
// ALBEDO, ALPHA) as the last statement of fragment().
void strata_writer_emit_at(StrataWriterOutput o, float fragment_x, float viewport_width, out vec3 albedo, out float alpha) {
	int slot = int(floor(fragment_x / (viewport_width / 3.0)));
	alpha = slot == strata_writer_pass ? clamp(o.alpha, 0.0, 1.0) : 0.0;
	if (strata_writer_pass == 0) {
		albedo = clamp(o.albedo, vec3(0.0), vec3(1.0));
	} else if (strata_writer_pass == 1) {
		vec3 n = normalize(vec3(o.normal.x, max(o.normal.y, 0.0001), o.normal.z));
		albedo = vec3(n.x * 0.5 + 0.5, n.z * 0.5 + 0.5, clamp(o.roughness, 0.0, 1.0));
	} else {
		albedo = vec3(clamp(o.ao, 0.0, 1.0), clamp(o.relief * 0.25 + 0.5, 0.0, 1.0), clamp(o.metallic, 0.0, 1.0));
	}
}

#define strata_writer_emit(o, albedo, alpha) strata_writer_emit_at(o, FRAGCOORD.x, VIEWPORT_SIZE.x, albedo, alpha)

// A view-space vector (VERTEX, NORMAL, TANGENT ...) in ground space.
vec3 strata_writer_view_to_ground(vec3 v) {
	return vec3(v.x, v.z, -v.y);
}

// Ground-space XZ directions of +u and +v of a UV set from its screen derivatives
// (dFdx(uv), dFdy(uv), taken in uniform control flow). Screen x is terrain +X and screen y
// terrain +Z, so the derivatives form the Jacobian d(uv)/d(x, z).
mat2 strata_writer_uv_axes(vec2 uv_dx, vec2 uv_dy) {
	mat2 jacobian = mat2(uv_dx, uv_dy);
	float det = determinant(jacobian);
	if (abs(det) < 1e-12) { return mat2(vec2(1.0, 0.0), vec2(0.0, 1.0)); }
	mat2 inverse_jacobian = inverse(jacobian);
	return mat2(normalize(inverse_jacobian[0]), normalize(inverse_jacobian[1]));
}

// A tangent-space normal (OpenGL convention: x along +u, y image up = -v, z out) of a texture
// mapped with uv, in ground space.
vec3 strata_writer_tangent_to_ground(vec3 tangent_normal, vec2 uv_dx, vec2 uv_dy) {
	mat2 axes = strata_writer_uv_axes(uv_dx, uv_dy);
	vec3 u = vec3(axes[0].x, 0.0, axes[0].y);
	vec3 v = vec3(axes[1].x, 0.0, axes[1].y);
	return normalize(tangent_normal.x * u - tangent_normal.y * v + tangent_normal.z * vec3(0.0, 1.0, 0.0));
}

#ifdef STRATA_WRITER_TERRAIN_MATERIALS
// Terrain materials by id (the StrataTerrain3D material list), sampled with the writer's own
// UVs. The renderers whose cache draws this writer fill these uniforms from their terrain
// material; nothing is saved into the writer material. Material textures use nearest
// filtering with mipmaps and texel-centre sampling (StrataRenderSettings.pixel_sampling)
// unless STRATA_WRITER_LINEAR_SAMPLING is defined before the include.
#ifdef STRATA_WRITER_LINEAR_SAMPLING
uniform sampler2D color_maps[32] : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D ormh_maps[32] : filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_maps[32] : filter_linear_mipmap, repeat_enable;
#else
#define STRATA_PIXEL_SAMPLING
uniform sampler2D color_maps[32] : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D ormh_maps[32] : filter_nearest_mipmap, repeat_enable;
uniform sampler2D normal_maps[32] : filter_nearest_mipmap, repeat_enable;
#endif
uniform float uv_scales[32];
uniform int top_texture_slots[32];
uniform float top_uv_scales[32];
uniform float material_displacement[32];
uniform float material_roughness_scales[32];
uniform float material_roughness_biases[32];

#include "res://addons/strata/shaders/terrain_texture_dispatch.gdshaderinc"

struct StrataWriterMaterial {
	vec3 albedo;      // linear
	vec3 normal;      // tangent space of uv (OpenGL convention); see strata_writer_tangent_to_ground()
	float roughness;  // after the material's roughness scale and bias
	float metallic;
	float ao;
	float relief;     // (ORMH height - 0.5) x the material's displacement, metres
	float height;     // ORMH height, 0.5 neutral
};

// Repeat of material id in texture repeats per metre (its top layer set when it has one).
float strata_writer_material_scale(int id) {
	return top_texture_slots[id] > 0 ? top_uv_scales[id] : uv_scales[id];
}

// Material id's top-projection textures at uv (in texture repeats: metres x
// strata_writer_material_scale(id)) with the screen derivatives of uv.
StrataWriterMaterial strata_writer_terrain_material(int id, vec2 uv, vec2 uv_dx, vec2 uv_dy) {
	int slot = clamp(id, 0, 31);
	int tid = top_texture_slots[slot] > 0 ? top_texture_slots[slot] - 1 : slot;
	vec3 color = terrain_color_grad(tid, uv, uv_dx, uv_dy).rgb;
	vec2 rg = terrain_normal_grad(tid, uv, uv_dx, uv_dy).rg * 2.0 - 1.0;
	vec4 ormh = terrain_ormh_grad(tid, uv, uv_dx, uv_dy);
	StrataWriterMaterial m;
	m.albedo = color;
	m.normal = vec3(rg, sqrt(max(0.0, 1.0 - dot(rg, rg))));
	m.roughness = clamp(ormh.g * material_roughness_scales[slot] + material_roughness_biases[slot], 0.0, 1.0);
	m.metallic = ormh.b;
	m.ao = ormh.r;
	m.height = ormh.a;
	m.relief = (ormh.a - 0.5) * material_displacement[slot];
	return m;
}
#endif
