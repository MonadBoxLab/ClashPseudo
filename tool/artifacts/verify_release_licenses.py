#!/usr/bin/env python3
"""比较APK中的许可、数据资产和原生依赖与本次构建材料。

使用python3 -I运行，--output-dir指定已有空目录，接收原生库和buildinfo。
--notices填写依赖源码生成并解码的NOTICES文件，--go-modules和
--android-dependencies分别填写本次Go模块图与Gradle依赖报告。
"""

import argparse
import base64
import gzip
import hashlib
import io
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile
import zlib


ASSETS = (
    "LICENSE",
    "third_party/notices/mihomo.txt",
    "third_party/notices/go.txt",
    "third_party/notices/android.txt",
    "third_party/notices/material-icons.txt",
    "third_party/sources/re_editor/LICENSE",
    "build/generated/bundled/legal/certificates/NOTICE.txt",
    "build/generated/bundled/legal/certificates/MPL-2.0.txt",
    "third_party/notices/publicsuffix.txt",
    "build/generated/bundled/legal/geodata/NOTICE.txt",
    "build/generated/bundled/legal/geodata/CC-BY-SA-4.0.txt",
    "build/generated/bundled/legal/geodata/GeoSite-MIT.txt",
    "build/generated/bundled/legal/geodata/CC-BY-4.0.txt",
)
ABIS = {"armeabi-v7a": "arm", "arm64-v8a": "arm64", "x86_64": "amd64"}
# 限制归档成员的读取大小，包括gzip解压后的内容。
TEXT_LIMIT = 32 * 1024 * 1024
LIBRARY_LIMIT = 256 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def emit(label, **details):
    print(label + " " + json.dumps(details, ensure_ascii=False, sort_keys=True))


def go_modules(path):
    """读取go list -m -json all依次输出的多个JSON对象。"""
    text = path.read_text(encoding="utf-8").strip()
    decoder = json.JSONDecoder()
    modules = {}
    while text:
        module, end = decoder.raw_decode(text)
        require(isinstance(module, dict) and module.get("Path"), "Invalid Go module object")
        name = module["Path"]
        require(name not in modules, "Duplicate Go module: " + name)
        if not module.get("Main"):
            require(module.get("Version"), "Unversioned Go module: " + name)
        replacement = module.get("Replace")
        if replacement:
            require(isinstance(replacement, dict) and replacement.get("Path") and replacement.get("Version"),
                    "Local/unversioned Go replacement is not supported: " + name)
        modules[name] = module
        text = text[end:].strip()
    require(sum(bool(m.get("Main")) for m in modules.values()) == 1,
            "Go input must contain exactly one Main module")
    return modules


def android_coordinates(text):
    """读取依赖报告中最终选择的Maven坐标。"""
    require(re.search(r"^releaseRuntimeClasspath(?:\s|$)", text, re.M),
            "Expected a releaseRuntimeClasspath dependency report")
    selected = set()
    for line in text.splitlines():
        match = re.search(r"(?:\+---|\\---)\s+(\S+)(?:\s+->\s+(\S+))?", line)
        if not match:
            continue
        require("FAILED" not in line and "(n)" not in line,
                "Unresolved Android dependency: " + line.strip())
        if "(c)" in line:
            continue
        requested, chosen = match.groups()
        if requested == "project" and re.search(r"project\s+(?::[\w:.-]+|':[^'\s]+')(?:\s+\(\*\))?\s*$", line):
            # Flutter插件作为本地Gradle项目参与构建；下方核对其Maven依赖，
            # 插件许可则从NOTICES.Z中核对。
            continue
        parts = requested.split(":")
        require(len(parts) in (2, 3), "Unsupported Android dependency: " + requested)
        if chosen:
            parts = chosen.split(":") if ":" in chosen else parts[:2] + [chosen]
        require(len(parts) == 3 and all(parts), "Missing selected Maven coordinate: " + line.strip())
        if parts[0] != "io.flutter":
            selected.add(":".join(parts))
    require(selected, "No non-Flutter Android dependencies found")
    return selected


