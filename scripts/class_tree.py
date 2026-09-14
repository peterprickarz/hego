"""Places every generated class page into the documentation tree.

Nothing here decides what a class *does* - that comes from its XML. This decides where a
class appears in the sidebar, and refuses to produce a class reference with a class missing
from it. Adding a class therefore has to be a decision somebody makes, rather than one that
gets made by leaving it out.

Run from scripts/generate_docs.sh, after make_rst.py has written the raw pages.
"""

import argparse
import os
import re
import shutil
import sys
import xml.etree.ElementTree as ET

# ─────────────────────────────────────────────────────────────────────────────
# The tree. Every class in the XML has to appear in exactly one group below, or
# in INTERNAL_CLASSES with a reason.
# ─────────────────────────────────────────────────────────────────────────────

GROUPS = [
    (
        "houdini_engine_nodes",
        "Houdini Engine nodes",
        "One Godot object per node in the Houdini session. Everything a cook does is a "
        "method on one of these, and every one of those methods returns a "
        ":ref:`HEGoTask<class_HEGoTask>`.",
        [
            "HEGoAssetNode",
            "HEGoMergeNode",
            "HEGoInputNode",
            "HEGoCurveInputNode",
            "HEGoHeightfieldInputNode",
        ],
    ),
    (
        "node_base_classes",
        "Node base classes",
        "Shared by the nodes above. None can be instantiated; they are here because the "
        "methods a node inherits are documented on the class that declares them.",
        [
            "HEGoBaseNode",
            "HEGoTrackableNode",
            "HEGoTransformableNode",
            "HEGoTransformableNamedNode",
            "HEGoInputReceiverNode",
            "HEGoTransformableInputReceiverNode",
            "HEGoBaseInputNode",
        ],
    ),
    (
        "session_and_tasks",
        "Session, tasks and logging",
        "The session itself, the queue every Houdini call goes through, and where messages "
        "come out. See :doc:`/api/task_pattern` and :doc:`/api/logging`.",
        [
            "HEGoAPI",
            "HEGoTask",
            "HEGoLog",
        ],
    ),
    (
        "reading_output",
        "Reading a cook's output",
        "Points and surfaces as they sit in C++, filtered and split without being copied "
        "into Godot until asked for. See :doc:`/api/geo_output`.",
        [
            "HEGoGeoOutput",
            "HEGoGeoSelection",
            "HEGoGeoSurfaces",
            "HEGoGeoPrimSelection",
        ],
    ),
    (
        "writing_a_node",
        "Writing a node",
        "The node HEGo ships, the helper a node of your own holds, and what the two of them "
        "pass around. See :doc:`/api/custom_nodes/index`.",
        [
            "HEGoNode3D",
            "HEGoAssetAgent",
            "HEGoOutputContext",
            "HEGoNodeUtil",
            "HEGoInputNodes",
            "HEGoCookTimings",
        ],
    ),
    (
        "output_handlers",
        "Output handlers",
        "What turns a cook's geometry into Godot nodes, one class per output type, plus the "
        "pieces they share. See :doc:`/api/node3d_modules`.",
        [
            "HEGoMeshOutput",
            "HEGoMultiMeshOutput",
            "HEGoObjectOutput",
            "HEGoCurveOutput",
            "HEGoCurveBuilder",
            "HEGoPointUtil",
            "HEGoPropertyUtil",
        ],
    ),
    (
        "terrain3d",
        "Terrain3D",
        "Heightfields in both directions, for projects using the optional Terrain3D addon. "
        "None of it refers to Terrain3D's types directly, so HEGo runs without the addon "
        "installed.",
        [
            "HEGoTerrain3DInput",
            "HEGoTerrain3DOutput",
            "HEGoTerrain3DInstancer",
            "HEGoTerrain3DUtil",
        ],
    ),
    (
        "resources",
        "Resources",
        "What HEGo saves to disk.",
        [
            "HDAResource",
            "HEGoHDAPreset",
            "HEGoFetchPointsConfig",
            "HEGoFetchSurfacesConfig",
        ],
    ),
]

