#!/usr/bin/env hython
"""Build Sop/hego_material_distribution::1.0, the registry-material weight generator.

A mask-only HDA, the final MaterialCook pass: it reads the cumulative FINAL
terrain height (input 0, volume 'height', a dense orthogonal horizontal lattice
such as 1025^2 at 4 m), the optional erosion masks flow / sediment / debris /
erosion_delta and the optional stage material_<name> fields authored by the
erosion HDAs, all on exactly the same lattice, and writes one normalized weight
volume per registry material, at most four positive contributions per sample
(every registry channel persists), material_<name> in registry id order, on
exactly the input lattice. Valid normalized stage mixtures with at most four contributors are
published byte-exact (Prior Stage Materials = inherit); the habitat model
(material_habitat.py) fills the rest. It never outputs or modifies height or any
other layer. Run with Houdini 22.0's hython:

  hython scripts/houdini/build_material_distribution_hda.py   # author demo/island/hda/hego_material_distribution.hda

The registry (demo/island/materials/material_registry.json) is the only
channel list; this script validates it and embeds it, the contract and its own
source in the HDA. The regression is scripts/houdini/test_material_distribution.py
(loads only the saved .hda).
"""

import argparse
import hashlib
import json
import os
import shutil
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(SCRIPT_DIR))
sys.dont_write_bytecode = True

HDA_VERSION = "1.0"
OPERATOR = "hego_material_distribution::" + HDA_VERSION
HDA_PATH = os.path.join(REPO, "demo", "island", "hda", "hego_material_distribution.hda")
CONTRACT_PATH = os.path.join(REPO, "demo", "island", "hda", "material_contract.json")
REGISTRY_PATH = os.path.join(REPO, "demo", "island", "materials", "material_registry.json")
OPTIONAL_MASKS = ("flow", "sediment", "debris", "erosion_delta")
MAX_SAMPLES = 1025  # per axis; the island packer (pack_material_weights) accepts at most 1025
PACKER_SLOTS = 4  # soft limit matches the native packer; every registry field remains present
WEIGHT_LIMIT_PATH = os.path.join(SCRIPT_DIR, "material_weight_limit.py")
HABITAT_PATH = os.path.join(SCRIPT_DIR, "material_habitat.py")
STAGE_PATH = os.path.join(SCRIPT_DIR, "material_stage.py")


def weight_limit_source():
    with open(WEIGHT_LIMIT_PATH) as handle:
        return handle.read()

# Parameter name -> (label, default, min, max, help). Heights are metres above sea_level.
FLOAT_PARMS = [
    ("sea_level", "Sea Level", 0.0, -500.0, 500.0,
     "Absolute height (m) of the shoreline. Samples at or below it are sea floor."),
    ("beach_height", "Beach Height", 6.0, 0.5, 50.0,
     "Top (m above sea level) of beach sand; coastal materials fade out by twice this height."),
    ("shore_width", "Shore Width", 60.0, 4.0, 1000.0,
     "Horizontal distance (m) from the coastline over which beach and shore rock fade out (sea cliffs reach 2.5x)."),
    ("cliff_slope", "Cliff Slope", 40.0, 15.0, 80.0,
     "Slope (degrees) where bare rock is half exposed; the transition spans -8..+4 degrees."),
    ("tree_line", "Tree Line", 240.0, 0.0, 5000.0,
     "Height (m above sea level) of the upper forest limit; alpine heath above it."),
    ("snow_line", "Snow Line", 330.0, 0.0, 9000.0,
     "Height (m above sea level) where snow starts on unshaded slopes; shaded slopes hold snow up to 30 m lower."),
    ("sun_azimuth", "Sun Azimuth", 128.0, -360.0, 360.0,
     "Horizontal direction TOWARD the sun in degrees from +X toward +Z (128 = the island showcase Sun). "
     "Faces turned away from it are shaded: moister, mossier and colder."),
    ("variation_scale", "Variation Scale", 420.0, 32.0, 16384.0,
     "Base wavelength (m) of the smooth world-space geology/vegetation fields that choose between variants."),
    ("sharpness", "Sharpness", 2.5, 1.0, 8.0,
     "Exponent applied to variant affinities inside a habitat; higher gives crisper, larger variant regions."),
]
INT_PARMS = [("seed", "Seed", 32, 0, 100000, "Seed of the world-space variation fields (plane-wave directions and phases).")]
# name, label, items, labels, default index, help
MENU_PARMS = [("prior_materials", "Prior Stage Materials", ["inherit", "regenerate"],
               ["Keep Stage Materials (fill gaps)", "Regenerate From Final Height"], 0,
               "Inherit (default): covered normalized mixtures with at most four positive weights keep their "
               "float32 values exactly. Other covered mixtures use the shared soft limiter with explicit "
               "redistribution and tie diagnostics. Erosion masks are not applied again. Only uncovered "
               "samples use the final-height habitat model, so habitat controls affect those gaps. "
               "Regenerate: ignore stage materials and generate every sample (contract v2 behavior).")]