def parse_buildinfo(text):
    dependencies = {}
    settings = {}
    main = None
    previous = None
    for line in text.splitlines():
        fields = line.strip().split("\t")
        if fields[0] == "mod":
            require(len(fields) >= 3 and main is None, "Invalid Go main-module buildinfo")
            main = fields[1]
        elif fields[0] == "dep":
            require(len(fields) in (3, 4) and fields[1] not in dependencies,
                    "Invalid/duplicate Go buildinfo dependency")
            previous = fields[1]
            dependencies[previous] = {"Path": previous, "Version": fields[2],
                                      "Sum": fields[3] if len(fields) == 4 else ""}
        elif fields[0] == "=>":
            require(previous is not None and len(fields) in (3, 4)
                    and "Replace" not in dependencies[previous], "Invalid Go buildinfo replacement")
            dependencies[previous]["Replace"] = {
                "Path": fields[1], "Version": fields[2],
                "Sum": fields[3] if len(fields) == 4 else "",
            }
        elif fields[0] == "build":
            require(len(fields) == 2 and "=" in fields[1], "Invalid Go build setting")
            key, value = fields[1].split("=", 1)
            require(key not in settings, "Duplicate Go build setting: " + key)
            settings[key] = value
    require(main and dependencies, "Missing Go main module or dependencies in buildinfo")
    return main, dependencies, settings


def check_linked(main, dependencies, settings, abi, modules, notices):
    require(modules.get(main, {}).get("Main"), "Linked Go main module differs from input graph")
    require(settings.get("GOOS") == "android", abi + ": GOOS is not android")
    require(settings.get("GOARCH") == ABIS[abi], abi + ": GOARCH mismatch")
    if abi == "armeabi-v7a":
        require(settings.get("GOARM") in ("7", "7,hardfloat"), abi + ": GOARM must target ARMv7")
    require(set(settings.get("-tags", "").split(",")) == {"cmfa", "with_gvisor"},
            abi + ": production tags mismatch")
    for name, linked in dependencies.items():
        selected = modules.get(name)
        require(selected is not None, "Linked module absent from selected graph: " + name)
        for key in ("Version", "Sum"):
            require(linked[key] == selected.get(key, ""), name + ": linked " + key + " mismatch")
        replacement = linked.get("Replace")
        expected = selected.get("Replace")
        require(bool(replacement) == bool(expected), name + ": replacement presence mismatch")
        if replacement:
            require(all(replacement[k] == expected.get(k, "") for k in ("Path", "Version", "Sum")),
                    name + ": linked replacement mismatch")
        effective = replacement or linked
        require((effective["Path"], effective["Version"]) in notices,
                "Go notice missing linked version: " + effective["Path"] + " " + effective["Version"])


def read_entry(archive, name, limit):
    entry = archive.getinfo(name)
    require(entry.file_size <= limit, "Archive entry exceeds size limit: " + name)
    with archive.open(entry) as stream:
        data = stream.read(limit + 1)
    require(len(data) <= limit, "Archive entry exceeds size limit: " + name)
    return data


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate manifest key: " + key)
        result[key] = value
    return result


def resource_origin(row, label):
    require(isinstance(row.get("version"), str) and row["version"]
            and row["version"].lower() != "latest", "Missing fixed resource version: " + label)
    url = row.get("sourceUrl", "")
    require(isinstance(url, str) and re.fullmatch(r"https://[A-Za-z0-9.-]+/[^\s?#]+", url)
            and "/latest/" not in url, "Invalid fixed resource URL: " + label)
    return {"version": row["version"], "source_url": url}


