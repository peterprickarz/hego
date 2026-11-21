@tool
class_name StrataSurfaceCache
extends RefCounted
## Sparse virtual texture of the resolved terrain surface (a runtime virtual texture): pages of
## page_size² cells in a mip chain over the terrain, of which the requested ones are resident in
## a fixed pool, found through a page table. Pages are filled on the GPU from the terrain
## material by a compute shader that splices the same shader includes as
## terrain_surface.gdshader. See "Surface cache" in docs/strata/reference.md.
##
## Cells are world-aligned at every mip: cell g of mip m covers [g, g + 1) * texel * 2^m on both
## terrain-local axes, so material texels and writer tiles keep their grid. Page p of mip m holds
## cells [p * page_size, (p + 1) * page_size); its page table texel is p - (origin0 >> m), where
## origin0 is the first page of mip 0 over the terrain, and the table of mip m has (size0 >> m)²
## texels. top_mip is the coarsest mip whose pages over the terrain fit its table.
##
## Page table: one R16 texture with a mip per page mip, 0 for an absent page, otherwise
## (slot + 1) / 65535. Pool: four texture arrays used as atlases, slots_per_side² slots per
## layer, each slot page_size + 2 * BORDER cells wide (the border repeats the neighbouring
## pages' cells, for filtering and for corner heights):
##   albedo  RGBA8   sRGB-encoded albedo after the macro tint (centre of cell), A ambient occlusion
##   normal  RGBA8   octahedral terrain-local normal (RG, Y up), B roughness, A metallic
##   height  RG16    at the cell corner g * texel: R base height, unorm over height_decode()
##                   (1 + t * 65534) / 65535 with t = (height - min) / range, 0 in holes;
##                   G material relief there (terrain_material_relief(), metres along the normal,
##                   before displacement_strength and the camera fade), relief / (2 *
##                   RELIEF_RANGE) + 0.5
##   cover   R8      how much of the cell surface writers replaced (StrataSurfaceWriter; 0 none)
##
## Requests come from the screen (StrataVirtualTextureFeedback: the page under every drawn pixel
## on or near the terrain surface, at its footprint), from the displaced mesh (the relief mip around the camera) and from the
## coarsest mips, which stay resident so every lookup ends somewhere. The least recently
## requested pages make room. A page a surface writer touches (StrataSurfaceWriter, drawn
## top-down by strata_surface_writer_pass.gd) waits for its writer tile and is evaluated once,
## with the writers composited over the terrain material.
## The cache holds the material without custom fragment code (that depends on the view).
##
## StrataRenderer owns one cache per terrain (StrataRenderSettings.surface_cache_enabled). It
## binds the page table and atlases to its own shader and, when publish_globals is set,
## publishes them as the strata_cache_* global shader parameters read by
## shaders/strata_surface_cache.gdshaderinc. Needs Forward+ or Mobile (a RenderingDevice).

## Cells of border around a page in its slot.
const BORDER := 4
## Largest material relief (metres either way) the height atlas holds: 16 m over 16 bits, a
## quarter of a millimetre per step.
const RELIEF_RANGE := 8.0
## The base height range is snapped outward to multiples of this many metres (with a metre of
## margin), so terrain edits seldom change it: a change refills every page.
const HEIGHT_RANGE_STEP := 32.0
const MAX_TABLE_SIZE := 4096
const MAX_ATLAS_SIZE := 4096
## The coarsest mips are always resident while they hold at most this many pages together: a
## lookup that finds nothing finer ends there.
const PINNED_PAGES := 64
## A missing page stays wanted this many frames after its last request (the feedback pass
## samples each pixel once in 64 frames).
const PENDING_FRAMES := 96
const GLOBAL_PARAMETERS := {
	"strata_cache_page_table": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D,
	"strata_cache_albedo": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2DARRAY,
	"strata_cache_normal": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2DARRAY,
	"strata_cache_height": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2DARRAY,
	# cell size (m) of mip 0, page size (cells), border (cells), top mip
	"strata_cache_params": RenderingServer.GLOBAL_VAR_TYPE_VEC4,
	# first page of mip 0 (xy), page table size at mip 0, slots per atlas side
	"strata_cache_layout": RenderingServer.GLOBAL_VAR_TYPE_IVEC4,
	# terrain-local camera position, displacement radius (0: no displacement)
	"strata_cache_camera": RenderingServer.GLOBAL_VAR_TYPE_VEC4,
	# displacement strength, terrain specular, relief mip (cells = displaced vertex spacing; -1
	# none), 1 when enabled
	"strata_cache_surface": RenderingServer.GLOBAL_VAR_TYPE_VEC4,
	# lod bias, 1 when readers filter cells bilinearly, 0, 0
	"strata_cache_sampling": RenderingServer.GLOBAL_VAR_TYPE_VEC4,
	"strata_cache_world_to_local": RenderingServer.GLOBAL_VAR_TYPE_TRANSFORM,
}
## Global parameters of earlier versions, removed from the project settings.
const _OBSOLETE_GLOBALS := ["strata_cache_windows_a", "strata_cache_windows_b", "strata_cache_windows_c", "strata_cache_windows_d"]
## Pages waiting for a writer tile at most, and missing pages looked at per frame at most.
const _MAX_AWAITING := 64
const _MAX_SCANNED := 256
## Frames a requested page counts as on screen and keeps its slot: the feedback pass reports a
## visible page once per sampling cycle (not every frame), a frame or two late; the camera
## squares request theirs every frame.
const _ON_SCREEN_FEEDBACK := preload("res://addons/strata/strata_virtual_texture_feedback.gd").CYCLE_FRAMES + 2
const _ON_SCREEN_SQUARES := 2
## Shares of the pool on screen (pages requested within the on-screen frames, resident or still
## missing) above which pressure_bias rises and below which it falls again, its steps per frame
## and its limit. After a step it holds for the on-screen frames, until the pages requested
## before the step have left the measure.
const _PRESSURE_ABOVE := 0.85
const _PRESSURE_BELOW := 0.6
const _PRESSURE_RISE := 0.02
const _PRESSURE_FALL := 0.005
const _PRESSURE_MAX := 4.0

const _SHADER_DIR := "res://addons/strata/shaders/"
const _INCLUDES := ["terrain_regions", "terrain_controls", "terrain_texture_dispatch", "terrain_normals", "terrain_height_blend", "terrain_bombing", "terrain_triplanar", "terrain_surface_core"]
const _MATERIAL_ARRAYS := ["uv_scales", "top_texture_slots", "top_uv_scales", "triplanar_sharpnesses", "projection_modes", "material_displacement", "height_blend_contrasts", "height_blend_biases", "material_roughness_scales", "material_roughness_biases", "top_material_displacement", "material_bombing"]
const _INT_ARRAYS := ["top_texture_slots", "projection_modes"]
## Scalar uniforms read by the includes, in the float/int slots of the parameter buffer.
const _FLOAT_SLOTS := {"region_origin": 0, "region_extent": 2, "region_spacing": 3, "field_origin": 4, "field_size": 6, "crease_cosine": 8, "terrain_tint_strength": 9, "terrain_ao_strength": 10, "far_uv_factor": 11, "cell_bombing_size": 12, "uv_near_distance": 13, "uv_far_distance": 14, "surface_cache_pixel_angle": 15, "surface_cache_bake_lod_bias": 16, "surface_cache_shading_eye_height": 17}
const _INT_SLOTS := {"region_cells": 0, "region_grid": 1, "region_lattice": 3, "height_scale": 5, "height_apron": 6, "material_ids_scale": 7, "material_ids_apron": 8, "holes_scale": 9, "holes_apron": 10, "macro_scale": 11, "macro_apron": 12, "far_level": 13, "coarse_level": 14, "has_far_tier": 15, "has_coarse_maps": 16, "has_material_maps": 17, "has_holes": 18, "has_terrain_macro_map": 19, "height_blend_enabled": 20, "triangle_height_sampling": 21, "smooth_shading": 22, "cell_bombing": 23, "distance_uv_enabled": 24, "surface_cache_shading": 25}
const _VECTOR_UNIFORMS := ["region_origin", "field_origin", "field_size", "region_grid", "region_lattice"]
## Sampled maps after the three material arrays (bindings 3-18): name, filter (0 nearest, 1 linear).
const _MAP_BINDINGS := [["region_table", 0], ["height_regions", 1], ["material_ids_regions", 0], ["material_weights_regions", 0], ["holes_regions", 0], ["macro_regions", 1], ["height_far_regions", 1], ["material_ids_far_regions", 0], ["material_weights_far_regions", 0], ["holes_far_regions", 0], ["macro_far_regions", 1], ["coarse_height", 1], ["coarse_material_ids", 0], ["coarse_material_weights", 0], ["coarse_holes", 0], ["coarse_macro", 1]]