def load_registry(path=REGISTRY_PATH):
    """The registry is authoritative: 1 to 32 entries, id == material_id == index, channel == material_<name>."""
    with open(path, "rb") as handle:
        raw = handle.read()
    entries = json.loads(raw)
    if not isinstance(entries, list) or not 1 <= len(entries) <= 32:
        raise ValueError("material registry must list 1 to 32 materials")
    names = []
    for index, entry in enumerate(entries):
        name = entry.get("name")
        if entry.get("id") != index or entry.get("material_id") != index:
            raise ValueError(f"registry entry {index} has id {entry.get('id')} / material_id {entry.get('material_id')}")
        if not isinstance(name, str) or not name or entry.get("channel") != "material_" + name:
            raise ValueError(f"registry entry {index}: channel must be material_<name>")
        names.append(name)
    if len(set(names)) != len(names):
        raise ValueError("registry names must be unique")
    return entries, hashlib.sha256(raw).hexdigest()


def check_contract(entries, registry_sha, path=CONTRACT_PATH):
    """The adjacent contract must describe exactly this registry and interface."""
    with open(path) as handle:
        contract = json.load(handle)
    problems = []
    if contract.get("operator") != "Sop/" + OPERATOR:
        problems.append("operator")
    if contract.get("registry", {}).get("sha256") != registry_sha:
        problems.append("registry sha256 (update the contract after a registry change)")
    if contract.get("outputs", {}).get("channels") != [entry["channel"] for entry in entries]:
        problems.append("outputs.channels")
    parameters = contract.get("parameters", {})
    expected = {"target_layer_path": ("string", "", None)}
    expected.update({p[0]: ("float", p[2], [p[3], p[4]]) for p in FLOAT_PARMS})
    expected.update({p[0]: ("int", p[2], [p[3], p[4]]) for p in INT_PARMS})
    expected.update({p[0]: ("menu", p[2][p[4]], None) for p in MENU_PARMS})
    if set(parameters) != set(expected):
        problems.append("parameter names")
    for name, (kind, default, bounds) in expected.items():
        entry = parameters.get(name, {})
        if entry.get("type") != kind or entry.get("default") != default or (bounds and entry.get("range") != bounds):
            problems.append("parameter " + name)
    if problems:
        raise ValueError(f"{path} disagrees with the builder: {', '.join(problems)}")
    return contract


def core_source():
    """The habitat model (distribute() and its signals), shared with the erosion HDA's stage materials."""
    with open(HABITAT_PATH) as handle:
        return handle.read()



