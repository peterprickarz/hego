class_name LargeWorldFixture
extends RefCounted
## ARTIFICIAL TEST FIXTURE. Not terrain content, not a production feature, not a showcase.
##
## A procedural terrain of a chosen size and spacing for the large-world suite test and the
## 8 km / 16 km benchmarks (docs/development/testing.md). It exists only to put load on the
## bake, the streamer, the renderer and the physics helpers; nothing in it was authored.
##
## Layers (all children of the returned StrataTerrain3D, bottom to top):
##   FixtureRelief    height, REPLACE, at 4 x spacing: a broad fractal relief of about 200 m
##                    with a gaussian mountain and a basin, so a camera flight sees relief.
##   FixtureDetail    height, ADD, 0..1 m of fine noise at the full spacing, UNORM16, written in
##                    dense windows of WINDOW samples per side so no whole-terrain float image
##                    exists (optional, see the "detail" option).
##   FixtureMaterials material_grass / material_rock / material_sand at 4 x spacing (UNORM8):
##                    rock by high slope, sand by low height, grass elsewhere; optional macro
##                    tint terrain_tint_r/g/b (see "macro").
##   FixtureHoles     a few hole cells at 4 x spacing.
## The terrain's editor_materials are three solid-colour StrataMaterial resources (4 x 4 pixel
## generated textures). Everything is deterministic for a given seed.

const LABEL := "ARTIFICIAL large-world fixture (procedural noise, not island content)"
const WINDOW := 1025
const CHANNELS: Array[String] = ["material_grass", "material_rock", "material_sand"]
const COLORS: Array[Color] = [Color(0.25, 0.5, 0.18), Color(0.45, 0.43, 0.4), Color(0.8, 0.72, 0.5)]
## Coarse layers sample every COARSE_FACTOR-th lattice point.
const COARSE_FACTOR := 4

static func describe() -> String:
	return LABEL

## Options: seed (7), detail (true), macro (true), holes (6), amplitude (200.0 m of relief).
## The terrain is not in the tree and has its preview disabled; add it to the scene before a bake.
## Returns the terrain, with meta "fixture_build_ms" and "fixture_label" set.
static func build(size_m: float, spacing: float, options: Dictionary = {}) -> StrataTerrain3D:
	var started := Time.get_ticks_usec()
	var cells := roundi(size_m / spacing)
	assert(absf(cells * spacing - size_m) < 0.0001 and cells % COARSE_FACTOR == 0, "fixture size must be a multiple of %d x spacing" % COARSE_FACTOR)
	var seed_value := int(options.get("seed", 7))
	var amplitude := float(options.get("amplitude", 200.0))
	var terrain := StrataTerrain3D.new()
	terrain.name = "LargeWorldFixture"
	terrain.set_preview_enabled(false)
	terrain.base_bounds = Rect2(-size_m * 0.5, -size_m * 0.5, size_m, size_m)
	terrain.region_spacing = spacing
	terrain.region_cells = 0
	terrain.editor_material_channels = PackedStringArray(CHANNELS)
	terrain.editor_materials = _materials()
	terrain.set_meta("fixture_label", LABEL)
	var origin := terrain.base_bounds.position
	var coarse_spacing := spacing * COARSE_FACTOR
	var coarse_size := cells / COARSE_FACTOR + 1
	var relief := _relief(coarse_size, coarse_spacing, origin, size_m, amplitude, seed_value)
	_add_layer(terrain, "FixtureRelief", coarse_spacing, origin).data.replace_dense(&"height", Vector2i.ZERO, _image_rf(coarse_size, relief))
	if bool(options.get("detail", true)):
		_write_detail(_add_layer(terrain, "FixtureDetail", spacing, origin), cells + 1, spacing, seed_value + 1)
	var materials := _add_layer(terrain, "FixtureMaterials", coarse_spacing, origin)
	_write_materials(materials, relief, coarse_size, coarse_spacing, amplitude, bool(options.get("macro", true)))
	var hole_count := int(options.get("holes", 6))
	if hole_count > 0:
		_write_holes(_add_layer(terrain, "FixtureHoles", coarse_spacing, origin), coarse_size, hole_count)
	terrain.set_meta("fixture_build_ms", (Time.get_ticks_usec() - started) / 1000.0)
	return terrain

static func _add_layer(terrain: StrataTerrain3D, layer_name: String, spacing: float, origin: Vector2) -> StrataLayer:
	var layer := StrataLayer.new()
	layer.name = layer_name
	layer.data.sample_spacing = spacing
	layer.data.grid_origin = origin
	terrain.add_child(layer)
	return layer

static func _image_rf(side: int, values: PackedFloat32Array) -> Image:
	return Image.create_from_data(side, side, false, Image.FORMAT_RF, values.to_byte_array())

static func _materials() -> Array[StrataMaterial]:
	var result: Array[StrataMaterial] = []
	for color in COLORS:
		var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		image.fill(color)
		var material := StrataMaterial.new()
		material.color_texture = ImageTexture.create_from_image(image)
		material.uv_scale = 0.25
		result.append(material)
	return result