const _GLSL_PRELUDE := """
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D color_maps[32];
layout(set = 0, binding = 1) uniform sampler2D normal_maps[32];
layout(set = 0, binding = 2) uniform sampler2D ormh_maps[32];
layout(set = 0, binding = 3) uniform sampler2D region_table;
layout(set = 0, binding = 4) uniform sampler2DArray height_regions;
layout(set = 0, binding = 5) uniform sampler2DArray material_ids_regions;
layout(set = 0, binding = 6) uniform sampler2DArray material_weights_regions;
layout(set = 0, binding = 7) uniform sampler2DArray holes_regions;
layout(set = 0, binding = 8) uniform sampler2DArray macro_regions;
layout(set = 0, binding = 9) uniform sampler2DArray height_far_regions;
layout(set = 0, binding = 10) uniform sampler2DArray material_ids_far_regions;
layout(set = 0, binding = 11) uniform sampler2DArray material_weights_far_regions;
layout(set = 0, binding = 12) uniform sampler2DArray holes_far_regions;
layout(set = 0, binding = 13) uniform sampler2DArray macro_far_regions;
layout(set = 0, binding = 14) uniform sampler2D coarse_height;
layout(set = 0, binding = 15) uniform sampler2D coarse_material_ids;
layout(set = 0, binding = 16) uniform sampler2D coarse_material_weights;
layout(set = 0, binding = 17) uniform sampler2D coarse_holes;
layout(set = 0, binding = 18) uniform sampler2D coarse_macro;
layout(set = 0, binding = 19, std430) restrict readonly buffer Parameters {
	float uv_scales[32]; int top_texture_slots[32]; float top_uv_scales[32]; float triplanar_sharpnesses[32];
	int projection_modes[32]; float material_displacement[32]; float height_blend_contrasts[32]; float height_blend_biases[32];
	float material_roughness_scales[32]; float material_roughness_biases[32]; float top_material_displacement[32]; float material_bombing[32];
	float pf[32]; int pi[32];
};
layout(set = 0, binding = 20, rgba8) restrict writeonly uniform image2DArray albedo_out;
layout(set = 0, binding = 21, rgba8) restrict writeonly uniform image2DArray normal_out;
layout(set = 0, binding = 22, rg16) restrict writeonly uniform image2DArray height_out;
layout(set = 0, binding = 23, r8) restrict writeonly uniform image2DArray cover_out;
// Writer pass tile (strata_surface_writer_pass.gd), premultiplied over-composite of the writers,
// three outputs side by side (fill.tile_width texels each):
//   0 albedo   linear albedo, A coverage
//   1 normal   ground-space normal xz * 0.5 + 0.5, roughness, A coverage
//   2 surface  AO, relief * 0.25 + 0.5, metallic, A coverage
layout(set = 1, binding = 0) uniform sampler2D writer_tile;
// rect_origin: the slot's first cell at its mip; store_origin: its first texel in atlas layer `layer`.
layout(push_constant, std430) uniform Fill { ivec2 rect_origin; ivec2 rect_size; int level; int layer; float texel; int writers; ivec2 tile_origin; int tile_width; int pad; ivec2 store_origin; vec2 height_decode; } fill;
#define writer_albedo_at(t) texelFetch(writer_tile, (t), 0)
#define writer_normal_at(t) texelFetch(writer_tile, (t) + ivec2(fill.tile_width, 0), 0)
#define writer_surface_at(t) texelFetch(writer_tile, (t) + ivec2(2 * fill.tile_width, 0), 0)

// The includes read the terrain shader's uniforms by name; these map them to the buffer.
#define region_origin vec2(pf[0], pf[1])
#define region_extent pf[2]
#define region_spacing pf[3]
#define field_origin vec2(pf[4], pf[5])
#define field_size vec2(pf[6], pf[7])
#define crease_cosine pf[8]
#define terrain_tint_strength pf[9]
#define terrain_ao_strength pf[10]
#define far_uv_factor pf[11]
#define cell_bombing_size pf[12]
#define uv_near_distance pf[13]
#define uv_far_distance pf[14]
#define surface_cache_pixel_angle pf[15]
#define surface_cache_bake_lod_bias pf[16]
#define surface_cache_shading_eye_height pf[17]
#define region_cells pi[0]
#define region_grid ivec2(pi[1], pi[2])
#define region_lattice ivec2(pi[3], pi[4])
#define height_scale pi[5]
#define height_apron pi[6]
#define material_ids_scale pi[7]
#define material_ids_apron pi[8]
#define holes_scale pi[9]
#define holes_apron pi[10]
#define macro_scale pi[11]
#define macro_apron pi[12]
#define far_level pi[13]
#define coarse_level pi[14]
#define has_far_tier (pi[15] != 0)
#define has_coarse_maps (pi[16] != 0)
#define has_material_maps (pi[17] != 0)
#define has_holes (pi[18] != 0)
#define has_terrain_macro_map (pi[19] != 0)
#define height_blend_enabled (pi[20] != 0)
#define triangle_height_sampling (pi[21] != 0)
#define smooth_shading (pi[22] != 0)
#define cell_bombing (pi[23] != 0)
#define distance_uv_enabled (pi[24] != 0)
#define surface_cache_shading (pi[25] != 0)
"""

