# Strata addon package

This standalone package is built from source commit e6a02e0d2b694438f1f51962ce1579915ec4922f. It depends on Godot
and godot-cpp, but does not require HEGo or Houdini. See `PACKAGE.json` for
the package dependency declaration and `native-build.json` for binary receipts.

# Strata

Layered terrain for Godot 4.7+: hand-painted and procedural layers composed into one
heightfield, a quadtree mesher, a material renderer with up to 32 materials, and a bake
that produces runtime data for collision and navigation. Strata has no dependency on
HEGo or Houdini; the native extension needs only godot-cpp.

- `StrataTerrain3D` holds the layer stack and its `storage_directory`, where every layer
  and cooked channel is one file (`StrataStorage`).
- `StrataLayer` is either manual (brush data) or procedural (channels committed by a
  producer such as the HEGo Strata bridge).
- `StrataBake`, `StrataCollision` and `StrataNavigation` turn the compiled stack into
  gameplay data; the `strata_runtime_*` scripts load that data without the extension.

Documentation: `docs/development/terrain_runtime.md`, `docs/development/terrain_shading.md`,
`docs/development/terrain_material_blending.md` and `docs/development/terrain_macro.md` in the HEGo repository.
Native binaries are receipted in `native-build.json`.