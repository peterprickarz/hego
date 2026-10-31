#!/usr/bin/env hython
"""Build Sop/HEGo_IslandErosion and the rough island base cache.

Run with Houdini 22.0's hython. Default: author the HDA and export the
uneroded 513x513 base height; no erosion is cooked. Cook modes load ONLY the
saved .hda file in a clean session and cook it independently:

  hython scripts/houdini/build_island_hda.py                 # author HDA + base
  hython scripts/houdini/build_island_hda.py --cook smoke    # small real cooks
  hython scripts/houdini/build_island_hda.py --cook coarse   # 513^2 @ 8 m
  hython scripts/houdini/build_island_hda.py --cook full     # coarse, then 2049^2 @ 2 m

Logs, metrics and previews go to --out-dir (default /tmp/hego-terrain-prototype/island).
The manual-height transition has its own regression: scripts/houdini/test_island_transition.py.
The base cache in demo/island/cache/ is persistent and never cleaned up.
"""

import argparse
import json
import os
import resource
import shutil
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(SCRIPT_DIR))
sys.path.insert(0, SCRIPT_DIR)
sys.dont_write_bytecode = True  # keep the source tree free of __pycache__

import island_base  # noqa: E402
import build_material_distribution_hda as material_builder  # noqa: E402  registry, habitat parameters, limiter

HDA_VERSION = "1.0"
OPERATOR = "HEGo_IslandErosion"
HDA_PATH = os.path.join(REPO, "otls", "HEGo_IslandErosion.hda")
CACHE_DIR = os.path.join(REPO, "demo", "island", "cache")
CHANNELS = ["height", "erosion_delta", "sediment", "debris", "flow", "grass", "rock", "sand", "scree", "footpath"]
MASK_CHANNELS = CHANNELS[1:]
FLOW_REFERENCE = 100.0
# Stage materials: one field per registry material on the mask lattice, after the 10 channels.
EVIDENCE_MASKS = ("flow", "sediment", "debris", "erosion_delta")
MATERIAL_GATE = "material_refine_gate"  # internal diagnostic layer, never output
MATERIAL_HABITAT_PATH = os.path.join(SCRIPT_DIR, "material_habitat.py")
MATERIAL_STAGE_PATH = os.path.join(SCRIPT_DIR, "material_stage.py")


def material_names():
    entries, registry_sha = material_builder.load_registry()
    return [entry["name"] for entry in entries], registry_sha


def material_stage_code():
    """Self-contained Python SOP source: limiter, habitat model, stage math, adapter."""
    names, registry_sha = material_names()
    header = "\n".join([
        "NAMES = " + repr(names),
        "REGISTRY_SHA256 = " + repr(registry_sha),
        "EVIDENCE_MASKS = " + repr(EVIDENCE_MASKS),
        "PACKER_SLOTS = %d" % material_builder.PACKER_SLOTS,
        "FLOAT_RANGES = " + repr([(p[0], p[3], p[4]) for p in material_builder.FLOAT_PARMS]),
    ])
    parts = [material_builder.weight_limit_source()]
    for path in (MATERIAL_HABITAT_PATH, MATERIAL_STAGE_PATH):
        with open(path) as handle:
            parts.append(handle.read())
    return "\n\n".join(parts + [header, MATERIAL_STAGE_PY.strip()]) + "\n"

# --- VEX -----------------------------------------------------------------

GRID_INFO_VEX = r"""
// Derive the output and mask lattices from the input height sample centres.
int hp = nametoprim(0, "height");
if (hp < 0) error("HEGo_IslandErosion: input 0 has no 'height' volume");
if (chs("../target_layer_path") == "") error("HEGo_IslandErosion: target_layer_path is empty");
vector res = volumeres(0, hp);
if (res.x < 2 || res.y < 2 || res.z != 1) error("HEGo_IslandErosion: height must be a 2D grid of at least 2x2 samples");
vector o = volumeindextopos(0, hp, {0, 0, 0});
vector ea = volumeindextopos(0, hp, {1, 0, 0}) - o;
vector eb = volumeindextopos(0, hp, {0, 1, 0}) - o;
float la = length(ea), lb = length(eb);
if (abs(ea.y) > 1e-4 * la || abs(eb.y) > 1e-4 * lb || abs(dot(ea, eb)) > 1e-4 * la * lb)
    error("HEGo_IslandErosion: height steps must be horizontal and orthogonal");
vector corners[] = array(o, o + ea * (res.x - 1), o + eb * (res.y - 1), o + ea * (res.x - 1) + eb * (res.y - 1));
float minx = 1e30, maxx = -1e30, minz = 1e30, maxz = -1e30;
foreach (vector c; corners) {
    minx = min(minx, c.x); maxx = max(maxx, c.x);
    minz = min(minz, c.z); maxz = max(maxz, c.z);
}
float s = chf("../output_spacing");
if (s <= 0) error("HEGo_IslandErosion: output_spacing must be positive");
int nx = int(floor((maxx - minx) / s + 1e-3)) + 1;
int nz = int(floor((maxz - minz) / s + 1e-3)) + 1;
if (nx < 4 || nz < 4) error("HEGo_IslandErosion: output grid needs at least 4x4 samples");
if (nx > 4097 || nz > 4097) error("HEGo_IslandErosion: output grid exceeds the 4097-sample bound per axis");
int k = max(1, int(rint(max(chf("../mask_spacing"), s) / s)));
int mnx = (nx - 1) / k + 1;
int mnz = (nz - 1) / k + 1;
i@hego_island_res_x = nx;
i@hego_island_res_z = nz;
f@hego_island_spacing = s;
f@hego_island_size_x = (nx - 1) * s;
f@hego_island_size_z = (nz - 1) * s;
f@hego_island_center_x = minx + (nx - 1) * s * 0.5;
f@hego_island_center_z = minz + (nz - 1) * s * 0.5;
f@hego_island_origin_x = minx;
f@hego_island_origin_z = minz;
i@hego_island_mask_stride = k;
i@hego_island_mask_res_x = mnx;
i@hego_island_mask_res_z = mnz;
f@hego_island_mask_spacing = k * s;
f@hego_island_mask_size_x = (mnx - 1) * k * s;
f@hego_island_mask_size_z = (mnz - 1) * k * s;
f@hego_island_mask_center_x = minx + (mnx - 1) * k * s * 0.5;
f@hego_island_mask_center_z = minz + (mnz - 1) * k * s * 0.5;
f@hego_island_feature_size = max(chf("../feature_size"), 3.0 * s);
i@hego_island_freeze_frame = clamp(chi("../freeze_frame"), 1, 400);
i@hego_island_input_res_a = int(res.x);
i@hego_island_input_res_b = int(res.y);
v@hego_island_input_origin = o;
v@hego_island_input_step_a = ea;
v@hego_island_input_step_b = eb;
"""

RESAMPLE_VEX = r"""
// Deliberate resample onto the output lattice before erosion. Catmull-Rom
// on the input's own sample centres (any orthogonal horizontal basis); it
// is exact wherever an output centre coincides with an input centre.
float crw(float t; int k) {
    float t2 = t * t, t3 = t2 * t;
    if (k == 0) return 0.5 * (-t3 + 2.0 * t2 - t);
    if (k == 1) return 0.5 * (3.0 * t3 - 5.0 * t2 + 2.0);
    if (k == 2) return 0.5 * (-3.0 * t3 + 4.0 * t2 + t);
    return 0.5 * (t3 - t2);
}

void lattice(int input, prim; vector P; vector res; int ia, ib; float ta, tb; int inside) {
    res = volumeres(input, prim);
    vector o = volumeindextopos(input, prim, {0, 0, 0});
    vector ea = volumeindextopos(input, prim, {1, 0, 0}) - o;
    vector eb = volumeindextopos(input, prim, {0, 1, 0}) - o;
    float fa = dot(P - o, ea) / dot(ea, ea);
    float fb = dot(P - o, eb) / dot(eb, eb);
    inside = fa > -0.5 && fb > -0.5 && fa < res.x - 0.5 && fb < res.y - 0.5;
    fa = clamp(fa, 0.0, res.x - 1.0);
    fb = clamp(fb, 0.0, res.y - 1.0);
    // Snap coincident centres so float noise cannot blend neighbours.
    if (abs(fa - rint(fa)) < 1e-4) fa = rint(fa);
    if (abs(fb - rint(fb)) < 1e-4) fb = rint(fb);
    ia = int(floor(fa)); ib = int(floor(fb));
    ta = fa - ia; tb = fb - ib;
}

float sample_cr(int input, prim; vector P) {
    vector res; int ia, ib, inside; float ta, tb;
    lattice(input, prim, P, res, ia, ib, ta, tb, inside);
    float sum = 0.0;
    for (int a = 0; a < 4; a++) {
        float wa = crw(ta, a);
        if (wa == 0.0) continue;
        int xa = clamp(ia + a - 1, 0, int(res.x) - 1);
        for (int b = 0; b < 4; b++) {
            float wb = crw(tb, b);
            if (wb == 0.0) continue;
            int xb = clamp(ib + b - 1, 0, int(res.y) - 1);
            sum += wa * wb * volumeindex(input, prim, set(xa, xb, 0));
        }
    }
    return sum;
}

// Protection weight w = clamp(value,0,1) * binary ownership, bilinear, 0 outside.
float sample_constraint(int input, vprim, oprim; vector P) {
    vector res; int ia, ib, inside; float ta, tb;
    lattice(input, vprim, P, res, ia, ib, ta, tb, inside);
    if (!inside) return 0.0;
    float sum = 0.0;
    for (int a = 0; a < 2; a++) {
        for (int b = 0; b < 2; b++) {
            float w = (a ? ta : 1.0 - ta) * (b ? tb : 1.0 - tb);
            if (w == 0.0) continue;
            vector idx = set(min(ia + a, int(res.x) - 1), min(ib + b, int(res.y) - 1), 0);
            float owned = oprim < 0 ? 1.0 : (volumeindex(input, oprim, idx) >= 0.5 ? 1.0 : 0.0);
            sum += w * owned * clamp(volumeindex(input, vprim, idx), 0.0, 1.0);
        }
    }
    return sum;
}

int hp = nametoprim(1, "height");
@height = sample_cr(1, hp, @P);
float w = 0.0;
string channel = chs("../constraint_channel");
int cp = channel == "" ? -1 : nametoprim(2, channel);
if (cp >= 0) w = sample_constraint(2, cp, nametoprim(2, channel + "__ownership"), @P);
@mask = w;
"""

ERODE_SOURCE_VEX = r"""
// The erosion source carries no mask; protection is supplied on input 1.
@mask = 0.0;
"""

ERODE_MASKS_VEX = r"""
// heightfield_erode input-1 masks. Manual protection removes erodability;
// the sea floor and the depositional beach band barely erode, and sediment
// reaching the sea is removed instead of infilling coves and the coastline.
float sea = chf("../sea_level");
float land = smooth(sea - 2.0, sea + 10.0, @height);
float shore = smooth(sea - 1.5, sea + 3.0, @height);
float protect = @mask;
@mask = (1.0 - protect) * lerp(0.03, 1.0, land);
@depositmask = lerp(0.02, 1.0, shore);
@removalmask = lerp(1.0, 0.02, shore);
"""

POST_VEX = r"""
// Same lattice as the resampled source (checked by check_grid).
vector idx = set(@ix, @iy, @iz);
float pre = volumeindex(1, "height", idx);
float w = volumeindex(1, "mask", idx);
@height = lerp(@height, pre, w);
@sediment *= 1.0 - w;
@debris *= 1.0 - w;
"""

