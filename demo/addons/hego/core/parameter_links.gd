@tool
extends RefCounted
## Scene-relative counterparts of HAPI's session-local node parameter values.

const STORAGE := &"_hego_parameter_links"


static func panel_assets(host: Node) -> Array:
	if host.has_method("hego_get_panel_assets"):
		var entries: Variant = host.hego_get_panel_assets()
		if entries is Array:
			return entries.filter(func(entry): return entry is Dictionary and entry.get("asset") is HEGoAssetNode)
	if host.has_method("hego_get_asset_node"):
		return [{"asset": host.hego_get_asset_node(), "label": ""}]
	return []


static func asset_key(host: Node, asset: HEGoAssetNode) -> String:
	for entry in panel_assets(host):
		if entry.get("asset") == asset:
			return JSON.stringify([asset.op_name, entry.get("label", "")])
	return ""


static func saved(host: Node, key: String) -> Dictionary:
	return host.get_meta(STORAGE, {}).get(key, {}).duplicate(true)


static func store(host: Node, key: String, links: Dictionary) -> void:
	if key.is_empty():
		return
	var all_links: Dictionary = host.get_meta(STORAGE, {}).duplicate()
	if links.is_empty():
		all_links.erase(key)
	else:
		all_links[key] = links.duplicate(true)
	if not all_links.is_empty():
		host.set_meta(STORAGE, all_links)
	elif host.has_meta(STORAGE):
		host.remove_meta(STORAGE)


static func candidates(host: Node, target: HEGoAssetNode) -> Array:
	var tree := host.get_tree()
	var scene := tree.edited_scene_root if tree.edited_scene_root != null else tree.current_scene
	if scene == null:
		return []
	var nodes := scene.find_children("*", "", true, false)
	nodes.push_front(scene)
	var result := []
	for source_host in nodes:
		for entry in panel_assets(source_host):
			var source: HEGoAssetNode = entry.get("asset")
			if source == null or source == target or source.get_id() < 0:
				continue
			var path := host.get_path_to(source_host)
			var label := str(entry.get("label", ""))
			result.append({"label": str(path) if label.is_empty() else "%s / %s" % [path, label],
				"node": source, "source": {"path": path, "label": label, "op": source.op_name}})
	return result


static func _resolve(source_host: Node, binding: Dictionary) -> HEGoAssetNode:
	for entry in panel_assets(source_host):
		var source: HEGoAssetNode = entry.get("asset")
		if source != null and source.op_name == binding.get("op") and entry.get("label", "") == binding.get("label", ""):
			return source
	return null


static func restore(host: Node, target: HEGoAssetNode, links: Dictionary) -> bool:
	for name in links:
		var binding: Dictionary = links[name]
		var source_host := host.get_node_or_null(NodePath(binding.get("path", "")))
		var source: HEGoAssetNode
		if source_host != null:
			source = _resolve(source_host, binding)
			if (source == null or source.get_id() < 0) and source_host != host and source_host.has_method("cook"):
				# A scene can be reopened with its consumer selected first.
				await source_host.cook()
				if is_instance_valid(source_host):
					source = _resolve(source_host, binding)
		if source == null or source.get_id() < 0:
			HEGoLog.get_singleton().error("parm", "Cannot resolve the saved source for %s (%s)." % [name, binding.get("path")])
			return false
		var result := await HEGoNodeUtil.checked_task(host, target.set_node_parm(name, source))
		if not result.ok:
			HEGoLog.get_singleton().error("parm", result.message)
			return false
	return true


## Each node parameter inside a block has an address made of template names and
## instance indices. A middle insertion/deletion moves those indices, even when
## several rows resolve to the same source or some rows contain literal paths.
static func _instance_addresses(rows: Array, block: String, position: int, delta: int, result: Dictionary,
		path: Array = [], removed := false) -> void:
	for row in rows:
		var template: String = row.get("template_name", row.name)
		if not path.is_empty() and row.has("node_id"):
			result[row.name] = "" if removed else JSON.stringify(path + [template])
		_instance_addresses(row.get("children", []), block, position, delta, result, path, removed)
		var instances: Array = row.get("instances", [])
		for i in instances.size():
			var index := i + int(row.get("instance_start_offset", 1))
			var child_path := path
			var dropped := removed
			if row.name == block:
				dropped = dropped or (delta == -1 and index == position)
				if index >= position:
					index += delta
				child_path = [template, index]
			elif not path.is_empty():
				child_path = path + [template, index]
			_instance_addresses(instances[i], block, position, delta, result, child_path, dropped)


static func remap_instances(links: Dictionary, before: Dictionary, after: Dictionary, change: Dictionary) -> Dictionary:
	var before_addresses := {}
	var after_addresses := {}
	_instance_addresses(before.values(), change.block, change.position, change.delta, before_addresses)
	_instance_addresses(after.values(), change.block, 0, 0, after_addresses)
	var result := links.duplicate(true)
	var moved := {}
	for name in before_addresses:
		if links.has(name):
			result.erase(name)
			if before_addresses[name] != "":
				moved[before_addresses[name]] = links[name]
	for name in after_addresses:
		if moved.has(after_addresses[name]):
			result[name] = moved[after_addresses[name]]
	return result
