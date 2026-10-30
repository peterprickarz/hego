#!/usr/bin/env hython
"""Focused regression for the HEGo_IslandErosion manual-height transition.

Cooks only the saved .hda in a fresh hython session on small synthetic fixtures
(257x257 @ 2 m around the Bracken Isle pad, no 4 km erosion):

  hython scripts/houdini/test_island_transition.py [--hda PATH] [--out-dir DIR]
  hython scripts/houdini/test_island_transition.py --hda OLD.hda --baseline-out FILE   # old-HDA reference

With --baseline FILE (written by an older HDA build) the disabled/absent cases
are also compared bit for bit with the previous HDA's genuine erosion output.
Optional --actual DIR runs the transition on exported actual fields (see docs/island-hda.md).
Any failed check raises; metrics go to <out-dir>/transition-metrics.json.
"""

import argparse
import json
import math
import os
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(SCRIPT_DIR))
sys.path.insert(0, SCRIPT_DIR)
sys.dont_write_bytecode = True

import numpy as np  # noqa: E402

import build_island_hda as builder  # noqa: E402

PAD = (-1008.0, 592.0)
IN_SPACING, IN_RES = 4.0, 129            # cumulative input 129^2 @ 4 m
OUT_SPACING = 2.0                        # output 257^2 @ 2 m
IN_ORIGIN = (PAD[0] - 256.0, PAD[1] - 256.0)
RAW_SPACING = 0.25
WIDTH = 32.0
DETAIL = dict(detail_stage=1, output_spacing=OUT_SPACING, mask_spacing=4.0, feature_size=6.0, freeze_frame=16, seed=7)

LOAD_FIELDS_PY = r"""
# Build explicitly based 2D volumes from an .npz fixture: data[index1][index0],
# sample i lies at origin + i0 * step0 + i1 * step1 (any orthogonal basis).
import json
import numpy as np
node = hou.pwd()
geo = node.geometry()
geo.clear()
archive = np.load(node.parm("npz").evalAsString(), allow_pickle=False)
meta = json.loads(str(archive["meta"]))
geo.addAttrib(hou.attribType.Prim, "name", "")
for field in meta["fields"]:
    data = np.ascontiguousarray(archive[field["key"]], dtype="<f4")
    n1, n0 = data.shape
    o, a, b = (hou.Vector3(field[k]) for k in ("origin", "step0", "step1"))
    normal = a.cross(b).normalized()
    centre = o + a * ((n0 - 1) * 0.5) + b * ((n1 - 1) * 0.5)
    vol = geo.createVolume(n0, n1, 1, hou.BoundingBox(-1, -1, -1, 1, 1, 1))
    vol.setTransform(hou.Matrix4((tuple(a * (n0 * 0.5)) + (0,), tuple(b * (n1 * 0.5)) + (0,),
                                  tuple(normal) + (0,), tuple(centre) + (1,))))
    vol.setAttribValue("name", field["name"])
    for key, value in field.get("attrs", {}).items():
        if geo.findPrimAttrib(key) is None:
            geo.addAttrib(hou.attribType.Prim, key, "")
        vol.setAttribValue(key, value)
    vol.setAllVoxelsFromString(data.tobytes())
"""


def log(message):
    print(message, flush=True)


class Failure(RuntimeError):
    pass


def check(condition, message, results, name):
    results[name] = bool(condition)
    log(("  PASS " if condition else "  FAIL ") + name + ("" if condition else ": " + message))
    if not condition:
        raise Failure(f"{name}: {message}")


# --- synthetic world ------------------------------------------------------

def base_height(x, z):
    u, v = x - PAD[0], z - PAD[1]
    return (80.0 + 0.12 * u - 0.05 * v + 10.0 * np.sin(x / 37.0) * np.cos(z / 53.0)
            + 4.0 * np.sin((x + z) / 11.0) + 1.5 * np.sin(x / 5.3) * np.sin(z / 4.1))


def old_surface(x, z):
    """Surface the brush saw before later recooks: base plus a smooth +-10 m drift."""
    return base_height(x, z) + 6.0 * np.sin((x - PAD[0]) / 23.0 + 1.0) + 4.0 * np.cos((z - PAD[1]) / 17.0)


def smoothstep01(t):
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def manual_world(x, z):
    """Absolute manual height + ownership (the BuildingFlatten-like raw layer)."""
    u, v = x - PAD[0], z - PAD[1]
    r = np.hypot(u, v)
    flat = float(old_surface(np.array(PAD[0]), np.array(PAD[1]))) + 1.0
    disc = r < 30.0
    blend = np.clip(8.0 * (1.0 - smoothstep01(r / 30.0)), 0.0, 1.0)
    value = np.where(disc, old_surface(x, z) * (1.0 - blend) + flat * blend, 0.0)
    walkway = (u >= 25.0) & (u <= 50.0) & (np.abs(v) <= 6.0) & ~disc
    value = np.where(walkway, old_surface(x, z) + 2.0, value)
    zero_pad = (u >= -70.0) & (u <= -60.0) & (v >= 40.0) & (v <= 50.0)       # owned absolute zero
    value = np.where(zero_pad, 0.0, value)
    owned = disc | walkway | zero_pad
    # Sparse samples: one on a 2 m output centre, one strictly between centres.
    on_node = (np.abs(u - 64.0) < 1e-6) & (np.abs(v + 40.0) < 1e-6)
    off_node = (np.abs(u + 90.25) < 1e-6) & (np.abs(v + 60.75) < 1e-6)
    value = np.where(on_node, base_height(x, z) + 5.0, value)
    value = np.where(off_node, 500.0, value)
    owned |= on_node | off_node
    return value.astype(np.float32), owned


