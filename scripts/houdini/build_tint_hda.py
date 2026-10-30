#!/usr/bin/env hython
"""Build Sop/hego_terrain_tint::1.0, the terrain-wide tint/AO generator.

A lightweight, tint-only HDA: it reads the cumulative FINAL terrain height
(input 0, any dense orthogonal horizontal lattice) and writes the four HEGo
macro channels terrain_tint_r/g/b (linear multipliers, neutral 1, 0..2) and
terrain_ao (neutral 1, 0..1) on exactly the input lattice. No erosion, no
directional light. Run with Houdini 22.0's hython:

  hython scripts/houdini/build_tint_hda.py             # author demo/island/hda/hego_terrain_tint.hda

The regression is scripts/houdini/test_terrain_tint.py (loads only the saved .hda).
"""

import argparse
import os
import shutil
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(SCRIPT_DIR))
sys.dont_write_bytecode = True

HDA_VERSION = "1.0"
OPERATOR = "hego_terrain_tint::" + HDA_VERSION
HDA_PATH = os.path.join(REPO, "demo", "island", "hda", "hego_terrain_tint.hda")
CONTRACT_PATH = os.path.join(REPO, "demo", "island", "hda", "tint_contract.json")
CHANNELS = ["terrain_tint_r", "terrain_tint_g", "terrain_tint_b", "terrain_ao"]

# Parameter name -> (label, default, min, max, help). All lengths are metres.
FLOAT_PARMS = [
    ("relief_radius", "Relief Radius", 96.0, 4.0, 1024.0,
     "Gaussian sigma (m) of the local mean height that defines broad convexity (ridges, crests)."),
    ("ridge_ratio", "Ridge Ratio", 0.35, 0.001, 1.0,
     "Convexity (height above the local mean / relief_radius) at which the ridge highlight is full."),
    ("ridge_strength", "Ridge Strength", 0.12, 0.0, 1.0,
     "Tint brightening on full ridges (multiplier 1 + strength). Concave terrain is never darkened by tint."),
    ("ao_radius", "AO Radius", 24.0, 2.0, 512.0,
     "Gaussian sigma (m) of the fine cavity scale; a second scale uses 4x this radius."),
    ("ao_ratio", "AO Ratio", 0.25, 0.001, 1.0,
     "Concavity (depth below the local mean / radius) at which a scale's occlusion is full."),
    ("ao_strength", "AO Strength", 0.45, 0.0, 1.0,
     "Maximum occlusion (terrain_ao = 1 - strength in full cavities). terrain_ao is a cavity-derived approximation "
     "from the local mean height, not ray-traced visibility. It is the only cavity darkening."),
    ("variation_scale", "Variation Scale", 320.0, 8.0, 8192.0,
     "Largest wavelength (m) of the subtle world-space colour variation (3 octaves)."),
    ("variation_strength", "Variation Strength", 0.06, 0.0, 0.5,
     "Amplitude of the brightness variation; warm/cool shift uses half of it."),
]
INT_PARMS = [("seed", "Seed", 11, 0, 100000, "World-space variation noise seed.")]

