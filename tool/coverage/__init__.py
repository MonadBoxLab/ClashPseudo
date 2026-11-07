"""Invoke the Dart coverage implementation through the public entry point."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def register_parser(subparsers):
    flutter = subparsers.add_parser(
        "flutter", help="Validate or collect Flutter coverage",
        description="Run the Dart implementation and save results outside the repository under the system temporary directory without changing project inputs.",
        epilog="Example: coverage flutter collect /tmp/flutter-coverage test/tool/flutter_coverage_test.dart")
    flutter.add_argument("mode", choices=("validate", "collect"), help="validate checks collection; collect gathers coverage for the selected tests")
    flutter.add_argument("output", type=Path, help="Absolute path to a new directory under the system temporary directory")
    flutter.add_argument("targets", nargs="*", help="test/..._test.dart paths for collect, defaulting to the full suite")
    flutter.add_argument("--project", type=Path, default=ROOT, help="Application project directory")
    flutter.add_argument("--dart", default="dart", help="Dart executable")
    flutter.set_defaults(handler=run_flutter, validate_args=validate_flutter)
    summary = subparsers.add_parser(
        "summary", help="Summarize LCOV function, line, and branch coverage",
        description="Read LCOV and write a summary to stdout without modifying inputs.",
        epilog="Example: coverage summary /tmp/flutter-coverage/lcov.info")
    summary.add_argument("lcov", type=Path, help="LCOV file")
    summary.add_argument("--project", type=Path, default=ROOT, help="Application project directory")
    summary.add_argument("--dart", default="dart", help="Dart executable")
    summary.set_defaults(handler=run_summary)


def validate_flutter(args, parser):
    if args.mode == "validate" and args.targets:
        parser.error("validate does not accept test paths; use collect for selected tests")
    if not args.output.is_absolute():
        parser.error("output must be an absolute path")


def run_flutter(args):
    subprocess.run([args.dart, "run", str(ROOT / "tool/coverage/flutter.dart"),
                    args.mode, str(args.output), *args.targets], cwd=args.project, check=True)
    return 0


def run_summary(args):
    subprocess.run([args.dart, "run", str(ROOT / "tool/coverage/summary.dart"),
                    str(args.lcov.absolute())], cwd=args.project, check=True)
    return 0
