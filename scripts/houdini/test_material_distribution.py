#!/usr/bin/env hython
"""Regression for Sop/HEGo_MaterialDistribution (loads only the saved .hda).

  hython scripts/houdini/test_material_distribution.py [--hda PATH] [--out-dir DIR] [--actual DIR]

Synthetic fixtures are ARTIFICIAL test terrain built here (an analytic island
with a beach, a sea cliff, a valley and a 440 m summit); they never ship. They
check the interface against the contract and registry, routing, exact lattice
reuse and sample/world correspondence, ranges, per-sample normalisation of all
every registry field with at most four positive weights per sample, determinism, mask-only behaviour,
habitat placement by slope/elevation/coast, optional erosion masks,
orientation and spacing invariance, parameter response and errors.

--actual RF32 cooks the saved-scene final cumulative height (row-major
[row][column] float32 with a sibling .json: width, height, sample_origin,
sample_step_x, sample_step_y, height_sha256) height-only, exactly as the
editor's MaterialCook sends it. It checks the same invariants, reports every
material's total/mean weight, dominant area and the fraction a top-4 packer
retains, measures small patches, and writes previews, material-coverage.json
and material-metrics.json. Any failed check exits nonzero.
"""

import argparse
import hashlib
import json
import os
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(SCRIPT_DIR))
sys.path.insert(0, SCRIPT_DIR)
sys.dont_write_bytecode = True

from hda_source_metadata import builder_source_matches, contract_metadata_matches  # noqa: E402
import numpy as np  # noqa: E402

import build_material_distribution_hda as builder  # noqa: E402

LOAD_PY = r"""
# Explicitly based volumes from an .npz: data[index1][index0] (or [index2][index1][index0]),
# sample at origin + i0 * step0 + i1 * step1 (any horizontal basis).
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
    n2, n1, n0 = data.shape if data.ndim == 3 else (1,) + data.shape
    o, a, b = (hou.Vector3(field[k]) for k in ("origin", "step0", "step1"))
    normal = a.cross(b).normalized()
    centre = o + a * ((n0 - 1) * 0.5) + b * ((n1 - 1) * 0.5)
    vol = geo.createVolume(n0, n1, n2, hou.BoundingBox(-1, -1, -1, 1, 1, 1))
    vol.setTransform(hou.Matrix4((tuple(a * (n0 * 0.5)) + (0,), tuple(b * (n1 * 0.5)) + (0,),
                                  tuple(normal * (n2 * 0.5)) + (0,), tuple(centre) + (1,))))
    vol.setAttribValue("name", field["name"])
    vol.setAttribValue("hegostrata_snapshot_mode", "cumulative")
    vol.setAllVoxelsFromString(data.tobytes())
"""

ROUTE_ATTRS = {"name", "hegostrata_layer_path", "hegostrata_role", "hegostrata_channel", "hegostrata_composition"}
TARGET = "../../Terrain/MaterialDistribution"
ENTRIES, REGISTRY_SHA = builder.load_registry()
NAMES = [entry["name"] for entry in ENTRIES]
CHANNELS = [entry["channel"] for entry in ENTRIES]
INDEX = {name: i for i, name in enumerate(NAMES)}
# Habitat groups used by the placement checks (registry names; not channel IDs). The four
# materials are sand, grass, gravel and cliff; sea floor is anything but grass.
SEA = {"coastal_sand", "scree_gravel", "dark_cliff"}
ROCK = {"dark_cliff"}
BARE = {"dark_cliff", "scree_gravel"}  # what replaces snow: high ground is rock and scree
COAST = {"coastal_sand", "scree_gravel", "island_grass"}
LOOSE = {"scree_gravel"}
VEGETATED = {"island_grass"}
SNOW_LINE = 330.0
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
        self.geo = hou.node("/obj").createNode("geo", "material_test")
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

    def material(self, source, **parms):
        node = self.geo.createNode(builder.OPERATOR.split("::")[0], f"material_{self.count}_{len(self.geo.children())}")
        node.setInput(0, source)
        node.parm("target_layer_path").set(parms.pop("target_layer_path", TARGET))
        for key, value in parms.items():
            node.parm(key).set(value)
        return node


def cook(node):
    started = time.time()
    node.cook(force=True)
    return time.time() - started


def outputs(node):
    geo = node.geometry()
    result = {"_order": [], "_types": set()}
    for prim in geo.prims():
        result["_types"].add(prim.type().name())
        res = prim.resolution()
        origin = np.array(prim.indexToPos((0, 0, 0)))
        name = prim.attribValue("name")
        result["_order"].append(name)
        result[name] = {
            "data": np.frombuffer(prim.allVoxelsAsString(), dtype="<f4").reshape(res[1], res[0]).astype(np.float64),
            "res": (res[0], res[1], res[2]), "origin": origin,
            "step0": np.array(prim.indexToPos((1, 0, 0))) - origin, "step1": np.array(prim.indexToPos((0, 1, 0))) - origin,
            "attrs": {a.name(): prim.attribValue(a) for a in geo.primAttribs()},
        }
    result["_detail"] = {a.name(): geo.attribValue(a) for a in geo.globalAttribs()}
    return result


def weights_of(out):
    return np.stack([out[channel]["data"] for channel in CHANNELS])


def group(weights, names):
    return sum(weights[INDEX[name]] for name in names)


def top4_ids(weights):
    return np.argpartition(weights, weights.shape[0] - 4, axis=0)[weights.shape[0] - 4:]


def top4_retained(weights):
    """Per-sample fraction a top-4 consumer (the native packer) keeps; independent of the HDA code."""
    return np.take_along_axis(weights, top4_ids(weights), axis=0).sum(axis=0) / weights.sum(axis=0)


