"""Command arguments for dependency checks, updates, and frozen build inputs."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def _project(parser):
    parser.add_argument("--project", type=Path, default=ROOT, help="Application project directory")


def _prepared(parser):
    parser.add_argument("--prepared-resources", type=Path, help="Verified resource root containing ca, geoip, geosite, mmdb, and asn")


def register_parser(subparsers):
    for name in ("check", "apply"):
        parser = subparsers.add_parser(
            name, help="Check all dependency and resource updates" if name == "check" else "Apply verified dependency and resource updates",
            description="Resolve a candidate and output JSON; check leaves project inputs unchanged, while apply transactionally updates declarations, lockfiles, licenses, and versions. Unchanged inputs do not increment the version.",
            epilog=f"Example: dependencies {name} --scope mihomo --mihomo-version v1.0.0")
        _project(parser)
        parser.add_argument("--scope", choices=("all", "mihomo"), default="all", help="all checks application dependencies and resources with fixed toolchains; mihomo checks only the core")
        parser.add_argument("--mihomo-version", help="Go selector such as a tag, commit, branch, or latest; requires --scope mihomo")
        parser.add_argument("--toolchain-cache", type=Path, help="Fixed toolchain cache directory; defaults to ~/.cache/clash-pseudo/toolchains")
        parser.add_argument("--go-module", action="append", default=[], help="Select an existing direct Go module; repeat for multiple modules")
        parser.add_argument("--pub", action="append", default=[], help="Select an existing direct hosted Pub dependency; repeat for multiple dependencies")
        parser.add_argument("--android", action="append", default=[], help="Select an existing group:artifact; repeat for multiple artifacts")
        if name == "apply":
            parser.add_argument("--report", type=Path, help="Write update results to a JSON file, creating parent directories")
            parser.add_argument("--evidence", type=Path, help="New directory for dependency resolution results and license notices")
            _prepared(parser)
            parser.add_argument("--reuse-version", action="store_true", help="Keep the current application version for local dependency experiments")
        parser.set_defaults(handler=run_update, validate_args=validate_update, apply=name == "apply")

    parser = subparsers.add_parser(
        "validate", help="Run tests and static checks for the candidate",
        description="Run tests and static checks with fixed toolchains; write logs and verification reports to output. Use dependencies release build for APK builds.",
        epilog="Example: dependencies validate --project /tmp/candidate --output /tmp/validation")
    _project(parser)
    parser.add_argument("--output", type=Path, required=True, help="New output directory for this verification run")
    parser.add_argument("--toolchain-cache", type=Path, help="Fixed toolchain cache directory; defaults to ~/.cache/clash-pseudo/toolchains")
    parser.set_defaults(handler=run_validate)

    parser = subparsers.add_parser(
        "prepare-build", help="Generate build inputs from frozen resource records",
        description="Read frozen records only; default output is build/generated/bundled, leaving project dependency declarations unchanged.",
        epilog="Example: dependencies prepare-build --offline --payload-directory /tmp/assets")
    _project(parser)
    _prepared(parser)
    parser.add_argument("--payload-directory", type=Path, help="Frozen payload root, such as build-inputs/bundled/assets in a source package")
    parser.add_argument("--output", type=Path, help="Directory for generated assets and Kotlin files; defaults to build/generated/bundled in the project")
    parser.add_argument("--offline", action="store_true", help="Use existing payloads only, without downloads")
    parser.set_defaults(handler=run_build)

    parser = subparsers.add_parser(
        "prepare-toolchains", help="Install fixed toolchains and output the execution environment",
        description="Read fixed toolchain records and write the cache and project android/local.properties without querying latest versions.",
        epilog="Example: dependencies prepare-toolchains --environment /tmp/toolchain-environment.json")
    _project(parser)
    parser.add_argument("--record", type=Path, help="Fixed toolchain JSON; defaults to toolchains in the project resources.json")
    parser.add_argument("--cache", type=Path, default=Path.home() / ".cache/clash-pseudo/toolchains", help="Toolchain cache directory")
    parser.add_argument("--environment", type=Path, help="JSON output file for environment and archive digests; also emit JSON on stdout")
    parser.set_defaults(handler=run_toolchains)

    for name, description in (
            ("prepare-resource", "Prepare one frozen resource"),
            ("prepare-resources", "Prepare five frozen resources"),
            ("prepare-resource-sources", "Prepare corresponding source archives for frozen resources")):
        parser = subparsers.add_parser(
            name, help=description, description=description + "; output to a separate directory without changing dependency inputs.",
            epilog=f"Example: dependencies {name} --spec /tmp/resource-spec.json --destination /tmp/prepared")
        parser.add_argument("--spec", type=Path, required=True,
                            help="Frozen source JSON: an object for one resource, an array for five, or an object keyed by kind for source preparation")
        parser.add_argument("--destination", type=Path, required=True, help="Separate output directory that does not yet exist")
        if name == "prepare-resource":
            parser.add_argument("--resource-source", type=Path, help="Previously downloaded original resource file")
        elif name == "prepare-resources":
            parser.add_argument("--resource-sources", type=Path, help="JSON mapping kinds to absolute paths of original files")
        else:
            _project(parser)
        parser.set_defaults(handler=run_resources, preparation=name)


def validate_update(args, parser):
    args.mihomo_version = args.mihomo_version or None
    if args.mihomo_version is not None:
        if args.scope != "mihomo":
            parser.error("--mihomo-version requires --scope mihomo")
    if args.scope == "mihomo" and (args.go_module or args.pub or args.android):
        parser.error("--scope mihomo does not accept other Go, Pub, or Android update selections")


def run_update(args):
    from .update import execute
    if args.apply and args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
    try:
        report = execute(
            args.project, apply=args.apply, scope=args.scope, mihomo_version=args.mihomo_version,
            toolchain_cache=args.toolchain_cache,
            go_module=args.go_module, pub=args.pub, android=args.android,
            evidence=getattr(args, "evidence", None), prepared_resources=getattr(args, "prepared_resources", None),
            reuse_version=getattr(args, "reuse_version", False))
    except Exception as error:
        if args.apply and args.report:
            from tool.common.io import json_bytes
            args.report.write_bytes(json_bytes({"status": "failed", "error": str(error)}))
        raise
    if args.apply:
        import os
        from tool.common.io import json_bytes
        if args.report:
            args.report.write_bytes(json_bytes(report))
        if report["status"] == "unchanged" and os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
                summary.write("## 依赖检查\n\n无实际更新（unchanged）。当前应用版本："
                              + str(report["version"]) + "。\n")
        if os.environ.get("GITHUB_OUTPUT"):
            changed = report["status"] == "updated" and bool(report["files"])
            with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
                output.write("changed=" + str(changed).lower() + "\n")
    return report


def run_validate(args):
    from .validation import validate
    return validate(args.project, args.output, toolchain_cache=args.toolchain_cache)


def run_build(args):
    from .resources import RESOURCE_ASSETS, prepare_bundled_assets
    payloads = ({kind: args.payload_directory / name for kind, name in RESOURCE_ASSETS.items()}
                if args.payload_directory else None)
    output = prepare_bundled_assets(args.project, prepared=args.prepared_resources, payloads=payloads,
                                    output=args.output, offline=args.offline)
    return {"status": "prepared", "generated": str(output)}


def _read_json(path, limit=128 * 1024):
    import json
    from tool.common.io import read_resource, unique_object
    return json.loads(read_resource(path, limit), object_pairs_hook=unique_object)


def run_toolchains(args):
    from .resources import read_release_resources
    from .toolchains import prepare
    from tool.common.io import json_bytes
    record = _read_json(args.record) if args.record else read_release_resources(args.project)["toolchains"]
    environment, measured = prepare(record, args.cache, args.project.resolve())
    report = {"environment": environment, "archives": measured}
    if args.environment:
        args.environment.write_bytes(json_bytes(report))
    return report


def run_resources(args):
    from . import resources, sources
    specs = _read_json(args.spec)
    if args.preparation == "prepare-resource-sources":
        if not isinstance(specs, dict):
            raise ValueError("Frozen source resource arguments must be a JSON object keyed by kind")
        current = resources.read_release_resources(args.project)["resources"]
        for kind in sources.GEO_SOURCE_REPOSITORIES:
            if any(specs[kind][field] != current[kind][field] for field in ("sourceCommit", "sourceUrl", "version")):
                raise ValueError("Frozen source resource arguments differ from the application resource manifest: " + kind)
        if args.destination.resolve().is_relative_to(args.project.resolve()):
            raise ValueError("Frozen source directory must be outside the project")
        manifest = sources.prepare_resource_sources(specs, args.destination)
        resources.check_resource_source_selection(args.project.resolve(), resources.read_resource_sources(manifest.parent))
        return {"status": "prepared", "sources": str(manifest)}
    if args.preparation == "prepare-resource":
        paths = [resources.prepare_resource(specs, args.destination, args.resource_source)]
    else:
        if not isinstance(specs, list):
            raise ValueError("Arguments for the five resources must be a JSON array")
        original = _read_json(args.resource_sources, 64 * 1024) if args.resource_sources else None
        if original is not None and not isinstance(original, dict):
            raise ValueError("Original file path mapping must be a JSON object")
        paths = resources.prepare_resources(specs, args.destination, original)
    return {"status": "prepared", "prepared": [str(path) for path in paths],
            "resources": [str(path / "resource.json") for path in paths]}
