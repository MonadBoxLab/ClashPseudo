"""依赖检查、更新和固定构建输入的命令参数。"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def _project(parser):
    parser.add_argument("--project", type=Path, default=ROOT, help="应用项目目录")


def _prepared(parser):
    parser.add_argument("--prepared-resources", type=Path, help="已核验的五项资源根目录，包含 ca、geoip、geosite、mmdb、asn")


def register_parser(subparsers):
    for name in ("check", "apply"):
        parser = subparsers.add_parser(
            name, help="检查全部依赖和资源更新" if name == "check" else "应用已核验的依赖和资源更新",
            description="解析候选并输出 JSON；check 不写回项目输入，apply 事务写回声明、锁文件、许可和版本。无真实变化不递增版本。",
            epilog=f"示例：dependencies {name} --scope mihomo --mihomo-version v1.0.0")
        _project(parser)
        parser.add_argument("--scope", choices=("all", "mihomo"), default="all", help="all 检查应用依赖和资源，工具链固定；mihomo 仅检查内核")
        parser.add_argument("--mihomo-version", help="Go selector，例如 tag、commit、branch 或 latest；仅适用于 --scope mihomo")
        parser.add_argument("--toolchain-cache", type=Path, help="固定工具链缓存目录；默认 ~/.cache/clash-pseudo/toolchains")
        parser.add_argument("--go-module", action="append", default=[], help="选择现有直接 Go 模块，可重复")
        parser.add_argument("--pub", action="append", default=[], help="选择现有 hosted 直接 Pub 依赖，可重复")
        parser.add_argument("--android", action="append", default=[], help="选择现有 group:artifact，可重复")
        if name == "apply":
            parser.add_argument("--report", type=Path, help="将更新结果写入 JSON 文件，自动创建父目录")
            parser.add_argument("--evidence", type=Path, help="保存依赖解析结果及许可通知的新目录")
            _prepared(parser)
            parser.add_argument("--reuse-version", action="store_true", help="本地依赖实验沿用当前应用版本")
        parser.set_defaults(handler=run_update, validate_args=validate_update, apply=name == "apply")

    parser = subparsers.add_parser(
        "validate", help="运行候选的测试和静态检查",
        description="使用固定工具链执行测试与静态检查；日志和验证报告写入 output。APK 构建使用 dependencies release build。",
        epilog="示例：dependencies validate --project /tmp/candidate --output /tmp/validation")
    _project(parser)
    parser.add_argument("--output", type=Path, required=True, help="本次验证的新输出目录")
    parser.add_argument("--toolchain-cache", type=Path, help="固定工具链缓存目录；默认 ~/.cache/clash-pseudo/toolchains")
    parser.set_defaults(handler=run_validate)

    parser = subparsers.add_parser(
        "prepare-build", help="根据固定资源记录生成构建输入",
        description="只读取固定记录；默认输出 build/generated/bundled，不更新项目依赖声明。",
        epilog="示例：dependencies prepare-build --offline --payload-directory /tmp/assets")
    _project(parser)
    _prepared(parser)
    parser.add_argument("--payload-directory", type=Path, help="固定 payload 根目录，例如源码包的 build-inputs/bundled/assets")
    parser.add_argument("--output", type=Path, help="生成的 assets 和 Kotlin 文件目录；默认项目 build/generated/bundled")
    parser.add_argument("--offline", action="store_true", help="只使用现有 payload，不下载")
    parser.set_defaults(handler=run_build)

    parser = subparsers.add_parser(
        "prepare-toolchains", help="安装固定工具链并输出执行环境",
        description="读取固定工具链记录，写入缓存及项目 android/local.properties，不查询最新版本。",
        epilog="示例：dependencies prepare-toolchains --environment /tmp/toolchain-environment.json")
    _project(parser)
    parser.add_argument("--record", type=Path, help="固定工具链 JSON；默认读取项目 resources.json 的 toolchains")
    parser.add_argument("--cache", type=Path, default=Path.home() / ".cache/clash-pseudo/toolchains", help="工具链缓存目录")
    parser.add_argument("--environment", type=Path, help="环境及 archive 摘要的 JSON 输出文件；同时在 stdout 输出 JSON")
    parser.set_defaults(handler=run_toolchains)

    for name, description in (
            ("prepare-resource", "准备单项固定资源"),
            ("prepare-resources", "准备五项固定资源"),
            ("prepare-resource-sources", "准备固定资源的对应源码归档")):
        parser = subparsers.add_parser(
            name, help=description, description=description + "；输出到独立目录，不修改依赖输入。",
            epilog=f"示例：dependencies {name} --spec /tmp/resource-spec.json --destination /tmp/prepared")
        parser.add_argument("--spec", type=Path, required=True,
                            help="固定来源 JSON；单项为对象、五项为数组、源码准备为以 kind 为键的对象")
        parser.add_argument("--destination", type=Path, required=True, help="尚不存在的独立输出目录")
        if name == "prepare-resource":
            parser.add_argument("--resource-source", type=Path, help="已经下载的原始资源文件")
        elif name == "prepare-resources":
            parser.add_argument("--resource-sources", type=Path, help="以 kind 为键、原始文件绝对路径为值的 JSON")
        else:
            _project(parser)
        parser.set_defaults(handler=run_resources, preparation=name)


def validate_update(args, parser):
    args.mihomo_version = args.mihomo_version or None
    if args.mihomo_version is not None:
        if args.scope != "mihomo":
            parser.error("--mihomo-version 需要 --scope mihomo")
    if args.scope == "mihomo" and (args.go_module or args.pub or args.android):
        parser.error("--scope mihomo 不接受其他 Go、Pub 或 Android 更新选择")


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
            raise ValueError("固定源码的资源参数必须是以 kind 为键的 JSON 对象")
        current = resources.read_release_resources(args.project)["resources"]
        for kind in sources.GEO_SOURCE_REPOSITORIES:
            if any(specs[kind][field] != current[kind][field] for field in ("sourceCommit", "sourceUrl", "version")):
                raise ValueError("固定源码的资源参数与应用资源清单不一致：" + kind)
        if args.destination.resolve().is_relative_to(args.project.resolve()):
            raise ValueError("固定源码目录须在项目之外")
        manifest = sources.prepare_resource_sources(specs, args.destination)
        resources.check_resource_source_selection(args.project.resolve(), resources.read_resource_sources(manifest.parent))
        return {"status": "prepared", "sources": str(manifest)}
    if args.preparation == "prepare-resource":
        paths = [resources.prepare_resource(specs, args.destination, args.resource_source)]
    else:
        if not isinstance(specs, list):
            raise ValueError("五项资源的参数必须是 JSON 数组")
        original = _read_json(args.resource_sources, 64 * 1024) if args.resource_sources else None
        if original is not None and not isinstance(original, dict):
            raise ValueError("原件路径映射必须是 JSON 对象")
        paths = resources.prepare_resources(specs, args.destination, original)
    return {"status": "prepared", "prepared": [str(path) for path in paths],
            "resources": [str(path / "resource.json") for path in paths]}
