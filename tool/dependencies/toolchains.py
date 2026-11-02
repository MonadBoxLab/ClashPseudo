"""从官方 stable 元数据选择兼容工具链，并在 Gradle plugin 加载前准备固定输入。"""

import argparse
import hashlib
from html.parser import HTMLParser
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("dependency_toolchain_update", ROOT / "tool/dependencies/update.py")
update = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update)
LIMIT = 4 * 1024 * 1024 * 1024
FLUTTER = "https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json"
GO = "https://go.dev/dl/?mode=json"
ANDROID = "https://dl.google.com/android/repository/repository2-3.xml"
KOTLIN = "https://kotlinlang.org/docs/gradle-configure-project.html"
GRADLE_COMPATIBILITY = "https://docs.gradle.org/current/userguide/compatibility.html"


class Tables(HTMLParser):
    def __init__(self):
        super().__init__()
        self.rows, self.row, self.cell = [], None, None

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self.row = []
        elif tag in ("td", "th") and self.row is not None:
            self.cell = []

    def handle_data(self, data):
        if self.cell is not None:
            self.cell.append(data)

    def handle_endtag(self, tag):
        if tag in ("td", "th") and self.cell is not None:
            self.row.append(" ".join("".join(self.cell).split()))
            self.cell = None
        elif tag == "tr" and self.row is not None:
            if self.row:
                self.rows.append(self.row)
            self.row = None


def table(data):
    parser = Tables()
    parser.feed(data.decode("utf-8"))
    return parser.rows


def versions(text):
    return re.findall(r"\d+\.\d+(?:\.\d+)?", text)


def inside(version, expression):
    bounds = versions(expression)
    return bool(bounds) and update.stable_version(bounds[0]) <= update.stable_version(version) <= update.stable_version(bounds[-1])


def android_license_hash(text):
    # Android SDK 的 TrimStringAdapter 保留空行，合并段内换行与连续空白。
    text = re.sub(r"(?<=[ \t\n\x0b\f\r])[ \t]*", "", text)
    text = re.sub(r"(?<!\n)\n(?!\n)", " ", text)
    return hashlib.sha1(re.sub(r" +", " ", text).strip().encode("utf-8")).hexdigest()


