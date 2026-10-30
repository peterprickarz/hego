"""Deterministic rough island base for the Strata island showcase.

The base is an editable, uneroded manual layer. It is analytic (numpy only) so
it can be regenerated without a Houdini licence; erosion is applied later by
the Sop/hego_island_erosion HDA. Coordinates are metres in the terrain parent
frame: X east, Z south, Y up, sea level at Y=0, extent 4096 m centred at 0.
"""

import json
import math

import numpy as np

BASE_VERSION = 1
EXTENT = 4096.0
SPACING = 8.0
RESOLUTION = int(EXTENT / SPACING) + 1  # 513 sample centres, corners included


def _perlin_tables(seed):
    rng = np.random.default_rng(seed)
    perm = rng.permutation(256)
    angles = rng.uniform(0.0, 2.0 * math.pi, 256)
    return np.concatenate([perm, perm]), np.stack([np.cos(angles), np.sin(angles)], -1)


def _perlin(x, z, tables):
    perm, grads = tables
    xi = np.floor(x).astype(np.int64)
    zi = np.floor(z).astype(np.int64)
    xf = x - xi
    zf = z - zi
    xi &= 255
    zi &= 255

    def corner(dx, dz):
        g = grads[perm[perm[(xi + dx) & 255] + ((zi + dz) & 255)]]
        return g[..., 0] * (xf - dx) + g[..., 1] * (zf - dz)

    u = xf * xf * xf * (xf * (xf * 6 - 15) + 10)
    v = zf * zf * zf * (zf * (zf * 6 - 15) + 10)
    a = corner(0, 0) + u * (corner(1, 0) - corner(0, 0))
    b = corner(0, 1) + u * (corner(1, 1) - corner(0, 1))
    return (a + v * (b - a)) * 1.414


def fbm(x, z, tables, scale, octaves, lacunarity=2.03, gain=0.5):
    total = np.zeros_like(x)
    amp = 1.0
    freq = 1.0 / scale
    norm = 0.0
    for octave in range(octaves):
        # Per-octave offsets avoid lattice-aligned artefacts.
        total += amp * _perlin(x * freq + 17.3 * octave, z * freq - 31.7 * octave, tables)
        norm += amp
        amp *= gain
        freq *= lacunarity
    return total / norm


def ridged(x, z, tables, scale, octaves, lacunarity=2.1, gain=0.55):
    total = np.zeros_like(x)
    weight = np.ones_like(x)
    amp = 1.0
    freq = 1.0 / scale
    norm = 0.0
    for octave in range(octaves):
        n = 1.0 - np.abs(_perlin(x * freq + 41.1 * octave, z * freq + 7.9 * octave, tables))
        n = n * n * weight
        weight = np.clip(n * 1.6, 0.0, 1.0)
        total += amp * n
        norm += amp
        amp *= gain
        freq *= lacunarity
    return total / norm


