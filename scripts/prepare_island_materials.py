#!/usr/bin/env python3
"""Fetch and pack real ambientCG PBR maps for the HEGo island showcase catalog.

Downloads are cached outside the repository. The committed runtime payload is
Color.jpg, NormalGL.jpg, and one lossless RGBA ORMH PNG per source material.
Requires Pillow (`python3 -m pip install Pillow`).
Existing material resources retain artist tuning unless --reset-resources is
explicitly supplied. This catalog belongs to the island demo, not the addon.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date
from email.utils import parsedate_to_datetime
from hashlib import sha256
from io import BytesIO
import json
from pathlib import Path
import shutil
import sys
import time
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "demo" / "island" / "assets" / "ambientcg_sources.json"
DEFAULT_OUTPUT = ROOT / "demo" / "island" / "materials"
DEFAULT_CACHE = Path.home() / ".cache" / "strata" / "ambientcg"
API = "https://ambientcg.com/api/v3/assets"
USER_AGENT = "StrataIslandMaterialPrep/1.0 (prototype asset pack; ambientCG API v3)"
MAP_SUFFIXES = {
    "color": "Color",
    "normal_gl": "NormalGL",
    "roughness": "Roughness",
    "ambient_occlusion": "AmbientOcclusion",
    "displacement": "Displacement",
}
# Defaults are used only when creating a missing demo resource or explicitly
# resetting one. Existing resources, including their UIDs, remain byte-exact.
HEIGHT_BLEND_CONTRAST = {
    "coastal_sand": 1.2,
    "island_grass": 2.0,
    "mossy_cliff": 12.0,
    "dark_cliff": 14.0,
    "scree_gravel": 8.0,
    "alpine_snow": 2.5,
}
HEIGHT_BLEND_BIAS = {
    "coastal_sand": 0.10,
    "island_grass": 0.18,
    "mossy_cliff": 0.11,
    "dark_cliff": 0.0,
    "scree_gravel": 0.14,
    "alpine_snow": -0.20,
}
ROUGHNESS_REMAP = {
    "coastal_sand": (1.0, 0.18),
    "island_grass": (0.75, 0.52),
    "mossy_cliff": (1.0, 0.22),
    "dark_cliff": (1.0, 0.06),
    "scree_gravel": (1.0, 0.18),
    "alpine_snow": (1.0, 0.24),
}


def request_bytes(url: str, timeout: int = 120) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def atomic_download(url: str, destination: Path, expected_size: int = 0, chunk_bytes: int = 0) -> None:
    if destination.exists() and destination.stat().st_size:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".part")
    offset = temporary.stat().st_size if temporary.is_file() else 0
    if expected_size and offset == expected_size:
        temporary.replace(destination)
        return
    if expected_size and offset > expected_size:
        temporary.unlink()
        offset = 0
    while True:
        headers = {"User-Agent": USER_AGENT}
        ranged = offset > 0 or (chunk_bytes > 0 and expected_size > 0)
        if ranged:
            last = str(min(offset + chunk_bytes, expected_size) - 1) if chunk_bytes and expected_size else ""
            headers["Range"] = f"bytes={offset}-{last}"
        request = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(request, timeout=180) as response:
            resumed = ranged and response.status == 206 and response.headers.get("Content-Range", "").startswith(f"bytes {offset}-")
            if response.status == 206 and not resumed:
                raise RuntimeError(f"Unexpected partial archive response for {destination.name}")
            before = offset if resumed else 0
            with temporary.open("ab" if resumed else "wb") as output:
                shutil.copyfileobj(response, output)
        offset = temporary.stat().st_size
        if not chunk_bytes or not expected_size or offset >= expected_size: break
        if offset <= before: raise RuntimeError(f"Archive download made no progress for {destination.name}")
    if expected_size and temporary.stat().st_size != expected_size:
        raise RuntimeError(f"Incomplete archive {destination.name}; partial download retained for the next run")
    temporary.replace(destination)


def api_assets(ids: list[str]) -> tuple[str, dict[str, dict]]:
    params = {"id": ",".join(ids), "include": "downloads,maps,title,url,tags,dimensions"}
    url = API + "?" + urllib.parse.urlencode(params)
    result = json.loads(request_bytes(url).decode("utf-8"))
    by_id = {str(asset.get("id")): asset for asset in result.get("assets", [])}
    missing = sorted(set(ids) - by_id.keys())
    if missing:
        raise RuntimeError("ambientCG API did not return requested assets: " + ", ".join(missing))
    return url, by_id


def find_member(archive: zipfile.ZipFile, asset_id: str, map_name: str) -> str:
    suffix = f"_{map_name}.jpg".lower()
    candidates = [
        member for member in archive.namelist()
        if Path(member).name.lower().startswith(asset_id.lower() + "_")
        and Path(member).name.lower().endswith(suffix)
    ]
    if len(candidates) != 1:
        raise RuntimeError(f"Expected one {map_name} JPG for {asset_id}, found {candidates}")
    return candidates[0]


def sha256_file(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_if_changed(path: Path, payload: bytes) -> None:
    """Avoid needless editor reimports; replace complete payloads atomically."""
    if path.is_file() and path.read_bytes() == payload:
        return
    temporary = path.with_suffix(path.suffix + ".prep-part")
    try:
        temporary.write_bytes(payload)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def write_texture_import_settings(texture_path: Path, kind: str) -> None:
    """Persist Godot 4.4's desktop VRAM-compressed, mipmapped import profile."""
    if kind not in {"color", "normal_gl", "ormh"}:
        raise ValueError(f"Unknown island texture kind: {kind}")
    sidecar = Path(str(texture_path) + ".import")
    if sidecar.is_file():
        lines = sidecar.read_text(encoding="utf-8").splitlines()
    else:
        try:
            res_path = "res://" + texture_path.resolve().relative_to(ROOT / "demo").as_posix()
        except ValueError:
            res_path = texture_path.resolve().as_posix()
        lines = [
            "[remap]",
            'importer="texture"',
            'type="CompressedTexture2D"',
            "",
            "[deps]",
            f'source_file="{res_path}"',
            "dest_files=[]",
            "",
            "[params]",
        ]

    parameters = {
        "compress/mode": "2",  # ResourceImporterTexture.COMPRESS_VRAM_COMPRESSED
        "compress/high_quality": "true" if kind in {"color", "ormh"} else "false",
        "compress/normal_map": "1" if kind == "normal_gl" else "0",
        # The profile already fixes VRAM compression and mipmaps explicitly.
        # Disable the one-shot 3D detector so tool viewports do not rewrite it.
        "detect_3d/compress_to": "0",
        "mipmaps/generate": "true",
        "process/normal_map_invert_y": "false",  # ambientCG NormalGL is already OpenGL Y+
    }
    try:
        params_start = lines.index("[params]")
    except ValueError:
        lines.extend(["", "[params]"])
        params_start = len(lines) - 1
    params_end = next((index for index in range(params_start + 1, len(lines)) if lines[index].startswith("[")), len(lines))
    existing: dict[str, int] = {}
    for index in range(params_start + 1, params_end):
        key, separator, _ = lines[index].partition("=")
        if separator:
            existing[key] = index
    for key, value in parameters.items():
        if key in existing:
            lines[existing[key]] = f"{key}={value}"
        else:
            lines.insert(params_end, f"{key}={value}")
            params_end += 1
    sidecar.parent.mkdir(parents=True, exist_ok=True)
    write_if_changed(sidecar, ("\n".join(lines) + "\n").encode("utf-8"))


