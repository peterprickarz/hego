"""Rebuild or verify the two parameter editing test fixtures with Houdini 22 hython.

Run this file to rebuild. Pass --verify-only to check the existing libraries.
Both assets cook empty geometry carrying a few detail attributes for assertions.
"""

import argparse
from pathlib import Path
import shutil
import tempfile

import hapi
import hou


HERE = Path(__file__).resolve().parent
VALUES = "hego_test_parameter_values"
STRUCTURE = "hego_test_parameter_structure"
PYTHON = hou.scriptLanguage.Python

VALUES_HELP = """@parameters

Conditional controls:
    #id: enabled

    Show the conditional text field and enable the amount slider.

    Turn off Auto Recook to try these controls without cooking the asset.

::Conditional amount:
    Adjust the sample amount while
    conditional controls are enabled.

    The slider demonstrates a soft range for typed values.

Increment action count:
    #id: press_action

    Run the callback once and watch the action count increase.
"""

STRUCTURE_HELP = """@parameters List controls

List instances:
    #id: entries

    Add or remove rows to test nested parameter editing.

Value:
    #id: entry_value#

    Edit the value on this list row.

Name:
    #id: tab_name#

    Name this tabbed instance.
"""


def string(name, label, **options):
    return hou.StringParmTemplate(name, label, 1, **options)


def folder(name, label, style, children, **options):
    return hou.FolderParmTemplate(name, label, children, folder_type=style, **options)


def multiparm(name, label, style, children, count=2, **options):
    template = folder(name, label, style, children, **options)
    template.setDefaultValue(count)
    return template


def path_parm(name, label, kind, default, mode, pattern=""):
    tags = {"filechooser_mode": mode}
    if pattern:
        tags["filechooser_pattern"] = pattern
    return string(name, label, string_type=hou.stringParmType.FileReference,
                  file_type=kind, default_value=(default,), tags=tags)


def sop_reference(name, label):
    return string(name, label, string_type=hou.stringParmType.NodeReference, tags={"opfilter": "!!SOP!!"})