const _GLSL_MAIN := """
vec3 cache_linear_to_srgb(vec3 c) {
	c = clamp(c, vec3(0.0), vec3(1.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

// Octahedral encoding around +Y (the terrain up axis), mapped to 0..1.
vec2 cache_octahedral(vec3 n) {
	n /= abs(n.x) + abs(n.y) + abs(n.z);
	vec2 e = n.xz;
	if (n.y < 0.0) { e = (vec2(1.0) - abs(e.yx)) * vec2(e.x >= 0.0 ? 1.0 : -1.0, e.y >= 0.0 ? 1.0 : -1.0); }
	return e * 0.5 + 0.5;
}

// The height atlas (RG16 unorm, see the class description): base height over fill.height_decode
// (min, range), 0 reserved for holes; relief over +-RELIEF_RANGE metres.
vec2 cache_encode_height(bool hole, float base, float relief) {
	if (hole) { return vec2(0.0, 0.5); }
	float t = clamp((base - fill.height_decode.x) / max(fill.height_decode.y, 1.0e-6), 0.0, 1.0);
	return vec2((1.0 + t * 65534.0) / 65535.0, clamp(relief / (2.0 * %RELIEF_RANGE%) + 0.5, 0.0, 1.0));
}

// With cache shading the terrain reads colour, normal and ORM from the cache, far UV blend
// included: a mip holds the blend of the footprint that reads it (uv_blend_footprint() in
// terrain_surface.gdshader). Without it the cache holds the near UVs.
float cache_far_mix(float texel) {
	if (!surface_cache_shading || !distance_uv_enabled || surface_cache_pixel_angle <= 0.0) { return 0.0; }
	float footprint = texel * exp2(-surface_cache_bake_lod_bias);
	return smoothstep(uv_near_distance, uv_far_distance, sqrt(footprint * surface_cache_shading_eye_height / surface_cache_pixel_angle));
}

// Writer coverage-weighted sum of a tile texel (premultiplied: rgb is the sum of value * weight).
vec4 writer_fetch_surface_corner(ivec2 t) {
	return 0.25 * (writer_surface_at(t) + writer_surface_at(t - ivec2(1, 0)) + writer_surface_at(t - ivec2(0, 1)) + writer_surface_at(t - ivec2(1, 1)));
}

void main() {
	ivec2 local = ivec2(gl_GlobalInvocationID.xy);
	if (local.x >= fill.rect_size.x || local.y >= fill.rect_size.y) { return; }
	ivec2 cell = fill.rect_origin + local;
	ivec3 store = ivec3(fill.store_origin + local, fill.layer);
	float texel = fill.texel;
	// Colour, normal and ORM at the cell centre with a footprint of one cell, so the material
	// mip matches the page's (128 texels/m material on a 1/128 m mip 0 is copied texel for texel).
	vec2 centre = (vec2(cell) + vec2(0.5)) * texel;
	vec2 smooth_gradient = terrain_smooth_gradient(centre);
	vec3 projection_normal = normalize(vec3(-smooth_gradient.x, 1.0, -smooth_gradient.y));
	vec3 base_point = vec3(centre.x, base_height(centre), centre.y);
	vec3 point_dx = vec3(texel, smooth_gradient.x * texel, 0.0);
	vec3 point_dy = vec3(0.0, smooth_gradient.y * texel, texel);
	vec2 gradient = base_shading_gradient(centre, smooth_gradient);
	vec3 geometric_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	vec3 color; vec3 orm; vec3 normal; float discarded;
	terrain_surface_evaluate(centre, base_point, point_dx, point_dy, projection_normal, geometric_normal, cache_far_mix(texel), color, orm, normal, discarded);
	vec4 macro = terrain_macro_sample(centre);
	color *= mix(vec3(1.0), macro.rgb, terrain_tint_strength);
	float ao = clamp(orm.r, 0.0, 1.0) * mix(1.0, macro.a, terrain_ao_strength);
	float roughness = clamp(orm.g, 0.04, 1.0);
	float metallic = clamp(orm.b, 0.0, 1.0);
	float cover = 0.0;
	ivec2 tile = cell - fill.tile_origin;
	if (fill.writers != 0) {
		// Writers over the finished terrain surface (after the macro tint: writers keep their colour).
		vec4 wa = writer_albedo_at(tile);
		vec4 wn = writer_normal_at(tile);
		vec4 ws = writer_surface_at(tile);
		color = color * (1.0 - wa.a) + max(wa.rgb, vec3(0.0));
		if (wn.a > 0.0001) {
			// Ground-space detail (Y up over flat ground) laid onto the terrain's lighting normal,
			// as the top projection's normal maps are: tangent x = +X, image up = -Z.
			vec2 xz = clamp((wn.rg - 0.5 * wn.a) * 2.0 / wn.a, vec2(-1.0), vec2(1.0));
			vec3 detail = vec3(xz.x, -xz.y, sqrt(max(0.0, 1.0 - dot(xz, xz))));
			vec3 written = terrain_reoriented_normal(terrain_triplanar_frame(1, geometric_normal), geometric_normal, detail);
			normal = normalize(mix(normal, normalize(written), clamp(wn.a, 0.0, 1.0)));
			roughness = clamp(roughness * (1.0 - wn.a) + wn.b, 0.04, 1.0);
		}
		ao = clamp(ao * (1.0 - ws.a) + ws.r, 0.0, 1.0);
		metallic = clamp(metallic * (1.0 - ws.a) + ws.b, 0.0, 1.0);
		cover = clamp(max(wa.a, max(wn.a, ws.a)), 0.0, 1.0);
	}
	imageStore(albedo_out, store, vec4(cache_linear_to_srgb(color), ao));
	imageStore(normal_out, store, vec4(cache_octahedral(normal), roughness, metallic));
	imageStore(cover_out, store, vec4(cover));
	// Heights at the cell corner: displaced vertices on the mip's lattice read their own value.
	vec2 corner = vec2(cell) * texel;
	vec2 corner_gradient = terrain_smooth_gradient(corner);
	vec3 corner_normal = normalize(vec3(-corner_gradient.x, 1.0, -corner_gradient.y));
	float corner_height = base_height(corner);
	float relief = terrain_material_relief(vec3(corner.x, corner_height, corner.y), corner_normal, 0.0);
	if (fill.writers != 0) {
		vec4 ws = writer_fetch_surface_corner(tile);
		if (ws.a > 0.0001) { relief = relief * (1.0 - ws.a) + (ws.g - 0.5 * ws.a) * 4.0; }
	}
	bool hole = has_holes && terrain_cell_hole(corner);
	imageStore(height_out, ivec3(store.xy, fill.layer), vec4(cache_encode_height(hole, corner_height, relief), 0.0, 0.0));
}
"""

const _TABLE_GLSL := """#version 450
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0, r16) restrict writeonly uniform image2D table;
layout(push_constant, std430) uniform Entry { ivec2 texel; float value; float pad; } entry;
void main() { imageStore(table, entry.texel, vec4(entry.value)); }
"""

## Cell edge of mip 0 in metres (1 / texels per metre).
var texel := 1.0 / 128.0
## Cells per page side (a power of two).
var page_size := 128
## Slots in the pool (rounded up to whole atlas layers).
var pool_pages := 1024
## Pages evaluated per frame at most (pages drawn with a writer tile come on top).
var page_fills_per_frame := 32
## Half-size in cells, per mip, of the square around the camera whose pages are requested while
## no feedback names the visible pages.
var ring_cells := 448
## True while feedback_keys carries the pages the screen reads (StrataVirtualTextureFeedback);
## the squares around the camera are then requested for the relief mip only.
var feedback_active := false
## Page keys reported since the last update (mip << 28 | table y << 14 | table x); consumed by
## update().
var feedback_keys := PackedInt32Array()
## Mip whose relief the displaced vertices read (-1: none) and the terrain-local distance from
## the camera within which its pages are always requested: vertices cannot wait for feedback.
var relief_mip := -1
var relief_radius := 0.0
## Readers of the published cache filter cells bilinearly (the terrain does) instead of taking
## the nearest one.
var bilinear_readers := false
## Added to the mip a pixel footprint selects (negative: finer).
var lod_bias := -1.0
## Added on top of lod_bias while the screen requests more pages than the pool holds, so the
## requests fit (a softer surface) instead of pages being left out. See effective_lod_bias().
var pressure_bias := 0.0
## Coarsest mip with a page table (see the class description).
var top_mip := 0
## Cells per atlas side, and the number of mips (top_mip + 1).
var resolution := 0
var levels := 0
var publish_globals := true
## Terrain-local base height range the height atlas encodes (set_height_range()).
var height_min := -HEIGHT_RANGE_STEP
var height_range := 2.0 * HEIGHT_RANGE_STEP
## Records GPU timestamps around the fill: stats.gpu_ms is the GPU time of the last fill that
## did work (two frames late), stats.gpu_ms_total the sum over all fills.
var measure_gpu := false
var page_table_texture := Texture2DRD.new()
var albedo_texture := Texture2DArrayRD.new()
var normal_texture := Texture2DArrayRD.new()
var height_texture := Texture2DArrayRD.new()
## R8: writer coverage of each cell (read by the terrain shader).
var cover_texture := Texture2DArrayRD.new()
var stats := {"levels": 0, "resolution": 0, "texels_last_frame": 0, "dispatches_last_frame": 0, "memory_mb": 0.0, "status": "Not configured", "gpu_ms": 0.0, "gpu_ms_total": 0.0, "gpu_samples": 0}

var _rd: RenderingDevice
var _bounds := Rect2()
var _origin0 := Vector2i.ZERO
var _last0 := Vector2i.ZERO
var _size0 := 1
var _slot_size := 136
var _slots_per_side := 1
var _layers := 1
var _layout_key := ""
## Page key (Vector3i table x, table y, mip) -> slot.
var _resident := {}
## Per slot: its page key (null when free) and the frame it was last requested.
var _slot_key: Array = []
var _slot_used := PackedInt32Array()
var _free: Array[int] = []
## Resident pages whose content is stale (terrain or material edits).
var _dirty := {}
## Requested pages that are missing or stale -> the frame of their last request.
var _asked := {}
## Pages a surface writer touches, waiting for their writer tile -> the frame it was queued (-1:
## the writers changed since, so the tile is drawn again). Such a page is evaluated once, with
## its writers; until then a lookup falls back to coarser pages, or keeps the page's old content.
var _awaiting := {}
## Slots that may be evicted this frame, the least recently requested last.
var _evictable: Array[int] = []
var _evictable_frame := -1
## pressure_bias as effective_lod_bias() last applied it, and the frame until which it holds.
var _pressure_step := 0.0
var _pressure_hold := 0
## Frames a requested page counts as on screen (see _ON_SCREEN_FEEDBACK).
var _on_screen_frames := _ON_SCREEN_SQUARES
var _pinned: Array[Vector3i] = []
var _frame := 0
## Every resident page is stale: the material or the shader variant changed.
var _refill := false
## Set on the render thread when a request could not run (a map not uploaded yet): the main
## thread starts over.
var _reset_requested := false
var _textures: Array[RID] = []
var _textures_dirty := true
var _table := RID()
var _table_views: Array[RID] = []
var _table_shader := RID()
var _table_pipeline := RID()
var _table_sets: Array[RID] = []
var _table_dirty := true
var _shader := RID()
var _pipeline := RID()
var _shader_key := ""
var _samplers: Array[RID] = []
var _sampler_key := ""
var _params := RID()
var _params_size := 0
var _uniform_set := RID()
var _uniform_key := ""
var _writer_sets := {}
var _writer_fallback_set := RID()
var _fallbacks: Array[RID] = []
var _material_signature := ""
var _parameter_bytes := PackedByteArray()
var _parameter_dirty := true
var _maps: Dictionary = {}
var _defines := ""
var _failed := false
var _globals_owner := false
var _globals_checked := -1
## Last value sent per global parameter.
var _published := {}
var _timestamp_frame := 0


