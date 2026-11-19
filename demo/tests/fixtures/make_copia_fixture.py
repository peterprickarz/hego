"""Builds hego_test_copia.hda, the TEST FIXTURE for hego_copia_roundtrip_test.gd.

    hython demo/tests/fixtures/make_copia_fixture.py

Not a production tool: a small SOP asset that exercises the HEGo Copia contract
(docs/copia/houdini.md) with known, seeded values. One input, the Copia input cloud (may be
empty or unconnected). Three independent branches, merged into the output:

- spawn: a grid of `size` on XZ, scattered with `count` points and `seed`; a wrangle gives
  each point its transform (random yaw plus a fixed 20 degree tilt about X, non-uniform
  `scale` on every third point, random `pscale`), colour, keep, custom data, `fixture_id`,
  object, set (every other point into `second_set` when that is set) and the store from the
  `store` parameter. It also writes `fixture_basis_x/y/z`, the instance basis by
  Houdini's own rule (scale in the local frame, then rotate by orient), as reference values
  the test reads straight from the cook; the bridge ignores them.
- clear: when `clear` is on, the input's cell points of this asset's sets whose cell lies
  within the `size` square become clear points.
- copy: when `copy_set` is set, the input's instance points of that set are re-emitted into
  `set`, 1000 m along +X, with N and up turned into orient.

Every output point, spawned, clear or copied, gets `hegocopia_store` from the string parameter
`store`: the node path of the CopiaStore3D from the scene root, blank for the only store.

Random values are deterministic in `seed`, so an unchanged recook is identical.
"""
import os
import shutil

import hou

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(HERE, "hego_test_copia.hda")
NAME = "hego_test_copia"
GREEN = hou.Color((0.4, 0.8, 0.4))
PINK = hou.Color((1.0, 0.6, 0.8))

SPAWN = r'''// TEST FIXTURE. Spawn attributes, deterministic in the seed and the point number.
int seed = chi("../seed");
float id = @ptnum + 1;
vector4 yaw = quaternion(radians(rand(set(id, seed, 1)) * 360.0), {0, 1, 0});
vector4 tilt = quaternion(radians(20.0), {1, 0, 0});
p@orient = qmultiply(yaw, tilt);
v@scale = (@ptnum % 3 == 0) ? {1.0, 2.0, 0.5} : {1.0, 1.0, 1.0};
f@pscale = fit01(rand(set(id, seed, 2)), 0.5, 1.5);
v@Cd = rand(set(id, seed, 3));
f@hegocopia_keep = fit01(rand(set(id, seed, 4)), 0.2, 1.0);
p@hegocopia_custom = set(id, float(seed), @P.x, 0.5);
f@fixture_id = id;

s@hegocopia_object = chs("../object");
string second = chs("../second_set");
s@hegocopia_set = (second != "" && @ptnum % 2 == 1) ? second : chs("../set");
s@hegocopia_store = chs("../store");
i@hegocopia_clear = 0;

// Reference basis by Houdini's instancing rule; not read by the bridge.
vector s = v@scale * f@pscale;
v@fixture_basis_x = qrotate(p@orient, set(s.x, 0, 0));
v@fixture_basis_y = qrotate(p@orient, set(0, s.y, 0));
v@fixture_basis_z = qrotate(p@orient, set(0, 0, s.z));
'''

CLEAR = r'''// TEST FIXTURE. Clear this asset's sets in every cell that lies within the size square.
string mine = chs("../set");
string second = chs("../second_set");
float half = ch("../size") * 0.5 + 1e-3;
int ours = s@hegocopia_set == mine || (second != "" && s@hegocopia_set == second);
int inside = v@hegocopia_cell_min.x >= -half && v@hegocopia_cell_max.x <= half
          && v@hegocopia_cell_min.z >= -half && v@hegocopia_cell_max.z <= half;
if (chi("../clear") && i@hegocopia_cell_point == 1 && ours && inside) {
    i@hegocopia_clear = 1;
    s@hegocopia_store = chs("../store");
} else
    removepoint(0, @ptnum);
'''

COPY = r'''// TEST FIXTURE. Re-emit the input's instance points of copy_set into set, 1000 m along +X.
string from = chs("../copy_set");
if (from == "" || i@hegocopia_cell_point != 0 || s@hegocopia_set != from) {
    removepoint(0, @ptnum);
} else {
    // The Copia input sends the frame as N (+Z) and up (+Y) with scale; orient replaces them
    // so the merge with the spawned points (which carry orient) cannot leave a zero orient.
    p@orient = quaternion(maketransform(normalize(v@N), normalize(v@up)));
    f@pscale = 1.0;
    @P.x += 1000.0;
    s@hegocopia_set = chs("../set");
    s@hegocopia_store = chs("../store");
    f@fixture_id += 100000.0;
    // A vector3 custom with its w beside it, as the input sends it, becomes one vector4.
    p@copy_custom = set(v@hegocopia_custom.x, v@hegocopia_custom.y, v@hegocopia_custom.z, f@hegocopia_custom_w);
}
'''


