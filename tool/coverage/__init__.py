"""通过公共入口调用现有 Dart 覆盖率实现。"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def register_parser(subparsers):
    flutter = subparsers.add_parser(
        "flutter", help="验证或采集 Flutter 覆盖率",
        description="调用现有 Dart 实现，结果写入仓库外系统临时目录；不修改项目输入。",
        epilog="示例：coverage flutter collect /tmp/flutter-coverage test/tool/flutter_coverage_test.dart")
    flutter.add_argument("mode", choices=("validate", "collect"), help="validate 验证采集流程，collect 采集指定测试")
    flutter.add_argument("output", type=Path, help="系统临时目录下尚不存在的绝对目录")
    flutter.add_argument("targets", nargs="*", help="collect 的 test/..._test.dart 路径，默认全套测试")
    flutter.add_argument("--project", type=Path, default=ROOT, help="应用项目目录")
    flutter.add_argument("--dart", default="dart", help="Dart 可执行文件")
    flutter.set_defaults(handler=run_flutter, validate_args=validate_flutter)
    summary = subparsers.add_parser(
        "summary", help="汇总 LCOV 中的函数、行和分支覆盖率",
        description="只读取 LCOV，汇总写入标准输出，不修改输入。",
        epilog="示例：coverage summary /tmp/flutter-coverage/lcov.info")
    summary.add_argument("lcov", type=Path, help="LCOV 文件")
    summary.add_argument("--project", type=Path, default=ROOT, help="应用项目目录")
    summary.add_argument("--dart", default="dart", help="Dart 可执行文件")
    summary.set_defaults(handler=run_summary)


def validate_flutter(args, parser):
    if args.mode == "validate" and args.targets:
        parser.error("validate 不接受测试路径，采集指定测试请使用 collect")
    if not args.output.is_absolute():
        parser.error("output 必须是绝对路径")


def run_flutter(args):
    subprocess.run([args.dart, "run", str(ROOT / "tool/coverage/flutter.dart"),
                    args.mode, str(args.output), *args.targets], cwd=args.project, check=True)
    return 0


def run_summary(args):
    subprocess.run([args.dart, "run", str(ROOT / "tool/coverage/summary.dart"),
                    str(args.lcov.absolute())], cwd=args.project, check=True)
    return 0
