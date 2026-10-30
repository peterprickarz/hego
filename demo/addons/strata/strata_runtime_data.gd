class_name StrataRuntimeData
extends Resource
## Compiled runtime terrain. Built-in types only: it loads, samples, collides and
## navigates without the native terrain extension, HEGo or Houdini.
##
## Lattice: sample (i, j) lies at bounds.position + spacing * (i, j) in
## terrain-local XZ, endpoints included. Cell (x, z) spans samples a=(x, z),
## b=(x+1, z), c=(x, z+1), d=(x+1, z+1) and is split into triangles (a, b, c)
## and (b, d, c). This is Godot Physics' HeightMapShape3D triangulation and the
## canonical surface for CPU queries, collision and navigation.

enum Status { OK, OUTSIDE, ABSENT, NOT_RESIDENT, HOLE }
enum Interpolation { TRIANGLE, BILINEAR }

const FORMAT_VERSION := 1
## Cell masks are 0 (solid) or 255 (masked); float inputs use value >= 0.5.
const MASK_SET := 255
const MAX_SAMPLES := 20 * 1024 * 1024
const MAX_PAYLOAD_BYTES := 512 * 1024 * 1024
## Optional terrain-wide macro map: RGBAH, RGB linear tint in 0..2 and A ambient
## occlusion in 0..1, neutral (1, 1, 1, 1). Its own endpoint-aligned lattice.
const MACRO_MAX_SIDE := 4097
const MACRO_TINT_MAX := 2.0
const MACRO_NEUTRAL := Color(1.0, 1.0, 1.0, 1.0)

@export var format_version := FORMAT_VERSION
## Increments on every published bake of the owning terrain.
@export var bake_revision := 0
@export var resolution := Vector2i.ZERO
## (resolution - 1) cells, row-major. Empty means no masked cells.
@export var holes := PackedByteArray()
@export var nav_exclusions := PackedByteArray()
## Channels listed here were retained by the bake. Evicted ones stay listed.
@export var channel_names := PackedStringArray()
## Optional renderer controls, stored as validated by the bake.
@export var material_ids: Image:
	set(value):
		material_ids = value
		_payload_checked = false
@export var material_weights: Image:
	set(value):
		material_weights = value
		_payload_checked = false
## Optional terrain-wide tint/AO (see set_macro()). Null means none, which is
## also how resources saved before this field load.
@export var macro_image: Image:
	set(value):
		macro_image = value
		_payload_checked = false
## Optional renderer settings captured by the bake (a duplicate, so later
## authoring edits never change a published artifact). Typed as Resource so
## runtime-only projects can parse this script without the settings class.
@export var render_settings: Resource

# Floating-point payloads persist as raw bytes (see _get_property_list): Godot
# 4.4 text resources write floats with ~6 significant digits, which would
# silently move a .tres/.tscn bake away from its collision and render data.
var bounds := Rect2()
var heights := PackedFloat32Array():
	set(value):
		heights = value
		_payload_checked = false
		_height_scan = {}
var height_min := 0.0
var height_max := 0.0
## Terrain-local XZ of the first and last macro texel centres (endpoints).
var macro_bounds := Rect2():
	set(value):
		macro_bounds = value
		_payload_checked = false
## name -> {"values": PackedFloat32Array, "coverage": PackedFloat32Array} on the
## height lattice. Values are signed and unclamped; coverage > 0 means defined.
var channels: Dictionary = {}:
	set(value):
		channels = value
		_payload_checked = false
		_channel_scans = {}
var _decode_error := ""
var _payload_checked := false
var _payload_validation: Dictionary = {}
var _height_scan: Dictionary = {}
var _channel_scans: Dictionary = {}

func _get_property_list() -> Array[Dictionary]:
	var shown := PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY
	return [
		{"name": "lattice_data", "type": TYPE_PACKED_BYTE_ARRAY, "usage": PROPERTY_USAGE_STORAGE},
		{"name": "height_data", "type": TYPE_PACKED_BYTE_ARRAY, "usage": PROPERTY_USAGE_STORAGE},
		{"name": "channel_data", "type": TYPE_DICTIONARY, "usage": PROPERTY_USAGE_STORAGE},
		{"name": "macro_lattice", "type": TYPE_PACKED_BYTE_ARRAY, "usage": PROPERTY_USAGE_STORAGE},
		{"name": "bounds", "type": TYPE_RECT2, "usage": shown},
		{"name": "macro_bounds", "type": TYPE_RECT2, "usage": shown},
		{"name": "height_min", "type": TYPE_FLOAT, "usage": shown},
		{"name": "height_max", "type": TYPE_FLOAT, "usage": shown},
	]