TRANSITION_PY = r'''
# Manual-height transition. Input 0: eroded, constraint-blended terrain on the
# output lattice (E). Input 1: raw manual fields. When the raw input carries an
# owned absolute target height, output samples whose ownership coverage is at
# least 0.5 (anchors) take that height, nodes of cells straddling the
# ownership edge continue the manual surface's local plane, and a band of
# manual_transition_width metres blends E toward those values; samples
# farther away keep E bit for bit. Without a usable target the geometry
# passes through. All work is vectorised numpy on a crop around the owned
# samples. contract.json (inputs[1].manual_transition) is the specification.
import math
import time
import numpy as np

RELAX_LIMIT = 1024
node = hou.pwd()  # parameters are channel references to the asset's own parms
geo = node.geometry()
started = time.time()
stats = {"status": "disabled", "anchor_samples": 0, "band_samples": 0, "fitted_samples": 0, "max_abs_discrepancy_m": 0.0,
         "max_abs_correction_m": 0.0, "relax_iterations": 0, "relax_residual_m": 0.0, "width_m": 0.0}


def publish():
    stats["seconds"] = time.time() - started
    for key, value in stats.items():
        name = "hego_island_transition_" + key
        if geo.findGlobalAttrib(name) is None:
            geo.addAttrib(hou.attribType.Global, name, value)
        geo.setGlobalAttribValue(name, value)


def lattice(prim):
    res = prim.resolution()
    if res[2] != 1:
        raise hou.NodeError("HEGo_IslandErosion: manual target volumes must be 2D heightfields")
    origin = np.array(prim.indexToPos((0, 0, 0)), dtype=np.float64)
    step_a = np.array(prim.indexToPos((1, 0, 0)), dtype=np.float64) - origin
    step_b = np.array(prim.indexToPos((0, 1, 0)), dtype=np.float64) - origin
    la, lb = np.linalg.norm(step_a), np.linalg.norm(step_b)
    if la <= 0 or lb <= 0 or abs(step_a[1]) > 1e-4 * la or abs(step_b[1]) > 1e-4 * lb or abs(step_a @ step_b) > 1e-4 * la * lb:
        raise hou.NodeError("HEGo_IslandErosion: manual target steps must be horizontal and orthogonal")
    return (res[0], res[1]), origin, step_a, step_b


def voxels(prim):
    res = prim.resolution()
    return np.frombuffer(prim.allVoxelsAsString(), dtype="<f4").reshape(res[1], res[0]).astype(np.float64)  # [index1, index0]


def prim_string(g, prim, name):
    attrib = g.findPrimAttrib(name)
    return prim.attribValue(attrib) if attrib is not None and attrib.dataType() == hou.attribData.String else ""


def run():
    if not node.parm("manual_transition").evalAsInt():
        return
    stats["status"] = "no_raw_input"
    inputs = node.inputs()
    raw = inputs[1].geometry() if len(inputs) > 1 and inputs[1] is not None else None
    if raw is None or raw.findPrimAttrib("name") is None:
        return
    channel = node.parm("manual_height_channel").evalAsString().strip()
    stats["status"] = "no_target_channel"
    if not channel:
        return
    named = {}
    for prim in raw.prims():
        if isinstance(prim, hou.Volume):
            named.setdefault(prim.attribValue("name"), prim)
    target = named.get(channel)
    if target is None:
        return
    owner = named.get(channel + "__ownership")
    if owner is None:
        stats["status"] = "ignored_no_ownership"
        node.addWarning("HEGo_IslandErosion: raw '%s' has no '%s__ownership'; manual transition ignored" % (channel, channel))
        return
    mode = prim_string(raw, target, "hegostrata_snapshot_mode")
    if mode not in ("", "raw"):
        raise hou.NodeError("HEGo_IslandErosion: manual target '%s' must be a raw snapshot, got '%s'" % (channel, mode))
    composition = prim_string(raw, target, "hegostrata_composition")
    if composition not in ("", "replace"):
        raise hou.NodeError("HEGo_IslandErosion: manual target '%s' must be an absolute (replace) layer, got '%s'" % (channel, composition))
    role = prim_string(raw, owner, "hegostrata_role")
    if role not in ("", "ownership"):
        raise hou.NodeError("HEGo_IslandErosion: '%s__ownership' must have role 'ownership', got '%s'" % (channel, role))
    if owner.resolution() != target.resolution():
        raise hou.NodeError("HEGo_IslandErosion: manual target and its ownership differ in resolution")
    t_res, t_origin, t_a, t_b = lattice(target)
    _, o_origin, o_a, o_b = lattice(owner)
    if np.abs(o_origin - t_origin).max() > 1e-3 or np.abs(o_a - t_a).max() > 1e-6 or np.abs(o_b - t_b).max() > 1e-6:
        raise hou.NodeError("HEGo_IslandErosion: manual target and its ownership use different lattices")
    raw_value = voxels(target)
    raw_owned = voxels(owner) >= 0.5
    if not np.all(np.isfinite(raw_value[raw_owned])):
        raise hou.NodeError("HEGo_IslandErosion: manual target has non-finite owned samples")
    stats["status"] = "no_owned_samples"
    if not raw_owned.any():
        return

    height = [p for p in geo.prims() if p.attribValue("name") == "height"][0]
    (na, nb), origin, step_a, step_b = lattice(height)
    la, lb = np.linalg.norm(step_a), np.linalg.norm(step_b)
    width = max(0.0, node.parm("manual_transition_width").evalAsFloat())
    stats["width_m"] = width
    reach_a, reach_b = int(math.ceil(width / la)) + 1, int(math.ceil(width / lb)) + 1

    # Crop: output samples whose centres lie within the owned raw bounds plus the band.
    rows, cols = np.nonzero(raw_owned)
    corners = [t_origin + t_a * a + t_b * b for a in (cols.min(), cols.max()) for b in (rows.min(), rows.max())]
    fa = [(c - origin) @ step_a / (la * la) for c in corners]
    fb = [(c - origin) @ step_b / (lb * lb) for c in corners]
    a0, a1 = max(int(math.floor(min(fa))) - reach_a - 1, 0), min(int(math.ceil(max(fa))) + reach_a + 1, na - 1)
    b0, b1 = max(int(math.floor(min(fb))) - reach_b - 1, 0), min(int(math.ceil(max(fb))) + reach_b + 1, nb - 1)
    stats["status"] = "no_overlap"
    if a0 > a1 or b0 > b1:
        return

    # 1. Explicit finite sampling of the raw target at output centres: bilinear
    #    weights over the four surrounding raw samples, times binary ownership,
    #    renormalised (the runtime compositor's rule). Raw samples outside the
    #    field are unowned; centres within 1e-4 of a raw sample snap to it.
    ia, ib = np.meshgrid(np.arange(a0, a1 + 1, dtype=np.float64), np.arange(b0, b1 + 1, dtype=np.float64))  # [b, a]
    px = origin[0] + ia * step_a[0] + ib * step_b[0]
    pz = origin[2] + ia * step_a[2] + ib * step_b[2]
    ra = ((px - t_origin[0]) * t_a[0] + (pz - t_origin[2]) * t_a[2]) / (t_a @ t_a)
    rb = ((px - t_origin[0]) * t_b[0] + (pz - t_origin[2]) * t_b[2]) / (t_b @ t_b)
    for f in (ra, rb):
        near = np.rint(f)
        np.copyto(f, near, where=np.abs(f - near) < 1e-4)
    fa0, fb0 = np.floor(ra), np.floor(rb)
    ta, tb = ra - fa0, rb - fb0
    coverage = np.zeros_like(ra)
    weighted = np.zeros_like(ra)
    for da in (0, 1):
        for db in (0, 1):
            w = (ta if da else 1.0 - ta) * (tb if db else 1.0 - tb)
            ka, kb = fa0 + da, fb0 + db
            valid = (w > 0) & (ka >= 0) & (kb >= 0) & (ka < t_res[0]) & (kb < t_res[1])
            ka_i = np.where(valid, ka, 0).astype(np.int64)
            kb_i = np.where(valid, kb, 0).astype(np.int64)
            owned = valid & raw_owned[kb_i, ka_i]
            coverage += np.where(owned, w, 0.0)
            weighted += np.where(owned, w * raw_value[kb_i, ka_i], 0.0)
    anchor = coverage >= 0.5
    stats["status"] = "no_anchor_samples"
    if not anchor.any():
        return
    target_h = np.where(anchor, weighted / np.where(anchor, coverage, 1.0), 0.0)

    full = voxels(height)
    eroded = full[b0:b1 + 1, a0:a1 + 1]

    def shifted(array, k, axis, fill):
        """array[i + k] along axis, `fill` where that falls outside the crop."""
        out = np.full_like(array, fill)
        src = [slice(None)] * 2; dst = [slice(None)] * 2
        src[axis], dst[axis] = (slice(k, None), slice(None, -k)) if k > 0 else (slice(None, k), slice(-k, None))
        out[tuple(dst)] = array[tuple(src)]
        return out

    def neighbours8(array, fill):
        return [shifted(shifted(array, da, 1, fill), db, 0, fill) if da and db else
                shifted(array, da or db, 1 if da else 0, fill) for da in (-1, 0, 1) for db in (-1, 0, 1) if da or db]

    # 2. Sub-grid boundary fit. The 2 m nodes of cells that straddle the
    #    ownership edge (anchors with a non-anchor 8-neighbour and non-anchors
    #    with an anchor 8-neighbour) only matter through interpolation across
    #    that edge, so they take the manual surface's local plane at the nearest
    #    owned raw edge sample: value there plus a least-squares gradient over
    #    owned raw samples within `fit_radius`. Interior anchors keep t exactly.
    diagonal = math.hypot(la, lb)
    value = np.where(anchor, target_h, 0.0)
    fixed = anchor.copy()
    fit_count = 0
    if width > diagonal:
        fit = (anchor & np.logical_or.reduce(neighbours8(~anchor, True))) | (~anchor & np.logical_or.reduce(neighbours8(anchor, False)))
        padded = np.pad(raw_owned, 1, constant_values=False)
        raw_edge = raw_owned & ~(padded[:-2, 1:-1] & padded[2:, 1:-1] & padded[1:-1, :-2] & padded[1:-1, 2:])
        lta, ltb = np.linalg.norm(t_a), np.linalg.norm(t_b)
        fit_radius = max(0.75, 2.0 * max(lta, ltb))
        fb_i, fa_i = np.nonzero(fit)
        nx, nz = px[fit], pz[fit]
        ca, cb = np.rint(ra[fit]).astype(np.int64), np.rint(rb[fit]).astype(np.int64)

        def window(ka_c, kb_c, ra_, rb_):
            oa, ob = np.meshgrid(np.arange(-ra_, ra_ + 1), np.arange(-rb_, rb_ + 1))
            ka = ka_c[:, None] + oa.ravel()[None, :]
            kb = kb_c[:, None] + ob.ravel()[None, :]
            inside = (ka >= 0) & (kb >= 0) & (ka < t_res[0]) & (kb < t_res[1])
            ka, kb = np.where(inside, ka, 0), np.where(inside, kb, 0)
            wx = t_origin[0] + ka * t_a[0] + kb * t_b[0]
            wz = t_origin[2] + ka * t_a[2] + kb * t_b[2]
            return ka, kb, inside, wx, wz

        search_a, search_b = int(math.ceil(1.5 * diagonal / lta)) + 1, int(math.ceil(1.5 * diagonal / ltb)) + 1
        grad_a, grad_b = int(math.ceil(fit_radius / lta)), int(math.ceil(fit_radius / ltb))
        chunk = max(1, 4000000 // ((2 * search_a + 1) * (2 * search_b + 1)))
        fitted = np.full(nx.shape, np.nan)
        for lo in range(0, nx.size, chunk):
            sl = slice(lo, lo + chunk)
            ka, kb, inside, wx, wz = window(ca[sl], cb[sl], search_a, search_b)
            edge = inside & raw_edge[kb, ka]
            d2 = np.where(edge, (wx - nx[sl, None]) ** 2 + (wz - nz[sl, None]) ** 2, np.inf)
            # Nearest edge sample; exact ties resolve by world x then z so the
            # result does not depend on the raw lattice's orientation.
            d2q = np.where(edge, np.rint(d2 * 1e6), np.inf)
            pick = d2q == d2q.min(axis=1, keepdims=True)
            for key in (wx, wz):
                kq = np.where(pick, np.rint(key * 1e4), np.inf)
                pick &= kq == kq.min(axis=1, keepdims=True)
            found = edge.any(axis=1)
            j = np.argmax(pick, axis=1)
            rows = np.arange(j.size)
            pa, pb = ka[rows, j], kb[rows, j]
            sx, sz, sv = wx[rows, j], wz[rows, j], raw_value[pb, pa]
            ga, gb, ginside, gx, gz = window(pa, pb, grad_a, grad_b)
            dx, dz = gx - sx[:, None], gz - sz[:, None]
            use = ginside & raw_owned[gb, ga] & (dx * dx + dz * dz <= fit_radius * fit_radius)
            dv = np.where(use, raw_value[gb, ga] - sv[:, None], 0.0)
            dx, dz = np.where(use, dx, 0.0), np.where(use, dz, 0.0)
            sxx, sxz, szz = (dx * dx).sum(1), (dx * dz).sum(1), (dz * dz).sum(1)
            sxv, szv = (dx * dv).sum(1), (dz * dv).sum(1)
            ridge = 1e-9 + 1e-6 * (sxx + szz)  # a one-sample-wide edge gets the minimum-norm gradient
            det = (sxx + ridge) * (szz + ridge) - sxz * sxz
            gxv = ((szz + ridge) * sxv - sxz * szv) / det
            gzv = ((sxx + ridge) * szv - sxz * sxv) / det
            fitted[sl] = np.where(found, sv + gxv * (nx[sl] - sx) + gzv * (nz[sl] - sz), np.nan)
        ok = np.isfinite(fitted)
        value[fb_i[ok], fa_i[ok]] = fitted[ok]
        fixed[fb_i[ok], fa_i[ok]] = True
        fit_count = int(ok.sum())
    discrepancy = np.where(fixed, value - eroded, 0.0)

    # 3. Exact Euclidean distance (metres) to the nearest anchor within the
    #    band reach, separable: along index0, then along index1. The nearest
    #    anchor's discrepancy is carried along as the initial extension.
    gap = np.where(anchor, 0.0, np.inf)
    carried = discrepancy.copy()
    for k in range(1, reach_a + 1):
        for sign in (1, -1):
            hit = shifted(anchor, sign * k, 1, False) & (k * la < gap)
            gap = np.where(hit, k * la, gap)
            carried = np.where(hit, shifted(discrepancy, sign * k, 1, 0.0), carried)
    dist2 = gap * gap
    nearest = carried.copy()
    for k in range(1, reach_b + 1):
        for sign in (1, -1):
            candidate = shifted(gap, sign * k, 0, np.inf) ** 2 + (k * lb) ** 2
            hit = candidate < dist2
            dist2 = np.where(hit, candidate, dist2)
            nearest = np.where(hit, shifted(carried, sign * k, 0, 0.0), nearest)
    dist = np.sqrt(dist2)

    # 4. Harmonic extension of the discrepancy into the band: anchors and fitted
    #    nodes are fixed (Dirichlet), the band's outer edge is free (Neumann).
    #    Red-black SOR started from the nearest-anchor values removes their
    #    Voronoi creases; it stops once every sample is within 0.1 mm of its
    #    neighbour mean.
    band = ~anchor & (dist < width)
    domain = ~fixed & (dist < width + max(la, lb))
    member = (fixed | domain).astype(np.float64)
    count = sum(shifted(member, k, ax, 0.0) for ax in (0, 1) for k in (1, -1))
    parity = (np.add.outer(np.arange(member.shape[0]), np.arange(member.shape[1])) & 1).astype(bool)
    extension = np.where(fixed, discrepancy, np.where(domain, nearest, 0.0))
    omega = 2.0 / (1.0 + math.sin(math.pi / (2.0 * max(reach_a, reach_b) + 2.0)))
    live = domain & (count > 0)

    def neighbour_average(values):
        return sum(shifted(values * member, k, ax, 0.0) for ax in (0, 1) for k in (1, -1)) / np.maximum(count, 1.0)

    iterations = 0
    residual = 0.0
    if live.any():
        while True:
            for _ in range(16):
                for color in (False, True):
                    update = live & (parity == color)
                    extension = np.where(update, extension + omega * (neighbour_average(extension) - extension), extension)
            iterations += 16
            residual = float(np.abs(neighbour_average(extension) - extension)[live].max())
            if residual < 1e-4 or iterations >= RELAX_LIMIT:
                break

    # 5. Compose: fixed nodes take their value exactly; the rest of the band
    #    adds the extended discrepancy with a smoothstep falloff (1 inside the
    #    fitted ring, 0 with zero slope at the band's outer edge); everything
    #    else is untouched.
    inner = diagonal if fit_count else 0.0
    if width > inner:
        ramp = np.clip((dist - inner) / (width - inner), 0.0, 1.0)
    else:
        ramp = np.ones_like(dist)
    falloff = 1.0 - ramp * ramp * (3.0 - 2.0 * ramp)
    correction = np.where(fixed, discrepancy, falloff * extension)
    changed = anchor | band
    result = np.where(fixed, value, np.where(band, eroded + correction, eroded))
    if not np.all(np.isfinite(result[changed])):
        raise hou.NodeError("HEGo_IslandErosion: manual transition produced non-finite heights")
    out = np.frombuffer(height.allVoxelsAsString(), dtype="<f4").reshape(nb, na).copy()
    crop = out[b0:b1 + 1, a0:a1 + 1]
    crop[changed] = result[changed].astype("<f4")
    height.setAllVoxelsFromString(out.tobytes())
    stats.update({
        "status": "applied", "anchor_samples": int(anchor.sum()), "band_samples": int(band.sum()),
        "fitted_samples": fit_count,
        "max_abs_discrepancy_m": float(np.abs(discrepancy[fixed]).max()),
        "max_abs_correction_m": float(np.abs(correction[band]).max()) if band.any() else 0.0,
        "relax_iterations": iterations, "relax_residual_m": residual,
    })


try:
    run()
finally:
    publish()
'''

