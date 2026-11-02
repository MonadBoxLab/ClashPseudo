"""测试依赖更新、应用版本递增及许可材料收集。"""

import argparse
from contextlib import redirect_stdout, redirect_stderr
import importlib.util
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile

from frozen_resource_fixture import frozen_resources


ROOT = Path(__file__).resolve().parents[2]


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


update = load("dependency_update", "tool/dependencies/update.py")
legal = load("dependency_legal", "tool/dependencies/legal.py")


class VersionTest(unittest.TestCase):
    def test_levels_reset_subordinate_components_and_increment_android_code_once(self):
        source = "name: test\nversion: 2.7.9+42\n\ndependencies:\n"
        for level, version in (("major", "3.0.0+43"), ("minor", "2.8.0+43"), ("patch", "2.7.10+43")):
            with self.subTest(level=level):
                text, actual = update.bump_version(source, level)
                self.assertEqual(actual, version)
                self.assertEqual(text, "name: test\nversion: " + version + "\n\ndependencies:\n")

    def test_default_maintenance_example(self):
        self.assertEqual(update.bump_version("version: 1.0.0+1\n"),
                         ("version: 1.0.1+2\n", "1.0.1+2"))

    def test_development_updates_stay_development_until_explicit_first_stable(self):
        source = "name: sample\nversion: 0.7.9+42\n"
        for level, expected in (("patch", "0.7.10+43"), ("minor", "0.8.0+43"), ("stable", "1.0.0+43")):
            with self.subTest(level=level):
                text, version = update.bump_version(source, level)
                self.assertEqual(version, expected)
                self.assertEqual(text, "name: sample\nversion: " + expected + "\n")
        with self.assertRaisesRegex(ValueError, "明确选择 stable"):
            update.bump_version(source, "major")
        with self.assertRaisesRegex(ValueError, "仅适用于"):
            update.bump_version("version: 1.2.3+43\n", "stable")

    def test_invalid_or_duplicate_version_and_android_limit(self):
        for text in ("", "version: 1.0+1", "version: 1.0.0", "version: 1.0.0-beta+1",
                     "version: 1.0.0+1\nversion: 1.0.1+2\n", "version: 1.0.0+2100000000"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                update.bump_version(text)

    def test_stable_metadata_filters_previews(self):
        self.assertEqual(update.stable_version("v1.19.33"), (1, 19, 33))
        for version in ("1.3.0-rc1", "1.3.0-alpha01", "v1.3.0+build", "latest", "1"):
            self.assertIsNone(update.stable_version(version))

    def test_github_draft_and_prerelease_are_rejected(self):
        for release in ({"tag_name": "v1.19.33", "draft": True},
                        {"tag_name": "v1.19.33", "prerelease": True},
                        {"tag_name": "v1.19.33-rc1"}, {"tag_name": "1.19.33"}, {}):
            with mock.patch.object(update, "fetch", return_value=json.dumps(release).encode()), self.assertRaises(ValueError):
                update.mihomo_release()

    def test_latest_formal_github_release_is_selected_without_manual_tag(self):
        for version in ("v1.19.33", "v1.19.34"):
            release = {"tag_name": version, "draft": False, "prerelease": False}
            with self.subTest(version=version), mock.patch.object(
                    update, "fetch", return_value=json.dumps(release).encode()) as fetch:
                self.assertEqual(update.mihomo_release(), version)
            fetch.assert_called_once_with("https://api.github.com/repos/MetaCubeX/mihomo/releases/latest")


class UpdateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "project"
        self.root.mkdir()
        for name in update.INPUTS:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("existing " + name + "\n")
        (self.root / ".gitignore").write_text("build/\n")
        (self.root / "pubspec.yaml").write_text(
            "name: sample\nversion: 1.0.0+1\n\ndependencies:\n"
            "  flutter:\n    sdk: flutter\n  http: ^1.0.0\n"
            "  re_editor:\n    path: third_party/sources/re_editor\n"
            "dev_dependencies:\n  coverage: ^1.16.0\n")
        (self.root / "pubspec.lock").write_text("existing lock\n")
        (self.root / "native/mihomo/go.mod").write_text(
            "module example.test/app\n\ngo 1.27.1\n\nrequire (\n"
            f"\t{update.MIHOMO} v1.19.32\n\tgolang.org/x/net v0.40.0\n)\n")
        (self.root / "android/app/build.gradle.kts").write_text(
            'plugins { id("com.android.application") }\n'
            'implementation("androidx.work:work-runtime:2.12.0")\n')
        self.source_directory = self.base / "resource-sources"
        self.source_directory.mkdir()

        def source(kind, commit, filename, description=None):
            content = ("合成资源对应源码 " + kind + " " + commit + "\n").encode()
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode="w") as archive:
                entry = tarfile.TarInfo("fixture/README.txt")
                entry.size = len(content)
                archive.addfile(entry, io.BytesIO(content))
            data = gzip.compress(buffer.getvalue(), mtime=0)
            (self.source_directory / filename).write_bytes(data)
            repository = "v2fly/geoip" if kind == "geoip" else "v2fly/domain-list-community"
            row = {"sourceCommit": commit,
                   "sourceUrl": f"https://github.com/{repository}/archive/{commit}.tar.gz",
                   "file": filename, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
            if description is not None:
                row["description"] = description
            return row

        self.sources = {"format": "clash-pseudo-resource-sources", "version": 1, "sources": [
            dict(source("geoip", "1" * 40, "geoip.tar.gz"), kind="geoip",
                 processing=update.GEOIP_DATA_PROCESSING,
                 inputs=[source("geoip", "2" * 40, "geoip-inputs.tar.gz", "合成 GeoIP 补充输入")]),
            dict(source("geosite", "3" * 40, "geosite.tar.gz"), kind="geosite"),
        ]}
        self.source_manifest = self.source_directory / "resource-sources.json"
        self.source_manifest.write_bytes(update.json_bytes(self.sources))
        self.record, self.generated = frozen_resources(self.root, update, source_metadata=self.sources)
        self.record["application"] = "1.0.0+1"
        for path in (self.root / update.RESOURCE_RECORD, self.generated / "resources.json"):
            path.write_bytes(update.json_bytes(self.record))
        self.prepared = self.base / "resources"
        update.prepare_resources(list(self.record["resources"].values()), self.prepared, {
            kind: self.generated / "assets" / name for kind, name in update.RESOURCE_ASSETS.items()})
        subprocess.run(["git", "init", "-q", self.root], check=True, capture_output=True)
        subprocess.run(["git", "-C", self.root, "add", "."], check=True, capture_output=True)
        self.updater = mock.Mock()
        self.manifest = {"Go": "1.27.1", "Require": [
            {"Path": update.MIHOMO, "Version": "v1.19.32"},
            {"Path": "golang.org/x/net", "Version": "v0.40.0"},
            {"Path": "github.com/rasky/go-lzo", "Version": "v0.0.0-20200203143853-96a758eda86e", "Indirect": True},
            {"Path": "github.com/metacubex/chacha", "Version": "v0.1.5", "Indirect": True},
        ], "Replace": []}
        self.updater.go_run.return_value = json.dumps(self.manifest)
        self.updater.go_updates.return_value = {update.MIHOMO: "v1.19.33"}
        self.updater.pub_updates.return_value = {}
        self.updater.android_updates.return_value = {}
        self.toolchains = {"go": {"version": "1.28.0"}, "flutter": {"version": "4.0.0"}}
        self.environment = {
            "PATH": os.pathsep.join((str(self.base / "toolchains/flutter/bin"),
                                     str(self.base / "toolchains/go/bin"), os.environ["PATH"])),
            "CLASH_TOOLCHAIN_FIXTURE": "stable",
        }
        self.bootstrap = mock.Mock()
        self.bootstrap.resolve.return_value = self.toolchains
        self.bootstrap.prepare.return_value = (self.environment, {"fixture": "measured"})

    def arguments(self, **values):
        defaults = dict(project=self.root, go="go", flutter="flutter", go_module=[], pub=[], android=[],
                        apply=True, check=False, evidence=None, bump="patch", reuse_version=False,
                        resolved_release="v1.19.33", prepared_resources=None, toolchain_cache=self.base / "cache")
        defaults.update(values)
        return argparse.Namespace(**defaults)

    def execute(self, **values):
        original_load, original_run = update.load_tool, update.run

        def load_tool(name, path):
            return self.bootstrap if name == "dependency_toolchains" else original_load(name, path)

        def create_updater(work, go, flutter):
            self.work = work
            self.updater.root = work
            self.updater.go = go
            self.updater.flutter = flutter
            self.updater.resolution = {
                "go": {name: {"selected": version} for name, version in self.updater.go_updates.return_value.items()},
                "pub": {name: {"selected": version} for name, (version, _) in self.updater.pub_updates.return_value.items()},
                "android": {name: {"selected": version} for name, version in self.updater.android_updates.return_value.items()},
            }
            if values.get("apply", True):
                self.assertEqual(os.environ["PATH"], self.environment["PATH"])
                self.assertEqual(go, str(self.base / "toolchains/go/bin/go"))
                self.assertEqual(flutter, str(self.base / "toolchains/flutter/bin/flutter"))
                self.assertEqual(self.bootstrap.method_calls[-1], mock.call.apply_versions(work, self.toolchains))
            return self.updater

        def run(command, cwd, env=None):
            if str(command[0]) == str(self.base / "toolchains/flutter/bin/flutter"):
                self.assertEqual(command[1:], ["pub", "get", "--enforce-lockfile"])
                return ""
            return original_run(command, cwd, env)

        with mock.patch.object(update, "Updater", side_effect=create_updater), \
                mock.patch.object(update, "load_tool", side_effect=load_tool), \
                mock.patch.object(update, "run", side_effect=run), \
                mock.patch.object(update, "delivery_resources", return_value={
                    "prepared": self.prepared, "sources": self.source_manifest}):
            return update.execute(self.arguments(**values))

    def test_check_preserves_user_changes_and_index(self):
        (self.root / "pubspec.yaml").write_text("name: user-edited\nversion: 1.0.0+1\n")
        before = update.snapshot(self.root)
        index = (self.root / ".git/index").read_bytes()
        result = self.execute(apply=False, check=True)
        self.assertEqual(result["status"], "available")
        self.assertEqual(update.snapshot(self.root), before)
        self.assertEqual((self.root / ".git/index").read_bytes(), index)
        self.updater.update_go.assert_not_called()
        self.updater.legal.assert_not_called()

    def test_dependency_and_feature_release_use_one_minor_bump(self):
        result = self.execute(bump="minor")
        self.assertEqual(result["version"], "1.1.0+2")
        self.assertEqual(result["files"], ["pubspec.yaml", update.RESOURCE_RECORD])
        self.updater.legal.return_value.go_notices.assert_called_once()
        self.updater.legal.return_value.pub_licenses.assert_called_once()
        self.updater.legal.return_value.android_notices.assert_called_once()
        self.bootstrap.resolve.assert_called_once_with()
        self.bootstrap.prepare.assert_called_once_with(self.toolchains, self.base / "cache", self.work)
        self.bootstrap.freeze_archives.assert_called_once_with(self.toolchains, {"fixture": "measured"})
        self.bootstrap.apply_versions.assert_called_once_with(self.work, self.toolchains)
        record = update.verify_bundled_assets(self.root)
        self.assertEqual(record["application"], result["version"])
        self.assertEqual(record["toolchains"], self.toolchains)
        self.assertEqual(record["dependencies"], self.updater.resolution)
        self.assertEqual(record["sourceInputs"], self.sources)

    def test_no_update_and_retry_preserve_determined_version(self):
        (self.root / "pubspec.yaml").write_text("version: 1.1.0+2\n")
        self.updater.go_updates.return_value = {}
        before = update.snapshot(self.root)
        result = self.execute(apply=False, check=True, resolved_release="v1.19.32")
        self.assertEqual(result["status"], "unchanged")
        self.assertEqual(result["version"], "1.1.0+2")
        self.assertEqual(result["files"], [])
        self.assertEqual(update.snapshot(self.root), before)
        result = self.execute()
        self.assertEqual(result["status"], "updated")
        self.assertEqual(result["version"], "1.1.1+3")
        self.assertEqual(result["files"], ["pubspec.yaml", update.RESOURCE_RECORD])
        result = self.execute(reuse_version=True)
        self.assertEqual(result["status"], "updated")
        self.assertEqual(result["version"], "1.1.1+3")
        self.assertEqual(result["files"], [])

    def test_additional_kernel_update_does_not_stack_pending_release_version(self):
        (self.root / "pubspec.yaml").write_text("version: 1.1.0+2\n")
        before = (self.root / "pubspec.yaml").read_bytes()
        result = self.execute(reuse_version=True)
        self.assertEqual(result["version"], "1.1.0+2")
        self.assertEqual(result["files"], [update.RESOURCE_RECORD])
        self.assertEqual((self.root / "pubspec.yaml").read_bytes(), before)
        self.updater.update_go.assert_called_once_with({update.MIHOMO: "v1.19.33"})

    def test_explicit_release_queries_all_direct_dependencies_and_bumps_once(self):
        self.updater.go_updates.return_value = {}
        result = self.execute(bump="major")
        self.assertEqual(result["version"], "2.0.0+2")
        self.updater.go_updates.assert_called_once_with([update.MIHOMO, "golang.org/x/net"], "v1.19.33")
        self.updater.pub_updates.assert_called_once_with(["http", "coverage"])
        self.updater.android_updates.assert_called_once_with(["androidx.work:work-runtime"])
        self.updater.legal.assert_called_once()

    def test_first_stable_uses_real_version_writer_and_major_rejection_preserves_inputs(self):
        (self.root / "pubspec.yaml").write_text("version: 0.7.9+42\n")
        before = update.snapshot(self.root)
        with self.assertRaisesRegex(ValueError, "明确选择 stable"):
            self.execute(bump="major")
        self.assertEqual(update.snapshot(self.root), before)
        self.updater.go_updates.return_value = {}
        result = self.execute(bump="stable")
        self.assertEqual(result["version"], "1.0.0+43")
        self.assertEqual((self.root / "pubspec.yaml").read_text(), "version: 1.0.0+43\n")
        self.assertEqual(result["files"], ["pubspec.yaml", update.RESOURCE_RECORD])
        self.updater.go_updates.assert_called_with([update.MIHOMO, "golang.org/x/net"], "v1.19.33")
        self.assertEqual((self.root / "pubspec.lock").read_text(), "existing lock\n")

    def test_development_no_update_and_pending_retry_keep_version_and_android_code(self):
        (self.root / "pubspec.yaml").write_text("version: 0.1.0+3\n")
        result = self.execute(reuse_version=True)
        self.assertEqual(result["version"], "0.1.0+3")
        self.assertEqual(result["files"], [update.RESOURCE_RECORD])
        self.updater.go_updates.return_value = {}
        result = self.execute()
        self.assertEqual(result["status"], "updated")
        self.assertEqual(result["version"], "0.1.1+4")
        self.assertEqual(result["files"], ["pubspec.yaml", update.RESOURCE_RECORD])
        result = self.execute(reuse_version=True)
        self.assertEqual(result["version"], "0.1.1+4")
        self.assertEqual(result["files"], [])

    def test_resolution_or_license_failure_preserves_inputs(self):
        before = update.snapshot(self.root)
        index = (self.root / ".git/index").read_bytes()
        environment = dict(os.environ)
        for operation in (self.updater.update_go, self.updater.legal.return_value.go_notices):
            with self.subTest(operation=operation):
                operation.side_effect = ValueError("specific failure")
                with self.assertRaisesRegex(ValueError, "specific failure"):
                    self.execute()
                self.assertEqual(update.snapshot(self.root), before)
                self.assertEqual((self.root / ".git/index").read_bytes(), index)
                self.assertEqual(dict(os.environ), environment)
                operation.side_effect = None

    def test_success_restores_environment_and_explicit_dependency_selection(self):
        environment = dict(os.environ)
        result = self.execute(go_module=[update.MIHOMO], pub=["coverage"], android=["androidx.work:work-runtime"])
        self.assertEqual(result["version"], "1.0.1+2")
        self.assertEqual(dict(os.environ), environment)
        self.updater.go_updates.assert_called_once_with([update.MIHOMO], "v1.19.33")
        self.updater.pub_updates.assert_called_once_with(["coverage"])
        self.updater.android_updates.assert_called_once_with(["androidx.work:work-runtime"])
        self.assertIn("    sdk: flutter\n", (self.root / "pubspec.yaml").read_text())
        self.assertIn("    path: third_party/sources/re_editor\n", (self.root / "pubspec.yaml").read_text())

    def test_full_source_identity_change_prevents_input_writeback(self):
        source = self.root / "user.txt"
        source.write_bytes(b"initial source\n")
        before = update.snapshot(self.root)
        index = (self.root / ".git/index").read_bytes()
        status = update.run(["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"], self.root)

        def change_source(names):
            source.write_bytes(b"concurrent source\n")
            return {}

        self.updater.pub_updates.side_effect = change_source
        with self.assertRaisesRegex(ValueError, "归档期间工作树发生变化"):
            self.execute()
        self.assertEqual(update.snapshot(self.root), before)
        self.assertEqual((self.root / ".git/index").read_bytes(), index)
        self.assertEqual(source.read_bytes(), b"concurrent source\n")
        self.assertEqual(update.run(["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"], self.root), status)

    def test_concurrent_change_is_not_overwritten(self):
        before = update.snapshot(self.root)
        after = dict(before, **{"pubspec.yaml": b"version: 1.0.1+2\n"})
        (self.root / "pubspec.yaml").write_text("version: 7.0.0+12\n")
        with self.assertRaisesRegex(ValueError, "更新期间文件发生变化"):
            update.publish_changes(self.root, before, after)
        self.assertEqual((self.root / "pubspec.yaml").read_text(), "version: 7.0.0+12\n")

    def test_only_owned_updated_inputs_are_written(self):
        path = self.root / "user.txt"
        path.write_text("keep")
        before = update.snapshot(self.root)
        after = dict(before, **{"native/mihomo/go.mod": b"updated\n"})
        self.assertEqual(update.publish_changes(self.root, before, after), ["native/mihomo/go.mod"])
        self.assertEqual(path.read_text(), "keep")

    def test_deleted_tracked_file_is_not_resurrected(self):
        path = self.root / "pubspec.lock"
        path.unlink()
        destination = self.base / "copy"
        destination.mkdir()
        update.copy_workspace(self.root, destination)
        self.assertFalse((destination / "pubspec.lock").exists())

    def test_go_toolchain_and_transitive_changes_keep_the_selected_target(self):
        before = json.loads(json.dumps(self.manifest))
        before["Require"][1]["Indirect"] = True
        updater = update.Updater(self.root)
        for toolchain in ({"Go": "1.28.0"}, {"Toolchain": "go1.28.0"},
                          {"Go": "1.28.0", "Toolchain": "go1.28.0"}):
            after = dict(before, **toolchain, Require=[
                dict(row, Version="v1.19.33" if row["Path"] == update.MIHOMO else
                     "v0.41.0" if row["Path"] == "golang.org/x/net" else row["Version"])
                for row in before["Require"]] + [
                    {"Path": "example.test/transitive", "Version": "v1.0.0", "Indirect": True}])
            with self.subTest(toolchain=toolchain), mock.patch.object(
                    updater, "go_run", side_effect=[json.dumps(before), "", "", json.dumps(after)]) as process:
                updater.update_go({update.MIHOMO: "v1.19.33"})
            self.assertEqual(process.call_args_list, [
                mock.call("mod", "edit", "-json"), mock.call("get", update.MIHOMO + "@v1.19.33"),
                mock.call("mod", "tidy"), mock.call("mod", "edit", "-json")])

    def test_go_replace_changes_stop_before_writeback(self):
        original = [{"Old": {"Path": "google.golang.org/protobuf"},
                     "New": {"Path": "github.com/metacubex/protobuf", "Version": "v1.36.7"}}]
        before = dict(self.manifest, Replace=original)
        snapshot = update.snapshot(self.root)
        updater = update.Updater(self.root)
        for replacement in ([], [{"Old": original[0]["Old"], "New": {"Path": "example.test/replacement"}}],
                            [{"Old": original[0]["Old"],
                              "New": {"Path": "github.com/metacubex/protobuf", "Version": "v1.36.8"}}]):
            after = dict(before, Replace=replacement)
            with self.subTest(replacement=replacement), mock.patch.object(
                    updater, "go_run", side_effect=[json.dumps(before), "", "", json.dumps(after)]):
                with self.assertRaisesRegex(ValueError, "Go replace 发生变化"):
                    updater.update_go({update.MIHOMO: "v1.19.33"})
            self.assertEqual(update.snapshot(self.root), snapshot)

    def test_go_license_modules_and_selected_version_remain_required(self):
        updater = update.Updater(self.root)
        snapshot = update.snapshot(self.root)
        for missing in ("github.com/rasky/go-lzo", "github.com/metacubex/chacha", update.MIHOMO):
            after = dict(self.manifest, Require=[
                dict(row, Version="v1.19.33" if row["Path"] == update.MIHOMO else row["Version"])
                for row in self.manifest["Require"] if row["Path"] != missing])
            message = "实际 Go 解析与更新目标不同" if missing == update.MIHOMO else "许可版本约束丢失：" + missing
            with self.subTest(missing=missing), mock.patch.object(
                    updater, "go_run", side_effect=[json.dumps(self.manifest), "", "", json.dumps(after)]):
                with self.assertRaisesRegex(ValueError, message):
                    updater.update_go({update.MIHOMO: "v1.19.33"})
            self.assertEqual(update.snapshot(self.root), snapshot)
        with mock.patch.object(updater, "go_run", side_effect=[
                json.dumps(self.manifest), "", "", json.dumps(self.manifest)]):
            with self.assertRaisesRegex(ValueError, "实际 Go 解析与更新目标不同"):
                updater.update_go({update.MIHOMO: "v1.19.33"})
        self.assertEqual(update.snapshot(self.root), snapshot)

    def test_pub_uses_resolvable_version_and_preserves_dev_section(self):
        updater = update.Updater(self.root)
        output = {"packages": [{"package": "coverage", "kind": "dev", "current": {"version": "1.16.0"},
                                "resolvable": {"version": "1.17.0"}, "latest": {"version": "2.0.0"}}]}
        dependencies = {"packages": [{"name": "coverage", "source": "hosted", "version": "1.16.0"}]}
        with mock.patch.object(update, "run", side_effect=["", json.dumps(output), json.dumps(dependencies), ""]) as process:
            updates = updater.pub_updates(["coverage"])
            updater.update_pub(updates)
        self.assertEqual(updates, {"coverage": ("1.17.0", "dev")})
        self.assertIn("dev:coverage@1.17.0", process.call_args.args[0])

    def test_android_library_update_preserves_build_plugins(self):
        path = self.root / "android/app/build.gradle.kts"
        source = 'plugins { id("com.android.application") }\nimplementation("androidx.work:work-runtime:2.12.0")\n'
        path.write_text(source)
        update.Updater(self.root).update_android({"androidx.work:work-runtime": "2.13.0"})
        self.assertEqual(path.read_text(), source.replace("2.12.0", "2.13.0"))

    def test_android_selection_falls_back_to_sdk_compatible_formal_version(self):
        path = self.root / "android/app/build.gradle.kts"
        source = 'implementation("androidx.work:work-runtime:2.12.0")\n'
        path.write_text(source)
        metadata = (b"<metadata><versioning><versions><version>2.12.0</version>"
                    b"<version>2.13.0</version><version>2.14.0</version>"
                    b"<version>2.15.0-alpha01</version></versions></versioning></metadata>")
        with mock.patch.object(update, "fetch", return_value=metadata), mock.patch.object(
                update, "run", side_effect=["", ValueError("uses-sdk:minSdkVersion 24 cannot be smaller than 26"), ""]):
            result = update.Updater(self.root).android_updates(["androidx.work:work-runtime"])
        self.assertEqual(result, {"androidx.work:work-runtime": "2.13.0"})
        self.assertEqual(path.read_text(), source)

    def test_android_resolution_failure_is_not_treated_as_sdk_incompatibility(self):
        path = self.root / "android/app/build.gradle.kts"
        source = 'implementation("example:library:1.0.0")\n'
        path.write_text(source)
        metadata = b"<metadata><versioning><versions><version>2.0.0</version></versions></versioning></metadata>"
        with mock.patch.object(update, "fetch", return_value=metadata), mock.patch.object(
                update, "run", side_effect=["", ValueError("repository unavailable")]):
            with self.assertRaisesRegex(ValueError, "repository unavailable"):
                update.Updater(self.root).android_updates(["example:library"])
        self.assertEqual(path.read_text(), source)

    def test_pub_sdk_and_path_packages_keep_their_sources(self):
        for name, source in (("flutter", "sdk"), ("re_editor", "path")):
            outdated = {"packages": [{"package": name, "kind": "direct", "current": {"version": "1.0.0"},
                                      "resolvable": {"version": "2.0.0"}}]}
            dependencies = {"packages": [{"name": name, "source": source}]}
            with self.subTest(name=name), mock.patch.object(
                    update, "run", side_effect=["", json.dumps(outdated), json.dumps(dependencies)]):
                with self.assertRaisesRegex(ValueError, "hosted 直接依赖"):
                    update.Updater(self.root).pub_updates([name])

    def test_evidence_build_failure_is_reported(self):
        updater = update.Updater(self.root)
        with mock.patch.object(update, "prepare_bundled_assets", return_value=self.generated) as prepare, \
                mock.patch.object(updater, "graph"), mock.patch.object(updater, "android_graph", return_value="graph"), \
                mock.patch.object(update, "run", side_effect=ValueError("asset build failed")):
            with self.assertRaisesRegex(ValueError, "asset build failed"):
                updater.evidence(self.base / "evidence")
        prepare.assert_called_once_with(self.root)

    def test_cli_rejects_removed_manual_tag_and_version_only_arguments(self):
        for arguments in (["--check", "--version-only", "--bump", "minor"],
                          ["--apply", "--version-only"], ["--apply", "--mihomo-tag", "v1.19.33"]):
            with self.subTest(arguments=arguments), redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit) as error:
                update.main(arguments)
            self.assertEqual(error.exception.code, 2)

    def test_cli_reports_failure(self):
        output = io.StringIO()
        with mock.patch.object(update, "execute", side_effect=ValueError("license conflict")), redirect_stderr(output):
            self.assertEqual(update.main(["--apply"]), 1)
        self.assertEqual(json.loads(output.getvalue())["error"], "license conflict")


