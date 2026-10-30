"""Each addon may only name classes from the addons it declares as dependencies.

hego and strata depend on nothing; hego_strata depends on both. Godot has
no addon dependency system: a script naming another addon's class, or loading one of
its files, *is* the dependency. This keeps every such reference pointing the declared
way, so neither standalone addon can quietly start requiring the other again.

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