MATERIAL_STAGE_PY = r'''
# Stage materials on the mask lattice. Input 0: mask-lattice layers holding the
# material_<name> / material_refine_gate templates and this pass's published
# sediment, debris and flow. Input 1: protected post-simulation height (before the
# manual transition). Input 2: resampled pre-simulation height and protection
# `mask`. Input 3: the cumulative input, whose optional prior material_<name>
# fields may use any lattice. contract.json (outputs.materials) is the
# specification; material_stage.py holds the model-independent math.
import time

node = hou.pwd()
geo = node.geometry()
started = time.time()


def fail(message):
    raise hou.NodeError("HEGo_IslandErosion: " + message)


def by_name(g):
    found = {}
    if g.findPrimAttrib("name") is not None:
        for prim in g.prims():
            found.setdefault(prim.attribValue("name"), []).append(prim)
    return found


def single(found, name, where):
    prims = found.get(name, [])
    if len(prims) != 1 or prims[0].type() != hou.primType.Volume:
        fail("%s needs exactly one '%s' Volume" % (where, name))
    return prims[0]


def lattice(prim):
    """-> (resolution, origin, step_a, step_b) of a dense 2D heightfield with a finite,
    nonzero, horizontal and orthogonal sample basis; anything else is a node error."""
    name = prim.attribValue("name")
    res = prim.resolution()
    if res[2] != 1 or res[0] < 2 or res[1] < 2:
        fail("'%s' must be a 2D heightfield of at least 2x2 samples" % name)
    origin = np.array(prim.indexToPos((0, 0, 0)), dtype=np.float64)
    step_a = np.array(prim.indexToPos((1, 0, 0)), dtype=np.float64) - origin
    step_b = np.array(prim.indexToPos((0, 1, 0)), dtype=np.float64) - origin
    la, lb = float(np.linalg.norm(step_a)), float(np.linalg.norm(step_b))
    if not (np.isfinite(origin).all() and np.isfinite(la) and np.isfinite(lb)) or la <= 1e-6 or lb <= 1e-6:
        fail("'%s' needs a finite lattice with nonzero sample steps" % name)
    if abs(step_a[1]) > 1e-4 * la or abs(step_b[1]) > 1e-4 * lb or abs(float(step_a @ step_b)) > 1e-4 * la * lb:
        fail("'%s' sample steps must be horizontal and orthogonal" % name)
    return (res[0], res[1]), origin, step_a, step_b


def voxels(prim):
    res = prim.resolution()
    return np.frombuffer(prim.allVoxelsAsString(), dtype="<f4").reshape(res[1], res[0]).astype(np.float64)


values = {}
for name, low, high in FLOAT_RANGES:
    value = float(node.evalParm(name))
    if not np.isfinite(value) or not low <= value <= high:
        fail("material %s must be finite and in [%g, %g]" % (name, low, high))
    values[name] = value
values["seed"] = int(node.evalParm("seed"))
depth = float(node.evalParm("evidence_depth"))
flow_weight = float(node.evalParm("flow_evidence"))
if not np.isfinite(depth) or depth <= 0.0:
    fail("material_evidence_depth must be positive")
if not 0.0 <= flow_weight <= 1.0:
    fail("material_flow_evidence must be in [0, 1]")

own = by_name(geo)
outputs = [single(own, "material_" + name, "material templates") for name in NAMES]
gate_prim = single(own, "material_refine_gate", "material templates")
(na, nb), origin, step_a, step_b = lattice(outputs[0])
la, lb = float(np.linalg.norm(step_a)), float(np.linalg.norm(step_b))
post = single(by_name(node.inputs()[1].geometry()), "height", "post-simulation input")
pre_found = by_name(node.inputs()[2].geometry())
pre = single(pre_found, "height", "pre-simulation input")
(ha, hb), h_origin, h_a, h_b = lattice(pre)
k = int(round(la / float(np.linalg.norm(h_a))))
if (k < 1 or np.abs(h_origin - origin).max() > 1e-3 or np.abs(h_a * k - step_a).max() > 1e-4
        or np.abs(h_b * k - step_b).max() > 1e-4 or ((ha - 1) // k + 1, (hb - 1) // k + 1) != (na, nb)
        or lattice(post)[0] != (ha, hb)):
    fail("material lattice is not an integer stride of the height lattice")
h_pre_full, h_post_full = voxels(pre), voxels(post)
h_pre, h_sim = h_pre_full[::k, ::k].copy(), h_post_full[::k, ::k].copy()
evidence = {name: voxels(single(own, name, "mask layers")) for name in ("sediment", "debris", "flow")}
# Simulation-only change: the manual transition is applied after `post`, so a
# hand-flattened pad is never read as erosion or deposition.
evidence["erosion_delta"] = tent_downsample(h_post_full - h_pre_full, k)
del h_pre_full, h_post_full
protect = tent_downsample(voxels(single(pre_found, "mask", "pre-simulation input")), k)

i1, i0 = np.mgrid[0:nb, 0:na].astype(np.float64)
px = origin[0] + i0 * step_a[0] + i1 * step_b[0]
pz = origin[2] + i0 * step_a[2] + i1 * step_b[2]

# Prior materials: all registry channels or none, each found by NAME and sampled on
# its own lattice at the material sample centres by coverage-weighted bilinear
# interpolation (exact where centres coincide). Source samples outside a prior's
# lattice, or below 0.5 in its optional material_<name>__ownership companion, are
# unowned; a material sample is covered only where every channel has coverage
# >= 0.5, otherwise it is unassigned and the stage initializes it like the coarse
# stage. The previous stage's sediment/debris/flow/erosion_delta are already
# expressed by these weights and are deliberately not read again.
prior_found = by_name(node.inputs()[3].geometry())
present = [name for name in NAMES if "material_" + name in prior_found]
if present and len(present) != len(NAMES):
    fail("input 0 carries %d of the %d registry material channels; send all or none (missing %s)"
         % (len(present), len(NAMES), ", ".join(n for n in NAMES if n not in present)))
prior = np.zeros((len(NAMES), nb, na))
prior_coverage = np.ones((nb, na))
for index, name in enumerate(NAMES if present else []):
    prim = single(prior_found, "material_" + name, "input 0")
    (ra, rb), o, ea, eb = lattice(prim)
    data = voxels(prim)
    if not np.isfinite(data).all() or data.min() < -1e-6:
        fail("prior material_%s must be finite and >= 0" % name)
    owned = None
    if "material_%s__ownership" % name in prior_found:
        owner = single(prior_found, "material_%s__ownership" % name, "input 0")
        (oa, ob), oo, oea, oeb = lattice(owner)
        if (oa, ob) != (ra, rb) or max(np.abs(oo - o).max(), np.abs(oea - ea).max(), np.abs(oeb - eb).max()) > 1e-4:
            fail("material_%s__ownership must share the lattice of material_%s" % (name, name))
        owned = voxels(owner)
        if not np.isfinite(owned).all():
            fail("material_%s__ownership must be finite" % name)
    fa = ((px - o[0]) * ea[0] + (pz - o[2]) * ea[2]) / float(ea @ ea)
    fb = ((px - o[0]) * eb[0] + (pz - o[2]) * eb[2]) / float(eb @ eb)
    prior[index], coverage = bilinear_coverage(fa, fb, (ra, rb), np.maximum(data, 0.0), owned)
    np.minimum(prior_coverage, coverage, out=prior_coverage)
prior *= (prior_coverage >= 0.5)[None]

unit_a, unit_b = step_a / la, step_b / lb
frame = {"la": la, "lb": lb, "ua": (unit_a[0], unit_a[2]), "ub": (unit_b[0], unit_b[2]), "x": px, "z": pz}
none = np.zeros_like(h_pre)
base, _ = distribute(h_pre, {name: none for name in EVIDENCE_MASKS}, frame, values, NAMES)
evolved, _ = distribute(h_sim, evidence, frame, values, NAMES)
gate = evidence_gate(evidence["erosion_delta"], evidence["sediment"], evidence["debris"], evidence["flow"],
                     protect, la, lb, depth, flow_weight)
weights, stats = refine(prior, base, evolved, gate, PACKER_SLOTS)
del base, evolved, prior
weights = weights.astype("<f4")
wide = weights.astype(np.float64)
if not np.isfinite(wide).all() or wide.min() < 0.0:
    fail("internal error: nonfinite or negative material weight")
for prim, data in zip(outputs, weights):
    prim.setAllVoxelsFromString(np.ascontiguousarray(data).tobytes())
gate_prim.setAllVoxelsFromString(np.ascontiguousarray(gate, dtype="<f4").tobytes())
if not present:
    status = "initialized"
elif stats["prior_covered_fraction"] == 0.0:
    status = "initialized_all_zero_prior"
else:
    status = "refined_prior"
stats.update({
    "status": status, "seconds": time.time() - started, "samples": int(gate.size), "stride": k,
    "prior_outside_fraction": float((prior_coverage < 0.5).mean()) if present else 1.0,
    "max_nonzero": int((weights > 0).sum(axis=0).max()),
    "max_sum_error": float(np.abs(wide.sum(axis=0) - 1.0).max()),
    "dominant_fraction": [float(f) for f in np.bincount(np.argmax(weights, axis=0).ravel(), minlength=len(NAMES)) / float(gate.size)],
    "registry_sha256": REGISTRY_SHA256,
})
for key, value in stats.items():
    name = "hego_island_material_" + key
    if geo.findGlobalAttrib(name) is None:
        geo.addAttrib(hou.attribType.Global, name, value)
    geo.setGlobalAttribValue(name, value)
'''

CHECK_GRID_VEX = r"""
// Guard: erosion must preserve the resampled lattice exactly.
int a = nametoprim(0, "height"), b = nametoprim(1, "height");
if (volumeres(0, a) != volumeres(1, b)) error("HEGo_IslandErosion: erosion changed the grid resolution");
if (distance(volumeindextopos(0, a, {0, 0, 0}), volumeindextopos(1, b, {0, 0, 0})) > 1e-3)
    error("HEGo_IslandErosion: erosion changed the sample origin");
int c = nametoprim(1, "height");
vector o = volumeindextopos(1, c, {0, 0, 0});
if (abs(o.x - detail(2, "hego_island_origin_x")) > 1e-3 || abs(o.z - detail(2, "hego_island_origin_z")) > 1e-3)
    error("HEGo_IslandErosion: output lattice does not start at the input's first sample centre");
string produced[] = {"sediment", "debris", "flow"};
foreach (string name; produced)
    if (nametoprim(0, name) < 0) error("HEGo_IslandErosion: heightfield_erode did not produce '%s'", name);
"""

