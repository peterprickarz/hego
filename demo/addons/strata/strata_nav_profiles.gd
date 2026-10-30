class_name StrataNavProfiles
extends RefCounted
## Static navigation profiles: which cells one agent population may walk on,
## derived once at bake time from data the bake retained. Built-in types only,
## like StrataRuntimeData, so runtime-only projects can re-evaluate a rule.
##
## A profile is {"name": StringName, "rule": Dictionary}. A rule is true where a
## cell is walkable. Forms (each Dictionary is exactly one form):
##   {"channel": "footpath", "min": 0.5, "max": 1.0}  min and/or max, inclusive,
##     on the cell mean of a retained channel (see below).
##   {"height_min": 0.0, "height_max": 80.0}  either or both, inclusive, on the
##     cell mean height.
##   {"slope_min": 0.0, "slope_max": 35.0}  either or both, inclusive, degrees in
##     0..90, on the steeper of the cell's two canonical triangles.
##   {"exclusion": true}  the cell is not in the categorical nav_exclusion mask
##     (the mask's own per-cell value; no corner averaging).
##   {"not": rule}, {"all": [rule, ...]}, {"any": [rule, ...]}  (nonempty lists).
## Cell mean: (a + b + c + d) * 0.25 of the four corner samples, computed in
## float32 (the engine's 2 x 2 average), then compared in float64. Uncovered
## channel samples hold the value the bake stored there (the composition base,
## 0 for custom channels). Categorical inputs are already per-cell masks, so a
## 0/1 channel meant as a category should use min 0.5 (compile_cell_masks'
## "value >= 0.5" convention), which on a cell mean means at least two corners.
##
## Polarity: evaluated masks use the holes/nav_exclusions convention, 255 =
## BLOCKED (rule false), 0 = walkable, empty = nothing blocked. Holes are not
## written into profile masks; consumers always treat holes | profile as blocked.
## Unknown keys, wrong types, empty lists, channels the bake did not retain and
## non-finite or inverted thresholds are errors; nothing is guessed.
##
## Cost: each distinct leaf term sets one bit per cell; a 256-entry table then
## maps the bits to the mask. Channel/height terms are an engine-side 2 x 2
## average plus one script pass; the exclusion term is a fill plus a pass over
## the excluded cells. Slope (the costly script pass) runs only on cells every
## earlier top-level term of an "all" root leaves walkable when those are a
## minority, and the final mapping writes only the minority class when it can.
## Skipped work never changes the result. At most MAX_TERMS distinct terms.

const DEFAULT := &"default"
## The default profile is the nav_exclusions mask itself (not a stored copy).
const DEFAULT_RULE := {"exclusion": true}
const MAX_TERMS := 8
const BLOCKED := 255
enum Term { CHANNEL, HEIGHT, SLOPE, EXCLUSION }
const _FORMS := {"channel": ["channel", "min", "max"], "height": ["height_min", "height_max"], "slope": ["slope_min", "slope_max"], "exclusion": ["exclusion"], "not": ["not"], "all": ["all"], "any": ["any"]}
## Lattice rows per engine-side averaging band (bounds transient memory).
const _BAND_SAMPLES := 2 * 1024 * 1024

static func _error(message: String) -> Dictionary:
	return {"ok": false, "message": message}

## {ok, message, terms}. channel_names: the channels retained by the bake.
static func validate(rule: Variant, channel_names: Variant = PackedStringArray()) -> Dictionary:
	var compiled := _compile(rule, PackedStringArray(channel_names))
	if not compiled.ok: return compiled
	return {"ok": true, "message": "", "terms": compiled.leaves.size()}

