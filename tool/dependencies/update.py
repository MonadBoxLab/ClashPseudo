#!/usr/bin/env python3
"""检查或更新依赖、许可材料与应用版本；默认跟随 mihomo 正式版。"""

import argparse
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import ssl
import stat
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
MIHOMO = "github.com/metacubex/mihomo"
GO_INPUTS = ("native/mihomo/go.mod", "native/mihomo/go.sum")
ASSET_ROOT = "android/app/src/main/assets/"
RESOURCE_ASSETS = {
    "ca": "certificates/cacert.pem",
    "geoip": "geodata/GeoIP.dat",
    "geosite": "geodata/GeoSite.dat",
    "mmdb": "geodata/dbip-country-lite.mmdb.gzip",
    "asn": "geodata/dbip-asn-lite.mmdb.gzip",
}
RESOURCE_RECORD = "third_party/data/resources.json"
GENERATED_BUNDLED = "build/generated/bundled"
RESOURCE_INPUTS = (
    RESOURCE_RECORD,
    "third_party/data/certificates/MPL-2.0.txt",
    "third_party/data/geodata/CC-BY-SA-4.0.txt",
    "third_party/data/geodata/GeoSite-MIT.txt",
    "third_party/data/geodata/CC-BY-4.0.txt",
)
INPUTS = GO_INPUTS + (
    "pubspec.yaml", "pubspec.lock", "android/app/build.gradle.kts", "android/settings.gradle.kts",
    "android/gradle/wrapper/gradle-wrapper.properties", ".github/workflows/update-dependencies.yml",
    "third_party/notices/go.txt", "third_party/notices/mihomo.txt",
    "third_party/notices/android.txt", "third_party/notices/publicsuffix.txt",
    "third_party/data/publicsuffix/public_suffix_list.dat",
) + RESOURCE_INPUTS
CHUNK = 64 * 1024
FETCH_LIMIT = 64 * 1024 * 1024
RESOURCE_LIMIT = 128 * 1024 * 1024
RESOURCE_TOTAL_LIMIT = 256 * 1024 * 1024
MAVEN = ("https://dl.google.com/dl/android/maven2", "https://repo.maven.apache.org/maven2")
VERSION = re.compile(r"(?m)^version: ([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)[ \t]*$")
MAVEN_DECLARATION = re.compile(
    r'(?P<prefix>\b(?:implementation|api|testImplementation|androidTestImplementation)\(")'
    r'(?P<name>[\w.-]+:[\w.-]+):(?P<version>[^"\s]+)(?P<suffix>"\))')


def load_tool(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


artifacts = load_tool("release_licenses", ROOT / "tool/artifacts/verify_release_licenses.py")
require = artifacts.require


def run(command, cwd, env=None):
    process = subprocess.run(
        list(map(str, command)), cwd=cwd,
        env={**os.environ, "GOTOOLCHAIN": "local", "GOWORK": "off", "GIT_OPTIONAL_LOCKS": "0", **(env or {})},
        text=True, capture_output=True, check=False,
    )
    if process.returncode:
        raise ValueError(f"命令失败（{process.returncode}）：{' '.join(map(str, command))}\n"
                         + process.stdout + process.stderr)
    return process.stdout


def read_bounded(stream, limit):
    output = io.BytesIO()
    transfer(stream, output, limit)
    return output.getvalue()


def transfer(source, destination, limit):
    require(type(limit) is int and limit > 0, "读取大小上限无效")
    size, digest = 0, hashlib.sha256()
    while True:
        chunk = source.read(min(CHUNK, limit - size + 1))
        if not chunk:
            break
        size += len(chunk)
        require(size <= limit, "数据超过读取大小上限")
        digest.update(chunk)
        destination.write(chunk)
    return {"bytes": size, "sha256": digest.hexdigest()}


class HttpsRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, url):
        require(url.startswith("https://"), "重定向来源必须使用 HTTPS")
        return super().redirect_request(request, fp, code, message, headers, url)


def fetch(url, *, limit=FETCH_LIMIT, destination=None):
    """通过HTTPS下载更新材料，按limit限制响应大小。"""
    require(url.startswith("https://"), "来源必须使用 HTTPS：" + url)
    request = urllib.request.Request(url, headers={"User-Agent": "clash-pseudo-dependency-update"})
    with urllib.request.build_opener(HttpsRedirect()).open(request, timeout=60) as response:
        require(response.geturl().startswith("https://"), "响应来源必须使用 HTTPS")
        length = response.headers.get("Content-Length")
        if length is not None:
            require(length.isdecimal() and int(length) <= limit, "响应长度超过读取大小上限或无效")
        if destination is None:
            data = read_bounded(response, limit)
            require(length is None or len(data) == int(length), "Content-Length 声明的字节数与实际读取的字节数不一致")
            return data
        with Path(destination).open("xb") as output:
            result = transfer(response, output, limit)
            output.flush()
            os.fsync(output.fileno())
        require(length is None or result["bytes"] == int(length), "Content-Length 声明的字节数与实际读取的字节数不一致")
        return result


def stable_version(value):
    match = re.fullmatch(r"v?([0-9]+(?:\.[0-9]+){1,3})", value)
    return tuple(map(int, match[1].split("."))) if match else None


def mihomo_release():
    release = json.loads(fetch("https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"))
    value = release.get("tag_name", "")
    require(not release.get("draft") and not release.get("prerelease")
            and re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", value), "上游返回的版本不是正式发布")
    return value


def bump_version(text, level="patch"):
    matches = list(VERSION.finditer(text))
    require(len(matches) == 1, "pubspec.yaml 必须有唯一的 major.minor.patch+versionCode")
    major, minor, patch, code = map(int, matches[0].groups())
    require(code < 2100000000, "Android versionCode 已达到平台上限")
    require(level in ("major", "minor", "patch", "stable"), "应用版本的递增方式无效")
    if level == "stable":
        require(major == 0, "首次稳定发布仅适用于 0.y.z 开发版本")
        major, minor, patch = 1, 0, 0
    elif level == "major":
        require(major > 0, "开发版本的不兼容调整使用 minor；首次稳定发布须明确选择 stable")
        major, minor, patch = major + 1, 0, 0
    elif level == "minor":
        minor, patch = minor + 1, 0
    else:
        patch += 1
    value = f"{major}.{minor}.{patch}+{code + 1}"
    return text[:matches[0].start()] + "version: " + value + text[matches[0].end():], value


def application_version(root):
    matches = list(VERSION.finditer((root / "pubspec.yaml").read_text(encoding="utf-8")))
    require(len(matches) == 1, "pubspec.yaml 应用版本格式无效")
    return ".".join(matches[0].groups()[:3]) + "+" + matches[0][4]


def input_path(root, name):
    require(name in INPUTS, "该文件不在允许更新的列表中：" + name)
    path = root / name
    require(path.resolve() == root.resolve() / name, "输入包含符号链接：" + name)
    require(not path.exists() or path.is_file(), "输入不是普通文件：" + name)
    return path


def input_bytes(root, name):
    path = input_path(root, name)
    if not path.exists():
        return None
    with path.open("rb") as stream:
        return read_bounded(stream, RESOURCE_LIMIT)


def snapshot(root):
    return {name: input_bytes(root, name) for name in INPUTS}


def copy_workspace(root, destination):
    """复制当前文件内容，包含尚未提交的正式输入，排除 Git 忽略的构建输出。"""
    files = run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], root)
    for name in set(files.split("\0")) - {""}:
        relative = Path(name)
        require(not relative.is_absolute() and ".." not in relative.parts, "Git 文件路径无效")
        source = root / relative
        if not source.exists():
            continue
        require(source.is_file() and not source.is_symlink(), "更新副本要求普通文件：" + name)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    # 本机 SDK 位置属于执行输入，始终排除在写回和源码分发之外。
    properties = root / "android/local.properties"
    if properties.is_file():
        (destination / "android").mkdir(parents=True, exist_ok=True)
        shutil.copy2(properties, destination / "android/local.properties")


def stage_bytes(path, data):
    descriptor, name = tempfile.mkstemp(prefix=".clash-update-", dir=path.parent)
    staged = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        staged.chmod(stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644)
        return staged
    except BaseException:
        staged.unlink(missing_ok=True)
        raise


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def publish_changes(root, before, after):
    """先准备所有文件的新内容，再比较并逐个原子替换；失败时只回滚仍与本次写入内容一致的文件。"""
    require(set(before) == set(after) == set(INPUTS), "更新事务必须包含 INPUTS 列出的全部文件，且不得包含其他文件")
    changes = {name: data for name, data in after.items() if before[name] != data}
    require(all(isinstance(data, bytes) for data in changes.values()), "更新内容必须以 bytes 提供")
    staged, backups, written = {}, {}, []
    failure = None
    try:
        for name, data in changes.items():
            path = input_path(root, name)
            path.parent.mkdir(parents=True, exist_ok=True)
            staged[name] = stage_bytes(path, data)
            if before[name] is not None:
                backups[name] = stage_bytes(path, before[name])
        # 包括未写入但被本次解析使用的输入，避免把不同来源的依赖或资源拼在一起。
        for name in INPUTS:
            require(input_bytes(root, name) == before[name], "更新期间文件发生变化，保留现有内容：" + name)
        for name in changes:
            path = input_path(root, name)
            require(input_bytes(root, name) == before[name], "更新期间文件发生变化，保留现有内容：" + name)
            os.replace(staged[name], path)
            written.append(name)
            sync_directory(path.parent)
        for name in INPUTS:
            require(input_bytes(root, name) == after[name], "更新期间文件发生变化，保留现有内容：" + name)
    except BaseException as error:
        failure = error
        for name in reversed(written):
            try:
                path = input_path(root, name)
                if input_bytes(root, name) != changes[name]:
                    continue  # 文件在本次写入后已被修改，保留当前内容。
                if before[name] is None:
                    path.unlink()
                else:
                    os.replace(backups[name], path)
                sync_directory(path.parent)
            except BaseException as cleanup:
                error.add_note("事务回滚未完成：" + name + "；" + repr(cleanup))
        raise
    finally:
        for path in (*staged.values(), *backups.values()):
            try:
                path.unlink(missing_ok=True)
            except OSError as cleanup:
                if failure is None:
                    raise
                failure.add_note("事务临时文件清理失败：" + repr(cleanup))
    return sorted(changes)


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "JSON 包含重复字段：" + key)
        result[key] = value
    return result