def check_public_suffix(root, module, source):
    """校验所选模块zip的h1，比较编译表记录的提交、来源通知和可编辑PSL列表。"""
    effective = module.get("Replace") or module
    name, version = effective["Path"], effective["Version"]
    prefix = name + "@" + version + "/"
    entries = []
    total = 0
    with zipfile.ZipFile(source) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate x/net source archive names")
        for path in sorted(names):
            require(path.startswith(prefix) and ".." not in path.split("/") and "\n" not in path,
                    "Invalid selected x/net source archive path")
            data = read_entry(archive, path, TEXT_LIMIT)
            total += len(data)
            require(total <= LIBRARY_LIMIT, "x/net source archive exceeds size limit")
            entries.append(digest(data) + "  " + path + "\n")
        module_sum = "h1:" + base64.b64encode(hashlib.sha256("".join(entries).encode()).digest()).decode()
        require(module_sum == effective.get("Sum"), "x/net source archive Sum mismatch")
        table = read_entry(archive, prefix + "publicsuffix/table.go", TEXT_LIMIT)
    revision = re.search(rb"git revision ([0-9a-f]{40})", table[:6000])
    require(revision, "Compiled publicsuffix revision is missing")
    revision = revision[1].decode()
    notice = (root / "third_party/notices/publicsuffix.txt").read_text(encoding="utf-8")
    data = (root / "third_party/data/publicsuffix/public_suffix_list.dat").read_bytes()
    require(revision in notice and version in notice and digest(data) in notice,
            "PSL notice differs from selected x/net revision or editable source bytes")
    require(b"Mozilla Public" in data[:4096] and b"2.0" in data[:4096], "PSL editable source license is missing")
    result = {"verified": True, "module": name, "version": version, "sum": module_sum, "revision": revision,
              "bytes": len(data), "sha256": digest(data), "table_sha256": digest(table)}
    emit("PUBLIC_SUFFIX", **result)
    return result


