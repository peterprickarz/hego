#!/usr/bin/env python3
"""Open the saved island in the main demo; Houdini runs only for explicit cook actions.

The island's data lives at fixed paths under demo/island/terrain (see StrataStorage): one
file per hand layer, one per cooked channel, plus the region bake (runtime_data.res and
regions/). Material ids and weights are composed from the stack at the terrain's region
spacing (1 m); there are no control-map files. A cook overwrites its files in place. The
headless modes below cook into those files:

  --prepare           rough base -> coarse -> detail -> tint -> materials (1 m, 4097^2) from the
                      saved hand layers, bake the regions, then save (overwrites the stage and
                      bake files in place; every hand layer, including the top StrataLayer, is
                      saved as loaded and the run refuses to save if a cook changed one).
                      Roughly coarse 15 s, detail 172 s, materials 75 s (about 12 GB in
                      hython), bake 15 s.
  --cook-materials    only the material distribution, against the saved layers, then bake
  --five-stage-check  ARTIFICIAL FIXTURE: scripted strokes stand in for hand edits to check the
                      five-stage preservation contract; cooks in memory, saves nothing
  --verify            reopen the saved island headlessly without starting Houdini

Material cook options (--prepare and --cook-materials). A material lattice above 4097 samples per
axis is cooked in tiles and published in one transaction (docs/development/island_material_distribution.md):

  --storage DIR            write every save to DIR, a scratch copy of demo/island/terrain made
                           beforehand (cp -r); the script refuses the shipped directory itself and
                           reaches DIR through a symlink in demo/.godot/scratch (ignored by git)
  --material-spacing M     SCRATCH EXPERIMENT: cook the material pass at M metres instead of the terrain's
                           region spacing (the terrain's spacing and the MaterialCook input row are changed
                           in memory only); at 0.5 m only the material fields are cooked and saved, there is
                           no whole-terrain height image to bake from the cook script
  --tile-samples N         largest tile, per axis (default 4097, the HDA limit; smaller only for tests)
  --tile-overlap N|exact   samples two tiles share (default 32); "exact" is the overlap at which tiles
                           equal a whole cook (900 at 0.5 m)
  --material-storage S     unorm8 (default) or float value storage of a tiled result
"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "demo"
GODOT = "/home/peter/Godot/Godot_v4.7.2-stable_linux.x86_64"
SHOWCASE = "res://island/island_showcase.tscn"
EDITOR_SCENE = "res://scenes/terrain_island.tscn"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", GODOT))
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--prepare", action="store_true", help="recook every stage from the rough base and the saved hand layers, bake the regions, then save")
    modes.add_argument("--cook-materials", action="store_true", help="cook only the material distribution (1 m) against the saved layers, then bake and save")
    modes.add_argument("--five-stage-check", action="store_true", help="artificial fixture: scripted hand edits + recooks checking the preservation contract; saves nothing")
    modes.add_argument("--verify", action="store_true", help="reopen the saved island headlessly without starting Houdini")
    modes.add_argument("--editor", action="store_true", help="open scenes/terrain_island.tscn in the main demo editor")
    modes.add_argument("--stage-only", action="store_true", help="validate the installed main-demo addons without launching")
    parser.add_argument("--storage", type=Path, help="scratch copy of the island storage directory that receives every save")
    parser.add_argument("--material-spacing", type=float, help="scratch experiment: material pass spacing in metres")
    parser.add_argument("--tile-samples", type=int, help="largest material tile per axis (default 4097)")
    parser.add_argument("--tile-overlap", help="samples shared by neighbouring material tiles, or 'exact' (default 32)")
    parser.add_argument("--material-storage", choices=("unorm8", "float"), help="value storage of a tiled material result (default unorm8)")
    parser.add_argument("--capture", type=Path)
    parser.add_argument("--capture-view", choices=("overview", "platform", "ground"), default="overview")
    parser.add_argument("--show-ownership", action="store_true")
    parser.add_argument("--quit-after-frames", type=int)
    parser.add_argument("--skip-import", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    godot = str(Path(args.godot).expanduser()) if Path(args.godot).expanduser().is_file() else shutil.which(args.godot)
    if not godot: parser.error("Godot executable is missing; set GODOT_BIN or --godot to Godot 4.7.2")
    args.godot = godot
    terrain_library = ROOT / "demo/addons/strata/bin/libstrata.linux.template_debug.x86_64.so"
    if not terrain_library.is_file(): parser.error("Build the Strata library first: scripts/build-terrain.sh")
    if args.quit_after_frames is not None and args.quit_after_frames < 1: parser.error("--quit-after-frames must be positive")
    cook_options = (args.storage, args.material_spacing, args.tile_samples, args.tile_overlap, args.material_storage)
    if any(option is not None for option in cook_options) and not (args.prepare or args.cook_materials):
        parser.error("--storage, --material-spacing, --tile-samples, --tile-overlap and --material-storage apply to --prepare and --cook-materials only")
    if args.storage is not None:
        storage = args.storage.expanduser().resolve()
        shipped = (PROJECT / "island/terrain").resolve()
        if storage == shipped or shipped in storage.parents: parser.error("--storage must be a scratch copy, never demo/island/terrain")
        if not storage.is_dir(): parser.error("--storage must be an existing directory (copy demo/island/terrain there first)")
        # Strata saves only to res:// or user:// paths, so the scratch copy is reached through a symlink
        # in the project's ignored .godot folder.
        link = PROJECT / ".godot/scratch" / storage.name
        link.parent.mkdir(parents=True, exist_ok=True)
        if link.is_symlink() and link.resolve() != storage: link.unlink()
        if not link.exists(): link.symlink_to(storage, target_is_directory=True)
        args.storage = "res://.godot/scratch/" + storage.name
    if args.tile_overlap is not None and args.tile_overlap != "exact" and not args.tile_overlap.isdigit(): parser.error("--tile-overlap must be a number of samples or 'exact'")
    if args.material_spacing is not None and args.material_spacing <= 0: parser.error("--material-spacing must be positive")
    headless = args.prepare or args.cook_materials or args.five_stage_check or args.verify
    diagnostic_view = args.capture_view != "overview" or args.show_ownership
    diagnostic_run = bool(args.capture or diagnostic_view or args.quit_after_frames is not None)
    if diagnostic_run and (args.editor or args.stage_only or headless):
        parser.error("capture/view/frame-limit options apply to showcase play only")
    if args.stage_only:
        print(f"Using installed addons in {PROJECT / 'addons'}; no files staged")
        return 0
    # Plain play opens the saved editor scene, as the editor does. The showcase, with its
    # explicit cook buttons, is for headless modes and diagnostic captures.
    scene = SHOWCASE if headless or diagnostic_run else EDITOR_SCENE
    if diagnostic_run:
        print("Opening the showcase for capture/view/frame-limit options; the editor scene is unchanged", flush=True)
    env = os.environ.copy()
    env.setdefault("DISPLAY", ":0")
    common = [args.godot, "--path", str(PROJECT)]
    if args.verbose: common.append("--verbose")
    if not args.skip_import:
        result = subprocess.run(common + ["--headless", "--editor", "--import", "--quit"], cwd=ROOT, env=env)
        if result.returncode: return result.returncode
    command = common + (["--headless"] if headless else ["--rendering-method", "forward_plus"])
    if args.editor: command += ["--editor"]
    command += [scene]
    extra = []
    if args.prepare: extra.append("--prepare-island")
    if args.cook_materials: extra.append("--cook-materials")
    if args.five_stage_check: extra.append("--five-stage-check")
    if args.storage is not None: extra.append("--storage=" + args.storage)
    if args.material_spacing is not None: extra.append("--material-spacing=" + repr(args.material_spacing))
    if args.tile_samples is not None: extra.append("--tile-samples=" + str(args.tile_samples))
    if args.tile_overlap is not None: extra.append("--tile-overlap=" + args.tile_overlap)
    if args.material_storage is not None: extra.append("--material-storage=" + args.material_storage)
    if args.verify: extra.append("--verify")
    if args.capture:
        args.capture.parent.mkdir(parents=True, exist_ok=True)
        extra.append("--capture=" + str(args.capture.resolve()))
    extra.append("--capture-view=" + args.capture_view)
    if args.show_ownership: extra.append("--show-ownership")
    if args.quit_after_frames: extra.append("--quit-after-frames=" + str(args.quit_after_frames))
    if extra: command += ["--"] + extra
    return subprocess.run(command, cwd=ROOT, env=env).returncode


if __name__ == "__main__":
    raise SystemExit(main())
