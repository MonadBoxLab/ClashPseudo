#!/usr/bin/env python3
"""定向运行已安装的 self-target SDK 观察器并记录动作回执。"""
import argparse
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
        raise ValueError("观察材料必须放在仓库外的系统临时目录中的新目录")
    return output


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="观察目标的 serial")
    parser.add_argument("--allowed-serial", action="append", required=True,
                        help="运行器接受的目标列表，可重复提供")
    parser.add_argument("--action", required=True, choices=ACTIONS)
    parser.add_argument("--apk-sha256", required=True, help="待观察 test APK 的预期 SHA-256")
    parser.add_argument("--output", type=Path, required=True, help="仓库外系统临时目录中的新观察目录")
    parser.add_argument("--adb", default="adb", help="adb 命令或路径")
    parser.add_argument("--allow-ui-action", action="store_true")
    parser.add_argument("--expected-config-name")
    parser.add_argument("--window-package", choices=WINDOWS)
    parser.add_argument("--label", action="append", default=[], help="snapshot 的精确预期标签，可重复提供")
    args = parser.parse_args(argv)
    if (any(not serial or any(c.isspace() or c == "\0" for c in serial)
            for serial in [args.serial, *args.allowed_serial]) or
            len(set(args.allowed_serial)) != len(args.allowed_serial) or args.serial not in args.allowed_serial):
        parser.error("目标 serial 必须属于显式提供的列表，列表项须唯一且有效")
    if not re.fullmatch(r"[0-9a-f]{64}", args.apk_sha256):
        parser.error("--apk-sha256 必须是 64 位小写十六进制 SHA-256")
    if args.action not in ("keyguard-state", "snapshot") and not args.allow_ui_action:
        parser.error("有 UI 副作用的动作需要显式 --allow-ui-action")
    if args.action in ("start", "stop") and (not args.expected_config_name or not args.expected_config_name.strip() or
                                              len(args.expected_config_name.encode("utf-16-le")) // 2 > 1024):
        parser.error("启停需要显式、非空且有界的预期配置名")
    if args.action in ("snapshot", "click"):
        if (not args.window_package or not 1 <= len(args.label) <= 64 or
                len(set(args.label)) != len(args.label) or
                any(not label or len(label.encode("utf-16-le")) // 2 > 1024 for label in args.label)):
            parser.error("精确观察／点击需要明确窗口 package 及 1..64 个不重复的有界标签")
        if args.action == "click" and (len(args.label) != 1 or
                args.window_package not in (APP, "com.android.documentsui", "com.google.android.documentsui") or
                args.label[0] in ("Start tunnel", "启动接管", "Stop tunnel", "停止接管")):
            parser.error("单次点击仅限应用／DocumentsUI 的唯一精确标签；启停使用专用动作")
    elif args.window_package or args.label:
        parser.error("只有 snapshot／click 接受窗口及标签参数")
    try:
        args.output = _output_path(args.output)
    except ValueError as error:
        parser.error(str(error))
    return args


def observe(args):
    if args.serial not in args.allowed_serial or args.action not in ACTIONS:
        raise ValueError("观察器仅支持当轮显式授权的目标及固定动作")
    args.output = _output_path(args.output)
    adb = shutil.which(args.adb)
    if not adb:
        raise ValueError("找不到现有 adb")
    args.output.mkdir(parents=True, exist_ok=False)
    commands = []
    result = {"action": args.action, "serial": args.serial, "allowedSerials": args.allowed_serial,
              "expectedTestApkSha256": args.apk_sha256,
              "status": "unconfirmed", "scope": "公开 SDK 节点与动作回执"}

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
            raise ValueError("无法确认当前设备的公开 API／ABI 能力；不从 serial 推断")
        return {"api": int(api), "abis": abis.split(",")}

    def instance(prefix):
        pid = run(prefix + "-pid", ["pidof", APP], absent=True)
        if not pid:
            return {"mainAbsent": True}
        if not pid.isdigit():
            raise ValueError("主进程身份不唯一")
        raw = run(prefix + "-startticks", ["cat", "/proc/" + pid + "/stat"])
        return {"pid": int(pid), "startTicks": raw[raw.rindex(")") + 2:].split()[19]}

    try:
        metadata = run("instrumentation-metadata", ["pm", "list", "instrumentation", PACKAGE])
        if metadata != "instrumentation:" + RUNNER + " (target=" + PACKAGE + ")":
            raise ValueError("拒绝缺失、含混或 Main-target 的 runner")
        path = run("test-package-path", ["pm", "path", PACKAGE])
        if not path.startswith("package:/data/app/") or "\n" in path:
            raise ValueError("无法确认唯一的已安装 test APK")
        installed = args.output / "installed-test.apk"
        run("read-only-test-apk-identity", ["pull", path.removeprefix("package:"), str(installed)], shell=False)
        if hashlib.sha256(installed.read_bytes()).hexdigest() != args.apk_sha256:
            raise ValueError("已安装 test APK 与预期摘要不同")
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
            raise ValueError("SDK 未报告动作成功；保留原回执，不重发")
        if (result["deviceBefore"] != result["deviceAfter"] or
                fields.get("api") != str(result["deviceBefore"]["api"])):
            raise ValueError("设备 API／ABI 与 SDK 目标回执不一致")
        result["status"] = "sdk-witness-completed"
        return result
    except BaseException as error:
        result["errorType"] = type(error).__name__
        result["error"] = str(error)
        raise
    finally:
        (args.output / "results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")


def main():
    try:
        result = observe(arguments())
    except KeyboardInterrupt:
        print("观察已取消；已发出动作的结果请检查设备状态及保留回执。", file=sys.stderr)
        return 130
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