def resolve(*, fetch=None):
    fetch = fetch or update.fetch
    documents = []

    def read(url):
        data = fetch(url, limit=update.FETCH_LIMIT)
        documents.append({"sourceUrl": url, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        return data

    def metadata(url):
        return json.loads(read(url), object_pairs_hook=update.unique_object)

    def maven(path):
        tree = ET.fromstring(read("https://dl.google.com/dl/android/maven2/" + path + "/maven-metadata.xml"))
        return sorted({row.text for row in tree.findall("./versioning/versions/version")
                       if row.text and update.stable_version(row.text)}, key=update.stable_version, reverse=True)

    flutter_metadata = metadata(FLUTTER)
    flutter = next(row for row in flutter_metadata["releases"]
                   if row["hash"] == flutter_metadata["current_release"]["stable"] and row["channel"] == "stable")
    selected = {"flutter": {"version": flutter["version"], "dart": flutter["dart_sdk_version"],
                            "commit": flutter["hash"], "sourceUrl": flutter_metadata["base_url"] + "/" + flutter["archive"],
                            "sha256": flutter["sha256"]}}
    go = next(row for row in metadata(GO) if row.get("stable") and update.stable_version(row["version"].removeprefix("go")))
    archive = next(row for row in go["files"] if row["os"] == "linux" and row["arch"] == "amd64" and row["kind"] == "archive")
    selected["go"] = {"version": go["version"], "sourceUrl": "https://go.dev/dl/" + archive["filename"],
                      "sha256": archive["sha256"], "bytes": archive["size"]}
    agps = maven("com/android/tools/build/gradle")
    kotlin_tree = ET.fromstring(read("https://repo.maven.apache.org/maven2/org/jetbrains/kotlin/kotlin-gradle-plugin/maven-metadata.xml"))
    kotlins = sorted({row.text for row in kotlin_tree.findall("./versioning/versions/version")
                      if row.text and update.stable_version(row.text)}, key=update.stable_version, reverse=True)
    gradles = [row for row in metadata("https://services.gradle.org/versions/all")
               if not row.get("snapshot") and not row.get("broken") and update.stable_version(row.get("version", ""))]
    gradles.sort(key=lambda row: update.stable_version(row["version"]), reverse=True)
    matrix = table(read(KOTLIN))
    excluded = []
    for agp in agps:
        major, minor, *_ = agp.split(".")
        url = f"https://developer.android.com/build/releases/agp-{major}-{minor}-0-release-notes"
        rows = table(read(url))
        minimum = {}
        for row in rows:
            if len(row) >= 2 and row[0] in ("Gradle", "JDK", "SDK Build Tools", "NDK"):
                minimum[row[0]] = row[1:]
        update.require("Gradle" in minimum and "JDK" in minimum,
                       "AGP 官方兼容表缺少 Gradle／JDK：" + agp)
        compatible_kotlins = [kotlin for kotlin in kotlins
                              if any(len(row) >= 3 and inside(kotlin, row[0]) and inside(agp, row[2]) for row in matrix)]
        for kotlin in compatible_kotlins:
            compatible = [row for row in matrix if len(row) >= 3 and inside(kotlin, row[0]) and inside(agp, row[2])]
            for gradle in gradles:
                value = gradle["version"]
                if (update.stable_version(value) < update.stable_version(versions(minimum["Gradle"][0])[0])
                        or not any(inside(value, row[1]) for row in compatible)):
                    excluded.append({"component": "gradle", "version": value, "agp": agp, "kotlin": kotlin,
                                     "reason": "不满足 AGP 最低版本或 KGP 官方 Gradle 范围"})
                    continue
                selected["agp"] = {"version": agp, "compatibilityUrl": url}
                selected["kotlin"] = {"version": kotlin, "compatibilityUrl": KOTLIN}
                selected["gradle"] = {"version": value, "sourceUrl": gradle["downloadUrl"],
                                      "sha256": read(gradle["checksumUrl"]).decode("ascii").strip()}
                break
            if "gradle" in selected:
                break
        if "gradle" in selected:
            break
        excluded.append({"component": "agp", "version": agp, "reason": "没有同时满足官方 KGP 与 Gradle 范围的组合"})
    update.require("gradle" in selected, "官方正式工具链没有可用的 AGP／Kotlin／Gradle 组合")
    java_matrix = table(read(GRADLE_COMPATIBILITY))
    releases = metadata("https://api.adoptium.net/v3/info/available_releases")
    java_minimum = int(re.search(r"\d+", minimum["JDK"][0])[0])
    for java in sorted((value for value in releases["available_releases"]
                        if value <= releases["most_recent_feature_release"]), reverse=True):
        if java < java_minimum:
            continue
        matching = [row for row in java_matrix if len(row) >= 3 and row[0] == str(java)]
        if not matching or not versions(matching[0][2]):
            excluded.append({"component": "java", "version": str(java), "reason": "Gradle 官方表未列为可运行的 Java 版本"})
            continue
        lower = versions(matching[0][2])[0]
        if update.stable_version(selected["gradle"]["version"]) < update.stable_version(lower):
            excluded.append({"component": "java", "version": str(java), "reason": "所选 Gradle 低于该 Java 的最低支持版本"})
            continue
        assets = metadata(f"https://api.adoptium.net/v3/assets/latest/{java}/hotspot?architecture=x64&image_type=jdk&os=linux&vendor=eclipse")
        package = assets[0]["binary"]["package"]
        selected["java"] = {"version": assets[0]["version"]["semver"], "sourceUrl": package["link"],
                            "sha256": package["checksum"], "bytes": package["size"]}
        break
    update.require("java" in selected, "所选 Gradle 没有受支持的官方 Java 正式版本")
    sdk = ET.fromstring(read(ANDROID))
    remote = []
    for package in sdk.findall("remotePackage"):
        channel = package.find("channelRef")
        if channel is not None and channel.get("ref") != "channel-0":
            continue
        revision = package.find("revision")
        if revision is None or revision.find("preview") is not None:
            continue
        for archive in package.findall("./archives/archive"):
            if archive.findtext("host-os", "linux") != "linux":
                continue
            complete = archive.find("complete")
            if complete is None:
                continue
            remote.append({"package": package.get("path"),
                           "revision": ".".join(revision.findtext(key, "0") for key in ("major", "minor", "micro")),
                           "sourceUrl": "https://dl.google.com/android/repository/" + complete.findtext("url"),
                           "bytes": int(complete.findtext("size")), "officialSha1": complete.findtext("checksum")})
    sdk_selected = {}
    for name, prefix in (("platform", "platforms;android-"), ("buildTools", "build-tools;"),
                         ("ndk", "ndk;"), ("commandTools", "cmdline-tools;"), ("platformTools", "platform-tools")):
        choices = [row for row in remote if row["package"].startswith(prefix)]
        if name == "platform":
            choices = [row for row in choices if re.fullmatch(r"platforms;android-\d+", row["package"])]
            # AGP 文档明确列出最大 API；缺少该字段时不推测支持范围。
            text = read(selected["agp"]["compatibilityUrl"]).decode("utf-8")
            match = re.search(r"maximum API level.{0,200}?supports is API level\s+(\d+)",
                              " ".join(re.sub(r"<[^>]+>", " ", text).split()), re.I)
            update.require(match is not None, "AGP 官方说明缺少最大 API level")
            choices = [row for row in choices if int(row["package"].split("-")[-1]) <= int(match[1])]
            choices.sort(key=lambda row: int(row["package"].split("-")[-1]), reverse=True)
        else:
            choices.sort(key=lambda row: update.stable_version(row["revision"]), reverse=True)
        update.require(choices, "Android 官方 stable 包缺失：" + name)
        sdk_selected[name] = choices[0]
    required_build_tools = versions(minimum.get("SDK Build Tools", [""])[0])
    update.require(required_build_tools, "AGP 官方说明缺少 SDK Build Tools 最低版本")
    required = next((row for row in remote if row["package"] == "build-tools;" + required_build_tools[0]), None)
    update.require(required is not None, "Android 官方 stable 包缺少 AGP 默认 Build Tools")
    if required["package"] != sdk_selected["buildTools"]["package"]:
        sdk_selected["compatibilityBuildTools"] = required
    selected["android"] = sdk_selected
    selected["actions"] = {}
    for name in ("checkout", "github-script", "upload-artifact"):
        source = "https://api.github.com/repos/actions/" + name
        release = metadata(source + "/releases/latest")
        tag = release.get("tag_name", "")
        update.require(not release.get("draft") and not release.get("prerelease")
                       and update.stable_version(tag), "Actions 必须选择官方正式 release")
        target = metadata(source + "/git/ref/tags/" + tag)["object"]
        for _ in range(8):
            if target["type"] != "tag":
                break
            target = metadata(source + "/git/tags/" + target["sha"])["object"]
        update.require(target["type"] == "commit" and re.fullmatch(r"[0-9a-f]{40}", target["sha"]),
                       "Actions tag 缺少固定 commit")
        selected["actions"]["actions/" + name] = {"version": tag, "commit": target["sha"]}
    licenses = {row.get("id"): row.text for row in sdk.findall("license") if row.get("id") and row.text}
    return {"format": "clash-pseudo-toolchains", "version": 1, "minSdk": 24,
            "latest": {"agp": agps[0], "kotlin": kotlins[0], "gradle": gradles[0]["version"],
                       "java": str(releases["most_recent_feature_release"])},
            "selected": selected, "excluded": excluded, "documents": documents,
            "androidLicenses": licenses,
            "androidLicenseInputs": {name: {"bytes": len(text.encode("utf-8")),
                                             "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
                                             "acceptanceSha1": android_license_hash(text)}
                                     for name, text in licenses.items()}}


def mutable_flutter_cache(name):
    return (name.startswith(("flutter/.pub-preload-cache/", "flutter/packages/flutter_tools/.dart_tool/",
                             "flutter/packages/flutter_tools/gradle/.gradle/", "flutter/packages/flutter_tools/gradle/build/"))
            or name.startswith("flutter/.git/") and name not in ("flutter/.git/HEAD", "flutter/.git/refs/heads/stable")
            or name in ("flutter/bin/cache/flutter_version_check.stamp", "flutter/bin/cache/lockfile"))


def installed_files(directory):
    """核对安装目录的文件、符号链接与执行权限。"""
    records = []
    for path in sorted(directory.rglob("*")):
        name = path.relative_to(directory).as_posix()
        if mutable_flutter_cache(name):
            continue
        if path.is_symlink():
            update.require(path.resolve().is_relative_to(directory.resolve()), "工具链符号链接超出安装目录")
            records.append({"path": name, "link": os.readlink(path)})
        elif path.is_file():
            with path.open("rb") as stream:
                checksum = hashlib.file_digest(stream, "sha256").hexdigest()
            records.append({"path": name, "bytes": path.stat().st_size, "sha256": checksum,
                            "executable": bool(path.stat().st_mode & 0o111)})
        else:
            update.require(path.is_dir(), "工具链包含不支持的文件类型")
    return records


def install_archive(row, destination, *, fetch=None):
    """下载与解包分别使用新空目录；只复用已核对的完成记录。"""
    fetch = fetch or update.fetch
    marker = destination / "receipt.json"
    if marker.is_file():
        receipt = json.loads(marker.read_bytes(), object_pairs_hook=update.unique_object)
        update.require(all(row.get(key) == value for key, value in receipt["input"].items())
                       and row.get("sha256", receipt["archive"]["sha256"]) == receipt["archive"]["sha256"],
                       "工具链缓存与固定输入不同")
        expected = {row["path"]: row for row in receipt.get("files", []) if not mutable_flutter_cache(row["path"])}
        actual = {row["path"]: row for row in installed_files(destination / "content")}
        def generated_metadata(name):
            if name.startswith("flutter/bin/cache/"):
                return True
            if row.get("package") and name.endswith("/package.xml"):
                document = ET.fromstring(update.read_resource(destination / "content" / name, 1024 * 1024))
                packages = [element for element in document.iter() if element.tag.split("}")[-1] == "localPackage"]
                return len(packages) == 1 and packages[0].get("path") == row["package"]
            return False
        update.require(expected and all(actual.get(name) == row for name, row in expected.items())
                       and all(generated_metadata(name) for name in actual.keys() - expected.keys()),
                       "工具链缓存文件发生变化")
        return destination / "content", receipt["archive"]
    update.require(not destination.exists(), "工具链缓存未完成，请使用新空目录：" + str(destination))
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="clash-toolchain-download-", dir=destination.parent) as downloaded, \
            tempfile.TemporaryDirectory(prefix="clash-toolchain-extract-", dir=destination.parent) as extracted:
        archive = Path(downloaded) / "archive"
        measured = fetch(row["sourceUrl"], limit=row.get("bytes", LIMIT), destination=archive)
        data_hash = measured["sha256"]
        update.require(row.get("sha256", data_hash) == data_hash, "工具链 SHA-256 不同")
        if "bytes" in row:
            update.require(measured["bytes"] == row["bytes"], "工具链下载大小不同")
        if "officialSha1" in row:
            with archive.open("rb") as stream:
                update.require(hashlib.file_digest(stream, "sha1").hexdigest() == row["officialSha1"], "Android 官方 SHA-1 不同")
        target = Path(extracted)
        if zipfile.is_zipfile(archive):
            with zipfile.ZipFile(archive) as contents:
                total = 0
                names = set()
                for member in contents.infolist():
                    path = Path(member.filename)
                    total += member.file_size
                    update.require(not path.is_absolute() and ".." not in path.parts
                                   and member.filename not in names and total <= 4 * LIMIT
                                   and member.file_size <= LIMIT, "工具链 ZIP 路径或大小无效")
                    names.add(member.filename)
                links = []
                for member in contents.infolist():
                    path = target / member.filename
                    mode = member.external_attr >> 16
                    kind = mode & 0o170000
                    update.require(kind in (0, 0o040000, 0o100000, 0o120000),
                                   "工具链 ZIP 包含不支持的文件类型")
                    if kind == 0o120000:
                        update.require(member.file_size <= 4096, "工具链 ZIP 符号链接过长")
                        link = contents.read(member).decode("utf-8")
                        update.require(link and not Path(link).is_absolute()
                                       and (path.parent / link).resolve().is_relative_to(target.resolve()),
                                       "工具链 ZIP 符号链接超出安装目录")
                        links.append((path, link))
                    elif member.is_dir():
                        path.mkdir(parents=True, exist_ok=True)
                    else:
                        path.parent.mkdir(parents=True, exist_ok=True)
                        with contents.open(member) as source, path.open("xb") as destination_file:
                            shutil.copyfileobj(source, destination_file, length=1024 * 1024)
                        path.chmod(0o755 if mode & 0o111 else 0o644)
                # 常规文件写入完成后再创建符号链接，禁止后续成员经由链接写出安装目录。
                for path, link in links:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.symlink_to(link)
                for path, _ in links:
                    update.require(path.resolve().is_relative_to(target.resolve()),
                                   "工具链 ZIP 符号链接超出安装目录")
        else:
            with tarfile.open(archive) as contents:
                total = 0
                for member in contents:
                    total += member.size
                    update.require(total <= 4 * LIMIT and member.size <= LIMIT, "工具链 TAR 展开大小超过上限")
                contents.extractall(target, filter="data")
        destination.mkdir()
        shutil.move(str(target), destination / "content")
        marker.write_bytes(update.json_bytes({"input": row, "archive": measured,
                                               "files": installed_files(destination / "content")}))
    return destination / "content", measured


def prepare(record, cache, root, *, fetch=None):
    update.require(record.get("format") == "clash-pseudo-toolchains"
                   and type(record.get("version")) is int and record["version"] == 1
                   and record.get("minSdk") == 24,
                   "固定工具链记录格式或 API24 约束无效")
    selected = record["selected"]
    cache = Path(cache).absolute()
    paths = {}
    measured = {}
    for name in ("flutter", "go", "java", "gradle"):
        row = selected[name]
        key = row["sha256"]
        update.require(isinstance(key, str) and re.fullmatch(r"[0-9a-f]{64}", key),
                       "固定工具链 SHA-256 无效：" + name)
        directory, measured[name] = install_archive(row, cache / name / key, fetch=fetch)
        folders = [child for child in directory.iterdir() if child.is_dir()]
        update.require(len(folders) == 1, "工具链 archive 的顶层目录数量无效：" + name)
        paths[name] = folders[0]
    sdk = cache / "android"
    sdk.mkdir(exist_ok=True)
    for name, row in selected["android"].items():
        key = row.get("officialSha1") or row["sha256"]
        update.require(isinstance(key, str) and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", key),
                       "固定 Android 工具链摘要无效：" + name)
        patterns = {"platform": r"platforms;android-\d+", "buildTools": r"build-tools;\d+\.\d+\.\d+",
                    "compatibilityBuildTools": r"build-tools;\d+\.\d+\.\d+", "ndk": r"ndk;\d+\.\d+\.\d+",
                    "commandTools": r"cmdline-tools;\d+(?:\.\d+)*", "platformTools": r"platform-tools"}
        update.require(name in patterns and isinstance(row.get("package"), str)
                       and re.fullmatch(patterns[name], row["package"]), "固定 Android package 路径无效：" + name)
        # 旧 NDK cache 将 ZIP 中的 Unix 符号链接写成文本；新目录重新核对官方 archive 后安装。
        if name == "ndk":
            key += "-unix-links-v1"
        directory, measured["android." + name] = install_archive(row, cache / "android-packages" / key, fetch=fetch)
        entries = list(directory.iterdir())
        update.require(len(entries) == 1 and entries[0].is_dir(), "Android archive 顶层目录无效：" + name)
        target = sdk / row["package"].replace(";", "/")
        if target.is_symlink():
            update.require(target.resolve().is_relative_to(cache / "android-packages"),
                           "Android SDK 符号链接不属于工具链 cache")
        else:
            update.require(not target.exists(), "Android SDK 路径不是工具链符号链接")
        if not target.is_symlink() or target.resolve() != entries[0].resolve():
            target.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix=".sdk-link-", dir=target.parent) as temporary:
                replacement = Path(temporary) / "package"
                replacement.symlink_to(entries[0], target_is_directory=True)
                os.replace(replacement, target)
    ndk = sdk / selected["android"]["ndk"]["package"].replace(";", "/")
    platforms = json.loads((ndk / "meta/platforms.json").read_bytes())
    update.require(platforms["min"] <= 24 <= platforms["max"], "所选 NDK 不支持 API24")
    environment = {"JAVA_HOME": str(paths["java"]), "ANDROID_HOME": str(sdk), "ANDROID_SDK_ROOT": str(sdk),
                   "CLASH_GRADLE": str(paths["gradle"] / "bin/gradle"),
                   "PATH": os.pathsep.join((str(paths["flutter"] / "bin"), str(paths["go"] / "bin"),
                                            str(paths["java"] / "bin"), str(sdk / "platform-tools"), os.environ.get("PATH", os.defpath))),
                   "GOTOOLCHAIN": "local"}
    licenses = sdk / "licenses"
    licenses.mkdir(exist_ok=True)
    for name, text in record["androidLicenses"].items():
        update.require(re.fullmatch(r"[A-Za-z0-9_.-]+", name), "Android SDK license 名称无效")
        (licenses / name).write_text(android_license_hash(text) + "\n", encoding="ascii")
    # local.properties 不属于分发输入；只在固定工具链准备完成后写入。
    properties = root / "android/local.properties"
    properties.write_text(f"sdk.dir={sdk}\nflutter.sdk={paths['flutter']}\n", encoding="utf-8")
    return environment, measured


