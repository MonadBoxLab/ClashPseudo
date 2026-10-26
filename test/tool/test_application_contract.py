"""验证共同契约生成及过期产物检查。"""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("application_contract_generator", ROOT / "tool/contracts/generate.py")
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class ApplicationContractTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "contracts").mkdir()
        self.source = self.root / GENERATOR.SOURCE
        self.source.write_text(json.dumps({
            "sample": {"bytes": 257, "timeout_ms": 1300, "label": "controlled"},
        }))
        self.geo = self.root / "android/app/src/main/assets/geodata/manifest.json"
        self.ca = self.root / "third_party/data/certificates/manifest.json"
        self.geo.parent.mkdir(parents=True)
        self.ca.parent.mkdir(parents=True)
        self.geo.write_text(json.dumps({
            "format": "clash-pseudo-bundled-geodata", "version": 1,
            "files": [{
                "kind": kind, "asset": kind + ".dat", "encoding": "identity",
                "storedBytes": 11, "installedBytes": 11,
                "storedSha256": "1" * 64, "installedSha256": "1" * 64,
            } for kind in ("geoip", "geosite", "mmdb", "asn")],
        }))
        self.ca.write_text(json.dumps({
            "asset": "certificates/controlled.pem", "bytes": 13, "sha256": "2" * 64,
        }))

    def test_each_language_uses_the_same_input_and_check_preserves_files(self):
        GENERATOR.generate(self.root)
        outputs = GENERATOR.outputs(self.root)
        self.assertEqual(len(outputs), 5)
        for path, body in outputs.items():
            if path.name != "BundledAssetContract.kt":
                self.assertIn("257", body)
                self.assertIn("1300", body)
                self.assertIn('"controlled"', body)
            self.assertEqual((self.root / path).read_text(), body)
        before = {p: (self.root / p).stat().st_mtime_ns for p in outputs}
        GENERATOR.generate(self.root, check=True)
        self.assertEqual(before, {p: (self.root / p).stat().st_mtime_ns for p in outputs})

    def test_changed_source_is_rejected_until_all_consumers_are_regenerated(self):
        GENERATOR.generate(self.root)
        before = {p: (self.root / p).read_bytes() for p in GENERATOR.outputs(self.root)}
        self.source.write_text(json.dumps({"sample": {"bytes": 513}}))
        with self.assertRaisesRegex(ValueError, "stale"):
            GENERATOR.generate(self.root, check=True)
        for path, body in before.items():
            self.assertEqual((self.root / path).read_bytes(), body)
        GENERATOR.generate(self.root)
        GENERATOR.generate(self.root, check=True)
        for path, body in GENERATOR.outputs(self.root).items():
            if path.name != "BundledAssetContract.kt":
                self.assertIn("513", body)
                self.assertNotIn("257", body)

    def test_duplicate_keys_and_wrong_value_types_fail_before_generation(self):
        for source in ['{"sample":{"bytes":1,"bytes":2}}',
                       '{"sample":{"bytes":true}}',
                       '{"sample":{"bytes":-1}}']:
            with self.subTest(source=source):
                self.source.write_text(source)
                with self.assertRaises(ValueError):
                    GENERATOR.generate(self.root)
                self.assertFalse((self.root / "lib").exists())

    def test_resource_metadata_drives_the_runtime_definitions(self):
        metadata = GENERATOR.asset_metadata(self.root)
        self.assertIn('BundledGeo.Data("geoip.dat", false, 11L,', metadata)
        self.assertIn('CERTIFICATE_ASSET = "certificates/controlled.pem"', metadata)
        self.assertIn('CERTIFICATE_BYTES = 13', metadata)
        GENERATOR.generate(self.root)
        certificate = json.loads(self.ca.read_text())
        certificate["bytes"] = 17
        self.ca.write_text(json.dumps(certificate))
        with self.assertRaisesRegex(ValueError, "stale"):
            GENERATOR.generate(self.root, check=True)
        GENERATOR.generate(self.root)
        self.assertIn('CERTIFICATE_BYTES = 17', GENERATOR.asset_metadata(self.root))

    def test_incomplete_or_invalid_resources_fail_before_writing(self):
        original = self.geo.read_text()
        for key, value in [("kind", "unknown"), ("asset", "../outside"),
                           ("asset", "$interpolation"), ("encoding", "unknown"),
                           ("storedBytes", True), ("installedBytes", -1),
                           ("installedSha256", "bad")]:
            with self.subTest(key=key, value=value):
                manifest = json.loads(original)
                manifest["files"][0][key] = value
                self.geo.write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    GENERATOR.generate(self.root)
                self.assertFalse((self.root / "lib").exists())
        self.geo.write_text(original)
        for path in (self.geo, self.ca):
            content = path.read_text()
            path.unlink()
            with self.assertRaises(OSError):
                GENERATOR.generate(self.root)
            self.assertFalse((self.root / "lib").exists())
            path.write_text(content)

    def test_output_ownership_is_checked_before_any_write(self):
        GENERATOR.generate(self.root)
        outputs = GENERATOR.outputs(self.root)
        protected = self.root / next(p for p in outputs if p.name == "BundledAssetContract.kt")
        protected.write_text("user-owned source")
        first = self.root / next(iter(outputs))
        before = first.read_bytes()
        self.source.write_text(json.dumps({"sample": {"bytes": 513}}))
        with self.assertRaisesRegex(ValueError, "not owned"):
            GENERATOR.generate(self.root)
        self.assertEqual(first.read_bytes(), before)
        self.assertEqual(protected.read_text(), "user-owned source")

    def test_project_generated_sources_match_the_authoritative_contract(self):
        GENERATOR.generate(ROOT, check=True)


if __name__ == "__main__":
    unittest.main()
