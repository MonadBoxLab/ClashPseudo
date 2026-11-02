#!/usr/bin/env python3
"""打包当前应用及实际解析依赖的对应源码，供 APK 同步分发。"""

import argparse
import gzip
import hashlib
import importlib.util
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


def public_test_material(path):
    # 保留测试目录中的公开合成证书、私钥和keystore文件。
    return (path.parts[0] in ("test", "tests", "testdata")
            or "testdata" in path.parts
            or any(path.parts[index:index + 2] in (("src", "test"), ("src", "androidTest"))
                   for index in range(len(path.parts) - 1)))


def excluded_source_path(name):
    path = PurePosixPath(name)
    update.require(path.parts and not path.is_absolute() and ".." not in path.parts,
                   "Git 文件路径无效")
    if any(part in (".git", ".claude", ".codegraph", "__pycache__") for part in path.parts):
        return True
    if path.parts[0] in (".dart_tool", ".gradle", ".idea", ".vscode", ".local", ".android", "build", "coverage",
                         "dist", "artifacts", "backups", "backup", "device-backups", "secrets", "signing",
                         ".ssh", ".aws", ".azure", ".docker", ".kube", ".gnupg"):
        return True
    if path.parts[:2] in ((".config", "gh"), (".config", "gcloud")):
        return True
    if path.parts[0].lower().startswith(("backup-", "backup.", "device-backup", "clash-pseudo-backup")):
        return True
    if path.parts[:2] in (("android", ".gradle"), ("android", "build"), ("android", ".kotlin")):
        return True
    if path.parts[:3] in (("android", "app", "build"), ("android", "app", ".cxx")):
        return True
    return (not public_test_material(path)
            and (path.name in ("local.properties", "key.properties", "keystore.properties", ".DS_Store",
                               ".actrc", ".secrets", ".vars", ".input", ".inputs", ".gitconfig", ".git-credentials",
                               ".netrc", ".npmrc", ".pypirc", ".envrc")
                 or path.name == ".env" or path.name.startswith((".env.", ".secrets.", ".vars.", ".inputs."))))


def check_private_inputs(names):
    for name in names:
        path = PurePosixPath(name)
        update.require(not excluded_source_path(name)
                       and (public_test_material(path)
                            or (path.suffix.lower() not in (".jks", ".keystore", ".p12", ".pfx", ".ab")
                                and path.name not in ("key.properties", "local.properties", "keystore.properties",
                                                      "id_rsa", "id_ed25519", "id_ecdsa", "credentials.json"))),
                       "源码分发发现私有构建材料：" + name)


def working_tree_names(root):
    entries = update.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], root)
    names = sorted(name for name in set(entries.split("\0")) - {""} if not excluded_source_path(name))
    check_private_inputs(names)
    return names


def source_file(root, name):
    path = root
    for part in PurePosixPath(name).parts:
        path = path / part
        update.require(not path.is_symlink(), "源码目录包含符号链接：" + name)
    if not path.exists():
        return None  # 归档时省略已删除的Git跟踪文件。
    update.require(path.is_file(), "源码归档要求普通文件：" + name)
    return path