## Heights (metres) of the coarse lattice, row-major.
static func _relief(side: int, step: float, origin: Vector2, size_m: float, amplitude: float, seed_value: int) -> PackedFloat32Array:
	var broad := FastNoiseLite.new()
	broad.seed = seed_value
	broad.frequency = 1.0 / maxf(size_m * 0.35, 1.0)
	broad.fractal_type = FastNoiseLite.FRACTAL_FBM
	broad.fractal_octaves = 3
	var mid := FastNoiseLite.new()
	mid.seed = seed_value + 100
	mid.frequency = 1.0 / 700.0
	mid.fractal_type = FastNoiseLite.FRACTAL_FBM
	mid.fractal_octaves = 4
	var mountain := Vector2(0.22, -0.18) * size_m
	var basin := Vector2(-0.2, 0.25) * size_m
	var radius := size_m * 0.12
	var values := PackedFloat32Array()
	values.resize(side * side)
	var index := 0
	for j in range(side):
		var z := origin.y + j * step
		for i in range(side):
			var x := origin.x + i * step
			var p := Vector2(x, z)
			var h := 0.45 * amplitude + 0.3 * amplitude * broad.get_noise_2d(x, z) + 0.2 * amplitude * mid.get_noise_2d(x, z)
			h += 0.55 * amplitude * exp(-p.distance_squared_to(mountain) / (radius * radius))
			h -= 0.3 * amplitude * exp(-p.distance_squared_to(basin) / (radius * radius))
			values[index] = h
			index += 1
	return values

static func _write_detail(layer: StrataLayer, side: int, spacing: float, seed_value: int) -> void:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = spacing / 40.0
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	layer.data.set_channel_format(&"height", StrataLayerData.VALUE_UNORM16)
	layer.set_composition(&"height", StrataLayer.Composition.ADD)
	for y0 in range(0, side, WINDOW):
		for x0 in range(0, side, WINDOW):
			noise.offset = Vector3(x0, y0, 0)
			var window := noise.get_image(mini(WINDOW, side - x0), mini(WINDOW, side - y0), false, false, false)
			window.convert(Image.FORMAT_RF)
			if not layer.data.patch_dense(&"height", Vector2i(x0, y0), window): push_error("fixture detail window %s rejected" % Vector2i(x0, y0))

static func _smoothstep(low: float, high: float, value: float) -> float:
	var t := clampf((value - low) / (high - low), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

static func _write_materials(layer: StrataLayer, relief: PackedFloat32Array, side: int, step: float, amplitude: float, macro: bool) -> void:
	var grass := PackedFloat32Array()
	var rock := PackedFloat32Array()
	var sand := PackedFloat32Array()
	var tint := PackedFloat32Array()
	for array in [grass, rock, sand]: array.resize(side * side)
	if macro: tint.resize(side * side)
	for j in range(side):
		var j0 := maxi(j - 1, 0)
		var j1 := mini(j + 1, side - 1)
		for i in range(side):
			var i0 := maxi(i - 1, 0)
			var i1 := mini(i + 1, side - 1)
			var dx := (relief[j * side + i1] - relief[j * side + i0]) / ((i1 - i0) * step)
			var dz := (relief[j1 * side + i] - relief[j0 * side + i]) / ((j1 - j0) * step)
			var slope := sqrt(dx * dx + dz * dz)
			var h := relief[j * side + i]
			var rock_w := _smoothstep(0.35, 0.8, slope)
			var sand_w := (1.0 - rock_w) * (1.0 - _smoothstep(0.12 * amplitude, 0.3 * amplitude, h))
			var index := j * side + i
			rock[index] = rock_w
			sand[index] = sand_w
			grass[index] = 1.0 - rock_w - sand_w
			if macro: tint[index] = 0.85 + 0.3 * _smoothstep(0.0, amplitude, h)
	for entry in [[&"material_grass", grass], [&"material_rock", rock], [&"material_sand", sand]]:
		layer.data.set_channel_format(entry[0], StrataLayerData.VALUE_UNORM8)
		layer.data.replace_dense(entry[0], Vector2i.ZERO, _image_rf(side, entry[1]))
	if macro:
		layer.data.replace_dense(&"terrain_tint_r", Vector2i.ZERO, _image_rf(side, tint))
		var tint_b := PackedFloat32Array()
		tint_b.resize(side * side)
		for index in range(tint_b.size()): tint_b[index] = 2.0 - tint[index]
		layer.data.replace_dense(&"terrain_tint_b", Vector2i.ZERO, _image_rf(side, tint_b))

## A few small hole squares at deterministic places away from the centre.
static func _write_holes(layer: StrataLayer, side: int, count: int) -> void:
	var values := Image.create(side, side, false, Image.FORMAT_RF)
	values.fill(Color(1, 0, 0, 1))
	var owned := Image.create(side, side, false, Image.FORMAT_RF)
	for index in range(count):
		var cx := int(side * (0.15 + 0.7 * fmod(index * 0.381966 + 0.1, 1.0)))
		var cy := int(side * (0.15 + 0.7 * fmod(index * 0.618034 + 0.3, 1.0)))
		owned.fill_rect(Rect2i(cx, cy, 3, 3), Color(1, 0, 0, 1))
	layer.data.replace_dense(&"hole", Vector2i.ZERO, values, owned)

## World-space XZ of the first hole's centre cell, for tests that probe a hole.
static func hole_point(terrain: StrataTerrain3D, index: int, count: int = 6) -> Vector2:
	var spacing := terrain.region_spacing * COARSE_FACTOR
	var side := roundi(terrain.base_bounds.size.x / spacing) + 1
	var cx := int(side * (0.15 + 0.7 * fmod(index * 0.381966 + 0.1, 1.0)))
	var cy := int(side * (0.15 + 0.7 * fmod(index * 0.618034 + 0.3, 1.0)))
	return terrain.base_bounds.position + Vector2(cx + 1.5, cy + 1.5) * spacing
