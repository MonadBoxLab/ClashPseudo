"""Test resource preparation, source record validation, and batch writes with synthetic resources."""

from contextlib import redirect_stdout
import gzip
import hashlib
import tool_test_support
from tool.dependencies import update, resources, sources, packages, inputs, legal
from tool.common import io as common_io, workspace
from tool.cli import main as cli_main
import io
import json
from pathlib import Path
import shutil
import ssl
import tempfile
import unittest
from unittest import mock
import zipfile


ROOT = Path(__file__).resolve().parents[2]









def digest(data):
    return hashlib.sha256(data).hexdigest()


def varint(value):
    result = bytearray()
    while value > 127:
        result.append(value & 127 | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def pb(field, value):
    return varint(field << 3 | 2) + varint(len(value)) + value


def mmdb_value(value):
    if isinstance(value, str):
        data = value.encode()
        assert len(data) < 29
        return bytes([2 << 5 | len(data)]) + data
    if isinstance(value, dict):
        return bytes([7 << 5 | len(value)]) + b"".join(mmdb_value(key) + mmdb_value(item) for key, item in value.items())
    if isinstance(value, bool):
        return bytes([int(value), 7])  # Extended type 14 encodes the boolean in the length field with no trailing data bytes
    return bytes([6 << 5 | 1, value])


def mmdb(kind):
    metadata = {
        "node_count": 1, "record_size": 24, "ip_version": 6,
        "database_type": "DBIP-Country-Lite" if kind == "mmdb" else "DBIP-ASN-Lite",
        "binary_format_major_version": 2, "description": {"en": "synthetic"}, "extra": True,
    }
    return b"\0\0\x11" * 2 + bytes(16) + mmdb_value("synthetic") + b"\xab\xcd\xefMaxMind.com" + mmdb_value(metadata)


class ResourceTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="resource-regression-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.root = self.base / "project"
        self.root.mkdir()
        self.put("pubspec.yaml", b"name: sample\nversion: 1.0.0+1\n")
        self.put("pubspec.lock", b"unchanged lock\n")
        self.put("android/app/build.gradle.kts", b"android { minSdk = 24 }\n")
        self.put("native/mihomo/go.mod", ("module example.test/app\nrequire " + packages.MIHOMO + " v1.0.0\n").encode())
        self.put("native/mihomo/go.sum", b"unchanged sums\n")
        self.put("third_party/data/certificates/manifest.json", b'{"unknown":false}\n')
        self.put("android/app/src/main/assets/geodata/manifest.json",
                 b'{"unknown":null,"files":[{"kind":"geoip","future":[]}]}\n')
        self.put("third_party/data/certificates/MPL-2.0.txt", b"synthetic MPL original\r\n")
        for name in ("CC-BY-SA-4.0.txt", "GeoSite-MIT.txt", "CC-BY-4.0.txt"):
            self.put("third_party/data/geodata/" + name, b"synthetic original license\r\n" + name.encode())
        self.installed = {
            "ca": (ROOT / "android/app/src/test/resources/certificates/synthetic-ec-acc-positive.pem").read_bytes(),
            "geoip": pb(1, pb(1, b"TEST") + pb(2, pb(1, b"\x7f\0\0\0") + b"\x10\x08")),
            "geosite": pb(1, pb(1, b"TEST") + pb(2, pb(2, b"example.test"))),
            "mmdb": mmdb("mmdb"), "asn": mmdb("asn"),
        }
        self.data = {kind: gzip.compress(data, mtime=0) if kind in ("mmdb", "asn") else data
                     for kind, data in self.installed.items()}
        self.specs = {kind: self.make_spec(kind) for kind in self.data}
        self.sources = {}
        for kind, data in self.data.items():
            directory = self.base / "raw" / kind
            directory.mkdir(parents=True)
            self.sources[kind] = directory / "original"
            self.sources[kind].write_bytes(data)
        context = mock.patch.object(resources.ssl, "SSLContext", wraps=ssl.SSLContext)
        self.context = context.start()
        self.addCleanup(context.stop)
        network = mock.patch.object(resources, "download", side_effect=AssertionError("network not allowed in regression"))
        self.network = network.start()
        self.addCleanup(network.stop)

    def put(self, relative, data):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def make_spec(self, kind, stored=None, installed=None):
        stored = self.data[kind] if stored is None else stored
        installed = self.installed[kind] if installed is None else installed
        version = "2026-10-01" if kind == "ca" else "202610010101" if kind in ("geoip", "geosite") else "2026-10"
        urls = {
            "ca": f"https://curl.se/ca/cacert-{version}.pem",
            "geoip": f"https://github.com/v2fly/geoip/releases/download/{version}/geoip.dat",
            "geosite": f"https://github.com/v2fly/domain-list-community/releases/download/{version}/dlc.dat",
            "mmdb": f"https://download.db-ip.com/free/dbip-country-lite-{version}.mmdb.gz",
            "asn": f"https://download.db-ip.com/free/dbip-asn-lite-{version}.mmdb.gz",
        }
        spec = {"kind": kind, "version": version, "sourceUrl": urls[kind],
                "storedBytes": len(stored), "storedSha256": digest(stored),
                "installedBytes": len(installed), "installedSha256": digest(installed)}
        if kind in ("geoip", "geosite"):
            spec["sourceCommit"] = "a" * 40
            name = "CC-BY-SA-4.0.txt" if kind == "geoip" else "GeoSite-MIT.txt"
            spec["licenseSha256"] = digest((self.root / "third_party/data/geodata" / name).read_bytes())
        if kind in ("mmdb", "asn"):
            name = "country" if kind == "mmdb" else "asn"
            spec["sourcePage"] = f"https://db-ip.com/db/download/ip-to-{name}-lite"
        return spec

    def prepare(self):
        return resources.prepare_resources(list(self.specs.values()), self.base / "prepared", self.sources)



    def unknown_spec(self, kind):
        return {key: value for key, value in self.specs[kind].items()
                if key not in ("storedBytes", "storedSha256", "installedBytes", "installedSha256")}

    def test_first_dbip_prepare_measures_unknown_bytes_and_resume_never_fetches(self):
        before = inputs.snapshot(self.root)
        for kind in ("mmdb", "asn"):
            spec = self.unknown_spec(kind)
            directory = resources.prepare_resource(spec, self.base / ("first-" + kind), self.sources[kind])
            fixed = json.loads((directory / "resource.json").read_bytes())
            self.assertEqual(set(path.name for path in directory.iterdir()), {"resource.json", "payload"})
            self.assertEqual(fixed["sourceUrl"], spec["sourceUrl"])
            resolved, data = resources.read_prepared_resource(directory)
            self.assertEqual(data, self.data[kind])
            for key in ("storedBytes", "storedSha256", "installedBytes", "installedSha256"):
                self.assertNotIn(key, spec)
                self.assertEqual(resolved[key], self.specs[kind][key])
            self.assertEqual(resources.prepare_resource(spec, directory), directory)
            (directory / "payload").write_bytes(self.data[kind][:-1])
            with self.assertRaises(ValueError):
                resources.prepare_resource(spec, directory)
        self.network.assert_not_called()
        self.assertEqual(inputs.snapshot(self.root), before)

    def test_resource_record_accepts_json_whitespace_and_measures_installed_bytes(self):
        directory = resources.prepare_resource(self.unknown_spec("mmdb"), self.base / "record", self.sources["mmdb"])
        path = directory / "resource.json"
        fixed = json.loads(path.read_bytes())
        fixed["installedBytes"] = 1
        fixed["installedSha256"] = "old measurement"
        path.write_text(json.dumps(fixed, indent=4))
        resolved, data = resources.read_prepared_resource(directory)
        self.assertEqual(data, self.data["mmdb"])
        self.assertEqual(resolved["installedBytes"], len(self.installed["mmdb"]))
        self.assertEqual(resolved["installedSha256"], digest(self.installed["mmdb"]))
        self.network.assert_not_called()


    def test_known_official_expected_digest_is_not_replaced_with_a_measured_value(self):
        spec = self.unknown_spec("geoip")
        spec["storedSha256"] = "0" * 64
        directory = self.base / "wrong-official-digest"
        with self.assertRaisesRegex(ValueError, "Downloaded file size or SHA-256 differs from the record"):
            resources.prepare_resource(spec, directory, self.sources["geoip"])
        self.assertFalse((directory / "resource.json").exists())
        self.assertFalse((directory / "payload").exists())
        self.network.assert_not_called()

    def test_ca_official_checksum_is_checked_and_fixed_before_any_resume(self):
        spec = self.unknown_spec("ca")
        spec["checksumUrl"] = spec["sourceUrl"] + ".sha256"
        checksum = (digest(self.data["ca"]) + "  cacert.pem\n").encode()
        with mock.patch.object(resources, "download", return_value=checksum) as fetch:
            directory = resources.prepare_resource(spec, self.base / "official-ca", self.sources["ca"])
            fetch.assert_called_once_with(spec["checksumUrl"], limit=4096)
        self.assertEqual(resources.read_prepared_resource(directory)[0]["storedSha256"], digest(self.data["ca"]))
        self.assertEqual(resources.prepare_resource(spec, directory), directory)
        with mock.patch.object(resources, "download", return_value=b"0" * 64 + b"  cacert.pem\n"):
            failed = self.base / "bad-checksum-ca"
            with self.assertRaisesRegex(ValueError, "Downloaded file size or SHA-256 differs from the record"):
                resources.prepare_resource(spec, failed, self.sources["ca"])
            self.assertFalse((failed / "resource.json").exists())
        self.network.assert_not_called()

    def test_unknown_size_still_obeys_stored_and_expanded_budgets(self):
        spec = self.unknown_spec("mmdb")
        for name, limit in (("FETCH_LIMIT", len(self.data["mmdb"]) - 1),
                            ("RESOURCE_LIMIT", len(self.installed["mmdb"]) - 1)):
            destination = self.base / name
            with mock.patch.object(resources, name, limit), self.assertRaisesRegex(ValueError, "limit"):
                resources.prepare_resource(spec, destination, self.sources["mmdb"])
            self.assertFalse((destination / "resource.json").exists())
        self.network.assert_not_called()

    def test_cli_single_prepare_and_resume_are_executable_without_an_application_update(self):
        spec = self.unknown_spec("asn")
        spec_file = self.base / "spec.json"
        spec_file.write_bytes(common_io.json_bytes(spec))
        destination = self.base / "cli-prepared-asn"
        arguments = ["prepare-resource", "--spec", str(spec_file), "--destination", str(destination)]
        with mock.patch.object(update, "execute", side_effect=AssertionError("not an application transaction")):
            for extra in (["--resource-source", str(self.sources["asn"])], []):
                output = io.StringIO()
                with redirect_stdout(output):
                    self.assertEqual(cli_main(["dependencies", *arguments] + extra), 0)
                result = json.loads(output.getvalue())
                self.assertEqual(result["status"], "prepared")
                self.assertEqual(result["resources"], [str(destination / "resource.json")])
        self.network.assert_not_called()

    def test_cli_bulk_prepare_accepts_unknown_dbip_sizes_and_generates_complete_candidates(self):
        specs = [self.unknown_spec(kind) if kind in ("mmdb", "asn") else spec
                 for kind, spec in self.specs.items()]
        spec_file = self.base / "specs.json"
        spec_file.write_bytes(common_io.json_bytes(specs))
        sources_file = self.base / "sources.json"
        sources_file.write_bytes(common_io.json_bytes({kind: str(path) for kind, path in self.sources.items()}))
        before = inputs.snapshot(self.root)
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(cli_main(["dependencies", "prepare-resources", "--spec", str(spec_file), "--destination", str(self.base / "bulk"),
                                          "--resource-sources", str(sources_file)]), 0)
        result = json.loads(output.getvalue())
        self.assertEqual(len(result["resources"]), 5)
        candidates = sources.resource_changes(self.root, resources.prepared_resources(self.base / "bulk"))
        record = json.loads(candidates[resources.RESOURCE_RECORD])
        for kind, item in record["resources"].items():
            for key in ("storedBytes", "storedSha256", "installedBytes", "installedSha256"):
                self.assertEqual(item[key], self.specs[kind][key])
        self.assertEqual(inputs.snapshot(self.root), before)
        self.network.assert_not_called()

    def test_explicit_delivery_version_does_not_write_or_increment_application_version(self):
        before = inputs.snapshot(self.root)
        changed = inputs.publish_resources(self.root, before, self.prepare(),
                                           application_delivery=True, delivery_version="1.1.0+2")
        self.assertNotIn("pubspec.yaml", changed)
        self.assertEqual((self.root / "pubspec.yaml").read_bytes(), before["pubspec.yaml"])
        self.assertEqual(json.loads((self.root / resources.RESOURCE_RECORD).read_bytes())["application"], "1.1.0+2")

    def test_frozen_ca_uses_recorded_checksum_without_querying_the_official_checksum(self):
        spec = dict(self.specs["ca"], checksumUrl=self.specs["ca"]["sourceUrl"] + ".sha256")
        directory = self.base / "frozen-ca"
        with mock.patch.object(resources, "download", side_effect=AssertionError("Frozen builds must not query checksums")) as fetch:
            resources.prepare_resource(spec, directory, self.sources["ca"])
            self.assertEqual(resources.read_prepared_resource(directory)[0]["storedSha256"], spec["storedSha256"])
            fetch.assert_not_called()
        corrupt = self.base / "changed-ca.pem"
        corrupt.write_bytes(self.data["ca"] + b"changed")
        with self.assertRaisesRegex(ValueError, "limit|size or SHA-256"):
            resources.prepare_resource(spec, self.base / "wrong-frozen-ca", corrupt)

    def test_preparation_uses_fixed_bytes_and_never_touches_project(self):
        before = inputs.snapshot(self.root)
        paths = self.prepare()
        self.assertEqual(paths, resources.prepared_resources(self.base / "prepared"))
        self.assertEqual(inputs.snapshot(self.root), before)
        for directory in paths:
            kind = directory.name
            self.assertEqual((directory / "payload").read_bytes(), self.data[kind])
            self.assertEqual(json.loads((directory / "resource.json").read_bytes())["storedSha256"], digest(self.data[kind]))
        self.network.assert_not_called()
        self.context.assert_called_with(ssl.PROTOCOL_TLS_CLIENT)

    def test_resume_verifies_original_input_and_never_redownloads(self):
        directory = self.prepare()[1]
        self.assertEqual(resources.prepare_resource(self.specs["geoip"], directory), directory)
        changed = dict(self.specs["geoip"], sourceCommit="b" * 40)
        with self.assertRaisesRegex(ValueError, "Resource source or frozen inputs differ on rerun"):
            resources.prepare_resource(changed, directory)
        (directory / "payload").write_bytes(b"changed bytes")
        with self.assertRaises(ValueError):
            resources.prepare_resource(self.specs["geoip"], directory)
        self.network.assert_not_called()

    def test_incomplete_preparation_cannot_silently_request_new_bytes(self):
        directory = self.base / "incomplete"
        directory.mkdir()
        (directory / "resource.json").write_bytes(common_io.json_bytes(resources.resource_spec(self.specs["geoip"])))
        (directory / "payload.part").write_bytes(b"interrupted")
        with self.assertRaises(OSError):
            resources.prepare_resource(self.specs["geoip"], directory)
        self.assertEqual((directory / "payload.part").read_bytes(), b"interrupted")
        self.network.assert_not_called()

    def test_untrusted_directory_and_project_destination_are_not_reused(self):
        directory = self.base / "untrusted"
        directory.mkdir()
        (directory / "json.py").write_text("raise RuntimeError('never execute')")
        with self.assertRaises(OSError):
            resources.prepare_resource(self.specs["geoip"], directory)
        with self.assertRaisesRegex(ValueError, "source directory"):
            resources.prepare_resource(self.specs["geoip"], resources.ROOT / "candidate")
        self.assertEqual(list(directory.iterdir()), [directory / "json.py"])

    def test_bad_digest_size_or_format_never_creates_a_completed_payload(self):
        for index, spec in enumerate((dict(self.specs["geoip"], storedSha256="0" * 64, installedSha256="0" * 64),
                                      dict(self.specs["geoip"], storedBytes=1, installedBytes=1))):
            directory = self.base / f"bad-{index}"
            with self.assertRaises(ValueError):
                resources.prepare_resource(spec, directory, self.sources["geoip"])
            self.assertFalse((directory / "payload").exists())
        for kind in ("ca", "mmdb", "asn"):
            with self.subTest(kind=kind):
                spec = resources.resource_spec(self.make_spec(kind, b"<html>error</html>", b"<html>error</html>"))
                with self.assertRaises((ValueError, OSError)):
                    resources.validate_resource(b"<html>error</html>", spec)

    def test_gzip_crc_truncation_and_decoded_budget_are_independent(self):
        original = self.data["mmdb"]
        for data in (original[:-2], original[:-8] + bytes(8)):
            spec = resources.resource_spec(self.make_spec("mmdb", data))
            with self.assertRaises((OSError, EOFError)):
                resources.validate_resource(data, spec)
        spec = resources.resource_spec(self.specs["mmdb"])
        with mock.patch.object(resources, "RESOURCE_LIMIT", len(self.installed["mmdb"]) - 1), \
                self.assertRaisesRegex(ValueError, "limit"):
            resources.validate_resource(original, spec)


    def test_geo_payload_is_not_parsed_by_the_dependency_tool(self):
        for kind in ("geoip", "geosite", "mmdb", "asn"):
            installed = b"opaque upstream database bytes"
            data = gzip.compress(installed, mtime=0) if kind in ("mmdb", "asn") else installed
            spec = resources.resource_spec(self.make_spec(kind, data, installed))
            with self.subTest(kind=kind):
                result = resources.validate_resource(data, spec)
                self.assertEqual(result["installedBytes"], len(installed))
                self.assertEqual(result["installedSha256"], digest(installed))





    def test_resource_spec_preserves_source_fields_without_version_or_url_rules(self):
        spec = {"kind": "geoip", "version": "release/next+data", "sourceCommit": "upstream-revision",
                "sourceUrl": "https://downloads.example.test/attachment", "licenseSha256": "measured",
                "sourceInputs": [{"sourceCommit": "input-revision", "description": "官方补充输入", "extra": True}]}
        self.assertEqual(resources.resource_spec(spec), dict(spec, encoding="identity"))
        identity = resources.resource_spec(dict(self.specs["geoip"], installedBytes=1, installedSha256="old"))
        measured = resources.validate_resource(self.data["geoip"], identity)
        self.assertEqual(measured["installedBytes"], measured["storedBytes"])
        self.assertEqual(measured["installedSha256"], measured["storedSha256"])


    def test_record_and_generated_manifests_preserve_exact_stored_and_installed_bytes(self):
        before = inputs.snapshot(self.root)
        changes = sources.resource_changes(self.root, self.prepare())
        self.assertEqual(set(changes), {resources.RESOURCE_RECORD})
        self.assertEqual(inputs.snapshot(self.root), before)
        record = json.loads(changes[resources.RESOURCE_RECORD])
        materials = resources.bundled_materials(self.root, record)
        certificate = json.loads(materials["certificates.json"])
        geo = json.loads(materials["assets/geodata/manifest.json"])
        self.assertNotIn("unknown", certificate)
        self.assertNotIn("unknown", geo)
        self.assertNotIn("future", geo["files"][0])
        self.assertEqual(certificate["asset"], "certificates/cacert.pem")
        self.assertEqual(certificate["roots"], 1)
        self.assertEqual(record["application"], "1.0.0+1")
        for item in geo["files"]:
            data = self.data[item["kind"]]
            installed = gzip.decompress(data) if item["encoding"] == "gzip" else data
            self.assertEqual(item["storedSha256"], digest(data))
            self.assertEqual(item["installedBytes"], len(installed))
            self.assertEqual(item["installedSha256"], digest(installed))
        self.assertEqual(geo["notice"]["sha256"], digest(materials["legal/geodata/NOTICE.txt"]))
        self.assertEqual(geo["installedTotalBytes"], sum(len(self.installed[kind]) for kind in ("geoip", "geosite", "mmdb", "asn")))

    def test_incomplete_changed_license_or_tampered_resource_cannot_partially_publish(self):
        before = inputs.snapshot(self.root)
        paths = self.prepare()
        for selected in (paths[:-1], paths + paths[:1]):
            with self.assertRaises(ValueError):
                inputs.publish_resources(self.root, before, selected, application_delivery=True)
            self.assertEqual(inputs.snapshot(self.root), before)
        (paths[-1] / "payload").write_bytes(b"tampered")
        with self.assertRaises(ValueError):
            inputs.publish_resources(self.root, before, paths, application_delivery=True)
        self.assertEqual(inputs.snapshot(self.root), before)
        self.sources["asn"].replace(paths[-1] / "payload")
        self.put("third_party/data/geodata/GeoSite-MIT.txt", b"changed original license")
        changes = sources.resource_changes(self.root, paths)
        with self.assertRaisesRegex(ValueError, "license content changed"):
            resources.bundled_materials(self.root, json.loads(changes[resources.RESOURCE_RECORD]))
        self.assertEqual((self.root / "pubspec.yaml").read_bytes(), before["pubspec.yaml"])

    def test_only_explicit_delivery_can_refresh_an_unpublished_candidate(self):
        paths = self.prepare()
        before = inputs.snapshot(self.root)
        with self.assertRaisesRegex(ValueError, "new application deliveries"):
            inputs.publish_resources(self.root, before, paths)
        changed = inputs.publish_resources(self.root, before, paths, application_delivery=True)
        self.assertEqual(changed, [resources.RESOURCE_RECORD])
        self.assertEqual(inputs.publish_resources(self.root, inputs.snapshot(self.root), paths, application_delivery=True), [])
        # Explicit release updates may replace resources in the same undistributed candidate; normal builds only consume saved records.
        spec = dict(self.specs["geoip"], sourceCommit="b" * 40)
        paths[1] = resources.prepare_resource(spec, self.base / "different-commit" / "geoip", self.sources["geoip"])
        changes = sources.resource_changes(self.root, paths)
        record = json.loads(changes[resources.RESOURCE_RECORD])
        self.assertEqual(record["resources"]["geoip"]["sourceCommit"], "b" * 40)
        self.assertEqual(record["application"], "1.0.0+1")





class FrozenBuildTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="frozen-build-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "project"
        self.root.mkdir()
        from frozen_resource_fixture import frozen_resources
        self.record, self.output = frozen_resources(self.root, resources)
        self.payloads = {kind: self.output / "assets" / name for kind, name in resources.RESOURCE_ASSETS.items()}
        self.bytes = {kind: path.read_bytes() for kind, path in self.payloads.items()}
        self.original = self.files()

    def files(self):
        return {path.relative_to(self.output).as_posix(): path.read_bytes()
                for path in self.output.rglob("*") if path.is_file()}

    def test_offline_rebuild_and_retry_only_consume_the_frozen_record(self):
        with mock.patch.object(sources, "official_resource_spec", side_effect=AssertionError("Must not query latest")), \
                mock.patch.object(resources, "download", side_effect=AssertionError("Offline preparation must not download")):
            resources.prepare_bundled_assets(self.root, payloads=self.payloads, offline=True)
            self.assertEqual(self.files(), self.original)
            shutil.rmtree(self.output)
            resources.prepare_bundled_assets(self.root, offline=True)
        self.assertEqual(self.files(), self.original)

    def test_missing_cache_downloads_only_fixed_urls_sizes_and_digests(self):
        calls = []
        by_url = {spec["sourceUrl"]: kind for kind, spec in self.record["resources"].items()}
        def fetch(url, *, limit, destination):
            calls.append(url)
            kind = by_url[url]
            self.assertEqual(limit, self.record["resources"][kind]["storedBytes"])
            Path(destination).write_bytes(self.bytes[kind])
            return {"bytes": len(self.bytes[kind]), "sha256": digest(self.bytes[kind])}
        with mock.patch.object(sources, "official_resource_specs", side_effect=AssertionError("Must not query latest")):
            resources.prepare_bundled_assets(self.root, fetch=fetch)
            resources.prepare_bundled_assets(self.root, fetch=lambda *a, **k: self.fail("Retries must not download a complete cache"))
        self.assertEqual(set(calls), set(by_url))
        self.assertEqual(len(calls), 5)
        self.assertEqual(self.files(), self.original)

    def test_tampered_cache_fails_without_network_or_replacing_complete_output(self):
        resources.prepare_bundled_assets(self.root, payloads=self.payloads, offline=True)
        fingerprint = self.record["resources"]["asn"]["storedSha256"]
        cache = self.root / "build/generated/resource-cache" / fingerprint / "payload"
        cache.write_bytes(b"tampered")
        with mock.patch.object(resources, "download", side_effect=AssertionError("Corrupt caches must not be downloaded again")) as fetch, \
                self.assertRaises(ValueError):
            resources.prepare_bundled_assets(self.root)
        fetch.assert_not_called()
        self.assertEqual(self.files(), self.original)

    def test_wrong_download_and_missing_offline_payload_preserve_complete_output(self):
        with self.assertRaisesRegex(ValueError, "Offline build is missing a frozen resource"):
            resources.prepare_bundled_assets(self.root, offline=True)
        self.assertEqual(self.files(), self.original)
        def wrong(url, *, limit, destination):
            Path(destination).write_bytes(b"wrong")
            return {"bytes": 5, "sha256": digest(b"wrong")}
        with self.assertRaises(ValueError):
            resources.prepare_bundled_assets(self.root, fetch=wrong)
        self.assertEqual(self.files(), self.original)

    def test_failed_output_replacement_restores_previous_files(self):
        replace = resources.os.replace
        failure = OSError("输出替换失败")
        def fail_output(source, target):
            if Path(source).name == "complete" and Path(target) == self.output:
                raise failure
            return replace(source, target)
        with mock.patch.object(resources.os, "replace", side_effect=fail_output), self.assertRaises(OSError) as caught:
            resources.prepare_bundled_assets(self.root, payloads=self.payloads, offline=True)
        self.assertIs(caught.exception, failure)
        self.assertEqual(self.files(), self.original)
        self.assertFalse(self.output.with_name(self.output.name + ".previous").exists())

    def test_payload_cache_is_shared_when_only_application_record_changes(self):
        resources.prepare_bundled_assets(self.root, payloads=self.payloads, offline=True)
        self.record["application"] = "1.0.1+2"
        (self.root / resources.RESOURCE_RECORD).write_bytes(common_io.json_bytes(self.record))
        with mock.patch.object(resources, "download", side_effect=AssertionError("Must not download again")):
            resources.prepare_bundled_assets(self.root, offline=True)
        self.assertEqual(len(list((self.root / "build/generated/resource-cache").glob("*/payload"))), 5)

    def test_cache_digest_cannot_escape_the_cache_directory(self):
        self.record["resources"]["asn"]["storedSha256"] = "../outside"
        (self.root / resources.RESOURCE_RECORD).write_bytes(common_io.json_bytes(self.record))
        with self.assertRaisesRegex(ValueError, "cache path"):
            resources.prepare_bundled_assets(self.root, payloads=self.payloads, offline=True)
        self.assertEqual(self.files(), self.original)


    def test_record_schema_version_dispatch_is_preserved(self):
        path = self.root / resources.RESOURCE_RECORD
        for value in (True, "1", None):
            changed = dict(self.record, version=value)
            path.write_bytes(common_io.json_bytes(changed))
            with self.subTest(version=value), self.assertRaisesRegex(ValueError, "Invalid release resource source record format"):
                resources.read_release_resources(self.root)


class TransactionTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="transaction-regression-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.first, self.second = inputs.GO_INPUTS
        for name in (self.first, self.second):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"old " + name.encode())
        self.before = inputs.snapshot(self.root)
        self.after = dict(self.before, **{self.first: b"new first", self.second: b"new second"})

    def test_outside_inputs_or_deletion_are_rejected_before_writes(self):
        for after in (dict(self.after, **{"../../other": b"bad"}), dict(self.after, **{self.second: None})):
            with self.assertRaises(ValueError):
                inputs.publish_changes(self.root, self.before, after)
        self.assertEqual(inputs.snapshot(self.root), self.before)

    def test_write_failure_restores_every_previously_replaced_input_and_original_error(self):
        replace = workspace.os.replace
        original = OSError("specific replacement failure")

        def fail_second(source, destination):
            if destination == self.root / self.second:
                raise original
            return replace(source, destination)

        with mock.patch.object(workspace.os, "replace", side_effect=fail_second), self.assertRaises(OSError) as result:
            inputs.publish_changes(self.root, self.before, self.after)
        self.assertIs(result.exception, original)
        self.assertEqual(inputs.snapshot(self.root), self.before)
        self.assertEqual(list(self.root.rglob(".clash-update-*")), [])

    def test_rollback_does_not_overwrite_a_concurrent_users_later_bytes(self):
        replace = workspace.os.replace

        def change_then_fail(source, destination):
            if destination == self.root / self.second:
                (self.root / self.first).write_bytes(b"user changed after first replacement")
                raise OSError("second failed")
            return replace(source, destination)

        with mock.patch.object(workspace.os, "replace", side_effect=change_then_fail), self.assertRaises(OSError):
            inputs.publish_changes(self.root, self.before, self.after)
        self.assertEqual((self.root / self.first).read_bytes(), b"user changed after first replacement")
        self.assertEqual((self.root / self.second).read_bytes(), self.before[self.second])

    def test_concurrent_change_between_replacements_is_checked_again(self):
        replace = workspace.os.replace

        def change_next(source, destination):
            result = replace(source, destination)
            if destination == self.root / self.first:
                (self.root / self.second).write_bytes(b"user next target")
            return result

        with mock.patch.object(workspace.os, "replace", side_effect=change_next), self.assertRaisesRegex(ValueError, "changed"):
            inputs.publish_changes(self.root, self.before, self.after)
        self.assertEqual((self.root / self.first).read_bytes(), self.before[self.first])
        self.assertEqual((self.root / self.second).read_bytes(), b"user next target")

    def test_unwritten_input_change_is_not_mixed_into_a_successful_transaction(self):
        path = self.root / "pubspec.yaml"
        path.write_bytes(b"user new input")
        with self.assertRaisesRegex(ValueError, "changed"):
            inputs.publish_changes(self.root, self.before, self.after)
        self.assertEqual((self.root / self.first).read_bytes(), self.before[self.first])
        self.assertEqual(path.read_bytes(), b"user new input")

    def test_sync_failure_rolls_back_and_cleanup_failure_remains_suppressed(self):
        failure = OSError("directory sync failed")
        cleanup = OSError("rollback sync failed")
        with mock.patch.object(workspace, "sync_directory", side_effect=[failure, cleanup]), self.assertRaises(OSError) as result:
            inputs.publish_changes(self.root, self.before, self.after)
        self.assertIs(result.exception, failure)
        self.assertTrue(any("rollback sync failed" in note for note in failure.__notes__))
        self.assertEqual(inputs.snapshot(self.root), self.before)

    def test_new_file_is_removed_on_failure_and_symlinks_never_followed(self):
        target = "pubspec.yaml"
        after = dict(self.after, **{target: b"new version"})
        replace = workspace.os.replace

        def fail_final(source, destination):
            if destination == self.root / target:
                raise OSError("final failed")
            return replace(source, destination)

        with mock.patch.object(workspace.os, "replace", side_effect=fail_final), self.assertRaises(OSError):
            inputs.publish_changes(self.root, self.before, after)
        self.assertFalse((self.root / target).exists())
        (self.root / target).symlink_to(self.root / self.first)
        with self.assertRaisesRegex(ValueError, "symbolic link"):
            inputs.snapshot(self.root)


