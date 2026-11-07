#!/usr/bin/env python3
"""Run the installed SDK observer on the specified device and save results; the observer targets its own test package."""
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
APP = "io.github.monadboxlab.clashpseudo"
PACKAGE = APP + ".test"
RUNNER = PACKAGE + "/" + APP + ".validation.SystemEntryInstrumentation"
ACTIONS = ("keyguard-state", "snapshot", "click", "notification-inspect", "notification-open", "start", "stop")
WINDOWS = (APP, "com.android.settings", "com.android.documentsui", "com.google.android.documentsui",
           "com.android.vpndialogs", "com.android.launcher3", "com.google.android.apps.nexuslauncher")


def _output_path(path):
    output = path.resolve()
    temporary_root = Path(tempfile.gettempdir()).resolve()
    if (output == temporary_root or not output.is_relative_to(temporary_root) or
            output.is_relative_to(ROOT)):
        raise ValueError("Check results and command logs must use a new directory outside the repository under the system temporary directory")
    return output


def register_parser(subparsers):
    parser = subparsers.add_parser(
        "run-sdk-observer", help="Run SDK checks on the specified device", description=__doc__,
        epilog="Example: android run-sdk-observer --serial emulator-5554 --allowed-serial emulator-5554 "
               "--action keyguard-state --apk-sha256 <sha256> --output /tmp/sdk-observation")
    parser.add_argument("--serial", required=True, help="Serial number of the device to check")
    parser.add_argument("--allowed-serial", action="append", required=True,
                        help="Allowed device serial number; repeat for multiple devices")
    parser.add_argument("--action", required=True, choices=ACTIONS)
    parser.add_argument("--apk-sha256", required=True, help="Expected SHA-256 digest of the installed test APK")
    parser.add_argument("--output", type=Path, required=True, help="New directory outside the repository under the system temporary directory for check results and command logs")
    parser.add_argument("--adb", default="adb", help="adb command or path")
    parser.add_argument("--allow-ui-action", action="store_true")
    parser.add_argument("--expected-config-name")
    parser.add_argument("--window-package", choices=WINDOWS)
    parser.add_argument("--label", action="append", default=[], help="Exact displayed control label to find with snapshot or activate with click; repeat for multiple labels")
    parser.set_defaults(handler=run, validate_args=validate_args)