def values_interface():
    group = hou.ParmTemplateGroup()
    add = group.append
    add(hou.LabelParmTemplate("fixture_legend", "Parameter test fixture",
                              column_labels=("Controls and values", "Empty geometry output")))
    add(hou.ToggleParmTemplate("enabled", "Enable conditional controls", default_value=True,
                               help="Enable the conditional fixture fields."))
    amount = hou.FloatParmTemplate("conditional_amount", "Conditional amount", 1,
                                   default_value=(0.5,), min=0, max=1)
    amount.setConditional(hou.parmCondType.DisableWhen, "{ enabled == 0 }")
    add(amount)
    text = string("conditional_text", "Conditional text", default_value=("Visible while enabled",))
    text.setConditional(hou.parmCondType.HideWhen, "{ enabled == 0 }")
    add(text)
    add(hou.IntParmTemplate("marker", "Source marker", 1, default_value=(17,), min=0, max=100,
                            help="Set the detail marker read by the Structure fixture."))
    add(hou.ButtonParmTemplate("press_action", "Increment action count",
                               script_callback="p = kwargs['node'].parm('action_count'); p.set(p.eval() + 1)",
                               script_callback_language=PYTHON))
    add(hou.IntParmTemplate("action_count", "Action count", 1))
    add(hou.SeparatorParmTemplate("menu_separator"))
    choices = ("clay", "ice")
    labels = ("Red clay", "Blue ice")
    menus = [
        hou.MenuParmTemplate("ordinal_menu", "Ordered menu", ("low", "high"),
                             menu_labels=("Low detail", "High detail")),
        hou.MenuParmTemplate("token_menu", "Integer token menu", ("10", "40"),
                             menu_labels=("Ten", "Forty"), menu_use_token=True,
                             default_value=0, store_default_value_as_string=True),
        string("string_menu", "String menu", default_value=("clay",), menu_items=choices,
               menu_labels=labels),
        string("dynamic_menu", "Menu from Enable conditional controls", default_value=("base",),
               item_generator_script="['base', 'Base', 'extra', 'Extra'] if kwargs['node'].evalParm('enabled') else ['base', 'Base']",
               item_generator_script_language=PYTHON),
        hou.MenuParmTemplate("mini_menu", "Mini menu", choices, menu_labels=labels, menu_type=hou.menuType.Mini),
        string("replace_menu", "Editable replace menu", default_value=("custom",), menu_items=choices,
               menu_labels=labels, menu_type=hou.menuType.StringReplace),
        string("toggle_menu", "Multiple selection menu", default_value=("clay",), menu_items=choices,
               menu_labels=labels, menu_type=hou.menuType.StringToggle),
        hou.MenuParmTemplate("button_strip", "Button strip", choices, menu_labels=labels, is_button_strip=True),
        hou.MenuParmTemplate("icon_strip", "Icon strip", ("SOP_box", "SOP_sphere"), menu_labels=("Box", "Sphere"),
                             icon_names=("SOP_box", "SOP_sphere"), is_button_strip=True, strip_uses_icons=True),
    ]
    add(folder("menus", "Menus", hou.folderType.Simple, menus))
    colors = [hou.FloatParmTemplate(name, label, len(default), default_value=default,
                                    naming_scheme=hou.parmNamingScheme.RGBA, look=hou.parmLook.ColorSquare)
              for name, label, default in (("rgb", "RGB color", (0.2, 0.5, 1.5)),
                                           ("rgba", "RGBA color", (0.9, 0.3, 0.2, 0.4)))]
    paths = [
        path_parm("file_path", "Open file", hou.fileType.Any, "$HIP/readme.txt", "read", "*.txt"),
        path_parm("geo_path", "Save geometry", hou.fileType.Geometry, "$HIP/fixture.$F4.bgeo.sc", "write", "*.bgeo.sc *.obj"),
        path_parm("image_path", "Open image", hou.fileType.Image, "$HIP/fixture.exr", "read", "*.exr *.png"),
        path_parm("directory_path", "Directory", hou.fileType.Directory, "$HIP", "read"),
    ]
    add(folder("colors_paths", "Colors and paths", hou.folderType.Collapsible, colors + paths))
    base = hou.parmNamingScheme.Base1
    tuples = [
        hou.StringParmTemplate("words", "Two strings", 2, default_value=("east", "west")),
        hou.FloatParmTemplate("wide_floats", "Nine floats", 9, naming_scheme=base,
                              default_value=(1, 0, 0, 0, 1, 0, 0, 0, 1)),
        hou.IntParmTemplate("wide_ints", "Six integers", 6, naming_scheme=base, default_value=tuple(range(6))),
    ]
    for arity in (2, 3, 4):
        tuples.extend([hou.FloatParmTemplate(f"float{arity}", f"Float {arity}", arity),
                       hou.IntParmTemplate(f"int{arity}", f"Integer {arity}", arity)])
    add(folder("tuples", "Tuples", hou.folderType.Collapsible, tuples))
    add(folder("specialized", "Specialized fields", hou.folderType.Collapsible, [
        hou.FloatParmTemplate("angle", "Angle", 1, look=hou.parmLook.Angle),
        hou.FloatParmTemplate("uv", "UV", 2, naming_scheme=hou.parmNamingScheme.UVW),
        hou.FloatParmTemplate("direction", "Direction", 3, look=hou.parmLook.Vector, default_value=(0, 1, 0)),
        hou.FloatParmTemplate("limits", "Minimum and maximum", 2, naming_scheme=hou.parmNamingScheme.MinMax,
                              default_value=(0, 5)),
        hou.FloatParmTemplate("log_scale", "Logarithmic scale", 1, default_value=(1,), min=0.01, max=100,
                              min_is_strict=True, look=hou.parmLook.Logarithmic),
        string("notes", "Multiline notes", default_value=("First line\nSecond line",),
               tags={"editor": "1", "editorlines": "3"}),
    ]))
    return group