def raw_lattice(spacing, offset=(0.0, 0.0), margin=1.0):
    lo_x, hi_x = PAD[0] - 92.0 - margin, PAD[0] + 66.0 + margin
    lo_z, hi_z = PAD[1] - 62.0 - margin, PAD[1] + 52.0 + margin
    first_x = math.floor((lo_x - offset[0]) / spacing) * spacing + offset[0]
    first_z = math.floor((lo_z - offset[1]) / spacing) * spacing + offset[1]
    nx = int(math.ceil((hi_x - first_x) / spacing)) + 1
    nz = int(math.ceil((hi_z - first_z) / spacing)) + 1
    xs = first_x + np.arange(nx) * spacing
    zs = first_z + np.arange(nz) * spacing
    return xs, zs


def field(key, name, data_zx, origin, step0, step1, attrs=None):
    return {"key": key, "name": name, "data": data_zx, "origin": origin, "step0": step0, "step1": step1, "attrs": attrs or {}}


def oriented(prefix, name, data_zx, xs, zs, layout, attrs=None, y=0.0):
    """data_zx is [z][x]; express it in one of several equivalent volume bases."""
    s = float(xs[1] - xs[0])
    if layout == "hego":          # index0 +X, index1 +Z (HEGo transport)
        return field(prefix, name, data_zx, (xs[0], y, zs[0]), (s, 0, 0), (0, 0, s), attrs)
    if layout == "houdini":       # index0 +Z, index1 +X (Houdini heightfield)
        return field(prefix, name, data_zx.T, (xs[0], y, zs[0]), (0, 0, s), (s, 0, 0), attrs)
    if layout == "flipped":       # index0 -X, index1 +Z
        return field(prefix, name, data_zx[:, ::-1], (xs[-1], y, zs[0]), (-s, 0, 0), (0, 0, s), attrs)
    raise ValueError(layout)


def raw_fields(layout="hego", spacing=RAW_SPACING, offset=(0.0, 0.0), y=0.0, height=True, ownership=True,
               constraint=False, attrs=None, compact_empty=False):
    xs, zs = raw_lattice(spacing, offset)
    X, Z = np.meshgrid(xs, zs)
    value, owned = manual_world(X, Z)
    fields = []
    hattrs = {"hegostrata_role": "value", "hegostrata_channel": "height", "hegostrata_snapshot_mode": "raw",
              "hegostrata_composition": "replace"}
    hattrs.update(attrs or {})
    oattrs = {"hegostrata_role": "ownership", "hegostrata_channel": "height", "hegostrata_snapshot_mode": "raw"}
    if compact_empty:
        one = np.zeros((1, 1), np.float32)
        return [field("h", "height", one, (0.0, 0.0, 0.0), (spacing, 0, 0), (0, 0, spacing), hattrs),
                field("ho", "height__ownership", one, (0.0, 0.0, 0.0), (spacing, 0, 0), (0, 0, spacing), oattrs)]
    if height:
        fields.append(oriented("h", "height", value, xs, zs, layout, hattrs, y))
    if height and ownership:
        fields.append(oriented("ho", "height__ownership", owned.astype(np.float32), xs, zs, layout, oattrs, y))
    if constraint:
        disc = np.hypot(X - PAD[0], Z - PAD[1]) < 30.0
        fields.append(oriented("c", "constraint", disc.astype(np.float32), xs, zs, layout, {"hegostrata_role": "value"}, y))
        fields.append(oriented("co", "constraint__ownership", disc.astype(np.float32), xs, zs, layout, {"hegostrata_role": "ownership"}, y))
    return fields


def input_fields():
    xs = IN_ORIGIN[0] + np.arange(IN_RES) * IN_SPACING
    zs = IN_ORIGIN[1] + np.arange(IN_RES) * IN_SPACING
    X, Z = np.meshgrid(xs, zs)
    return [oriented("in", "height", base_height(X, Z).astype(np.float32), xs, zs, "hego")]


def write_npz(path, fields):
    arrays = {f["key"]: np.ascontiguousarray(f["data"], dtype=np.float32) for f in fields}
    meta = {"fields": [{k: (list(map(float, v)) if isinstance(v, tuple) else v) for k, v in f.items() if k != "data"} for f in fields]}
    np.savez(path, meta=json.dumps(meta), **arrays)
    return path


# --- Houdini helpers -------------------------------------------------------

class Session:
    def __init__(self, hou, hda_path, out_dir):
        self.hou = hou
        hou.hipFile.clear(suppress_save_prompt=True)
        hou.hda.installFile(hda_path)
        node_type = hou.nodeType(hou.sopNodeTypeCategory(), builder.OPERATOR)
        if node_type is None or node_type.definition() is None:
            raise RuntimeError(f"{builder.OPERATOR} not found in {hda_path}")
        self.definition = node_type.definition()
        self.geo = hou.node("/obj").createNode("geo", "transition_fixtures")
        self.out_dir = out_dir
        self.count = 0

    def loader(self, name, fields):
        hou = self.hou
        path = write_npz(os.path.join(self.out_dir, "fixtures", name + ".npz"), fields)
        node = self.geo.createNode("python", name)
        group = node.parmTemplateGroup()
        group.append(hou.StringParmTemplate("npz", "NPZ", 1, default_value=(path,)))
        node.setParmTemplateGroup(group)
        node.parm("python").set(LOAD_FIELDS_PY)
        return node

    def hda(self, name, source, raw=None, **parms):
        node = self.geo.createNode(builder.OPERATOR, name)
        node.setInput(0, source)
        if raw is not None:
            node.setInput(1, raw)
        node.parm("target_layer_path").set("../Terrain/IslandErosionDetail")
        for key, value in parms.items():
            node.parm(key).set(value)
        return node

    def cook(self, node, expect_error=False):
        start = time.time()
        try:
            node.cook(force=True)
        except self.hou.OperationFailed:
            pass
        errors = list(node.errors())
        if errors and not expect_error:
            raise RuntimeError(f"{node.name()} failed: {errors}")
        if expect_error:
            return errors
        geo = node.geometry()
        out = builder._volume_arrays(geo)
        details = {a.name(): geo.attribValue(a) for a in geo.globalAttribs()}
        # Internal-node warnings are not mirrored on the asset; read the stage directly.
        inner = node.node("manual_transition")
        warnings = list(node.warnings()) + (list(inner.warnings()) if inner is not None else [])
        log(f"[cook] {node.name()}: {time.time() - start:.2f}s transition={details.get('hego_island_transition_status')} "
            f"anchors={details.get('hego_island_transition_anchor_samples')} band={details.get('hego_island_transition_band_samples')} "
            f"residual={details.get('hego_island_transition_relax_residual_m')} warnings={warnings}")
        return out, details, warnings


