#!/usr/bin/env python3
"""Record and validate hashes for native artifacts shipped by HEGo packages.

The fingerprint covers only native compilation inputs and build configuration, so
GDScript, scenes, docs, and other content edits do not require rebuilding binaries.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
COMMON_INPUT_FILES = ("scripts/native_build_manifest.py",)
MANIFEST_NAME = "native-build.json"


ADDONS = ("hego", "strata", "copia")


def _run(*args: str, cwd: Path = ROOT, env: dict | None = None) -> bytes:
    return subprocess.check_output(args, cwd=cwd, env=env)


def _is_native_input(path: str, addon: str) -> bool:
    if path == "godot-cpp" or path in COMMON_INPUT_FILES:
        return True
    if addon == "hego":
        return path in ("SConstruct", "scripts/build.sh") or path.startswith("src/")
    if addon == "copia":
        return path in (
            "SConstruct.copia",
            "scripts/build-copia.sh",
            "scripts/linux-compat-copia.Containerfile",
        ) or path.startswith("copia/src/")
    return path in (
        "SConstruct.terrain",
        "scripts/build-terrain.sh",
        "scripts/linux-compat-terrain.Containerfile",
    ) or path.startswith("terrain/src/")


def fingerprint(addon: str, ref: str | None = None) -> str:
    digest = hashlib.sha256()
    if ref:
        rows = _run("git", "ls-tree", "-r", "-z", "--full-tree", ref).split(b"\0")
        entries: list[tuple[str, str, str]] = []
        for row in rows:
            if not row:
                continue
            meta, raw_path = row.split(b"\t", 1)
            mode, _kind, oid = meta.decode().split()
            path = raw_path.decode()
            if _is_native_input(path, addon):
                entries.append((path, mode, oid))
        has_submodule = any(path == "godot-cpp" for path, _mode, _oid in entries)
        # Some Git versions omit gitlinks from recursive -r output. Add it to the
        # same sorted entry stream so ref and worktree fingerprints are identical.
        if not has_submodule:
            top = _run("git", "ls-tree", "-z", ref).split(b"\0")
            for row in top:
                if not row:
                    continue
                meta, raw_path = row.split(b"\t", 1)
                mode, _kind, oid = meta.decode().split()
                if mode == "160000" and raw_path.decode() == "godot-cpp":
                    entries.append(("godot-cpp", mode, oid))
                    break
        for path, mode, oid in sorted(entries):
            digest.update(path.encode() + b"\0" + mode.encode() + b"\0")
            if path == "godot-cpp":
                digest.update(oid.encode() + b"\0")
            else:
                digest.update(_run("git", "cat-file", "blob", oid))
                digest.update(b"\0")
        return digest.hexdigest()

    return fingerprint(addon, worktree_tree(addon))


def worktree_tree(addon: str) -> str:
    """Stage the addon's native inputs as they are on disk into a private index and
    return the tree a commit of them would have.

    The fingerprint must equal the one validate() computes from the committed revision,
    so the files go through Git's own clean step (line endings, filters) and keep the
    modes Git would commit. Reading them straight from disk does not match on a Windows
    checkout with CRLF files and no executable bits. The real index and the working tree
    are untouched; only blob objects are written.
    """
    paths = _run("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0")
    inputs = sorted({raw.decode() for raw in paths if raw and _is_native_input(raw.decode(), addon)})
    if "godot-cpp" in inputs:
        submodule = ROOT / "godot-cpp"
        if not submodule.is_dir():
            raise ValueError("godot-cpp submodule is not initialized; initialize it before recording native builds")
        dirty = _run("git", "status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none", cwd=submodule)
        if dirty.strip():
            raise ValueError("godot-cpp submodule has modified or untracked files; clean it before recording native builds")
    with tempfile.TemporaryDirectory() as folder:
        index = Path(folder) / "index"
        real_index = Path(_run("git", "rev-parse", "--path-format=absolute", "--git-path", "index").decode().strip())
        if real_index.is_file():
            shutil.copyfile(real_index, index)
        env = dict(os.environ, GIT_INDEX_FILE=str(index))
        # --all also drops tracked inputs that were deleted from disk.
        if inputs:
            _run("git", "add", "--all", "--", *inputs, env=env)
        return _run("git", "write-tree", env=env).decode().strip()


def package_root(addon: str) -> str:
    roots = {"hego": "demo/addons/hego", "strata": "demo/addons/strata", "copia": "demo/addons/copia"}
    if addon not in roots:
        raise ValueError(f"unknown addon: {addon}")
    return roots[addon]


def record(addon: str, artifacts: list[str], contexts: list[str]) -> None:
    if len(contexts) == 1:
        contexts = contexts * len(artifacts)
    if len(contexts) != len(artifacts):
        raise ValueError("provide one --context for all artifacts, or one --context per --artifact")
    root = package_root(addon)
    folder = ROOT / root
    path = folder / MANIFEST_NAME
    current_fp = fingerprint(addon)
    if path.exists():
        previous = json.loads(path.read_text())
    else:
        previous = {}
    existing = previous.get("artifacts", {}) if previous.get("source_fingerprint") == current_fp else {}
    for artifact, context in zip(artifacts, contexts):
        artifact_path = PurePosixPath(artifact)
        if artifact_path.is_absolute() or ".." in artifact_path.parts:
            raise ValueError(f"artifact must be package-relative: {artifact}")
        full = folder.joinpath(*artifact_path.parts)
        if not full.is_file():
            raise ValueError(f"built artifact does not exist: {full}")
        existing[artifact_path.as_posix()] = {
            "sha256": hashlib.sha256(full.read_bytes()).hexdigest(),
            "build_context": context,
        }
    doc = {
        "format_version": 1,
        "source_fingerprint": current_fp,
        "artifacts": dict(sorted(existing.items())),
    }
    path.write_text(json.dumps(doc, indent=2) + "\n")
    print(f"Recorded {len(artifacts)} artifact(s) for {addon}: {path.relative_to(ROOT)}")


def read_at(ref: str, path: str) -> bytes:
    return _run("git", "show", f"{ref}:{path}")


def validate(addon: str, ref: str) -> list[str]:
    root = package_root(addon)
    errors: list[str] = []
    try:
        manifest = json.loads(read_at(ref, f"{root}/{MANIFEST_NAME}"))
    except (subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        return [f"{addon}: missing or invalid {MANIFEST_NAME}: {exc}"]
    if manifest.get("format_version") != 1:
        errors.append(f"{addon}: unsupported native build manifest version")
    expected_fp = fingerprint(addon, ref)
    if manifest.get("source_fingerprint") != expected_fp:
        errors.append(f"{addon}: native build fingerprint does not match source {ref}")
    try:
        extension = read_at(ref, f"{root}/bin/{addon}.gdextension").decode()
    except subprocess.CalledProcessError as exc:
        return errors + [f"{addon}: extension descriptor missing: {exc}"]
    referenced = re.findall(r'^\s*[\w.]+\s*=\s*"res://addons/[^/]+/bin/([^"]+)"', extension, re.M)
    if not referenced:
        errors.append(f"{addon}: extension descriptor contains no native library paths")
    artifacts = manifest.get("artifacts", {})
    for name in referenced:
        relative = f"bin/{name}"
        receipt = artifacts.get(relative)
        if not receipt:
            errors.append(f"{addon}: no build receipt for {relative}")
            continue
        expected_hash = receipt.get("sha256") if isinstance(receipt, dict) else receipt
        if not expected_hash:
            errors.append(f"{addon}: malformed build receipt for {relative}")
            continue
        try:
            data = read_at(ref, f"{root}/{relative}")
        except subprocess.CalledProcessError:
            errors.append(f"{addon}: referenced library is missing: {relative}")
            continue
        actual_hash = hashlib.sha256(data).hexdigest()
        if actual_hash != expected_hash:
            errors.append(f"{addon}: binary hash differs from receipt: {relative}")
    return errors


def main() -> int:
    global ROOT
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    commands = parser.add_subparsers(dest="command", required=True)
    record_parser = commands.add_parser("record")
    record_parser.add_argument("--addon", choices=ADDONS, required=True)
    record_parser.add_argument("--artifact", action="append", required=True, help="package-relative path; repeatable")
    record_parser.add_argument("--context", action="append", help="build config paired with --artifact; a single value applies to all artifacts")
    validate_parser = commands.add_parser("validate")
    validate_parser.add_argument("--addon", choices=ADDONS, required=True)
    validate_parser.add_argument("--ref", required=True)
    args = parser.parse_args()
    ROOT = args.repo_root.resolve()
    try:
        if args.command == "record":
            record(args.addon, args.artifact, args.context or ["unspecified"])
            return 0
        errors = validate(args.addon, args.ref)
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        print(f"Validated native receipts: {args.addon} ({args.ref})")
        return 0
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