MASKS_VEX = r"""
// Tent-filter height-resolution fields into the mask lattice and classify
// biomes per fine sample. Weights per sample sum to one by construction.
int k = detail(3, "hego_island_mask_stride");
float sea = chf("../sea_level");
int hp = nametoprim(1, "height");
int pp = nametoprim(2, "height");
int sp = nametoprim(1, "sediment"), dp = nametoprim(1, "debris"), fp = nametoprim(1, "flow");
vector res = volumeres(1, hp);
vector o = volumeindextopos(1, hp, {0, 0, 0});
vector ea = volumeindextopos(1, hp, {1, 0, 0}) - o;
vector eb = volumeindextopos(1, hp, {0, 1, 0}) - o;
int ca = int(rint(dot(@P - o, ea) / dot(ea, ea)));
int cb = int(rint(dot(@P - o, eb) / dot(eb, eb)));
float la = length(ea), lb = length(eb);
float acc[] = array(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
float wsum = 0.0;
for (int da = -(k - 1); da <= k - 1; da++) {
    int a = ca + da;
    if (a < 0 || a >= res.x) continue;
    for (int db = -(k - 1); db <= k - 1; db++) {
        int b = cb + db;
        if (b < 0 || b >= res.y) continue;
        float wt = (k - abs(da)) * (k - abs(db));
        float h = volumeindex(1, hp, set(a, b, 0));
        int a0 = max(a - 1, 0), a1 = min(a + 1, int(res.x) - 1);
        int b0 = max(b - 1, 0), b1 = min(b + 1, int(res.y) - 1);
        float gx = (volumeindex(1, hp, set(a1, b, 0)) - volumeindex(1, hp, set(a0, b, 0))) / ((a1 - a0) * la);
        float gy = (volumeindex(1, hp, set(a, b1, 0)) - volumeindex(1, hp, set(a, b0, 0))) / ((b1 - b0) * lb);
        float slope = degrees(atan(sqrt(gx * gx + gy * gy)));
        float sed = volumeindex(1, sp, set(a, b, 0));
        float deb = volumeindex(1, dp, set(a, b, 0));
        float flow = clamp(log(1.0 + max(volumeindex(1, fp, set(a, b, 0)), 0.0)) / log(1.0 + FLOW_REFERENCE), 0.0, 1.0);
        float rock = max(smooth(38.0, 50.0, slope), smooth(400.0, 470.0, h) * smooth(22.0, 34.0, slope));
        float scree_r = max(smooth(0.2, 1.5, deb) * smooth(10.0, 22.0, slope),
                            smooth(31.0, 39.0, slope) * (1.0 - smooth(44.0, 52.0, slope)));
        float beach = (1.0 - smooth(sea + 3.0, sea + 10.0, h)) * (1.0 - smooth(14.0, 26.0, slope));
        float fan = smooth(0.2, 2.0, sed) * (1.0 - smooth(sea + 15.0, sea + 45.0, h)) * (1.0 - smooth(8.0, 18.0, slope));
        float sand_r = max(beach, fan);
        // Below sea level nothing is grass: steep sea floor is rock, the rest sand.
        if (h < sea) { rock = smooth(24.0, 38.0, slope); scree_r = 0.0; sand_r = 1.0; }
        float scree = (1.0 - rock) * clamp(scree_r, 0.0, 1.0);
        float sand = (1.0 - rock - scree) * clamp(sand_r, 0.0, 1.0);
        float grass = max(0.0, 1.0 - rock - scree - sand);
        acc[0] += wt * (h - volumeindex(2, pp, set(a, b, 0)));
        acc[1] += wt * sed;
        acc[2] += wt * deb;
        acc[3] += wt * flow;
        acc[4] += wt * grass;
        acc[5] += wt * rock;
        acc[6] += wt * sand;
        acc[7] += wt * scree;
        wsum += wt;
    }
}
if (wsum <= 0.0) error("HEGo_IslandErosion: mask sample outside the height lattice");
@erosion_delta = acc[0] / wsum;
@sediment = acc[1] / wsum;
@debris = acc[2] / wsum;
@flow = acc[3] / wsum;
@grass = acc[4] / wsum;
@rock = acc[5] / wsum;
@sand = acc[6] / wsum;
@scree = acc[7] / wsum;
""".replace("FLOW_REFERENCE", repr(FLOW_REFERENCE))

FOOTPATH_PY = r'''
# Footpath network on the mask lattice. Input 0: mask-lattice layers holding the
# footpath template. Input 1: final (published) height. Walkable samples lie at
# least 1 m above sea level everywhere in their footprint and are flatter than
# footpath_max_slope; trails are least-cost paths (slope-weighted distance, 8
# neighbours, diagonals need a walkable corner) joining seeded waypoints on the
# main walkable component into one connected network, rasterised to 0..1 with
# footpath_width. contract.json (outputs.footpath) is the specification.
import time
import heapq
import math
import numpy as np

SLOPE_WEIGHT = 4.0       # walking cost per metre = 1 + SLOPE_WEIGHT * (slope / max_slope)^2
PEAK_RADIUS_M = 64.0     # interior high points are local height maxima within this radius
COAST_RADIUS_M = 16.0    # coast landings lie within this distance of water
MIN_SEPARATION_M = 48.0  # waypoints are at least this far apart


def footprint(fine, k, op):
    """op-reduce the fine samples within |offset| <= k-1 of each coincident mask sample."""
    if k == 1:
        return fine.copy()
    nb, na = fine.shape
    mb, ma = (nb - 1) // k + 1, (na - 1) // k + 1
    pad = np.pad(fine, k - 1, mode="edge")
    out = None
    for db in range(2 * k - 1):
        for da in range(2 * k - 1):
            sub = pad[db:db + (mb - 1) * k + 1:k, da:da + (ma - 1) * k + 1:k]
            out = sub.copy() if out is None else op(out, sub, out=out)
    return out


def window_max(a, r):
    """Square sliding maximum of radius r samples (separable, edge clamped)."""
    out = a
    for axis in (0, 1):
        pad = [(0, 0), (0, 0)]
        pad[axis] = (r, r)
        p = np.pad(out, pad, mode="edge")
        n = a.shape[axis]
        acc = None
        for s in range(2 * r + 1):
            sl = [slice(None), slice(None)]
            sl[axis] = slice(s, s + n)
            acc = p[tuple(sl)].copy() if acc is None else np.maximum(acc, p[tuple(sl)], out=acc)
        out = acc
    return out


def components4(mask):
    """4-connected component labels (0 = background, 1..n) from row runs and union-find."""
    nb, na = mask.shape
    padded = np.zeros((nb, na + 2), np.int8)
    padded[:, 1:-1] = mask
    step = np.diff(padded, axis=1)
    rows, starts = np.nonzero(step == 1)
    ends = np.nonzero(step == -1)[1]  # exclusive; row-major order matches the starts
    parent = list(range(starts.size))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    first = np.searchsorted(rows, np.arange(nb + 1))
    for r in range(nb - 1):
        a0, a1, b1 = int(first[r]), int(first[r + 1]), int(first[r + 2])
        if a0 == a1 or a1 == b1:
            continue
        lo = np.searchsorted(ends[a1:b1], starts[a0:a1], side="right")
        hi = np.searchsorted(starts[a1:b1], ends[a0:a1], side="left")
        for i in np.nonzero(hi > lo)[0]:
            ra = find(a0 + int(i))
            for j in range(int(lo[i]), int(hi[i])):
                rb = find(a1 + j)
                if ra != rb:
                    low, high = min(ra, rb), max(ra, rb)
                    parent[high] = low
                    ra = low
    roots = np.array([find(i) for i in range(starts.size)], dtype=np.int64)
    run_label = np.unique(roots, return_inverse=True)[1].ravel()
    run_of = np.cumsum((step == 1)[:, :-1].ravel()).reshape(nb, na) - 1
    labels = np.zeros((nb, na), np.int64)
    labels[mask] = run_label[run_of[mask]] + 1
    return labels


def connect(tree, targets, walk, cost, steps):
    """Multi-source Dijkstra from every tree sample (flat indices into the
    1-sample padded grid) to the cheapest target. Diagonal moves need a
    walkable corner, so reachability is 4-connectivity. -> path or None."""
    dist = dict.fromkeys(tree, 0.0)
    prev = {}
    heap = [(0.0, t) for t in sorted(tree)]
    while heap:
        du, u = heapq.heappop(heap)
        if du > dist[u]:
            continue
        if u in targets:
            path = [u]
            while u in prev:
                u = prev[u]
                path.append(u)
            return path
        cu = cost[u]
        for off, ln, corners in steps:
            v = u + off
            if not walk[v] or (corners and not (walk[u + corners[0]] or walk[u + corners[1]])):
                continue
            nd = du + ln * 0.5 * (cu + cost[v])
            if nd < dist.get(v, math.inf):
                dist[v] = nd
                prev[v] = u
                heapq.heappush(heap, (nd, v))
    return None


def footpaths(h_fine, k, la, lb, sea, count, width, max_slope, seed):
    """Footpath mask on the mask lattice (stride k of h_fine, steps la, lb in m).
    -> (float32 [mb, ma] in 0..1, stats dict)."""
    stats = {"status": "no_walkable_land", "waypoints": 0, "connected_waypoints": 0, "centreline_samples": 0,
             "nonzero_samples": 0, "walkable_fraction": 0.0, "component_fraction": 0.0}
    fine = h_fine.astype(np.float64)
    g1, g0 = np.gradient(fine, lb / k, la / k)  # central differences, one-sided at the border
    slope = footprint(np.degrees(np.arctan(np.hypot(g0, g1))), k, np.maximum)
    low = footprint(fine, k, np.minimum)
    h = fine[::k, ::k]
    mb, ma = h.shape
    walk = (low > sea + 1.0) & (slope < max_slope)
    stats["walkable_fraction"] = float(walk.mean())
    if not walk.any():
        return np.zeros((mb, ma), np.float32), stats

    # Main walkable component; its highest sample is the first waypoint.
    labels = components4(walk)
    sizes = np.bincount(labels.ravel())
    sizes[0] = 0
    comp = labels == int(np.argmax(sizes))
    stats["component_fraction"] = float(comp.sum() / walk.sum())
    root = np.unravel_index(int(np.argmax(np.where(comp, h, -np.inf))), h.shape)

    # Waypoints: seeded k-means++-style picks (probability ~ squared distance to
    # the waypoints so far) among interior high points, then coast landings.
    rng = np.random.default_rng(int(seed))
    ii1, ii0 = np.mgrid[0:mb, 0:ma]
    px, pz = ii0 * la, ii1 * lb
    near_water = window_max((h < sea).astype(np.uint8), max(1, int(round(COAST_RADIUS_M / min(la, lb))))) > 0
    peaks = comp & (h >= window_max(h, max(2, int(round(PEAK_RADIUS_M / min(la, lb)))))) & ~near_water
    coast = comp & near_water
    n = max(2, int(count))
    n_coast = n // 2 if coast.any() else 0
    chosen = [(int(root[0]), int(root[1]))]

    def pick(cands, m):
        rows, cols = np.nonzero(cands)
        if m <= 0 or not rows.size:
            return
        x, z = px[rows, cols], pz[rows, cols]
        dmin = np.full(rows.size, np.inf)
        for r, c in chosen:
            dmin = np.minimum(dmin, np.hypot(x - px[r, c], z - pz[r, c]))
        for _ in range(m):
            weight = np.where(dmin >= MIN_SEPARATION_M, dmin * dmin, 0.0)
            if weight.sum() <= 0.0:
                return
            j = int(np.searchsorted(np.cumsum(weight), rng.random() * weight.sum(), side="right"))
            j = min(j, rows.size - 1)
            chosen.append((int(rows[j]), int(cols[j])))
            dmin = np.minimum(dmin, np.hypot(x - x[j], z - z[j]))

    pick(peaks, n - n_coast - 1)
    pick(coast, n_coast)
    pick(comp, n - len(chosen))  # top up when either candidate set ran short
    stats["waypoints"] = len(chosen)

    # Prim-style network: connect the cheapest remaining waypoint to the whole
    # network so far, so later paths may join earlier trails.
    W = ma + 2
    walk_p = np.zeros((mb + 2, ma + 2), bool)
    walk_p[1:-1, 1:-1] = walk
    cost_p = np.ones((mb + 2, ma + 2))
    cost_p[1:-1, 1:-1] = 1.0 + SLOPE_WEIGHT * (np.minimum(slope, max_slope) / max_slope) ** 2
    diag = math.hypot(la, lb)
    steps = [(1, la, None), (-1, la, None), (W, lb, None), (-W, lb, None)]
    steps += [(sb * W + sa, diag, (sa, sb * W)) for sa in (1, -1) for sb in (1, -1)]
    walk_l, cost_l = walk_p.ravel().tolist(), cost_p.ravel().tolist()
    flat = [(r + 1) * W + (c + 1) for r, c in chosen]
    tree = {flat[0]}
    centre = np.zeros((mb + 2) * (ma + 2), bool)
    centre[flat[0]] = True
    pending = set(flat[1:])
    connected = 1
    while pending:
        path = connect(tree, pending, walk_l, cost_l, steps)
        if path is None:
            break
        pending.discard(path[0])
        connected += 1
        for a, b in zip(path[:-1], path[1:]):
            if abs(b - a) not in (1, W):  # diagonal: also mark the cheaper walkable corner (4-connected)
                sa = 1 if (b - a) % W == 1 else -1
                corners = [c for c in (a + sa, b - sa) if walk_l[c]]
                centre[min(corners, key=lambda c: (cost_l[c], c))] = True
        tree.update(path)
        centre[path] = True
    centre = centre.reshape(mb + 2, ma + 2)[1:-1, 1:-1]
    stats["connected_waypoints"] = connected
    stats["centreline_samples"] = int(centre.sum())

    # Rasterise: 1 within width/2 of a centreline sample, linear to 0 one cell
    # farther, and 0 on every non-walkable sample.
    half = 0.5 * max(0.0, float(width))
    soft = max(la, lb)
    ra, rb = int(math.ceil((half + soft) / la)), int(math.ceil((half + soft) / lb))
    dist = np.where(centre, 0.0, np.inf)
    padded = np.pad(centre, ((rb, rb), (ra, ra)))
    for db in range(-rb, rb + 1):
        for da in range(-ra, ra + 1):
            r = math.hypot(da * la, db * lb)
            if (da or db) and r < half + soft:
                hit = padded[rb + db:rb + db + mb, ra + da:ra + da + ma]
                np.minimum(dist, np.where(hit, r, np.inf), out=dist)
    mask = np.where(walk, np.clip(1.0 - (dist - half) / soft, 0.0, 1.0), 0.0).astype(np.float32)
    # Drop edge samples that touch the trail only diagonally across blocked ground,
    # so the nonzero mask is one 4-connected component.
    labels = components4(mask > 0)
    mask[labels != labels[centre][0]] = 0.0
    stats["nonzero_samples"] = int((mask > 0).sum())
    stats["status"] = "connected" if connected == len(chosen) else "partial"
    return mask, stats


node = hou.pwd()
geo = node.geometry()
started = time.time()
stats = {"status": "disabled", "waypoints": 0, "connected_waypoints": 0, "centreline_samples": 0,
         "nonzero_samples": 0, "walkable_fraction": 0.0, "component_fraction": 0.0}


def fail(message):
    raise hou.NodeError("HEGo_IslandErosion: " + message)


def named(g, name, where):
    prims = [p for p in g.prims() if p.attribValue("name") == name] if g.findPrimAttrib("name") else []
    if len(prims) != 1 or prims[0].type() != hou.primType.Volume:
        fail("%s needs exactly one '%s' Volume" % (where, name))
    return prims[0]


def lattice(prim):
    res = prim.resolution()
    origin = np.array(prim.indexToPos((0, 0, 0)), dtype=np.float64)
    step_a = np.array(prim.indexToPos((1, 0, 0)), dtype=np.float64) - origin
    step_b = np.array(prim.indexToPos((0, 1, 0)), dtype=np.float64) - origin
    return (res[0], res[1]), origin, step_a, step_b


def publish():
    stats["seconds"] = time.time() - started
    for key, value in stats.items():
        name = "hego_island_footpath_" + key
        if geo.findGlobalAttrib(name) is None:
            geo.addAttrib(hou.attribType.Global, name, value)
        geo.setGlobalAttribValue(name, value)


def run():
    target = named(geo, "footpath", "mask layers")
    (na, nb), origin, step_a, step_b = lattice(target)
    mask = np.zeros((nb, na), np.float32)
    if node.evalParm("footpaths"):
        count, width = int(node.evalParm("count")), float(node.evalParm("width"))
        max_slope, sea = float(node.evalParm("max_slope")), float(node.evalParm("sea_level"))
        if not 2 <= count <= 64:
            fail("footpath_count must be in [2, 64]")
        if not (np.isfinite(width) and width >= 0.0):
            fail("footpath_width must be finite and >= 0")
        if not 0.0 < max_slope < 90.0:
            fail("footpath_max_slope must be in (0, 90) degrees")
        height = named(node.inputs()[1].geometry(), "height", "final height input")
        (ha, hb), h_origin, h_a, h_b = lattice(height)
        la, lb = float(np.linalg.norm(step_a)), float(np.linalg.norm(step_b))
        k = int(round(la / float(np.linalg.norm(h_a))))
        if (k < 1 or np.abs(h_origin - origin).max() > 1e-3 or np.abs(h_a * k - step_a).max() > 1e-4
                or np.abs(h_b * k - step_b).max() > 1e-4 or ((ha - 1) // k + 1, (hb - 1) // k + 1) != (na, nb)):
            fail("footpath lattice is not an integer stride of the height lattice")
        fine = np.frombuffer(height.allVoxelsAsString(), dtype="<f4").reshape(hb, ha)
        if not np.isfinite(fine).all():
            fail("final height has non-finite samples")
        mask, found = footpaths(fine, k, la, lb, sea, count, width, max_slope, int(node.evalParm("seed")))
        stats.update(found)
    if not (np.isfinite(mask).all() and mask.min() >= 0.0 and mask.max() <= 1.0):
        fail("internal error: footpath mask outside [0, 1]")
    target.setAllVoxelsFromString(np.ascontiguousarray(mask, dtype="<f4").tobytes())


try:
    run()
finally:
    publish()
'''