def structure_interface():
    group = hou.ParmTemplateGroup()
    add = group.append
    add(hou.LabelParmTemplate("structure_legend", "Parameter test fixture",
                              column_labels=("Folders, instances and references", "Empty geometry output")))
    add(folder("display_tabs", "Surface", hou.folderType.Tabs, [string("surface_name", "Surface name")],
               tags={"group_default": "1"}))
    add(folder("pattern_tab", "Pattern", hou.folderType.Tabs, [string("pattern_name", "Pattern name")],
               ends_tab_group=True))
    add(folder("radio_mode", "Local", hou.folderType.RadioButtons, [string("local_name", "Local name")]))
    add(folder("linked_mode", "Linked", hou.folderType.RadioButtons, [string("linked_name", "Linked name")],
               ends_tab_group=True))
    add(hou.SeparatorParmTemplate("structure_separator"))
    add(hou.RampParmTemplate("float_ramp", "Float ramp", hou.rampParmType.Float,
                             default_value=3, default_basis=hou.rampBasis.Linear))
    add(hou.RampParmTemplate("color_ramp", "Color ramp", hou.rampParmType.Color,
                             default_value=3, default_basis=hou.rampBasis.Linear))
    add(multiparm("entries", "List instances", hou.folderType.MultiparmBlock,
                  [hou.FloatParmTemplate("entry_value#", "Value", 1), sop_reference("entry_source#", "Row SOP"),
                   multiparm("children#", "Nested instances", hou.folderType.MultiparmBlock,
                             [string("child#_name#", "Name"), sop_reference("child#_source#", "Nested SOP")], count=1)]))
    add(multiparm("zero_entries", "Zero-based list", hou.folderType.MultiparmBlock,
                  [hou.IntParmTemplate("zero_value#", "Value", 1)], count=0, tags={"multistartoffset": "0"}))
    add(multiparm("scroll_entries", "Scrolling instances", hou.folderType.ScrollingMultiparmBlock,
                  [string("scroll_name#", "Name"), hou.FloatParmTemplate("scroll_weight#", "Weight", 1)], count=5))
    add(multiparm("tab_entries", "Tabbed instances", hou.folderType.TabbedMultiparmBlock,
                  [string("tab_name#", "Name"), hou.ToggleParmTemplate("tab_enabled#", "Enabled", default_value=True)]))
    add(folder("references", "Houdini references", hou.folderType.Simple, [
        sop_reference("source_node", "Source SOP"),
        string("source_nodes", "Operator path list", string_type=hou.stringParmType.NodeReferenceList,
               tags={"opfilter": "!!SOP!!"}),
    ]))
    data = []
    for name, label, kind in (("dictionary_data", "Dictionary data", hou.dataParmType.KeyValueDictionary),
                              ("geometry_data", "Geometry data", hou.dataParmType.Geometry)):
        parm = hou.DataParmTemplate(name, label, 1)
        parm.setDataParmType(kind)
        data.append(parm)
    add(folder("opaque", "Opaque data", hou.folderType.Collapsible, data, tags={"group_default": "1"}))
    return group


def write_asset(directory, name, label, interface, snippet):
    path = str(directory / (name + ".hda"))
    geo = hou.node("/obj").createNode("geo")
    subnet = geo.createNode("subnet")
    empty = subnet.createNode("add")
    sample = subnet.createNode("attribwrangle", "sample_fixture_parameters")
    sample.parm("class").set(0)  # Detail (once per cook).
    sample.parm("snippet").set(snippet)
    sample.setColor(hou.Color((0.35, 0.7, 0.4)))
    sample.setInput(0, empty)
    output = subnet.createNode("output")
    output.setInput(0, sample)
    output.setDisplayFlag(True)
    output.setRenderFlag(True)
    box = subnet.createNetworkBox()
    box.setComment("Parameter test fixture output")
    for row, node in enumerate((empty, sample, output)):
        node.setPosition(hou.Vector2(0, -2 * row))
        box.addItem(node)
    box.fitAroundContents()
    box.setAutoFit(True)
    asset = subnet.createDigitalAsset(name, path, description=label, min_num_inputs=0, max_num_inputs=0)
    definition = asset.type().definition()
    definition.setParmTemplateGroup(interface())
    definition.setComment("Parameter editing test fixture. Cooks detail attributes on empty geometry.")
    help_text = VALUES_HELP if name == VALUES else STRUCTURE_HELP
    definition.addSection("Help", f"= {label} =\n\nParameter editing test fixture for HEGo. "
                          "Select the corresponding host in the parameter_types.tscn test scene.\n\n" + help_text)
    definition.save(path)
    geo.destroy()
    hou.hda.uninstallFile(path)