## Checks a profile list (Array of {name, rule}) without evaluating it.
static func validate_profiles(profiles: Variant, channel_names: Variant = PackedStringArray()) -> Dictionary:
	if not profiles is Array: return _error("nav_profiles must be an Array of {name, rule} Dictionaries")
	var seen := {}
	for entry in profiles:
		if not entry is Dictionary: return _error("Each navigation profile must be a {name, rule} Dictionary")
		var name: Variant = entry.get("name")
		var label := String(name) if name is String or name is StringName else "?"
		for key in entry:
			if not String(key) in ["name", "rule"]: return _error("Navigation profile %s: unknown key %s" % [label, key])
		if not (name is String or name is StringName) or label.strip_edges().is_empty(): return _error("Navigation profile names must be nonempty Strings or StringNames")
		if StringName(label) == DEFAULT: return _error("Navigation profile %s is reserved: it is always the nav_exclusions mask" % DEFAULT)
		if seen.has(StringName(label)): return _error("Navigation profile %s is listed twice" % label)
		seen[StringName(label)] = true
		if not entry.has("rule"): return _error("Navigation profile %s has no rule" % label)
		var checked := validate(entry.rule, channel_names)
		if not checked.ok: return _error("Navigation profile %s: %s" % [label, checked.message])
	return {"ok": true, "message": ""}

## Canonical cell mask of a rule, 255 = blocked. Empty on error (also reported).
static func evaluate(data: StrataRuntimeData, rule: Dictionary) -> PackedByteArray:
	var result := evaluate_checked(data, rule)
	if not result.ok:
		push_error("Strata navigation profile: " + String(result.message))
		return PackedByteArray()
	return result.mask