SOP_PY = r'''
# hego_material_distribution: one copy of the input height volume per registry material (same lattice
# and transform) become the registry material weights. Mask-only; pure numpy.
import time

node = hou.pwd()
geo = node.geometry()
started = time.time()


def fail(message):
    raise hou.NodeError("hego_material_distribution: " + message)


if not node.evalParm("target_layer_path").strip():
    fail("target_layer_path is empty")
prims = geo.prims()
if len(prims) != len(NAMES) or any(prim.type() != hou.primType.Volume for prim in prims):
    fail("input 0 needs exactly one 'height' Volume primitive (2D scalar heightfield, not VDB)")
source = prims[0]
res = source.resolution()
if res[2] != 1 or res[0] < 3 or res[1] < 3:
    fail("height must be a 2D grid of at least 3x3 samples")
if res[0] > MAX_SAMPLES or res[1] > MAX_SAMPLES:
    fail("height exceeds %d samples per axis; send the cumulative final height with terrain_spacing 4.0" % MAX_SAMPLES)
values = {}
for name, low, high in FLOAT_RANGES:
    value = float(node.evalParm(name))
    if not np.isfinite(value) or not low <= value <= high:
        fail("%s must be finite and in [%g, %g]" % (name, low, high))
    values[name] = value
seed = int(node.evalParm("seed"))
if not 0 <= seed <= 100000:
    fail("seed must be in 0..100000")
values["seed"] = seed
origin = np.array(source.indexToPos((0, 0, 0)), dtype=np.float64)
step_a = np.array(source.indexToPos((1, 0, 0)), dtype=np.float64) - origin
step_b = np.array(source.indexToPos((0, 1, 0)), dtype=np.float64) - origin
la, lb = float(np.linalg.norm(step_a)), float(np.linalg.norm(step_b))
if not (np.isfinite(origin).all() and np.isfinite(la) and np.isfinite(lb)) or la <= 1e-6 or lb <= 1e-6:
    fail("height lattice needs finite nonzero sample steps")
if abs(step_a[1]) > 1e-4 * la or abs(step_b[1]) > 1e-4 * lb or abs(float(np.dot(step_a, step_b))) > 1e-4 * la * lb:
    fail("height steps must be horizontal and orthogonal")
height = np.frombuffer(source.allVoxelsAsString(), dtype="<f4").reshape(res[1], res[0]).astype(np.float64)  # [b][a]
if not np.isfinite(height).all():
    fail("height contains nonfinite samples")

# Optional erosion masks: read from the untouched input (second wire), never copied.
masks = {name: np.zeros_like(height) for name in OPTIONAL_MASKS}
present = []
# Origin, first steps and far edges: a tiny spacing difference accumulates across the lattice.
corner_index = ((0, 0, 0), (1, 0, 0), (0, 1, 0), (res[0] - 1, 0, 0), (0, res[1] - 1, 0))
corners = [np.array(source.indexToPos(index), dtype=np.float64) for index in corner_index]
for prim in node.inputs()[1].geometry().prims():
    name = prim.attribValue("name") if prim.geometry().findPrimAttrib("name") else ""
    if name not in OPTIONAL_MASKS:
        continue
    if name in present:
        fail("more than one '%s' volume on input 0" % name)
    if prim.type() != hou.primType.Volume:
        fail("optional mask '%s' must be a Volume primitive" % name)
    if tuple(prim.resolution()) != tuple(res):
        fail("optional mask '%s' resolution %s differs from height %s; masks must share the exact height lattice" % (name, tuple(prim.resolution()), tuple(res)))
    for index, corner in zip(corner_index, corners):
        if np.abs(np.array(prim.indexToPos(index), dtype=np.float64) - corner).max() > 1e-4:
            fail("optional mask '%s' origin/steps differ from height; masks must share the exact height lattice" % name)
    data = np.frombuffer(prim.allVoxelsAsString(), dtype="<f4").reshape(res[1], res[0]).astype(np.float64)
    if not np.isfinite(data).all():
        fail("optional mask '%s' contains nonfinite samples" % name)
    if name == "flow" and (data.min() < -1e-4 or data.max() > 1.0 + 1e-4):
        fail("optional mask 'flow' must be in 0..1")
    if name in ("sediment", "debris") and data.min() < -1e-4:
        fail("optional mask '%s' must be >= 0 metres" % name)
    masks[name] = data
    present.append(name)
# A declared but all-zero field carries no simulation evidence (for example a
# stage that has not cooked yet); like a missing field it is reported unavailable.
all_zero = [name for name in present if not masks[name].any()]
unavailable = [name for name in OPTIONAL_MASKS if name not in present or name in all_zero]

# Optional prior stage materials (third wire: material_* volumes of input 0) on the
# exact height lattice: all registry channels or none.
prior_mode = PRIOR_MODES[int(node.evalParm("prior_materials"))]
prior = {}
prior_prims = node.inputs()[2].geometry().prims()
prior_owners = {}
for owner in prior_prims:
    owner_name = owner.attribValue("name") if owner.geometry().findPrimAttrib("name") else ""
    if not owner_name.endswith("__ownership"):
        continue
    channel = owner_name[:-len("__ownership")]
    if channel[len("material_"):] not in NAMES:
        continue
    if channel in prior_owners:
        fail("more than one '%s' ownership volume on input 0" % channel)
    if owner.type() != hou.primType.Volume or tuple(owner.resolution()) != tuple(res):
        fail("prior '%s__ownership' must share the exact height lattice" % channel)
    for index, corner in zip(corner_index, corners):
        if np.abs(np.array(owner.indexToPos(index), dtype=np.float64) - corner).max() > 1e-4:
            fail("prior '%s__ownership' origin/steps differ from height" % channel)
    owned = np.frombuffer(owner.allVoxelsAsString(), dtype="<f4").reshape(res[1], res[0])
    if not np.isfinite(owned).all():
        fail("prior '%s__ownership' must be finite" % channel)
    prior_owners[channel] = owned >= 0.5
for prim in prior_prims:
    name = prim.attribValue("name") if prim.geometry().findPrimAttrib("name") else ""
    if name[len("material_"):] not in NAMES:
        continue
    if name in prior:
        fail("more than one '%s' volume on input 0" % name)
    if prim.type() != hou.primType.Volume or tuple(prim.resolution()) != tuple(res):
        fail("prior '%s' must be a Volume on the exact height lattice" % name)
    for index, corner in zip(corner_index, corners):
        if np.abs(np.array(prim.indexToPos(index), dtype=np.float64) - corner).max() > 1e-4:
            fail("prior '%s' origin/steps differ from height; prior materials must share the exact height lattice" % name)
    data = np.frombuffer(prim.allVoxelsAsString(), dtype="<f4").reshape(res[1], res[0]).astype(np.float64)
    if not np.isfinite(data).all() or data.min() < -1e-6:
        fail("prior '%s' must be finite and >= 0" % name)
    prior[name] = data
if prior_owners:
    common_owned = np.logical_and.reduce(list(prior_owners.values()))
    prior = {name: np.where(common_owned, data, 0.0) for name, data in prior.items()}
if prior and len(prior) != len(NAMES):
    fail("input 0 carries %d of the %d registry material channels; send all or none" % (len(prior), len(NAMES)))

unit_a, unit_b = step_a / la, step_b / lb
i1, i0 = np.mgrid[0:res[1], 0:res[0]].astype(np.float64)
frame = {"la": la, "lb": lb, "ua": (unit_a[0], unit_a[2]), "ub": (unit_b[0], unit_b[2]),
         "x": origin[0] + i0 * step_a[0] + i1 * step_b[0], "z": origin[2] + i0 * step_a[2] + i1 * step_b[2]}
raw_weights, zone = distribute(height, masks, frame, values, NAMES)
raw_weights = raw_weights.astype("<f4").astype(np.float64)
raw_retained = top_retained(raw_weights, PACKER_SLOTS)
weights, limit_diagnostics = limit_weights(raw_weights, PACKER_SLOTS)
# Stage materials already express the erosion evidence; the final pass publishes
# them unchanged and generates only uncovered samples.
mode, prior_status, covered_fraction, exact_fraction, inherit_stats = "standalone", "absent", 0.0, 0.0, {}
if prior:
    prior_status = "ignored"
    if prior_mode == "inherit":
        inherited, covered, exact, inherit_stats = inherit(np.maximum(np.stack([prior["material_" + n] for n in NAMES]), 0.0),
                                                       PACKER_SLOTS)
        prior_status = "all_zero"
        if covered.any():
            mode, prior_status = "inherit", "inherited"
            covered_fraction, exact_fraction = float(covered.mean()), float(exact.mean())
            weights = np.where(covered[None], inherited, weights)
        del inherited
    else:
        mode = "regenerate"
weights = weights.astype("<f4")
if not np.isfinite(weights).all() or weights.min() < 0.0:
    fail("internal error: nonfinite or negative weight")
wide = weights.astype(np.float64)
sums = wide.sum(axis=0)
for prim, name, data in zip(prims, NAMES, weights):
    prim.setAttribValue("name", "material_" + name)
    prim.setAllVoxelsFromString(np.ascontiguousarray(data).tobytes())
dominant = np.bincount(np.argmax(weights, axis=0).ravel(), minlength=len(NAMES)) / float(height.size)
retained = top_retained(wide, PACKER_SLOTS)
diagnostics = [("operator", "Sop/OPERATOR"), ("registry_sha256", REGISTRY_SHA256), ("seconds", time.time() - started),
               ("samples", int(height.size)), ("spacing_a", la), ("spacing_b", lb), ("seed", seed),
               ("optional_masks", " ".join(present)), ("unavailable_masks", " ".join(unavailable)),
               ("all_zero_masks", " ".join(all_zero)), ("mode", mode), ("prior_status", prior_status),
               ("prior_covered_fraction", covered_fraction), ("inherited_exact_fraction", exact_fraction),
               ("generated_fraction", 1.0 - covered_fraction), ("inherit_truncated_samples", inherit_stats.get("inherit_limited_samples", 0)),
               ("max_sum_error", float(np.abs(sums - 1.0).max())),
               ("max_nonzero", int((weights > 0.0).sum(axis=0).max())),
               ("top4_retained_mean", float(retained.mean())), ("top4_retained_min", float(retained.min())),
               ("raw_max_nonzero", int((raw_weights > 0.0).sum(axis=0).max())),
               ("raw_top4_retained_mean", float(raw_retained.mean())), ("raw_top4_retained_min", float(raw_retained.min())),
               ("mean_weight", [float(w) for w in wide.mean(axis=(1, 2))]),
               ("dominant_fraction", [float(f) for f in dominant]),
               ("zones", " ".join(sorted(zone))), ("zone_mean", [float(zone[k].mean()) for k in sorted(zone)])]
diagnostics += list(inherit_stats.items())
diagnostics += [("limit_" + key, value) for key, value in limit_diagnostics.items()]
for key, value in diagnostics:
    name = "hego_material_" + key
    if geo.findGlobalAttrib(name) is None:
        geo.addAttrib(hou.attribType.Global, name, value)
    geo.setGlobalAttribValue(name, value)
'''