def height_zx(out):
    return builder._image_zx(out["height"]).astype(np.float64)


def channel_bytes(out):
    return {name: out[name]["data"].tobytes() for name in out}


def output_axes():
    n = int(round(2 * 256.0 / OUT_SPACING)) + 1
    xs = IN_ORIGIN[0] + np.arange(n) * OUT_SPACING
    zs = IN_ORIGIN[1] + np.arange(n) * OUT_SPACING
    return xs, zs


def reference_target(fields, xs, zs):
    """Independent numpy reference of the documented sampling rule."""
    names = {f["name"]: f for f in fields}
    h, o = names["height"], names["height__ownership"]
    origin, a, b = (np.array(h[k], dtype=np.float64) for k in ("origin", "step0", "step1"))
    X, Z = np.meshgrid(xs, zs)
    fa = ((X - origin[0]) * a[0] + (Z - origin[2]) * a[2]) / (a @ a)
    fb = ((X - origin[0]) * b[0] + (Z - origin[2]) * b[2]) / (b @ b)
    for f in (fa, fb):
        near = np.rint(f)
        np.copyto(f, near, where=np.abs(f - near) < 1e-4)
    value, owner = h["data"].astype(np.float64), o["data"] >= 0.5
    n1, n0 = value.shape
    cov = np.zeros_like(X)
    acc = np.zeros_like(X)
    for da in (0, 1):
        for db in (0, 1):
            ka, kb = np.floor(fa) + da, np.floor(fb) + db
            w = (fa - np.floor(fa) if da else 1 - (fa - np.floor(fa))) * (fb - np.floor(fb) if db else 1 - (fb - np.floor(fb)))
            ok = (w > 0) & (ka >= 0) & (kb >= 0) & (ka < n0) & (kb < n1)
            ia, ib = np.where(ok, ka, 0).astype(int), np.where(ok, kb, 0).astype(int)
            own = ok & owner[ib, ia]
            cov += np.where(own, w, 0)
            acc += np.where(own, w * value[ib, ia], 0)
    anchor = cov >= 0.5
    return anchor, np.where(anchor, acc / np.where(anchor, cov, 1), 0)


def anchor_distance(anchor, spacing):
    """Brute-force reference Euclidean distance to the nearest anchor (metres)."""
    zi, xi = np.nonzero(anchor)
    Z, X = np.mgrid[0:anchor.shape[0], 0:anchor.shape[1]]
    d2 = np.full(anchor.shape, np.inf)
    for z, x in zip(zi, xi):
        d2 = np.minimum(d2, (Z - z) ** 2 + (X - x) ** 2)
    return np.sqrt(d2) * spacing


def interior_of(anchor):
    """Anchors whose eight neighbours are anchors too (kept exactly by the HDA)."""
    padded = np.pad(anchor, 1, constant_values=False)
    inner = anchor.copy()
    for dz in (-1, 0, 1):
        for dx in (-1, 0, 1):
            inner &= padded[1 + dz:1 + dz + anchor.shape[0], 1 + dx:1 + dx + anchor.shape[1]]
    return inner


def footprint(x, z):
    """Which synthetic manual feature a raw sample belongs to (for per-feature seams)."""
    u, v = x - PAD[0], z - PAD[1]
    return np.select([np.hypot(u, v) < 30.0, (u >= 25.0) & (u <= 50.0) & (np.abs(v) <= 6.0),
                      (u >= -70.0) & (u <= -60.0) & (v >= 40.0) & (v <= 50.0)], ["house_disc", "walkway", "owned_zero_pad"], "sparse")


def runtime_metrics(height2m, xs, zs, manual_value, manual_owned, mxs, mzs, label, step=1.0, window=72.0):
    """Emulate HEGo composition: 2 m HDA height bilinear, then the raw manual
    Replace layer (binary at coincident raw centres). Measures ownership-crossing
    neighbour steps on a `step` lattice around the pad and the slope of the band."""
    gx = np.arange(PAD[0] - window, PAD[0] + window + 1e-9, step)
    gz = np.arange(PAD[1] - window, PAD[1] + window + 1e-9, step)
    X, Z = np.meshgrid(gx, gz)
    fx = (X - xs[0]) / OUT_SPACING
    fz = (Z - zs[0]) / OUT_SPACING
    x0 = np.clip(np.floor(fx).astype(int), 0, len(xs) - 2)
    z0 = np.clip(np.floor(fz).astype(int), 0, len(zs) - 2)
    tx, tz = fx - x0, fz - z0
    below = (height2m[z0, x0] * (1 - tx) * (1 - tz) + height2m[z0, x0 + 1] * tx * (1 - tz)
             + height2m[z0 + 1, x0] * (1 - tx) * tz + height2m[z0 + 1, x0 + 1] * tx * tz)
    rs = mxs[1] - mxs[0]
    ix = np.rint((X - mxs[0]) / rs).astype(int)
    iz = np.rint((Z - mzs[0]) / rs).astype(int)
    inside = (ix >= 0) & (iz >= 0) & (ix < len(mxs)) & (iz < len(mzs))
    ixc, izc = np.clip(ix, 0, len(mxs) - 1), np.clip(iz, 0, len(mzs) - 1)
    owned = inside & manual_owned[izc, ixc]
    final = np.where(owned, manual_value[izc, ixc], below)
    steps, kinds = [], []
    feature = footprint(X, Z)
    for axis in (0, 1):
        a = (slice(None, -1), slice(None)) if axis == 0 else (slice(None), slice(None, -1))
        b = (slice(1, None), slice(None)) if axis == 0 else (slice(None), slice(1, None))
        cross = owned[a] != owned[b]
        steps.append(np.abs(final[a] - final[b])[cross])
        kinds.append(np.where(owned[a], feature[a], feature[b])[cross])
    steps, kinds = np.concatenate(steps), np.concatenate(kinds)

    def summary(values):
        return {"crossing_edges": int(values.size), "mean_step_m": float(values.mean()),
                "p95_step_m": float(np.percentile(values, 95)), "max_step_m": float(values.max())}
    gz_, gx_ = np.gradient(final, step)
    slope = np.degrees(np.arctan(np.hypot(gx_, gz_)))
    record = {"label": label, "lattice_m": step, **summary(steps), "max_slope_deg_unowned": float(slope[~owned].max())}
    record["features"] = {k: summary(steps[kinds == k]) for k in np.unique(kinds)}
    return record, final, owned


