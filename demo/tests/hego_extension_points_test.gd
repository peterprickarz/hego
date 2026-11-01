extends SceneTree
## HEGo's extension points with the HEGo Strata bridge installed. Never starts Houdini:
## Strata results are fabricated and published through HEGoStrataOutput.publish, the entry
## point the bridge's output handler hands a fetched cook to.
## Needs a project with addons/hego, addons/strata and addons/hego_strata;
## demo/tests/addon_split_runner.py stages one.

var checks := 0
var failures := 0


class RefusingExtension extends HEGoCookExtension:
	func cook_prepare(_host: Node, _cook: Dictionary) -> Dictionary:
		return {"ok": false, "message": "refused for test"}


class RecordingExtension extends HEGoCookExtension:
	var prepared := 0
	var failed: Array = []
	func cook_prepare(_host: Node, _cook: Dictionary) -> Dictionary:
		prepared += 1
		return {"ok": true}
	func cook_failed(_host: Node, _cook: Dictionary, message: String) -> void:
		failed.append(message)


## Records how the cook started, then stops it before anything reaches Houdini.
class StrictnessProbe extends HEGoCookExtension:
	var strict := false
	var started: Dictionary = {}
	func cook_prepare(_host: Node, cook: Dictionary) -> Dictionary:
		strict = cook.strict
		started = cook.duplicate()
		return {"ok": false, "message": "probe stops the cook"}


func _initialize() -> void:
	run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("EXTENSION_POINTS_TEST: " + message)


## A heightfield as HEGoAssetNode.get_heightfield_fields returns it, routed to [param path].
func volume(path: String, value: float, channel := "height") -> Dictionary:
	var image := Image.create(2, 2, false, Image.FORMAT_RF); image.fill(Color(value, 0, 0))
	var attrs := {HEGoStrataOutput.ROLE_ATTR: "value", HEGoStrataOutput.CHANNEL_ATTR: channel}
	if not path.is_empty(): attrs[HEGoStrataOutput.TARGET_ATTR] = path
	return {"name": channel, "image": image, "sample_origin": Vector3.ZERO, "sample_step_x": Vector3.RIGHT, "sample_step_y": Vector3.BACK, "attrs": attrs, "coordinate_space": "sop_local"}


