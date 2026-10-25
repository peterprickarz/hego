#!/usr/bin/env python3
"""Load HEGo and optionally cook a box in an isolated, Terrain3D-free project."""

import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile


SCRIPT = '''extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func wait_task(task: HEGoTask) -> bool:
	while task.get_status() < HEGoTask.COMPLETED:
		await process_frame
	if task.get_status() != HEGoTask.COMPLETED:
		push_error(task.get_error_message())
		return false
	return true

func run() -> void:
	var api := HEGoAPI.get_singleton()
	if api == null:
		push_error("HEGoAPI singleton is missing")
		quit(1)
		return
	if OS.get_cmdline_user_args().has("--load-only"):
		print("PASS: HEGo extension loaded")
		quit(0)
		return
	var pipe := "hego_smoke_%s_%s" % [OS.get_process_id(), Time.get_ticks_usec()]
	if not api.start_session(HEGoAPI.SESSION_NAMED_PIPE, pipe):
		push_error("Could not start Houdini Engine session")
		quit(1)
		return
	var asset := HEGoAssetNode.new()
	asset.op_name = "Sop/box"
	var ok := await wait_task(asset.instantiate())
	if ok:
		ok = await wait_task(asset.cook())
	if ok:
		var output_task := asset.get_surface_output()
		ok = await wait_task(output_task)
		if ok:
			var output: HEGoSurfaceOutput = output_task.get_result()
			ok = output != null and output.is_valid()
	api.stop_session()
	if ok:
		print("PASS: HEGo session, box cook, surface output and shutdown")
	else:
		push_error("HEGo box cook or surface output failed")
	quit(0 if ok else 1)
'''


def run(command, env, timeout):
    try:
        result = subprocess.run(
            command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        output = error.stdout or b""
        print(output.decode(errors="replace") if isinstance(output, bytes) else output, flush=True)
        raise RuntimeError(f"Godot timed out after {timeout}s; use the executable directly, not a terminal launcher") from error
    print(result.stdout, end="", flush=True)
    if result.returncode or "SCRIPT ERROR:" in result.stdout or "ERROR:" in result.stdout:
        raise RuntimeError(f"Godot smoke test failed (exit {result.returncode})")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot", help="Godot 4.4+ executable matching the CPU")
    parser.add_argument("--hfs", type=Path, help="Houdini runtime installation (otherwise uses HFS/default)")
    parser.add_argument("--load-only", action="store_true", help="Check extension loading without Houdini or a license")
    parser.add_argument("--timeout", type=int, default=120, help="Timeout per Godot process in seconds")
    args = parser.parse_args()
    godot = shutil.which(args.godot)
    if not godot:
        parser.error(f"Godot executable not found: {args.godot}")
    env = os.environ.copy()
    if args.hfs:
        env["HFS"] = str(args.hfs.resolve())
    print(f"Host: {platform.system()} {platform.machine()}; Godot: {godot}", flush=True)
    print(f"HFS: {env.get('HFS', '(platform default)')}", flush=True)
    root = Path(__file__).resolve().parents[1]
    # Copy only HEGo; the demo includes unrelated native addons with their own
    # architecture requirements. Never change the user's project or sessions.
    with tempfile.TemporaryDirectory(prefix="hego-smoke-") as directory:
        project = Path(directory)
        shutil.copytree(root / "demo/addons/hego", project / "addons/hego")
        (project / "project.godot").write_text(
            'config_version=5\n[application]\nconfig/name="HEGo smoke test"\n'
            '[rendering]\nrenderer/rendering_method="gl_compatibility"\n'
            '[editor_plugins]\nenabled=PackedStringArray("res://addons/hego/plugin.cfg")\n'
        )
        (project / "smoke.gd").write_text(SCRIPT)
        command = [godot, "--headless", "--path", str(project)]
        run(command + ["--editor", "--import"], env, args.timeout)
        output = run(
            command + ["--script", "res://smoke.gd", "--"]
            + (["--load-only"] if args.load_only else []), env, args.timeout,
        )
        if "PASS: HEGo" not in output:
            raise RuntimeError("Godot exited without completing the smoke test")


if __name__ == "__main__":
    main()