def validate_args(args, parser):
    if (any(not serial or any(c.isspace() or c == "\0" for c in serial)
            for serial in [args.serial, *args.allowed_serial]) or
            len(set(args.allowed_serial)) != len(args.allowed_serial) or args.serial not in args.allowed_serial):
        parser.error("Device serial must appear in --allowed-serial; entries must be unique, nonempty, and contain no whitespace or NUL")
    if not re.fullmatch(r"[0-9a-f]{64}", args.apk_sha256):
        parser.error("--apk-sha256 must be a SHA-256 digest of 64 lowercase hexadecimal characters")
    if args.action not in ("keyguard-state", "snapshot") and not args.allow_ui_action:
        parser.error("Actions other than keyguard-state and snapshot require --allow-ui-action")
    if args.action in ("start", "stop") and (not args.expected_config_name or not args.expected_config_name.strip() or
                                              len(args.expected_config_name.encode("utf-16-le")) // 2 > 1024):
        parser.error("Start and stop actions require a nonblank configuration name of at most 1024 UTF-16 code units")
    if args.action in ("snapshot", "click"):
        if (not args.window_package or not 1 <= len(args.label) <= 64 or
                len(set(args.label)) != len(args.label) or
                any(not label or len(label.encode("utf-16-le")) // 2 > 1024 for label in args.label)):
            parser.error("Provide the window package and 1 to 64 unique labels; each label must be nonempty and at most 1024 UTF-16 code units")
        if args.action == "click" and (len(args.label) != 1 or
                args.window_package not in (APP, "com.android.documentsui", "com.google.android.documentsui") or
                args.label[0] in ("Start tunnel", "启动接管", "Stop tunnel", "停止接管")):
            parser.error("click requires a single exact, unique control in the app or DocumentsUI; use start or stop for tunnel actions")
    elif args.window_package or args.label:
        parser.error("Only snapshot and click support --window-package and --label")
    try:
        args.output = _output_path(args.output)
    except ValueError as error:
        parser.error(str(error))
    return args


def observe(args):
    if args.serial not in args.allowed_serial or args.action not in ACTIONS:
        raise ValueError("Device serial must appear in --allowed-serial and the action must be supported by --action")
    args.output = _output_path(args.output)
    adb = shutil.which(args.adb)
    if not adb:
        raise ValueError("adb command not found")
    args.output.mkdir(parents=True, exist_ok=False)
    commands = []
    result = {"action": args.action, "serial": args.serial, "allowedSerials": args.allowed_serial,
              "expectedTestApkSha256": args.apk_sha256,
              "status": "unconfirmed", "scope": "UI controls and action results read through the Android SDK"}

    def run(name, parts, absent=False, shell=True):
        command = [adb, "-s", args.serial] + (["shell", shlex.join(parts)] if shell else parts)
        record = {"name": name, "command": command, "exit": None}
        commands.append(record)
        try:
            path = args.output / (name + ".log")
            with path.open("xb") as log:
                value = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=65)
            record["exit"] = value.returncode
            if not (absent and value.returncode == 1):
                value.check_returncode()
            return path.read_text().strip()
        finally:
            (args.output / "commands.json").write_text(json.dumps(commands, ensure_ascii=False, indent=2) + "\n")

    def device(prefix):
        api = run(prefix + "-api", ["getprop", "ro.build.version.sdk"])
        abis = run(prefix + "-abis", ["getprop", "ro.product.cpu.abilist"])
        if not api.isdigit() or int(api) < 24 or not abis:
            raise ValueError("Cannot read device API level or ABI list, or device API level is below 24")
        return {"api": int(api), "abis": abis.split(",")}

    def instance(prefix):
        pid = run(prefix + "-pid", ["pidof", APP], absent=True)
        if not pid:
            return {"mainAbsent": True}
        if not pid.isdigit():
            raise ValueError("Could not obtain a unique app main process ID")
        raw = run(prefix + "-startticks", ["cat", "/proc/" + pid + "/stat"])
        return {"pid": int(pid), "startTicks": raw[raw.rindex(")") + 2:].split()[19]}

    try:
        metadata = run("instrumentation-metadata", ["pm", "list", "instrumentation", PACKAGE])
        if metadata != "instrumentation:" + RUNNER + " (target=" + PACKAGE + ")":
            raise ValueError("No unique SystemEntryInstrumentation found, or its targetPackage is not the test package")
        path = run("test-package-path", ["pm", "path", PACKAGE])
        if not path.startswith("package:/data/app/") or "\n" in path:
            raise ValueError("Could not find a unique installed test APK")
        installed = args.output / "installed-test.apk"
        run("read-only-test-apk-identity", ["pull", path.removeprefix("package:"), str(installed)], shell=False)
        if hashlib.sha256(installed.read_bytes()).hexdigest() != args.apk_sha256:
            raise ValueError("Installed test APK SHA-256 does not match --apk-sha256")
        result["deviceBefore"] = device("device-before")
        before = instance("before")
        result["mainInstanceBefore"] = before
        command = ["am", "instrument", "-w", "-r", "-e", "systemEntryAction", args.action]
        if args.allow_ui_action:
            command += ["-e", "allowUiAction", "true"]
        if args.expected_config_name:
            command += ["-e", "expectedConfigName", args.expected_config_name]
        if args.action in ("snapshot", "click"):
            command += ["-e", "expectedWindowPackage", args.window_package,
                        "-e", "labelsJson", json.dumps(args.label, ensure_ascii=False)]
        text = run("actual-sdk-action", command + [RUNNER])
        fields = dict(re.findall(r"^INSTRUMENTATION_RESULT: ([A-Za-z0-9]+)=(.*)$", text, re.MULTILINE))
        result["sdkResult"] = fields
        after = instance("after")
        result["mainInstanceAfter"] = after
        result["deviceAfter"] = device("device-after")
        if not re.search(r"^INSTRUMENTATION_CODE: -1$", text, re.MULTILINE) or fields.get("sdkActionSucceeded") != "true":
            raise ValueError("SDK did not return the action success marker; results are saved in actual-sdk-action.log")
        if (result["deviceBefore"] != result["deviceAfter"] or
                fields.get("api") != str(result["deviceBefore"]["api"])):
            raise ValueError("Device API/ABI check failed: API level or ABI list changed during the action, or SDK API level differs from the device")
        result["status"] = "sdk-witness-completed"
        return result
    except BaseException as error:
        result["errorType"] = type(error).__name__
        result["error"] = str(error)
        raise
    finally:
        (args.output / "results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")


def run(args):
    try:
        result = observe(args)
    except KeyboardInterrupt:
        print("Check cancelled. Dispatched actions may still be running; inspect the device state and saved results.", file=sys.stderr)
        return 130
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0
