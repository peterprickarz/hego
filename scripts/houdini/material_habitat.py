"""Island habitat model shared by the material HDAs; embedded verbatim, no imports beyond numpy.

distribute(height, masks, frame, params, names) is the whole deterministic model:
smooth terrain signals -> stick-breaking habitat partition -> per-habitat variant
shares -> one normalized raw weight field per registry material (sand, grass, gravel, cliff). It is a heuristic
habitat model, not a physical simulation; erosion evidence enters only through
the masks it is given (flow, sediment, debris, erosion_delta). The text below the
docstring is the model previously inlined as CORE_PY in
build_material_distribution_hda.py, moved here unchanged so the erosion HDA can
embed the same model.
"""
import numpy as np

TAU = 2.0 * np.pi
MASK64 = (1 << 64) - 1


def rise(x, a, b):
    """Smoothstep from 0 at a to 1 at b."""
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def fall(x, a, b):
    return 1.0 - rise(x, a, b)


def box(values, radius, axis):
    if radius <= 0:
        return values
    pad = [(0, 0), (0, 0)]
    pad[axis] = (radius + 1, radius)
    total = np.cumsum(np.pad(values, pad, mode="edge"), axis=axis)
    width = 2 * radius + 1
    upper = [slice(None), slice(None)]
    lower = [slice(None), slice(None)]
    upper[axis] = slice(width, None)
    lower[axis] = slice(None, -width)
    return (total[tuple(upper)] - total[tuple(lower)]) / width


def gaussian(values, sigma_m, la, lb):
    """Three box passes per axis approximate a Gaussian of sigma_m metres on each
    axis's physical step (la along index0 = array axis 1, lb along index1 = axis 0)."""
    for axis, spacing in ((1, la), (0, lb)):
        sigma = sigma_m / spacing
        radius = int(round((np.sqrt(4.0 * sigma * sigma + 1.0) - 1.0) * 0.5))
        for _ in range(3):
            values = box(values, radius, axis)
    return values


def chamfer(source, la, lb):
    """Exact 8-neighbour chamfer distance (m) to the nearest True sample, +inf if none.
    Horizontal sweeps first, then vertical/diagonal sweeps: any optimal chamfer path
    can be reordered that way, so four vectorised passes are exact."""
    d = np.where(source, 0.0, np.inf)
    n1, n0 = d.shape
    for j in range(1, n0):
        np.minimum(d[:, j], d[:, j - 1] + la, out=d[:, j])
    for j in range(n0 - 2, -1, -1):
        np.minimum(d[:, j], d[:, j + 1] + la, out=d[:, j])
    diag = float(np.hypot(la, lb))
    for order, step in ((range(1, n1), -1), (range(n1 - 2, -1, -1), 1)):
        for i in order:
            prev = d[i + step]
            best = prev + lb
            np.minimum(best[1:], prev[:-1] + diag, out=best[1:])
            np.minimum(best[:-1], prev[1:] + diag, out=best[:-1])
            np.minimum(d[i], best, out=d[i])
    return d


