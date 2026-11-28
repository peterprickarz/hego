@tool
class_name HEGoCopiaInput
extends HEGoInputHandler

## Sends a Copia store to an HDA input as one point cloud, so a generator can see what the store
## holds and send back clear points for the cells it replaces (docs/copia/houdini.md).
##
## HEGo finds this handler because it extends [HEGoInputHandler]; neither HEGo nor Copia names
## the other. Wire the [code]CopiaStore3D[/code] node into an input row.
##
## Row settings (the input's settings dictionary):
## [codeblock]
## copia_input: true         marks the row as a Copia input (SETTINGS_MARKER)
## rect: [x0, z0, x1, z1]    optional; only the cells that intersect it, and only instance points
##                           inside it (store-local metres on X and Z). Absent = every cell.
## sets: ["roots"]           optional; only these sets get cell points. Empty = every set.
## exclude_sets: ["roots"]   optional; these sets get no cell points.
## points_of_sets: ["roads"] optional; the instance points of these sets (within rect) are sent
##                           too. Empty = none. Not limited by sets and exclude_sets.
## [/codeblock]
##
## The cloud has two kinds of points, told apart by [code]hegocopia_cell_point[/code]:
## [codeblock]
## cell points (hegocopia_cell_point = 1), one per cell and set that holds points:
##   P (cell centre, y 0), hegocopia_cell, hegocopia_set,
##   hegocopia_count (int), hegocopia_cell_min, hegocopia_cell_max (vector3)
## instance points (hegocopia_cell_point = 0), when points_of_sets names sets:
##   P, N, up, scale, hegocopia_object, hegocopia_set, hegocopia_keep,
##   Cd, hegocopia_custom + hegocopia_custom_w when the points have them, and each
##   pass-through column under its own name
## [/codeblock]
## Every attribute has a value for every point; the other kind's rows hold zero or an empty
## string. The cloud does not name its store: the HDA names the store it writes to with a
## string parameter of its own, stamped onto its output as [code]hegocopia_store[/code]
## (docs/copia/houdini.md). HEGo inputs carry int, float, vector3 and string
## attributes only, so the orientation travels as N + up + scale. The points are in the
## store's local space and are sent as they are: the HDA's output is written back into the
## store without a transform, so keep the HEGo node and the store at the same transform.
##
## Nothing is filtered or interpreted here: which cell points to turn into clear points is
## the generator's recipe. A generator that clears must be cooked against the store's current
## content, so a row with this marker makes its cook strict.

## Marks stored input settings as belonging to a Copia input, so its options and strict cook
## rule stay in force while the store is missing.
const SETTINGS_MARKER := "copia_input"

const OutputScript := preload("res://addons/hego_copia/hego_copia_output.gd")

const CELL := "hegocopia_cell"
const SET := "hegocopia_set"
const COUNT := "hegocopia_count"
const CELL_MIN := "hegocopia_cell_min"
const CELL_MAX := "hegocopia_cell_max"
const CELL_POINT := "hegocopia_cell_point"
## What an unbounded read covers, in metres.
const EVERYWHERE := Rect2(-1.0e9, -1.0e9, 2.0e9, 2.0e9)
## to_attributes names the sent columns by.
const RENAMES := {"object": "hegocopia_object", "set": SET, "keep": "hegocopia_keep", "custom": "hegocopia_custom", "custom_w": "hegocopia_custom_w"}
## What a row holds where the other kind of point has a value.
enum Kind { INT, FLOAT, VECTOR, STRING }


func handles(node: Node) -> bool:
	return OutputScript.is_store(node)


func claims_settings(settings: Dictionary) -> bool:
	return bool(settings.get(SETTINGS_MARKER, false)) or settings.has("points_of_sets") or settings.has("exclude_sets") or settings.has("rect")


## A generator that clears cells must see the store as it is.
func requires_strict_cook(settings: Dictionary) -> bool:
	return claims_settings(settings)


