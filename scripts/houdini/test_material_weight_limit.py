#!/usr/bin/env hython
"""Focused artificial limiter fixtures, isolated from the normal island showcase.

Runs numerical checks with Python/NumPy and optionally the saved standalone HDA
in a fresh hython process. Test outputs go only to --out-dir.
"""
import argparse
import os
import sys

sys.dont_write_bytecode = True
import numpy as np

import material_weight_limit as limiter
import build_material_weight_limit_hda as builder

CHECKS = 0


def check(condition, message):
    global CHECKS
    CHECKS += 1
    if not condition:
        raise AssertionError(message)
    print("  ok " + message, flush=True)


def expect_error(function, message):
    try:
        function()
    except ValueError:
        check(True, message)
    else:
        check(False, message)


def numeric():
    w = np.asarray([[.4], [.25], [.15], [.10001], [.09999], [0]])
    original = w.copy()
    q, diagnostics = limiter.limit_weights(w)
    reference = np.maximum(w - .09999, 0)
    reference /= reference.sum(axis=0)
    check(np.allclose(q, reference) and np.array_equal(w, original), "soft fifth subtraction, normalization and immutable input")
    check((q > 0).sum() == 4 and q[4, 0] == 0, "weak channels are zeroed while all channel slots remain")
    check(diagnostics['pre_max_nonzero'] == 5 and diagnostics['post_max_nonzero'] == 4, "pre/post contribution diagnostics")
    check(np.isclose(diagnostics['pre_topk_retained_mean'], .90001) and diagnostics['post_topk_retained_mean'] == 1, "pre/post retained-mass diagnostics")
    random = np.random.default_rng(781).random((32, 1000))
    random /= random.sum(axis=0)
    q, _ = limiter.limit_weights(random)
    reference = np.maximum(random - np.sort(random, axis=0)[-5], 0)
    reference /= reference.sum(axis=0)
    check(np.allclose(q, reference) and np.all((q > 0).sum(axis=0) <= 4),
          "1,000 unordered 32-way inputs agree with full-sort reference and never exceed four positives")
    jump = []
    for epsilon in [1e-3, 1e-5, 1e-7]:
        a, _ = limiter.limit_weights(np.asarray([[.4], [.25], [.15], [.1 + epsilon], [.1 - epsilon]]))
        b, _ = limiter.limit_weights(np.asarray([[.4], [.25], [.15], [.1 - epsilon], [.1 + epsilon]]))
        jump.append(float(np.abs(a - b).sum()))
    check(jump[2] < jump[1] / 90 < jump[0] / 8000, "fourth/fifth exchange converges continuously to zero contribution")
    q, d = limiter.limit_weights(np.full((7, 2), 1.0))
    check(np.array_equal(q[:4], np.full((4, 2), .25)) and np.all(q[4:] == 0) and d['tie_fallback_voxels'] == 2,
          "five-or-more equal maxima use deterministic ascending-channel fallback and count it")
    q, d = limiter.limit_weights(np.zeros((6, 3)))
    check(np.all(q == 0) and d['zero_voxels'] == 3 and d['tie_fallback_voxels'] == 0, "zero coverage stays unassigned")
    sparse = np.asarray([[.7, 0], [.2, 0], [.1, 0], [0, 0], [0, 0]])
    q, _ = limiter.limit_weights(sparse)
    check(np.allclose(q, sparse), "existing normalized mixtures with at most four positives stay unchanged")
    q, _ = limiter.limit_weights(sparse * 27)
    check(np.allclose(q, sparse), "positive input scale does not change the normalized result")
    q, _ = limiter.limit_weights(np.asarray([[1, 0], [2, 0]]), 32)
    check(np.allclose(q[:, 0], [1/3, 2/3]) and np.all(q[:, 1] == 0), "maximum above channel count normalizes only assigned samples")
    q, d = limiter.limit_weights(np.asarray([[3, 4], [3, 1], [1, 0]]), 1)
    check(np.array_equal(q, np.asarray([[1, 1], [0, 0], [0, 0]])) and d['tie_fallback_voxels'] == 1, "k=1 handles dominant ties and ordinary values")
    for values in [np.asarray([[-1.0], [2]]), np.asarray([[np.nan], [2]]), np.asarray([[np.inf], [2]])]:
        expect_error(lambda: limiter.limit_weights(values), "reject negative/nonfinite input")
    for maximum in [0, -1, 1.5, True]:
        expect_error(lambda: limiter.limit_weights(sparse, maximum), "reject invalid maximum")