func run() -> void:
	# The demo project also has the Terrain3D bridge's handlers; the staged project has only
	# this bridge's.
	var handlers := HEGoInputNodes.extension_handlers().filter(func(handler): return handler is HEGoStrataInput)
	check(handlers.size() == 1, "HEGo discovers the bridge's terrain input handler from the class list")
	check(HEGoInputNodes.extension_handlers().has(handlers[0]) if handlers.size() == 1 else false, "handler instances are reused while the class list is unchanged")
	var outputs := HEGoOutputHandler.extension_handlers().filter(func(handler): return handler is HEGoStrataOutput)
	var listing := HEGoNode3D.new()
	check(outputs.size() == 1 and listing.output_handlers().has(outputs[0]), "HEGo discovers the bridge's terrain output handler and runs it in every cook")
	listing.free()
	check(outputs.size() == 1 and outputs[0].should_handle({"has_volumes": true}) and not outputs[0].should_handle({"has_volumes": false}) and outputs[0].should_handle({}), "the terrain output looks at every cook with volumes, or an unreadable summary")

	var scene := Node3D.new(); scene.name = "Scene"; root.add_child(scene)
	var terrain := StrataTerrain3D.new(); terrain.name = "Terrain"; terrain.base_bounds = Rect2(0, 0, 4, 4); terrain.set_preview_enabled(false)
	scene.add_child(terrain)
	var source := StrataLayer.new(); source.name = "Source"; terrain.add_child(source)
	source.data.set_sample(&"height", Vector2i.ZERO, 3.0)
	var layer := StrataLayer.new(); layer.name = "Generated"; layer.procedural = true; terrain.add_child(layer)
	var orphan := StrataLayer.new(); orphan.name = "Orphan"; scene.add_child(orphan)
	check(HEGoInputNodes.is_compatible_source(layer) and HEGoInputNodes.handler_for(layer) is HEGoStrataInput, "a terrain layer is an input HEGo can send")
	check(not HEGoInputNodes.is_compatible_source(orphan), "a layer outside a terrain is not")

	# A Strata input row alone makes the host explicit and strict; no extension child.
	var host := HEGoNode3D.new(); host.name = "Producer"; host.asset_name = "Sop/test"; scene.add_child(host)
	check(host.cook_extensions().is_empty() and not host.hego_requires_explicit_cook(), "a plain HEGo node has no extensions and recooks automatically")
	var settings := {HEGoStrataInput.SETTINGS_MARKER: true, "terrain_mode": "cumulative", "terrain_channels": "height"}
	host.input_stash = [{"inputs": ["../Terrain/Source"], "settings": settings}]
	check(host.cook_extensions().is_empty() and host.hego_requires_explicit_cook(), "a terrain input makes the host cook only on request")
	host.input_stash = [{"inputs": ["../Terrain/Renamed"], "settings": settings}]
	check(host.hego_requires_explicit_cook(), "stored terrain settings keep the rule while the source layer is missing")
	host.input_stash = [{"inputs": ["../Terrain/Source"], "settings": settings}]
	var probe := StrictnessProbe.new(); host.add_child(probe)
	await host.cook()
	check(probe.strict and probe.started.get("input_stash") == host.input_stash and probe.started.get("transform") == host.global_transform, "a terrain input makes the cook strict, and the cook records what it started from")
	host.remove_child(probe); probe.free()
	var plain := HEGoNode3D.new(); plain.name = "Plain"; plain.asset_name = "Sop/test"; scene.add_child(plain)
	var plain_probe := StrictnessProbe.new(); plain.add_child(plain_probe)
	await plain.cook()
	check(not plain_probe.strict, "a cook without terrain inputs is not strict")
	plain.remove_child(plain_probe); plain_probe.free()

	# A fabricated cook routes to the layer its volume names, in one transaction.
	var snapshot := HEGoStrataInput.snapshot(source, settings)
	var cook := {}
	HEGoStrataOutput.record_input(cook, snapshot)
	check(snapshot.ok and cook[HEGoStrataOutput.COOK_KEY].inputs == [snapshot], "an uploaded terrain input is recorded in the cook dictionary")
	var signature := HEGoStrataOutput.signature(host)
	var published := HEGoStrataOutput.publish(host, [volume("../Terrain/Generated", 7.0), volume("", 99.0, "foreign"), volume("../Terrain/Generated", 0.5, "mask")], cook[HEGoStrataOutput.COOK_KEY].inputs, signature)
	check(published.ok and layer.procedural_fields.keys() == ["height", "mask"] and not layer.procedural_stale and layer.procedural_revision == 1, "a routed result publishes every channel the HDA emits, without an allowlist, and ignores volumes without a target")
	check(is_equal_approx(layer.sample_channel(&"height", Vector2.ZERO).value, 7.0), "the published height is the routed volume's")
	check(layer.producer_path == layer.get_path_to(host) and layer.producer_id == HEGoStrataOutput.producer_id(host) and layer.producer_signature == signature and layer.source_tokens.size() == 1, "the layer records its producer, the host's signature and the inputs it was built from")
	var kept: StrataFieldData = layer.procedural_fields.height

	var missing := HEGoStrataOutput.publish(host, [volume("../Terrain/Generated", 8.0), volume("../Terrain/Missing", 8.0)], [snapshot], signature)
	check(not missing.ok and "missing" in missing.message and layer.procedural_fields.height == kept and layer.procedural_revision == 1, "a result for a missing layer is rejected and every target keeps its previous fields")
	check(layer.procedural_stale and layer.procedural_status.begins_with("Cook rejected"), "the rejection is recorded on the layers the cook was meant for")
	var manual := HEGoStrataOutput.publish(host, [volume("../Terrain/Source", 8.0)], [], signature)
	check(not manual.ok and source.procedural_fields.is_empty() and is_equal_approx(source.data.get_sample(&"height", Vector2i.ZERO), 3.0) and layer.procedural_fields.height == kept, "a result for a non-procedural layer is rejected and changes nothing")
	var cycle := HEGoStrataOutput.publish(host, [volume("../Terrain/Generated", 8.0)], [HEGoStrataInput.snapshot(layer, {"terrain_mode": "raw", "terrain_channels": "height"})], signature)
	check(not cycle.ok and "cycle" in cycle.message and layer.procedural_fields.height == kept, "a target that is also an input is rejected")
	var stale_snapshot := HEGoStrataInput.snapshot(source, settings)
	source.data.set_sample(&"height", Vector2i.ZERO, 4.0)
	var stale := HEGoStrataOutput.publish(host, [volume("../Terrain/Generated", 8.0)], [stale_snapshot], signature)
	check(not stale.ok and layer.procedural_fields.height == kept and layer.procedural_revision == 1, "a result whose input changed after its snapshot is rejected with the previous fields retained")
	var refused := HEGoStrataOutput.publish(host, [volume("../Terrain/Generated", 8.0)], [], signature, func() -> bool: return false)
	check(not refused.ok and layer.procedural_fields.height == kept, "a host that changed during the cook is rejected")

	# Freshness: Strata watches the inputs, the bridge watches the producer.
	var fresh := HEGoStrataOutput.publish(host, [volume("../Terrain/Generated", 9.0)], [HEGoStrataInput.snapshot(source, settings)], HEGoStrataOutput.signature(host))
	check(fresh.ok and not layer.procedural_stale and layer.procedural_revision == 2, "a current result publishes")
	terrain.check_procedural_sources()
	check(not layer.procedural_stale, "an unchanged input leaves the result current")
	source.data.set_sample(&"height", Vector2i.ZERO, 5.0)
	terrain.check_procedural_sources()
	check(layer.procedural_stale, "Strata marks the result stale once an input layer changes")
	HEGoStrataOutput.publish(host, [volume("../Terrain/Generated", 9.0)], [HEGoStrataInput.snapshot(source, settings)], HEGoStrataOutput.signature(host))
	check(not layer.procedural_stale and not HEGoStrataOutput.producer_changed(layer), "a fresh result matches its producer")
	host.input_stash = [{"inputs": ["../Terrain/Source"], "settings": {HEGoStrataInput.SETTINGS_MARKER: true, "terrain_mode": "raw", "terrain_channels": "height"}}]
	check(HEGoStrataOutput.producer_changed(layer) and HEGoStrataOutput.published_layers(host) == [layer], "an edited input row changes the producer's signature")
	var intent := layer.producer_intent_revision
	HEGoStrataOutput.poll(scene)
	check(layer.procedural_stale and layer.procedural_status == HEGoStrataOutput.STALE_PRODUCER and layer.producer_intent_revision == intent + 1, "the editor poll marks a layer stale when its producer changed")
	var watched := host.cook_inputs_changed.get_connections().size()
	HEGoStrataOutput.poll(scene)
	check(watched == 1 and host.cook_inputs_changed.get_connections().size() == 1, "the poll connects every HEGo node's change signal once")
	host.hego_notify_cook_inputs_changed()
	check(layer.producer_intent_revision == intent + 2, "a change the panel reports reaches the published layer at once")

	# Hooks run in child order. The extension that stops a cook records its own reason;
	# the others are told through cook_failed, and nothing reaches Houdini.
	var refusing := HEGoNode3D.new(); refusing.name = "Refusing"; refusing.asset_name = "Sop/test"; scene.add_child(refusing)
	var recorder := RecordingExtension.new(); refusing.add_child(recorder)
	var refuser := RefusingExtension.new(); refusing.add_child(refuser)
	await refusing.cook()
	check(recorder.prepared == 1 and recorder.failed == ["refused for test"] and not refusing.hego_did_last_cook_succeed(), "a refusing extension stops the cook and the others hear why")
	check(not HEGoAPI.get_singleton().is_session_active(), "no Houdini session was started")

	# The panel's input row shows the bridge's terrain options for a layer input.
	var row: Variant = load("res://addons/hego/ui/input_ui.tscn").instantiate()
	scene.add_child(row)
	row.setup("Input", PackedStringArray(["../Terrain/Generated"]), {}, host)
	var editors: Array = row.get_extension_editors()
	check(editors.size() == 1 and editors[0] is HEGoStrataInputSettings and editors[0].visible, "a terrain input row gets the bridge's settings editor")
	var row_settings: Dictionary = row.get_extension_settings()
	check(bool(row_settings.get(HEGoStrataInput.SETTINGS_MARKER, false)) and row_settings.get("terrain_mode") == "cumulative" and row.requires_explicit_cook(), "the row stores terrain settings and cooks only on request")

	scene.free()
	print("HEGO_EXTENSION_POINTS_TEST: %s (%d checks, %d failures)" % ["PASS" if failures == 0 else "FAIL", checks, failures])
	quit(0 if failures == 0 else 1)
