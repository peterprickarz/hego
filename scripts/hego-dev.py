#!/usr/bin/env python3
"""Switch a Godot project's pinned HEGo submodule to/from a local source checkout."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def git(directory, *args):
    return subprocess.check_output(
        ["git", "-C", str(directory), *args], text=True, stderr=subprocess.PIPE
    ).strip()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["enable", "disable", "status"])
    parser.add_argument("project", type=Path, help="Godot project directory (contains project.godot)")
    parser.add_argument("--checkout", type=Path, help="HEGo source checkout; required for enable")
    args = parser.parse_args()
    project = args.project.resolve()
    require((project / "project.godot").is_file(), "Project must contain project.godot")
    root = Path(git(project, "rev-parse", "--show-toplevel"))
    addon = project / "addons" / "hego"  # Do not resolve the symlink.
    relative = addon.relative_to(root).as_posix()
    git_dir = Path(git(root, "rev-parse", "--absolute-git-dir"))
    key = hashlib.sha256(relative.encode()).hexdigest()[:16]
    storage = git_dir / "hego-dev" / key
    state_file = storage / "state.json"
    backup = storage / "pinned"
    entry = git(root, "ls-files", "--stage", "--", relative).split(maxsplit=3)
    require(len(entry) == 4 and entry[0] == "160000" and entry[2] == "0",
            f"{relative} must be an unconflicted, tracked submodule")
    pin = entry[1]

    if args.mode == "status":
        if state_file.exists():
            state = json.loads(state_file.read_text())
            print(f"Development mode: {addon} -> {state['target']}")
            print(f"Saved pin: {state['pin']}")
            require(addon.is_symlink() and os.readlink(addon) == state["target"],
                    "Development link was changed or removed; backup preserved")
            require(pin == state["pin"], "Submodule pin changed while development mode was enabled")
        else:
            require(not addon.is_symlink() and not backup.exists(), "Unmanaged link or backup exists")
            print(f"Pinned mode: {relative} (index pin {pin})")
        return

    storage.mkdir(parents=True, exist_ok=True)
    # Exclusive lock also guards against two invocations moving the directory.
    lock = storage / "lock"
    fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        if args.mode == "enable":
            require(args.checkout is not None, "--checkout is required for enable")
            checkout = args.checkout.resolve()
            target = checkout / "demo" / "addons" / "hego"
            require((target / "plugin.cfg").is_file(), "Checkout has no demo/addons/hego/plugin.cfg")
            require(Path(git(checkout, "rev-parse", "--show-toplevel")) == checkout,
                    "--checkout must be the HEGo source repository root")
            require(not target.is_relative_to(addon.resolve()), "Checkout cannot be inside the addon")
            require(not state_file.exists() and not backup.exists(), "Development backup already exists")
            require(addon.is_dir() and not addon.is_symlink() and (addon / ".git").is_file(),
                    "Initialize the submodule first; expected a directory with a .git file")
            require(git(addon, "rev-parse", "HEAD") == pin,
                    "Submodule HEAD differs from the project's index pin; commit or restore it first")
            require(not git(addon, "status", "--porcelain", "--untracked-files=all"),
                    "Submodule has local changes or untracked files; preserve them before switching")
            state = {"target": str(target), "pin": pin}
            state_file.write_text(json.dumps(state, indent=2) + "\n")
            try:
                addon.rename(backup)
                try:
                    addon.symlink_to(target, target_is_directory=True)
                except BaseException:
                    backup.rename(addon)
                    raise
            except BaseException:
                state_file.unlink()
                raise
            print(f"Development enabled: {addon} -> {target}")
            print("Edit and commit HEGo in the source checkout. Do not stage the addon symlink.")
        else:
            require(state_file.exists() and backup.is_dir(), "No saved development checkout found")
            state = json.loads(state_file.read_text())
            require(pin == state["pin"], "Submodule index pin changed; restore it before disabling")
            require(addon.is_symlink() and os.readlink(addon) == state["target"],
                    "Addon link was changed; refusing to overwrite it")
            addon.unlink()
            try:
                backup.rename(addon)
            except BaseException:
                addon.symlink_to(state["target"], target_is_directory=True)
                raise
            state_file.unlink()
            print(f"Pinned submodule restored: {addon} ({pin})")
    finally:
        os.close(fd)
        lock.unlink()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
