"""Check generated cross-language constants and detect stale generated files."""

import tool_test_support
from tool.contracts import generate as GENERATOR
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


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
            "asset": "certificates/controlled.pem", "bytes": 13, "sha256": "2" * 64, "roots": 1,
        }))

    def test_each_language_uses_the_same_input_and_check_preserves_files(self):
        GENERATOR.generate(self.root)
        outputs = GENERATOR.outputs(self.root)
        self.assertEqual(len(outputs), 4)
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

    def metadata(self):
        return GENERATOR.asset_metadata(json.loads(self.geo.read_bytes()), json.loads(self.ca.read_bytes()))

    def test_resource_metadata_drives_the_runtime_definitions(self):
        metadata = self.metadata()
        self.assertIn('BundledGeo.Data("geoip.dat", false, 11L,', metadata)
        self.assertIn('CERTIFICATE_ASSET = "certificates/controlled.pem"', metadata)
        self.assertIn('CERTIFICATE_BYTES = 13', metadata)
        self.assertIn('CERTIFICATE_ROOTS = 1', metadata)
        GENERATOR.generate(self.root)
        certificate = json.loads(self.ca.read_text())
        certificate["bytes"] = 17
        self.ca.write_text(json.dumps(certificate))
        GENERATOR.generate(self.root, check=True)
        self.assertIn('CERTIFICATE_BYTES = 17', self.metadata())

    def test_incomplete_or_invalid_resources_fail_before_writing(self):
        original = self.geo.read_text()
        for key, value in [("kind", "unknown"), ("asset", "../outside"),
                           ("asset", "$interpolation"), ("encoding", "unknown")]:
            with self.subTest(key=key, value=value):
                manifest = json.loads(original)
                manifest["files"][0][key] = value
                self.geo.write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    self.metadata()
                self.assertFalse((self.root / "lib").exists())
        self.geo.unlink()
        self.ca.unlink()
        GENERATOR.generate(self.root)
        GENERATOR.generate(self.root, check=True)

    def test_resource_generation_copies_measured_values_without_revalidation(self):
        manifest = json.loads(self.geo.read_text())
        manifest["files"][0].update(storedBytes=2**32, installedBytes=2**32 + 1,
                                    storedSha256="stored-result", installedSha256="installed-result")
        certificate = json.loads(self.ca.read_text())
        certificate.update(bytes=0, sha256="certificate-result", roots=0)
        result = GENERATOR.asset_metadata(manifest, certificate)
        self.assertIn('4294967297L, "installed-result", 4294967296L, "stored-result"', result)
        self.assertIn('CERTIFICATE_BYTES = 0', result)
        self.assertIn('CERTIFICATE_ROOTS = 0', result)
        self.assertIn('CERTIFICATE_SHA256 = "certificate-result"', result)

    def test_output_ownership_is_checked_before_any_write(self):
        GENERATOR.generate(self.root)
        outputs = GENERATOR.outputs(self.root)
        protected = self.root / list(outputs)[-1]
        protected.write_text("user-owned source")
        first = self.root / next(iter(outputs))
        before = first.read_bytes()
        self.source.write_text(json.dumps({"sample": {"bytes": 513}}))
        with self.assertRaisesRegex(ValueError, "not owned"):
            GENERATOR.generate(self.root)
        self.assertEqual(first.read_bytes(), before)
        self.assertEqual(protected.read_text(), "user-owned source")

    def test_core_contract_rejects_duplicate_codes_and_inconsistent_limits(self):
        original = json.loads((ROOT / GENERATOR.SOURCE).read_text())
        cases = [
            ("core_operation", "rules", original["core_operation"]["nodes"]),
            ("core_operation", "rules", True),
            ("core_ipc", "frame_terminal", original["core_ipc"]["frame_record"]),
            ("core_ipc", "frame_terminal", 256),
            ("core_ipc", "record_bytes", original["core_ipc"]["frame_bytes"] + 1),
            ("core_ipc", "queue_bytes", original["core_ipc"]["frame_bytes"] - 1),
            ("core_ipc", "control_bytes", original["core_ipc"]["identity_bytes"] - 1),
            ("core_field", "process_id", original["core_field"]["input_id"]),
            ("core_purpose", "running", original["core_purpose"]["preview"]),
        ]
        for domain, key, value in cases:
            with self.subTest(domain=domain, key=key, value=value):
                data = json.loads(json.dumps(original))
                data[domain][key] = value
                self.source.write_text(json.dumps(data))
                with self.assertRaises(ValueError):
                    GENERATOR.generate(self.root)
                self.assertFalse((self.root / "lib").exists())

    def test_core_protocol_is_generated_with_the_same_names_and_values(self):
        self.source.write_bytes((ROOT / GENERATOR.SOURCE).read_bytes())
        GENERATOR.generate(self.root)
        outputs = GENERATOR.outputs(self.root)
        for path, body in outputs.items():
            if path.name != "BundledAssetContract.kt":
                self.assertIn('"processId"', body)
                self.assertIn('"inputId"', body)
                self.assertIn('"communicationLost"', body)
                self.assertIn('"coreSubmit"', body)
                self.assertIn('"recordCount"', body)
        data = json.loads(self.source.read_text())
        self.assertEqual(data["configuration"]["text_bytes"], 16 * 1024 * 1024)
        self.assertEqual(data["configuration"]["override_json_bytes"], 128 * 1024 * 1024)
        self.assertEqual(data["connection"]["response_bytes"], 8 * 1024 * 1024)
        self.assertNotIn("collection_bytes", data["core_ipc"])

    def test_project_generated_sources_match_the_authoritative_contract(self):
        GENERATOR.generate(ROOT, check=True)


if __name__ == "__main__":
    unittest.main()