def wrangle(parent, name, snippet, comment):
    node = parent.createNode("attribwrangle", name)
    node.parm("class").set(2)  # points
    node.parm("snippet").set(snippet)
    node.setColor(GREEN)
    node.setComment(comment)
    node.setGenericFlag(hou.nodeFlag.DisplayComment, True)
    return node


def build():
    geo = hou.node("/obj").createNode("geo", "fixture")
    subnet = geo.createNode("subnet", NAME)
    source = subnet.indirectInputs()[0]
    source.setPosition(hou.Vector2(4, 0))

    copia_in = subnet.createNode("null", "IN_copia")
    copia_in.setInput(0, source)
    copia_in.setColor(PINK)
    copia_in.setComment("The Copia input cloud: cell points and instance points")
    copia_in.setGenericFlag(hou.nodeFlag.DisplayComment, True)
    copia_in.setPosition(hou.Vector2(4, -1))


    # Spawn branch (left).
    grid = subnet.createNode("grid")
    grid.parm("sizex").setExpression('ch("../size")')
    grid.parm("sizey").setExpression('ch("../size")')
    grid.parm("rows").set(2)
    grid.parm("cols").set(2)
    grid.setPosition(hou.Vector2(0, -1))
    scatter = subnet.createNode("scatter")
    scatter.setInput(0, grid)
    scatter.parm("forcetotal").set(1)
    scatter.parm("npts").setExpression('ch("../count")')
    scatter.parm("seed").setExpression('ch("../seed")')
    scatter.parm("relaxpoints").set(0)
    scatter.setPosition(hou.Vector2(0, -2))
    spawn = wrangle(subnet, "spawn_points", SPAWN, "Transform, colour, keep, custom, set and store per point")
    spawn.setInput(0, scatter)
    spawn.setInput(1, copia_in)
    spawn.setPosition(hou.Vector2(0, -3.5))

    # Clear branch (middle).
    clear = wrangle(subnet, "clear_points", CLEAR, "Cell points of this asset's sets inside the size square")
    clear.setInput(0, copia_in)
    clear.setPosition(hou.Vector2(4, -3.5))
    clear_keep = subnet.createNode("attribdelete")
    clear_keep.setInput(0, clear)
    clear_keep.parm("ptdel").set("* ^hegocopia_clear ^hegocopia_set ^hegocopia_cell ^hegocopia_store")
    clear_keep.setComment("A clear point needs only its set, cell and store")
    clear_keep.setGenericFlag(hou.nodeFlag.DisplayComment, True)
    clear_keep.setPosition(hou.Vector2(4, -4.5))

    # Copy branch (right).
    copy = wrangle(subnet, "copy_points", COPY, "Instance points of copy_set, moved 1000 m along X")
    copy.setInput(0, copia_in)
    copy.setPosition(hou.Vector2(8, -3.5))
    copy_keep = subnet.createNode("attribdelete")
    copy_keep.setInput(0, copy)
    copy_keep.parm("ptdel").set("* ^orient ^scale ^pscale ^Cd ^hegocopia_object ^hegocopia_set ^hegocopia_store ^hegocopia_keep ^copy_custom ^fixture_id")
    copy_keep.setPosition(hou.Vector2(8, -4.5))
    swap = subnet.createNode("attribswap")
    swap.setInput(0, copy_keep)
    swap.parm("method1").set(2)  # move
    swap.parm("class1").set(2)  # point
    swap.parm("srcattribs1").set("copy_custom")
    swap.parm("dstattribs1").set("hegocopia_custom")
    swap.setComment("copy_custom becomes hegocopia_custom (vector4)")
    swap.setGenericFlag(hou.nodeFlag.DisplayComment, True)
    swap.setPosition(hou.Vector2(8, -5.5))

    merge = subnet.createNode("merge")
    merge.setInput(0, spawn)
    merge.setInput(1, clear_keep)
    merge.setInput(2, swap)
    merge.setPosition(hou.Vector2(4, -7))
    out = subnet.createNode("output", "output0")
    out.setInput(0, merge)
    out.setPosition(hou.Vector2(4, -8))
    out.setDisplayFlag(True)
    out.setRenderFlag(True)

    for label, nodes in (("Spawn", [grid, scatter, spawn]), ("Clear", [clear, clear_keep]), ("Copy", [copy, copy_keep, swap])):
        box = subnet.createNetworkBox(label.lower())
        box.setComment(label)
        for node in nodes:
            box.addNode(node)
        box.fitAroundContents()
        box.setAutoFit(True)

    asset = subnet.createDigitalAsset(
        name=NAME,
        hda_file_name=PATH,
        description="HEGo Copia test fixture",
        min_num_inputs=0,
        max_num_inputs=1,
    )
    definition = asset.type().definition()
    group = hou.ParmTemplateGroup()
    group.append(hou.IntParmTemplate("seed", "Seed", 1, default_value=(1,), min=0, max=100))
    group.append(hou.IntParmTemplate("count", "Count", 1, default_value=(16,), min=0, max=1000))
    group.append(hou.FloatParmTemplate("size", "Size", 1, default_value=(128.0,), min=1.0, max=1024.0))
    group.append(hou.StringParmTemplate("object", "Object", 1, default_value=("",)))
    group.append(hou.StringParmTemplate("store", "Store", 1, default_value=("",)))
    group.append(hou.StringParmTemplate("set", "Set", 1, default_value=("fixture",)))
    group.append(hou.StringParmTemplate("second_set", "Second Set", 1, default_value=("",)))
    group.append(hou.StringParmTemplate("copy_set", "Copy Set", 1, default_value=("",)))
    group.append(hou.ToggleParmTemplate("clear", "Clear", default_value=True))
    definition.setParmTemplateGroup(group)
    definition.setComment("Test fixture for the HEGo Copia bridge (hego_copia_roundtrip_test.gd). Not a production tool.")
    definition.addSection("Help", """= HEGo Copia test fixture =

#type: node
#context: sop

\"\"\"TEST FIXTURE for hego_copia_roundtrip_test.gd. Not a production tool.\"\"\"

Spawns `count` seeded points in a `size` square on XZ with the HEGo Copia attributes, turns
the input's cell points of its own sets inside that square into clear points when `clear` is
on, and re-emits the input's instance points of `copy_set` into `set` 1000 m along +X.

@inputs
Copia input:
    The point cloud of a Copia input row (cell points and instance points); may be empty.

@parameters
Seed:
    Seed of every random value.
Count:
    Points to spawn; 0 spawns nothing.
Size:
    Side of the square on XZ, centred on the origin.
Object:
    Resource path written into `hegocopia_object`.
Store:
    Node path of the CopiaStore3D from the scene root, written into `hegocopia_store` on every
    output point. Blank names the only store in the scene.
Set:
    Set the points go into.
Second Set:
    When set, every other spawned point goes into it.
Copy Set:
    When set, the input's instance points of this set are re-emitted into `Set`, 1000 m along +X.
Clear:
    Clear this asset's sets in the cells inside the square.
""")
    definition.save(PATH)
    return geo


