"""本地依赖更新、应用版本及许可材料回归。"""

import argparse
from contextlib import redirect_stdout, redirect_stderr
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile


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
                        {"tag_name": "v1.19.33-rc1"}, {"tag_name": "v1.19.34"}):
            with mock.patch.object(update, "fetch", return_value=json.dumps(release).encode()), self.assertRaises(ValueError):
                update.mihomo_release("v1.19.33")


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
        (self.root / "pubspec.yaml").write_text("name: sample\nversion: 1.0.0+1\n")
        (self.root / "pubspec.lock").write_text("existing lock\n")
        (self.root / "native/mihomo/go.mod").write_text("existing go.mod\n")
        subprocess.run(["git", "init", "-q", self.root], check=True, capture_output=True)
        subprocess.run(["git", "-C", self.root, "add", "."], check=True, capture_output=True)
        self.updater = mock.Mock()
        self.updater.go_updates.return_value = {update.MIHOMO: "v1.19.33"}
        self.updater.pub_updates.return_value = {}
        self.updater.android_updates.return_value = {}

    def arguments(self, **values):
        defaults = dict(project=self.root, go="go", flutter="flutter", go_module=[], pub=[], android=[],
                        mihomo_tag="v1.19.33", apply=True, check=False, evidence=None,
                        bump="patch", reuse_version=False, version_only=False)
        defaults.update(values)
        return argparse.Namespace(**defaults)

    def execute(self, **values):
        with mock.patch.object(update, "Updater", return_value=self.updater):
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
        self.assertEqual(result["files"], ["pubspec.yaml"])
        self.updater.legal.return_value.go_notices.assert_called_once()

    def test_no_update_and_retry_preserve_determined_version(self):
        (self.root / "pubspec.yaml").write_text("version: 1.1.0+2\n")
        self.updater.go_updates.return_value = {}
        result = self.execute()
        self.assertEqual(result["status"], "unchanged")
        self.assertEqual(result["version"], "1.1.0+2")
        self.assertEqual(result["files"], [])

    def test_additional_kernel_update_does_not_stack_pending_release_version(self):
        (self.root / "pubspec.yaml").write_text("version: 1.1.0+2\n")
        result = self.execute(reuse_version=True)
        self.assertEqual(result["version"], "1.1.0+2")
        self.assertEqual(result["files"], [])

    def test_app_only_release_uses_same_entry_and_skips_default_kernel_query(self):
        self.updater.go_updates.return_value = {}
        result = self.execute(version_only=True, mihomo_tag=None, bump="major")
        self.assertEqual(result["version"], "2.0.0+2")
        self.updater.go_updates.assert_called_once_with([], None)
        self.updater.legal.assert_not_called()

    def test_first_stable_uses_real_version_writer_and_major_rejection_preserves_inputs(self):
        (self.root / "pubspec.yaml").write_text("version: 0.7.9+42\n")
        before = update.snapshot(self.root)
        with self.assertRaisesRegex(ValueError, "明确选择 stable"):
            self.execute(bump="major")
        self.assertEqual(update.snapshot(self.root), before)
        self.updater.go_updates.return_value = {}
        result = self.execute(version_only=True, mihomo_tag=None, bump="stable")
        self.assertEqual(result["version"], "1.0.0+43")
        self.assertEqual((self.root / "pubspec.yaml").read_text(), "version: 1.0.0+43\n")
        self.assertEqual(result["files"], ["pubspec.yaml"])
        self.updater.go_updates.assert_called_with([], None)
        self.assertEqual((self.root / "pubspec.lock").read_text(), "existing lock\n")

    def test_development_no_update_and_pending_retry_keep_version_and_android_code(self):
        (self.root / "pubspec.yaml").write_text("version: 0.1.0+3\n")
        result = self.execute(reuse_version=True)
        self.assertEqual(result["version"], "0.1.0+3")
        self.assertEqual(result["files"], [])
        self.updater.go_updates.return_value = {}
        result = self.execute()
        self.assertEqual(result["status"], "unchanged")
        self.assertEqual(result["version"], "0.1.0+3")
        self.assertEqual(result["files"], [])

    def test_resolution_or_license_failure_preserves_inputs(self):
        before = update.snapshot(self.root)
        for operation in (self.updater.update_go, self.updater.legal.return_value.go_notices):
            with self.subTest(operation=operation):
                operation.side_effect = ValueError("specific failure")
                with self.assertRaisesRegex(ValueError, "specific failure"):
                    self.execute()
                self.assertEqual(update.snapshot(self.root), before)
                operation.side_effect = None

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

    def test_go_toolchain_and_replace_changes_stop_before_writeback(self):
        before = {"Go": "1.27.1", "Require": [], "Replace": [{"Old": "protobuf", "New": "fork"}]}
        updater = update.Updater(self.root)
        after = dict(before, Go="1.28.0")
        with mock.patch.object(updater, "go_run", side_effect=[json.dumps(before), "", "", json.dumps(after)]):
            with self.assertRaisesRegex(ValueError, "工具链或 replace"):
                updater.update_go({update.MIHOMO: "v1.19.33"})

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
        with mock.patch.object(updater, "graph"), mock.patch.object(updater, "android_graph", return_value="graph"), \
                mock.patch.object(update, "run", side_effect=ValueError("asset build failed")):
            with self.assertRaisesRegex(ValueError, "asset build failed"):
                updater.evidence(self.base / "evidence")

    def test_cli_rejects_version_preparation_in_check_mode(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            update.main(["--check", "--version-only", "--bump", "minor"])
        self.assertEqual(error.exception.code, 2)

    def test_cli_reports_failure(self):
        output = io.StringIO()
        with mock.patch.object(update, "execute", side_effect=ValueError("license conflict")), redirect_stderr(output):
            self.assertEqual(update.main(["--apply"]), 1)
        self.assertEqual(json.loads(output.getvalue())["error"], "license conflict")


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
