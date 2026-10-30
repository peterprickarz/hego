"""Each addon may only name classes from the addons it declares as dependencies.

hego and strata depend on nothing; hego_strata depends on both. hego_terrain3d
depends on hego and on the external Terrain3D addon (addons/terrain_3d), which it only
reaches through ClassDB, is_class() and Object.call(), never by class name, so that
dependency is not a scanned one. Godot has no addon dependency system: a script naming
another addon's class, or loading one of its files, *is* the dependency. This keeps every
such reference pointing the declared way, so no standalone addon can quietly start
requiring another again.

Run: python3 scripts/tests/test_addon_boundaries.py
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADDONS = ROOT / "demo" / "addons"
DEPENDS = {
    "hego": set(),
    "strata": set(),
    "hego_strata": {"hego", "strata"},
    "hego_terrain3d": {"hego"},
}
NATIVE_SOURCES = {"hego": ROOT / "src", "strata": ROOT / "terrain" / "src"}
SCANNED = {".gd", ".tscn", ".tres", ".gdshader", ".gdshaderinc", ".cfg", ".gdextension"}


def native_classes(source: Path) -> set[str]:
    names = set()
    for path in source.rglob("register_types.cpp"):
        pattern = r"(?:GDREGISTER_\w*CLASS\(|register_\w*class<)\s*(?:[\w:]*::)?(\w+)"
        names.update(match.group(1) for match in re.finditer(pattern, path.read_text()))
    return names


def script_classes(addon: str) -> set[str]:
    names = set()
    for path in (ADDONS / addon).rglob("*.gd"):
        match = re.search(r"^class_name\s+(\w+)", path.read_text(), re.M)
        if match:
            names.add(match.group(1))
    return names


def classes_of(addon: str) -> set[str]:
    names = script_classes(addon)
    if addon in NATIVE_SOURCES:
        names |= native_classes(NATIVE_SOURCES[addon])
    return names


class AddonBoundaries(unittest.TestCase):
    def test_every_addon_declares_classes(self):
        for addon in DEPENDS:
            self.assertTrue(classes_of(addon), f"found no classes in {addon}; is the scan still right?")
        self.assertIn("StrataLayerData", classes_of("strata"))
        self.assertIn("HEGoAPI", classes_of("hego"))
        self.assertIn("HEGoTerrain3DOutput", classes_of("hego_terrain3d"))

    def test_terrain3d_lives_only_in_its_bridge(self):
        # Terrain3D's own classes are not in the scan above, so check the code that would
        # use them directly: their names as strings (ClassDB, is_class), the addon's files
        # and the bridge's attribute prefix. Prose may still mention the bridge.
        # graph_placement.gd may probe for a Terrain3D node by class name string when
        # picking in the viewport; nothing else outside the bridge may.
        allowed = {ADDONS / "hego" / "graph_input" / "editor" / "graph_placement.gd"}
        pattern = re.compile(r"[\"']Terrain3D\w*[\"']|addons/terrain_3d|hegot3d_|HEGoTerrain3D")
        violations = []
        for addon in ("hego", "strata", "hego_strata"):
            for path in sorted((ADDONS / addon).rglob("*")):
                if path.suffix not in SCANNED or not path.is_file() or path in allowed:
                    continue
                for line_number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                    if pattern.search(line):
                        violations.append(f"{path.relative_to(ROOT)}:{line_number}: {line.strip()}")
        self.assertEqual(violations, [], "\n".join(violations))

    def test_references_follow_declared_dependencies(self):
        owned = {addon: classes_of(addon) for addon in DEPENDS}
        violations = []
        for addon, allowed in DEPENDS.items():
            forbidden = [other for other in DEPENDS if other != addon and other not in allowed]
            names = {name: other for other in forbidden for name in owned[other]}
            pattern = re.compile(r"\b(" + "|".join(sorted(map(re.escape, names))) + r")\b") if names else None
            for path in sorted((ADDONS / addon).rglob("*")):
                if path.suffix not in SCANNED or not path.is_file():
                    continue
                text = path.read_text(errors="replace")
                relative = path.relative_to(ROOT)
                if pattern:
                    for match in sorted(set(pattern.findall(text))):
                        violations.append(f"{relative} names {match} from {names[match]}")
                for other in forbidden:
                    if f"res://addons/{other}/" in text:
                        violations.append(f"{relative} loads a file from addons/{other}")
        self.assertEqual(violations, [], "\n".join(violations))


if __name__ == "__main__":
    unittest.main()
