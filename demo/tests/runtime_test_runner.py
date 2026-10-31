#!/usr/bin/env python3
"""Runtime bake/collision/navigation suites in disposable projects under build/test-staging.

Stages demo/addons/strata into an isolated authoring project (never into
the tracked demo add-on directories), imports it, runs the
runtime_* suites headless, then stages a second project that contains only the
three runtime scripts (no native extension, HEGo or Houdini) and loads the
exported scene there.
"""

import argparse
import os
import shutil
import subprocess
import sys
import selectors
import signal
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADDON = ROOT / "demo" / "addons" / "strata"
TESTS = Path(__file__).resolve().parent
# Staged projects live on disk under the repository's ignored build/ directory, never in
# tmpfs (/tmp, /dev/shm), where the imported 4097-square fixtures would sit in RAM.
STAGING = ROOT / "build" / "test-staging"
TMPFS = (Path("/tmp"), Path("/dev/shm"), Path("/run"))
RUNTIME_SCRIPTS = ("strata_regions.gd", "strata_region_data.gd", "strata_runtime_data.gd", "strata_nav_profiles.gd", "strata_collision.gd", "strata_navigation.gd", "strata_render_settings.gd")
SUITES = ("runtime_data_test.gd", "runtime_collision_test.gd", "runtime_navigation_test.gd", "runtime_bake_test.gd", "runtime_macro_test.gd", "region_compose_test.gd")
RUNTIME_ONLY_SUITES = ("runtime_roundtrip_test.gd", "runtime_macro_roundtrip_test.gd")
PROJECT = """config_version=5

[application]

config/name="{name}"

[rendering]

renderer/rendering_method="gl_compatibility"

[navigation]

3d/merge_rasterizer_cell_scale=0.01
"""


def run(command, timeout, quiet=False):
    print("$", " ".join(str(part) for part in command), flush=True)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    output = []
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    aborted = False
    while selector.get_map():
        if time.monotonic() >= deadline:
            print("Runtime process exceeded its bounded timeout", flush=True)
            aborted = True
        for key, _ in selector.select(0.2):
            chunk = os.read(key.fileobj.fileno(), 65536)
            if not chunk:
                selector.unregister(key.fileobj)
                continue
            text = chunk.decode("utf-8", errors="replace")
            output.append(text)
            if not quiet: print(text, end="", flush=True)
            if "SCRIPT ERROR" in "".join(output[-2:]) or "Parse Error" in "".join(output[-2:]): aborted = True
        if aborted:
            # Only this owned process group; never terminate other Godot/HAPI work.
            try: os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
            break
    selector.close()
    code = process.wait(timeout=5)
    text = "".join(output)
    if quiet and (code or aborted): print(text, flush=True)
    return subprocess.CompletedProcess(command, code if code else (1 if aborted else 0), text)


def stage_project(path: Path, name: str):
    if path.exists():
        shutil.rmtree(path)
    (path / "tests").mkdir(parents=True)
    (path / "project.godot").write_text(PROJECT.format(name=name))


def seed_extension_list(project: Path) -> None:
    """Pre-register the staged GDExtensions as Godot itself would after a first scan.

    Godot 4.7 (and 4.8-dev6) aborts while quitting a headless --import of a project whose
    extensions it discovers only during that first scan; with .godot/extension_list.cfg
    already naming them it exits cleanly, so write it before the first import.
    """
    descriptors = sorted(project.glob("addons/*/**/*.gdextension")) + sorted(project.glob("addons/*/*.gdextension"))
    if not descriptors:
        return
    (project / ".godot").mkdir(exist_ok=True)
    lines = sorted({"res://" + path.relative_to(project).as_posix() for path in descriptors})
    (project / ".godot" / "extension_list.cfg").write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"))
    parser.add_argument("--work", type=Path, default=STAGING / "runtime")
    parser.add_argument("--large", action="store_true", help="also run the 4097x4097 bake measurement")
    parser.add_argument("--only", action="append", help="run only this suite (repeatable)")
    parser.add_argument("--keep", action="store_true", help="keep the staged projects after a successful run (they are always kept after a failure)")
    args = parser.parse_args()
    work = args.work.resolve()
    if any(work == root or root in work.parents for root in TMPFS):
        parser.error("--work must not be on tmpfs (/tmp, /dev/shm, /run); the default is build/test-staging/runtime")
    if (work == ROOT or ROOT in work.parents) and STAGING not in work.parents and work != STAGING:
        parser.error("--work inside the repository must be under build/test-staging")
    work.mkdir(parents=True, exist_ok=True)
    authoring = work / "authoring"
    runtime_only = work / "runtime_only"
    stage_project(authoring, "HEGo runtime authoring tests")
    shutil.copytree(ADDON, authoring / "addons" / "strata")
    for script in list(TESTS.glob("runtime_*.gd")) + [TESTS / "region_compose_test.gd"]:
        shutil.copy2(script, authoring / "tests" / script.name)
    (authoring / "export").mkdir()
    seed_extension_list(authoring)
    imported = run([args.godot, "--headless", "--editor", "--path", str(authoring), "--import", "--quit"], 120, quiet=True)
    if imported.returncode: return imported.returncode

    # The roundtrip suite only runs in the runtime-only project below.
    suites = [suite for suite in (args.only or SUITES) if suite not in RUNTIME_ONLY_SUITES]
    if args.large and "runtime_large_bake_test.gd" not in suites:
        suites.append("runtime_large_bake_test.gd")
    failed = []
    for suite in suites:
        completed = run([args.godot, "--headless", "--path", str(authoring), "--script", f"res://tests/{suite}"], 150)
        if completed.returncode != 0 or ": PASS" not in completed.stdout:
            failed.append(suite)

    runtime_only_suites = [suite for suite in RUNTIME_ONLY_SUITES if args.only is None or suite in args.only]
    if runtime_only_suites:
        stage_project(runtime_only, "HEGo runtime-only roundtrip")
        target = runtime_only / "addons" / "strata"
        target.mkdir(parents=True)
        for script in RUNTIME_SCRIPTS:
            for suffix in ("", ".uid"):
                source = authoring / "addons" / "strata" / (script + suffix)
                if source.exists():
                    shutil.copy2(source, target / source.name)
        shutil.copytree(authoring / "export", runtime_only / "export")
        for script in ("runtime_test_base.gd",) + RUNTIME_ONLY_SUITES:
            shutil.copy2(TESTS / script, runtime_only / "tests" / script)
        seed_extension_list(runtime_only)
        imported = run([args.godot, "--headless", "--editor", "--path", str(runtime_only), "--import", "--quit"], 120, quiet=True)
        if imported.returncode: return imported.returncode
        for suite in runtime_only_suites:
            completed = run([args.godot, "--headless", "--path", str(runtime_only), "--script", f"res://tests/{suite}"], 150)
            if completed.returncode != 0 or ": PASS" not in completed.stdout:
                failed.append(suite)

    if failed:
        print("RUNTIME SUITES FAILED:", ", ".join(failed))
        return 1
    if not args.keep:
        for staged in (authoring, runtime_only):
            shutil.rmtree(staged, ignore_errors=True)
        try: work.rmdir()
        except OSError: pass
    print("RUNTIME SUITES PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
