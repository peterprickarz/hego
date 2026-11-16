extends SceneTree
## Contract of StrataSurfaceCache's page addressing. The script side (page_key, page_rect,
## lookup_params, lookup_layout, request keys) is held against the lookup of
## shaders/strata_virtual_texture.gdshaderinc and the key packing of the feedback pass, both
## repeated here in script. Nothing is evaluated on the GPU. Runs headless in about a second.
var failures := 0
var checks := 0

func _initialize() -> void: run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("SURFACE_CACHE_PAGES: " + message)

## strata_vt_locate() up to the page table fetch: the table texel a position reads at a mip.
func shader_table_texel(position: Vector2, mip: int, params: Vector4, layout: Vector4i) -> Vector2i:
	var grid := position / (params.x * pow(2.0, float(mip)))
	var page := Vector2i(floori(grid.x / params.y), floori(grid.y / params.y))
	return page - Vector2i(layout.x >> mip, layout.y >> mip)

func run() -> void:
	var cache := StrataSurfaceCache.new()
	# Bounds that start at negative coordinates and are not a whole number of pages.
	var bounds := Rect2(-1000.5, -300.25, 2500.0, 1700.0)
	check(cache.configure(bounds, 16.0, 64, 256), "a terrain whose page table fits is accepted")
	var params := cache.lookup_params()
	var layout := cache.lookup_layout()
	check(is_equal_approx(params.x, 1.0 / 16.0) and int(params.y) == cache.page_size and int(params.z) == StrataSurfaceCache.BORDER and int(params.w) == cache.top_mip, "lookup_params: cell size, page size, border, top mip")
	check(layout.z > 0 and layout.z <= StrataSurfaceCache.MAX_TABLE_SIZE and (layout.z & (layout.z - 1)) == 0, "the page table is a power of two within MAX_TABLE_SIZE")
	check(cache.resolution == layout.w * (cache.page_size + 2 * StrataSurfaceCache.BORDER) and cache.resolution <= StrataSurfaceCache.MAX_ATLAS_SIZE, "an atlas layer holds whole slots of a page and its border")
	check(cache.pool_pages >= 256, "the pool holds at least the slots asked for")
	var inside := 0.001
	var corners := [bounds.position + Vector2(inside, inside), bounds.end - Vector2(inside, inside), Vector2(bounds.position.x + inside, bounds.end.y - inside), Vector2(bounds.end.x - inside, bounds.position.y + inside)]
	var samples: Array = corners.duplicate()
	samples.append_array([Vector2.ZERO, Vector2(-0.001, -0.001), Vector2(0.001, 0.001), Vector2(-999.9, 1399.7), Vector2(733.3, 211.7), Vector2(1499.4, -300.2)])
	for mip in cache.top_mip + 1:
		var side := maxi(layout.z >> mip, 1)
		for position: Vector2 in samples:
			var key := cache.page_key(position, mip)
			check(key.z == mip and Vector2i(key.x, key.y) == shader_table_texel(position, mip, params, layout), "mip %d: the script and the shader lookup agree on the table texel of %s" % [mip, position])
			check(key.x >= 0 and key.y >= 0 and key.x < side and key.y < side, "mip %d: %s lies inside the mip's page table" % [mip, position])
			check(cache.page_rect(key).has_point(position), "mip %d: the page of %s contains it" % [mip, position])
			var size := cache.page_rect(key).size
			check(is_equal_approx(size.x, params.x * params.y * pow(2.0, float(mip))) and is_equal_approx(size.x, size.y), "mip %d: a page is page_size cells of that mip wide" % mip)
	# Request keys: mip << 28 | table y << 14 | table x, read back from a 32-bit buffer.
	check(StrataSurfaceCache.MAX_TABLE_SIZE <= 16384, "table coordinates fit the 14 bits of a request key")
	for page: Vector3i in [Vector3i(0, 0, 0), Vector3i(StrataSurfaceCache.MAX_TABLE_SIZE - 1, StrataSurfaceCache.MAX_TABLE_SIZE - 1, 0), Vector3i(5, 9, 7), Vector3i(1, 2, 8), Vector3i(3, 0, 15)]:
		var packed := PackedInt32Array([StrataSurfaceCache.request_key(page)])
		check(StrataSurfaceCache.request_page(packed[0]) == page, "request key of %s survives a signed 32-bit buffer" % page)
	check(cache.top_mip <= 15, "mips fit the 4 bits of a request key")
	# A terrain too large for the page table is refused with a reason, and a later layout works.
	check(not cache.configure(Rect2(0.0, 0.0, 100000.0, 100000.0), 128.0, 64, 256), "a page table beyond MAX_TABLE_SIZE is refused")
	check("surface_cache_page_size" in str(cache.stats.get("status", "")), "the refusal names the settings to change")
	check(cache.configure(bounds, 16.0, 64, 256), "a fitting layout is accepted after a refused one")
	# Settings keep invalid values out.
	var settings := StrataRenderSettings.new()
	var filter: int = settings.surface_cache_filter
	settings.surface_cache_filter = 7
	check(settings.surface_cache_filter == filter, "an unknown filter is rejected")
	var page_size: int = settings.surface_cache_page_size
	settings.surface_cache_page_size = 100
	check(settings.surface_cache_page_size == page_size, "a page size that is not offered is rejected")
	var anisotropy: int = settings.surface_cache_anisotropy
	settings.surface_cache_anisotropy = 3
	check(settings.surface_cache_anisotropy == anisotropy, "an anisotropy that is not offered is rejected")
	print("SURFACE_CACHE_PAGES checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
