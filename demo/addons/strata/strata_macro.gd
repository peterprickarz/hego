@tool
class_name StrataMacro
extends RefCounted
## Terrain-wide tint and ambient occlusion composed from ordinary scalar layer
## channels into one bounded RGBAH map. No HEGo or Houdini dependency.
##
## terrain_tint_r/g/b are linear multipliers (neutral 1, packed range 0..2) and
## terrain_ao is an occlusion multiplier (neutral 1, packed range 0..1). Each
## channel composes independently over an implicit full-coverage neutral base:
## Replace lerps toward the layer value by its coverage, Add adds a signed
## offset. A channel no enabled layer owns is exactly 1.

const TINT_R := &"terrain_tint_r"
const TINT_G := &"terrain_tint_g"
const TINT_B := &"terrain_tint_b"
const AO := &"terrain_ao"
const CHANNELS: Array[StringName] = [TINT_R, TINT_G, TINT_B, AO]
const NEUTRAL := 1.0
const TINT_MAX := StrataRuntimeData.MACRO_TINT_MAX
const DEFAULT_SPACING := 4.0
const MAX_SIDE := StrataRuntimeData.MACRO_MAX_SIDE
## Texels per packing strip; keeps every temporary image under Image limits.
const _STRIP_TEXELS := 1 << 22

static var _neutral_data: StrataLayerData

static func _error(message: String) -> Dictionary:
	return {"ok": false, "message": message}

static func is_macro_channel(channel: StringName) -> bool:
	return CHANNELS.has(channel)

## Value below the first layer: 1 for macro channels, 0 for other channels.
static func channel_base(channel: StringName) -> float:
	return NEUTRAL if is_macro_channel(channel) else 0.0

## Composition descriptor for the neutral base of a macro channel, covering
## bounds completely. Prepend it to a captured layer list for compose_dense().
static func neutral_descriptor(channel: StringName, bounds: Rect2) -> Dictionary:
	if _neutral_data == null:
		var data := StrataLayerData.new()
		for name in CHANNELS:
			for z in range(-1, 3):
				for x in range(-1, 3):
					data.set_sample(name, Vector2i(x, z), NEUTRAL)
		_neutral_data = data
	return {"data": _neutral_data, "origin": Vector3(bounds.position.x, 0.0, bounds.position.y), "step_x": Vector3(bounds.size.x, 0.0, 0.0), "step_y": Vector3(0.0, 0.0, bounds.size.y), "mode": StrataLayer.Composition.REPLACE, "imported_field": false, "height_offset": 0.0}

## True if an enabled layer (through the cutoff) owns any macro channel.
static func has_macro_channels(terrain: StrataTerrain3D, through_layer: StrataLayer = null) -> bool:
	return not owned_channels(terrain, through_layer).is_empty()

static func owned_channels(terrain: StrataTerrain3D, through_layer: StrataLayer = null) -> PackedStringArray:
	var owned := PackedStringArray()
	if not is_instance_valid(terrain): return owned
	for layer in terrain.get_layers():
		if layer.enabled:
			var names := layer.get_channel_names()
			for channel in CHANNELS:
				if names.has(String(channel)) and not owned.has(String(channel)): owned.append(String(channel))
		if layer == through_layer: break
	return owned

