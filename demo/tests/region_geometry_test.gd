extends SceneTree
## Region geometry and region data contract (docs/development/strata_regions_plan.md). Adjacent
## regions share their edge samples, aprons address the neighbour's samples, cell and sample
## maps and coarser scales size as the plan states, and region files store levels byte-exact.
var checks := 0
var failures := 0

func _initialize() -> void: run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures += 1; push_error("REGION_GEOMETRY: " + message)

func run() -> void:
	var bounds := Rect2(-2048, -2048, 4096, 4096)
	var spec := StrataRegions.standard_spec(bounds, 1.0)
	check(StrataRegions.validate_spec(spec).ok, "the standard spec validates")
	check(StrataRegions.grid_size(spec) == Vector2i(16, 16), "4 km at 1 m with 256 cells is a 16 x 16 grid")
	check(is_equal_approx(StrataRegions.extent(spec), 256.0), "a region spans 256 m")
	var height: Dictionary = spec.maps[StrataRegions.MAP_HEIGHT]
	var holes: Dictionary = spec.maps[StrataRegions.MAP_HOLES]
	var macro: Dictionary = spec.maps[StrataRegions.MAP_MACRO]
	check(StrataRegions.map_size(256, height) == Vector2i(261, 261), "a sample map holds 257 samples plus a 2-texel apron on each side")
	check(StrataRegions.map_size(256, holes) == Vector2i(260, 260), "a cell map holds 256 cells plus the apron")
	check(StrataRegions.map_size(256, macro) == Vector2i(67, 67), "a scale-4 sample map with a 1-texel apron holds 67 texels")
	check(StrataRegions.map_size(256, height, 1) == Vector2i(133, 133) and StrataRegions.map_size(256, height, 2) == Vector2i(69, 69), "levels halve the cell texels and keep the apron")
	check(StrataRegions.max_level(256, height) == 8 and StrataRegions.max_level(256, macro) == 6, "the deepest level keeps one texel per region")

	# Region origins, bounds and the inverse lookup.
	check(StrataRegions.region_origin(spec, Vector2i(0, 0)) == Vector2(-2048, -2048), "region (0,0) starts at the bounds origin")
	check(StrataRegions.region_origin(spec, Vector2i(3, 5)) == Vector2(-2048 + 768, -2048 + 1280), "region origins step by the extent")
	check(StrataRegions.region_at(spec, Vector2(-2048 + 768.5, -2048 + 1280.5)) == Vector2i(3, 5), "a position inside a region maps back to it")
	check(StrataRegions.region_at(spec, Vector2(-2048 + 768.0, -2048 + 1280.0)) == Vector2i(3, 5), "a shared edge belongs to the higher region")
	check(StrataRegions.region_at(spec, Vector2(-2048 + 767.9, 0)) == Vector2i(2, 8), "just below the edge is the lower region")
	check(not StrataRegions.contains_region(spec, Vector2i(16, 0)) and StrataRegions.contains_region(spec, Vector2i(15, 15)), "the grid has 16 regions per axis")

	# Windows: texel apron maps to lattice index -2; texel apron + n is the neighbour's first sample.
	var window := StrataRegions.map_window(spec, Vector2i(3, 5), height)
	check(window.first == Vector2i(3 * 256 - 2, 5 * 256 - 2) and window.size == Vector2i(261, 261) and is_equal_approx(window.step, 1.0), "the height window starts two lattice samples before the region")
	check(window.origin == Vector2(-2048 + 768 - 2, -2048 + 1280 - 2), "the window origin is the apron's position")
	var edge := StrataRegions.texel_position(spec, Vector2i(3, 5), height, Vector2i(2 + 256, 2))
	var next := StrataRegions.texel_position(spec, Vector2i(4, 5), height, Vector2i(2, 2))
	check(edge == next, "adjacent regions share their edge sample")
	check(StrataRegions.texel_position(spec, Vector2i(3, 5), height, Vector2i(2, 2)) == StrataRegions.region_origin(spec, Vector2i(3, 5)), "texel (apron, apron) is the region origin")
	var apron_texel := StrataRegions.texel_position(spec, Vector2i(4, 5), height, Vector2i(0, 2))
	check(apron_texel == StrataRegions.texel_position(spec, Vector2i(3, 5), height, Vector2i(256, 2)), "the apron holds the neighbour's samples")
	check(StrataRegions.texel_at(spec, Vector2i(3, 5), height, StrataRegions.region_origin(spec, Vector2i(3, 5)) + Vector2(10.5, 20.25)) == Vector2(12.5, 22.25), "texel_at is the inverse of texel_position with fractions")
	var macro_window := StrataRegions.map_window(spec, Vector2i(3, 5), macro)
	check(macro_window.first == Vector2i(3 * 64 - 1, 5 * 64 - 1) and is_equal_approx(macro_window.step, 4.0) and macro_window.size == Vector2i(67, 67), "a scale-4 map windows on its own lattice")
	var hole_window := StrataRegions.map_window(spec, Vector2i(0, 0), holes)
	check(hole_window.first == Vector2i(-2, -2) and hole_window.size == Vector2i(260, 260), "a cell map window has no endpoint sample")
	var level_window := StrataRegions.map_window(spec, Vector2i(1, 0), height, 1)
	check(level_window.first == Vector2i(128 - 2, -2) and is_equal_approx(level_window.step, 2.0), "a level window uses the level's lattice")

	# Dirty rectangles.
	var area := Rect2(StrataRegions.region_origin(spec, Vector2i(3, 5)) + Vector2(250, 10), Vector2(10, 10))
	var touched := StrataRegions.regions_touching(spec, area, height)
	check(touched == [Vector2i(3, 5), Vector2i(4, 5)], "a dab across a region edge touches both regions, got %s" % [touched])
	check(StrataRegions.regions_touching(spec, Rect2(StrataRegions.region_origin(spec, Vector2i(3, 5)) + Vector2(254.5, 10), Vector2(0.1, 0.1)), height) == [Vector2i(3, 5), Vector2i(4, 5)], "the apron pulls in the neighbour within two samples of the edge")
	var rect := StrataRegions.texel_rect(spec, Vector2i(3, 5), height, area)
	check(rect == Rect2i(252, 12, 9, 11), "the texel rectangle covers the area with the apron offset, got %s" % rect)
	check(not StrataRegions.texel_rect(spec, Vector2i(9, 9), height, area).has_area(), "a far region has no texel rectangle")
	check(StrataRegions.regions_touching(spec, Rect2(-5000, -5000, 20000, 20000), height).size() == 256, "touching clips to the grid")

	# Spec validation.
	check(not StrataRegions.validate_spec({"bounds": bounds, "spacing": 1.0, "cells": 100, "apron": 2, "maps": {}}).ok, "cells must be a power of two")
	check(not StrataRegions.validate_spec({"bounds": bounds, "spacing": 1.0, "cells": 256, "apron": 2, "maps": {"x": StrataRegions.map(Image.FORMAT_RF, "sample", 3)}}).ok, "a map scale must be a power of two")
	check(not StrataRegions.validate_spec({"bounds": bounds, "spacing": 1.0, "cells": 256, "apron": 2, "maps": {"x": StrataRegions.map(Image.FORMAT_RGB8, "sample")}}).ok, "RGB8 is not a region map format")
	check(StrataRegions.validate_spec({"bounds": Rect2(0, 0, 100, 60), "spacing": 0.5, "cells": 64, "apron": 2, "maps": {}}).ok and StrataRegions.grid_size({"bounds": Rect2(0, 0, 100, 60), "spacing": 0.5, "cells": 64}) == Vector2i(4, 2), "bounds that are not a multiple of the extent round up")

	# Region data: levels are stored byte-exact and validated against the geometry.
	var data := StrataRegionData.new()
	data.region = Vector2i(3, 5)
	data.origin = StrataRegions.region_origin(spec, data.region)
	var image := Image.create(261, 261, false, Image.FORMAT_RF)
	for y in range(261):
		for x in range(261): image.set_pixel(x, y, Color(sin(x * 0.1) * 7.0 + y * 0.01, 0, 0))
	check(data.set_image(StrataRegions.MAP_HEIGHT, image, 0, height), "a matching image is stored")
	check(not data.set_image(StrataRegions.MAP_HEIGHT, Image.create(260, 260, false, Image.FORMAT_RF), 0), "a wrong size is refused")
	check(not data.set_image(StrataRegions.MAP_HEIGHT, Image.create(261, 261, false, Image.FORMAT_RH), 0), "a wrong format is refused")
	check(not data.set_image("new_map", image, 0), "a new map needs its description")
	check(data.get_image(StrataRegions.MAP_HEIGHT).get_data() == image.get_data(), "the stored level reads back byte-identical")
	check(data.set_image(StrataRegions.MAP_HEIGHT, Image.create(133, 133, false, Image.FORMAT_RF), 1) and data.level_count(StrataRegions.MAP_HEIGHT) == 2, "a level-1 image sizes as the geometry says")
	var patch := Image.create(3, 3, false, Image.FORMAT_RF)
	patch.fill(Color(42, 0, 0))
	var revision := data.revision
	check(data.blit(StrataRegions.MAP_HEIGHT, 0, patch, Vector2i(10, 20)) and data.get_image(StrataRegions.MAP_HEIGHT).get_pixel(11, 21).r == 42.0 and data.get_image(StrataRegions.MAP_HEIGHT).get_pixel(13, 21).r != 42.0 and data.revision > revision, "a blit replaces exactly its rectangle and advances the revision")
	check(not data.blit(StrataRegions.MAP_HEIGHT, 0, patch, Vector2i(259, 0)), "a blit outside the map is refused")
	check(data.set_image(StrataRegions.MAP_HOLES, Image.create(260, 260, false, Image.FORMAT_L8), 0, holes) and data.set_image(StrataRegions.MAP_MACRO, Image.create(67, 67, false, Image.FORMAT_RGBAH), 0, macro), "cell and scaled maps store with their own sizes")
	check(data.validate().ok, "a consistent region validates: %s" % data.validate().message)
	check(data.payload_bytes() == 261 * 261 * 4 + 133 * 133 * 4 + 260 * 260 + 67 * 67 * 8, "payload bytes sum every level")
	data.maps[StrataRegions.MAP_HOLES].levels[0] = PackedByteArray([1, 2, 3])
	check(not data.validate().ok, "a level with the wrong byte count fails validation")
	data.remove_map(StrataRegions.MAP_HOLES)
	check(data.validate().ok and not data.has_map(StrataRegions.MAP_HOLES), "removing the map restores validity")

	# Resource round trip keeps bytes.
	var path := "user://region_geometry_test.res"
	check(ResourceSaver.save(data, path, ResourceSaver.FLAG_COMPRESS) == OK, "the region saves")
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as StrataRegionData
	check(loaded != null and loaded.validate().ok and loaded.get_image(StrataRegions.MAP_HEIGHT).get_data() == data.get_image(StrataRegions.MAP_HEIGHT).get_data() and loaded.region == Vector2i(3, 5), "the loaded region is byte-identical")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	# Automatic region size: the largest power of two at or below min(256, side in cells), at least 16.
	check(StrataRegions.resolve_cells(0, Rect2(-32, -32, 64, 64), 1.0) == 64, "a 64 m terrain at 1 m gets 64-cell regions")
	check(StrataRegions.resolve_cells(0, Rect2(-2048, -2048, 4096, 4096), 1.0) == 256, "a 4 km terrain at 1 m gets 256-cell regions")
	check(StrataRegions.resolve_cells(0, Rect2(0, 0, 100, 100), 1.0) == 64 and StrataRegions.resolve_cells(0, Rect2(0, 0, 10, 10), 1.0) == 16, "the automatic size rounds down and is at least 16")
	check(StrataRegions.resolve_cells(0, Rect2(0, 0, 64, 64), 0.25) == 256 and StrataRegions.resolve_cells(0, Rect2(0, 0, 64, 1024), 1.0) == 64, "spacing and the smaller side decide")
	check(StrataRegions.resolve_cells(128, Rect2(0, 0, 64, 64), 1.0) == 128 and StrataRegions.resolve_cells(16, Rect2(0, 0, 8192, 8192), 1.0) == 16, "an explicit size is kept")
	var automatic := StrataTerrain3D.new()
	check(automatic.region_cells == 0 and automatic.effective_region_cells() == 64 and StrataRegions.validate_spec(automatic.region_spec()).ok and automatic.region_spec().cells == 64, "a default terrain is automatic: 64 m at 1 m gives 64-cell regions")
	check(automatic._get_configuration_warnings().is_empty(), "the default small terrain has no configuration warning")
	automatic.region_cells = 100
	check(automatic.region_cells == 128 and automatic.region_spec().cells == 128, "an explicit value rounds to a power of two and is used")
	automatic.region_cells = 0
	check(automatic.region_cells == 0, "0 returns to automatic")
	automatic.free()

	# Coarse maps (Phase B): the terrain-wide horizon tier at a shared level, no apron.
	check(StrataRegions.coarse_level(spec) == 2, "the 4 km island at 1 m gets 4 m coarse maps (level 2, 1024 cells per axis)")
	check(StrataRegions.coarse_map_size(spec, height, 2) == Vector2i(1025, 1025) and StrataRegions.coarse_map_size(spec, holes, 2) == Vector2i(1024, 1024) and StrataRegions.coarse_map_size(spec, macro, 2) == Vector2i(257, 257), "coarse sample maps share the far edge, cell maps do not, scale divides")
	check(StrataRegions.coarse_level(StrataRegions.standard_spec(Rect2(-8192, -8192, 16384, 16384), 1.0)) == 4, "a 16 km terrain gets 16 m coarse maps")
	check(StrataRegions.coarse_level(StrataRegions.standard_spec(Rect2(-32, -32, 64, 64), 1.0, 16)) == 0, "a small terrain's coarse maps are its level 0")
	check(StrataRegions.coarse_level(StrataRegions.standard_spec(Rect2(-8192, -8192, 16384, 16384), 1.0, 16), 1) == 2, "the level is capped so every map keeps a texel per region (scale-4 macro at 16 cells)")
	var coarse := StrataRegions.coarse_window(spec, height, 2)
	check(coarse.first == Vector2i.ZERO and coarse.size == Vector2i(1025, 1025) and is_equal_approx(coarse.step, 4.0) and coarse.origin == bounds.position and coarse.level == 2, "the coarse window covers the grid at the level's step")
	check(StrataRegions.coarse_texel_position(spec, height, Vector2i(1024, 1024), 2) == bounds.end and StrataRegions.coarse_texel_position(spec, holes, Vector2i(1, 0), 2) == bounds.position + Vector2(4, 0), "coarse texels step by spacing × scale << level from the bounds origin")
	var placement := StrataRegions.coarse_placement(spec, Vector2i(3, 5), height, 2)
	check(placement.source == Rect2i(2, 2, 65, 65) and placement.destination == Vector2i(192, 320), "a region's level-2 core (apron excluded, shared edge included) lands at grid × 64")
	var cell_placement := StrataRegions.coarse_placement(spec, Vector2i(15, 15), holes, 2)
	check(cell_placement.source == Rect2i(2, 2, 64, 64) and cell_placement.destination + cell_placement.source.size == Vector2i(1024, 1024), "the last region's cells end the coarse cell map")
	check(StrataRegions.coarse_texel_position(spec, height, placement.destination, 2) == StrataRegions.region_origin(spec, Vector2i(3, 5)), "the placed core's first texel is the region origin")
	check(StrataRegions.map_window(spec, Vector2i(3, 5), height, 1).level == 1, "map windows carry their level")

	print("REGION_GEOMETRY checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
