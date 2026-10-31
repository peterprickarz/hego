#!/usr/bin/env hython
"""Footpath channel regression for Sop/HEGo_IslandErosion (contract outputs.footpath).

Cooks only the saved .hda in a fresh hython session on the versioned rough base
cache (demo/island/cache, 513x513 @ 8 m) with the coarse caller preset, then
runs the detail preset (2 m height / 4 m masks) on a 512 m crop of that coarse
result. Nothing here writes to the repository, an authoring scene or a cache.

  hython scripts/houdini/test_island_footpaths.py [--hda PATH] [--out-dir DIR]

Checks: channel order and routing, mask lattice, finite 0..1 values, zero on
water and on every non-walkable sample, coverage of land, slope under the limit
(independently recomputed from the published height), one connected component,
footpaths off -> all zeros, determinism for one seed and a different network for
another, and the width parameter.
"""

import argparse
import json
import os
import sys
import time
from collections import deque

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
sys.dont_write_bytecode = True

import build_island_hda as island  # noqa: E402

CHECKS = []
SLOPE_TOLERANCE = 1.5  # degrees; walkability is gated exactly, this only absorbs float32 round-off
CROP_CENTRE, CROP_SIZE = (-1008.0, 592.0), 512.0
COARSE = dict(output_spacing=8.0, mask_spacing=8.0, feature_size=24.0, freeze_frame=24, seed=7, manual_transition=0)
DETAIL = dict(detail_stage=1, output_spacing=2.0, mask_spacing=4.0, feature_size=6.0, freeze_frame=16, seed=8)


def check(label, ok, detail=""):
    CHECKS.append({"label": label, "ok": bool(ok), "detail": detail})
    print(("PASS " if ok else "FAIL ") + label + (": " + str(detail) if detail != "" else ""), flush=True)
    return ok