TINT_PY = r'''
# hego_terrain_tint: four copies of the input height volume (same lattice and
# transform) become terrain_tint_r/g/b and terrain_ao. Pure numpy, O(samples).
import time
import numpy as np

node = hou.pwd()
geo = node.geometry()
started = time.time()
if not node.evalParm("target_layer_path"):
    raise hou.NodeError("hego_terrain_tint: target_layer_path is empty")
volumes = [prim for prim in geo.prims() if prim.type() == hou.primType.Volume]
if len(volumes) != 4 or len(geo.prims()) != 4:
    raise hou.NodeError("hego_terrain_tint: input 0 needs exactly one 'height' volume")
source = volumes[0]
res = source.resolution()
if res[2] != 1 or res[0] < 2 or res[1] < 2:
    raise hou.NodeError("hego_terrain_tint: height must be a 2D grid of at least 2x2 samples")
if res[0] > 4097 or res[1] > 4097:
    raise hou.NodeError("hego_terrain_tint: height exceeds 4097 samples per axis; send a coarser cumulative input (terrain_spacing)")
# HAPI can set any value; re-check every parameter (finite, in range).
values = {}
for name, _, _, low, high, _ in FLOAT_PARMS:
    value = float(node.evalParm(name))
    if not np.isfinite(value) or not low <= value <= high:
        raise hou.NodeError("hego_terrain_tint: %s must be finite and in [%g, %g]" % (name, low, high))
    values[name] = value
seed = int(node.evalParm("seed"))
if not 0 <= seed <= 100000:
    raise hou.NodeError("hego_terrain_tint: seed must be in 0..100000")
p = lambda name: values[name]
origin = np.array(source.indexToPos((0, 0, 0)), dtype=np.float64)
step_a = np.array(source.indexToPos((1, 0, 0)), dtype=np.float64) - origin
step_b = np.array(source.indexToPos((0, 1, 0)), dtype=np.float64) - origin
la, lb = float(np.linalg.norm(step_a)), float(np.linalg.norm(step_b))
if not (np.isfinite(origin).all() and np.isfinite(la) and np.isfinite(lb)) or la <= 1e-6 or lb <= 1e-6:
    raise hou.NodeError("hego_terrain_tint: height lattice needs finite nonzero sample steps")
if abs(step_a[1]) > 1e-4 * la or abs(step_b[1]) > 1e-4 * lb or abs(float(np.dot(step_a, step_b))) > 1e-4 * la * lb:
    raise hou.NodeError("hego_terrain_tint: height steps must be horizontal and orthogonal")
height = np.frombuffer(source.allVoxelsAsString(), dtype="<f4").reshape(res[1], res[0]).astype(np.float64)  # [b][a]
if not np.isfinite(height).all():
    raise hou.NodeError("hego_terrain_tint: height contains nonfinite samples")


def box(values, radius, axis):
    if radius <= 0:
        return values
    pad = [(0, 0), (0, 0)]
    pad[axis] = (radius + 1, radius)
    total = np.cumsum(np.pad(values, pad, mode="edge"), axis=axis)
    width = 2 * radius + 1
    upper = [slice(None), slice(None)]
    lower = [slice(None), slice(None)]
    upper[axis] = slice(width, None)
    lower[axis] = slice(None, -width)
    return (total[tuple(upper)] - total[tuple(lower)]) / width


def gaussian(values, sigma_m):
    # Three box passes per axis approximate a Gaussian of sigma_m metres on
    # each axis's own physical step. Edges extend the boundary sample.
    for axis, spacing in ((1, la), (0, lb)):
        sigma = sigma_m / spacing
        radius = int(round((np.sqrt(4.0 * sigma * sigma + 1.0) - 1.0) * 0.5))
        for _ in range(3):
            values = box(values, radius, axis)
    return values


def smooth(edge0, edge1, x):
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def lattice_noise(x, z, scale, seed):
    # Value noise on world XZ: identical at a world point for any lattice.
    u, v = x / scale, z / scale
    iu, iv = np.floor(u), np.floor(v)
    fu, fv = u - iu, v - iv
    fu, fv = fu * fu * (3.0 - 2.0 * fu), fv * fv * (3.0 - 2.0 * fv)
    iu, iv = iu.astype(np.int64), iv.astype(np.int64)

    def corner(dx, dz):
        h = ((iu + dx) * 374761393 + (iv + dz) * 668265263 + seed * 2246822519) & 0xFFFFFFFF
        h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
        h = h ^ (h >> 16)
        return h.astype(np.float64) / 2147483647.5 - 1.0

    top = corner(0, 0) * (1.0 - fu) + corner(1, 0) * fu
    bottom = corner(0, 1) * (1.0 - fu) + corner(1, 1) * fu
    return top * (1.0 - fv) + bottom * fv


def fbm(x, z, scale, seed):
    total, weight = 0.0, 0.0
    for octave in range(3):
        amplitude = 0.5 ** octave
        total = total + amplitude * lattice_noise(x, z, scale / (2 ** octave), seed * 7 + octave)
        weight += amplitude
    return total / weight


relief_radius = p("relief_radius")
relief = (height - gaussian(height, relief_radius)) / relief_radius
ridge = smooth(0.0, p("ridge_ratio"), relief)
ao_radius = p("ao_radius")
cavity = 0.0
for radius, share in ((ao_radius, 0.65), (4.0 * ao_radius, 0.35)):
    depth = (gaussian(height, radius) - height) / radius
    cavity = cavity + share * smooth(0.0, p("ao_ratio"), depth)
ao = np.clip(1.0 - p("ao_strength") * cavity, 0.0, 1.0)

j, i = np.mgrid[0:res[1], 0:res[0]].astype(np.float64)
world_x = origin[0] + i * step_a[0] + j * step_b[0]
world_z = origin[2] + i * step_a[2] + j * step_b[2]
strength = p("variation_strength")
if strength > 0.0:
    brightness_noise = fbm(world_x, world_z, p("variation_scale"), seed)
    warmth = 0.5 * strength * fbm(world_x, world_z, p("variation_scale") * 1.7, seed + 1)
else:
    brightness_noise = 0.0
    warmth = 0.0
brightness = (1.0 + p("ridge_strength") * ridge) * (1.0 + strength * brightness_noise)
tint = [brightness * (1.0 + warmth), brightness, brightness * (1.0 - warmth)]
outputs = [np.clip(channel, 0.0, 2.0) for channel in tint] + [ao]
stats = []
for prim, name, values in zip(volumes, ("terrain_tint_r", "terrain_tint_g", "terrain_tint_b", "terrain_ao"), outputs):
    values = np.ascontiguousarray(values, dtype="<f4")
    prim.setAttribValue("name", name)
    prim.setAllVoxelsFromString(values.tobytes())
    stats.append((float(values.min()), float(values.max()), float(values.mean())))
for key, value in (("operator", "Sop/OPERATOR"), ("seconds", time.time() - started), ("samples", int(res[0] * res[1])),
                   ("spacing_a", la), ("spacing_b", lb), ("seed", seed),
                   ("min", [s[0] for s in stats]), ("max", [s[1] for s in stats]), ("mean", [s[2] for s in stats])):
    name = "hego_tint_" + key
    if geo.findGlobalAttrib(name) is None:
        geo.addAttrib(hou.attribType.Global, name, value)
    geo.setGlobalAttribValue(name, value)
'''.replace("Sop/OPERATOR", "Sop/" + OPERATOR).replace("FLOAT_PARMS", repr([p[:1] + (None, None) + p[3:5] + (None,) for p in FLOAT_PARMS]))

