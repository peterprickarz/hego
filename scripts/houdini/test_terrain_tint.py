#!/usr/bin/env hython
"""Regression for Sop/HEGo_TerrainTint (loads only the saved .hda).

  hython scripts/houdini/test_terrain_tint.py [--hda PATH] [--out-dir DIR] [--actual RF32]

Synthetic fixtures check neutrality, routing, exact lattice reuse, ranges,
ridge/cavity behaviour (no double cavity darkening), orientation invariance,
world-space (lattice independent) variation, physical radii, determinism and
errors. --actual cooks an exported final-height .rf32 (+ .json: resolution,
sample_origin, sample_step_x, sample_step_y) such as the saved 4 km island at
4 m and writes previews/metrics. Any failed check raises.
"""

import argparse
import json
import os
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
sys.dont_write_bytecode = True

import numpy as np  # noqa: E402

import build_tint_hda as builder  # noqa: E402

LOAD_PY = r"""
# Explicitly based 2D volumes from an .npz: data[index1][index0], sample at
# origin + i0 * step0 + i1 * step1 (any orthogonal horizontal basis).
import json
import numpy as np
node = hou.pwd()
geo = node.geometry()
geo.clear()
archive = np.load(node.parm("npz").evalAsString(), allow_pickle=False)
meta = json.loads(str(archive["meta"]))
geo.addAttrib(hou.attribType.Prim, "name", "")
geo.addAttrib(hou.attribType.Prim, "hegostrata_snapshot_mode", "")
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
    vol.setAttribValue("hegostrata_snapshot_mode", "cumulative")
    vol.setAllVoxelsFromString(data.tobytes())
"""

ROUTE_ATTRS = {"name", "hegostrata_layer_path", "hegostrata_role", "hegostrata_channel", "hegostrata_composition"}
FAILURES = []
CHECKS = [0]


def check(condition, message):
    CHECKS[0] += 1
    print(("  ok   " if condition else "  FAIL ") + message, flush=True)
    if not condition:
        FAILURES.append(message)


class Session:
    def __init__(self, hou, hda, work):
        self.hou, self.work = hou, work
        hou.hipFile.clear(suppress_save_prompt=True)
        hou.hda.installFile(hda)
        self.geo = hou.node("/obj").createNode("geo", "tint_test")
        self.count = 0

    def load(self, fields):
        """fields: list of (name, data[index1][index0], origin, step0, step1)."""
        self.count += 1
        path = os.path.join(self.work, f"fixture_{self.count}.npz")
        meta = {"fields": []}
        arrays = {}
        for index, (name, data, origin, step0, step1) in enumerate(fields):
            key = f"f{index}"
            arrays[key] = np.asarray(data, dtype=np.float32)
            meta["fields"].append({"key": key, "name": name, "origin": list(origin), "step0": list(step0), "step1": list(step1)})
        np.savez(path, meta=json.dumps(meta), **arrays)
        node = self.geo.createNode("python", f"load_{self.count}")
        group = node.parmTemplateGroup()
        group.append(self.hou.StringParmTemplate("npz", "npz", 1))
        node.setParmTemplateGroup(group)
        node.parm("npz").set(path)
        node.parm("python").set(LOAD_PY)
        return node

    def tint(self, source, **parms):
        node = self.geo.createNode(builder.OPERATOR.split("::")[0], f"tint_{self.count}")
        node.setInput(0, source)
        node.parm("target_layer_path").set(parms.pop("target_layer_path", "../../Terrain/TerrainTint"))
        for key, value in parms.items():
            node.parm(key).set(value)
        return node


def cook(node):
    started = time.time()
    node.cook(force=True)
    return time.time() - started


def outputs(node):
    geo = node.geometry()
    result = {}
    for prim in geo.prims():
        res = prim.resolution()
        origin = np.array(prim.indexToPos((0, 0, 0)))
        result[prim.attribValue("name")] = {
            "data": np.frombuffer(prim.allVoxelsAsString(), dtype="<f4").reshape(res[1], res[0]).astype(np.float64),
            "res": (res[0], res[1]), "origin": origin,
            "step0": np.array(prim.indexToPos((1, 0, 0))) - origin, "step1": np.array(prim.indexToPos((0, 1, 0))) - origin,
            "attrs": {a.name(): prim.attribValue(a) for a in geo.primAttribs()},
        }
    result["_detail"] = {a.name(): geo.attribValue(a) for a in geo.globalAttribs()}
    return result


