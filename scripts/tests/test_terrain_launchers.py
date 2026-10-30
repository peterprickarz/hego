"""Offline launcher contracts: real demo editing and isolated test fixtures."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]


def module(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


ISLAND = module("island_launcher", "scripts/run_terrain_island.py")
PROTOTYPE = module("prototype_launcher", "scripts/run_terrain_prototype.py")
METADATA = module("hda_metadata", "scripts/houdini/hda_source_metadata.py")


def snapshot(root):
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in root.rglob("*") if path.is_file()}


class TerrainLaunchers(unittest.TestCase):
    def test_editor_and_play_use_saved_scene_without_staging_or_cooking(self):
        for mode, scene, editor in (([], "res://scenes/terrain_island.tscn", False),
                                    (["--editor"], "res://scenes/terrain_island.tscn", True),
                                    (["--quit-after-frames", "3"], "res://island/island_showcase.tscn", False)):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                project = root / "demo"
                files = {
                    "scenes/terrain_island.tscn": b"saved edited island",
                    "addons/strata/bin/libstrata.linux.template_debug.x86_64.so": b"terrain library",
                    "addons/hego/bin/libhego.linux.template_debug.x86_64.so": b"shipping hego library",
                }
                for relative, content in files.items():
                    target = project / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(content)
                before = snapshot(root)
                completed = Mock(returncode=0)
                with patch.object(ISLAND, "ROOT", root), patch.object(ISLAND, "PROJECT", project), patch.object(ISLAND.shutil, "which", return_value="/mock/godot"), patch.object(ISLAND.subprocess, "run", return_value=completed) as run, patch("sys.argv", ["run_terrain_island.py", "--godot", "mock-godot", *mode]):
                    self.assertEqual(ISLAND.main(), 0)
                self.assertEqual(snapshot(root), before)
                self.assertEqual(run.call_count, 2)  # Import, then the actual saved scene.
                launched = run.call_args.args[0]
                self.assertIn(str(project), launched)
                self.assertIn(scene, launched)
                self.assertEqual("--editor" in launched, editor)
                for call in run.call_args_list:
                    self.assertNotIn("--script", call.args[0])
                    self.assertFalse(any("prepare" in argument or "cook" in argument for argument in call.args[0]))

    def test_editor_rejects_diagnostic_options_before_launching(self):
        import contextlib
        import io
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            library = root / "demo/addons/strata/bin/libstrata.linux.template_debug.x86_64.so"
            library.parent.mkdir(parents=True)
            library.write_bytes(b"test library fixture")
            errors = io.StringIO()
            with patch.object(ISLAND, "ROOT", root), patch.object(ISLAND.shutil, "which", return_value="/mock/godot"), patch.object(ISLAND.subprocess, "run") as run, patch("sys.argv", ["run_terrain_island.py", "--editor", "--quit-after-frames", "3"]), contextlib.redirect_stderr(errors):
                with self.assertRaises(SystemExit) as raised:
                    ISLAND.main()
            self.assertEqual(raised.exception.code, 2)
            self.assertIn("showcase play only", errors.getvalue())
            run.assert_not_called()

    def test_headless_cook_modes_pass_their_flags_to_the_showcase(self):
        for mode, flag in (("--prepare", "--prepare-island"), ("--cook-materials", "--cook-materials"), ("--five-stage-check", "--five-stage-check"), ("--verify", "--verify")):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                library = root / "demo/addons/strata/bin/libstrata.linux.template_debug.x86_64.so"
                library.parent.mkdir(parents=True)
                library.write_bytes(b"test library fixture")
                with patch.object(ISLAND, "ROOT", root), patch.object(ISLAND, "PROJECT", root / "demo"), patch.object(ISLAND.shutil, "which", return_value="/mock/godot"), patch.object(ISLAND.subprocess, "run", return_value=Mock(returncode=0)) as run, patch("sys.argv", ["run_terrain_island.py", "--skip-import", mode]):
                    self.assertEqual(ISLAND.main(), 0)
                launched = run.call_args.args[0]
                self.assertIn("--headless", launched)
                self.assertIn("res://island/island_showcase.tscn", launched)
                self.assertIn(flag, launched)

    def test_prototype_test_staging_keeps_source_assets_outside_temp_project(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / "demo"
            addon = project / "addons/strata"
            for relative, data in {
                "addons/strata/manifest.json": b"canonical addon",
                "tests/native_data_test.gd": b"artificial test fixture",
                "scenes/terrain_prototype/main.tscn": b"prototype scene",
                "island/materials/images/large_texture.jpg": b"real asset should not be staged for unit tests",
            }.items():
                target = project / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            for name in PROTOTYPE.TEST_SCRIPTS:
                (project / "tests" / name).write_bytes(b"artificial test fixture")
            (project / "tests/hego_only_test.gd").write_bytes(b"must not import in standalone terrain tests")
            before = snapshot(project)
            destination = root / "disposable"
            with patch.object(PROTOTYPE, "PROJECT", project), patch.object(PROTOTYPE, "ADDON_SOURCE", addon):
                self.assertEqual(PROTOTYPE.stage_test_project(destination), destination)
            self.assertEqual(snapshot(project), before)
            self.assertTrue((destination / "tests/native_data_test.gd").is_file())
            self.assertTrue((destination / "scenes/terrain_prototype/main.tscn").is_file())
            self.assertFalse((destination / "tests/hego_only_test.gd").exists())
            self.assertFalse((destination / "island").exists())
            self.assertFalse((destination / "addons/hego").exists())

    def test_saved_hda_contracts_allow_paths_but_reject_semantic_changes(self):
        for name in ("contract.json", "material_contract.json", "tint_contract.json"):
            with self.subTest(contract=name):
                current = (ROOT / "demo/island/hda" / name).read_text()
                saved = current.replace('"otls/', '"demo/island/hda/')
                self.assertNotEqual(saved, current)
                self.assertTrue(METADATA.contract_metadata_matches(saved, current))
                changed = current.replace('"contract_version": ', '"contract_version": 100', 1)
                self.assertFalse(METADATA.contract_metadata_matches(saved, changed))
                self.assertFalse(METADATA.contract_metadata_matches(None, current))

    def test_saved_hda_provenance_allows_only_directory_migration(self):
        old = 'HDA_PATH = os.path.join(REPO, "terrain_demo", "island", "hda")\nseed = 32\n'
        current = old.replace('"terrain_demo"', '"demo"')
        self.assertTrue(METADATA.builder_source_matches(old, current))
        self.assertFalse(METADATA.builder_source_matches(old, current.replace("32", "31")))
        self.assertFalse(METADATA.builder_source_matches(None, current))


if __name__ == "__main__":
    unittest.main()