ROUTE_VEX = r"""
s@hegostrata_layer_path = chs("../target_layer_path");
s@hegostrata_role = "value";
s@hegostrata_channel = s@name;
s@hegostrata_composition = "replace";
"""

DIAG_ATTRIBUTES = [
    ("i", "res_x"), ("i", "res_z"), ("f", "spacing"), ("f", "origin_x"), ("f", "origin_z"),
    ("i", "mask_res_x"), ("i", "mask_res_z"), ("f", "mask_spacing"), ("i", "mask_stride"),
    ("f", "feature_size"), ("i", "freeze_frame"), ("i", "input_res_a"), ("i", "input_res_b"),
    ("v", "input_origin"), ("v", "input_step_a"), ("v", "input_step_b"),
]
TRANSITION_ATTRIBUTES = [
    ("s", "status"), ("i", "anchor_samples"), ("i", "band_samples"), ("i", "fitted_samples"), ("f", "max_abs_discrepancy_m"),
    ("f", "max_abs_correction_m"), ("i", "relax_iterations"), ("f", "relax_residual_m"), ("f", "width_m"), ("f", "seconds"),
]
MATERIAL_ATTRIBUTES = [
    ("s", "status"), ("f", "seconds"), ("i", "samples"), ("i", "stride"), ("f", "prior_covered_fraction"),
    ("f", "inherited_exact_fraction"), ("f", "inherited_unrefined_fraction"), ("f", "refined_fraction"), ("f", "gate_mean"), ("f", "prior_outside_fraction"),
    ("i", "inherit_limited_samples"), ("i", "inherit_renormalized_samples"), ("f", "inherit_redistributed_mass_max"),
    ("i", "inherit_tie_fallback_voxels"),
    ("f", "limit_redistributed_mass_mean"), ("i", "limit_tie_fallback_voxels"), ("i", "max_nonzero"),
    ("f", "max_sum_error"), ("f[]", "dominant_fraction"), ("s", "registry_sha256"),
]
FOOTPATH_ATTRIBUTES = [
    ("s", "status"), ("f", "seconds"), ("i", "waypoints"), ("i", "connected_waypoints"), ("i", "centreline_samples"),
    ("i", "nonzero_samples"), ("f", "walkable_fraction"), ("f", "component_fraction"),
]
DIAG_VEX = "// Diagnostics only; never routed to terrain layers.\n" + "".join(
    f'{t}@hego_island_{n} = detail(1, "hego_island_{n}");\n' for t, n in DIAG_ATTRIBUTES) + "".join(
    f'{t}@hego_island_transition_{n} = detail(2, "hego_island_transition_{n}");\n' for t, n in TRANSITION_ATTRIBUTES) + "".join(
    f'{t}@hego_island_material_{n} = detail(3, "hego_island_material_{n}");\n' for t, n in MATERIAL_ATTRIBUTES) + "".join(
    # The footpath statistics travel with the mask layers through the material stage.
    f'{t}@hego_island_footpath_{n} = detail(3, "hego_island_footpath_{n}");\n' for t, n in FOOTPATH_ATTRIBUTES) + r"""
s@hego_island_operator = "Sop/OPERATOR";
s@hego_island_stage = chi("../detail_stage") ? "detail" : "coarse";
i@hego_island_seed = chi("../seed");
f@HEGo_IslandErosion_strength = chf("../erosion_strength");
s@hego_island_erode_node = "Sop/heightfield_erode::3.0";
""".replace("OPERATOR", OPERATOR)

# heightfield_erode::3.0 parameters driven by the HDA interface. The stage
# toggle selects a preset; erosion_strength scales the active forces and the
# hydro_scale / thermal_scale ablation controls isolate either process.
STRENGTH = 'ch("../erosion_strength")'
STAGE = 'ch("../detail_stage")'
ERODE_EXPRESSIONS = {
    "dofreeze": "1",
    "freezeframe": 'detail("../grid_info", "hego_island_freeze_frame", 0)',
    "startframe": "1",
    "iterations": "1",
    "erosionscale": 'detail("../grid_info", "hego_island_feature_size", 0)',
    "seed": 'ch("../seed")',
    "erodability": "1",
    "flow": f'{STRENGTH} * ch("../hydro_scale") * if({STAGE}, 0.5, 0.7)',
    "erosion": f'{STRENGTH} * ch("../hydro_scale") * if({STAGE}, 0.12, 0.2)',
    "deposition": f'if({STAGE}, 0.6, 0.5)',
    "removal": "0.5",
    "evaporation": "0.001",
    "coverage": f'if({STAGE}, 0.25, 0.2)',
    "slopeinfluence": "0.8",
    "bankangle": "35",
    "spreaditers": "40",
    "weathering": f'{STRENGTH} * ch("../thermal_scale") * if({STAGE}, 0.45, 0.3)',
    "cutangle": f'if({STAGE}, 38, 35)',
    "reposeangle": f'if({STAGE}, 28, 22)',
}


# Slump (native heightfield_slump, smooth mode) of this pass's thermal debris.
SLUMP_PARMS = [
    ("slump_repose_angle", "Slump Repose Angle", 32.0, 10.0, 60.0,
     "Steepest angle (degrees) at which loose thermal debris rests; steeper debris slides downhill."),
    ("slump_iterations", "Slump Iterations", 30, 0, 200,
     "HeightField Slump spread iterations; more iterations let debris travel farther."),
    ("slump_spread_rate", "Slump Spread Rate", 0.5, 0.0, 1.0,
     "HeightField Slump spread rate per iteration."),
]
# How this pass's simulation evidence opens the stage-material gate.
MATERIAL_EVIDENCE_PARMS = [
    ("material_evidence_depth", "Evidence Depth", 0.5, 0.01, 20.0,
     "Metres of simulated height change, sediment or debris at which this stage fully re-derives local "
     "materials. Depth evidence below 10% is ignored; concentrated flow can still open the gate when enabled."),
    ("material_flow_evidence", "Flow Evidence", 1.0, 0.0, 1.0,
     "Weight of concentrated flow (drainage lines) as evidence; 0 counts only height change, sediment and debris."),
]
# Footpath network (Python SOP footpath_network) on the mask lattice.
FOOTPATH_PARMS = [
    ("footpath_count", "Waypoints", 8, 2, 64,
     "Number of trail waypoints on the main walkable area: the highest walkable point, interior high points and "
     "about half coast landings, picked from Seed. Every waypoint is joined into one connected network."),
    ("footpath_width", "Width", 3.0, 0.0, 32.0,
     "Trail width in metres at full mask value (1); the mask then falls linearly to 0 over one mask sample."),
    ("footpath_max_slope", "Max Slope", 30.0, 5.0, 60.0,
     "Steepest walkable slope in degrees. Steeper ground, water and land less than 1 m above sea level carry no trail."),
]
FOOTPATH_REFS = [("footpaths", 'ch("../footpaths")'), ("count", 'ch("../footpath_count")'),
                 ("width", 'ch("../footpath_width")'), ("max_slope", 'ch("../footpath_max_slope")'),
                 ("seed", 'ch("../seed")'), ("sea_level", 'ch("../sea_level")')]

SLUMP_EXPRESSIONS = {
    "iterations": 'ch("../slump_iterations")',
    "repose_angle": 'ch("../slump_repose_angle")',
    "spread_rate": 'ch("../slump_spread_rate")',
    "seed": 'ch("../seed")',
}

NODE_NOTES = {
    "IN_terrain": ("input", "Cumulative terrain: height (+ optional previous-stage masks and 32 prior material_* fields)"),
    "IN_constraints": ("input", "Raw manual constraints / owned target height (optional)"),
    "grid_info": ("input", "Output and mask lattices from the input height sample centres"),
    "target_grid": ("input", "Empty heightfield on the output lattice"),
    "resample": ("exact", "Exact Catmull-Rom resample of input height + protection weight (mask)"),
    "erode_source": ("simulation", "Erosion source: resampled height, mask cleared"),
    "erode_mask_layers": ("simulation", "Copy mask -> depositmask / removalmask"),
    "erode_masks": ("simulation", "Sea-floor / beach erodability, deposition and removal masks; protection"),
    "erode": ("simulation", "Native HeightField Erode 3.0: frozen hydraulic + thermal simulation"),
    "slump_thermal_debris": ("simulation", "Native HeightField Slump of erode's own thermal debris (smooth)"),
    "slump_switch": ("simulation", "Slump on: slumped branch. Off: original erode output"),
    "check_grid": ("simulation", "Guard: erosion kept the lattice and produced sediment/debris/flow"),
    "post": ("exact", "Manual protection: height back to pre-erosion, sediment/debris scaled by (1-w)"),
    "manual_transition": ("exact", "Exact manual-height transition band (contract inputs[1].manual_transition)"),
    "mask_grid": ("masks", "Empty heightfield on the mask lattice"),
    "mask_layers": ("masks", "Mask-lattice channel templates"),
    "masks": ("masks", "Tent-filtered erosion_delta/sediment/debris/flow + legacy grass/rock/sand/scree"),
    "footpath_network": ("masks", "Footpath mask: least-cost trails joining seeded waypoints on walkable land (Python: graph search)"),
    "material_layers": ("materials", "Registry material_<name> templates + internal material_refine_gate"),
    "material_stage": ("materials", "Stage materials: prior + gate(this pass's sim evidence) * (evolved - base)"),
    "keep_materials": ("materials", "Publish the registry material fields (gate stays internal)"),
    "keep_height": ("output", "Height channel"),
    "keep_masks": ("output", "9 mask-lattice channels (8 simulation/habitat masks + footpath)"),
    "merge_channels": ("output", "height, 9 masks, registry materials"),
    "route": ("output", "HEGo routing attributes"),
    "clean_attributes": ("output", "Strip scratch attributes"),
    "diagnostics": ("output", "Diagnostic detail attributes (never routed)"),
    "output0": ("output", "Asset output"),
}


def log(message):
    print(message, flush=True)


# --- HDA authoring --------------------------------------------------------

def _wrangle(parent, name, kind, snippet, inputs, run_over=None):
    node = parent.createNode(kind, name)
    for index, source in enumerate(inputs):
        if source is not None:
            node.setInput(index, source)
    node.parm("snippet").set(snippet.strip() + "\n")
    if run_over is not None:
        node.parm("class").set(run_over)
    return node


def _heightfield(parent, name, prefix):
    node = parent.createNode("heightfield", name)
    node.parm("orient").set("zx")
    node.parm("sampling").set("corner")
    node.parm("divisionmode").set("size")
    node.parm("initialheight").set(0.0)
    node.parm("initialmask").set(0.0)
    attr = lambda suffix: f'detail("../grid_info", "hego_island_{prefix}{suffix}", 0)'
    node.parm("gridspacing").setExpression(attr("spacing"))
    node.parm("sizex").setExpression(attr("size_x"))
    node.parm("sizey").setExpression(attr("size_z"))
    node.parm("tx").setExpression(attr("center_x"))
    node.parm("ty").set(0.0)
    node.parm("tz").setExpression(attr("center_z"))
    return node


