#!/usr/bin/env python3
"""使用合成工作树和工具副本，测试对应源码归档的文件内容、摘要和源码身份。"""

import gzip
import hashlib
import tool_test_support
from tool.artifacts import package_sources
from tool.dependencies import resources
from tool.common import workspace
from tool.cli import main as cli_main
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import tarfile


ROOT = Path(__file__).resolve().parents[2]


class SourceArchiveTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.packager = package_sources

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="clash-source-case-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "project"
        self.root.mkdir()
        self.output = self.base / "application.tar"
        self.names = []
        self.status = " M lib/current.dart\0?? lib/new.dart\0"
        self.command = mock.Mock(side_effect=self.git)
        patcher = mock.patch.object(self.packager, "run", self.command)
        patcher.start()
        self.addCleanup(patcher.stop)
        shared = mock.patch.object(workspace, "run", self.command)
        shared.start()
        self.addCleanup(shared.stop)

    def git(self, command, cwd):
        self.assertEqual(cwd, self.root)
        if command[:3] == ["git", "ls-files", "-z"]:
            return "\0".join(self.names) + "\0"
        if command[:2] == ["git", "status"]:
            return self.status
        if command == ["git", "rev-parse", "HEAD"]:
            return "a" * 40 + "\n"
        if command[:3] == ["git", "diff", "--exit-code"]:
            return ""
        self.fail("unexpected external command")

    def file(self, name, data=b"public synthetic input\n", executable=False):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o755 if executable else 0o644)
        self.names.append(name)
        return path

    def test_snapshot_includes_current_new_and_executable_inputs_but_not_deleted_head_bytes(self):
        self.file("lib/current.dart", b"modified\r\n")
        self.file("lib/new.dart", b"new source\n")
        self.file("tool/build.sh", b"#!/bin/sh\n", executable=True)
        self.names.append("lib/deleted.dart")
        identity = self.packager.application_tar(self.root, self.output, None)
        self.assertTrue(identity["workingTree"])
        self.assertTrue(identity["dirty"])
        self.assertEqual(identity["applicationTar"]["sha256"], hashlib.sha256(self.output.read_bytes()).hexdigest())
        self.assertEqual([row["path"] for row in identity["files"]],
                         ["lib/current.dart", "lib/new.dart", "tool/build.sh"])
        with tarfile.open(self.output) as archive:
            self.assertEqual(archive.extractfile("application/lib/current.dart").read(), b"modified\r\n")
            self.assertEqual(archive.extractfile("application/lib/new.dart").read(), b"new source\n")
            self.assertNotIn("application/lib/deleted.dart", archive.getnames())
            self.assertEqual(archive.getmember("application/tool/build.sh").mode, 0o755)
            self.assertTrue(all(info.mtime == 0 and info.uid == 0 for info in archive.getmembers()))
        self.assertFalse(any(call.args[0][:2] == ["git", "archive"] for call in self.command.call_args_list))

    def test_local_state_is_excluded_without_deleting_public_test_keys_or_backup_source(self):
        excluded = (".claude/settings.json", ".codegraph/index.sqlite", "backups/device.ab", ".env.local",
                    "backup.zip", "device-backup-2026.zip",
                    "android/local.properties", "android/key.properties", "build/app.apk", "signing/release.key")
        retained = ("test/fixtures/public.pem", "test/fixtures/private.key", "test/fixtures/synthetic.jks",
                    "test/fixtures/backup.zip",
                    "android/app/src/androidTest/assets/synthetic.keystore",
                    "native/mihomo/testdata/private.key", "android/app/src/main/backup/Backup.kt")
        for name in excluded + retained:
            self.file(name)
        self.packager.application_tar(self.root, self.output, None)
        with tarfile.open(self.output) as archive:
            self.assertEqual(set(archive.getnames()), {"application/" + name for name in retained})

    def test_unclassified_signing_container_fails_before_output_is_created(self):
        self.file("release.keystore")
        with self.assertRaisesRegex(ValueError, "私有构建材料"):
            self.packager.application_tar(self.root, self.output, None)
        self.assertFalse(self.output.exists())

    def test_existing_output_is_preserved(self):
        self.output.write_bytes(b"not owned by this attempt")
        with self.assertRaisesRegex(ValueError, "已存在"):
            self.packager.application_tar(self.root, self.output, None)
        self.assertEqual(self.output.read_bytes(), b"not owned by this attempt")

    def test_parent_symlink_cannot_pull_outside_bytes_into_snapshot(self):
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "file.dart").write_bytes(b"outside")
        (self.root / "linked").symlink_to(outside, target_is_directory=True)
        self.names.append("linked/file.dart")
        with self.assertRaisesRegex(ValueError, "符号链接"):
            self.packager.application_tar(self.root, self.output, None)
        self.assertFalse(self.output.exists())

    def test_in_place_edit_without_a_status_change_invalidates_the_snapshot(self):
        path = self.file("lib/current.dart", b"first")
        original = self.packager.add_bytes
        def add(archive, name, data, executable=False):
            original(archive, name, data, executable)
            path.write_bytes(b"second")
        with mock.patch.object(self.packager, "add_bytes", side_effect=add), \
                self.assertRaisesRegex(ValueError, "工作树发生变化"):
            self.packager.application_tar(self.root, self.output, None)
        self.assertFalse(self.output.exists())
        self.assertEqual(path.read_bytes(), b"second")

    def test_new_file_during_copy_invalidates_the_snapshot(self):
        self.file("lib/current.dart")
        original = self.packager.add_bytes
        def add(archive, name, data, executable=False):
            original(archive, name, data, executable)
            self.file("lib/late.dart")
        with mock.patch.object(self.packager, "add_bytes", side_effect=add), \
                self.assertRaisesRegex(ValueError, "工作树发生变化"):
            self.packager.application_tar(self.root, self.output, None)
        self.assertFalse(self.output.exists())

    def test_snapshot_bytes_are_repeatable_and_clean_identity_is_not_forced_dirty(self):
        self.status = ""
        self.file("lib/current.dart")
        first = self.packager.application_tar(self.root, self.output, None)
        second_output = self.base / "second.tar"
        second = self.packager.application_tar(self.root, second_output, None)
        self.assertFalse(first["dirty"])
        self.assertEqual(self.output.read_bytes(), second_output.read_bytes())
        self.assertEqual(first, second)

    def test_commit_mode_cannot_hide_untracked_current_source(self):
        self.file("lib/new.dart")
        with self.assertRaisesRegex(ValueError, "干净工作树"):
            self.packager.application_tar(self.root, self.output, "a" * 40)
        self.assertFalse(self.output.exists())

    def resources(self):
        material = self.base / "materials"
        material.mkdir()
        rows = []
        files = []
        for index, (kind, repository) in enumerate((("geoip", "geoip"), ("geosite", "domain-list-community"))):
            commit = str(index + 1) * 40
            data = gzip.compress((kind + " editable upstream source").encode(), mtime=0)
            name = kind + "-source.tar.gz"
            (material / name).write_bytes(data)
            rows.append({"kind": kind, "sourceCommit": commit,
                         "sourceUrl": f"https://github.com/v2fly/{repository}/archive/{commit}.tar.gz",
                         "file": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
            files.append({"kind": kind, "sourceCommit": commit})
        data = gzip.compress(b"synthetic release data: text/example.txt CIDR input", mtime=0)
        name = "geoip-release-data.tar.gz"
        (material / name).write_bytes(data)
        rows[0]["inputs"] = [{
            "sourceCommit": "3" * 40,
            "sourceUrl": "https://github.com/v2fly/geoip/archive/" + "3" * 40 + ".tar.gz",
            "file": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "description": "Synthetic fixed release text/*.txt CIDR input; no external download",
        }]
        rows[0]["processing"] = "Synthetic converter plus release CIDR inputs; fixture only"
        self.file("android/app/src/main/assets/geodata/manifest.json", json.dumps({"files": files}).encode())
        manifest = material / "resource-sources.json"
        metadata = {"format": "clash-pseudo-resource-sources", "version": 1, "sources": rows}
        manifest.write_text(json.dumps(metadata))
        from frozen_resource_fixture import frozen_resources
        frozen_resources(self.root, resources, source_metadata=metadata)
        return manifest, metadata

    def test_fixed_editable_data_archives_are_preserved_without_extraction(self):
        manifest, metadata = self.resources()
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w") as archive:
            self.packager.add_resource_sources(archive, self.root, manifest)
        output.seek(0)
        with tarfile.open(fileobj=output) as archive:
            self.assertEqual(archive.extractfile("build-inputs/resource-sources.json").read(), manifest.read_bytes())
            for row in metadata["sources"]:
                for source in [row, *row.get("inputs", [])]:
                    name = "dependencies/data/" + row["kind"] + "/" + source["file"]
                    self.assertEqual(archive.extractfile(name).read(), (manifest.parent / source["file"]).read_bytes())
            self.assertEqual(len([name for name in archive.getnames() if name.startswith("dependencies/data/")]), 3)

    def test_data_source_commit_digest_and_path_must_match_fixed_inputs(self):
        manifest, metadata = self.resources()
        for field, value in (("sourceCommit", "f" * 40), ("sha256", "0" * 64),
                             ("file", "../outside.tar.gz"), ("bytes", True),
                             ("sourceUrl", "https://github.com/v2fly/geoip/archive/latest.tar.gz")):
            changed = json.loads(json.dumps(metadata))
            changed["sources"][0][field] = value
            manifest.write_text(json.dumps(changed))
            with self.subTest(field=field), tarfile.open(fileobj=io.BytesIO(), mode="w") as archive, \
                    self.assertRaises(ValueError):
                self.packager.add_resource_sources(archive, self.root, manifest)

    def test_geoip_converter_alone_or_inputs_without_processing_are_rejected(self):
        manifest, metadata = self.resources()
        for field, value in (("inputs", []), ("inputs", None), ("processing", " ")):
            changed = json.loads(json.dumps(metadata))
            changed["sources"][0][field] = value
            manifest.write_text(json.dumps(changed))
            with self.subTest(field=field, value=value), tarfile.open(fileobj=io.BytesIO(), mode="w") as archive, \
                    self.assertRaises(ValueError):
                self.packager.add_resource_sources(archive, self.root, manifest)

    def test_supplementary_data_archive_has_independent_fixed_commit_and_digest_checks(self):
        manifest, metadata = self.resources()
        for field, value in (("sourceCommit", "latest"), ("sha256", "0" * 64),
                             ("file", "../outside.tar.gz"), ("bytes", True), ("description", ""),
                             ("sourceUrl", "https://github.com/v2fly/geoip/archive/latest.tar.gz")):
            changed = json.loads(json.dumps(metadata))
            changed["sources"][0]["inputs"][0][field] = value
            manifest.write_text(json.dumps(changed))
            with self.subTest(field=field), tarfile.open(fileobj=io.BytesIO(), mode="w") as archive, \
                    self.assertRaises(ValueError):
                self.packager.add_resource_sources(archive, self.root, manifest)

    def test_duplicate_source_archive_cannot_create_ambiguous_tar_members(self):
        manifest, metadata = self.resources()
        for duplicate in (dict(metadata["sources"][0]), dict(metadata["sources"][0]["inputs"][0])):
            changed = json.loads(json.dumps(metadata))
            duplicate["description"] = "Duplicate public fixture"
            changed["sources"][0]["inputs"].append(duplicate)
            manifest.write_text(json.dumps(changed))
            with tarfile.open(fileobj=io.BytesIO(), mode="w") as archive, self.assertRaisesRegex(ValueError, "重复"):
                self.packager.add_resource_sources(archive, self.root, manifest)

    def test_symlinked_input_cannot_read_outside_materials(self):
        manifest, metadata = self.resources()
        path = manifest.parent / metadata["sources"][0]["inputs"][0]["file"]
        outside = self.base / "outside.tar.gz"
        path.rename(outside)
        path.symlink_to(outside)
        with tarfile.open(fileobj=io.BytesIO(), mode="w") as archive, self.assertRaisesRegex(ValueError, "普通文件"):
            self.packager.add_resource_sources(archive, self.root, manifest)

    def package_inputs(self):
        manifest, _ = self.resources()
        self.file("pubspec.yaml", b"version: 1.0.0+1\n")
        self.file("lib/current.dart", b"current dirty source\n")
        self.file("third_party/data/certificates/manifest.json", b"{}\n")
        configuration = self.root / ".dart_tool/package_config.json"
        configuration.parent.mkdir()
        configuration.write_text('{"packages": []}')
        evidence = self.base / "evidence"
        evidence.mkdir()
        for path in manifest.parent.iterdir():
            (evidence / path.name).write_bytes(path.read_bytes())
        (evidence / "go-modules.json").write_text('{"Path":"example.org/app","Main":true}')
        (evidence / "android-dependencies.txt").write_text(
            "releaseRuntimeClasspath - Runtime classpath\n\\--- org.example:metadata:1.0\n")
        (evidence / "NOTICES").write_bytes(b"reviewed synthetic notices\n")
        updater = mock.Mock(root=self.root, flutter="/fake/flutter")
        updater.legal.return_value.production_modules.return_value = set()
        updater.go_run.return_value = "go version synthetic\n"
        original = self.git
        def command(arguments, cwd):
            if arguments == ["/fake/flutter", "pub", "deps", "--json"]:
                return '{"packages": []}'
            if arguments == ["/fake/flutter", "--version", "--machine"]:
                return '{"frameworkRevision":"synthetic"}'
            return original(arguments, cwd)
        self.command.side_effect = command
        updater.run.side_effect = command
        return manifest, evidence, updater

    def test_full_package_identifies_tar_bytes_not_head_as_the_dirty_source(self):
        manifest, evidence, updater = self.package_inputs()
        output = self.base / "sources.tar.gz"
        with mock.patch.object(self.packager, "application_version", return_value="1.0.0+1", create=True), \
                mock.patch.object(self.packager, "maven_sources", return_value={"metadata.pom": b"original POM"}):
            self.packager.create(updater, evidence, output, resource_sources=manifest)
        with tarfile.open(output) as archive:
            identity = json.load(archive.extractfile("build-inputs/source-tree.json"))
            version = json.load(archive.extractfile("build-inputs/version.json"))
            data = archive.extractfile("application.tar").read()
            self.assertEqual(identity["baseCommit"], "a" * 40)
            self.assertTrue(identity["dirty"])
            self.assertTrue(identity["workingTree"])
            self.assertNotIn("_status", identity)
            self.assertEqual(identity["applicationTar"]["sha256"], hashlib.sha256(data).hexdigest())
            self.assertEqual(version["applicationTar"], identity["applicationTar"])
            readme = archive.extractfile("README.txt").read().decode()
            self.assertIn("应用源码：当前工作树快照", readme)
            universal_save = (
                "  cp build/app/outputs/apk/release/app-universal-release.apk "
                "../clash-pseudo-1.0.0+1-apks/clash-pseudo-1.0.0+1-universal.apk\n")
            split_build = (
                "  flutter build apk --release --no-pub --target-platform "
                "android-arm,android-arm64,android-x64 --split-per-abi\n")
            self.assertIn(universal_save, readme)
            self.assertIn(split_build, readme)
            self.assertLess(readme.index(split_build), readme.index(universal_save))
            self.assertEqual(readme.count("flutter build apk "), 1)
            self.assertIn("四个分发签名环境变量", readme)
            for abi in ("arm64-v8a", "armeabi-v7a", "x86_64"):
                self.assertIn(
                    f"  cp build/app/outputs/flutter-apk/app-{abi}-release.apk "
                    f"../clash-pseudo-1.0.0+1-apks/clash-pseudo-1.0.0+1-{abi}.apk\n", readme)
            self.assertIn("build-inputs/resource-sources.json", archive.getnames())
            self.assertIn("build-inputs/certificates.json", archive.getnames())
            self.assertIn("build-inputs/geodata.json", archive.getnames())

    def test_source_changes_during_dependency_packaging_remove_only_owned_output(self):
        manifest, evidence, updater = self.package_inputs()
        output = self.base / "sources.tar.gz"
        def version(*args):
            (self.root / "lib/current.dart").write_bytes(b"newer user edit")
            return "go version synthetic\n"
        updater.go_run.side_effect = version
        with mock.patch.object(self.packager, "application_version", return_value="1.0.0+1", create=True), \
                mock.patch.object(self.packager, "maven_sources", return_value={"metadata.pom": b"original POM"}), \
                self.assertRaisesRegex(ValueError, "工作树发生变化"):
            self.packager.create(updater, evidence, output, resource_sources=manifest)
        self.assertFalse(output.exists())
        self.assertEqual((self.root / "lib/current.dart").read_bytes(), b"newer user edit")

    def test_original_four_argument_consumer_uses_default_evidence_resource_sources(self):
        _, evidence, updater = self.package_inputs()
        output = self.base / "sources.tar.gz"
        with mock.patch.object(self.packager, "application_version", return_value="1.0.0+1", create=True), \
                mock.patch.object(self.packager, "maven_sources", return_value={"metadata.pom": b"original POM"}):
            self.packager.create(updater, evidence, output, None)
        with tarfile.open(output) as archive:
            self.assertEqual(archive.extractfile("build-inputs/resource-sources.json").read(),
                             (evidence / "resource-sources.json").read_bytes())
            identity = json.load(archive.extractfile("build-inputs/source-tree.json"))
            self.assertTrue(identity["workingTree"])
            self.assertTrue(identity["dirty"])

    def test_cli_defaults_do_not_invent_a_head_commit(self):
        evidence = self.base / "evidence"
        output = self.base / "sources.tar.gz"
        updater = mock.Mock()
        with mock.patch.object(self.packager, "Updater", return_value=updater, create=True), \
                mock.patch.object(self.packager, "create") as create:
            self.assertEqual(cli_main(["artifacts", "package-sources", "--project", str(self.root), "--evidence", str(evidence),
                                                  "--output", str(output)]), 0)
        create.assert_called_once_with(updater, evidence, output, None, None, None)

    def test_replaced_inner_output_is_not_deleted_on_snapshot_failure(self):
        source = self.file("lib/current.dart", b"first")
        original = self.packager.add_bytes
        def add(archive, name, data, executable=False):
            original(archive, name, data, executable)
            self.output.rename(self.base / "owned-unfinished.tar")
            self.output.write_bytes(b"replacement user material")
            source.write_bytes(b"second")
        with mock.patch.object(self.packager, "add_bytes", side_effect=add), \
                self.assertRaisesRegex(ValueError, "工作树发生变化"):
            self.packager.application_tar(self.root, self.output, None)
        self.assertEqual(self.output.read_bytes(), b"replacement user material")

    def test_replaced_outer_output_is_not_deleted_on_packaging_failure(self):
        manifest, evidence, updater = self.package_inputs()
        output = self.base / "sources.tar.gz"
        def version(*args):
            output.rename(self.base / "owned-unfinished.tar.gz")
            output.write_bytes(b"replacement user material")
            raise ValueError("synthetic dependency failure")
        updater.go_run.side_effect = version
        with mock.patch.object(self.packager, "application_version", return_value="1.0.0+1", create=True), \
                mock.patch.object(self.packager, "maven_sources", return_value={"metadata.pom": b"original POM"}), \
                self.assertRaisesRegex(ValueError, "synthetic dependency failure"):
            self.packager.create(updater, evidence, output, resource_sources=manifest)
        self.assertEqual(output.read_bytes(), b"replacement user material")

    def test_missing_source_material_does_not_fabricate_an_archive(self):
        with tarfile.open(fileobj=io.BytesIO(), mode="w") as archive, self.assertRaises(FileNotFoundError):
            self.packager.add_resource_sources(archive, self.root, self.base / "missing.json")


if __name__ == "__main__":
    unittest.main()
