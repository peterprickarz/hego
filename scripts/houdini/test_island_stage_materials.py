#!/usr/bin/env hython
"""Stage-material and slump regression for Sop/hego_island_erosion::1.0 (contract v2).

Cooks the saved HDA in a fresh hython session on ACTUAL island inputs exported
from a HEGo session (bgeo files: the coarse cumulative height, the detail
cumulative height and the raw BuildingFlatten constraints). Without them it
falls back to the versioned rough base cache for the coarse checks and skips the
detail checks. The coarse stage runs on the whole island at a draft spacing
(default 16 m); the detail stage runs at its real 2 m / 4 m spacings on a 512 m
crop around the building pad. Nothing here writes to the repository, an
authoring scene or a cache.

  hython scripts/houdini/test_island_stage_materials.py \
      --coarse-input coarse.bgeo.sc --detail-input detail.bgeo.sc \
      --constraints constraints.bgeo.sc --baseline-hda old/hego_island_erosion.hda \
      --out-dir /tmp/hego-stage-materials

--baseline-hda is a contract v1 definition (e.g. `git show <rev>:demo/
island/hda/hego_island_erosion.hda`); it is cooked in a separate hython process
to prove that Slump off reproduces the v1 channels byte for byte.
"""

import argparse
import json
import os
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(SCRIPT_DIR))
sys.path.insert(0, SCRIPT_DIR)
sys.dont_write_bytecode = True

import build_island_hda as island  # noqa: E402

OPERATOR = "hego_island_erosion::1.0"
# The four island materials: loose rock is the talus family, water-moved material is gravel
# or sand, and incised ground reads as gravel or bare rock.
FAMILIES = {
    "talus": ("scree_gravel",),
    "wet_transport": ("scree_gravel", "coastal_sand"),
    "eroded_soil": ("dark_cliff",),
}
CROP_CENTRE = (-1008.0, 592.0)
CROP_SIZE = 512.0
CHECKS = []


def check(label, ok, detail=""):
    CHECKS.append({"label": label, "ok": bool(ok), "detail": detail})
    print(("PASS " if ok else "FAIL ") + label + (": " + str(detail) if detail != "" else ""), flush=True)
    return ok