def _document(hou, sub):
    import graph_layout
    # graph_layout.py is shared with the material HDA builder; the footpath row
    # and its semantic handoff name are added here for this asset only.
    stages = []
    for label, rows in graph_layout.EROSION_STAGES:
        if label.startswith("04 "):
            label, rows = "04 Published simulation, habitat and footpath masks", rows + [[("footpath_network", 0)]]
        stages.append((label, rows))
    graph_layout.HANDOFF_NAMES.setdefault("footpath_network", "MASK_CHANNELS")
    graph_layout.organize(hou, sub, stages, NODE_NOTES)


def _parm_templates(hou):
    group = hou.ParmTemplateGroup()
    target = hou.StringParmTemplate(
        "target_layer_path", "Target Layer Path", 1, default_value=("",),
        help="Scene path of the procedural StrataLayer, written verbatim to hegostrata_layer_path.")
    group.append(target)
    group.append(hou.ToggleParmTemplate(
        "detail_stage", "Detail Stage", default_value=False,
        help="Off: coarse preset (strong hydraulic carving). On: detail preset (gentler hydraulic, finer thermal talus)."))
    group.append(hou.IntParmTemplate("seed", "Seed", 1, default_value=(7,), min=0, max=1000,
                                     help="HeightField Erode random seed; also picks the footpath waypoints."))
    group.append(hou.IntParmTemplate(
        "freeze_frame", "Freeze Frame", 1, default_value=(24,), min=1, max=400, min_is_strict=True, max_is_strict=True,
        help="Number of simulated frames. The frozen state is output at every timeline frame."))
    group.append(hou.FloatParmTemplate(
        "feature_size", "Feature Size", 1, default_value=(24.0,), min=0.5, max=200.0,
        help="Erosion Feature Size in metres; effective value is at least 3x output_spacing."))
    group.append(hou.FloatParmTemplate(
        "output_spacing", "Output Spacing", 1, default_value=(8.0,), min=0.5, max=64.0,
        help="Height output sample spacing in metres. Input height is resampled to this lattice before erosion."))
    group.append(hou.FloatParmTemplate(
        "mask_spacing", "Mask Spacing", 1, default_value=(4.0,), min=0.5, max=64.0,
        help="Spacing of non-height channels; at least output_spacing, snapped to a multiple of it."))
    group.append(hou.FloatParmTemplate(
        "erosion_strength", "Erosion Strength", 1, default_value=(1.0,), min=0.0, max=3.0,
        min_is_strict=True, max_is_strict=True))
    group.append(hou.StringParmTemplate("constraint_channel", "Constraint Channel", 1, default_value=("constraint",)))
    group.append(hou.FloatParmTemplate("sea_level", "Sea Level", 1, default_value=(0.0,), min=-100.0, max=100.0))
    group.append(hou.ToggleParmTemplate(
        "manual_transition", "Manual Transition", default_value=True,
        help="Blend toward an owned absolute manual height on input 1 (raw <manual_height_channel> + __ownership). "
             "Without that input the output is unchanged."))
    group.append(hou.FloatParmTemplate(
        "manual_transition_width", "Transition Width", 1, default_value=(32.0,), min=0.0, max=256.0,
        min_is_strict=True, disable_when="{ manual_transition == 0 }",
        help="Width in metres of the procedural band around owned manual samples that blends from the manual "
             "boundary heights back to the eroded terrain. Terrain farther away is unchanged."))
    group.append(hou.StringParmTemplate(
        "manual_height_channel", "Manual Height Channel", 1, default_value=("height",),
        disable_when="{ manual_transition == 0 }",
        help="Raw absolute height channel on input 1; its <name>__ownership companion is required."))
    advanced = hou.FolderParmTemplate("advanced", "Advanced", folder_type=hou.folderType.Collapsible)
    advanced.addParmTemplate(hou.FloatParmTemplate(
        "hydro_scale", "Hydraulic Scale", 1, default_value=(1.0,), min=0.0, max=2.0, min_is_strict=True,
        help="Ablation control: multiplies hydraulic flow force and erosion rate."))
    advanced.addParmTemplate(hou.FloatParmTemplate(
        "thermal_scale", "Thermal Scale", 1, default_value=(1.0,), min=0.0, max=2.0, min_is_strict=True,
        help="Ablation control: multiplies thermal weathering force."))
    group.append(advanced)
    slump = hou.FolderParmTemplate("slump", "Slump", folder_type=hou.folderType.Collapsible)
    slump.addParmTemplate(hou.ToggleParmTemplate(
        "slump_enable", "Slump Thermal Debris", default_value=True,
        help="Native HeightField Slump of this pass's own thermal debris before it is added to the height. "
             "Off: the original erode output (debris added by HeightField Erode)."))
    for name, label, default, low, high, text in SLUMP_PARMS:
        template = (hou.IntParmTemplate if isinstance(default, int) else hou.FloatParmTemplate)(
            name, label, 1, default_value=(default,), min=low, max=high, min_is_strict=True,
            disable_when="{ slump_enable == 0 }", help=text)
        slump.addParmTemplate(template)
    group.append(slump)
    materials = hou.FolderParmTemplate("materials", "Materials", folder_type=hou.folderType.Collapsible)
    for name, label, default, low, high, text in material_builder.FLOAT_PARMS:
        if name != "sea_level":  # the stage's own Sea Level drives both erosion masks and materials
            materials.addParmTemplate(hou.FloatParmTemplate(
                name, label, 1, default_value=(default,), min=low, max=high, min_is_strict=True,
                max_is_strict=True, help=text))
    materials.addParmTemplate(hou.IntParmTemplate(
        "material_seed", "Material Seed", 1, default_value=(32,), min=0, max=100000, min_is_strict=True,
        max_is_strict=True, help="Seed of the world-space variation fields (the material HDA's Seed)."))
    for name, label, default, low, high, text in MATERIAL_EVIDENCE_PARMS:
        materials.addParmTemplate(hou.FloatParmTemplate(
            name, label, 1, default_value=(default,), min=low, max=high, min_is_strict=True, help=text))
    group.append(materials)
    footpaths = hou.FolderParmTemplate("footpaths_folder", "Footpaths", folder_type=hou.folderType.Collapsible)
    footpaths.addParmTemplate(hou.ToggleParmTemplate(
        "footpaths", "Footpaths", default_value=True,
        help="Compute the footpath channel: least-cost trails over walkable land joining seeded waypoints. "
             "Off: the footpath channel is still output, all zeros."))
    for name, label, default, low, high, text in FOOTPATH_PARMS:
        template = (hou.IntParmTemplate if isinstance(default, int) else hou.FloatParmTemplate)(
            name, label, 1, default_value=(default,), min=low, max=high, min_is_strict=True, max_is_strict=True,
            disable_when="{ footpaths == 0 }", help=text)
        footpaths.addParmTemplate(template)
    group.append(footpaths)
    return group


def build_hda(hou, hda_path, staging_dir):
    """Author in a staging file (Houdini writes a backup per definition edit), then copy."""
    final_path = hda_path
    os.makedirs(staging_dir, exist_ok=True)
    hda_path = os.path.join(staging_dir, os.path.basename(final_path))
    hou.hipFile.clear(suppress_save_prompt=True)
    geo = hou.node("/obj").createNode("geo", "island_build")
    sub = geo.createNode("subnet", "HEGo_IslandErosion")
    sub.parm("label1").set("Cumulative terrain (height + masks)")
    sub.parm("label2").set("Raw manual constraints (optional)")
    group = sub.parmTemplateGroup()
    for template in _parm_templates(hou).parmTemplates():
        group.append(template)
    sub.setParmTemplateGroup(group)

    terrain_in, constraints_in = sub.indirectInputs()[:2]
    in_terrain = sub.createNode("null", "IN_terrain")
    in_terrain.setInput(0, terrain_in)
    in_constraints = sub.createNode("null", "IN_constraints")
    in_constraints.setInput(0, constraints_in)

    grid_info = _wrangle(sub, "grid_info", "attribwrangle", GRID_INFO_VEX, [in_terrain], run_over="detail")
    target_grid = _heightfield(sub, "target_grid", "")
    resample = _wrangle(sub, "resample", "volumewrangle", RESAMPLE_VEX, [target_grid, grid_info, in_constraints])
    erode_src = _wrangle(sub, "erode_source", "volumewrangle", ERODE_SOURCE_VEX, [resample])
    mask_copies = sub.createNode("heightfield_copylayer", "erode_mask_layers")
    mask_copies.setInput(0, resample)
    mask_copies.parm("numcopy").set(2)
    for index, name in enumerate(("depositmask", "removalmask"), 1):
        mask_copies.parm(f"create{index}").set(1)
        mask_copies.parm(f"srcname{index}").set("mask")
        mask_copies.parm(f"dstname{index}").set(name)
    erode_masks = _wrangle(sub, "erode_masks", "volumewrangle", ERODE_MASKS_VEX, [mask_copies])
    erode = sub.createNode("heightfield_erode::3.0", "erode")
    erode.setInput(0, erode_src)
    erode.setInput(1, erode_masks)
    erode.parm("erodabilitymaskmode").set("maskon")
    erode.parm("erodabilitymasklayer").set("mask")
    erode.parm("depositionmaskmode").set("maskon")
    erode.parm("depositionmasklayer").set("depositmask")
    erode.parm("removalmaskmode").set("maskon")
    erode.parm("removalmasklayer").set("removalmask")
    erode.parm("adddebris").set(1)
    erode.parm("addsediment").set(1)
    erode.parm("cacheenabled").set(0)
    for name, expression in ERODE_EXPRESSIONS.items():
        erode.parm(name).setExpression(expression)
    # Slump: erode keeps its debris separate only on the slump branch, so the
    # switch's input 0 is the original erode output.
    erode.parm("adddebris").setExpression('if(ch("../slump_enable"), 0, 1)')
    slump = sub.createNode("heightfield_slump", "slump_thermal_debris")
    slump.setInput(0, erode)
    _set_parms(slump, slumpmode="smooth", bedrocklayer="height", materiallayer="debris", flow_enable=0, add_to_bedrock=1)
    for name, expression in SLUMP_EXPRESSIONS.items():
        slump.parm(name).setExpression(expression)
    slump_switch = sub.createNode("switch", "slump_switch")
    slump_switch.setInput(0, erode)
    slump_switch.setInput(1, slump)
    slump_switch.parm("input").setExpression('ch("../slump_enable")')
    check = _wrangle(sub, "check_grid", "attribwrangle", CHECK_GRID_VEX, [slump_switch, resample, grid_info], run_over="detail")
    post = _wrangle(sub, "post", "volumewrangle", POST_VEX, [check, resample])
    transition = sub.createNode("python", "manual_transition")
    transition.setInput(0, post)
    transition.setInput(1, in_constraints)
    transition.parm("python").set(TRANSITION_PY.strip() + "\n")
    tgroup = transition.parmTemplateGroup()
    tgroup.append(hou.IntParmTemplate("manual_transition", "Manual Transition", 1))
    tgroup.append(hou.FloatParmTemplate("manual_transition_width", "Transition Width", 1))
    tgroup.append(hou.StringParmTemplate("manual_height_channel", "Manual Height Channel", 1))
    transition.setParmTemplateGroup(tgroup)
    transition.parm("manual_transition").setExpression('ch("../manual_transition")')
    transition.parm("manual_transition_width").setExpression('ch("../manual_transition_width")')
    transition.parm("manual_height_channel").setExpression('chs("../manual_height_channel")', hou.exprLanguage.Hscript)

    mask_grid = _heightfield(sub, "mask_grid", "mask_")
    copies = sub.createNode("heightfield_copylayer", "mask_layers")
    copies.setInput(0, mask_grid)
    copies.parm("numcopy").set(len(MASK_CHANNELS))
    for index, name in enumerate(MASK_CHANNELS, 1):
        copies.parm(f"create{index}").set(1)
        copies.parm(f"srcname{index}").set("mask")
        copies.parm(f"dstname{index}").set(name)
    masks = _wrangle(sub, "masks", "volumewrangle", MASKS_VEX, [copies, transition, resample, grid_info])
    footpath = sub.createNode("python", "footpath_network")
    footpath.setInput(0, masks)
    footpath.setInput(1, transition)
    footpath.parm("python").set(FOOTPATH_PY.strip() + "\n")
    fgroup = footpath.parmTemplateGroup()
    for name, _ in FOOTPATH_REFS:
        fgroup.append((hou.IntParmTemplate if name in ("footpaths", "count", "seed") else hou.FloatParmTemplate)(name, name, 1))
    footpath.setParmTemplateGroup(fgroup)
    # Explicit channel references give the Python SOP real parameter dependencies.
    for name, expression in FOOTPATH_REFS:
        footpath.parm(name).setExpression(expression)

    names, _ = material_names()
    material_layers = sub.createNode("heightfield_copylayer", "material_layers")
    material_layers.setInput(0, footpath)
    targets = ["material_" + name for name in names] + [MATERIAL_GATE]
    material_layers.parm("numcopy").set(len(targets))
    for index, name in enumerate(targets, 1):
        _set_parms(material_layers, **{f"create{index}": 1, f"srcname{index}": "mask", f"dstname{index}": name})
    material_stage = sub.createNode("python", "material_stage")
    for index, source in enumerate((material_layers, post, resample, in_terrain)):
        material_stage.setInput(index, source)
    material_stage.parm("python").set(material_stage_code())
    mgroup = material_stage.parmTemplateGroup()
    stage_refs = [(p[0], f'ch("../{p[0]}")') for p in material_builder.FLOAT_PARMS]
    stage_refs += [("evidence_depth", 'ch("../material_evidence_depth")'), ("flow_evidence", 'ch("../material_flow_evidence")')]
    for name, _ in stage_refs:
        mgroup.append(hou.FloatParmTemplate(name, name, 1))
    mgroup.append(hou.IntParmTemplate("seed", "seed", 1))
    material_stage.setParmTemplateGroup(mgroup)
    # Explicit channel references give the Python SOP real parameter dependencies.
    for name, expression in stage_refs + [("seed", 'ch("../material_seed")')]:
        material_stage.parm(name).setExpression(expression)
    keep_materials = sub.createNode("blast", "keep_materials")
    keep_materials.setInput(0, material_stage)
    _set_parms(keep_materials, group=f"@name=material_* ^@name={MATERIAL_GATE}", grouptype="prims", negate=1)

    keep_height = sub.createNode("blast", "keep_height")
    keep_height.setInput(0, transition)
    keep_height.parm("group").set("@name=height")
    keep_height.parm("grouptype").set("prims")
    keep_height.parm("negate").set(1)
    keep_masks = sub.createNode("blast", "keep_masks")
    keep_masks.setInput(0, footpath)
    keep_masks.parm("group").set(" ".join(f"@name={name}" for name in MASK_CHANNELS))
    keep_masks.parm("grouptype").set("prims")
    keep_masks.parm("negate").set(1)
    merge = sub.createNode("merge", "merge_channels")
    merge.setInput(0, keep_height)
    merge.setInput(1, keep_masks)
    merge.setInput(2, keep_materials)
    route = _wrangle(sub, "route", "attribwrangle", ROUTE_VEX, [merge], run_over="primitive")
    clean = sub.createNode("attribdelete", "clean_attributes")
    clean.setInput(0, route)
    clean.parm("ptdel").set("*")
    clean.parm("vtxdel").set("*")
    clean.parm("primdel").set("* ^name ^hegostrata_*")
    clean.parm("dtldel").set("*")
    diag = _wrangle(sub, "diagnostics", "attribwrangle", DIAG_VEX, [clean, grid_info, transition, material_stage],
                    run_over="detail")
    out = sub.createNode("output", "output0")
    out.setInput(0, diag)
    out.setDisplayFlag(True)
    out.setRenderFlag(True)
    _document(hou, sub)

    if os.path.exists(hda_path):
        os.remove(hda_path)
    asset = sub.createDigitalAsset(
        name=OPERATOR, hda_file_name=hda_path, description="HEGo Island Erosion",
        min_num_inputs=1, max_num_inputs=2, version="",
        ignore_external_references=True, change_node_type=True, create_backup=False)
    definition = asset.type().definition()
    from graph_layout import document_definition
    document_definition(hou, definition, _parm_templates(hou), 'HEGo Island Erosion', 'Native hydraulic and thermal erosion with optional debris slump. Each stage initializes uncovered materials and refines inherited mixtures only from its own simulation evidence. Protected pre-transition height excludes manual pad corrections from material evidence. A footpath mask joins seeded waypoints on walkable land with least-cost trails.', ['Cumulative terrain:', '    Required height; optional all 32 prior material fields, sampled by physical position on their own lattices. Optional material __ownership companions control coverage.', 'Raw manual constraints:', '    Optional protection and owned absolute manual target height.'], ['Terrain channels:', '    Height, eight simulation/habitat masks, the footpath mask, then all registry material fields. Materials and masks use the mask lattice.'])
    definition.setIcon("SOP_heightfield_erode")
    definition.setComment("HEGo island erosion: genuine frozen heightfield_erode::3.0; built by scripts/houdini/build_island_hda.py")
    with open(os.path.abspath(__file__)) as handle:
        definition.addSection("hego_build_island_hda.py", handle.read())
    with open(os.path.join(REPO, "demo", "island", "hda", "contract.json")) as handle:
        definition.addSection("hego_contract.json", handle.read())
    for section, path in (("hego_material_habitat.py", MATERIAL_HABITAT_PATH), ("hego_material_stage.py", MATERIAL_STAGE_PATH)):
        with open(path) as handle:
            definition.addSection(section, handle.read())
    definition.addSection("hego_material_weight_limit.py", material_builder.weight_limit_source())
    with open(os.path.join(SCRIPT_DIR, "graph_layout.py")) as handle:
        definition.addSection("hego_graph_layout.py", handle.read())
    definition.setExtraFileOption("hego_hda_version", HDA_VERSION)
    definition.updateFromNode(asset)
    definition.save(hda_path, asset, create_backup=False)
    os.makedirs(os.path.dirname(final_path), exist_ok=True)
    shutil.copyfile(hda_path, final_path)
    return final_path


