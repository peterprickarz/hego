@tool
class_name CopiaSpecies
extends Resource
## A named group of [CopiaObject] variants painted or placed together as one logical species
## (for example "Bracken Fern" with large/medium/small variants and radial brush falloff rules).
## Editor-only authoring resource: never a build input.

const PlacementScript := preload("res://addons/copia/copia_placement_settings.gd")
const EntryScript := preload("res://addons/copia/copia_species_entry.gd")

## Human-readable label shown in the Copia dock (falls back to the file basename when blank).
@export var display_name := "":
	set(value):
		display_name = value
		emit_changed()
## Optional folder/category tag for filtering in the Copia dock (e.g. "ferns", "rocks", "trees").
@export var category := "":
	set(value):
		category = value
		emit_changed()
## Shared placement and paint rules for every variant in this species (unless an entry overrides it).
@export var placement: PlacementScript:
	set(value):
		placement = value
		emit_changed()
## The object variants belonging to this species.
@export var entries: Array[EntryScript] = []:
	set(value):
		entries = value
		emit_changed()


func label() -> String:
	if not display_name.is_empty():
		return display_name
	if not resource_path.is_empty():
		return resource_path.get_file().get_basename()
	return "Species"


func effective_placement() -> PlacementScript:
	return placement if placement != null else PlacementScript.new()


## Expands every valid entry into dab spec dictionaries for [code]CopiaBrush.sample_dab()[/code].
func to_dab_specs(weight_scale := 1.0) -> Array:
	var specs := []
	if weight_scale <= 0.0:
		return specs
	var base := effective_placement()
	for entry in entries:
		if entry == null or entry.object == null or entry.object.resource_path.is_empty() or entry.weight <= 0.0:
			continue
		var cfg: PlacementScript = entry.placement_override if entry.placement_override != null else (
			entry.object.placement if entry.object.placement != null and placement == null else base
		)
		var curve: Curve = entry.brush_strength_curve if entry.brush_strength_curve != null else cfg.brush_falloff
		specs.append(cfg.to_dab_spec(entry.object, {
			"weight": entry.weight * weight_scale,
			"band_curve": curve,
			"band_min": minf(entry.brush_strength_min, entry.brush_strength_max),
			"band_max": maxf(entry.brush_strength_min, entry.brush_strength_max),
			"scale_multiplier": entry.scale_multiplier,
			"spacing_override": entry.spacing_override,
		}))
	return specs


## Picks one [CopiaSpeciesEntry] weighted by its strength at [param brush_strength] (0..1).
func pick_entry(rng: RandomNumberGenerator, brush_strength := 1.0) -> EntryScript:
	var total := 0.0
	for entry in entries:
		if entry != null:
			total += entry.weight_at(brush_strength)
	if total <= 0.0:
		for entry in entries:
			if entry != null and entry.object != null:
				return entry
		return null
	var roll := rng.randf() * total
	var acc := 0.0
	for entry in entries:
		if entry == null:
			continue
		var w := entry.weight_at(brush_strength)
		acc += w
		if roll <= acc and w > 0.0:
			return entry
	return null


## All non-null object resource paths referenced by this species.
func object_paths() -> PackedStringArray:
	var out := PackedStringArray()
	for entry in entries:
		if entry != null and entry.object != null and not entry.object.resource_path.is_empty():
			if not out.has(entry.object.resource_path):
				out.append(entry.object.resource_path)
	return out
