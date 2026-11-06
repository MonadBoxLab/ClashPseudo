"""按项目固定记录安装工具链，并准备构建环境。"""

import hashlib
import json
import logging
import os
import time
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import tempfile
import zipfile
import xml.etree.ElementTree as ET

from tool.common.io import fetch as download, require, read_resource, json_bytes, unique_object

LIMIT = 4 * 1024 * 1024 * 1024


def android_license_hash(text):
    # Android SDK 的 TrimStringAdapter 保留空行，合并段内换行与连续空白。
    text = re.sub(r"(?<=[ \t\n\x0b\f\r])[ \t]*", "", text)
    text = re.sub(r"(?<!\n)\n(?!\n)", " ", text)
    return hashlib.sha1(re.sub(r" +", " ", text).strip().encode("utf-8")).hexdigest()


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
            require(path.resolve().is_relative_to(directory.resolve()), "工具链符号链接超出安装目录")
            records.append({"path": name, "link": os.readlink(path)})
        elif path.is_file():
            with path.open("rb") as stream:
                checksum = hashlib.file_digest(stream, "sha256").hexdigest()
            records.append({"path": name, "bytes": path.stat().st_size, "sha256": checksum,
                            "executable": bool(path.stat().st_mode & 0o111)})
        else:
            require(path.is_dir(), "工具链包含不支持的文件类型")
    return records