def load_exported(directory, name, key=None):
    """An exported HEGo field: <name>.rf32 row-major [y][x] + <name>.json basis."""
    meta = json.load(open(os.path.join(directory, name + ".json")))
    width, height = meta["resolution"]
    data = np.fromfile(os.path.join(directory, name + ".rf32"), dtype="<f4").reshape(height, width)
    return field(key or name, meta["name"], data, tuple(meta["sample_origin"]), tuple(meta["sample_step_x"]),
                 tuple(meta["sample_step_y"]), {k: v for k, v in meta["attrs"].items() if k != "hegostrata_layer_path"})


def crop_detail(f, half=256.0):
    """Crop a Houdini-layout (index0 +Z, index1 +X) 2 m field to the pad +-half metres."""
    o, s0, s1 = np.array(f["origin"]), np.array(f["step0"]), np.array(f["step1"])
    if not (s0[2] > 0 and s1[0] > 0 and s0[0] == 0 and s1[2] == 0):
        raise RuntimeError(f"unexpected detail basis {s0} {s1}")
    i1 = int(round((PAD[0] - half - o[0]) / s1[0])); i0 = int(round((PAD[1] - half - o[2]) / s0[2]))
    n = int(round(2 * half / s0[2])) + 1
    data = f["data"][i1:i1 + n, i0:i0 + n]
    origin = (o[0] + i1 * s1[0], 0.0, o[2] + i0 * s0[2])
    return field(f["key"], f["name"], np.ascontiguousarray(data), origin, f["step0"], f["step1"], f["attrs"])


def image_zx_field(f):
    """[z][x] image of an exported field with axis-aligned positive steps."""
    s0, s1 = f["step0"], f["step1"]
    if s0[0] > 0 and s1[2] > 0:
        return f["data"], f["origin"][0] + np.arange(f["data"].shape[1]) * s0[0], f["origin"][2] + np.arange(f["data"].shape[0]) * s1[2]
    if s0[2] > 0 and s1[0] > 0:
        return f["data"].T, f["origin"][0] + np.arange(f["data"].shape[0]) * s1[0], f["origin"][2] + np.arange(f["data"].shape[1]) * s0[2]
    raise RuntimeError("unsupported basis")


