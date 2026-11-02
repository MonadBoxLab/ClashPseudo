"""测试自动发布的版本选择、中断后重新运行、资产大小与摘要校验和对应源码归档。"""

from contextlib import redirect_stderr
import base64
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

from frozen_resource_fixture import frozen_resources


ROOT = Path(__file__).resolve().parents[2]


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load("dependency_release", "tool/dependencies/release.py")
packager = load("package_sources", "tool/artifacts/package_sources.py")


class ReleaseTest(unittest.TestCase):
    def setUp(self):
        environment = mock.patch.dict(os.environ, {"ACT": "", "CLASH_LOCAL_EXECUTION": ""})
        environment.start()
        self.addCleanup(environment.stop)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.version = "1.1.0+2"
        self.kernel = "v1.19.33"
        self.commit = "a" * 40
        latest = mock.patch.object(release.update, "mihomo_release", return_value=self.kernel)
        self.latest = latest.start()
        self.addCleanup(latest.stop)
        (self.root / "pubspec.yaml").write_text("version: " + self.version + "\n")

    def record(self, *, draft=False, missing=()):
        return {"draft": draft, "prerelease": self.version.startswith("0."),
                "body": release.metadata(self.version, self.kernel, self.commit),
                "assets": [{"name": name, "state": "uploaded"} for name in release.names(self.version)
                           if name not in missing]}

    def preparation(self):
        preparation = release.ReleasePreparation(self.root, "main", "owner/repo", self.root)
        preparation.prepare_tools = mock.Mock()
        return preparation

    def resources(self, *, prepared=True):
        sources = self.root / "resource-sources.json"
        sources.write_text("{}", encoding="utf-8")
        directory = self.root / "prepared-resources"
        if prepared:
            directory.mkdir(exist_ok=True)
        return {"prepared": directory if prepared else None, "sources": sources}

    def test_complete_release_and_draft_retry_are_distinguished(self):
        self.assertTrue(release.check_release(self.record(), self.version, self.kernel, self.commit))
        self.assertFalse(release.check_release(self.record(draft=True), self.version, self.kernel, self.commit))
        self.assertFalse(release.check_release(self.record(missing=("SHA256SUMS",)),
                                               self.version, self.kernel, self.commit))
        self.assertFalse(release.check_release(None, self.version, self.kernel, self.commit))

    def test_development_release_requires_prerelease_and_mismatch_remains_resumable(self):
        for version, expected in (("0.1.0+3", True), ("1.0.0+4", False)):
            with self.subTest(version=version):
                self.version = version
                record = self.record()
                self.assertEqual(record["prerelease"], expected)
                self.assertTrue(release.check_release(record, version, self.kernel, self.commit))
                record["prerelease"] = not expected
                self.assertFalse(release.check_release(record, version, self.kernel, self.commit))

    def test_first_stable_preparation_changes_real_version_once_with_or_without_development_tag(self):
        for tagged in (False, True):
            with self.subTest(tagged=tagged):
                self.version = "0.1.0+3"
                (self.root / "pubspec.yaml").write_text("version: " + self.version + "\n")
                preparation = self.preparation()
                def git(*arguments):
                    if arguments[:2] == ("show", "v" + self.version + ":pubspec.yaml"):
                        return "version: " + self.version
                    if arguments[:2] == ("show", "v" + self.version + ":native/mihomo/go.mod"):
                        return "require github.com/metacubex/mihomo " + self.kernel
                    return self.commit
                preparation.git = mock.Mock(side_effect=git)
                preparation.tag_commit = mock.Mock(side_effect=lambda tag:
                    self.commit if tagged and tag == "v" + self.version else None)
                preparation.record = mock.Mock(return_value=self.record())
                preparation.kernel = mock.Mock(return_value=self.kernel)
                preparation.existing_assets = mock.Mock(return_value={})
                preparation.artifacts = mock.Mock()
                preparation.source_assets = mock.Mock()
                preparation.commit_inputs = mock.Mock(return_value=self.commit)
                preparation.release_plan = mock.Mock(return_value=self.root / "release.json")
                resources = self.resources()
                preparation.delivery_resources = mock.Mock(return_value=resources)
                def update_application(args):
                    path = args.project / "pubspec.yaml"
                    text, version = release.update.bump_version(path.read_text(), args.bump)
                    path.write_text(text)
                    return {"status": "updated", "version": version, "files": ["pubspec.yaml"]}
                with mock.patch.object(release, "signing_digest", return_value="certificate"), \
                        mock.patch.object(release, "check_version"), \
                        mock.patch.object(release.update, "bump_version", wraps=release.update.bump_version) as bump, \
                        mock.patch.object(release.update, "execute", side_effect=update_application) as update:
                    result = preparation.execute(bump="stable")
                self.assertEqual(result["version"], "1.0.0+4")
                self.assertEqual((self.root / "pubspec.yaml").read_text(), "version: 1.0.0+4\n")
                preparation.delivery_resources.assert_called_once_with(prepare=True)
                bump.assert_called_once_with("version: 0.1.0+3\n", "stable")
                update.assert_called_once()
                args = update.call_args.args[0]
                self.assertEqual(args.project, self.root)
                self.assertEqual(args.resolved_release, self.kernel)
                self.assertEqual(args.prepared_resources, resources["prepared"])
                self.assertEqual((args.go_module, args.pub, args.android), ([], [], []))
                self.assertTrue(args.apply)
                self.assertFalse(args.check)
                self.assertFalse(args.reuse_version)
                preparation.prepare_tools.assert_called_once_with()
                self.assertEqual(preparation.source_assets.call_args.kwargs,
                                 {"resource_sources": resources["sources"]})
                preparation.git.assert_any_call("push", "--atomic", "origin", "HEAD:refs/heads/main",
                                               "refs/tags/v1.0.0+4")

    def test_development_major_is_rejected_before_reusing_unpublished_version(self):
        (self.root / "pubspec.yaml").write_text("version: 0.1.0+3\n")
        preparation = self.preparation()
        preparation.git = mock.Mock(return_value=self.commit)
        with mock.patch.object(release, "signing_digest", return_value="certificate"), \
                mock.patch.object(preparation, "artifacts") as build, \
                self.assertRaisesRegex(ValueError, "明确选择 stable"):
            preparation.execute(bump="major")
        build.assert_not_called()
        self.assertEqual((self.root / "pubspec.yaml").read_text(), "version: 0.1.0+3\n")
        self.assertFalse(any(call.args[0] in ("push", "tag") for call in preparation.git.call_args_list))

    def test_foreign_or_ambiguous_release_ownership_is_rejected(self):
        for suffix in ("wrong", self.commit + "suffix", self.commit + "\nSource: another"):
            record = self.record()
            record["body"] = record["body"].replace("Source: " + self.commit, "Source: " + suffix)
            with self.subTest(suffix=suffix), self.assertRaisesRegex(ValueError, "版本、内核版本或源码提交与本次发布不一致"):
                release.check_release(record, self.version, self.kernel, self.commit)

    def test_checksum_manifest_checks_exact_asset_set_and_preserves_bytes(self):
        name = release.names(self.version)[0]
        path = self.root / name
        path.write_bytes(b"signed APK bytes")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        manifest = digest + "  " + name + "\n"
        self.assertEqual(release.verify_sums(manifest, [name], {name: path}), {name: digest})
        with self.assertRaisesRegex(ValueError, "已保留附件的摘要与校验文件不一致"):
            release.verify_sums("0" * 64 + "  " + name, [name], {name: path})
        for text in (manifest + manifest, digest + "  ../outside", digest + "  extra", "invalid"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                release.verify_sums(text, [name], {name: path})

    def test_no_update_uses_existing_version_without_building(self):
        preparation = self.preparation()
        preparation.git = mock.Mock(return_value=self.commit)
        preparation.tag_commit = mock.Mock(return_value=self.commit)
        preparation.kernel = mock.Mock(return_value=self.kernel)
        preparation.record = mock.Mock(return_value=self.record())
        def git(*arguments):
            if arguments[:2] == ("show", "v" + self.version + ":pubspec.yaml"):
                return "version: " + self.version
            if arguments[:2] == ("show", "v" + self.version + ":native/mihomo/go.mod"):
                return "require github.com/metacubex/mihomo " + self.kernel
            return self.commit
        preparation.git.side_effect = git
        with mock.patch.object(release, "signing_digest", return_value="certificate"), \
                mock.patch.object(preparation, "delivery_resources") as resources, \
                mock.patch.object(preparation, "artifacts") as build, mock.patch.object(release.update, "execute") as update:
            result = preparation.execute()
        self.assertEqual(result, {"status": "unchanged", "version": self.version, "kernel": self.kernel})
        resources.assert_not_called()
        build.assert_not_called()
        update.assert_not_called()

    def test_prepared_feature_release_reuses_version_while_updating_kernel(self):
        self.latest.return_value = "v1.19.34"
        preparation = self.preparation()
        preparation.git = mock.Mock(return_value=self.commit)
        preparation.tag_commit = mock.Mock(return_value=None)
        preparation.record = mock.Mock(return_value=None)
        preparation.kernel = mock.Mock(return_value=self.kernel)
        preparation.existing_assets = mock.Mock(return_value={})
        preparation.artifacts = mock.Mock()
        preparation.source_assets = mock.Mock()
        preparation.commit_inputs = mock.Mock(return_value=self.commit)
        preparation.release_plan = mock.Mock(return_value=self.root / "release.json")
        preparation.delivery_resources = mock.Mock(return_value=self.resources())
        with mock.patch.object(release, "signing_digest", return_value="certificate"), \
                mock.patch.object(release, "check_version"), \
                mock.patch.object(release.update, "execute", return_value={"files": ["go.mod"]}) as update:
            result = preparation.execute(bump="minor")
        self.assertTrue(update.call_args.args[0].reuse_version)
        self.assertEqual(update.call_args.args[0].resolved_release, "v1.19.34")
        self.latest.assert_called_once_with()
        preparation.prepare_tools.assert_called_once_with()
        self.assertEqual(update.call_args.args[0].prepared_resources,
                         self.root / "prepared-resources")
        self.assertEqual(preparation.delivery_resources.call_args.kwargs, {"prepare": True})
        self.assertEqual(result["version"], "1.1.0+2")
        self.assertEqual(result["tag"], "v1.1.0+2")
        self.assertEqual((self.root / "pubspec.yaml").read_text(), "version: 1.1.0+2\n")
        preparation.git.assert_any_call("push", "--atomic", "origin", "HEAD:refs/heads/main", "refs/tags/v1.1.0+2")

    def test_incomplete_release_resumes_original_version_even_when_newer_kernel_exists(self):
        self.latest.return_value = "v1.19.34"
        preparation = self.preparation()
        def git(*arguments):
            if arguments[:2] == ("show", "v" + self.version + ":pubspec.yaml"):
                return "version: " + self.version
            if arguments[:2] == ("show", "v" + self.version + ":native/mihomo/go.mod"):
                return "require github.com/metacubex/mihomo " + self.kernel
            return self.commit
        preparation.git = mock.Mock(side_effect=git)
        preparation.tag_commit = mock.Mock(return_value=self.commit)
        preparation.record = mock.Mock(return_value=self.record(draft=True))
        preparation.kernel = mock.Mock(return_value=self.kernel)
        preparation.existing_assets = mock.Mock(return_value={})
        preparation.artifacts = mock.Mock()
        preparation.source_assets = mock.Mock()
        preparation.release_plan = mock.Mock(return_value=self.root / "release.json")
        resources = self.resources(prepared=False)
        recovered = self.root / "restored"
        preparation.recover_resources = mock.Mock(return_value=recovered)
        preparation.delivery_resources = mock.Mock(return_value=resources)
        with mock.patch.object(release, "signing_digest", return_value="certificate"), \
                mock.patch.object(release.update, "execute") as update:
            result = preparation.execute()
        update.assert_not_called()
        self.latest.assert_not_called()
        preparation.prepare_tools.assert_called_once_with()
        preparation.delivery_resources.assert_called_once_with(prepare=False, recovered=recovered)
        preparation.recover_resources.assert_called_once_with(preparation.existing_assets.call_args.args[2],
                                                              self.version, self.commit, {})
        preparation.git.assert_any_call("checkout", "--detach", self.commit)
        self.assertEqual(result["version"], self.version)
        self.assertEqual(result["kernel"], self.kernel)
        self.assertEqual(preparation.artifacts.call_args.args[1:], (self.version, "certificate", {}))
        preparation.artifacts.assert_called_once()
        self.assertEqual(preparation.source_assets.call_args.kwargs, {"resource_sources": resources["sources"]})
        self.assertFalse(any(call.args[0] == "push" for call in preparation.git.call_args_list))

    def test_resource_preparation_failure_stops_before_application_or_git_writes(self):
        self.latest.return_value = "v1.19.34"
        preparation = self.preparation()
        preparation.git = mock.Mock(return_value=self.commit)
        preparation.tag_commit = mock.Mock(return_value=None)
        preparation.record = mock.Mock(return_value=None)
        preparation.kernel = mock.Mock(return_value=self.kernel)
        failure = ValueError("synthetic resource preparation failure")
        preparation.delivery_resources = mock.Mock(side_effect=failure)
        with mock.patch.object(release, "signing_digest", return_value="certificate"), \
                mock.patch.object(release.update, "execute") as update, \
                self.assertRaises(ValueError) as error:
            preparation.execute()
        self.assertIs(error.exception, failure)
        update.assert_not_called()
        self.assertFalse(any(call.args[0] in ("tag", "push", "add", "commit")
                             for call in preparation.git.call_args_list))
        self.assertEqual((self.root / "pubspec.yaml").read_text(), "version: " + self.version + "\n")

    def test_delivery_resources_forwards_prepare_and_rejects_incomplete_material(self):
        preparation = self.preparation()
        sources = self.root / "sources.json"
        sources.write_text("{}", encoding="utf-8")
        prepared = self.root / "prepared"
        prepared.mkdir()
        with mock.patch.object(release.update, "delivery_resources",
                               return_value={"prepared": prepared, "sources": sources}) as delivery:
            self.assertEqual(preparation.delivery_resources(prepare=True),
                             {"prepared": prepared, "sources": sources})
        self.assertTrue(delivery.call_args.kwargs["prepare"])
        self.assertTrue(delivery.call_args.args[1].is_dir())
        self.assertTrue(delivery.call_args.args[1].name.startswith("release-resources-"))
        cases = [
            ({"prepared": prepared, "sources": sources, "extra": 1}, True, "资源准备函数未返回完整的来源清单"),
            ({"prepared": prepared, "sources": str(sources)}, True, "资源准备函数未返回完整的来源清单"),
            ({"prepared": prepared, "sources": self.root / "absent.json"}, True, "资源准备函数未返回完整的来源清单"),
            ({"prepared": None, "sources": sources}, True, "准备阶段"),
            ({"prepared": sources, "sources": sources}, True, "准备阶段"),
            ({"prepared": prepared, "sources": sources}, False, "准备阶段"),
        ]
        for result, prepare, message in cases:
            with self.subTest(result=result, prepare=prepare), \
                    mock.patch.object(release.update, "delivery_resources", return_value=result), \
                    self.assertRaisesRegex(ValueError, message):
                preparation.delivery_resources(prepare=prepare, recovered=self.root if not prepare else None)

    def test_source_archive_consumes_the_delivery_resource_manifest(self):
        frozen_resources(self.root, release.update)
        for name in ("NOTICE.md", "doc/legal/dependencies.md", *release.update.artifacts.ASSETS):
            path = self.root / name
            if not path.exists():
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(("合成许可材料 " + name + "\n").encode())
        preparation = self.preparation()
        preparation.updater = mock.Mock()
        directory = self.root / "assets"
        directory.mkdir()
        sources = self.root / "resource-sources.json"
        sources.write_text("{}", encoding="utf-8")
        manifest = release.names(self.version)[-3]
        for name in release.apk_targets(self.version):
            (directory / name).write_bytes(b"signed APK")
        create = mock.Mock(side_effect=lambda *arguments, **keywords:
                           (directory / manifest).write_bytes(b"source archive"))
        tool = mock.Mock(create=create, add_bytes=packager.add_bytes)
        with mock.patch.object(release.update, "load_tool", return_value=tool), \
                mock.patch.object(release.update, "run", side_effect=AssertionError("归档不应运行外部命令")) as process:
            preparation.source_assets(directory, self.root / "evidence", self.version, self.commit, {},
                                      resource_sources=sources)
        process.assert_not_called()
        self.assertEqual(tool.create.call_args.args[:4],
                         (preparation.updater, self.root / "evidence", directory / manifest, self.commit))
        self.assertEqual(tool.create.call_args.kwargs, {"resource_sources": sources})
        with tarfile.open(directory / release.names(self.version)[-2], "r:gz") as archive:
            expected = {"NOTICE.md", "doc/legal/dependencies.md", release.update.RESOURCE_RECORD,
                        *release.update.artifacts.ASSETS}
            self.assertEqual(set(archive.getnames()), expected)
            for name in expected:
                self.assertEqual(archive.extractfile(name).read(), (self.root / name).read_bytes())
        release.verify_sums((directory / "SHA256SUMS").read_text(), release.names(self.version)[:-1],
                            {name: directory / name for name in release.names(self.version)[:-1]})

    def test_new_version_code_must_exceed_existing_distribution(self):
        with mock.patch.object(release.update, "run", side_effect=["v1.0.0+2\n", "version: 1.0.0+2\n"]):
            with self.assertRaisesRegex(ValueError, "versionCode"):
                release.check_version(self.root, "v" + self.version)

    def test_missing_asset_is_recovered_only_when_its_bytes_match(self):
        preparation = self.preparation()
        name = release.names(self.version)[0]
        data = b"original signed APK"
        digest = hashlib.sha256(data).hexdigest()
        artifact = {"name": "release-materials-" + self.version + "-123-1", "expired": False,
                    "workflow_run": {"id": 123}}
        preparation.api = mock.Mock(return_value={"artifacts": [artifact]})
        def download(command, cwd):
            path = Path(command[command.index("--dir") + 1])
            (path / name).write_bytes(data)
        files = {}
        with mock.patch.object(release.update, "run", side_effect=download):
            preparation.recover_assets(self.version, {name: digest}, self.root, files)
        self.assertEqual(files[name].read_bytes(), data)

    def test_four_apks_share_one_version_and_notes_recommend_universal_first(self):
        targets = release.apk_targets(self.version)
        self.assertEqual(list(targets.values()), [
            ("armeabi-v7a", "arm64-v8a", "x86_64"), ("arm64-v8a",), ("armeabi-v7a",), ("x86_64",),
        ])
        self.assertEqual(set(targets), {
            "clash-pseudo-1.1.0+2-universal.apk", "clash-pseudo-1.1.0+2-arm64-v8a.apk",
            "clash-pseudo-1.1.0+2-armeabi-v7a.apk", "clash-pseudo-1.1.0+2-x86_64.apk",
        })
        notes = release.release_notes(self.version, self.kernel, self.commit, "owner/repo")
        self.assertTrue(notes.startswith("## Android 通用版（推荐）"))
        self.assertLess(notes.index("-universal.apk"), notes.index("其他下载／按架构选择"))
        self.assertIn("通用版包含 armeabi-v7a、arm64-v8a 和 x86_64。下载 APK 后在 Android 设备上打开，按系统提示安装。", notes)
        self.assertIn("1.1.0%2B2", notes)
        self.assertEqual(len(release.names(self.version)), 7)

    def test_plan_contains_all_distribution_digests_for_actions(self):
        for name in release.names(self.version):
            (self.root / name).write_bytes(name.encode())
        path = self.preparation().release_plan(self.root, self.version, self.kernel, self.commit)
        plan = json.loads(path.read_text())
        self.assertEqual(plan["tag"], "v1.1.0+2")
        self.assertEqual(plan["commit"], self.commit)
        self.assertEqual([asset["name"] for asset in plan["assets"]], list(release.names(self.version)))
        for asset in plan["assets"]:
            self.assertEqual(asset["sha256"], hashlib.sha256(asset["name"].encode()).hexdigest())
            self.assertEqual(asset["bytes"], len(asset["name"].encode()))

    def test_four_packages_build_without_implicit_functional_tests(self):
        preparation = self.preparation()
        preparation.updater.evidence = mock.Mock()
        preparation.tests = mock.Mock()
        outputs = self.root / "build/app/outputs/flutter-apk"
        outputs.mkdir(parents=True)
        for suffix in ("", "-arm64-v8a", "-armeabi-v7a", "-x86_64"):
            (outputs / ("app" + suffix + "-release.apk")).write_bytes(suffix.encode() or b"universal")
        def inspect(updater, apk, evidence, output, version, certificate, abis):
            return {abi: abi for abi in abis}
        with mock.patch.object(release.update, "run", return_value="") as process, \
                mock.patch.object(release, "verify_apk", side_effect=inspect) as verify:
            preparation.artifacts(self.root, self.version, "certificate", {})
        preparation.tests.assert_not_called()
        self.assertEqual(process.call_count, 3)
        self.assertEqual(process.call_args_list[0].args[0],
                         ["python3", "-I", "-B", "tool/contracts/generate.py", "--check"])
        builds = process.call_args_list[1:]
        self.assertTrue(all(call.args[0][1:3] == ["build", "apk"] for call in builds))
        self.assertNotIn("--split-per-abi", builds[0].args[0])
        self.assertIn("--split-per-abi", builds[1].args[0])
        self.assertEqual([call.args[-1] for call in verify.call_args_list], [
            ("armeabi-v7a", "arm64-v8a", "x86_64"), ("arm64-v8a",), ("armeabi-v7a",), ("x86_64",),
        ])
        self.assertTrue(all((self.root / name).is_file() for name in release.apk_targets(self.version)))

    def test_successful_existing_packages_are_preserved_on_resume(self):
        preparation = self.preparation()
        preparation.updater.evidence = mock.Mock()
        preparation.tests = mock.Mock()
        before = {}
        for name in release.apk_targets(self.version):
            path = self.root / name
            path.write_bytes(b"original signed bytes")
            before[name] = path
        with mock.patch.object(release.update, "run") as process, \
                mock.patch.object(release, "verify_apk", return_value={}) as verify:
            preparation.artifacts(self.root, self.version, "certificate", before)
        preparation.tests.assert_not_called()
        process.assert_called_once_with(["python3", "-I", "-B", "tool/contracts/generate.py", "--check"], self.root)
        self.assertEqual(verify.call_count, 4)
        self.assertEqual([call.args[-1] for call in verify.call_args_list], list(release.apk_targets(self.version).values()))
        self.assertTrue(all(path.read_bytes() == b"original signed bytes" for path in before.values()))

    def test_split_with_different_native_library_is_rejected(self):
        preparation = self.preparation()
        preparation.updater.evidence = mock.Mock()
        before = {name: self.root / name for name in release.apk_targets(self.version)}
        fingerprints = [{"arm64-v8a": "universal"}, {"arm64-v8a": "different"}]
        with mock.patch.object(release.update, "run", return_value="") as process, \
                mock.patch.object(release, "verify_apk", side_effect=fingerprints), \
                self.assertRaisesRegex(ValueError, "原生库不同"):
            preparation.artifacts(self.root, self.version, "certificate", before)
        process.assert_called_once_with(["python3", "-I", "-B", "tool/contracts/generate.py", "--check"], self.root)

    def test_generation_check_failure_prevents_evidence_build_and_apk_verification(self):
        preparation = self.preparation()
        preparation.updater.evidence = mock.Mock()
        failure = ValueError("synthetic generated contract mismatch")
        with mock.patch.object(release.update, "run", side_effect=failure) as process, \
                mock.patch.object(release, "verify_apk") as verify:
            with self.assertRaises(ValueError) as error:
                preparation.artifacts(self.root, self.version, "certificate", {})
        self.assertIs(error.exception, failure)
        process.assert_called_once_with(["python3", "-I", "-B", "tool/contracts/generate.py", "--check"], self.root)
        preparation.updater.evidence.assert_not_called()
        verify.assert_not_called()

    def test_signing_secrets_are_passed_by_environment_name(self):
        environment = {
            "CLASH_PSEUDO_ANDROID_KEYSTORE_BASE64": base64.b64encode(b"synthetic key").decode("ascii"),
            "CLASH_PSEUDO_ANDROID_KEYSTORE_PASSWORD": "private password",
            "CLASH_PSEUDO_ANDROID_KEY_ALIAS": "release",
            "CLASH_PSEUDO_ANDROID_KEY_PASSWORD": "private key password",
        }
        stores = []
        def certificate(command, cwd, env):
            store = Path(command[command.index("-keystore") + 1])
            stores.append(store)
            self.assertEqual(store.read_bytes(), b"synthetic key")
            self.assertEqual(stat.S_IMODE(store.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(store.parent.stat().st_mode), 0o700)
            self.assertEqual(env, {"CLASH_PSEUDO_ANDROID_KEYSTORE_PASSWORD": "private password"})
            return "pem certificate"
        with mock.patch.dict(os.environ, environment, clear=True), \
                mock.patch.object(release.update, "run", side_effect=certificate) as process, \
                mock.patch.object(release.ssl, "PEM_cert_to_DER_cert", return_value=b"certificate"), \
                mock.patch.object(release, "signing_properties") as local:
            digest = release.signing_digest(self.root)
        self.assertEqual(digest, hashlib.sha256(b"certificate").hexdigest())
        local.assert_not_called()
        process.assert_called_once()
        command = process.call_args.args[0]
        self.assertIn("-storepass:env", command)
        for secret in (environment[name] for name in environment if not name.endswith("ALIAS")):
            self.assertNotIn(secret, " ".join(map(str, command)))
        self.assertEqual(len(stores), 1)
        self.assertFalse(stores[0].exists())
        self.assertFalse(stores[0].parent.exists())

    def test_scheduled_event_cannot_request_first_stable_before_any_release_work(self):
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "CLASH_AUTOMATIC_RELEASES_ENABLED": "true",
                                         "GITHUB_WORKSPACE": str(release.ROOT), "GITHUB_EVENT_NAME": "schedule"}), \
                redirect_stderr(io.StringIO()), mock.patch.object(release.update, "mihomo_release") as query, \
                self.assertRaises(SystemExit) as error:
            release.main(["--output", str(self.root / "output"), "--bump", "stable"])
        self.assertEqual(error.exception.code, 1)
        self.assertFalse((self.root / "output").exists())
        query.assert_not_called()

    def test_release_cli_requires_explicit_remote_enablement(self):
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}), redirect_stderr(io.StringIO()), \
                self.assertRaises(SystemExit) as error:
            release.main(["--output", str(self.root / "output")])
        self.assertEqual(error.exception.code, 1)
        self.assertFalse((self.root / "output").exists())


