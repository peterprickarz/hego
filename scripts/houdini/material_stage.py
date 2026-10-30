"""Per-stage material refinement shared by the island erosion and material HDAs.

Embedded verbatim after material_weight_limit.py and material_habitat.py (it uses
limit_weights, distribute, gaussian and rise from them); numpy only. Arrays are
[channel, index1, index0] in Houdini heightfield voxel order.

A stage never reclassifies the whole inherited mixture. It computes the habitat
model twice on its own mask lattice: once on the pre-simulation height with no
erosion evidence (base) and once on the protected post-simulation height with
this pass's own simulation fields (evolved). Their difference is the change this
pass's erosion explains. A gate built only from this pass's simulation evidence
decides where that change is applied to the prior. Where the gate is exactly zero
the inherited mixture is published unchanged.
"""
import numpy as np


def tent_downsample(field, stride):
    """Mask-lattice values at every `stride`-th sample of a height-lattice field.

Weighted mean over +-(stride-1) samples with weights (stride-|da|)(stride-|db|),
clipped at the lattice edge and renormalized: the tent filter the erosion HDA's
`masks` node applies to its published channels.
"""
    k = int(stride)
    field = np.asarray(field, dtype=np.float64)
    if k <= 1:
        return field.copy()
    taps = [(d, float(k - abs(d))) for d in range(-(k - 1), k)]

    def along(values, axis):
        centres = np.arange(0, values.shape[axis], k)
        pad = [(0, 0), (0, 0)]
        pad[axis] = (k - 1, k - 1)
        padded = np.pad(values, pad)
        return sum(weight * np.take(padded, centres + d + k - 1, axis=axis) for d, weight in taps)

    ones = np.ones_like(field)
    return along(along(field, 0), 1) / along(along(ones, 0), 1)


def evidence_gate(delta, sediment, debris, flow, protect, la, lb, depth, flow_weight):
    """Where this pass's simulation changed the ground, 0..1; exactly 0 elsewhere.

delta: protected post-simulation height minus pre-simulation height (m), before
any manual-height transition. sediment/debris: this pass's hydraulic sediment and
(slumped) thermal debris (m). flow: this pass's log-normalized flow (0..1); only
flow concentrated relative to its 40 m surroundings counts, using the habitat
model's drainage thresholds. `depth` (m) is the change that fully opens the gate;
nothing below 10% of it counts, so the gate is exactly zero there. Each term is
a smoothstep of an already tent-filtered field, so the gate has no hard seam.
Manual protection closes the gate.
"""
    low = 0.1 * depth
    evidence = np.maximum.reduce([rise(np.abs(delta), low, depth), rise(sediment, low, depth),
                                  rise(debris, low, depth)])
    if flow_weight > 0.0:
        concentrated = gaussian(flow, 6.0, la, lb) - gaussian(flow, 40.0, la, lb)
        evidence = np.maximum(evidence, flow_weight * rise(concentrated, 0.03, 0.08))
    evidence *= 1.0 - np.clip(protect, 0.0, 1.0)
    return np.clip(evidence, 0.0, 1.0)


def inherit(prior, maximum=4, coverage_epsilon=1e-6, sum_tolerance=1e-5):
    """Inherited mixture -> (weights, covered, exact, diagnostics).

prior: weights as received or sampled (all zero where no earlier stage authored
materials). A sample is covered when its total exceeds coverage_epsilon. Samples
that are already valid (at most `maximum` positive weights summing to 1 within
sum_tolerance) keep their values exactly (`exact`): no renormalization and no
limiter. Other covered samples, typically where bilinear resampling of a coarser
prior blends neighbouring palettes into more than `maximum` contributors, are
normalized and passed through the shared soft limiter (limit_weights), so a
fourth/fifth crossing fades continuously instead of being cut. Uncovered
samples are zero.
"""
    prior = np.asarray(prior, dtype=np.float64)
    total = prior.sum(axis=0)
    covered = total > coverage_epsilon
    exact = covered & (np.abs(total - 1.0) <= sum_tolerance) & ((prior > 0).sum(axis=0) <= maximum)
    limited, limit = limit_weights(np.where(covered[None], prior, 0.0), maximum)
    inherited = np.where(exact[None], prior, limited)
    adjusted = covered & ~exact
    movement = 0.5 * np.abs(limited - np.divide(prior, total[None], out=np.zeros_like(prior), where=covered[None])).sum(axis=0)
    diagnostics = {
        "inherit_limited_samples": int((adjusted & ((prior > 0).sum(axis=0) > maximum)).sum()),
        "inherit_renormalized_samples": int(adjusted.sum()),
        "inherit_redistributed_mass_max": float(movement[adjusted].max()) if adjusted.any() else 0.0,
        "inherit_tie_fallback_voxels": limit["tie_fallback_voxels"],
    }
    return inherited, covered, exact, diagnostics