func _get(property: StringName) -> Variant:
	match property:
		&"lattice_data":
			return PackedFloat64Array([bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y, height_min, height_max]).to_byte_array()
		&"height_data":
			return heights.to_byte_array()
		&"channel_data":
			var encoded := {}
			for name in channels:
				encoded[name] = [channels[name].values.to_byte_array(), channels[name].coverage.to_byte_array()]
			return encoded
		&"macro_lattice":
			if macro_image == null: return PackedByteArray()
			return PackedFloat64Array([macro_bounds.position.x, macro_bounds.position.y, macro_bounds.size.x, macro_bounds.size.y]).to_byte_array()
	return null

func _set(property: StringName, value: Variant) -> bool:
	match property:
		&"lattice_data":
			if not value is PackedByteArray or (value as PackedByteArray).size() != 48:
				_decode_error = "Stored lattice header is malformed"
				return true
			var lattice: PackedFloat64Array = (value as PackedByteArray).to_float64_array()
			bounds = Rect2(lattice[0], lattice[1], lattice[2], lattice[3])
			height_min = lattice[4]
			height_max = lattice[5]
			return true
		&"height_data":
			if not value is PackedByteArray or (value as PackedByteArray).size() % 4 != 0 or (value as PackedByteArray).size() > MAX_SAMPLES * 4:
				_decode_error = "Stored height payload is not float32 data"
				heights = PackedFloat32Array()
				return true
			heights = (value as PackedByteArray).to_float32_array()
			_height_scan = _scan_floats(heights, resolution)
			if not _height_scan.ok: _decode_error = "Stored height payload contains nonfinite values"
			return true
		&"channel_data":
			channels = {}
			if not value is Dictionary:
				_decode_error = "Stored channel payload must be a Dictionary"
				return true
			var decoded_bytes := heights.size() * 4
			for name in value:
				if not value[name] is Array:
					_decode_error = "Stored channel %s payload is malformed" % name
					continue
				var entry: Array = value[name]
				if entry.size() != 2 or not entry[0] is PackedByteArray or not entry[1] is PackedByteArray or entry[0].size() % 4 != 0 or entry[1].size() % 4 != 0:
					_decode_error = "Stored channel %s payload is malformed" % name
					continue
				decoded_bytes += entry[0].size() + entry[1].size()
				if decoded_bytes > MAX_PAYLOAD_BYTES:
					_decode_error = "Stored runtime channels exceed the bounded payload budget"
					break
				channels[name] = {"values": entry[0].to_float32_array(), "coverage": entry[1].to_float32_array()}
				var values := _scan_floats(channels[name].values, resolution)
				var coverage := _scan_floats(channels[name].coverage, resolution)
				_channel_scans[name] = {"values": values, "coverage": coverage}
				if not values.ok or not coverage.ok or coverage.min < 0 or coverage.max > 1:
					_decode_error = "Stored channel %s values/coverage are invalid" % name
			return true
		&"macro_lattice":
			if not value is PackedByteArray or not (value as PackedByteArray).size() in [0, 32]:
				_decode_error = "Stored macro lattice header is malformed"
				return true
			if (value as PackedByteArray).is_empty():
				macro_bounds = Rect2()
				return true
			var lattice: PackedFloat64Array = (value as PackedByteArray).to_float64_array()
			macro_bounds = Rect2(lattice[0], lattice[1], lattice[2], lattice[3])
			return true
	return false

func get_spacing() -> float:
	return bounds.size.x / float(resolution.x - 1) if resolution.x > 1 else 0.0

func get_cell_resolution() -> Vector2i:
	return resolution - Vector2i.ONE

func is_resident() -> bool:
	return resolution.x > 1 and heights.size() == resolution.x * resolution.y

