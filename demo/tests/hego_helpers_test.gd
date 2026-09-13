## Covers HEGoHelpers, the small object a node writing its own cook() leans on.
##
## Everything here works without a Houdini session: creating an HEGoAssetNode is cheap and
## its id stays -1 until something instantiates it, which is exactly the state these checks
## care about.
extends SceneTree

var failures := 0


func check(condition: bool, what: String) -> void:
	if condition:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


## A node holding an input stash, the way the panel and the helper both expect.
class StubNode extends Node3D:
	var input_stash: Array = []
	func hego_get_input_stash() -> Array: return input_stash
	func hego_set_input_stash(rows: Array) -> void: input_stash = rows


func _initialize() -> void:
	var node := StubNode.new()
	root.add_child(node)
	await process_frame
	var hego := HEGoHelpers.new(node)

	# --- assets are created once and reused ---------------------------------
	var first := hego.asset("Sop/hego_fence")
	var again := hego.asset("Sop/hego_fence")
	check(first == again, "asking twice returns the same asset node")
	check(first.op_name == "Sop/hego_fence", "the operator name is kept verbatim")
	check(hego.assets.size() == 1, "and only one is recorded")
	check(hego.assets.has("hego_fence"), "labelled by the operator without its table")

	var labelled := hego.asset("Sop/other", "detail")
	check(hego.assets.has("detail"), "an explicit label wins")
	check(hego.assets.size() == 2, "a second asset is recorded alongside the first")
	check(labelled != first, "and is a different node")

	# --- a bare operator name gets the default table ------------------------
	check(hego.asset("my_tool").op_name == "Sop/my_tool", "a name without a table gets Sop/")

	# --- pointing a label at a different HDA must not reuse the old node -----
	var reused := hego.asset("Sop/changed", "detail")
	check(reused == labelled, "the same label keeps the same object")
	check(reused.op_name == "Sop/changed", "but its operator is updated")
	check(reused.get_id() == -1, "and its Houdini node is forgotten, so the next cook makes the right one")

	# --- set_input writes rows the panel can read back ----------------------
	var fresh := StubNode.new()
	root.add_child(fresh)
	await process_frame
	var inputs := HEGoHelpers.new(fresh)

	inputs.set_input(0, "SomePath")
	check(fresh.input_stash.size() == 1, "setting input 0 makes one row")
	check(fresh.input_stash[0]["inputs"] == ["SomePath"], "holding that path")
	check(fresh.input_stash[0].has("settings"), "with a settings dictionary alongside")

	# Setting a later input pads the earlier ones rather than losing them.
	inputs.set_input(2, ["A", "B"])
	check(fresh.input_stash.size() == 3, "setting input 2 pads up to it, got %d" % fresh.input_stash.size())
	check(fresh.input_stash[2]["inputs"] == ["A", "B"], "and takes several sources")
	check(fresh.input_stash[0]["inputs"] == ["SomePath"], "leaving input 0 alone")

	# Nulls are dropped rather than written as empty entries.
	inputs.set_input(0, [null, "Kept"])
	check(fresh.input_stash[0]["inputs"] == ["Kept"], "null sources are dropped")

	# A Node is stored as a path, not an object.
	var target := Node3D.new()
	target.name = "Target"
	root.add_child(target)
	await process_frame
	inputs.set_input(1, target)
	check(fresh.input_stash[1]["inputs"].size() == 1, "a Node produces one entry")
	check(fresh.input_stash[1]["inputs"][0] is String, "stored as a path string, not an object")

	# --- settings survive being written around -------------------------------
	fresh.input_stash = [{"inputs": ["X"], "settings": {"keep": 1}}]
	inputs.set_input(0, "Y")
	check(fresh.input_stash[0]["settings"] == {"keep": 1}, "existing settings are carried through")

	node.free()
	fresh.free()
	target.free()
	print("")
	print("failures: ", failures)
	quit(1 if failures > 0 else 0)
