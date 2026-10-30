#!/usr/bin/env hython
"""Build standalone Sop/util_MaterialWeightLimit (no runtime imports).

  hython scripts/houdini/build_material_weight_limit_hda.py
"""
import argparse
import os
import shutil
import sys

sys.dont_write_bytecode = True
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(SCRIPT_DIR))
OPERATOR = "util_MaterialWeightLimit"
HDA_PATH = os.path.join(REPO, "otls/util_MaterialWeightLimit.hda")
HELPER_PATH = os.path.join(SCRIPT_DIR, "material_weight_limit.py")


def helper_source():
    with open(HELPER_PATH) as handle:
        return handle.read()


def build_hda(hou, path, staging):
    import material_weight_limit
    os.makedirs(staging, exist_ok=True)
    staged = os.path.join(staging, os.path.basename(path))
    hou.hipFile.clear(suppress_save_prompt=True)
    parent = hou.node("/obj").createNode("geo", "weight_limit_build")
    subnet = parent.createNode("subnet", "util_MaterialWeightLimit")
    group = hou.ParmTemplateGroup()
    group.append(hou.StringParmTemplate("channels", "Material Channels (Stable ID Order)", 1, default_value=("material_*",),
        help="Whitespace-separated material weight names/patterns. Explicit names keep caller order; wildcard matches keep incoming primitive order. This is the stable tie order. Only selected values change; all geometry, attributes and other fields pass through."))
    group.append(hou.IntParmTemplate("maximum", "Maximum Contributions", 1, default_value=(4,), min=1, max=32,
        min_is_strict=True, max_is_strict=True,
        help="Subtract rank maximum+1, clamp to zero and normalize. Equal maximum ties use stable channel order; unassigned voxels stay zero."))
    subnet.setParmTemplateGroup(group)
    python = subnet.createNode("python", "limit_weights")
    python.setInput(0, subnet.indirectInputs()[0])
    python_group = python.parmTemplateGroup()
    for template in group.parmTemplates():
        python_group.append(template)
    python.setParmTemplateGroup(python_group)
    python.parm("channels").setExpression('chs("../channels")', hou.exprLanguage.Hscript)
    python.parm("maximum").setExpression('ch("../maximum")')
    python.parm("python").set(helper_source() + "\n" + material_weight_limit.SOP_ADAPTER)
    output = subnet.createNode("output", "output0")
    output.setInput(0, python)
    output.setDisplayFlag(True)
    output.setRenderFlag(True)
    subnet.layoutChildren()
    if os.path.exists(staged):
        os.remove(staged)
    asset = subnet.createDigitalAsset(name=OPERATOR, hda_file_name=staged,
        description="HEGo Material Weight Limit", min_num_inputs=1, max_num_inputs=1,
        version="", ignore_external_references=True, create_backup=False)
    definition = asset.type().definition()
    definition.setParmTemplateGroup(group)
    definition.setIcon("SOP_heightfield_maskbyfeature")
    definition.addSection("hego_material_weight_limit.py", helper_source())
    with open(__file__) as handle:
        definition.addSection("hego_build_material_weight_limit_hda.py", handle.read())
    definition.updateFromNode(asset)
    definition.save(staged, asset, create_backup=False)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    shutil.copyfile(staged, path)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hda", default=HDA_PATH)
    parser.add_argument("--out-dir", default="/tmp/hego-material-weight-limit")
    args = parser.parse_args()
    import hou
    print(build_hda(hou, args.hda, os.path.join(args.out_dir, "staging")), flush=True)
    hou.hipFile.clear(suppress_save_prompt=True)


if __name__ == "__main__":
    main()
