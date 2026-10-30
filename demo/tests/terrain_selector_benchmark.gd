extends SceneTree
## Focused native selector timings and exact serialized-partition fingerprint.

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var mesher := StrataMesher.new()
	var bounds := Rect2(-2048, -2048, 4096, 4096)
	var cameras: Array[Vector2] = []
	for index in range(48):
		cameras.append(Vector2(-1750 + (index * 197) % 3500, -1750 + (index * 311) % 3500))
	var fingerprint := HashingContext.new(); fingerprint.start(HashingContext.HASH_SHA256)
	var minimum_leaves := 1000000; var maximum_leaves := 0
	for budget in [128, 512, 1024]:
		for minimum in [8.0, 1.0]:
			for camera in cameras:
				var plan := mesher.select_patches(bounds, camera, minimum, 1.8, budget)
				fingerprint.update(var_to_bytes(plan))
	for index in range(128): mesher.select_patches(bounds, cameras[index % cameras.size()], 8.0, 1.8, 512)
	var samples: Array[float] = []
	for block_index in range(21):
		var started := Time.get_ticks_usec()
		for index in range(100):
			var plan := mesher.select_patches(bounds, cameras[(block_index * 100 + index) % cameras.size()], 8.0, 1.8, 512)
			minimum_leaves = mini(minimum_leaves, plan.size()); maximum_leaves = maxi(maximum_leaves, plan.size())
		samples.append((Time.get_ticks_usec() - started) / 100000.0)
	samples.sort()
	print("SELECTOR_PROFILE ", JSON.stringify({"partition_sha256": fingerprint.finish().hex_encode(), "calls": 2100, "leaves_min": minimum_leaves, "leaves_max": maximum_leaves, "p50_ms": samples[10], "p95_ms": samples[19], "best_ms": samples[0]}))
	quit(0)