def install_archive(row, destination, *, fetch=None):
    """下载与解包分别使用新空目录；只复用已核对的完成记录。"""
    fetch = fetch or download
    started = time.monotonic()
    label = row.get("package") or destination.parent.name
    marker = destination / "receipt.json"
    if marker.is_file():
        logging.info("核对工具链缓存：%s", label)
        receipt = json.loads(marker.read_bytes(), object_pairs_hook=unique_object)
        require(all(row.get(key) == value for key, value in receipt["input"].items())
                       and row.get("sha256", receipt["archive"]["sha256"]) == receipt["archive"]["sha256"],
                       "工具链缓存与固定输入不同")
        expected = {row["path"]: row for row in receipt.get("files", []) if not mutable_flutter_cache(row["path"])}
        actual = {row["path"]: row for row in installed_files(destination / "content")}
        def generated_metadata(name):
            if name.startswith("flutter/bin/cache/"):
                return True
            if row.get("package") and name.endswith("/package.xml"):
                document = ET.fromstring(read_resource(destination / "content" / name, 1024 * 1024))
                packages = [element for element in document.iter() if element.tag.split("}")[-1] == "localPackage"]
                return len(packages) == 1 and packages[0].get("path") == row["package"]
            return False
        require(expected and all(actual.get(name) == row for name, row in expected.items())
                       and all(generated_metadata(name) for name in actual.keys() - expected.keys()),
                       "工具链缓存文件发生变化")
        logging.info("工具链缓存可用：%s，耗时 %.1f 秒", label, time.monotonic() - started)
        return destination / "content", receipt["archive"]
    require(not destination.exists(), "工具链缓存未完成，请使用新空目录：" + str(destination))
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="clash-toolchain-download-", dir=destination.parent) as downloaded, \
            tempfile.TemporaryDirectory(prefix="clash-toolchain-extract-", dir=destination.parent) as extracted:
        archive = Path(downloaded) / "archive"
        measured = fetch(row["sourceUrl"], limit=row.get("bytes", LIMIT), destination=archive)
        data_hash = measured["sha256"]
        require(row.get("sha256", data_hash) == data_hash, "工具链 SHA-256 不同")
        if "bytes" in row:
            require(measured["bytes"] == row["bytes"], "工具链下载大小不同")
        if "officialSha1" in row:
            with archive.open("rb") as stream:
                require(hashlib.file_digest(stream, "sha1").hexdigest() == row["officialSha1"], "Android 官方 SHA-1 不同")
        logging.info("解包工具链：%s", label)
        target = Path(extracted)
        if zipfile.is_zipfile(archive):
            with zipfile.ZipFile(archive) as contents:
                total = 0
                names = set()
                for member in contents.infolist():
                    path = Path(member.filename)
                    total += member.file_size
                    require(not path.is_absolute() and ".." not in path.parts
                                   and member.filename not in names and total <= 4 * LIMIT
                                   and member.file_size <= LIMIT, "工具链 ZIP 路径或大小无效")
                    names.add(member.filename)
                links = []
                for member in contents.infolist():
                    path = target / member.filename
                    mode = member.external_attr >> 16
                    kind = mode & 0o170000
                    require(kind in (0, 0o040000, 0o100000, 0o120000),
                                   "工具链 ZIP 包含不支持的文件类型")
                    if kind == 0o120000:
                        require(member.file_size <= 4096, "工具链 ZIP 符号链接过长")
                        link = contents.read(member).decode("utf-8")
                        require(link and not Path(link).is_absolute()
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
                    require(path.resolve().is_relative_to(target.resolve()),
                                   "工具链 ZIP 符号链接超出安装目录")
        else:
            with tarfile.open(archive) as contents:
                total = 0
                for member in contents:
                    total += member.size
                    require(total <= 4 * LIMIT and member.size <= LIMIT, "工具链 TAR 展开大小超过上限")
                contents.extractall(target, filter="data")
        destination.mkdir()
        shutil.move(str(target), destination / "content")
        marker.write_bytes(json_bytes({"input": row, "archive": measured,
                                               "files": installed_files(destination / "content")}))
    logging.info("工具链安装完成：%s，耗时 %.1f 秒", label, time.monotonic() - started)
    return destination / "content", measured


def prepare(record, cache, root, *, fetch=None):
    require(record.get("format") == "clash-pseudo-toolchains"
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
        require(isinstance(key, str) and re.fullmatch(r"[0-9a-f]{64}", key),
                       "固定工具链 SHA-256 无效：" + name)
        directory, measured[name] = install_archive(row, cache / name / key, fetch=fetch)
        folders = [child for child in directory.iterdir() if child.is_dir()]
        require(len(folders) == 1, "工具链 archive 的顶层目录数量无效：" + name)
        paths[name] = folders[0]
    sdk = cache / "android"
    sdk.mkdir(exist_ok=True)
    for name, row in selected["android"].items():
        key = row.get("officialSha1") or row["sha256"]
        require(isinstance(key, str) and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", key),
                       "固定 Android 工具链摘要无效：" + name)
        package = PurePosixPath(row["package"].replace(";", "/"))
        require(not package.is_absolute() and ".." not in package.parts and "\\" not in str(package),
                "Android package 路径超出 SDK 目录：" + str(package))
        # 旧 NDK cache 将 ZIP 中的 Unix 符号链接写成文本；新目录重新核对官方 archive 后安装。
        if name == "ndk":
            key += "-unix-links-v1"
        directory, measured["android." + name] = install_archive(row, cache / "android-packages" / key, fetch=fetch)
        entries = list(directory.iterdir())
        require(len(entries) == 1 and entries[0].is_dir(), "Android archive 顶层目录无效：" + name)
        target = sdk / row["package"].replace(";", "/")
        if target.is_symlink():
            require(target.resolve().is_relative_to(cache / "android-packages"),
                           "Android SDK 符号链接不属于工具链 cache")
        else:
            require(not target.exists(), "Android SDK 路径不是工具链符号链接")
        if not target.is_symlink() or target.resolve() != entries[0].resolve():
            target.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix=".sdk-link-", dir=target.parent) as temporary:
                replacement = Path(temporary) / "package"
                replacement.symlink_to(entries[0], target_is_directory=True)
                os.replace(replacement, target)
    ndk = sdk / selected["android"]["ndk"]["package"].replace(";", "/")
    platforms = json.loads((ndk / "meta/platforms.json").read_bytes())
    require(platforms["min"] <= 24 <= platforms["max"], "所选 NDK 不支持 API24")
    environment = {"JAVA_HOME": str(paths["java"]), "ANDROID_HOME": str(sdk), "ANDROID_SDK_ROOT": str(sdk),
                   "CLASH_GRADLE": str(paths["gradle"] / "bin/gradle"),
                   "PATH": os.pathsep.join((str(paths["flutter"] / "bin"), str(paths["go"] / "bin"),
                                            str(paths["java"] / "bin"), str(sdk / "platform-tools"), os.environ.get("PATH", os.defpath))),
                   "GOTOOLCHAIN": "local"}
    licenses = sdk / "licenses"
    licenses.mkdir(exist_ok=True)
    for name, text in record["androidLicenses"].items():
        require(re.fullmatch(r"[A-Za-z0-9_.-]+", name), "Android SDK license 名称无效")
        (licenses / name).write_text(android_license_hash(text) + "\n", encoding="ascii")
    # local.properties 不属于分发输入；只在固定工具链准备完成后写入。
    properties = root / "android/local.properties"
    properties.write_text(f"sdk.dir={sdk}\nflutter.sdk={paths['flutter']}\n", encoding="utf-8")
    return environment, measured