# Pages that stay linkable but out of the navigation, because they are parts of the bottom
# panel rather than anything a project would call.
INTERNAL_CLASSES = {
    "HEGoAssetSection": "a section of the bottom panel",
    "HEGoInputLineEdit": "a field in the bottom panel",
}

# Methods a class inherits are documented on the class that declares them, and make_rst does
# not cross-reference them from the subclass. These lists say where to look instead.
INHERITED_METHODS = {
    "HEGoAssetNode": [
        ("HEGoTransformableNode", ["set_transform"]),
        ("HEGoTransformableInputReceiverNode", ["connect_input"]),
        ("HEGoBaseNode", ["get_id", "instantiate", "reset_node_id"]),
    ],
    "HEGoCurveInputNode": [
        ("HEGoBaseInputNode", ["set_prim_attr"]),
        ("HEGoTransformableNode", ["set_transform"]),
        ("HEGoBaseNode", ["get_id", "instantiate", "reset_node_id"]),
    ],
    "HEGoHeightfieldInputNode": [
        ("HEGoBaseInputNode", ["set_prim_attr"]),
        ("HEGoTransformableNode", ["set_transform"]),
        ("HEGoBaseNode", ["get_id", "instantiate", "reset_node_id"]),
    ],
    "HEGoInputNode": [
        ("HEGoBaseInputNode", ["set_prim_attr"]),
        ("HEGoTransformableNode", ["set_transform"]),
        ("HEGoBaseNode", ["get_id", "instantiate", "reset_node_id"]),
    ],
    "HEGoMergeNode": [
        ("HEGoInputReceiverNode", ["connect_input"]),
        ("HEGoBaseNode", ["get_id", "instantiate", "reset_node_id"]),
    ],
}


def page_name(class_name):
    return "class_" + class_name.lower()


def read_classes(xml_dir):
    """Class name to its one-line brief, for every XML file in a directory."""
    classes = {}
    for entry in sorted(os.listdir(xml_dir)):
        if not entry.endswith(".xml"):
            continue
        root = ET.parse(os.path.join(xml_dir, entry)).getroot()
        brief = " ".join((root.findtext("brief_description") or "").split())
        classes[root.get("name")] = brief
    return classes


def read_registration_kinds(register_types_cpp):
    """Whether each C++ class can be instantiated, as register_types.cpp says."""
    source = "\n".join(
        line for line in open(register_types_cpp) if not line.strip().startswith("//")
    )
    kinds = {}
    patterns = [
        (r"GDREGISTER_ABSTRACT_CLASS\(([^)]*)\)", "Abstract"),
        (r"GDREGISTER_VIRTUAL_CLASS\(([^)]*)\)", "Virtual"),
        (r"ClassDB::register_class<([^>]*)>", "Concrete"),
    ]
    for pattern, kind in patterns:
        for symbol in re.findall(pattern, source):
            kinds[symbol.replace(" ", "").split("::")[-1]] = kind
    return kinds


def read_script_paths(gdscript_src_dir, project_dir):
    """Class name to the res:// path of the script declaring it."""
    paths = {}
    for directory, _, files in os.walk(gdscript_src_dir):
        for name in sorted(files):
            if not name.endswith(".gd"):
                continue
            full = os.path.join(directory, name)
            for line in open(full):
                match = re.match(r"^class_name\s+([A-Za-z_][A-Za-z0-9_]*)", line)
                if match:
                    paths[match.group(1)] = "res://" + os.path.relpath(full, project_dir)
                    break
    return paths


def ref(class_name):
    return ":ref:`{0}<class_{0}>`".format(class_name)


# The brief descriptions are written in Godot's markup, because that is what the editor's
# own help renders them with. make_rst.py translates it for the page bodies; the tables
# here are assembled from the XML directly, so they need the same handful of tags.
TAGGED = re.compile(r"\[(/?)(\w+)(?:[ =]([^\]]+))?\]")


