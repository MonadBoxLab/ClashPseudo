#!/usr/bin/env python3
"""打包当前应用及实际解析依赖的对应源码，供 APK 同步分发。"""

import argparse
import gzip
import importlib.util
import io
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import tempfile
from urllib.parse import unquote, urljoin, urlparse
import urllib.error
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("dependency_update", ROOT / "tool/dependencies/update.py")
update = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update)


def add_bytes(archive, name, data, executable=False):
    path = PurePosixPath(name)
    update.require(not path.is_absolute() and ".." not in path.parts, "源码归档路径无效：" + name)
    info = tarfile.TarInfo(path.as_posix())
    info.size = len(data)
    info.mode = 0o755 if executable else 0o644
    info.mtime = 0
    archive.addfile(info, io.BytesIO(data))


def add_directory(archive, directory, prefix):
    for path in sorted(directory.rglob("*")):
        update.require(not path.is_symlink(), "源码目录包含符号链接：" + str(path))
        if path.is_file():
            add_bytes(archive, prefix + "/" + path.relative_to(directory).as_posix(),
                      path.read_bytes(), bool(path.stat().st_mode & 0o111))


def maven_sources(coordinate):
    group, name, version = coordinate.split(":")
    relative = f"{group.replace('.', '/')}/{name}/{version}/{name}-{version}"
    for repository in update.MAVEN:
        try:
            pom = update.fetch(repository + "/" + relative + ".pom")
            break
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
    else:
        raise ValueError("Maven POM 缺失：" + coordinate)
    files = {name + "-" + version + ".pom": pom}
    tree = ET.fromstring(pom)
    packaging = tree.findtext("{http://maven.apache.org/POM/4.0.0}packaging", default="jar")
    if packaging != "pom":
        files[name + "-" + version + "-sources.jar"] = update.fetch(repository + "/" + relative + "-sources.jar")
    return files


def check_private_inputs(names):
    for name in names:
        path = PurePosixPath(name)
        update.require(path.suffix.lower() not in (".jks", ".keystore")
                       and path.name not in ("key.properties", "local.properties"),
                       "源码分发发现私有构建材料：" + name)


def application_tar(root, output, commit):
    if commit:
        update.run(["git", "diff", "--exit-code", commit, "--"], root)
        entries = update.run(["git", "ls-tree", "-r", "--name-only", "-z", commit], root)
        check_private_inputs(filter(None, entries.split("\0")))
        update.run(["git", "archive", "--format=tar", "--output", output, commit], root)
        return
    with tempfile.TemporaryDirectory(prefix="clash-source-tree-") as temporary:
        work = Path(temporary) / "application"
        work.mkdir()
        update.copy_workspace(root, work)
        # copy_workspace 同时承接构建现场的 SDK 位置；分发包只包含正式输入。
        properties = work / "android/local.properties"
        if properties.exists():
            properties.unlink()
        check_private_inputs(path.relative_to(work).as_posix() for path in work.rglob("*") if path.is_file())
        with tarfile.open(output, "w") as archive:
            add_directory(archive, work, "application")


def create(updater, evidence, output, commit=None):
    root = updater.root
    update.require(not output.exists(), "对应源码输出路径已存在：" + str(output))
    modules = update.artifacts.go_modules(evidence / "go-modules.json")
    coordinates = update.artifacts.android_coordinates((evidence / "android-dependencies.txt").read_text(encoding="utf-8"))
    version = update.application_version(root)
    current = update.run(["git", "rev-parse", "HEAD"], root).strip()
    if commit:
        commit = update.run(["git", "rev-parse", commit + "^{commit}"], root).strip()
    with tempfile.TemporaryDirectory(prefix="clash-source-package-") as temporary:
        app_tar = Path(temporary) / "application.tar"
        application_tar(root, app_tar, commit)
        try:
            with output.open("xb") as stream, gzip.GzipFile(fileobj=stream, mode="wb", mtime=0) as compressed, \
                    tarfile.open(fileobj=compressed, mode="w|") as archive:
                add_bytes(archive, "application.tar", app_tar.read_bytes())
                production = updater.legal(Path(temporary)).production_modules()
                for original in sorted(production):
                    module = modules[original]
                    if module.get("Main"):
                        continue
                    effective = module.get("Replace") or module
                    name, selected = effective["Path"], effective["Version"]
                    metadata = json.loads(updater.go_run("mod", "download", "-json", name + "@" + selected))
                    update.require(metadata.get("Sum") == effective.get("Sum"), "Go 源码与解析校验不同：" + name)
                    data = Path(metadata["Zip"]).read_bytes()
                    add_bytes(archive, f"dependencies/go/{name}@{selected}.zip", data)
                configuration = root / ".dart_tool/package_config.json"
                packages = json.loads(configuration.read_text(encoding="utf-8"))["packages"]
                resolved = json.loads(update.run([updater.flutter, "pub", "deps", "--json"], root))
                hosted = {row["name"]: row["version"] for row in resolved["packages"] if row.get("source") == "hosted"}
                for package in packages:
                    if package["name"] not in hosted:
                        continue
                    uri = urlparse(urljoin(configuration.as_uri(), package["rootUri"]))
                    update.require(uri.scheme == "file", "Pub 源码路径无效")
                    add_directory(archive, Path(unquote(uri.path)),
                                  f"dependencies/pub/{package['name']}-{hosted[package['name']]}")
                for coordinate in sorted(coordinates):
                    for name, data in maven_sources(coordinate).items():
                        add_bytes(archive, "dependencies/android/" + coordinate.replace(":", "/") + "/" + name, data)
                for name in ("go-modules.json", "android-dependencies.txt", "NOTICES"):
                    add_bytes(archive, "build-inputs/" + name, (evidence / name).read_bytes())
                toolchain = {
                    "application": version,
                    "commit": commit or current,
                    "workingTree": commit is None,
                    "flutter": json.loads(update.run([updater.flutter, "--version", "--machine"], root)),
                    "go": updater.go_run("version").strip(),
                }
                add_bytes(archive, "build-inputs/version.json", json.dumps(toolchain, ensure_ascii=False, indent=2).encode())
                add_bytes(archive, "README.txt", (
                    "Clash Pseudo 对应源码\n\n"
                    f"应用版本：{version}\n源码提交：{commit or current}\n"
                    + ("应用源码取当前工作树快照。\n" if commit is None else "应用源码取所标识 Git 提交。\n")
                    + "\n先解开 application.tar；固定提交模式在当前目录恢复项目，工作树模式在 application/ 恢复项目。\n"
                    "构建入口见项目 doc/development/build-and-test.md，工具链修订见 build-inputs/version.json。\n"
                    "使用标准 Flutter／Go／Gradle 入口按锁文件构建。dependencies/ 提供固定版本的第三方源码，\n"
                    "Go 原始 zip、Pub 已解析源码和 Maven sources.jar／POM 保留各自许可与版权。\n"
                    "SDK、构建工具及 Android 系统组件按构建说明取得。应用补丁、生成输入、原始通知和 GPLv3\n"
                    "正文随 application.tar 提供，依赖与分发关系见项目 NOTICE.md。\n"
                ).encode())
        except BaseException:
            if output.exists():
                output.unlink()
            raise
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--commit", help="已检查的 Git 提交；省略时打包当前工作树")
    parser.add_argument("--go", default="go")
    parser.add_argument("--flutter", default="flutter")
    args = parser.parse_args(argv)
    try:
        create(update.Updater(args.project.resolve(), args.go, args.flutter), args.evidence.resolve(),
               args.output.resolve(), args.commit)
    except (OSError, ValueError, KeyError, ET.ParseError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
