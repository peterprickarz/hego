"""Reusable soft top-k material limiting; this source is embedded into both HDAs.

Arrays are [stable channel order, ...voxel dimensions]. Channels stay present.
No Houdini or project imports are needed by limit_weights().
"""
import fnmatch
import numpy as np


def limit_weights(weights, maximum=4):
    """Return normalized soft top-k weights and pre/post diagnostics.

Subtract rank k+1 before normalizing, so a changing kth material reaches zero
at its selection boundary. Five equal maxima at k=4 are degenerate: retain
original top-k weights, breaking ties by ascending input channel index.
All-zero voxels remain unassigned. Input is never changed.
"""
    source = np.asarray(weights, dtype=np.float64)
    if source.ndim < 2 or source.shape[0] < 1:
        raise ValueError("weights need a channel axis and at least one voxel axis")
    if isinstance(maximum, bool) or int(maximum) != maximum or maximum < 1:
        raise ValueError("maximum must be a positive integer")
    if not np.isfinite(source).all() or np.any(source < 0):
        raise ValueError("material weights must be finite and nonnegative")
    maximum = min(int(maximum), source.shape[0])
    total = source.sum(axis=0)
    if not np.isfinite(total).all():
        raise ValueError("material weight totals must be finite")
    assigned = total > 0
    normalized = np.divide(source, total[None], out=np.zeros_like(source), where=assigned[None])
    # Partition at rank k+1 itself; the preceding element of a partition at
    # rank k would not be ordered and cannot supply the cutoff.
    pivot = source.shape[0] - maximum - 1
    ordered = np.partition(normalized, max(pivot, 0), axis=0)
    retained = ordered[-maximum:].sum(axis=0)
    threshold = ordered[pivot] if pivot >= 0 else np.zeros_like(total)
    result = np.maximum(normalized - threshold[None], 0)
    remaining = result.sum(axis=0)
    degenerate = assigned & (remaining == 0)
    # Restrict stable sorting to degenerate voxels. Stable sort retains the
    # ascending channel index for exact ties, matching native/GPU ordering.
    if np.any(degenerate):
        flat = result.reshape(source.shape[0], -1)
        values = normalized.reshape(source.shape[0], -1)[:, degenerate.ravel()]
        chosen = np.argsort(-values, axis=0, kind="stable")[:maximum]
        fallback = np.zeros_like(values)
        np.put_along_axis(fallback, chosen, np.take_along_axis(values, chosen, axis=0), axis=0)
        flat[:, degenerate.ravel()] = fallback
        remaining = result.sum(axis=0)
    result = np.divide(result, remaining[None], out=np.zeros_like(result), where=(remaining > 0)[None])
    active = retained[assigned]
    movement = 0.5 * np.abs(result - normalized).sum(axis=0)
    diagnostics = {
        "maximum": maximum,
        "assigned_voxels": int(assigned.sum()),
        "zero_voxels": int((~assigned).sum()),
        "tie_fallback_voxels": int(degenerate.sum()),
        "pre_max_nonzero": int((source > 0).sum(axis=0).max()),
        "post_max_nonzero": int((result > 0).sum(axis=0).max()),
        "pre_topk_retained_mean": float(active.mean()) if active.size else 1.0,
        "pre_topk_retained_min": float(active.min()) if active.size else 1.0,
        "post_topk_retained_mean": 1.0,
        "post_topk_retained_min": 1.0,
        "redistributed_mass_mean": float(movement[assigned].mean()) if active.size else 0.0,
        "redistributed_mass_max": float(movement.max()),
    }
    return result, diagnostics


# This adapter edits Houdini's copied input geometry in place. Unselected
# primitives, transforms, topology and existing attributes are untouched.
SOP_ADAPTER = r'''
node = hou.pwd()
geo = node.geometry()
try:
    selectors = node.evalParm("channels").split()
    if not selectors:
        raise ValueError("Channels must explicitly list material volume names or patterns")
    selected = []
    names = set()
    for selector in selectors:
        matches = [p for p in geo.prims() if geo.findPrimAttrib("name") and fnmatch.fnmatchcase(p.attribValue("name"), selector)]
        if not matches:
            raise ValueError("Channel selector '%s' matches no primitives" % selector)
        for prim in matches:
            name = prim.attribValue("name")
            if name == "height" or name.startswith("height__") or name.startswith("terrain_tint_") or name == "terrain_ao":
                raise ValueError("Height and terrain tint/AO fields are not material weights: " + name)
            if name in names or prim.type() != hou.primType.Volume:
                raise ValueError("Channel '%s' must be unique and a dense scalar Volume" % name)
            selected.append(prim)
            names.add(name)
    first = selected[0]
    resolution = tuple(first.resolution())
    transform = np.asarray(first.transform().asTuple())
    origin = np.asarray(first.indexToPos((0, 0, 0)))
    for prim in selected[1:]:
        if (tuple(prim.resolution()) != resolution
                or not np.allclose(np.asarray(prim.transform().asTuple()), transform, atol=1e-6, rtol=0)
                or not np.allclose(np.asarray(prim.indexToPos((0, 0, 0))), origin, atol=1e-6, rtol=0)):
            raise ValueError("Material volumes must share the exact resolution and transform; nothing is resampled")
    data = np.stack([np.frombuffer(p.allVoxelsAsString(), dtype="<f4") for p in selected])
    limited, diagnostics = limit_weights(data, node.evalParm("maximum"))
    for prim, values in zip(selected, limited):
        prim.setAllVoxelsFromString(np.ascontiguousarray(values, dtype="<f4").tobytes())
    for key, value in diagnostics.items():
        name = "hego_material_limit_" + key
        if geo.findGlobalAttrib(name) is None:
            geo.addAttrib(hou.attribType.Global, name, value)
        geo.setGlobalAttribValue(name, value)
except ValueError as error:
    raise hou.NodeError("hego_material_weight_limit: " + str(error))
'''
