"""官方资源发现与对应源码准备。"""
import hashlib
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import tempfile
import urllib.parse
from tool.common.io import fetch, require, read_resource, json_bytes, unique_object, FETCH_LIMIT, RESOURCE_TOTAL_LIMIT
from tool.common.workspace import sync_directory
from tool.dependencies.versions import application_version
from tool.dependencies.resources import (RESOURCE_ASSETS, RESOURCE_INPUTS, RESOURCE_RECORD, GEO_SOURCE_REPOSITORIES, resource_spec, prepare_resource, read_prepared_resource, prepared_specs, read_resource_sources, check_resource_source_selection, _source_expected, _replace_directory)

ROOT = Path(__file__).resolve().parents[2]


GEOIP_DATA_PROCESSING = (
    "V2Fly geoip 官方构建使用同一仓库 release 数据提交中的 text/*.txt 及转换器 config.json，"
    "合并 DB-IP Lite Country MMDB、内置 private 与 test 列表后生成所分发的 GeoIP.dat。")


CA_INDEX = "https://curl.se/docs/caextract.html"


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
    ref = _github_json(f"https://api.github.com/repos/v2fly/{repository}/git/ref/tags/{urllib.parse.quote(version, safe='')}", "V2Fly tag", fetch)
    target = ref.get("object")
    for _ in range(2):
        require(isinstance(target, dict) and isinstance(target.get("sha"), str), "V2Fly tag 对象无效")
        if target.get("type") == "commit":
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


class _PageLinks(HTMLParser):
    def __init__(self, data, url):
        super().__init__()
        self.url = url
        self.links = []
        self.feed(data.decode("utf-8", errors="replace"))

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            href = dict(attrs).get("href")
            if href:
                self.links.append(urllib.parse.urljoin(self.url, href))


def _download_link(links, prefix, suffix):
    for link in links:
        name = Path(urllib.parse.urlsplit(link).path).name
        if name.startswith(prefix) and name.endswith(suffix):
            return link, name[len(prefix):-len(suffix)]
    raise ValueError("官方下载页缺少资源链接：" + prefix + "*" + suffix)


def official_resource_spec(kind, root=ROOT, *, fetch=None):
    """从官方 API 和下载页链接读取资源来源。"""
    require(kind in RESOURCE_ASSETS, "未知资源种类")
    fetch = _resolver(fetch)
    if kind == "ca":
        links = _PageLinks(fetch(CA_INDEX, limit=FETCH_LIMIT), CA_INDEX).links
        url, version = _download_link(links, "cacert-", ".pem")
        checksum_url = next((link for link in links
                             if urllib.parse.urlsplit(link).path == urllib.parse.urlsplit(url).path + ".sha256"), None)
        require(checksum_url is not None, "curl 官方下载页缺少 PEM 校验文件链接")
        checksum = fetch(checksum_url, limit=4096).decode("ascii").strip()
        match = re.fullmatch(r"(?:SHA256\([^\r\n]+\)\s*=\s*)?([0-9a-fA-F]{64})(?:[ \t]+\*?[^\r\n]+)?", checksum)
        require(match is not None, "CA 官方校验文件格式无效")
        return resource_spec({"kind": "ca", "version": version, "sourceUrl": url,
                              "checksumUrl": checksum_url, "storedSha256": match[1].lower()})
    if kind in ("geoip", "geosite"):
        repository = GEO_SOURCE_REPOSITORIES[kind]
        asset = "geoip.dat" if kind == "geoip" else "dlc.dat"
        release = _github_json("https://api.github.com/repos/v2fly/" + repository + "/releases/latest",
                               "V2Fly release", fetch)
        version = release["tag_name"]
        assets = [entry for entry in release["assets"] if entry["name"] == asset]
        require(len(assets) == 1, "V2Fly 发布附件缺失或同名附件重复：" + asset)
        item = assets[0]
        commit = _tag_commit(repository, version, fetch)
        name = GEO_LICENSE_FILES[kind]
        license_data = fetch(f"https://raw.githubusercontent.com/v2fly/{repository}/{commit}/LICENSE",
                             limit=32 * 1024 * 1024)
        original = read_resource(root / "third_party/data/geodata" / name, 32 * 1024 * 1024)
        require(license_data == original, "指定源码提交中的资源许可内容已变化，请完成技术复核：" + name)
        spec = {"kind": kind, "version": version, "sourceUrl": item["browser_download_url"],
                "sourceCommit": commit, "licenseSha256": hashlib.sha256(original).hexdigest(),
                "storedBytes": item["size"]}
        if item.get("digest"):
            algorithm, digest = item["digest"].split(":", 1)
            require(algorithm == "sha256", "V2Fly 发布附件摘要算法不支持：" + algorithm)
            spec["storedSha256"] = digest
        if kind == "geoip":
            data_commit = _geoip_data_commit(version, release["published_at"], fetch)
            spec["sourceInputs"] = [{"sourceCommit": data_commit,
                                     "description": f"release {version} 构建提交中的 text/*.txt 补充输入"}]
        return resource_spec(spec)
    name = "country" if kind == "mmdb" else "asn"
    page = DBIP_PAGES[kind]
    links = _PageLinks(fetch(page, limit=FETCH_LIMIT), page).links
    url, version = _download_link(links, "dbip-" + name + "-lite-", ".mmdb.gz")
    return resource_spec({"kind": kind, "version": version, "sourceUrl": url, "sourcePage": page})


