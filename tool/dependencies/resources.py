"""固定资源记录、payload 校验与构建资源。"""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import ssl
import shutil
import stat
import tempfile
import urllib.parse
from tool.common.io import (fetch as download, require, read_resource, read_bounded, json_bytes, unique_object, FETCH_LIMIT, RESOURCE_LIMIT, RESOURCE_TOTAL_LIMIT)
from tool.common.workspace import sync_directory

def _resolver(fetch):
    return fetch or download

ROOT = Path(__file__).resolve().parents[2]


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


GEO_SOURCE_REPOSITORIES = {"geoip": "geoip", "geosite": "domain-list-community"}


def resource_spec(spec):
    """补齐资源安装所用的编码方式。"""
    return {"encoding": "gzip" if spec["kind"] in ("mmdb", "asn") else "identity", **spec}


def validate_resource(data, spec):
    """核对下载字节，限制解压大小并记录实际安装数据。"""
    stored = {"storedBytes": len(data), "storedSha256": hashlib.sha256(data).hexdigest()}
    require(0 < len(data) <= FETCH_LIMIT
            and all(spec.get(key, value) == value for key, value in stored.items()),
            "下载文件的字节数或 SHA-256 与记录值不一致，或大小超过上限")
    if spec["encoding"] == "gzip":
        with gzip.GzipFile(fileobj=io.BytesIO(data)) as stream:
            installed = read_bounded(stream, RESOURCE_LIMIT)
    else:
        installed = data
    require(0 < len(installed) <= RESOURCE_LIMIT, "安装用文件为空或大小超过上限")
    measured = {"installedBytes": len(installed), "installedSha256": hashlib.sha256(installed).hexdigest()}
    if spec["kind"] == "ca":
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        # cafile 保留 PEM 注释中的 UTF-8 字节，由 TLS 库解析整份文件。
        with tempfile.TemporaryDirectory(prefix="clash-ca-") as temporary:
            pem = Path(temporary) / "cacert.pem"
            pem.write_bytes(installed)
            context.load_verify_locations(cafile=str(pem))
        measured["certificateRoots"] = context.cert_store_stats()["x509"]
    return dict(spec, **stored, **measured)


def read_prepared_resource(directory):
    """读取固定资源记录并核对实际 payload。"""
    directory = Path(directory).absolute()
    require(directory.resolve() == directory
            and (not directory.is_relative_to(ROOT) or directory.is_relative_to(ROOT / "build/generated")),
            "资源准备目录不能包含符号链接或写入源码目录")
    spec = json.loads(read_resource(directory / "resource.json", 128 * 1024), object_pairs_hook=unique_object)
    data = read_resource(directory / "payload", min(spec["storedBytes"], FETCH_LIMIT))
    return validate_resource(data, spec), data


def prepare_resource(spec, destination, source=None, *, fetch=None):
    """在独立目录下载资源，成功后保存固定记录和 payload。"""
    fetch = _resolver(fetch)
    spec = resource_spec(spec)
    destination = Path(destination).absolute()
    require(destination.resolve() == destination
            and (not destination.is_relative_to(ROOT) or destination.is_relative_to(ROOT / "build/generated")),
            "资源准备目录不能包含符号链接或写入源码目录")
    destination.mkdir(parents=True, exist_ok=True)
    if any(destination.iterdir()):
        resolved, _ = read_prepared_resource(destination)
        require(all(resolved.get(key) == value for key, value in spec.items()
                    if key not in ("installedBytes", "installedSha256", "certificateRoots")),
                "重新运行时资源来源或固定输入不同")
        return destination
    expected = dict(spec)
    if "storedSha256" not in spec and spec.get("checksumUrl"):
        checksum = fetch(spec["checksumUrl"], limit=4096).decode("ascii").strip()
        match = re.fullmatch(r"(?:SHA256\([^\r\n]+\)\s*=\s*)?([0-9a-fA-F]{64})(?:[ \t]+\*?[^\r\n]+)?", checksum)
        require(match is not None, "官方校验文件格式无效")
        expected["storedSha256"] = match[1].lower()
    limit = min(spec.get("storedBytes", FETCH_LIMIT), FETCH_LIMIT)
    with tempfile.TemporaryDirectory(prefix=".resource-", dir=destination.parent) as temporary:
        staging = Path(temporary)
        payload = staging / "payload"
        if source is None:
            fetch(spec["sourceUrl"], limit=limit, destination=payload)
        else:
            payload.write_bytes(read_resource(source, limit))
        resolved = validate_resource(read_resource(payload, limit), expected)
        (staging / "resource.json").write_bytes(json_bytes(resolved))
        os.replace(staging, destination)
        sync_directory(destination.parent)
    return destination


def prepare_resources(specs, destination, sources=None):
    specs = [resource_spec(spec) for spec in specs]
    require(len(specs) == len(RESOURCE_ASSETS) and {spec["kind"] for spec in specs} == set(RESOURCE_ASSETS),
            "交付资源必须完整且没有重复种类")
    paths = [prepare_resource(spec, Path(destination) / spec["kind"], (sources or {}).get(spec["kind"]))
             for spec in specs]
    resolved = [read_prepared_resource(path)[0] for path in paths]
    require(all(sum(spec[prefix + "Bytes"] for spec in resolved) <= RESOURCE_TOTAL_LIMIT
                for prefix in ("stored", "installed")), "资源总量超过上限")
    return paths