func sync(host: Node, existing_node: Variant, node: Node, settings: Dictionary) -> Dictionary:
	var options := settings.duplicate()
	var root := OutputScript.scene_root(host)
	options.store_path = str(root.get_path_to(node)) if root != null else str(node.get_path())
	options.input_path = str(settings.get(HEGoInputNodes.INPUT_PATH_KEY, options.store_path))
	var built := build_points(node, options)
	if not built.error.is_empty():
		return {"ok": false, "message": "Copia input: " + built.error}
	var input: HEGoInputNode = existing_node if existing_node is HEGoInputNode else HEGoInputNode.new()
	var created: Dictionary = await HEGoNodeUtil.checked_task(host, input.instantiate())
	if not created.ok:
		return {"ok": false, "message": "Copia input: " + str(created.message)}
	var uploaded: Dictionary = await HEGoNodeUtil.checked_task(host, input.set_geo(built.P, "points", PackedInt32Array(), PackedInt32Array(), built.attributes))
	if not uploaded.ok:
		return {"ok": false, "message": "Copia input: " + str(uploaded.message)}
	await HEGoNodeUtil.checked_task(host, input.set_transform(Transform3D.IDENTITY))
	return {"ok": true, "node": input}


## The point cloud of [param store] for the row settings in [param settings] (see the class
## comment): [code]{P, attributes, cell_count, instance_count, error}[/code], where
## [code]P[/code] and [code]attributes[/code] are exactly what [method HEGoInputNode.set_geo]
## takes (cell points first, then instance points; an empty store gives no points and no
## attributes, as HEGo rejects zero-length attribute arrays) and [code]error[/code] is empty
## unless the store or the settings cannot be used.
##
## Also read from [param settings]: [code]input_path[/code], the value of
## [code]_hego_node_path[/code] (default: [code]store_path[/code], else the store's path from its
## scene root).
##
## No loop over points: the columns come from the store as arrays and are joined as arrays.
static func build_points(store: Node, settings := {}) -> Dictionary:
	var result := {"P": PackedVector3Array(), "attributes": [], "cell_count": 0, "instance_count": 0, "error": ""}
	if not OutputScript.is_store(store):
		result.error = "the input is not a CopiaStore3D"
		return result
	if str(store.data_directory).is_empty():
		result.error = "the store has no data directory"
		return result
	var limit: Variant = _rect(settings.get("rect"))
	if limit == null:
		result.error = "rect must be [min_x, min_z, max_x, max_z] with max above min"
		return result
	var area: Rect2 = limit
	var exclude_list: Array = _names(settings.get("exclude_sets", []))
	if bool(settings.get("exclude_authored", false)) and store.has_method("list_authored_sets"):
		for authored_name: String in store.list_authored_sets():
			if not exclude_list.has(authored_name):
				exclude_list.append(authored_name)
	var cells: Dictionary = store.cell_points(area, PackedStringArray(_names(settings.get("sets", []))), PackedStringArray(exclude_list))
	if cells.is_empty() or not cells.has("P"):
		result.error = "the store's cells could not be read"
		return result
	var instances := {}
	var wanted := PackedStringArray(_names(settings.get("points_of_sets", [])))
	if not wanted.is_empty():
		var read: Dictionary = store.read_points(area if area.has_area() else EVERYWHERE, wanted, PackedStringArray())
		if read.is_empty() or not read.has("transform"):
			result.error = "the store's points could not be read"
			return result
		if int(read.get("count", 0)) > 0:
			var converted: Variant = OutputScript.native_static("CopiaPoints", "to_attributes", [read, RENAMES])
			if not converted is Dictionary or not converted.has("P"):
				result.error = "the Copia native library is not loaded"
				return result
			instances = converted
	var cell_rows: int = (cells.P as PackedVector3Array).size()
	var instance_rows: int = (instances.P as PackedVector3Array).size() if instances.has("P") else 0
	result.cell_count = cell_rows
	result.instance_count = instance_rows
	if cell_rows + instance_rows == 0:
		return result
	var store_path := str(settings.get("store_path", _default_path(store)))
	var columns := {}  # name -> packed array, in the order they are sent
	columns["P"] = _join(cells.P, instances.get("P"), cell_rows, instance_rows, Kind.VECTOR)
	# Cell points' own columns; the instance rows hold zero.
	columns[CELL] = _join(cells.cell, null, cell_rows, instance_rows, Kind.STRING)
	columns[COUNT] = _join(cells["count"], null, cell_rows, instance_rows, Kind.INT)
	columns[CELL_MIN] = _join(cells.cell_min, null, cell_rows, instance_rows, Kind.VECTOR)
	columns[CELL_MAX] = _join(cells.cell_max, null, cell_rows, instance_rows, Kind.VECTOR)
	# Both kinds have a set and the marker.
	columns[SET] = _join(cells.set, instances.get(SET), cell_rows, instance_rows, Kind.STRING)
	var ones := PackedInt32Array()
	ones.resize(cell_rows)
	ones.fill(1)
	columns[CELL_POINT] = _join(ones, null, cell_rows, instance_rows, Kind.INT)
	# Instance columns that are always there, and then the ones the points have.
	columns["N"] = _join(null, instances.get("N"), cell_rows, instance_rows, Kind.VECTOR)
	columns["up"] = _join(null, instances.get("up"), cell_rows, instance_rows, Kind.VECTOR)
	columns["scale"] = _join(null, instances.get("scale"), cell_rows, instance_rows, Kind.VECTOR)
	columns["hegocopia_object"] = _join(null, instances.get("hegocopia_object"), cell_rows, instance_rows, Kind.STRING)
	columns["hegocopia_keep"] = _join(null, instances.get("hegocopia_keep"), cell_rows, instance_rows, Kind.FLOAT)
	for name: String in instances:
		if columns.has(name):
			continue
		var column: Variant = instances[name]
		var kind := _kind_of(column)
		if kind >= 0:
			columns[name] = _join(null, column, cell_rows, instance_rows, kind)
	var attributes := []
	attributes.append({"name": HEGoInputNodes.NODE_PATH_ATTRIB, "type": "point", "value": str(settings.get("input_path", store_path))})
	for name: String in columns:
		if name != "P":
			attributes.append({"name": name, "type": "point", "values": columns[name]})
	result.P = columns.P
	result.attributes = attributes
	return result