## Resident payloads are scanned once after assignment/decoding, then reused.
## Treat published arrays as immutable. Call validate_payload() explicitly after
## intentional in-place array edits, which bypass Godot property setters.
func validate() -> Dictionary:
	if not _decode_error.is_empty():
		return _error(_decode_error)
	if format_version != FORMAT_VERSION:
		return _error("Unsupported runtime terrain format version %d" % format_version)
	if resolution.x < 2 or resolution.y < 2 or resolution.x * resolution.y > MAX_SAMPLES:
		return _error("Runtime terrain needs 2..%d samples with at least 2 per axis" % MAX_SAMPLES)
	if not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite() or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return _error("Runtime terrain bounds must be finite and positive")
	var spacing_z := bounds.size.y / float(resolution.y - 1)
	if not is_equal_approx(get_spacing(), spacing_z):
		return _error("Runtime terrain requires uniform spacing (%s x %s)" % [get_spacing(), spacing_z])
	if not heights.is_empty() and heights.size() != resolution.x * resolution.y:
		return _error("Height payload does not match its resolution")
	if not is_finite(height_min) or not is_finite(height_max) or height_min > height_max:
		return _error("Height range must be finite")
	var cells := (resolution.x - 1) * (resolution.y - 1)
	if not holes.is_empty() and holes.size() != cells or not nav_exclusions.is_empty() and nav_exclusions.size() != cells:
		return _error("Cell masks must have (width - 1) x (height - 1) entries")
	if not _canonical_mask(holes) or not _canonical_mask(nav_exclusions):
		return _error("Cell masks must contain only 0 and 255")
	var names := {}
	for name in channel_names:
		if name.strip_edges().is_empty() or names.has(name): return _error("Runtime channel manifest names must be nonempty and unique")
		names[name] = true
	var payload_bytes := heights.size() * 4 + holes.size() + nav_exclusions.size()
	for name in channels:
		if not channel_names.has(String(name)):
			return _error("Channel payload %s is missing from the manifest" % name)
		if not channels[name] is Dictionary: return _error("Channel %s payload must be a Dictionary" % name)
		var entry: Dictionary = channels[name]
		if not entry.get("values") is PackedFloat32Array or not entry.get("coverage") is PackedFloat32Array or entry.values.size() != resolution.x * resolution.y or entry.coverage.size() != entry.values.size():
			return _error("Channel %s payload does not match the height lattice" % name)
		payload_bytes += entry.values.size() * 8
	if (material_ids == null) != (material_weights == null):
		return _error("Material ids and weights must be provided together")
	if material_ids != null and (material_ids.is_compressed() or material_weights.is_compressed() or material_ids.get_width() < 2 or material_ids.get_height() < 2 or material_ids.get_width() > 1025 or material_ids.get_height() > 1025 or material_ids.get_size() != material_weights.get_size() or material_ids.get_format() != Image.FORMAT_RGBA8 or material_weights.get_format() != Image.FORMAT_RGBAF):
		return _error("Material controls need matching RGBA8 ids and RGBAF weights")
	if material_ids != null: payload_bytes += material_ids.get_data().size() + material_weights.get_data().size()
	if macro_image != null:
		var macro := validate_macro_layout(macro_image, macro_bounds)
		if not macro.ok: return macro
		payload_bytes += macro_image.get_data().size()
	if render_settings != null and not render_settings.has_method("parameters"):
		return _error("Runtime render settings must be an StrataRenderSettings resource")
	if payload_bytes > MAX_PAYLOAD_BYTES: return _error("Runtime payload exceeds the 512 MiB aggregate budget")
	if not _payload_checked:
		_payload_validation = _validate_resident_values()
		_payload_checked = true
	if not _payload_validation.get("ok", false): return _payload_validation
	if not heights.is_empty() and (height_min != _payload_validation.min or height_max != _payload_validation.max):
		return _error("Stored height extrema do not match the resident finite samples")
	return {"ok": true}

## Explicit ingestion/revalidation hook, including when callers edited a packed
## array in place. No native extension is required in a runtime-only project.
func validate_payload() -> Dictionary:
	_payload_checked = false
	_height_scan = {}
	_channel_scans = {}
	return validate()