def validate(out, label, res, origin, step0, step1):
    """Contract invariants shared by every successful cook -> weights[len(NAMES)][n1][n0]."""
    check(out["_order"] == CHANNELS, f"{label}: exactly the {len(CHANNELS)} registry channels in id order")
    check(out["_types"] == {"Volume"}, f"{label}: outputs are Volume primitives only")
    attrs_ok = all(set(out[c]["attrs"]) == ROUTE_ATTRS and out[c]["attrs"]["hegostrata_layer_path"] == TARGET
                   and out[c]["attrs"]["hegostrata_channel"] == c and out[c]["attrs"]["hegostrata_role"] == "value"
                   and out[c]["attrs"]["hegostrata_composition"] == "replace" for c in CHANNELS)
    check(attrs_ok, f"{label}: every volume carries only name + replace-value routing to {TARGET}")
    lattice_ok = all(out[c]["res"] == (res[0], res[1], 1) and np.allclose(out[c]["origin"], origin, atol=1e-6)
                     and np.allclose(out[c]["step0"], step0, atol=1e-6) and np.allclose(out[c]["step1"], step1, atol=1e-6)
                     for c in CHANNELS)
    check(lattice_ok, f"{label}: every volume keeps exactly the input lattice {res[0]}x{res[1]}")
    w = weights_of(out)
    total = w.sum(axis=0)
    check(np.isfinite(w).all() and w.min() >= 0.0 and w.max() <= 1.0, f"{label}: weights finite in [0, 1] ({w.min():.3g}..{w.max():.3g})")
    check(float(np.abs(total - 1.0).max()) <= 1e-5, f"{label}: weights sum to 1 at every sample (max |sum-1| {np.abs(total - 1.0).max():.2e})")
    detail = out["_detail"]
    nonzero = int((w > 0.0).sum(axis=0).max())
    check(detail.get("hego_material_max_nonzero") == nonzero and nonzero <= 4
          and np.isclose(detail.get("hego_material_top4_retained_mean", -1.0), 1.0, atol=1e-6),
          f"{label}: all {len(NAMES)} named fields remain, with at most four positive weights (max {nonzero}); native top-4 packing loses no further mass")
    check(detail.get("hego_material_limit_post_max_nonzero") == nonzero
          and detail.get("hego_material_raw_max_nonzero", 0) >= nonzero
          and 0 <= detail.get("hego_material_raw_top4_retained_min", -1) <= detail.get("hego_material_raw_top4_retained_mean", -1) <= 1.000001,
          f"{label}: raw/pre/post limiter diagnostics remain explicit")
    check(detail.get("hego_material_operator") == "Sop/" + builder.OPERATOR and detail.get("hego_material_registry_sha256") == REGISTRY_SHA,
          f"{label}: diagnostics name the operator and registry sha256")
    return w


def grid(n0, n1, origin, step0, step1):
    i0, i1 = np.meshgrid(np.arange(n0), np.arange(n1), indexing="xy")  # [index1][index0]
    x = origin[0] + i0 * step0[0] + i1 * step1[0]
    z = origin[2] + i0 * step0[2] + i1 * step1[2]
    return x, z


def smooth(edge0, edge1, x):
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def island(x, z):
    """ARTIFICIAL test island: shelf and deep floor, gentle eastern beach, a 45 m western
    sea cliff, a lowland valley and a flat-topped 440 m massif with cliff flanks."""
    r = np.hypot(x, 1.15 * z)
    sea = -2.0 - 70.0 * smooth(760.0, 1000.0, r)
    land = 4.0 + 56.0 * smooth(700.0, 400.0, r)
    height = np.where(r > 760.0, sea, np.where(r > 700.0, -2.0 + 6.0 * smooth(760.0, 700.0, r), land))
    height = height + 45.0 * smooth(785.0, 745.0, r) * smooth(-450.0, -600.0, x)
    height = height + 440.0 * np.exp(-(np.hypot(x - 120.0, z + 80.0) / 280.0) ** 4)
    valley = np.exp(-0.5 * ((z - 350.0) / 18.0) ** 2) * smooth(-450.0, -350.0, x) * smooth(550.0, 450.0, x)
    return height - 18.0 * valley * smooth(720.0, 600.0, r)


def slope_deg(height, spacing):
    gz, gx = np.gradient(height, spacing)
    return np.degrees(np.arctan(np.hypot(gx, gz)))


def sample_world(field, x, z):
    o, a, b = field["origin"], field["step0"], field["step1"]
    i0 = np.rint(((x - o[0]) * a[0] + (z - o[2]) * a[2]) / np.dot(a, a)).astype(int)
    i1 = np.rint(((x - o[0]) * b[0] + (z - o[2]) * b[2]) / np.dot(b, b)).astype(int)
    return field["data"][i1, i0]


def expect_error(label, node):
    try:
        node.cook(force=True)
        failed = bool(node.errors())
    except Exception:  # hou.OperationFailed
        failed = True
    check(failed, f"{label} is a node error")


def components(labels):
    """4-connected component sizes of an integer label image (run-length union-find)."""
    parent, size, sizes_label, previous = [], [], [], []

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for row in labels:
        cuts = np.flatnonzero(np.diff(row)) + 1
        starts = np.concatenate(([0], cuts)).tolist()
        ends = np.concatenate((cuts, [len(row)])).tolist()
        current, k = [], 0
        for start, end in zip(starts, ends):
            value = int(row[start])
            rid = len(parent)
            parent.append(rid)
            size.append(end - start)
            sizes_label.append(value)
            while k < len(previous) and previous[k][1] <= start:
                k += 1
            j = k
            while j < len(previous) and previous[j][0] < end:
                if previous[j][2] == value:
                    a, b = find(previous[j][3]), find(rid)
                    if a != b:
                        parent[b] = a
                        size[a] += size[b]
                j += 1
            current.append((start, end, value, rid))
        previous = current
    roots = [i for i in range(len(parent)) if parent[i] == i]
    return np.array([size[r] for r in roots]), np.array([sizes_label[r] for r in roots])