ROUTE_VEX = r"""
s@hegostrata_layer_path = chs("../target_layer_path");
s@hegostrata_role = "value";
s@hegostrata_channel = s@name;
s@hegostrata_composition = "replace";
"""


def sop_code(names, registry_sha):
    header = "\n".join([
        "NAMES = " + repr(list(names)),
        "REGISTRY_SHA256 = " + repr(registry_sha),
        "OPTIONAL_MASKS = " + repr(OPTIONAL_MASKS),
        "MAX_SAMPLES = %d" % MAX_SAMPLES,
        "PACKER_SLOTS = %d" % PACKER_SLOTS,
        "FLOAT_RANGES = " + repr([(p[0], p[3], p[4]) for p in FLOAT_PARMS]),
        "PRIOR_MODES = " + repr(MENU_PARMS[0][2]),
    ])
    with open(STAGE_PATH) as handle:
        stage = handle.read()
    return (weight_limit_source() + "\n" + core_source().strip() + "\n\n" + stage.strip() + "\n\n" + header + "\n"
            + SOP_PY.replace("Sop/OPERATOR", "Sop/" + OPERATOR))


def core_namespace():
    """The model as a plain module namespace (for builder self-checks, not the test)."""
    namespace = {}
    exec(compile(core_source(), "hego_material_core", "exec"), namespace)
    return namespace