## True when a RenderingDevice exists (Forward+ or Mobile; not Compatibility or headless).
static func available() -> bool:
	return RenderingServer.get_rendering_device() != null and DisplayServer.get_name() != "headless"


## Brings the strata_cache_* global shader parameters in the project settings up to date (adds
## the missing ones, removes those of earlier versions), so shaders including
## strata_surface_cache.gdshaderinc compile. Returns true when it changed any; the editor must
## save the project settings for exported games.
static func register_project_globals() -> bool:
	var changed := false
	for name: String in _OBSOLETE_GLOBALS:
		var key := "shader_globals/" + name
		if not ProjectSettings.has_setting(key): continue
		ProjectSettings.set_setting(key, null)
		if RenderingServer.global_shader_parameter_get_list().has(StringName(name)):
			RenderingServer.global_shader_parameter_remove(name)
		changed = true
	for name: String in GLOBAL_PARAMETERS:
		var key := "shader_globals/" + name
		var type_name := _global_type_name(int(GLOBAL_PARAMETERS[name]))
		if ProjectSettings.has_setting(key):
			var current: Variant = ProjectSettings.get_setting(key)
			if current is Dictionary and str((current as Dictionary).get("type", "")) == type_name: continue
		var value: Variant = "" if type_name.begins_with("sampler") else (Transform3D.IDENTITY if type_name == "transform" else (Vector4i.ZERO if type_name == "ivec4" else Vector4.ZERO))
		ProjectSettings.set_setting(key, {"type": type_name, "value": value})
		if RenderingServer.global_shader_parameter_get_list().has(StringName(name)):
			RenderingServer.global_shader_parameter_remove(name)
		RenderingServer.global_shader_parameter_add(name, int(GLOBAL_PARAMETERS[name]), null if type_name.begins_with("sampler") else value)
		changed = true
	return changed


static func _global_type_name(type: int) -> String:
	match type:
		RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D: return "sampler2D"
		RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2DARRAY: return "sampler2DArray"
		RenderingServer.GLOBAL_VAR_TYPE_VEC4: return "vec4"
		RenderingServer.GLOBAL_VAR_TYPE_IVEC4: return "ivec4"
		RenderingServer.GLOBAL_VAR_TYPE_TRANSFORM: return "transform"
	return "float"


## Sets the layout over terrain-local [param bounds]; changing it reallocates the pool and the
## page table and drops every page. False (with stats.status) when the page table would exceed
## MAX_TABLE_SIZE: use larger pages or fewer texels per metre.
func configure(bounds: Rect2, texels_per_metre: float, cells_per_page: int, slots: int) -> bool:
	if not is_finite(texels_per_metre) or texels_per_metre <= 0.0 or not bounds.has_area(): return false
	cells_per_page = clampi(nearest_po2(cells_per_page), 32, 512)
	slots = clampi(slots, 64, 16384)
	var key := "%s|%f|%d|%d" % [bounds, texels_per_metre, cells_per_page, slots]
	if key == _layout_key: return not _failed
	_layout_key = key
	_bounds = bounds
	texel = 1.0 / texels_per_metre
	page_size = cells_per_page
	var first_cell := Vector2i(floori(bounds.position.x / texel), floori(bounds.position.y / texel))
	var last_cell := Vector2i(ceili(bounds.end.x / texel) - 1, ceili(bounds.end.y / texel) - 1)
	_origin0 = Vector2i(_floor_div(first_cell.x, page_size), _floor_div(first_cell.y, page_size))
	_last0 = Vector2i(_floor_div(last_cell.x, page_size), _floor_div(last_cell.y, page_size))
	var span := maxi(_last0.x - _origin0.x, _last0.y - _origin0.y) + 1
	_size0 = nearest_po2(span)
	if _size0 > MAX_TABLE_SIZE:
		stats.status = "Page table of %d² pages exceeds %d: raise surface_cache_page_size or lower surface_cache_texels_per_metre" % [_size0, MAX_TABLE_SIZE]
		_failed = true
		return false
	_failed = false
	top_mip = 0
	var mip := 1
	while (_size0 >> mip) >= 1:
		var spanned := maxi((_last0.x >> mip) - (_origin0.x >> mip), (_last0.y >> mip) - (_origin0.y >> mip)) + 1
		if spanned > (_size0 >> mip): break
		top_mip = mip
		mip += 1
	_slot_size = page_size + 2 * BORDER
	var per_side_max := MAX_ATLAS_SIZE / _slot_size
	_layers = ceili(float(slots) / float(per_side_max * per_side_max))
	_slots_per_side = ceili(sqrt(float(slots) / float(_layers)))
	pool_pages = _layers * _slots_per_side * _slots_per_side
	resolution = _slots_per_side * _slot_size
	levels = top_mip + 1
	_pinned.clear()
	var pinned_count := 0
	for m in range(top_mip, -1, -1):
		var count := ((_last0.x >> m) - (_origin0.x >> m) + 1) * ((_last0.y >> m) - (_origin0.y >> m) + 1)
		if pinned_count + count > PINNED_PAGES: break
		pinned_count += count
		for y in range(_origin0.y >> m, (_last0.y >> m) + 1):
			for x in range(_origin0.x >> m, (_last0.x >> m) + 1):
				_pinned.append(Vector3i(x - (_origin0.x >> m), y - (_origin0.y >> m), m))
	_drop_all()
	_textures_dirty = true
	_table_dirty = true
	stats.levels = levels
	stats.resolution = resolution
	stats.page_size = page_size
	stats.pool_pages = pool_pages
	stats.table_size = _size0
	stats.memory_mb = (_layers * resolution * resolution * 13.0 + _size0 * _size0 * 2.0 * 4.0 / 3.0) / 1048576.0
	return true


## Sets the terrain-local base height range ([param minimum], [param maximum]) the height atlas
## encodes, snapped outward to HEIGHT_RANGE_STEP with a metre of margin. A change marks every
## page stale (each keeps its content, read with the new range, until refilled).
func set_height_range(minimum: float, maximum: float) -> void:
	if not is_finite(minimum) or not is_finite(maximum): return
	var low := floorf((minf(minimum, maximum) - 1.0) / HEIGHT_RANGE_STEP) * HEIGHT_RANGE_STEP
	var high := ceilf((maxf(minimum, maximum) + 1.0) / HEIGHT_RANGE_STEP) * HEIGHT_RANGE_STEP
	stats.height_step_mm = (high - low) / 65534.0 * 1000.0
	if low == height_min and high - low == height_range: return
	height_min = low
	height_range = high - low
	invalidate()


## Decoding of the height atlas's base height: x the height at t = 0, y the range.
func height_decode() -> Vector2:
	return Vector2(height_min, height_range)


static func _floor_div(a: int, b: int) -> int:
	return floori(float(a) / float(b))


func _drop_all() -> void:
	_resident.clear()
	_dirty.clear()
	_asked.clear()
	_awaiting.clear()
	_slot_key.resize(pool_pages)
	_slot_key.fill(null)
	_slot_used.resize(pool_pages)
	_slot_used.fill(-1000)
	_free.clear()
	for slot in range(pool_pages - 1, -1, -1): _free.append(slot)


## Shader parameters of the lookup: vt_params (mip 0 texel in metres, page size, border, top mip)
## and vt_layout (first page of mip 0, table size at mip 0, slots per atlas side).
func lookup_params() -> Vector4:
	return Vector4(texel, page_size, BORDER, top_mip)


func lookup_layout() -> Vector4i:
	return Vector4i(_origin0.x, _origin0.y, _size0, _slots_per_side)


## Cell edge (m) of a mip.
func level_texel(level: int) -> float:
	return texel * float(1 << level)


## The lod bias every lookup uses (the terrain's shading, the feedback pass, readers of the
## published cache): lod_bias plus the pool pressure, in steps of an eighth of a mip.
func effective_lod_bias() -> float:
	return lod_bias + snappedf(pressure_bias, 0.125)


## The page of [param mip] holding a terrain-local XZ position, as its page table texel and
## mip (the key pages are known by). Outside the terrain the texel is outside the mip's table
## ((table size at mip 0) >> mip texels per side).
func page_key(position: Vector2, mip: int) -> Vector3i:
	var size := level_texel(mip) * page_size
	return Vector3i(floori(position.x / size) - (_origin0.x >> mip), floori(position.y / size) - (_origin0.y >> mip), mip)


