# HEGo Strata package

This package is built from source commit e09d823b11dd14f76f6a8e89f9efccb8e86edffe. It cooks Houdini Digital Assets
into Strata layers and requires both other packages from the same source
revision: HEGo at `addons/hego` and Strata at `addons/strata`.
See `PACKAGE.json` for their branches. It contains no native code.

# HEGo Strata

The bridge between HEGo and Strata. It requires both addons from the same source
revision and contains no native code.

HEGo finds both of its handlers through its extension points, so a `HEGoNode3D` needs no
extra child or setup. `HEGoStrataOutput` (an `HEGoOutputHandler`) routes every cooked
heightfield volume that carries a `hegostrata_layer_path` attribute into the procedural
`StrataLayer` it names, usually from the HDA's `target_layer_path` parameter; every channel
the HDA emits is accepted. All targets of one cook publish as one transaction: a rejected
result leaves the previous layer content in place, marks those layers stale with the reason
and logs a warning. `HEGoStrataInput` (an `HEGoInputHandler`) uploads Strata layers (raw or
cumulative) from the host's ordinary input rows and makes its cooks explicit and strict.
Published layers record their producer and inputs; Strata and this plugin's editor watch
mark them stale when either changes, until the host is cooked again.

Attribute contract and examples: `docs/strata/houdini.md`; the island
demo's HDAs are documented in `docs/development/island_hda.md`.