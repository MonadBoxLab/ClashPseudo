"""SDK 运行入口的授权边界、参数引用和异步进程身份。"""
import hashlib
import tool_test_support
from tool.cli import parse_args
from tool.android import run_sdk_observer as TOOL
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
APK = b"fixture-only-sdk-apk"
DIGEST = hashlib.sha256(APK).hexdigest()
SERIAL = "owned-avd:12345"


class RunSdkObserverTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sdk-runner-")
        self.root = Path(self.temporary.name)
        self.command_parts = []
        self.changed = False
        self.metadata = "instrumentation:" + TOOL.RUNNER + " (target=" + TOOL.PACKAGE + ")"
        self.exit_code = -1
        self.partial = False

    def tearDown(self):
        self.temporary.cleanup()

    def args(self, *extra):
        return parse_args(["android", "run-sdk-observer"] +["--serial", SERIAL, "--allowed-serial", SERIAL, "--apk-sha256", DIGEST,
                               "--output", str(self.root / "output"), "--action", "snapshot",
                               "--window-package", TOOL.APP, "--label", "Tunnel stopped", *extra])

    def fake(self, command, **kwargs):
        self.assertNotIn("shell", kwargs)
        parts = shlex.split(command[4]) if command[3] == "shell" else command[3:]
        self.command_parts.append(parts)
        data = b""
        if parts[:3] == ["pm", "list", "instrumentation"]:
            data = self.metadata.encode()
        elif parts[:2] == ["pm", "path"]:
            data = b"package:/data/app/owned-test/base.apk\n"
        elif parts[0] == "pull":
            if getattr(self, "read_error", False):
                data = b"adb: error: remote object '/data/app/owned-test/base.apk' does not exist\n"
                if kwargs.get("stdout"):
                    kwargs["stdout"].write(data)
                return subprocess.CompletedProcess(command, 1, data, b"")
            Path(parts[2]).write_bytes(APK)
        elif parts[0] == "getprop":
            data = (("43" if getattr(self, "api_changed", False) else "42")
                    if parts[1] == "ro.build.version.sdk" else "x86_64,arm64-v8a").encode()
        elif parts[0] == "pidof":
            data = b"1234\n"
        elif parts[0] == "cat":
            ticks = "100" if self.changed else "99"
            data = ("1234 (own-app) " + " ".join(["S"] + ["0"] * 18 + [ticks] + ["0"] * 3)).encode()
        elif parts[:2] == ["am", "instrument"]:
            if self.partial:
                data = b"INSTRUMENTATION_STATUS: partial-witness=true\n"
                if kwargs.get("stdout"):
                    kwargs["stdout"].write(data)
                if self.partial == "interrupt":
                    raise KeyboardInterrupt()
                raise subprocess.TimeoutExpired(command, 65, output=data)
            self.changed = getattr(self, "change_after_action", False)
            self.api_changed = getattr(self, "change_device_after_action", False)
            data = ("INSTRUMENTATION_RESULT: sdkActionSucceeded=true\n" +
                    "INSTRUMENTATION_RESULT: api=42\n" +
                    "INSTRUMENTATION_RESULT: configurationUnchanged=" +
                    ("false" if getattr(self, "configuration_changed", False) else "true") + "\n" +
                    "INSTRUMENTATION_CODE: " + str(self.exit_code) + "\n").encode()
        else:
            self.fail("Unexpected device command: " + repr(parts))
        if kwargs.get("stdout"):
            kwargs["stdout"].write(data)
        return subprocess.CompletedProcess(command, 0, data, b"")

    def execute(self, args):
        with mock.patch.object(TOOL.shutil, "which", return_value="fixture-adb"), \
                mock.patch.object(TOOL.subprocess, "run", side_effect=self.fake):
            return TOOL.observe(args)

    def test_snapshot_preserves_exact_json_labels_and_never_uses_a_main_target_runner(self):
        label = "停止接管 ' ; not-a-shell-command"
        result = self.execute(self.args("--label", label))
        self.assertEqual(result["status"], "sdk-witness-completed")
        self.assertEqual(result["mainInstanceBefore"], result["mainInstanceAfter"])
        command = next(p for p in self.command_parts if p[:2] == ["am", "instrument"])
        self.assertEqual(command[-1], TOOL.RUNNER)
        self.assertEqual(json.loads(command[command.index("labelsJson") + 1]), ["Tunnel stopped", label])
        self.assertNotIn("allowUiAction", command)
        self.assertTrue(all("force-stop" not in p and "install" not in p for p in self.command_parts))

    def test_scoped_click_requires_explicit_ack_and_submits_exact_label_once(self):
        label = "Settings\nTab 3 of 3"
        args = parse_args(["android", "run-sdk-observer"] +["--serial", SERIAL, "--allowed-serial", SERIAL, "--action", "click",
                               "--apk-sha256", DIGEST, "--output", str(self.root / "click"),
                               "--window-package", TOOL.APP, "--label", label, "--allow-ui-action"])
        result = self.execute(args)
        self.assertEqual(result["status"], "sdk-witness-completed")
        commands = [c for c in self.command_parts if c[:2] == ["am", "instrument"]]
        self.assertEqual(len(commands), 1)
        self.assertEqual(json.loads(commands[0][commands[0].index("labelsJson") + 1]), [label])
        self.assertIn("allowUiAction", commands[0])

    def test_click_does_not_expand_to_settings_multiple_targets_or_unscoped_tunnel_start(self):
        common = ["--serial", SERIAL, "--allowed-serial", SERIAL, "--action", "click",
                  "--apk-sha256", DIGEST, "--output", str(self.root / "click")]
        for extra in (["--window-package", TOOL.APP, "--label", "Settings"],
                      ["--window-package", "com.android.settings", "--label", "Reset", "--allow-ui-action"],
                      ["--window-package", TOOL.APP, "--label", "Settings", "--label", "Other", "--allow-ui-action"],
                      ["--window-package", TOOL.APP, "--label", "Start tunnel", "--allow-ui-action"]):
            with self.subTest(extra=extra), self.assertRaises(SystemExit):
                parse_args(["android", "run-sdk-observer"] +common + extra)
        self.assertFalse((self.root / "click").exists())

    def test_explicit_authorization_handles_changed_serial_and_device_count(self):
        args = self.args()
        args.serial = "emulator-new"
        args.allowed_serial = ["other-owned:23456", args.serial, "usb-owned"]
        result = self.execute(args)
        self.assertEqual(result["serial"], "emulator-new")
        self.assertEqual(result["allowedSerials"], args.allowed_serial)
        self.assertEqual(result["deviceBefore"], {"api": 42, "abis": ["x86_64", "arm64-v8a"]})
        self.assertEqual(result["deviceAfter"], result["deviceBefore"])

    def test_device_configuration_change_is_not_accepted_as_the_original_device(self):
        self.change_device_after_action = True
        args = self.args()
        with self.assertRaisesRegex(ValueError, "API／ABI"):
            self.execute(args)
        self.assertEqual(json.loads((args.output / "results.json").read_text())["status"], "unconfirmed")
        self.assertEqual(sum(p[:2] == ["am", "instrument"] for p in self.command_parts), 1)

    def test_sdk_configuration_change_is_recorded_with_the_single_action_receipt(self):
        self.configuration_changed = True
        args = self.args()
        result = self.execute(args)
        self.assertEqual(result["status"], "sdk-witness-completed")
        self.assertEqual(result["sdkResult"]["configurationUnchanged"], "false")
        self.assertEqual(sum(p[:2] == ["am", "instrument"] for p in self.command_parts), 1)

    def test_system_output_is_created_without_writing_checkout(self):
        checkout = self.root / "clean-checkout"
        checkout.mkdir()
        args = self.args()
        args.output = self.root / "outputs/snapshot"
        self.assertFalse(args.output.parent.exists())
        with mock.patch.object(TOOL, "ROOT", checkout):
            result = self.execute(args)
        self.assertEqual(result["status"], "sdk-witness-completed")
        self.assertTrue((args.output / "results.json").is_file())
        self.assertEqual(list(checkout.iterdir()), [])

    def test_repository_output_is_rejected_before_any_device_command(self):
        checkout = self.root / "checkout"
        checkout.mkdir()
        output = checkout / "snapshot"
        args = self.args()
        with mock.patch.object(TOOL, "ROOT", checkout):
            with self.assertRaises(SystemExit):
                self.args("--output", str(output))
            args.output = output
            with mock.patch.object(TOOL.subprocess, "run") as run, self.assertRaises(ValueError):
                TOOL.observe(args)
            run.assert_not_called()
        self.assertEqual(list(checkout.iterdir()), [])

    def test_system_temporary_root_itself_is_rejected(self):
        with self.assertRaises(SystemExit):
            self.args("--output", tempfile.gettempdir())

    def test_output_outside_system_temporary_root_is_rejected(self):
        temporary_root = self.root / "system-temp"
        temporary_root.mkdir()
        output = self.root / "outside/snapshot"
        with mock.patch.object(TOOL.tempfile, "gettempdir", return_value=str(temporary_root)), \
                self.assertRaises(SystemExit):
            self.args("--output", str(output))
        self.assertFalse(output.parent.exists())

    def test_main_target_metadata_is_rejected_before_reading_any_apk_or_running_sdk(self):
        self.metadata = "instrumentation:" + TOOL.RUNNER + " (target=" + TOOL.APP + ")"
        with self.assertRaises(ValueError):
            self.execute(self.args())
        self.assertEqual(len(self.command_parts), 1)

    def test_apk_mismatch_does_not_run_the_observer(self):
        args = self.args()
        args.apk_sha256 = "0" * 64
        with self.assertRaisesRegex(ValueError, "摘要不同"):
            self.execute(args)
        self.assertFalse(any(p[:2] == ["am", "instrument"] for p in self.command_parts))

    def test_changed_kernel_instance_is_recorded_without_discarding_the_sdk_receipt(self):
        self.change_after_action = True
        result = self.execute(self.args())
        self.assertEqual(result["status"], "sdk-witness-completed")
        self.assertNotEqual(result["mainInstanceBefore"], result["mainInstanceAfter"])
        self.assertEqual(sum(p[:2] == ["am", "instrument"] for p in self.command_parts), 1)

    def test_instrumentation_failure_or_timeout_is_not_resubmitted_or_reported_as_success(self):
        for name in ("wrong-code", "timeout"):
            with self.subTest(name=name):
                self.command_parts.clear()
                args = self.args()
                args.output = self.root / name
                self.partial = name == "timeout"
                self.exit_code = -10
                with self.assertRaises((ValueError, subprocess.TimeoutExpired)):
                    self.execute(args)
                self.assertEqual(sum(p[:2] == ["am", "instrument"] for p in self.command_parts), 1)
                self.assertEqual(json.loads((args.output / "results.json").read_text())["status"], "unconfirmed")

    def test_unreadable_test_apk_preserves_failure_without_alternate_read_or_sdk_action(self):
        self.read_error = True
        args = self.args()
        with self.assertRaises(subprocess.CalledProcessError):
            self.execute(args)
        self.assertEqual([p[0] for p in self.command_parts], ["pm", "pm", "pull"])
        record = json.loads((args.output / "results.json").read_text())
        self.assertEqual(record["status"], "unconfirmed")
        self.assertIn("does not exist", (args.output / "read-only-test-apk-identity.log").read_text())

    def test_timeout_and_cancel_keep_partial_receipt_and_close_the_actual_log(self):
        original_fake = self.fake
        for mode, error_type in (("timeout", subprocess.TimeoutExpired), ("interrupt", KeyboardInterrupt)):
            with self.subTest(mode=mode):
                self.command_parts.clear()
                self.partial = mode
                args = self.args()
                args.output = self.root / mode
                logs = []

                def checked_fake(command, **kwargs):
                    if kwargs.get("stdout"):
                        logs.append(kwargs["stdout"])
                    return original_fake(command, **kwargs)

                with mock.patch.object(TOOL.shutil, "which", return_value="fixture-adb"), \
                        mock.patch.object(TOOL.subprocess, "run", side_effect=checked_fake), self.assertRaises(error_type):
                    TOOL.observe(args)
                self.assertEqual((args.output / "actual-sdk-action.log").read_bytes(),
                                 b"INSTRUMENTATION_STATUS: partial-witness=true\n")
                self.assertTrue(logs)
                self.assertTrue(all(stream.closed for stream in logs))
                self.assertEqual(sum(p[:2] == ["am", "instrument"] for p in self.command_parts), 1)
                self.assertEqual(json.loads((args.output / "results.json").read_text())["status"], "unconfirmed")

    def test_bad_serial_global_systemui_and_mutation_without_ack_are_rejected(self):
        common = ["--apk-sha256", DIGEST, "--output", str(self.root / "output"), "--allowed-serial", SERIAL]
        for parts in (["--serial", "unauthorized:5555", "--action", "keyguard-state"],
                      ["--serial", SERIAL, "--action", "snapshot", "--window-package", "com.android.systemui", "--label", "Clash Pseudo"],
                      ["--serial", SERIAL, "--action", "start", "--expected-config-name", "owned"]):
            with self.subTest(parts=parts), self.assertRaises(SystemExit):
                parse_args(["android", "run-sdk-observer"] +common + parts)
        self.assertFalse((self.root / "output").exists())


if __name__ == "__main__":
    unittest.main()
