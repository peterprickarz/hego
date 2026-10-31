#!/usr/bin/env python3
"""Launch the terrain prototype in the main demo, or run suites in a disposable project."""

import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "demo"
ADDON_SOURCE = ROOT / "demo" / "addons" / "strata"
PROTOTYPE_SCENE = "res://scenes/terrain_prototype/main.tscn"
RENDER_LAB_SCENE = "res://scenes/terrain_prototype/render_lab.tscn"
TEST_SCRIPTS = ("native_data_test.gd", "terrain_mesher_test.gd", "render_material_test.gd",
                "frontend_smoke_test.gd", "render_shader_probe.gd", "render_state_test.gd")


def seed_extension_list(project: Path) -> None:
    """Pre-register staged GDExtensions as Godot would after a first scan: Godot 4.7 aborts
    while quitting a headless --import that discovered them during that same scan."""
    descriptors = sorted(project.glob("addons/**/*.gdextension"))
    if not descriptors:
        return
    (project / ".godot").mkdir(exist_ok=True)
    lines = sorted({"res://" + path.relative_to(project).as_posix() for path in descriptors})
    (project / ".godot" / "extension_list.cfg").write_text("\n".join(lines) + "\n")


def stage_test_project(destination: Path) -> Path:
    """Copy only the terrain addon, test scripts and artificial prototype scenes."""
    shutil.copytree(ADDON_SOURCE, destination / "addons/strata")
    (destination / "tests").mkdir()
    for name in TEST_SCRIPTS:
        shutil.copy2(PROJECT / "tests" / name, destination / "tests" / name)
        uid = PROJECT / "tests" / (name + ".uid")
        if uid.is_file(): shutil.copy2(uid, destination / "tests" / uid.name)
    shutil.copytree(PROJECT / "scenes/terrain_prototype", destination / "scenes/terrain_prototype")
    (destination / "project.godot").write_text(
        'config_version=5\n\n[application]\nconfig/name="Strata Disposable Tests"\n'
        '[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
    seed_extension_list(destination)
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--godot",
        default=os.environ.get("GODOT_BIN") or shutil.which("godot") or "godot",
        help="Godot executable path (default: GODOT_BIN or godot on PATH)",
    )
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--test", action="store_true", help="run four headless data, mesher, material and frontend suites")
    modes.add_argument("--editor", action="store_true", help="open the prototype scene in the main demo editor")
    modes.add_argument("--prepare-only", action="store_true", help="validate the installed terrain addon without launching Godot")
    modes.add_argument("--test-renderer", action="store_true", help="run graphical Forward+ shader/material integration checks")
    parser.add_argument("--render-lab", action="store_true", help="launch the separate Forward+ renderer scene")
    parser.add_argument("--benchmark", action="store_true", help="run a deterministic Forward+ render benchmark")
    parser.add_argument("--frames", type=int, default=300, help="measured frames (benchmark minimum 300; 60 warmup frames)")
    parser.add_argument("--report", type=Path, help="explicit JSON report destination (required for --benchmark)")
    parser.add_argument("--no-displacement", action="store_true", help="disable height detail; useful for paired benchmarks")
    parser.add_argument("--capture", type=Path, help="save a render-lab screenshot to this path")
    parser.add_argument("--quit-after-frames", type=int, help="exit after this many render-lab frames; can combine with --capture")
    args = parser.parse_args()
    if args.render_lab and (args.test or args.editor or args.prepare_only or args.test_renderer):
        parser.error("--render-lab cannot be combined with tests, editor, or prepare-only modes")
    if args.benchmark:
        if args.test or args.editor or args.prepare_only or args.test_renderer:
            parser.error("--benchmark cannot be combined with test, editor, or prepare-only modes")
        args.render_lab = True
        if args.frames < 300:
            parser.error("--benchmark requires at least 300 measured frames")
        if args.report is None:
            parser.error("--benchmark requires an explicit --report PATH")
        if args.quit_after_frames is not None:
            parser.error("--benchmark cannot be combined with --quit-after-frames")
    if args.test_renderer and args.quit_after_frames is not None:
        parser.error("--quit-after-frames is only supported by --render-lab")
    if args.no_displacement and not (args.render_lab or args.benchmark):
        parser.error("--no-displacement requires --render-lab or --benchmark")
    if args.report is not None and not args.benchmark:
        parser.error("--report is only used by --benchmark")
    if args.capture is not None and not (args.render_lab or args.test_renderer):
        parser.error("--capture requires --render-lab or --test-renderer")
    if args.quit_after_frames is not None and not args.render_lab:
        parser.error("--quit-after-frames requires --render-lab")
    if args.quit_after_frames is not None and args.quit_after_frames < 1:
        parser.error("--quit-after-frames must be positive")

    if not ADDON_SOURCE.is_dir():
        parser.error(f"canonical addon directory is missing: {ADDON_SOURCE}")
    if args.prepare_only:
        print(f"Using installed addon: {ADDON_SOURCE}; no files staged")
        return 0

    godot = shutil.which(args.godot) if not Path(args.godot).is_file() else args.godot
    if not godot:
        parser.error(f"Godot executable not found: {args.godot}")

    # Unit/render suites get a small disposable project so imports do not scan
    # the main demo's full island texture collection or mutate source metadata.
    test_context = tempfile.TemporaryDirectory(prefix="hego-terrain-tests-") if args.test or args.test_renderer else None
    project = stage_test_project(Path(test_context.name)) if test_context else PROJECT
    if test_context:
        imported = subprocess.run(
            [godot, "--headless", "--editor", "--import", "--path", str(project), "--quit"],
            cwd=ROOT,
            check=False,
        )
        if imported.returncode:
            return imported.returncode

    if args.test:
        for test_script in ("native_data_test.gd", "terrain_mesher_test.gd", "render_material_test.gd", "frontend_smoke_test.gd"):
            result = subprocess.run(
                [godot, "--headless", "--path", str(project), "--script", f"res://tests/{test_script}"],
                cwd=ROOT,
                check=False,
            )
            if result.returncode:
                return result.returncode
        return 0
    if args.test_renderer:
        if args.capture is not None:
            args.capture.resolve().parent.mkdir(parents=True, exist_ok=True)
        binding_result = subprocess.run(
            [godot, "--path", str(project), "--rendering-method", "forward_plus", "--script", "res://tests/render_shader_probe.gd"],
            cwd=ROOT,
            check=False,
        )
        if binding_result.returncode:
            return binding_result.returncode
        command = [godot, "--path", str(project), "--rendering-method", "forward_plus", "--script", "res://tests/render_material_test.gd", "--", "--render-lab"]
        if args.capture is not None:
            command.append("--capture=" + str(args.capture.resolve()))
        material_result = subprocess.run(command, cwd=ROOT, check=False)
        if material_result.returncode:
            return material_result.returncode
        state_command = [godot, "--path", str(project), "--rendering-method", "forward_plus", "--script", "res://tests/render_state_test.gd"]
        return subprocess.run(state_command, cwd=ROOT, check=False).returncode
    elif args.render_lab:
        if args.report is not None:
            args.report.resolve().parent.mkdir(parents=True, exist_ok=True)
        if args.capture is not None:
            args.capture.resolve().parent.mkdir(parents=True, exist_ok=True)
        resolution = "1920x1080" if args.benchmark else "1280x800"
        command = [godot, "--path", str(project), "--resolution", resolution, "--rendering-method", "forward_plus", RENDER_LAB_SCENE]
        user_args: list[str] = []
        if args.benchmark:
            user_args += ["--benchmark", "--frames", str(args.frames), "--report", str(args.report.resolve())]
        if args.no_displacement:
            user_args.append("--no-displacement")
        if args.capture is not None:
            user_args += ["--capture", str(args.capture.resolve())]
        if args.quit_after_frames is not None:
            user_args += ["--quit-after-frames", str(args.quit_after_frames)]
        if user_args:
            command += ["--"] + user_args
    elif args.editor:
        command = [godot, "--editor", "--path", str(project), PROTOTYPE_SCENE]
    else:
        command = [godot, "--path", str(project), PROTOTYPE_SCENE]
    return subprocess.run(command, cwd=ROOT, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