static func _scan_floats(values: PackedFloat32Array, size: Vector2i) -> Dictionary:
	if values.is_empty(): return {"ok": true, "min": 0.0, "max": 0.0}
	if ClassDB.class_exists("StrataLayerData") and size.x > 0 and size.x * size.y == values.size():
		var validator: Object = ClassDB.instantiate("StrataLayerData")
		var image := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RF, values.to_byte_array())
		return validator.call("validate_dense", image)
	var minimum := INF
	var maximum := -INF
	for value in values:
		if not is_finite(value): return _error("Resident runtime values must be finite")
		minimum = minf(minimum, value); maximum = maxf(maximum, value)
	return {"ok": true, "min": minimum, "max": maximum}

func _validate_resident_values() -> Dictionary:
	if _height_scan.is_empty(): _height_scan = _scan_floats(heights, resolution)
	var checked := _height_scan
	if not checked.ok: return checked
	for name in channels:
		var entry: Dictionary = channels[name]
		if not _channel_scans.has(name): _channel_scans[name] = {"values": _scan_floats(entry.values, resolution), "coverage": _scan_floats(entry.coverage, resolution)}
		var values: Dictionary = _channel_scans[name].values
		if not values.ok: return _error("Channel %s contains nonfinite values" % name)
		var coverage: Dictionary = _channel_scans[name].coverage
		if not coverage.ok or coverage.min < 0 or coverage.max > 1: return _error("Channel %s coverage must be finite and in 0..1" % name)
	if material_ids != null:
		# Four categorical bytes at once; every byte must have its upper three
		# bits clear (pool IDs 0..31). No per-texel Image calls are needed.
		for word in material_ids.get_data().to_int32_array():
			if word & 0xe0e0e0e0: return _error("Material IDs must be in 0..31")
		var weights := _scan_floats(material_weights.get_data().to_float32_array(), Vector2i(material_weights.get_width() * 4, material_weights.get_height()))
		if not weights.ok or weights.min < 0: return _error("Material weights must be finite and nonnegative")
	if macro_image != null:
		var macro := scan_macro_image(macro_image)
		if not macro.ok: return macro
	return checked

static func _canonical_mask(mask: PackedByteArray) -> bool:
	return mask.count(0) + mask.count(MASK_SET) == mask.size()

static func _error(message: String) -> Dictionary:
	return {"ok": false, "message": message}

## Converts a cell mask Image/PackedByteArray into canonical bytes. Float images
## mark value >= 0.5; 8-bit images mark byte >= 128 (the same 0.5 threshold).
## Already-canonical bytes are accepted without a per-cell script loop.
static func canonicalize_cell_mask(source: Variant, cells: Vector2i) -> Dictionary:
	if source == null:
		return {"ok": true, "mask": PackedByteArray()}
	var bytes := PackedByteArray()
	var float_values := PackedFloat32Array()
	if source is Image:
		var image: Image = source
		if image.get_size() != cells or image.is_compressed():
			return _error("Cell mask must be an uncompressed %dx%d image (one texel per cell)" % [cells.x, cells.y])
		match image.get_format():
			Image.FORMAT_L8, Image.FORMAT_R8:
				bytes = image.get_data()
			Image.FORMAT_RF:
				float_values = image.get_data().to_float32_array()
			_:
				return _error("Cell mask images must be L8, R8 or RF")
	elif source is PackedByteArray:
		bytes = source
		if bytes.is_empty():
			return {"ok": true, "mask": bytes, "count": 0}
		if bytes.size() != cells.x * cells.y:
			return _error("Cell mask byte count must be %d" % (cells.x * cells.y))
	else:
		return _error("Cell mask must be an Image or PackedByteArray")
	if not float_values.is_empty():
		bytes.resize(float_values.size())
		for index in range(float_values.size()):
			var value := float_values[index]
			if not is_finite(value):
				return _error("Cell mask values must be finite")
			bytes[index] = MASK_SET if value >= 0.5 else 0
	elif not _canonical_mask(bytes):
		bytes = bytes.duplicate()
		for index in range(bytes.size()):
			bytes[index] = MASK_SET if bytes[index] >= 128 else 0
	if bytes.count(MASK_SET) == 0:
		bytes = PackedByteArray()
	return {"ok": true, "mask": bytes, "count": bytes.count(MASK_SET)}