ROUTE_VEX = r"""
s@hegostrata_layer_path = chs("../target_layer_path");
s@hegostrata_role = "value";
s@hegostrata_channel = s@name;
s@hegostrata_composition = "replace";
"""


def log(message):
    print(message, flush=True)


def _parm_templates(hou):
    group = hou.ParmTemplateGroup()
    group.append(hou.StringParmTemplate(
        "target_layer_path", "Target Layer Path", 1, default_value=("",),
        help="Scene path of the mask-only procedural StrataLayer (e.g. ../../Terrain/TerrainTint), "
             "written verbatim to hegostrata_layer_path."))
    for name, label, default, minimum, maximum, text in FLOAT_PARMS:
        group.append(hou.FloatParmTemplate(name, label, 1, default_value=(default,), min=minimum, max=maximum,
                                           min_is_strict=True, help=text))
    for name, label, default, minimum, maximum, text in INT_PARMS:
        group.append(hou.IntParmTemplate(name, label, 1, default_value=(default,), min=minimum, max=maximum,
                                         min_is_strict=True, help=text))
    return group


def build_hda(hou, hda_path, staging_dir):
    final_path = hda_path
    os.makedirs(staging_dir, exist_ok=True)
    hda_path = os.path.join(staging_dir, os.path.basename(final_path))
    hou.hipFile.clear(suppress_save_prompt=True)
    geo = hou.node("/obj").createNode("geo", "tint_build")
    sub = geo.createNode("subnet", "hego_terrain_tint")
    sub.parm("label1").set("Cumulative final terrain height")
    group = sub.parmTemplateGroup()
    for template in _parm_templates(hou).parmTemplates():
        group.append(template)
    sub.setParmTemplateGroup(group)

    terrain_in = sub.indirectInputs()[0]
    keep = sub.createNode("blast", "keep_height")
    keep.setInput(0, terrain_in)
    keep.parm("group").set("@name=height")
    keep.parm("grouptype").set("prims")
    keep.parm("negate").set(1)
    strip = sub.createNode("attribdelete", "strip_input_attributes")
    strip.setInput(0, keep)
    strip.parm("ptdel").set("*")
    strip.parm("vtxdel").set("*")
    strip.parm("primdel").set("* ^name")
    strip.parm("dtldel").set("*")
    merge = sub.createNode("merge", "four_channels")
    for index in range(4):
        merge.setInput(index, strip)
    tint = sub.createNode("python", "tint")
    tint.setInput(0, merge)
    tint.parm("python").set(TINT_PY.strip() + "\n")
    tgroup = tint.parmTemplateGroup()
    tgroup.append(hou.StringParmTemplate("target_layer_path", "Target Layer Path", 1))
    for name, *_ in FLOAT_PARMS:
        tgroup.append(hou.FloatParmTemplate(name, name, 1))
    for name, *_ in INT_PARMS:
        tgroup.append(hou.IntParmTemplate(name, name, 1))
    tint.setParmTemplateGroup(tgroup)
    # Explicit channel references give the Python SOP real parameter dependencies.
    tint.parm("target_layer_path").setExpression('chs("../target_layer_path")', hou.exprLanguage.Hscript)
    for name, *_ in FLOAT_PARMS + INT_PARMS:
        tint.parm(name).setExpression(f'ch("../{name}")')
    route = sub.createNode("attribwrangle", "route")
    route.setInput(0, tint)
    route.parm("class").set("primitive")
    route.parm("snippet").set(ROUTE_VEX.strip() + "\n")
    clean = sub.createNode("attribdelete", "clean_attributes")
    clean.setInput(0, route)
    clean.parm("ptdel").set("*")
    clean.parm("vtxdel").set("*")
    clean.parm("primdel").set("* ^name ^hegostrata_*")
    clean.parm("dtldel").set("* ^hego_tint_*")
    out = sub.createNode("output", "output0")
    out.setInput(0, clean)
    out.setDisplayFlag(True)
    out.setRenderFlag(True)
    from graph_layout import organize, document_definition
    organize(hou, sub, [("Terrain tint and cavity AO", [[(name, 0)] for name in
        ("keep_height", "strip_input_attributes", "four_channels", "tint", "route", "clean_attributes", "output0")])],
        {"keep_height": "Final cumulative height", "four_channels": "Four output lattice templates",
         "tint": "Terrain tint variation and cavity AO", "route": "HEGo channel routing"})

    if os.path.exists(hda_path):
        os.remove(hda_path)
    asset = sub.createDigitalAsset(
        name=OPERATOR, hda_file_name=hda_path, description="Strata Tint",
        min_num_inputs=1, max_num_inputs=1, version=HDA_VERSION,
        ignore_external_references=True, change_node_type=True, create_backup=False)
    definition = asset.type().definition()
    document_definition(hou, definition, _parm_templates(hou), "Strata Tint",
        "Terrain-wide color multipliers and cavity-derived AO on the input lattice.",
        ["Final height:", "    One dense scalar height volume."],
        ["Tint and AO:", "    terrain_tint_r/g/b and terrain_ao. No height or material weights."])
    definition.setIcon("SOP_heightfield_maskbyfeature")
    definition.setComment("HEGo terrain-wide tint/AO from the cumulative final height; built by scripts/houdini/build_tint_hda.py")
    with open(os.path.abspath(__file__)) as handle:
        definition.addSection("hego_build_tint_hda.py", handle.read())
    with open(CONTRACT_PATH) as handle:
        definition.addSection("hego_contract.json", handle.read())
    definition.setExtraFileOption("hego_hda_version", HDA_VERSION)
    definition.updateFromNode(asset)
    definition.save(hda_path, asset, create_backup=False)
    os.makedirs(os.path.dirname(final_path), exist_ok=True)
    shutil.copyfile(hda_path, final_path)
    return final_path


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hda", default=HDA_PATH)
    parser.add_argument("--out-dir", default="/tmp/hego-terrain-prototype/editor-macro/houdini")
    args = parser.parse_args()
    import hou
    start = time.time()
    path = build_hda(hou, args.hda, os.path.join(args.out_dir, "hda-staging"))
    log(f"[hda] saved Sop/{OPERATOR} to {path} in {time.time() - start:.1f}s")
    hou.hipFile.clear(suppress_save_prompt=True)


if __name__ == "__main__":
    main()
