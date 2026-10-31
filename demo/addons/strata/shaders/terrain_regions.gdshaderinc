// Region addressing (docs/development/terrain_renderer_regions.md). Every composed map
// lives in a Texture2DArray with one layer per resident region; region_table maps a
// region index to its layer. A position is clamped to the terrain, split into a region
// index and a metre offset inside it, and the offset becomes a texel of that region's
// layer: texel = offset / (region_spacing * scale) + apron.
//
// Needs, declared by the including shader before this file: field_size, region_origin,
// region_extent, region_spacing, region_cells, region_grid, region_lattice, region_table,
// the <map>_regions arrays and their <map>_scale / <map>_apron, has_material_maps.

// True and the array layer for a resident region.
bool terrain_region_layer(ivec2 region, out int layer) {
	ivec4 entry = ivec4(texelFetch(region_table, region, 0) * 255.0 + vec4(0.5));
	layer = entry.r + entry.g * 256;
	return entry.a != 0;
}

// Region of a terrain position (clamped to the terrain edge) and the metres inside it.
ivec2 terrain_region_locate(vec2 position, out vec2 local) {
	vec2 relative = clamp(position - region_origin, vec2(0.0), field_size);
	ivec2 region = clamp(ivec2(floor(relative / region_extent)), ivec2(0), region_grid - ivec2(1));
	local = relative - vec2(region) * region_extent;
	return region;
}

// Layer coordinates of a sample-map lattice index (sample 0 at the terrain origin, one
// index per spacing * scale metres). Shared region edges resolve to the higher region.
ivec3 terrain_lattice_address(ivec2 index, int scale, int apron, out bool resident) {
	int per_region = region_cells / scale;
	ivec2 region = clamp(index / per_region, ivec2(0), region_grid - ivec2(1));
	int layer;
	resident = terrain_region_layer(region, layer);
	return ivec3(index - region * per_region + ivec2(apron), layer);
}

ivec2 terrain_lattice_max_for(int scale) { return (region_lattice + ivec2(scale - 1)) / scale; }

// ---- host interface of terrain_normals.gdshaderinc ----
vec2 terrain_lattice_step() { return vec2(region_spacing * float(height_scale)); }
ivec2 terrain_lattice_max() { return terrain_lattice_max_for(height_scale); }

float terrain_texel_height(ivec2 index) {
	bool resident;
	ivec3 address = terrain_lattice_address(index, height_scale, height_apron, resident);
	return resident ? texelFetch(height_regions, address, 0).r : 0.0;
}

// Hardware bilinear inside one region; the apron keeps the filter footprint in the layer.
float terrain_linear_height(vec2 position) {
	vec2 local;
	ivec2 region = terrain_region_locate(position, local);
	int layer;
	if (!terrain_region_layer(region, layer)) { return 0.0; }
	vec2 texel = local / (region_spacing * float(height_scale)) + vec2(float(height_apron));
	vec2 size = vec2(textureSize(height_regions, 0).xy);
	return textureLod(height_regions, vec3((texel + vec2(0.5)) / size, float(layer)), 0.0).r;
}

// ---- host interface of terrain_controls.gdshaderinc ----
// One corner of the 2x2 control cell around the position: raw IDs and weights, and the
// cell fraction. The lattice is the control map's own (spacing * material_ids_scale).
void terrain_control_corner(vec2 position, ivec2 offset, out ivec4 ids, out vec4 weights, out vec2 fraction) {
	ids = ivec4(0); weights = vec4(0.0); fraction = vec2(0.0);
	if (!has_material_maps) { return; }
	vec2 step_size = vec2(region_spacing * float(material_ids_scale));
	ivec2 lattice_max = terrain_lattice_max_for(material_ids_scale);
	vec2 grid = clamp((position - region_origin) / step_size, vec2(0.0), vec2(lattice_max));
	ivec2 base = ivec2(floor(grid));
	fraction = fract(grid);
	ivec2 index = min(base + offset, lattice_max);
	bool resident;
	ivec3 address = terrain_lattice_address(index, material_ids_scale, material_ids_apron, resident);
	if (!resident) { return; }
	ids = ivec4(round(texelFetch(material_ids_regions, address, 0) * 255.0));
	weights = texelFetch(material_weights_regions, address, 0);
}

// Cell holes: one texel per cell of spacing * holes_scale, nearest.
bool terrain_cell_hole(vec2 position) {
	float cell_size = region_spacing * float(holes_scale);
	ivec2 cell_max = terrain_lattice_max_for(holes_scale) - ivec2(1);
	vec2 relative = clamp(position - region_origin, vec2(0.0), field_size);
	ivec2 cell = clamp(ivec2(floor(relative / cell_size)), ivec2(0), cell_max);
	int per_region = region_cells / holes_scale;
	ivec2 region = clamp(cell / per_region, ivec2(0), region_grid - ivec2(1));
	int layer;
	if (!terrain_region_layer(region, layer)) { return false; }
	return texelFetch(holes_regions, ivec3(cell - region * per_region + ivec2(holes_apron), layer), 0).r >= 0.5;
}

vec4 terrain_macro_sample(vec2 position) {
	if (!has_terrain_macro_map) { return vec4(1.0); }
	vec2 local;
	ivec2 region = terrain_region_locate(position, local);
	int layer;
	if (!terrain_region_layer(region, layer)) { return vec4(1.0); }
	vec2 texel = local / (region_spacing * float(macro_scale)) + vec2(float(macro_apron));
	vec2 size = vec2(textureSize(macro_regions, 0).xy);
	return textureLod(macro_regions, vec3((texel + vec2(0.5)) / size, float(layer)), 0.0);
}