class StreamAndLegalTest(unittest.TestCase):
    def test_streams_always_have_explicit_read_bounds(self):
        class Stream(io.BytesIO):
            def read(self, size=-1):
                if size <= 0 or size > common_io.CHUNK:
                    raise AssertionError("unbounded read")
                return super().read(size)
        self.assertEqual(common_io.read_bounded(Stream(b"abc"), 3), b"abc")
        with self.assertRaisesRegex(ValueError, "limit"):
            common_io.read_bounded(Stream(b"abcd"), 3)

    def test_fetch_enforces_length_budget_and_https_redirect_without_network(self):
        class Response(io.BytesIO):
            def __init__(self, data, length):
                super().__init__(data)
                self.headers = {"Content-Length": length}
            def geturl(self):
                return "https://example.test/fixed"
        for data, length, limit in ((b"abcd", "4", 3), (b"ab", "3", 3)):
            opener = mock.Mock()
            opener.open.return_value = Response(data, length)
            with mock.patch.object(common_io.urllib.request, "build_opener", return_value=opener), self.assertRaises(ValueError):
                common_io.fetch("https://example.test/fixed", limit=limit)
        with self.assertRaisesRegex(ValueError, "HTTPS"):
            common_io.HttpsRedirect().redirect_request(None, None, 302, "", {}, "http://example.test/downgrade")

    def test_real_ssl_parser_preserves_utf8_ca_names_and_original_bytes(self):
        certificate = (ROOT / "android/app/src/test/resources/certificates/synthetic-ec-acc-positive.pem").read_bytes()
        data = "# NetLock Főtanúsítvány\n".encode("utf-8") + certificate
        spec = {"kind": "ca", "encoding": "identity", "storedBytes": len(data), "installedBytes": len(data),
                "storedSha256": digest(data), "installedSha256": digest(data)}
        result = resources.validate_resource(data, spec)
        self.assertEqual(result, dict(spec, certificateRoots=1))
        self.assertIn("ő".encode("utf-8"), data)
        self.assertEqual(result["storedSha256"], digest(data))
        self.assertEqual(result["installedSha256"], digest(data))

    def test_utf8_ca_comments_do_not_hide_a_later_invalid_certificate(self):
        certificate = (ROOT / "android/app/src/test/resources/certificates/synthetic-ec-acc-positive.pem").read_bytes()
        invalid = b"-----BEGIN CERTIFICATE-----\nU1lOVEhFVElD\n-----END CERTIFICATE-----\n"
        data = "# NetLock Főtanúsítvány\n".encode("utf-8") + certificate + b"\n" + invalid
        spec = {"kind": "ca", "encoding": "identity", "storedBytes": len(data), "installedBytes": len(data),
                "storedSha256": digest(data), "installedSha256": digest(data)}
        with self.assertRaises(ssl.SSLError):
            resources.validate_resource(data, spec)

    def test_real_ssl_parser_rejects_a_pem_shaped_noncertificate(self):
        data = b"-----BEGIN CERTIFICATE-----\nU1lOVEhFVElD\n-----END CERTIFICATE-----\n"
        spec = {"kind": "ca", "encoding": "identity", "storedBytes": len(data), "installedBytes": len(data),
                "storedSha256": digest(data), "installedSha256": digest(data)}
        with self.assertRaises(ssl.SSLError):
            resources.validate_resource(data, spec)

    def test_archive_expansion_recursion_and_entry_budgets_are_shared(self):
        def archive(entries):
            output = io.BytesIO()
            with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as target:
                for name, data in entries:
                    target.writestr(name, data)
            return output.getvalue()
        data = archive([("LICENSE", b"x" * 1000)])
        with mock.patch.object(legal, "TEXT_LIMIT", 999), self.assertRaisesRegex(ValueError, "limit"):
            legal.archive_legal(data)
        nested = archive([("NOTICE", b"original notice\r\n")])
        outer = archive([("classes.jar", nested), ("../json.py", b"raise RuntimeError('never execute')")])
        self.assertEqual(legal.archive_legal(outer), {"classes.jar!/NOTICE": b"original notice\r\n"})
        with mock.patch.object(legal, "ARCHIVE_ENTRIES", 2), self.assertRaisesRegex(ValueError, "entry count"):
            legal.archive_legal(outer)
        for _ in range(6):
            nested = archive([("classes.jar", nested)])
        with self.assertRaisesRegex(ValueError, "nesting"):
            legal.archive_legal(nested)

    def test_psl_revision_comes_from_actual_effective_compiled_table(self):
        with tempfile.TemporaryDirectory(prefix="psl-regression-") as temporary:
            root = Path(temporary)
            table = root / "module/publicsuffix/table.go"
            table.parent.mkdir(parents=True)
            revision = "c" * 40
            table.write_text("// generated from git revision " + revision + "\npackage publicsuffix\n")
            updater = mock.Mock(root=root)
            updater.go_run.return_value = json.dumps({"Dir": str(table.parent.parent)})
            helper = legal.Legal(updater, root, mock.Mock(), mock.Mock(), packages.artifacts)
            graph = {"golang.org/x/net": {"Path": "golang.org/x/net", "Version": "v1.0.0",
                                          "Replace": {"Path": "example.test/x/net", "Version": "v1.0.1"}}}
            source = helper.public_suffix_source(graph)
            self.assertEqual(source["revision"], revision)
            self.assertEqual(source["module"], "example.test/x/net")
            self.assertEqual(source["moduleVersion"], "v1.0.1")
            updater.go_run.assert_called_once_with("mod", "download", "-json", "example.test/x/net@v1.0.1")
            self.assertFalse((root / "third_party").exists())