## A page key as the feedback pass reports it: mip << 28 | table y << 14 | table x.
static func request_key(page: Vector3i) -> int:
	return (page.z << 28) | (page.y << 14) | page.x


## The page key of a reported request (a 32-bit value that may arrive sign-extended).
static func request_page(key: int) -> Vector3i:
	var bits := key & 0xFFFFFFFF
	return Vector3i(bits & 0x3FFF, (bits >> 14) & 0x3FFF, bits >> 28)


## Terrain-local rectangle of a page.
func page_rect(key: Vector3i) -> Rect2:
	var size := level_texel(key.z) * page_size
	var page := Vector2i(key.x + (_origin0.x >> key.z), key.y + (_origin0.y >> key.z))
	return Rect2(Vector2(page) * size, Vector2.ONE * size)


## Marks terrain-local [param rect] stale in every resident page, or every page when empty.
## Content stays readable until refilled.
func invalidate(rect := Rect2()) -> void:
	if not rect.has_area():
		for key: Vector3i in _resident: _dirty[key] = true
		return
	for key: Vector3i in _resident:
		# The border and the corner heights read one cell beyond the page.
		if page_rect(key).grow(level_texel(key.z) * (BORDER + 1)).intersects(rect): _dirty[key] = true


## Surface writers changed over terrain-local [param rect] (everywhere when empty): the pages
## there are evaluated again, keeping their content until then, and tiles being drawn for them
## are drawn again.
func invalidate_writers(rect: Rect2) -> void:
	invalidate(rect)
	var everywhere := not rect.has_area()
	for key: Vector3i in _awaiting:
		if everywhere or page_rect(key).grow(level_texel(key.z) * (BORDER + 1)).intersects(rect): _awaiting[key] = -1


## Material uniforms changed: re-read them on the next update and refill when they differ.
func mark_material_dirty() -> void:
	_parameter_dirty = true


# ─────────────────────────────────────────────
# Main thread
# ─────────────────────────────────────────────

## The cells of a page's slot (the page and its border) at its mip.
func _slot_cells(key: Vector3i) -> Rect2i:
	var page := Vector2i(key.x + (_origin0.x >> key.z), key.y + (_origin0.y >> key.z))
	return Rect2i(page * page_size - Vector2i(BORDER, BORDER), Vector2i(_slot_size, _slot_size))


## The page whose slot starts at [param first] cell of [param mip].
func _key_of_slot_cells(mip: int, first: Vector2i) -> Vector3i:
	var page := (first + Vector2i(BORDER, BORDER)) / page_size if first.x + BORDER >= 0 and first.y + BORDER >= 0 else Vector2i(_floor_div(first.x + BORDER, page_size), _floor_div(first.y + BORDER, page_size))
	return Vector3i(page.x - (_origin0.x >> mip), page.y - (_origin0.y >> mip), mip)


## The slot of a page, taking a free one or evicting the least recently requested page for it
## (not those requested within the on-screen frames). -1 when none can go.
func _acquire_slot(key: Vector3i, updates: Array) -> int:
	var slot := -1
	if _resident.has(key):
		slot = _resident[key]
	elif not _free.is_empty():
		slot = _free.pop_back()
	else:
		if _evictable_frame != _frame:
			_evictable_frame = _frame
			_evictable.clear()
			for candidate in pool_pages:
				if _slot_used[candidate] <= _frame - _on_screen_frames: _evictable.append(candidate)
			_evictable.sort_custom(func(a: int, b: int) -> bool: return _slot_used[a] > _slot_used[b])
		if _evictable.is_empty():
			stats.thrash = int(stats.get("thrash", 0)) + 1
			return -1
		slot = _evictable.pop_back()
		var old: Vector3i = _slot_key[slot]
		_resident.erase(old)
		_dirty.erase(old)
		updates.append([old.z, Vector2i(old.x, old.y), 0.0])
	if not _resident.has(key):
		_resident[key] = slot
		_slot_key[slot] = key
		updates.append([key.z, Vector2i(key.x, key.y), float(slot + 1) / 65535.0])
	_slot_used[slot] = _frame
	return slot


func _work_item(key: Vector3i, slot: int) -> Array:
	var per_layer := _slots_per_side * _slots_per_side
	var in_layer := slot % per_layer
	return [key.z, _slot_cells(key).position, slot / per_layer, Vector2i(in_layer % _slots_per_side, in_layer / _slots_per_side) * _slot_size]


## Appends the pages of [param mip] that touch the square of half-size [param reach] metres
## around [param camera] (terrain-local).
func _append_square(wanted: Array[Vector3i], mip: int, camera: Vector3, reach: float) -> void:
	var size := level_texel(mip) * page_size
	var origin := Vector2i(_origin0.x >> mip, _origin0.y >> mip)
	var last := Vector2i(_last0.x >> mip, _last0.y >> mip)
	var first_page := Vector2i(floori((camera.x - reach) / size), floori((camera.z - reach) / size))
	var last_page := Vector2i(floori((camera.x + reach) / size), floori((camera.z + reach) / size))
	for y in range(maxi(first_page.y, origin.y), mini(last_page.y, last.y) + 1):
		for x in range(maxi(first_page.x, origin.x), mini(last_page.x, last.x) + 1):
			wanted.append(Vector3i(x - origin.x, y - origin.y, mip))


## Reads the terrain's [param material] when it changed (the StrataRenderer ShaderMaterial;
## [param defines] its variant defines), takes this frame's requests (the feedback keys, or the squares around [param camera],
## terrain-local, without feedback), evicts the least recently requested pages for new ones and
## records the fills and page table updates on the render thread. True when every requested
## page is resident and current.
func update(material: ShaderMaterial, defines: String, camera: Vector3, writers: Node = null) -> bool:
	if _failed or material == null or material.shader == null or _layout_key.is_empty(): return false
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
		if _rd == null:
			_failed = true
			stats.status = "No RenderingDevice (Compatibility renderer or headless)"
			return false
	if _reset_requested:
		_reset_requested = false
		_drop_all()
		_table_dirty = true
	if _parameter_dirty:
		_parameter_dirty = false
		_gather_material(material)
	if defines != _defines:
		_defines = defines
		_refill = true
	if _refill:
		_refill = false
		invalidate()
	_frame += 1
	var wanted: Array[Vector3i] = []
	wanted.append_array(_pinned)
	if feedback_active:
		for raw in feedback_keys:
			var key := request_page(raw)
			var side := maxi(_size0 >> key.z, 1)
			if key.z <= top_mip and key.x < side and key.y < side: wanted.append(key)
		if relief_mip >= 0 and relief_mip <= top_mip and relief_radius > 0.0:
			_append_square(wanted, relief_mip, camera, relief_radius)
	else:
		for mip in top_mip + 1: _append_square(wanted, mip, camera, ring_cells * level_texel(mip))
	stats.feedback_keys = feedback_keys.size()
	feedback_keys = PackedInt32Array()
	_on_screen_frames = _ON_SCREEN_FEEDBACK if feedback_active else _ON_SCREEN_SQUARES
	var on_screen := 0
	for slot in pool_pages:
		if _slot_key[slot] != null and _slot_used[slot] > _frame - _on_screen_frames: on_screen += 1
	for key: Vector3i in _asked:
		if not _resident.has(key): on_screen += 1
	var demand := float(on_screen) / float(maxi(pool_pages, 1))
	if demand > _PRESSURE_ABOVE:
		if _frame >= _pressure_hold: pressure_bias = minf(pressure_bias + _PRESSURE_RISE, _PRESSURE_MAX)
	elif demand < _PRESSURE_BELOW: pressure_bias = maxf(pressure_bias - _PRESSURE_FALL, 0.0)
	stats.pressure_bias = pressure_bias
	var pressure_step := snappedf(pressure_bias, 0.125)
	if pressure_step > _pressure_step:
		# Lookups read coarser mips now: the finer pages asked for before are not wanted any more.
		_asked.clear()
		_awaiting.clear()
		_pressure_hold = _frame + _on_screen_frames
	_pressure_step = pressure_step
	for key in wanted:
		if _resident.has(key):
			_slot_used[_resident[key]] = _frame
			if _dirty.has(key): _asked[key] = _frame
		else:
			_asked[key] = _frame
	# Coarse pages first (a lookup falls back to them while finer ones are missing), then the
	# most recently requested.
	var missing: Array[Vector3i] = []
	for key: Vector3i in _asked.keys():
		if _frame - int(_asked[key]) > PENDING_FRAMES:
			_asked.erase(key)
			_awaiting.erase(key)
		else:
			missing.append(key)
	missing.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return a.z > b.z if a.z != b.z else int(_asked[a]) > int(_asked[b]))
	var work := []
	var updates := []
	var sets := {}
	if writers != null:
		writers.call("drop_pages", func(level: int, cells: Rect2i) -> bool: return _awaiting.has(_key_of_slot_cells(level, cells.position)))
		# Tiles drawn since they were dispatched: their pages are evaluated with them.
		for tile: Array in writers.call("take_ready"):
			var key := _key_of_slot_cells(int(tile[0]), (tile[1] as Rect2i).position)
			if not _awaiting.has(key): continue
			if int(_awaiting[key]) < 0:
				# The writers changed while the tile was drawn.
				if writers.call("queue_rect", key.z, _slot_cells(key)): _awaiting[key] = _frame
				else: _awaiting.erase(key)
				continue
			_awaiting.erase(key)
			var slot := _acquire_slot(key, updates)
			if slot < 0: continue
			_dirty.erase(key)
			_asked.erase(key)
			var item := _work_item(key, slot)
			item.append_array([int(tile[3]), tile[2], int(tile[4])])
			work.append(item)
			if not sets.has(int(tile[3])): sets[int(tile[3])] = writers.call("set_texture", int(tile[3]))
	var fills := 0
	var scanned := 0
	for key in missing:
		if _awaiting.has(key) or not _asked.has(key): continue
		scanned += 1
		if scanned > _MAX_SCANNED: break
		if writers != null and writers.call("overlaps", key.z, _slot_cells(key)):
			# With its writers, once the pass has drawn them.
			if _awaiting.size() < _MAX_AWAITING and writers.call("queue_rect", key.z, _slot_cells(key)): _awaiting[key] = _frame
			continue
		if fills >= page_fills_per_frame: continue
		var slot := _acquire_slot(key, updates)
		if slot < 0: break
		_dirty.erase(key)
		_asked.erase(key)
		fills += 1
		work.append(_work_item(key, slot))
	if writers != null: writers.call("dispatch")
	stats.awaiting_writers = _awaiting.size()
	stats.texels_last_frame = work.size() * _slot_size * _slot_size
	stats.dispatches_last_frame = work.size()
	stats.resident = _resident.size()
	stats.requested = wanted.size()
	stats.missing = missing.size() - work.size()
	if not work.is_empty() or not updates.is_empty() or _textures_dirty or _table_dirty:
		_timestamp_frame += 1
		var request := {"work": work, "updates": updates, "sets": sets, "maps": _maps.duplicate(), "bytes": _parameter_bytes, "defines": defines, "allocate": _textures_dirty, "allocate_table": _table_dirty, "layers": _layers, "resolution": resolution, "slot": _slot_size, "table_size": _size0, "mips": top_mip + 1, "texel": texel, "measure": measure_gpu, "stamp": _timestamp_frame, "height_decode": height_decode()}
		_textures_dirty = false
		_table_dirty = false
		RenderingServer.call_on_render_thread(_render_update.bind(request))
	stats.status = "Ready" if int(stats.missing) == 0 else "Filling"
	return int(stats.missing) == 0