def project_path(path: Path) -> str:
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return str(path.resolve())


def write_material_resource(output: Path, name: str, uv_scale: float = 0.1,
                            reset: bool = False, defaults: dict | None = None) -> bool:
    resources = output / "resources"
    resources.mkdir(parents=True, exist_ok=True)
    resource_path = resources / f"{name}.tres"
    if resource_path.exists() and not reset:
        return False
    defaults = defaults or {}
    roughness_scale, roughness_bias = ROUGHNESS_REMAP.get(name, (1.0, 0.0))
    resource_path.write_text(
        '[gd_resource type="Resource" script_class="StrataMaterial" load_steps=5 format=3]\n\n'
        '[ext_resource type="Script" path="res://addons/strata/strata_material.gd" id="1_material"]\n'
        f'[ext_resource type="Texture2D" path="res://island/materials/textures/{name}_color.jpg" id="2_color"]\n'
        f'[ext_resource type="Texture2D" path="res://island/materials/textures/{name}_normal_gl.jpg" id="3_normal"]\n'
        f'[ext_resource type="Texture2D" path="res://island/materials/textures/{name}_ormh.png" id="4_ormh"]\n\n'
        '[resource]\n'
        'script = ExtResource("1_material")\n'
        'color_texture = ExtResource("2_color")\n'
        'normal_texture = ExtResource("3_normal")\n'
        'ormh_texture = ExtResource("4_ormh")\n'
        f'uv_scale = {defaults.get("uv_scale", uv_scale):.6f}\n'
        f'displacement_strength = {defaults.get("displacement_strength", 1.0):.4f}\n'
        f'height_blend_contrast = {defaults.get("height_blend_contrast", HEIGHT_BLEND_CONTRAST.get(name, 0.0)):.4f}\n'
        f'height_blend_bias = {defaults.get("height_blend_bias", HEIGHT_BLEND_BIAS.get(name, 0.0)):.4f}\n'
        f'roughness_scale = {defaults.get("roughness_scale", roughness_scale):.4f}\n'
        f'roughness_bias = {defaults.get("roughness_bias", roughness_bias):.4f}\n',
        encoding="utf-8",
    )
    return True