class ResourceResumeTest(unittest.TestCase):
    """联合调用release、update与package_sources，使用mock提供下载和构建结果。"""
    def setUp(self):
        environment = mock.patch.dict(os.environ, {"ACT": "", "CLASH_LOCAL_EXECUTION": ""})
        environment.start()
        self.addCleanup(environment.stop)
        temporary = tempfile.TemporaryDirectory(prefix="release-resume-real-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.root = self.base / "project"
        self.root.mkdir()
        self.version, self.commit, self.kernel = "0.2.0+4", "a" * 40, "v1.19.33"
        (self.root / "pubspec.yaml").write_text("version: " + self.version + "\n")
        self.materials = self.base / "fixed"
        self.materials.mkdir()
        rows = []
        for kind, commit, data in (("geoip", "b" * 40, b"converter"), ("geosite", "c" * 40, b"rules")):
            url, name = release.update._source_expected(kind, commit)
            row = {"kind": kind, "sourceCommit": commit, "sourceUrl": url, "file": name,
                   "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "inputs": []}
            (self.materials / name).write_bytes(data)
            if kind == "geoip":
                url, name = release.update._source_expected(kind, "d" * 40)
                data = b"editable aggregation data"
                (self.materials / name).write_bytes(data)
                row["inputs"] = [{"sourceCommit": "d" * 40, "sourceUrl": url, "file": name,
                                  "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "description": "data"}]
                row["processing"] = "converter consumes the editable data"
            rows.append(row)
        self.metadata = {"format": "clash-pseudo-resource-sources", "version": 1, "sources": rows}
        (self.materials / "resource-sources.json").write_bytes(release.update.json_bytes(self.metadata))
        self.release_record, self.generated = frozen_resources(self.root, release.update, source_metadata=self.metadata)
        self.remote = self.base / "remote"
        self.remote.mkdir()
        self.source = self.remote / release.names(self.version)[-3]
        self.write_source()
        for name in release.names(self.version)[:-1]:
            path = self.remote / name
            if path != self.source:
                path.write_bytes(b"fixed " + name.encode())
        self.write_sums()
        self.output = self.base / "output"
        self.output.mkdir()

    def write_source(self, mutate=None, extra=()):
        documents = {
            "build-inputs/version.json": release.update.json_bytes({"commit": self.commit, "application": self.version,
                                                                   "workingTree": False}),
            "build-inputs/resources.json": release.update.json_bytes(self.release_record),
            "build-inputs/resource-sources.json": release.update.json_bytes(self.metadata),
        }
        for kind, name in release.update.RESOURCE_ASSETS.items():
            documents["build-inputs/bundled/assets/" + name] = (self.generated / "assets" / name).read_bytes()
        for kind, row in release.update.resource_source_entries(self.metadata):
            documents["dependencies/data/" + kind + "/" + row["file"]] = (self.materials / row["file"]).read_bytes()
        if mutate:
            mutate(documents)
        with tarfile.open(self.source, "w:gz") as archive:
            for name, data in documents.items():
                packager.add_bytes(archive, name, data)
            for name, data, kind in extra:
                member = tarfile.TarInfo(name)
                member.type, member.size = kind, len(data) if kind == tarfile.REGTYPE else 0
                member.linkname = "../../outside"
                archive.addfile(member, io.BytesIO(data) if member.isfile() else None)

    def write_sums(self):
        text = "".join(release.file_digest(self.remote / name) + "  " + name + "\n"
                       for name in release.names(self.version)[:-1])
        (self.remote / "SHA256SUMS").write_text(text)

    def preparation(self, available, actions=False):
        preparation = release.ReleasePreparation(self.root, "main", "owner/repo", self.output)
        preparation.prepare_tools = mock.Mock()
        def git(*args):
            if args == ("show", "v" + self.version + ":pubspec.yaml"):
                return "version: " + self.version
            if args == ("show", "v" + self.version + ":native/mihomo/go.mod"):
                return "require " + release.update.MIHOMO + " " + self.kernel
            return self.commit
        preparation.git = mock.Mock(side_effect=git)
        preparation.tag_commit = mock.Mock(return_value=self.commit)
        preparation.kernel = mock.Mock(return_value=self.kernel)
        preparation.record = mock.Mock(return_value={"draft": True, "prerelease": True,
            "body": release.metadata(self.version, self.kernel, self.commit),
            "assets": [{"name": name, "state": "uploaded"} for name in available]})
        preparation.api = mock.Mock(return_value={"artifacts": [{
            "name": "release-materials-" + self.version + "-123-1", "expired": False,
            "workflow_run": {"id": 123, "head_sha": "f" * 40}}] if actions else []})
        preparation.artifacts = mock.Mock()
        preparation.source_assets = mock.Mock()
        preparation.release_plan = mock.Mock(return_value=self.output / "plan.json")
        return preparation

    def download(self, command, cwd):
        self.assertEqual(command[0], "gh")
        destination = Path(command[command.index("--dir") + 1])
        if command[1:3] == ["release", "download"]:
            name = command[command.index("--pattern") + 1]
            shutil.copyfile(self.remote / name, destination / name)
        elif command[1:3] == ["run", "download"]:
            for path in self.remote.iterdir():
                shutil.copyfile(path, destination / path.name)
        else:
            self.fail("unexpected command " + repr(command))
        return ""

    def test_fresh_resume_restores_sources_before_real_prepare_false_without_latest(self):
        names = release.names(self.version)
        cases = ((names, False), (names[1:], False), (names[1:], True), ((), True))
        for available, actions in cases:
            with self.subTest(available=available, actions=actions):
                preparation = self.preparation(available, actions)
                events = []
                recover = preparation.recover_resources
                resources = preparation.delivery_resources
                def restore(*args):
                    events.append("restore")
                    return recover(*args)
                def delivery(*args, **kwargs):
                    events.append("prepare=False")
                    result = resources(*args, **kwargs)
                    self.assertTrue(result["sources"].is_file())
                    self.assertEqual(release.update.read_resource_sources(result["sources"].parent), self.metadata)
                    return result
                preparation.recover_resources = restore
                preparation.delivery_resources = delivery
                with mock.patch.object(release, "signing_digest", return_value="synthetic certificate"), \
                        mock.patch.object(release.update, "run", side_effect=self.download), \
                        mock.patch.object(release.update, "fetch", side_effect=AssertionError("network forbidden")), \
                        mock.patch.object(release.update, "mihomo_release", side_effect=AssertionError("latest forbidden")):
                    result = preparation.execute()
                self.assertEqual(events, ["restore", "prepare=False"])
                self.assertEqual(result["version"], self.version)
                self.assertEqual(result["kernel"], self.kernel)
                existing = preparation.artifacts.call_args.args[-1]
                self.assertIn(names[-3], existing)
                self.assertEqual(names[0] in existing, names[0] in available or actions)
                self.assertFalse(any(call.args[0] in ("push", "tag", "commit", "add")
                                     for call in preparation.git.call_args_list))

    def test_missing_fixed_sources_or_sums_stops_before_prepare_or_build(self):
        names = release.names(self.version)
        for missing in (names[-3], "SHA256SUMS"):
            preparation = self.preparation([name for name in names if name != missing])
            with mock.patch.object(release, "signing_digest", return_value="certificate"), \
                    mock.patch.object(release.update, "run", side_effect=self.download), \
                    mock.patch.object(preparation, "delivery_resources") as resources, \
                    mock.patch.object(release.update, "mihomo_release", side_effect=AssertionError("latest forbidden")), \
                    self.assertRaisesRegex(ValueError, "缺少"):
                preparation.execute()
            resources.assert_not_called()
            preparation.artifacts.assert_not_called()

    def test_source_identity_and_geo_digests_are_checked(self):
        def version_change(key, value):
            def change(documents):
                data = json.loads(documents["build-inputs/version.json"])
                data[key] = value
                documents["build-inputs/version.json"] = release.update.json_bytes(data)
            return change
        def resource_change(documents):
            record = json.loads(documents["build-inputs/resources.json"])
            record["resources"]["geoip"]["storedSha256"] = "0" * 64
            documents["build-inputs/resources.json"] = release.update.json_bytes(record)
        def payload_change(kind, missing):
            def change(documents):
                name = "build-inputs/bundled/assets/" + release.update.RESOURCE_ASSETS[kind]
                data = documents.pop(name)
                if not missing:
                    documents[name] = bytes([data[0] ^ 1]) + data[1:]
            return change
        changes = [version_change("commit", "0" * 40), version_change("application", "0.2.1+5"),
                   version_change("workingTree", True), version_change("workingTree", 0), resource_change]
        changes.extend(payload_change(kind, missing) for kind in release.update.RESOURCE_ASSETS
                       for missing in (False, True))
        for index, change in enumerate(changes):
            self.write_source(change)
            with self.subTest(index=index), self.assertRaises(ValueError):
                release.recover_resource_sources(self.root, self.source, self.base / ("bad-" + str(index)),
                                                self.version, self.commit)

    def test_duplicate_unsafe_link_unregistered_and_oversize_members_are_rejected(self):
        cases = (("build-inputs/version.json", b"{}", tarfile.REGTYPE),
                 ("../outside", b"x", tarfile.REGTYPE), ("/absolute", b"x", tarfile.REGTYPE),
                 ("dependencies/data/extra.tar.gz", b"x", tarfile.REGTYPE),
                 ("linked", b"", tarfile.SYMTYPE), ("hardlinked", b"", tarfile.LNKTYPE))
        for index, entry in enumerate(cases):
            self.write_source(extra=[entry])
            with self.subTest(entry=entry), self.assertRaises(ValueError):
                release.recover_resource_sources(self.root, self.source, self.base / ("unsafe-" + str(index)),
                                                self.version, self.commit)
        self.write_source()
        with mock.patch.object(release, "SOURCE_PACKAGE_LIMIT", 16), self.assertRaisesRegex(ValueError, "上限"):
            release.recover_resource_sources(self.root, self.source, self.base / "oversize", self.version, self.commit)

    def test_registered_archive_tamper_or_missing_member_never_downloads_a_replacement(self):
        row = self.metadata["sources"][0]
        (self.materials / row["file"]).write_bytes(b"x" * row["bytes"])
        # 保留登记的摘要并写入损坏成员，检查恢复函数是否拒绝摘要不符的内容。
        self.write_source()
        with mock.patch.object(release.update, "fetch", side_effect=AssertionError("network forbidden")), \
                self.assertRaisesRegex(ValueError, "摘要不同"):
            release.recover_resource_sources(self.root, self.source, self.base / "tampered", self.version, self.commit)


    def test_missing_registered_member_and_wrong_manifest_url_stop_without_network(self):
        for index, error_kind in enumerate(("missing", "url")):
            def change(documents):
                if error_kind == "missing":
                    kind, row = next(iter(release.update.resource_source_entries(self.metadata)))
                    documents.pop("dependencies/data/" + kind + "/" + row["file"])
                else:
                    metadata = json.loads(documents["build-inputs/resource-sources.json"])
                    metadata["sources"][0]["sourceUrl"] = "https://github.com/v2fly/geoip/archive/latest.tar.gz"
                    documents["build-inputs/resource-sources.json"] = release.update.json_bytes(metadata)
            self.write_source(change)
            with self.subTest(error_kind=error_kind), \
                    mock.patch.object(release.update, "fetch", side_effect=AssertionError("network forbidden")), \
                    self.assertRaises(ValueError):
                release.recover_resource_sources(self.root, self.source, self.base / ("missing-member-" + str(index)),
                                                self.version, self.commit)

    def test_asset_digest_mismatch_stops_before_resource_preparation(self):
        first = self.remote / release.names(self.version)[0]
        first.write_bytes(b"changed signed bytes")
        preparation = self.preparation(release.names(self.version))
        with mock.patch.object(release, "signing_digest", return_value="certificate"), \
                mock.patch.object(release.update, "run", side_effect=self.download), \
                mock.patch.object(preparation, "delivery_resources") as resources, \
                self.assertRaisesRegex(ValueError, "已保留附件的摘要与校验文件不一致"):
            preparation.execute()
        resources.assert_not_called()
        preparation.artifacts.assert_not_called()

    def test_local_input_or_resource_manifest_changes_invalidate_the_fixed_snapshot(self):
        workspace = self.isolated_fixture()
        source = workspace / "new.dart"
        source.write_bytes(b"changed after freezing")
        with self.assertRaisesRegex(ValueError, "固定输入发生变化"):
            release.local_input_identity(workspace)
        source.write_bytes(b"necessary new source")
        manifest = workspace / ".local/resource-inputs/resource-sources/resource-sources.json"
        manifest.write_bytes(manifest.read_bytes() + b"\n")
        with self.assertRaisesRegex(ValueError, "固定资源清单发生变化"):
            release.local_input_identity(workspace)

    def isolated_fixture(self):
        environment = {"PATH": os.defpath, "HOME": str(self.base), "LANG": "C.UTF-8",
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
        release.isolated_run(["git", "init", "-b", "main", self.root], self.base, environment)
        (self.root / "deleted.dart").write_bytes(b"old tracked source")
        (self.root / ".gitignore").write_text("forced.dart\n")
        (self.root / "forced.dart").write_bytes(b"tracked despite ignore rule")
        release.isolated_run(["git", "add", "--all"], self.root, environment)
        release.isolated_run(["git", "add", "--force", "--", "forced.dart"], self.root, environment)
        release.isolated_run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@invalid", "commit",
                              "-m", "fixture"], self.root, environment)
        (self.root / "deleted.dart").unlink()
        (self.root / "new.dart").write_bytes(b"necessary new source")
        (self.root / ".actrc").write_bytes(b"unsafe inherited act arguments")
        (self.root / ".secrets").write_bytes(b"synthetic excluded material")
        (self.root / "android").mkdir(parents=True, exist_ok=True)
        (self.root / "android/key.properties").write_bytes(b"synthetic excluded signing configuration")
        index = (self.root / ".git/index").read_bytes()
        destination = self.base / "act-fixture"
        with mock.patch.dict(os.environ, {"GH_TOKEN": "synthetic token", "AWS_ACCESS_KEY_ID": "synthetic cloud",
                                          "SSH_AUTH_SOCK": "/synthetic/socket"}):
            result = release.prepare_act(self.root, destination, self.materials / "resource-sources.json",
                                         "example.test/debian:runner", artifact_host="192.0.2.1",
                                         docker_host="unix:///run/user/1000/docker.sock")
        self.assertEqual((self.root / ".git/index").read_bytes(), index)
        workspace = Path(result["workspace"])
        self.assertFalse((workspace / "deleted.dart").exists())
        self.assertEqual((workspace / "new.dart").read_bytes(), b"necessary new source")
        self.assertEqual((workspace / "forced.dart").read_bytes(), b"tracked despite ignore rule")
        for excluded in (".actrc", ".secrets", "android/key.properties"):
            self.assertFalse((workspace / excluded).exists())
        self.assertNotEqual((workspace / ".git").stat().st_ino, (self.root / ".git").stat().st_ino)
        launch = json.loads(Path(result["launch"]).read_bytes())
        self.assertTrue((destination / "origin.git/HEAD").is_file())
        self.assertEqual(set(launch["environment"]), {"PATH", "HOME", "TMPDIR", "LANG", "GIT_CONFIG_NOSYSTEM",
                                                     "GIT_CONFIG_GLOBAL", "GIT_TERMINAL_PROMPT", "DOCKER_CONFIG", "DOCKER_HOST"})
        self.assertEqual(launch["environment"]["DOCKER_HOST"], "unix:///run/user/1000/docker.sock")
        self.assertEqual(launch["command"][launch["command"].index("--container-daemon-socket") + 1], "-")
        self.assertEqual(launch["command"][launch["command"].index("--container-options-policy") + 1], "restrict")
        for command in (launch["command"], launch["validate"], launch["dryrun"]):
            self.assertIn("--bind", command)
            self.assertEqual(command[command.index("--directory") + 1], str(workspace))
            self.assertNotIn(str(self.root), command)
        self.assertIn("--no-cache-server", launch["command"])
        self.assertIn("--pull=false", launch["command"])
        self.assertIn("--validate", launch["validate"])
        self.assertIn("--dryrun", launch["validate"])
        self.assertIn("--dryrun", launch["dryrun"])
        self.assertNotIn("--dryrun", launch["command"])
        for flag in ("--env-file", "--secret-file", "--var-file", "--input-file", "--eventpath",
                     "--action-cache-path", "--artifact-server-path", "--platform", "--directory"):
            self.assertIn(flag, launch["command"])
        self.assertEqual(stat.S_IMODE((destination / "control/secrets").stat().st_mode), 0o600)
        self.assertEqual((destination / "control/secrets").read_bytes(), b"")
        release.local_input_identity(workspace)
        return workspace

    def test_prepare_act_uses_independent_repository_home_and_explicit_mappings(self):
        self.isolated_fixture()

    def test_local_real_entry_never_creates_production_client_or_uses_remote_commands(self):
        workspace = self.isolated_fixture()
        output = self.base / "local-output"
        calls = []
        original = release.update.run
        def command(arguments, cwd, env=None):
            calls.append(arguments)
            if arguments[:3] == ["flutter", "pub", "get"]:
                return ""
            self.assertEqual(arguments[0], "git")
            self.assertIn(arguments[1], ("tag", "show", "rev-parse", "ls-files", "status"))
            if arguments[1] == "tag":
                self.assertEqual(arguments[2:4], ["--list", "v*+*"])
            return original(arguments, cwd, env=env)
        def assets(directory, evidence, version, commit, existing, **kwargs):
            self.assertIsNone(commit)
            for name in release.names(version):
                (directory / name).write_bytes(b"synthetic verified boundary " + name.encode())
        with mock.patch.dict(os.environ, {"ACT": "true", "CLASH_LOCAL_EXECUTION": "true",
                                          **{name: "synthetic" for name in release.SIGNING_NAMES}}, clear=True), \
                mock.patch.object(release, "ReleasePreparation", side_effect=AssertionError("production client forbidden")), \
                mock.patch.object(release, "signing_digest", return_value="1" * 64), \
                mock.patch.object(release.update, "mihomo_release", side_effect=AssertionError("latest forbidden")), \
                mock.patch.object(release.update, "run", side_effect=command), \
                mock.patch.object(release.update.Updater, "go_run", return_value=self.kernel), \
                mock.patch.object(release.LocalPreparation, "artifacts") as build, \
                mock.patch.object(release.LocalPreparation, "source_assets", side_effect=assets):
            self.assertEqual(release.main(["--local", "--project", str(workspace), "--output", str(output)]), 0)
        build.assert_called_once()
        plans = list(output.rglob("release.json"))
        self.assertEqual(len(plans), 1)
        plan = json.loads(plans[0].read_bytes())
        self.assertIs(plan["local"], True)
        self.assertIs(plan["workingTree"], True)
        self.assertEqual(len(plan["assets"]), 7)
        self.assertTrue(any(arguments[:3] == ["flutter", "pub", "get"] for arguments in calls))
        self.assertEqual((self.root / "pubspec.yaml").read_bytes(), (workspace / "pubspec.yaml").read_bytes())

    def test_local_missing_signing_fails_without_properties_or_production_reads(self):
        workspace = self.isolated_fixture()
        with mock.patch.dict(os.environ, {"CLASH_LOCAL_EXECUTION": "true"}, clear=True), \
                mock.patch.object(release, "signing_digest") as signing, \
                mock.patch.object(release, "ReleasePreparation") as production, \
                mock.patch.object(release.LocalPreparation, "artifacts") as build, \
                redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
            release.main(["--local", "--project", str(workspace), "--output", str(self.base / "missing-signing")])
        self.assertEqual(caught.exception.code, 1)
        signing.assert_not_called()
        production.assert_not_called()
        build.assert_not_called()

    def test_act_and_local_marker_cannot_enter_production_cli_or_execute(self):
        for environment in ({"ACT": "true"}, {"ACT": "false"}, {"CLASH_LOCAL_EXECUTION": "true"}):
            with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "CLASH_AUTOMATIC_RELEASES_ENABLED": "true",
                                              **environment}, clear=True), \
                    mock.patch.object(release, "ReleasePreparation") as production, \
                    mock.patch.object(release.update, "mihomo_release") as latest, \
                    redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
                release.main(["--output", str(self.base / "forbidden")])
            self.assertEqual(caught.exception.code, 1)
            production.assert_not_called()
            latest.assert_not_called()
            preparation = self.preparation([])
            with mock.patch.dict(os.environ, environment, clear=True), self.assertRaisesRegex(ValueError, "生产"):
                preparation.execute()
            preparation.git.assert_not_called()


class SigningPropertiesTest(unittest.TestCase):
    BASE = "storeFile=synthetic.jks\nstorePassword=synthetic store password\nkeyAlias=release\nkeyPassword=synthetic key password\n"
    JAVA_SOURCE = r"""
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

public class PropertiesOracle {
    private static String hex(String value) {
        StringBuilder result = new StringBuilder();
        for (int index = 0; index < value.length(); index++) {
            result.append(String.format("%04x", (int) value.charAt(index)));
        }
        return result.toString();
    }
    public static void main(String[] args) throws Exception {
        Properties properties = new Properties();
        try (var reader = new InputStreamReader(Files.newInputStream(Path.of(args[0])), StandardCharsets.UTF_8)) {
            properties.load(reader);
        } catch (IllegalArgumentException error) {
            System.out.println("ERROR");
            return;
        }
        for (String key : properties.stringPropertyNames().stream().sorted().toList()) {
            System.out.println(hex(key) + "\t" + hex(properties.getProperty(key)));
        }
    }
}
"""

    @classmethod
    def setUpClass(cls):
        java, javac = shutil.which("java"), shutil.which("javac")
        if not java or not javac:
            raise unittest.SkipTest("需要JDK来比较签名配置解析结果与java.util.Properties的解析结果")
        temporary = tempfile.TemporaryDirectory(prefix="clash-properties-oracle-")
        cls.addClassCleanup(temporary.cleanup)
        cls.oracle_root = Path(temporary.name)
        cls.java = java
        source = cls.oracle_root / "PropertiesOracle.java"
        source.write_text(cls.JAVA_SOURCE, encoding="utf-8")
        subprocess.run([javac, "-d", cls.oracle_root, source], cwd=cls.oracle_root,
                       env={"PATH": os.defpath}, capture_output=True, check=True, timeout=30)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="clash-properties-input-")
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name) / "key.properties"

    def oracle(self):
        result = subprocess.run([self.java, "-cp", self.oracle_root, "PropertiesOracle", self.path],
                                cwd=self.oracle_root, env={"PATH": os.defpath},
                                text=True, capture_output=True, check=True, timeout=30).stdout
        if result == "ERROR\n":
            return None
        def decode(value):
            return bytes.fromhex(value).decode("utf-16-be", "surrogatepass")
        return {decode(key): decode(value) for key, value in
                (line.split("\t") for line in result.splitlines())}

    def test_matches_real_java_reader_for_separators_whitespace_escapes_and_continuations(self):
        cases = {
            "second separator is value": "storePassword==abc\nkeyAlias: :release\nextra \t\f = \t\f ==value  ",
            "empty key and value": "=first\n:second\nempty=\nno_separator\n",
            "escaped key separators": r"a\ b\=c\:d\#\!=preserved" + "\n",
            "whitespace is only space tab formfeed": "\textra\f: value\n\u00a0key=left\u00a0right\nvertical\vkey=one\vtwo\n",
            "unicode line separators remain in values": "extra=one\u0085two\u2028three\u2029four\n",
            "leading and trailing value spaces": "extra=  \t\fvalue  \t\f\nleading=\\ value\n",
            "standard escapes and literal slash": r"extra=\t\r\n\f\\\ \=\:\#\!" + "\n",
            "unknown escapes lose only slash": r"extra=\q\b\0\a\U0041" + "\n",
            "unicode escapes and surrogate pairs": r"extra=\u" + "0041" + r"\u" + "00e9" + r"\u" + "d83d" + r"\u" + "de00" + r"\u" + "d800\n",
            "raw utf8 and escaped unicode keys coincide": "😀=raw\n" + r"\u" + "d83d" + r"\u" + "de00=escaped\n",
            "last decoded duplicate wins": "keyAlias=previous\n" + r"key\u" + "0041lias=last\n",
            "comment slash does not continue": " #ignored\\\n!also ignored " + r"\uBAD" + "\nextra=kept\n",
            "comment markers on continued line are values": "extra=first\\\n \t\f#not a comment\\\r\n !still a value\n",
            "blank continuation line ends value": "extra=first\\\n\nnext=separate\n",
            "empty prefix continuation follows Java comment handling": "\\\n#not.comment=value\n",
            "empty continuation then blank restarts comment": "\\\n\n#ignored=value\nextra=kept\n",
            "empty continuation before whitespace at eof": "\\\n \t",
            "empty continuation before blank line at eof": "\\\n\n",
            "empty repeated continuation at eof": "\\\n\\\n",
            "empty continuation before carriage return eof": "\\\r",
            "empty continuation before CRLF eof": "\\\r\n",
            "continued key and separator": "key\\\n \tAlias\\\n : release\n",
            "carriage return and CRLF": "extra=first\\\r\n \tsecond\rnext=third\\\rfourth\r\n",
            "eof slash is discarded": "extra=tail\\",
            "eof continuation preserves content": "extra=tail\\\n",
            "eof standalone slash makes empty property": "\\",
            "eof empty continued line matches Java": "\\\n",
            "bom remains part of key": "\ufeffextra=preserved\n",
        }
        for count in range(1, 6):
            cases[f"slash parity {count}"] = "extra=value" + "\\" * count + "\n next=line\n"
        for name, text in cases.items():
            with self.subTest(case=name):
                self.path.write_bytes((self.BASE + text).encode("utf-8"))
                expected = self.oracle()
                self.assertIsNotNone(expected)
                actual = release.signing_properties(self.path)
                self.assertEqual(actual, expected)
                if name == "second separator is value":
                    self.assertEqual(actual["storePassword"], "=abc")

    def test_malformed_utf8_replacement_matches_real_java_reader(self):
        cases = [b"\xff", b"\xed\xa0\x80", b"\xed\xa0", b"\xed\xa0X", b"\xed\xbf\xbf",
                 b"\xe0\x80\x80", b"\xf4\x90\x80\x80", b"\xf0\x80\x80\x80", b"\xf0\x9fX", b"\xe2X\x80"]
        for data in cases:
            with self.subTest(encoded=data.hex()):
                self.path.write_bytes(self.BASE.encode("utf-8") + b"extra=" + data)
                self.assertEqual(release.signing_properties(self.path), self.oracle())

    def test_invalid_unicode_escape_errors_match_real_java_without_echoing_values(self):
        cases = [r"extra=\u", r"extra=\u0", r"extra=\u123", r"extra=\u12x4",
                 r"extra=\uu1234", r"extra=\u+123", r"extra=\uＦFFF", r"\u12x4=value",
                 "extra=prefix\\\n" + r"\u12x4"]
        for text in cases:
            with self.subTest(case=text):
                self.path.write_bytes((self.BASE + text).encode("utf-8"))
                self.assertIsNone(self.oracle())
                with self.assertRaisesRegex(ValueError, "Unicode 转义无效") as error:
                    release.signing_properties(self.path)
                self.assertNotIn(text, str(error.exception))

    def test_signing_fields_must_be_complete_but_explicit_spaces_are_not_trimmed(self):
        for field in ("storeFile", "storePassword", "keyAlias", "keyPassword"):
            for text in (self.BASE + field + "=\n",
                         "\n".join(line for line in self.BASE.splitlines() if not line.startswith(field + "="))):
                with self.subTest(field=field, text=text):
                    self.path.write_text(text, encoding="utf-8")
                    with self.assertRaisesRegex(ValueError, "签名配置不完整"):
                        release.signing_properties(self.path)
        self.path.write_text(self.BASE + r"storePassword=\ " + "\n", encoding="utf-8")
        self.assertEqual(release.signing_properties(self.path)["storePassword"], " ")


class SigningInputTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="clash-signing-input-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "android").mkdir()
        self.environment = {
            "CLASH_PSEUDO_ANDROID_KEYSTORE_BASE64": base64.b64encode(b"synthetic key").decode("ascii"),
            "CLASH_PSEUDO_ANDROID_KEYSTORE_PASSWORD": "synthetic store password",
            "CLASH_PSEUDO_ANDROID_KEY_ALIAS": "release",
            "CLASH_PSEUDO_ANDROID_KEY_PASSWORD": "synthetic key password",
        }

    def local(self, *, absolute=False):
        store = self.root / "android/stores/synthetic.jks"
        store.parent.mkdir()
        store.write_bytes(b"synthetic local key")
        value = str(store) if absolute else "stores/synthetic.jks"
        (self.root / "android/key.properties").write_text(
            "storeFile=" + value + "\nstorePassword==abc\nkeyAlias=local release\nkeyPassword=local key password\n",
            encoding="utf-8")
        return store

    def test_any_partial_or_empty_environment_cannot_mix_with_local_properties(self):
        self.local()
        names = list(self.environment)
        cases = [{name: self.environment[name] for index, name in enumerate(names) if mask & (1 << index)}
                 for mask in range(1, 15)]
        cases.extend({**self.environment, name: ""} for name in names)
        cases.extend({name: ""} for name in names)
        cases.append(dict.fromkeys(names, ""))
        for environment in cases:
            with self.subTest(provided=list(environment), empty=[name for name, value in environment.items() if not value]), \
                    mock.patch.dict(os.environ, environment, clear=True), \
                    mock.patch.object(release, "signing_properties") as local, \
                    mock.patch.object(release.update, "run") as process, \
                    self.assertRaisesRegex(ValueError, "四个签名环境变量必须完整提供"):
                try:
                    release.signing_digest(self.root)
                finally:
                    local.assert_not_called()
                    process.assert_not_called()

    def test_invalid_base64_never_falls_back_or_echoes_input(self):
        self.local()
        for encoded in ("not base64", "☃", "====", "AA=A", "A", "AAAA=", "YQ=", "YQ===", "YWI==",
                        self.environment["CLASH_PSEUDO_ANDROID_KEYSTORE_BASE64"] + "\n"):
            with self.subTest(encoded=encoded), \
                    mock.patch.dict(os.environ, {**self.environment, "CLASH_PSEUDO_ANDROID_KEYSTORE_BASE64": encoded}, clear=True), \
                    mock.patch.object(release, "signing_properties") as local, \
                    mock.patch.object(release.update, "run") as process:
                with self.assertRaisesRegex(ValueError, "Base64 无效") as error:
                    release.signing_digest(self.root)
                self.assertNotIn(encoded, str(error.exception))
                local.assert_not_called()
                process.assert_not_called()

    def test_complete_environment_accepts_java_base64_with_or_without_padding(self):
        self.local()
        for data in (b"k", b"ke", b"key"):
            padded = base64.b64encode(data).decode("ascii")
            for encoded in (padded, padded.rstrip("=")):
                stores = []
                def certificate(command, cwd, env):
                    store = Path(command[command.index("-keystore") + 1])
                    stores.append(store)
                    self.assertEqual(store.read_bytes(), data)
                    return "pem"
                with self.subTest(encoded=encoded), \
                        mock.patch.dict(os.environ, {**self.environment, "CLASH_PSEUDO_ANDROID_KEYSTORE_BASE64": encoded}, clear=True), \
                        mock.patch.object(release, "signing_properties") as local, \
                        mock.patch.object(release.update, "run", side_effect=certificate), \
                        mock.patch.object(release.ssl, "PEM_cert_to_DER_cert", return_value=b"certificate"):
                    self.assertEqual(release.signing_digest(self.root), hashlib.sha256(b"certificate").hexdigest())
                    local.assert_not_called()
                self.assertEqual(len(stores), 1)
                self.assertFalse(stores[0].parent.exists())

    def test_local_fallback_resolves_store_from_properties_directory(self):
        for absolute in (False, True):
            with self.subTest(absolute=absolute):
                store = self.local(absolute=absolute)
                with mock.patch.dict(os.environ, {}, clear=True), \
                        mock.patch.object(release.update, "run", return_value="pem") as process, \
                        mock.patch.object(release.ssl, "PEM_cert_to_DER_cert", return_value=b"certificate"):
                    self.assertEqual(release.signing_digest(self.root), hashlib.sha256(b"certificate").hexdigest())
                command = process.call_args.args[0]
                self.assertEqual(Path(command[command.index("-keystore") + 1]), store)
                self.assertEqual(command[-1], "local release")
                self.assertEqual(process.call_args.kwargs["env"], {"CLASH_PSEUDO_ANDROID_KEYSTORE_PASSWORD": "=abc"})
                self.assertNotIn("=abc", command)
                self.assertNotIn("local key password", command)
                self.assertEqual(store.read_bytes(), b"synthetic local key")
                store.unlink()
                store.parent.rmdir()

    def test_missing_local_signing_and_required_distribution_environment_fail_closed(self):
        with mock.patch.dict(os.environ, {}, clear=True), \
                mock.patch.object(release.update, "run") as process, \
                self.assertRaisesRegex(ValueError, "均不可用"):
            release.signing_digest(self.root)
        process.assert_not_called()
        store = self.local()
        with mock.patch.dict(os.environ, {"CLASH_REQUIRE_DISTRIBUTION_SIGNING": "true"}, clear=True), \
                mock.patch.object(release.update, "run") as process, \
                self.assertRaisesRegex(ValueError, "正式分发必须提供"):
            release.signing_digest(self.root)
        process.assert_not_called()
        self.assertTrue(store.is_file())

    def test_missing_local_store_fails_before_keytool(self):
        self.local().unlink()
        with mock.patch.dict(os.environ, {}, clear=True), \
                mock.patch.object(release.update, "run") as process, \
                self.assertRaisesRegex(ValueError, "签名密钥文件缺失"):
            release.signing_digest(self.root)
        process.assert_not_called()

    def test_nul_in_selected_environment_values_fails_without_local_fallback(self):
        for name in self.environment:
            # 用普通映射提供含NUL的签名配置，检查工具是否拒绝无效字符；os._Environ会在赋值时拒绝NUL。
            with self.subTest(name=name), \
                    mock.patch.object(release.os, "environ", {**self.environment, name: "invalid\0value"}), \
                    mock.patch.object(release, "signing_properties") as local, \
                    mock.patch.object(release.tempfile, "TemporaryDirectory") as temporary, \
                    mock.patch.object(release.update, "run") as process, \
                    self.assertRaisesRegex(ValueError, "签名配置包含无效字符"):
                release.signing_digest(self.root)
            local.assert_not_called()
            temporary.assert_not_called()
            process.assert_not_called()

    def test_nul_in_each_local_field_fails_without_changing_local_material(self):
        store = self.local()
        properties = self.root / "android/key.properties"
        original = properties.read_text(encoding="utf-8")
        for name in ("storeFile", "storePassword", "keyAlias", "keyPassword"):
            data = (original + name + r"=invalid\u0000value" + "\n").encode("utf-8")
            properties.write_bytes(data)
            with self.subTest(name=name), mock.patch.dict(os.environ, {}, clear=True), \
                    mock.patch.object(release.update, "run") as process, \
                    self.assertRaisesRegex(ValueError, "签名配置包含无效字符") as error:
                release.signing_digest(self.root)
            process.assert_not_called()
            self.assertNotIn("invalid", str(error.exception))
            self.assertEqual(properties.read_bytes(), data)
            self.assertEqual(store.read_bytes(), b"synthetic local key")

    def test_environment_passwords_and_alias_are_not_trimmed(self):
        self.local()
        environment = {**self.environment,
                       "CLASH_PSEUDO_ANDROID_KEYSTORE_PASSWORD": " \tpassword \t",
                       "CLASH_PSEUDO_ANDROID_KEY_ALIAS": " \talias \t",
                       "CLASH_PSEUDO_ANDROID_KEY_PASSWORD": " \t"}
        stores = []
        def certificate(command, cwd, env):
            store = Path(command[command.index("-keystore") + 1])
            stores.append(store)
            self.assertEqual(store.read_bytes(), b"synthetic key")
            self.assertEqual(command[-1], environment["CLASH_PSEUDO_ANDROID_KEY_ALIAS"])
            self.assertEqual(env, {"CLASH_PSEUDO_ANDROID_KEYSTORE_PASSWORD": environment["CLASH_PSEUDO_ANDROID_KEYSTORE_PASSWORD"]})
            return "pem"
        with mock.patch.dict(os.environ, environment, clear=True), \
                mock.patch.object(release, "signing_properties") as local, \
                mock.patch.object(release.update, "run", side_effect=certificate), \
                mock.patch.object(release.ssl, "PEM_cert_to_DER_cert", return_value=b"certificate"):
            self.assertEqual(release.signing_digest(self.root), hashlib.sha256(b"certificate").hexdigest())
        local.assert_not_called()
        self.assertEqual(len(stores), 1)
        self.assertFalse(stores[0].parent.exists())

    def test_keytool_and_certificate_errors_preserve_original_error_and_remove_temporary_key(self):
        self.local()
        for stage in ("keytool", "certificate"):
            failure = ValueError("synthetic " + stage + " failure")
            stores = []
            def certificate(command, cwd, env):
                store = Path(command[command.index("-keystore") + 1])
                stores.append(store)
                self.assertEqual(store.read_bytes(), b"synthetic key")
                self.assertEqual(stat.S_IMODE(store.stat().st_mode), 0o600)
                if stage == "keytool":
                    raise failure
                return "pem"
            with self.subTest(stage=stage), mock.patch.dict(os.environ, self.environment, clear=True), \
                    mock.patch.object(release.update, "run", side_effect=certificate), \
                    mock.patch.object(release.ssl, "PEM_cert_to_DER_cert", side_effect=failure), \
                    mock.patch.object(release, "signing_properties") as local:
                with self.assertRaises(ValueError) as error:
                    release.signing_digest(self.root)
                self.assertIs(error.exception, failure)
                local.assert_not_called()
            self.assertEqual(len(stores), 1)
            self.assertFalse(stores[0].exists())
            self.assertFalse(stores[0].parent.exists())

    def test_partial_temporary_key_write_is_cleaned_without_running_keytool(self):
        original_write = Path.write_bytes
        failure = OSError("synthetic write failure")
        stores = []
        def write(path, data):
            stores.append(path)
            original_write(path, data[:1])
            raise failure
        with mock.patch.dict(os.environ, self.environment, clear=True), \
                mock.patch.object(Path, "write_bytes", autospec=True, side_effect=write), \
                mock.patch.object(release.update, "run") as process:
            with self.assertRaises(OSError) as error:
                release.signing_digest(self.root)
            self.assertIs(error.exception, failure)
        process.assert_not_called()
        self.assertEqual(len(stores), 1)
        self.assertFalse(stores[0].exists())
        self.assertFalse(stores[0].parent.exists())


class PublicSuffixReleaseTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="clash-release-psl-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.evidence = self.root / "evidence"
        self.evidence.mkdir()
        self.source = self.root / "selected-xnet.zip"
        self.source.write_bytes(b"synthetic source archive")
        self.selected = {"Path": "golang.org/x/net", "Version": "v0.35.0", "Sum": "h1:synthetic"}
        self.modules = {"golang.org/x/net": self.selected}
        self.metadata = {**self.selected, "Zip": str(self.source)}
        self.updater = mock.Mock(root=self.root, go="go")
        self.updater.go_run.return_value = json.dumps(self.metadata)

    def test_selected_original_zip_is_resolved_only_through_offline_go_metadata(self):
        with mock.patch.object(release.update.artifacts, "go_modules", return_value=self.modules) as graph:
            self.assertEqual(release.xnet_source(self.updater, self.evidence), self.source)
        graph.assert_called_once_with(self.evidence / "go-modules.json")
        self.updater.go_run.assert_called_once_with(
            "mod", "download", "-json", "golang.org/x/net@v0.35.0",
            env={"GOPROXY": "off", "GOSUMDB": "off", "GONOPROXY": "none"})

    def test_versioned_replace_selects_its_own_original_zip_and_sum(self):
        replacement = {"Path": "example.com/selected/net", "Version": "v1.2.3", "Sum": "h1:replacement"}
        self.selected["Replace"] = replacement
        self.updater.go_run.return_value = json.dumps({**replacement, "Zip": str(self.source)})
        with mock.patch.object(release.update.artifacts, "go_modules", return_value=self.modules):
            self.assertEqual(release.xnet_source(self.updater, self.evidence), self.source)
        self.updater.go_run.assert_called_once_with(
            "mod", "download", "-json", "example.com/selected/net@v1.2.3",
            env={"GOPROXY": "off", "GOSUMDB": "off", "GONOPROXY": "none"})

    def test_missing_selected_module_version_or_sum_fails_before_go(self):
        cases = [{}, {"golang.org/x/net": {**self.selected, "Version": ""}},
                 {"golang.org/x/net": {**self.selected, "Sum": ""}},
                 {"golang.org/x/net": {key: value for key, value in self.selected.items() if key != "Sum"}}]
        for modules in cases:
            with self.subTest(modules=modules), \
                    mock.patch.object(release.update.artifacts, "go_modules", return_value=modules), \
                    self.assertRaisesRegex(ValueError, "缺少"):
                release.xnet_source(self.updater, self.evidence)
        self.updater.go_run.assert_not_called()

    def test_missing_empty_or_wrong_source_metadata_cannot_skip_verification(self):
        empty = self.root / "empty.zip"
        empty.touch()
        cases = [({**self.metadata, "Sum": "h1:wrong"}, "x/net 原始源码的 h1 校验值与发布核验记录不一致"),
                 ({key: value for key, value in self.metadata.items() if key != "Sum"}, "x/net 原始源码的 h1 校验值与发布核验记录不一致"),
                 ({key: value for key, value in self.metadata.items() if key != "Zip"}, "找不到所选 x/net 版本的非空原始源码 ZIP 文件"),
                 ({**self.metadata, "Zip": ""}, "找不到所选 x/net 版本的非空原始源码 ZIP 文件"),
                 ({**self.metadata, "Zip": str(self.root / "missing.zip")}, "找不到所选 x/net 版本的非空原始源码 ZIP 文件"),
                 ({**self.metadata, "Zip": str(self.root)}, "找不到所选 x/net 版本的非空原始源码 ZIP 文件"),
                 ({**self.metadata, "Zip": str(empty)}, "找不到所选 x/net 版本的非空原始源码 ZIP 文件"),
                 ({**self.metadata, "Error": "synthetic cache metadata failure"}, "synthetic cache metadata failure")]
        for metadata, message in cases:
            self.updater.go_run.return_value = json.dumps(metadata)
            with self.subTest(metadata=metadata), \
                    mock.patch.object(release.update.artifacts, "go_modules", return_value=self.modules), \
                    self.assertRaisesRegex(ValueError, message):
                release.xnet_source(self.updater, self.evidence)
        self.assertEqual(self.source.read_bytes(), b"synthetic source archive")

    def test_offline_go_failure_keeps_original_error_without_another_source(self):
        failure = ValueError("synthetic offline Go failure")
        self.updater.go_run.side_effect = failure
        with mock.patch.object(release.update.artifacts, "go_modules", return_value=self.modules), \
                self.assertRaises(ValueError) as error:
            release.xnet_source(self.updater, self.evidence)
        self.assertIs(error.exception, failure)
        self.updater.go_run.assert_called_once()

    def test_malformed_go_metadata_keeps_the_actual_json_error(self):
        self.updater.go_run.return_value = "synthetic invalid json"
        with mock.patch.object(release.update.artifacts, "go_modules", return_value=self.modules), \
                self.assertRaises(json.JSONDecodeError) as error:
            release.xnet_source(self.updater, self.evidence)
        self.assertEqual(error.exception.doc, "synthetic invalid json")
        self.updater.go_run.assert_called_once()

    def test_apk_verifier_receives_original_zip_and_keeps_psl_verification_failure(self):
        failure = ValueError("synthetic x/net h1 or PSL revision failure")
        def run(command, cwd):
            tool = Path(command[0]).name
            if tool == "aapt":
                return "package: name='io.github.monadboxlab.clashpseudo' versionCode='4' versionName='0.2.0'"
            if tool == "apksigner":
                return "Signer #1 certificate SHA-256 digest: abcdef"
            self.assertEqual(tool, "zipalign")
            return ""
        with mock.patch.object(release.update.artifacts, "go_modules", return_value=self.modules), \
                mock.patch.object(release, "sdk_tools", return_value=self.root / "tools"), \
                mock.patch.object(release.update, "run", side_effect=run), \
                mock.patch.object(release.update.artifacts, "verify", side_effect=failure) as verify, \
                self.assertRaises(ValueError) as error:
            release.verify_apk(self.updater, self.root / "synthetic.apk", self.evidence,
                               self.root / "verification", "0.2.0+4", "abcdef", ("arm64-v8a",))
        self.assertIs(error.exception, failure)
        verify.assert_called_once()
        inputs = verify.call_args.args[0]
        self.assertEqual(inputs.xnet_source, self.source)
        self.assertEqual(inputs.go_modules, self.evidence / "go-modules.json")
        self.assertEqual(inputs.abis, ("arm64-v8a",))

    def test_missing_zip_stops_before_apk_tools_or_optional_verifier_path(self):
        self.updater.go_run.return_value = json.dumps(self.selected)
        with mock.patch.object(release.update.artifacts, "go_modules", return_value=self.modules), \
                mock.patch.object(release, "sdk_tools") as tools, \
                mock.patch.object(release.update, "run") as process, \
                mock.patch.object(release.update.artifacts, "verify") as verify, \
                self.assertRaisesRegex(ValueError, "找不到所选 x/net 版本的非空原始源码 ZIP 文件"):
            release.verify_apk(self.updater, self.root / "synthetic.apk", self.evidence,
                               self.root / "verification", "0.2.0+4", "abcdef", ("arm64-v8a",))
        tools.assert_not_called()
        process.assert_not_called()
        verify.assert_not_called()
        self.assertFalse((self.root / "verification").exists())


class SourcePackageTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_application_worktree_contains_uncommitted_inputs_and_excludes_local_sdk_location(self):
        subprocess.run(["git", "init", "-q", self.root], check=True, capture_output=True)
        (self.root / "pubspec.yaml").write_text("version: 1.1.0+2\n")
        android = self.root / "android"
        android.mkdir()
        (android / "local.properties").write_text("flutter.sdk=/private/sdk\n")
        (self.root / ".gitignore").write_text("android/local.properties\n")
        subprocess.run(["git", "-C", self.root, "add", "."], check=True, capture_output=True)
        (self.root / "uncommitted.dart").write_text("new source\n")
        output = self.root.parent / (self.root.name + "-application.tar")
        self.addCleanup(output.unlink, missing_ok=True)
        packager.application_tar(self.root, output, None)
        with tarfile.open(output) as archive:
            self.assertEqual(archive.extractfile("application/uncommitted.dart").read(), b"new source\n")
            self.assertFalse(any(name.endswith("local.properties") for name in archive.getnames()))

    def test_untracked_private_build_material_is_rejected_before_packaging(self):
        subprocess.run(["git", "init", "-q", self.root], check=True, capture_output=True)
        (self.root / "android").mkdir()
        (self.root / "pubspec.yaml").write_text("version: 1.1.0+2\n")
        (self.root / "release.keystore").write_bytes(b"private signing material")
        output = self.root / "application.tar"
        with self.assertRaisesRegex(ValueError, "私有构建材料"):
            packager.application_tar(self.root, output, None)
        self.assertFalse(output.exists())

    def test_private_build_material_names_include_root_properties(self):
        for name in ("signing.JKS", "release.keystore", "key.properties", "android/key.properties", "local.properties"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "私有构建材料"):
                packager.check_private_inputs([name])

    def test_tar_entries_use_fixed_metadata_and_forbid_parent_paths(self):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w") as archive:
            packager.add_bytes(archive, "source/LICENSE", b"original\r\n")
            with self.assertRaisesRegex(ValueError, "归档路径无效"):
                packager.add_bytes(archive, "../outside", b"bad")
        data.seek(0)
        with tarfile.open(fileobj=data) as archive:
            info = archive.getmember("source/LICENSE")
            self.assertEqual(info.mtime, 0)
            self.assertEqual(archive.extractfile(info).read(), b"original\r\n")

    def test_maven_metadata_component_keeps_pom_without_inventing_source_archive(self):
        pom = b'<project xmlns="http://maven.apache.org/POM/4.0.0"><packaging>pom</packaging></project>'
        with mock.patch.object(packager.update, "fetch", return_value=pom) as fetch:
            result = packager.maven_sources("org.example:metadata:1.0")
        self.assertEqual(result, {"metadata-1.0.pom": pom})
        self.assertEqual(fetch.call_count, 1)


if __name__ == "__main__":
    unittest.main()