## Deprecated for the editor preview, which composes macro maps per region
## (StrataRegions.compose_region); the whole-terrain form stays for the island binding and
## bakes of a single map.
## Composes the four channels on an endpoint-aligned lattice and packs them.
## Options: spacing (4 m; the actual step is returned when bounds are not a
## whole number of intervals), bounds (terrain-local XZ inside base_bounds,
## default base_bounds), through_layer (null = complete stack; the editor
## preview passes its cutoff), max_side (<= 4097 texels per axis).
## Returns {ok, empty, image (RGBAH: RGB tint, A ao), bounds, resolution,
## spacing (Vector2), sample_origin, sample_step_x, sample_step_y,
## owned_channels, token, report {min, max (Color), clamped, cpu_ms}}.
static func compose(terrain: StrataTerrain3D, options: Dictionary = {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	if not is_instance_valid(terrain) or not terrain.is_inside_tree() or not terrain.is_transform_valid():
		return _error("Macro composition requires a live terrain with a valid transform")
	var layers := terrain.get_layers()
	var through: StrataLayer = options.get("through_layer")
	if through != null and (not is_instance_valid(through) or through.get_parent() != terrain or not layers.has(through)):
		return _error("Macro cutoff must be a live direct terrain layer")
	var spacing := float(options.get("spacing", DEFAULT_SPACING))
	var bounds: Rect2 = options.get("bounds", terrain.base_bounds)
	var max_side := clampi(int(options.get("max_side", MAX_SIDE)), 2, MAX_SIDE)
	if not is_finite(spacing) or spacing <= 0.0 or not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite() or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return _error("Macro composition needs positive finite spacing and bounds")
	if not terrain.base_bounds.encloses(bounds):
		return _error("Macro bounds must lie inside the terrain bounds")
	var columns := bounds.size.x / spacing
	var rows := bounds.size.y / spacing
	if not is_finite(columns) or not is_finite(rows) or columns > max_side - 1 or rows > max_side - 1:
		return _error("Macro map exceeds %d texels per axis; choose a coarser spacing" % max_side)
	var resolution := Vector2i(ceili(columns) + 1, ceili(rows) + 1)
	var step_x := Vector3(bounds.size.x / (resolution.x - 1), 0.0, 0.0)
	var step_y := Vector3(0.0, 0.0, bounds.size.y / (resolution.y - 1))
	var origin := Vector3(bounds.position.x, 0.0, bounds.position.y)
	var owned := owned_channels(terrain, through)
	var planes: Array[Image] = []
	for channel in CHANNELS:
		if not owned.has(String(channel)):
			planes.append(null)
			continue
		var composed: Dictionary = StrataLayerData.compose_dense(StrataProcedural._capture_layers(terrain, channel, through), channel, origin, step_x, step_y, resolution, terrain.base_bounds, false, 0.0)
		if not composed.get("ok", false):
			return _error("Macro channel %s: %s" % [channel, composed.get("message", "composition failed")])
		planes.append(composed.image)
	var packed := _pack(planes, resolution)
	if not packed.ok: return packed
	var token := StrataProcedural.revision_token(through if through != null else layers[-1], "cumulative") if not layers.is_empty() else {"terrain": weakref(terrain), "mode": "empty", "bounds": terrain.base_bounds, "transform": terrain.global_transform}
	return {"ok": true, "empty": owned.is_empty(), "image": packed.image, "bounds": bounds, "resolution": resolution, "spacing": Vector2(step_x.x, step_y.z), "sample_origin": origin, "sample_step_x": step_x, "sample_step_y": step_y, "owned_channels": owned, "token": token, "report": {"min": packed.min, "max": packed.max, "clamped": packed.clamped, "bytes": packed.image.get_data().size(), "cpu_ms": (Time.get_ticks_usec() - started) / 1000.0}}

## Packs four matching RF images (tint r, g, b, ao) into a clamped RGBAH map.
## A null plane is neutral. Returns {ok, image, min, max, clamped}.
static func pack(tint_r: Image, tint_g: Image, tint_b: Image, ao: Image) -> Dictionary:
	var size := Vector2i.ZERO
	for plane in [tint_r, tint_g, tint_b, ao]:
		if plane == null: continue
		if size == Vector2i.ZERO: size = plane.get_size()
		if plane.get_size() != size: return _error("Macro planes must have matching sizes")
	if size == Vector2i.ZERO: return _error("Pack needs at least one plane to define its size")
	return _pack([tint_r, tint_g, tint_b, ao], size)

static func _pack(planes: Array, size: Vector2i) -> Dictionary:
	if size.x < 2 or size.y < 2 or size.x > MAX_SIDE or size.y > MAX_SIDE:
		return _error("Macro map needs 2..%d texels per axis" % MAX_SIDE)
	var count := size.x * size.y
	var values: Array[PackedFloat32Array] = []
	var minimum := Color(NEUTRAL, NEUTRAL, NEUTRAL, NEUTRAL)
	var maximum := minimum
	var clamped := PackedStringArray()
	for index in range(4):
		var plane: Image = planes[index]
		var upper := 1.0 if index == 3 else TINT_MAX
		var data := PackedFloat32Array()
		if plane == null:
			data.resize(count)
			data.fill(NEUTRAL)
		else:
			if plane.is_compressed() or plane.get_format() != Image.FORMAT_RF or plane.get_size() != size:
				return _error("Macro planes must be uncompressed RF images of %s" % size)
			data = plane.get_data().to_float32_array()
			var scanned := StrataRuntimeData._scan_floats(data, size)
			if not scanned.ok: return _error("Macro channel %s contains nonfinite values" % CHANNELS[index])
			if scanned.min < 0.0 or scanned.max > upper:
				clamped.append(String(CHANNELS[index]))
				for texel in range(count):
					data[texel] = clampf(data[texel], 0.0, upper)
				scanned = {"min": clampf(scanned.min, 0.0, upper), "max": clampf(scanned.max, 0.0, upper)}
			minimum[index] = scanned.min
			maximum[index] = scanned.max
		values.append(data)
	# Interleave natively: rows a, b, g, r of an RF strip rotated clockwise
	# become texels (r, g, b, a). Strips bound each temporary image width.
	var interleaved := PackedByteArray()
	var strip_rows := maxi(1, _STRIP_TEXELS / size.x)
	for first_row in range(0, size.y, strip_rows):
		var start := first_row * size.x
		var length := mini(strip_rows, size.y - first_row) * size.x
		var stacked := PackedByteArray()
		for index in [3, 2, 1, 0]:
			stacked.append_array(values[index].slice(start, start + length).to_byte_array())
		var strip := Image.create_from_data(length, 4, false, Image.FORMAT_RF, stacked)
		strip.rotate_90(CLOCKWISE)
		interleaved.append_array(strip.get_data())
	var image := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBAF, interleaved)
	image.convert(Image.FORMAT_RGBAH)
	return {"ok": true, "image": image, "min": minimum, "max": maximum, "clamped": clamped}

## Neutral (1, 1, 1, 1) map of the given size.
static func neutral_image(size: Vector2i) -> Image:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBAH)
	image.fill(Color(NEUTRAL, NEUTRAL, NEUTRAL, NEUTRAL))
	return image

static func validate_image(image: Image, bounds: Rect2) -> Dictionary:
	var layout := StrataRuntimeData.validate_macro_layout(image, bounds)
	if not layout.ok: return layout
	return StrataRuntimeData.scan_macro_image(image)

## Shader binding {ok, image, bounds, resolution, uv_scale, uv_offset}:
## uv = local_xz * uv_scale + uv_offset, linear filter, clamp to edge.
static func binding(image: Image, bounds: Rect2) -> Dictionary:
	return StrataRuntimeData.macro_binding(image, bounds)

## CPU reference of the shader lookup: Color(tint r, g, b, ao).
static func sample(image: Image, bounds: Rect2, position: Vector2) -> Color:
	return StrataRuntimeData.sample_macro_image(image, bounds, position)
