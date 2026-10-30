#!/usr/bin/env python3
"""Fetch the official Houdini 22.0.429 HAPI headers for compiling HEGo."""

import argparse
import hashlib
import re
import shutil
import ssl
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path


ARCHIVE_URL = (
    "https://github.com/sideeffects/HoudiniEngineForUnreal/releases/download/"
    "v4.0.1/HoudiniEngine-v4.0.1-H22.0.429-UE5.6-MacOs-arm64.zip"
)
ARCHIVE_SHA256 = "ca960320dfb5cf742dab3b6a46793c093bffe57b7c78f222e56e1e3294a8bed4"
HEADERS = ("HAPI.h", "HAPI_API.h", "HAPI_Common.h", "HAPI_Helpers.h", "HAPI_Version.h")
ARCHIVE_PREFIX = "HoudiniEngine/Source/HoudiniEngine/Public/HAPI/"
DEFAULT_OUTPUT = Path(__file__).resolve().parent.parent / "build/deps/houdini"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_headers(archive):
    if sha256(archive) != ARCHIVE_SHA256:
        raise ValueError("Archive SHA-256 mismatch; no headers were installed.")
    # Read exact members only: never extract archive paths or executable binaries.
    with zipfile.ZipFile(archive) as source:
        files = {
            Path("toolkit/include/HAPI") / name: source.read(ARCHIVE_PREFIX + name)
            for name in HEADERS
        }
        files[Path("LICENSE.SideFX.md")] = source.read("HoudiniEngine/LICENSE.md")
    version = files[Path("toolkit/include/HAPI/HAPI_Version.h")].decode("utf-8")
    expected = {
        "HOUDINI_MAJOR": 22,
        "HOUDINI_MINOR": 0,
        "HOUDINI_BUILD": 429,
        "HOUDINI_PATCH": 0,
        "HOUDINI_ENGINE_MAJOR": 9,
        "HOUDINI_ENGINE_MINOR": 0,
        "HOUDINI_ENGINE_API": 0,
    }
    for name, value in expected.items():
        if not re.search(rf"^#define\s+HAPI_VERSION_{name}\s+{value}\s*$", version, re.M):
            raise ValueError(f"Unexpected HAPI version: {name}; no headers were installed.")
    return files


def install_headers(files, output, force):
    for relative, content in files.items():
        destination = output / relative
        if destination.exists() and destination.read_bytes() != content and not force:
            raise ValueError(f"Refusing to overwrite different file: {destination}; use --force.")
    files[Path("SHA256SUMS")] = "".join(
        f"{hashlib.sha256(content).hexdigest()}  {relative.as_posix()}\n"
        for relative, content in files.items()
    ).encode("utf-8")
    files[Path("PROVENANCE.md")] = f"""# Official HAPI headers for HEGo

- Source: {ARCHIVE_URL}
- Release: https://github.com/sideeffects/HoudiniEngineForUnreal/releases/tag/v4.0.1
- Archive SHA-256: `{ARCHIVE_SHA256}`
- Archive header directory: `{ARCHIVE_PREFIX}`
- Verified version: Houdini 22.0.429, HAPI 9.0, API 0.
- License: `LICENSE.SideFX.md`; original notices remain in every header.

The release archive contains the exact 22.0.429 headers; the Git tag's source
headers declare the older build 22.0.423. Only five SDK headers and the license
were extracted. No executable, runtime library, or Houdini license is included.
These headers work for compilation on macOS and Linux; running Houdini Engine
requires an installed compatible Houdini runtime and an appropriate license.

Use this directory as HFS: `{output}`.
""".encode("utf-8")
    for relative, content in files.items():
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="HFS directory (default: %(default)s)")
    parser.add_argument("--archive", type=Path, help="Use an already downloaded release ZIP; still verify SHA-256")
    parser.add_argument("--force", action="store_true", help="Replace existing headers if their content differs")
    args = parser.parse_args()
    try:
        if args.archive:
            files = read_headers(args.archive)
        else:
            print("Downloading official SideFX release archive (approximately 50 MB)...", flush=True)
            context = ssl.create_default_context()
            # Some python.org macOS installs have no bundled CA store configured.
            if sys.platform == "darwin" and not context.get_ca_certs() and Path("/etc/ssl/cert.pem").is_file():
                context.load_verify_locations(cafile="/etc/ssl/cert.pem")
            with tempfile.TemporaryDirectory(prefix="hego-hapi-") as directory:
                archive = Path(directory) / "houdini-engine.zip"
                with urllib.request.urlopen(ARCHIVE_URL, timeout=60, context=context) as response, archive.open("wb") as target:
                    shutil.copyfileobj(response, target)
                files = read_headers(archive)
        output = args.output.expanduser().resolve()
        install_headers(files, output, args.force)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, urllib.error.URLError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    print(f"Verified Houdini 22.0.429 / HAPI 9.0 headers installed.\nHFS={output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
