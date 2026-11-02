"""收集依赖的许可原文，检查许可与GPLv3的兼容性。"""

import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import urllib.error
from urllib.parse import unquote, urljoin, urlparse
import xml.etree.ElementTree as ET
import zipfile


SEPARATOR = "=" * 72 + "\n"
CLASSIFIER = "github.com/google/licenseclassifier/v2/tools/identify_license@v2.0.0"
TEXT_LIMIT = 8 * 1024 * 1024
ARCHIVE_LIMIT = 64 * 1024 * 1024
ARCHIVE_ENTRIES = 10000


def limited_read(stream, limit):
    result = bytearray()
    while True:
        chunk = stream.read(min(64 * 1024, limit - len(result) + 1))
        if not chunk:
            return bytes(result)
        if len(result) + len(chunk) > limit:
            raise ValueError("许可材料超过读取大小上限")
        result.extend(chunk)


def read_text_bytes(path):
    with path.open("rb") as stream:
        return limited_read(stream, TEXT_LIMIT)

# 可与GPL-3.0-only组合的许可，以及随独立数据文件提供源码时可用的许可。
COMPATIBLE = {
    "MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "BSD-0-Clause", "0BSD",
    "ISC", "Zlib", "Unlicense", "CC0-1.0", "BSL-1.0", "MPL-2.0",
    "GPL-3.0", "GPL-3.0-only", "GPL-3.0-or-later",
    "LGPL-2.1", "LGPL-2.1-only", "LGPL-2.1-or-later", "LGPL-3.0", "LGPL-3.0-only",
    "LGPL-3.0-or-later", "Unicode-DFS-2016", "Unicode-3.0", "PSF-2.0",
}
LEGAL_NAME = re.compile(r"^(?:licen[sc]e|copying|notice|copyright|authors|patents)(?:[._-].*)?$", re.I)
GRANT_NAME = re.compile(r"^(?:licen[sc]e|copying)(?:[._-].*)?$", re.I)
POM_LICENSES = {
    "The Apache Software License, Version 2.0": "Apache-2.0",
    "The Apache License, Version 2.0": "Apache-2.0",
    "Apache License, Version 2.0": "Apache-2.0",
    "Apache 2.0": "Apache-2.0",
    "Apache-2.0": "Apache-2.0",
    "MIT License": "MIT",
    "MIT": "MIT",
    "BSD 3-Clause": "BSD-3-Clause",
    "BSD-3-Clause": "BSD-3-Clause",
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def sections(text, pattern):
    matches = list(re.finditer(r"(?m)^={10,}\n(" + pattern + r")\n", text))
    prefix = text[:matches[0].start()] if matches else text
    blocks = {}
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        key = match[1]
        if key in blocks:
            raise ValueError("通知包含重复依赖：" + key)
        blocks[key] = text[match.start():end]
    return prefix, blocks


def legal_files(directory):
    result = {}
    copyrights = set()
    paths = []
    for path in directory.rglob("*"):
        paths.append(path)
        if len(paths) > 100000:
            raise ValueError("许可源码文件数超过上限")
    total = 0
    for path in sorted(paths):
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(directory).as_posix()
        if LEGAL_NAME.fullmatch(path.name):
            result[relative] = read_text_bytes(path)
            total += len(result[relative])
        elif path.suffix in (".go", ".c", ".h", ".s", ".S", ".java", ".kt", ".dart"):
            text = read_text_bytes(path).decode("utf-8", errors="replace")
            for line in text.splitlines():
                if line not in copyrights and re.search(r"(?i)copyright\b|©", line):
                    copyrights.add(line)
                    total += len(line.encode()) + 1
        if total > ARCHIVE_LIMIT:
            raise ValueError("许可正文与版权行超过总大小上限")
    if copyrights:
        result["源码版权行"] = ("\n".join(sorted(copyrights)) + "\n").encode()
    return result


def render_files(files):
    return "".join(f"\n--- {name} | SHA-256 {sha(data)} ---\n" + data.decode("utf-8") + "\n"
                   for name, data in sorted(files.items()))


def archive_legal(data, *, _budget=None, _depth=0):
    """读取归档中的许可；外层归档与嵌套JAR共用解压后总大小和条目数上限。"""
    if len(data) > ARCHIVE_LIMIT or _depth > 4:
        raise ValueError("许可归档大小或嵌套层数超过上限")
    budget = _budget if _budget is not None else {"bytes": ARCHIVE_LIMIT, "entries": ARCHIVE_ENTRIES}
    files = {}
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        budget["entries"] -= len(entries)
        if budget["entries"] < 0:
            raise ValueError("许可归档超过条目数上限")
        for info in entries:
            path = PurePosixPath(info.filename)
            if info.is_dir() or not (LEGAL_NAME.fullmatch(path.name) or path.suffix in (".jar", ".java", ".kt")):
                continue
            limit = min(budget["bytes"], ARCHIVE_LIMIT if path.suffix == ".jar" else TEXT_LIMIT)
            if info.file_size > limit or info.flag_bits & 1:
                raise ValueError("许可归档成员大小超过上限或已加密：" + info.filename)
            with archive.open(info) as stream:
                value = limited_read(stream, limit)
            budget["bytes"] -= len(value)
            if LEGAL_NAME.fullmatch(path.name):
                if path.as_posix() in files:
                    raise ValueError("许可归档包含重复正文：" + path.as_posix())
                files[path.as_posix()] = value
            elif path.suffix == ".jar":
                for name, value in archive_legal(value, _budget=budget, _depth=_depth + 1).items():
                    key = path.as_posix() + "!/" + name
                    if key in files:
                        raise ValueError("许可归档包含重复正文：" + key)
                    files[key] = value
            else:
                header = re.match(r"\s*(/\*.*?\*/)", value.decode("utf-8"), re.S)
                if header and re.search(r"(?i)copyright|licensed|permission", header[1]):
                    files[path.as_posix() + "（许可头）"] = header[1].encode()
    return files


def resource_materials(root, specs):
    """生成 CA 与 Geo 的资源清单和来源通知，返回各文件的待写入内容。"""
    def encoded(value):
        return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()

    ca = specs["ca"]
    certificate = {}
    certificate.update(asset="certificates/cacert.pem", sourceUrl=ca["sourceUrl"], version=ca["version"],
                       checksumUrl=ca.get("checksumUrl", ca["sourceUrl"] + ".sha256"),
                       bytes=ca["storedBytes"], sha256=ca["storedSha256"], roots=ca["certificateRoots"])
    ca_notice = (
        "公共 CA 数据通知\n\nMozilla 公共 CA 数据，经 curl 的 Mozilla CA Extract 项目提供。\n"
        "来源与说明：https://curl.se/docs/caextract.html\n"
        f"原始快照：{ca['sourceUrl']}\nMozilla 数据版本：{ca['version']}\n"
        "对应源码位置：build-inputs/bundled/assets/certificates/cacert.pem\n"
        f"原始文件：{ca['storedBytes']} bytes\n完整文件 SHA-256：{ca['storedSha256']}\n\n"
        "本地处理：保存上述PEM快照，包含其头部、证书名称和证书数据。\n"
        "文件校验：对完整PEM计算SHA-256，与上述值比较。\n\n"
        "公共 CA 数据采用 Mozilla Public License 2.0。\n"
        "MPL-2.0 全文：third_party/data/certificates/MPL-2.0.txt\n"
        "官方法律原文：https://www.mozilla.org/media/MPL/2.0/index.txt\n"
        "获取源码：从上述原始文件 URL 下载，或在应用对应源码包的\n"
        "build-inputs/bundled/assets/certificates/cacert.pem 查找。分发时附上本通知和 MPL 全文。\n"
        "应用对应源码下载入口见NOTICE.md。\n"
    ).encode()
    geo = {}
    names = {"geoip": ("GeoIP.dat", "GeoIP.dat"), "geosite": ("GeoSite.dat", "GeoSite.dat"),
             "mmdb": ("Country.mmdb", "dbip-country-lite.mmdb.gzip"),
             "asn": ("ASN.mmdb", "dbip-asn-lite.mmdb.gzip")}
    records = []
    for kind, (work, asset) in names.items():
        spec = specs[kind]
        item = {}
        item.update({key: spec[key] for key in ("kind", "version", "sourceUrl", "encoding", "storedBytes",
                                                "storedSha256", "installedBytes", "installedSha256")})
        item.update(workName=work, asset=asset)
        item["licenses"] = (["CC-BY-SA-4.0", "CC-BY-4.0"] if kind == "geoip"
                            else ["MIT"] if kind == "geosite" else ["CC-BY-4.0"])
        item["attribution"] = ("Copyright (c) 2018-2019 V2Ray" if kind == "geosite" else
                               ("V2Fly; " if kind == "geoip" else "")
                               + "IP Geolocation by DB-IP (https://db-ip.com/)")
        item["changes"] = (f"本地文件名：{asset}；安装文件名：{work}。安装时复制该DAT文件。"
                           if kind in ("geoip", "geosite") else
                           f"应用内文件名：{asset}；安装时将官方gzip解压为{work}。")
        if kind in ("geoip", "geosite"):
            item["sourceCommit"] = spec["sourceCommit"]
            item["licenseSha256"] = spec["licenseSha256"]
        else:
            item["sourcePage"] = spec["sourcePage"]
        records.append(item)
    materials = []
    for name, source in (
        ("CC-BY-SA-4.0.txt", f"https://raw.githubusercontent.com/v2fly/geoip/{specs['geoip']['sourceCommit']}/LICENSE"),
        ("GeoSite-MIT.txt", f"https://raw.githubusercontent.com/v2fly/domain-list-community/{specs['geosite']['sourceCommit']}/LICENSE"),
        ("CC-BY-4.0.txt", "https://raw.githubusercontent.com/spdx/license-list-data/v3.27.0/text/CC-BY-4.0.txt"),
    ):
        data = read_text_bytes(root / "third_party/data/geodata" / name)
        if not data:
            raise ValueError("资源许可正文为空：" + name)
        kind = {"CC-BY-SA-4.0.txt": "geoip", "GeoSite-MIT.txt": "geosite"}.get(name)
        if kind and sha(data) != specs[kind]["licenseSha256"]:
            raise ValueError("指定源码提交中的资源许可内容已变化，请完成技术复核：" + name)
        materials.append({"file": "licenses/" + name, "bytes": len(data), "sha256": sha(data), "sourceUrl": source})
    if not read_text_bytes(root / "third_party/data/certificates/MPL-2.0.txt"):
        raise ValueError("CA MPL-2.0 许可正文缺失")
    notice = ("内置Geo数据的来源与许可\n\n"
              + "\n\n".join(
                  f"{item['workName']}\n来源：{item['sourceUrl']}\n版本：{item['version']}\n"
                  + (f"源码：{item['sourceCommit']}\n" if "sourceCommit" in item else f"官网下载页：{item['sourcePage']}\n")
                  + f"许可：{', '.join(item['licenses'])}\n归属：{item['attribution']}\n处理：{item['changes']}"
                  for item in records)
              + "\n\nAPK 内的许可全文位于 geodata/licenses/CC-BY-SA-4.0.txt、GeoSite-MIT.txt 和 CC-BY-4.0.txt。\n"
              "来源、版本、下载文件和安装用文件的字节数及 SHA-256 记录在 geodata/manifest.json 中。\n"
              "构建时从 third_party/data/resources.json 的冻结记录生成上述文件，不查询最新版本。\n"
              "应用对应源码包包含 build-inputs/bundled/assets/geodata/ 下的同次数据库、manifest 与许可，\n"
              "以及 dependencies/data/ 下的 GeoIP 转换器、GeoIP 数据和 GeoSite 可编辑源码归档。\n"
              "源码归档来源、大小与 SHA-256 见 build-inputs/resource-sources.json；下载入口见 NOTICE.md。\n").encode()
    geo.update(format="clash-pseudo-bundled-geodata", version=1, files=records, legalMaterials=materials,
               installedTotalBytes=sum(item["installedBytes"] for item in records),
               storedDataTotalBytes=sum(item["storedBytes"] for item in records),
               notice={"file": "NOTICE.txt", "bytes": len(notice), "sha256": sha(notice)})
    return {
        "third_party/data/certificates/manifest.json": encoded(certificate),
        "third_party/data/certificates/NOTICE.txt": ca_notice,
        "android/app/src/main/assets/geodata/manifest.json": encoded(geo),
        "third_party/data/geodata/NOTICE.txt": notice,
    }


class Legal:
    def __init__(self, updater, temporary, fetch, run, artifacts):
        self.updater = updater
        self.root = updater.root
        self.temporary = temporary
        self.fetch = fetch
        self.run = run
        self.require = artifacts.require
        self.artifacts = artifacts

    def check(self, files, previous="", gpl2_later=False):
        grants = {name: data for name, data in files.items()
                  if GRANT_NAME.fullmatch(PurePosixPath(name).name)}
        self.require(grants, "缺少许可授权正文：" + repr(sorted(files)))
        accepted = set(re.findall(r"SHA-256 ([a-f0-9]{64})", previous))
        changed = {name: data for name, data in grants.items() if sha(data) not in accepted}
        if not changed:
            return
        directory = self.temporary / "classification"
        directory.mkdir(exist_ok=True)
        paths = []
        for index, (name, data) in enumerate(sorted(changed.items())):
            path = directory / str(index)
            path.write_bytes(data)
            paths.append((name, path))
        output = directory / "licenses.json"
        self.run([self.updater.go, "run", CLASSIFIER, "-tasks=1", "-json", output,
                  *[path for _, path in paths]], self.root)
        result = json.loads(output.read_text(encoding="utf-8"))
        by_path = {row["Filepath"]: row["Classifications"] for row in result}
        for name, path in paths:
            names = {row["Name"] for row in by_path.get(str(path), [])
                     if row["Name"] not in ("Copyright", "Author", "Authors")}
            allowed = COMPATIBLE | ({"GPL-2.0", "GPL-2.0-only", "GPL-2.0-or-later"} if gpl2_later else set())
            self.require(names and names <= allowed,
                         f"许可需要技术复核：{name}，识别结果 {sorted(names)}；原文 SHA-256 {sha(changed[name])}")

    def production_modules(self):
        names = set()
        for architecture in ("arm", "arm64", "amd64"):
            text = self.updater.go_run(
                "list", "-mod=readonly", "-deps", "-tags=cmfa,with_gvisor",
                "-f", "{{if .Module}}{{.Module.Path}}{{end}}", "./...",
                env={"GOOS": "android", "GOARCH": architecture, "CGO_ENABLED": "1", "GOARM": "7"},
            )
            names.update(text.split())
        return names

    def go_notices(self):
        graph = self.updater.graph(self.temporary / "modules.json")
        notice = self.root / "third_party/notices/go.txt"
        prefix, existing = sections(notice.read_bytes().decode("utf-8"), r"[\w.-]+(?:/[\w.+~-]+)+ v[^\s]+")
        blocks = []
        for name in sorted(self.production_modules()):
            module = graph[name]
            if module.get("Main"):
                continue
            effective = module.get("Replace") or module
            key = effective["Path"] + " " + effective["Version"]
            if key in existing:
                blocks.append(existing[key])
                continue
            metadata = json.loads(self.updater.go_run("mod", "download", "-json", key.replace(" ", "@")))
            self.require(not metadata.get("Error") and metadata.get("Dir"), "Go 源码归档不可用：" + key)
            files = legal_files(Path(metadata["Dir"]))
            if not any(GRANT_NAME.fullmatch(PurePosixPath(path).name) for path in files):
                origin = metadata.get("Origin", {})
                url = origin.get("URL", "")
                commit = origin.get("Hash", "")
                if url.startswith("https://github.com/") and re.fullmatch("[0-9a-f]{40}", commit):
                    repository = url.removeprefix("https://github.com/").removesuffix(".git")
                    for candidate in ("LICENSE", "LICENSE.txt", "COPYING"):
                        try:
                            files[candidate] = self.fetch(f"https://raw.githubusercontent.com/{repository}/{commit}/{candidate}")
                            break
                        except urllib.error.HTTPError as error:
                            if error.code != 404:
                                raise
            previous = "\n".join(block for old, block in existing.items() if old.startswith(effective["Path"] + " "))
            lzo = effective["Path"] == "github.com/rasky/go-lzo"
            if lzo:
                readme = (Path(metadata["Dir"]) / "README.md").read_bytes()
                self.require(b"GPL-2.0-or-later" in readme, "go-lzo 缺少与 GPLv3 组合所需的 or-later 授权")
                files["README.md"] = readme
            self.check(files, previous, gpl2_later=lzo)
            if effective["Path"] == "github.com/metacubex/mihomo":
                self.require("LICENSE" in files, "mihomo 根许可缺失")
                (self.root / "third_party/notices/mihomo.txt").write_bytes(files["LICENSE"])
            block = (SEPARATOR + key + "\nhttps://pkg.go.dev/" + key.replace(" ", "@") + "\n"
                     + f"模块 Sum：{metadata['Sum']}\nGoModSum：{metadata['GoModSum']}\n"
                     + f"模块 zip SHA-256：{sha(Path(metadata['Zip']).read_bytes())}\n"
                     + render_files(files))
            blocks.append(block)
        notice.write_text(prefix + "".join(blocks), encoding="utf-8")
        return self.public_suffix(graph)

    def public_suffix_source(self, graph):
        selected = graph["golang.org/x/net"]
        module = selected.get("Replace") or selected
        metadata = json.loads(self.updater.go_run("mod", "download", "-json",
                                                module["Path"] + "@" + module["Version"]))
        self.require(not metadata.get("Error") and metadata.get("Dir"), "x/net 实际源码不可用")
        table = read_text_bytes(Path(metadata["Dir"]) / "publicsuffix/table.go").decode("utf-8")
        revision = re.search(r"git revision ([0-9a-f]{40})", table[:6000])
        self.require(revision, "x/net 的 publicsuffix 数据缺少来源提交号")
        revision = revision[1]
        return {"module": module["Path"], "moduleVersion": module["Version"], "revision": revision,
                "sourceUrl": "https://raw.githubusercontent.com/publicsuffix/list/" + revision + "/public_suffix_list.dat"}

    def public_suffix(self, graph):
        source = self.public_suffix_source(graph)
        revision, version = source["revision"], source["moduleVersion"]
        notice = self.root / "third_party/notices/publicsuffix.txt"
        current = read_text_bytes(notice).decode("utf-8")
        target = self.root / "third_party/data/publicsuffix/public_suffix_list.dat"
        labels = (source["module"], "x/net") if source["module"] == "golang.org/x/net" else (source["module"],)
        module_pattern = r"(?:" + "|".join(re.escape(name) for name in labels) + r") " + re.escape(version)
        selected = bool(re.search(module_pattern + r"(?=[；。\s]|$)", current))
        pinned_revision = (source["sourceUrl"] in current or bool(re.search(
            r"(?m)(?:PSL |^)" + revision + r"(?=[（\s]|$)", current)))
        unchanged = selected and pinned_revision
        if unchanged and target.is_file():
            data = read_text_bytes(target)
            checksum = sha(data)
            self.require(re.search(r"(?<![0-9a-f])" + checksum + r"(?![0-9a-f])", current),
                         "PSL 固定来源与现有摘要不同")
            self.require(data and b"BEGIN ICANN DOMAINS" in data and b"END PRIVATE DOMAINS" in data,
                         "PSL 原始列表格式无效")
            return dict(source, sha256=checksum)
        data = self.fetch(source["sourceUrl"])
        self.require(data and b"BEGIN ICANN DOMAINS" in data and b"END PRIVATE DOMAINS" in data,
                     "PSL 原始列表格式无效")
        if unchanged:
            self.require(sha(data) in current, "PSL 固定来源与现有摘要不同")
        # 将可编辑PSL列表加入对应源码包，并附上现有的MPL许可全文。
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        if not unchanged:
            notice.write_text(
                f"Public Suffix List\n{source['module']} {version}；PSL {revision}\n"
                f"来源：https://github.com/publicsuffix/list/blob/{revision}/public_suffix_list.dat\n"
                f"列表 SHA-256：{sha(data)}\n\n"
                "列表采用MPL-2.0，Go实现采用其随附BSD许可。\n"
                "可编辑列表：third_party/data/publicsuffix/public_suffix_list.dat\n"
                "获取源码：从上述固定 URL 下载，或从应用对应源码包的 application.tar 中获取。\n\n"
                + (self.root / "third_party/data/certificates/MPL-2.0.txt").read_text(encoding="utf-8"), encoding="utf-8")
        return dict(source, sha256=sha(data))

    def pub_licenses(self):
        resolved = json.loads(self.run([self.updater.flutter, "pub", "deps", "--json"], self.root))
        changed = {row["name"] for row in resolved["packages"] if row.get("source") == "hosted"
                   and self.updater.pub_previous.get(row["name"]) != row["version"]}
        config = json.loads((self.root / ".dart_tool/package_config.json").read_text(encoding="utf-8"))
        base = (self.root / ".dart_tool/package_config.json").as_uri()
        for package in config["packages"]:
            if package["name"] not in changed:
                continue
            uri = urlparse(urljoin(base, package["rootUri"]))
            self.require(uri.scheme == "file", "Pub 包来源必须指向依赖解析得到的本地文件")
            directory = Path(unquote(uri.path))
            if directory == self.root:
                continue
            files = {path.name: path.read_bytes() for path in directory.iterdir()
                     if path.is_file() and GRANT_NAME.fullmatch(path.name)}
            self.check(files)

    def android_notices(self):
        graph = self.updater.android_graph()
        selected = self.artifacts.android_coordinates(graph)
        target = self.root / "third_party/notices/android.txt"
        prefix, existing = sections(target.read_bytes().decode("utf-8"), r"[\w.-]+:[\w.-]+:[^\s:]+")
        prefix = re.sub(r"releaseRuntimeClasspath 中的 \d+ 个",
                        f"releaseRuntimeClasspath 中的 {len(selected)} 个", prefix)
        blocks = []
        for coordinate in sorted(selected):
            if coordinate in existing:
                blocks.append(existing[coordinate])
                continue
            group, artifact, version = coordinate.split(":")
            relative = f"{group.replace('.', '/')}/{artifact}/{version}/{artifact}-{version}"
            pom = None
            for repository in ("https://dl.google.com/dl/android/maven2", "https://repo.maven.apache.org/maven2"):
                try:
                    pom = self.fetch(repository + "/" + relative + ".pom")
                    break
                except urllib.error.HTTPError as error:
                    if error.code != 404:
                        raise
            self.require(pom is not None, "Maven POM 缺失：" + coordinate)
            tree = ET.fromstring(pom)
            ns = {"m": "http://maven.apache.org/POM/4.0.0"}
            licenses = tree.findall("m:licenses/m:license", ns)
            # Maven 的父 POM 可以集中声明许可。
            if not licenses:
                parent = tree.find("m:parent", ns)
                if parent is not None:
                    parent_values = [parent.findtext("m:" + name, namespaces=ns)
                                     for name in ("groupId", "artifactId", "version")]
                    self.require(all(parent_values), "Maven 父 POM 坐标缺失")
                    pg, pa, pv = parent_values
                    parent_pom = self.fetch(f"{repository}/{pg.replace('.', '/')}/{pa}/{pv}/{pa}-{pv}.pom")
                    licenses = ET.fromstring(parent_pom).findall("m:licenses/m:license", ns)
            self.require(licenses, "Maven 许可声明缺失：" + coordinate)
            files = {}
            for license_element in licenses:
                name = license_element.findtext("m:name", namespaces=ns)
                identifier = POM_LICENSES.get(name)
                self.require(identifier, f"Maven 许可需要技术复核：{coordinate}，{name}")
                files["LICENSE-" + identifier] = self.fetch(
                    "https://raw.githubusercontent.com/spdx/license-list-data/v3.27.0/text/" + identifier + ".txt")
            packaging = tree.findtext("m:packaging", default="jar", namespaces=ns)
            provenance = [f"POM: {repository}/{relative}.pom\nPOM SHA-256: {sha(pom)}\n"]
            if packaging != "pom":
                for suffix in ("." + packaging, "-sources.jar"):
                    url = repository + "/" + relative + suffix
                    data = self.fetch(url)
                    provenance.append(f"归档: {url}\n归档 SHA-256: {sha(data)}\n")
                    files.update({suffix + "/" + name: value for name, value in archive_legal(data).items()})
            self.check(files)
            blocks.append(SEPARATOR + coordinate + "\n" + "".join(provenance) + render_files(files))
        target.write_text(prefix + "".join(blocks), encoding="utf-8")
