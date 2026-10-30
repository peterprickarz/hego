#!/usr/bin/env hython
"""Dedicated ARTIFICIAL prior fixtures for saved erosion/material HDA adapters.

These tiny fields exercise resampling, coverage and malformed inputs; they are
not showcase terrain or production material assignments. No live scene used.
"""
import os
import sys
import argparse
import numpy as np
import hou
import test_material_distribution as fixture
import build_island_hda as island

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--erosion-hda', required=True)
parser.add_argument('--material-hda', required=True)
parser.add_argument('--out-dir', default='/tmp/hego-material-inheritance')
args = parser.parse_args()
os.makedirs(args.out_dir, exist_ok=True)
session = fixture.Session(hou, args.material_hda, args.out_dir)
hou.hda.installFile(args.erosion_hda)
ns = {}
for filename in ('material_weight_limit.py', 'material_habitat.py', 'material_stage.py'):
    exec(compile(open(os.path.join(island.SCRIPT_DIR, filename)).read(), filename, 'exec'), ns)
NAMES = fixture.NAMES
passed = 0

def check(value, text):
    global passed
    if not value:
        raise AssertionError(text)
    passed += 1
    print('PASS ' + text, flush=True)

n = 17
origin, a, b = (-32., 0., -32.), (4., 0., 0.), (0., 0., 4.)
height = np.full((n, n), 90., dtype=np.float32)
base_fields = [('height', height, origin, a, b)]

def stage(fields):
    node = session.geo.createNode(island.OPERATOR)
    node.setInput(0, session.load(fields))
    for name, value in dict(target_layer_path='../Terrain/Test', output_spacing=4., mask_spacing=4.,
                            erosion_strength=0., freeze_frame=1, manual_transition=0).items():
        node.parm(name).set(value)
    return node

def weights(node):
    node.cook(force=True)
    check(not node.errors(), node.name() + ' clean cook')
    return fixture.weights_of(fixture.outputs(node)).astype('<f4')

def expect_error(node, label):
    try:
        node.cook(force=True)
    except hou.OperationFailed:
        pass
    check(bool(node.errors()), label + ' rejected')