BASELINE_PY = r"""
import hou, sys, json
hda, source, constraints, out, parms = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], json.loads(sys.argv[5])
hou.hda.installFile(hda)
geo = hou.node("/obj").createNode("geo", "baseline")
src = geo.createNode("file"); src.parm("file").set(source)
if parms.pop("_crop", None):
    crop = geo.createNode("heightfield_crop"); crop.setInput(0, src)
    crop.parm("orient").set("zx"); crop.parmTuple("size").set((CROP, CROP)); crop.parmTuple("t").set((CX, 0, CZ))
    src = crop
node = geo.createNode("hego_island_erosion::1.0"); node.setInput(0, src)
if constraints:
    c = geo.createNode("file"); c.parm("file").set(constraints); node.setInput(1, c)
for k, v in parms.items(): node.parm(k).set(v)
node.cook(force=True)
node.geometry().saveToFile(out)
""".replace("CROP", repr(CROP_SIZE)).replace("CX", repr(CROP_CENTRE[0])).replace("CZ", repr(CROP_CENTRE[1]))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hda", default=island.HDA_PATH)
    parser.add_argument("--baseline-hda", default="")
    parser.add_argument("--coarse-input", default="")
    parser.add_argument("--detail-input", default="")
    parser.add_argument("--constraints", default="")
    parser.add_argument("--coarse-spacing", type=float, default=16.0)
    parser.add_argument("--out-dir", default="/tmp/hego-stage-materials")
    args = parser.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)

    import hou
    import numpy as np

    ns = {}
    for path in (os.path.join(SCRIPT_DIR, "material_weight_limit.py"), island.MATERIAL_HABITAT_PATH, island.MATERIAL_STAGE_PATH):
        exec(compile(open(path).read(), path, "exec"), ns)
    names, registry_sha = island.material_names()
    channels = island.CHANNELS + ["material_" + n for n in names]
    index = {n: i for i, n in enumerate(names)}

    hou.hipFile.clear(suppress_save_prompt=True)
    hou.hda.installFile(args.hda)
    geo = hou.node("/obj").createNode("geo", "stage_materials")

    def file_node(path, name):
        node = geo.createNode("file", name)
        node.parm("file").set(path)
        return node

    if args.coarse_input:
        coarse_src = file_node(args.coarse_input, "coarse_input")
    else:  # versioned rough base cache, 513^2 @ 8 m
        meta = json.load(open(os.path.join(island.CACHE_DIR, "base_height.json")))
        grid = geo.createNode("heightfield", "base_grid")
        island._set_parms(grid, sampling="corner", divisionmode="size", gridspacing=meta["sample_spacing"],
                          sizex=meta["extent"][0], sizey=meta["extent"][1])
        grid.parm("orient").set("zx")
        coarse_src = island._python_sop(hou, geo, "base_load", island.LOAD_RF32_PY, grid)
        group = coarse_src.parmTemplateGroup()
        group.append(hou.StringParmTemplate("rf32_path", "RF32", 1, default_value=(os.path.join(island.CACHE_DIR, "base_height.rf32"),)))
        group.append(hou.IntParmTemplate("stride", "Stride", 1, default_value=(1,)))
        coarse_src.setParmTemplateGroup(group)

    def erosion(name, source, constraints=None, **parms):
        node = geo.createNode(OPERATOR, name)
        node.setInput(0, source)
        if constraints is not None:
            node.setInput(1, constraints)
        parms.setdefault("target_layer_path", "../Terrain/Test")
        for key, value in parms.items():
            node.parm(key).set(value)
        started = time.time()
        try:
            node.cook(force=True)
        except hou.OperationFailed:
            pass
        print(f"[cook] {name}: {time.time() - started:.1f}s errors={list(node.errors())}", flush=True)
        return node

    def volumes(node):
        out = {}
        for prim in node.geometry().prims():
            res = prim.resolution()
            out[prim.attribValue("name")] = np.frombuffer(prim.allVoxelsAsString(), dtype="<f4").reshape(res[1], res[0]).copy()
        return out

    def stack(out):
        return np.stack([out["material_" + n] for n in names]).astype(np.float64)

    def detail(node, key):
        g = node.geometry()
        return g.attribValue("hego_island_" + key) if g.findGlobalAttrib("hego_island_" + key) else None

    def family(weights, key):
        return sum(weights[index[n]] for n in FAMILIES[key])

    def gate_of(node):
        stage = node.node("material_stage")
        prim = [p for p in stage.geometry().prims() if p.attribValue("name") == island.MATERIAL_GATE][0]
        res = prim.resolution()
        return np.frombuffer(prim.allVoxelsAsString(), dtype="<f4").reshape(res[1], res[0]).astype(np.float64)

    def contract_checks(label, node, expect_status):
        out = volumes(node)
        check(f"{label}: no cook errors", not node.errors(), list(node.errors()))
        check(f"{label}: 9 channels then {len(names)} registry materials in order", list(out) == channels, list(out)[:12])
        g = node.geometry()
        attrs = {p.attribValue("name"): p.attribValue("hegostrata_channel") for p in g.prims()}
        check(f"{label}: routing channel == name", all(k == v for k, v in attrs.items()))
        w = stack(out)
        masks = out["erosion_delta"].shape
        check(f"{label}: materials on the mask lattice", all(out["material_" + n].shape == masks for n in names), masks)
        check(f"{label}: finite, >= 0", bool(np.isfinite(w).all()) and float(w.min()) >= 0.0, float(w.min()))
        check(f"{label}: <= 4 positive weights", int((w > 0).sum(0).max()) <= 4, int((w > 0).sum(0).max()))
        check(f"{label}: weights sum to 1", float(np.abs(w.sum(0) - 1).max()) <= 1e-5, float(np.abs(w.sum(0) - 1).max()))
        check(f"{label}: status {expect_status}", detail(node, "material_status") == expect_status, detail(node, "material_status"))
        check(f"{label}: registry sha", detail(node, "material_registry_sha256") == registry_sha)
        return out, w

    metrics = {"hda": args.hda, "houdini": hou.applicationVersionString()}
    coarse_parms = dict(output_spacing=args.coarse_spacing, mask_spacing=args.coarse_spacing, seed=19, erosion_strength=1.18)

    # --- Coarse: initialization, slump, zero strength and real ablations -----
    coarse = erosion("coarse", coarse_src, **coarse_parms)
    cout, cw = contract_checks("coarse", coarse, "initialized")
    check("coarse: no prior coverage", detail(coarse, "material_prior_covered_fraction") == 0.0)
    no_slump = erosion("coarse_no_slump", coarse_src, slump_enable=0, **coarse_parms)
    nout = volumes(no_slump)
    moved = cout["debris"].astype(np.float64) - nout["debris"]
    check("slump: debris redistributed", float(np.abs(moved).max()) > 0.01, float(np.abs(moved).max()))
    check("slump: debris mass conserved (mean change < 1 mm)", abs(float(moved.mean())) < 1e-3, float(moved.mean()))
    zero = erosion("coarse_zero", coarse_src, **dict(coarse_parms, erosion_strength=0.0))
    zout, zw = contract_checks("coarse zero strength", zero, "initialized")
    check("zero strength: no sediment/debris, delta 0",
          max(float(np.abs(zout[k]).max()) for k in ("sediment", "debris", "erosion_delta")) == 0.0)
    check("zero strength: flow is zero (no false transport evidence)", float(zout["flow"].max()) == 0.0, float(zout["flow"].max()))
    check("zero strength: gate closed everywhere", detail(zero, "material_refined_fraction") == 0.0)
    hydro = erosion("coarse_hydro_only", coarse_src, **dict(coarse_parms, thermal_scale=0.0))
    thermal = erosion("coarse_thermal_only", coarse_src, **dict(coarse_parms, hydro_scale=0.0))
    hout, hw = volumes(hydro), stack(volumes(hydro))
    tout, tw = volumes(thermal), stack(volumes(thermal))
    debris_area = tout["debris"] > 0.5
    talus_gain = float((family(tw, "talus") - family(zw, "talus"))[debris_area].mean()) if debris_area.any() else 0.0
    check("thermal-only debris areas gain talus materials", debris_area.sum() > 20 and talus_gain > 0.15,
          {"samples": int(debris_area.sum()), "mean_talus_gain": talus_gain})
    wet_area = (hout["sediment"] > 0.5) & (hout["debris"] == 0)
    wet_gain = float((family(hw, "wet_transport") - family(zw, "wet_transport"))[wet_area].mean()) if wet_area.any() else 0.0
    check("hydro-only sediment areas gain wet transport/deposit materials", wet_area.sum() > 20 and wet_gain > 0.05,
          {"samples": int(wet_area.sum()), "mean_gain": wet_gain})
    eroded_area = (hout["erosion_delta"] < -1.0) & (hout["sediment"] < 0.05)
    eroded_gain = float((family(hw, "eroded_soil") + family(hw, "talus") - family(zw, "eroded_soil") - family(zw, "talus"))[eroded_area].mean()) if eroded_area.any() else 0.0
    metrics["coarse_ablation"] = {
        "talus_gain_thermal_debris": talus_gain, "wet_gain_hydro_sediment": wet_gain,
        "eroded_soil_or_talus_gain_hydro_incision": eroded_gain, "eroded_samples": int(eroded_area.sum()),
        "refined_fraction": {k: detail(n, "material_refined_fraction") for k, n in
                             (("full", coarse), ("hydro_only", hydro), ("thermal_only", thermal), ("zero", zero))},
    }
    print("[metrics] coarse ablation", json.dumps(metrics["coarse_ablation"]), flush=True)
    np.save(os.path.join(args.out_dir, "coarse_weights.npy"), cw.astype("<f4"))
    np.save(os.path.join(args.out_dir, "coarse_zero_weights.npy"), zw.astype("<f4"))
    np.save(os.path.join(args.out_dir, "coarse_debris.npy"), cout["debris"])

    def baseline(source_path, constraints_path, parms, crop, name):
        out = os.path.join(args.out_dir, name + ".bgeo.sc")
        script = os.path.join(args.out_dir, "baseline_cook.py")
        with open(script, "w") as handle:
            handle.write(BASELINE_PY)
        parms = dict(parms, target_layer_path="../Terrain/Test")
        if crop:
            parms["_crop"] = 1
        hython = os.path.join(os.environ.get("HFS", "/opt/hfs22.0.429"), "bin", "hython")
        subprocess.run([hython, script, args.baseline_hda, source_path, constraints_path, out, json.dumps(parms)],
                       check=True, capture_output=True, timeout=1200)
        reference = geo.createNode("file", name)
        reference.parm("file").set(out)
        return {p.attribValue("name"): np.frombuffer(p.allVoxelsAsString(), dtype="<f4") for p in reference.geometry().prims()}

    if args.baseline_hda and args.coarse_input:
        ref = baseline(args.coarse_input, "", coarse_parms, False, "baseline_coarse")
        same = all(np.array_equal(ref[c], nout[c].ravel()) for c in island.CHANNELS)
        check("slump off: coarse 9 channels byte-identical to contract v1", same and list(ref) == island.CHANNELS,
              {c: float(np.abs(ref[c] - nout[c].ravel()).max()) for c in island.CHANNELS})

    # --- Detail on an actual 2 m crop around the building pad ---------------
    if args.detail_input and args.constraints:
        dsrc = file_node(args.detail_input, "detail_input")
        crop = geo.createNode("heightfield_crop", "detail_crop")
        crop.setInput(0, dsrc)
        crop.parm("orient").set("zx")
        crop.parmTuple("size").set((CROP_SIZE, CROP_SIZE))
        crop.parmTuple("t").set((CROP_CENTRE[0], 0.0, CROP_CENTRE[1]))
        raw = file_node(args.constraints, "constraints")
        detail_parms = dict(detail_stage=1, output_spacing=2.0, mask_spacing=4.0, feature_size=6.0, freeze_frame=16, seed=7)

        def with_prior(name, source_node, keep):
            """Crop height + material (and optionally simulation) fields of another stage's output."""
            blast = geo.createNode("blast", name + "_fields")
            blast.setInput(0, source_node)
            island._set_parms(blast, group=keep, grouptype="prims", negate=1)
            merge = geo.createNode("merge", name)
            merge.setInput(0, crop)
            merge.setInput(1, blast)
            return merge

        d0 = erosion("detail_initial", crop, raw, **detail_parms)
        d0out, d0w = contract_checks("detail without prior", d0, "initialized")
        check("detail: transition applied", detail(d0, "transition_status") == "applied", detail(d0, "transition_status"))
        prior = with_prior("prior_materials", d0, "@name=material_*")
        d1 = erosion("detail_zero_with_prior", prior, raw, **dict(detail_parms, erosion_strength=0.0))
        d1out, d1w = contract_checks("detail zero strength with prior", d1, "refined_prior")
        check("zero strength + prior: inherited materials byte-identical",
              all(np.array_equal(d1out["material_" + n], d0out["material_" + n]) for n in names))
        check("zero strength + prior: inherited exact fraction 1", detail(d1, "material_inherited_exact_fraction") == 1.0)
        d2 = erosion("detail_with_prior", prior, raw, **detail_parms)
        d2out, d2w = contract_checks("detail with prior", d2, "refined_prior")
        gate = gate_of(d2)
        closed = gate == 0.0
        check("unaffected samples keep inherited weights byte-identical",
              all(np.array_equal(d2out["material_" + n][closed], d0out["material_" + n][closed]) for n in names),
              {"closed_fraction": float(closed.mean())})
        changed = (np.abs(d2w - d0w).max(axis=0) > 1e-6)
        check("refinement is local to evidence", bool(changed[~closed].any()) and not changed[closed].any(),
              {"refined_fraction": float((~closed).mean()), "changed_fraction": float(changed.mean())})
        # Protection closes the gate.
        res = d2.node("resample").geometry()
        wprim = [p for p in res.prims() if p.attribValue("name") == "mask"][0]
        r = wprim.resolution()
        protect = ns["tent_downsample"](np.frombuffer(wprim.allVoxelsAsString(), dtype="<f4").reshape(r[1], r[0]), 2)
        owned = protect >= 0.999
        check("fully protected samples keep inherited materials", owned.sum() > 0 and bool(closed[owned].all()),
              {"protected_samples": int(owned.sum())})
        # Previous-stage simulation fields are not re-applied.
        prior_sim = with_prior("prior_materials_and_sim", d0, "@name=material_* @name=erosion_delta @name=sediment @name=debris @name=flow")
        d3 = erosion("detail_prior_sim_fields", prior_sim, raw, **detail_parms)
        d3out = volumes(d3)
        check("previous-stage sediment/debris/flow/delta inputs are ignored",
              all(np.array_equal(d3out[c], d2out[c]) for c in channels))
        # The manual transition is not erosion evidence.
        d4 = erosion("detail_no_transition", prior, raw, **dict(detail_parms, manual_transition=0))
        d4out = volumes(d4)
        check("manual transition changes height but not the material gate or weights",
              not np.array_equal(d4out["height"], d2out["height"]) and np.array_equal(gate_of(d4), gate)
              and all(np.array_equal(d4out["material_" + n], d2out["material_" + n]) for n in names))
        # All-zero prior counts as absent.
        zmix = geo.createNode("volumemix", "zero_prior")  # material fields present, every value 0
        zmix.setInput(0, prior)
        island._set_parms(zmix, group="@name=material_*", mixmethod="copy", postmul=0.0)
        d5 = erosion("detail_all_zero_prior", zmix, raw, **detail_parms)
        d5out, _ = contract_checks("detail all-zero prior", d5, "initialized_all_zero_prior")
        check("all-zero prior == no prior", all(np.array_equal(d5out[c], d0out[c]) for c in channels))
        partial = geo.createNode("blast", "partial_prior")
        partial.setInput(0, prior)
        island._set_parms(partial, group="@name=material_" + names[-1], grouptype="prims")
        d6 = erosion("detail_partial_prior", partial, raw, **detail_parms)
        check(f"partial prior ({len(names) - 1} of {len(names)}) is a node error", bool(d6.errors()) and "send all or none" in " ".join(d6.errors()))
        metrics["detail"] = {k: detail(d2, "material_" + k) for k in
                             ("refined_fraction", "inherited_exact_fraction", "gate_mean", "seconds", "max_nonzero")}
        metrics["detail"]["transition_status"] = detail(d2, "transition_status")
        np.save(os.path.join(args.out_dir, "detail_prior_weights.npy"), d0w.astype("<f4"))
        np.save(os.path.join(args.out_dir, "detail_refined_weights.npy"), d2w.astype("<f4"))
        np.save(os.path.join(args.out_dir, "detail_gate.npy"), gate.astype("<f4"))
        if args.baseline_hda:
            ns_off = erosion("detail_no_slump", crop, raw, **dict(detail_parms, slump_enable=0))
            noff = volumes(ns_off)
            ref = baseline(args.detail_input, args.constraints, detail_parms, True, "baseline_detail")
            check("slump off: detail 9 channels (incl. protection + manual transition) byte-identical to v1",
                  all(np.array_equal(ref[c], noff[c].ravel()) for c in island.CHANNELS),
                  {c: float(np.abs(ref[c] - noff[c].ravel()).max()) for c in island.CHANNELS})
            check("slump on: transition anchors identical to slump off",
                  detail(d0, "transition_anchor_samples") == detail(ns_off, "transition_anchor_samples"))

    failed = [c for c in CHECKS if not c["ok"]]
    metrics["checks"] = CHECKS
    metrics["passed"] = len(CHECKS) - len(failed)
    metrics["failed"] = len(failed)
    with open(os.path.join(args.out_dir, "stage_materials_metrics.json"), "w") as handle:
        json.dump(metrics, handle, indent=2, default=str)
    print(f"[done] {metrics['passed']} passed, {metrics['failed']} failed", flush=True)
    hou.hipFile.clear(suppress_save_prompt=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
