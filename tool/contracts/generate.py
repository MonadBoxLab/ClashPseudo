"""从共同静态契约及资源来源清单生成各层编译期定义。"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


SOURCE = Path("contracts/application.json")
HEADER = "// 由 contracts/application.json 生成；修改源声明后运行 tool/contracts/generate.py。\n"
ASSET_HEADER = "// 由 Geo／CA manifest 生成；修改源声明后运行 tool/contracts/generate.py。\n"


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


def asset_metadata(root):
    manifest = json.loads(
        (root / "android/app/src/main/assets/geodata/manifest.json").read_text(),
        object_pairs_hook=unique_object,
    )
    certificate = json.loads(
        (root / "third_party/data/certificates/manifest.json").read_text(),
        object_pairs_hook=unique_object,
    )
    if (not isinstance(manifest, dict)
            or manifest.get("format") != "clash-pseudo-bundled-geodata"
            or type(manifest.get("version")) is not int or manifest["version"] != 1
            or not isinstance(manifest.get("files"), list)):
        raise ValueError("Invalid bundled Geo manifest")
    metadata = [ASSET_HEADER, "package io.github.monadboxlab.clashpseudo.nativecore\n\ninternal object BundledAssetContract {\n"]
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
        for prefix in ("stored", "installed"):
            size = item.get(prefix + "Bytes")
            checksum = item.get(prefix + "Sha256")
            if (type(size) is not int or not 0 < size <= 0x7fffffff
                    or not isinstance(checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", checksum)):
                raise ValueError("Invalid bundled Geo size or SHA-256")
        if item["encoding"] == "identity" and (
                item["storedBytes"] != item["installedBytes"]
                or item["storedSha256"] != item["installedSha256"]):
            raise ValueError("Identity Geo asset must preserve size and SHA-256")
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
    size = certificate.get("bytes")
    checksum = certificate.get("sha256")
    if (not isinstance(asset, str) or not re.fullmatch(r"certificates/[A-Za-z0-9_-][A-Za-z0-9_.-]*\.pem", asset)
            or type(size) is not int or not 0 < size <= 0x7fffffff
            or not isinstance(checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", checksum)):
        raise ValueError("Invalid bundled certificate asset, size or SHA-256")
    for name, value in [("CERTIFICATE_ASSET", asset), ("CERTIFICATE_BYTES", size),
                        ("CERTIFICATE_SHA256", checksum)]:
        metadata.append(f"    const val {name} = {json.dumps(value)}\n")
    metadata.append("}\n")
    return "".join(metadata)


def outputs(root):
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
        check=True, timeout=30,
    ).stdout
    return {
        Path("lib/src/model/application_contract.dart"): "".join(dart),
        Path("android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/ApplicationContract.kt"): "".join(kotlin),
        Path("native/mihomo/internal/appcontract/contract.go"): go_source,
        Path("native/mihomo/application_contract.h"): "".join(native),
        Path("android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/nativecore/BundledAssetContract.kt"): asset_metadata(root),
    }


def generate(root, check=False):
    changed = []
    for relative, expected in outputs(root).items():
        target = root / relative
        actual = target.read_text() if target.exists() else None
        if actual == expected:
            continue
        if actual is not None and not actual.startswith((HEADER, ASSET_HEADER)):
            raise ValueError(f"Output is not owned by this generator: {relative}")
        changed.append((target, expected))
    if check and changed:
        raise ValueError("Generated contract is stale: " + ", ".join(str(p.relative_to(root)) for p, _ in changed))
    if not check:
        for target, expected in changed:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(expected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        generate(args.root, check=args.check)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
