#!/usr/bin/env python3
"""Open the saved island in the main demo; Houdini runs only for explicit cook actions.

The island's data lives at fixed paths under demo/island/terrain (see StrataStorage): one
file per hand layer, one per cooked channel, plus the bake and material control maps. A
cook overwrites its files in place. The headless modes below cook into those files:

  --prepare           rough base -> coarse -> detail -> tint -> materials from the saved hand
                      layers, then save (overwrites the stage files in place)
  --cook-materials    only the material distribution, against the saved layers
  --five-stage-check  ARTIFICIAL FIXTURE: scripted strokes stand in for hand edits to check the
                      five-stage preservation contract; cooks in memory, saves nothing
  --verify            reopen the saved island headlessly without starting Houdini
"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "demo"
GODOT = "/home/peter/Godot/Godot_v4.4.1-stable_linux.x86_64"
SHOWCASE = "res://island/island_showcase.tscn"
EDITOR_SCENE = "res://scenes/terrain_island.tscn"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", GODOT))
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--prepare", action="store_true", help="recook every stage from the rough base and the saved hand layers, then save")
    modes.add_argument("--cook-materials", action="store_true", help="cook only the material distribution against the saved layers")
    modes.add_argument("--five-stage-check", action="store_true", help="artificial fixture: scripted hand edits + recooks checking the preservation contract; saves nothing")
    modes.add_argument("--verify", action="store_true", help="reopen the saved island headlessly without starting Houdini")
    modes.add_argument("--editor", action="store_true", help="open scenes/terrain_island.tscn in the main demo editor")
    modes.add_argument("--stage-only", action="store_true", help="validate the installed main-demo addons without launching")
    parser.add_argument("--capture", type=Path)
    parser.add_argument("--capture-view", choices=("overview", "platform", "ground"), default="overview")
    parser.add_argument("--show-ownership", action="store_true")
    parser.add_argument("--quit-after-frames", type=int)
    parser.add_argument("--skip-import", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    godot = str(Path(args.godot).expanduser()) if Path(args.godot).expanduser().is_file() else shutil.which(args.godot)
    if not godot: parser.error("Godot executable is missing; set GODOT_BIN or --godot to Godot 4.4.1")
    args.godot = godot
    terrain_library = ROOT / "demo/addons/strata/bin/libstrata.linux.template_debug.x86_64.so"
    if not terrain_library.is_file(): parser.error("Build the Strata library first: scripts/build-terrain.sh")
    if args.quit_after_frames is not None and args.quit_after_frames < 1: parser.error("--quit-after-frames must be positive")
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
