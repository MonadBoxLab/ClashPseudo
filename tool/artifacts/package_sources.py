#!/usr/bin/env python3
"""打包当前应用及实际解析依赖的对应源码，供 APK 同步分发。"""

import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import tempfile
from urllib.parse import unquote, urljoin, urlparse
import urllib.error
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
from tool.common.io import fetch, require, json_bytes, read_resource
from tool.common.process import run
from tool.common.workspace import (public_test_material, excluded_source_path, check_private_inputs,
                                   working_tree_names, source_file, file_record, check_working_tree)
from tool.dependencies.packages import Updater, MAVEN
from tool.dependencies.versions import application_version
from tool.dependencies.resources import (read_release_resources, GENERATED_BUNDLED,
    read_resource_sources, check_resource_source_selection, resource_source_entries)
from tool.artifacts import verify_release_licenses as artifacts


def add_bytes(archive, name, data, executable=False):
    path = PurePosixPath(name)
    require(not path.is_absolute() and ".." not in path.parts, "源码归档路径无效：" + name)
    info = tarfile.TarInfo(path.as_posix())
    info.size = len(data)
    info.mode = 0o755 if executable else 0o644
    info.mtime = 0
    archive.addfile(info, io.BytesIO(data))


def add_directory(archive, directory, prefix):
    for path in sorted(directory.rglob("*")):
        require(not path.is_symlink(), "源码目录包含符号链接：" + str(path))
        if path.is_file():
            add_bytes(archive, prefix + "/" + path.relative_to(directory).as_posix(),
                      path.read_bytes(), bool(path.stat().st_mode & 0o111))


def maven_sources(coordinate):
    group, name, version = coordinate.split(":")
    relative = f"{group.replace('.', '/')}/{name}/{version}/{name}-{version}"
    for repository in MAVEN:
        try:
            pom = fetch(repository + "/" + relative + ".pom")
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
        files[name + "-" + version + "-sources.jar"] = fetch(repository + "/" + relative + "-sources.jar")
    return files
















def output_identity(status):
    return status.st_dev, status.st_ino


def remove_owned_output(path, identity):
    # 失败时按设备号和inode识别并删除本次输出文件；输出路径已被替换时保留替换文件。
    try:
        current = path.lstat()
    except FileNotFoundError:
        return
    if output_identity(current) == identity:
        path.unlink()


def application_tar(root, output, commit):
    require(not output.exists(), "应用源码输出路径已存在：" + str(output))
    if commit:
        run(["git", "diff", "--exit-code", commit, "--"], root)
        require(not run(["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"], root),
                       "提交模式要求干净工作树；当前源码请使用 workingTree 模式")
        entries = run(["git", "ls-tree", "-r", "--name-only", "-z", commit], root)
        check_private_inputs(filter(None, entries.split("\0")))
        run(["git", "archive", "--format=tar", "--output", output, commit], root)
        files = None
        status = ""
    else:
        status = run(["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"], root)
        names = working_tree_names(root)
        files = []
        owned = None
        try:
            with output.open("xb") as stream:
                owned = output_identity(os.fstat(stream.fileno()))
                with tarfile.open(fileobj=stream, mode="w") as archive:
                    for name in names:
                        path = source_file(root, name)
                        if path is None:
                            continue
                        data = path.read_bytes()
                        executable = bool(path.stat().st_mode & 0o111)
                        add_bytes(archive, "application/" + name, data, executable)
                        files.append(file_record(name, data, executable))
            check_working_tree(root, {"_status": status, "files": files})
            require(output_identity(output.lstat()) == owned, "归档输出文件已被替换")
        except BaseException:
            if owned is not None:
                remove_owned_output(output, owned)
            raise
    with output.open("rb") as stream:
        checksum = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"workingTree": commit is None, "dirty": bool(status), "_status": status,
            "applicationTar": {"bytes": output.stat().st_size, "sha256": checksum}, "files": files}


