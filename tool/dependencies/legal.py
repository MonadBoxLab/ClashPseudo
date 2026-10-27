"""依赖更新使用的原始许可收集与 GPLv3 组合检查。"""

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
# 与项目现有 GPL-3.0-only 组合及独立文件源码交付相符的标准许可。
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
    for path in sorted(directory.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(directory).as_posix()
        if LEGAL_NAME.fullmatch(path.name):
            result[relative] = path.read_bytes()
        elif path.suffix in (".go", ".c", ".h", ".s", ".S", ".java", ".kt", ".dart"):
            text = path.read_text(encoding="utf-8", errors="replace")
            copyrights.update(line for line in text.splitlines()
                              if re.search(r"(?i)copyright\b|©", line))
    if copyrights:
        result["源码版权行"] = ("\n".join(sorted(copyrights)) + "\n").encode()
    return result


def render_files(files):
    return "".join(f"\n--- {name} | SHA-256 {sha(data)} ---\n" + data.decode("utf-8") + "\n"
                   for name, data in sorted(files.items()))


def archive_legal(data):
    """只读取 ZIP 内容，原始材料保持在字节中，嵌套 JAR 单独读取。"""
    files = {}
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for info in archive.infolist():
            path = PurePosixPath(info.filename)
            if info.is_dir():
                continue
            if LEGAL_NAME.fullmatch(path.name):
                files[path.as_posix()] = archive.read(info)
            elif path.suffix == ".jar":
                for name, value in archive_legal(archive.read(info)).items():
                    files[path.as_posix() + "!/" + name] = value
            elif path.suffix in (".java", ".kt"):
                content = archive.read(info).decode("utf-8")
                header = re.match(r"\s*(/\*.*?\*/)", content, re.S)
                if header and re.search(r"(?i)copyright|licensed|permission", header[1]):
                    files[path.as_posix() + "（许可头）"] = header[1].encode()
    return files


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
        self.public_suffix(graph)

    def public_suffix(self, graph):
        module = graph["golang.org/x/net"]
        metadata = json.loads(self.updater.go_run("mod", "download", "-json",
                                                module["Path"] + "@" + module["Version"]))
        table = (Path(metadata["Dir"]) / "publicsuffix/table.go").read_text(encoding="utf-8")
        revision = re.search(r"git revision ([0-9a-f]{40})", table[:6000])
        self.require(revision, "x/net publicsuffix 来源修订缺失")
        revision = revision[1]
        notice = self.root / "third_party/notices/publicsuffix.txt"
        current = notice.read_bytes().decode("utf-8")
        target = self.root / "third_party/data/publicsuffix/public_suffix_list.dat"
        unchanged = revision in current and module["Version"] in current
        if unchanged and target.is_file() and sha(target.read_bytes()) in current:
            return
        data = self.fetch("https://raw.githubusercontent.com/publicsuffix/list/" + revision + "/public_suffix_list.dat")
        if unchanged:
            self.require(sha(data) in current, "PSL 固定来源与现有摘要不同")
        # 可编辑列表随对应源码交付；MPL 原文继续复用现有材料。
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        if unchanged:
            return
        notice.write_text(
            f"Public Suffix List\nx/net {module['Version']}；PSL {revision}\n"
            f"来源：https://github.com/publicsuffix/list/blob/{revision}/public_suffix_list.dat\n"
            f"列表 SHA-256：{sha(data)}\n\n"
            "列表采用 MPL-2.0，Go 实现采用其随附 BSD 许可。可编辑列表随对应源码提供。\n\n"
            + (self.root / "third_party/data/certificates/MPL-2.0.txt").read_text(encoding="utf-8"), encoding="utf-8")

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
            self.require(uri.scheme == "file", "Pub 包来源不是本地解析文件")
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