def prepared_resources(directory):
    return [Path(directory) / kind for kind in RESOURCE_ASSETS]


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
    revision = urllib.parse.quote(commit, safe="")
    url = f"https://github.com/v2fly/{repository}/archive/{revision}.tar.gz"
    return url, f"{repository}-{revision}.tar.gz"


def resource_source_entries(metadata):
    """读取源码清单，检查归档路径和大小上限，返回登记的 (kind, source)。"""
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
            require(isinstance(name, str) and name not in ("", ".", "..", "resource-sources.json")
                    and "/" not in name and "\\" not in name and "\0" not in name,
                    "资源对应源码文件路径无效")
            require(name not in filenames and commit not in commits, "重复资源源码文件或提交：" + kind)
            filenames.add(name)
            commits.add(commit)
            size = source.get("bytes")
            require(type(size) is int and 0 < size <= FETCH_LIMIT, "资源对应源码大小无效：" + kind)
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
    return record


def bundled_materials(root, record):
    from tool.dependencies import legal
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
        data = read_resource(Path(root) / name, 32 * 1024 * 1024)
        require(record["licenses"][name] == {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()},
                "release 资源许可正文发生变化：" + name)
        result["legal/" + relative] = data
        if relative.startswith("geodata/"):
            result["assets/geodata/licenses/" + Path(name).name] = data
    from tool.contracts import generate as contract
    result["kotlin/io/github/monadboxlab/clashpseudo/nativecore/BundledAssetContract.kt"] = contract.asset_metadata(
        json.loads(result["assets/geodata/manifest.json"], object_pairs_hook=unique_object),
        json.loads(result["certificates.json"], object_pairs_hook=unique_object)).encode()
    result["resources.json"] = json_bytes(record)
    return result


def _replace_directory(staging, destination):
    previous = destination.with_name(destination.name + ".previous")
    require(not previous.exists() and not previous.is_symlink(), "存在尚未恢复的资源目录：" + str(previous))
    if destination.exists():
        os.replace(destination, previous)
    try:
        os.replace(staging, destination)
    except BaseException as error:
        if previous.exists():
            try:
                os.replace(previous, destination)
            except BaseException as rollback:
                error.add_note("恢复旧资源失败，原文件保留于 " + str(previous) + "：" + str(rollback))
        raise
    if previous.exists():
        shutil.rmtree(previous)


def prepare_bundled_assets(root, *, prepared=None, payloads=None, output=None, fetch=None, offline=False):
    """普通构建只读取固定记录；缺失 payload 时按记录的 URL 和摘要补齐。"""
    root = Path(root).resolve()
    record = read_release_resources(root)
    output = Path(output).absolute() if output else root / GENERATED_BUNDLED
    require(output.resolve() == output and output.is_relative_to(root / "build/generated"),
            "bundled assets 必须写入 build/generated 且不能包含符号链接")
    output.parent.mkdir(parents=True, exist_ok=True)
    import fcntl
    with (output.parent / ".bundled.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        cache = root / "build/generated/resource-cache"
        data = {}
        for kind, spec in record["resources"].items():
            if prepared is not None:
                payload = read_resource(Path(prepared) / kind / "payload", min(spec["storedBytes"], FETCH_LIMIT))
                validate_resource(payload, spec)
            else:
                # 摘要只作为单个目录名，记录不参与路径拼接。
                digest_name = spec["storedSha256"]
                require(isinstance(digest_name, str) and digest_name not in ("", ".", "..")
                        and "/" not in digest_name and "\\" not in digest_name and "\0" not in digest_name,
                        "资源缓存路径无效")
                directory = cache / digest_name
                require(directory.resolve() == directory, "资源缓存目录不能包含符号链接")
                cached_payload = directory / "payload"
                if not cached_payload.exists():
                    source = (payloads or {}).get(kind)
                    require(not offline or source is not None, "离线构建缺少固定资源：" + kind)
                    cache.mkdir(parents=True, exist_ok=True)
                    with tempfile.TemporaryDirectory(prefix=".download-", dir=cache) as temporary:
                        incoming = Path(temporary) / "payload"
                        limit = min(spec["storedBytes"], FETCH_LIMIT)
                        if source is None:
                            _resolver(fetch)(spec["sourceUrl"], limit=limit, destination=incoming)
                        else:
                            incoming.write_bytes(read_resource(source, limit))
                        payload = read_resource(incoming, limit)
                        validate_resource(payload, spec)
                        directory.mkdir(exist_ok=True)
                        os.replace(incoming, cached_payload)
                else:
                    payload = read_resource(cached_payload, min(spec["storedBytes"], FETCH_LIMIT))
                    validate_resource(payload, spec)
            data["assets/" + RESOURCE_ASSETS[kind]] = payload
        data.update(bundled_materials(root, record))
        # 输出先写入新目录；任何校验失败都不替换上一份完整输出。
        with tempfile.TemporaryDirectory(prefix=".bundled-", dir=output.parent) as temporary:
            staging = Path(temporary) / "complete"
            staging.mkdir()
            for name, value in data.items():
                target = staging / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(value)
            require(read_release_resources(root) == record, "生成期间 release 资源记录发生变化")
            _replace_directory(staging, output)
    return output


def check_resource_source_selection(root, metadata):
    """比较可编辑资源源码与本次 release 固定记录中的提交。"""
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