def add_resource_sources(archive, root, manifest_path):
    """将 release 记录对应的可编辑资源源码与补充输入纳入分发。"""
    metadata = read_resource_sources(manifest_path.parent)
    check_resource_source_selection(root, metadata)
    for kind, source in resource_source_entries(metadata):
        add_bytes(archive, "dependencies/data/" + kind + "/" + source["file"],
                  read_resource(manifest_path.parent / source["file"], source["bytes"]))
    add_bytes(archive, "build-inputs/resource-sources.json", manifest_path.read_bytes())


def create(updater, evidence, output, commit=None, resource_sources=None, release_inputs=None):
    root = updater.root
    record = read_release_resources(root, release_inputs)
    generated = root / GENERATED_BUNDLED
    require(not output.exists(), "对应源码输出路径已存在：" + str(output))
    modules = artifacts.go_modules(evidence / "go-modules.json")
    coordinates = artifacts.android_coordinates((evidence / "android-dependencies.txt").read_text(encoding="utf-8"))
    version = application_version(root)
    current = run(["git", "rev-parse", "HEAD"], root).strip()
    if commit:
        commit = run(["git", "rev-parse", commit + "^{commit}"], root).strip()
    with tempfile.TemporaryDirectory(prefix="clash-source-package-") as temporary:
        app_tar = Path(temporary) / "application.tar"
        identity = application_tar(root, app_tar, commit)
        owned = None
        try:
            stream = output.open("xb")
            owned = output_identity(os.fstat(stream.fileno()))
            with stream, gzip.GzipFile(filename="", fileobj=stream, mode="wb", mtime=0) as compressed, \
                    tarfile.open(fileobj=compressed, mode="w|") as archive:
                add_bytes(archive, "application.tar", app_tar.read_bytes())
                add_resource_sources(archive, root, resource_sources or evidence / "resource-sources.json")
                add_directory(archive, generated, "build-inputs/bundled")
                add_bytes(archive, "build-inputs/resources.json", json_bytes(record))
                add_bytes(archive, "build-inputs/certificates.json", (generated / "certificates.json").read_bytes())
                add_bytes(archive, "build-inputs/geodata.json", (generated / "assets/geodata/manifest.json").read_bytes())
                production = updater.legal(Path(temporary)).production_modules()
                for original in sorted(production):
                    module = modules[original]
                    if module.get("Main"):
                        continue
                    effective = module.get("Replace") or module
                    name, selected = effective["Path"], effective["Version"]
                    metadata = json.loads(updater.go_run("mod", "download", "-json", name + "@" + selected))
                    data = Path(metadata["Zip"]).read_bytes()
                    if original == "golang.org/x/net":
                        psl = artifacts.check_public_suffix(root, module, io.BytesIO(data))
                        add_bytes(archive, "build-inputs/publicsuffix.json",
                                  json.dumps(psl, ensure_ascii=False, indent=2).encode())
                    add_bytes(archive, f"dependencies/go/{name}@{selected}.zip", data)
                configuration = root / ".dart_tool/package_config.json"
                packages = json.loads(configuration.read_text(encoding="utf-8"))["packages"]
                resolved = json.loads(updater.run([updater.flutter, "pub", "deps", "--json"], root))
                hosted = {row["name"]: row["version"] for row in resolved["packages"] if row.get("source") == "hosted"}
                for package in packages:
                    if package["name"] not in hosted:
                        continue
                    uri = urlparse(urljoin(configuration.as_uri(), package["rootUri"]))
                    require(uri.scheme == "file", "Pub 源码路径无效")
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
                    "workingTree": identity["workingTree"],
                    "dirty": identity["dirty"],
                    "applicationTar": identity["applicationTar"],
                    "flutter": json.loads(updater.run([updater.flutter, "--version", "--machine"], root)),
                    "go": updater.go_run("version").strip(),
                }
                source_identity = {key: value for key, value in identity.items() if key != "_status"}
                source_identity.update(format="clash-pseudo-source-tree", version=1, baseCommit=commit or current)
                add_bytes(archive, "build-inputs/source-tree.json",
                          json.dumps(source_identity, ensure_ascii=False, indent=2).encode())
                add_bytes(archive, "build-inputs/version.json", json.dumps(toolchain, ensure_ascii=False, indent=2).encode())
                add_bytes(archive, "README.txt", (
                    "Clash Pseudo 对应源码\n\n"
                    f"应用版本：{version}\n基准提交：{commit or current}\n"
                    + ("应用源码：当前工作树快照\n" if commit is None else "应用源码：上述Git提交\n")
                    + f"workingTree={identity['workingTree']}, dirty={identity['dirty']}\n"
                    + f"application.tar SHA-256：{identity['applicationTar']['sha256']}\n"
                    + "\n一、核对材料\n"
                    "按分发的SHA256SUMS核对源码包，按上述摘要核对application.tar。\n"
                    "build-inputs/source-tree.json记录文件清单、大小、SHA-256和可执行位；\n"
                    "build-inputs/version.json记录应用版本及Flutter／Go工具链。\n"
                    "\n二、恢复应用源码\n"
                    "在新的源码目录恢复 application.tar：\n"
                    + ("  tar -xf application.tar\n" if commit is None else
                       "  mkdir application\n  tar -xf application.tar -C application\n")
                    + "  cd application\n"
                    + "以下命令在恢复后的项目根目录运行。\n"
                    "\n三、构建APK\n"
                    "按doc/development/build-and-test.md安装固定工具链，并通过四个分发签名环境变量提供签名，\n"
                    "再运行：\n"
                    "  python3 -I -B tool/main.py dependencies prepare-build --offline --payload-directory ../build-inputs/bundled/assets\n"
                    "  flutter pub get --enforce-lockfile\n"
                    "  python3 -I -B tool/main.py contracts check\n"
                    f"  mkdir ../clash-pseudo-{version}-apks\n"
                    "  flutter build apk --release --no-pub --target-platform android-arm,android-arm64,android-x64 --split-per-abi\n"
                    f"  cp build/app/outputs/apk/release/app-universal-release.apk ../clash-pseudo-{version}-apks/clash-pseudo-{version}-universal.apk\n"
                    f"  cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk ../clash-pseudo-{version}-apks/clash-pseudo-{version}-arm64-v8a.apk\n"
                    f"  cp build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk ../clash-pseudo-{version}-apks/clash-pseudo-{version}-armeabi-v7a.apk\n"
                    f"  cp build/app/outputs/flutter-apk/app-x86_64-release.apk ../clash-pseudo-{version}-apks/clash-pseudo-{version}-x86_64.apk\n"
                    f"四个APK保存在../clash-pseudo-{version}-apks/。\n"
                    "\n四、查阅依赖和许可\n"
                    "dependencies/go/ 保存所选 Go 模块的原始 ZIP 文件，dependencies/pub/ 保存已解析的 Pub 托管包源码，\n"
                    "dependencies/android/ 保存 Maven sources.jar 和 POM，dependencies/data/ 保存固定版本的数据资源源码归档。\n"
                    "build-inputs/ 保存依赖解析结果、NOTICES、资源清单和来源清单。\n"
                    "应用补丁、生成输入、通知与GPLv3正文位于application.tar；依赖与分发关系见项目NOTICE.md。\n"
                ).encode())
            require(run(["git", "rev-parse", "HEAD"], root).strip() == current,
                           "归档期间基准提交发生变化；确定源码提交后，使用新的输出路径重试")
            if commit is None:
                check_working_tree(root, identity)
            require(output_identity(output.lstat()) == owned, "归档输出文件已被替换")
        except BaseException:
            if owned is not None:
                remove_owned_output(output, owned)
            raise
    return output




def register_parser(subparsers):
    parser = subparsers.add_parser("package-sources", help="打包当前应用与依赖对应源码", description=__doc__)
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--commit", help="归档指定 Git 提交，要求工作树干净；省略时归档当前文件")
    parser.add_argument("--release-inputs", type=Path, help="固定资源记录路径")
    parser.add_argument("--resource-sources", type=Path, help="resource-sources.json 路径，默认读取 evidence 目录")
    parser.add_argument("--go", default="go")
    parser.add_argument("--flutter", default="flutter")
    parser.set_defaults(handler=package, command_parser=parser)
    return parser


def package(args):
    output = create(Updater(args.project.resolve(), args.go, args.flutter), args.evidence.resolve(),
                    args.output.resolve(), args.commit, args.resource_sources, args.release_inputs)
    return {"status": "packaged", "output": str(output)}
