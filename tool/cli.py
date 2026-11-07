"""Command registration, argument validation, and exit codes for project tools."""
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
            result.command_parser.error("Unrecognized arguments: " + " ".join(unknown))
        return result


def create_parser():
    parser = Parser(
        prog="python3 -I -B tool/main.py",
        description="Build, verify, and maintain Clash Pseudo; use -h on each command for arguments and outputs.",
        epilog="Example: python3 -I -B tool/main.py contracts check")
    groups = parser.add_subparsers(title="Command groups")

    from tool.dependencies import cli as dependencies, release
    dependency_operations = groups.add_parser("dependencies", help="Check and update dependencies or publish releases").add_subparsers(title="Operations")
    dependencies.register_parser(dependency_operations)
    release.register_parser(dependency_operations)

    from tool.android import build_core, build_sdk_observer, run_sdk_observer
    android = groups.add_parser("android", help="Build native libraries and SDK observers").add_subparsers(title="Operations")
    build_core.register_parser(android)
    build_sdk_observer.register_parser(android)
    run_sdk_observer.register_parser(android)

    from tool.artifacts import package_sources, verify_release_licenses, verify_backup, update_bundle
    artifacts = groups.add_parser("artifacts", help="Package sources and verify release artifacts and backups").add_subparsers(title="Operations")
    for module in (package_sources, verify_release_licenses, verify_backup, update_bundle):
        module.register_parser(artifacts)

    from tool.contracts import generate
    generate.register_parser(groups.add_parser("contracts", help="Generate and check cross-language contracts").add_subparsers(title="Operations"))

    from tool.network import native_fixture
    native_fixture.register_parser(groups.add_parser("network", help="Run controlled network test servers").add_subparsers(title="Operations"))

    from tool.coverage import register_parser
    register_parser(groups.add_parser("coverage", help="Collect and summarize Dart coverage").add_subparsers(title="Operations"))
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
        logging.warning("Operation cancelled.")
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
