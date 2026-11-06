"""项目工具的命令注册、参数检查和退出码。"""
import argparse
import json
import logging
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]


class Parser(argparse.ArgumentParser):
    def __init__(self, *args, **kwargs):
        kwargs.setdefault("allow_abbrev", False)
        kwargs.setdefault("formatter_class", argparse.ArgumentDefaultsHelpFormatter)
        super().__init__(*args, **kwargs)
        self.set_defaults(command_parser=self, handler=None, validate_args=None)

    def parse_args(self, args=None, namespace=None):
        result, unknown = self.parse_known_args(args, namespace)
        if unknown:
            result.command_parser.error("无法识别参数：" + " ".join(unknown))
        return result


def create_parser():
    parser = Parser(
        prog="python3 -I -B tool/main.py",
        description="构建、验证及维护 Clash Pseudo；各操作通过 -h 查看参数和输出。",
        epilog="示例：python3 -I -B tool/main.py contracts check")
    groups = parser.add_subparsers(title="命令组")

    from tool.dependencies import cli as dependencies, release
    dependency_operations = groups.add_parser("dependencies", help="检查、更新依赖及直接发布").add_subparsers(title="操作")
    dependencies.register_parser(dependency_operations)
    release.register_parser(dependency_operations)

    from tool.android import build_core, build_sdk_observer, run_sdk_observer
    android = groups.add_parser("android", help="构建原生库及 SDK 测试程序").add_subparsers(title="操作")
    build_core.register_parser(android)
    build_sdk_observer.register_parser(android)
    run_sdk_observer.register_parser(android)

    from tool.artifacts import package_sources, verify_release_licenses, verify_backup, update_bundle
    artifacts = groups.add_parser("artifacts", help="打包源码及核验分发材料、备份").add_subparsers(title="操作")
    for module in (package_sources, verify_release_licenses, verify_backup, update_bundle):
        module.register_parser(artifacts)

    from tool.contracts import generate
    generate.register_parser(groups.add_parser("contracts", help="生成及检查跨语言 Contract").add_subparsers(title="操作"))

    from tool.network import native_fixture
    native_fixture.register_parser(groups.add_parser("network", help="运行受控网络测试服务").add_subparsers(title="操作"))

    from tool.coverage import register_parser
    register_parser(groups.add_parser("coverage", help="运行 Dart 覆盖率采集和汇总").add_subparsers(title="操作"))
    return parser


def parse_args(argv=None):
    args = create_parser().parse_args(argv)
    if args.validate_args is not None:
        args.validate_args(args, args.command_parser)
    return args


def main(argv=None):
    args = parse_args(argv)
    if args.handler is None:
        args.command_parser.print_help()
        return 0
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S", force=True)
    try:
        result = args.handler(args)
        if isinstance(result, dict):
            print(json.dumps(result, ensure_ascii=False, sort_keys=True))
            return 0
        return result or 0
    except KeyboardInterrupt:
        logging.warning("操作已取消。")
        return 130
    except subprocess.CalledProcessError as error:
        logging.error("%s", error)
        for output in (error.stdout, error.stderr):
            if output:
                print(output.decode(errors="replace") if isinstance(output, bytes) else output, file=sys.stderr)
        return error.returncode if error.returncode > 0 else 128 - error.returncode
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, EOFError,
            subprocess.SubprocessError, ET.ParseError, zipfile.BadZipFile) as error:
        logging.error("%s", error)
        return 1
