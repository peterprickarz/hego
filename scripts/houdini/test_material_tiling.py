#!/usr/bin/env hython
"""Locality proof for Sop/HEGo_MaterialDistribution, the basis of the tiled material cook.

  hython scripts/houdini/test_material_tiling.py [--hda PATH] [--out-dir DIR]

The island's material pass above 4097 samples per axis (0.5 m) is cooked in tiles that the
client assembles. That is valid only where a tile's weights equal the whole cook's. The model
(material_habitat.distribute) has no global statistic and no per-sample randomness: every
signal is a window operation on the height lattice (central differences, three-pass box
Gaussians, an exact chamfer distance to the coast that its consumers clamp) plus world-space
plane waves. Nothing is normalised across the lattice. Its dependency radius is therefore
finite but large: the 150 m shelter Gaussian reaches 3 box-pass radii (about 450 m) from a
sample, so a tile reproduces the whole cook only at least that far inside its edge.

This test cooks ARTIFICIAL synthetic terrain (the analytic test island of
test_material_distribution.py, scaled; nothing ships) whole and as overlapping tiles and
compares every weight a tile owns (tile minus a margin of overlap/2 samples on interior
edges) with the whole cook:

  A. 1025x1025 at 16 m, two 545x545 tiles per axis overlapping by 64 samples: the dependency
     radius (about 28 samples) is inside the 32-sample margin, so the tiles must equal the
     whole cook (max |difference| below the float32 rounding of the cook's float64 prefix sums).
  B. 1025x1025 at 4 m, 545x545 tiles with overlaps 32, 64, 128 and the exact overlap for that
     spacing: the error shrinks with the overlap and is at rounding level at the exact one.
     Only the exact overlap is asserted; the others are reported.
  C. A ragged tile grid (the last tile clamped) is assembled to cover every sample once.

The tile grid helpers here are the same algorithm as HEGoIslandMaterials.tile_grid
(demo/island/island_materials.gd); demo/tests/material_tiling_test.gd checks that one.
"""

import argparse
import math
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
sys.dont_write_bytecode = True

import numpy as np  # noqa: E402

import test_material_distribution as base  # noqa: E402
from test_material_distribution import check, grid, island  # noqa: E402

SHELTER_SIGMA_M = 150.0  # the widest Gaussian of material_habitat.signals
DEFAULT_SHORE_WIDTH = 60.0


def box_radius(sigma_samples):
    return int(round((math.sqrt(4.0 * sigma_samples * sigma_samples + 1.0) - 1.0) * 0.5))


def dependency_radius(spacing, shore_width=DEFAULT_SHORE_WIDTH):
    """Samples a weight can depend on: the largest of the shelter Gaussian (three box passes),
    the clamped coast distance (3 x shore_width plus its 4 m Gaussian) and the gradient."""
    shelter = 3 * box_radius(SHELTER_SIGMA_M / spacing)
    shore = math.ceil((3.0 * shore_width + 3 * box_radius(4.0 / spacing) * spacing) / spacing)
    return max(shelter, shore) + 2


