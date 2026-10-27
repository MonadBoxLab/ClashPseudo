"""自动发布的版本、续跑、资产归属和对应源码回归。"""

from contextlib import redirect_stderr
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock


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
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.version = "1.1.0+2"
        self.kernel = "v1.19.33"
        self.commit = "a" * 40
        (self.root / "pubspec.yaml").write_text("version: " + self.version + "\n")

    def record(self, *, draft=False, missing=()):
        return {"draft": draft, "prerelease": self.version.startswith("0."),
                "body": release.metadata(self.version, self.kernel, self.commit),
                "assets": [{"name": name, "state": "uploaded"} for name in release.names(self.version)
                           if name not in missing]}

    def preparation(self):
        return release.ReleasePreparation(self.root, "main", "owner/repo", self.root)

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
                updater = mock.Mock()
                updater.go_updates.return_value = {}
                updater.pub_updates.return_value = {}
                updater.android_updates.return_value = {}
                def copy(root, destination):
                    (destination / "pubspec.yaml").write_bytes((root / "pubspec.yaml").read_bytes())
                with mock.patch.object(release, "signing_digest", return_value="certificate"), \
                        mock.patch.object(release, "check_version"), \
                        mock.patch.object(release.update, "copy_workspace", side_effect=copy), \
                        mock.patch.object(release.update, "Updater", return_value=updater):
                    result = preparation.execute(self.kernel, bump="stable")
                self.assertEqual(result["version"], "1.0.0+4")
                self.assertEqual((self.root / "pubspec.yaml").read_text(), "version: 1.0.0+4\n")
                preparation.git.assert_any_call("push", "--atomic", "origin", "HEAD:refs/heads/main",
                                               "refs/tags/v1.0.0+4")
                updater.go_updates.assert_called_once_with([], None)
                updater.legal.assert_not_called()

    def test_development_major_is_rejected_before_reusing_unpublished_version(self):
        (self.root / "pubspec.yaml").write_text("version: 0.1.0+3\n")
        preparation = self.preparation()
        preparation.git = mock.Mock(return_value=self.commit)
        with mock.patch.object(release, "signing_digest", return_value="certificate"), \
                mock.patch.object(preparation, "artifacts") as build, \
                self.assertRaisesRegex(ValueError, "明确选择 stable"):
            preparation.execute(self.kernel, bump="major")
        build.assert_not_called()
        self.assertEqual((self.root / "pubspec.yaml").read_text(), "version: 0.1.0+3\n")
        self.assertFalse(any(call.args[0] in ("push", "tag") for call in preparation.git.call_args_list))

    def test_foreign_or_ambiguous_release_ownership_is_rejected(self):
        for suffix in ("wrong", self.commit + "suffix", self.commit + "\nSource: another"):
            record = self.record()
            record["body"] = record["body"].replace("Source: " + self.commit, "Source: " + suffix)
            with self.subTest(suffix=suffix), self.assertRaisesRegex(ValueError, "源码归属不同"):
                release.check_release(record, self.version, self.kernel, self.commit)

    def test_checksum_manifest_checks_exact_asset_set_and_preserves_bytes(self):
        name = release.names(self.version)[0]
        path = self.root / name
        path.write_bytes(b"signed APK bytes")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        manifest = digest + "  " + name + "\n"
        self.assertEqual(release.verify_sums(manifest, [name], {name: path}), {name: digest})
        with self.assertRaisesRegex(ValueError, "资产摘要不同"):
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
                mock.patch.object(preparation, "artifacts") as build, mock.patch.object(release.update, "execute") as update:
            result = preparation.execute(self.kernel)
        self.assertEqual(result, {"status": "unchanged", "version": self.version, "kernel": self.kernel})
        build.assert_not_called()
        update.assert_not_called()

    def test_prepared_feature_release_reuses_version_while_updating_kernel(self):
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
        with mock.patch.object(release, "signing_digest", return_value="certificate"), \
                mock.patch.object(release, "check_version"), \
                mock.patch.object(release.update, "execute", return_value={"files": ["go.mod"]}) as update:
            result = preparation.execute(self.kernel, bump="minor")
        self.assertTrue(update.call_args.args[0].reuse_version)
        self.assertEqual(result["version"], "1.1.0+2")
        self.assertEqual(result["tag"], "v1.1.0+2")
        self.assertEqual((self.root / "pubspec.yaml").read_text(), "version: 1.1.0+2\n")
        preparation.git.assert_any_call("push", "--atomic", "origin", "HEAD:refs/heads/main", "refs/tags/v1.1.0+2")

    def test_incomplete_release_resumes_original_version_even_when_newer_kernel_exists(self):
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
        with mock.patch.object(release, "signing_digest", return_value="certificate"), \
                mock.patch.object(release.update, "execute") as update:
            result = preparation.execute("v1.19.34")
        update.assert_not_called()
        preparation.git.assert_any_call("checkout", "--detach", self.commit)
        self.assertEqual(result["version"], self.version)
        self.assertEqual(result["kernel"], self.kernel)
        self.assertTrue(preparation.artifacts.call_args.kwargs["checked"])
        self.assertFalse(any(call.args[0] == "push" for call in preparation.git.call_args_list))

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
        self.assertIn("下载体积较大", notes)
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

    def test_four_packages_build_with_one_functional_test_run(self):
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
        preparation.tests.assert_called_once_with(self.root)
        self.assertEqual(process.call_count, 2)
        self.assertNotIn("--split-per-abi", process.call_args_list[0].args[0])
        self.assertIn("--split-per-abi", process.call_args_list[1].args[0])
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
                mock.patch.object(release, "verify_apk", return_value={}):
            preparation.artifacts(self.root, self.version, "certificate", before, checked=True)
        preparation.tests.assert_not_called()
        process.assert_not_called()
        self.assertTrue(all(path.read_bytes() == b"original signed bytes" for path in before.values()))

    def test_split_with_different_native_library_is_rejected(self):
        preparation = self.preparation()
        preparation.updater.evidence = mock.Mock()
        before = {name: self.root / name for name in release.apk_targets(self.version)}
        fingerprints = [{"arm64-v8a": "universal"}, {"arm64-v8a": "different"}]
        with mock.patch.object(release, "verify_apk", side_effect=fingerprints), \
                self.assertRaisesRegex(ValueError, "原生库不同"):
            preparation.artifacts(self.root, self.version, "certificate", before)

    def test_signing_secrets_are_passed_by_environment_name(self):
        with mock.patch.dict(os.environ, {"CLASH_SIGNING_STORE_FILE": str(self.root / "key.jks"),
                                         "CLASH_SIGNING_STORE_PASSWORD": "private password",
                                         "CLASH_SIGNING_KEY_ALIAS": "release",
                                         "CLASH_SIGNING_KEY_PASSWORD": "private key password"}):
            (self.root / "key.jks").write_bytes(b"key")
            with mock.patch.object(release.update, "run", return_value="pem certificate") as process, \
                    mock.patch.object(release.ssl, "PEM_cert_to_DER_cert", return_value=b"certificate"):
                digest = release.signing_digest(self.root)
        self.assertEqual(digest, hashlib.sha256(b"certificate").hexdigest())
        command = process.call_args.args[0]
        self.assertIn("-storepass:env", command)
        self.assertNotIn("private password", command)
        self.assertNotIn("private key password", command)

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
