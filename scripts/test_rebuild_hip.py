"""Exercise HEGo rebuild and HIP export against a real, private Houdini session.

Run with Houdini's hython and pass --godot /path/to/godot. The input HDAs are
temporary test fixtures. The Godot test corrupts the installed copy, retries
with a valid replacement, and checks the version stamped on the cooked points.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

import hou


OPERATOR = "hego_test_rebuild"


def write_fixture(path, version):
    path.parent.mkdir()
    geo = hou.node("/obj").createNode("geo")
    subnet = geo.createNode("subnet")
    merge = subnet.createNode("merge")
    for index in range(2):
        merge.setInput(index, subnet.indirectInputs()[index])
    # The Godot test reads the marker through the point-cloud output API.
    points = subnet.createNode("add")
    points.setInput(0, merge)
    points.parm("keep").set(1)
    stamp = subnet.createNode("attribwrangle", "stamp_version")
    stamp.setInput(0, points)
    stamp.parm("snippet").set(f'@P.y += chf("../lift"); i@fixture_version = {version};')
    stamp.setColor(hou.Color((0.3, 0.6, 0.3)))
    output = subnet.createNode("output")
    output.setInput(0, stamp)
    output.setDisplayFlag(True)
    stage = subnet.createNetworkBox()
    stage.setComment("Rebuild test fixture")
    for row, node in enumerate([merge, points, stamp, output]):
        node.setPosition(hou.Vector2(0, -2 * row))
        stage.addItem(node)
    stage.fitAroundContents()
    stage.setAutoFit(True)
    asset = subnet.createDigitalAsset(OPERATOR, str(path), min_num_inputs=0, max_num_inputs=2)
    definition = asset.type().definition()
    parameters = definition.parmTemplateGroup()
    parameters.append(hou.FloatParmTemplate("lift", "Lift", 1))
    if version == 2:
        parameters.append(hou.FloatParmTemplate("detail", "Fine Detail", 1, default_value=(0.75,)))
    definition.setParmTemplateGroup(parameters)
    geo.destroy()
    hou.hda.uninstallFile(str(path))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1] / "demo")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="hego rebuild ") as directory:
        folder = Path(directory)
        active = folder / "installed" / "fixture.hda"
        replacement = folder / "replacement" / "fixture.hda"
        write_fixture(active, 1)
        write_fixture(replacement, 2)
        env = os.environ.copy()
        env["HOUDINI_OTLSCAN_PATH"] = str(active.parent) + os.pathsep + "&"
        run = subprocess.run(
            [args.godot, "--headless", "--path", str(args.project), "--script",
             "res://tests/hego_rebuild_hip_test.gd", "--", active.as_posix(), replacement.as_posix(), folder.as_posix()],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180,
            text=True, errors="replace",
        )
        print(run.stdout, flush=True)
        if run.returncode or "HEGO_REBUILD_HIP_PASS" not in run.stdout or "SCRIPT ERROR:" in run.stdout:
            raise RuntimeError("Godot failed the rebuild or HIP export checks")

        # Open the exported file independently and check both connections and
        # the surviving parameter on the rebuilt asset in the saved session.
        snapshot, = folder.glob("saved session.hip*")
        hou.hda.installFile(str(active))
        hou.hipFile.load(str(snapshot), suppress_save_prompt=True)
        rebuilt, = hou.sopNodeTypeCategory().nodeTypes()[OPERATOR].instances()
        assert rebuilt.parm("lift").eval() == 3.5
        assert rebuilt.parm("detail").eval() == 0.75
        assert len(rebuilt.inputs()) == 2 and all(rebuilt.inputs())
        geometry = rebuilt.geometry()
        versions = geometry.pointIntAttribValues("fixture_version")
        assert versions and set(versions) == {2}
        print("PASS reopened the saved session with both inputs, live parameters and the new definition")
        hou.hipFile.clear(suppress_save_prompt=True)


if __name__ == "__main__":
    main()