class SourceNoticeTest(unittest.TestCase):
    """核对锁定 Go 解析结果、生产依赖和本地 PSL 原字节。"""

    @classmethod
    def setUpClass(cls):
        environment = mock.patch.dict(os.environ, {"GOPROXY": "off", "GOSUMDB": "off"})
        environment.start()
        cls.addClassCleanup(environment.stop)
        temporary = tempfile.TemporaryDirectory(prefix="source-notices-")
        cls.addClassCleanup(temporary.cleanup)
        cls.updater = update.Updater(ROOT)
        cls.graph = cls.updater.graph(Path(temporary.name) / "modules.json")
        cls.legal = cls.updater.legal(Path(temporary.name))

    def test_go_notice_matches_every_effective_production_module(self):
        text = (ROOT / "third_party/notices/go.txt").read_bytes().decode("utf-8")
        entries = re.findall(r"^={20,}\n(\S+) (v\S+)\n", text, re.M)
        expected = {}
        for name in self.legal.production_modules():
            module = self.graph[name]
            if module.get("Main"):
                continue
            effective = module.get("Replace") or module
            expected[effective["Path"]] = effective["Version"]
        self.assertEqual(len(entries), len(expected))
        self.assertEqual(len({name for name, _ in entries}), len(entries))
        self.assertEqual(dict(entries), expected)
        for attribution in ("tempfork/goupnp/LICENSE", "third_party/svgpan/LICENSE",
                            "Additional IP Rights Grant (Patents)"):
            with self.subTest(attribution=attribution):
                self.assertIn(attribution, text)

    def test_psl_notice_matches_selected_compiled_table_and_original_list(self):
        source = self.legal.public_suffix_source(self.graph)
        selected = self.graph["golang.org/x/net"]
        effective = selected.get("Replace") or selected
        table = (Path(effective["Dir"]) / "publicsuffix/table.go").read_bytes().decode("utf-8")
        revision = re.search(r"git revision ([0-9a-f]{40})", table)[1]
        self.assertEqual(source["module"], effective["Path"])
        self.assertEqual(source["moduleVersion"], effective["Version"])
        self.assertEqual(source["revision"], revision)
        raw = (ROOT / "third_party/notices/publicsuffix.txt").read_bytes()
        notice = raw.decode("utf-8")
        self.assertIn(f"{effective['Path']} {effective['Version']}；PSL {revision}\n", notice)
        self.assertIn(f"https://github.com/publicsuffix/list/blob/{revision}/public_suffix_list.dat", notice)
        data = (ROOT / "third_party/data/publicsuffix/public_suffix_list.dat").read_bytes()
        self.assertIn(b"BEGIN ICANN DOMAINS", data)
        self.assertIn(b"END PRIVATE DOMAINS", data)
        self.assertEqual(re.findall(r"^列表 SHA-256：([0-9a-f]{64})$", notice, re.M),
                         [hashlib.sha256(data).hexdigest()])
        self.assertIn("Mozilla Public", notice)
        self.assertIn("MPL-2.0", notice)
        self.assertTrue(raw.endswith((ROOT / "third_party/data/certificates/MPL-2.0.txt").read_bytes()))


class LegalTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        updater = mock.Mock(root=self.root, go="go")
        self.process = mock.Mock()
        self.legal = legal.Legal(updater, self.root, mock.Mock(), self.process, update.artifacts)

    def classifier(self, names):
        def result(command, cwd):
            output = Path(command[command.index("-json") + 1])
            paths = command[command.index("-json") + 2:]
            output.write_text(json.dumps([{"Filepath": str(path), "Classifications":
                                          [{"Name": name} for name in names]} for path in paths]))
        self.process.side_effect = result

    def test_unchanged_original_license_is_reused(self):
        data = b"original bytes\n"
        self.legal.check({"LICENSE": data}, "SHA-256 " + legal.sha(data))
        self.process.assert_not_called()

    def test_normal_copyright_or_license_text_change_is_automatically_classified(self):
        self.classifier(["Copyright", "MIT"])
        self.legal.check({"LICENSE": b"new copyright year and MIT text\n"})
        self.process.assert_called_once()
        self.assertIn(legal.CLASSIFIER, self.process.call_args.args[0])

    def test_missing_unknown_and_conflicting_licenses_fail(self):
        with self.assertRaisesRegex(ValueError, "缺少许可授权正文"):
            self.legal.check({"AUTHORS": b"name"})
        for names in ([], ["Copyright"], ["GPL-2.0"], ["proprietary"]):
            self.classifier(names)
            with self.subTest(names=names), self.assertRaisesRegex(ValueError, "许可需要技术复核"):
                self.legal.check({"LICENSE": b"source license"})

    def test_lzo_or_later_authorization_allows_gplv3_combination(self):
        self.classifier(["GPL-2.0"])
        self.legal.check({"LICENSE.gpl": b"GPLv2"}, gpl2_later=True)

    def test_sections_preserve_original_text_and_raw_bytes(self):
        original = "intro\n" + legal.SEPARATOR + "example.org/module v1.0.0\nraw license\n"
        prefix, blocks = legal.sections(original, r"[\w./]+ v[^\s]+")
        self.assertEqual(prefix, "intro\n")
        self.assertEqual(prefix + blocks["example.org/module v1.0.0"], original)
        self.assertIn("original\r\n", legal.render_files({"LICENSE": b"original\r\n"}))

    def test_nested_archive_notices_and_source_headers_are_retained_without_extraction(self):
        nested = io.BytesIO()
        with zipfile.ZipFile(nested, "w") as archive:
            archive.writestr("META-INF/NOTICE", "notice")
        outer = io.BytesIO()
        with zipfile.ZipFile(outer, "w") as archive:
            archive.writestr("classes.jar", nested.getvalue())
            archive.writestr("example/A.java", "/* Copyright Owner. Licensed under Apache. */\nclass A {}")
            archive.writestr("../json.py", "raise RuntimeError('never execute')")
        files = legal.archive_legal(outer.getvalue())
        self.assertEqual(files["classes.jar!/META-INF/NOTICE"], b"notice")
        self.assertIn("example/A.java（许可头）", files)
        self.assertFalse((self.root / "json.py").exists())

    def test_legal_files_keep_subdirectory_licenses_and_copyrights(self):
        (self.root / "LICENSE").write_bytes(b"root\n")
        sub = self.root / "sub"
        sub.mkdir()
        (sub / "COPYING.txt").write_bytes(b"sub license\n")
        (sub / "code.go").write_text("// Copyright 2026 Owner.\npackage sub\n")
        files = legal.legal_files(self.root)
        self.assertEqual(files["sub/COPYING.txt"], b"sub license\n")
        self.assertEqual(files["源码版权行"], b"// Copyright 2026 Owner.\n")


if __name__ == "__main__":
    unittest.main()