def components(mask, eight):
    """Connected-component count of a boolean [index1, index0] array (BFS)."""
    import numpy as np
    seen = np.zeros(mask.shape, bool)
    steps = [(a, b) for a in (-1, 0, 1) for b in (-1, 0, 1) if (a or b) and (eight or not (a and b))]
    count = 0
    for start in zip(*np.nonzero(mask)):
        if seen[start]:
            continue
        count += 1
        seen[start] = True
        queue = deque([start])
        while queue:
            r, c = queue.popleft()
            for a, b in steps:
                rr, cc = r + a, c + b
                if 0 <= rr < mask.shape[0] and 0 <= cc < mask.shape[1] and mask[rr, cc] and not seen[rr, cc]:
                    seen[rr, cc] = True
                    queue.append((rr, cc))
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hda", default=island.HDA_PATH)
    parser.add_argument("--out-dir", default="/tmp/hego-footpaths")
    args = parser.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)

    import hou
    import numpy as np

    hou.hipFile.clear(suppress_save_prompt=True)
    hou.hda.installFile(args.hda)
    geo = hou.node("/obj").createNode("geo", "footpaths")
    meta = json.load(open(os.path.join(island.CACHE_DIR, "base_height.json")))
    grid = geo.createNode("heightfield", "base_grid")
    island._set_parms(grid, sampling="corner", divisionmode="size", gridspacing=meta["sample_spacing"],
                      sizex=meta["extent"][0], sizey=meta["extent"][1])
    grid.parm("orient").set("zx")
    base = island._python_sop(hou, geo, "base_load", island.LOAD_RF32_PY, grid)
    group = base.parmTemplateGroup()
    group.append(hou.StringParmTemplate("rf32_path", "RF32", 1, default_value=(os.path.join(island.CACHE_DIR, "base_height.rf32"),)))
    group.append(hou.IntParmTemplate("stride", "Stride", 1, default_value=(1,)))
    base.setParmTemplateGroup(group)
    names = island.CHANNELS + ["material_" + n for n in island.material_names()[0]]
    metrics = {"hda": args.hda, "houdini": hou.applicationVersionString()}

    def erosion(name, source, **parms):
        node = geo.createNode(island.OPERATOR, name)
        node.setInput(0, source)
        node.parm("target_layer_path").set("../Terrain/Test")
        for key, value in parms.items():
            node.parm(key).set(value)
        return node

    def cook(node, label):
        started = time.time()
        try:
            node.cook(force=False)
        except hou.OperationFailed:
            pass
        seconds = time.time() - started
        print(f"[cook] {label}: {seconds:.1f}s errors={list(node.errors())}", flush=True)
        check(f"{label}: no cook errors", not node.errors(), list(node.errors()))
        out = island._volume_arrays(node.geometry())
        g = node.geometry()
        stats = {a.name()[len("hego_island_footpath_"):]: g.attribValue(a) for a in g.globalAttribs()
                 if a.name().startswith("hego_island_footpath_")}
        return out, stats, seconds

    def walkable_and_slope(out, sea, max_slope):
        """Independent restatement of contract outputs.footpath.walkable on the published height."""
        h, m = out["height"], out["footpath"]
        fine = h["data"].astype(np.float64)
        la_f, lb_f = np.linalg.norm(h["step_a"]), np.linalg.norm(h["step_b"])
        k = int(round(np.linalg.norm(m["step_a"]) / la_f))
        nb, na = fine.shape
        # Central differences inside, one-sided at the border.
        g0 = np.empty_like(fine)
        g1 = np.empty_like(fine)
        g0[:, 1:-1] = (fine[:, 2:] - fine[:, :-2]) / (2 * la_f)
        g0[:, 0], g0[:, -1] = (fine[:, 1] - fine[:, 0]) / la_f, (fine[:, -1] - fine[:, -2]) / la_f
        g1[1:-1] = (fine[2:] - fine[:-2]) / (2 * lb_f)
        g1[0], g1[-1] = (fine[1] - fine[0]) / lb_f, (fine[-1] - fine[-2]) / lb_f
        slope_f = np.degrees(np.arctan(np.sqrt(g0 * g0 + g1 * g1)))
        mb, ma = m["data"].shape
        slope = np.full((mb, ma), -np.inf)
        low = np.full((mb, ma), np.inf)
        rows, cols = np.arange(mb) * k, np.arange(ma) * k
        for db in range(-(k - 1), k):
            for da in range(-(k - 1), k):
                r = np.clip(rows + db, 0, nb - 1)[:, None]
                c = np.clip(cols + da, 0, na - 1)[None, :]
                slope = np.maximum(slope, slope_f[r, c])
                low = np.minimum(low, fine[r, c])
        walk = (low > sea + 1.0) & (slope < max_slope)
        return walk, slope, fine[::k, ::k]

    def footpath_checks(label, out, stats, max_slope=30.0, sea=0.0, coverage=(0.005, 0.15)):
        check(f"{label}: channel order (footpath after scree, before materials)", list(out) == names,
              list(out)[8:11])
        attrs = out["footpath"]["attrs"]
        check(f"{label}: footpath routing", attrs.get("hegostrata_role") == "value" and attrs.get("hegostrata_channel") == "footpath"
              and attrs.get("hegostrata_composition") == "replace", attrs)
        ref = out["erosion_delta"]
        same_lattice = all(out["footpath"][key] == ref[key] for key in ("res", "origin", "step_a", "step_b"))
        check(f"{label}: footpath on the mask lattice", same_lattice, out["footpath"]["res"])
        f = out["footpath"]["data"].astype(np.float64)
        check(f"{label}: finite, within [0, 1]", bool(np.isfinite(f).all()) and f.min() >= 0.0 and f.max() <= 1.0,
              (float(f.min()), float(f.max())))
        walk, slope, h = walkable_and_slope(out, sea, max_slope)
        on = f > 0
        water = h < sea
        land = ~water
        check(f"{label}: zero on water", not on[water].any(), int(on[water].sum()))
        check(f"{label}: zero on every non-walkable sample", not on[~walk].any(), int(on[~walk].sum()))
        fraction = float(on.sum() / max(1, land.sum()))
        if coverage:
            check(f"{label}: nonzero fraction of land in [{coverage[0]:.1%}, {coverage[1]:.0%}]",
                  coverage[0] <= fraction <= coverage[1], f"{fraction:.4%} ({int(on.sum())} of {int(land.sum())} land samples)")
        worst = float(slope[on].max()) if on.any() else 0.0
        check(f"{label}: footpath slope < max_slope + {SLOPE_TOLERANCE} deg", worst < max_slope + SLOPE_TOLERANCE, f"max {worst:.2f} deg")
        c8, c4 = components(on, True), components(on, False)
        check(f"{label}: nonzero mask is one connected component", c8 == 1 and c4 == 1, {"8-connected": c8, "4-connected": c4})
        check(f"{label}: centreline samples are 1", int((f == 1.0).sum()) >= int(stats.get("centreline_samples", 0)) > 0,
              {"value_1": int((f == 1.0).sum()), "centreline": stats.get("centreline_samples")})
        check(f"{label}: every waypoint connected", stats.get("status") == "connected"
              and stats.get("connected_waypoints") == stats.get("waypoints") >= 2, stats)
        return {"land_fraction": fraction, "nonzero_samples": int(on.sum()), "land_samples": int(land.sum()),
                "max_slope_deg": worst, "components_8": c8, "components_4": c4, "stats": stats}

    # --- Coarse preset on the whole island -----------------------------------
    a = erosion("coarse_a", base, **COARSE)
    aout, astats, aseconds = cook(a, "coarse seed 7")
    metrics["coarse"] = footpath_checks("coarse", aout, astats)
    metrics["coarse"]["cook_seconds"] = aseconds
    first = aout["footpath"]["data"].copy()
    np.save(os.path.join(args.out_dir, "coarse_footpath.npy"), first)

    a.parm("footpaths").set(0)
    off, ostats, _ = cook(a, "coarse footpaths off")
    check("footpaths off: channel still emitted with routing, all zeros",
          list(off) == names and off["footpath"]["attrs"].get("hegostrata_channel") == "footpath"
          and not off["footpath"]["data"].any(), ostats.get("status"))
    check("footpaths off: other channels unchanged",
          all(np.array_equal(off[n]["data"], aout[n]["data"]) for n in names if n != "footpath"))
    a.parm("footpaths").set(1)
    again, _, _ = cook(a, "coarse footpaths on again")
    check("same node, same seed: byte-identical", np.array_equal(again["footpath"]["data"], first))

    b = erosion("coarse_b", base, **COARSE)
    bout, _, _ = cook(b, "coarse seed 7 (second node)")
    check("second node, same seed: byte-identical", np.array_equal(bout["footpath"]["data"], first))

    a.parm("footpath_width").set(12.0)
    wide, wstats, _ = cook(a, "coarse width 12 m")
    narrow_on, wide_on = int((first > 0).sum()), int((wide["footpath"]["data"] > 0).sum())
    check("width 12 m: wider trails, same centreline", wide_on > narrow_on
          and wstats.get("centreline_samples") == astats.get("centreline_samples"), {"3 m": narrow_on, "12 m": wide_on})
    footpath_checks("coarse width 12 m", wide, wstats, coverage=None)
    a.parm("footpath_width").set(3.0)

    c = erosion("coarse_c", base, **dict(COARSE, seed=8))
    cout, cstats, _ = cook(c, "coarse seed 8")
    metrics["coarse_seed8"] = footpath_checks("coarse seed 8", cout, cstats)
    differs = float((cout["footpath"]["data"] != first).mean())
    check("another seed: different network", differs > 0.0, f"{differs:.4%} of samples differ")

    # --- Detail preset (2 m height / 4 m masks) on a 512 m crop --------------
    keep = geo.createNode("blast", "coarse_height")
    keep.setInput(0, a)
    island._set_parms(keep, group="@name=height", grouptype="prims", negate=1)
    crop = geo.createNode("heightfield_crop", "detail_crop")
    crop.setInput(0, keep)
    crop.parm("orient").set("zx")
    crop.parmTuple("size").set((CROP_SIZE, CROP_SIZE))
    crop.parmTuple("t").set((CROP_CENTRE[0], 0.0, CROP_CENTRE[1]))
    d = erosion("detail_crop", crop, **DETAIL)
    dout, dstats, dseconds = cook(d, "detail crop")
    metrics["detail_crop"] = footpath_checks("detail crop", dout, dstats, coverage=None)
    metrics["detail_crop"]["cook_seconds"] = dseconds
    check("detail crop: 4 m mask lattice", np.isclose(np.linalg.norm(dout["footpath"]["step_a"]), 4.0)
          and np.isclose(np.linalg.norm(dout["height"]["step_a"]), 2.0), dout["footpath"]["res"])

    print("[metrics] " + json.dumps({k: {kk: vv for kk, vv in v.items() if kk != "stats"} | {"seconds": v["stats"].get("seconds")}
                                     for k, v in metrics.items() if isinstance(v, dict)}, default=str), flush=True)
    failed = [c for c in CHECKS if not c["ok"]]
    metrics["checks"] = CHECKS
    with open(os.path.join(args.out_dir, "footpath_metrics.json"), "w") as handle:
        json.dump(metrics, handle, indent=2, default=str)
    print(f"[done] {len(CHECKS) - len(failed)} passed, {len(failed)} failed", flush=True)
    hou.hipFile.clear(suppress_save_prompt=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