def to_rst(markup, known_classes):
    """Godot's [code]...[/code] and [Class] markup as reStructuredText."""
    literal_tags = {"code", "codeblock"}
    simple = {"b": "**", "i": "*"}

    def replace(match):
        closing, tag, argument = match.group(1), match.group(2), match.group(3)

        # reStructuredText needs whitespace or punctuation on both sides of inline markup,
        # and a brief like "into [Curve3D]s" puts a word straight after it. Only the side
        # facing out of the markup needs the escape, so an opening tag looks left, a
        # closing tag looks right, and a tag standing on its own looks both ways.
        def spaced(text, left, right):
            before = "\\ " if left and match.start() > 0 and markup[match.start() - 1].isalnum() else ""
            after = "\\ " if right and match.end() < len(markup) and markup[match.end()].isalnum() else ""
            return before + text + after

        if tag in literal_tags:
            return spaced("``", not closing, bool(closing))
        if tag in simple:
            return spaced(simple[tag], not closing, bool(closing))
        if closing:
            return ""
        if tag in ("method", "member", "constant", "signal", "param", "theme_item"):
            name = (argument or "").split(".")[-1]
            return spaced("``{0}{1}``".format(name, "()" if tag == "method" else ""), True, True)
        if tag in known_classes:
            return spaced(ref(tag), True, True)
        return spaced("``{0}``".format(tag), True, True)

    return TAGGED.sub(replace, markup)


def write_group_page(out_dir, slug, title, blurb, class_names, briefs, known_classes):
    lines = [
        title,
        "=" * len(title),
        "",
        blurb,
        "",
        ".. list-table::",
        "   :widths: 34 66",
        "   :header-rows: 1",
        "",
        "   * - Class",
        "     - Description",
    ]
    for class_name in class_names:
        lines.append("   * - " + ref(class_name))
        lines.append("     - " + to_rst(briefs.get(class_name) or "", known_classes))
    lines += [
        "",
        ".. toctree::",
        "   :maxdepth: 1",
        "   :hidden:",
        "",
    ]
    lines += ["   " + page_name(class_name) for class_name in class_names]
    lines.append("")
    with open(os.path.join(out_dir, slug + ".rst"), "w") as handle:
        handle.write("\n".join(lines))


def write_index(out_dir):
    lines = [
        "HEGo Class Reference",
        "====================",
        "",
        "Every class HEGo registers. The C++ pages come from the class reference XML in",
        "``demo/addons/hego/doc_classes``; the GDScript pages are generated from the scripts'",
        "own ``##`` comments, so a class page and the editor's built-in help say the same thing.",
        "",
    ]
    for slug, title, blurb, class_names in GROUPS:
        lines += [
            title,
            "-" * len(title),
            "",
            blurb,
            "",
        ]
        lines += ["- " + ref(class_name) for class_name in class_names]
        lines.append("")
    lines += [
        ".. toctree::",
        "   :maxdepth: 2",
        "   :hidden:",
        "",
    ]
    lines += ["   " + slug for slug, _, _, _ in GROUPS]
    lines.append("")
    with open(os.path.join(out_dir, "index.rst"), "w") as handle:
        handle.write("\n".join(lines))


def append_section(path, body_lines):
    with open(path, "a") as handle:
        handle.write("\n".join(["", ".. rst-class:: classref-section-separator", "", "----", ""] + body_lines) + "\n")


REFERENCE = re.compile(r":ref:`([^`<]+)<([^`>]+)>`")
LABEL = re.compile(r"^\.\. _([^:]+):$", re.MULTILINE)