## Byte counts of resident payloads, for budgeting and export reports.
func get_manifest() -> Dictionary:
	var channel_entries: Array = []
	var total := heights.size() * 4 + holes.size() + nav_exclusions.size()
	for name in channel_names:
		var entry: Dictionary = channels.get(name, {})
		var bytes := 0
		if not entry.is_empty():
			bytes = entry.values.size() * 4 + entry.coverage.size() * 4
		channel_entries.append({"name": name, "resident": not entry.is_empty(), "bytes": bytes})
		total += bytes
	var material_bytes := 0
	if material_ids != null:
		material_bytes = material_ids.get_data().size() + material_weights.get_data().size()
	total += material_bytes
	var macro_bytes := macro_image.get_data().size() if macro_image != null else 0
	total += macro_bytes
	return {"format_version": format_version, "bake_revision": bake_revision, "bounds": bounds, "resolution": resolution, "spacing": get_spacing(), "height_bytes": heights.size() * 4, "hole_cells": holes.count(MASK_SET), "nav_excluded_cells": nav_exclusions.count(MASK_SET), "mask_bytes": holes.size() + nav_exclusions.size(), "channels": channel_entries, "material_bytes": material_bytes, "macro_bytes": macro_bytes, "macro_resolution": macro_image.get_size() if macro_image != null else Vector2i.ZERO, "macro_bounds": macro_bounds, "total_bytes": total}

## Frees a retained channel payload while keeping its manifest entry, so later
## queries report NOT_RESIDENT instead of ABSENT.
func evict_channel(name: StringName) -> void:
	if channels.erase(String(name)):
		emit_changed()

## Independent copy for runtime export.
func duplicate_runtime() -> StrataRuntimeData:
	var copy := StrataRuntimeData.new()
	copy.bake_revision = bake_revision
	copy.bounds = bounds
	copy.resolution = resolution
	copy.heights = heights.duplicate()
	copy.height_min = height_min
	copy.height_max = height_max
	copy.holes = holes.duplicate()
	copy.nav_exclusions = nav_exclusions.duplicate()
	copy.channels = channels.duplicate(true)
	copy.channel_names = channel_names.duplicate()
	copy.material_ids = material_ids.duplicate() if material_ids != null else null
	copy.material_weights = material_weights.duplicate() if material_weights != null else null
	copy.macro_image = macro_image.duplicate() if macro_image != null else null
	copy.macro_bounds = macro_bounds
	copy.render_settings = render_settings.duplicate(true) if render_settings != null else null
	return copy

## Terrain-wide tint/AO. image: uncompressed RGBAH without mipmaps, 2..4097 per
## axis; RGB tint finite in 0..2, A occlusion in 0..1, neutral (1, 1, 1, 1).
## bounds: terrain-local XZ of the first/last texel centres. Pass null to clear.
## A rejected map leaves the previous one untouched.
func set_macro(image: Image, bounds: Rect2 = Rect2()) -> Dictionary:
	if image == null:
		macro_image = null
		macro_bounds = Rect2()
		return {"ok": true}
	var layout := validate_macro_layout(image, bounds)
	if not layout.ok: return layout
	var scanned := scan_macro_image(image)
	if not scanned.ok: return scanned
	macro_image = image
	macro_bounds = bounds
	return {"ok": true, "min": scanned.min, "max": scanned.max}

func has_macro() -> bool:
	return macro_image != null

## Shader binding of the stored map ({ok: false} without one); see macro_binding().
func get_macro_binding() -> Dictionary:
	if macro_image == null: return {"ok": false, "message": "No terrain-wide tint/AO map"}
	return macro_binding(macro_image, macro_bounds)

## {status, tint: Color (rgb, a = 1), ao}. Bilinear between texel centres, like
## a linear-filtered clamp-to-edge texture. ABSENT/OUTSIDE return neutral values.
func sample_macro(position: Vector2) -> Dictionary:
	if macro_image == null:
		return {"status": Status.ABSENT, "tint": MACRO_NEUTRAL, "ao": 1.0}
	if not position.is_finite() or position.x < macro_bounds.position.x or position.y < macro_bounds.position.y or position.x > macro_bounds.end.x or position.y > macro_bounds.end.y:
		return {"status": Status.OUTSIDE, "tint": MACRO_NEUTRAL, "ao": 1.0}
	var value := sample_macro_image(macro_image, macro_bounds, position)
	return {"status": Status.OK, "tint": Color(value.r, value.g, value.b, 1.0), "ao": value.a}

