"""Build the artificial COP round-trip test HDA with hython.

The SOP output is one point recording a corner of the incoming red channel
and the references received on its numbered input. The COP path parameter
is a fallback for the native parameter-binding regression.
The Godot test can independently render the RGBA input or any split channel.
The white constant gives newly instantiated test assets a cookable default.
Two artificial layers cover half precision and integer identifier rasters.
"""

from pathlib import Path
from tempfile import TemporaryDirectory

import hou


OPERATOR = "hego_test_cop_texture"
DESTINATION = Path(__file__).with_name(OPERATOR + ".hda")


def stage(parent, title, nodes):
    box = parent.createNetworkBox()
    box.setComment(title)
    for node in nodes:
        box.addItem(node)
    box.fitAroundContents()
    box.setAutoFit(True)


def add_cop_path(node, template, default=""):
    path = template.clone()
    path.setName("source_texture")
    path.setLabel("Test Texture")
    path.setDefaultValue((default,))
    group = node.parmTemplateGroup()
    group.append(path)
    node.setParmTemplateGroup(group)


def build(filename):
    geo = hou.node("/obj").createNode("geo")
    subnet = geo.createNode("subnet")
    subnet.parm("label1").set("Textures")
    texture_input = subnet.createNode("null", "IN_TEXTURE")
    texture_input.setInput(0, subnet.indirectInputs()[0])
    texture_input.setColor(hou.Color((0.91, 0.55, 0.71)))
    net = subnet.createNode("copnet")
    default = net.createNode("constant")
    fetch = net.createNode("fetch")
    split = net.createNode("channelsplit")
    split.setInput(0, fetch)
    half = net.createNode("layer")
    half.parm("signature").set("f2")
    half.parmTuple("f2").set((-2.25, 4.5))
    half.parm("setprecision").set(1)
    half.parm("precision").set("b16")
    half.setComment("Two-component, half-precision test raster")
    ids = net.createNode("layer")
    ids.parm("signature").set("i")
    ids.parm("i").set(16777217)
    ids.parm("setprecision").set(1)
    ids.parm("precision").set("b32")
    ids.setComment("Integer ID above the float32 exact integer range")
    source_template = fetch.parm("coppath").parmTemplate()
    add_cop_path(subnet, source_template, "copnet1/constant1")
    add_cop_path(net, source_template)
    net.parm("source_texture").setExpression('chsop("../source_texture")')
    fetch.parm("coppath").setExpression(
        'ifs(npoints("../../IN_TEXTURE") > 0, '
        'points("../../IN_TEXTURE", 0, "hego_cop_path"), chsop("../source_texture"))'
    )

    net.parm("setres").set(1)
    net.parmTuple("res").set((2, 2))
    net.parm("usecoppath").set(1)
    net.parm("coppath").set("channelsplit1")
    # The first channel from the split arrives as a single red-channel volume.
    sample = subnet.createNode("attribwrangle", "sample_red_corner")
    sample.setInput(0, net)
    sample.setInput(1, texture_input)
    sample.parm("class").set(0)
    sample.parm("snippet").set(
        'float red = volumeindex(0, 0, set(0, 0, 0));\n'
        'int sample = addpoint(0, {0, 0, 0});\n'
        'setpointattrib(0, "red_corner", sample, red);\n'
        'setpointattrib(0, "texture_count", sample, npoints(1));\n'
        'string first = npoints(1) > 0 ? point(1, "hego_cop_path", 0) : "";\n'
        'string second = npoints(1) > 1 ? point(1, "hego_cop_path", 1) : "";\n'
        'setpointattrib(0, "first_cop", sample, first);\n'
        'setpointattrib(0, "second_cop", sample, second);\n'
        'removeprim(0, 0, 1);'
    )
    sample.setColor(hou.Color((0.35, 0.65, 0.35)))
    out = subnet.createNode("output")
    out.setInput(0, sample)
    out.setDisplayFlag(True)
    default.setPosition(hou.Vector2(-3, 4))
    fetch.setPosition(hou.Vector2(0, 2))
    split.setPosition(hou.Vector2(0, 0))
    stage(net, "Test texture and channels", [default, fetch, split])
    half.setPosition(hou.Vector2(4, 4))
    ids.setPosition(hou.Vector2(7, 4))
    stage(net, "Precision test rasters", [half, ids])
    texture_input.setPosition(hou.Vector2(1, 7))
    net.setPosition(hou.Vector2(0, 4))
    sample.setPosition(hou.Vector2(0, 2))
    out.setPosition(hou.Vector2(0, 0))
    stage(subnet, "Texture input", [texture_input])
    stage(subnet, "Sample the texture in SOPs", [net, sample, out])

    asset = subnet.createDigitalAsset(
        name=OPERATOR, hda_file_name=str(filename), description="HEGo COP Texture Test Fixture",
        min_num_inputs=0, max_num_inputs=1,
    )
    definition = asset.type().definition()
    add_cop_path(definition, source_template, "copnet1/constant1")
    definition.setComment(__doc__)
    asset.matchCurrentDefinition()
    fresh = geo.createNode(OPERATOR)
    cooked = fresh.geometry()
    assert fresh.matchesCurrentDefinition() and not fresh.errors(), fresh.errors()
    assert fresh.inputLabels() == ("Textures",), fresh.inputLabels()
    assert len(cooked.points()) == 1 and cooked.points()[0].attribValue("red_corner") == 1.0


if __name__ == "__main__":
    # Houdini writes backups when modifying an existing HDA. Build in isolation.
    with TemporaryDirectory() as directory:
        library = Path(directory) / DESTINATION.name
        build(library)
        DESTINATION.write_bytes(library.read_bytes())