# --- Base export ----------------------------------------------------------

def export_base(out_dir):
    height, meta = island_base.generate()
    os.makedirs(CACHE_DIR, exist_ok=True)
    data_path = os.path.join(CACHE_DIR, "base_height.rf32")
    json_path = os.path.join(CACHE_DIR, "base_height.json")
    meta = island_base.write_rf32(data_path, height, meta, json_path)
    try:
        from PIL import Image
        Image.fromarray(island_base.hillshade(height, meta["sample_spacing"])).save(os.path.join(out_dir, "base_preview.png"))
    except ImportError:
        pass
    return data_path, json_path, meta


# --- Independent cooks ----------------------------------------------------

LOAD_RF32_PY = r"""
import numpy as np
node = hou.pwd()
geo = node.geometry()
path = node.parm("rf32_path").evalAsString()
meta = __import__("json").load(open(path[:-5] + ".json"))
data = np.fromfile(path, dtype="<f4").reshape(meta["height"], meta["width"])  # [z, x]
stride = node.parm("stride").evalAsInt()
data = np.ascontiguousarray(data[::stride, ::stride])
prim = [p for p in geo.prims() if p.attribValue("name") == "height"][0]
res = prim.resolution()
if (res[1], res[0]) != (data.shape[1], data.shape[0]):
    raise hou.NodeError("grid mismatch %s vs %s" % (res, data.shape))
# Houdini heightfield: index 0 -> +Z, index 1 -> +X, index 0 fastest.
prim.setAllVoxelsFromString(np.ascontiguousarray(data.T).astype("<f4").tobytes())
"""

TRANSPOSE_PY = r"""
# Rebuild 'height' with column +X / row +Z indexing (HEGo input layout).
import numpy as np
node = hou.pwd()
geo = node.geometry()
prim = [p for p in geo.prims() if p.attribValue("name") == "height"][0]
res = prim.resolution()
o = hou.Vector3(prim.indexToPos((0, 0, 0)))
step_z = hou.Vector3(prim.indexToPos((1, 0, 0))) - o
step_x = hou.Vector3(prim.indexToPos((0, 1, 0))) - o
data = np.frombuffer(prim.allVoxelsAsString(), dtype="<f4").reshape(res[1], res[0])  # [x, z]
geo.clear()
nx, nz = res[1], res[0]
vol = geo.createVolume(nx, nz, 1, hou.BoundingBox(-1, -1, -1, 1, 1, 1))
centre = o + step_x * ((nx - 1) * 0.5) + step_z * ((nz - 1) * 0.5)
m = hou.Matrix4(((step_x[0] * nx * 0.5, 0, 0, 0), (0, 0, step_z[2] * nz * 0.5, 0), (0, -1, 0, 0),
                 (centre[0], centre[1], centre[2], 1)))
vol.setTransform(m)
geo.addAttrib(hou.attribType.Prim, "name", "")
vol.setAttribValue("name", "height")
vol.setAllVoxelsFromString(np.ascontiguousarray(data.T).astype("<f4").tobytes())
"""

CONSTRAINT_PY = r"""
# Raw manual constraint fixture: a 'constraint' field plus binary ownership.
import numpy as np
node = hou.pwd()
geo = node.geometry()
names = {p.attribValue("name"): p for p in geo.prims()}
value = names["height"]
owner = names["mask"]
res = value.resolution()
a, b = np.meshgrid(np.arange(res[0]), np.arange(res[1]), indexing="xy")  # [index1, index0]
inside = (a >= res[0] // 4) & (a < res[0] // 2) & (b >= res[1] // 4) & (b < res[1] // 2)
value.setAllVoxelsFromString(np.where(inside, 1.0, 0.25).astype("<f4").tobytes())
owner.setAllVoxelsFromString(inside.astype("<f4").tobytes())
value.setAttribValue("name", "constraint")
owner.setAttribValue("name", "constraint__ownership")
"""


def _python_sop(hou, parent, name, code, source=None):
    node = parent.createNode("python", name)
    if source is not None:
        node.setInput(0, source)
    node.parm("python").set(code)
    return node


def _volume_arrays(geo):
    import numpy as np
    out = {}
    for prim in geo.prims():
        res = prim.resolution()
        origin = prim.indexToPos((0, 0, 0))
        step_a = prim.indexToPos((1, 0, 0)) - origin
        step_b = prim.indexToPos((0, 1, 0)) - origin
        data = np.frombuffer(prim.allVoxelsAsString(), dtype="<f4").reshape(res[1], res[0])
        attrs = {a.name(): prim.attribValue(a) for a in geo.primAttribs()}
        out[prim.attribValue("name")] = {
            "data": data, "res": (res[0], res[1]), "origin": tuple(origin), "step_a": tuple(step_a),
            "step_b": tuple(step_b), "attrs": attrs,
        }
    return out


def _grid_record(volume):
    return {
        "resolution_index0_index1": list(volume["res"]),
        "sample_origin": [round(v, 6) for v in volume["origin"]],
        "step_index0": [round(v, 6) for v in volume["step_a"]],
        "step_index1": [round(v, 6) for v in volume["step_b"]],
    }


def _stats(array):
    import numpy as np
    a = np.asarray(array, dtype=np.float64)
    return {"min": float(a.min()), "max": float(a.max()), "mean": float(a.mean()), "std": float(a.std())}


def _image_zx(volume):
    """Return [z, x] image of a heightfield volume (index0 = +Z, index1 = +X)."""
    import numpy as np
    sa, sb = volume["step_a"], volume["step_b"]
    data = volume["data"]  # [index1, index0]
    if abs(sa[2]) > 0 and abs(sb[0]) > 0:
        img = data.T  # [index0 (z), index1 (x)]
        if sa[2] < 0:
            img = img[::-1]
        if sb[0] < 0:
            img = img[:, ::-1]
    else:
        img = data  # [index1 (z), index0 (x)]
        if sb[2] < 0:
            img = img[::-1]
        if sa[0] < 0:
            img = img[:, ::-1]
    return np.ascontiguousarray(img)


def _cook(hou, node, label, metrics):
    start = time.time()
    try:
        node.cook(force=True)
    except hou.OperationFailed:
        pass
    elapsed = time.time() - start
    errors = list(node.errors())
    warnings = list(node.warnings())
    metrics.setdefault("cooks", []).append({
        "label": label, "seconds": round(elapsed, 3), "errors": errors, "warnings": warnings,
        "peak_rss_mib": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024.0, 1)})
    log(f"[cook] {label}: {elapsed:.2f}s errors={errors} warnings={warnings}")
    if errors:
        raise RuntimeError(f"{label} failed: {errors}")
    return elapsed


def _analyse(label, out, pre_height_zx, spacing_ratio, metrics):
    """Erosion and contract metrics for one HDA output."""
    import numpy as np
    names = [name for name in out]
    record = {"channels": names, "grids": {n: _grid_record(v) for n, v in out.items()}}
    if names != CHANNELS + ["material_" + n for n in material_names()[0]]:
        raise RuntimeError(f"{label}: unexpected channel list {names}")
    for name, volume in out.items():
        attrs = volume["attrs"]
        expected = {"hegostrata_role": "value", "hegostrata_channel": name, "hegostrata_composition": "replace"}
        for key, value in expected.items():
            if attrs.get(key) != value:
                raise RuntimeError(f"{label}: {name} has {key}={attrs.get(key)!r}")
        if set(attrs) != {"name", "hegostrata_layer_path", "hegostrata_role", "hegostrata_channel", "hegostrata_composition"}:
            raise RuntimeError(f"{label}: unexpected primitive attributes {sorted(attrs)}")
        if not np.all(np.isfinite(volume["data"])):
            raise RuntimeError(f"{label}: non-finite samples in {name}")
    height = _image_zx(out["height"])
    record["height"] = _stats(height)
    if pre_height_zx is not None:
        delta = height - pre_height_zx
        record["height_minus_pre"] = _stats(delta)
        record["eroded_fraction_lt_-0.05m"] = float((delta < -0.05).mean())
        record["deposited_fraction_gt_0.05m"] = float((delta > 0.05).mean())
        record["max_abs_delta_m"] = float(np.abs(delta).max())
    for name in MASK_CHANNELS:
        record[name] = _stats(out[name]["data"])
    biomes = sum(out[n]["data"].astype(np.float64) for n in ("grass", "rock", "sand", "scree"))
    record["biome_sum_max_error"] = float(np.abs(biomes - 1.0).max())
    record["footpath_nonzero_fraction"] = float((out["footpath"]["data"] > 0).mean())
    land = _image_zx(out["erosion_delta"])
    record["erosion_delta_eroded_fraction"] = float((land < -0.05).mean())
    record["erosion_delta_deposited_fraction"] = float((land > 0.05).mean())
    metrics[label] = record
    log(f"[metrics] {label}: " + json.dumps({k: record[k] for k in record if k not in ("grids",)}, default=str)[:2000])
    return record


def _save_preview(path, height_zx, spacing):
    try:
        from PIL import Image
    except ImportError:
        return
    Image.fromarray(island_base.hillshade(height_zx, spacing)).save(path)


def _save_delta_preview(path, delta_zx, scale):
    import numpy as np
    from PIL import Image
    t = np.clip(delta_zx / scale, -1.0, 1.0)
    rgb = np.ones(t.shape + (3,))
    rgb[..., 0] = np.where(t < 0, 1.0 + t, 1.0)
    rgb[..., 1] = 1.0 - np.abs(t)
    rgb[..., 2] = np.where(t > 0, 1.0 - t, 1.0)
    Image.fromarray((rgb * 255).astype(np.uint8)).save(path)


def _save_biome_preview(path, out):
    import numpy as np
    from PIL import Image
    colors = {"grass": (0.30, 0.55, 0.20), "rock": (0.45, 0.42, 0.40), "sand": (0.90, 0.82, 0.55), "scree": (0.70, 0.60, 0.50)}
    rgb = sum(_image_zx(out[n])[..., None] * np.array(c) for n, c in colors.items())
    Image.fromarray((np.clip(rgb, 0, 1) * 255).astype(np.uint8)).save(path)