def resolve_engine_references(out_dir):
    """Turns links to labels no page defines into inline code."""
    pages = sorted(name for name in os.listdir(out_dir) if name.endswith(".rst"))

    labels = set()
    for name in pages:
        labels.update(LABEL.findall(open(os.path.join(out_dir, name)).read()))

    def replace(match):
        text, label = match.group(1), match.group(2)
        return match.group(0) if label in labels else "``{0}``".format(text)

    for name in pages:
        path = os.path.join(out_dir, name)
        body = open(path).read()
        rewritten = REFERENCE.sub(replace, body)
        if rewritten != body:
            open(path, "w").write(rewritten)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generated", required=True, help="where make_rst.py wrote its pages")
    parser.add_argument("--out", required=True, help="docs/classes")
    parser.add_argument("--cpp-xml", required=True)
    parser.add_argument("--gdscript-xml", required=True)
    parser.add_argument("--gdscript-src", required=True)
    parser.add_argument("--register-types", required=True)
    args = parser.parse_args()

    cpp_classes = read_classes(args.cpp_xml)
    gdscript_classes = read_classes(args.gdscript_xml)
    briefs = dict(cpp_classes)
    briefs.update(gdscript_classes)

    # ── every class placed, every placement real ─────────────────────────────
    placed = []
    for _, _, _, class_names in GROUPS:
        placed += class_names

    problems = []
    duplicates = {name for name in placed if placed.count(name) > 1}
    for name in sorted(duplicates):
        problems.append("{0} is in more than one group".format(name))

    known = set(placed) | set(INTERNAL_CLASSES)
    for name in sorted(set(briefs) - known):
        problems.append(
            "{0} is documented but has no place in the tree: add it to a group in "
            "scripts/class_tree.py, or to INTERNAL_CLASSES if it is a part of the panel".format(name)
        )
    for name in sorted(known - set(briefs)):
        problems.append("{0} is in the tree but no XML documents it".format(name))
    for name in sorted(set(briefs)):
        if not briefs[name] and name not in INTERNAL_CLASSES:
            problems.append("{0} has no brief description".format(name))

    if problems:
        print("Error: the class tree does not match the documented classes:", file=sys.stderr)
        for problem in problems:
            print("  - " + problem, file=sys.stderr)
        return 1

    # ── copy the pages we know about ─────────────────────────────────────────
    if os.path.isdir(args.out):
        shutil.rmtree(args.out)
    os.makedirs(args.out)

    for name in sorted(briefs):
        source = os.path.join(args.generated, page_name(name) + ".rst")
        if not os.path.isfile(source):
            print("Error: make_rst.py generated no page for " + name, file=sys.stderr)
            return 1
        shutil.copy(source, os.path.join(args.out, page_name(name) + ".rst"))

    # ── navigation ───────────────────────────────────────────────────────────
    write_index(args.out)
    for slug, title, blurb, class_names in GROUPS:
        write_group_page(args.out, slug, title, blurb, class_names, briefs, set(briefs))

    for name, reason in INTERNAL_CLASSES.items():
        path = os.path.join(args.out, page_name(name) + ".rst")
        body = open(path).read()
        with open(path, "w") as handle:
            handle.write(":orphan:\n\n.. Out of the navigation tree: " + reason + ".\n\n" + body)

    # ── references the class reference cannot resolve ────────────────────────
    # A doc comment linking an engine member, [method Object.call] say, is a link the
    # Godot editor resolves and this site cannot: the engine's own class reference is not
    # part of this build. Sphinx would report each one as an undefined label, so they
    # become plain code instead, which is what they read as anyway.
    resolve_engine_references(args.out)

    # ── footers ──────────────────────────────────────────────────────────────
    project_dir = os.path.dirname(os.path.dirname(os.path.abspath(args.gdscript_src)))
    script_paths = read_script_paths(args.gdscript_src, project_dir)
    kinds = read_registration_kinds(args.register_types)

    for name in sorted(briefs):
        path = os.path.join(args.out, page_name(name) + ".rst")
        footer = [".. rst-class:: classref-descriptions-group", "", "Class Registration", "------------------", ""]
        if name in gdscript_classes:
            footer.append("- Kind: GDScript class")
            if name in script_paths:
                footer.append("- Script: ``{0}``".format(script_paths[name]))
        elif name in kinds:
            footer.append("- Kind: {0}".format(kinds[name]))
        else:
            continue
        append_section(path, footer)

    for name, inherited in INHERITED_METHODS.items():
        path = os.path.join(args.out, page_name(name) + ".rst")
        body = [".. rst-class:: classref-descriptions-group", "", "Inherited Methods", "-----------------", ""]
        for declaring_class, methods in inherited:
            links = ", ".join(
                ":ref:`{0}()<class_{1}_method_{0}>`".format(method, declaring_class) for method in methods
            )
            body.append("- {0} from :ref:`{1}<class_{1}>`.".format(links, declaring_class))
        append_section(path, body)

    print("  {0} class pages in {1} groups".format(len(briefs), len(GROUPS)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
