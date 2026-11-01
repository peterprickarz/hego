#!/usr/bin/env python3
"""Scaffold checks: python3 scripts/tests/test_build_terrain.py."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "scripts/build-terrain.sh"

def run(*args: str, ok: bool = True) -> str:
    result = subprocess.run([str(BUILDER), *args], cwd=ROOT, text=True, capture_output=True)
    if ok and result.returncode:
        raise AssertionError(f"{args}: exit={result.returncode}\n{result.stdout}\n{result.stderr}")
    if not ok and result.returncode == 0:
        raise AssertionError(f"{args}: expected rejection, got:\n{result.stdout}")
    return result.stdout + result.stderr

# The former positional target form remains a host build.
legacy = run("--dry-run", "template_debug")
assert "platform=linux target=template_debug" in legacy
assert "terrain_build_profile=host" in legacy
assert "podman" not in legacy
default_plan = run("--dry-run")
assert default_plan.count("would verify and record linux /") == 2
assert "template_debug" in default_plan and "template_release" in default_plan

all_targets = run("--dry-run", "all", "template_release")
assert "linux-compat / template_release" in all_targets
assert "windows / template_release" in all_targets
assert "terrain_build_profile=linux-compat" in all_targets
assert "use_mingw=yes" in all_targets
assert "HFS" not in all_targets and "houdini" not in all_targets.lower()

windows_debug = run("--dry-run", "windows", "template_debug")
assert "platform=windows target=template_debug" in windows_debug
assert "strata.windows.template_debug.x86_64.dll" not in windows_debug  # dry-run never claims a DLL exists

compat_release = run("--dry-run", "linux-compat", "template_release")
assert "glibc" not in compat_release  # no build artifact is claimed by a plan
assert "terrain_build_profile=linux-compat" in compat_release
assert "unsupported target" in run("--dry-run", "bogus", ok=False)

extension = (ROOT / "demo/addons/strata/bin/strata.gdextension").read_text()
for path in (
    "libstrata.linux.template_debug.x86_64.so",
    "libstrata.linux.template_release.x86_64.so",
    "strata.windows.template_debug.x86_64.dll",
    "strata.windows.template_release.x86_64.dll",
):
    assert path in extension, f"missing descriptor entry for {path}"

container = (ROOT / "scripts/linux-compat-terrain.Containerfile").read_text().lower()
assert "almalinux:8" in container and "gcc-toolset-13" in container
assert "libhapil" not in container and "hfs=" not in container

sconstruct = (ROOT / "SConstruct.terrain").read_text()
assert "exclude-libs,all" in sconstruct.lower()
assert "terrain/build/{env['platform']}.{env['target']}.{env['arch']}" in sconstruct
assert 'terrain/build/dependencies/godot-cpp/{_terrain_profile}' in sconstruct
assert 'git", "-C", "godot-cpp", "ls-files", "-z' in sconstruct
assert "SConstruct.terrain" in (ROOT / "scripts/native_build_manifest.py").read_text()
print("PASS terrain build scaffold: legacy host form, Windows/compat plans, descriptor, and no-Houdini container")