def _export_outputs(out_dir, prefix, out):
    import numpy as np
    folder = os.path.join(out_dir, "outputs")
    os.makedirs(folder, exist_ok=True)
    manifest = {}
    for name, volume in out.items():
        path = os.path.join(folder, f"{prefix}_{name}.rf32")
        # Stored exactly as Houdini indexes it: row = index1, column = index0.
        np.ascontiguousarray(volume["data"], dtype="<f4").tofile(path)
        manifest[name] = dict(_grid_record(volume), file=path, layout="row-major [index1][index0], little-endian float32")
    with open(os.path.join(folder, f"{prefix}_manifest.json"), "w") as handle:
        json.dump(manifest, handle, indent=2)


def _set_parms(node, **parms):
    for key, value in parms.items():
        node.parm(key).set(value)


def run_cook(hou, mode, hda_path, out_dir, args):
    import numpy as np
    hou.hipFile.clear(suppress_save_prompt=True)
    hou.hda.installFile(hda_path)
    node_type = hou.nodeType(hou.sopNodeTypeCategory(), OPERATOR)
    if node_type is None or node_type.definition() is None:
        raise RuntimeError(f"{OPERATOR} not found in {hda_path}")
    metrics = {
        "mode": mode, "houdini": hou.applicationVersionString(), "operator": "Sop/" + OPERATOR,
        "hda": hda_path, "hda_library": node_type.definition().libraryFilePath(),
        "erode_definition": hou.nodeType(hou.sopNodeTypeCategory(), "heightfield_erode::3.0").definition().libraryFilePath(),
    }
    try:
        metrics["opencl"] = subprocess.run([os.path.join(os.environ.get("HFS", "/opt/hfs22.0"), "bin", "hgpuinfo"), "-c"],
                                           capture_output=True, text=True, timeout=60).stdout.strip().splitlines()[:6]
    except Exception as exc:  # noqa: BLE001 - diagnostic only
        metrics["opencl"] = f"hgpuinfo unavailable: {exc}"
    log(f"[env] {metrics['houdini']} {metrics['operator']} from {metrics['hda_library']}")
    log("[env] OpenCL: " + " | ".join(metrics["opencl"]) if isinstance(metrics["opencl"], list) else str(metrics["opencl"]))

    geo = hou.node("/obj").createNode("geo", "island_cook")
    base_path = os.path.join(CACHE_DIR, "base_height.rf32")
    base_meta = json.load(open(os.path.join(CACHE_DIR, "base_height.json")))
    base = np.fromfile(base_path, dtype="<f4").reshape(base_meta["height"], base_meta["width"])

    def base_input(stride):
        spacing = base_meta["sample_spacing"] * stride
        grid = geo.createNode("heightfield", f"base_grid_s{stride}")
        _set_parms(grid, sampling="corner", divisionmode="size", gridspacing=spacing,
                   sizex=base_meta["extent"][0], sizey=base_meta["extent"][1], tx=0.0, ty=0.0, tz=0.0)
        grid.parm("orient").set("zx")
        load = _python_sop(hou, geo, f"base_load_s{stride}", LOAD_RF32_PY, grid)
        group = load.parmTemplateGroup()
        group.append(hou.StringParmTemplate("rf32_path", "RF32", 1, default_value=(base_path,)))
        group.append(hou.IntParmTemplate("stride", "Stride", 1, default_value=(stride,)))
        load.setParmTemplateGroup(group)
        return load, np.ascontiguousarray(base[::stride, ::stride]), spacing

    def hda(name, source, constraints=None, **parms):
        node = geo.createNode(OPERATOR, name)
        node.setInput(0, source)
        if constraints is not None:
            node.setInput(1, constraints)
        _set_parms(node, **parms)
        return node

    if mode == "smoke":
        # 129x129 @ 32 m coarse, then a deliberate 2x resample (257x257 @ 16 m) detail pass.
        load, pre, spacing = base_input(4)
        coarse = hda("smoke_coarse", load, target_layer_path="../Terrain/IslandCoarse", output_spacing=32.0,
                     mask_spacing=32.0, feature_size=96.0, freeze_frame=12, seed=7)
        _cook(hou, coarse, "smoke_coarse", metrics)
        out = _volume_arrays(coarse.geometry())
        _analyse("smoke_coarse", out, pre, 1, metrics)
        expected_origin = (-2048.0, 0.0, -2048.0)
        if any(abs(a - b) > 1e-3 for a, b in zip(out["height"]["origin"], expected_origin)):
            raise RuntimeError(f"smoke_coarse origin {out['height']['origin']}")
        smoke_height = _image_zx(out["height"])
        _save_preview(os.path.join(out_dir, "smoke_coarse.png"), smoke_height, 32.0)

        keep = geo.createNode("blast", "smoke_coarse_height")
        keep.setInput(0, coarse)
        _set_parms(keep, group="@name=height", grouptype="prims", negate=1)
        detail = hda("smoke_detail", keep, target_layer_path="../Terrain/IslandDetail", detail_stage=1,
                     output_spacing=16.0, mask_spacing=32.0, feature_size=48.0, freeze_frame=8, seed=11)
        _cook(hou, detail, "smoke_detail", metrics)
        dout = _volume_arrays(detail.geometry())
        _analyse("smoke_detail", dout, None, 2, metrics)
        dh = _image_zx(dout["height"])
        metrics["smoke_detail"]["resample_check"] = "detail grid 257^2 @16 m shares every 32 m centre"
        if dh.shape != (257, 257):
            raise RuntimeError(f"smoke_detail grid {dh.shape}")

        # Ablations on the same small input: each process alone must move terrain.
        for label, parms in (("smoke_hydro_only", {"thermal_scale": 0.0}), ("smoke_thermal_only", {"hydro_scale": 0.0}),
                             ("smoke_strength_zero", {"erosion_strength": 0.0})):
            node = hda(label, load, target_layer_path="../T", output_spacing=32.0, mask_spacing=32.0,
                       feature_size=96.0, freeze_frame=12, seed=7, **parms)
            _cook(hou, node, label, metrics)
            ab = _volume_arrays(node.geometry())
            delta = _image_zx(ab["height"]) - pre
            metrics[label] = {"max_abs_delta_m": float(np.abs(delta).max()), "mean_abs_delta_m": float(np.abs(delta).mean()),
                              "sediment_max": float(ab["sediment"]["data"].max()), "debris_max": float(ab["debris"]["data"].max())}
            log(f"[metrics] {label}: {metrics[label]}")

        # Transposed input layout (column +X, row +Z) must give the same result.
        transposed = _python_sop(hou, geo, "transposed_input", TRANSPOSE_PY, load)
        tnode = hda("smoke_transposed", transposed, target_layer_path="../Terrain/IslandCoarse", output_spacing=32.0,
                    mask_spacing=32.0, feature_size=96.0, freeze_frame=12, seed=7)
        tin = _volume_arrays(transposed.geometry())["height"]
        metrics["transposed_input_grid"] = _grid_record(tin)
        _cook(hou, tnode, "smoke_transposed", metrics)
        tout = _volume_arrays(tnode.geometry())
        diff = float(np.abs(_image_zx(tout["height"]) - smoke_height).max())
        metrics["transposed_vs_standard_max_abs_m"] = diff
        log(f"[metrics] transposed input max |difference| = {diff}")
        if diff > 1e-3:
            raise RuntimeError("transposed input layout changed the result")

        # Raw manual constraints protect their owned region.
        cgrid = geo.createNode("heightfield", "constraint_grid")
        _set_parms(cgrid, sampling="corner", divisionmode="size", gridspacing=32.0, sizex=4096.0, sizey=4096.0)
        craw = _python_sop(hou, geo, "constraint_raw", CONSTRAINT_PY, cgrid)
        cnode = hda("smoke_constrained", load, craw, target_layer_path="../Terrain/IslandCoarse", output_spacing=32.0,
                    mask_spacing=32.0, feature_size=96.0, freeze_frame=12, seed=7)
        _cook(hou, cnode, "smoke_constrained", metrics)
        cout = _volume_arrays(cnode.geometry())
        craw_vol = _volume_arrays(craw.geometry())["constraint__ownership"]
        owned = _image_zx(craw_vol) > 0.5
        cdelta = _image_zx(cout["height"]) - pre
        free = _image_zx(out["height"]) - pre
        metrics["constraint"] = {
            "owned_samples": int(owned.sum()),
            "owned_max_abs_delta_m": float(np.abs(cdelta[owned]).max()),
            "unconstrained_same_region_max_abs_delta_m": float(np.abs(free[owned]).max()),
            "outside_max_abs_delta_m": float(np.abs(cdelta[~owned]).max()),
        }
        log(f"[metrics] constraint: {metrics['constraint']}")
        if metrics["constraint"]["owned_max_abs_delta_m"] > 1e-3:
            raise RuntimeError("constraint region was eroded")

        # Frozen state is time-independent.
        hou.setFrame(25)
        later = _image_zx(_volume_arrays(coarse.geometry())["height"])
        metrics["frame25_vs_frame1_max_abs_m"] = float(np.abs(later - smoke_height).max())
        hou.setFrame(1)

        # Missing target path is a hard error.
        bad = hda("smoke_no_target", load, output_spacing=32.0)
        try:
            bad.cook(force=True)
        except hou.OperationFailed:
            pass
        metrics["empty_target_errors"] = list(bad.errors())
        if not bad.errors():
            raise RuntimeError("empty target_layer_path did not error")
    else:
        load, pre, spacing = base_input(1)
        coarse = hda("coarse", load, target_layer_path=args.coarse_target, output_spacing=8.0, mask_spacing=8.0,
                     feature_size=args.coarse_feature, freeze_frame=args.coarse_freeze, seed=args.seed)
        _cook(hou, coarse, "coarse", metrics)
        out = _volume_arrays(coarse.geometry())
        _analyse("coarse", out, pre, 1, metrics)
        ch = _image_zx(out["height"])
        _save_preview(os.path.join(out_dir, "coarse_height.png"), ch, 8.0)
        _save_delta_preview(os.path.join(out_dir, "coarse_delta.png"), ch - pre, 15.0)
        _save_biome_preview(os.path.join(out_dir, "coarse_biomes.png"), out)
        _export_outputs(out_dir, "coarse", out)
        metrics["coarse"]["detail_attributes"] = {a.name(): coarse.geometry().attribValue(a) for a in coarse.geometry().globalAttribs()}

        if mode == "full":
            keep = geo.createNode("blast", "coarse_height_only")
            keep.setInput(0, coarse)
            _set_parms(keep, group="@name=height", grouptype="prims", negate=1)
            detail = hda("detail", keep, target_layer_path=args.detail_target, detail_stage=1, output_spacing=2.0,
                         mask_spacing=4.0, feature_size=args.detail_feature, freeze_frame=args.detail_freeze,
                         seed=args.seed + 1)
            _cook(hou, detail, "detail", metrics)
            dout = _volume_arrays(detail.geometry())
            _analyse("detail", dout, None, 4, metrics)
            dh = _image_zx(dout["height"])
            coincident = dh[::4, ::4] - ch
            metrics["detail"]["delta_at_coarse_centres"] = _stats(coincident)
            metrics["detail"]["eroded_fraction_at_coarse_centres"] = float((coincident < -0.05).mean())
            metrics["detail"]["deposited_fraction_at_coarse_centres"] = float((coincident > 0.05).mean())
            metrics["detail"]["detail_attributes"] = {a.name(): detail.geometry().attribValue(a) for a in detail.geometry().globalAttribs()}
            _save_preview(os.path.join(out_dir, "detail_height.png"), dh[::2, ::2], 4.0)
            _save_preview(os.path.join(out_dir, "detail_height_crop.png"), dh[700:1300, 700:1300], 2.0)
            _save_delta_preview(os.path.join(out_dir, "detail_delta.png"), _image_zx(dout["erosion_delta"]), 4.0)
            _save_biome_preview(os.path.join(out_dir, "detail_biomes.png"), dout)
            _export_outputs(out_dir, "detail", dout)
    metrics["peak_rss_mib"] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024.0, 1)
    return metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cook", choices=["smoke", "coarse", "full"], help="Load the saved HDA and cook it (no authoring).")
    parser.add_argument("--build", action="store_true", help="Author the HDA and base even when --cook is given.")
    parser.add_argument("--skip-base", action="store_true", help="Do not regenerate the base cache.")
    parser.add_argument("--hda", default=HDA_PATH)
    parser.add_argument("--out-dir", default="/tmp/hego-terrain-prototype/island")
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--coarse-freeze", type=int, default=24)
    parser.add_argument("--coarse-feature", type=float, default=24.0)
    parser.add_argument("--detail-freeze", type=int, default=16)
    parser.add_argument("--detail-feature", type=float, default=6.0)
    parser.add_argument("--coarse-target", default="../Terrain/IslandErosionCoarse")
    parser.add_argument("--detail-target", default="../Terrain/IslandErosionDetail")
    args = parser.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)

    import hou

    metrics = {"started": time.strftime("%Y-%m-%dT%H:%M:%S")}
    if args.cook is None or args.build:
        if not args.skip_base:
            data_path, json_path, meta = export_base(args.out_dir)
            log(f"[base] wrote {data_path} ({meta['byte_size']} bytes) and {json_path}: {json.dumps(meta['stats'])}")
        start = time.time()
        path = build_hda(hou, args.hda, os.path.join(args.out_dir, "hda-staging"))
        log(f"[hda] saved Sop/{OPERATOR} to {path} in {time.time() - start:.1f}s")
    if args.cook:
        metrics.update(run_cook(hou, args.cook, args.hda, args.out_dir, args))
        metrics_path = os.path.join(args.out_dir, f"metrics-{args.cook}.json")
        with open(metrics_path, "w") as handle:
            json.dump(metrics, handle, indent=2, default=str)
        log(f"[done] {args.cook} metrics: {metrics_path}")
    hou.hipFile.clear(suppress_save_prompt=True)


if __name__ == "__main__":
    main()