def run(hou, args):
    os.makedirs(args.out_dir, exist_ok=True)
    work = os.path.join(args.out_dir, "fixtures")
    os.makedirs(work, exist_ok=True)
    session = Session(hou, args.hda, work)
    metrics = {"hda": os.path.relpath(args.hda, REPO), "hda_sha256": hashlib.sha256(open(args.hda, "rb").read()).hexdigest()}
    right, up = (4.0, 0.0, 0.0), (0.0, 0.0, 4.0)

    print("[1] interface: contract, registry and embedded sections", flush=True)
    contract = json.load(open(builder.CONTRACT_PATH))
    definition = hou.hda.definitionsInFile(args.hda)[0]
    sections = definition.sections()
    check(definition.nodeTypeName() == builder.OPERATOR and contract["operator"] == "Sop/" + builder.OPERATOR, "operator name matches the contract")
    check(definition.maxNumInputs() == 1, "one input (cumulative height + optional masks)")
    check(contract["registry"]["sha256"] == REGISTRY_SHA and contract["outputs"]["channels"] == CHANNELS, f"contract matches the registry (sha256, {len(CHANNELS)} channels in id order)")
    check([e["id"] for e in ENTRIES] == list(range(len(ENTRIES))) and NAMES == ["coastal_sand", "island_grass", "scree_gravel", "dark_cliff"],
          "registry ids 0..3 are sand, grass, gravel and cliff")
    embedded = {name: sections[name].contents() for name in ("hego_contract.json", "hego_material_registry.json", "hego_build_material_distribution_hda.py", "hego_material_weight_limit.py") if name in sections}
    check(contract_metadata_matches(embedded.get("hego_contract.json"), open(builder.CONTRACT_PATH).read()), "HDA embeds the matching contract (demo path migration allowed)")
    check(embedded.get("hego_material_registry.json") == open(builder.REGISTRY_PATH).read(), "HDA embeds the current registry")
    check(builder_source_matches(embedded.get("hego_build_material_distribution_hda.py"), open(builder.__file__).read()), "HDA embeds matching builder provenance (demo path migration allowed)")
    check(embedded.get("hego_material_weight_limit.py") == builder.weight_limit_source(), "HDA embeds the shared limiter source without project runtime imports")
    probe = session.material(session.load([("height", np.zeros((3, 3)), (0, 0, 0), right, up)]))
    defaults_ok = all(probe.parm(name) is not None and (spec.get("default") == "" if spec["type"] == "string" else
                      probe.parm(name).evalAsString() == spec["default"] if spec["type"] == "menu" else
                      np.isclose(probe.parm(name).eval(), spec["default"])) for name, spec in contract["parameters"].items() if name != "target_layer_path")
    check(defaults_ok and probe.parm("target_layer_path") is not None, "every contract parameter exists with its contract default")

    print("[2] synthetic island (ARTIFICIAL fixture): invariants and habitat placement", flush=True)
    n = 513
    origin = (-1024.0, 0.0, -1024.0)
    x, z = grid(n, n, origin, right, up)
    height = island(x, z)
    slope = slope_deg(height, 4.0)
    source = session.load([("height", height, origin, right, up), ("height__ownership", np.ones_like(height), origin, right, up)])
    before = source.geometry().prims()[0].allVoxelsAsString()
    node = session.material(source)
    metrics["synthetic_513_seconds"] = cook(node)
    out = outputs(node)
    w = validate(out, "synthetic", (n, n), origin, right, up)
    check(source.geometry().prims()[0].allVoxelsAsString() == before and len(source.geometry().prims()) == 2, "mask-only: the input height is untouched")
    check("height" not in out and "height__ownership" not in out, "mask-only: no height or input companion is passed through")
    r = np.hypot(x, 1.15 * z)
    sea_sum, rock, bare, coast, veg = group(w, SEA), group(w, ROCK), group(w, BARE), group(w, COAST), group(w, VEGETATED)
    under = height < -3.0
    check(float(np.abs(sea_sum[under] - 1.0).max()) < 1e-5, "every sea-floor sample (< -3 m) uses only sea-floor materials (no grass)")
    deep = height < -50.0
    check(float(w[INDEX["scree_gravel"]][deep].mean()) > 0.5, f"deep floor (< -50 m) is mostly gravel ({w[INDEX['scree_gravel']][deep].mean():.2f})")
    cliffs = (slope > 50.0) & (height > 20.0)
    check(cliffs.sum() > 200 and float(rock[cliffs].mean()) > 0.9, f"slopes > 50 deg are bare rock (mean {rock[cliffs].mean():.3f}, n={cliffs.sum()})")
    summit = (height > SNOW_LINE + 60.0) & (slope < 30.0)
    check(summit.sum() > 200 and float(bare[summit].min()) > 0.999, f"summit above the snow line is bare rock and scree (min {bare[summit].min():.4f}, n={summit.sum()})")
    beach = (height > 0.5) & (height < 3.0) & (slope < 10.0)
    check(beach.sum() > 200 and float(coast[beach].mean()) > 0.95, f"low gentle coast is beach/shore (mean {coast[beach].mean():.3f}, n={beach.sum()})")
    check(float(w[INDEX["coastal_sand"]][(height > 0.5) & (height < 3.0) & (slope < 10.0)].mean()) > 0.4, "sand dominates the low gentle coast")
    lowland = (height > 15.0) & (height < 120.0) & (slope < 20.0) & (r < 600.0)
    check(lowland.sum() > 1000 and float(veg[lowland].mean()) > 0.7, f"gentle inland lowland is grass (mean {veg[lowland].mean():.3f})")
    sea_cliff = (x < -620.0) & (height > 2.0) & (slope > 40.0) & (r > 700.0)
    check(sea_cliff.sum() > 50 and float(rock[sea_cliff].mean()) > 0.7 and float(w[INDEX["scree_gravel"]][sea_cliff].mean()) > 0.05,
          f"western sea cliff is rock with scree at its foot (rock {rock[sea_cliff].mean():.2f}, scree {w[INDEX['scree_gravel']][sea_cliff].mean():.2f})")
    land = height > 1.0
    by_slope = [float(rock[land & (slope >= a) & (slope < b)].mean()) for a, b in ((0, 15), (15, 30), (30, 45), (45, 90))]
    check(all(b > a for a, b in zip(by_slope, by_slope[1:])), f"rock rises with slope ({', '.join(f'{v:.2f}' for v in by_slope)})")
    by_height = [float(bare[land & (height >= a) & (height < b)].mean()) for a, b in ((0, 200), (200, 300), (300, 380), (380, 1000))]
    check(all(b >= a - 0.02 for a, b in zip(by_height, by_height[1:])) and by_height[-1] > 0.3, f"bare ground rises with elevation ({', '.join(f'{v:.2f}' for v in by_height)})")
    present = [name for name in NAMES if w[INDEX[name]].max() > 0.3]
    check(len(present) == len(NAMES), f"synthetic island uses every material ({len(present)}/{len(NAMES)} reach 0.3)")
    metrics["synthetic_present"] = len(present)
    blend = (w > 0.0).sum(axis=0)
    check(int(blend.max()) <= 4 and out["_detail"]["hego_material_raw_max_nonzero"] >= 2,
          f"raw habitat model blends materials ({out['_detail']['hego_material_raw_max_nonzero']} contributions); published fields use at most four")

    print("[3] determinism", flush=True)
    again = session.material(source)
    cook(again)
    check(np.array_equal(weights_of(outputs(again)), w), "a second node on the same input cooks bit-identically")
    cook(node)
    check(np.array_equal(weights_of(outputs(node)), w), "recooking the same node is bit-identical")

    print("[4] optional erosion masks", flush=True)
    zeros = np.zeros_like(height)
    masks = [(name, zeros, origin, right, up) for name in builder.OPTIONAL_MASKS]
    zero_node = session.material(session.load([("height", height, origin, right, up)] + masks))
    cook(zero_node)
    zero_out = outputs(zero_node)
    check(np.array_equal(weights_of(zero_out), w) and zero_out["_detail"]["hego_material_optional_masks"] == " ".join(builder.OPTIONAL_MASKS),
          "explicit all-zero masks equal absent masks (missing masks default to 0)")
    line = np.exp(-0.5 * ((z + 450.0) / 6.0) ** 2) * smooth(-260.0, -200.0, x) * smooth(260.0, 200.0, x)
    flow = 0.05 + 0.25 * line
    disc = np.hypot(x + 300.0, z + 250.0)
    debris = 1.5 * np.exp(-0.5 * (disc / 30.0) ** 2)
    mask_node = session.material(session.load([("height", height, origin, right, up), ("flow", flow, origin, right, up),
                                               ("debris", debris, origin, right, up), ("sediment", zeros, origin, right, up)]))
    cook(mask_node)
    wm = validate(outputs(mask_node), "with masks", (n, n), origin, right, up)
    on_line = (line > 0.6) & (height > 10.0) & (slope < 25.0)
    wet_before = w[INDEX["scree_gravel"]][on_line].mean()
    wet_after = wm[INDEX["scree_gravel"]][on_line].mean()
    check(on_line.sum() > 20 and wet_after - wet_before > 0.2, f"a concentrated flow line becomes a gravel stream bed ({wet_before:.2f} -> {wet_after:.2f})")
    in_disc = (disc < 20.0) & (height > 5.0)
    loose_before, loose_after = group(w, LOOSE)[in_disc].mean(), group(wm, LOOSE)[in_disc].mean()
    check(in_disc.sum() > 20 and loose_after - loose_before > 0.4, f"a thermal debris deposit becomes scree/talus ({loose_before:.2f} -> {loose_after:.2f})")
    far = (np.abs(z + 450.0) > 120.0) & (disc > 150.0)
    worst_far = float(np.abs(wm - w)[:, far].max())
    check(worst_far < 1e-5, f"masks change materials only around the masked features (elsewhere max |d| {worst_far:.1e})")
    small = np.zeros((n - 1, n))
    shifted = (origin[0] + 2.0, 0.0, origin[2])
    for label, extra in (("mask on a different resolution", [("flow", small, origin, right, up)]),
                         ("mask with a shifted origin", [("flow", zeros, shifted, right, up)]),
                         ("mask with another spacing", [("flow", zeros, origin, (4.0001, 0, 0), up)]),
                         # inf, not NaN: Houdini's tile compression folds isolated NaNs into constant tiles.
                         ("nonfinite sediment", [("sediment", np.where(disc < 10.0, np.inf, 0.0), origin, right, up)]),
                         ("flow above 1", [("flow", zeros + 1.5, origin, right, up)]),
                         ("negative debris", [("debris", zeros - 1.0, origin, right, up)]),
                         ("duplicate flow", [("flow", zeros, origin, right, up), ("flow", zeros, origin, right, up)])):
        expect_error(label, session.material(session.load([("height", height, origin, right, up)] + extra)))

    print("[4b] prior stage materials (ARTIFICIAL prior fixture; contract v3)", flush=True)
    # Left half: a deliberately unnatural two-material prior that no habitat rule would
    # produce, so inheritance is unmistakable. Right half: zero total = uncovered.
    left = x < 0.0
    prior = np.zeros_like(w)
    prior[INDEX["island_grass"]][left] = np.float32(0.7)
    prior[INDEX["dark_cliff"]][left] = np.float32(0.3)
    prior_fields = [("material_" + name, prior[i], origin, right, up) for i, name in enumerate(NAMES)]
    inherit_node = session.material(session.load([("height", height, origin, right, up)] + prior_fields))
    cook(inherit_node)
    io = outputs(inherit_node)
    wi = validate(io, "inherit", (n, n), origin, right, up)
    check(np.array_equal(wi[:, left], prior[:, left].astype(np.float32)), "inherit: covered samples publish the stage weights byte for byte")
    check(np.array_equal(wi[:, ~left], w[:, ~left]), "inherit: uncovered samples equal the standalone habitat model")
    d = io["_detail"]
    check(d["hego_material_mode"] == "inherit" and d["hego_material_prior_status"] == "inherited"
          and abs(d["hego_material_prior_covered_fraction"] - float(left.mean())) < 1e-6  # float32 detail attribute
          and d["hego_material_inherited_exact_fraction"] == d["hego_material_prior_covered_fraction"],
          "inherit: mode, status and covered/exact fractions are reported")
    with_masks = session.material(session.load([("height", height, origin, right, up), ("flow", flow, origin, right, up),
                                                ("debris", debris, origin, right, up)] + prior_fields))
    cook(with_masks)
    wim = weights_of(outputs(with_masks))
    check(np.array_equal(wim[:, left], wi[:, left]) and np.array_equal(wim[:, ~left], wm[:, ~left]),
          "inherit + masks: masks are not applied again to inherited samples; uncovered samples use them")
    regen = session.material(session.load([("height", height, origin, right, up)] + prior_fields), prior_materials=1)
    cook(regen)
    ro = outputs(regen)
    check(np.array_equal(weights_of(ro), w) and ro["_detail"]["hego_material_mode"] == "regenerate"
          and ro["_detail"]["hego_material_prior_status"] == "ignored", "regenerate: stage materials ignored, contract v2 weights")
    zero_prior = session.material(session.load([("height", height, origin, right, up)]
                                               + [(name, zeros, origin, right, up) for name, *_ in prior_fields]))
    cook(zero_prior)
    zo = outputs(zero_prior)
    check(np.array_equal(weights_of(zo), w) and zo["_detail"]["hego_material_prior_status"] == "all_zero"
          and zo["_detail"]["hego_material_mode"] == "standalone", "all-zero prior equals no prior (reported all_zero)")
    check(out["_detail"]["hego_material_unavailable_masks"] == " ".join(builder.OPTIONAL_MASKS)
          and out["_detail"]["hego_material_prior_status"] == "absent", "height only: all four masks reported unavailable, prior absent")
    check(zero_out["_detail"]["hego_material_all_zero_masks"] == " ".join(builder.OPTIONAL_MASKS)
          and zero_out["_detail"]["hego_material_unavailable_masks"] == " ".join(builder.OPTIONAL_MASKS),
          "declared all-zero masks are reported unavailable")
    mo = outputs(mask_node)["_detail"]
    check(mo["hego_material_unavailable_masks"] == "sediment erosion_delta" and mo["hego_material_all_zero_masks"] == "sediment",
          "nonzero flow/debris are available; zero sediment and missing erosion_delta are not")
    expect_error(f"partial prior ({len(NAMES) - 1} of {len(NAMES)})", session.material(session.load([("height", height, origin, right, up)] + prior_fields[:-1])))
    expect_error("prior on another lattice", session.material(session.load(
        [("height", height, origin, right, up)] + [(f, a, shifted, right, up) for f, a, *_ in prior_fields])))
    expect_error("negative prior", session.material(session.load(
        [("height", height, origin, right, up)] + [(f, a - 1.0 if i == 0 else a, o, r, u) for i, (f, a, o, r, u) in enumerate(prior_fields)])))

    print("[5] sample/world correspondence and orientation invariance", flush=True)
    # A west-east ramp (sea at x < 0, land at x > 0) on the +X/+Z grid: columns (index0) are +X.
    ramp_n = 129
    ramp_origin = (-256.0, 0.0, -256.0)
    rx, rz = grid(ramp_n, ramp_n, ramp_origin, right, up)
    ramp_node = session.material(session.load([("height", 0.1 * rx, ramp_origin, right, up)]))
    cook(ramp_node)
    rw = validate(outputs(ramp_node), "ramp", (ramp_n, ramp_n), ramp_origin, right, up)
    ramp_sea = group(rw, SEA)
    check(bool(np.all(ramp_sea[:, rx[0] < -40.0] > 0.99999)) and bool(np.all(rw[INDEX["island_grass"]][:, rx[0] > 40.0] > 0.0)),
          "value [row][column] is the sample at origin + column * (4,0,0) + row * (0,0,4): sea in western columns, grass only on land")
    m = 257
    origin_a, origin_b = (-512.0, 0.0, -512.0), (-512.0, 0.0, 512.0)
    step0_b, step1_b = (0.0, 0.0, -4.0), (4.0, 0.0, 0.0)
    xa, za = grid(m, m, origin_a, right, up)
    xb, zb = grid(m, m, origin_b, step0_b, step1_b)
    node_a = session.material(session.load([("height", island(xa, za), origin_a, right, up)]))
    node_b = session.material(session.load([("height", island(xb, zb), origin_b, step0_b, step1_b)]))
    cook(node_a)
    cook(node_b)
    out_a, out_b = outputs(node_a), outputs(node_b)
    validate(out_b, "transposed", (m, m), origin_b, step0_b, step1_b)
    worst = max(float(np.abs(sample_world(out_b[c], xa, za) - out_a[c]["data"]).max()) for c in CHANNELS)
    check(worst < 1e-4, f"same world terrain in another orientation gives the same weights (max {worst:.2e})")

    print("[6] physical units: 8 m and 4 m lattices of the same world agree", flush=True)
    origin8 = (-1024.0, 0.0, -1024.0)
    x8, z8 = grid(257, 257, origin8, (8.0, 0, 0), (0, 0, 8.0))
    coarse = session.material(session.load([("height", island(x8, z8), origin8, (8.0, 0, 0), (0, 0, 8.0))]))
    cook(coarse)
    w8 = weights_of(outputs(coarse))
    w4 = w[:, ::2, ::2]
    habitats = ({"coastal_sand"}, ROCK, LOOSE, VEGETATED)
    diffs = [float(np.abs(group(w8, g) - group(w4, g)).mean()) for g in habitats]
    agree = float((np.argmax(np.stack([group(w8, g) for g in habitats]), 0) == np.argmax(np.stack([group(w4, g) for g in habitats]), 0)).mean())
    check(max(diffs) < 0.05 and agree > 0.9, f"habitat weights depend on metres, not samples (mean |d| max {max(diffs):.3f}, dominant habitat agreement {agree:.3f})")
    metrics["spacing_8_vs_4"] = {"mean_abs_diff": diffs, "dominant_agreement": agree}

    print("[7] parameter response and recook", flush=True)
    variants = {}
    for label, parms in (("high snow line", {"snow_line": 9000.0}), ("raised sea", {"sea_level": 10.0}),
                         ("low cliff slope", {"cliff_slope": 30.0}), ("reseeded", {"seed": 33}), ("sharper", {"sharpness": 6.0})):
        variant = session.material(source, **parms)
        cook(variant)
        variants[label] = weights_of(outputs(variant))
    check(float(group(variants["high snow line"], VEGETATED)[summit].mean()) > float(veg[summit].mean()), "snow_line above the summit lets grass climb higher")
    check((group(variants["raised sea"], SEA) > 0.999).sum() > (sea_sum > 0.999).sum(), "raising sea_level floods more samples with sea-floor materials")
    check(float(group(variants["low cliff slope"], ROCK)[land].mean()) > float(rock[land].mean()) + 0.05, "a lower cliff_slope exposes more rock")
    reseeded = variants["reseeded"]
    check(not np.array_equal(reseeded, w) and float(np.abs(group(reseeded, SEA) - sea_sum)[under].max()) < 1e-5,
          "seed changes variants, never the sea/land partition")
    check(float(variants["sharper"].max(axis=0).mean()) > float(w.max(axis=0).mean()), "higher sharpness gives more dominant variants")
    node.parm("cliff_slope").set(30.0)
    cook(node)
    check(float(group(weights_of(outputs(node)), ROCK)[land].mean()) > float(rock[land].mean()) + 0.05, "changing a parameter on an existing node recooks it")
    node.parm("cliff_slope").set(contract["parameters"]["cliff_slope"]["default"])

    print("[8] errors", flush=True)
    flat = np.full((9, 9), 5.0)

    def bad_parm(name, expression):
        bad = session.material(session.load([("height", flat, (0, 0, 0), right, up)]))
        bad.allowEditingOfContents()
        bad.node("distribute").parm(name).setExpression(expression)
        return bad

    for label, node_ in (("empty target", session.material(session.load([("height", flat, (0, 0, 0), right, up)]), target_layer_path="")),
                         ("missing height", session.material(session.load([("flow", flat * 0.0, (0, 0, 0), right, up)]))),
                         ("two height volumes", session.material(session.load([("height", flat, (0, 0, 0), right, up), ("height", flat, (0, 0, 0), right, up)]))),
                         ("3D height volume", session.material(session.load([("height", np.stack([flat, flat]), (0, 0, 0), right, up)]))),
                         ("2x2 height", session.material(session.load([("height", np.zeros((2, 2)), (0, 0, 0), right, up)]))),
                         ("4098-sample axis", session.material(session.load([("height", np.zeros((3, 4098)), (0, 0, 0), right, up)]))),
                         ("non-horizontal step", session.material(session.load([("height", flat, (0, 0, 0), (4.0, 1.0, 0.0), up)]))),
                         ("non-orthogonal steps", session.material(session.load([("height", flat, (0, 0, 0), right, (1.0, 0.0, 4.0))]))),
                         ("nonfinite height", session.material(session.load([("height", np.where(np.eye(9) > 0, np.inf, 5.0), (0, 0, 0), right, up)]))),
                         ("NaN parameter through HAPI", bad_parm("beach_height", "nan")),
                         ("out-of-range parameter through HAPI", bad_parm("cliff_slope", "95")),
                         ("seed out of range", bad_parm("seed", "-3"))):
        expect_error(label, node_)

    print("[9] 1025^2 timing (4 km at 4 m, ARTIFICIAL terrain)", flush=True)
    xl, zl = grid(1025, 1025, (-2048.0, 0.0, -2048.0), right, up)
    large = session.material(session.load([("height", island(xl / 2.0, zl / 2.0), (-2048.0, 0.0, -2048.0), right, up)]))
    metrics["synthetic_1025_seconds"] = cook(large)
    large_out = outputs(large)
    validate(large_out, "synthetic 1025", (1025, 1025), (-2048.0, 0.0, -2048.0), right, up)
    metrics["synthetic_1025_internal_seconds"] = large_out["_detail"].get("hego_material_seconds")
    check(metrics["synthetic_1025_seconds"] < 30.0, f"1025^2 cook is economical ({metrics['synthetic_1025_seconds']:.2f} s)")

    print("[9b] lattice above the old 1025 cap: 2049 x 1537 at 2 m, non-square, offset origin (ARTIFICIAL terrain)", flush=True)
    step2 = (2.0, 0.0, 0.0), (0.0, 0.0, 2.0)
    origin2 = (-2048.0, 0.0, -1536.0)
    x2, z2 = grid(2049, 1537, origin2, *step2)
    big = session.material(session.load([("height", island(x2 / 2.0, z2 / 2.0), origin2, *step2)]))
    metrics["synthetic_2049_seconds"] = cook(big)
    big_out = outputs(big)
    validate(big_out, "synthetic 2049x1537", (2049, 1537), origin2, *step2)
    check(all(tuple(big_out[c]["data"].shape[-2:]) == (1537, 2049) for c in CHANNELS),
          "2049x1537 input: every output is on exactly the input lattice")
    sample_x = sample_world(big_out["material_island_grass"], -2048.0 + 2.0 * 1000, -1536.0 + 2.0 * 700)
    check(np.isfinite(float(sample_x)), "2049x1537 input: world sampling at an interior lattice point works")

    if args.actual:
        run_actual(session, args, metrics)
    metrics["checks"] = CHECKS[0]
    metrics["failures"] = FAILURES
    with open(os.path.join(args.out_dir, "material-metrics.json"), "w") as handle:
        json.dump(metrics, handle, indent=2)
    hou.hipFile.clear(suppress_save_prompt=True)
    print(f"MATERIAL_DISTRIBUTION_HDA_TEST: {'PASS' if not FAILURES else 'FAIL'} ({CHECKS[0]} checks, {len(FAILURES)} failures)", flush=True)
    if FAILURES:
        raise SystemExit(1)


