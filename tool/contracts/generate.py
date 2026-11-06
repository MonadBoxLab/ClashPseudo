"""从跨语言常量声明和资源来源清单生成各语言的编译期定义。"""

import json
from pathlib import Path
import re
import subprocess


SOURCE = Path("contracts/application.json")
HEADER = "// 由 contracts/application.json 生成；修改源声明后运行 python3 -I -B tool/main.py contracts generate。\n"
ASSET_HEADER = "// 由 Geo／CA manifest 生成；修改源声明后运行 python3 -I -B tool/main.py contracts generate。\n"


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate contract key: {key}")
        result[key] = value
    return result


def entries(root):
    data = json.loads((root / SOURCE).read_text(), object_pairs_hook=unique_object)
    if not isinstance(data, dict) or not data:
        raise ValueError("Contract must contain named domains")
    validate_core_contract(data)
    result = []
    names = set()
    for domain, fields in data.items():
        if not re.fullmatch(r"[a-z][a-z0-9_]*", domain) or not isinstance(fields, dict) or not fields:
            raise ValueError(f"Invalid contract domain: {domain}")
        for name, value in fields.items():
            if not re.fullmatch(r"[a-z][a-z0-9_]*", name):
                raise ValueError(f"Invalid contract field: {name}")
            if type(value) is int:
                if not 0 < value <= 0x7fffffff:
                    raise ValueError(f"Contract integer is outside the bridge range: {name}")
            elif not isinstance(value, str) or not value or "$" in value:
                raise ValueError(f"Invalid contract value: {name}")
            combined = f"{domain}_{name}"
            title = "".join(word.capitalize() for word in combined.split("_"))
            if title in names:
                raise ValueError(f"Duplicate generated contract name: {combined}")
            names.add(title)
            result.append((combined, value))
    return result


def validate_core_contract(data):
    ipc = data.get("core_ipc")
    if ipc is None:
        return
    if not isinstance(ipc, dict):
        raise ValueError("Core IPC contract 格式无效")
    limits = ("version", "control_bytes", "identity_bytes", "frame_bytes",
              "queue_bytes", "record_bytes")
    if any(type(ipc.get(name)) is not int or not 0 < ipc[name] <= 0x7fffffff
           for name in limits):
        raise ValueError("Core IPC 容量必须是有效的正整数")
    if not (ipc["identity_bytes"] <= ipc["control_bytes"] <= ipc["frame_bytes"]
            <= ipc["queue_bytes"] and ipc["record_bytes"] <= ipc["frame_bytes"]):
        raise ValueError("Core IPC 容量之间的关系无效")
    frames = [value for name, value in ipc.items() if name.startswith("frame_") and name != "frame_bytes"]
    if (not frames or any(type(value) is not int or not 1 <= value <= 255 for value in frames)
            or len(frames) != len(set(frames))):
        raise ValueError("Core IPC frame kind 必须是互不重复的单字节值")
    operations = data.get("core_operation")
    if (not isinstance(operations, dict) or not operations
            or any(type(value) is not int or not 0 < value <= 0x7fffffff
                   for value in operations.values())
            or len(operations) != len(set(operations.values()))):
        raise ValueError("core_operation 的值必须是互不重复的正整数")
    for domain in ("core_part", "core_channel", "core_field", "core_purpose", "core_phase", "core_error"):
        fields = data.get(domain)
        if (not isinstance(fields, dict) or not fields
                or any(not isinstance(value, str) or not value for value in fields.values())
                or len(fields) != len(set(fields.values()))):
            raise ValueError(f"Core IPC 字段必须是互不重复的非空字符串：{domain}")


def asset_metadata(manifest, certificate):
    """根据当次构建的 Geo／CA manifest 生成资源定义，不读取源码目录中的 payload。"""
    if (not isinstance(manifest, dict)
            or manifest.get("format") != "clash-pseudo-bundled-geodata"
            or type(manifest.get("version")) is not int or manifest["version"] != 1
            or not isinstance(manifest.get("files"), list)):
        raise ValueError("Invalid bundled Geo manifest")
    metadata = [ASSET_HEADER, "package io.github.monadboxlab.clashpseudo.nativecore\n\n"
                "import io.github.monadboxlab.clashpseudo.nativecore.assets.BundledGeo\n\n"
                "internal object BundledAssetContract {\n"]
    kinds = set()
    assets = set()
    for item in manifest["files"]:
        if not isinstance(item, dict):
            raise ValueError("Invalid bundled Geo record")
        kind = item.get("kind")
        asset = item.get("asset")
        if not isinstance(kind, str) or kind not in {"geoip", "geosite", "mmdb", "asn"} or kind in kinds:
            raise ValueError("Invalid bundled Geo kind")
        if (not isinstance(asset, str) or not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*", asset)
                or asset in assets):
            raise ValueError("Invalid bundled Geo asset")
        if item.get("encoding") not in ("identity", "gzip"):
            raise ValueError("Invalid bundled Geo encoding")
        kinds.add(kind)
        assets.add(asset)
        values = [
            json.dumps(asset),
            str(item["encoding"] == "gzip").lower(),
            str(item["installedBytes"]) + "L",
            json.dumps(item["installedSha256"]),
            str(item["storedBytes"]) + "L",
            json.dumps(item["storedSha256"]),
        ]
        metadata.append(f"    val {kind} = BundledGeo.Data({', '.join(values)})\n")
    if kinds != {"geoip", "geosite", "mmdb", "asn"}:
        raise ValueError("Bundled Geo metadata is incomplete")
    if not isinstance(certificate, dict):
        raise ValueError("Invalid bundled certificate manifest")
    asset = certificate.get("asset")
    if not isinstance(asset, str) or not re.fullmatch(r"certificates/[A-Za-z0-9_-][A-Za-z0-9_.-]*\.pem", asset):
        raise ValueError("Invalid bundled certificate asset")
    size, checksum, roots = certificate["bytes"], certificate["sha256"], certificate["roots"]
    for name, value in [("CERTIFICATE_ASSET", asset), ("CERTIFICATE_BYTES", size),
                        ("CERTIFICATE_SHA256", checksum), ("CERTIFICATE_ROOTS", roots)]:
        metadata.append(f"    const val {name} = {json.dumps(value)}\n")
    metadata.append("}\n")
    return "".join(metadata)


