"""验证统一入口、各级帮助、参数边界及隔离模式。"""
import argparse
import contextlib
import importlib
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
from tool import cli

ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / "tool/main.py"


def command_paths(parser, prefix=(), *, groups_only=False):
    groups = [action for action in parser._actions if isinstance(action, argparse._SubParsersAction)]
    if not groups_only or groups:
        yield prefix
    for action in groups:
        for name, child in action.choices.items():
            yield from command_paths(child, (*prefix, name), groups_only=groups_only)


class CliTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tool-cli-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cwd = self.root / "foreign"
        self.cwd.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = dict(os.environ, PATH="/nonexistent", HOME=str(self.home), PYTHONPATH=str(self.cwd))

    def invoke(self, *args, audit=False):
        if audit:
            script = '''import os, runpy, sys
entry, arguments = sys.argv[1], sys.argv[2:]
def audit(event, values):
    if event in ("subprocess.Popen", "os.system", "os.mkdir", "os.remove", "os.rename", "os.rmdir", "socket.__new__", "socket.connect"):
        raise RuntimeError("help side effect: " + event)
    if event == "open":
        mode, flags = values[1:]
        if (isinstance(mode, str) and any(c in mode for c in "wax+")) or flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC):
            raise RuntimeError("help writes a file")
sys.addaudithook(audit)
sys.argv = [entry, *arguments]
runpy.run_path(entry, run_name="__main__")
'''
            command = [sys.executable, "-I", "-B", "-c", script, str(ENTRY), *args]
        else:
            command = [sys.executable, "-I", "-B", str(ENTRY), *args]
        return subprocess.run(command, cwd=self.cwd, env=self.env, text=True, capture_output=True, timeout=15)

    def test_all_help_paths_work_without_toolchains_network_or_writes(self):
        paths = list(command_paths(cli.create_parser()))
        self.assertGreater(len(paths), 25)
        for path in paths:
            for flag in ("-h", "--help"):
                with self.subTest(path=path, flag=flag):
                    result = self.invoke(*path, flag, audit=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("usage:", result.stdout)
                    self.assertIn("--help", result.stdout)
                    self.assertEqual(result.stderr, "")
        self.assertEqual(list(self.home.rglob("*")), [])
        self.assertEqual(list(self.cwd.rglob("*")), [])

    def test_no_command_or_group_only_displays_help_successfully(self):
        for args in command_paths(cli.create_parser(), groups_only=True):
            with self.subTest(args=args):
                result = self.invoke(*args, audit=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("usage:", result.stdout)

    def test_invalid_arguments_are_rejected_before_execution(self):
        cases = [
            ("unknown",),
            ("android", "build-core"),
            ("dependencies", "apply", "--scope", "wrong"),
            ("dependencies", "apply", "--mihomo-version", "v1.0.0"),
            ("dependencies", "apply", "--scope", "mihomo", "--pub", "http"),
            ("dependencies", "apply", "--bump", "patch", "--reuse-version"),
            ("dependencies", "check", "--bump", "patch"),
            ("dependencies", "check", "--go", "other-go"),
            ("dependencies", "apply", "--flutter", "other-flutter"),
            ("dependencies", "check", "--prepared-resources", "/tmp/resources"),
            ("dependencies", "prepare-build", "--bump", "patch"),
            ("dependencies", "prepare-build", "--scope", "all"),
            ("dependencies", "prepare-build", "--off"),
            ("dependencies", "prepare-resource", "--spec", "/tmp/spec.json"),
            ("dependencies", "prepare-resources", "--spec", "/tmp/spec.json", "--destination", "/tmp/output", "--resource-source", "/tmp/file"),
            ("dependencies", "validate"),
            ("contracts", "check", "--asset-output", "/tmp/out"),
            ("contracts", "generate", "--asset-manifest", "/tmp/geo.json"),
            ("artifacts", "verify-backup"),
            ("network", "native-fixture", "--self-test", "--nonce", "test-run-123"),
            ("coverage", "flutter", "validate", "/tmp/output", "test/tool/flutter_coverage_test.dart"),
            ("coverage", "summary", "/tmp/lcov", "--unknown"),
        ]
        for args in cases:
            with self.subTest(args=args):
                result = self.invoke(*args, audit=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("usage:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_foreign_cwd_and_pythonpath_cannot_supply_imported_modules(self):
        for name in ("json.py", "argparse.py", "sitecustomize.py"):
            (self.cwd / name).write_text("raise RuntimeError('untrusted module loaded')\n")
        (self.cwd / "tool").mkdir()
        (self.cwd / "tool/__init__.py").write_text("raise RuntimeError('untrusted tool loaded')\n")
        result = self.invoke("--help", audit=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Clash Pseudo", result.stdout)

    def test_dependency_route_passes_typed_parameters_once(self):
        from tool.dependencies import update
        with mock.patch.object(update, "execute", return_value={"status": "unchanged", "files": []}) as execute:
            with contextlib.redirect_stdout(io.StringIO()) as output:
                status = cli.main(["dependencies", "check", "--project", str(ROOT)])
            self.assertEqual(status, 0)
            self.assertEqual(json.loads(output.getvalue())["status"], "unchanged")
            execute.assert_called_once_with(
                ROOT, apply=False, scope="all", mihomo_version=None,
                toolchain_cache=None, go_module=[], pub=[], android=[], evidence=None,
                prepared_resources=None, reuse_version=False)

    def test_mihomo_selectors_reach_go_update_without_cli_version_rules(self):
        from tool.dependencies import update
        selectors = ("v1.0.0", "v1.0.0-rc.1", "latest", "main", "9a8b7c6", "branch/name")
        for selector in selectors:
            with self.subTest(selector=selector), \
                    mock.patch.object(update, "execute", return_value={"status": "unchanged", "files": []}) as execute, \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(cli.main(["dependencies", "check", "--scope", "mihomo", "--mihomo-version", selector]), 0)
                self.assertEqual(execute.call_args.kwargs["mihomo_version"], selector)
                self.assertEqual(execute.call_args.kwargs["scope"], "mihomo")

    def test_apply_report_and_github_changed_output_follow_real_result(self):
        from tool.dependencies import update
        for status, files, changed in (("unchanged", [], "false"), ("updated", ["native/mihomo/go.mod"], "true")):
            report_path = self.root / status / "report.json"
            output_path = self.root / (status + ".outputs")
            summary_path = self.root / (status + ".summary")
            result = {"status": status, "files": files, "version": "1.0.0+1"}
            with mock.patch.object(update, "execute", return_value=result) as execute, \
                    mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(output_path), "GITHUB_STEP_SUMMARY": str(summary_path)}), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(cli.main(["dependencies", "apply", "--mihomo-version", "", "--report", str(report_path)]), 0)
            self.assertEqual(execute.call_args.kwargs["mihomo_version"], None)
            self.assertEqual(json.loads(report_path.read_text()), result)
            self.assertEqual(output_path.read_text(), f"changed={changed}\n")
            if status == "unchanged":
                self.assertIn("unchanged", summary_path.read_text())
                self.assertIn(result["version"], summary_path.read_text())
            else:
                self.assertFalse(summary_path.exists())

    def test_failed_update_writes_failure_report_without_success_output(self):
        from tool.dependencies import update
        report = self.root / "failure/report.json"
        outputs = self.root / "outputs"
        summary = self.root / "summary"
        with mock.patch.object(update, "execute", side_effect=ValueError("upstream resolution failed")), \
                mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(outputs), "GITHUB_STEP_SUMMARY": str(summary)}), \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            status = cli.main(["dependencies", "apply", "--report", str(report)])
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(report.read_text()), {"status": "failed", "error": "upstream resolution failed"})
        self.assertIn("upstream resolution failed", errors.getvalue())
        self.assertFalse(outputs.exists())
        self.assertFalse(summary.exists())

    def test_candidate_validation_calls_internal_api(self):
        from tool.dependencies import validation
        with mock.patch.object(validation, "validate", return_value={"status": "passed"}) as validate, \
                contextlib.redirect_stdout(io.StringIO()):
            status = cli.main(["dependencies", "validate", "--project", str(ROOT), "--output", "/tmp/validation",
                               "--toolchain-cache", "/tmp/toolchains"])
        self.assertEqual(status, 0)
        validate.assert_called_once_with(ROOT, Path("/tmp/validation"), toolchain_cache=Path("/tmp/toolchains"))

    def test_dart_coverage_delegates_existing_implementations(self):
        with mock.patch("subprocess.run") as run:
            self.assertEqual(cli.main(["coverage", "flutter", "collect", "/tmp/coverage-output", "test/tool/flutter_coverage_test.dart"]), 0)
            command = run.call_args.args[0]
            self.assertEqual(command[:2], ["dart", "run"])
            self.assertEqual(command[2], str(ROOT / "tool/coverage/flutter.dart"))
            self.assertEqual(command[3:], ["collect", "/tmp/coverage-output", "test/tool/flutter_coverage_test.dart"])
            self.assertEqual(run.call_args.kwargs["cwd"], ROOT)

    def test_ordinary_imports_keep_single_module_identity(self):
        for name in ("tool.android.build_core", "tool.contracts.generate", "tool.dependencies.resources",
                     "tool.network.native_fixture", "tool.artifacts.verify_backup"):
            module = importlib.import_module(name)
            self.assertIs(module, importlib.import_module(name))
            aliases = [key for key, value in sys.modules.items() if getattr(value, "__file__", None) == module.__file__]
            self.assertEqual(aliases, [name])

    def test_failed_subprocess_keeps_exit_status_and_original_output(self):
        with mock.patch("subprocess.run", side_effect=subprocess.CalledProcessError(7, ["dart", "run"], output="original stdout", stderr="original stderr")), \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(cli.main(["coverage", "summary", "/tmp/lcov.info"]), 7)
        self.assertIn("original stdout", errors.getvalue())
        self.assertIn("original stderr", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