def run_actual(session, args, metrics):
    print("[10] actual saved-scene final height (read-only, height-only like MaterialCook)", flush=True)
    meta = json.load(open(os.path.splitext(args.actual)[0] + ".json"))
    raw = open(args.actual, "rb").read()
    digest = hashlib.sha256(raw).hexdigest()
    check(digest == meta.get("height_sha256"), f"actual RF32 matches its recorded height sha256 ({digest[:16]}...)")
    res = (int(meta["width"]), int(meta["height"]))
    origin, step0, step1 = tuple(meta["sample_origin"]), tuple(meta["sample_step_x"]), tuple(meta["sample_step_y"])
    check(res == (1025, 1025) and origin == (-2048.0, 0.0, -2048.0) and step0 == (4.0, 0.0, 0.0) and step1 == (0.0, 0.0, 4.0),
          f"actual input is the contractual +X/+Z grid ({res[0]}x{res[1]}, origin {origin}, steps {step0} {step1})")
    height = np.frombuffer(raw, dtype="<f4").reshape(res[1], res[0]).astype(np.float64)  # [row = +Z][column = +X]
    slope = slope_deg(height, 4.0)
    land = height > 0.0
    cell_km2 = abs(step0[0] * step1[2] - step0[2] * step1[0]) * 1e-6
    node = session.material(session.load([("height", height, origin, step0, step1)]))
    seconds = cook(node)
    out = outputs(node)
    w = validate(out, "actual", res, origin, step0, step1)
    again = session.material(node.inputs()[0])
    cook(again)
    check(np.array_equal(weights_of(outputs(again)), w), "actual: deterministic (second node bit-identical)")
    x, z = grid(res[0], res[1], origin, step0, step1)
    peak = np.unravel_index(np.argmax(height), height.shape)
    check(float(sample_world(out["material_dark_cliff"], x[peak], z[peak]) + sample_world(out["material_scree_gravel"], x[peak], z[peak])) > 0.5
          and float(sample_world(out["material_island_grass"], -2048.0, -2048.0)) == 0.0,
          f"world correspondence: summit at ({x[peak]:.0f}, {z[peak]:.0f}) is bare rock/scree, deep corner (-2048, -2048) has no grass")
    sea_sum, rock, bare, coast, veg = group(w, SEA), group(w, ROCK), group(w, BARE), group(w, COAST), group(w, VEGETATED)
    under = height < -3.0
    check(float(np.abs(sea_sum[under] - 1.0).max()) < 1e-5, "actual: all sea floor (< -3 m) uses sea-floor materials")
    cliffs = land & (slope > 50.0)
    check(float(rock[cliffs].mean()) > 0.85, f"actual: slopes > 50 deg are rock (mean {rock[cliffs].mean():.3f}, {cliffs.sum() * cell_km2:.3f} km2)")
    summit = height > 400.0
    check(summit.sum() > 0 and float(bare[summit].mean()) > 0.5, f"actual: ground above 400 m is mostly bare rock/scree (mean {bare[summit].mean():.3f})")
    beach = (height > 0.5) & (height < 3.0) & (slope < 10.0)
    check(float(coast[beach].mean()) > 0.9, f"actual: low gentle coast is beach/shore (mean {coast[beach].mean():.3f})")
    lowland = land & (height > 15.0) & (height < 150.0) & (slope < 25.0)
    check(float(veg[lowland].mean()) > 0.6, f"actual: moderate lowland is grass (mean {veg[lowland].mean():.3f})")
    by_slope = [float(rock[land & (slope >= a) & (slope < b)].mean()) for a, b in ((0, 15), (15, 30), (30, 45), (45, 90))]
    check(all(b > a for a, b in zip(by_slope, by_slope[1:])), f"actual: rock rises with slope ({', '.join(f'{v:.2f}' for v in by_slope)})")

    dominant = np.argmax(w, axis=0)
    kept = top4_ids(w)
    in_top4 = np.zeros(w.shape, dtype=bool)
    np.put_along_axis(in_top4, kept, True, axis=0)
    retained = top4_retained(w)
    coverage = []
    for i, name in enumerate(NAMES):
        mine = dominant == i
        total = float(w[i].sum())
        coverage.append({"id": i, "name": name, "channel": CHANNELS[i],
                         "total_weight_km2": total * cell_km2, "mean_weight": float(w[i].mean()),
                         "mean_weight_land": float(w[i][land].mean()),
                         "dominant_km2": float(mine.sum() * cell_km2), "dominant_land_km2": float((mine & land).sum() * cell_km2),
                         "weight_ge_0_3_km2": float((w[i] >= 0.3).sum() * cell_km2), "positive_km2": float((w[i] > 0.0).sum() * cell_km2),
                         "top4_retained_fraction": float(w[i][in_top4[i]].sum() / total) if total > 0.0 else 0.0})
    print("       id name              total_km2  mean_w   dominant_km2  top4_retained", flush=True)
    for c in coverage:
        print(f"       {c['id']:2d} {c['name']:<16} {c['total_weight_km2']:9.4f}  {c['mean_weight']:.4f}  {c['dominant_km2']:12.4f}  {c['top4_retained_fraction']:.4f}", flush=True)
    weak = [c["name"] for c in coverage if c["dominant_km2"] < 0.01]
    check(not weak, f"actual: all {len(NAMES)} materials dominate at least 0.01 km2 (1 ha){'; below: ' + ', '.join(weak) if weak else ''}")
    check(float(retained.mean()) > 0.97, f"actual: a top-4 consumer keeps {retained.mean():.4f} of the weight on average (min {retained.min():.4f})")
    # Preserve the original habitat/noise check on the raw habitat model.
    # Soft limiting deliberately boosts dominance/confidence; applying the old
    # 0.5 confidence cutoff to its result selects additional samples rather
    # than measuring the same population. Report both, without loosening the
    # original threshold, and prove no dominant-ID region was introduced.
    parameters = {p[0]: p[2] for p in builder.FLOAT_PARMS + builder.INT_PARMS}
    frame = {"la": float(np.linalg.norm(step0)), "lb": float(np.linalg.norm(step1)),
             "ua": (step0[0] / 4.0, step0[2] / 4.0), "ub": (step1[0] / 4.0, step1[2] / 4.0), "x": x, "z": z}
    raw_weights, _ = builder.core_namespace()["distribute"](
        height, {name: np.zeros_like(height) for name in builder.OPTIONAL_MASKS}, frame, parameters, NAMES)
    raw_weights = raw_weights.astype("<f4").astype(np.float64)
    raw_retained = top4_retained(raw_weights)
    check(np.isclose(out["_detail"]["hego_material_raw_top4_retained_mean"], raw_retained.mean(), atol=1e-7)
          and np.isclose(out["_detail"]["hego_material_raw_top4_retained_min"], raw_retained.min(), atol=1e-7),
          "actual: saved HDA raw retention diagnostics match the unchanged habitat model")
    check(np.array_equal(np.argmax(raw_weights, axis=0), dominant),
          "actual: soft limiting preserves every raw dominant material ID (no new dominant-ID regions)")
    patch_metrics = {}
    for label, model in (("raw", raw_weights), ("limited", w)):
        labels = np.where(model.max(axis=0) >= 0.5, np.argmax(model, axis=0), -1)
        sizes, component_values = components(labels)
        tiny = (sizes < 4) & (component_values >= 0)
        patch_metrics[label + "_confidence_ge_0_5_tiny_fraction"] = float(sizes[tiny].sum() / labels.size)
    raw_tiny = patch_metrics["raw_confidence_ge_0_5_tiny_fraction"]
    tiny_fraction = patch_metrics["limited_confidence_ge_0_5_tiny_fraction"]
    check(raw_tiny < 0.002, f"actual: raw habitat tiny isolated patches (<4 samples, weight >= 0.5) cover {100 * raw_tiny:.3f}% (< 0.2%)")
    print(f"  info limited confidence>=0.5 tiny patches cover {100 * tiny_fraction:.3f}%; normalization changes the confidence-qualified population, dominant IDs remain identical", flush=True)
    all_sizes, _ = components(dominant)
    # Private test export for production-shader comparisons; no scene/cache
    # resource is saved or adopted. Match the native stable top-four layout.
    ordered_ids = np.argsort(-w, axis=0, kind="stable")[:4]
    control_weights = np.take_along_axis(w, ordered_ids, axis=0)
    control_weights /= control_weights.sum(axis=0)
    control_ids_path = os.path.join(args.out_dir, "actual-control-ids.rgba8")
    control_weights_path = os.path.join(args.out_dir, "actual-control-weights.rgbaf")
    np.moveaxis(ordered_ids, 0, -1).astype("u1").tofile(control_ids_path)
    np.moveaxis(control_weights, 0, -1).astype("<f4").tofile(control_weights_path)
    with open(os.path.join(args.out_dir, "actual-controls.json"), "w") as handle:
        json.dump({"width": res[0], "height": res[1], "ids": control_ids_path, "weights": control_weights_path,
                   "ids_format": "RGBA8 stable byte IDs, row-major", "weights_format": "RGBAF float32 little endian, row-major",
                   "height_sha256": digest, "hda_sha256": metrics["hda_sha256"], "source_scene_sha256": meta.get("source_scene_sha256"),
                   "note": "Private numerical test export; not an adopted authoring/cache generation"}, handle, indent=2)
    report = {"source": os.path.abspath(args.actual), "height_sha256": digest, "source_scene_sha256": meta.get("source_scene_sha256"),
              "lattice": {"resolution": list(res), "sample_origin": list(origin), "sample_step_x": list(step0), "sample_step_y": list(step1)},
              "land_km2": float(land.sum() * cell_km2), "sea_km2": float((~land).sum() * cell_km2),
              "cook_seconds": seconds, "internal_seconds": out["_detail"].get("hego_material_seconds"),
              "max_sum_error": out["_detail"].get("hego_material_max_sum_error"), "max_nonzero": out["_detail"].get("hego_material_max_nonzero"),
              "top4_retained_mean": float(retained.mean()), "top4_retained_min": float(retained.min()),
              "patch_metrics": patch_metrics,
              "raw_top4_retained_mean": out["_detail"].get("hego_material_raw_top4_retained_mean"),
              "raw_top4_retained_min": out["_detail"].get("hego_material_raw_top4_retained_min"),
              "limiter": {k.removeprefix("hego_material_limit_"): v for k,v in out["_detail"].items() if k.startswith("hego_material_limit_")},
              "zones": dict(zip(out["_detail"]["hego_material_zones"].split(), out["_detail"]["hego_material_zone_mean"])),
              "geography": {"rock_on_slopes_gt_50": float(rock[cliffs].mean()), "rock_by_slope_0_15_30_45_90": by_slope,
                            "snow_above_400m": float(snow[summit].mean()), "coast_low_gentle": float(coast[beach].mean()),
                            "vegetation_lowland": float(veg[lowland].mean())},
              "patches": {"strong_components": int((component_values >= 0).sum()), "strong_tiny_lt4": int(tiny.sum()), "strong_tiny_area_fraction": tiny_fraction,
                          "dominant_components": int(len(all_sizes)), "dominant_lt4_area_fraction": float(all_sizes[all_sizes < 4].sum() / labels.size)},
              "coverage": coverage}
    write_previews(args.out_dir, "final_height", height, w)
    check(hashlib.sha256(open(args.actual, "rb").read()).hexdigest() == digest, "actual RF32 is unchanged after the test (read-only)")
    metrics["actual"] = report
    with open(os.path.join(args.out_dir, "material-coverage.json"), "w") as handle:
        json.dump(report, handle, indent=2)


