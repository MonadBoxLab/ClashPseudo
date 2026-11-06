"""候选测试与 release 构建编排回归。"""

import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import tool_test_support
from tool.dependencies import validation
from tool.artifacts import android_apk as apk_tools


class ValidationTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.root = self.base / "project"
        self.root.mkdir()
        self.output = self.base / "result"
        self.updater = mock.Mock(root=self.root, go="go", flutter="flutter", env={})
        self.updater.go_run.return_value = "v1.0.0\n"
        self.environment = {**os.environ, "GOTOOLCHAIN": "local"}
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(mock.patch.object(validation, "_prepare", return_value=(self.environment, self.updater)))
        self.stack.enter_context(mock.patch.object(validation, "input_identity", return_value={"pubspec.yaml": "fixed"}))
        self.stack.enter_context(mock.patch.object(validation, "run", return_value="candidate\n"))
        self.stack.enter_context(mock.patch.object(validation, "application_version", return_value="1.0.0+1"))
        self.stack.enter_context(mock.patch.object(validation.resources, "prepare_bundled_assets"))

    def metadata(self, labels=("universal", *validation.ABIS)):
        directory = self.root / "build/app/outputs/apk/release"
        directory.mkdir(parents=True, exist_ok=True)
        elements = []
        for label in labels:
            name = label + ".apk"
            (directory / name).write_bytes(("APK " + label).encode())
            elements.append({"filters": [] if label == "universal" else [{"filterType": "ABI", "value": label}],
                             "outputFile": name})
        path = directory / "output-metadata.json"
        path.write_text(json.dumps({"elements": elements}))
        return path

    def test_validation_runs_tests_without_an_apk_build(self):
        with mock.patch.object(validation, "_command") as command:
            result = validation.validate(self.root, self.output)
        self.assertEqual(result["status"], "verified")
        self.assertEqual(result["commit"], "candidate")
        calls = [list(map(str, item.args[0])) for item in command.call_args_list]
        self.assertEqual(len(calls), 8)
        self.assertFalse(any("apk" in row for row in calls))
        self.assertTrue(any("verify" in row and "mod" in row for row in calls))
        self.assertTrue(any("-tags=cmfa,with_gvisor" in row and "test" in row for row in calls))
        self.updater.evidence.assert_not_called()

    def test_test_failure_is_saved_and_stops_remaining_commands(self):
        with mock.patch.object(validation, "_command", side_effect=ValueError("原始工具错误")) as command:
            with self.assertRaisesRegex(ValueError, "原始工具错误"):
                validation.validate(self.root, self.output)
        self.assertEqual(command.call_count, 1)
        report = json.loads((self.output / "validation.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["error"], "原始工具错误")

    def test_existing_report_is_not_overwritten(self):
        self.output.mkdir()
        report = self.output / "validation.json"
        report.write_text("previous")
        with self.assertRaises(FileExistsError):
            validation.validate(self.root, self.output)
        self.assertEqual(report.read_text(), "previous")

    def test_output_cannot_be_inside_project(self):
        with self.assertRaisesRegex(ValueError, "项目之外"):
            validation.validate(self.root, self.root / "result")
        self.assertFalse((self.root / "result").exists())

    def test_toolchain_failure_is_recorded(self):
        with mock.patch.object(validation, "_prepare", side_effect=ValueError("下载失败")):
            with self.assertRaisesRegex(ValueError, "下载失败"):
                validation.validate(self.root, self.output)
        self.assertEqual(json.loads((self.output / "validation.json").read_text())["error"], "下载失败")

    def test_input_change_fails_validation(self):
        with mock.patch.object(validation, "_command"), \
                mock.patch.object(validation, "input_identity", side_effect=[{"a": "first"}, {"a": "second"}]):
            with self.assertRaisesRegex(ValueError, "候选输入发生变化"):
                validation.validate(self.root, self.output)

    def test_release_build_produces_four_apks_and_source_assets_once(self):
        self.metadata()

        def sources(updater, evidence, output, version, commit):
            self.assertEqual(commit, "candidate")
            names = [f"clash-pseudo-{version}-sources.tar.gz", f"clash-pseudo-{version}-licenses.tar.gz"]
            for name in names:
                (output / name).write_bytes(name.encode())
            return names

        with mock.patch.object(validation, "_command") as command, \
                mock.patch.object(validation, "_source_assets", side_effect=sources), \
                mock.patch.object(apk_tools, "verify_apk") as verify:
            result = validation.build_release(self.root, self.output, commit="candidate")
        command.assert_called_once()
        arguments = command.call_args.args[0]
        self.assertIn("--release", arguments)
        self.assertIn("--split-per-abi", arguments)
        self.assertNotIn("--debug", arguments)
        self.assertEqual(verify.call_count, 4)
        self.assertEqual(result["status"], "built")
        self.assertEqual(len(result["assets"]), 7)
        self.assertNotIn("build.json", result["assets"])
        for line in (self.output / "SHA256SUMS").read_text().splitlines():
            digest, name = line.split("  ", 1)
            self.assertEqual(digest, hashlib.sha256((self.output / name).read_bytes()).hexdigest())

    def test_release_build_cannot_use_a_different_commit(self):
        with self.assertRaisesRegex(ValueError, "候选提交不同"):
            validation.build_release(self.root, self.output, commit="other")
        self.updater.evidence.assert_not_called()

    def test_release_build_failure_does_not_package_sources(self):
        with mock.patch.object(validation, "_command", side_effect=ValueError("Gradle 原始错误")), \
                mock.patch.object(validation, "_source_assets") as sources:
            with self.assertRaisesRegex(ValueError, "Gradle 原始错误"):
                validation.build_release(self.root, self.output, commit="candidate")
        sources.assert_not_called()
        self.assertEqual(json.loads((self.output / "build.json").read_text())["status"], "failed")

    def test_apks_follow_gradle_metadata_not_filename_guesses(self):
        path = self.metadata()
        data = json.loads(path.read_text())
        data["elements"][0]["outputFile"] = "renamed-universal.apk"
        path.write_text(json.dumps(data))
        self.assertEqual(validation.release_apks(self.root)["universal"].name, "renamed-universal.apk")

    def test_missing_universal_output_fails(self):
        self.metadata(validation.ABIS)
        with self.assertRaisesRegex(ValueError, "通用及三个"):
            validation.release_apks(self.root)

    def test_metadata_cannot_select_an_outside_apk(self):
        path = self.metadata()
        data = json.loads(path.read_text())
        data["elements"][0]["outputFile"] = "../../outside.apk"
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "路径越界"):
            validation.release_apks(self.root)

    def test_command_preserves_stderr_and_exit_code(self):
        self.output.mkdir()
        report = {"steps": []}
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaisesRegex(ValueError, "失败（7）"):
            validation._command([sys.executable, "-I", "-c", "import sys; print('original error',file=sys.stderr); sys.exit(7)"],
                                self.root, self.environment, self.output, report, "command")
        self.assertEqual(report["steps"][0]["exitCode"], 7)
        self.assertIn("original error", (self.output / "command.log").read_text())


if __name__ == "__main__":
    unittest.main()