def log(message):
    print(message, flush=True)


def _parm_templates(hou):
    group = hou.ParmTemplateGroup()
    group.append(hou.StringParmTemplate(
        "target_layer_path", "Target Layer Path", 1, default_value=("",),
        help="Scene path of the mask-only procedural StrataLayer (e.g. ../../Terrain/MaterialDistribution), "
             "written verbatim to hegostrata_layer_path."))
    for name, label, default, minimum, maximum, text in FLOAT_PARMS:
        group.append(hou.FloatParmTemplate(name, label, 1, default_value=(default,), min=minimum, max=maximum,
                                           min_is_strict=True, max_is_strict=True, help=text))
    for name, label, default, minimum, maximum, text in INT_PARMS:
        group.append(hou.IntParmTemplate(name, label, 1, default_value=(default,), min=minimum, max=maximum,
                                         min_is_strict=True, max_is_strict=True, help=text))
    for name, label, items, labels, default, text in MENU_PARMS:
        group.append(hou.MenuParmTemplate(name, label, items, menu_labels=labels, default_value=default, help=text))
    return group


INPUT_LABEL = "Cumulative final height (+ optional flow, sediment, debris, erosion_delta, stage material_* fields)"
NODE_NOTES = {
    "keep_height": "Final cumulative height",
    "strip_input_attributes": "Height lattice template, attributes stripped",
    "registry_channels": "one copy per registry material -> material_<name> outputs (registry order)",
    "keep_optional_masks": "Optional flow / sediment / debris / erosion_delta (missing or all-zero = unavailable)",
    "keep_prior_materials": "Optional stage materials from the erosion HDAs (all registry channels or none)",
    "distribute": "Inherit stage materials; habitat model only where none exist (or Regenerate)",
    "route": "HEGo routing attributes",
    "clean_attributes": "Strip scratch attributes; keep hego_material_* diagnostics",
    "output0": "Asset output",
}
def _document(hou, sub):
    from graph_layout import organize, MATERIAL_STAGES
    organize(hou, sub, MATERIAL_STAGES, NODE_NOTES)


