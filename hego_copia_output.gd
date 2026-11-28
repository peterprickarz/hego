@tool
class_name HEGoCopiaOutput
extends HEGoOutputHandler

## Writes a cook's points into a Copia store, on every cook of any HEGo node whose output
## carries them: the panel's Recook, a Session Sync update and a batch cook() all do the same.
##
## HEGo finds this handler because it extends [HEGoOutputHandler]; neither HEGo nor Copia
## names the other. It acts on points with a [code]hegocopia_object[/code] or a
## [code]hegocopia_clear[/code] point attribute (the table is in docs/copia/houdini.md):
##
## [codeblock]
## hegocopia_object  string  path of a CopiaObject (or a Mesh); non-empty = an instance
## P, orient or N + up, scale, pscale                    the transform
## Cd, hegocopia_custom (+ hegocopia_custom_w)           optional colour and custom data
## hegocopia_keep    float   optional density priority 0..1
## hegocopia_set     string  set to write into; blank = default
## hegocopia_store   string  node path of the CopiaStore3D from the scene root; blank = the only one
## hegocopia_clear   int     1 = a clear point: empties set hegocopia_set in cell hegocopia_cell
## hegocopia_cell    string  "cx_cz", on clear points only
## [/codeblock]
##
## Within one cook, clears are applied first and instances added after, per store. Nothing is
## cleared implicitly. One cook may write several sets and several stores.
##
## Options, from the host's metadata [code]hegocopia[/code] and the cook state key
## [code]hegocopia_options[/code] (a cook extension's cook_prepare can set it), the later one
## winning per key: [code]extra_attributes[/code] ([PackedStringArray]), point attributes that
## are loaded too and stored as pass-through columns.
##
## The result is left in the cook state under [code]hegocopia[/code]:
## [code]{stores: {path: result}, errors, warnings, point_count, clear_count, skipped_count}[/code]
## where each result is what [method write_attributes] returns.

## Metadata key of the host that holds the options.
const META_KEY := &"hegocopia"
## Cook state key of the options a cook extension sets.
const OPTIONS_KEY := "hegocopia_options"
## Cook state key the report is left under.
const REPORT_KEY := "hegocopia"

## The attribute that names the store a point goes to.
const STORE_ATTRIB := "hegocopia_store"
const OBJECT_ATTRIB := "hegocopia_object"
const CLEAR_ATTRIB := "hegocopia_clear"
## Copia's default attribute names, and the names used here for them.
const NAMES := {
	"P": "P", "orient": "orient", "N": "N", "up": "up", "scale": "scale", "pscale": "pscale",
	"Cd": "Cd", "object": OBJECT_ATTRIB, "set": "hegocopia_set", "custom": "hegocopia_custom",
	"custom_w": "hegocopia_custom_w", "keep": "hegocopia_keep", "clear": CLEAR_ATTRIB, "cell": "hegocopia_cell",
}
## Script of the store node.
const STORE_SCRIPT := "res://addons/copia/copia_store_3d.gd"
const EXTENSION := "res://addons/copia/bin/copia.gdextension"


func output_phase() -> String:
	return "copia_output"


func should_handle(summary: Dictionary) -> bool:
	return HEGoNodeUtil.output_has_attribute(summary, "point_attributes", OBJECT_ATTRIB) \
		or HEGoNodeUtil.output_has_attribute(summary, "point_attributes", CLEAR_ATTRIB)


func handle(context: HEGoOutputContext) -> void:
	var start_usec := Time.get_ticks_usec()
	var output: HEGoPointOutput = await context.await_task(context.asset.get_point_output())
	# should_handle() runs us whenever the summary could not be read: check for real.
	if output == null or not output.is_valid():
		return
	if not output.has_attribute(OBJECT_ATTRIB) and not output.has_attribute(CLEAR_ATTRIB):
		return
	var options := options_of(context.host, context.cook_state)
	var names := PackedStringArray()
	var wanted: Array = NAMES.values() + [STORE_ATTRIB] + Array(options.get("extra_attributes", PackedStringArray()))
	for name: String in wanted:
		if output.has_attribute(name) and not names.has(name):
			names.append(name)
	await context.await_task(output.load_attributes(names))
	var fetch_msec := HEGoCookTimings.elapsed_msec(start_usec)

	# Whole columns, as HEGo holds them; nothing is copied per point here.
	var split_usec := Time.get_ticks_usec()
	var columns := {}
	for name in names:
		columns[name] = output.get_attribute(name)
	var routes := split_routes(columns)
	var split_msec := HEGoCookTimings.elapsed_msec(split_usec)
	var write_usec := Time.get_ticks_usec()
	var report := write_routes(context.host, routes, options)
	context.cook_state[REPORT_KEY] = report
	HEGoLog.get_singleton().debug(HEGoNodeUtil.LOG_CATEGORY,
		"Copia output breakdown: fetch=%.3f ms, split=%.3f ms, convert_and_write=%.3f ms, total=%.3f ms, points=%d, routes=%d"
		% [fetch_msec, split_msec, HEGoCookTimings.elapsed_msec(write_usec), HEGoCookTimings.elapsed_msec(start_usec), output.get_point_count(), routes.size()])
	for message: String in report.warnings:
		HEGoLog.get_singleton().warning(HEGoNodeUtil.LOG_CATEGORY, "Copia: " + message)
	for message: String in report.errors:
		HEGoLog.get_singleton().error(HEGoNodeUtil.LOG_CATEGORY, "Copia: " + message)