static func validate_macro_layout(image: Image, bounds: Rect2) -> Dictionary:
	if image == null: return _error("Macro map is missing")
	if image.is_compressed() or image.has_mipmaps() or image.get_format() != Image.FORMAT_RGBAH:
		return _error("Macro map must be an uncompressed RGBAH image without mipmaps")
	if image.get_width() < 2 or image.get_height() < 2 or image.get_width() > MACRO_MAX_SIDE or image.get_height() > MACRO_MAX_SIDE:
		return _error("Macro map needs 2..%d texels per axis" % MACRO_MAX_SIDE)
	if not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite() or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return _error("Macro map bounds must be finite and positive")
	return {"ok": true}

## Per-channel finite/range scan. Each channel is extracted by an engine-side
## format conversion of the byte payload shifted by whole half-floats, so no
## per-texel script loop runs when the native validator is present.
static func scan_macro_image(image: Image) -> Dictionary:
	var bytes := image.get_data()
	var minimum := Color(); var maximum := Color()
	for channel in range(4):
		var shifted := bytes.slice(channel * 2)
		shifted.resize(bytes.size())
		var extracted := Image.create_from_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBAH, shifted)
		extracted.convert(Image.FORMAT_RF)
		var scanned := _scan_floats(extracted.get_data().to_float32_array(), image.get_size())
		if not scanned.ok: return _error("Macro map values must be finite")
		minimum[channel] = scanned.min; maximum[channel] = scanned.max
	if minimum.r < 0.0 or minimum.g < 0.0 or minimum.b < 0.0 or maximum.r > MACRO_TINT_MAX or maximum.g > MACRO_TINT_MAX or maximum.b > MACRO_TINT_MAX:
		return _error("Macro tint must be in 0..%s" % MACRO_TINT_MAX)
	if minimum.a < 0.0 or maximum.a > 1.0:
		return _error("Macro ambient occlusion must be in 0..1")
	return {"ok": true, "min": minimum, "max": maximum}

## Shader contract: texel (i, j) centre lies at bounds.position + (i, j) *
## bounds.size / (resolution - 1), endpoints included. With linear filtering
## and clamp-to-edge, sample uv = local_xz * uv_scale + uv_offset.
static func macro_binding(image: Image, bounds: Rect2) -> Dictionary:
	var layout := validate_macro_layout(image, bounds)
	if not layout.ok: return layout
	var size := Vector2(image.get_size())
	var uv_scale := (size - Vector2.ONE) / (bounds.size * size)
	return {"ok": true, "image": image, "bounds": bounds, "resolution": image.get_size(), "uv_scale": uv_scale, "uv_offset": Vector2(0.5, 0.5) / size - bounds.position * uv_scale}

## CPU reference of the shader lookup (clamped to the bounds).
static func sample_macro_image(image: Image, bounds: Rect2, position: Vector2) -> Color:
	var last := image.get_size() - Vector2i.ONE
	var lattice := ((position - bounds.position) / bounds.size * Vector2(last)).clamp(Vector2.ZERO, Vector2(last))
	var cell := Vector2i(mini(floori(lattice.x), last.x - 1), mini(floori(lattice.y), last.y - 1))
	var f := lattice - Vector2(cell)
	var top := image.get_pixel(cell.x, cell.y).lerp(image.get_pixel(cell.x + 1, cell.y), f.x)
	var bottom := image.get_pixel(cell.x, cell.y + 1).lerp(image.get_pixel(cell.x + 1, cell.y + 1), f.x)
	return top.lerp(bottom, f.y)

## Renderer inputs. These copy payload bytes once; no per-pixel loops.
func create_height_image() -> Image:
	if not is_resident():
		return null
	return Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RF, heights.to_byte_array())

## Same shape as StrataProcedural.compile_heightfield(), for renderers that
## bind a compiled RF field (StrataRenderer.set_compiled_field()).
func to_compiled_field() -> Dictionary:
	if not is_resident():
		return {"ok": false, "message": "Runtime heights are not resident"}
	var spacing := get_spacing()
	return {"ok": true, "image": create_height_image(), "min": height_min, "max": height_max, "bounds": bounds, "resolution": resolution, "sample_origin": Vector3(bounds.position.x, 0.0, bounds.position.y), "sample_step_x": Vector3(spacing, 0.0, 0.0), "sample_step_y": Vector3(0.0, 0.0, spacing), "bake_revision": bake_revision}