def _unlocked_bad(node, name, expression):
    """Bypass the interface clamps the way an unchecked HAPI value could."""
    node.allowEditingOfContents()
    node.node("tint").parm(name).setExpression(expression, node.hou_language if hasattr(node, "hou_language") else None) if False else node.node("tint").parm(name).setExpression(expression)
    return node


def grid(n0, n1, origin, step0, step1):
    i0, i1 = np.meshgrid(np.arange(n0), np.arange(n1), indexing="xy")  # [index1][index0]
    x = origin[0] + i0 * step0[0] + i1 * step1[0]
    z = origin[2] + i0 * step0[2] + i1 * step1[2]
    return x, z


def terrain(x, z):
    hill = 70.0 * np.exp(-((x - 120.0) ** 2 + (z + 60.0) ** 2) / (2 * 70.0 ** 2))
    bowl = -40.0 * np.exp(-((x + 150.0) ** 2 + (z - 90.0) ** 2) / (2 * 55.0 ** 2))
    return 12.0 + hill + bowl + 3.0 * np.sin(x / 37.0) * np.cos(z / 53.0)


def sample_world(field, x, z):
    """Value of an output field at world points that are exact lattice samples."""
    o, a, b = field["origin"], field["step0"], field["step1"]
    i0 = np.rint(((x - o[0]) * a[0] + (z - o[2]) * a[2]) / np.dot(a, a)).astype(int)
    i1 = np.rint(((x - o[0]) * b[0] + (z - o[2]) * b[2]) / np.dot(b, b)).astype(int)
    return field["data"][i1, i0]