class OfficialResolutionTest(unittest.TestCase):
    """Test resource version, fixed commit, and download URL resolution with synthetic official API responses."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="official-resources-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.root = self.base / "project"
        self.root.mkdir()
        for name in ("CC-BY-SA-4.0.txt", "GeoSite-MIT.txt"):
            path = self.root / "third_party/data/geodata" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixed original license " + name.encode())
        self.licenses = {
            "geoip": (self.root / "third_party/data/geodata/CC-BY-SA-4.0.txt").read_bytes(),
            "geosite": (self.root / "third_party/data/geodata/GeoSite-MIT.txt").read_bytes(),
        }
        self.calls = []

    def dataset(self, kind):
        from_docs = {
            "ca": (ROOT / "android/app/src/test/resources/certificates/synthetic-ec-acc-positive.pem").read_bytes(),
            "geoip": pb(1, pb(1, b"TEST") + pb(2, pb(1, b"\x7f\0\0\0") + b"\x10\x08")),
            "geosite": pb(1, pb(1, b"TEST") + pb(2, pb(2, b"example.test"))),
            "mmdb": mmdb("mmdb"), "asn": mmdb("asn"),
        }
        data = from_docs[kind]
        return gzip.compress(data, mtime=0) if kind in ("mmdb", "asn") else data

    def reply(self, kind, version="202610050438", commit="a" * 40, license_changed=False,
              data_commit="c" * 40, annotated=False):
        data = self.dataset(kind)
        self.data = getattr(self, "data", {})
        self.data[kind] = data

        def fetch(url, **values):
            self.calls.append(url)
            if url == sources.CA_INDEX:
                return (b"<a href='/ca/cacert-2026-10-20.pem'>x</a><a href='/ca/cacert-2026-10-20.pem.sha256'>y</a>"
                        b"<a href='/ca/cacert-2026-09-24.pem'>x</a>")
            if url == "https://curl.se/ca/cacert-2026-10-20.pem.sha256":
                return (digest(data) + "  cacert-2026-10-20.pem\n").encode()
            if url.endswith("/releases/latest"):
                kind_name = "geoip" if "/v2fly/geoip/" in url else "domain-list-community"
                asset = "geoip.dat" if kind_name == "geoip" else "dlc.dat"
                return json.dumps({
                    "tag_name": version, "draft": False, "prerelease": False,
                    "published_at": "2026-10-05T04:52:52Z",
                    "assets": [{"name": asset, "size": len(data), "digest": "sha256:" + digest(data),
                                "browser_download_url": f"https://github.com/v2fly/{kind_name}/releases/"
                                                        f"download/{version}/{asset}"}]}).encode()
            if "/git/ref/tags/" in url:
                if annotated:
                    return json.dumps({"object": {"sha": "b" * 40, "type": "tag",
                                                  "url": "https://api.github.com/tags/object"}}).encode()
                return json.dumps({"object": {"sha": commit, "type": "commit",
                                              "url": "https://api.github.com/commits"}}).encode()
            if url == "https://api.github.com/tags/object":
                return json.dumps({"object": {"sha": commit, "type": "commit",
                                              "url": "https://api.github.com/commits"}}).encode()
            if "/commits?" in url and "sha=release" in url:
                rows = [{"sha": data_commit, "commit": {"message": version + "\n"}}]
                if "/geoip/" not in url:
                    rows = []
                return json.dumps(rows).encode()
            if "/git/trees/" in url and "recursive=1" in url:
                return json.dumps({"truncated": False, "tree": [
                    {"path": "text/one.txt", "type": "blob", "size": 10},
                    {"path": "dat/ad.dat", "type": "blob", "size": 20}]}).encode()
            if url.startswith("https://raw.githubusercontent.com/"):
                changed = b"changed license" if license_changed else self.licenses[
                    "geoip" if "/v2fly/geoip/" in url else "geosite"]
                return changed
            if url in sources.DBIP_PAGES.values():
                name = "country" if url.endswith("country-lite") else "asn"
                return (f"<a href='https://download.db-ip.com/free/dbip-{name}-lite-2026-10.mmdb.gz'>x</a>"
                        f"<a href='https://download.db-ip.com/free/dbip-{name}-lite-2026-09.mmdb.gz'>x</a>"
                        f"<span>dbip-{name}-lite-latest.mmdb.gz</span>").encode()
            raise AssertionError("unexpected URL " + url)
        return fetch

    def test_each_kind_resolves_only_official_fixed_versions_and_digests(self):
        cases = {
            "ca": {"version": "2026-10-20", "sourceUrl": "https://curl.se/ca/cacert-2026-10-20.pem"},
            "geoip": {"version": "202610050438", "sourceCommit": "a" * 40,
                      "sourceUrl": "https://github.com/v2fly/geoip/releases/download/202610050438/geoip.dat"},
            "geosite": {"version": "202610050438", "sourceCommit": "a" * 40,
                        "sourceUrl": "https://github.com/v2fly/domain-list-community/releases/download/"
                                     "202610050438/dlc.dat"},
            "mmdb": {"version": "2026-10",
                     "sourceUrl": "https://download.db-ip.com/free/dbip-country-lite-2026-10.mmdb.gz"},
            "asn": {"version": "2026-10", "sourceUrl": "https://download.db-ip.com/free/dbip-asn-lite-2026-10.mmdb.gz"},
        }
        for kind, expected in cases.items():
            with self.subTest(kind=kind):
                spec = sources.official_resource_spec(kind, self.root, fetch=self.reply(kind))
                self.assertEqual({key: spec[key] for key in expected}, expected)
                if kind == "ca":
                    self.assertNotIn("storedBytes", spec)
                self.assertNotIn("latest", spec["sourceUrl"])
        self.assertTrue(all(url in sources.DBIP_PAGES.values() or not url.endswith(".mmdb.gz")
                            for url in self.calls))
        self.assertEqual(sources.official_resource_spec("mmdb", self.root, fetch=self.reply("mmdb"))["sourcePage"],
                         "https://db-ip.com/db/download/ip-to-country-lite")
        spec = sources.official_resource_spec("geoip", self.root, fetch=self.reply("geoip"))
        self.assertEqual(spec["storedBytes"], len(self.data["geoip"]))
        self.assertEqual(spec["storedSha256"], digest(self.data["geoip"]))
        self.assertNotIn("installedBytes", spec)
        self.assertEqual(spec["licenseSha256"], digest(self.licenses["geoip"]))
        self.assertEqual(spec["sourceInputs"],
                         [{"sourceCommit": "c" * 40,
                           "description": "Supplemental text/*.txt inputs from the release 202610050438 build commit"}])
        self.assertNotIn("sourceInputs", sources.official_resource_spec("geosite", self.root,
                                                                        fetch=self.reply("geosite")))

    def test_geoip_build_data_commit_comes_from_official_release_metadata(self):
        spec = sources.official_resource_spec("geoip", self.root, fetch=self.reply("geoip"))
        self.assertEqual(spec["sourceCommit"], "a" * 40)
        self.assertEqual(spec["sourceInputs"][0]["sourceCommit"], "c" * 40)
        self.assertTrue(any("sha=release" in url and "until=2026-10-05" in url for url in self.calls))
        self.assertTrue(any("/git/trees/" + "c" * 40 in url for url in self.calls))
        annotated = sources.official_resource_spec("geoip", self.root, fetch=self.reply("geoip", annotated=True))
        self.assertEqual(annotated["sourceCommit"], "a" * 40)

    def test_missing_or_mismatched_geoip_data_commit_fails_without_fallback(self):
        without = self.reply("geoip")
        def no_rows(url, **values):
            if "/commits?" in url:
                self.calls.append(url)
                return b"[]"
            return without(url, **values)
        with self.assertRaisesRegex(ValueError, "build data commit"):
            sources.official_resource_spec("geoip", self.root, fetch=no_rows)

    def test_geoip_data_commit_requires_release_time_and_text_inputs(self):
        without_time = self.reply("geoip")
        def no_time(url, **values):
            if url.endswith("/releases/latest"):
                body = json.loads(without_time(url, **values))
                del body["published_at"]
                return json.dumps(body).encode()
            return without_time(url, **values)
        with self.assertRaises(KeyError):
            sources.official_resource_spec("geoip", self.root, fetch=no_time)

        no_text = self.reply("geoip")
        def no_texts(url, **values):
            if "/git/trees/" in url:
                return json.dumps({"truncated": False, "tree": [{"path": "dat/ad.dat", "type": "blob"}]}).encode()
            return no_text(url, **values)
        with self.assertRaisesRegex(ValueError, "text/\\*.txt"):
            sources.official_resource_spec("geoip", self.root, fetch=no_texts)

    def test_ca_spec_has_no_fabricated_bytes_and_uses_official_checksum(self):
        spec = sources.official_resource_spec("ca", self.root, fetch=self.reply("ca"))
        self.assertEqual(spec["checksumUrl"], "https://curl.se/ca/cacert-2026-10-20.pem.sha256")
        for key in ("storedBytes", "installedBytes", "installedSha256"):
            self.assertNotIn(key, spec)
        self.assertEqual(spec["storedSha256"], digest(self.dataset("ca")))
        self.assertIn(spec["checksumUrl"], self.calls)
        with self.assertRaisesRegex(ValueError, "Invalid official CA checksum file format"):
            sources.official_resource_spec("ca", self.root, fetch=lambda url, **values:
                                          b"invalid checksum" if url.endswith(".sha256") else self.reply("ca")(url, **values))

    def test_missing_official_asset_or_page_link_is_reported(self):
        def missing_asset(url, **values):
            return json.dumps({"tag_name": "upstream-tag", "assets": []}).encode()
        with self.assertRaisesRegex(ValueError, "release asset is missing or duplicated"):
            sources.official_resource_spec("geoip", self.root, fetch=missing_asset)
        for kind in ("ca", "mmdb"):
            with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, "Official download page lacks a resource link"):
                sources.official_resource_spec(kind, self.root, fetch=lambda url, **values: b"<html>none</html>")

    def test_upstream_tag_and_asset_url_are_used_without_reconstruction(self):
        original = self.reply("geosite", version="data/next+build")
        def fetch(url, **values):
            data = original(url, **values)
            if url.endswith("/releases/latest"):
                document = json.loads(data)
                document["assets"][0]["browser_download_url"] = "https://downloads.example.test/dlc"
                return json.dumps(document).encode()
            return data
        spec = sources.official_resource_spec("geosite", self.root, fetch=fetch)
        self.assertEqual(spec["version"], "data/next+build")
        self.assertEqual(spec["sourceUrl"], "https://downloads.example.test/dlc")
        self.assertTrue(any("/tags/data%2Fnext%2Bbuild" in url for url in self.calls))

    def test_asset_without_official_digest_is_measured_when_downloaded(self):
        original = self.reply("geosite")
        def fetch(url, **values):
            data = original(url, **values)
            if url.endswith("/releases/latest"):
                document = json.loads(data)
                document["assets"][0]["digest"] = None
                return json.dumps(document).encode()
            return data
        spec = sources.official_resource_spec("geosite", self.root, fetch=fetch)
        self.assertNotIn("storedSha256", spec)
        source = self.base / "original"
        source.write_bytes(self.dataset("geosite"))
        directory = resources.prepare_resource(spec, self.base / "geosite", source=source)
        self.assertEqual(resources.read_prepared_resource(directory)[0]["storedSha256"], digest(source.read_bytes()))

    def test_page_link_order_and_revision_text_are_not_sorted_or_validated(self):
        page = (b"<a href='https://download.example.test/dbip-country-lite-preview.mmdb.gz?download=1'>current</a>"
                b"<a href='https://download.example.test/dbip-country-lite-9999-99.mmdb.gz'>archive</a>")
        spec = sources.official_resource_spec("mmdb", self.root, fetch=lambda url, **values: page)
        self.assertEqual(spec["version"], "preview")
        self.assertEqual(spec["sourceUrl"], "https://download.example.test/dbip-country-lite-preview.mmdb.gz?download=1")
        ca_page = (b"<a href='/ca/cacert-snapshot.pem'>current</a>"
                   b"<a href='/ca/cacert-snapshot.pem.sha256?download=1'>checksum</a>"
                   b"<a href='/ca/cacert-9999-99-99.pem'>archive</a>")
        checksum_url = "https://curl.se/ca/cacert-snapshot.pem.sha256?download=1"
        def fetch(url, **values):
            return ("0" * 64).encode() if url == checksum_url else ca_page
        spec = sources.official_resource_spec("ca", self.root, fetch=fetch)
        self.assertEqual(spec["version"], "snapshot")
        self.assertEqual(spec["checksumUrl"], checksum_url)


    def test_changed_fixed_revision_license_stops_for_legal_review(self):
        with self.assertRaisesRegex(ValueError, "license content changed"):
            sources.official_resource_spec("geoip", self.root, fetch=self.reply("geoip", license_changed=True))

    def test_all_five_specs_are_resolved_from_official_sources_without_overrides(self):
        def fetch(url, **values):
            kind = ("asn" if url == sources.DBIP_PAGES["asn"] else
                    "mmdb" if url == sources.DBIP_PAGES["mmdb"] else
                    "geoip" if "/v2fly/geoip/" in url else
                    "geosite" if "/domain-list-community/" in url else "ca")
            return self.reply(kind)(url, **values)
        specs = sources.official_resource_specs(self.root, fetch=fetch)
        self.assertEqual(specs[0]["version"], "2026-10-20")
        self.assertEqual([spec["kind"] for spec in specs], list(resources.RESOURCE_ASSETS))
        self.assertEqual(specs[0]["storedSha256"], digest(self.dataset("ca")))
        self.assertTrue(all(page in self.calls for page in sources.DBIP_PAGES.values()))
        with self.assertRaises(TypeError):
            sources.official_resource_specs(self.root, pinned={"ca": specs[0]}, fetch=fetch)


class OfficialPreparationTest(unittest.TestCase):
    """Test preparation of five resources, frozen source manifest generation, and reuse of existing artifacts."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="official-preparation-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.root = self.base / "project"
        self.root.mkdir()
        self.data = {
            "ca": (ROOT / "android/app/src/test/resources/certificates/synthetic-ec-acc-positive.pem").read_bytes(),
            "geoip": pb(1, pb(1, b"TEST") + pb(2, pb(1, b"\x7f\0\0\0") + b"\x10\x08")),
            "geosite": pb(1, pb(1, b"TEST") + pb(2, pb(2, b"example.test"))),
            "mmdb": gzip.compress(mmdb("mmdb"), mtime=0), "asn": gzip.compress(mmdb("asn"), mtime=0),
        }
        self.pinned = {
            "ca": {"kind": "ca", "version": "2026-10-20",
                   "sourceUrl": "https://curl.se/ca/cacert-2026-10-20.pem"},
            "geoip": {"kind": "geoip", "version": "202610050438", "sourceCommit": "a" * 40,
                      "licenseSha256": "0" * 64, "storedBytes": len(self.data["geoip"]),
                      "storedSha256": digest(self.data["geoip"]),
                      "sourceInputs": [{"sourceCommit": "c" * 40, "description": "release 数据输入"}],
                      "sourceUrl": "https://github.com/v2fly/geoip/releases/download/202610050438/geoip.dat"},
            "geosite": {"kind": "geosite", "version": "20261028111806", "sourceCommit": "b" * 40,
                        "licenseSha256": "0" * 64, "storedBytes": len(self.data["geosite"]),
                        "storedSha256": digest(self.data["geosite"]),
                        "sourceUrl": "https://github.com/v2fly/domain-list-community/releases/download/"
                                     "20261028111806/dlc.dat"},
            "mmdb": {"kind": "mmdb", "version": "2026-10",
                     "sourceUrl": "https://download.db-ip.com/free/dbip-country-lite-2026-10.mmdb.gz",
                     "sourcePage": "https://db-ip.com/db/download/ip-to-country-lite"},
            "asn": {"kind": "asn", "version": "2026-10",
                    "sourceUrl": "https://download.db-ip.com/free/dbip-asn-lite-2026-10.mmdb.gz",
                    "sourcePage": "https://db-ip.com/db/download/ip-to-asn-lite"},
        }
        for name in resources.RESOURCE_INPUTS:
            if name == resources.RESOURCE_RECORD:
                continue
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(("合成许可原文 " + path.name + "\n").encode())
        for kind in ("geoip", "geosite"):
            self.pinned[kind]["licenseSha256"] = digest(
                (self.root / "third_party/data/geodata" / sources.GEO_LICENSE_FILES[kind]).read_bytes())
        (self.root / "pubspec.yaml").write_text("name: sample\nversion: 1.0.0+1\n", encoding="utf-8")
        by_url = {spec["sourceUrl"]: self.data[kind] for kind, spec in self.pinned.items()}
        self.by_url = by_url
        self.by_url[self.pinned["ca"]["sourceUrl"] + ".sha256"] = (
            digest(self.data["ca"]) + "  cacert-2026-10-20.pem\n").encode()
        self.pinned["ca"]["storedSha256"] = digest(self.data["ca"])
        self.requests = []
        resolver = mock.patch.object(sources, "official_resource_spec",
                                     side_effect=lambda kind, root, *, fetch=None: resources.resource_spec(self.pinned[kind]))
        self.official = resolver.start()
        self.addCleanup(resolver.stop)

    def fetch(self, url, *, limit=resources.FETCH_LIMIT, destination=None):
        self.requests.append(url)
        data = self.by_url[url]
        if destination is None:
            return data
        self.assertEqual(list(Path(destination).parent.iterdir()), [])
        with Path(destination).open("xb") as output:
            output.write(data)
        return {"bytes": len(data), "sha256": digest(data)}

    def prepare(self):
        context = mock.patch.object(resources.ssl, "SSLContext", wraps=ssl.SSLContext)
        context.start()
        self.addCleanup(context.stop)
        network = mock.patch.object(sources, "fetch", self.fetch)
        network.start()
        self.addCleanup(network.stop)
        return sources.prepare_official_resources(self.base / "prepared", root=self.root)

    def freeze_record(self, metadata, prepared=None):
        paths = self.prepare() if prepared is None else [prepared / kind for kind in resources.RESOURCE_ASSETS]
        changes = sources.resource_changes(self.root, paths, source_metadata=metadata)
        for name, data in changes.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        return resources.read_release_resources(self.root)

    def test_preparation_is_isolated_and_explicit_refresh_redownloads_dbip(self):
        paths = self.prepare()
        self.assertEqual(paths, [self.base / "prepared" / kind for kind in resources.RESOURCE_ASSETS])
        self.assertEqual(sorted(self.requests), sorted([
            self.pinned[kind]["sourceUrl"] for kind in resources.RESOURCE_ASSETS]))
        for kind, path in zip(resources.RESOURCE_ASSETS, paths):
            self.assertEqual((path / "payload").read_bytes(), self.data[kind])
            spec, _ = resources.read_prepared_resource(path)
            for key in ("storedBytes", "storedSha256", "installedBytes", "installedSha256"):
                self.assertIn(key, spec)
        self.requests.clear()
        self.assertEqual(sources.prepare_official_resources(self.base / "prepared", root=self.root), paths)
        self.assertEqual(self.requests, [self.pinned[kind]["sourceUrl"] for kind in ("mmdb", "asn")])
        self.assertEqual(self.official.call_count, 10)
        self.assertEqual(resources.prepared_specs(paths)["mmdb"]["storedBytes"], len(self.data["mmdb"]))

    def test_same_release_tag_can_refresh_bytes_in_the_same_unpublished_application_version(self):
        paths = self.prepare()
        first = json.loads(sources.resource_changes(self.root, paths)[resources.RESOURCE_RECORD])
        changed = self.data["geoip"].replace(b"TEST", b"NEXT")
        self.data["geoip"] = changed
        self.by_url[self.pinned["geoip"]["sourceUrl"]] = changed
        self.pinned["geoip"]["storedSha256"] = digest(changed)
        self.requests.clear()
        paths = sources.prepare_official_resources(self.base / "prepared", root=self.root)
        second = json.loads(sources.resource_changes(self.root, paths)[resources.RESOURCE_RECORD])
        self.assertEqual(first["application"], "1.0.0+1")
        self.assertEqual(second["application"], first["application"])
        self.assertEqual(second["resources"]["geoip"]["version"], first["resources"]["geoip"]["version"])
        self.assertNotEqual(second["resources"]["geoip"]["storedSha256"], first["resources"]["geoip"]["storedSha256"])
        self.assertEqual(second["resources"]["geoip"]["storedSha256"], digest(changed))
        self.assertEqual(self.requests, [self.pinned[kind]["sourceUrl"] for kind in ("geoip", "mmdb", "asn")])

    def test_changed_official_digest_or_network_failure_never_returns_old_cache(self):
        self.prepare()
        self.pinned["geoip"]["storedSha256"] = "0" * 64
        self.requests.clear()
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            sources.prepare_official_resources(self.base / "prepared", root=self.root)
        self.assertEqual(self.requests, [self.pinned["geoip"]["sourceUrl"]])
        self.pinned["geoip"]["storedSha256"] = digest(self.data["geoip"])
        with mock.patch.object(sources, "fetch", side_effect=OSError("official network failed")), \
                self.assertRaisesRegex(OSError, "official network failed"):
            sources.prepare_official_resources(self.base / "prepared", root=self.root)
        self.assertEqual(resources.read_prepared_resource(self.base / "prepared/geoip")[1], self.data["geoip"])

    def test_unknown_dbip_values_come_from_the_real_first_read(self):
        self.prepare()
        for kind in ("mmdb", "asn"):
            directory = self.base / "prepared" / kind
            fixed = json.loads((directory / "resource.json").read_bytes())
            self.assertEqual(fixed["storedBytes"], len(self.data[kind]))
            self.assertEqual(fixed["installedSha256"], digest(gzip.decompress(self.data[kind])))
            self.assertEqual({path.name for path in directory.iterdir()}, {"resource.json", "payload"})


    def test_legacy_cache_is_rebuilt_without_reading_input_or_receipt(self):
        self.prepare()
        directory = self.base / "prepared" / "geoip"
        (directory / "resource.json").unlink()
        (directory / "input.json").write_bytes(b"legacy input")
        (directory / "receipt.json").write_bytes(b"legacy receipt")
        self.requests.clear()
        sources.prepare_official_resources(self.base / "prepared", root=self.root)
        self.assertEqual(self.requests, [self.pinned[kind]["sourceUrl"] for kind in ("geoip", "mmdb", "asn")])
        self.assertEqual({path.name for path in directory.iterdir()}, {"resource.json", "payload"})

    def test_later_resource_failure_preserves_the_whole_previous_set(self):
        self.prepare()
        directory = self.base / "prepared"
        before = {path.relative_to(directory): path.read_bytes() for path in directory.rglob("*") if path.is_file()}
        changed = self.data["geoip"] + b"new data"
        self.by_url[self.pinned["geoip"]["sourceUrl"]] = changed
        self.pinned["geoip"].update(storedSha256=digest(changed), storedBytes=len(changed))
        self.by_url[self.pinned["asn"]["sourceUrl"]] = b"broken gzip"
        with self.assertRaises(OSError):
            sources.prepare_official_resources(directory, root=self.root)
        after = {path.relative_to(directory): path.read_bytes() for path in directory.rglob("*") if path.is_file()}
        self.assertEqual(after, before)

    def test_failed_cache_directory_replace_restores_previous_resources(self):
        self.prepare()
        directory = self.base / "prepared"
        before = {path.relative_to(directory): path.read_bytes() for path in directory.rglob("*") if path.is_file()}
        replace = resources.os.replace
        failure = OSError("缓存替换失败")
        def fail_cache(source, target):
            if Path(source).name == "resources" and Path(target) == directory:
                raise failure
            return replace(source, target)
        with mock.patch.object(resources.os, "replace", side_effect=fail_cache), self.assertRaises(OSError) as caught:
            sources.prepare_official_resources(directory, root=self.root)
        self.assertIs(caught.exception, failure)
        after = {path.relative_to(directory): path.read_bytes() for path in directory.rglob("*") if path.is_file()}
        self.assertEqual(after, before)


    def test_unknown_or_symlinked_root_is_rejected(self):
        (self.base / "prepared").mkdir()
        (self.base / "prepared" / "stray.txt").write_bytes(b"x")
        with self.assertRaisesRegex(ValueError, "unknown entries"):
            sources.prepare_official_resources(self.base / "prepared", root=self.root)
        with self.assertRaisesRegex(ValueError, "outside the repository"):
            sources.prepare_official_resources(resources.ROOT / "candidate", root=self.root)

    def test_sources_manifest_records_actual_bytes_and_resume_is_offline(self):
        expected = {
            ("geoip", "a" * 40): b"converter archive", ("geoip", "c" * 40): b"data archive",
            ("geosite", "b" * 40): b"rules archive",
        }
        self.by_url.update({resources._source_expected(kind, commit)[0]: data
                            for (kind, commit), data in expected.items()})

        def download(url, *, limit=resources.FETCH_LIMIT, destination=None):
            return OfficialPreparationTest.fetch(self, url, limit=limit, destination=destination)
        specs = resources.prepared_specs(self.prepare())
        inputs = [{"sourceCommit": "c" * 40, "description": "release 数据提交中的 text/*.txt"}]
        self.requests.clear()
        manifest = sources.prepare_resource_sources(specs, self.base / "sources", inputs=inputs, fetch=download)
        metadata = resources.read_resource_sources(self.base / "sources")
        self.assertEqual(metadata["format"], "clash-pseudo-resource-sources")
        self.assertEqual([row["kind"] for row in metadata["sources"]], ["geoip", "geosite"])
        geoip = metadata["sources"][0]
        self.assertEqual(geoip["sourceCommit"], "a" * 40)
        self.assertEqual(geoip["inputs"][0]["sourceCommit"], "c" * 40)
        self.assertEqual(geoip["inputs"][0]["bytes"], len(b"data archive"))
        self.assertEqual(geoip["inputs"][0]["sha256"], digest(b"data archive"))
        self.assertTrue(geoip["processing"].strip())
        for row in metadata["sources"]:
            self.assertEqual((self.base / "sources" / row["file"]).read_bytes(), expected[(row["kind"], row["sourceCommit"])])
        self.requests.clear()
        self.assertEqual(sources.prepare_resource_sources(specs, self.base / "sources", inputs=inputs,
                                                         fetch=download), manifest)
        self.assertEqual(self.requests, [])
        for row in metadata["sources"]:
            for source in [row, *row.get("inputs", [])]:
                registered_name = row["kind"] + "-registered-" + source["sourceCommit"] + ".tar.gz"
                (manifest.parent / source["file"]).rename(manifest.parent / registered_name)
                source["file"] = registered_name
        metadata["sources"][1].pop("inputs")
        manifest.write_bytes(common_io.json_bytes(metadata))
        registered_bytes = manifest.read_bytes()
        with mock.patch.object(sources, "fetch", side_effect=AssertionError("offline resume fetched")) as offline:
            self.assertEqual(sources.prepare_resource_sources(specs, manifest.parent, inputs=inputs), manifest)
            offline.assert_not_called()
        self.assertEqual(manifest.read_bytes(), registered_bytes)
        self.assertEqual(resources.read_resource_sources(manifest.parent), metadata)
        (self.base / "sources" / geoip["file"]).write_bytes(b"x" * geoip["bytes"])
        with self.assertRaisesRegex(ValueError, "digest differs"):
            sources.prepare_resource_sources(specs, self.base / "sources", inputs=inputs, fetch=download)
        self.assertEqual(self.requests, [])

    def test_sources_require_explicit_geoip_inputs_and_reject_empty_placeholders(self):
        specs = resources.prepared_specs(self.prepare())
        without = {kind: dict(spec) for kind, spec in specs.items()}
        del without["geoip"]["sourceInputs"]
        self.requests.clear()
        for selected, inputs in ((specs, []), (specs, [{"sourceCommit": "d" * 40}]),
                                 (without, None), (without, [])):
            with self.subTest(inputs=inputs), self.assertRaises(ValueError):
                sources.prepare_resource_sources(selected, self.base / "sources", inputs=inputs, fetch=self.fetch)
        self.assertFalse((self.base / "sources" / "resource-sources.json").exists())
        self.assertEqual(self.requests, [])

    def test_sources_use_spec_inputs_without_manual_commit(self):
        expected = {
            resources._source_expected("geoip", "a" * 40)[0]: b"converter archive",
            resources._source_expected("geoip", "c" * 40)[0]: b"data archive",
            resources._source_expected("geosite", "b" * 40)[0]: b"rules archive",
        }
        self.by_url.update(expected)
        specs = resources.prepared_specs(self.prepare())
        self.requests.clear()
        sources.prepare_resource_sources(specs, self.base / "sources", fetch=self.fetch)
        self.assertEqual(sorted(self.requests), sorted(expected))
        geoip = resources.read_resource_sources(self.base / "sources")["sources"][0]
        self.assertEqual(geoip["inputs"], [{
            "sourceCommit": "c" * 40, "sourceUrl": resources._source_expected("geoip", "c" * 40)[0],
            "file": "geoip-" + "c" * 40 + ".tar.gz", "description": "release 数据输入",
            "bytes": len(b"data archive"), "sha256": digest(b"data archive")}])

    def test_source_archive_paths_cannot_escape_the_material_directory(self):
        self.by_url.update({resources._source_expected(kind, commit)[0]: data
                            for kind, commit, data in (("geoip", "a" * 40, b"converter"),
                                                       ("geoip", "c" * 40, b"data"),
                                                       ("geosite", "b" * 40, b"rules"))})
        manifest = sources.prepare_resource_sources(resources.prepared_specs(self.prepare()),
                                                    self.base / "sources", fetch=self.fetch)
        original = json.loads(manifest.read_bytes())
        for name in ("../outside", "/absolute", "nested/archive", "nested\\archive", "resource-sources.json"):
            changed = json.loads(common_io.json_bytes(original))
            changed["sources"][0]["file"] = name
            manifest.write_bytes(common_io.json_bytes(changed))
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "Invalid resource source file path"):
                resources.read_resource_sources(manifest.parent)

    def test_source_archive_symlink_is_not_read(self):
        self.by_url.update({resources._source_expected(kind, commit)[0]: data
                            for kind, commit, data in (("geoip", "a" * 40, b"converter"),
                                                       ("geoip", "c" * 40, b"data"),
                                                       ("geosite", "b" * 40, b"rules"))})
        manifest = sources.prepare_resource_sources(resources.prepared_specs(self.prepare()),
                                                    self.base / "sources", fetch=self.fetch)
        row = json.loads(manifest.read_bytes())["sources"][0]
        archive = manifest.parent / row["file"]
        outside = self.base / "outside"
        archive.replace(outside)
        archive.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "regular files"):
            resources.read_resource_sources(manifest.parent)

    def test_sources_directory_with_unknown_files_is_not_reused(self):
        specs = resources.prepared_specs(self.prepare())
        directory = self.base / "sources"
        directory.mkdir()
        (directory / "stray.tar.gz").write_bytes(b"x")
        with self.assertRaisesRegex(ValueError, "new empty directory"):
            sources.prepare_resource_sources(specs, directory, inputs=[{"sourceCommit": "c" * 40,
                                                                       "description": "data"}], fetch=self.fetch)

    def test_delivery_entry_prepares_resources_and_sources_together(self):
        archives = {
            resources._source_expected("geoip", self.pinned["geoip"]["sourceCommit"])[0]: b"converter",
            resources._source_expected("geoip", "c" * 40)[0]: b"data",
            resources._source_expected("geosite", self.pinned["geosite"]["sourceCommit"])[0]: b"rules",
        }
        by_url = {**self.by_url, **archives}
        self.by_url = by_url
        network = mock.patch.object(sources, "fetch", self.fetch)
        network.start()
        self.addCleanup(network.stop)
        context = mock.patch.object(resources.ssl, "SSLContext", wraps=ssl.SSLContext)
        context.start()
        self.addCleanup(context.stop)
        with mock.patch.object(sources, "official_resource_spec",
                               side_effect=lambda kind, root, *, fetch=None: self.pinned[kind]):
            result = sources.delivery_resources(self.root, self.base / "delivery", prepare=True,
                                               fetch=self.fetch)
        self.assertEqual(result["prepared"], self.base / "delivery/resources")
        self.assertEqual(result["sources"], self.base / "delivery/resource-sources/resource-sources.json")
        metadata = resources.read_resource_sources(result["sources"].parent)
        geoip = metadata["sources"][0]
        self.assertEqual(geoip["inputs"][0]["sourceCommit"], "c" * 40)
        self.assertEqual(geoip["inputs"][0]["sha256"], digest(b"data"))
        for kind in resources.RESOURCE_ASSETS:
            spec, data = resources.read_prepared_resource(result["prepared"] / kind)
            self.assertEqual(data, self.data[kind])
            self.assertEqual(spec["kind"], kind)

    def test_delivery_entry_without_refresh_only_restores_fixed_sources(self):
        destination = self.base / "delivery"
        with self.assertRaisesRegex(ValueError, "Current delivery lacks a frozen resource source manifest"):
            sources.delivery_resources(self.root, destination, prepare=False, fetch=self.fetch)
        source_dir = destination / "resource-sources"
        source_dir.mkdir(parents=True)
        files = {
            resources._source_expected("geoip", "a" * 40)[0]: ("geoip-" + "a" * 40 + ".tar.gz", b"converter"),
            resources._source_expected("geoip", "c" * 40)[0]: ("geoip-" + "c" * 40 + ".tar.gz", b"data"),
            resources._source_expected("geosite", "b" * 40)[0]: ("domain-list-community-" + "b" * 40 + ".tar.gz", b"rules"),
        }
        rows = []
        for url, (name, data) in files.items():
            (source_dir / name).write_bytes(data)
        rows = [{"kind": "geoip", "sourceCommit": "a" * 40, "sourceUrl": resources._source_expected("geoip", "a" * 40)[0],
                 "file": "geoip-" + "a" * 40 + ".tar.gz", "bytes": 9, "sha256": digest(b"converter"),
                 "inputs": [{"sourceCommit": "c" * 40, "sourceUrl": resources._source_expected("geoip", "c" * 40)[0],
                             "file": "geoip-" + "c" * 40 + ".tar.gz", "bytes": 4, "sha256": digest(b"data"),
                             "description": "data"}], "processing": "processing"},
                {"kind": "geosite", "sourceCommit": "b" * 40,
                 "sourceUrl": resources._source_expected("geosite", "b" * 40)[0],
                 "file": "domain-list-community-" + "b" * 40 + ".tar.gz", "bytes": 5,
                 "sha256": digest(b"rules"), "inputs": []}]
        metadata = {"format": "clash-pseudo-resource-sources", "version": 1, "sources": rows}
        (source_dir / "resource-sources.json").write_bytes(common_io.json_bytes(metadata))
        self.freeze_record(metadata)
        self.requests.clear()
        result = sources.delivery_resources(self.root, destination, prepare=False, fetch=self.fetch)
        self.assertIsNone(result["prepared"])
        self.assertEqual(result["sources"], source_dir / "resource-sources.json")
        self.assertEqual(self.requests, [])

    def test_release_resource_interface_and_source_packager_use_the_real_manifest_file(self):
        from tool.artifacts import package_sources as packager
        self.by_url.update({resources._source_expected(kind, commit)[0]: data
                            for kind, commit, data in (("geoip", "a" * 40, b"converter"),
                                                       ("geoip", "c" * 40, b"data"),
                                                       ("geosite", "b" * 40, b"rules"))})
        geo = self.root / (resources.ASSET_ROOT + "geodata/manifest.json")
        geo.parent.mkdir(parents=True)
        geo.write_bytes(common_io.json_bytes({"files": [self.pinned["geoip"], self.pinned["geosite"]]}))
        before = geo.read_bytes()
        with mock.patch.object(sources, "official_resource_spec",
                               side_effect=lambda kind, root, *, fetch=None: self.pinned[kind]), \
                mock.patch.object(sources, "fetch", self.fetch), \
                mock.patch.object(resources.ssl, "SSLContext", wraps=ssl.SSLContext):
            result = sources.delivery_resources(self.root, self.base / "delivery", prepare=True)
        self.assertTrue(result["sources"].is_file())
        self.assertEqual(result["sources"].name, "resource-sources.json")
        self.assertEqual(geo.read_bytes(), before)
        self.freeze_record(resources.read_resource_sources(result["sources"].parent), prepared=result["prepared"])
        target = self.base / "resource-contract.tar.gz"
        import tarfile
        with tarfile.open(target, "w:gz") as archive:
            packager.add_resource_sources(archive, self.root, result["sources"])
        with tarfile.open(target, "r:gz") as archive:
            self.assertEqual(archive.extractfile("build-inputs/resource-sources.json").read(), result["sources"].read_bytes())
            for kind, row in resources.resource_source_entries(
                    resources.read_resource_sources(result["sources"].parent)):
                self.assertEqual(archive.extractfile("dependencies/data/" + kind + "/" + row["file"]).read(),
                                 (result["sources"].parent / row["file"]).read_bytes())

    def test_fixed_source_cli_never_resolves_latest_or_updates_application_inputs(self):
        self.by_url.update({resources._source_expected(kind, commit)[0]: data
                            for kind, commit, data in (("geoip", "a" * 40, b"converter"),
                                                       ("geoip", "c" * 40, b"data"),
                                                       ("geosite", "b" * 40, b"rules"))})
        geo = self.root / (resources.ASSET_ROOT + "geodata/manifest.json")
        geo.parent.mkdir(parents=True)
        geo.write_bytes(common_io.json_bytes({"files": [self.pinned["geoip"], self.pinned["geosite"]]}))
        fixed_sources = sources.prepare_resource_sources(resources.prepared_specs(self.prepare()),
                                                       self.base / "fixed-source-fixture", fetch=self.fetch)
        self.freeze_record(resources.read_resource_sources(fixed_sources.parent), prepared=self.base / "prepared")
        specs = self.base / "fixed-specs.json"
        specs.write_bytes(common_io.json_bytes({kind: self.pinned[kind] for kind in ("geoip", "geosite")}))
        destination = self.base / "fixed-cli"
        before = inputs.snapshot(self.root)
        arguments = ["prepare-resource-sources", "--spec", str(specs), "--destination", str(destination),
                     "--project", str(self.root)]
        with mock.patch.object(sources, "fetch", self.fetch), \
                mock.patch.object(sources, "official_resource_spec", side_effect=AssertionError("latest forbidden")), \
                mock.patch.object(update, "execute", side_effect=AssertionError("application update forbidden")):
            self.assertEqual(cli_main(["dependencies", *arguments]), 0)
            self.requests.clear()
            self.assertEqual(cli_main(["dependencies", *arguments]), 0)
            self.assertEqual(self.requests, [])
        self.assertEqual(inputs.snapshot(self.root), before)
        metadata = resources.read_resource_sources(destination)
        self.assertEqual(metadata["sources"][0]["inputs"][0]["sourceCommit"], "c" * 40)
        changed = json.loads(specs.read_bytes())
        changed["geoip"]["version"] = "202610060438"
        specs.write_bytes(common_io.json_bytes(changed))
        with mock.patch.object(sources, "fetch", side_effect=AssertionError("network forbidden")):
            self.assertEqual(cli_main(["dependencies", *arguments]), 1)
        self.assertEqual(inputs.snapshot(self.root), before)

    def test_delivery_entry_rejects_project_destination_and_unknown_entries(self):
        with self.assertRaisesRegex(ValueError, "outside the repository"):
            sources.delivery_resources(self.root, self.root / "candidate", prepare=False, fetch=self.fetch)
        destination = self.base / "delivery"
        destination.mkdir()
        (destination / "stray").write_bytes(b"x")
        with self.assertRaisesRegex(ValueError, "unknown entries"):
            sources.delivery_resources(self.root, destination, prepare=False, fetch=self.fetch)




if __name__ == "__main__":
    unittest.main()