## L8 image of size (width - 1, height - 1): 255 marks a hole cell. Sample it with
## nearest filtering at floor((local - bounds.position) / spacing).
func get_hole_image() -> Image:
	return _mask_image(holes)

func get_nav_exclusion_image() -> Image:
	return _mask_image(nav_exclusions)

func _mask_image(mask: PackedByteArray) -> Image:
	var cells := get_cell_resolution()
	if cells.x < 1 or cells.y < 1:
		return null
	if mask.is_empty():
		return Image.create(cells.x, cells.y, false, Image.FORMAT_L8)
	return Image.create_from_data(cells.x, cells.y, false, Image.FORMAT_L8, mask)

func is_hole_cell(cell: Vector2i) -> bool:
	return _mask_at(holes, cell)

func is_nav_excluded_cell(cell: Vector2i) -> bool:
	return _mask_at(nav_exclusions, cell)

## Hole or navigation exclusion: cells that never carry navigation source faces.
func is_nav_blocked_cell(cell: Vector2i) -> bool:
	return _mask_at(holes, cell) or _mask_at(nav_exclusions, cell)

func _mask_at(mask: PackedByteArray, cell: Vector2i) -> bool:
	if mask.is_empty() or cell.x < 0 or cell.y < 0 or cell.x >= resolution.x - 1 or cell.y >= resolution.y - 1:
		return false
	return mask[cell.y * (resolution.x - 1) + cell.x] == MASK_SET

func get_height_at(index: Vector2i) -> float:
	return heights[index.y * resolution.x + index.x]

func contains_local(position: Vector2) -> bool:
	return position.x >= bounds.position.x and position.y >= bounds.position.y and position.x <= bounds.end.x and position.y <= bounds.end.y

## Continuous lattice coordinates of a terrain-local XZ position.
func local_to_lattice(position: Vector2) -> Vector2:
	return (position - bounds.position) / get_spacing()

func lattice_to_local(lattice: Vector2) -> Vector2:
	return bounds.position + lattice * get_spacing()

## Cells whose closed area contains the point (one, two or four).
func cells_at(position: Vector2) -> Array[Vector2i]:
	var lattice := local_to_lattice(position)
	var cells_x := _cell_candidates(lattice.x, resolution.x - 1)
	var cells_z := _cell_candidates(lattice.y, resolution.y - 1)
	var result: Array[Vector2i] = []
	for z in cells_z:
		for x in cells_x:
			result.append(Vector2i(x, z))
	return result

static func _cell_candidates(coordinate: float, count: int) -> PackedInt32Array:
	var base := floori(coordinate)
	var result := PackedInt32Array()
	if float(base) == coordinate and base > 0:
		result.append(base - 1)
	if base < count:
		result.append(maxi(base, 0))
	elif result.is_empty():
		result.append(count - 1)
	return result

## A point is in a hole only if every cell touching it is a hole, so the solid
## side of a hole edge keeps its surface (matching the omitted triangles).
func is_hole_at(position: Vector2) -> bool:
	if holes.is_empty() or not contains_local(position):
		return false
	for cell in cells_at(position):
		if not is_hole_cell(cell):
			return false
	return true

## {status, value}. TRIANGLE matches collision/navigation exactly. BILINEAR
## matches the current renderer's filtered height texture instead.
func sample_height(position: Vector2, interpolation: int = Interpolation.TRIANGLE, ignore_holes := false) -> Dictionary:
	if not position.is_finite() or not contains_local(position):
		return {"status": Status.OUTSIDE, "value": NAN}
	if not is_resident():
		return {"status": Status.NOT_RESIDENT, "value": NAN}
	var cell := Vector2i(-1, -1)
	for candidate in cells_at(position):
		if ignore_holes or not is_hole_cell(candidate):
			cell = candidate
			break
	if cell.x < 0:
		return {"status": Status.HOLE, "value": NAN}
	var local := local_to_lattice(position) - Vector2(cell)
	return {"status": Status.OK, "value": _interpolate(heights, cell, local, interpolation)}