def bilinear_coverage(fa, fb, resolution, data, owned=None, threshold=0.5):
    """Coverage-weighted bilinear sample of one lattice -> (values, coverage).

fa/fb: fractional sample indices along index0/index1 of the source lattice (no
clamping). Source samples outside the lattice, or whose ownership is below
0.5, are unowned. coverage = sum(w * owned); value = sum(w * owned * v) /
coverage where coverage >= threshold, else 0 (unassigned). Fractional index
values within 1e-4 of an integer snap to it, so coincident lattices are exact.
"""
    fa, fb = np.array(fa, dtype=np.float64), np.array(fb, dtype=np.float64)
    for f in (fa, fb):
        near = np.rint(f)
        np.copyto(f, near, where=np.abs(f - near) < 1e-4)
    ia, ib = np.floor(fa).astype(np.int64), np.floor(fb).astype(np.int64)
    ta, tb = fa - ia, fb - ib
    coverage = np.zeros(fa.shape)
    weighted = np.zeros(fa.shape)
    for da in (0, 1):
        for db in (0, 1):
            w = (ta if da else 1.0 - ta) * (tb if db else 1.0 - tb)
            ka, kb = ia + da, ib + db
            inside = (w > 0.0) & (ka >= 0) & (kb >= 0) & (ka < resolution[0]) & (kb < resolution[1])
            ka, kb = np.where(inside, ka, 0), np.where(inside, kb, 0)
            own = inside if owned is None else inside & (owned[kb, ka] >= 0.5)
            coverage += np.where(own, w, 0.0)
            weighted += np.where(own, w * data[kb, ka], 0.0)
    assigned = coverage >= threshold
    return np.where(assigned, weighted / np.where(assigned, coverage, 1.0), 0.0), coverage


def refine(prior, base, evolved, gate, maximum=4, coverage_epsilon=1e-6, sum_tolerance=1e-5):
    """Stage weights -> (weights[n][...] float64, diagnostics).

prior: inherited weights as sampled (all zero where no earlier stage authored
materials). A sample is covered when its prior total exceeds coverage_epsilon.
base/evolved: normalized habitat-model weights without and with this pass's
evidence. Covered samples start from inherit(prior), uncovered ones from base. The evidence-gated transfer gate * (evolved - base) is added,
clamped at zero, normalized and soft limited. Covered samples with gate == 0
publish inherit(prior): sampled values unchanged when already valid, otherwise
normalized and soft limited.
"""
    inherited, covered, exact, inherit_stats = inherit(prior, maximum, coverage_epsilon, sum_tolerance)
    transfer = np.asarray(evolved, dtype=np.float64) - base
    mixed = np.where(covered[None], inherited, base)
    mixed += gate[None] * transfer
    del transfer
    np.maximum(mixed, 0.0, out=mixed)
    mixed /= mixed.sum(axis=0)[None]
    limited, limit = limit_weights(mixed, maximum)
    del mixed
    keep = covered & (gate == 0.0)
    np.copyto(limited, inherited, where=keep[None])
    samples = float(gate.size)
    diagnostics = {
        "prior_covered_fraction": float(covered.sum()) / samples,
        "inherited_exact_fraction": float((keep & exact).sum()) / samples,
        "inherited_unrefined_fraction": float(keep.sum()) / samples,
        "refined_fraction": float((gate > 0.0).sum()) / samples,
        "gate_mean": float(gate.mean()),
        "limit_redistributed_mass_mean": limit["redistributed_mass_mean"],
        "limit_tie_fallback_voxels": limit["tie_fallback_voxels"],
    }
    diagnostics.update(inherit_stats)
    return limited, diagnostics
