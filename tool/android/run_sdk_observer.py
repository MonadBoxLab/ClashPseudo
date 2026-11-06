#!/usr/bin/env python3
"""在指定设备上运行已安装的 SDK 测试程序并保存操作结果，测试程序以自身测试包为目标。"""
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
        raise ValueError("检查结果和命令日志必须保存到系统临时目录下的仓库外新目录")
    return output


def register_parser(subparsers):
    parser = subparsers.add_parser(
        "run-sdk-observer", help="在指定设备运行 SDK 检查", description=__doc__,
        epilog="示例：android run-sdk-observer --serial emulator-5554 --allowed-serial emulator-5554 "
               "--action keyguard-state --apk-sha256 <sha256> --output /tmp/sdk-observation")
    parser.add_argument("--serial", required=True, help="要检查的设备序列号")
    parser.add_argument("--allowed-serial", action="append", required=True,
                        help="允许操作的设备序列号，可重复指定以提供多个序列号")
    parser.add_argument("--action", required=True, choices=ACTIONS)
    parser.add_argument("--apk-sha256", required=True, help="已安装测试 APK 的预期 SHA-256 摘要")
    parser.add_argument("--output", type=Path, required=True, help="系统临时目录下的仓库外新目录，用于保存检查结果和命令日志")
    parser.add_argument("--adb", default="adb", help="adb 命令或路径")
    parser.add_argument("--allow-ui-action", action="store_true")
    parser.add_argument("--expected-config-name")
    parser.add_argument("--window-package", choices=WINDOWS)
    parser.add_argument("--label", action="append", default=[], help="snapshot 要查找、click 要点击的控件标签；须与显示文字完全一致，可重复指定")
    parser.set_defaults(handler=run, validate_args=validate_args)


def validate_args(args, parser):
    if (any(not serial or any(c.isspace() or c == "\0" for c in serial)
            for serial in [args.serial, *args.allowed_serial]) or
            len(set(args.allowed_serial)) != len(args.allowed_serial) or args.serial not in args.allowed_serial):
        parser.error("设备序列号必须在 --allowed-serial 列表中；列表项不得重复、为空或包含空白字符和 NUL")
    if not re.fullmatch(r"[0-9a-f]{64}", args.apk_sha256):
        parser.error("--apk-sha256 必须是由 64 个小写十六进制字符组成的 SHA-256 摘要")
    if args.action not in ("keyguard-state", "snapshot") and not args.allow_ui_action:
        parser.error("除 keyguard-state 和 snapshot 外，其他操作必须同时指定 --allow-ui-action")
    if args.action in ("start", "stop") and (not args.expected_config_name or not args.expected_config_name.strip() or
                                              len(args.expected_config_name.encode("utf-16-le")) // 2 > 1024):
        parser.error("启停操作必须提供配置名称，不能为空白，且不超过1024个UTF-16代码单元")
    if args.action in ("snapshot", "click"):
        if (not args.window_package or not 1 <= len(args.label) <= 64 or
                len(set(args.label)) != len(args.label) or
                any(not label or len(label.encode("utf-16-le")) // 2 > 1024 for label in args.label)):
            parser.error("必须提供窗口所属应用的包名和1至64个不重复的标签；每个标签不能为空，且不超过1024个UTF-16代码单元")
        if args.action == "click" and (len(args.label) != 1 or
                args.window_package not in (APP, "com.android.documentsui", "com.google.android.documentsui") or
                args.label[0] in ("Start tunnel", "启动接管", "Stop tunnel", "停止接管")):
            parser.error("click 只能点击应用或 DocumentsUI 中一个文字完全匹配且唯一的控件；启动和停止请使用 start、stop")
    elif args.window_package or args.label:
        parser.error("只有 snapshot 和 click 支持 --window-package 和 --label 参数")
    try:
        args.output = _output_path(args.output)
    except ValueError as error:
        parser.error(str(error))
    return args


def observe(args):
    if args.serial not in args.allowed_serial or args.action not in ACTIONS:
        raise ValueError("设备序列号须在 --allowed-serial 列表中，操作须为 --action 支持的选项")
    args.output = _output_path(args.output)
    adb = shutil.which(args.adb)
    if not adb:
        raise ValueError("找不到 adb 命令")
    args.output.mkdir(parents=True, exist_ok=False)
    commands = []
    result = {"action": args.action, "serial": args.serial, "allowedSerials": args.allowed_serial,
              "expectedTestApkSha256": args.apk_sha256,
              "status": "unconfirmed", "scope": "通过 Android SDK 读取的界面控件及操作返回结果"}

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
            raise ValueError("无法读取设备的API级别或ABI列表，或设备API级别低于24")
        return {"api": int(api), "abis": abis.split(",")}

    def instance(prefix):
        pid = run(prefix + "-pid", ["pidof", APP], absent=True)
        if not pid:
            return {"mainAbsent": True}
        if not pid.isdigit():
            raise ValueError("未获取到唯一的应用主进程号")
        raw = run(prefix + "-startticks", ["cat", "/proc/" + pid + "/stat"])
        return {"pid": int(pid), "startTicks": raw[raw.rindex(")") + 2:].split()[19]}

    try:
        metadata = run("instrumentation-metadata", ["pm", "list", "instrumentation", PACKAGE])
        if metadata != "instrumentation:" + RUNNER + " (target=" + PACKAGE + ")":
            raise ValueError("未找到唯一的SystemEntryInstrumentation，或其targetPackage不是测试包")
        path = run("test-package-path", ["pm", "path", PACKAGE])
        if not path.startswith("package:/data/app/") or "\n" in path:
            raise ValueError("无法找到唯一的已安装测试 APK")
        installed = args.output / "installed-test.apk"
        run("read-only-test-apk-identity", ["pull", path.removeprefix("package:"), str(installed)], shell=False)
        if hashlib.sha256(installed.read_bytes()).hexdigest() != args.apk_sha256:
            raise ValueError("已安装测试 APK 的 SHA-256 与 --apk-sha256 指定的摘要不同")
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
            raise ValueError("SDK 未返回操作成功标记；操作结果保存在 actual-sdk-action.log 中")
        if (result["deviceBefore"] != result["deviceAfter"] or
                fields.get("api") != str(result["deviceBefore"]["api"])):
            raise ValueError("设备 API／ABI 检查失败：操作前后的 API 级别或 ABI 列表发生变化，或 SDK 返回的 API 级别与设备不一致")
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
        print("检查已取消。已发送的操作可能仍在执行，请查看设备状态和已保存的操作结果。", file=sys.stderr)
        return 130
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0
