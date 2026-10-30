#!/usr/bin/env python3
"""Checks the addon split in disposable projects. Never starts Houdini.

HEGo and Strata must each work without the other; only hego_strata
depends on both. This stages two projects under --work, never touching demo/:

  hego_only    addons/hego alone            -> tests/hego_standalone_test.gd
  strata_only  addons/strata alone          -> tests/terrain_cache_standalone_test.gd
  all_addons   hego, strata and the bridge  -> tests/hego_extension_points_test.gd

Strata on its own is covered by runtime_test_runner.py, whose runtime project has no
HEGo. Pass --godot (or set GODOT_BIN) to a real Godot binary; a launcher that opens a
terminal window will hang here.
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADDONS = ROOT / "demo" / "addons"
TESTS = Path(__file__).resolve().parent
PROJECTS = {
    "hego_only": (("hego",), "hego_standalone_test.gd", "HEGO_STANDALONE_TEST: PASS"),
    "strata_only": (("strata",), "terrain_cache_standalone_test.gd", "HEGO_TERRAIN_STANDALONE_CACHE_PASS"),
    "all_addons": (("hego", "strata", "hego_strata"), "hego_extension_points_test.gd", "HEGO_EXTENSION_POINTS_TEST: PASS"),
}
PROJECT = """config_version=5

[application]

config/name="{name}"
config/features=PackedStringArray("4.4")

[rendering]

renderer/rendering_method="gl_compatibility"
"""


def stage(destination: Path, addons: tuple, test: str) -> None:
    if destination.exists():
        shutil.rmtree(destination)
    (destination / "addons").mkdir(parents=True)
    for addon in addons:
        shutil.copytree(ADDONS / addon, destination / "addons" / addon)
    (destination / "tests").mkdir()
    shutil.copy2(TESTS / test, destination / "tests" / test)
    (destination / "project.godot").write_text(PROJECT.format(name=destination.name))


def run(command: list, timeout: int) -> tuple[int, str]:
    print("$", " ".join(str(part) for part in command), flush=True)
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 1, f"Timed out after {timeout} s"
    return completed.returncode, completed.stdout + completed.stderr


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"))
    parser.add_argument("--work", type=Path, default=Path("/tmp/hego-addon-split-test"))
    args = parser.parse_args()
    failed = []
    for name, (addons, test, marker) in PROJECTS.items():
        project = args.work / name
        stage(project, addons, test)
        code, output = run([args.godot, "--headless", "--editor", "--path", str(project), "--import", "--quit"], 600)
        if code != 0:
            print(output)
            failed.append(f"{name}: import failed")
            continue
        code, output = run([args.godot, "--headless", "--path", str(project), "--script", "res://tests/" + test], 300)
        print(output)
        if code != 0 or marker not in output:
            failed.append(f"{name}: {test} failed")
    if failed:
        print("ADDON SPLIT FAILED: " + "; ".join(failed))
        return 1
    print("ADDON SPLIT PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