def check_platform_assets(archive, root, release_inputs=None):
    spec = importlib.util.spec_from_file_location("dependency_update_verifier", Path(__file__).resolve().parents[2] / "tool/dependencies/update.py")
    update = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(update)
    record = update.read_release_resources(root, release_inputs)
    source = root / update.GENERATED_BUNDLED / "assets"
    require(json.loads((source.parent / "resources.json").read_bytes(), object_pairs_hook=unique_object) == record,
            "generated assets 与指定的 release 输入记录不同")
    certificate_manifest = json.loads(
        (source.parent / "certificates.json").read_text(encoding="utf-8"),
        object_pairs_hook=unique_object)
    certificate_origin = resource_origin(certificate_manifest, "CA")
    certificate = certificate_manifest["asset"]
    require(isinstance(certificate, str)
            and re.fullmatch(r"certificates/[A-Za-z0-9_-][A-Za-z0-9_.-]*\.pem", certificate),
            "Invalid certificate asset name")
    size = certificate_manifest["bytes"]
    checksum = certificate_manifest["sha256"]
    require(type(size) is int and 0 < size <= TEXT_LIMIT
            and isinstance(checksum, str) and re.fullmatch(r"[0-9a-f]{64}", checksum),
            "Invalid certificate size or SHA-256")
    actual = read_entry(archive, "assets/" + certificate, TEXT_LIMIT)
    require(actual == (source / certificate).read_bytes()
            and len(actual) == size and digest(actual) == checksum,
            "Platform asset bytes differ: " + certificate)
    certificates = {name for name in archive.namelist()
                    if name.startswith("assets/certificates/") and not name.endswith("/")}
    require(certificates == {"assets/" + certificate}, "Unexpected certificate assets")
    emit("PLATFORM_ASSET", entry="assets/" + certificate, bytes=len(actual), sha256=digest(actual),
         **certificate_origin)
    manifest_bytes = read_entry(archive, "assets/geodata/manifest.json", 64 * 1024)
    require(manifest_bytes == (source / "geodata/manifest.json").read_bytes(), "Geo manifest bytes differ")
    manifest = json.loads(manifest_bytes, object_pairs_hook=unique_object)
    require(manifest.get("format") == "clash-pseudo-bundled-geodata" and type(manifest.get("version")) is int
            and manifest["version"] == 1, "Unsupported Geo manifest")
    files = manifest["files"]
    require(isinstance(files, list) and all(isinstance(row, dict) for row in files)
            and len(files) == 4 and {row["kind"] for row in files} == {"geoip", "geosite", "mmdb", "asn"},
            "Expected exactly four Geo kinds")
    require(len({row["asset"] for row in files}) == 4, "Duplicate Geo asset name")
    stored_total = installed_total = compressed_total = 0
    for row in files:
        origin = resource_origin(row, row["kind"])
        work_name = {"geoip": "GeoIP.dat", "geosite": "GeoSite.dat", "mmdb": "Country.mmdb", "asn": "ASN.mmdb"}[row["kind"]]
        require(row.get("workName") == work_name, "Invalid Geo install target: " + row["kind"])
        require(isinstance(row.get("licenses"), list) and row["licenses"]
                and all(isinstance(value, str) and value for value in row["licenses"])
                and isinstance(row.get("attribution"), str) and row["attribution"]
                and isinstance(row.get("changes"), str) and row["changes"], "Missing Geo legal provenance")
        expected_licenses = ({"CC-BY-SA-4.0", "CC-BY-4.0"} if row["kind"] == "geoip"
                             else {"MIT"} if row["kind"] == "geosite" else {"CC-BY-4.0"})
        require(expected_licenses <= set(row["licenses"]), "Missing Geo source license attribution")
        if row["kind"] in ("geoip", "geosite"):
            require(isinstance(row.get("sourceCommit"), str)
                    and re.fullmatch(r"[0-9a-f]{40}", row["sourceCommit"]), "Missing fixed V2Fly source commit")
            origin["source_commit"] = row["sourceCommit"]
        name = row["asset"]
        require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_.-]+", name)
                and name not in (".", ".."), "Invalid Geo asset name")
        require(all(type(row[key]) is int and 0 < row[key] <= TEXT_LIMIT
                    for key in ("storedBytes", "installedBytes")), "Invalid fixed Geo size")
        require(all(isinstance(row[key], str) and re.fullmatch(r"[0-9a-f]{64}", row[key])
                    for key in ("storedSha256", "installedSha256")), "Invalid fixed Geo SHA-256")
        entry = "assets/geodata/" + name
        stored = read_entry(archive, entry, row["storedBytes"])
        require(len(stored) == row["storedBytes"] and digest(stored) == row["storedSha256"],
                "Stored Geo checksum differs: " + name)
        require(stored == (source / "geodata" / name).read_bytes(), "Geo source bytes differ: " + name)
        if row["encoding"] == "gzip":
            with gzip.GzipFile(fileobj=io.BytesIO(stored)) as stream:
                installed = stream.read(row["installedBytes"] + 1)
        else:
            require(row["encoding"] == "identity", "Unsupported Geo encoding")
            installed = stored
        require(len(installed) == row["installedBytes"] and digest(installed) == row["installedSha256"],
                "Expanded Geo checksum differs: " + name)
        stored_total += len(stored)
        installed_total += len(installed)
        compressed = archive.getinfo(entry).compress_size
        compressed_total += compressed
        emit("GEODATA_ASSET", entry=entry, work_name=work_name, stored_bytes=len(stored), installed_bytes=len(installed),
             apk_compressed_bytes=compressed, sha256=digest(stored), installed_sha256=digest(installed), **origin)
    require(all(type(manifest[key]) is int for key in ("storedDataTotalBytes", "installedTotalBytes"))
            and stored_total == manifest["storedDataTotalBytes"] and installed_total == manifest["installedTotalBytes"],
            "Geo manifest totals differ")
    legal = manifest.get("legalMaterials", []) + ([manifest["notice"]] if "notice" in manifest else [])
    require(len({row["file"] for row in legal}) == len(legal), "Duplicate Geo legal asset name")
    for row in legal:
        name = row["file"]
        require(isinstance(name, str) and re.fullmatch(r"(?:licenses/)?[A-Za-z0-9_.-]+", name)
                and name.split("/")[-1] not in (".", ".."), "Invalid Geo legal asset name")
        actual = read_entry(archive, "assets/geodata/" + name, TEXT_LIMIT)
        canonical = source / "geodata" / name
        require(type(row["bytes"]) is int and 0 < row["bytes"] <= TEXT_LIMIT
                and isinstance(row["sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", row["sha256"]),
                "Invalid Geo legal size or SHA-256")
        require(actual == canonical.read_bytes()
                and len(actual) == row["bytes"] and digest(actual) == row["sha256"],
                "Geo legal asset bytes differ: " + name)
    expected = {"assets/geodata/manifest.json"} | {"assets/geodata/" + row["asset"] for row in files}
    expected |= {"assets/geodata/" + row["file"] for row in legal}
    actual_names = {name for name in archive.namelist() if name.startswith("assets/geodata/") and not name.endswith("/")}
    require(actual_names == expected, "Unexpected Geo assets or expanded duplicate")
    update.verify_bundled_assets(root, record)
    emit("GEODATA_TOTAL", stored_bytes=stored_total, installed_bytes=installed_total,
         apk_compressed_data_bytes=compressed_total, scope="数据文件内容的总大小，不含ZIP结构、签名和对齐填充")


def verify(args):
    root = args.project.resolve()
    output = args.output_dir.resolve()
    require(output.is_dir() and not any(output.iterdir()), "Output directory must exist and be empty")
    modules = go_modules(args.go_modules)
    xnet_source = getattr(args, "xnet_source", None)
    if xnet_source is not None:
        require("golang.org/x/net" in modules, "Selected graph has no x/net module")
        check_public_suffix(root, modules["golang.org/x/net"], xnet_source)
    else:
        emit("PUBLIC_SUFFIX", verified=False, reason="填写--xnet-source参数，指定实际所选x/net模块的原始zip路径，然后重新运行PSL来源核验")
    abis = tuple(getattr(args, "abis", None) or ABIS)
    require(len(set(abis)) == len(abis) and set(abis) <= ABIS.keys(), "Invalid target ABI selection")
    selected = android_coordinates(args.android_dependencies.read_text(encoding="utf-8"))
    android_notice = (root / "third_party/notices/android.txt").read_text(encoding="utf-8")
    notice_coordinates = set(re.findall(r"^([\w.-]+:[\w.-]+:[^\s:]+)$", android_notice, re.M))
    require(selected == notice_coordinates,
            "Android notice coordinates differ: missing=" + repr(sorted(selected - notice_coordinates))
            + "; extra=" + repr(sorted(notice_coordinates - selected)))
    emit("ANDROID_GRAPH", coordinates=len(selected))
    go_notice = (root / "third_party/notices/go.txt").read_text(encoding="utf-8")
    notice_modules = set(re.findall(r"^([\w.-]+(?:/[\w.+~-]+)+) (v[^\s]+)$", go_notice, re.M))
    expected_notices = args.notices.read_bytes()
    require(expected_notices and len(expected_notices) <= TEXT_LIMIT,
            "作为比较依据的NOTICES文件须为非空文本，且大小在上限以内")
    expected_notices.decode("utf-8")
    with args.apk.open("rb") as stream:
        apk_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    emit("APK", path=str(args.apk.resolve()), sha256=apk_hash)
    with zipfile.ZipFile(args.apk) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate APK archive names")
        for relative in ASSETS:
            name = "assets/flutter_assets/" + relative
            actual = read_entry(archive, name, TEXT_LIMIT)
            require(actual == (root / relative).read_bytes(), "License asset bytes differ: " + relative)
            emit("LICENSE_ASSET", entry=name, bytes=len(actual), sha256=digest(actual))
        compressed = read_entry(archive, "assets/flutter_assets/NOTICES.Z", TEXT_LIMIT)
        # 通过GzipFile.read分段解压，并限制解压后内容的大小。
        with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as stream:
            notices = stream.read(TEXT_LIMIT + 1)
        require(notices == expected_notices, "NOTICES.Z解压后的内容与指定的NOTICES文件不同")
        emit("NOTICES", bytes=len(notices), sha256=digest(notices))
        check_platform_assets(archive, root, getattr(args, "release_inputs", None))
        libraries = sorted(n for n in names if n.startswith("lib/") and n.endswith("/libmihomo_bridge.so"))
        require(libraries == sorted("lib/" + abi + "/libmihomo_bridge.so" for abi in abis),
                "Expected exactly the selected native bridge ABIs: " + ", ".join(abis))
        packaged_abis = {name.split("/")[1] for name in names if name.startswith("lib/") and len(name.split("/")) >= 3}
        require(packaged_abis == set(abis), "Packaged native ABIs differ from selected targets")
        graphs = []
        for name in libraries:
            abi = name.split("/")[1]
            directory = output / abi
            directory.mkdir()
            library = directory / "libmihomo_bridge.so"
            data = read_entry(archive, name, LIBRARY_LIMIT)
            library.write_bytes(data)
            env = dict(os.environ, GOTOOLCHAIN="local", GOPROXY="off", GOSUMDB="off", GOENV="off")
            process = subprocess.run([args.go, "version", "-m", str(library)], cwd=root,
                                     env=env, text=True, capture_output=True, timeout=30)
            (directory / "buildinfo.txt").write_text(process.stdout + process.stderr, encoding="utf-8")
            require(process.returncode == 0, abi + ": go version -m failed; see buildinfo.txt")
            main, dependencies, settings = parse_buildinfo(process.stdout)
            check_linked(main, dependencies, settings, abi, modules, notice_modules)
            emit("BUILDINFO", abi=abi, dependencies=len(dependencies), sha256=digest(data))
            graphs.append(dependencies)
        require(all(graph == graphs[0] for graph in graphs[1:]),
                "Native ABIs link different Go dependency graphs")
    emit("FINAL", exit_code=0, scope="许可与数据资产字节、各ABI的Go buildinfo及所选依赖图")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-inputs", type=Path, help="本次 third_party/data/resources.json 的路径")
    parser.add_argument("--project", required=True, type=Path, help="本次构建的项目根目录")
    parser.add_argument("--apk", required=True, type=Path, help="待核验APK路径")
    parser.add_argument("--notices", required=True, type=Path, help="从依赖源码生成并解码的NOTICES文件")
    parser.add_argument("--abi", dest="abis", action="append", choices=tuple(ABIS),
                        help="APK应含的ABI；通用版可重复指定，默认核对三个ABI")
    parser.add_argument("--go-modules", required=True, type=Path, help="本次go list -m -json all输出文件")
    parser.add_argument("--xnet-source", type=Path,
                        help="实际所选x/net模块原始zip，用于核对PSL提交及可编辑列表")
    parser.add_argument("--android-dependencies", required=True, type=Path,
                        help="本次Gradle releaseRuntimeClasspath依赖报告")
    parser.add_argument("--output-dir", required=True, type=Path, help="已有空目录，保存各ABI原生库和buildinfo.txt")
    parser.add_argument("--go", default="go", help="已安装Go可执行文件的名称或路径")
    args = parser.parse_args(argv)
    try:
        verify(args)
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile,
            EOFError, zlib.error, subprocess.SubprocessError) as error:
        emit("FINAL", exit_code=1, error=str(error))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