base = weights(stage(base_fields))
palette = np.zeros((len(NAMES), n, n), dtype='<f4')
palette[0], palette[1] = .7, .3
fields = [('material_' + name, palette[i], origin, a, b) for i, name in enumerate(NAMES)]
check(np.array_equal(weights(stage(base_fields + fields)), palette), 'same-grid zero-evidence inherited float32 bytes exact')
force_zero = stage(base_fields + fields)
force_zero.parm('erosion_strength').set(1.)
force_zero.parm('hydro_scale').set(0.)
force_zero.parm('thermal_scale').set(0.)
check(np.array_equal(weights(force_zero), palette), 'both physics forces zero preserve inherited bytes')
final = session.material(session.load(base_fields + fields))
check(np.array_equal(weights(final), palette), 'final inherit float32 bytes exact; scalar diagnostics cook')
# A cropped, rotated and anisotropic prior: outside is unassigned, never edge-clamped.
o, ea, eb = np.array((-8., 0., -16.)), np.array((8., 0., 4.)), np.array((-2., 0., 4.))
small = np.zeros((len(NAMES), 5, 5), dtype='<f4')
small[0], small[1] = .7, .3
owner = np.ones((5, 5), dtype='<f4'); owner[:, 0] = 0.; owner[0, :] = .49
cropped = [('material_' + name, small[i], o, ea, eb) for i, name in enumerate(NAMES)]
cropped += [('material_' + name + '__ownership', owner, o, ea, eb) for name in NAMES]
node = stage(base_fields + cropped)
out = weights(node)
grid = fixture.outputs(node)["material_" + NAMES[0]]
i1, i0 = np.mgrid[:n, :n]
xx = grid['origin'][0] + i0 * grid['step0'][0] + i1 * grid['step1'][0]
zz = grid['origin'][2] + i0 * grid['step0'][2] + i1 * grid['step1'][2]
fa = ((xx-o[0])*ea[0] + (zz-o[2])*ea[2]) / (ea @ ea)
fb = ((xx-o[0])*eb[0] + (zz-o[2])*eb[2]) / (eb @ eb)
sampled, coverage = ns['bilinear_coverage'](fa, fb, (5, 5), small[0], owner)
covered = coverage >= .5
check(covered.any() and (~covered).any() and ((coverage > 0) & (coverage < 1)).any(), 'fixture exercises fractional coverage and cropped exterior')
check(np.array_equal(out[:, ~covered], base[:, ~covered]), 'cropped/unowned exterior initializes locally rather than extending edge weights')
check(np.array_equal(out[0, covered], sampled[covered].astype('<f4')), 'rotated anisotropic coverage-weighted samples retained exactly')
# Coarse two-palette interpolation: with four materials every mixture fits the top-four limit,
# so resampling must reproduce the shared inherit() math exactly without limiting anything.
coarse = np.zeros((len(NAMES), 9, 9), dtype='<f4')
coarse[0:2] = .2
ramp = np.linspace(.16, .24, 9, dtype='<f4')[None]
coarse[2] = ramp; coarse[3] = .6 - ramp
coarse_fields = [('material_' + name, coarse[i], origin, (8.,0.,0.), (0.,0.,8.)) for i,name in enumerate(NAMES)]
node = stage(base_fields + coarse_fields); out = weights(node)
fa, fb = (xx + 32.) / 8., (zz + 32.) / 8.
samples = np.stack([ns['bilinear_coverage'](fa, fb, (9,9), data)[0] for data in coarse])
expected, _, _, stats = ns['inherit'](samples)
check(np.allclose(out, expected.astype('<f4'), atol=2e-7), 'coarse-to-detail resampled prior matches the shared inherit() math')
check(stats['inherit_limited_samples'] == 0 and int((out > 0).sum(0).max()) <= 4, 'four materials never need limiting; the top-four cap still holds')
for eps in (1e-3, 1e-5, 1e-7):
    p = np.zeros((32,1,2)); p[0]=.4; p[1]=.3; p[2]=.2; p[3,0]=(.05-eps,.05+eps); p[4,0]=(.05+eps,.05-eps)
    q, *_ = ns['inherit'](p)
    check(np.abs(q[:,:,0]-q[:,:,1]).sum() < 9*eps, 'fourth/fifth crossover converges continuously eps=%g' % eps)
# Malformed prior basis / values / ownership are explicit node errors.
for label, replacement in [('sheared basis',(8.,0.,1.)), ('nonhorizontal basis',(8.,1.,0.)), ('zero step',(0.,0.,0.))]:
    invalid = [(name,data,o,replacement,eb) for name,data,o,_,_ in coarse_fields]
    expect_error(stage(base_fields + invalid), label)
bad = [(name, data.copy(), o,aa,bb) for name,data,o,aa,bb in fields]; bad[0][1][0,0] = np.nan
expect_error(stage(base_fields + bad), 'nonfinite prior')
mismatch = cropped[:-1] + [(cropped[-1][0], owner, o + (1,0,0), ea, eb)]
expect_error(stage(base_fields + mismatch), 'mismatched ownership basis')
# Final adapter requires its documented common lattice; ownership gaps regenerate.
owners = [('material_' + name + '__ownership', np.broadcast_to((np.arange(n) < 8)[None], (n,n)).astype('<f4'), origin,a,b) for name in NAMES]
node = session.material(session.load(base_fields + fields + owners)); out = weights(node)
generated = weights(session.material(session.load(base_fields)))
check(np.array_equal(out[:,:, :8], palette[:,:, :8]) and np.array_equal(out[:,:,8:], generated[:,:,8:]), 'final ownership gaps fill locally')
expect_error(session.material(session.load(base_fields + fields + [(owners[0][0], owners[0][1], (0,0,0), a,b)])), 'final mismatched ownership lattice')
print('[done] %d inheritance checks passed' % passed, flush=True)