## What [method handle] does with a cook's points once they are read: [param routes] maps each
## [code]hegocopia_store[/code] value to the attributes of the points that carry it (as
## [method write_attributes] takes them), and [param options] are the cook's options
## ([method options_of]). Store paths are resolved first and the points of every path that
## names the same store are written in one call, so a blank path and the store's own path (the
## spawned points and the clear points of the documented pattern) clear before they spawn.
## Returns the report the handler leaves in the cook state:
## [code]{stores: {path: result}, errors, warnings, point_count, clear_count, skipped_count}[/code].
static func write_routes(host: Node, routes: Dictionary, options := {}) -> Dictionary:
	var report := {"stores": {}, "errors": [], "warnings": [], "point_count": 0, "clear_count": 0, "skipped_count": 0}
	var write_options := {"extra": PackedStringArray(options.get("extra_attributes", PackedStringArray()))}
	var by_store := {}  # store path from the scene root -> {store, attributes}
	for path: String in routes:
		# A route without points has nothing to write and needs no store.
		if _row_count(routes[path]) == 0:
			continue
		var found := resolve_store(host, path)
		if found.store == null:
			report.errors.append(found.error)
			continue
		if not by_store.has(found.path):
			# The only route of a store is written as it is; a second one is merged into a copy.
			by_store[found.path] = {"store": found.store, "attributes": routes[path], "merged": false}
			continue
		var target: Dictionary = by_store[found.path]
		if not target.merged:
			var copy := {}
			merge_points(copy, target.attributes)
			target.attributes = copy
			target.merged = true
		merge_points(target.attributes, routes[path])
	for key: String in by_store:
		var result := write_attributes(by_store[key].attributes, by_store[key].store, write_options)
		report.stores[key] = result
		report.point_count += result.point_count
		report.clear_count += result.clear_count
		report.skipped_count += result.skipped_count
		for message: String in result.errors:
			(report.errors if not result.ok else report.warnings).append("%s: %s" % [key, message])
	return report


## Splits the columns of a cook's points ([code]{name: one value per point}[/code]) into the
## routes [method write_routes] takes, by [code]hegocopia_store[/code]: points without a store
## and points with a blank one both go to the route [code]""[/code] (the only store). The split
## is native and linear; when every point names the same store (the usual case) the columns are
## passed on without a copy.
static func split_routes(columns: Dictionary) -> Dictionary:
	if not columns.has(STORE_ATTRIB):
		return {"": columns}
	var routes: Variant = native_static("CopiaPoints", "split_by", [columns, STORE_ATTRIB])
	# Without the native library nothing can be written; write_attributes says so.
	return routes if routes is Dictionary else {"": columns}


## The options of a cook: the host's metadata, then [param cook_state]'s options on top.
static func options_of(host: Node, cook_state: Dictionary) -> Dictionary:
	var options := {}
	var meta: Variant = host.get_meta(META_KEY, {}) if host != null else {}
	if meta is Dictionary:
		options = (meta as Dictionary).duplicate()
	var later: Variant = cook_state.get(OPTIONS_KEY, {})
	if later is Dictionary:
		options.merge(later, true)
	return options


## Appends the points of [param more] to [param into], attribute by attribute. A column only
## one side has is padded with [code]null[/code] (a point without a value), so the rows stay
## aligned; padded columns become plain Arrays.
static func merge_points(into: Dictionary, more: Dictionary) -> void:
	var had := _row_count(into)
	var adding := _row_count(more)
	for name: String in more:
		if into.has(name):
			if typeof(into[name]) != typeof(more[name]):
				into[name] = Array(into[name])
				into[name].append_array(Array(more[name]))
			else:
				into[name].append_array(more[name])
		else:
			var column := []
			column.resize(had)
			column.append_array(Array(more[name]))
			into[name] = column if had > 0 else more[name].duplicate()
	for name: String in into:
		if not more.has(name) and adding > 0:
			var column := Array(into[name])
			column.resize(had + adding)
			into[name] = column


static func _row_count(columns: Dictionary) -> int:
	for name: String in columns:
		return columns[name].size()
	return 0


