#!/usr/bin/env python3
"""Runtime bake/collision/navigation suites in disposable /tmp projects.

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
RUNTIME_SCRIPTS = ("strata_runtime_data.gd", "strata_collision.gd", "strata_navigation.gd", "strata_render_settings.gd")
SUITES = ("runtime_data_test.gd", "runtime_collision_test.gd", "runtime_navigation_test.gd", "runtime_bake_test.gd", "runtime_macro_test.gd")
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"))
    parser.add_argument("--work", type=Path, default=Path("/tmp/hego-runtime-test"))
    parser.add_argument("--large", action="store_true", help="also run the 4097x4097 bake measurement")
    parser.add_argument("--only", action="append", help="run only this suite (repeatable)")
    args = parser.parse_args()
    work = args.work.resolve()
    if work == ROOT or ROOT in work.parents:
        parser.error("--work must be outside the repository")
    authoring = work / "authoring"
    runtime_only = work / "runtime_only"
    stage_project(authoring, "HEGo runtime authoring tests")
    shutil.copytree(ADDON, authoring / "addons" / "strata")
    for script in TESTS.glob("runtime_*.gd"):
        shutil.copy2(script, authoring / "tests" / script.name)
    (authoring / "export").mkdir()
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
        imported = run([args.godot, "--headless", "--editor", "--path", str(runtime_only), "--import", "--quit"], 120, quiet=True)
        if imported.returncode: return imported.returncode
        for suite in runtime_only_suites:
            completed = run([args.godot, "--headless", "--path", str(runtime_only), "--script", f"res://tests/{suite}"], 150)
            if completed.returncode != 0 or ": PASS" not in completed.stdout:
                failed.append(suite)

    if failed:
        print("RUNTIME SUITES FAILED:", ", ".join(failed))
        return 1
    print("RUNTIME SUITES PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
