// Page lookup of Strata's surface cache, a sparse virtual texture (strata_surface_cache.gd):
// pages of cells in a mip chain over the terrain, of which the requested ones sit in the slots
// of an atlas, found through a page table. Shared by terrain_surface.gdshader and
// strata_surface_cache.gdshaderinc. Define before including:
//   STRATA_VT_TABLE    sampler2D  the page table (nearest), one mip per page mip
//   STRATA_VT_PARAMS   vec4       cell size of mip 0 in metres, page size in cells, border in
//                                 cells, top mip (page size 0: no cache)
//   STRATA_VT_LAYOUT   ivec4      first page of mip 0 (xy), table size at mip 0, slots per atlas side
//
// Cell g of mip m covers [g, g + 1) * cell size * 2^m on both terrain-local axes. Page p of mip
// m holds cells [p, p + 1) * page size; its table texel is p - (first page >> m). A table entry
// is 0 for an absent page, otherwise (slot + 1) / 65535. A slot is the page with a border of
// the neighbouring pages' cells on every side, so texels next to the page can be read too.

// The height atlas is RG16 unorm (strata_surface_cache.gd): R the base height over a range
// (decode: x the height at 0, y the range), 0 in holes; G the material relief over
// +-STRATA_VT_RELIEF_RANGE metres (StrataSurfaceCache.RELIEF_RANGE).
const float STRATA_VT_RELIEF_RANGE = 8.0;

bool strata_vt_height_hole(float encoded) {
	return encoded < 0.5 / 65535.0;
}

float strata_vt_base_height(float encoded, vec2 decode) {
	return decode.x + (encoded * 65535.0 - 1.0) / 65534.0 * decode.y;
}

float strata_vt_relief(float encoded) {
	return (encoded - 0.5) * (2.0 * STRATA_VT_RELIEF_RANGE);
}

// The resident page of a mip holding a terrain-local XZ position. atlas: xy the position in the
// page's atlas layer in cells (integers are cell corners; the centre of a cell is at + 0.5), z
// the layer. False when the page is absent, outside the table or there is no cache.
bool strata_vt_locate(vec2 position, int mip, out vec3 atlas) {
	atlas = vec3(0.0);
	int page_size = int(STRATA_VT_PARAMS.y);
	if (page_size <= 0 || mip < 0 || mip > int(STRATA_VT_PARAMS.w)) { return false; }
	vec2 grid = position / (STRATA_VT_PARAMS.x * exp2(float(mip)));
	ivec2 page = ivec2(floor(grid / float(page_size)));
	ivec2 entry_at = page - ivec2(STRATA_VT_LAYOUT.x >> mip, STRATA_VT_LAYOUT.y >> mip);
	int size = max(STRATA_VT_LAYOUT.z >> mip, 1);
	if (any(lessThan(entry_at, ivec2(0))) || any(greaterThanEqual(entry_at, ivec2(size)))) { return false; }
	int entry = int(texelFetch(STRATA_VT_TABLE, entry_at, mip).r * 65535.0 + 0.5);
	if (entry == 0) { return false; }
	int per_side = STRATA_VT_LAYOUT.w;
	int layer = (entry - 1) / (per_side * per_side);
	int in_layer = (entry - 1) - layer * per_side * per_side;
	vec2 slot_origin = vec2(float(in_layer % per_side), float(in_layer / per_side)) * (float(page_size) + 2.0 * STRATA_VT_PARAMS.z);
	atlas = vec3(slot_origin + vec2(STRATA_VT_PARAMS.z) + (grid - vec2(page * page_size)), float(layer));
	return true;
}

// The finest resident mip from first up to the top mip that holds the position, with its atlas
// position; -1 when none does (outside the terrain, or before the coarsest pages are filled:
// those stay resident).
int strata_vt_find(vec2 position, int first, out vec3 atlas) {
	int top = int(STRATA_VT_PARAMS.w);
	for (int mip = clamp(first, 0, top); mip <= top; mip++) {
		if (strata_vt_locate(position, mip, atlas)) { return mip; }
	}
	atlas = vec3(0.0);
	return -1;
}

// The mip nearest to a footprint (metres per pixel) with the cache's lod bias, as nearest mipmap
// selection picks. The pages the screen requests are the two mips around footprint + bias, so
// this one is among them.
int strata_vt_footprint_mip(float footprint, float bias) {
	return clamp(int(floor(log2(max(footprint, 0.000001) / STRATA_VT_PARAMS.x) + bias + 0.5)), 0, int(STRATA_VT_PARAMS.w));
}