def saved_hda(path, out_dir):
    import hou
    import test_material_distribution as distribution
    os.makedirs(out_dir, exist_ok=True)
    session = distribution.Session(hou, path, out_dir)
    shape = (3, 4)
    origin, step0, step1 = (12, 0, -7), (0, 0, -2), (3, 0, 0)
    names = ["material_z", "material_a", "material_f", "material_b", "material_y", "material_c"]
    values = [np.full(shape, v) for v in [.4, .25, .15, .10001, .09999, 0]]
    # An unassigned voxel and a deliberately degenerate tie are artificial fixtures.
    for value in values:
        value[0, 0] = 0
        value[0, 1] = 1
    fields = list(zip(names, values, [origin] * 6, [step0] * 6, [step1] * 6))
    fields += [("height", np.arange(12).reshape(shape), origin, step0, step1),
               ("terrain_tint_r", np.full(shape, .37), origin, step0, step1)]
    source = session.load(fields)
    source.parm("python").set(source.parm("python").eval() + '''
geo.addAttrib(hou.attribType.Global, "existing_detail", "keep")
geo.addAttrib(hou.attribType.Prim, "existing_prim", "keep")
point = geo.createPoint()
point.setPosition((17, 8, 3))
polygon = geo.createPolygon()
polygon.addVertex(point)
polygon.setAttribValue("name", "mesh")
geo.createPrimGroup("preserved_group").add(geo.prims()[0])
''')
    before = source.geometry()
    node = session.geo.createNode(builder.OPERATOR)
    node.setInput(0, source)
    node.parm("channels").set(" ".join(names))
    node.cook(force=True)
    after = node.geometry()
    expected, diagnostics = limiter.limit_weights(np.stack(values))
    selected = after.prims()[:6]
    actual = np.stack([np.frombuffer(p.allVoxelsAsString(), dtype='<f4').reshape(shape) for p in selected])
    check(np.allclose(actual, expected, atol=1e-7), "saved standalone HDA executes the embedded shared algorithm")
    check([p.type() for p in before.prims()] == [p.type() for p in after.prims()], "all primitive types/order and non-volume geometry pass through")
    check([p.position() for p in before.points()] == [p.position() for p in after.points()], "point positions and topology remain unchanged")
    check(after.attribValue("existing_detail") == before.attribValue("existing_detail") and [p.attribValue("existing_prim") for p in after.prims()] == [p.attribValue("existing_prim") for p in before.prims()], "existing detail/primitive attributes persist")
    check([p.number() for p in after.findPrimGroup("preserved_group").prims()] == [0], "primitive groups persist")
    check(all(a.transform() == b.transform() and a.indexToPos((0,0,0)) == b.indexToPos((0,0,0)) and a.resolution() == b.resolution()
              for a,b in zip(before.prims()[:8], after.prims()[:8])), "all volume transforms, origins and lattice dimensions persist")
    check(all(a.allVoxelsAsString() == b.allVoxelsAsString() for a,b in zip(before.prims()[6:8], after.prims()[6:8])), "height/tint values remain byte-identical")
    check(all(np.isclose(after.attribValue('hego_material_limit_' + k), v, atol=1e-7) for k,v in diagnostics.items()), "saved HDA publishes all pre/post/tie diagnostics")
    node.parm("channels").set('material_*')
    node.cook(force=True)
    check(all(a.allVoxelsAsString() == b.allVoxelsAsString() for a,b in zip(selected, node.geometry().prims()[:6])), "wildcards use deterministic incoming primitive order")
    node.parm("channels").set(' '.join(reversed(names)))
    node.cook(force=True)
    tie = [np.frombuffer(p.allVoxelsAsString(), dtype='<f4')[1] for p in node.geometry().prims()[:6]]
    check(tie == [0, 0, .25, .25, .25, .25], "explicit caller channel order determines degenerate tie IDs")
    sections = node.type().definition().sections()
    check(sections['hego_material_weight_limit.py'].contents() == builder.helper_source(), "standalone HDA embeds current reusable helper source")
    for channels in ['material_missing', 'material_z material_z', 'material_* material_a', 'height', 'terrain_tint_r', 'mesh']:
        node.parm('channels').set(channels)
        try:
            node.cook(force=True)
        except hou.OperationFailed:
            pass
        check(bool(node.errors()), 'saved HDA rejects missing/duplicate/protected/non-volume selectors: ' + channels)
    # Reuse fresh loader nodes for malformed selected payloads and lattices.
    for label, replacement in [
        ('negative', ('material_y', np.full(shape, -1), origin, step0, step1)),
        ('nonfinite', ('material_y', np.full(shape, np.inf), origin, step0, step1)),
        ('mismatched origin', ('material_y', values[4], (13,0,-7), step0, step1)),
        ('mismatched transform', ('material_y', values[4], origin, (0,0,-3), step1)),
        ('mismatched resolution', ('material_y', np.ones((4,4)), origin, step0, step1)),
    ]:
        broken = session.load(fields[:4] + [replacement] + fields[5:])
        node.setInput(0, broken)
        node.parm('channels').set(' '.join(names))
        try:
            node.cook(force=True)
        except hou.OperationFailed:
            pass
        check(bool(node.errors()), 'saved HDA rejects ' + label)
    arbitrary = ["grass", "rock", "sand", "soil", "moss", "snow"]
    generic_source = session.load(list(zip(arbitrary, values, [origin]*6, [step0]*6, [step1]*6)) + fields[6:])
    node.setInput(0, generic_source)
    node.parm('channels').set(' '.join(arbitrary))
    node.cook(force=True)
    generic = node.geometry()
    check(all(np.allclose(np.frombuffer(p.allVoxelsAsString(),dtype='<f4').reshape(shape), value, atol=1e-7)
              for p,value in zip(generic.prims()[:6], expected)), "explicit arbitrary material names reuse the same limiter")
    check(all(a.allVoxelsAsString() == b.allVoxelsAsString() for a,b in zip(generic_source.geometry().prims()[6:], generic.prims()[6:])),
          "generic arbitrary-name limiting preserves unselected height/tint bytes")
    hou.hipFile.clear(suppress_save_prompt=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hda', default=None)
    parser.add_argument('--out-dir', default='/tmp/hego-material-weight-limit/tests')
    args = parser.parse_args()
    numeric()
    if args.hda:
        saved_hda(args.hda, args.out_dir)
    print('MATERIAL_WEIGHT_LIMIT checks=%d failures=0' % CHECKS, flush=True)


if __name__ == '__main__':
    main()