## Writes the points in [param attributes] into [param store]:
## [code]{name: one value per point}[/code] as HEGo delivers them (plain Arrays, [code]null[/code]
## where a point has no value; packed arrays work too), under the [code]hegocopia_[/code] names above.
##
## Clear points are applied first, then the instances added. [param options]:
## [code]extra[/code] ([PackedStringArray]), the names of attributes stored as pass-through
## columns. This is also the entry point for a cook extension that reads its points itself.
##
## Returns [code]{ok, errors, point_count, clear_count, skipped_count, write}[/code]. [code]ok[/code]
## says the store took what there was to write (nothing to write is ok); [code]errors[/code]
## also lists what the conversion skipped or ignored, so it can be non-empty when ok.
## [code]write[/code] is [method CopiaStore3D.write]'s result, empty when nothing was written.
static func write_attributes(attributes: Dictionary, store: Node, options := {}) -> Dictionary:
	var report := {"ok": false, "errors": [], "point_count": 0, "clear_count": 0, "skipped_count": 0, "write": {}}
	if not is_store(store):
		report.errors.append("the target is not a CopiaStore3D")
		return report
	if not attributes.has("P") and not attributes.has(OBJECT_ATTRIB) and not attributes.has(CLEAR_ATTRIB):
		report.errors.append("the points carry none of P, %s and %s" % [OBJECT_ATTRIB, CLEAR_ATTRIB])
		return report
	var core := NAMES.values()
	var columns := {}
	for name: String in core:
		if attributes.has(name):
			columns[name] = attributes[name]
	var extra := PackedStringArray()
	for name: String in PackedStringArray(options.get("extra", PackedStringArray())):
		if attributes.has(name) and not core.has(name) and name != STORE_ATTRIB:
			columns[name] = attributes[name]
			extra.append(name)
	var converted: Variant = native_static("CopiaPoints", "from_attributes", [columns, NAMES, extra])
	if not converted is Dictionary:
		report.errors.append("the Copia native library is not loaded")
		return report
	report.errors.append_array(converted.get("errors", PackedStringArray()))
	report.point_count = converted.get("point_count", 0)
	report.clear_count = converted.get("clear_count", 0)
	report.skipped_count = converted.get("skipped_count", 0)
	if report.point_count == 0 and report.clear_count == 0:
		report.ok = true
		return report
	var written: Dictionary = store.write_generated(converted.clears, converted.points) if store.has_method("write_generated") else store.write(converted.clears, converted.points)
	report.write = written
	report.ok = bool(written.get("ok", false))
	if not report.ok:
		report.errors.append("the store did not take the points: " + str(written.get("error", "write failed")))
	return report


## The store [param path] names, or the only store when it is blank: see [method resolve_store].
static func find_store(host: Node, path: String) -> Node:
	return resolve_store(host, path).store


## Like [method find_store], with the reason when there is none: returns
## [code]{store, path, error}[/code], where [code]path[/code] is the store's node path from the
## scene root ([method scene_root]).
##
## A non-blank [param path] is the node path from the scene root (also tried as an absolute
## path). A blank one means the only [code]CopiaStore3D[/code] of the scene: none, or several,
## is an error.
static func resolve_store(host: Node, path: String) -> Dictionary:
	var result := {"store": null, "path": path, "error": ""}
	var root := scene_root(host)
	if root == null:
		result.error = "no scene to look for the store in"
		return result
	var found: Node = null
	if not path.is_empty():
		found = root.get_node_or_null(NodePath(path))
		if found == null and path.begins_with("/") and host.is_inside_tree():
			found = host.get_tree().root.get_node_or_null(NodePath(path))
		if found == null:
			result.error = "no node '%s' under the scene root %s" % [path, root.name]
		elif not is_store(found):
			result.error = "the node '%s' is not a CopiaStore3D" % path
			found = null
	else:
		var stores: Array[Node] = []
		if is_store(root):
			stores.append(root)
		for node in root.find_children("*", "", true, false):
			if is_store(node):
				stores.append(node)
		if stores.size() == 1:
			found = stores[0]
		elif stores.is_empty():
			result.error = "the scene has no CopiaStore3D, and the points name none"
		else:
			result.error = "the scene has %d CopiaStore3D nodes and the points name none" % stores.size()
	if found != null:
		result.store = found
		result.path = str(root.get_path_to(found))
	return result


## The root node store paths are relative to: the owner of [param host] (the scene root of
## the scene it is saved in, which is the current scene at run time), else the edited or
## current scene when it holds the host, else the topmost ancestor below the window.
static func scene_root(host: Node) -> Node:
	if host == null:
		return null
	if host.owner != null:
		return host.owner
	var tree := host.get_tree()
	if tree != null:
		for scene in [tree.edited_scene_root, tree.current_scene]:
			if scene != null and (scene == host or scene.is_ancestor_of(host)):
				return scene
	var top := host
	while top.get_parent() != null and not top.get_parent() is Window:
		top = top.get_parent()
	return top


## Whether [param node] is a [code]CopiaStore3D[/code]: its script, or one it extends, is the
## store's. The script is checked, not a class name the class cache may not know.
static func is_store(node: Variant) -> bool:
	if not node is Node or not is_instance_valid(node):
		return false
	var script: Variant = (node as Node).get_script()
	while script is Script:
		if (script as Script).resource_path == STORE_SCRIPT:
			return true
		script = (script as Script).get_base_script()
	return false


## Calls a static method of a Copia native class, loading the extension if it is not yet.
static func native_static(native_class: String, method: String, arguments: Array) -> Variant:
	if not ClassDB.class_exists(native_class):
		GDExtensionManager.load_extension(EXTENSION)
	if not ClassDB.class_exists(native_class):
		return null
	return Callable(ClassDB, "class_call_static").callv([native_class, method] + arguments)