func _interpolate(values: PackedFloat32Array, cell: Vector2i, local: Vector2, interpolation: int) -> float:
	var row := cell.y * resolution.x + cell.x
	var a := values[row]
	var b := values[row + 1]
	var c := values[row + resolution.x]
	var d := values[row + resolution.x + 1]
	var fx := clampf(local.x, 0.0, 1.0)
	var fz := clampf(local.y, 0.0, 1.0)
	if interpolation == Interpolation.BILINEAR:
		return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fz)
	if fx + fz <= 1.0:
		return a + (b - a) * fx + (c - a) * fz
	return d + (c - d) * (1.0 - fx) + (b - d) * (1.0 - fz)

## Batch query: values (NAN unless status is OK) and per-point Status bytes.
func sample_heights(positions: PackedVector2Array, interpolation: int = Interpolation.TRIANGLE) -> Dictionary:
	var values := PackedFloat32Array()
	var statuses := PackedByteArray()
	values.resize(positions.size())
	statuses.resize(positions.size())
	for index in range(positions.size()):
		var sampled := sample_height(positions[index], interpolation)
		values[index] = sampled.value
		statuses[index] = sampled.status
	return {"values": values, "status": statuses}

## World-space query through the runtime/authoring terrain's global transform.
## Returns the local query plus the world-space surface position when OK.
func sample_height_world(world_position: Vector3, terrain_transform: Transform3D, interpolation: int = Interpolation.TRIANGLE) -> Dictionary:
	var local := terrain_transform.affine_inverse() * world_position
	var result := sample_height(Vector2(local.x, local.z), interpolation)
	if result.status == Status.OK:
		result.position = terrain_transform * Vector3(local.x, result.value, local.z)
	return result

func sample_heights_world(world_positions: PackedVector3Array, terrain_transform: Transform3D, interpolation: int = Interpolation.TRIANGLE) -> Dictionary:
	var inverse := terrain_transform.affine_inverse()
	var local := PackedVector2Array()
	local.resize(world_positions.size())
	for index in range(world_positions.size()):
		var point := inverse * world_positions[index]
		local[index] = Vector2(point.x, point.z)
	var result := sample_heights(local, interpolation)
	var positions := PackedVector3Array()
	positions.resize(world_positions.size())
	for index in range(world_positions.size()):
		positions[index] = terrain_transform * Vector3(local[index].x, result.values[index], local[index].y)
	result.positions = positions
	return result

## {status, value, coverage}. Coverage-weighted bilinear over defined corners,
## like native layer sampling; a defined zero is OK, never ABSENT.
func sample_channel(name: StringName, position: Vector2) -> Dictionary:
	if not position.is_finite() or not contains_local(position):
		return {"status": Status.OUTSIDE, "value": NAN, "coverage": 0.0}
	if not channel_names.has(String(name)):
		return {"status": Status.ABSENT, "value": NAN, "coverage": 0.0}
	var entry: Dictionary = channels.get(String(name), {})
	if entry.is_empty():
		return {"status": Status.NOT_RESIDENT, "value": NAN, "coverage": 0.0}
	var lattice := local_to_lattice(position)
	var cell := Vector2i(mini(floori(lattice.x), resolution.x - 2), mini(floori(lattice.y), resolution.y - 2))
	var f := (lattice - Vector2(cell)).clamp(Vector2.ZERO, Vector2.ONE)
	var values: PackedFloat32Array = entry.values
	var coverage: PackedFloat32Array = entry.coverage
	var numerator := 0.0
	var weight_sum := 0.0
	var covered := 0.0
	for corner: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
		var weight := (f.x if corner.x == 1 else 1.0 - f.x) * (f.y if corner.y == 1 else 1.0 - f.y)
		var index := (cell.y + corner.y) * resolution.x + cell.x + corner.x
		if weight > 0.0 and coverage[index] > 0.0:
			numerator += values[index] * weight
			weight_sum += weight
			covered += coverage[index] * weight
	if weight_sum <= 0.0:
		return {"status": Status.ABSENT, "value": NAN, "coverage": 0.0}
	return {"status": Status.OK, "value": numerator / weight_sum, "coverage": covered}