def resource_spec(spec):
    """校验资源来源、版本、大小和摘要字段，返回规范化的资源记录。"""
    require(isinstance(spec, dict), "资源输入必须是对象")
    spec = dict(spec)
    kind = spec.get("kind")
    require(isinstance(kind, str) and kind in RESOURCE_ASSETS, "未知资源种类")
    encoding = "gzip" if kind in ("mmdb", "asn") else "identity"
    require(spec.get("encoding", encoding) == encoding, "资源编码方式与该类资源要求的编码方式不一致")
    spec["encoding"] = encoding
    version, url = spec.get("version"), spec.get("sourceUrl")
    require(isinstance(version, str) and isinstance(url, str), "资源版本与来源缺失")
    if kind == "ca":
        require(re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", version)
                and url == f"https://curl.se/ca/cacert-{version}.pem", "CA 来源必须为 curl 按日期发布的原始 PEM 文件")
        checksum = spec.get("checksumUrl")
        require(checksum is None or checksum == url + ".sha256", "CA 校验文件地址必须与该 PEM 文件对应")
        if "certificateRoots" in spec:
            require(type(spec["certificateRoots"]) is int and spec["certificateRoots"] > 0,
                    "CA 证书数量必须为正整数")
    elif kind in ("geoip", "geosite"):
        repository, name = ("geoip", "geoip.dat") if kind == "geoip" else ("domain-list-community", "dlc.dat")
        require(re.fullmatch(r"[0-9]{8,14}", version)
                and url == f"https://github.com/v2fly/{repository}/releases/download/{version}/{name}",
                "V2Fly 资源必须指定已发布的版本")
        require(isinstance(spec.get("sourceCommit"), str)
                and re.fullmatch(r"[0-9a-f]{40}", spec["sourceCommit"]), "缺少 V2Fly 源码提交号")
        require(isinstance(spec.get("licenseSha256"), str)
                and re.fullmatch(r"[0-9a-f]{64}", spec["licenseSha256"]), "V2Fly 原始许可摘要缺失")
    else:
        name = "country" if kind == "mmdb" else "asn"
        require(re.fullmatch(r"[0-9]{4}-(?:0[1-9]|1[0-2])", version)
                and url == f"https://download.db-ip.com/free/dbip-{name}-lite-{version}.mmdb.gz"
                and spec.get("sourcePage") == f"https://db-ip.com/db/download/ip-to-{name}-lite",
                "DB-IP 资源必须指定官网下载页列出的年月版本")
    for prefix, limit in (("stored", FETCH_LIMIT), ("installed", RESOURCE_LIMIT)):
        if prefix + "Bytes" in spec:
            require(type(spec[prefix + "Bytes"]) is int and 0 < spec[prefix + "Bytes"] <= limit,
                    "资源大小无效或超过上限：" + prefix)
        if prefix + "Sha256" in spec:
            require(isinstance(spec[prefix + "Sha256"], str)
                    and re.fullmatch(r"[0-9a-f]{64}", spec[prefix + "Sha256"]), "资源摘要无效：" + prefix)
    if "sourceInputs" in spec:
        entries = spec["sourceInputs"]
        require(kind == "geoip" and isinstance(entries, list) and entries, "资源补充输入只适用于 GeoIP 且不能为空")
        commits, names = set(), set()
        for entry in entries:
            require(isinstance(entry, dict) and set(entry) == {"sourceCommit", "description"},
                    "资源补充输入字段无效")
            commit, description = entry["sourceCommit"], entry["description"]
            require(isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{40}", commit), "资源补充输入 commit 无效")
            require(isinstance(description, str) and description.strip(), "资源补充输入缺少说明")
            require(commit not in commits, "重复的资源补充输入：" + commit)
            commits.add(commit)
    if encoding == "identity":
        for suffix in ("Bytes", "Sha256"):
            if "stored" + suffix in spec and "installed" + suffix in spec:
                require(spec["stored" + suffix] == spec["installed" + suffix], "未压缩资源必须保留原始字节")
    return spec


def protobuf_fields(data):
    """遍历DAT的Protocol Buffers字段，检查字段号、类型和长度。"""
    data, offset = memoryview(data), 0

    def varint():
        nonlocal offset
        value = 0
        for shift in range(0, 70, 7):
            require(offset < len(data), "DAT varint 被截断")
            byte = data[offset]
            offset += 1
            require(shift < 63 or byte <= 1, "DAT varint 超出范围")
            value |= (byte & 127) << shift
            if not byte & 128:
                return value
        raise ValueError("DAT varint 超出范围")

    while offset < len(data):
        tag = varint()
        field, wire = tag >> 3, tag & 7
        require(0 < field < 1 << 29, "DAT 字段号无效")
        if wire == 0:
            value = varint()
        else:
            require(wire in (1, 2, 5), "DAT wire 类型无效")
            size = varint() if wire == 2 else 8 if wire == 1 else 4
            require(size <= len(data) - offset, "DAT 字段被截断")
            value = data[offset:offset + size]
            offset += size
        yield field, wire, value


def validate_dat(data, kind):
    records, values = 0, 0
    for field, wire, entry in protobuf_fields(data):
        if field != 1:
            continue
        require(wire == 2, "DAT 根记录类型无效")
        code = None
        for number, inner_wire, value in protobuf_fields(entry):
            if number == 1:
                require(inner_wire == 2, "DAT 分类类型无效")
                code = bytes(value).decode("utf-8")
            elif number == 2:
                require(inner_wire == 2, "DAT 条目类型无效")
                details = {}
                for key, item_wire, item in protobuf_fields(value):
                    if key in (1, 2):
                        details[key] = (item_wire, item)
                if kind == "geoip":
                    address = details.get(1)
                    prefix = details.get(2, (0, 0))
                    require(address is not None and address[0] == 2 and len(address[1]) in (4, 16)
                            and prefix[0] == 0 and 0 <= prefix[1] <= len(address[1]) * 8, "GeoIP CIDR 无效")
                else:
                    domain = details.get(2)
                    require(domain is not None and domain[0] == 2
                            and bytes(domain[1]).decode("utf-8"), "GeoSite域名无效")
                values += 1
        require(code is not None and code.strip(), "DAT 分类缺失")
        records += 1
    require(records > 0 and values > 0, "DAT 为空或缺少实际条目")


def mmdb_metadata(data):
    marker = b"\xab\xcd\xefMaxMind.com"
    index = data.rfind(marker, max(0, len(data) - 128 * 1024))
    require(index > 0, "MMDB 元数据标记缺失")
    content, offset, count = memoryview(data)[index + len(marker):], 0, 0

    def decode(depth=0):
        nonlocal offset, count
        count += 1
        require(depth <= 8 and count <= 4096 and offset < len(content), "MMDB 元数据超过上限或数据不完整")
        control = content[offset]
        offset += 1
        kind, size = control >> 5, control & 31
        if kind == 0:
            require(offset < len(content), "MMDB 扩展类型字段不完整")
            kind = content[offset] + 7
            offset += 1
        if size >= 29:
            width = size - 28
            require(offset + width <= len(content), "MMDB 长度字段不完整")
            size = (29, 285, 65821)[width - 1] + int.from_bytes(content[offset:offset + width], "big")
            offset += width
        if kind == 7:
            require(size <= 256, "MMDB 映射表的条目数量超过上限")
            result = {}
            for _ in range(size):
                key = decode(depth + 1)
                require(isinstance(key, str) and key not in result, "MMDB 映射表键重复或无效")
                result[key] = decode(depth + 1)
            return result
        if kind == 11:
            require(size <= 256, "MMDB 数组元素数量超过上限")
            return [decode(depth + 1) for _ in range(size)]
        if kind == 14:
            require(size in (0, 1), "MMDB 布尔值的编码长度无效")
            return bool(size)
        require(kind in (2, 3, 4, 5, 6, 8, 9, 10, 15) and offset + size <= len(content),
                "MMDB 元数据类型无效或数据不完整")
        value = content[offset:offset + size]
        offset += size
        if kind == 2:
            return bytes(value).decode("utf-8")
        if kind in (5, 6, 8, 9, 10):
            require(size <= {5: 2, 6: 4, 8: 4, 9: 8, 10: 16}[kind], "MMDB 整数无效")
            return int.from_bytes(value, "big", signed=kind == 8)
        require(kind == 4 or kind == 3 and size == 8 or kind == 15 and size == 4, "MMDB 浮点数无效")
        return bytes(value)

    metadata = decode()
    require(isinstance(metadata, dict) and offset == len(content), "MMDB 元数据不完整或包含额外数据")
    require(metadata.get("binary_format_major_version") == 2, "MMDB 格式版本无效")
    nodes, bits = metadata.get("node_count"), metadata.get("record_size")
    require(type(nodes) is int and nodes > 0 and bits in (24, 28, 32)
            and metadata.get("ip_version") in (4, 6), "MMDB 搜索树定义无效")
    tree_size = nodes * (bits // 4)
    require(tree_size + 16 < index and data[tree_size:tree_size + 16] == bytes(16), "MMDB 搜索树或数据区无效")
    found_data = False
    width = bits // 4
    for start in range(0, tree_size, width):
        if bits == 28:
            left = int.from_bytes(data[start:start + 3], "big") | (data[start + 3] & 0xf0) << 20
            right = int.from_bytes(data[start + 4:start + 7], "big") | (data[start + 3] & 15) << 24
        else:
            half = width // 2
            left = int.from_bytes(data[start:start + half], "big")
            right = int.from_bytes(data[start + half:start + width], "big")
        for pointer in (left, right):
            if pointer > nodes:
                require(tree_size + 16 <= pointer - nodes + tree_size < index, "MMDB 数据指针越界")
                found_data = True
    require(found_data, "MMDB 搜索树没有数据记录")
    return metadata


def validate_resource(data, spec):
    # prepare_resource和read_prepared_resource校验来源；此处校验文件内容、格式和摘要。
    spec = dict(spec)
    stored = {"storedBytes": len(data), "storedSha256": hashlib.sha256(data).hexdigest()}
    require(0 < len(data) <= FETCH_LIMIT
            and all(spec.get(key, value) == value for key, value in stored.items()),
            "下载文件的字节数或 SHA-256 与记录值不一致，或大小超过上限")
    if spec["encoding"] == "gzip":
        with gzip.GzipFile(fileobj=io.BytesIO(data)) as stream:
            installed = read_bounded(stream, spec.get("installedBytes", RESOURCE_LIMIT))
    else:
        installed = data
    measured = {"installedBytes": len(installed), "installedSha256": hashlib.sha256(installed).hexdigest()}
    require(0 < len(installed) <= RESOURCE_LIMIT
            and all(spec.get(key, value) == value for key, value in measured.items()),
            "安装用文件的字节数或 SHA-256 与记录值不一致，或大小超过上限")
    kind = spec["kind"]
    if kind == "ca":
        # curl 原件的名称／注释可含 UTF-8；仅证书 PEM 块要求 ASCII，整份原字节不转换。
        blocks = re.findall(rb"-----BEGIN CERTIFICATE-----\s+.*?-----END CERTIFICATE-----", installed, re.S)
        require(blocks and len(blocks) == installed.count(b"-----BEGIN CERTIFICATE-----")
                == installed.count(b"-----END CERTIFICATE-----"), "CA PEM 为空或不完整")
        measured["certificateRoots"] = len(blocks)
        require(spec.get("certificateRoots", len(blocks)) == len(blocks), "CA 证书数量与 release 记录不同")
        for block in blocks:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.load_verify_locations(cadata=block.decode("ascii"))
    elif kind in ("geoip", "geosite"):
        validate_dat(installed, kind)
    else:
        metadata = mmdb_metadata(installed)
        expected = "Country" if kind == "mmdb" else "ASN"
        require(expected.lower() in str(metadata.get("database_type", "")).lower(), "MMDB 数据库种类与目标不同")
    return dict(spec, **stored, **measured)


def read_resource(path, limit):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "资源输入不是普通文件")
        return read_bounded(stream, limit)


def read_prepared_resource(directory):
    """读取input.json、receipt.json和payload，比较输入记录与文件内容、格式及摘要。"""
    directory = Path(directory).absolute()
    require(directory.resolve() == directory
            and (not directory.is_relative_to(ROOT) or directory.is_relative_to(ROOT / "build/generated")),
            "资源准备目录不能包含符号链接或写入源码目录")
    raw_input = read_resource(directory / "input.json", 64 * 1024)
    spec = resource_spec(json.loads(raw_input, object_pairs_hook=unique_object))
    require(raw_input == json_bytes(spec), "input.json内容与规范化后的资源记录不同")
    receipt = json.loads(read_resource(directory / "receipt.json", 128 * 1024), object_pairs_hook=unique_object)
    require(isinstance(receipt, dict) and receipt.get("format") == "clash-pseudo-prepared-resource"
            and receipt.get("version") == 1
            and receipt.get("inputSha256") == hashlib.sha256(raw_input).hexdigest(), "receipt.json 的格式、版本或 input.json 摘要不一致")
    resolved = resource_spec(receipt.get("resource"))
    measured_keys = {"storedBytes", "storedSha256", "installedBytes", "installedSha256"}
    if spec["kind"] == "ca":
        measured_keys.add("certificateRoots")
    require(set(resolved) == set(spec) | measured_keys
            and all(resolved.get(key) == value for key, value in spec.items()), "receipt.json 缺少实测大小或摘要，或记录的来源与输入不一致")
    data = read_resource(directory / "payload", resolved["storedBytes"])
    require(validate_resource(data, resolved) == resolved, "receipt.json 记录的大小或摘要与本地资源文件不一致")
    return resolved, data


def prepare_resource(spec, destination, source=None, *, fetch=None):
    """在独立目录准备资源，成功后写入receipt.json；再次运行时核对并复用已准备的文件。"""
    fetch = _resolver(fetch)
    spec = resource_spec(spec)
    destination = Path(destination).absolute()
    require(destination.resolve() == destination
            and (not destination.is_relative_to(ROOT) or destination.is_relative_to(ROOT / "build/generated")),
            "资源准备目录不能包含符号链接或写入源码目录")
    destination.mkdir(parents=True, exist_ok=True)
    fixed = destination / "input.json"
    payload = destination / "payload"
    if any(destination.iterdir()):
        require(read_resource(fixed, 64 * 1024) == json_bytes(spec), "重新运行时资源来源或固定输入不同")
        read_prepared_resource(destination)
        return destination
    with fixed.open("xb") as output:
        output.write(json_bytes(spec))
        output.flush()
        os.fsync(output.fileno())
    expected = dict(spec)
    if spec["kind"] == "ca" and "storedSha256" not in spec:
        checksum_url = spec.get("checksumUrl", spec["sourceUrl"] + ".sha256")
        checksum = fetch(checksum_url, limit=4096).decode("ascii").strip()
        match = re.fullmatch(r"(?:SHA256\([^\r\n]+\)\s*=\s*)?([0-9a-fA-F]{64})(?:[ \t]+\*?[^\r\n]+)?", checksum)
        require(match is not None, "CA 官方校验文件格式无效")
        checksum = match[1].lower()
        require(spec.get("storedSha256", checksum) == checksum, "CA 官方校验文件中的 SHA-256 与预期值不一致")
        expected["storedSha256"] = checksum
    limit = spec.get("storedBytes", FETCH_LIMIT)
    partial = destination / "payload.part"
    if source is None:
        fetch(spec["sourceUrl"], limit=limit, destination=partial)
    else:
        # 将source指定的原始文件复制为payload.part，再校验格式、大小和摘要。
        with partial.open("xb") as output:
            output.write(read_resource(source, limit))
            output.flush()
            os.fsync(output.fileno())
    resolved = validate_resource(read_resource(partial, limit), expected)
    os.replace(partial, payload)
    receipt = {"format": "clash-pseudo-prepared-resource", "version": 1,
               "inputSha256": hashlib.sha256(json_bytes(spec)).hexdigest(), "resource": resolved}
    with (destination / "receipt.json.part").open("xb") as output:
        output.write(json_bytes(receipt))
        output.flush()
        os.fsync(output.fileno())
    os.replace(destination / "receipt.json.part", destination / "receipt.json")
    sync_directory(destination)
    return destination


def prepare_resources(specs, destination, sources=None):
    specs = [resource_spec(spec) for spec in specs]
    require(len(specs) == len(RESOURCE_ASSETS) and {spec["kind"] for spec in specs} == set(RESOURCE_ASSETS),
            "交付资源必须完整且没有重复种类")
    require(all(sum(spec.get(prefix + "Bytes", 0) for spec in specs) <= RESOURCE_TOTAL_LIMIT
                for prefix in ("stored", "installed")), "资源总量超过上限")
    paths = [prepare_resource(spec, Path(destination) / spec["kind"], (sources or {}).get(spec["kind"]))
             for spec in specs]
    resolved = [read_prepared_resource(path)[0] for path in paths]
    require(all(sum(spec[prefix + "Bytes"] for spec in resolved) <= RESOURCE_TOTAL_LIMIT
                for prefix in ("stored", "installed")), "资源总量超过上限")
    return paths


def prepared_resources(directory):
    return [Path(directory) / kind for kind in RESOURCE_ASSETS]


def resource_changes(root, prepared, *, delivery_version=None, source_metadata=None, toolchains=None, dependencies=None):
    """生成本次 release 的固定来源记录；payload 与实际 manifest 由构建入口生成。"""
    specs = prepared_specs(prepared)
    legal = load_tool("dependency_legal", ROOT / "tool/dependencies/legal.py")
    legal.resource_materials(root, specs)
    record = {"format": "clash-pseudo-release-resources", "version": 1,
              "application": delivery_version or application_version(root),
              "resources": specs,
              "licenses": {name: {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                           for name in RESOURCE_INPUTS if name != RESOURCE_RECORD
                           for data in [read_resource(Path(root) / name, artifacts.TEXT_LIMIT)]}}
    if source_metadata is not None:
        resource_source_entries(source_metadata)
        record["sourceInputs"] = source_metadata
    if toolchains is not None:
        record["toolchains"] = toolchains
    if dependencies is not None:
        record["dependencies"] = dependencies
    return {RESOURCE_RECORD: json_bytes(record)}


def publish_resources(root, before, prepared, *, application_delivery=False, delivery_version=None):
    """在应用交付过程中统一写入资源；application_delivery须为True。"""
    require(application_delivery, "资源刷新只随新应用交付，不单独准备 APK")
    after = dict(before)
    after.update(resource_changes(root, prepared, delivery_version=delivery_version))
    return publish_changes(root, before, after)


GEOIP_DATA_PROCESSING = (
    "V2Fly geoip 官方构建使用同一仓库 release 数据提交中的 text/*.txt 及转换器 config.json，"
    "合并 DB-IP Lite Country MMDB、内置 private 与 test 列表后生成所分发的 GeoIP.dat。")
CA_INDEX = "https://curl.se/docs/caextract.html"
GEO_SOURCE_REPOSITORIES = {"geoip": "geoip", "geosite": "domain-list-community"}
GEO_LICENSE_FILES = {"geoip": "CC-BY-SA-4.0.txt", "geosite": "GeoSite-MIT.txt"}
DBIP_PAGES = {"mmdb": "https://db-ip.com/db/download/ip-to-country-lite",
              "asn": "https://db-ip.com/db/download/ip-to-asn-lite"}


def _resolver(fetch):
    return fetch if fetch is not None else globals()["fetch"]


def _json_document(data, label):
    value = json.loads(data, object_pairs_hook=unique_object)
    require(isinstance(value, dict), label + "不是 JSON 对象")
    return value


def _github_json(url, label, fetch):
    return _json_document(fetch(url, limit=4 * 1024 * 1024), label)


def _tag_commit(repository, version, fetch):
    """release tag 指向的提交；附注 tag 继续解析到其提交对象。"""
    ref = _github_json(f"https://api.github.com/repos/v2fly/{repository}/git/ref/tags/{version}", "V2Fly tag", fetch)
    target = ref.get("object")
    for _ in range(2):
        require(isinstance(target, dict) and isinstance(target.get("sha"), str), "V2Fly tag 对象无效")
        if target.get("type") == "commit":
            require(re.fullmatch(r"[0-9a-f]{40}", target["sha"]), "V2Fly tag 提交无效")
            return target["sha"]
        require(target.get("type") == "tag" and isinstance(target.get("url"), str), "V2Fly tag 类型无效")
        target = _github_json(target["url"], "V2Fly tag 对象", fetch).get("object")
    raise ValueError("V2Fly tag 嵌套层数无效")


def _geoip_data_commit(version, published_at, fetch):
    """geoip 构建把当次输出提交到 release 分支，提交说明为 release 版本。"""
    query = urllib.parse.urlencode({"sha": "release", "until": published_at, "per_page": 5})
    rows = fetch("https://api.github.com/repos/v2fly/geoip/commits?" + query, limit=4 * 1024 * 1024)
    rows = json.loads(rows, object_pairs_hook=unique_object)
    require(isinstance(rows, list), "geoip release 分支提交列表无效")
    for row in rows:
        message = row.get("commit", {}).get("message", "").splitlines()
        commit = row.get("sha")
        if message and message[0] == version:
            require(isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{40}", commit), "geoip 数据提交无效")
            tree = _github_json(f"https://api.github.com/repos/v2fly/geoip/git/trees/{commit}?recursive=1",
                                "geoip 数据树", fetch)
        else:
            continue
        entries = tree.get("tree")
        require(not tree.get("truncated") and isinstance(entries, list), "geoip 数据树不完整")
        texts = [entry for entry in entries
                 if isinstance(entry, dict) and entry.get("type") == "blob"
                 and re.fullmatch(r"text/[^/]+\.txt", str(entry.get("path", "")))]
        require(texts, "geoip release 数据提交缺少 text/*.txt 输入")
        return commit
    raise ValueError("geoip release 缺少与版本同名的构建数据提交")


def official_resource_spec(kind, root=ROOT, *, fetch=None):
    """从官方发布信息生成资源记录，保留官方提供的版本、来源和摘要。"""
    require(kind in RESOURCE_ASSETS, "未知资源种类")
    fetch = _resolver(fetch)
    if kind == "ca":
        page = fetch(CA_INDEX, limit=FETCH_LIMIT).decode("utf-8", errors="replace")
        versions = set(re.findall(
            r"cacert-(\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01]))\.pem(?![0-9A-Za-z.])", page))
        require(versions, "curl 官方目录没有带日期的 PEM 快照")
        version = max(versions)
        url = "https://curl.se/ca/cacert-" + version + ".pem"
        checksum = fetch(url + ".sha256", limit=4096).decode("ascii").strip()
        match = re.fullmatch(r"(?:SHA256\([^\r\n]+\)\s*=\s*)?([0-9a-fA-F]{64})(?:[ \t]+\*?[^\r\n]+)?", checksum)
        require(match is not None, "CA 官方校验文件格式无效")
        return resource_spec({"kind": "ca", "version": version, "sourceUrl": url,
                              "checksumUrl": url + ".sha256", "storedSha256": match[1].lower()})
    if kind in ("geoip", "geosite"):
        repository = GEO_SOURCE_REPOSITORIES[kind]
        asset = "geoip.dat" if kind == "geoip" else "dlc.dat"
        release = _github_json("https://api.github.com/repos/v2fly/" + repository + "/releases/latest",
                               "V2Fly release", fetch)
        version = release.get("tag_name")
        require(not release.get("draft") and not release.get("prerelease")
                and isinstance(version, str) and re.fullmatch(r"[0-9]{8,14}", version),
                "V2Fly 上游未返回带有固定版本号的正式发布")
        assets = [entry for entry in release.get("assets", [])
                  if isinstance(entry, dict) and entry.get("name") == asset]
        require(len(assets) == 1, "V2Fly 发布附件缺失或同名附件重复：" + asset)
        item = assets[0]
        size, digest = item.get("size"), item.get("digest")
        match = re.fullmatch(r"sha256:([0-9a-f]{64})", digest if isinstance(digest, str) else "")
        require(type(size) is int and 0 < size <= FETCH_LIMIT and match is not None,
                "V2Fly 发布附件的大小或摘要无效")
        url = f"https://github.com/v2fly/{repository}/releases/download/{version}/{asset}"
        require(item.get("browser_download_url") == url, "V2Fly 发布附件的下载地址与指定版本不一致")
        commit = _tag_commit(repository, version, fetch)
        name = GEO_LICENSE_FILES[kind]
        license_data = fetch(f"https://raw.githubusercontent.com/v2fly/{repository}/{commit}/LICENSE",
                             limit=artifacts.TEXT_LIMIT)
        original = read_resource(root / "third_party/data/geodata" / name, artifacts.TEXT_LIMIT)
        require(license_data == original, "指定源码提交中的资源许可内容已变化，请完成技术复核：" + name)
        spec = {"kind": kind, "version": version, "sourceUrl": url, "sourceCommit": commit,
                "licenseSha256": hashlib.sha256(original).hexdigest(),
                "storedBytes": size, "storedSha256": match[1]}
        if kind == "geoip":
            published = release.get("published_at")
            require(isinstance(published, str) and re.fullmatch(
                r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", published),
                "V2Fly release 发布时间缺失")
            data_commit = _geoip_data_commit(version, published, fetch)
            require(data_commit != commit, "GeoIP 补充数据提交与转换器提交相同")
            spec["sourceInputs"] = [{"sourceCommit": data_commit,
                                     "description": f"release {version} 构建提交中的 text/*.txt 补充输入"}]
        return resource_spec(spec)
    name = "country" if kind == "mmdb" else "asn"
    page = fetch(DBIP_PAGES[kind], limit=FETCH_LIMIT).decode("utf-8", errors="replace")
    versions = set(re.findall(
        r"https://download\.db-ip\.com/free/dbip-" + name + r"-lite-(\d{4}-(?:0[1-9]|1[0-2]))\.mmdb\.gz", page))
    require(versions, "DB-IP 官方下载页没有有效的年月版本：" + name)
    version = max(versions)
    return resource_spec({"kind": kind, "version": version,
                          "sourceUrl": f"https://download.db-ip.com/free/dbip-{name}-lite-{version}.mmdb.gz",
                          "sourcePage": DBIP_PAGES[kind]})


def official_resource_specs(root=ROOT, *, fetch=None):
    """查询本次 release 的五项官方来源。"""
    return [official_resource_spec(kind, root, fetch=fetch) for kind in RESOURCE_ASSETS]


def prepare_official_resources(destination, *, root=ROOT, fetch=None):
    """先查询官方来源；有官方摘要时复核缓存，其余内容在本次更新中重新下载。"""
    fetch = _resolver(fetch)
    specs = official_resource_specs(root, fetch=fetch)
    destination = Path(destination).absolute()
    require(destination.resolve() == destination and not destination.is_relative_to(ROOT),
            "release 更新的资源目录必须在仓库外且不能包含符号链接")
    destination.mkdir(parents=True, exist_ok=True)
    entries = {entry.name for entry in destination.iterdir()}
    require(entries <= set(RESOURCE_ASSETS), "资源准备根目录包含未知条目：" + repr(sorted(entries - set(RESOURCE_ASSETS))))
    cached_resources = {}
    for kind in RESOURCE_ASSETS:
        directory = destination / kind
        require(not directory.is_symlink() and (not directory.exists() or directory.is_dir()), "资源缓存目录无效：" + kind)
        if directory.exists() and any(directory.iterdir()):
            cached_resources[kind] = read_prepared_resource(directory)[0]
    paths = []
    for spec in specs:
        directory = destination / spec["kind"]
        cached = cached_resources.get(spec["kind"])
        if cached is not None:
            if "storedSha256" in spec and all(cached.get(key) == value for key, value in spec.items()):
                paths.append(directory)
                continue
        with tempfile.TemporaryDirectory(prefix="clash-resource-update-") as temporary:
            fresh = prepare_resource(spec, Path(temporary) / spec["kind"], fetch=fetch)
            if directory.exists():
                os.replace(directory, Path(temporary) / "previous")
            shutil.move(str(fresh), directory)
        paths.append(directory)
    resolved = prepared_specs(paths)
    require(all(sum(spec[prefix + "Bytes"] for spec in resolved.values()) <= RESOURCE_TOTAL_LIMIT
                for prefix in ("stored", "installed")), "资源总量超过上限")
    return paths


def prepared_specs(prepared):
    specs = {}
    for directory in prepared:
        directory = Path(directory)
        require(directory.is_dir() and not directory.is_symlink(), "准备资源目录无效：" + str(directory))
        spec, _ = read_prepared_resource(directory)
        require(directory.name == spec["kind"], "资源准备目录名与 kind 指定的种类不一致：" + str(directory))
        require(spec["kind"] not in specs, "准备资源包含重复种类")
        specs[spec["kind"]] = spec
    require(set(specs) == set(RESOURCE_ASSETS), "交付资源不完整")
    return specs


def _source_expected(kind, commit):
    repository = GEO_SOURCE_REPOSITORIES[kind]
    url = f"https://github.com/v2fly/{repository}/archive/{commit}.tar.gz"
    return url, f"{repository}-{commit}.tar.gz"


def _source_inputs(spec, inputs):
    """优先使用 inputs 指定的源码输入，其次使用 spec.sourceInputs；两者都未提供时返回错误。"""
    require(spec["kind"] == "geoip", "补充输入只用于 GeoIP")
    if inputs is None:
        inputs = [{"sourceCommit": item["sourceCommit"], "description": item["description"]}
                  for item in spec.get("sourceInputs", [])]
    require(isinstance(inputs, list), "GeoIP 补充输入必须是数组")
    result, names, commits = [], set(), set()
    for item in inputs:
        require(isinstance(item, dict) and isinstance(item.get("description"), str) and item["description"].strip(),
                "GeoIP 补充输入必须是带说明的对象")
        commit, description = item.get("sourceCommit"), item["description"]
        require(isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{40}", commit), "GeoIP 补充输入 commit 无效")
        url, name = _source_expected("geoip", commit)
        require(name not in names and commit not in commits, "重复的 GeoIP 补充输入")
        names.add(name)
        commits.add(commit)
        result.append({"sourceCommit": commit, "sourceUrl": url, "file": name, "description": description})
    require(result, "GeoIP 补充输入缺失")
    return result, commits


def _download_source(url, path, fetch):
    result = fetch(url, limit=FETCH_LIMIT, destination=path)
    require(isinstance(result, dict) and type(result.get("bytes")) is int
            and 0 < result["bytes"] <= FETCH_LIMIT
            and isinstance(result.get("sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", result["sha256"]),
            "资源对应源码下载结果无效")
    return result


def prepare_resource_sources(specs, destination, *, inputs=None, processing=GEOIP_DATA_PROCESSING, fetch=None):
    """按固定提交准备资源源码归档；已有resource-sources.json时，核对本地归档及其来源。"""
    fetch = _resolver(fetch)
    require(isinstance(specs, dict) and set(GEO_SOURCE_REPOSITORIES) <= set(specs), "缺少 GeoIP／GeoSite 固定输入")
    fixed = {kind: resource_spec(specs[kind]) for kind in GEO_SOURCE_REPOSITORIES}
    for kind, spec in fixed.items():
        require(spec["kind"] == kind, "资源种类与固定输入不同：" + kind)
    require(isinstance(processing, str) and processing.strip(), "GeoIP 处理说明缺失")
    geoip_inputs, input_commits = _source_inputs(fixed["geoip"], inputs)
    require(fixed["geoip"]["sourceCommit"] not in input_commits, "GeoIP 补充输入与转换器 commit 相同")
    destination = Path(destination).absolute()
    require(destination.resolve() == destination and not destination.is_relative_to(ROOT),
            "资源对应源码使用仓库外独立目录，且不能包含符号链接")
    manifest = destination / "resource-sources.json"
    if destination.exists():
        entries = {entry.name for entry in destination.iterdir()}
        if manifest.exists():
            prepared = read_resource_sources(destination)
            recorded = {"resource-sources.json"} | {source["file"] for row in prepared["sources"]
                                                    for source in [row, *row.get("inputs", [])]}
            require(entries == recorded, "资源对应源码目录包含未登记文件：" + repr(sorted(entries - recorded)))
            for row in prepared["sources"]:
                kind = row["kind"]
                url = _source_expected(kind, fixed[kind]["sourceCommit"])[0]
                require(row["sourceCommit"] == fixed[kind]["sourceCommit"] and row["sourceUrl"] == url,
                        "已准备资源源码与当前固定输入不同：" + kind)
            expected = {(item["sourceCommit"], item["sourceUrl"]) for item in geoip_inputs}
            current = next(row for row in prepared["sources"] if row["kind"] == "geoip")
            actual = {(item["sourceCommit"], item["sourceUrl"]) for item in current["inputs"]}
            require(expected == actual, "已准备 GeoIP 补充输入与本次不同")
            return manifest
        require(not entries, "资源对应源码目录已有未登记文件，请使用新空目录：" + repr(sorted(entries)))
    destination.mkdir(parents=True, exist_ok=True)
    rows, total = [], 0
    for kind in ("geoip", "geosite"):
        commit = fixed[kind]["sourceCommit"]
        url, name = _source_expected(kind, commit)
        result = _download_source(url, destination / name, fetch)
        total += result["bytes"]
        require(total <= RESOURCE_TOTAL_LIMIT, "资源对应源码总量超过上限")
        row = {"kind": kind, "sourceCommit": commit, "sourceUrl": url, "file": name,
               "bytes": result["bytes"], "sha256": result["sha256"]}
        if kind == "geoip":
            entries = []
            for item in geoip_inputs:
                measured = _download_source(item["sourceUrl"], destination / item["file"], fetch)
                total += measured["bytes"]
                require(total <= RESOURCE_TOTAL_LIMIT, "资源对应源码总量超过上限")
                entries.append(dict(item, bytes=measured["bytes"], sha256=measured["sha256"]))
            row.update(inputs=entries, processing=processing)
        else:
            row["inputs"] = []
        rows.append(row)
    metadata = {"format": "clash-pseudo-resource-sources", "version": 1, "sources": rows}
    partial = destination / "resource-sources.json.part"
    with partial.open("xb") as output:
        output.write(json_bytes(metadata))
        output.flush()
        os.fsync(output.fileno())
    os.replace(partial, manifest)
    sync_directory(destination)
    read_resource_sources(destination)
    return manifest


def resource_source_entries(metadata):
    """校验清单格式、资源种类、固定来源及大小上限，返回登记的(kind, source)。"""
    require(isinstance(metadata, dict) and metadata.get("format") == "clash-pseudo-resource-sources"
            and type(metadata.get("version")) is int and metadata["version"] == 1,
            "资源对应源码清单格式无效")
    rows, kinds, total, result, filenames = metadata.get("sources"), set(), 0, [], set()
    require(isinstance(rows, list) and len(rows) == len(GEO_SOURCE_REPOSITORIES)
            and all(isinstance(row, dict) for row in rows), "资源对应源码清单条目无效")
    for row in rows:
        kind = row.get("kind")
        require(isinstance(kind, str) and kind in GEO_SOURCE_REPOSITORIES and kind not in kinds,
                "资源对应源码种类无效：" + repr(kind))
        kinds.add(kind)
        entries = row.get("inputs", [])
        require(isinstance(entries, list) and all(isinstance(item, dict) for item in entries),
                "资源补充输入清单无效：" + kind)
        if kind == "geoip" or entries:
            require(entries and all(isinstance(item.get("description"), str) and item["description"].strip()
                                    for item in entries)
                    and isinstance(row.get("processing"), str) and row["processing"].strip(),
                    "缺少资源可编辑补充输入或处理说明：" + kind)
        commits = set()
        for source in [row, *entries]:
            commit, name = source.get("sourceCommit"), source.get("file")
            require(isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{40}", commit),
                    "资源源码提交无效：" + kind)
            require(source.get("sourceUrl") == _source_expected(kind, commit)[0],
                    "资源源码必须来自固定上游提交：" + kind)
            require(isinstance(name, str) and name not in ("", ".", "..", "resource-sources.json")
                    and "/" not in name and "\\" not in name and "\0" not in name,
                    "资源对应源码文件路径无效")
            require(name not in filenames and commit not in commits, "重复资源源码文件或提交：" + kind)
            filenames.add(name)
            commits.add(commit)
            size = source.get("bytes")
            require(type(size) is int and 0 < size <= FETCH_LIMIT, "资源对应源码大小无效：" + kind)
            require(isinstance(source.get("sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", source["sha256"]),
                    "资源对应源码摘要无效：" + kind)
            total += size
            require(total <= RESOURCE_TOTAL_LIMIT, "资源对应源码总量超过上限")
            result.append((kind, source))
    return result


def read_release_resources(root, record_path=None):
    """读取 release 保存的来源和摘要，不查询官方 latest。"""
    root = Path(root).resolve()
    path = Path(record_path) if record_path else root / RESOURCE_RECORD
    record = json.loads(read_resource(path, 1024 * 1024), object_pairs_hook=unique_object)
    require(isinstance(record, dict) and record.get("format") == "clash-pseudo-release-resources"
            and type(record.get("version")) is int and record["version"] == 1,
            "release 资源来源记录格式无效")
    specs = record.get("resources")
    require(isinstance(specs, dict) and set(specs) == set(RESOURCE_ASSETS), "release 资源记录必须包含五项资源")
    for kind, spec in specs.items():
        require(resource_spec(spec) == spec and spec["kind"] == kind
                and all(key in spec for key in ("storedBytes", "storedSha256", "installedBytes", "installedSha256")),
                "release 资源缺少固定大小或摘要：" + kind)
        if kind == "ca":
            require("certificateRoots" in spec, "release 资源缺少 CA 证书数量")
    require(all(sum(spec[prefix + "Bytes"] for spec in specs.values()) <= RESOURCE_TOTAL_LIMIT
                for prefix in ("stored", "installed")), "资源总量超过上限")
    licenses = record.get("licenses")
    require(isinstance(licenses, dict) and set(licenses) == set(RESOURCE_INPUTS) - {RESOURCE_RECORD},
            "release 资源许可记录不完整")
    for name, measured in licenses.items():
        data = read_resource(root / name, artifacts.TEXT_LIMIT)
        require(measured == {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()},
                "release 资源许可正文发生变化：" + name)
    if "sourceInputs" in record:
        resource_source_entries(record["sourceInputs"])
        for source in record["sourceInputs"]["sources"]:
            spec = specs[source["kind"]]
            require(source["sourceCommit"] == spec["sourceCommit"],
                    "资源源码提交与 release 记录不同：" + source["kind"])
            if "sourceInputs" in spec:
                require({row["sourceCommit"] for row in source.get("inputs", [])}
                        == {row["sourceCommit"] for row in spec["sourceInputs"]},
                        "GeoIP 数据源码与 release 记录不同")
    return record


def bundled_materials(root, record):
    legal = load_tool("dependency_legal", ROOT / "tool/dependencies/legal.py")
    original = legal.resource_materials(Path(root), record["resources"])
    result = {}
    for name, data in original.items():
        if name == ASSET_ROOT + "geodata/manifest.json":
            result["assets/geodata/manifest.json"] = data
        elif name == "third_party/data/certificates/manifest.json":
            result["certificates.json"] = data
        elif name.startswith("third_party/data/"):
            relative = name.removeprefix("third_party/data/")
            result["legal/" + relative] = data
            if relative.startswith("geodata/"):
                result["assets/geodata/NOTICE.txt"] = data
    for name in record["licenses"]:
        relative = name.removeprefix("third_party/data/")
        data = read_resource(Path(root) / name, artifacts.TEXT_LIMIT)
        result["legal/" + relative] = data
        if relative.startswith("geodata/"):
            result["assets/geodata/licenses/" + Path(name).name] = data
    contract = load_tool("application_contract_generator", ROOT / "tool/contracts/generate.py")
    result["kotlin/io/github/monadboxlab/clashpseudo/nativecore/BundledAssetContract.kt"] = contract.asset_metadata(
        json.loads(result["assets/geodata/manifest.json"], object_pairs_hook=unique_object),
        json.loads(result["certificates.json"], object_pairs_hook=unique_object)).encode()
    result["resources.json"] = json_bytes(record)
    return result


def prepare_bundled_assets(root, *, prepared=None, payloads=None, output=None, fetch=None, offline=False):
    """普通构建只读取固定记录；缺失 payload 时按记录的 URL 和摘要补齐。"""
    root = Path(root).resolve()
    record = read_release_resources(root)
    fingerprint = hashlib.sha256(json_bytes(record)).hexdigest()
    output = Path(output).absolute() if output else root / GENERATED_BUNDLED
    require(output.resolve() == output and output.is_relative_to(root / "build/generated"),
            "bundled assets 必须写入 build/generated 且不能包含符号链接")
    output.parent.mkdir(parents=True, exist_ok=True)
    import fcntl
    with (output.parent / ".bundled.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        cache = root / "build/generated/resource-cache" / fingerprint
        data = bundled_materials(root, record)
        for kind, spec in record["resources"].items():
            if prepared is not None:
                resolved, payload = read_prepared_resource(Path(prepared) / kind)
                require(resolved == spec, "已准备资源与 release 记录不同：" + kind)
            else:
                directory = cache / kind
                if not directory.exists():
                    source = (payloads or {}).get(kind)
                    require(not offline or source is not None, "离线构建缺少固定资源：" + kind)
                    prepare_resource(spec, directory, source=source, fetch=fetch)
                resolved, payload = read_prepared_resource(directory)
                require(resolved == spec, "资源缓存与 release 记录不同：" + kind)
            data["assets/" + RESOURCE_ASSETS[kind]] = payload
        # 输出先写入新目录；任何校验失败都不替换上一份完整输出。
        with tempfile.TemporaryDirectory(prefix=".bundled-", dir=output.parent) as temporary:
            staging = Path(temporary) / "complete"
            staging.mkdir()
            for name, value in data.items():
                target = staging / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(value)
            require(read_release_resources(root) == record, "生成期间 release 资源记录发生变化")
            if output.exists():
                os.replace(output, Path(temporary) / "previous")
            os.replace(staging, output)
    return output


def verify_bundled_assets(root, record=None):
    """按同次 release 记录核对 payload、实际 manifest、常量和许可材料。"""
    root = Path(root).resolve()
    record = record if record is not None else read_release_resources(root)
    output = root / GENERATED_BUNDLED
    expected = bundled_materials(root, record)
    for kind, spec in record["resources"].items():
        name = "assets/" + RESOURCE_ASSETS[kind]
        payload = read_resource(output / name, spec["storedBytes"])
        require(validate_resource(payload, spec) == spec, "generated payload 与 release 输入不同：" + kind)
        expected[name] = payload
    for name, data in expected.items():
        require(read_resource(output / name, max(1, len(data))) == data,
                "generated 材料与 release 输入不同：" + name)
    files = set()
    for path in output.rglob("*"):
        require(not path.is_symlink(), "generated 材料不能包含符号链接")
        if path.is_file():
            files.add(path.relative_to(output).as_posix())
    require(files == set(expected), "generated 材料缺失或包含额外文件")
    return record


def check_resource_source_selection(root, metadata):
    """比较可编辑资源源码与本次 release 固定记录中的提交。"""
    resource_source_entries(metadata)
    record = read_release_resources(root)
    for row in metadata["sources"]:
        require(row["sourceCommit"] == record["resources"][row["kind"]]["sourceCommit"],
                "资源源码提交与 release 记录不同：" + row["kind"])
    if "sourceInputs" in record:
        require(metadata == record["sourceInputs"], "资源源码来源、大小或摘要与 release 记录不同")


def read_resource_sources(directory):
    """读取resource-sources.json，逐个校验同目录归档的大小和SHA-256。"""
    directory = Path(directory).absolute()
    require(directory.resolve() == directory, "资源对应源码目录不能包含符号链接")
    manifest = directory / "resource-sources.json"
    require(not manifest.is_symlink(), "资源对应源码清单不能是符号链接")
    metadata = json.loads(read_resource(manifest, 128 * 1024), object_pairs_hook=unique_object)
    for kind, source in resource_source_entries(metadata):
        path = directory / source["file"]
        require(not path.is_symlink() and path.is_file(), "资源对应源码要求普通文件：" + kind)
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "资源对应源码要求普通文件：" + kind)
            require(os.fstat(stream.fileno()).st_size == source["bytes"], "资源对应源码大小不同：" + kind)
            require(hashlib.file_digest(stream, "sha256").hexdigest() == source["sha256"],
                    "资源对应源码摘要不同：" + kind)
    return metadata


def delivery_resources(root, destination, *, prepare, fetch=None):
    """为发布准备资源和对应源码，或读取已恢复的固定源码归档。"""
    fetch = _resolver(fetch)
    root = Path(root).resolve()
    destination = Path(destination).absolute()
    require(destination.resolve() == destination and not destination.is_relative_to(root),
            "交付资源材料使用仓库外独立目录，且不能包含符号链接")
    prepared = destination / "resources"
    sources = destination / "resource-sources"
    if destination.exists():
        entries = {entry.name for entry in destination.iterdir()}
        require(entries <= {"resources", "resource-sources", "payloads"},
                "交付资源目录包含未知条目：" + repr(sorted(entries - {"resources", "resource-sources", "payloads"})))
    if not prepare:
        require(not prepared.exists(), "当前交付没有资源刷新时不能准备新资源目录")
        manifest = sources / "resource-sources.json"
        require(manifest.is_file(), "当前交付缺少固定资源源码清单：" + str(manifest))
        metadata = read_resource_sources(sources)
        check_resource_source_selection(root, metadata)
        return {"prepared": None, "sources": manifest}
    paths = prepare_official_resources(prepared, root=root, fetch=fetch)
    specs = prepared_specs(paths)
    manifest = prepare_resource_sources(specs, sources, fetch=fetch)
    return {"prepared": prepared, "sources": manifest}


class Updater:
    def __init__(self, root, go="go", flutter="flutter"):
        self.root = root
        self.go = go
        self.flutter = flutter
        self.native = root / "native/mihomo"
        self.pub_previous = {}
        self.pub_direct = {}
        self.resolution = {"go": {}, "pub": {}, "android": {}}

    def go_run(self, *arguments, env=None):
        return run([self.go, *arguments], self.native, env)

    def graph(self, output):
        output.write_text(self.go_run("list", "-mod=readonly", "-m", "-json", "all"), encoding="utf-8")
        return artifacts.go_modules(output)

    def go_updates(self, names, release=None):
        if not names:
            return {}
        manifest = json.loads(self.go_run("mod", "edit", "-json"))
        current = {entry["Path"]: entry["Version"] for entry in manifest["Require"]}
        require(set(names) <= current.keys(), "只能选择现有 Go 依赖：" + repr(sorted(set(names) - current.keys())))
        updates = {}
        for name in names:
            if name == MIHOMO:
                target = release or mihomo_release()
                require(stable_version(target) >= stable_version(current[name]), "内核更新目标早于当前版本")
            else:
                module = json.loads(self.go_run("list", "-mod=readonly", "-m", "-u", "-json", name))
                target = module.get("Update", module)["Version"]
            self.resolution["go"][name] = {"previous": current[name], "selected": target}
            if target != current[name]:
                updates[name] = target
        return updates

    def update_go(self, updates):
        before = json.loads(self.go_run("mod", "edit", "-json"))
        if updates:
            self.go_run("get", *[name + "@" + version for name, version in sorted(updates.items())])
        self.go_run("mod", "tidy")
        after = json.loads(self.go_run("mod", "edit", "-json"))
        require(before.get("Replace") == after.get("Replace"),
                "Go replace 发生变化；保留原 replace，完成所选依赖的来源与许可复核")
        new = {row["Path"]: row["Version"] for row in after["Require"]}
        for name in ("github.com/rasky/go-lzo", "github.com/metacubex/chacha"):
            require(name in new, "许可版本约束丢失：" + name)
        require(all(new.get(name) == version for name, version in updates.items()),
                "实际 Go 解析与更新目标不同")

    def pub_updates(self, names):
        if not names:
            return {}
        run([self.flutter, "pub", "get"], self.root)
        result = json.loads(run([self.flutter, "pub", "outdated", "--json", "--show-all"], self.root))
        packages = {row["package"]: row for row in result["packages"]}
        resolved = json.loads(run([self.flutter, "pub", "deps", "--json"], self.root))
        hosted = {row["name"] for row in resolved["packages"] if row.get("source") == "hosted"}
        self.pub_previous = {row["name"]: row["version"] for row in resolved["packages"] if row["name"] in hosted}
        self.pub_direct = {row["name"]: row["version"] for row in resolved["packages"]
                           if row["name"] in hosted and row.get("kind") in ("direct", "dev")}
        updates = {}
        for name in names:
            row = packages.get(name)
            require(row and row.get("kind") in ("direct", "dev") and name in hosted,
                    "只能选择现有 hosted 直接依赖：" + name)
            version = (row.get("resolvable") or {}).get("version")
            require(version and stable_version(version), "当前 SDK 下缺少可解析正式版本：" + name)
            self.resolution["pub"][name] = {"current": row.get("current"), "latest": row.get("latest"),
                                             "selected": version, "kind": row["kind"]}
            if version != (row.get("current") or {}).get("version"):
                updates[name] = (version, row["kind"])
        return updates

    def update_pub(self, updates):
        if not updates:
            return
        descriptors = [("dev:" if kind == "dev" else "") + name + "@" + version
                       for name, (version, kind) in sorted(updates.items())]
        run([self.flutter, "pub", "add", "--no-example", *descriptors], self.root)
        if self.pub_direct:
            resolved = json.loads(run([self.flutter, "pub", "deps", "--json"], self.root))
            versions = {row["name"]: row["version"] for row in resolved["packages"]}
            require(all(versions.get(name) == version for name, (version, _) in updates.items()),
                    "实际 Pub 解析与更新目标不同")
            run([self.flutter, "pub", "get", "--enforce-lockfile"], self.root)

    def android_updates(self, names):
        if not names:
            return {}
        path = self.root / "android/app/build.gradle.kts"
        text = path.read_text(encoding="utf-8")
        declared = {m["name"]: m["version"] for m in MAVEN_DECLARATION.finditer(text)}
        require(set(names) <= declared.keys(), "只能选择现有 Android 库：" + repr(sorted(set(names) - declared.keys())))
        updates = {}
        prepared = False
        try:
            for name in names:
                group, artifact = name.split(":")
                versions = []
                for repository in MAVEN:
                    url = f"{repository}/{group.replace('.', '/')}/{artifact}/maven-metadata.xml"
                    try:
                        data = fetch(url)
                    except urllib.error.HTTPError as error:
                        if error.code == 404:
                            continue
                        raise
                    versions.extend(row.text for row in ET.fromstring(data).findall("./versioning/versions/version")
                                    if row.text and stable_version(row.text))
                    if versions:
                        break
                require(versions, "缺少 Maven 正式版本：" + name)
                candidates = sorted({v for v in versions if stable_version(v) > stable_version(declared[name])},
                                    key=stable_version, reverse=True)
                decision = {"previous": declared[name], "latest": max(versions, key=stable_version),
                            "selected": declared[name], "excluded": []}
                self.resolution["android"][name] = decision
                for candidate in candidates:
                    if not prepared:
                        run([self.flutter, "pub", "get", "--enforce-lockfile"], self.root)
                        prepared = True
                    self.update_android({name: candidate})
                    try:
                        run([os.environ.get("CLASH_GRADLE", self.root / "android/gradlew"), "-p", self.root / "android", "--console=plain",
                             ":app:checkReleaseAarMetadata", ":app:processReleaseMainManifest",
                             "-x", ":app:buildNativeCore", "-x", ":app:compileFlutterBuildRelease"], self.root)
                    except ValueError as error:
                        if re.search(r"uses-sdk:minSdkVersion|minCompileSdk|requires.*compile.*(?:SDK|API)|"
                                     r"requires libraries and applications.*compile", str(error), re.I | re.S):
                            decision["excluded"].append({"version": candidate, "reason": str(error)})
                            continue
                        raise
                    updates[name] = candidate
                    decision["selected"] = candidate
                    break
                self.update_android({name: updates.get(name, declared[name])})
        finally:
            path.write_text(text, encoding="utf-8")
        return updates

    def update_android(self, updates):
        path = self.root / "android/app/build.gradle.kts"
        text = path.read_text(encoding="utf-8")
        text = MAVEN_DECLARATION.sub(
            lambda m: m["prefix"] + m["name"] + ":" + updates.get(m["name"], m["version"]) + m["suffix"], text)
        path.write_text(text, encoding="utf-8")

    def android_graph(self):
        run([self.flutter, "pub", "get", "--enforce-lockfile"], self.root)
        return run([os.environ.get("CLASH_GRADLE", self.root / "android/gradlew"), "-p", self.root / "android", "--console=plain",
                    ":app:dependencies", "--configuration", "releaseRuntimeClasspath"], self.root)

    def legal(self, temporary):
        return load_tool("dependency_legal", ROOT / "tool/dependencies/legal.py").Legal(
            self, temporary, fetch, run, artifacts)

    def evidence(self, output):
        """生成Go模块图、Android依赖报告和Flutter NOTICES，保存为APK核验输入。"""
        prepare_bundled_assets(self.root)
        output.mkdir()
        self.graph(output / "go-modules.json")
        (output / "android-dependencies.txt").write_text(self.android_graph(), encoding="utf-8")
        assets = output / "flutter-assets"
        run([self.flutter, "build", "bundle", "--release", "--no-pub", "--target-platform=android-arm64",
             "--asset-dir", assets], self.root)
        import gzip
        notices = gzip.decompress((assets / "NOTICES.Z").read_bytes())
        (output / "NOTICES").write_bytes(notices)


def execute(args):
    environment = dict(os.environ)
    try:
        return _execute(args)
    finally:
        os.environ.clear()
        os.environ.update(environment)


def _execute(args):
    root = args.project.resolve()
    resources = getattr(args, "prepared_resources", None)
    require(resources is None or args.apply, "--check 不接受 --prepared-resources")
    before = snapshot(root)
    packager = load_tool("dependency_package_snapshot", ROOT / "tool/artifacts/package_sources.py")
    identity = {"_status": run(["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"], root),
                "files": [packager.file_record(name, path.read_bytes(), bool(path.stat().st_mode & 0o111))
                          for name in packager.working_tree_names(root)
                          for path in [packager.source_file(root, name)] if path is not None]}
    target = getattr(args, "resolved_release", None) or mihomo_release()
    current = re.search(re.escape(MIHOMO) + r"\s+(v[^\s]+)", (root / GO_INPUTS[0]).read_text())[1]
    if not args.apply and not (args.go_module or args.pub or args.android):
        return {"status": "available" if target != current else "unchanged", "version": application_version(root),
                "go": {MIHOMO: target} if target != current else {}, "pub": {}, "android": {}, "files": []}
    with tempfile.TemporaryDirectory(prefix="clash-dependencies-") as temporary:
        base = Path(temporary)
        work = base / "project"
        work.mkdir()
        copy_workspace(root, work)
        require(snapshot(work) == before, "复制期间输入文件发生变化")
        toolchains = None
        go_binary, flutter_binary = args.go, args.flutter
        if args.apply:
            bootstrap = load_tool("dependency_toolchains", ROOT / "tool/dependencies/toolchains.py")
            toolchains = getattr(args, "resolved_toolchains", None) or bootstrap.resolve()
            environment, measured = bootstrap.prepare(toolchains,
                Path(getattr(args, "toolchain_cache", None) or Path.home() / ".cache/clash-pseudo/toolchains"), work)
            bootstrap.freeze_archives(toolchains, measured)
            bootstrap.apply_versions(work, toolchains)
            # 所有 resolver 与 Gradle 调用都在新工具链环境中开始。
            os.environ.update(environment)
            go_binary = str(Path(environment["PATH"].split(os.pathsep)[1]) / "go")
            flutter_binary = str(Path(environment["PATH"].split(os.pathsep)[0]) / "flutter")
        updater = Updater(work, go_binary, flutter_binary)
        go_names = list(args.go_module)
        pub_names = list(args.pub)
        android_names = list(args.android)
        if args.apply:
            manifest = json.loads(updater.go_run("mod", "edit", "-json"))
            go_names = go_names or [row["Path"] for row in manifest["Require"] if not row.get("Indirect")]
            # SDK 与 path 依赖不进入 hosted 更新列表，re_editor 的本地适配保持原来源。
            sections = re.findall(r"(?m)^(?:dev_)?dependencies:\s*\n((?:(?:[ \t]+[^\n]*|)[\n])*)",
                                  (work / "pubspec.yaml").read_text(encoding="utf-8"))
            pub_names = pub_names or re.findall(r"(?m)^  ([A-Za-z0-9_]+):[^\n]*[0-9][^\n]*$", "\n".join(sections))
            android_names = android_names or sorted({m["name"] for m in MAVEN_DECLARATION.finditer(
                (work / "android/app/build.gradle.kts").read_text(encoding="utf-8"))})
        go = updater.go_updates(go_names, target)
        pub = updater.pub_updates(pub_names)
        android = updater.android_updates(android_names)
        report = {"go": go, "pub": {name: value[0] for name, value in pub.items()}, "android": android}
        if args.apply:
            updater.update_go(go)
            updater.update_pub(pub)
            if android:
                updater.update_android(android)
            legal = updater.legal(base)
            legal.go_notices()
            legal.pub_licenses()
            legal.android_notices()
            version = application_version(work)
            if not args.reuse_version:
                text, version = bump_version((work / "pubspec.yaml").read_text(encoding="utf-8"), args.bump)
                (work / "pubspec.yaml").write_text(text, encoding="utf-8")
            if resources is None:
                delivery = delivery_resources(work, base / "delivery", prepare=True)
                resources, source_manifest = delivery["prepared"], delivery["sources"]
            else:
                source_manifest = Path(resources).parent / "resource-sources/resource-sources.json"
            metadata = read_resource_sources(source_manifest.parent)
            for name, data in resource_changes(work, prepared_resources(resources), delivery_version=version,
                                              source_metadata=metadata, toolchains=toolchains,
                                              dependencies=updater.resolution).items():
                path = input_path(work, name)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            prepare_bundled_assets(work, prepared=resources)
            run([updater.flutter, "pub", "get", "--enforce-lockfile"], work)
            updater.go_run("list", "-mod=readonly", "-m", "all")
            if args.evidence:
                updater.evidence(args.evidence.resolve())
            packager.check_working_tree(root, identity)
            report["files"] = publish_changes(root, before, snapshot(work))
            report["version"] = version
            # 普通构建无需再次下载刚刚完成的固定 payload。
            prepare_bundled_assets(root, prepared=resources)
        else:
            report["files"] = []
            report["version"] = application_version(root)
        report["status"] = "updated" if args.apply else "available" if go or pub or android else "unchanged"
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="查询正式更新，保持工作树文件原状")
    mode.add_argument("--apply", action="store_true", help="更新声明、锁文件、许可与应用版本")
    mode.add_argument("--prepare-build", action="store_true", help="只消费本次 release 固定输入，生成构建资源")
    parser.add_argument("--offline", action="store_true", help="构建准备只读取现有 payload，不下载")
    parser.add_argument("--payload-directory", type=Path, help="源码包中 build-inputs/bundled/assets 的恢复路径")
    mode.add_argument("--prepare-resource", type=Path, help="单项资源的固定来源JSON；资源文件写入仓库外独立目录")
    mode.add_argument("--prepare-resources", type=Path, help="五项资源的固定来源JSON数组；资源文件写入仓库外独立目录")
    mode.add_argument("--prepare-resource-sources", type=Path,
                      help="固定Geo来源的JSON对象，以kind为键；geoip记录须含sourceInputs，输出对应源码归档")
    parser.add_argument("--destination", type=Path, help="资源准备目录；五项资源模式按kind建立子目录")
    parser.add_argument("--resource-source", type=Path, help="单项资源模式使用的原始下载文件路径")
    parser.add_argument("--resource-sources", type=Path, help="五项资源模式的JSON文件，以kind为键、原始文件绝对路径为值")
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--go", default="go", help="现有 Go 可执行文件")
    parser.add_argument("--flutter", default="flutter", help="现有 Flutter 可执行文件")
    parser.add_argument("--toolchain-cache", type=Path, help="官方固定工具链的本地缓存目录")
    parser.add_argument("--go-module", action="append", default=[], help="选择现有 Go 模块，可重复")
    parser.add_argument("--pub", action="append", default=[], help="选择pubspec.yaml中已声明的hosted直接依赖，可重复指定")
    parser.add_argument("--android", action="append", default=[], help="选择现有 group:artifact，可重复")
    parser.add_argument("--evidence", type=Path, help="保存依赖解析结果和许可通知的新目录；与 --apply 一起使用")
    parser.add_argument("--prepared-resources", type=Path,
                        help="已准备的五项资源根目录，包含ca、geoip、geosite、mmdb和asn子目录")
    version = parser.add_mutually_exclusive_group()
    version.add_argument("--bump", choices=("major", "minor", "patch", "stable"), default="patch",
                         help="默认 patch；开发期功能／不兼容调整用 minor，首次稳定发布明确选 stable")
    version.add_argument("--reuse-version", action="store_true", help="沿用本次待发布的已确定版本")
    args = parser.parse_args(argv)
    if args.prepare_build:
        try:
            payloads = ({kind: args.payload_directory / name for kind, name in RESOURCE_ASSETS.items()}
                        if args.payload_directory else None)
            generated = prepare_bundled_assets(args.project, prepared=args.prepared_resources,
                                               payloads=payloads, offline=args.offline)
            print(json.dumps({"status": "prepared", "generated": str(generated)}, ensure_ascii=False))
            return 0
        except (OSError, ValueError, KeyError, TypeError, EOFError) as error:
            print(json.dumps({"status": "failed", "error": str(error)}, ensure_ascii=False), file=sys.stderr)
            return 1
    if args.offline or args.payload_directory:
        parser.error("--offline 和 --payload-directory 与 --prepare-build 一起使用")
    if args.prepare_resource_sources is not None:
        if (args.destination is None or args.evidence or args.reuse_version or args.prepared_resources
                or args.go_module or args.pub or args.android or args.resource_source or args.resource_sources):
            parser.error("--prepare-resource-sources 需要资源参数 JSON 和 --destination，可用 --project 指定项目")
        try:
            specs = json.loads(read_resource(args.prepare_resource_sources, 128 * 1024), object_pairs_hook=unique_object)
            require(isinstance(specs, dict), "固定源码的资源参数 JSON 必须以 kind 为键、资源参数为值")
            current = read_release_resources(args.project)["resources"]
            for kind in GEO_SOURCE_REPOSITORIES:
                require(specs[kind]["sourceCommit"] == current[kind]["sourceCommit"]
                        and specs[kind]["sourceUrl"] == current[kind]["sourceUrl"]
                        and specs[kind]["version"] == current[kind]["version"], "固定源码的资源参数与应用资源清单不一致：" + kind)
            require(not args.destination.absolute().is_relative_to(args.project.resolve()), "固定源码目录须在项目之外")
            manifest = prepare_resource_sources(specs, args.destination)
            check_resource_source_selection(args.project.resolve(), read_resource_sources(manifest.parent))
            print(json.dumps({"status": "prepared", "sources": str(manifest)}, ensure_ascii=False, sort_keys=True))
            return 0
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(json.dumps({"status": "failed", "error": str(error)}, ensure_ascii=False), file=sys.stderr)
            return 1
    preparing = args.prepare_resource is not None or args.prepare_resources is not None
    if preparing:
        if (args.destination is None or args.evidence or args.reuse_version
                or args.prepared_resources or args.go_module or args.pub or args.android):
            parser.error("资源准备需要资源参数 JSON 和 --destination；原始文件通过对应的 --resource-source 或 --resource-sources 提供")
        if args.prepare_resource and args.resource_sources or args.prepare_resources and args.resource_source:
            parser.error("单项资源／五项资源原件参数与模式不匹配")
        try:
            spec = json.loads(read_resource(args.prepare_resource or args.prepare_resources, 128 * 1024),
                              object_pairs_hook=unique_object)
            if args.prepare_resource:
                paths = [prepare_resource(spec, args.destination, args.resource_source)]
            else:
                require(isinstance(spec, list), "五项资源的参数必须是 JSON 数组")
                sources = (json.loads(read_resource(args.resource_sources, 64 * 1024), object_pairs_hook=unique_object)
                           if args.resource_sources else None)
                require(sources is None or isinstance(sources, dict), "原件路径映射必须是对象")
                paths = prepare_resources(spec, args.destination, sources)
            report = {"status": "prepared", "prepared": [str(path) for path in paths],
                      "receipts": [str(path / "receipt.json") for path in paths]}
        except (OSError, ValueError, KeyError, TypeError, EOFError) as error:
            print(json.dumps({"status": "failed", "error": str(error)}, ensure_ascii=False), file=sys.stderr)
            return 1
        print(json.dumps(report, ensure_ascii=False, sort_keys=True))
        return 0
    if args.destination or args.resource_source or args.resource_sources:
        parser.error("资源准备目录和原始下载文件的路径参数须与 --prepare-resource 或 --prepare-resources 一起使用")
    if (args.evidence or args.reuse_version or args.prepared_resources) and not args.apply:
        parser.error("--evidence、--reuse-version 和 --prepared-resources 与 --apply 一起使用")
    try:
        report = execute(args)
    except (OSError, ValueError, KeyError, TypeError, EOFError, ET.ParseError, subprocess.SubprocessError) as error:
        print(json.dumps({"status": "failed", "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