def _smoothstep(e0, e1, v):
    t = np.clip((v - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def _smax(a, b, k):
    h = np.clip(0.5 + 0.5 * (a - b) / k, 0.0, 1.0)
    return b + (a - b) * h + k * h * (1.0 - h)


def _segment_distance(x, z, points):
    """Distance to a polyline and the normalised arclength parameter."""
    best = np.full(x.shape, np.inf)
    best_t = np.zeros(x.shape)
    lengths = [math.dist(points[i], points[i + 1]) for i in range(len(points) - 1)]
    total = sum(lengths)
    start = 0.0
    for (ax, az), (bx, bz), length in zip(points[:-1], points[1:], lengths):
        dx, dz = bx - ax, bz - az
        t = np.clip(((x - ax) * dx + (z - az) * dz) / (dx * dx + dz * dz), 0.0, 1.0)
        d = np.hypot(x - (ax + t * dx), z - (az + t * dz))
        closer = d < best
        best = np.where(closer, d, best)
        best_t = np.where(closer, (start + t * length) / total, best_t)
        start += length
    return best, best_t


def _ellipse(x, z, cx, cz, rx, rz, angle_deg):
    a = math.radians(angle_deg)
    dx, dz = x - cx, z - cz
    u = dx * math.cos(a) + dz * math.sin(a)
    v = -dx * math.sin(a) + dz * math.cos(a)
    return np.sqrt((u / rx) ** 2 + (v / rz) ** 2)


def _coast_distance(land, spacing):
    """Signed distance (m) to the coastline: positive on land, negative at sea."""
    edge = land ^ np.roll(land, 1, 0) | land ^ np.roll(land, 1, 1)
    edge[0, :] = edge[:, 0] = False
    ez, ex = np.nonzero(edge)
    pts = np.stack([ex, ez], -1).astype(np.float64)
    h, w = land.shape
    gz, gx = np.mgrid[0:h, 0:w]
    flat = np.stack([gx.ravel(), gz.ravel()], -1).astype(np.float64)
    out = np.empty(flat.shape[0])
    for start in range(0, flat.shape[0], 4096):
        chunk = flat[start:start + 4096]
        d2 = ((chunk[:, None, :] - pts[None, :, :]) ** 2).sum(-1)
        out[start:start + 4096] = np.sqrt(d2.min(1))
    dist = out.reshape(h, w) * spacing
    return np.where(land, dist, -dist)


def generate(seed=20261028, resolution=RESOLUTION, extent=EXTENT):
    """Return (height[z, x] float32, metadata dict). Row index = +Z, column = +X."""
    spacing = extent / (resolution - 1)
    coords = -extent * 0.5 + spacing * np.arange(resolution)
    x, z = np.meshgrid(coords, coords)  # x varies along columns, z along rows
    t_warp = _perlin_tables(seed)
    t_shape = _perlin_tables(seed + 1)
    t_ridge = _perlin_tables(seed + 2)
    t_detail = _perlin_tables(seed + 3)

    # Large-scale domain warp keeps the coastline organic rather than elliptical.
    wx = x + 210.0 * fbm(x, z, t_warp, 1500.0, 4)
    wz = z + 210.0 * fbm(x + 913.0, z - 377.0, t_warp, 1500.0, 4)

    # Landness: central massif + western sub-massif + separated SE ridge
    # peninsula + SW headland, coves carved out afterwards. Coast at L = 0.
    main = 1.0 - _ellipse(wx, wz, -260.0, 60.0, 1180.0, 820.0, -28.0)
    west = 1.0 - _ellipse(wx, wz, -880.0, -520.0, 620.0, 470.0, 15.0)
    pen_spine = [(520.0, 520.0), (900.0, 760.0), (1330.0, 1180.0), (1560.0, 1560.0)]
    pen_d, pen_t = _segment_distance(wx, wz, pen_spine)
    pen_width = 280.0 - 90.0 * pen_t - 110.0 * np.exp(-((pen_t - 0.12) / 0.08) ** 2)
    peninsula = 1.0 - pen_d / pen_width
    head_spine = [(-1180.0, 620.0), (-1500.0, 980.0), (-1640.0, 1300.0)]
    head_d, head_t = _segment_distance(wx, wz, head_spine)
    headland = 1.0 - head_d / (230.0 - 70.0 * head_t)
    land_l = _smax(_smax(main, west, 0.25), _smax(peninsula, headland, 0.2), 0.12)
    land_l += 0.16 * fbm(x, z, t_shape, 520.0, 5)

    # Coves are warped ellipses whose long axis points inland.
    cwx = wx + 70.0 * fbm(x, z, t_detail, 180.0, 3)
    cwz = wz + 70.0 * fbm(x + 300.0, z, t_detail, 180.0, 3)
    coves = [(-60.0, 1010.0, 330.0, 220.0, 80.0), (-1600.0, -140.0, 300.0, 190.0, 10.0),
             (820.0, 230.0, 300.0, 170.0, 35.0), (-280.0, -930.0, 260.0, 170.0, 95.0),
             (-1040.0, 1000.0, 230.0, 140.0, 60.0), (420.0, 900.0, 260.0, 150.0, 120.0)]
    for cx, cz, rx, rz, angle in coves:
        cut = 1.0 - _ellipse(cwx, cwz, cx, cz, rx, rz, angle)
        land_l = land_l - 1.4 * _smoothstep(0.0, 0.7, cut)

    land = land_l > 0.0
    coast = _coast_distance(land, spacing)

    # Mountain cores along ridge spines, crest heights vary along arclength.
    main_spine = [(-1260.0, 480.0), (-760.0, 120.0), (-330.0, -60.0), (120.0, -170.0), (520.0, -40.0)]
    main_d, main_t = _segment_distance(wx, wz, main_spine)
    crest = 285.0 + 150.0 * np.exp(-((main_t - 0.48) / 0.22) ** 2)
    core = crest / (1.0 + (main_d / 520.0) ** 2)
    west_spine = [(-640.0, -60.0), (-930.0, -560.0), (-1150.0, -820.0)]
    west_d, west_t = _segment_distance(wx, wz, west_spine)
    core = _smax(core, (330.0 - 120.0 * west_t) / (1.0 + (west_d / 330.0) ** 2), 40.0)
    spur_spine = [(-200.0, -40.0), (-60.0, 560.0)]
    spur_d, _ = _segment_distance(wx, wz, spur_spine)
    core = _smax(core, 260.0 / (1.0 + (spur_d / 240.0) ** 2), 40.0)
    pen_crest = 70.0 + 190.0 * _smoothstep(0.05, 0.45, pen_t) * (1.0 - 0.45 * _smoothstep(0.6, 1.0, pen_t))
    core = _smax(core, pen_crest / (1.0 + (pen_d / 210.0) ** 2), 30.0)
    core = _smax(core, (150.0 - 60.0 * head_t) / (1.0 + (head_d / 180.0) ** 2), 25.0)

    # Gentle beaches where lowland_mask is high, steeper rocky coast elsewhere.
    lowland = _smoothstep(-0.15, 0.35, fbm(x, z, t_shape, 900.0, 3) + 0.25 * (z / 2048.0))
    ramp_width = 170.0 + 520.0 * lowland
    inland = _smoothstep(0.0, 1.0, np.clip(coast / ramp_width, 0.0, None) ** 0.8)
    inland = np.where(coast > 0.0, inland, 0.0)
    beach = np.clip(coast, 0.0, None) * (0.012 + 0.03 * (1.0 - lowland))
    land_h = np.minimum(beach, 4.0 + 0.0 * beach) + core * inland

    # Rugged ridges and gullies: ridged multifractal, stronger high up.
    rx = wx + 90.0 * fbm(x, z, t_detail, 260.0, 3)
    rz = wz + 90.0 * fbm(x - 51.0, z + 83.0, t_detail, 260.0, 3)
    rugged = ridged(rx, rz, t_ridge, 620.0, 6) - 0.45
    alt = np.clip(land_h / 470.0, 0.0, 1.0)
    land_h += rugged * (35.0 + 120.0 * alt) * inland
    land_h += 6.0 * fbm(x, z, t_detail, 70.0, 3) * inland

    # Soft marine terraces in lowland regions below ~90 m.
    step = 22.0
    q = np.floor(land_h / step)
    f = land_h / step - q
    terraced = step * (q + _smoothstep(0.55, 0.95, f))
    terrace_w = lowland * (1.0 - _smoothstep(60.0, 100.0, land_h)) * 0.55
    land_h = land_h + (terraced - land_h) * terrace_w

    # Sea floor: shallow shelf, then a slope to the deep bed at the domain edge.
    sea_d = np.clip(-coast, 0.0, None)
    shelf = -(0.8 + sea_d * (0.018 + 0.02 * (1.0 - lowland)))
    deep = -165.0 * _smoothstep(260.0, 1200.0, sea_d)
    sea_h = np.minimum(shelf, -0.5) + deep * (0.75 + 0.25 * lowland)
    sea_h += 7.0 * fbm(x, z, t_detail, 400.0, 4) * _smoothstep(30.0, 300.0, sea_d)

    # Blend through the waterline so the shore never forms a vertical step.
    blend = _smoothstep(-24.0, 24.0, coast)
    height = (sea_h * (1.0 - blend) + np.maximum(land_h, 0.3) * blend).astype(np.float32)

    meta = {
        "format": "RF32",
        "byte_order": "little-endian",
        "dtype": "float32",
        "layout": "row-major; row index steps +Z, column index steps +X",
        "width": resolution,
        "height": resolution,
        "sample_spacing": spacing,
        "sample_origin": [-extent * 0.5, 0.0, -extent * 0.5],
        "sample_step_x": [spacing, 0.0, 0.0],
        "sample_step_y": [0.0, 0.0, spacing],
        "extent": [extent, extent],
        "sample_centres": "first and last samples lie on the extent corners (-2048 and +2048)",
        "units": "metres, Y relative to the StrataTerrain3D origin, sea level 0",
        "channel": "height",
        "role": "rough manual base (uneroded); edit freely, erosion is applied by Sop/hego_island_erosion::1.0",
        "generator": "scripts/houdini/island_base.py",
        "generator_version": BASE_VERSION,
        "seed": seed,
    }
    land_area = float(land.sum()) * spacing * spacing
    meta["stats"] = {
        "min": float(height.min()),
        "max": float(height.max()),
        "land_fraction": float(land.mean()),
        "land_area_km2": land_area / 1.0e6,
    }
    return height, meta


def hillshade(height, spacing, sea_level=0.0):
    """Return an RGB uint8 preview (row = +Z downwards, column = +X)."""
    gz, gx = np.gradient(height.astype(np.float64), spacing)
    light = np.array([-0.6, 0.55, -0.6])
    light /= np.linalg.norm(light)
    n = np.stack([-gx, np.ones_like(gx), -gz], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    shade = np.clip(n @ light, 0.0, 1.0)
    t = np.clip(height / 480.0, 0.0, 1.0)[..., None]
    land = np.array([0.42, 0.52, 0.28]) * (1 - t) + np.array([0.75, 0.70, 0.62]) * t
    sea = np.array([0.10, 0.25, 0.42]) + np.clip(height / 180.0, -1, 0)[..., None] * 0.08
    beach = (height > sea_level) & (height < 5.0)
    rgb = np.where((height > sea_level)[..., None], land, sea)
    rgb = np.where(beach[..., None], np.array([0.85, 0.80, 0.60]), rgb)
    rgb = rgb * (0.35 + 0.75 * shade[..., None])
    return (np.clip(rgb, 0, 1) * 255).astype(np.uint8)


def write_rf32(path, height, meta, json_path):
    data = np.ascontiguousarray(height, dtype="<f4")
    with open(path, "wb") as handle:
        handle.write(data.tobytes())
    meta = dict(meta)
    meta["byte_size"] = int(data.nbytes)
    with open(json_path, "w") as handle:
        json.dump(meta, handle, indent=2)
        handle.write("\n")
    return meta


if __name__ == "__main__":
    import sys
    from PIL import Image

    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/hego-terrain-prototype/island/base_preview.png"
    h, m = generate()
    print(json.dumps(m["stats"]))
    Image.fromarray(hillshade(h, m["sample_spacing"])).save(out)