def validate_sources(assets: list[dict]) -> None:
    for field in ("id", "name"):
        values = [asset[field] for asset in assets]
        if len(values) != len(set(values)):
            raise RuntimeError(f"Duplicate {field} in the demo material catalog")
    if [asset.get("material_id") for asset in assets] != list(range(len(assets))):
        raise RuntimeError("Demo material IDs must be consecutive and match catalog order")


def write_material_resources_only(output: Path, reset: bool = False) -> None:
    """Create missing parameter resources without touching textures/imports."""
    assets = json.loads(SOURCES.read_text(encoding="utf-8"))["assets"]
    validate_sources(assets)
    for asset in assets:
        for suffix in ("color.jpg", "normal_gl.jpg", "ormh.png"):
            texture = output / "textures" / f"{asset['name']}_{suffix}"
            if not texture.is_file():
                raise RuntimeError(f"Existing texture is required for --resources-only: {texture}")
    changed = sum(write_material_resource(output, asset["name"], reset=reset,
                                          defaults=asset.get("material_defaults")) for asset in assets)
    print(f"Wrote {changed} parameter resources; preserved {len(assets) - changed}; textures and imports untouched")


def run(output: Path, cache: Path, refresh: bool = False, reset_resources: bool = False, workers: int = 4, chunk_bytes: int = 0) -> None:
    try:
        from PIL import Image
    except ImportError as error:
        raise RuntimeError("Pillow is required: python3 -m pip install Pillow") from error

    source_manifest = json.loads(SOURCES.read_text(encoding="utf-8"))
    assets = source_manifest["assets"]
    validate_sources(assets)
    api_url, metadata = api_assets([asset["id"] for asset in assets])
    texture_dir = output / "textures"
    texture_dir.mkdir(parents=True, exist_ok=True)
    output_assets = []

    def download_asset(asset: dict) -> None:
        asset_id = asset["id"]
        record = metadata[asset_id]
        download = next((item for item in record.get("downloads", []) if item.get("attributes") == source_manifest["resolution_format"] and item.get("extension") == "zip"), None)
        if download is None or download.get("url") != asset["download_url"]:
            raise RuntimeError(f"The source archive metadata changed for {asset_id}; review the source manifest before proceeding")
        archive_path = cache / f"{asset_id}_{source_manifest['resolution_format']}.zip"
        if refresh:
            archive_path.unlink(missing_ok=True)
            archive_path.with_suffix(archive_path.suffix + ".part").unlink(missing_ok=True)
        for attempt in range(4):
            try:
                atomic_download(download["url"], archive_path, int(download.get("size", 0)), chunk_bytes)
                if download.get("size") and archive_path.stat().st_size != int(download["size"]):
                    raise RuntimeError(f"Archive size mismatch for {asset_id}: expected {download['size']}, got {archive_path.stat().st_size}")
                break
            except (OSError, RuntimeError) as error:
                print(f"Download attempt {attempt + 1}/4 failed for {asset_id}: {error}", flush=True)
                if attempt == 3: raise
                delay = float(2 ** attempt)
                retry_after = getattr(error, "headers", {}).get("Retry-After")
                if retry_after:
                    try:
                        delay = max(delay, float(retry_after))
                    except ValueError:
                        delay = max(delay, parsedate_to_datetime(retry_after).timestamp() - time.time())
                    print(f"Provider Retry-After: waiting {delay:.1f}s for {asset_id}", flush=True)
                time.sleep(delay)
        print(f"Source ready: {asset_id}", flush=True)

    # Downloads alone run concurrently. Packing/manifest publication is ordered
    # and bounded, avoiding four simultaneous large decoded material payloads.
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [executor.submit(download_asset, asset) for asset in assets]
        try:
            for future in as_completed(futures): future.result()
        except Exception:
            for future in futures: future.cancel()
            raise

    for asset in assets:
        asset_id = asset["id"]
        record = metadata[asset_id]
        if "color" not in record.get("maps", []) or "normal" not in record.get("maps", []):
            raise RuntimeError(f"{asset_id} is missing its Color or Normal material map")
        download = next((item for item in record.get("downloads", []) if item.get("attributes") == source_manifest["resolution_format"] and item.get("extension") == "zip"), None)
        if download is None or download.get("url") != asset["download_url"]:
            raise RuntimeError(f"The source archive metadata changed for {asset_id}; review the source manifest before proceeding")
        archive_path = cache / f"{asset_id}_{source_manifest['resolution_format']}.zip"
        if download.get("size") and archive_path.stat().st_size != int(download["size"]):
            raise RuntimeError(f"Archive size mismatch for {asset_id}: expected {download['size']}, got {archive_path.stat().st_size}")

        with zipfile.ZipFile(archive_path) as archive:
            maps: dict[str, bytes] = {}
            for key, member_suffix in MAP_SUFFIXES.items():
                if key == "displacement" and "displacement" not in record.get("maps", []):
                    continue
                member = find_member(archive, asset_id, member_suffix)
                maps[key] = archive.read(member)
        required = {"color", "normal_gl", "roughness", "ambient_occlusion"}
        missing = required - maps.keys()
        if missing:
            raise RuntimeError(f"{asset_id} archive is missing expected maps: {sorted(missing)}")
        dimensions = {key: Image.open(BytesIO(data)).size for key, data in maps.items()}
        expected_side = int(source_manifest["resolution_format"].split("K")[0]) * 1024
        if len(set(dimensions.values())) != 1 or max(next(iter(dimensions.values()))) != expected_side:
            raise RuntimeError(f"Expected matching real {source_manifest['resolution_format']} source maps for {asset_id}, got {dimensions}")

        color_path = texture_dir / f"{asset['name']}_color.jpg"
        normal_path = texture_dir / f"{asset['name']}_normal_gl.jpg"
        ormh_path = texture_dir / f"{asset['name']}_ormh.png"
        ao = Image.open(BytesIO(maps["ambient_occlusion"])).convert("L")
        rough = Image.open(BytesIO(maps["roughness"])).convert("L")
        if ao.size != rough.size:
            raise RuntimeError(f"AO/Roughness dimensions disagree for {asset_id}")
        displacement_bytes = maps.get("displacement")
        height = Image.open(BytesIO(displacement_bytes)).convert("L") if displacement_bytes else Image.new("L", ao.size, 128)
        if height.size != ao.size:
            raise RuntimeError(f"Displacement dimensions disagree for {asset_id}")
        write_if_changed(color_path, maps["color"])
        write_if_changed(normal_path, maps["normal_gl"])
        write_texture_import_settings(color_path, "color")
        write_texture_import_settings(normal_path, "normal_gl")
        metallic = Image.new("L", ao.size, 0)
        packed = BytesIO()
        Image.merge("RGBA", (ao, rough, metallic, height)).save(packed, format="PNG", optimize=True)
        write_if_changed(ormh_path, packed.getvalue())
        write_texture_import_settings(ormh_path, "ormh")
        if color_path.stat().st_size == 0 or normal_path.stat().st_size == 0 or ormh_path.stat().st_size == 0:
            raise RuntimeError(f"Generated a zero-length texture for {asset_id}")

        write_material_resource(output, asset["name"], reset=reset_resources, defaults=asset.get("material_defaults"))
        output_assets.append({
            **asset,
            "title": record.get("title", asset_id),
            "provider_tags": record.get("tags", []),
            "provider_dimensions": record.get("dimensions", {}),
            "asset_url": f"https://ambientcg.com/a/{asset_id}",
            "source_download_url": download["url"],
            "source_archive_bytes": archive_path.stat().st_size,
            "source_archive_sha256": sha256_file(archive_path),
            "source_maps": {key: f"{asset_id}_{source_manifest['resolution_format']}_{suffix}.jpg" for key, suffix in MAP_SUFFIXES.items() if key in maps},
            "map_dimensions": list(ao.size),
            "maps": {
                "color": project_path(color_path),
                "normal_gl": project_path(normal_path),
                "ormh": project_path(ormh_path),
            },
            "material_resource": f"res://island/materials/resources/{asset['name']}.tres",
            "outputs": {path.name: {"bytes": path.stat().st_size, "sha256": sha256_file(path)} for path in (color_path, normal_path, ormh_path)},
        })

    manifest = {
        "schema_version": 1,
        "scope": f"HEGo island showcase catalog; {len(output_assets)} real distinct ambientCG source sets, stable IDs, no UV aliases. Not a temporary or artificial test fixture.",
        "generated_on": date.today().isoformat(),
        "license": source_manifest["license"],
        "api_request": api_url,
        "resolution_format": source_manifest["resolution_format"],
        "packing": "ORMH RGBA PNG channels are Ambient Occlusion, Roughness, constant Metallic=0, and source Displacement; the shader centers height at 0.5.",
        "normal_convention": "NormalGL source map (OpenGL green-up); preserved as supplied.",
        "godot_texture_import": "Godot 4.4 VRAM Compressed mode with mipmaps; high-quality BC7 for Color and ORMH; RGTC normal-map compression for NormalGL; no Y inversion.",
        "assets": output_assets,
    }
    assets_dir = ROOT / "demo" / "island" / "assets"
    (assets_dir / "material_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    runtime = []
    for asset in output_assets:
        runtime.append({
            "id": asset["material_id"],
            "material_id": asset["material_id"],
            "name": asset["name"],
            "channel": "material_" + asset["name"],
            "ambientcg_id": asset["id"],
            "resource": asset["material_resource"],
            "role": asset["role"],
            "description": asset["use"],
            "tiling": asset.get("tiling", {}),
            "source_url": asset["asset_url"],
            "license": source_manifest["license"]["name"],
        })
    (output / "material_manifest.json").write_text(json.dumps(runtime, indent=2) + "\n", encoding="utf-8")
    (output / "material_registry.json").write_text(json.dumps(runtime, indent=2) + "\n", encoding="utf-8")
    write_contact_sheet(output, assets_dir / "material_contact_sheet.jpg", output_assets)
    print(f"Prepared {len(output_assets)} ambientCG materials under {output}")
    print(f"Manifest: {assets_dir / 'material_manifest.json'}")
    for asset in output_assets:
        print(f"  {asset['name']}: {asset['id']} ({asset['map_dimensions'][0]}x{asset['map_dimensions'][1]}) {asset['source_archive_bytes']:,} byte source ZIP")


def write_contact_sheet(output: Path, destination: Path, assets: list[dict]) -> None:
    """The persistent showcase catalog, showing real source Color maps."""
    from PIL import Image, ImageDraw, ImageFont
    width, cell, header = 8, 240, 40
    sheet = Image.new("RGB", (width * cell, ((len(assets) + width - 1) // width) * (cell + 44) + header), (25, 28, 30))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("DejaVuSans.ttf", 14)
    except OSError:
        font = ImageFont.load_default()
    draw.text((12, 10), f"HEGo island showcase catalog | {len(assets)} real distinct ambientCG CC0 source sets | source Color maps", fill="white", font=font)
    for index, asset in enumerate(assets):
        color = Image.open(output / "textures" / f"{asset['name']}_color.jpg").convert("RGB")
        color.thumbnail((cell - 4, cell - 4))
        x, y = (index % width) * cell, (index // width) * (cell + 44) + header
        sheet.paste(color, (x, y))
        draw.text((x + 4, y + cell), f"{asset['material_id']:02d} {asset['name']}", fill="white", font=font)
        draw.text((x + 4, y + cell + 19), asset["id"], fill=(175, 205, 220), font=font)
    encoded = BytesIO()
    sheet.save(encoded, format="JPEG", quality=90)
    write_if_changed(destination, encoded.getvalue())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT, help="runtime textures and StrataMaterial resources")
    parser.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE, help="external source ZIP cache (default ~/.cache/hego-terrain/ambientcg)")
    parser.add_argument("--refresh", action="store_true", help="redownload cached source archives")
    parser.add_argument("--resources-only", action="store_true", help="offline: create missing demo material resources, preserving textures/import settings")
    parser.add_argument("--reset-resources", action="store_true", help="explicitly replace existing .tres tuning and UIDs with catalog defaults")
    parser.add_argument("--workers", type=int, choices=range(1, 9), default=4, help="simultaneous source downloads (1..8, packing stays sequential)")
    parser.add_argument("--download-chunk-mib", type=int, choices=range(0, 17), default=0, help="optional resumable range request size for slow connections (0: whole response)")
    args = parser.parse_args()
    output = args.output_dir.resolve()
    cache = args.cache_dir.expanduser().resolve()
    if args.resources_only and args.refresh:
        parser.error("--resources-only cannot be combined with --refresh")
    if not SOURCES.is_file():
        print(f"error: source manifest not found: {SOURCES}", file=sys.stderr)
        return 2
    try:
        if args.resources_only:
            write_material_resources_only(output, args.reset_resources)
        else:
            run(output, cache, args.refresh, args.reset_resources, args.workers, args.download_chunk_mib * 1024 * 1024)
    except (OSError, RuntimeError, ValueError, zipfile.BadZipFile, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