def file_record(name, data, executable):
    return {"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "executable": executable}


def check_working_tree(root, identity):
    status = update.run(["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"], root)
    files = []
    for name in working_tree_names(root):
        path = source_file(root, name)
        if path is not None:
            files.append(file_record(name, path.read_bytes(), bool(path.stat().st_mode & 0o111)))
    update.require(status == identity["_status"] and files == identity["files"],
                   "归档期间工作树发生变化；确定源码内容后，使用新的输出路径重试")


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
    update.require(not output.exists(), "应用源码输出路径已存在：" + str(output))
    if commit:
        update.run(["git", "diff", "--exit-code", commit, "--"], root)
        update.require(not update.run(["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"], root),
                       "提交模式要求干净工作树；当前源码请使用 workingTree 模式")
        entries = update.run(["git", "ls-tree", "-r", "--name-only", "-z", commit], root)
        check_private_inputs(filter(None, entries.split("\0")))
        update.run(["git", "archive", "--format=tar", "--output", output, commit], root)
        files = None
        status = ""
    else:
        status = update.run(["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"], root)
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
            update.require(output_identity(output.lstat()) == owned, "归档输出文件已被替换")
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
    metadata = update.read_resource_sources(manifest_path.parent)
    update.check_resource_source_selection(root, metadata)
    for kind, source in update.resource_source_entries(metadata):
        add_bytes(archive, "dependencies/data/" + kind + "/" + source["file"],
                  update.read_resource(manifest_path.parent / source["file"], source["bytes"]))
    add_bytes(archive, "build-inputs/resource-sources.json", manifest_path.read_bytes())


def create(updater, evidence, output, commit=None, resource_sources=None, release_inputs=None):
    root = updater.root
    record = update.read_release_resources(root, release_inputs)
    update.verify_bundled_assets(root, record)
    generated = root / update.GENERATED_BUNDLED
    update.require(json.loads((generated / "resources.json").read_bytes()) == record,
                   "对应源码的 generated 材料与指定 release 输入不同")
    update.require(not output.exists(), "对应源码输出路径已存在：" + str(output))
    modules = update.artifacts.go_modules(evidence / "go-modules.json")
    coordinates = update.artifacts.android_coordinates((evidence / "android-dependencies.txt").read_text(encoding="utf-8"))
    version = update.application_version(root)
    current = update.run(["git", "rev-parse", "HEAD"], root).strip()
    if commit:
        commit = update.run(["git", "rev-parse", commit + "^{commit}"], root).strip()
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
                add_bytes(archive, "build-inputs/resources.json", update.json_bytes(record))
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
                    update.require(metadata.get("Sum") == effective.get("Sum"), "Go 源码归档的 h1 校验值与依赖解析结果不一致：" + name)
                    data = Path(metadata["Zip"]).read_bytes()
                    if original == "golang.org/x/net":
                        psl = update.artifacts.check_public_suffix(root, module, io.BytesIO(data))
                        add_bytes(archive, "build-inputs/publicsuffix.json",
                                  json.dumps(psl, ensure_ascii=False, indent=2).encode())
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
                    "workingTree": identity["workingTree"],
                    "dirty": identity["dirty"],
                    "applicationTar": identity["applicationTar"],
                    "flutter": json.loads(update.run([updater.flutter, "--version", "--machine"], root)),
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
                    "按doc/development/build-and-test.md安装所需SDK／NDK、Flutter、Go并配置分发签名，\n"
                    "再运行：\n"
                    "  python3 -I -B tool/dependencies/update.py --prepare-build --offline --payload-directory ../build-inputs/bundled/assets\n"
                    "  flutter pub get --enforce-lockfile\n"
                    "  python3 -I -B tool/contracts/generate.py --check\n"
                    f"  mkdir ../clash-pseudo-{version}-apks\n"
                    "  flutter build apk --release --no-pub --target-platform android-arm,android-arm64,android-x64\n"
                    f"  cp build/app/outputs/flutter-apk/app-release.apk ../clash-pseudo-{version}-apks/clash-pseudo-{version}-universal.apk\n"
                    "  flutter build apk --release --no-pub --target-platform android-arm,android-arm64,android-x64 --split-per-abi\n"
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
            update.require(update.run(["git", "rev-parse", "HEAD"], root).strip() == current,
                           "归档期间基准提交发生变化；确定源码提交后，使用新的输出路径重试")
            if commit is None:
                check_working_tree(root, identity)
            update.require(output_identity(output.lstat()) == owned, "归档输出文件已被替换")
        except BaseException:
            if owned is not None:
                remove_owned_output(output, owned)
            raise
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--commit", help="归档指定Git提交，要求工作树干净；省略时归档当前工作树文件")
    parser.add_argument("--release-inputs", type=Path, help="本次 third_party/data/resources.json 的路径")
    parser.add_argument("--resource-sources", type=Path,
                        help="resource-sources.json文件路径；默认读取evidence目录下的同名文件")
    parser.add_argument("--go", default="go")
    parser.add_argument("--flutter", default="flutter")
    args = parser.parse_args(argv)
    try:
        create(update.Updater(args.project.resolve(), args.go, args.flutter), args.evidence.resolve(),
               args.output.resolve(), args.commit,
               args.resource_sources.resolve() if args.resource_sources is not None else None,
               args.release_inputs.resolve() if args.release_inputs is not None else None)
    except (OSError, ValueError, KeyError, ET.ParseError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
