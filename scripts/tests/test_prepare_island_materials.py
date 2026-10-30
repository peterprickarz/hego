"""Offline safety checks for the island demo asset preparation script."""

import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("island_material_prep", ROOT / "scripts/prepare_island_materials.py")
PREP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREP)


class MaterialPreparationTests(unittest.TestCase):
    def test_existing_resource_is_byte_exact_and_not_touched(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            resource = output / "resources/island_grass.tres"
            resource.parent.mkdir()
            artist_bytes = b'uid="uid://artist"\nuv_scale=7.25\ndisplacement_strength=2.27\ncustom_setting=true\n'
            resource.write_bytes(artist_bytes)
            modified = resource.stat().st_mtime_ns
            self.assertFalse(PREP.write_material_resource(output, "island_grass"))
            self.assertEqual(resource.read_bytes(), artist_bytes)
            self.assertEqual(resource.stat().st_mtime_ns, modified)

    def test_explicit_reset_and_new_resource_use_defaults(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            self.assertTrue(PREP.write_material_resource(output, "new_fixture", defaults={"uv_scale": .25, "roughness_bias": .17}))
            resource = output / "resources/new_fixture.tres"
            self.assertIn("uv_scale = 0.250000", resource.read_text())
            self.assertIn("roughness_bias = 0.1700", resource.read_text())
            resource.write_bytes(b"artist override")
            self.assertTrue(PREP.write_material_resource(output, "new_fixture", reset=True))
            self.assertNotEqual(resource.read_bytes(), b"artist override")

    def test_catalog_has_four_unique_sources_resources_and_channels(self):
        sources = json.loads(PREP.SOURCES.read_text())["assets"]
        PREP.validate_sources(sources)
        registry = json.loads((PREP.DEFAULT_OUTPUT / "material_registry.json").read_text())
        self.assertEqual([row["name"] for row in sources], ["coastal_sand", "island_grass", "scree_gravel", "dark_cliff"])
        self.assertEqual([row["role"] for row in sources], ["sand", "grass", "gravel", "cliff"])
        self.assertEqual(len({row["id"] for row in sources}), 4)
        self.assertEqual([row["id"] for row in registry], list(range(4)))
        self.assertEqual([row["name"] for row in registry], [row["name"] for row in sources])
        self.assertEqual([row["channel"] for row in registry], ["material_" + row["name"] for row in sources])
        self.assertEqual(len({row["resource"] for row in registry}), 4)
        self.assertEqual(len({row["source_url"] for row in registry}), 4)
        self.assertEqual(json.loads(PREP.SOURCES.read_text())["resolution_format"], "1K-JPG")

    def test_aliases_and_nonconsecutive_ids_are_rejected(self):
        with self.assertRaises(RuntimeError):
            PREP.validate_sources([{"id": "same", "name": "one", "material_id": 0}, {"id": "same", "name": "two", "material_id": 1}])
        with self.assertRaises(RuntimeError):
            PREP.validate_sources([{"id": "one", "name": "one", "material_id": 1}])

    def test_unchanged_texture_does_not_trigger_reimport(self):
        with tempfile.TemporaryDirectory() as temporary:
            texture = Path(temporary) / "source.jpg"
            texture.write_bytes(b"existing texture")
            modified = texture.stat().st_mtime_ns
            PREP.write_if_changed(texture, texture.read_bytes())
            self.assertEqual(texture.stat().st_mtime_ns, modified)

    def test_bounded_range_resume_validates_and_publishes_complete_archive(self):
        payload = b"unchanged real source bytes" * 1000
        ranges = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                requested = self.headers["Range"].split("=")[1]
                first, last = requested.split("-")
                first = int(first)
                last = min(int(last), len(payload) - 1)
                ranges.append((first, last))
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {first}-{last}/{len(payload)}")
                self.send_header("Content-Length", str(last - first + 1))
                self.end_headers()
                self.wfile.write(payload[first:last + 1])

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as temporary:
                destination = Path(temporary) / "archive.zip"
                partial = destination.with_suffix(".zip.part")
                partial.write_bytes(payload[:1111])
                PREP.atomic_download(f"http://127.0.0.1:{server.server_port}/asset", destination, len(payload), 4096)
                self.assertEqual(destination.read_bytes(), payload)
                self.assertFalse(partial.exists())
                self.assertEqual(ranges[0][0], 1111)
                self.assertTrue(all(last - first + 1 <= 4096 for first, last in ranges))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