def tile_grid(count, tile, overlap):
    """Tiles along one axis of [count] samples: [(start, end_inclusive, owned_start, owned_end_inclusive)].
    As few tiles as fit [tile] samples with at least [overlap] shared; they are balanced to one size
    (about count / n, not [tile] each) and the last is clamped to the end. A cut between neighbours
    lies in the middle of their overlap, so every tile owns all but at least overlap/2 samples of
    each interior edge."""
    if count <= tile:
        return [(0, count - 1, 0, count - 1)]
    overlap = max(0, min(overlap, tile // 2))
    n = 1 + math.ceil((count - tile) / (tile - overlap))
    size = -(-(count + (n - 1) * overlap) // n)
    starts = [min(i * (size - overlap), count - size) for i in range(n)]
    ends = [s + size - 1 for s in starts]
    cuts = [0] + [starts[i + 1] + (ends[i] - starts[i + 1] + 1) // 2 for i in range(n - 1)] + [count]
    return [(starts[i], ends[i], cuts[i], cuts[i + 1] - 1) for i in range(n)]


def scaled_height(x, z, horizontal, vertical):
    return vertical * island(x / horizontal, z / horizontal)


def tiled_weights(session, height, origin, step0, step1, tile, overlap):
    """Cooks [height] as overlapping tiles and assembles the owned parts."""
    n1, n0 = height.shape
    result = np.full((len(base.CHANNELS), n1, n0), np.nan)
    rows, columns = tile_grid(n1, tile, overlap), tile_grid(n0, tile, overlap)
    for r0, r1, ro0, ro1 in rows:
        for c0, c1, co0, co1 in columns:
            sub = height[r0:r1 + 1, c0:c1 + 1]
            sub_origin = tuple(np.array(origin) + np.array(step0) * c0 + np.array(step1) * r0)
            node = session.material(session.load([("height", sub, sub_origin, step0, step1)]))
            base.cook(node)
            w = base.weights_of(base.outputs(node))
            result[:, ro0:ro1 + 1, co0:co1 + 1] = w[:, ro0 - r0:ro1 - r0 + 1, co0 - c0:co1 - c0 + 1]
            node.destroy()
    return result, len(rows) * len(columns)


def compare(whole, tiled, label, assert_below=None):
    covered = np.isfinite(tiled).all()
    difference = np.abs(whole - tiled)
    identical = float((whole.astype("<f4") == tiled.astype("<f4")).mean())
    worst = float(difference.max())
    print(f"       {label}: max |diff| {worst:.3e}, mean {float(difference.mean()):.3e}, bit-identical float32 {identical * 100:.4f}%", flush=True)
    check(covered, f"{label}: every sample is owned by exactly one tile")
    if assert_below is not None:
        check(worst <= assert_below, f"{label}: tiles equal the whole cook (max |diff| {worst:.2e} <= {assert_below:.0e})")
    return worst


def run(hou, args):
    work = os.path.join(args.out_dir, "fixtures")
    os.makedirs(work, exist_ok=True)
    session = base.Session(hou, args.hda, work)
    n, tile = 1025, 545

    print("[1] tile grid helper", flush=True)
    for count, size, overlap in [(1025, 545, 64), (8193, 4097, 32), (8193, 4097, 1800), (4097, 4097, 32), (100, 4097, 32), (1025, 545, 544 // 2)]:
        tiles = tile_grid(count, size, overlap)
        owned = sum(t[3] - t[2] + 1 for t in tiles)
        margins_ok = all((tiles[i][1] - (tiles[i][3])) >= overlap // 2 and (tiles[i + 1][2] - tiles[i + 1][0]) >= overlap // 2 for i in range(len(tiles) - 1))
        check(owned == count and tiles[0][2] == 0 and tiles[-1][3] == count - 1 and all(t[1] - t[0] + 1 <= size for t in tiles) and margins_ok,
              f"{count} samples, tile {size}, overlap {overlap}: {len(tiles)} tiles own every sample once with margin >= overlap/2")

    print("[2] A: 16 m lattice, dependency radius inside the margin (ARTIFICIAL terrain)", flush=True)
    step0, step1 = (16.0, 0.0, 0.0), (0.0, 0.0, 16.0)
    origin = (-8192.0, 0.0, -8192.0)
    x, z = grid(n, n, origin, step0, step1)
    height = scaled_height(x, z, 8.0, 3.0)
    node = session.material(session.load([("height", height, origin, step0, step1)]))
    print(f"       whole cook {base.cook(node):.1f} s; dependency radius {dependency_radius(16.0)} samples, margin {64 // 2}", flush=True)
    whole = base.weights_of(base.outputs(node))
    tiled, count = tiled_weights(session, height, origin, step0, step1, tile, 64)
    check(count == 4, "A: 1025 samples in 545 tiles with overlap 64 make 2x2 tiles")
    compare(whole, tiled, "A 16 m, overlap 64", assert_below=1e-6)

    print("[3] B: 4 m lattice, error against the overlap (ARTIFICIAL terrain)", flush=True)
    step0, step1 = (4.0, 0.0, 0.0), (0.0, 0.0, 4.0)
    origin = (-2048.0, 0.0, -2048.0)
    x, z = grid(n, n, origin, step0, step1)
    height = island(x, z)
    node = session.material(session.load([("height", height, origin, step0, step1)]))
    print(f"       whole cook {base.cook(node):.1f} s", flush=True)
    whole = base.weights_of(base.outputs(node))
    exact = 2 * dependency_radius(4.0)
    print(f"       exact overlap for 4 m: {exact} samples (2 x dependency radius {dependency_radius(4.0)})", flush=True)
    errors = {}
    for overlap in [32, 64, 128, exact]:
        tiled, count = tiled_weights(session, height, origin, step0, step1, tile, overlap)
        errors[overlap] = compare(whole, tiled, f"B 4 m, overlap {overlap} ({count} tiles)", assert_below=1e-6 if overlap == exact else None)
    check(errors[exact] <= errors[32], "B: the exact overlap is at least as close as the 32-sample default")
    print("       note: below the exact overlap a tile differs from the whole cook only near its cut (about 1% of the samples, by up to 0.08 of")
    print("       weight on a synthetic terrain with no stage materials): the long Gaussians see edge-replicated terrain beyond the tile instead of the real one.", flush=True)

    print(f"{base.CHECKS[0]} checks, {len(base.FAILURES)} failed", flush=True)
    return 1 if base.FAILURES else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hda", default=base.builder.HDA_PATH)
    parser.add_argument("--out-dir", default=os.path.join(base.REPO, "build", "material-tiling"))
    args = parser.parse_args()
    import hou
    sys.exit(run(hou, args))


if __name__ == "__main__":
    main()