def run(hou, args):
    os.makedirs(args.out_dir, exist_ok=True)
    session = Session(hou, args.hda, args.out_dir)
    metrics = {}
    up = (0.0, 0.0, 4.0)
    right = (4.0, 0.0, 0.0)

    print("[1] flat terrain neutrality, routing, lattice reuse", flush=True)
    flat = np.full((65, 65), 5.0)
    node = session.tint(session.load([("height", flat, (-128.0, 0.0, -128.0), right, up),
                                      ("height__ownership", np.ones((65, 65)), (-128.0, 0.0, -128.0), right, up)]),
                        variation_strength=0.0)
    cook(node)
    out = outputs(node)
    check(set(out) - {"_detail"} == set(builder.CHANNELS), f"exactly the four macro channels: {sorted(out)}")
    check(all(np.all(out[c]["data"] == 1.0) for c in builder.CHANNELS), "flat terrain without variation is exactly neutral")
    for name in builder.CHANNELS:
        field = out[name]
        check(set(field["attrs"]) == ROUTE_ATTRS, f"{name}: only routing attributes survive ({sorted(field['attrs'])})")
        check(field["attrs"]["hegostrata_layer_path"] == "../../Terrain/TerrainTint" and field["attrs"]["hegostrata_channel"] == name
              and field["attrs"]["hegostrata_role"] == "value" and field["attrs"]["hegostrata_composition"] == "replace", f"{name}: routed as a replace value")
        check(field["res"] == (65, 65) and np.allclose(field["origin"], (-128, 0, -128)) and np.allclose(field["step0"], right) and np.allclose(field["step1"], up), f"{name}: exactly the input lattice")
    check(out["_detail"].get("hego_tint_operator") == "Sop/" + builder.OPERATOR, "diagnostic operator attribute")
    node = session.tint(session.load([("height", flat, (-128.0, 0.0, -128.0), right, up)]))
    cook(node)
    out = outputs(node)
    check(np.all(out["terrain_ao"]["data"] == 1.0), "flat terrain has no occlusion with variation on")
    g = out["terrain_tint_g"]["data"]
    check(g.min() >= 0.94 - 1e-6 and g.max() <= 1.06 + 1e-6 and g.std() > 1e-3, f"default variation is subtle but present (g {g.min():.4f}..{g.max():.4f})")

    print("[2] ridge highlight, cavity AO, no double cavity darkening", flush=True)
    x, z = grid(129, 129, (-256.0, 0.0, -256.0), right, up)
    h = terrain(x, z)
    node = session.tint(session.load([("height", h, (-256.0, 0.0, -256.0), right, up)]), variation_strength=0.0)
    seconds = cook(node)
    out = outputs(node)
    top = (np.abs(x - 120.0) < 2) & (np.abs(z + 60.0) < 2)
    pit = (np.abs(x + 152.0) < 2) & (np.abs(z - 88.0) < 2)
    tint_r, ao = out["terrain_tint_r"]["data"], out["terrain_ao"]["data"]
    check(tint_r[top].min() > 1.08 and ao[top].min() == 1.0, f"hill crest is brightened ({tint_r[top].min():.3f}) and unoccluded")
    check(ao[pit].max() < 0.75 and tint_r[pit].min() == 1.0, f"bowl floor is occluded ({ao[pit].max():.3f}) and its tint is not darkened")
    check(tint_r.min() >= 1.0, "with variation off the tint never darkens anywhere (cavities darken only via AO)")
    check(np.all(out["terrain_tint_r"]["data"] == out["terrain_tint_b"]["data"]), "no warm/cool shift without variation")
    check(ao.min() >= 1.0 - 0.45 - 1e-6 and ao.max() <= 1.0, "AO bounded by ao_strength")
    metrics["fixture_129_seconds"] = seconds

    print("[3] orientation invariance (transposed + flipped basis)", flush=True)
    n0, n1 = 129, 129
    origin_b = (-256.0, 0.0, 256.0)
    step0_b, step1_b = (0.0, 0.0, -4.0), (4.0, 0.0, 0.0)
    xb, zb = grid(n0, n1, origin_b, step0_b, step1_b)
    node_b = session.tint(session.load([("height", terrain(xb, zb), origin_b, step0_b, step1_b)]))
    node_a = session.tint(session.load([("height", h, (-256.0, 0.0, -256.0), right, up)]))
    cook(node_a); cook(node_b)
    out_a, out_b = outputs(node_a), outputs(node_b)
    worst = max(float(np.abs(sample_world(out_b[c], x, z) - out_a[c]["data"]).max()) for c in builder.CHANNELS)
    check(worst < 2e-5, f"same world terrain in another orientation gives the same values (max {worst:.2e})")
    check(np.allclose(out_b["terrain_ao"]["step0"], step0_b) and np.allclose(out_b["terrain_ao"]["origin"], origin_b), "transposed outputs keep the transposed input lattice")

    print("[4] world-space variation independent of lattice origin/spacing", flush=True)
    xa, za = grid(65, 65, (-128.0, 0.0, -128.0), right, up)
    flat_a = session.tint(session.load([("height", np.full((65, 65), 3.0), (-128.0, 0.0, -128.0), right, up)]))
    xs, zs = grid(97, 97, (-64.0, 0.0, -64.0), (2.0, 0, 0), (0, 0, 2.0))
    flat_b = session.tint(session.load([("height", np.full((97, 97), 3.0), (-64.0, 0.0, -64.0), (2.0, 0, 0), (0, 0, 2.0))]))
    cook(flat_a); cook(flat_b)
    oa, ob = outputs(flat_a), outputs(flat_b)
    inside = (xa >= -64) & (xa <= 128) & (za >= -64) & (za <= 128)
    worst = max(float(np.abs(sample_world(ob[c], xa[inside], za[inside]) - oa[c]["data"][inside]).max()) for c in builder.CHANNELS[:3])
    check(worst < 1e-6, f"variation is a function of world XZ only (max {worst:.2e})")

    print("[5] physical radii: 2 m and 4 m lattices of the same terrain agree", flush=True)
    x2, z2 = grid(257, 257, (-256.0, 0.0, -256.0), (2.0, 0, 0), (0, 0, 2.0))
    fine = session.tint(session.load([("height", terrain(x2, z2), (-256.0, 0.0, -256.0), (2.0, 0, 0), (0, 0, 2.0))]), variation_strength=0.0)
    cook(fine)
    of = outputs(fine)
    ao_diff = np.abs(sample_world(of["terrain_ao"], x, z) - out["terrain_ao"]["data"])
    tint_diff = np.abs(sample_world(of["terrain_tint_r"], x, z) - out["terrain_tint_r"]["data"])
    check(float(ao_diff.mean()) < 0.01 and float(tint_diff.mean()) < 0.01, f"AO/tint depend on metres, not samples (mean |d| ao {ao_diff.mean():.4f}, tint {tint_diff.mean():.4f})")

    print("[6] determinism, seed and parameter response", flush=True)
    again = session.tint(session.load([("height", h, (-256.0, 0.0, -256.0), right, up)]))
    reseed = session.tint(session.load([("height", h, (-256.0, 0.0, -256.0), right, up)]), seed=12)
    strong = session.tint(session.load([("height", h, (-256.0, 0.0, -256.0), right, up)]), ao_strength=0.9, ridge_strength=0.5)
    for n in (again, reseed, strong): cook(n)
    o1, o2, o3 = outputs(again), outputs(reseed), outputs(strong)
    check(all(np.array_equal(o1[c]["data"], out_a[c]["data"]) for c in builder.CHANNELS), "identical input and parameters cook bit-identically")
    check(not np.array_equal(o2["terrain_tint_g"]["data"], o1["terrain_tint_g"]["data"]) and np.array_equal(o2["terrain_ao"]["data"], o1["terrain_ao"]["data"]), "seed changes only the variation")
    check(o3["terrain_ao"]["data"].min() < o1["terrain_ao"]["data"].min() and o3["terrain_tint_g"]["data"].max() > o1["terrain_tint_g"]["data"].max(), "strength parameters reach the cook")
    strong.parm("ao_strength").set(0.0)
    cook(strong)
    check(np.all(outputs(strong)["terrain_ao"]["data"] == 1.0), "changing a parameter on an existing node recooks it (ao_strength 0 -> neutral AO)")

    print("[7] errors", flush=True)
    for label, node in (("empty target", session.tint(session.load([("height", flat, (0, 0, 0), right, up)]), target_layer_path="")),
                        ("missing height", session.tint(session.load([("mask", flat, (0, 0, 0), right, up)]))),
                        ("NaN radius through HAPI", _unlocked_bad(session.tint(session.load([("height", flat, (0, 0, 0), right, up)])), "relief_radius", "nan")),
                        ("seed out of range", _unlocked_bad(session.tint(session.load([("height", flat, (0, 0, 0), right, up)])), "seed", "-3"))):
        try:
            node.cook(force=True)
            failed = bool(node.errors())
        except hou.OperationFailed:
            failed = True
        check(failed, f"{label} is a node error")

    print("[8] 1025^2 timing (4 km at 4 m)", flush=True)
    xl, zl = grid(1025, 1025, (-2048.0, 0.0, -2048.0), right, up)
    large = session.tint(session.load([("height", terrain(xl / 6.0, zl / 6.0) * 3.0, (-2048.0, 0.0, -2048.0), right, up)]))
    metrics["synthetic_1025_seconds"] = cook(large)
    detail = outputs(large)["_detail"]
    metrics["synthetic_1025_internal_seconds"] = detail.get("hego_tint_seconds")
    check(metrics["synthetic_1025_seconds"] < 30.0, f"1025^2 cook is economical ({metrics['synthetic_1025_seconds']:.2f} s)")

    if args.actual:
        print("[9] actual final height", flush=True)
        meta = json.load(open(args.actual[:-5] + ".json"))
        width, height = meta["resolution"]
        data = np.fromfile(args.actual, dtype="<f4").reshape(height, width)
        node = session.tint(session.load([("height", data, tuple(meta["sample_origin"]), tuple(meta["sample_step_x"]), tuple(meta["sample_step_y"]))]))
        metrics["actual_seconds"] = cook(node)
        result = outputs(node)
        metrics["actual"] = {c: {"min": float(result[c]["data"].min()), "max": float(result[c]["data"].max()), "mean": float(result[c]["data"].mean()), "p05": float(np.percentile(result[c]["data"], 5)), "p95": float(np.percentile(result[c]["data"], 95))} for c in builder.CHANNELS}
        metrics["actual"]["resolution"] = [width, height]
        check(result["terrain_ao"]["res"] == (width, height), "actual output keeps the input lattice")
        try:
            from PIL import Image
            rgb = np.stack([result[c]["data"] for c in builder.CHANNELS[:3]], axis=-1)
            Image.fromarray(np.clip(rgb * 0.5 * 255.0, 0, 255).astype(np.uint8)).save(os.path.join(args.out_dir, "actual_tint_half.png"))
            Image.fromarray(np.clip(result["terrain_ao"]["data"] * 255.0, 0, 255).astype(np.uint8)).save(os.path.join(args.out_dir, "actual_ao.png"))
        except ImportError:
            pass
    metrics["checks"] = CHECKS[0]
    metrics["failures"] = FAILURES
    with open(os.path.join(args.out_dir, "tint-metrics.json"), "w") as handle:
        json.dump(metrics, handle, indent=2)
    hou.hipFile.clear(suppress_save_prompt=True)
    print(f"TERRAIN_TINT_HDA_TEST: {'PASS' if not FAILURES else 'FAIL'} ({CHECKS[0]} checks, {len(FAILURES)} failures)", flush=True)
    if FAILURES:
        raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hda", default=builder.HDA_PATH)
    parser.add_argument("--out-dir", default="/tmp/hego-terrain-prototype/editor-macro/houdini")
    parser.add_argument("--actual", help="final height .rf32 with a sibling .json lattice description")
    args = parser.parse_args()
    import hou
    run(hou, args)


if __name__ == "__main__":
    main()