def official_resource_specs(root=ROOT, *, fetch=None):
    """查询本次 release 的五项官方来源。"""
    return [official_resource_spec(kind, root, fetch=fetch) for kind in RESOURCE_ASSETS]


def prepare_official_resources(destination, *, root=ROOT, fetch=None):
    """查询官方来源，完整准备后替换缓存；失败时保留原有资源。"""
    fetch = _resolver(fetch)
    specs = official_resource_specs(root, fetch=fetch)
    destination = Path(destination).absolute()
    require(destination.resolve() == destination and not destination.is_relative_to(ROOT),
            "release 更新的资源目录必须在仓库外且不能包含符号链接")
    destination.mkdir(parents=True, exist_ok=True)
    entries = {entry.name for entry in destination.iterdir()}
    require(entries <= set(RESOURCE_ASSETS), "资源准备根目录包含未知条目：" + repr(sorted(entries - set(RESOURCE_ASSETS))))
    cached = {}
    for kind in RESOURCE_ASSETS:
        directory = destination / kind
        require(not directory.is_symlink() and (not directory.exists() or directory.is_dir()), "资源缓存目录无效：" + kind)
        if (directory / "resource.json").exists():
            cached[kind] = read_prepared_resource(directory)
    with tempfile.TemporaryDirectory(prefix=".resource-update-", dir=destination.parent) as temporary:
        staging = Path(temporary) / "resources"
        staging.mkdir()
        resolved = []
        for spec in specs:
            directory = staging / spec["kind"]
            previous, payload = cached.get(spec["kind"], ({}, None))
            if "storedSha256" in spec and all(previous.get(key) == value for key, value in spec.items()):
                directory.mkdir()
                (directory / "payload").write_bytes(payload)
                (directory / "resource.json").write_bytes(json_bytes(previous))
                resolved.append(previous)
            else:
                prepare_resource(spec, directory, fetch=fetch)
                resolved.append(json.loads((directory / "resource.json").read_bytes()))
        require(all(sum(spec[prefix + "Bytes"] for spec in resolved) <= RESOURCE_TOTAL_LIMIT
                    for prefix in ("stored", "installed")), "资源总量超过上限")
        _replace_directory(staging, destination)
    return [destination / kind for kind in RESOURCE_ASSETS]


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
        url, name = _source_expected("geoip", commit)
        require(name not in names and commit not in commits, "重复的 GeoIP 补充输入")
        names.add(name)
        commits.add(commit)
        result.append({"sourceCommit": commit, "sourceUrl": url, "file": name, "description": description})
    require(result, "GeoIP 补充输入缺失")
    return result, commits


def _download_source(url, destination, fetch):
    with tempfile.TemporaryDirectory(prefix=".source-download-", dir=destination.parent) as temporary:
        archive = Path(temporary) / "archive"
        result = fetch(url, limit=FETCH_LIMIT, destination=archive)
        os.replace(archive, destination)
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
                require(row["sourceCommit"] == fixed[kind]["sourceCommit"],
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
    return manifest


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


def resource_changes(root, prepared, *, delivery_version=None, source_metadata=None, toolchains=None, dependencies=None):
    """生成本次 release 的固定来源记录；payload 与实际 manifest 由构建入口生成。"""
    specs = prepared_specs(prepared)
    record = {"format": "clash-pseudo-release-resources", "version": 1,
              "application": delivery_version or application_version(root),
              "resources": specs,
              "licenses": {name: {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                           for name in RESOURCE_INPUTS if name != RESOURCE_RECORD
                           for data in [read_resource(Path(root) / name, 32 * 1024 * 1024)]}}
    if source_metadata is not None:
        record["sourceInputs"] = source_metadata
    if toolchains is not None:
        record["toolchains"] = toolchains
    if dependencies is not None:
        record["dependencies"] = dependencies
    return {RESOURCE_RECORD: json_bytes(record)}
