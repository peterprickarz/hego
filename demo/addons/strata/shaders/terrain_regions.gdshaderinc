// Region addressing (docs/development/terrain_renderer_regions.md). Every composed map
// lives in a Texture2DArray with one layer per bound region; region_table says, per region,
// which tier holds it and in which layer. A position is clamped to the terrain, split into a
// region index and a metre offset inside it, and the offset becomes a texel of that region's
// layer: texel = offset / (region_spacing * scale << level) + apron.
//
// Tiers (region_table texel: R/G slot low/high byte, B level, A flag 1 near / 2 far / 0 none;
// the Phase A layout writes 255 for near, so any value but 0 and 2 means near):
//   1 near    <map>_regions arrays, level 0
//   2 far     <map>_far_regions arrays, level far_level (the lattice is 1 << far_level coarser)
//   3 coarse  coarse_<map> terrain-wide images at coarse_level, no apron (clamped sampler);
//             drawn for every region without a tier when has_coarse_maps
//   0 none    nothing (height 0, no holes, no material)
// Where the lattice of a tier is coarser than the fine lattice a caller asks for, heights are
// bilinear samples of the coarser data and categorical maps use the nearest coarse texel.
//
// Needs, declared by the including shader before this file: field_size, region_origin,
// region_extent, region_spacing, region_cells, region_grid, region_lattice, region_table,
// the <map>_regions and <map>_far_regions arrays with <map>_scale / <map>_apron, the
// coarse_<map> samplers, far_level, coarse_level, has_far_tier, has_coarse_maps,
// has_material_maps.

// Tier of a region (see above) and its array layer.
int terrain_region_entry(ivec2 region, out int slot) {
	ivec4 entry = ivec4(texelFetch(region_table, region, 0) * 255.0 + vec4(0.5));
	slot = entry.r + entry.g * 256;
	if (entry.a == 2) { return has_far_tier ? 2 : (has_coarse_maps ? 3 : 0); }
	if (entry.a != 0) { return 1; }
	return has_coarse_maps ? 3 : 0;
}

// Region of a terrain position (clamped to the terrain edge) and the metres inside it.
ivec2 terrain_region_locate(vec2 position, out vec2 local) {
	vec2 relative = clamp(position - region_origin, vec2(0.0), field_size);
	ivec2 region = clamp(ivec2(floor(relative / region_extent)), ivec2(0), region_grid - ivec2(1));
	local = relative - vec2(region) * region_extent;
	return region;
}

// Where the sample-map lattice index (sample 0 at the terrain origin, one index per
// spacing * scale metres; shared region edges resolve to the higher region) is stored:
// the tier, and for tiers 1 and 2 the layer coordinates, for tier 3 the coarse texel
// (nearest coarse lattice point, clamped by the caller to the image).
int terrain_lattice_source(ivec2 index, int scale, int apron, out ivec3 address, out ivec2 coarse_texel) {
	int per_region = region_cells / scale;
	ivec2 region = clamp(index / per_region, ivec2(0), region_grid - ivec2(1));
	int slot;
	int tier = terrain_region_entry(region, slot);
	ivec2 local = index - region * per_region;
	address = ivec3(0); coarse_texel = ivec2(0);
	if (tier == 1) { address = ivec3(local + ivec2(apron), slot); }
	else if (tier == 2) {
		int far_step = 1 << far_level;
		address = ivec3((local + ivec2(far_step / 2)) / far_step + ivec2(apron), slot);
	}
	else if (tier == 3) {
		int coarse_step = 1 << coarse_level;
		coarse_texel = (max(index, ivec2(0)) + ivec2(coarse_step / 2)) / coarse_step;
	}
	return tier;
}

ivec2 terrain_lattice_max_for(int scale) { return (region_lattice + ivec2(scale - 1)) / scale; }

// Bilinear height at a terrain position: hardware filtering inside the region's tier (the
// apron keeps the near and far footprints in their layer), the coarse image elsewhere.
float terrain_linear_height(vec2 position) {
	vec2 local;
	ivec2 region = terrain_region_locate(position, local);
	int slot;
	int tier = terrain_region_entry(region, slot);
	if (tier == 1) {
		vec2 texel = local / (region_spacing * float(height_scale)) + vec2(float(height_apron));
		vec2 size = vec2(textureSize(height_regions, 0).xy);
		return textureLod(height_regions, vec3((texel + vec2(0.5)) / size, float(slot)), 0.0).r;
	}
	if (tier == 2) {
		vec2 texel = local / (region_spacing * float(height_scale << far_level)) + vec2(float(height_apron));
		vec2 size = vec2(textureSize(height_far_regions, 0).xy);
		return textureLod(height_far_regions, vec3((texel + vec2(0.5)) / size, float(slot)), 0.0).r;
	}
	if (tier == 3) {
		vec2 relative = clamp(position - region_origin, vec2(0.0), field_size);
		vec2 texel = relative / (region_spacing * float(height_scale << coarse_level));
		return textureLod(coarse_height, (texel + vec2(0.5)) / vec2(textureSize(coarse_height, 0)), 0.0).r;
	}
	return 0.0;
}