def outputs(root, *, env=None):
    dart = [HEADER, "\nabstract final class ApplicationContract {\n"]
    kotlin = [HEADER, "package io.github.monadboxlab.clashpseudo.app\n\nobject ApplicationContract {\n"]
    go = [HEADER, "package appcontract\n\nconst (\n"]
    native = [HEADER, "#ifndef CLASH_PSEUDO_APPLICATION_CONTRACT_H\n#define CLASH_PSEUDO_APPLICATION_CONTRACT_H\n\n"]
    for name, value in entries(root):
        words = name.split("_")
        title = "".join(word.capitalize() for word in words)
        literal = json.dumps(value, ensure_ascii=True)
        dart.append(f"  static const {title[0].lower() + title[1:]} = {literal};\n")
        suffix = "L" if type(value) is int and name.endswith("_ms") else ""
        kotlin.append(f"    const val {name.upper()} = {literal}{suffix}\n")
        go.append(f"\t{title} = {literal}\n")
        native.append(f"#define APP_{name.upper()} {literal}\n")
    dart.append("}\n")
    kotlin.append("}\n")
    go.append(")\n")
    native.append("\n#endif\n")
    go_source = subprocess.run(
        ["gofmt"], input="".join(go), text=True, capture_output=True,
        check=True, timeout=30, env=env,
    ).stdout
    return {
        Path("lib/src/model/application_contract.dart"): "".join(dart),
        Path("android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/ApplicationContract.kt"): "".join(kotlin),
        Path("native/mihomo/internal/appcontract/contract.go"): go_source,
        Path("native/mihomo/application_contract.h"): "".join(native),
    }


def generate(root, check=False, *, env=None):
    changed = []
    for relative, expected in outputs(root, env=env).items():
        target = root / relative
        actual = target.read_text() if target.exists() else None
        if actual == expected:
            continue
        if actual is not None and not actual.startswith(("// 由 contracts/application.json 生成；", "// 由 Geo／CA manifest 生成；")):
            raise ValueError(f"Output is not owned by this generator: {relative}")
        changed.append((target, expected))
    if check and changed:
        raise ValueError("Generated contract is stale: " + ", ".join(str(p.relative_to(root)) for p, _ in changed))
    if not check:
        for target, expected in changed:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(expected)


def register_parser(subparsers):
    for name, check in (("generate", False), ("check", True)):
        parser = subparsers.add_parser(
            name, help="检查生成文件一致性" if check else "生成跨语言 Contract 文件",
            description="检查项目输入，不写文件。" if check else "按声明生成 Dart、Kotlin、Go、C 定义，或生成资源 Kotlin 定义。",
            epilog=f"示例：contracts {name} --project /path/to/project")
        parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[2], help="应用项目目录")
        if not check:
            parser.add_argument("--asset-manifest", type=Path, help="当次生成的 Geo manifest")
            parser.add_argument("--certificate-manifest", type=Path, help="当次生成的 CA manifest")
            parser.add_argument("--asset-output", type=Path, help="BundledAssetContract.kt 输出路径")
        parser.set_defaults(handler=run, check=check, validate_args=validate_args)


def validate_args(args, parser):
    if not args.check:
        values = (args.asset_manifest, args.certificate_manifest, args.asset_output)
        if any(values) and not all(values):
            parser.error("资源生成需要 --asset-manifest、--certificate-manifest 和 --asset-output")


def run(args):
    if not args.check and args.asset_manifest:
        result = asset_metadata(
            json.loads(args.asset_manifest.read_bytes(), object_pairs_hook=unique_object),
            json.loads(args.certificate_manifest.read_bytes(), object_pairs_hook=unique_object))
        args.asset_output.parent.mkdir(parents=True, exist_ok=True)
        args.asset_output.write_text(result, encoding="utf-8")
    else:
        generate(args.project, check=args.check)
    return 0
