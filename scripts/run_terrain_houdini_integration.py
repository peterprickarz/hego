#!/usr/bin/env python3
"""Run the Strata/Houdini round-trip in a disposable Godot project.

This keeps the integration fixture isolated from the regular demo and never
changes either add-on's canonical binary directories.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_NATIVE_TEST = "res://tests/hego_heightfield_fields_native_test.gd"
DEFAULT_INTEGRATION_TEST = "res://tests/terrain_houdini_roundtrip_test.gd"
DEFAULT_STANDALONE_TEST = "res://tests/terrain_cache_standalone_test.gd"
DEFAULT_TRANSACTION_TEST = "res://tests/procedural_transaction_test.gd"
DEFAULT_LIFETIME_TEST = "res://tests/terrain_transport_lifetime_test.gd"


def godot_executable(argument: str | None) -> str:
    candidate = argument or os.environ.get("GODOT_BIN") or shutil.which("godot")
    if not candidate:
        raise RuntimeError("Godot was not found; pass --godot or set GODOT_BIN")
    resolved = shutil.which(candidate) or candidate
    if not Path(resolved).is_file():
        raise RuntimeError(f"Godot executable does not exist: {resolved}")
    return str(Path(resolved).resolve())


HEGO_LIBRARY_NAME = "libhego.linux.template_debug.x86_64.so"
TERRAIN_LIBRARY_NAME = "libstrata.linux.template_debug.x86_64.so"


def stage_project(destination: Path, hego_library: Path, terrain_library: Path, hfs: Path, test_scripts: list[str]) -> None:
    (destination / "addons").mkdir(parents=True, exist_ok=True)
    # The bridge carries the terrain input handler and target binding the tests cook through.
    for addon in ("hego", "strata", "hego_strata"):
        source = ROOT / "demo" / "addons" / addon
        if not source.is_dir():
            raise RuntimeError(f"Missing canonical add-on: {source}")
        shutil.copytree(source, destination / "addons" / addon)
    # Replace only the disposable project's copies. The tracked HEGo binary and
    # canonical addon directories are never written by this runner.
    shutil.copy2(hego_library, destination / "addons" / "hego" / "bin" / HEGO_LIBRARY_NAME)
    shutil.copy2(terrain_library, destination / "addons" / "strata" / "bin" / TERRAIN_LIBRARY_NAME)

    for test_script in test_scripts:
        if not test_script.startswith("res://"):
            raise RuntimeError("test scripts must be project paths beginning with res://")
        test_relative = Path(test_script.removeprefix("res://"))
        if ".." in test_relative.parts:
            raise RuntimeError("test scripts must stay inside the staged demo project")
        test_source = ROOT / "demo" / test_relative
        if not test_source.is_file():
            raise RuntimeError(f"Integration test is missing: {test_source}")
        test_destination = destination / test_relative
        test_destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(test_source, test_destination)

    (destination / "project.godot").write_text(
        'config_version=5\n\n'
        '[application]\n'
        'config/name="Strata Houdini Integration"\n'
        'config/features=PackedStringArray("4.4")\n\n'
        '[hego]\n'
        f'houdini_installation_path="{str(hfs).replace(chr(92), chr(92) * 2)}"\n\n'
        '[rendering]\n'
        'renderer/rendering_method="gl_compatibility"\n',
        encoding="utf-8",
    )


def stage_standalone_project(destination: Path, terrain_library: Path, test_script: str, transaction_script: str) -> None:
    addon = ROOT / "demo" / "addons" / "strata"
    if not addon.is_dir():
        raise RuntimeError(f"Missing canonical add-on: {addon}")
    (destination / "addons").mkdir(parents=True, exist_ok=True)
    shutil.copytree(addon, destination / "addons" / "strata")
    shutil.copy2(terrain_library, destination / "addons" / "strata" / "bin" / TERRAIN_LIBRARY_NAME)
    if not test_script.startswith("res://"):
        raise RuntimeError("--standalone-test-script must begin with res://")
    relative = Path(test_script.removeprefix("res://"))
    if ".." in relative.parts:
        raise RuntimeError("--standalone-test-script must stay inside the staged demo project")
    source = ROOT / "demo" / relative
    if not source.is_file():
        raise RuntimeError(f"Standalone cache test is missing: {source}")
    destination_test = destination / relative
    destination_test.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination_test)
    if not transaction_script.startswith("res://"):
        raise RuntimeError("--transaction-test-script must begin with res://")
    transaction_relative = Path(transaction_script.removeprefix("res://"))
    if ".." in transaction_relative.parts:
        raise RuntimeError("--transaction-test-script must stay inside the staged project")
    transaction_source = ROOT / "demo" / transaction_relative
    if not transaction_source.is_file():
        raise RuntimeError(f"Standalone transaction test is missing: {transaction_source}")
    transaction_destination = destination / transaction_relative
    transaction_destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(transaction_source, transaction_destination)
    (destination / "project.godot").write_text(
        'config_version=5\n\n'
        '[application]\n'
        'config/name="Strata Standalone Resource Test"\n'
        'config/features=PackedStringArray("4.4")\n\n'
        '[rendering]\n'
        'renderer/rendering_method="gl_compatibility"\n',
        encoding="utf-8",
    )


def run(command: list[str], *, env: dict[str, str], cwd: Path, timeout: int) -> int:
    print("+", " ".join(command), flush=True)
    process = subprocess.Popen(command, cwd=cwd, env=env, start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        # HAPI may have launched a Houdini process in this process group. Stop
        # only the children owned by this invocation; never kill unrelated HARS.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        print(f"error: command exceeded {timeout}s timeout; owned process group was stopped", file=sys.stderr)
        return 124


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", help="Godot 4.4.1 executable (or set GODOT_BIN)")
    parser.add_argument("--hfs", default=os.environ.get("HFS", "/opt/hfs22.0"), help="Houdini installation root")
    parser.add_argument("--hego-library", required=True, help="Built HEGo Linux debug extension library (copied only into the temp project)")
    parser.add_argument(
        "--terrain-library",
        default=str(ROOT / "demo" / "addons" / "strata" / "bin" / TERRAIN_LIBRARY_NAME),
        help="Built Strata Linux debug extension library",
    )
    parser.add_argument("--native-test-script", default=DEFAULT_NATIVE_TEST, help="Project-relative native HAPI grid transport test")
    parser.add_argument("--test-script", default=DEFAULT_INTEGRATION_TEST, help="Project-relative terrain transaction/HEGoNode3D integration test")
    parser.add_argument("--standalone-test-script", default=DEFAULT_STANDALONE_TEST, help="Project-relative resource persistence test without HEGo")
    parser.add_argument("--transaction-test-script", default=DEFAULT_TRANSACTION_TEST, help="Project-relative generic transaction test without HEGo/Houdini")
    parser.add_argument("--timeout", type=int, default=300, help="Per-Godot-process timeout in seconds")
    parser.add_argument("--keep-project", action="store_true", help="Keep and print the temporary project path")
    parser.add_argument("--prepare-only", action="store_true", help="Stage files without running Godot")
    args = parser.parse_args()

    try:
        godot = godot_executable(args.godot)
        hfs = Path(args.hfs).resolve()
        if not hfs.is_dir() or not (hfs / "bin").is_dir():
            raise RuntimeError(f"Houdini installation is unavailable: {hfs}")
        hego_library = Path(args.hego_library).resolve()
        terrain_library = Path(args.terrain_library).resolve()
        if not hego_library.is_file():
            raise RuntimeError(f"HEGo extension library is unavailable: {hego_library}")
        if not terrain_library.is_file():
            raise RuntimeError(f"Strata extension library is unavailable: {terrain_library}")
        if args.timeout < 1:
            raise RuntimeError("--timeout must be positive")
        if sys.platform != "linux":
            raise RuntimeError("This prototype runner currently stages the Linux x86_64 HEGo binary only")

        temp_context = None
        if args.keep_project:
            project = Path(tempfile.mkdtemp(prefix="hego-terrain-houdini-"))
        else:
            temp_context = tempfile.TemporaryDirectory(prefix="hego-terrain-houdini-")
            project = Path(temp_context.name)
        standalone_project = project / "standalone"
        integration_project = project / "integration"
        stage_standalone_project(standalone_project, terrain_library, args.standalone_test_script, args.transaction_test_script)
        stage_project(integration_project, hego_library, terrain_library, hfs, [DEFAULT_LIFETIME_TEST, args.native_test_script, args.test_script])
        print(f"Staged standalone resource project: {standalone_project}", flush=True)
        print(f"Staged Houdini integration project: {integration_project}", flush=True)
        if args.prepare_only:
            print("Staging complete; no Houdini session was started.")
            if temp_context:
                print("Use --keep-project to retain this project for inspection.")
            return 0

        env = os.environ.copy()
        env["HFS"] = str(hfs)

        # First prove the data resource saves without HEGo or Houdini being
        # staged, then prepare the separate real-HAPI project.
        result = run([godot, "--headless", "--path", str(standalone_project), "--editor", "--import", "--quit"], env=env, cwd=standalone_project, timeout=args.timeout)
        if result:
            return result
        result = run([godot, "--headless", "--path", str(standalone_project), "--script", args.standalone_test_script], env=env, cwd=standalone_project, timeout=args.timeout)
        if result:
            return result
        result = run([godot, "--headless", "--path", str(standalone_project), "--script", args.transaction_test_script], env=env, cwd=standalone_project, timeout=args.timeout)
        if result:
            return result
        # Load/import the global-class cache before the two HEGo/HAPI tests. On
        # a first import Godot 4.4 can report a transient Busy for HEGo's editor
        # dialog preload, so reopen after the queue has settled.
        result = run([godot, "--headless", "--path", str(integration_project), "--editor", "--import", "--quit"], env=env, cwd=integration_project, timeout=args.timeout)
        if result:
            return result
        result = run([godot, "--headless", "--path", str(integration_project), "--editor", "--import", "--quit"], env=env, cwd=integration_project, timeout=args.timeout)
        if result:
            return result
        result = run([godot, "--headless", "--path", str(integration_project), "--script", DEFAULT_LIFETIME_TEST], env=env, cwd=integration_project, timeout=args.timeout)
        if result:
            return result
        result = run([godot, "--headless", "--path", str(integration_project), "--script", args.native_test_script], env=env, cwd=integration_project, timeout=args.timeout)
        if result:
            return result
        result = run([godot, "--headless", "--path", str(integration_project), "--script", args.test_script], env=env, cwd=integration_project, timeout=args.timeout)
        if result == 0:
            print("HEGO_TERRAIN_HOUDINI_INTEGRATION_PASS")
        return result
    except (OSError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    finally:
        if "temp_context" in locals() and temp_context:
            temp_context.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
