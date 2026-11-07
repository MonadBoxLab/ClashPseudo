"""Test dependency updates, application version increments, and license collection."""

import argparse
from contextlib import redirect_stdout, redirect_stderr
import tool_test_support
from tool.dependencies import update, resources, sources, versions, packages, inputs, legal
from tool.common import io as common_io, workspace, process
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


class VersionTest(unittest.TestCase):
    def test_patch_and_android_code_increment_once(self):
        text, value = versions.bump_version("name: sample\nversion: 1.0.0+1\n")
        self.assertEqual(value, "1.0.1+2")
        self.assertEqual(text, "name: sample\nversion: 1.0.1+2\n")

    def test_declaration_read_preserves_publisher_version_policy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "pubspec.yaml").write_text('version: "2.3.4+2100000000" # 应用声明\n')
            self.assertEqual(versions.application_version(root), "2.3.4+2100000000")
            text, value = versions.bump_version((root / "pubspec.yaml").read_text())
            self.assertEqual(value, "2.3.5+2100000001")
            self.assertIn('# 应用声明', text)

    def test_official_latest_tag_is_used_without_a_second_version_policy(self):
        for selector in ("v1.0.0", "preview-next", "release/next"):
            with self.subTest(selector=selector), mock.patch.object(
                    packages, "fetch", return_value=json.dumps({"tag_name": selector}).encode()) as fetch:
                self.assertEqual(packages.mihomo_release(), selector)
                fetch.assert_called_once_with("https://api.github.com/repos/MetaCubeX/mihomo/releases/latest")


class UpdateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "project"
        self.root.mkdir()
        for name in inputs.INPUTS:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("existing " + name + "\n")
        (self.root / ".gitignore").write_text("build/\n")
        (self.root / "pubspec.yaml").write_text(
            "name: sample\nversion: 1.0.0+1\n\ndependencies:\n"
            "  flutter:\n    sdk: flutter\n  http: ^1.0.0\n"
            "  re_editor:\n    path: third_party/sources/re_editor\n"
            "dev_dependencies:\n  coverage: ^1.0.0\n")
        (self.root / "pubspec.lock").write_text("existing lock\n")
        (self.root / "native/mihomo/go.mod").write_text(
            "module example.test/app\n\ngo 1.0.0\n\nrequire (\n"
            f"\t{packages.MIHOMO} v1.0.0\n\tgolang.org/x/net v1.0.0\n)\n")
        (self.root / "android/app/build.gradle.kts").write_text(
            'plugins { id("com.android.application") }\n'
            'implementation("androidx.work:work-runtime:1.0.0")\n')
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
                 processing=sources.GEOIP_DATA_PROCESSING,
                 inputs=[source("geoip", "2" * 40, "geoip-inputs.tar.gz", "合成 GeoIP 补充输入")]),
            dict(source("geosite", "3" * 40, "geosite.tar.gz"), kind="geosite"),
        ]}
        self.source_manifest = self.source_directory / "resource-sources.json"
        self.source_manifest.write_bytes(common_io.json_bytes(self.sources))
        self.record, self.generated = frozen_resources(self.root, resources, source_metadata=self.sources)
        self.record["application"] = "1.0.0+1"
        for path in (self.root / resources.RESOURCE_RECORD, self.generated / "resources.json"):
            path.write_bytes(common_io.json_bytes(self.record))
        self.prepared = self.base / "resources"
        resources.prepare_resources(list(self.record["resources"].values()), self.prepared, {
            kind: self.generated / "assets" / name for kind, name in resources.RESOURCE_ASSETS.items()})
        subprocess.run(["git", "init", "-q", self.root], check=True, capture_output=True)
        subprocess.run(["git", "-C", self.root, "add", "."], check=True, capture_output=True)
        self.updater = mock.Mock()
        self.manifest = {"Go": "1.0.0", "Require": [
            {"Path": packages.MIHOMO, "Version": "v1.0.0"},
            {"Path": "golang.org/x/net", "Version": "v1.0.0"},
            {"Path": "github.com/rasky/go-lzo", "Version": "v1.0.0", "Indirect": True},
            {"Path": "github.com/metacubex/chacha", "Version": "v1.0.0", "Indirect": True},
        ], "Replace": []}
        self.updater.pub_updates.return_value = {}
        self.updater.android_updates.return_value = {}
        self.target = "v1.0.1"
        self.toolchains = {"format": "clash-pseudo-toolchains", "version": 1, "minSdk": 24,
                           "selected": {"go": {"version": "go1.0.0"}}, "documents": ["old"]}
        self.record["toolchains"] = self.toolchains
        self.record["dependencies"] = {"go": {packages.MIHOMO: {"selected": "v1.0.0"},
                                               "golang.org/x/net": {"selected": "v1.0.0"}}, "pub": {}, "android": {}}
        (self.root / resources.RESOURCE_RECORD).write_bytes(common_io.json_bytes(self.record))
        self.environment = {"PATH": "/fixture/flutter/bin:/fixture/go/bin:" + os.environ["PATH"],
                            "CLASH_TOOLCHAIN_FIXTURE": "stable"}
        self.bootstrap = mock.Mock()
        self.bootstrap.prepare.return_value = (self.environment, {"fixture": "measured"})
        self.updater.update_go.side_effect = self.write_go
        self.updater.update_pub.side_effect = self.write_pub
        self.updater.update_android.side_effect = self.write_android

    def write_go(self, changes):
        path = self.work / "native/mihomo/go.mod"
        text = path.read_text()
        for name, version in changes.items():
            text = re.sub(re.escape(name) + r"\s+v[^\s]+", name + " " + version, text)
        path.write_text(text)

    def write_pub(self, changes):
        if changes:
            (self.work / "pubspec.lock").write_text(json.dumps(changes))

    def write_android(self, changes):
        packages.Updater(self.work).update_android(changes)

    def execute(self, **values):
        defaults = dict(apply=True, toolchain_cache=self.base / "cache")
        defaults.update(values)
        before_environment = dict(os.environ)

        def create_updater(work, go, flutter, *, env):
            self.work = work
            self.updater.root, self.updater.go, self.updater.flutter = work, go, flutter
            self.assertEqual(env, self.environment)
            self.assertEqual(dict(os.environ), before_environment)
            self.assertEqual(go, "/fixture/go/bin/go")
            self.assertEqual(flutter, "/fixture/flutter/bin/flutter")
            current = re.search(re.escape(packages.MIHOMO) + r"\s+(v[^\s]+)",
                                (work / "native/mihomo/go.mod").read_text())[1]
            self.updater.go_updates.return_value = {} if current == self.target else {packages.MIHOMO: self.target}
            self.updater.resolution = {
                "go": {packages.MIHOMO: {"previous": current, "selected": self.target}},
                "pub": {}, "android": {},
            }
            def go_run(*arguments):
                manifest = json.loads(json.dumps(self.manifest))
                text = (work / "native/mihomo/go.mod").read_text()
                for row in manifest["Require"]:
                    match = re.search(re.escape(row["Path"]) + r"\s+(v[^\s]+)", text)
                    if match:
                        row["Version"] = match[1]
                if arguments[:5] == ("list", "-mod=readonly", "-m", "-f", "{{.Version}}"):
                    return next(row["Version"] for row in manifest["Require"] if row["Path"] == packages.MIHOMO)
                return json.dumps(manifest)
            self.updater.go_run.side_effect = go_run
            return self.updater

        with mock.patch.object(update, "Updater", side_effect=create_updater), \
                mock.patch.object(update, "toolchains", self.bootstrap), \
                mock.patch.object(update, "mihomo_release", return_value=self.target), \
                mock.patch.object(sources, "delivery_resources", return_value={
                    "prepared": self.prepared, "sources": self.source_manifest}), \
                mock.patch.object(resources, "prepare_bundled_assets"):
            result = update.execute(self.root, **defaults)
        self.assertEqual(dict(os.environ), before_environment)
        return result

    def test_check_resolves_full_candidate_without_writing_project_or_index(self):
        before = inputs.snapshot(self.root)
        index = (self.root / ".git/index").read_bytes()
        result = self.execute(apply=False)
        self.assertEqual(result["status"], "available")
        self.assertEqual(inputs.snapshot(self.root), before)
        self.assertEqual((self.root / ".git/index").read_bytes(), index)
        self.updater.update_go.assert_called_once()
        self.updater.legal.return_value.go_notices.assert_called_once()
        self.updater.pub_updates.assert_called_once_with([])
        self.updater.android_updates.assert_called_once_with(["androidx.work:work-runtime"])

    def test_noop_apply_does_not_bump_or_write_diagnostic_differences(self):
        self.target = "v1.0.0"
        self.record["toolchains"]["selected"]["actions"] = {"actions/checkout": {"commit": "old"}}
        self.record["dependencies"]["go"][packages.MIHOMO]["previous"] = "v0.9.0"
        (self.root / resources.RESOURCE_RECORD).write_bytes(common_io.json_bytes(self.record))
        before = inputs.snapshot(self.root)
        for _ in range(2):
            result = self.execute()
            self.assertEqual(result["status"], "unchanged")
            self.assertEqual(result["files"], [])
            self.assertEqual(result["version"], "1.0.0+1")
            self.assertEqual(inputs.snapshot(self.root), before)

    def test_real_update_defaults_to_one_patch_and_retry_is_unchanged(self):
        result = self.execute()
        self.assertEqual(result["version"], "1.0.1+2")
        self.assertEqual(result["files"], ["native/mihomo/go.mod", "pubspec.yaml", resources.RESOURCE_RECORD])
        self.assertEqual(self.execute()["status"], "unchanged")
        self.assertEqual(versions.application_version(self.root), "1.0.1+2")

    def test_check_and_apply_choose_the_same_candidate_version(self):
        checked = self.execute(apply=False)
        applied = self.execute()
        self.assertEqual(checked["version"], applied["version"])
        self.assertEqual(checked["files"], applied["files"])


    def test_reuse_version_preserves_pending_version_with_dependency_change(self):
        result = self.execute(reuse_version=True)
        self.assertEqual(result["version"], "1.0.0+1")
        self.assertNotIn("pubspec.yaml", result["files"])


    def test_mihomo_scope_uses_fixed_inputs_and_does_not_query_other_ecosystems(self):
        before = inputs.snapshot(self.root)
        result = self.execute(scope="mihomo", reuse_version=True)
        self.bootstrap.resolve.assert_not_called()
        self.bootstrap.apply_versions.assert_not_called()
        self.bootstrap.freeze_archives.assert_not_called()
        self.updater.pub_updates.assert_not_called()
        self.updater.android_updates.assert_not_called()
        self.updater.legal.return_value.pub_licenses.assert_not_called()
        self.updater.legal.return_value.android_notices.assert_not_called()
        self.assertEqual(result["go"], {packages.MIHOMO: self.target})
        after = inputs.snapshot(self.root)
        for name in inputs.INPUTS:
            if name not in ("native/mihomo/go.mod", resources.RESOURCE_RECORD):
                self.assertEqual(after[name], before[name], name)
        record = resources.read_release_resources(self.root)
        for key in ("resources", "toolchains", "sourceInputs", "licenses"):
            self.assertEqual(record[key], self.record[key])

    def test_explicit_older_release_is_allowed_only_in_mihomo_scope(self):
        self.target = "v0.9.0"
        result = self.execute(scope="mihomo", mihomo_version=self.target, reuse_version=True)
        self.assertEqual(result["mihomo"], {"previous": "v1.0.0", "selected": self.target})
        self.updater.go_updates.assert_called_once_with([packages.MIHOMO], self.target)
        with self.assertRaisesRegex(ValueError, "requires --scope mihomo"):
            update.execute(self.root, mihomo_version=self.target)

    def test_invalid_scope_combination_fails_before_release_lookup(self):
        for options in ({"scope": "other"}, {"scope": "mihomo", "pub": ["http"]}):
            with self.subTest(options=options), mock.patch.object(update, "mihomo_release") as release:
                with self.assertRaises(ValueError):
                    update.execute(self.root, **options)
                release.assert_not_called()

    def test_ca_only_change_is_detected_and_bumped(self):
        self.target = "v1.0.0"
        candidate = json.loads(json.dumps(self.record))
        candidate["resources"]["ca"]["version"] = "2026-11-01"
        candidate["resources"]["ca"]["sourceUrl"] = "https://curl.se/ca/cacert-2026-11-01.pem"
        with mock.patch.object(sources, "resource_changes", return_value={resources.RESOURCE_RECORD: common_io.json_bytes(candidate)}):
            result = self.execute()
        self.assertEqual(result["go"], {})
        self.assertEqual(set(result["resources"]), {"ca"})
        self.assertEqual(result["version"], "1.0.1+2")

    def test_pub_only_lock_change_is_detected_without_new_mihomo(self):
        self.target = "v1.0.0"
        self.updater.pub_updates.return_value = {"http": ("1.1.0", "direct")}
        result = self.execute()
        self.assertEqual(result["go"], {})
        self.assertIn("pubspec.lock", result["files"])
        self.assertEqual(result["version"], "1.0.1+2")

    def test_resolution_and_license_failure_preserve_project_and_environment(self):
        before = inputs.snapshot(self.root)
        for operation in (self.updater.update_go, self.updater.legal.return_value.go_notices):
            prior = operation.side_effect
            operation.side_effect = ValueError("具体失败")
            with self.assertRaisesRegex(ValueError, "具体失败"):
                self.execute()
            self.assertEqual(inputs.snapshot(self.root), before)
            operation.side_effect = prior

    def test_evidence_failure_precedes_all_project_writeback(self):
        before = inputs.snapshot(self.root)
        self.updater.evidence.side_effect = ValueError("evidence failed")
        with self.assertRaisesRegex(ValueError, "evidence failed"):
            self.execute(evidence=self.base / "evidence")
        self.assertEqual(inputs.snapshot(self.root), before)

    def test_environment_is_explicit_and_separate_between_runs(self):
        self.execute(apply=False)
        self.environment["CLASH_TOOLCHAIN_FIXTURE"] = "second"
        self.execute(apply=False)
        self.assertNotIn("CLASH_TOOLCHAIN_FIXTURE", os.environ)

    def test_source_change_stops_writeback(self):
        source = self.root / "user.txt"
        source.write_text("initial")
        before = inputs.snapshot(self.root)
        def change(_names):
            source.write_text("concurrent")
            return {}
        self.updater.pub_updates.side_effect = change
        with self.assertRaisesRegex(ValueError, "Working tree changed"):
            self.execute()
        self.assertEqual(inputs.snapshot(self.root), before)
        self.assertEqual(source.read_text(), "concurrent")

    def test_concurrent_change_is_not_overwritten(self):
        before = inputs.snapshot(self.root)
        after = dict(before, **{"pubspec.yaml": b"version: 1.0.1+2\n"})
        (self.root / "pubspec.yaml").write_text("version: 7.0.0+12\n")
        with self.assertRaisesRegex(ValueError, "File changed during update"):
            inputs.publish_changes(self.root, before, after)
        self.assertEqual((self.root / "pubspec.yaml").read_text(), "version: 7.0.0+12\n")

    def test_only_owned_updated_inputs_are_written(self):
        path = self.root / "user.txt"
        path.write_text("keep")
        before = inputs.snapshot(self.root)
        after = dict(before, **{"native/mihomo/go.mod": b"updated\n"})
        self.assertEqual(inputs.publish_changes(self.root, before, after), ["native/mihomo/go.mod"])
        self.assertEqual(path.read_text(), "keep")

    def test_deleted_tracked_file_is_not_resurrected(self):
        path = self.root / "pubspec.lock"
        path.unlink()
        destination = self.base / "copy"
        destination.mkdir()
        workspace.copy_workspace(self.root, destination)
        self.assertFalse((destination / "pubspec.lock").exists())

    def test_go_toolchain_and_transitive_changes_keep_the_selected_target(self):
        before = json.loads(json.dumps(self.manifest))
        before["Require"][1]["Indirect"] = True
        updater = packages.Updater(self.root)
        for toolchain in ({"Go": "1.0.1"}, {"Toolchain": "go1.0.1"},
                          {"Go": "1.0.1", "Toolchain": "go1.0.1"}):
            after = dict(before, **toolchain, Require=[
                dict(row, Version="v1.0.1" if row["Path"] == packages.MIHOMO else
                     "v1.0.1" if row["Path"] == "golang.org/x/net" else row["Version"])
                for row in before["Require"]] + [
                    {"Path": "example.test/transitive", "Version": "v1.0.0", "Indirect": True}])
            with self.subTest(toolchain=toolchain), mock.patch.object(
                    updater, "go_run", side_effect=[json.dumps(before), "", "", "", json.dumps(after)]) as process:
                updater.update_go({packages.MIHOMO: "v1.0.1"})
            self.assertEqual(process.call_args_list, [
                mock.call("mod", "edit", "-json"), mock.call("get", packages.MIHOMO + "@v1.0.1"),
                mock.call("mod", "tidy"), mock.call("mod", "verify"), mock.call("mod", "edit", "-json")])

    def test_go_replace_changes_stop_before_writeback(self):
        original = [{"Old": {"Path": "google.golang.org/protobuf"},
                     "New": {"Path": "github.com/metacubex/protobuf", "Version": "v1.0.0"}}]
        before = dict(self.manifest, Replace=original)
        snapshot = inputs.snapshot(self.root)
        updater = packages.Updater(self.root)
        for replacement in ([], [{"Old": original[0]["Old"], "New": {"Path": "example.test/replacement"}}],
                            [{"Old": original[0]["Old"],
                              "New": {"Path": "github.com/metacubex/protobuf", "Version": "v1.0.1"}}]):
            after = dict(before, Replace=replacement)
            with self.subTest(replacement=replacement), mock.patch.object(
                    updater, "go_run", side_effect=[json.dumps(before), "", "", "", json.dumps(after)]):
                with self.assertRaisesRegex(ValueError, "Go replace changed"):
                    updater.update_go({packages.MIHOMO: "v1.0.1"})
            self.assertEqual(inputs.snapshot(self.root), snapshot)

    def test_go_license_modules_remain_required(self):
        updater = packages.Updater(self.root)
        snapshot = inputs.snapshot(self.root)
        for missing in ("github.com/rasky/go-lzo", "github.com/metacubex/chacha"):
            after = dict(self.manifest, Require=[
                dict(row, Version="v1.0.1" if row["Path"] == packages.MIHOMO else row["Version"])
                for row in self.manifest["Require"] if row["Path"] != missing])
            message = "License version constraint is missing: " + missing
            with self.subTest(missing=missing), mock.patch.object(
                    updater, "go_run", side_effect=[json.dumps(self.manifest), "", "", "", json.dumps(after)]):
                with self.assertRaisesRegex(ValueError, message):
                    updater.update_go({packages.MIHOMO: "v1.0.1"})
            self.assertEqual(inputs.snapshot(self.root), snapshot)

    def test_pub_uses_resolvable_version_and_preserves_dev_section(self):
        updater = packages.Updater(self.root)
        output = {"packages": [{"package": "coverage", "kind": "dev", "current": {"version": "1.0.0"},
                                "resolvable": {"version": "1.0.1"}, "latest": {"version": "2.0.0"}}]}
        dependencies = {"packages": [{"name": "coverage", "source": "hosted", "version": "1.0.0"}]}
        with mock.patch.object(packages, "run", side_effect=["", json.dumps(output), json.dumps(dependencies), "",
                    json.dumps({"packages": [{"name": "coverage", "version": "1.0.2"}]}), ""]) as process:
            updates = updater.pub_updates(["coverage"])
            updater.update_pub(updates)
        self.assertEqual(updates, {"coverage": ("1.0.2", "dev")})
        self.assertEqual(updater.resolution["pub"]["coverage"]["selected"], "1.0.2")
        self.assertIn("dev:coverage@^1.0.1", process.call_args_list[3].args[0])

    def test_android_library_update_preserves_build_plugins(self):
        path = self.root / "android/app/build.gradle.kts"
        source = 'plugins { id("com.android.application") }\nimplementation("androidx.work:work-runtime:1.0.0")\n'
        path.write_text(source)
        packages.Updater(self.root).update_android({"androidx.work:work-runtime": "1.0.1"})
        self.assertEqual(path.read_text(), source.replace("1.0.0", "1.0.1"))

    def test_android_uses_gradle_latest_release_and_records_fixed_result(self):
        path = self.root / "android/app/build.gradle.kts"
        original = ('implementation("example:library:1.0")\n'
                    'testImplementation("example:tests:old")\n'
                    'androidTestImplementation("example:runner:old")\n')
        path.write_text(original)
        updater = packages.Updater(self.root, env={"CLASH_GRADLE": "/fixed/gradle"})
        def run(command, cwd, env):
            if command[1:3] == ["pub", "get"]:
                return ""
            self.assertEqual(command[0], "/fixed/gradle")
            self.assertNotIn("Release", command[-1])
            self.assertEqual(path.read_text().count(":latest.release"), 3)
            script = Path(command[command.index("--init-script") + 1]).read_text()
            for configuration in ("releaseRuntimeClasspath", "debugUnitTestRuntimeClasspath", "debugAndroidTestRuntimeClasspath"):
                self.assertIn(configuration, script)
            return 'CLASH_DEPENDENCIES={"example:library":"release-next","example:tests":"2","example:runner":"3"}\n'
        with mock.patch.object(packages, "run", side_effect=run):
            updates = updater.android_updates(["example:library", "example:tests", "example:runner"])
        self.assertEqual(updates, {"example:library": "release-next", "example:tests": "2", "example:runner": "3"})
        self.assertEqual(path.read_text(), original)
        updater.update_android(updates)
        self.assertNotIn("latest.release", path.read_text())
        self.assertIn('example:library:release-next', path.read_text())

    def test_gradle_failure_is_preserved_without_trying_an_older_candidate(self):
        path = self.root / "android/app/build.gradle.kts"
        original = 'implementation("example:library:1.0")\n'
        path.write_text(original)
        failure = ValueError("Gradle 原始不兼容错误")
        with mock.patch.object(packages, "run", side_effect=["", failure]) as run:
            with self.assertRaises(ValueError) as caught:
                packages.Updater(self.root).android_updates(["example:library"])
        self.assertIs(caught.exception, failure)
        self.assertEqual(run.call_count, 2)
        self.assertEqual(path.read_text(), original)

    def test_go_selector_is_passed_unchanged_and_normalized_by_go(self):
        updater = packages.Updater(self.root)
        after = json.loads(json.dumps(self.manifest))
        after["Require"][0]["Version"] = "v1.0.1-0.20000101000000-123456789abc"
        for selector in ("feature/next", "latest", "123456789abc", "v1.0.1-rc.1"):
            with self.subTest(selector=selector), mock.patch.object(updater, "go_run", side_effect=[
                    json.dumps(self.manifest), "", "", "", json.dumps(after)]) as run:
                updater.update_go({packages.MIHOMO: selector})
                self.assertEqual(run.call_args_list[1], mock.call("get", packages.MIHOMO + "@" + selector))
                self.assertEqual(updater.resolution["go"][packages.MIHOMO]["selected"], after["Require"][0]["Version"])

    def test_go_command_error_is_preserved(self):
        updater = packages.Updater(self.root)
        failure = ValueError("go: unknown revision feature/missing")
        with mock.patch.object(updater, "go_run", side_effect=[json.dumps(self.manifest), failure]):
            with self.assertRaises(ValueError) as caught:
                updater.update_go({packages.MIHOMO: "feature/missing"})
        self.assertIs(caught.exception, failure)

    def test_pub_selects_hosted_packages_from_the_resolver_not_version_spelling(self):
        updater = packages.Updater(self.root)
        rows = [{"package": name, "kind": "direct", "current": {"version": "old"},
                 "resolvable": {"version": "next-build"}} for name in ("hosted", "flutter", "re_editor")]
        graph = {"packages": [{"name": "hosted", "source": "hosted", "version": "old"}, {"name": "flutter", "source": "sdk"},
                              {"name": "re_editor", "source": "path"}]}
        with mock.patch.object(packages, "run", side_effect=["", json.dumps({"packages": rows}), json.dumps(graph)]):
            self.assertEqual(updater.pub_updates(), {"hosted": ("next-build", "direct")})

    def test_mihomo_selector_report_uses_actual_go_result(self):
        self.target = "v1.0.1-0.20000101000000-123456789abc"
        result = self.execute(scope="mihomo", mihomo_version="feature/next", reuse_version=True)
        self.updater.go_updates.assert_called_once_with([packages.MIHOMO], "feature/next")
        self.assertEqual(result["mihomo"]["selected"], self.target)

    def test_all_scope_only_installs_the_existing_toolchain_record(self):
        self.execute()
        self.assertEqual(self.bootstrap.method_calls, [mock.call.prepare(self.toolchains, self.base / "cache", self.work)])
        self.assertEqual(resources.read_release_resources(self.root)["toolchains"], self.toolchains)

    def test_pub_sdk_and_path_packages_keep_their_sources(self):
        for name, source in (("flutter", "sdk"), ("re_editor", "path")):
            outdated = {"packages": [{"package": name, "kind": "direct", "current": {"version": "1.0.0"},
                                      "resolvable": {"version": "2.0.0"}}]}
            dependencies = {"packages": [{"name": name, "source": source}]}
            with self.subTest(name=name), mock.patch.object(
                    packages, "run", side_effect=["", json.dumps(outdated), json.dumps(dependencies)]):
                with self.assertRaisesRegex(ValueError, "direct hosted dependencies"):
                    packages.Updater(self.root).pub_updates([name])

    def test_evidence_build_failure_is_reported(self):
        updater = packages.Updater(self.root)
        with mock.patch.object(packages, "prepare_bundled_assets", return_value=self.generated) as prepare, \
                mock.patch.object(updater, "graph"), mock.patch.object(updater, "android_graph", return_value="graph"), \
                mock.patch.object(packages, "run", side_effect=ValueError("asset build failed")):
            with self.assertRaisesRegex(ValueError, "asset build failed"):
                updater.evidence(self.base / "evidence")
        prepare.assert_called_once_with(self.root)



class SourceNoticeTest(unittest.TestCase):
    """Verify locked Go resolution, production dependencies, and original local PSL bytes."""

    @classmethod
    def setUpClass(cls):
        environment = mock.patch.dict(os.environ, {"GOPROXY": "off", "GOSUMDB": "off"})
        environment.start()
        cls.addClassCleanup(environment.stop)
        temporary = tempfile.TemporaryDirectory(prefix="source-notices-")
        cls.addClassCleanup(temporary.cleanup)
        cls.updater = packages.Updater(ROOT)
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
        self.legal = legal.Legal(updater, self.root, mock.Mock(), self.process, packages.artifacts)

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
        with self.assertRaisesRegex(ValueError, "License grant text is missing"):
            self.legal.check({"AUTHORS": b"name"})
        for names in ([], ["Copyright"], ["GPL-2.0"], ["proprietary"]):
            self.classifier(names)
            with self.subTest(names=names), self.assertRaisesRegex(ValueError, "License requires technical review"):
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