def verify(directory):
    for name in (VALUES, STRUCTURE):
        hou.hda.installFile(str(directory / (name + ".hda")))
    geo = hou.node("/obj").createNode("geo")
    values = geo.createNode(VALUES)
    other = geo.createNode(VALUES)
    structure = geo.createNode(STRUCTURE)
    for asset in (values, other, structure):
        asset.cook(force=True)
        assert asset.matchesCurrentDefinition() and not asset.errors() and not asset.warnings(), (
            asset.path(), asset.errors(), asset.warnings())
        assert not asset.geometry().points() and not asset.geometry().prims()
    values.parm("press_action").pressButton()
    assert values.evalParm("action_count") == 1 and other.evalParm("action_count") == 0
    values.parm("enabled").set(0)
    values.updateParmStates()
    assert values.parm("conditional_amount").isDisabled() and values.parm("conditional_text").isHidden()
    assert values.parm("dynamic_menu").menuItems() == ("base",)
    assert other.parm("dynamic_menu").menuItems() == ("base", "extra")
    assert values.evalParm("token_menu") == 10
    assert values.parm("geo_path").unexpandedString() == "$HIP/fixture.$F4.bgeo.sc"
    assert len(values.parmTuple("wide_floats")) == 9 and len(values.parmTuple("wide_ints")) == 6
    tabs = structure.parmTuple("display_tabs")
    assert tabs.parmTemplate().folderNames()[tabs.eval()[0]] == "Pattern"
    assert tabs.parmTemplate().tags()["group_default"] == "1"
    opaque = structure.parm("opaque")
    assert opaque.eval() == 1 and opaque.parmTemplate().tags()["group_default"] == "1"
    assert structure.parm("zero_entries").multiParmStartOffset() == 0
    structure.parm("zero_entries").set(1)
    assert structure.parm("zero_value0") is not None and structure.parm("child1_name1") is not None
    for name, style in (("entries", hou.folderType.MultiparmBlock),
                        ("scroll_entries", hou.folderType.ScrollingMultiparmBlock),
                        ("tab_entries", hou.folderType.TabbedMultiparmBlock)):
        assert structure.parm(name).parmTemplate().folderType() == style
    structure.parm("source_node").set(values.path())
    values.parm("marker").set(23)
    assert structure.geometry().attribValue("fixture_source_marker") == 23
    ramp = hou.Ramp((hou.rampBasis.Constant, hou.rampBasis.Linear), (0., 1.), (0.75, 1.))
    structure.parm("float_ramp").set(ramp)
    assert structure.geometry().attribValue("fixture_float_sample") == 0.75
    with tempfile.TemporaryDirectory() as temp:
        hip = str(Path(temp, "parameter_fixtures.hip"))
        paths = (values.path(), structure.path())
        hou.hipFile.save(hip)
        hou.hipFile.load(hip, suppress_save_prompt=True)
        assert hou.node(paths[0]).evalParm("action_count") == 1
        restored = hou.node(paths[1])
        assert restored.geometry().attribValue("fixture_source_marker") == 23
        assert restored.evalParm("float_ramp").basis() == ramp.basis()
        assert restored.geometry().attribValue("fixture_float_sample") == 0.75
    hou.hipFile.clear(suppress_save_prompt=True)
    print("PASS: fresh saved definitions, clean empty cooks, independent controls, ordered ramp and HIP round-trip")
    verify_hapi_types(directory)


def verify_hapi_types(directory):
    session = hapi.createInProcessSession(hapi.SessionInfo())
    hapi.initialize(session, hapi.CookOptions(), False)
    try:
        parameter_types = set()
        choice_types = set()
        for name in (VALUES, STRUCTURE):
            hapi.loadAssetLibraryFromFile(session, str(directory / (name + ".hda")), True)
            node = hapi.createNode(session, -1, "Sop/" + name, "", False)
            info = hapi.getNodeInfo(session, node)
            for parm in hapi.getParameters(session, node, 0, info.parmCount):
                parameter_types.add(int(parm.type))
                choice_types.add(parm.choiceListType)
        assert parameter_types == set(range(int(hapi.parmType.Max))), parameter_types
        assert choice_types == set(hapi.choiceListType), choice_types
        print(f"PASS: {len(parameter_types)} concrete HAPI parameter types and all five choice modes")
    finally:
        hapi.cleanup(session)
        hapi.closeSession(session)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.verify_only:
        verify(HERE)
    else:
        with tempfile.TemporaryDirectory(prefix="hego parameter fixtures ") as temporary:
            stage = Path(temporary)
            write_asset(stage, VALUES, "Parameter Test Fixture - Values", values_interface,
                        'i@fixture_marker = chi("../marker");')
            write_asset(stage, STRUCTURE, "Parameter Test Fixture - Structure", structure_interface, '''
f@fixture_float_sample = chramp("../float_ramp", 0.25);
v@fixture_color_sample = chramp("../color_ramp", 0.25);
string source = chsop("../source_node");
i@fixture_source_marker = source == "" ? -1 : int(detail("op:" + source, "fixture_marker", 0));
''')
            verify(stage)
            for operator in (VALUES, STRUCTURE):
                filename = operator + ".hda"
                shutil.copyfile(stage / filename, HERE / filename)