def build_hda(hou, hda_path, staging_dir):
    entries, registry_sha = load_registry()
    names = [entry["name"] for entry in entries]
    check_contract(entries, registry_sha)
    # Every registry material must be reachable from some habitat (checked on a tiny probe).
    probe = _probe_names(core_namespace())
    if probe != set(names):
        raise ValueError(f"habitat rules and registry disagree: missing {sorted(set(names) - probe)}, unknown {sorted(probe - set(names))}")
    final_path = hda_path
    os.makedirs(staging_dir, exist_ok=True)
    hda_path = os.path.join(staging_dir, os.path.basename(final_path))
    hou.hipFile.clear(suppress_save_prompt=True)
    geo = hou.node("/obj").createNode("geo", "material_build")
    sub = geo.createNode("subnet", "hego_material_distribution")
    sub.parm("label1").set(INPUT_LABEL)
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
    merge = sub.createNode("merge", "registry_channels")
    for index in range(len(names)):
        merge.setInput(index, strip)
    masks = sub.createNode("blast", "keep_optional_masks")
    masks.setInput(0, terrain_in)
    masks.parm("group").set(" ".join("@name=" + name for name in OPTIONAL_MASKS))
    masks.parm("grouptype").set("prims")
    masks.parm("negate").set(1)
    prior = sub.createNode("blast", "keep_prior_materials")
    prior.setInput(0, terrain_in)
    prior.parm("group").set("@name=material_*")
    prior.parm("grouptype").set("prims")
    prior.parm("negate").set(1)
    weights = sub.createNode("python", "distribute")
    weights.setInput(0, merge)
    weights.setInput(1, masks)
    weights.setInput(2, prior)
    weights.parm("python").set(sop_code(names, registry_sha))
    wgroup = weights.parmTemplateGroup()
    wgroup.append(hou.StringParmTemplate("target_layer_path", "Target Layer Path", 1))
    for name, *_ in FLOAT_PARMS:
        wgroup.append(hou.FloatParmTemplate(name, name, 1))
    for name, *_ in INT_PARMS + MENU_PARMS:
        wgroup.append(hou.IntParmTemplate(name, name, 1))
    weights.setParmTemplateGroup(wgroup)
    # Explicit channel references give the Python SOP real parameter dependencies.
    weights.parm("target_layer_path").setExpression('chs("../target_layer_path")', hou.exprLanguage.Hscript)
    for name, *_ in FLOAT_PARMS + INT_PARMS + MENU_PARMS:
        weights.parm(name).setExpression(f'ch("../{name}")')
    route = sub.createNode("attribwrangle", "route")
    route.setInput(0, weights)
    route.parm("class").set("primitive")
    route.parm("snippet").set(ROUTE_VEX.strip() + "\n")
    clean = sub.createNode("attribdelete", "clean_attributes")
    clean.setInput(0, route)
    clean.parm("ptdel").set("*")
    clean.parm("vtxdel").set("*")
    clean.parm("primdel").set("* ^name ^hegostrata_layer_path ^hegostrata_role ^hegostrata_channel ^hegostrata_composition")
    clean.parm("dtldel").set("* ^hego_material_*")
    out = sub.createNode("output", "output0")
    out.setInput(0, clean)
    out.setDisplayFlag(True)
    out.setRenderFlag(True)
    _document(hou, sub)

    if os.path.exists(hda_path):
        os.remove(hda_path)
    asset = sub.createDigitalAsset(
        name=OPERATOR, hda_file_name=hda_path, description="HEGo Material Distribution",
        min_num_inputs=1, max_num_inputs=1, version=HDA_VERSION,
        ignore_external_references=True, change_node_type=True, create_backup=False)
    definition = asset.type().definition()
    from graph_layout import document_definition
    document_definition(hou, definition, _parm_templates(hou), 'HEGo Material Distribution', 'Final mask-only material pass. Keep Stage Materials preserves valid covered mixtures byte for byte and fills uncovered samples. Regenerate explicitly classifies all samples from final height and available simulation masks.', ['Cumulative final fields:', '    Required height; optional flow, sediment, debris, erosion_delta and all 32 stage materials. Every field and ownership companion must use the exact height lattice.'], ['Registry materials:', '    All 32 material_<name> scalar fields in registry ID order; no height output.'])
    definition.setIcon("SOP_heightfield_maskbyfeature")
    definition.setComment("HEGo registry-material weights from the cumulative final height; built by "
                          "scripts/houdini/build_material_distribution_hda.py")
    with open(os.path.abspath(__file__)) as handle:
        definition.addSection("hego_build_material_distribution_hda.py", handle.read())
    with open(CONTRACT_PATH) as handle:
        definition.addSection("hego_contract.json", handle.read())
    definition.addSection("hego_material_weight_limit.py", weight_limit_source())
    definition.addSection("hego_material_habitat.py", core_source())
    with open(STAGE_PATH) as handle:
        definition.addSection("hego_material_stage.py", handle.read())
    with open(REGISTRY_PATH) as handle:
        definition.addSection("hego_material_registry.json", handle.read())
    with open(os.path.join(SCRIPT_DIR, "graph_layout.py")) as handle:
        definition.addSection("hego_graph_layout.py", handle.read())
    definition.setExtraFileOption("hego_hda_version", HDA_VERSION)
    definition.setExtraFileOption("hego_registry_sha256", registry_sha)
    definition.updateFromNode(asset)
    definition.save(hda_path, asset, create_backup=False)
    os.makedirs(os.path.dirname(final_path), exist_ok=True)
    shutil.copyfile(hda_path, final_path)
    return final_path


def _probe_names(namespace):
    """Material names the habitat tables can produce (evaluated on a tiny flat probe)."""
    import numpy as np
    shape = (3, 3)
    zero = np.zeros(shape)
    defaults = {p[0]: p[2] for p in FLOAT_PARMS}
    defaults.update({p[0]: p[2] for p in INT_PARMS})
    frame = {"la": 4.0, "lb": 4.0, "ua": (1.0, 0.0), "ub": (0.0, 1.0), "x": zero.copy(), "z": zero.copy()}
    s = namespace["signals"](zero + 10.0, {name: zero for name in OPTIONAL_MASKS}, frame, defaults)
    return {name for variants in namespace["affinities"](s, defaults).values() for name in variants}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hda", default=HDA_PATH)
    parser.add_argument("--out-dir", default="/tmp/hego-materials/hda")
    args = parser.parse_args()
    import hou
    start = time.time()
    path = build_hda(hou, args.hda, os.path.join(args.out_dir, "hda-staging"))
    log(f"[hda] saved Sop/{OPERATOR} to {path} in {time.time() - start:.1f}s")
    hou.hipFile.clear(suppress_save_prompt=True)


if __name__ == "__main__":
    main()