def freeze_archives(record, measured):
    """将官方 archive 的实际大小与 SHA-256 保存到同次 release 输入。"""
    for name in ("flutter", "go", "java", "gradle"):
        record["selected"][name].update(measured[name])
    for name, row in record["selected"]["android"].items():
        row.update(measured["android." + name])


def apply_versions(root, record):
    selected = record["selected"]
    settings = root / "android/settings.gradle.kts"
    text = settings.read_text(encoding="utf-8")
    for plugin, component in (("com.android.application", "agp"), ("org.jetbrains.kotlin.android", "kotlin")):
        text, count = re.subn(r'(id\("' + re.escape(plugin) + r'"\) version ")[^"]+(" apply false)',
                              lambda match: match[1] + selected[component]["version"] + match[2], text)
        update.require(count == 1, "Gradle plugin 声明缺失或重复：" + plugin)
    settings.write_text(text, encoding="utf-8")
    wrapper = root / "android/gradle/wrapper/gradle-wrapper.properties"
    text = wrapper.read_text(encoding="utf-8")
    text, count = re.subn(r"(?m)^distributionUrl=.*$",
                          lambda _: "distributionUrl=" + selected["gradle"]["sourceUrl"].replace(":", r"\:"), text)
    update.require(count == 1, "Gradle wrapper distributionUrl 缺失或重复")
    text = re.sub(r"(?m)^distributionSha256Sum=.*\n?", "", text)
    wrapper.write_text(text.rstrip() + "\ndistributionSha256Sum=" + selected["gradle"]["sha256"] + "\n", encoding="utf-8")
    application = root / "android/app/build.gradle.kts"
    text = application.read_text(encoding="utf-8")
    android = selected["android"]
    api = android["platform"]["package"].split("-")[-1]
    replacements = {
        "compileSdk": api, "targetSdk": api,
        "ndkVersion": json.dumps(android["ndk"]["package"].split(";")[1]),
    }
    for name, value in replacements.items():
        text, count = re.subn(r"(?m)^(\s*" + name + r"\s*=\s*)[^\n]+$",
                              lambda match: match[1] + value, text)
        update.require(count == 1, "Android 工具链声明缺失或重复：" + name)
    build_tools = json.dumps(android["buildTools"]["package"].split(";")[1])
    if re.search(r"(?m)^\s*buildToolsVersion\s*=", text):
        text = re.sub(r"(?m)^(\s*buildToolsVersion\s*=\s*)[^\n]+$",
                      lambda match: match[1] + build_tools, text)
    else:
        text = text.replace("android {\n", "android {\n    buildToolsVersion = " + build_tools + "\n", 1)
    application.write_text(text, encoding="utf-8")
    if selected.get("actions"):
        workflow = root / ".github/workflows/update-dependencies.yml"
        text = workflow.read_text(encoding="utf-8")
        for name, action in selected["actions"].items():
            text, count = re.subn(r"(?m)(uses:\s*" + re.escape(name) + r"@)[^\s]+(?:[^\n]*)",
                                  lambda match: match[1] + action["commit"] + " # " + action["version"], text)
            update.require(count == 1, "Actions 引用缺失或重复：" + name)
        workflow.write_text(text, encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--resolve", action="store_true", help="显式 release 更新时查询官方 stable")
    parser.add_argument("--record", type=Path, help="解析结果输出或固定输入；默认读取 resources.json 的 toolchains")
    parser.add_argument("--cache", type=Path, default=Path.home() / ".cache/clash-pseudo/toolchains")
    parser.add_argument("--environment", type=Path, help="保存实际工具路径，使用该文件更新后续命令环境")
    args = parser.parse_args(argv)
    if args.resolve:
        parser.error("官方工具链解析由 update.py --apply 的 release 更新事务执行")
    record = (json.loads(args.record.read_bytes()) if args.record else update.read_release_resources(args.project)["toolchains"])
    environment, measured = prepare(record, args.cache, args.project.resolve())
    if args.environment:
        args.environment.write_bytes(update.json_bytes({"environment": environment, "archives": measured}))
    if os.environ.get("GITHUB_PATH"):
        with open(os.environ["GITHUB_PATH"], "a", encoding="utf-8") as output:
            output.write("\n".join(environment["PATH"].split(os.pathsep)[:4]) + "\n")
    if os.environ.get("GITHUB_ENV"):
        with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as output:
            for key, value in environment.items():
                if key != "PATH":
                    output.write(key + "=" + value + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