## {ok, message, mask, blocked_cells, terms, ms}.
static func evaluate_checked(data: StrataRuntimeData, rule: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	if data == null or not data.is_resident():
		return _error("Navigation profiles need resident runtime heights")
	var compiled := _compile(rule, data.channel_names)
	if not compiled.ok: return compiled
	var leaves: Array = compiled.leaves
	for leaf in leaves:
		if leaf.kind == Term.CHANNEL and not data.channels.has(String(leaf.channel)):
			return _error("channel %s is not resident (evicted after the bake)" % leaf.channel)
	var cells := data.get_cell_resolution()
	var count := cells.x * cells.y
	var flags := PackedByteArray()
	flags.resize(count)
	# Top-level literals (leaves or negated leaves under an "all" root, or the
	# root itself) must all hold on a walkable cell, so a later literal only needs
	# evaluating where the earlier ones hold: flags == pattern.
	var literals := _literals(compiled.tree)
	var order := range(leaves.size())
	var rank := func(index: int) -> int:
		var kind: int = leaves[index].kind
		return (0 if kind == Term.EXCLUSION else 1 if kind != Term.SLOPE else 2) + (0 if literals.has(index) else 3)
	order.sort_custom(func(a: int, b: int) -> bool: return rank.call(a) < rank.call(b) or rank.call(a) == rank.call(b) and a < b)
	# Leaves without a per-cell pass are constants folded into the lookup table.
	var constants := {}
	var pattern := 0
	var narrowed := false
	var only_literals := true
	var fresh := true
	for index: int in order:
		var leaf: Dictionary = leaves[index]
		var bit := 1 << index
		match int(leaf.kind):
			Term.EXCLUSION:
				if data.nav_exclusions.is_empty():
					constants[index] = true
				else:
					_exclusion_pass(data.nav_exclusions, flags, bit, fresh)
			Term.CHANNEL:
				_mean_pass(data.channels[String(leaf.channel)].values, data.resolution, flags, bit, leaf.min, leaf.max)
			Term.HEIGHT:
				_mean_pass(data.heights, data.resolution, flags, bit, leaf.min, leaf.max)
			Term.SLOPE:
				if leaf.min <= 0.0 and leaf.max >= 90.0:
					constants[index] = true
				elif only_literals and narrowed and literals.has(index) and flags.count(pattern) * 3 < count:
					_slope_pass(data, flags, bit, leaf.min, leaf.max, pattern)
				else:
					_slope_pass(data, flags, bit, leaf.min, leaf.max, -1)
		if constants.has(index): continue
		fresh = false
		if literals.has(index) and only_literals:
			if literals[index]: pattern |= bit
			narrowed = true
		else:
			only_literals = false
	var mask := _map_flags(flags, compiled.tree, leaves.size(), constants)
	var blocked := mask.count(BLOCKED)
	if blocked == 0: mask = PackedByteArray()
	return {"ok": true, "message": "", "mask": mask, "blocked_cells": blocked, "terms": leaves.size(), "ms": (Time.get_ticks_usec() - started) / 1000.0}

## Leaf index -> required truth for the root's top-level literals. A leaf used
## with both polarities is left out (the rule then needs every pass).
static func _literals(tree: Array) -> Dictionary:
	var children: Array = tree[1] if tree[0] == "all" else [tree]
	var result := {}
	var conflicts := {}
	for child: Array in children:
		var negated: bool = child[0] == "not" and child[1][0] == "leaf"
		if child[0] != "leaf" and not negated: continue
		var index: int = child[1][1] if negated else child[1]
		if result.has(index) and result[index] == negated: conflicts[index] = true
		result[index] = not negated
	for index in conflicts: result.erase(index)
	return result

## Canonical mask from the per-cell term bits. When at most four bit patterns
## form the minority class (walkable or blocked) and it covers under a quarter
## of the cells, the majority is filled and only the minority is written.
static func _map_flags(flags: PackedByteArray, tree: Array, terms: int, constants: Dictionary) -> PackedByteArray:
	var count := flags.size()
	var table := PackedByteArray()
	table.resize(256)
	var walkable_values := PackedInt32Array()
	var blocked_values := PackedInt32Array()
	for value in range(1 << terms):
		var walkable := _walkable(tree, value, constants)
		table[value] = 0 if walkable else BLOCKED
		if walkable: walkable_values.append(value)
		else: blocked_values.append(value)
	var mask := PackedByteArray()
	mask.resize(count)
	if walkable_values.is_empty() or blocked_values.is_empty():
		mask.fill(0 if blocked_values.is_empty() else BLOCKED)
		return mask
	for minority in [[walkable_values, 0, BLOCKED], [blocked_values, BLOCKED, 0]]:
		var values: PackedInt32Array = minority[0]
		if values.size() > 4: continue
		var found := 0
		for value in values: found += flags.count(value)
		if found * 4 >= count: continue
		mask.fill(minority[2])
		var write: int = minority[1]
		for value in values:
			var index := flags.find(value)
			while index != -1:
				mask[index] = write
				index = flags.find(value, index + 1)
		return mask
	for index in count:
		mask[index] = table[flags[index]]
	return mask

## Validates every profile, evaluates them all, then replaces data.nav_profiles
## and data.nav_profile_rules together. On failure the data is untouched.
## {ok, message, report: {name: {blocked_cells, terms, ms}}, ms}.
static func apply(data: StrataRuntimeData, profiles: Array) -> Dictionary:
	var started := Time.get_ticks_usec()
	if data == null: return _error("Navigation profiles need runtime data")
	var checked := validate_profiles(profiles, data.channel_names)
	if not checked.ok: return checked
	var masks := {}
	var rules := {DEFAULT: DEFAULT_RULE.duplicate(true)}
	var report := {}
	for entry in profiles:
		var name := StringName(entry.name)
		var evaluated := evaluate_checked(data, entry.rule)
		if not evaluated.ok: return _error("Navigation profile %s: %s" % [name, evaluated.message])
		masks[name] = evaluated.mask
		rules[name] = (entry.rule as Dictionary).duplicate(true)
		report[name] = {"blocked_cells": evaluated.blocked_cells, "terms": evaluated.terms, "ms": evaluated.ms}
	data.nav_profiles = masks
	data.nav_profile_rules = rules
	return {"ok": true, "message": "", "report": report, "ms": (Time.get_ticks_usec() - started) / 1000.0}

## Rule -> {ok, tree, leaves}. Tree nodes: ["leaf", index], ["not", node],
## ["all"/"any", [nodes]]. Identical leaves share one index (one cell pass).
static func _compile(rule: Variant, channel_names: PackedStringArray) -> Dictionary:
	var leaves: Array = []
	var keys := {}
	var tree: Variant = _compile_node(rule, channel_names, "rule", leaves, keys)
	if tree is String: return _error(tree)
	if leaves.size() > MAX_TERMS: return _error("rule has %d distinct terms; at most %d are supported" % [leaves.size(), MAX_TERMS])
	return {"ok": true, "tree": tree, "leaves": leaves}

## Returns a tree node, or a String error message.
static func _compile_node(node: Variant, channel_names: PackedStringArray, path: String, leaves: Array, keys: Dictionary) -> Variant:
	if not node is Dictionary: return "%s must be a Dictionary" % path
	var rule: Dictionary = node
	if rule.is_empty(): return "%s is empty" % path
	var form := ""
	for key in rule:
		if not (key is String or key is StringName): return "%s has a non-string key %s" % [path, key]
		for candidate in _FORMS:
			if String(key) in _FORMS[candidate]:
				if not form.is_empty() and form != candidate: return "%s mixes %s and %s keys; combine rules with all/any" % [path, form, candidate]
				form = candidate
	for key in rule:
		if form.is_empty() or not String(key) in _FORMS[form]: return "%s: unknown key %s" % [path, key]
	match form:
		"not":
			var inner: Variant = _compile_node(_rule_value(rule, "not"), channel_names, path + ".not", leaves, keys)
			return inner if inner is String else ["not", inner]
		"all", "any":
			var list: Variant = _rule_value(rule, form)
			if not list is Array or (list as Array).is_empty(): return "%s.%s must be a nonempty Array of rules" % [path, form]
			var children: Array = []
			for index in range((list as Array).size()):
				var child: Variant = _compile_node(list[index], channel_names, "%s.%s[%d]" % [path, form, index], leaves, keys)
				if child is String: return child
				children.append(child)
			return [form, children]
		"exclusion":
			var value: Variant = _rule_value(rule, "exclusion")
			if not value is bool or not value: return "%s.exclusion must be true (use not for the excluded cells)" % path
			return _leaf({"kind": Term.EXCLUSION, "min": 0.0, "max": 0.0}, leaves, keys)
	var kind: int = {"channel": Term.CHANNEL, "height": Term.HEIGHT, "slope": Term.SLOPE}[form]
	var low_key: String = {"channel": "min", "height": "height_min", "slope": "slope_min"}[form]
	var high_key: String = {"channel": "max", "height": "height_max", "slope": "slope_max"}[form]
	if not _rule_has(rule, low_key) and not _rule_has(rule, high_key): return "%s needs %s and/or %s" % [path, low_key, high_key]
	var bounds := [-INF, INF]
	for side in range(2):
		var key: String = [low_key, high_key][side]
		if not _rule_has(rule, key): continue
		var value: Variant = _rule_value(rule, key)
		if not (value is float or value is int): return "%s.%s must be a number" % [path, key]
		if not is_finite(float(value)): return "%s.%s must be finite" % [path, key]
		if kind == Term.SLOPE and (float(value) < 0.0 or float(value) > 90.0): return "%s.%s must be in 0..90 degrees" % [path, key]
		bounds[side] = float(value)
	if bounds[0] > bounds[1]: return "%s: %s is above %s" % [path, low_key, high_key]
	var leaf := {"kind": kind, "min": bounds[0], "max": bounds[1]}
	if kind == Term.SLOPE:
		leaf.min = maxf(bounds[0], 0.0)
		leaf.max = minf(bounds[1], 90.0)
	if kind == Term.CHANNEL:
		var channel: Variant = _rule_value(rule, "channel")
		if not (channel is String or channel is StringName) or String(channel).strip_edges().is_empty(): return "%s.channel must be a nonempty channel name" % path
		if not channel_names.has(String(channel)): return "%s: channel %s is not retained by this bake (retained: %s)" % [path, channel, ", ".join(channel_names)]
		leaf.channel = StringName(channel)
	return _leaf(leaf, leaves, keys)

static func _rule_has(rule: Dictionary, key: String) -> bool:
	return rule.has(key) or rule.has(StringName(key))

static func _rule_value(rule: Dictionary, key: String) -> Variant:
	return rule[key] if rule.has(key) else rule.get(StringName(key))

static func _leaf(leaf: Dictionary, leaves: Array, keys: Dictionary) -> Array:
	var key := var_to_str(leaf)
	if not keys.has(key):
		keys[key] = leaves.size()
		leaves.append(leaf)
	return ["leaf", keys[key]]

static func _walkable(node: Array, flags: int, constants: Dictionary) -> bool:
	match String(node[0]):
		"leaf":
			return bool(constants[node[1]]) if constants.has(node[1]) else flags & (1 << int(node[1])) != 0
		"not":
			return not _walkable(node[1], flags, constants)
		"all":
			for child in node[1]:
				if not _walkable(child, flags, constants): return false
			return true
		_:
			for child in node[1]:
				if _walkable(child, flags, constants): return true
			return false

## Sets `bit` where low <= cell mean <= high. The 2 x 2 corner averages come from
## the engine: nearest x2 upscale, a one-texel offset crop, then shrink_x2, in
## bands so the transient images stay bounded.
static func _mean_pass(values: PackedFloat32Array, resolution: Vector2i, flags: PackedByteArray, bit: int, low: float, high: float) -> void:
	var width := resolution.x
	var cell_width := width - 1
	var rows_total := resolution.y - 1
	var bytes := values.to_byte_array()
	var band := clampi(_BAND_SAMPLES / width, 1, rows_total)
	for first in range(0, rows_total, band):
		var rows := mini(band, rows_total - first)
		var image := Image.create_from_data(width, rows + 1, false, Image.FORMAT_RF, bytes.slice(first * width * 4, (first + rows + 1) * width * 4))
		image.resize(width * 2, (rows + 1) * 2, Image.INTERPOLATE_NEAREST)
		image = image.get_region(Rect2i(1, 1, cell_width * 2, rows * 2))
		image.shrink_x2()
		var means := image.get_data().to_float32_array()
		var base := first * cell_width
		var size := means.size()
		for index in size:
			var mean := means[index]
			if mean >= low and mean <= high:
				flags[base + index] |= bit

## Sets `bit` where the steeper canonical triangle's slope is in low..high
## degrees, compared as squared rise over squared run (no per-cell atan). With
## pattern >= 0 only cells whose flags equal pattern are visited.
static func _slope_pass(data: StrataRuntimeData, flags: PackedByteArray, bit: int, low: float, high: float, pattern: int) -> void:
	var heights := data.heights
	var width := data.resolution.x
	var cell_width := width - 1
	var spacing := data.get_spacing()
	var low_limit := -INF if low <= 0.0 else pow(tan(deg_to_rad(low)) * spacing, 2.0)
	var high_limit := INF if high >= 90.0 else pow(tan(deg_to_rad(high)) * spacing, 2.0)
	if pattern >= 0:
		var index := flags.find(pattern)
		while index != -1:
			# Sample index of the cell's a corner: z * width + x.
			@warning_ignore("integer_division")
			var i := index + index / cell_width
			var a := heights[i]
			var b := heights[i + 1]
			var c := heights[i + width]
			var d := heights[i + width + 1]
			var steep := (b - a) * (b - a) + (c - a) * (c - a)
			var other := (d - c) * (d - c) + (d - b) * (d - b)
			if other > steep: steep = other
			if steep >= low_limit and steep <= high_limit:
				flags[index] = pattern | bit
			index = flags.find(pattern, index + 1)
		return
	for z in data.resolution.y - 1:
		var row := z * width
		var cell := z * cell_width
		var a := heights[row]
		var c := heights[row + width]
		for x in cell_width:
			var i := row + x + 1
			var b := heights[i]
			var d := heights[i + width]
			var p := b - a
			var q := c - a
			var steep := p * p + q * q
			p = d - c
			q = d - b
			var other := p * p + q * q
			if other > steep: steep = other
			if steep >= low_limit and steep <= high_limit:
				flags[cell + x] |= bit
			a = b
			c = d

## Sets `bit` on cells the canonical exclusion mask leaves clear (0). On fresh
## (all-zero) flags: fill, then clear the excluded cells.
static func _exclusion_pass(mask: PackedByteArray, flags: PackedByteArray, bit: int, fresh: bool) -> void:
	var count := mask.size()
	if not fresh:
		for index in count:
			if mask[index] == 0:
				flags[index] |= bit
		return
	flags.fill(bit)
	if mask.count(BLOCKED) * 4 < count:
		var index := mask.find(BLOCKED)
		while index != -1:
			flags[index] = 0
			index = mask.find(BLOCKED, index + 1)
		return
	for index in count:
		if mask[index] != 0:
			flags[index] = 0