PALETTE = {"sand": (226, 205, 150), "grass": (110, 160, 70), "rock": (125, 120, 115), "snow": (240, 245, 255),
           "gravel": (165, 155, 135), "soil": (140, 105, 70), "sandy_soil": (150, 120, 85), "forest": (80, 95, 45), "mud": (95, 85, 75)}


def write_previews(out_dir, case, height, w):
    try:
        from PIL import Image
    except ImportError:
        return
    shades = np.linspace(0.8, 1.2, 8)
    colours = np.array([np.clip(np.array(PALETTE.get(entry["role"], (128, 128, 128))) * shades[i % 8], 0, 255) for i, entry in enumerate(ENTRIES)])
    rgb = np.tensordot(w.transpose(1, 2, 0), colours, axes=([2], [0]))
    gz, gx = np.gradient(height, 4.0)
    light = np.clip(0.75 + 0.6 * (-0.5 * gx + 0.6 * gz) / np.sqrt(1.0 + gx * gx + gz * gz), 0.35, 1.2)
    Image.fromarray(np.clip(rgb * light[..., None], 0, 255).astype(np.uint8)).save(os.path.join(out_dir, f"actual_{case}_materials.png"))
    tiles = [np.clip(w[i][::4, ::4] * 255.0, 0, 255).astype(np.uint8) for i in range(32)]
    rows = [np.concatenate(tiles[r * 8:(r + 1) * 8], axis=1) for r in range(4)]
    Image.fromarray(np.concatenate(rows, axis=0)).save(os.path.join(out_dir, f"actual_{case}_weights_grid.png"))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hda", default=builder.HDA_PATH)
    parser.add_argument("--out-dir", default="/tmp/hego-materials/hda/test")
    parser.add_argument("--actual", help="saved-scene final height .rf32 with a sibling .json (e.g. /tmp/hego-materials/final_height.rf32)")
    args = parser.parse_args()
    import hou
    run(hou, args)


if __name__ == "__main__":
    main()
