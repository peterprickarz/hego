"""Builds hego_test_custom_channels.hda, the fixture for hego_custom_channels_test.gd.

    hython demo/tests/fixtures/make_custom_channels_fixture.py

A quad (two triangles, LOD 0) plus one reduced-LOD triangle over the same points, with
known per-point values in hego_custom0 (float4), hego_custom1 (float, tuple size 1) and
hego_custom3 (vector3). hego_custom2 is deliberately absent. A second surface
(hego_material "zero") has zero in every custom attribute.
"""
import os
import hou

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(HERE, "hego_test_custom_channels.hda")

SNIPPET = r'''
int pts[];
vector positions[] = array({0,0,0}, {1,0,0}, {1,0,1}, {0,0,1});
for (int i = 0; i < 4; i++) {
    int p = addpoint(0, positions[i]);
    append(pts, p);
    // custom0 = (index, 10 + index, 0.25 * index, 7): known and distinct per point.
    vector4 c0 = set(float(i), 10.0 + i, 0.25 * i, 7.0);
    setpointattrib(0, "hego_custom0", p, c0);
    setpointattrib(0, "hego_custom1", p, 0.5 + i);
    setpointattrib(0, "hego_custom3", p, set(-1.0 * i, 2.0, 3.0));
    setpointattrib(0, "N", p, {0,1,0});
}
int lods[] = array(0, 0, 1);
int tris[] = array(0, 2, 1,  0, 3, 2,  0, 3, 1);
for (int t = 0; t < 3; t++) {
    int prim = addprim(0, "poly", pts[tris[t*3]], pts[tris[t*3+1]], pts[tris[t*3+2]]);
    setprimattrib(0, "hego_lod", prim, lods[t] ? 0.5 : 0.0);
    setprimattrib(0, "hego_material", prim, "quad");
}
// A second surface whose points carry zero in every custom attribute: its channels are left out.
int z0 = addpoint(0, {0, 1, 0});
int z1 = addpoint(0, {1, 1, 0});
int z2 = addpoint(0, {0, 1, 1});
int zs[] = array(z0, z1, z2);
foreach (int z; zs) setpointattrib(0, "N", z, {0,1,0});
int zero = addprim(0, "poly", z0, z2, z1);
setprimattrib(0, "hego_lod", zero, 0.0);
setprimattrib(0, "hego_material", zero, "zero");
'''

geo = hou.node("/obj").createNode("geo", "fixture")
subnet = geo.createNode("subnet", "custom_channels")
wrangle = subnet.createNode("attribwrangle", "write_custom_channels")
wrangle.parm("class").set(0)  # detail: run once
wrangle.parm("snippet").set(SNIPPET)
out = subnet.createNode("output", "output0")
out.setInput(0, wrangle)
# attribwrangle infers float4 from set(a,b,c,d) and float/vector for the others.
asset = subnet.createDigitalAsset(
    name="hego_test_custom_channels",
    hda_file_name=PATH,
    description="hego_test_custom_channels",
    min_num_inputs=0,
    max_num_inputs=0,
)
definition = asset.type().definition()
definition.setComment("Test fixture for HEGo custom vertex channels (hego_custom_channels_test.gd).")
definition.save(PATH)
# Verify a fresh instance of the saved definition.
hou.hda.installFile(PATH)
check = geo.createNode("hego_test_custom_channels")
cooked = check.geometry()
import shutil
shutil.rmtree(os.path.join(HERE, "backup"), ignore_errors=True)
print("errors", check.errors(),
      "points", len(cooked.points()), "prims", len(cooked.prims()),
      [(a.name(), a.size()) for a in cooked.pointAttribs()])