def verify(geo):
    hou.hda.installFile(PATH)
    node = geo.createNode(NAME)
    node.parm("object").set("res://fixture_object.tres")
    cooked = node.geometry()
    attrs = sorted((a.name(), a.size(), a.dataType().name()) for a in cooked.pointAttribs())
    print("default cook: errors", node.errors(), "warnings", node.warnings(), "points", len(cooked.points()))
    print("attributes", attrs)
    first = cooked.points()[0]
    print("first point", first.position(), first.attribValue("orient"), first.attribValue("scale"), first.attribValue("pscale"))
    again = node.geometry().freeze()
    node.cook(force=True)
    same = [p.position() for p in again.points()] == [p.position() for p in node.geometry().points()]
    print("recook identical", same)
    node.parm("count").set(0)
    print("count 0 points", len(node.geometry().points()))
    node.parm("count").set(16)
    node.parm("second_set").set("other")
    sets = [p.attribValue("hegocopia_set") for p in node.geometry().points()]
    print("second_set split", sets.count("fixture"), sets.count("other"))
    node.parm("second_set").set("")
    node.parm("store").set("Level/StoreB")
    stores = {p.attribValue("hegocopia_store") for p in node.geometry().points()}
    print("store parameter: stores", stores, "detail attribs", [a.name() for a in node.geometry().globalAttribs()])

if __name__ == "__main__":
    fixture_geo = build()
    verify(fixture_geo)
    shutil.rmtree(os.path.join(HERE, "backup"), ignore_errors=True)