## Publishes the cache as the strata_cache_* global shader parameters (when publish_globals).
## [param terrain_transform] is the terrain node's global transform (translation/yaw).
func publish(terrain_transform: Transform3D, camera: Vector3, displacement_radius: float, displacement_strength: float, specular: float) -> void:
	if not publish_globals or _failed or _layout_key.is_empty():
		unpublish()
		return
	if not _globals_ready():
		stats.status = "Global shader parameters missing or outdated: enable the Strata plugin or call StrataSurfaceCache.register_project_globals()"
		return
	_globals_owner = true
	# Only changed values are sent: setting a global (a texture above all) dirties every
	# material that reads it.
	_set_global("strata_cache_page_table", page_table_texture)
	_set_global("strata_cache_albedo", albedo_texture)
	_set_global("strata_cache_normal", normal_texture)
	_set_global("strata_cache_height", height_texture)
	_set_global("strata_cache_params", lookup_params())
	_set_global("strata_cache_layout", lookup_layout())
	_set_global("strata_cache_camera", Vector4(camera.x, camera.y, camera.z, maxf(displacement_radius, 0.0)))
	_set_global("strata_cache_surface", Vector4(displacement_strength, specular, float(relief_mip), 1.0))
	_set_global("strata_cache_sampling", Vector4(effective_lod_bias(), 1.0 if bilinear_readers else 0.0, height_min, height_range))
	_set_global("strata_cache_world_to_local", terrain_transform.affine_inverse())


func _set_global(name: String, value: Variant) -> void:
	if _published.has(name) and _published[name] == value: return
	_published[name] = value
	RenderingServer.global_shader_parameter_set(name, value)


## Disables the published cache (readers fall back to their own shading).
func unpublish() -> void:
	if not _globals_owner or not _globals_ready(): return
	_globals_owner = false
	_set_global("strata_cache_surface", Vector4.ZERO)


## The global parameters exist when the project settings declare them with their current types
## (the renderer creates them from [shader_globals] at startup; the editor's list query is
## editor-only).
func _globals_ready() -> bool:
	if _globals_checked < 0:
		_globals_checked = 1
		for name: String in GLOBAL_PARAMETERS:
			var current: Variant = ProjectSettings.get_setting("shader_globals/" + name, null)
			if not (current is Dictionary) or str((current as Dictionary).get("type", "")) != _global_type_name(int(GLOBAL_PARAMETERS[name])): _globals_checked = 0
	return _globals_checked == 1


## Frees the GPU resources and drops every page.
func release() -> void:
	unpublish()
	var table_rids: Array[RID] = []
	table_rids.append_array(_table_sets)
	table_rids.append_array(_table_views)
	table_rids.append_array([_table_pipeline, _table_shader, _table])
	_table_sets = []; _table_views = []; _table_pipeline = RID(); _table_shader = RID(); _table = RID()
	_table_dirty = true
	# Dependents first: the uniform set, then the pipeline before its shader.
	var rids: Array[RID] = [_uniform_set, _pipeline, _shader, _params]
	# Writer tile sets are freed with the shader they were made for.
	_writer_sets = {}
	_writer_fallback_set = RID()
	rids.append_array(_textures)
	rids.append_array(_samplers)
	rids.append_array(_fallbacks)
	_fallbacks = []
	_textures = []; _samplers = []; _uniform_set = RID(); _params = RID(); _pipeline = RID(); _shader = RID()
	_shader_key = ""; _sampler_key = ""; _uniform_key = ""
	_textures_dirty = true
	_layout_key = ""
	_drop_all()
	if _rd == null: return
	if table_rids.any(func(rid: RID) -> bool: return rid.is_valid()):
		RenderingServer.call_on_render_thread(_free_table.bind(table_rids, page_table_texture))
	if rids.any(func(rid: RID) -> bool: return rid.is_valid()):
		RenderingServer.call_on_render_thread(_free_rids.bind(rids, [albedo_texture, normal_texture, height_texture, cover_texture]))


func _parameter(material: ShaderMaterial, name: String) -> Variant:
	var value: Variant = material.get_shader_parameter(name)
	if value == null:
		value = RenderingServer.shader_get_parameter_default(material.shader.get_rid(), name)
	return value


## Reads the material's uniforms into the parameter buffer bytes and texture list; requests a
## refill of every page when anything the cache depends on changed.
func _gather_material(material: ShaderMaterial) -> void:
	var bytes := PackedByteArray()
	bytes.resize((_MATERIAL_ARRAYS.size() * 32 + 64) * 4)
	var offset := 0
	for name: String in _MATERIAL_ARRAYS:
		var values: Variant = _parameter(material, name)
		for i in 32:
			var value: Variant = values[i] if (values is PackedFloat32Array or values is PackedInt32Array or values is Array) and i < values.size() else 0
			if name in _INT_ARRAYS: bytes.encode_s32(offset + i * 4, int(value))
			else: bytes.encode_float(offset + i * 4, float(value))
		offset += 128
	var float_base := offset
	var int_base := offset + 128
	for name: String in _FLOAT_SLOTS:
		var value: Variant = _parameter(material, name)
		var slot := int(_FLOAT_SLOTS[name])
		if name in _VECTOR_UNIFORMS:
			var vector := Vector2(value) if value != null else Vector2.ZERO
			bytes.encode_float(float_base + slot * 4, vector.x); bytes.encode_float(float_base + slot * 4 + 4, vector.y)
		else:
			bytes.encode_float(float_base + slot * 4, float(value) if value != null else 0.0)
	for name: String in _INT_SLOTS:
		var value: Variant = _parameter(material, name)
		var slot := int(_INT_SLOTS[name])
		if name in _VECTOR_UNIFORMS:
			var vector := Vector2i(value) if value != null else Vector2i.ZERO
			bytes.encode_s32(int_base + slot * 4, vector.x); bytes.encode_s32(int_base + slot * 4 + 4, vector.y)
		else:
			bytes.encode_s32(int_base + slot * 4, int(value) if value != null else 0)
	var maps := {}
	var identity := PackedStringArray()
	for name: String in ["color_maps", "normal_maps", "ormh_maps"]:
		var list: Variant = _parameter(material, name)
		var rids: Array[RID] = []
		for i in 32:
			var texture: Texture = list[i] if list is Array and i < list.size() and list[i] is Texture else null
			rids.append(texture.get_rid() if texture != null else RID())
			identity.append(str(texture.get_rid().get_id()) if texture != null else "-")
		maps[name] = rids
	for entry: Array in _MAP_BINDINGS:
		var texture: Variant = _parameter(material, entry[0])
		maps[entry[0]] = (texture as Texture).get_rid() if texture is Texture else RID()
		identity.append(str(maps[entry[0]].get_id()))
	var signature := "%s|%s" % [bytes.hex_encode(), ",".join(identity)]
	_maps = maps
	_parameter_bytes = bytes
	if signature != _material_signature:
		_material_signature = signature
		_refill = true


