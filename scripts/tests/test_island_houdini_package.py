"""Installer isolation and the portable package contract; no Houdini license."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("package_installer", ROOT / "scripts/install_island_houdini_package.py")
INSTALLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALLER)


class IslandHoudiniPackage(unittest.TestCase):
    def test_relative_package_prepends_instead_of_replacing_defaults(self):
        package = json.loads((ROOT / "demo/island/packages/hego_terrain_demo.json").read_text())
        entry = package["env"][0]["HOUDINI_OTLSCAN_PATH"]
        self.assertEqual(entry, {"method": "prepend", "value": "$HOUDINI_PACKAGE_PATH/../hda"})
        self.assertTrue(package["load_package_once"])

    def test_install_is_idempotent_and_preserves_existing_packages(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            source = root / "checkout with spaces/packages"
            source.mkdir(parents=True)
            (source / "hego_terrain_demo.json").write_text("{}")
            pref = root / "houdini22.0"
            (pref / "packages").mkdir(parents=True)
            original = pref / "packages/hego.json"
            original.write_text('{"env": [{"MY_SETTING": "untouched"}]}')
            destination = INSTALLER.install(pref, source)
            self.assertEqual(json.loads(destination.read_text())["package_path"], source.resolve().as_posix())
            self.assertNotEqual(destination.name, "hego_terrain_demo.json")
            before = destination.stat().st_mtime_ns
            self.assertEqual(INSTALLER.install(pref, source), destination)
            self.assertEqual(destination.stat().st_mtime_ns, before)
            self.assertEqual(original.read_text(), '{"env": [{"MY_SETTING": "untouched"}]}')

    def test_move_requires_explicit_replace_and_keeps_backup(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            first = root / "first"; second = root / "second"
            for source in (first, second):
                source.mkdir(); (source / "hego_terrain_demo.json").write_text("{}")
            destination = INSTALLER.install(root / "prefs", first)
            old = destination.read_bytes()
            with self.assertRaises(ValueError): INSTALLER.install(root / "prefs", second)
            self.assertEqual(destination.read_bytes(), old)
            INSTALLER.install(root / "prefs", second, replace=True)
            self.assertEqual(destination.with_suffix(".json.backup").read_bytes(), old)
            self.assertEqual(json.loads(destination.read_text())["package_path"], second.resolve().as_posix())

    def test_dry_run_and_missing_source_do_not_write(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); source = root / "package"; source.mkdir()
            with self.assertRaises(ValueError): INSTALLER.install(root / "prefs", source)
            (source / "hego_terrain_demo.json").write_text("{}")
            destination = INSTALLER.install(root / "prefs", source, dry_run=True)
            self.assertFalse(destination.exists())


if __name__ == "__main__": unittest.main()
