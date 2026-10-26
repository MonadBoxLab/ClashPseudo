"""Synthetic archives only; never compile or execute APK/native-library code."""

from contextlib import redirect_stdout
import gzip
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile


SCRIPT = Path(__file__).resolve().parents[2] / "tool/artifacts/verify_release_licenses.py"
SPEC = importlib.util.spec_from_file_location("verify_release_licenses", SCRIPT)
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)


class ReleaseLicenseTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.project = self.base / "project"
        self.project.mkdir()
        self.inputs = self.base / "inputs"
        self.inputs.mkdir()
        self.archives = self.base / "archives"
        self.archives.mkdir()
        self.output = self.base / "output"
        self.output.mkdir()
        for relative in verifier.ASSETS:
            path = self.project / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("Reviewed " + relative + "\n", encoding="utf-8")
        (self.project / "third_party/notices/go.txt").write_text("example.org/module v1.0.0\n")
        (self.project / "third_party/notices/android.txt").write_text("org.example:library:2.0\n")
        self.modules = [
            {"Path": "example.org/app", "Main": True},
            {"Path": "example.org/module", "Version": "v1.0.0", "Sum": "h1:module"},
        ]
        self.write_modules()
        (self.inputs / "android.txt").write_text(
            "releaseRuntimeClasspath - Runtime classpath\n"
            "+--- org.example:library:1.0 -> 2.0\n"
            "\\--- io.flutter:engine:1.0\n")
        (self.inputs / "NOTICES").write_bytes(b"Reviewed Flutter and Dart notices\n")
        self.entries = {
            "assets/flutter_assets/" + relative: (self.project / relative).read_bytes()
            for relative in verifier.ASSETS
        }
        self.entries["assets/flutter_assets/NOTICES.Z"] = gzip.compress(
            (self.inputs / "NOTICES").read_bytes())
        self.platform_assets = self.project / "android/app/src/main/assets"
        certificate = "certificates/controlled.pem"
        material = b"reviewed certificate material"
        (self.platform_assets / certificate).parent.mkdir(parents=True)
        (self.platform_assets / certificate).write_bytes(material)
        self.entries["assets/" + certificate] = material
        self.certificate_manifest = self.project / "third_party/data/certificates/manifest.json"
        self.certificate_manifest.write_text(json.dumps({
            "asset": certificate, "bytes": len(material), "sha256": verifier.digest(material),
        }))
        self.geo_manifest = {"format": "clash-pseudo-bundled-geodata", "version": 1, "files": []}
        for kind in ("geoip", "geosite", "mmdb", "asn"):
            installed = (kind + " controlled data").encode()
            compressed = kind in ("mmdb", "asn")
            stored = gzip.compress(installed) if compressed else installed
            name = kind + (".mmdb.gzip" if compressed else ".dat")
            path = self.platform_assets / "geodata" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(stored)
            self.entries["assets/geodata/" + name] = stored
            self.geo_manifest["files"].append({
                "kind": kind, "asset": name, "encoding": "gzip" if compressed else "identity",
                "storedBytes": len(stored), "storedSha256": verifier.digest(stored),
                "installedBytes": len(installed), "installedSha256": verifier.digest(installed),
            })
        legal = (self.project / "third_party/data/geodata/GeoSite-MIT.txt").read_bytes()
        self.geo_manifest["legalMaterials"] = [{
            "file": "licenses/GeoSite-MIT.txt", "bytes": len(legal), "sha256": verifier.digest(legal),
        }]
        self.entries["assets/geodata/licenses/GeoSite-MIT.txt"] = legal
        self.write_geo_manifest()
        for abi in verifier.ABIS:
            self.entries["lib/" + abi + "/libmihomo_bridge.so"] = b"synthetic library"
        self.write_archive()

    def write_geo_manifest(self):
        self.geo_manifest["storedDataTotalBytes"] = sum(row["storedBytes"] for row in self.geo_manifest["files"])
        self.geo_manifest["installedTotalBytes"] = sum(row["installedBytes"] for row in self.geo_manifest["files"])
        data = json.dumps(self.geo_manifest).encode()
        (self.platform_assets / "geodata/manifest.json").write_bytes(data)
        self.entries["assets/geodata/manifest.json"] = data

    def write_modules(self):
        (self.inputs / "go.json").write_text("\n".join(json.dumps(m) for m in self.modules))

    def write_archive(self):
        self.apk = self.archives / "app.apk"
        with zipfile.ZipFile(self.apk, "w") as archive:
            for name, data in self.entries.items():
                archive.writestr(name, data)

    def buildinfo(self, command, **kwargs):
        abi = Path(command[-1]).parent.name
        text = (
            "library: go1.26\n"
            "\tmod\texample.org/app\t(devel)\n"
            "\tdep\texample.org/module\tv1.0.0\th1:module\n"
            "\tbuild\tGOOS=android\n"
            "\tbuild\t-tags=cmfa,with_gvisor\n"
            "\tbuild\tGOARCH=" + verifier.ABIS[abi] + "\n"
            + ("\tbuild\tGOARM=7\n" if abi == "armeabi-v7a" else "")
        )
        return subprocess.CompletedProcess(command, 0, text, "")

    def run_verifier(self, response=None):
        stream = io.StringIO()
        with redirect_stdout(stream), mock.patch.object(
                verifier.subprocess, "run", side_effect=response or self.buildinfo) as process:
            result = verifier.main([
                "--project", str(self.project), "--apk", str(self.apk),
                "--notices", str(self.inputs / "NOTICES"),
                "--go-modules", str(self.inputs / "go.json"),
                "--android-dependencies", str(self.inputs / "android.txt"),
                "--output-dir", str(self.output), "--go", "/trusted/go",
            ])
        return result, stream.getvalue(), process

    def assert_failure(self, message, response=None):
        result, output, _ = self.run_verifier(response)
        self.assertEqual(result, 1, output)
        self.assertIn(message, output)

    def test_consistent_archive_and_offline_buildinfo_invocation(self):
        result, output, process = self.run_verifier()
        self.assertEqual(result, 0, output)
        self.assertEqual(process.call_count, len(verifier.ABIS))
        for call in process.call_args_list:
            self.assertEqual(call.args[0][:3], ["/trusted/go", "version", "-m"])
            self.assertEqual(call.kwargs["cwd"], self.project)
            for key, expected in (("GOTOOLCHAIN", "local"), ("GOPROXY", "off"),
                                  ("GOSUMDB", "off"), ("GOENV", "off")):
                self.assertEqual(call.kwargs["env"][key], expected)
        self.assertTrue((self.output / "arm64-v8a/buildinfo.txt").is_file())
        final = output.splitlines()[-1]
        self.assertTrue(final.startswith("FINAL "), output)
        self.assertEqual(json.loads(final.removeprefix("FINAL ")), {
            "exit_code": 0,
            "scope": "license/data bytes and resolved dependency graphs",
        })

    def test_all_declared_legal_assets_are_checked(self):
        pubspec = Path(__file__).resolve().parents[2] / "pubspec.yaml"
        declared = {
            line.strip()[2:] for line in pubspec.read_text().splitlines()
            if line.strip().startswith("- ")
        }
        self.assertEqual(set(verifier.ASSETS), declared)

    def test_changed_new_legal_asset_is_rejected(self):
        relative = "third_party/notices/publicsuffix.txt"
        path = self.project / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"Reviewed public suffix notice")
        self.entries["assets/flutter_assets/" + relative] = b"Changed notice"
        self.write_archive()
        self.assert_failure("License asset bytes differ")

    def test_missing_production_tags_are_rejected(self):
        def old_tags(command, **kwargs):
            result = self.buildinfo(command, **kwargs)
            result.stdout = result.stdout.replace("-tags=cmfa,with_gvisor", "-tags=cmfa")
            return result
        self.assert_failure("production tags mismatch", old_tags)

    def test_packaging_cannot_expand_or_rename_the_geo_gzip_asset(self):
        name = "assets/geodata/mmdb.mmdb.gzip"
        self.entries[name.removesuffix(".gzip")] = gzip.decompress(self.entries.pop(name))
        self.write_archive()
        self.assert_failure("mmdb.mmdb.gzip")

    def test_packaged_ca_material_must_match_the_reviewed_source(self):
        self.entries["assets/certificates/controlled.pem"] += b"changed"
        self.write_archive()
        self.assert_failure("Platform asset bytes differ")

    def test_ca_metadata_cannot_drift_from_the_packaged_bytes(self):
        manifest = json.loads(self.certificate_manifest.read_text())
        manifest["sha256"] = "0" * 64
        self.certificate_manifest.write_text(json.dumps(manifest))
        self.assert_failure("Platform asset bytes differ")

    def test_ca_metadata_cannot_select_an_outside_source_path(self):
        manifest = json.loads(self.certificate_manifest.read_text())
        manifest["asset"] = "certificates/../../outside.pem"
        self.certificate_manifest.write_text(json.dumps(manifest))
        self.assert_failure("Invalid certificate asset name")

    def test_geo_expanded_checksum_is_verified_separately(self):
        self.geo_manifest["files"][2]["installedSha256"] = "0" * 64
        self.write_geo_manifest()
        self.write_archive()
        self.assert_failure("Expanded Geo checksum differs")

    def test_geo_manifest_bytes_must_match_the_source(self):
        self.entries["assets/geodata/manifest.json"] += b" "
        self.write_archive()
        self.assert_failure("Geo manifest bytes differ")

    def test_generated_geo_legal_asset_must_match_the_canonical_material(self):
        self.entries["assets/geodata/licenses/GeoSite-MIT.txt"] += b"changed"
        self.write_archive()
        self.assert_failure("Geo legal asset bytes differ")

    def test_extra_expanded_geo_copy_is_not_silently_packaged(self):
        self.entries["assets/geodata/mmdb.mmdb"] = b"unexpected expanded copy"
        self.write_archive()
        self.assert_failure("Unexpected Geo assets or expanded duplicate")

    def test_geo_manifest_cannot_select_an_outside_source_path(self):
        self.geo_manifest["files"][0]["asset"] = "../outside"
        self.write_geo_manifest()
        self.write_archive()
        self.assert_failure("Invalid Geo asset name")

    def test_geo_expansion_is_bounded_by_its_reviewed_size(self):
        row = self.geo_manifest["files"][2]
        stored = gzip.compress(b"x" * 10000)
        row["storedBytes"] = len(stored)
        row["storedSha256"] = verifier.digest(stored)
        row["installedBytes"] = 8
        (self.platform_assets / "geodata" / row["asset"]).write_bytes(stored)
        self.entries["assets/geodata/" + row["asset"]] = stored
        self.write_geo_manifest()
        self.write_archive()
        self.assert_failure("Expanded Geo checksum differs")

    def test_asset_byte_difference(self):
        self.entries["assets/flutter_assets/LICENSE"] += b"changed"
        self.write_archive()
        self.assert_failure("License asset bytes differ")

    def test_missing_asset(self):
        del self.entries["assets/flutter_assets/LICENSE"]
        self.write_archive()
        self.assert_failure("LICENSE")

    def test_notices_snapshot_is_exact_not_a_substring(self):
        self.entries["assets/flutter_assets/NOTICES.Z"] = gzip.compress(
            b"Extra preamble\n" + (self.inputs / "NOTICES").read_bytes())
        self.write_archive()
        self.assert_failure("NOTICES.Z differs")

    def test_corrupt_notices_gzip(self):
        self.entries["assets/flutter_assets/NOTICES.Z"] = b"not gzip"
        self.write_archive()
        self.assert_failure("Not a gzipped file")

    def test_bounded_gzip_decompression(self):
        with mock.patch.object(verifier, "TEXT_LIMIT", 200):
            self.entries["assets/flutter_assets/NOTICES.Z"] = gzip.compress(b"x" * 10000)
            self.write_archive()
            self.assert_failure("NOTICES.Z differs")

    def test_bounded_archive_entry(self):
        with mock.patch.object(verifier, "TEXT_LIMIT", 10):
            with zipfile.ZipFile(self.apk) as archive:
                with self.assertRaisesRegex(ValueError, "size limit"):
                    verifier.read_entry(archive, "assets/flutter_assets/LICENSE", 10)

    def test_duplicate_archive_names_fail(self):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.apk, "a") as archive:
                archive.writestr("assets/flutter_assets/LICENSE", b"duplicate")
        self.assert_failure("Duplicate APK archive names")

    def test_unused_traversal_entry_is_never_extracted_or_executed(self):
        self.entries["../json.py"] = b"raise RuntimeError('must never run')"
        self.write_archive()
        result, output, _ = self.run_verifier()
        self.assertEqual(result, 0, output)
        self.assertFalse((self.base / "json.py").exists())
        self.assertEqual(set(p.name for p in self.output.iterdir()), set(verifier.ABIS))

    def test_unexpected_abi_fails_without_extraction(self):
        self.entries["lib/../../libmihomo_bridge.so"] = b"unsafe"
        self.write_archive()
        self.assert_failure("Expected exactly")
        self.assertEqual(list(self.output.iterdir()), [])

    def test_nonempty_output_is_preserved(self):
        marker = self.output / "keep.txt"
        marker.write_text("keep")
        self.assert_failure("Output directory must exist and be empty")
        self.assertEqual(marker.read_text(), "keep")

    def test_android_graph_drift(self):
        (self.inputs / "android.txt").write_text(
            "releaseRuntimeClasspath\n+--- org.example:library:3.0\n")
        self.assert_failure("Android notice coordinates differ")

    def test_selected_versions_substitutions_and_constraints(self):
        coordinates = verifier.android_coordinates(
            "releaseRuntimeClasspath\n"
            "+--- project :file_selector_android\n"
            "|    \\--- a:b:1 -> 2\n"
            "+--- project :nested:plugin (*)\n"
            "+--- a:b:1 -> 2\n"
            "+--- c:d -> 3\n"
            "+--- e:f:1 -> g:h:4 (*)\n"
            "+--- constraints:only:1 (c)\n"
            "\\--- io.flutter:engine:5\n")
        self.assertEqual(coordinates, {"a:b:2", "c:d:3", "g:h:4"})

    def test_unresolved_project_dependency_is_not_ignored(self):
        for suffix in (" FAILED", " (n)"):
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                verifier.android_coordinates(
                    "releaseRuntimeClasspath\n+--- project :plugin" + suffix +
                    "\n\\--- a:b:1\n")

    def test_unresolved_or_wrong_android_graph(self):
        for text in ("releaseRuntimeClasspath\n+--- a:b:1 FAILED\n",
                     "debugRuntimeClasspath\n+--- a:b:1\n",
                     "releaseRuntimeClasspath\n+--- project :app\n",
                     "releaseRuntimeClasspath\n+--- a:b:1 (n)\n"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                verifier.android_coordinates(text)

    def test_missing_main_or_duplicate_go_module(self):
        for modules in ([], self.modules[1:], self.modules + self.modules[1:]):
            self.modules = modules
            self.write_modules()
            with self.subTest(modules=modules), self.assertRaises(ValueError):
                verifier.go_modules(self.inputs / "go.json")

    def test_local_replacement_is_not_silently_accepted(self):
        self.modules[1]["Replace"] = {"Path": "../local-module"}
        self.write_modules()
        self.assert_failure("Local/unversioned Go replacement")

    def test_linked_version_or_sum_drift(self):
        self.modules[1]["Sum"] = "h1:other"
        self.write_modules()
        self.assert_failure("linked Sum mismatch")

    def test_go_notice_missing_linked_version(self):
        notice = self.project / "third_party/notices/go.txt"
        notice.write_text("example.org/module v2.0.0\n")
        self.entries["assets/flutter_assets/third_party/notices/go.txt"] = notice.read_bytes()
        self.write_archive()
        self.assert_failure("Go notice missing linked version")

    def test_versioned_replacement_matches_graph_and_effective_notice(self):
        selected = {
            "example.org/app": {"Main": True},
            "example.org/old": {"Version": "v1.0.0", "Replace": {
                "Path": "example.org/new", "Version": "v2.0.0", "Sum": "h1:new"}},
        }
        main, linked, settings = verifier.parse_buildinfo(
            "\tmod\texample.org/app\t(devel)\n"
            "\tdep\texample.org/old\tv1.0.0\n"
            "\t=>\texample.org/new\tv2.0.0\th1:new\n"
            "\tbuild\tGOOS=android\n\tbuild\tGOARCH=arm64\n"
            "\tbuild\t-tags=cmfa,with_gvisor\n")
        verifier.check_linked(main, linked, settings, "arm64-v8a", selected,
                              {("example.org/new", "v2.0.0")})
        selected["example.org/old"]["Replace"]["Sum"] = "h1:wrong"
        with self.assertRaisesRegex(ValueError, "replacement mismatch"):
            verifier.check_linked(main, linked, settings, "arm64-v8a", selected,
                                  {("example.org/new", "v2.0.0")})

    def test_go_command_failure(self):
        self.assert_failure("go version -m failed", lambda command, **kwargs:
                            subprocess.CompletedProcess(command, 1, "", "failed"))

    def test_go_command_timeout_is_reported(self):
        def timeout(command, **kwargs):
            raise subprocess.TimeoutExpired(command, 30)
        self.assert_failure("timed out", timeout)

    def test_different_abi_graphs_fail_even_when_both_match_selected_modules(self):
        self.modules.append({"Path": "example.org/other", "Version": "v1.0.0", "Sum": "h1:other"})
        self.write_modules()
        notice = self.project / "third_party/notices/go.txt"
        notice.write_text(notice.read_text() + "example.org/other v1.0.0\n")
        self.entries["assets/flutter_assets/third_party/notices/go.txt"] = notice.read_bytes()
        self.write_archive()
        def different_graph(command, **kwargs):
            result = self.buildinfo(command, **kwargs)
            if Path(command[-1]).parent.name == "x86_64":
                result.stdout += "\tdep\texample.org/other\tv1.0.0\th1:other\n"
            return result
        self.assert_failure("Native ABIs link different", different_graph)

    def test_wrong_main_module(self):
        def wrong_main(command, **kwargs):
            result = self.buildinfo(command, **kwargs)
            result.stdout = result.stdout.replace("example.org/app", "example.org/other")
            return result
        self.assert_failure("Linked Go main module differs", wrong_main)

    def test_malformed_or_non_go_buildinfo(self):
        for text in ("not a Go library", "\t=>\tx\tv1\n", "\tdep\tx\n",
                     "\tmod\tapp\t(devel)\n\tdep\tx\tv1\n\tdep\tx\tv1\n"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                verifier.parse_buildinfo(text)

    def test_missing_armv7_library_is_rejected(self):
        del self.entries["lib/armeabi-v7a/libmihomo_bridge.so"]
        self.write_archive()
        self.assert_failure("Expected exactly")

    def test_armv7_architecture_setting_is_verified(self):
        def wrong_arm(command, **kwargs):
            result = self.buildinfo(command, **kwargs)
            result.stdout = result.stdout.replace("GOARM=7", "GOARM=6")
            return result
        self.assert_failure("GOARM must target ARMv7", wrong_arm)

    def test_armv7_graph_is_compared_with_both_64_bit_graphs(self):
        self.modules.append({"Path": "example.org/other", "Version": "v1.0.0", "Sum": "h1:other"})
        self.write_modules()
        notice = self.project / "third_party/notices/go.txt"
        notice.write_text(notice.read_text() + "example.org/other v1.0.0\n")
        self.entries["assets/flutter_assets/third_party/notices/go.txt"] = notice.read_bytes()
        self.write_archive()
        def different_graph(command, **kwargs):
            result = self.buildinfo(command, **kwargs)
            if Path(command[-1]).parent.name == "armeabi-v7a":
                result.stdout += "\tdep\texample.org/other\tv1.0.0\th1:other\n"
            return result
        self.assert_failure("Native ABIs link different", different_graph)

    def test_wrong_goarch(self):
        def wrong_arch(command, **kwargs):
            result = self.buildinfo(command, **kwargs)
            result.stdout = result.stdout.replace("GOARCH=arm64", "GOARCH=amd64")
            return result
        self.assert_failure("GOARCH mismatch", wrong_arch)


if __name__ == "__main__":
    unittest.main()