# ─────────────────────────────────────────────
# Render thread
# ─────────────────────────────────────────────

func _render_update(request: Dictionary) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null: return
	if request.allocate or _textures.is_empty():
		_allocate(rd, int(request.layers), int(request.resolution))
	if request.allocate_table or not _table.is_valid():
		_allocate_table(rd, int(request.table_size), int(request.mips))
	var work: Array = request.work
	var updates: Array = request.updates
	if work.is_empty() and updates.is_empty(): return
	if not work.is_empty():
		if not _ensure_pipeline(rd, String(request.defines)): return
		var params_size := (request.bytes as PackedByteArray).size()
		if _params.is_valid() and _params_size != params_size:
			rd.free_rid(_params)
			_params = RID()
		if not _params.is_valid():
			_params = rd.storage_buffer_create(params_size, request.bytes)
			_params_size = params_size
		else:
			rd.buffer_update(_params, 0, params_size, request.bytes)
		if not _ensure_uniform_set(rd, request.maps):
			# A map is not uploaded yet: the main thread drops every page and asks again.
			_reset_requested = true
			return
		if bool(request.get("measure", false)): _read_timestamps(rd)
		var writer_sets := {}
		for index: int in request.sets:
			var set_rid := _writer_set(rd, index, request.sets[index])
			if set_rid.is_valid(): writer_sets[index] = set_rid
		var fallback := _writer_fallback(rd)
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, _pipeline)
		rd.compute_list_bind_uniform_set(list, _uniform_set, 0)
		var bound := RID()
		var stamp := "StrataSurfaceCache fill %d" % int(request.get("stamp", 0))
		if bool(request.get("measure", false)): rd.capture_timestamp(stamp + " begin")
		var slot := int(request.slot)
		var height_decode: Vector2 = request.height_decode
		for item: Array in work:
			var mip := int(item[0])
			var first: Vector2i = item[1]
			var store: Vector2i = item[3]
			var writer_set: RID = writer_sets.get(int(item[4]), RID()) if item.size() > 4 else RID()
			var set_rid := writer_set if writer_set.is_valid() else fallback
			if set_rid != bound:
				rd.compute_list_bind_uniform_set(list, set_rid, 1)
				bound = set_rid
			var push := PackedByteArray()
			push.resize(64)
			push.encode_s32(0, first.x); push.encode_s32(4, first.y)
			push.encode_s32(8, slot); push.encode_s32(12, slot)
			push.encode_s32(16, mip); push.encode_s32(20, int(item[2]))
			push.encode_float(24, float(request.texel) * float(1 << mip)); push.encode_s32(28, 1 if writer_set.is_valid() else 0)
			if writer_set.is_valid():
				var tile_origin: Vector2i = item[5]
				push.encode_s32(32, tile_origin.x); push.encode_s32(36, tile_origin.y)
				push.encode_s32(40, int(item[6]))
			push.encode_s32(48, store.x); push.encode_s32(52, store.y)
			push.encode_float(56, height_decode.x); push.encode_float(60, height_decode.y)
			rd.compute_list_set_push_constant(list, push, push.size())
			rd.compute_list_dispatch(list, ceili(slot / 8.0), ceili(slot / 8.0), 1)
		rd.compute_list_end()
		if bool(request.get("measure", false)): rd.capture_timestamp(stamp + " end")
	if updates.is_empty() or not _table_pipeline.is_valid(): return
	var table_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(table_list, _table_pipeline)
	for entry: Array in updates:
		var mip := int(entry[0])
		if mip >= _table_sets.size(): continue
		var at: Vector2i = entry[1]
		var push := PackedByteArray()
		push.resize(16)
		push.encode_s32(0, at.x); push.encode_s32(4, at.y)
		push.encode_float(8, float(entry[2]))
		rd.compute_list_bind_uniform_set(table_list, _table_sets[mip], 0)
		rd.compute_list_set_push_constant(table_list, push, push.size())
		rd.compute_list_dispatch(table_list, 1, 1, 1)
	rd.compute_list_end()


## GPU time of fills recorded in an earlier frame (the device reports the frame before last).
func _read_timestamps(rd: RenderingDevice) -> void:
	var begins := {}
	for i in rd.get_captured_timestamps_count():
		var name := rd.get_captured_timestamp_name(i)
		if not name.begins_with("StrataSurfaceCache fill "): continue
		var key := name.trim_suffix(" begin").trim_suffix(" end")
		if name.ends_with(" begin"): begins[key] = rd.get_captured_timestamp_gpu_time(i)
		elif begins.has(key):
			var ms := float(rd.get_captured_timestamp_gpu_time(i) - int(begins[key])) / 1000000.0
			stats.gpu_ms = ms
			stats.gpu_ms_total = float(stats.gpu_ms_total) + ms
			stats.gpu_samples = int(stats.gpu_samples) + 1


## Uniform set 1 for a writer tile: its viewport texture (the RD texture resolved now, so a
## reallocated viewport rebinds).
func _writer_set(rd: RenderingDevice, index: int, texture: RID) -> RID:
	var rd_rid := RenderingServer.texture_get_rd_texture(texture)
	if not rd_rid.is_valid(): return RID()
	var joined := str(rd_rid.get_id()) + "|" + str(_shader.get_id())
	var cached: Array = _writer_sets.get(index, [])
	if not cached.is_empty() and cached[0] == joined and rd.uniform_set_is_valid(cached[1]): return cached[1]
	if not cached.is_empty() and rd.uniform_set_is_valid(cached[1]): rd.free_rid(cached[1])
	var rid := _texture_set(rd, rd_rid)
	_writer_sets[index] = [joined, rid]
	return rid


## Uniform set 1 for plain fills: blank textures (fill.writers is 0, so they are not read).
func _writer_fallback(rd: RenderingDevice) -> RID:
	if _writer_fallback_set.is_valid() and rd.uniform_set_is_valid(_writer_fallback_set): return _writer_fallback_set
	_writer_fallback_set = _texture_set(rd, _fallback_texture(rd, false))
	return _writer_fallback_set


func _texture_set(rd: RenderingDevice, texture: RID) -> RID:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = 0
	uniform.add_id(_samplers[1])
	uniform.add_id(texture)
	return rd.uniform_set_create([uniform], _shader, 1)


## The atlases: [param layer_count] layers of [param cells]² texels.
func _allocate(rd: RenderingDevice, layer_count: int, cells: int) -> void:
	_uniform_set = RID()
	_uniform_key = ""
	var wrappers := [albedo_texture, normal_texture, height_texture, cover_texture]
	# The wrappers keep their rendering-server texture (materials hold its RID) and swap what it
	# shows when reassigned below, which may already free the old RenderingDevice textures:
	# only those still valid afterwards are freed here.
	var old_textures := _textures
	_textures = []
	var formats := [RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, RenderingDevice.DATA_FORMAT_R16G16_UNORM, RenderingDevice.DATA_FORMAT_R8_UNORM]
	var layers := [layer_count, layer_count, layer_count, layer_count]
	for i in 4:
		var format := RDTextureFormat.new()
		format.format = formats[i]
		format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
		format.width = cells
		format.height = cells
		format.array_layers = layers[i]
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		var rid := rd.texture_create(format, RDTextureView.new(), [])
		_textures.append(rid)
		(wrappers[i] as Texture2DArrayRD).texture_rd_rid = rid
	for rid: RID in old_textures:
		if rid.is_valid() and rd.texture_is_valid(rid): rd.free_rid(rid)


