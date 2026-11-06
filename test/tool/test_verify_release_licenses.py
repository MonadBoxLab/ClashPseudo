"""使用合成归档，测试APK中的许可、数据资产和原生依赖校验。"""

from contextlib import redirect_stdout, redirect_stderr
import gzip
import tool_test_support
from tool.dependencies import resources
from tool.artifacts import verify_release_licenses as verifier
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


def run_cli(arguments):
    from tool.cli import main
    return main(["artifacts", "verify-release-licenses", *arguments])


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
        from frozen_resource_fixture import frozen_resources
        self.release_record, generated = frozen_resources(self.project, resources)
        self.platform_assets = generated / "assets"
        self.certificate_manifest = generated / "certificates.json"
        self.geo_manifest = json.loads((self.platform_assets / "geodata/manifest.json").read_bytes())
        for path in self.platform_assets.rglob("*"):
            if path.is_file():
                self.entries["assets/" + path.relative_to(self.platform_assets).as_posix()] = path.read_bytes()
        for relative in verifier.ASSETS:
            self.entries["assets/flutter_assets/" + relative] = (self.project / relative).read_bytes()
        self.write_geo_manifest()
        for abi in verifier.ABIS:
            self.entries["lib/" + abi + "/libmihomo_bridge.so"] = b"synthetic library"
        self.write_archive()

    def write_geo_manifest(self):
        self.geo_manifest["storedDataTotalBytes"] = sum(row["storedBytes"] for row in self.geo_manifest["files"])
        self.geo_manifest["installedTotalBytes"] = sum(row["installedBytes"] for row in self.geo_manifest["files"])
        data = (json.dumps(self.geo_manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()
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

    def run_verifier(self, response=None, abis=(), xnet_source=None):
        stream = io.StringIO()
        with redirect_stdout(stream), redirect_stderr(stream), mock.patch.object(
                verifier.subprocess, "run", side_effect=response or self.buildinfo) as process:
            result = run_cli([
                "--project", str(self.project), "--apk", str(self.apk),
                "--notices", str(self.inputs / "NOTICES"),
                "--go-modules", str(self.inputs / "go.json"),
                "--android-dependencies", str(self.inputs / "android.txt"),
                "--output-dir", str(self.output), "--go", "/trusted/go",
                *(argument for abi in abis for argument in ("--abi", abi)),
                *(["--xnet-source", str(xnet_source)] if xnet_source is not None else []),
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
            "scope": "许可与数据资产字节、各ABI的Go buildinfo及所选依赖图",
        })

    def test_each_split_checks_only_its_selected_abi(self):
        original = dict(self.entries)
        for abi in ("armeabi-v7a", "arm64-v8a", "x86_64"):
            with self.subTest(abi=abi):
                self.entries = {name: value for name, value in original.items()
                                if not name.startswith("lib/") or name.startswith("lib/" + abi + "/")}
                self.write_archive()
                self.output = self.base / ("output-" + abi)
                self.output.mkdir()
                result, output, process = self.run_verifier(abis=(abi,))
                self.assertEqual(result, 0, output)
                self.assertEqual(process.call_count, 1)
                self.assertEqual([path.name for path in self.output.iterdir()], [abi])

    def test_split_rejects_extra_or_missing_bridge_abi(self):
        result, output, process = self.run_verifier(abis=("arm64-v8a",))
        self.assertEqual(result, 1, output)
        self.assertIn("Expected exactly", output)
        process.assert_not_called()

    def test_split_rejects_foreign_abi_in_other_native_libraries(self):
        self.entries = {name: value for name, value in self.entries.items()
                        if not name.startswith("lib/") or name.startswith("lib/arm64-v8a/")}
        self.entries["lib/x86_64/libflutter.so"] = b"unexpected architecture"
        self.write_archive()
        result, output, process = self.run_verifier(abis=("arm64-v8a",))
        self.assertEqual(result, 1, output)
        self.assertIn("Packaged native ABIs differ", output)
        process.assert_not_called()

    def test_duplicate_target_abi_is_rejected(self):
        result, output, process = self.run_verifier(abis=("arm64-v8a", "arm64-v8a"))
        self.assertEqual(result, 1, output)
        self.assertIn("Invalid target ABI selection", output)
        process.assert_not_called()

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
        name = "assets/geodata/dbip-country-lite.mmdb.gzip"
        self.entries[name.removesuffix(".gzip")] = gzip.decompress(self.entries.pop(name))
        self.write_archive()
        self.assert_failure("APK 资源文件集合与本轮生成材料不同")

    def test_ca_and_geo_report_actual_packaged_bytes(self):
        result, output, _ = self.run_verifier()
        self.assertEqual(result, 0, output)
        records = [json.loads(line.partition(" ")[2]) for line in output.splitlines()
                   if line.startswith("PLATFORM_ASSET ")]
        expected = {"assets/" + path.relative_to(self.platform_assets).as_posix(): path.read_bytes()
                    for path in self.platform_assets.rglob("*") if path.is_file()}
        self.assertEqual({row["entry"] for row in records}, set(expected))
        for row in records:
            self.assertEqual(row["bytes"], len(expected[row["entry"]]))
            self.assertEqual(row["sha256"], verifier.digest(expected[row["entry"]]))

    def test_extra_stale_ca_bundle_is_not_silently_packaged(self):
        self.entries["assets/certificates/old.pem"] = b"stale public certificate fixture"
        self.write_archive()
        self.assert_failure("APK 资源文件集合与本轮生成材料不同")

    def test_metadata_does_not_select_files_or_trigger_parsing(self):
        self.certificate_manifest.unlink()
        metadata = b'{"files": [{"asset": "../../outside"}], "version": true, "version": false}'
        (self.platform_assets / "geodata/manifest.json").write_bytes(metadata)
        self.entries["assets/geodata/manifest.json"] = metadata
        self.write_archive()
        result, output, _ = self.run_verifier()
        self.assertEqual(result, 0, output)
        self.assertFalse((self.base / "outside").exists())

    def test_missing_generated_asset_fails_before_native_extraction(self):
        del self.entries["assets/geodata/GeoIP.dat"]
        self.write_archive()
        self.assert_failure("APK 资源文件集合与本轮生成材料不同")
        self.assertEqual(list(self.output.iterdir()), [])

    def psl_source(self, replacement=False):
        revision = "6" * 40
        version = "v1.0.0"
        prefix = "golang.org/x/net@" + version + "/"
        entries = {
            prefix + "publicsuffix/table.go": ("// generated from git revision " + revision + "\npackage publicsuffix\n").encode(),
            prefix + "go.mod": b"module golang.org/x/net\n",
        }
        source = self.inputs / "xnet.zip"
        with zipfile.ZipFile(source, "w") as archive:
            for name, data in entries.items():
                archive.writestr(name, data)
        effective = {"Path": "golang.org/x/net", "Version": version, "Sum": "h1:fixture"}
        module = ({"Path": "golang.org/x/net", "Version": "v0.1.0", "Sum": "h1:original", "Replace": effective}
                  if replacement else effective)
        self.modules.append(module)
        self.write_modules()
        editable = self.project / "third_party/data/publicsuffix/public_suffix_list.dat"
        editable.parent.mkdir(parents=True)
        editable.write_bytes(b"// Mozilla Public License, v. 2.0.\ncom\n")
        notice = self.project / "third_party/notices/publicsuffix.txt"
        notice.write_text("x/net " + version + "\nPSL " + revision + "\nSHA-256 " + verifier.digest(editable.read_bytes()))
        self.entries["assets/flutter_assets/third_party/notices/publicsuffix.txt"] = notice.read_bytes()
        self.write_archive()
        return source, module, revision

    def test_absent_psl_source_input_is_explicitly_unverified(self):
        result, output, _ = self.run_verifier()
        self.assertEqual(result, 0, output)
        self.assertIn('"verified": false', output)
        self.assertIn("填写--xnet-source参数，指定实际所选x/net模块的原始zip路径，然后重新运行PSL来源核验", output)

    def test_selected_xnet_table_revision_and_editable_psl_are_checked(self):
        source, _, revision = self.psl_source()
        result, output, _ = self.run_verifier(xnet_source=source)
        self.assertEqual(result, 0, output)
        self.assertIn('"revision": "' + revision + '"', output)
        self.assertIn('"verified": true', output)
        self.assertNotIn('"verified": false', output)

    def test_psl_uses_effective_versioned_replacement(self):
        source, module, _ = self.psl_source(replacement=True)
        with redirect_stdout(io.StringIO()):
            result = verifier.check_public_suffix(self.project, module, source)
        self.assertEqual(result["version"], module["Replace"]["Version"])
        self.assertEqual(result["module"], module["Replace"]["Path"])

    def test_psl_notice_cannot_substitute_a_newer_revision_for_compiled_table(self):
        source, module, revision = self.psl_source()
        notice = self.project / "third_party/notices/publicsuffix.txt"
        notice.write_text(notice.read_text().replace(revision, "7" * 40))
        with self.assertRaisesRegex(ValueError, "PSL 通知与所选 x/net 的来源提交或可编辑源码不同"):
            verifier.check_public_suffix(self.project, module, source)

    def test_psl_editable_source_drift_is_rejected(self):
        source, module, _ = self.psl_source()
        editable = self.project / "third_party/data/publicsuffix/public_suffix_list.dat"
        editable.write_bytes(editable.read_bytes() + b"different.example\n")
        with self.assertRaisesRegex(ValueError, "PSL 通知与所选 x/net 的来源提交或可编辑源码不同"):
            verifier.check_public_suffix(self.project, module, source)

    def test_psl_archive_duplicate_and_outside_paths_are_not_extracted(self):
        source, module, _ = self.psl_source()
        with zipfile.ZipFile(source, "a") as archive:
            archive.writestr("../json.py", b"raise RuntimeError('must not run')")
        with self.assertRaisesRegex(ValueError, "x/net 源码归档路径越界"):
            verifier.check_public_suffix(self.project, module, source)
        self.assertFalse((self.base / "json.py").exists())

    def test_psl_duplicate_archive_member_is_rejected_before_reading(self):
        source, module, _ = self.psl_source()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(source, "a") as archive:
                archive.writestr("golang.org/x/net@v1.0.0/go.mod", b"duplicate")
        with self.assertRaisesRegex(ValueError, "x/net 源码归档含重复成员"):
            verifier.check_public_suffix(self.project, module, source)

    def test_psl_source_reads_are_bounded_without_extracting_zip_contents(self):
        source, module, _ = self.psl_source()
        with mock.patch.object(verifier, "TEXT_LIMIT", 8), self.assertRaisesRegex(ValueError, "size limit"):
            verifier.check_public_suffix(self.project, module, source)
        self.assertFalse((self.output / "publicsuffix").exists())

    def test_psl_source_cli_rejects_graph_without_selected_xnet(self):
        result, output, process = self.run_verifier(xnet_source=self.inputs / "unused.zip")
        self.assertEqual(result, 1, output)
        self.assertIn("Selected graph has no x/net module", output)
        process.assert_not_called()

    def test_packaged_ca_material_must_match_the_reviewed_source(self):
        self.entries["assets/certificates/cacert.pem"] += b"changed"
        self.write_archive()
        self.assert_failure("APK 资源字节与本轮生成材料不同：assets/certificates/cacert.pem")

    def test_geo_manifest_bytes_must_match_the_source(self):
        self.entries["assets/geodata/manifest.json"] += b" "
        self.write_archive()
        self.assert_failure("APK 资源字节与本轮生成材料不同：assets/geodata/manifest.json")

    def test_generated_geo_legal_asset_must_match_the_canonical_material(self):
        self.entries["assets/geodata/licenses/GeoSite-MIT.txt"] += b"changed"
        self.write_archive()
        self.assert_failure("APK 资源字节与本轮生成材料不同：assets/geodata/licenses/GeoSite-MIT.txt")

    def test_extra_expanded_geo_copy_is_not_silently_packaged(self):
        self.entries["assets/geodata/mmdb.mmdb"] = b"unexpected expanded copy"
        self.write_archive()
        self.assert_failure("APK 资源文件集合与本轮生成材料不同")

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
        self.assert_failure("NOTICES.Z解压后的内容与指定的NOTICES文件不同")

    def test_corrupt_notices_gzip(self):
        self.entries["assets/flutter_assets/NOTICES.Z"] = b"not gzip"
        self.write_archive()
        self.assert_failure("Not a gzipped file")

    def test_bounded_gzip_decompression(self):
        with mock.patch.object(verifier, "TEXT_LIMIT", 8192):
            self.entries["assets/flutter_assets/NOTICES.Z"] = gzip.compress(b"x" * 100000)
            self.write_archive()
            self.assert_failure("NOTICES.Z解压后的内容与指定的NOTICES文件不同")

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
            "+--- project ':file_selector_android'\n"
            "+--- project ':nested:plugin' (*)\n"
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
