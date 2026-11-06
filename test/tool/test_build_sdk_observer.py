"""self-target SDK 打包适配的显式工具链、可删除输出与失败／中断记录。"""
import tool_test_support
from tool.android import build_sdk_observer as TOOL
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[2]


class BuildSdkObserverTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sdk-builder-")
        self.root = Path(self.temporary.name)
        self.jar = self.root / "chosen-platform.jar"
        self.jar.write_bytes(b"fixture-only")
        self.tools = self.root / "chosen-build-tools"
        self.tools.mkdir()
        for name in ("aapt2", "d8", "zipalign", "apksigner"):
            (self.tools / name).write_bytes(b"fixture-only")
        self.key = self.root / "debug.keystore"
        self.key.write_bytes(b"fixture-only-not-a-signing-key")
        self.output = self.root / "output"
        javac = mock.patch.object(TOOL.shutil, "which", return_value="fixture-javac")
        javac.start()
        self.addCleanup(javac.stop)
        self.commands = []

    def tearDown(self):
        self.temporary.cleanup()

    def build(self, output=None, **kwargs):
        return TOOL.build(self.jar, self.tools, self.key, self.output if output is None else output,
                          java_release=kwargs.get("java_release", 11), min_api=kwargs.get("min_api", 25),
                          target_sdk=kwargs.get("target_sdk", 39), javac="chosen-javac")

    def successful_command(self, command, **kwargs):
        self.commands.append(command)
        if command[0] == "fixture-javac":
            if "--release" in command:
                (Path(command[command.index("-d") + 1]) / "Witness.class").write_bytes(b"class")
            else:
                kwargs["stdout"].write(b"fixture-javac selected-version\n")
        elif Path(command[0]).name == "d8" and "--output" in command:
            (Path(command[command.index("--output") + 1]) / "classes.dex").write_bytes(b"dex")
        elif "link" in command:
            with zipfile.ZipFile(command[command.index("-o") + 1], "w"):
                pass
        elif Path(command[0]).name == "zipalign":
            Path(command[-1]).write_bytes(Path(command[-2]).read_bytes())
        elif "sign" in command:
            Path(command[command.index("--out") + 1]).write_bytes(Path(command[-1]).read_bytes())
        return subprocess.CompletedProcess(command, 0)

    def test_missing_sdk_input_does_not_create_output_or_invoke_a_command(self):
        self.jar.unlink()
        with mock.patch.object(TOOL.subprocess, "run") as run, self.assertRaises(ValueError):
            self.build()
        run.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_repository_output_is_rejected_before_creation(self):
        output = ROOT / "tool/observer-build-not-authorized"
        self.assertFalse(output.exists())
        with mock.patch.object(TOOL.subprocess, "run") as run, self.assertRaises(ValueError):
            self.build(output)
        run.assert_not_called()
        self.assertFalse(output.exists())

    def test_repository_inside_system_temporary_directory_is_rejected(self):
        checkout = self.root / "checkout"
        checkout.mkdir()
        output = checkout / "observer-build"
        with mock.patch.object(TOOL, "ROOT", checkout), \
                mock.patch.object(TOOL.subprocess, "run") as run, self.assertRaises(ValueError):
            self.build(output)
        run.assert_not_called()
        self.assertEqual(list(checkout.iterdir()), [])

    def test_system_temporary_root_itself_is_rejected(self):
        with mock.patch.object(TOOL.subprocess, "run") as run, self.assertRaises(ValueError):
            self.build(Path(tempfile.gettempdir()))
        run.assert_not_called()

    def test_output_outside_system_temporary_root_is_rejected(self):
        temporary_root = self.root / "system-temp"
        temporary_root.mkdir()
        output = self.root / "outside/observer-build"
        with mock.patch.object(TOOL.tempfile, "gettempdir", return_value=str(temporary_root)), \
                mock.patch.object(TOOL.subprocess, "run") as run, self.assertRaises(ValueError):
            self.build(output)
        run.assert_not_called()
        self.assertFalse(output.parent.exists())

    def test_existing_output_is_not_reused_cleaned_or_overwritten(self):
        self.output.mkdir()
        marker = self.output / "original"
        marker.write_bytes(b"preserve")
        with mock.patch.object(TOOL.subprocess, "run") as run, self.assertRaises(FileExistsError):
            self.build()
        run.assert_not_called()
        self.assertEqual(marker.read_bytes(), b"preserve")
        self.assertEqual(list(self.output.iterdir()), [marker])

    def test_explicit_tool_locations_and_versions_drive_the_actual_commands(self):
        with mock.patch.object(TOOL.subprocess, "run", side_effect=self.successful_command):
            result = self.build()
        javac = next(c for c in self.commands if "--release" in c)
        self.assertEqual(javac[javac.index("--release") + 1], "11")
        self.assertEqual(javac[javac.index("-cp") + 1], str(self.jar))
        d8 = next(c for c in self.commands if "--min-api" in c)
        self.assertEqual(d8[d8.index("--min-api") + 1], "25")
        self.assertEqual(d8[0], str(self.tools / "d8"))
        self.assertIn('android:targetSdkVersion="39"', (self.output / "AndroidManifest.xml").read_text())
        self.assertEqual((result["javaRelease"], result["minApi"], result["targetSdk"]), (11, 25, 39))
        self.assertEqual(result["androidJar"], str(self.jar))

    def test_missing_system_output_parent_is_created_without_writing_checkout(self):
        checkout = self.root / "clean-checkout"
        checkout.mkdir()
        output = self.root / "outputs/observer-build"
        self.assertFalse(output.parent.exists())
        with mock.patch.object(TOOL, "ROOT", checkout), \
                mock.patch.object(TOOL.subprocess, "run", side_effect=self.successful_command):
            result = self.build(output)
        self.assertTrue((output / "build.json").is_file())
        self.assertEqual(result["targetSdk"], 39)
        self.assertEqual(list(checkout.iterdir()), [])

    def test_invalid_api_or_java_target_is_rejected_before_creating_output(self):
        for values in ({"min_api": 23}, {"target_sdk": 24}, {"java_release": 0}, {"java_release": True}):
            with self.subTest(values=values), mock.patch.object(TOOL.subprocess, "run") as run, \
                    self.assertRaises(ValueError):
                self.build(**values)
            run.assert_not_called()
            self.assertFalse(self.output.exists())

    def test_command_failure_keeps_evidence_and_never_reports_a_finished_apk(self):
        failure = subprocess.CompletedProcess(["javac"], 17)
        with mock.patch.object(TOOL.subprocess, "run", return_value=failure), self.assertRaises(subprocess.CalledProcessError):
            self.build()
        commands = json.loads((self.output / "commands.json").read_text())
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0]["name"], "javac-version")
        self.assertEqual(commands[0]["exit"], 17)
        self.assertFalse((self.output / "observer.apk").exists())
        self.assertFalse((self.output / "build.json").exists())
        self.assertEqual(self.key.read_bytes(), b"fixture-only-not-a-signing-key")

    def test_timeout_and_interruption_leave_unconfirmed_command_not_success(self):
        for name, failure in [("timeout", subprocess.TimeoutExpired("javac", 120)),
                              ("cancel", KeyboardInterrupt())]:
            output = self.root / name
            with self.subTest(name=name):
                with mock.patch.object(TOOL.subprocess, "run", side_effect=failure), self.assertRaises(type(failure)):
                    self.build(output)
                commands = json.loads((output / "commands.json").read_text())
                self.assertEqual(len(commands), 1)
                self.assertIsNone(commands[0]["exit"])
                self.assertFalse((output / "build.json").exists())
                self.assertFalse((output / "observer.apk").exists())
                with (output / "javac-version.log").open("ab") as stream:
                    stream.write(b"failure evidence retained\n")


if __name__ == "__main__":
    unittest.main()