def run_actual(s, hou, args):
    """Transition on the actual saved Bracken Isle fields (read-only exports)."""
    d = args.actual
    detail = crop_detail(load_exported(d, "detail_height", "det"))
    raw = [load_exported(d, n, k) for n, k in (("building_height", "bh"), ("building_height__ownership", "bho"),
                                                 ("building_constraint", "bc"), ("building_constraint__ownership", "bco"))]
    manual_value, mx, mz = image_zx_field(raw[0])
    manual_owned = image_zx_field(raw[1])[0] >= 0.5
    saved, xs, zs = image_zx_field(detail)
    saved = saved.astype(np.float64)
    report = {"inputs": d, "owned_samples": int(manual_owned.sum()), "detail_crop_origin": detail["origin"]}
    source = s.loader("actual_detail", [detail])
    raw_node = s.loader("actual_raw", raw)
    exact = dict(DETAIL, freeze_frame=1)
    # erosion_strength 0 reproduces the saved eroded field exactly, so this applies only the transition.
    out, details, _ = s.cook(s.hda("actual_on", source, raw_node, erosion_strength=0.0, **exact))
    off, _, _ = s.cook(s.hda("actual_off", source, raw_node, erosion_strength=0.0, manual_transition=0, **exact))
    after, before = height_zx(out), height_zx(off)
    report["saved_reproduced_exactly_when_off"] = bool(np.array_equal(before, saved.astype(np.float32).astype(np.float64)))
    report["transition"] = {k.replace("hego_island_transition_", ""): v for k, v in details.items() if k.startswith("hego_island_transition_")}
    changed = after != before
    zi, xi = np.nonzero(changed)
    if zi.size:
        report["changed_extent_m"] = {"x": [float(xs[xi.min()]), float(xs[xi.max()])], "z": [float(zs[zi.min()]), float(zs[zi.max()])],
                                      "max_radius_from_pad_m": float(np.hypot(xs[xi] - PAD[0], zs[zi] - PAD[1]).max())}
    report["max_abs_change_m"] = float(np.abs(after - before).max())
    globals()["OUT_SPACING"] = float(xs[1] - xs[0])
    for label, h in (("saved_before", before), ("transition_after", after)):
        for step in (1.0, 0.25):
            m, final, _ = runtime_metrics(h, xs, zs, manual_value, manual_owned, mx, mz, label, step, window=48.0)
            m.pop("features", None)
            report[f"{label}@{step}m"] = m
            log(f"  {label}@{step}m: " + json.dumps(m))
            if step == 0.25:
                np.save(os.path.join(args.out_dir, f"actual_runtime_{label}.npy"), final.astype(np.float32))
    # Radial profile of the composed 0.25 m surface (pad +-48 m) for the evidence record.
    profiles = {}
    for angle in range(0, 360, 45):
        rs = np.arange(20.0, 46.0, 1.0)
        ix = np.rint((PAD[0] + rs * math.cos(math.radians(angle)) - PAD[0] + 48.0) / 0.25).astype(int)
        iz = np.rint((PAD[1] + rs * math.sin(math.radians(angle)) - PAD[1] + 48.0) / 0.25).astype(int)
        b = np.load(os.path.join(args.out_dir, "actual_runtime_saved_before.npy"))
        a = np.load(os.path.join(args.out_dir, "actual_runtime_transition_after.npy"))
        profiles[str(angle)] = {"r": rs.tolist(), "before": b[iz, ix].round(2).tolist(), "after": a[iz, ix].round(2).tolist()}
    report["radial_profiles"] = profiles
    # Hand-off: the transition-applied 2 m crop, Houdini layout like the saved field.
    out_dir = os.path.join(args.out_dir, "actual-results")
    os.makedirs(out_dir, exist_ok=True)
    out["height"]["data"].astype("<f4").tofile(os.path.join(out_dir, "transition_height_crop.rf32"))
    with open(os.path.join(out_dir, "transition_height_crop.json"), "w") as handle:
        json.dump(dict(builder._grid_record(out["height"]), encoding="little-endian float32 row-major [index1][index0]"), handle, indent=2)

    if os.path.exists(os.path.join(d, "manual_fine_cumulative.json")):
        # Genuine detail erosion of the actual cumulative ManualFine crop (edges of the crop
        # erode differently from the 4 km cook; only the transition contrast is evaluated).
        fine = s.loader("actual_fine", [load_exported(d, "manual_fine_cumulative", "mf")])
        e_on, e_d, _ = s.cook(s.hda("actual_erode_on", fine, raw_node, erosion_strength=1.0, **DETAIL))
        e_off, _, _ = s.cook(s.hda("actual_erode_off", fine, raw_node, erosion_strength=1.0, manual_transition=0, **DETAIL))
        for label, h in (("crop_erosion_constraint_only", height_zx(e_off)), ("crop_erosion_transition", height_zx(e_on))):
            for step in (1.0, 0.25):
                m, _, _ = runtime_metrics(h, xs, zs, manual_value, manual_owned, mx, mz, label, step, window=48.0)
                m.pop("features", None)
                report[f"{label}@{step}m"] = m
                log(f"  {label}@{step}m: " + json.dumps(m))
        report["crop_erosion_transition"] = {k.replace("hego_island_transition_", ""): v for k, v in e_d.items() if k.startswith("hego_island_transition_")}
        far = ~((np.abs(xs[None, :] - PAD[0]) < 30 + WIDTH + 4) & (np.abs(zs[:, None] - PAD[1]) < 30 + WIDTH + 4))
        report["crop_erosion_far_bit_identical"] = bool(np.array_equal(height_zx(e_on)[far], height_zx(e_off)[far]))
    with open(os.path.join(args.out_dir, "transition-actual.json"), "w") as handle:
        json.dump(report, handle, indent=2, default=str)
    log("[actual] " + json.dumps({k: v for k, v in report.items() if k != "radial_profiles"}, default=str)[:3000])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hda", default=builder.HDA_PATH)
    parser.add_argument("--out-dir", default="/tmp/hego-terrain-prototype/shading-transition")
    parser.add_argument("--baseline-out", help="Cook only the old-HDA-compatible reference cases and save them.")
    parser.add_argument("--baseline", help="Reference .npz written by --baseline-out with the previous HDA.")
    parser.add_argument("--perf", action="store_true", help="Time the transition on a 2049^2 detail-sized output.")
    parser.add_argument("--actual", help="Directory of exported actual fields (detail_height, building_*, manual_fine_cumulative).")
    args = parser.parse_args()
    os.makedirs(os.path.join(args.out_dir, "fixtures"), exist_ok=True)

    import hou

    s = Session(hou, args.hda, args.out_dir)
    source = s.loader("input", input_fields())
    raw_constraint = s.loader("raw_constraint", raw_fields(height=False, constraint=True))

    if args.actual:
        run_actual(s, hou, args)
        hou.hipFile.clear(suppress_save_prompt=True)
        return

    if args.perf:
        # Detail-sized 2049^2 @ 2 m output (4 km), 0.25 m raw over 400 m with 40 flattened
        # footprints; freeze_frame 1 so the erode node costs little and the transition dominates.
        n = 513
        xs8 = -2048.0 + np.arange(n) * 8.0
        X8, Z8 = np.meshgrid(xs8, xs8)
        island = s.loader("perf_input", [oriented("in", "height", base_height(X8, Z8).astype(np.float32), xs8, xs8, "hego")])
        rng = np.random.default_rng(5)
        rx = PAD[0] - 200.0 + np.arange(1601) * 0.25
        rz = PAD[1] - 200.0 + np.arange(1601) * 0.25
        RX, RZ = np.meshgrid(rx, rz)
        value, owned = np.zeros(RX.shape, np.float32), np.zeros(RX.shape, bool)
        for _ in range(40):
            cx, cz, radius = PAD[0] + rng.uniform(-170, 170), PAD[1] + rng.uniform(-170, 170), rng.uniform(8.0, 30.0)
            r = np.hypot(RX - cx, RZ - cz)
            disc = r < radius
            blend = np.clip(8.0 * (1.0 - smoothstep01(r / radius)), 0.0, 1.0)
            flat = float(old_surface(np.array(cx), np.array(cz))) + 1.0
            value = np.where(disc, old_surface(RX, RZ) * (1 - blend) + flat * blend, value).astype(np.float32)
            owned |= disc
        attrs = {"hegostrata_snapshot_mode": "raw", "hegostrata_composition": "replace"}
        raw = s.loader("perf_raw", [oriented("h", "height", value, rx, rz, "hego", attrs),
                                    oriented("ho", "height__ownership", owned.astype(np.float32), rx, rz, "hego", {"hegostrata_role": "ownership"})])
        perf = {"owned_raw_samples": int(owned.sum()), "raw_samples": int(owned.size)}
        for label, enabled in (("perf_off", 0), ("perf_on", 1)):
            start = time.time()
            out, details, _ = s.cook(s.hda(label, island, raw, erosion_strength=0.0, manual_transition=enabled,
                                           **dict(DETAIL, freeze_frame=1)))
            perf[label] = {"hda_seconds": round(time.time() - start, 2), "grid": list(out["height"]["res"]),
                           **{k.replace("hego_island_transition_", ""): v for k, v in details.items() if k.startswith("hego_island_transition_")}}
            log(f"[perf] {label}: {perf[label]}")
        with open(os.path.join(args.out_dir, "transition-perf.json"), "w") as handle:
            json.dump(perf, handle, indent=2, default=str)
        hou.hipFile.clear(suppress_save_prompt=True)
        return

    if args.baseline_out:
        ref = {}
        for label, raw, strength in (("free_s0", None, 0.0), ("free_s1", None, 1.0), ("constraint_s1", raw_constraint, 1.0)):
            out, _, _ = s.cook(s.hda(label, source, raw, erosion_strength=strength, **DETAIL))
            for name, volume in out.items():
                ref[f"{label}/{name}"] = volume["data"]
        np.savez(args.baseline_out, **ref)
        log(f"[baseline] wrote {args.baseline_out}")
        hou.hipFile.clear(suppress_save_prompt=True)
        return

    results, metrics = {}, {"hda": args.hda, "houdini": hou.applicationVersionString()}
    xs, zs = output_axes()
    rx, rz = raw_lattice(RAW_SPACING)
    RX, RZ = np.meshgrid(rx, rz)
    manual_value, manual_owned = manual_world(RX, RZ)

    log("[check] interface metadata")
    contract = json.load(open(os.path.join(REPO, "demo", "island", "hda", "contract.json")))
    templates = {t.name(): t for t in s.definition.parmTemplateGroup().entries()}
    for folder in [t for t in templates.values() if t.type() == hou.parmTemplateType.Folder]:
        templates.update({t.name(): t for t in folder.parmTemplates()})
    kinds = {hou.parmTemplateType.Toggle: "toggle", hou.parmTemplateType.Int: "int",
             hou.parmTemplateType.Float: "float", hou.parmTemplateType.String: "string"}
    mismatches = []
    for name, spec in contract["parameters"].items():
        t = templates.get(name)
        if t is None:
            mismatches.append(f"{name} missing"); continue
        kind = kinds.get(t.type())
        default = t.defaultValue() if kind == "toggle" else t.defaultValue()[0]
        if kind != spec["type"] or (default != spec["default"] and not (kind == "toggle" and int(default) == spec["default"])):
            mismatches.append(f"{name}: hda {kind}={default!r} contract {spec['type']}={spec['default']!r}")
        if "range" in spec and kind in ("int", "float") and [t.minValue(), t.maxValue()] != spec["range"]:
            mismatches.append(f"{name}: range hda {[t.minValue(), t.maxValue()]} contract {spec['range']}")
    extra = sorted(set(n for n, t in templates.items() if t.type() != hou.parmTemplateType.Folder) - set(contract["parameters"]))
    check(not mismatches and not extra, f"{mismatches} extra={extra}", results, "contract_parameters_match_hda")
    for preset in ("coarse", "detail"):
        unknown = [k for k in contract["caller_presets"][preset] if k in templates and k not in contract["parameters"]]
        check(not unknown, str(unknown), results, f"caller_preset_{preset}_keys_known")
    check(contract["caller_presets"]["coarse"]["manual_transition"] == 0 and contract["caller_presets"]["detail"]["manual_transition"] == 1
          and contract["caller_presets"]["detail"]["manual_transition_width"] == WIDTH, "preset values", results, "caller_presets_transition")

    log("[check] identity when disabled or absent (zero-erosion)")
    free, free_d, _ = s.cook(s.hda("free_s0", source, erosion_strength=0.0, **DETAIL))
    resampled = height_zx(free)
    # Coincident 4 m input centres are reproduced exactly by the resample.
    X4, Z4 = np.meshgrid(xs[::2], zs[::2])
    check(np.array_equal(resampled[::2, ::2], base_height(X4, Z4).astype(np.float32).astype(np.float64)),
          "resample not exact at input centres", results, "zero_erosion_identity_at_input_centres")
    check(free_d["hego_island_transition_status"] == "no_raw_input", free_d["hego_island_transition_status"], results, "status_no_raw_input")
    raw_a = raw_fields("hego")
    raw_a_node = s.loader("raw_hego", raw_a)
    cases = {
        "off_with_height": (raw_a_node, {"manual_transition": 0}, "disabled"),
        "constraint_only": (raw_constraint, {}, "no_target_channel"),
        "height_without_ownership": (s.loader("raw_no_owner", raw_fields(ownership=False)), {}, "ignored_no_ownership"),
        "compact_empty_height": (s.loader("raw_compact_empty", raw_fields(compact_empty=True)), {}, "no_owned_samples"),
        "other_channel_name": (raw_a_node, {"manual_height_channel": "target"}, "no_target_channel"),
    }
    free_bytes = channel_bytes(free)
    for label, (raw, parms, status) in cases.items():
        out, details, warnings = s.cook(s.hda(label, source, raw, erosion_strength=0.0, **DETAIL, **parms))
        check(channel_bytes(out) == free_bytes, "output differs from the no-raw-input result", results, f"identity_{label}")
        check(details["hego_island_transition_status"] == status, details["hego_island_transition_status"], results, f"status_{label}")
        if label == "height_without_ownership":
            check(any("__ownership" in w for w in warnings), str(warnings), results, "warning_height_without_ownership")

    log("[check] invalid manual targets are explicit errors")
    for label, attrs in (("add_composition", {"hegostrata_composition": "add"}), ("cumulative_snapshot", {"hegostrata_snapshot_mode": "cumulative"})):
        errors = s.cook(s.hda(label, source, s.loader("raw_" + label, raw_fields(attrs=attrs)), erosion_strength=0.0, **DETAIL), expect_error=True)
        check(any("manual target" in e for e in errors), str(errors), results, f"error_{label}")

    log("[check] enabled transition on the zero-erosion fixture")
    on, on_d, _ = s.cook(s.hda("on_s0", source, raw_a_node, erosion_strength=0.0, **DETAIL))
    on_h = height_zx(on)
    anchor, target = reference_target(raw_a, xs, zs)
    dist = anchor_distance(anchor, OUT_SPACING)
    check(int(on_d["hego_island_transition_anchor_samples"]) == int(anchor.sum()), f"{on_d['hego_island_transition_anchor_samples']} vs {anchor.sum()}",
          results, "anchor_count_matches_reference")
    interior = interior_of(anchor)
    fitted = (anchor & ~interior) | (~anchor & (dist <= math.hypot(OUT_SPACING, OUT_SPACING) + 1e-9))
    check(np.array_equal(on_h[interior], target[interior].astype(np.float32).astype(np.float64)), "interior anchor heights differ",
          results, "interior_anchors_equal_manual_target")
    check(int(on_d["hego_island_transition_fitted_samples"]) == int(fitted.sum()), f"{on_d['hego_island_transition_fitted_samples']} vs {fitted.sum()}",
          results, "fitted_ring_is_edge_straddling_nodes")
    zero_cells = anchor & (target == 0.0)
    check(zero_cells.sum() >= 25 and np.all(on_h[zero_cells] == 0.0) and np.all(resampled[zero_cells] > 40.0),
          f"{zero_cells.sum()} owned-zero anchors", results, "owned_zero_pulls_to_zero")
    far = dist >= WIDTH
    check(np.array_equal(on_h[far], resampled[far]), "terrain beyond the band changed", results, "beyond_width_bit_identical")
    band = ~anchor & (dist < WIDTH)
    check(int(on_d["hego_island_transition_band_samples"]) == int(band.sum()), f"{on_d['hego_island_transition_band_samples']} vs {band.sum()}",
          results, "band_matches_reference_distance")
    sparse_xz = (PAD[0] - 90.25, PAD[1] - 60.75)
    near_off = (np.abs(xs[None, :] - sparse_xz[0]) < 3) & (np.abs(zs[:, None] - sparse_xz[1]) < 3)
    check(np.array_equal(on_h[near_off & far], resampled[near_off & far]) and not anchor[near_off].any(),
          "off-centre single sample changed terrain", results, "subgrid_sample_without_centre_is_ignored")
    node_ix, node_iz = int(round((PAD[0] + 64 - xs[0]) / OUT_SPACING)), int(round((PAD[1] - 40 - zs[0]) / OUT_SPACING))
    check(anchor[node_iz, node_ix] and on_h[node_iz, node_ix] == np.float32(base_height(xs[node_ix], zs[node_iz]) + 5.0),
          "on-centre sparse sample", results, "sparse_sample_on_centre_anchors")
    correction = on_h - resampled
    fixed = anchor | fitted
    check(np.abs(correction[band & ~fixed]).max() <= np.abs(correction[fixed]).max() + 1e-4, "overshoot", results,
          "band_correction_bounded_by_fixed_discrepancy")
    check(on_d["hego_island_transition_relax_residual_m"] < 1e-3, str(on_d["hego_island_transition_relax_residual_m"]), results, "harmonic_extension_converged")
    nonband = ~(anchor | band)
    check(np.array_equal(on_h[nonband], resampled[nonband]), "changed outside anchors+band", results, "support_is_anchors_plus_band")
    metrics["fixture_zero_erosion"] = {k.replace("hego_island_transition_", ""): v for k, v in on_d.items() if k.startswith("hego_island_transition_")}

    log("[check] raw orientation, origin height and resolution independence")
    # The edge fit sums in float64 in lattice order, so other bases may differ in the last float32 bit.
    for layout, y in (("houdini", 0.0), ("flipped", 37.5)):
        out, _, _ = s.cook(s.hda("on_" + layout, source, s.loader("raw_" + layout, raw_fields(layout, y=y)), erosion_strength=0.0, **DETAIL))
        diff = np.abs(height_zx(out) - on_h)
        metrics[f"orientation_{layout}"] = {"max_abs_m": float(diff.max()), "bit_identical_fraction": float((diff == 0).mean())}
        check(diff.max() <= 1e-5 and np.array_equal(height_zx(out)[interior], on_h[interior]), f"{layout} differs by {diff.max()}",
              results, f"orientation_{layout}_equivalent")
    half = s.loader("raw_half", raw_fields(spacing=0.5))
    out, _, _ = s.cook(s.hda("on_half", source, half, erosion_strength=0.0, **DETAIL))
    diff = np.abs(height_zx(out) - on_h)
    metrics["raw_0p5m_vs_0p25m_max_abs_m"] = float(diff.max())
    # A 0.5 m raw lattice moves the ownership edge by up to 0.25 m: the fitted ring (and the
    # band it drives) may differ slightly; interior anchors and distant terrain may not.
    check(np.array_equal(height_zx(out)[interior], on_h[interior]) and np.array_equal(diff[far], np.zeros(int(far.sum())))
          and diff.max() < 1.0, f"0.5 m raw differs by {diff.max()}", results, "raw_0p5m_consistent")
    coarse_raw = raw_fields(spacing=3.0, offset=(0.37, -1.1))
    out, d3, _ = s.cook(s.hda("on_3m", source, s.loader("raw_3m", coarse_raw), erosion_strength=0.0, **DETAIL))
    anchor3, target3 = reference_target(coarse_raw, xs, zs)
    h3 = height_zx(out)
    inner3 = interior_of(anchor3)
    check(int(d3["hego_island_transition_anchor_samples"]) == int(anchor3.sum()) and np.abs(h3[inner3] - target3[inner3]).max() < 1e-4,
          f"{d3['hego_island_transition_anchor_samples']} vs {anchor3.sum()}", results, "raw_3m_offset_bilinear_coverage")
    metrics["raw_3m_interior_anchor_max_err"] = float(np.abs(h3[inner3] - target3[inner3]).max())

    log("[check] width bound and parameter dependency (no forced recook)")
    narrow = s.hda("on_w16", source, raw_a_node, erosion_strength=0.0, manual_transition_width=16.0, **DETAIL)
    out16, d16, _ = s.cook(narrow)
    h16 = height_zx(out16)
    check(np.array_equal(h16[dist >= 16.0], resampled[dist >= 16.0]) and np.array_equal(h16[anchor], on_h[anchor]),
          "width 16", results, "width16_bounded")
    narrow.parm("manual_transition_width").set(WIDTH)
    narrow.cook()
    check(np.array_equal(height_zx(builder._volume_arrays(narrow.geometry())), on_h), "width change did not recook", results, "width_parm_dependency")
    narrow.parm("manual_transition").set(0)
    narrow.cook()
    check(np.array_equal(height_zx(builder._volume_arrays(narrow.geometry())), resampled), "toggle did not recook", results, "toggle_parm_dependency")

    log("[check] genuine detail erosion (small grid)")
    free1, _, _ = s.cook(s.hda("free_s1", source, erosion_strength=1.0, **DETAIL))
    e1 = height_zx(free1)
    check(np.abs(e1 - resampled).max() > 1.0, "erosion did nothing", results, "erosion_active")
    off1, _, _ = s.cook(s.hda("off_s1", source, raw_a_node, erosion_strength=1.0, manual_transition=0, **DETAIL))
    check(channel_bytes(off1) == channel_bytes(free1), "disabled differs from no raw input", results, "disabled_equals_free_erosion")
    con1, _, _ = s.cook(s.hda("constraint_s1", source, raw_constraint, erosion_strength=1.0, **DETAIL))
    raw_both = s.loader("raw_both", raw_fields(constraint=True))
    on1, on1_d, _ = s.cook(s.hda("on_s1", source, raw_both, erosion_strength=1.0, **DETAIL))
    h1, c1 = height_zx(on1), height_zx(con1)
    check(np.array_equal(h1[dist >= WIDTH], c1[dist >= WIDTH]), "eroded terrain beyond band changed", results, "eroded_beyond_width_bit_identical")
    check(np.array_equal(h1[interior], target[interior].astype(np.float32).astype(np.float64)), "eroded anchors", results,
          "eroded_interior_anchors_equal_manual_target")
    mask_far = builder._image_zx(on1["rock"]) == builder._image_zx(con1["rock"])
    mxs = xs[::2]; mzs = zs[::2]
    mdist = dist[::2, ::2]
    check(bool(np.all(mask_far[mdist >= WIDTH + 4.0])), "masks changed beyond band + mask stride", results, "masks_beyond_width_identical")
    if args.baseline:
        ref = np.load(args.baseline)
        for label, out in (("free_s0", free), ("free_s1", free1), ("constraint_s1", con1)):
            same = all(np.array_equal(ref[f"{label}/{name}"], out[name]["data"]) for name in out)
            check(same, "differs from previous HDA", results, f"previous_hda_bitwise_{label}")
        metrics["baseline"] = args.baseline

    log("[metrics] emulated runtime composition (2 m HDA -> 1 m and 0.25 m lattice + 0.25 m manual Replace)")
    runtime = {}
    for label, h in (("zero_erosion_off", resampled), ("zero_erosion_on", on_h), ("eroded_constraint_only", c1), ("eroded_on", h1)):
        for step in (1.0, 0.25):
            m, final, owned = runtime_metrics(h, xs, zs, manual_value, manual_owned, rx, rz, label, step)
            runtime[f"{label}@{step}m"] = m
            log(f"  {label}@{step}m: " + json.dumps(m))
            if step == 0.25:
                np.save(os.path.join(args.out_dir, f"runtime_{label}.npy"), final.astype(np.float32))
    metrics["runtime"] = runtime
    for prefix in ("zero_erosion", "eroded"):
        for step in (1.0, 0.25):
            off_key = (f"{prefix}_off" if prefix == "zero_erosion" else "eroded_constraint_only") + f"@{step}m"
            for feature in ("house_disc", "walkway", "owned_zero_pad"):
                before, after = runtime[off_key]["features"][feature], runtime[f"{prefix}_on@{step}m"]["features"][feature]
                check(after["mean_step_m"] < 0.2 * before["mean_step_m"] and after["p95_step_m"] < 0.3 * before["p95_step_m"]
                      and after["max_step_m"] <= before["max_step_m"], json.dumps([before, after]), results,
                      f"runtime_steps_reduced_{prefix}_{feature}@{step}m")
    metrics["eroded_on"] = {k.replace("hego_island_transition_", ""): v for k, v in on1_d.items() if k.startswith("hego_island_transition_")}

    # Radial profiles through the falloff edge for the evidence record.
    profiles = {}
    final_on = np.load(os.path.join(args.out_dir, "runtime_eroded_on.npy"))
    final_off = np.load(os.path.join(args.out_dir, "runtime_eroded_constraint_only.npy"))
    for angle in (0, 90, 135, 225, 315):
        rs = np.arange(24.0, 66.0, 2.0)
        px = PAD[0] + rs * math.cos(math.radians(angle)); pz = PAD[1] + rs * math.sin(math.radians(angle))
        ix = np.rint((px - PAD[0] + 72.0) / 0.25).astype(int); iz = np.rint((pz - PAD[1] + 72.0) / 0.25).astype(int)
        profiles[str(angle)] = {"r": rs.tolist(), "off": final_off[iz, ix].round(2).tolist(), "on": final_on[iz, ix].round(2).tolist()}
    metrics["radial_profiles_eroded"] = profiles
    metrics["results"] = results
    with open(os.path.join(args.out_dir, "transition-metrics.json"), "w") as handle:
        json.dump(metrics, handle, indent=2, default=str)
    log(f"[done] {sum(results.values())}/{len(results)} checks passed; metrics {os.path.join(args.out_dir, 'transition-metrics.json')}")
    hou.hipFile.clear(suppress_save_prompt=True)


if __name__ == "__main__":
    main()