def _mix(state):
    """splitmix64 step -> (state, uniform [0, 1)). Only seeds the wave parameters."""
    state = (state + 0x9E3779B97F4A7C15) & MASK64
    value = ((state ^ (state >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
    value = ((value ^ (value >> 27)) * 0x94D049BB133111EB) & MASK64
    return state, (value ^ (value >> 31)) / float(1 << 64)


def waves(x, z, scale, seed, key, count=6):
    """Smooth world-space field of about unit variance: a sum of `count` plane waves
    with seeded directions, phases and wavelengths in 0.6..1.6 x scale. There is no
    per-sample randomness, so the field is band-limited and lattice independent."""
    state = (seed * 0x100000001B3 + key * 0x9E3779B1) & MASK64
    total = np.zeros_like(x)
    for _ in range(count):
        state, a = _mix(state)
        state, b = _mix(state)
        state, c = _mix(state)
        angle, wavelength = TAU * a, scale * (0.6 + b)
        total += np.cos((x * np.cos(angle) + z * np.sin(angle)) * (TAU / wavelength) + TAU * c)
    return total / np.sqrt(0.5 * count)


def signals(height, masks, frame, p):
    """Terrain signals in physical units. frame: la, lb (m), ua, ub (unit world XZ step
    directions of index0/index1), x, z (world sample positions)."""
    la, lb = frame["la"], frame["lb"]
    s = {}
    z = height - p["sea_level"]
    s["z"] = z
    d1, d0 = np.gradient(height, lb, la)  # d/d(index1 metres), d/d(index0 metres)
    gx = d0 * frame["ua"][0] + d1 * frame["ub"][0]
    gz = d0 * frame["ua"][1] + d1 * frame["ub"][1]
    grad = np.hypot(gx, gz)
    slope = np.degrees(np.arctan(grad))
    s["slope"] = gaussian(slope, 8.0, la, lb)
    sun = np.radians(p["sun_azimuth"])
    # Downslope direction (-grad) against the direction toward the sun; flat ground is neutral.
    facing = -(gx * np.cos(sun) + gz * np.sin(sun)) / np.maximum(grad, 1e-9)
    s["sunny"] = gaussian(facing * rise(slope, 4.0, 14.0), 12.0, la, lb)
    # Band-passed concavity (+ hollow, - crest): the inner Gaussian drops sample-scale roughness.
    s["concave_fine"] = (gaussian(height, 12.0, la, lb) - gaussian(height, 4.0, la, lb)) / 12.0
    s["concave_broad"] = (gaussian(height, 48.0, la, lb) - gaussian(height, 8.0, la, lb)) / 48.0
    s["crest"] = rise(-s["concave_broad"], 0.04, 0.14)
    sea = z <= 0.0
    if sea.all() or not sea.any():
        shore = np.full(z.shape, -1e6 if sea.all() else 1e6)
    else:
        shore = np.where(sea, -chamfer(~sea, la, lb), chamfer(sea, la, lb))
    s["shore"] = gaussian(shore, 4.0, la, lb)  # metres to the coastline, + inland, - offshore
    # Land fraction within ~150 m: > 0.5 in sheltered bays, < 0.5 on exposed headlands.
    s["shelter"] = gaussian((~sea).astype(np.float64), 150.0, la, lb)
    # heightfield_erode flow tracks water speed (it rises with slope), so drainage
    # lines are where flow is concentrated relative to its 40 m surroundings.
    flow = np.clip(masks["flow"], 0.0, 1.0)
    s["flow_rel"] = gaussian(flow, 6.0, la, lb) - gaussian(flow, 40.0, la, lb)
    s["sediment"] = gaussian(np.maximum(masks["sediment"], 0.0), 8.0, la, lb)
    s["debris"] = gaussian(np.maximum(masks["debris"], 0.0), 8.0, la, lb)
    s["delta"] = gaussian(masks["erosion_delta"], 8.0, la, lb)
    valley = rise(s["concave_fine"], 0.09, 0.16) * rise(s["concave_broad"], -0.02, 0.05)
    s["drainage"] = np.maximum(rise(s["flow_rel"], 0.03, 0.08), valley)
    moist = (0.45 * s["drainage"] + 0.3 * rise(s["concave_broad"], 0.0, 0.08) + 0.25 * rise(-s["sunny"], -0.3, 0.5)
             + 0.3 * rise(s["sediment"], 0.05, 0.6))
    s["moist"] = np.clip(moist, 0.0, 1.0)
    s["steep"] = rise(s["slope"], p["cliff_slope"] - 8.0, p["cliff_slope"] + 4.0)
    s["cliff_near"] = gaussian(s["steep"], 24.0, la, lb)
    # Smooth world-space geology/vegetation fields (one shared domain warp).
    scale, seed = p["variation_scale"], p["seed"]
    x, wz = frame["x"], frame["z"]
    warp_x = 0.35 * scale * waves(x, wz, 1.7 * scale, seed, 101)
    warp_z = 0.35 * scale * waves(x, wz, 1.7 * scale, seed, 202)
    wx, wz = x + warp_x, wz + warp_z
    s["litho_a"] = waves(wx, wz, 2.2 * scale, seed, 1)  # rock provinces (km scale)
    s["litho_b"] = waves(wx, wz, 2.2 * scale, seed, 2)
    s["vegetation"] = waves(wx, wz, scale, seed, 3)
    s["coast_var"] = waves(wx, wz, 0.6 * scale, seed, 4)
    s["seabed_var"] = waves(wx, wz, 1.5 * scale, seed, 5)
    s["snow_var"] = waves(wx, wz, 0.5 * scale, seed, 6)
    s["grass_var"] = waves(wx, wz, 0.8 * scale, seed, 7)
    return s


def zones(s, p):
    """Stick-breaking habitat partition: every zone weight is >= 0 and they sum to 1."""
    z, slope, shore = s["z"], s["slope"], s["shore"]
    hb, ws, tl = p["beach_height"], p["shore_width"], p["tree_line"]
    under = fall(z, -2.5, -0.5)
    land = 1.0 - under
    steep = s["steep"]
    coastal = fall(shore, 0.5 * ws, ws) * fall(z, hb, 2.0 * hb)
    sea_cliff = fall(shore, ws, 2.5 * ws) * fall(z, 4.0 * hb, 10.0 * hb)
    line = p["snow_line"] - 30.0 * rise(-s["sunny"], -0.2, 0.6) - 15.0 * np.tanh(s["snow_var"])
    snow = rise(z, line - 25.0, line + 35.0) * fall(slope, p["cliff_slope"] - 2.0, p["cliff_slope"] + 8.0)
    # Talus: thermal debris, aprons below exposed rock, and steep gullies (couloirs).
    talus = np.maximum.reduce([rise(s["debris"], 0.05, 0.6),
                               rise(s["cliff_near"], 0.12, 0.45) * rise(slope, 20.0, 30.0),
                               s["drainage"] * rise(slope, 28.0, 36.0)])
    channel = s["drainage"] * fall(slope, 26.0, 36.0)
    forest = (fall(z, tl - 50.0, tl + 30.0) * rise(z, 6.0, 30.0) * fall(slope, 32.0, 40.0)
              * rise(s["vegetation"] + 0.9 * s["moist"] - 0.35, -0.35, 0.35))
    alpine = rise(z, tl - 20.0, tl + 60.0)
    inland = land * (1.0 - steep) * (1.0 - coastal)
    rest = inland * (1.0 - snow)
    loose = rest * (1.0 - talus)
    vegetated = loose * (1.0 - channel)
    return {
        "sea": under,
        "shore": land * (1.0 - steep) * coastal,
        "sea_cliff": land * steep * sea_cliff,
        "cliff": land * steep * (1.0 - sea_cliff),
        "snow": inland * snow,
        "talus": rest * talus,
        "channel": loose * channel,
        "forest": vegetated * forest,
        "alpine": vegetated * (1.0 - forest) * alpine,
        "grass": vegetated * (1.0 - forest) * (1.0 - alpine),
    }


def affinities(s, p):
    """Per-habitat variant affinities (>= 0, one positive base per habitat) over the four
    island materials: sand, grass, gravel and cliff. Habitats say where the ground is; these
    say which of the four surfaces it reads as there."""
    z, slope, sunny, moist, shore = s["z"], s["slope"], s["sunny"], s["moist"], s["shore"]
    shade = rise(-sunny, -0.1, 0.6)
    depth = -z
    hb, ws, tl, sl = p["beach_height"], p["shore_width"], p["tree_line"], p["snow_line"]
    crest, near_cliff, drainage = s["crest"], s["cliff_near"], s["drainage"]
    # Sheltered bays (and sandy coast stretches) hold sand; exposed headlands gravel and rock.
    sandy = rise(2.5 * (s["shelter"] - 0.5) + 0.5 * s["coast_var"], -0.5, 0.5)
    eroded = rise(-s["delta"], 0.2, 1.5)
    deposited = np.maximum(rise(s["delta"], 0.1, 1.0), rise(s["sediment"], 0.05, 0.6))
    stony = rise(slope, 22.0, 32.0) * (0.4 + 0.6 * np.maximum(crest, eroded))
    cliff = {
        "dark_cliff": 1.0,
        # Loose rock collects on the less steep parts of a cliff face and at its foot.
        "scree_gravel": fall(slope, p["cliff_slope"] + 6.0, p["cliff_slope"] + 18.0) * (0.3 + 0.7 * rise(s["debris"], 0.2, 1.0)),
    }
    sea_cliff = {name: value for name, value in cliff.items()}
    sea_cliff["scree_gravel"] = sea_cliff["scree_gravel"] + 0.6 * fall(z, 6.0, 18.0)
    return {
        "sea": {
            "coastal_sand": fall(depth, 6.0, 25.0) * (0.5 + 0.5 * sandy) + 0.2,
            "scree_gravel": rise(slope, 6.0, 16.0) * fall(depth, 10.0, 30.0) + 0.4 * rise(depth, 20.0, 45.0),
            "dark_cliff": rise(slope, 16.0, 28.0) * rise(depth, 8.0, 30.0),
        },
        "shore": {
            "coastal_sand": 0.2 + rise(z, 0.0, 1.0) * fall(z, 0.8 * hb, 1.4 * hb) * fall(slope, 10.0, 18.0) * (0.3 + 0.7 * sandy) + 0.5 * deposited * fall(slope, 4.0, 10.0),
            "scree_gravel": (1.0 - sandy) * rise(slope, 3.0, 9.0) + rise(slope, 14.0, 24.0) + rise(drainage, 0.6, 0.95) * rise(slope, 2.0, 6.0),
            "island_grass": rise(z, 0.8 * hb, 1.6 * hb) * fall(slope, 15.0, 25.0),
            "dark_cliff": rise(slope, 24.0, 32.0),
        },
        "sea_cliff": sea_cliff,
        "cliff": cliff,
        "snow": {
            # No snow surface in this catalog: the high ground reads as bare rock and scree.
            "dark_cliff": 0.4 + 0.6 * rise(slope, 24.0, 34.0) + 0.4 * crest,
            "scree_gravel": 0.5 + fall(slope, 20.0, 30.0) + 0.5 * rise(s["concave_broad"], 0.0, 0.1),
            "island_grass": fall(z, sl + 10.0, sl + 60.0) * fall(slope, 16.0, 26.0) * (0.5 + 0.5 * rise(sunny, -0.2, 0.5)),
        },
        "talus": {
            "scree_gravel": 0.6 + rise(near_cliff, 0.25, 0.6) * rise(slope, 26.0, 34.0) + 0.5 * rise(s["debris"], 0.3, 1.2),
            "dark_cliff": rise(near_cliff, 0.4, 0.8) * rise(slope, 28.0, 36.0),
            "island_grass": fall(slope, 22.0, 30.0) * fall(z, tl, tl + 60.0) * fall(near_cliff, 0.3, 0.6),
        },
        "channel": {
            "scree_gravel": 0.5 + 1.2 * rise(drainage, 0.6, 0.95) * rise(slope, 2.0, 6.0),
            "coastal_sand": fall(slope, 2.0, 6.0) * fall(z, 10.0, 30.0) * (0.5 + 0.5 * deposited),
            "island_grass": 0.3 + 0.6 * moist * fall(slope, 12.0, 22.0),
        },
        "forest": {
            "island_grass": 0.7 + rise(moist, 0.45, 0.8) * fall(slope, 25.0, 35.0),
            "scree_gravel": 0.5 * rise(slope, 24.0, 34.0) + 0.3 * eroded,
        },
        "alpine": {
            "island_grass": 0.6 + 0.4 * fall(slope, 18.0, 28.0),
            "scree_gravel": rise(slope, 22.0, 32.0) * (0.5 + 0.5 * eroded) + rise(slope, 26.0, 34.0) * rise(near_cliff, 0.1, 0.4),
            "dark_cliff": rise(slope, 30.0, 38.0),
        },
        "grass": {
            "island_grass": 0.6 + 0.4 * rise(s["grass_var"], -0.4, 0.6) + 0.5 * fall(slope, 14.0, 24.0) * (0.4 + 0.6 * rise(moist, 0.15, 0.5)),
            "scree_gravel": 1.2 * stony + rise(drainage, 0.6, 0.95) * rise(slope, 2.0, 6.0),
            "coastal_sand": 0.6 * fall(shore, ws, 3.0 * ws) * fall(slope, 8.0, 16.0) * sandy,
            "dark_cliff": rise(slope, 30.0, 38.0),
        },
    }


def distribute(height, masks, frame, p, names):
    """-> (weights[len(names)][n1][n0] float64 summing to 1, zones dict). Every one of the
    len(names) fields is authored in full; nothing is capped or sparsified here."""
    s = signals(height, masks, frame, p)
    zone = zones(s, p)
    table = affinities(s, p)
    index = {name: i for i, name in enumerate(names)}
    weights = np.zeros((len(names),) + height.shape)
    for habitat, variants in table.items():
        powered = {name: np.power(np.maximum(value, 0.0), p["sharpness"]) for name, value in variants.items()}
        total = sum(powered.values())
        for name, value in powered.items():
            weights[index[name]] += zone[habitat] * value / total
    # Habitats partition 1 and shares partition each habitat, so this only removes rounding.
    return weights / weights.sum(axis=0), zone


def top_retained(weights, slots):
    """Fraction of each sample's weight a top-`slots` consumer (the native packer) keeps."""
    count = weights.shape[0]
    if count <= slots:
        return np.ones(weights.shape[1:])
    return np.partition(weights, count - slots, axis=0)[count - slots:].sum(axis=0) / weights.sum(axis=0)
