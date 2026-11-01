extends SceneTree
## The terrain's inspector setup: Bake runtime data, Add collision, Add navigation and Add
## runtime renderer give a playable terrain without a script. Collision and navigation follow
## the terrain's bake (whole small terrain prepared automatically, replaced on a rebake); the
## renderer and streamer are wired but, headless, never start.
var checks := 0
var failures := 0

func _initialize() -> void: run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures += 1; push_error("TERRAIN_SETUP: " + message)

func run() -> void:
	var scene := Node3D.new(); scene.name = "Level"; get_root().add_child(scene)
	var terrain := StrataTerrain3D.new(); terrain.name = "Terrain"; terrain.base_bounds = Rect2(-32.0, -32.0, 64.0, 64.0); terrain.set_preview_enabled(false)
	scene.add_child(terrain)
	var base := StrataLayer.new(); base.name = "Base"; terrain.add_child(base)
	base.data.grid_origin = Vector2(-32.0, -32.0)
	for j in range(65):
		for i in range(65): base.data.set_sample(&"height", Vector2i(i, j), 2.0 * sin(i * 0.2) + cos(j * 0.3))
	var baked := terrain.bake_runtime()
	check(baked.get("ok", false) and terrain.runtime_data == baked.data and not terrain.is_runtime_bake_stale(), "Bake runtime data publishes the bake")

	var collision := terrain.add_collision(); var navigation := terrain.add_navigation(); var renderer := terrain.add_runtime_renderer()
	check(collision == terrain.add_collision() and navigation == terrain.add_navigation() and renderer == terrain.add_runtime_renderer() and terrain.get_children().filter(func(n: Node) -> bool: return n is StrataCollision).size() == 1, "each button adds its node once")
	var streamer := terrain.get_node("Streamer") as StrataRegionStreamer
	# Outside the editor the terrain itself has no owner, so the nodes are owned by the terrain; in
	# the editor _adopt_runtime_child uses the edited scene root instead.
	check(collision.owner == terrain and navigation.owner == terrain and renderer.owner == terrain and streamer != null and streamer.owner == terrain, "added nodes get an owner so they save with the scene")
	check(streamer.renderer == renderer and streamer.data == null and not streamer.is_started(), "the streamer is wired to the renderer and, headless, does not start")
	await process_frame; await process_frame
	check(collision.data == terrain.runtime_data and collision.get_chunk_grid() == Vector2i(1, 1) and int(collision.get_stats().resident_chunks) == 1, "collision follows the terrain's bake and prepares the whole small terrain")
	check(navigation.data == terrain.runtime_data, "navigation follows the terrain's bake")
	# The automatic bake is deferred by a frame so explicit setup code can win.
	await process_frame
	var waited := 0
	while navigation.is_baking() and waited < 900: await process_frame; waited += 1
	check(not navigation.is_baking() and navigation.get_tile_grid() == Vector2i(1, 1) and int(navigation.get_stats().resident_tiles) == 1, "navigation bakes the whole small terrain")
	await physics_frame; await physics_frame
	var probe := Vector2(3.5, -7.25)
	var sampled: Dictionary = terrain.sample_runtime_height(probe)
	var ray := PhysicsRayQueryParameters3D.create(terrain.to_global(Vector3(probe.x, 100.0, probe.y)), terrain.to_global(Vector3(probe.x, -100.0, probe.y)))
	var hit: Dictionary = scene.get_world_3d().direct_space_state.intersect_ray(ray)
	check(not hit.is_empty() and sampled.get("status", -1) == StrataRuntimeData.Status.OK and absf(terrain.to_local(hit.position).y - float(sampled.value)) < 0.01, "automatic collision has the bake's heights")

	# A rebake after an edit reaches both nodes through the terrain.
	base.data.set_sample(&"height", Vector2i(10, 10), 25.0)
	var rebaked := terrain.bake_runtime()
	check(rebaked.get("ok", false) and terrain.runtime_data == rebaked.data and terrain.runtime_data != baked.data, "the terrain rebakes")
	check(collision.data == terrain.runtime_data and int(collision.get_stats().resident_chunks) == 1, "a new bake replaces the resident collision in place")
	check(navigation.data == terrain.runtime_data, "a new bake replaces the navigation data")
	await process_frame
	waited = 0
	while navigation.is_baking() and waited < 900: await process_frame; waited += 1
	check(int(navigation.get_stats().resident_tiles) == 1, "navigation rebakes the terrain after a new bake")
	await physics_frame; await physics_frame
	var peak := terrain.sample_runtime_height(Vector2(-22.0, -22.0))
	hit = scene.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(terrain.to_global(Vector3(-22.0, 100.0, -22.0)), terrain.to_global(Vector3(-22.0, -100.0, -22.0))))
	check(not hit.is_empty() and absf(terrain.to_local(hit.position).y - float(peak.value)) < 0.01 and float(peak.value) > 20.0, "the replaced collision carries the edit")

	# Over budget without a target: nothing is prepared, one warning.
	collision.chunk_cells = 16; collision.max_resident_chunks = 4
	collision._auto_prepare()
	check(int(collision.get_stats().resident_chunks) == 0 and collision.get_chunk_grid() == Vector2i(4, 4), "a terrain above the chunk budget is not prepared without a track target")
	collision.max_resident_chunks = 16
	collision._auto_prepare()
	check(int(collision.get_stats().resident_chunks) == 16, "raising the budget lets the automatic preparation cover it")

	waited = 0
	while navigation.is_baking() and waited < 900: await process_frame; waited += 1
	print("TERRAIN_SETUP checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