## The node path of [param store] from its scene root, as the output resolves it.
static func _default_path(store: Node) -> String:
	var root := OutputScript.scene_root(store)
	return str(root.get_path_to(store)) if root != null else str(store.get_path())


## The settings rect as a Rect2 ([code]Rect2()[/code] when absent), or null when invalid.
static func _rect(value: Variant) -> Variant:
	if value == null:
		return Rect2()
	if value is Rect2:
		return value if (value as Rect2).has_area() else null
	if not (value is Array or value is PackedFloat32Array or value is PackedFloat64Array or value is PackedInt32Array) or value.size() != 4:
		return null
	for number in value:
		if not (number is float or number is int) or not is_finite(float(number)):
			return null
	var low := Vector2(float(value[0]), float(value[1]))
	var high := Vector2(float(value[2]), float(value[3]))
	if high.x <= low.x or high.y <= low.y:
		return null
	return Rect2(low, high - low)


## [param cell_values] for the first [param cell_rows] rows and [param instance_values] for the
## rows after them; a null part is zero (empty strings) of [param kind].
static func _join(cell_values: Variant, instance_values: Variant, cell_rows: int, instance_rows: int, kind: int) -> Variant:
	var joined: Variant = _zeros(kind, cell_rows) if cell_values == null else cell_values.duplicate()
	joined.append_array(_zeros(kind, instance_rows) if instance_values == null else instance_values)
	return joined


static func _zeros(kind: int, count: int) -> Variant:
	var zeros: Variant
	match kind:
		Kind.INT: zeros = PackedInt32Array()
		Kind.FLOAT: zeros = PackedFloat32Array()
		Kind.VECTOR: zeros = PackedVector3Array()
		_: zeros = PackedStringArray()
	zeros.resize(count)
	return zeros


static func _kind_of(column: Variant) -> int:
	if column is PackedInt32Array:
		return Kind.INT
	if column is PackedFloat32Array:
		return Kind.FLOAT
	if column is PackedVector3Array:
		return Kind.VECTOR
	if column is PackedStringArray:
		return Kind.STRING
	return -1


static func _names(value: Variant) -> Array:
	if value is String:
		return Array((value as String).split(",", false)).map(func(s: String) -> String: return s.strip_edges())
	return Array(value) if value is Array or value is PackedStringArray else []
