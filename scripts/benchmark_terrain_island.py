#!/usr/bin/env python3
"""Run repeatable Forward+ island phase benchmarks and save JSON/captures."""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "demo"
SCENE = PROJECT / "island" / "island_showcase.tscn"


def run(command: list[str], timeout: int) -> int:
    try:
        return subprocess.run(command, cwd=ROOT, check=False, timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        print(f"Timed out after {timeout}s: {' '.join(command)}", file=sys.stderr)
        return 124


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN") or shutil.which("godot") or "godot")
    parser.add_argument("--frames", type=int, default=300, help="measured frames per phase and displacement mode (minimum 300)")
    parser.add_argument("--warmup", type=int, default=60, help="warmup frames before every phase (minimum 60)")
    parser.add_argument("--report", type=Path, required=True, help="output JSON report path")
    parser.add_argument("--capture-dir", type=Path, help="optional directory for overview and ground-walk PNG captures")
    parser.add_argument("--texture-stress", action="store_true", help="after normal measurements, allocate 32 slots of distinct duplicated texture resources and report memory delta")
    parser.add_argument("--timeout", type=int, default=1200, help="maximum seconds for each Godot invocation")
    args = parser.parse_args()
    if args.frames < 300 or args.warmup < 60:
        parser.error("--frames must be >=300 and --warmup must be >=60")
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    godot = shutil.which(args.godot) if not Path(args.godot).is_file() else str(args.godot)
    if not godot:
        parser.error(f"Godot executable not found: {args.godot}")

    if not SCENE.is_file():
        parser.error(f"cached island showcase is not ready: {SCENE}")

    report = args.report.expanduser().resolve()
    report.parent.mkdir(parents=True, exist_ok=True)
    captures: Path | None = None
    if args.capture_dir is not None:
        captures = args.capture_dir.expanduser().resolve()
        captures.mkdir(parents=True, exist_ok=True)
    imported = [godot, "--headless", "--editor", "--import", "--path", str(PROJECT), "--quit"]
    code = run(imported, args.timeout)
    if code:
        return code
    # Godot 4.4 can emit a transient Busy when HEGo's editor dialog preload
    # enters the resource queue on first import; reopen after the scan settles.
    code = run(imported, args.timeout)
    if code:
        return code

    command = [
        godot,
        "--path", str(PROJECT),
        "--rendering-method", "forward_plus",
        "--resolution", "1920x1080",
        "--script", "res://island/island_benchmark.gd",
        "--",
        "--frames", str(args.frames),
        "--warmup", str(args.warmup),
        "--report", str(report),
    ]
    if captures is not None:
        command += ["--capture-dir", str(captures)]
    if args.texture_stress:
        command.append("--texture-stress")
    return run(command, args.timeout)


if __name__ == "__main__":
    raise SystemExit(main())
