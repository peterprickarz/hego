#!/usr/bin/env python3
"""Install a small Houdini package bootstrap; Houdini loads the island HDAs at startup.

The repository package uses relative paths. Only the user-level bootstrap points
to this checkout, and can be updated explicitly after moving the repository.
"""
import argparse
import json
import os
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP_NAME = "hego_terrain_demo_path.json"


def install(user_pref: Path, package_directory: Path, replace: bool = False, dry_run: bool = False) -> Path:
    package_directory = package_directory.expanduser().resolve()
    if not (package_directory / "hego_terrain_demo.json").is_file():
        raise ValueError("The island package JSON is missing from the selected checkout")
    destination = user_pref.expanduser().resolve() / "packages" / BOOTSTRAP_NAME
    # Forward slashes are accepted by Houdini on all supported platforms.
    content = json.dumps({"load_package_once": True, "package_path": package_directory.as_posix()}, indent=2) + "\n"
    if destination.exists():
        if destination.read_text() == content:
            print(f"Houdini package bootstrap already matches: {destination}")
            return destination
        if not replace:
            raise ValueError(f"Refusing to replace {destination}; use --replace after reviewing the existing bootstrap")
    if dry_run:
        print(f"Would write {destination}:\n{content}")
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        backup = destination.with_suffix(destination.suffix + ".backup")
        if backup.exists():
            raise ValueError(f"Refusing to overwrite existing backup {backup}; preserve it before replacing the bootstrap")
        shutil.copy2(destination, backup)
    pending = destination.with_suffix(destination.suffix + ".next")
    pending.write_text(content)
    pending.replace(destination)
    print(f"Installed {destination}\nHoudini will discover the island HDAs when its next session starts.")
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user-pref-dir", type=Path, default=os.environ.get("HOUDINI_USER_PREF_DIR"), help="Houdini preferences folder, e.g. ~/houdini22.0; defaults to HOUDINI_USER_PREF_DIR if set")
    parser.add_argument("--package-directory", type=Path, default=ROOT / "demo/island/packages")
    parser.add_argument("--replace", action="store_true", help="replace only this bootstrap after making a .backup copy")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.user_pref_dir is None:
        parser.error("Pass --user-pref-dir for your Houdini installation, or set HOUDINI_USER_PREF_DIR")
    try:
        install(args.user_pref_dir, args.package_directory, args.replace, args.dry_run)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