// ---- host interface of terrain_normals.gdshaderinc ----
vec2 terrain_lattice_step() { return vec2(region_spacing * float(height_scale)); }
ivec2 terrain_lattice_max() { return terrain_lattice_max_for(height_scale); }

float terrain_texel_height(ivec2 index) {
	ivec3 address; ivec2 coarse_texel;
	int tier = terrain_lattice_source(index, height_scale, height_apron, address, coarse_texel);
	if (tier == 1) { return texelFetch(height_regions, address, 0).r; }
	// A coarser tier answers with the bilinear sample of its lattice at this point, which is
	// the stored value where the lattices share the point.
	if (tier == 2 || tier == 3) { return terrain_linear_height(region_origin + vec2(index) * terrain_lattice_step()); }
	return 0.0;
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
	ivec3 address; ivec2 coarse_texel;
	int tier = terrain_lattice_source(index, material_ids_scale, material_ids_apron, address, coarse_texel);
	if (tier == 1) {
		ids = ivec4(round(texelFetch(material_ids_regions, address, 0) * 255.0));
		weights = texelFetch(material_weights_regions, address, 0);
	} else if (tier == 2) {
		ids = ivec4(round(texelFetch(material_ids_far_regions, address, 0) * 255.0));
		weights = texelFetch(material_weights_far_regions, address, 0);
	} else if (tier == 3) {
		ivec2 texel = clamp(coarse_texel, ivec2(0), textureSize(coarse_material_ids, 0) - ivec2(1));
		ids = ivec4(round(texelFetch(coarse_material_ids, texel, 0) * 255.0));
		weights = texelFetch(coarse_material_weights, texel, 0);
	}
}

// Cell holes: one texel per cell of spacing * holes_scale, nearest.
bool terrain_cell_hole(vec2 position) {
	float cell_size = region_spacing * float(holes_scale);
	ivec2 cell_max = terrain_lattice_max_for(holes_scale) - ivec2(1);
	vec2 relative = clamp(position - region_origin, vec2(0.0), field_size);
	ivec2 cell = clamp(ivec2(floor(relative / cell_size)), ivec2(0), cell_max);
	int per_region = region_cells / holes_scale;
	ivec2 region = clamp(cell / per_region, ivec2(0), region_grid - ivec2(1));
	int slot;
	int tier = terrain_region_entry(region, slot);
	ivec2 local = cell - region * per_region;
	if (tier == 1) { return texelFetch(holes_regions, ivec3(local + ivec2(holes_apron), slot), 0).r >= 0.5; }
	if (tier == 2) { return texelFetch(holes_far_regions, ivec3(local / (1 << far_level) + ivec2(holes_apron), slot), 0).r >= 0.5; }
	if (tier == 3) {
		ivec2 texel = clamp(cell / (1 << coarse_level), ivec2(0), textureSize(coarse_holes, 0) - ivec2(1));
		return texelFetch(coarse_holes, texel, 0).r >= 0.5;
	}
	return false;
}

vec4 terrain_macro_sample(vec2 position) {
	if (!has_terrain_macro_map) { return vec4(1.0); }
	vec2 local;
	ivec2 region = terrain_region_locate(position, local);
	int slot;
	int tier = terrain_region_entry(region, slot);
	if (tier == 1) {
		vec2 texel = local / (region_spacing * float(macro_scale)) + vec2(float(macro_apron));
		vec2 size = vec2(textureSize(macro_regions, 0).xy);
		return textureLod(macro_regions, vec3((texel + vec2(0.5)) / size, float(slot)), 0.0);
	}
	if (tier == 2) {
		vec2 texel = local / (region_spacing * float(macro_scale << far_level)) + vec2(float(macro_apron));
		vec2 size = vec2(textureSize(macro_far_regions, 0).xy);
		return textureLod(macro_far_regions, vec3((texel + vec2(0.5)) / size, float(slot)), 0.0);
	}
	if (tier == 3) {
		vec2 relative = clamp(position - region_origin, vec2(0.0), field_size);
		vec2 texel = relative / (region_spacing * float(macro_scale << coarse_level));
		return textureLod(coarse_macro, (texel + vec2(0.5)) / vec2(textureSize(coarse_macro, 0)), 0.0);
	}
	return vec4(1.0);
}
