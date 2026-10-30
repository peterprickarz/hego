# HEGo Strata

The bridge between HEGo and Strata. It requires both addons from the same source
revision and contains no native code.

A `HEGoNode3D` with a `StrataTargets` child cooks its HDA and routes every heightfield
volume that carries a `hegostrata_layer_path` attribute into the named `StrataLayer`,
as one transaction per cook: a rejected result leaves the previous layer content in
place. `HEGoStrataInput` uploads Strata layers (raw or cumulative) as HDA inputs.

Attribute contract and examples: `docs/terrain-houdini-integration.md`; the island
demo's HDAs are documented in `docs/island-hda.md`.