func _allocate_table(rd: RenderingDevice, size: int, mips: int) -> void:
	for rid: RID in _table_sets:
		if rid.is_valid() and rd.uniform_set_is_valid(rid): rd.free_rid(rid)
	for rid: RID in _table_views:
		if rid.is_valid() and rd.texture_is_valid(rid): rd.free_rid(rid)
	_table_sets = []; _table_views = []
	var old := _table
	if not _table_pipeline.is_valid():
		var source := RDShaderSource.new()
		source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
		source.source_compute = _TABLE_GLSL
		var spirv := rd.shader_compile_spirv_from_source(source)
		if not spirv.compile_error_compute.is_empty():
			push_error("StrataSurfaceCache: page table shader: " + spirv.compile_error_compute)
			_failed = true
			return
		_table_shader = rd.shader_create_from_spirv(spirv, "StrataSurfaceCacheTable")
		_table_pipeline = rd.compute_pipeline_create(_table_shader)
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R16_UNORM
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.width = size
	format.height = size
	format.mipmaps = mips
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_table = rd.texture_create(format, RDTextureView.new(), [])
	rd.texture_clear(_table, Color(0, 0, 0, 0), 0, mips, 0, 1)
	for mip in mips:
		var view := rd.texture_create_shared_from_slice(RDTextureView.new(), _table, 0, mip, 1, RenderingDevice.TEXTURE_SLICE_2D)
		_table_views.append(view)
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		uniform.binding = 0
		uniform.add_id(view)
		_table_sets.append(rd.uniform_set_create([uniform], _table_shader, 0))
	page_table_texture.texture_rd_rid = _table
	if old.is_valid() and rd.texture_is_valid(old): rd.free_rid(old)


func _ensure_pipeline(rd: RenderingDevice, defines: String) -> bool:
	if _shader_key == defines and _pipeline.is_valid(): return true
	if _shader.is_valid(): rd.free_rid(_shader)
	_shader = RID(); _pipeline = RID(); _uniform_set = RID(); _uniform_key = ""
	# Sets made for the old shader went with it.
	_writer_sets = {}; _writer_fallback_set = RID()
	_shader_key = defines
	var code := "#version 450\n" + defines + _GLSL_PRELUDE
	for name: String in _INCLUDES:
		var include := load(_SHADER_DIR + name + ".gdshaderinc") as ShaderInclude
		if include == null:
			push_error("StrataSurfaceCache: missing shader include %s" % name)
			_failed = true
			return false
		code += "\n// ---- %s ----\n" % name + include.code
	code += _GLSL_MAIN.replace("%RELIEF_RANGE%", "%.3f" % RELIEF_RANGE)
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = code
	var spirv := rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		push_error("StrataSurfaceCache: compute shader: " + spirv.compile_error_compute)
		_failed = true
		return false
	_shader = rd.shader_create_from_spirv(spirv, "StrataSurfaceCache")
	_pipeline = rd.compute_pipeline_create(_shader)
	return _pipeline.is_valid()


func _ensure_samplers(rd: RenderingDevice, pixel: bool) -> void:
	var key := "pixel" if pixel else "linear"
	if key == _sampler_key and not _samplers.is_empty(): return
	for rid: RID in _samplers: rd.free_rid(rid)
	_samplers = []
	_sampler_key = key
	# 0 material (nearest or linear with mipmaps, repeating), 1 nearest clamp, 2 linear clamp.
	var states := []
	var material := RDSamplerState.new()
	material.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST if pixel else RenderingDevice.SAMPLER_FILTER_LINEAR
	material.min_filter = material.mag_filter
	material.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	material.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	material.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	material.max_lod = 1000.0
	states.append(material)
	for filter in [RenderingDevice.SAMPLER_FILTER_NEAREST, RenderingDevice.SAMPLER_FILTER_LINEAR]:
		var state := RDSamplerState.new()
		state.mag_filter = filter
		state.min_filter = filter
		state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		states.append(state)
	for state: RDSamplerState in states:
		_samplers.append(rd.sampler_create(state))


## Binds the maps' current RenderingDevice textures; false when one is not available yet.
func _ensure_uniform_set(rd: RenderingDevice, maps: Dictionary) -> bool:
	_ensure_samplers(rd, _shader_key.contains("STRATA_PIXEL_SAMPLING"))
	var resolved := {}
	var key := PackedStringArray()
	for name: String in ["color_maps", "normal_maps", "ormh_maps"]:
		var list: Array[RID] = []
		for rid: RID in maps[name]:
			var rd_rid := RenderingServer.texture_get_rd_texture(rid, name == "color_maps") if rid.is_valid() else RID()
			if name == "color_maps" and rid.is_valid() and not rd_rid.is_valid():
				rd_rid = RenderingServer.texture_get_rd_texture(rid, false)
			if not rd_rid.is_valid(): return false
			list.append(rd_rid)
			key.append(str(rd_rid.get_id()))
		resolved[name] = list
	for entry: Array in _MAP_BINDINGS:
		var rid: RID = maps[entry[0]]
		var rd_rid := RID()
		if rid.is_valid():
			rd_rid = RenderingServer.texture_get_rd_texture(rid)
			if not rd_rid.is_valid(): return false
		else:
			# Unbound map (no far tier, coarse maps or holes): a blank stand-in, as Godot binds
			# for an unset sampler; the parameter flags keep the shader from reading it.
			rd_rid = _fallback_texture(rd, String(entry[0]).ends_with("_regions"))
		resolved[entry[0]] = rd_rid
		key.append(str(rd_rid.get_id()))
	for rid: RID in _textures: key.append(str(rid.get_id()))
	key.append(str(_params.get_id()))
	key.append(_sampler_key)
	var joined := ",".join(key)
	if joined == _uniform_key and _uniform_set.is_valid() and rd.uniform_set_is_valid(_uniform_set): return true
	if _uniform_set.is_valid() and rd.uniform_set_is_valid(_uniform_set): rd.free_rid(_uniform_set)
	var uniforms: Array[RDUniform] = []
	var binding := 0
	for name: String in ["color_maps", "normal_maps", "ormh_maps"]:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		uniform.binding = binding
		for rd_rid: RID in resolved[name]:
			uniform.add_id(_samplers[0])
			uniform.add_id(rd_rid)
		uniforms.append(uniform)
		binding += 1
	for entry: Array in _MAP_BINDINGS:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		uniform.binding = binding
		uniform.add_id(_samplers[1 + int(entry[1])])
		uniform.add_id(resolved[entry[0]])
		uniforms.append(uniform)
		binding += 1
	var buffer := RDUniform.new()
	buffer.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	buffer.binding = binding
	buffer.add_id(_params)
	uniforms.append(buffer)
	binding += 1
	for rid: RID in _textures:
		var image := RDUniform.new()
		image.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		image.binding = binding
		image.add_id(rid)
		uniforms.append(image)
		binding += 1
	_uniform_set = rd.uniform_set_create(uniforms, _shader, 0)
	_uniform_key = joined
	return _uniform_set.is_valid()


## A 1x1 blank RGBA8 texture (2D, or a one-layer 2D array) for unbound map bindings.
func _fallback_texture(rd: RenderingDevice, array: bool) -> RID:
	var index := 1 if array else 0
	if _fallbacks.size() < 2: _fallbacks = [RID(), RID()]
	if _fallbacks[index].is_valid(): return _fallbacks[index]
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY if array else RenderingDevice.TEXTURE_TYPE_2D
	format.width = 1
	format.height = 1
	format.array_layers = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var blank := PackedByteArray([0, 0, 0, 0])
	_fallbacks[index] = rd.texture_create(format, RDTextureView.new(), [blank])
	return _fallbacks[index]


static func _free_rids(rids: Array[RID], wrappers: Array) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null: return
	for wrapper: Texture2DArrayRD in wrappers: wrapper.texture_rd_rid = RID()
	# The uniform set may already be gone with a texture it used (freed by a reallocation).
	if rids[0].is_valid() and not rd.uniform_set_is_valid(rids[0]): rids[0] = RID()
	for rid: RID in rids:
		if rid.is_valid(): rd.free_rid(rid)


## Frees the page table's sets, views, pipeline, shader and texture, in that order.
static func _free_table(rids: Array[RID], wrapper: Texture2DRD) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null: return
	wrapper.texture_rd_rid = RID()
	for rid: RID in rids:
		if rid.is_valid(): rd.free_rid(rid)
