#!/usr/bin/env python3
"""为GitHub Actions发布或本地构建准备四个Android APK、对应源码、许可材料和校验文件。"""

import argparse
import base64
import binascii
import gzip
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import ssl
import stat
import subprocess
import tarfile
import tempfile
from urllib.parse import quote


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("dependency_update", ROOT / "tool/dependencies/update.py")
update = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update)


def apk_targets(version):
    return {
        f"clash-pseudo-{version}-universal.apk": tuple(update.artifacts.ABIS),
        f"clash-pseudo-{version}-arm64-v8a.apk": ("arm64-v8a",),
        f"clash-pseudo-{version}-armeabi-v7a.apk": ("armeabi-v7a",),
        f"clash-pseudo-{version}-x86_64.apk": ("x86_64",),
    }


def names(version):
    return (*apk_targets(version), f"clash-pseudo-{version}-sources.tar.gz",
            f"clash-pseudo-{version}-licenses.tar.gz", "SHA256SUMS")


def metadata(version, kernel, commit):
    return f"Application: {version}\nMihomo: {kernel}\nSource: {commit}"


def release_notes(version, kernel, commit, repository):
    tag = "v" + version
    base = "https://github.com/" + repository + "/releases/download/" + quote(tag, safe="") + "/"
    apks = list(apk_targets(version))
    link = lambda name: base + quote(name, safe="")
    return (
        "## Android 通用版（推荐）\n\n"
        f"[下载 Android 通用版]({link(apks[0])})\n\n"
        "通用版包含 armeabi-v7a、arm64-v8a 和 x86_64。下载 APK 后在 Android 设备上打开，按系统提示安装。\n\n"
        "## 其他下载／按架构选择\n\n"
        f"- [arm64-v8a]({link(apks[1])})：运行 64 位 Android 的大多数现代手机和平板。\n"
        f"- [armeabi-v7a]({link(apks[2])})：使用 32 位 Android 系统的设备。\n"
        f"- [x86_64]({link(apks[3])})：运行x86_64 Android系统的设备及模拟器。\n\n"
        "分架构包下载体积较小，按设备当前 Android 系统支持的 ABI 选择；不确定架构时下载通用版。\n\n"
        f"[对应源码]({link(names(version)[-3])}) · [许可材料]({link(names(version)[-2])}) · "
        f"[SHA256SUMS]({link('SHA256SUMS')})\n\n" + metadata(version, kernel, commit) + "\n"
    )


def owns_release(record, version, kernel, commit):
    lines = [line for line in record.get("body", "").splitlines()
             if re.match(r"^(?:Application|Mihomo|Source):", line)]
    return lines == metadata(version, kernel, commit).splitlines()


def check_release(record, version, kernel, commit):
    if record is None:
        return False
    update.require(owns_release(record, version, kernel, commit), "现有 Release 的版本、内核版本或源码提交与本次发布不一致")
    assets = {asset["name"] for asset in record["assets"] if asset.get("state") == "uploaded"}
    return (not record["draft"] and record.get("prerelease") == version.startswith("0.")
            and set(names(version)) <= assets)


def verify_sums(text, expected, files):
    entries = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/\\]+)", line)
        update.require(match and match[2] not in entries, "Release 校验文件格式无效")
        entries[match[2]] = match[1]
    update.require(set(entries) == set(expected), "Release 校验文件列出的附件与本次要求的附件不一致")
    for name in expected:
        if name in files:
            update.require(file_digest(files[name]) == entries[name],
                           "已保留附件的摘要与校验文件不一致：" + name)
    return entries


def sdk_tools():
    sdk = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT", ""))
    directory = sdk / "build-tools" / os.environ.get("ANDROID_BUILD_TOOLS", "36.0.0")
    update.require(all((directory / name).is_file() for name in ("aapt", "zipalign", "apksigner")),
                   "缺少已配置的 Android Build Tools")
    return directory


def signing_properties(path):
    """保持 java.util.Properties.load(UTF-8 Reader) 的逻辑行和转义语义。"""
    whitespace = " \t\f"

    def decode(value):
        result, index = [], 0
        while index < len(value):
            character = value[index]
            index += 1
            if character == "\\":
                character = value[index]
                index += 1
                if character == "u":
                    digits = value[index:index + 4]
                    update.require(len(digits) == 4 and re.fullmatch(r"[0-9a-fA-F]{4}", digits),
                                   "key.properties Unicode 转义无效")
                    character = chr(int(digits, 16))
                    index += 4
                else:
                    character = {"t": "\t", "r": "\r", "n": "\n", "f": "\f"}.get(character, character)
            result.append(character)
        # Java String 使用 UTF-16；成对的 Unicode 转义与原始补充字符必须相同。
        return "".join(result).encode("utf-16-le", "surrogatepass").decode("utf-16-le", "surrogatepass")

    values, pending = {}, None
    # UTF-8 Reader 替换非法序列；Java 将代理项的非法 UTF-8 编码视为一次错误。
    data = re.sub(rb"\xed[\xa0-\xbf][\x80-\xbf]?", b"\xef\xbf\xbd", path.read_bytes())
    text = data.decode("utf-8", "replace")
    natural_lines = re.split(r"\r\n|\r|\n", text)
    for number, natural in enumerate(natural_lines):
        line = natural.lstrip(whitespace)
        if not pending:
            if not line or line.startswith(("#", "!")):
                # Java 在空续行后仍识别注释；续行符后立即 EOF 则产生空属性。
                if (pending == "" and natural == "" and number == len(natural_lines) - 1
                        and not text.endswith("\r\n")):
                    values[""] = ""
                pending = None
                continue
        else:
            line = pending + line
        continued = (len(line) - len(line.rstrip("\\"))) % 2
        if continued:
            line = line[:-1]
            if number < len(natural_lines) - 1:
                pending = line
                continue
        pending = None
        if not line and not continued:
            continue
        key_end, value_start, has_separator = 0, len(line), False
        escaped = False
        while key_end < len(line):
            character = line[key_end]
            if not escaped and (character in "=:" or character in whitespace):
                has_separator = character in "=:"
                value_start = key_end + 1
                break
            escaped = not escaped if character == "\\" else False
            key_end += 1
        while value_start < len(line):
            character = line[value_start]
            if character not in whitespace:
                if has_separator or character not in "=:":
                    break
                has_separator = True
            value_start += 1
        values[decode(line[:key_end])] = decode(line[value_start:])
    update.require(all(values.get(name) for name in ("storeFile", "storePassword", "keyAlias", "keyPassword")),
                   "key.properties 签名配置不完整")
    return values


def signing_digest(root):
    names = ("CLASH_PSEUDO_ANDROID_KEYSTORE_BASE64", "CLASH_PSEUDO_ANDROID_KEYSTORE_PASSWORD",
             "CLASH_PSEUDO_ANDROID_KEY_ALIAS", "CLASH_PSEUDO_ANDROID_KEY_PASSWORD")
    values = [os.environ.get(name, "") for name in names]
    environment = any(name in os.environ for name in names)
    update.require(not environment or all(values), "四个签名环境变量必须完整提供")
    update.require(not environment or not any("\0" in value for value in values),
                   "签名配置包含无效字符")
    update.require(os.environ.get("CLASH_REQUIRE_DISTRIBUTION_SIGNING") != "true" or environment,
                   "正式分发必须提供四个签名环境变量")
    with tempfile.TemporaryDirectory(prefix="clash-pseudo-signing-") as temporary:
        if environment:
            store = Path(temporary) / "key.jks"
            try:
                # 与 Java Base64.getDecoder() 一致：允许省略末尾的填充字符，不接受多余的填充字符。
                encoded = values[0]
                update.require(re.fullmatch(r"(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}(?:==)?|[A-Za-z0-9+/]{3}=?)?",
                                            encoded), "签名密钥的 Base64 无效")
                data = base64.b64decode(encoded + "=" * (-len(encoded) % 4), validate=True)
            except (ValueError, binascii.Error):
                raise ValueError("签名密钥的 Base64 无效") from None
            update.require(data, "签名密钥内容为空")
            store.touch(mode=0o600)
            store.write_bytes(data)
            password, alias = values[1:3]
        else:
            path = root / "android/key.properties"
            update.require(path.is_file(), "签名环境和 android/key.properties 均不可用")
            local = signing_properties(path)
            update.require(not any("\0" in local[name] for name in
                                   ("storeFile", "storePassword", "keyAlias", "keyPassword")),
                           "签名配置包含无效字符")
            store = path.parent / local["storeFile"]
            password, alias = (local[name] for name in ("storePassword", "keyAlias"))
        update.require(store.is_file(), "签名密钥文件缺失")
        certificate = update.run([
            "keytool", "-exportcert", "-rfc", "-keystore", store,
            "-storepass:env", names[1], "-alias", alias,
        ], root, env={names[1]: password})
        return hashlib.sha256(ssl.PEM_cert_to_DER_cert(certificate)).hexdigest()


def xnet_source(updater, evidence):
    modules = update.artifacts.go_modules(evidence / "go-modules.json")
    update.require("golang.org/x/net" in modules, "发布核验记录缺少所选 x/net 模块")
    selected = modules["golang.org/x/net"]
    effective = selected.get("Replace") or selected
    update.require(effective.get("Path") and effective.get("Version") and effective.get("Sum"),
                   "已选 x/net 缺少固定版本或校验摘要")
    # 从 Go 模块缓存读取所选 x/net 版本的原始源码 ZIP 文件。
    metadata = json.loads(updater.go_run(
        "mod", "download", "-json", effective["Path"] + "@" + effective["Version"],
        env={"GOPROXY": "off", "GOSUMDB": "off", "GONOPROXY": "none"}))
    update.require(not metadata.get("Error"), "x/net 原始源码不可用：" + str(metadata.get("Error")))
    update.require(metadata.get("Sum") == effective["Sum"], "x/net 原始源码的 h1 校验值与发布核验记录不一致")
    source = metadata.get("Zip")
    update.require(isinstance(source, str) and source and Path(source).is_file()
                   and Path(source).stat().st_size > 0, "找不到所选 x/net 版本的非空原始源码 ZIP 文件")
    return Path(source)


def verify_apk(updater, apk, evidence, output, version, certificate, abis):
    source = xnet_source(updater, evidence)
    tools = sdk_tools()
    badging = update.run([tools / "aapt", "dump", "badging", apk], updater.root)
    name, code = version.split("+")
    update.require(re.search(r"^package: name='io.github.monadboxlab.clashpseudo' versionCode='" + re.escape(code)
                             + r"' versionName='" + re.escape(name) + r"'", badging, re.M),
                   "APK 应用身份或版本与 pubspec.yaml 不同")
    update.require("application-debuggable" not in badging, "分发 APK 是 debuggable 构建")
    update.run([tools / "zipalign", "-c", "-P", "16", "4", apk], updater.root)
    signatures = update.run([tools / "apksigner", "verify", "--verbose", "--print-certs", apk], updater.root)
    actual = re.findall(r"Signer #[0-9]+ certificate SHA-256 digest: ([a-fA-F0-9]+)", signatures)
    update.require(len(actual) == 1 and actual[0].lower() == certificate, "APK 分发签名证书不同")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.mkdir()
    update.artifacts.verify(argparse.Namespace(
        project=updater.root, apk=apk, notices=evidence / "NOTICES", go_modules=evidence / "go-modules.json",
        android_dependencies=evidence / "android-dependencies.txt", output_dir=output, go=updater.go, abis=abis,
        xnet_source=source,
    ))
    fingerprints = {}
    for abi in abis:
        library = output / abi / "libmihomo_bridge.so"
        programs = update.run(["readelf", "-lW", library], updater.root)
        loads = [line.split() for line in programs.splitlines() if line.lstrip().startswith("LOAD ")]
        update.require(loads and all(int(line[-1], 0) >= 16384 for line in loads), "ELF LOAD 对齐小于 16KiB")
        sections = update.run(["readelf", "-SW", library], updater.root)
        update.require(not any(name in sections for name in ("__llvm_prf", "__llvm_cov")),
                       "release原生库包含覆盖率插桩")
        buildinfo = (output / abi / "buildinfo.txt").read_text(encoding="utf-8")
        _, _, settings = update.artifacts.parse_buildinfo(buildinfo)
        update.require("-cover" not in settings, "release Go库包含覆盖率插桩")
        with library.open("rb") as stream:
            fingerprints[abi] = hashlib.file_digest(stream, "sha256").hexdigest()
    return fingerprints


def check_version(root, tag):
    code = int(update.application_version(root).split("+")[1])
    for existing in update.run(["git", "tag", "--list", "v*+*"], root).splitlines():
        if existing == tag or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+", existing):
            continue
        other = update.run(["git", "show", existing + ":pubspec.yaml"], root)
        match = update.VERSION.search(other)
        update.require(match and code > int(match[4]), "新发布版本的 versionCode 必须大于已有应用 tag 记录的 versionCode")


SOURCE_PACKAGE_LIMIT = 8 * 1024 * 1024 * 1024
SOURCE_MEMBER_LIMIT = 200000


def file_digest(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        update.require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "交付输入要求普通文件")
        return hashlib.file_digest(stream, "sha256").hexdigest()


class SourceBudget:
    """限制tar解析器读取的解压后总大小，包括PAX扩展头。"""
    def __init__(self, stream):
        self.stream, self.bytes = stream, 0

    def read(self, size):
        update.require(size >= 0, "每次读取对应源码时须指定非负的读取大小")
        remaining = SOURCE_PACKAGE_LIMIT + SOURCE_MEMBER_LIMIT * 1024 - self.bytes
        data = self.stream.read(min(size, update.CHUNK, remaining + 1))
        self.bytes += len(data)
        update.require(self.bytes <= SOURCE_PACKAGE_LIMIT + SOURCE_MEMBER_LIMIT * 1024, "对应源码解压超过上限")
        return data


def source_members(source, *, directories=False):
    """顺序读取外层tar，限制成员大小、成员数量和解压后总大小；拒绝链接。"""
    descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        update.require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode)
                       and os.fstat(stream.fileno()).st_size <= SOURCE_PACKAGE_LIMIT,
                       "对应源码输入不是普通文件或超过上限")
        with gzip.GzipFile(fileobj=stream, mode="rb") as decompressed, \
                tarfile.open(fileobj=SourceBudget(decompressed), mode="r|", bufsize=update.CHUNK) as archive:
            seen, total = set(), 0
            for member in archive:
                name = member.name
                path = PurePosixPath(name)
                update.require(name and not path.is_absolute() and ".." not in path.parts
                               and path.as_posix() == name and "\\" not in name
                               and name not in seen, "对应源码成员重复或路径无效：" + name)
                seen.add(name)
                update.require(len(seen) <= SOURCE_MEMBER_LIMIT, "对应源码成员数量或大小超过上限")
                if directories and member.isdir():
                    continue
                update.require(member.isfile() and not member.issparse(), "对应源码成员不是普通文件：" + name)
                total += member.size
                update.require(0 <= member.size <= SOURCE_PACKAGE_LIMIT and total <= SOURCE_PACKAGE_LIMIT,
                               "对应源码成员数量或大小超过上限")
                yield archive, member


def source_archive_version(source):
    result = None
    for archive, member in source_members(source):
        if member.name == "build-inputs/version.json":
            update.require(member.size <= 128 * 1024, "对应源码版本清单超过上限")
            result = json.loads(update.read_bounded(archive.extractfile(member), 128 * 1024),
                                object_pairs_hook=update.unique_object)
    update.require(isinstance(result, dict), "对应源码包缺少版本清单")
    return result


def recover_resource_sources(root, source, destination, version, commit):
    """从已校验的源码包恢复清单登记的资源归档，核对版本、提交、大小和摘要。"""
    destination = Path(destination).absolute()
    update.require(destination.resolve() == destination and not destination.is_relative_to(Path(root).resolve()),
                   "恢复目录必须在仓库外且不能包含符号链接")
    destination.mkdir(parents=True, exist_ok=False)
    checksum = file_digest(source)
    documents, data_members = {}, set()
    required = {"build-inputs/version.json", "build-inputs/resources.json", "build-inputs/resource-sources.json"}
    fixed_record = update.read_release_resources(root)
    payload_members = {"build-inputs/bundled/assets/" + update.RESOURCE_ASSETS[kind]: spec
                       for kind, spec in fixed_record["resources"].items()}
    found_payloads = set()
    for archive, member in source_members(source):
        if member.name in required:
            update.require(member.size <= 128 * 1024, "对应源码清单超过上限")
            documents[member.name] = update.read_bounded(archive.extractfile(member), 128 * 1024)
        elif member.name.startswith("dependencies/data/"):
            data_members.add(member.name)
        elif member.name in payload_members:
            spec = payload_members[member.name]
            data = update.read_bounded(archive.extractfile(member), spec["storedBytes"])
            update.require(member.size == spec["storedBytes"] and update.validate_resource(data, spec) == spec,
                           "源码包固定 payload 的大小或摘要不同")
            target = destination / "payloads" / update.RESOURCE_ASSETS[spec["kind"]]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            found_payloads.add(member.name)
    update.require(set(documents) == required, "对应源码包缺少固定来源或版本清单")
    info = json.loads(documents["build-inputs/version.json"], object_pairs_hook=update.unique_object)
    update.require(isinstance(info, dict) and info.get("commit") == commit
                   and info.get("application") == version and info.get("workingTree") is False,
                   "已有对应源码包的版本或提交不同")
    selected = json.loads(documents["build-inputs/resources.json"], object_pairs_hook=update.unique_object)
    update.require(selected == fixed_record and found_payloads == set(payload_members),
                   "对应源码包的 release 来源记录或五项 payload 不完整")
    manifest = documents["build-inputs/resource-sources.json"]
    metadata = json.loads(manifest, object_pairs_hook=update.unique_object)
    update.check_resource_source_selection(root, metadata)
    entries = {"dependencies/data/" + kind + "/" + row["file"]: row
               for kind, row in update.resource_source_entries(metadata)}
    update.require(data_members == set(entries), "对应源码包缺少登记资源或包含未登记归档")
    sources = destination / "resource-sources"
    sources.mkdir()
    restored = set()
    for archive, member in source_members(source):
        if member.name not in entries:
            continue
        row = entries[member.name]
        update.require(member.size == row["bytes"], "恢复资源源码大小不同")
        with (sources / row["file"]).open("xb") as output:
            measured = update.transfer(archive.extractfile(member), output, row["bytes"])
        update.require(measured == {"bytes": row["bytes"], "sha256": row["sha256"]}, "恢复资源源码摘要不同")
        restored.add(member.name)
    update.require(restored == set(entries) and file_digest(source) == checksum, "恢复期间对应源码输入发生变化")
    (sources / "resource-sources.json").write_bytes(manifest)
    update.read_resource_sources(sources)
    update.prepare_bundled_assets(Path(root), payloads={kind: destination / "payloads" / name
                                                      for kind, name in update.RESOURCE_ASSETS.items()}, offline=True)
    return destination


class ReleasePreparation:
    def __init__(self, root, branch, repository, output, go="go", flutter="flutter"):
        self.root = root
        self.branch = branch
        self.repository = repository
        self.output = output
        self.updater = update.Updater(root, go, flutter)
        self.version = None

    def git(self, *arguments):
        return update.run(["git", *arguments], self.root).strip()

    def api(self, path):
        try:
            return json.loads(update.run(["gh", "api", "repos/" + self.repository + path], self.root))
        except ValueError as error:
            if "(HTTP 404)" in str(error):
                return None
            raise

    def kernel(self):
        text = (self.root / "native/mihomo/go.mod").read_text(encoding="utf-8")
        match = re.search(re.escape(update.MIHOMO) + r"\s+(v[^\s]+)", text)
        update.require(match is not None, "go.mod 缺少 mihomo 版本声明")
        return match[1]

    def tag_commit(self, tag):
        tags = self.git("tag", "--list", tag).splitlines()
        return self.git("rev-parse", tag + "^{commit}") if tag in tags else None

    def record(self, tag):
        return self.api("/releases/tags/" + quote(tag, safe=""))

    def recover_assets(self, version, expected, directory, files, commit=None):
        missing = set(expected or names(version)[:-1]) - files.keys()
        page = 1
        while missing or "SHA256SUMS" not in files:
            records = self.api(f"/actions/artifacts?per_page=100&page={page}")
            update.require(records is not None, "发布归档列表不可用")
            for artifact in records["artifacts"]:
                run = artifact.get("workflow_run", {})
                if artifact["expired"] or not artifact["name"].startswith("release-materials-" + version + "-"):
                    continue
                with tempfile.TemporaryDirectory(prefix="clash-release-recovery-", dir=self.output) as temporary:
                    update.run(["gh", "run", "download", str(run["id"]), "--repo", self.repository,
                                "--name", artifact["name"], "--dir", temporary], self.root)
                    candidates = {}
                    for path in Path(temporary).rglob("*"):
                        update.require(not path.is_symlink(), "Actions 恢复材料不能包含符号链接")
                        if path.name not in names(version) or not path.is_file():
                            continue
                        update.require(path.name not in candidates, "Actions 恢复材料包含同名附件：" + path.name)
                        candidates[path.name] = path
                    candidate_sums = candidates.get("SHA256SUMS")
                    if expected is None:
                        if candidate_sums is None:
                            continue
                        source = candidates.get(names(version)[-3])
                        if commit is not None:
                            if source is None:
                                continue
                            identity = source_archive_version(source)
                            # run.head_sha 是工作流启动提交；发布提交可能由该 job 后续生成。
                            if (identity.get("commit") != commit or identity.get("application") != version
                                    or identity.get("workingTree") is not False):
                                continue
                        expected = verify_sums(update.read_resource(candidate_sums, 128 * 1024).decode("utf-8"),
                                               names(version)[:-1], files)
                    elif candidate_sums is not None:
                        measured = verify_sums(update.read_resource(candidate_sums, 128 * 1024).decode("utf-8"),
                                               names(version)[:-1], files)
                        update.require(measured == expected, "同次 Actions 校验清单与 Release 不同")
                    for name in sorted(set(expected) - files.keys()):
                        path = candidates.get(name)
                        if path is not None and file_digest(path) == expected[name]:
                            target = directory / name
                            shutil.copy2(path, target)
                            files[name] = target
                    if "SHA256SUMS" not in files and candidate_sums is not None:
                        target = directory / "SHA256SUMS"
                        shutil.copy2(candidate_sums, target)
                        files[target.name] = target
                missing = set(expected or names(version)[:-1]) - files.keys()
                if not missing and "SHA256SUMS" in files:
                    break
            if len(records["artifacts"]) < 100:
                break
            page += 1

    def existing_assets(self, tag, record, directory, version, commit=None):
        rows = [] if record is None else record["assets"]
        assets = {entry["name"]: entry for entry in rows}
        update.require(len(assets) == len(rows), "Release 包含同名附件")
        files = {}
        for name in names(version):
            if name in assets:
                update.require(assets[name].get("state") == "uploaded", "已有附件尚未上传完成：" + name)
                update.run(["gh", "release", "download", tag, "--repo", self.repository,
                            "--pattern", name, "--dir", directory], self.root)
                files[name] = directory / name
        expected = None
        if "SHA256SUMS" in files:
            expected = verify_sums(update.read_resource(files["SHA256SUMS"], 128 * 1024).decode("utf-8"),
                                   names(version)[:-1], files)
        if commit is not None and (expected is None or set(expected) - files.keys()):
            self.recover_assets(version, expected, directory, files, commit=commit)
        elif expected is not None and set(expected) - files.keys():
            self.recover_assets(version, expected, directory, files)
        if commit is not None:
            update.require("SHA256SUMS" in files, "重新运行同一tag的任务时缺少已固定的SHA256SUMS")
            verify_sums(update.read_resource(files["SHA256SUMS"], 128 * 1024).decode("utf-8"),
                        names(version)[:-1], files)
        return files

    def recover_resources(self, directory, version, commit, existing):
        source = existing.get(names(version)[-3])
        update.require(source is not None, "重新运行同一tag的任务时缺少已校验的对应源码包；不能重新查询latest")
        parent = Path(tempfile.mkdtemp(prefix="release-fixed-", dir=self.output))
        return recover_resource_sources(self.root, source, parent / "restored", version, commit)

    def artifacts(self, directory, version, certificate, existing):
        # 构建前检查生成文件与源声明一致。
        update.run(["python3", "-I", "-B", "tool/contracts/generate.py", "--check"], self.root)
        evidence = directory / "evidence"
        self.updater.evidence(evidence)
        targets = apk_targets(version)
        missing = set(targets) - existing.keys()
        arguments = [self.updater.flutter, "build", "apk", "--release", "--no-pub", "--target-platform",
                     "android-arm,android-arm64,android-x64"]
        universal = next(iter(targets))
        if universal in missing:
            update.run(arguments, self.root)
            shutil.copy2(self.root / "build/app/outputs/flutter-apk/app-release.apk", directory / universal)
        split = [name for name in missing if name != universal]
        if split:
            update.run([*arguments, "--split-per-abi"], self.root)
            for name in split:
                abi = targets[name][0]
                shutil.copy2(self.root / f"build/app/outputs/flutter-apk/app-{abi}-release.apk", directory / name)
        libraries = {}
        for name, abis in targets.items():
            fingerprints = verify_apk(self.updater, directory / name, evidence,
                                      directory / "verification" / name.removesuffix(".apk"), version, certificate, abis)
            for abi, fingerprint in fingerprints.items():
                update.require(abi not in libraries or libraries[abi] == fingerprint,
                               "同一 ABI 在通用版与分架构包中的原生库不同：" + abi)
                libraries[abi] = fingerprint

    def commit_inputs(self, kernel):
        changed = set(self.git("diff", "--name-only").splitlines())
        changed.update(self.git("ls-files", "--others", "--exclude-standard").splitlines())
        update.require(changed <= set(update.INPUTS), "更新出现范围外文件：" + repr(sorted(changed - set(update.INPUTS))))
        if changed:
            self.git("add", "--", *sorted(changed))
            self.git("-c", "user.name=github-actions[bot]", "-c",
                     "user.email=41898282+github-actions[bot]@users.noreply.github.com", "commit",
                     "-m", "chore(deps): prepare release with mihomo " + kernel,
                     "-m", "Assisted by AI")
        return self.git("rev-parse", "HEAD")

    def delivery_resources(self, prepare, recovered=None):
        """准备新资源，或读取从已校验源码包恢复的固定资源。"""
        update.require(prepare or recovered is not None, "复用已有资源时须提供恢复目录")
        directory = (Path(tempfile.mkdtemp(prefix="release-resources-", dir=self.output))
                     if prepare else Path(recovered))
        result = update.delivery_resources(Path(self.root), directory, prepare=prepare)
        update.require(isinstance(result, dict) and set(result) == {"prepared", "sources"}
                       and isinstance(result["sources"], Path) and result["sources"].is_file(),
                       "资源准备函数未返回完整的来源清单")
        prepared = result["prepared"]
        update.require(isinstance(prepared, Path) and prepared.is_dir() if prepare else prepared is None,
                       "资源准备函数的返回结果与当前准备阶段不一致")
        return result

    def source_assets(self, directory, evidence, version, commit, existing, resource_sources=None):
        sources = directory / names(version)[-3]
        if sources.name not in existing:
            packager = update.load_tool("package_sources", ROOT / "tool/artifacts/package_sources.py")
            packager.create(self.updater, evidence, sources, commit, resource_sources=resource_sources)
        else:
            info = source_archive_version(sources)
            update.require(info.get("commit") == commit and info.get("application") == version
                           and info.get("workingTree") is False, "已有对应源码包的版本或提交不同")
        licenses = directory / names(version)[-2]
        if licenses.name not in existing:
            packager = update.load_tool("package_sources", ROOT / "tool/artifacts/package_sources.py")
            with licenses.open("xb") as stream, gzip.GzipFile(filename="", fileobj=stream, mode="wb", mtime=0) as compressed, \
                    tarfile.open(fileobj=compressed, mode="w|") as archive:
                for name in ("NOTICE.md", "doc/legal/dependencies.md", update.RESOURCE_RECORD, *update.artifacts.ASSETS):
                    packager.add_bytes(archive, name, (self.root / name).read_bytes())
        else:
            expected = {name: (self.root / name).read_bytes()
                        for name in ("NOTICE.md", "doc/legal/dependencies.md", update.RESOURCE_RECORD, *update.artifacts.ASSETS)}
            checked = set()
            for archive, member in source_members(licenses, directories=True):
                update.require(member.name in expected and member.size == len(expected[member.name]),
                               "已有许可包的文件集合或大小不同：" + member.name)
                update.require(update.read_bounded(archive.extractfile(member), max(1, member.size)) == expected[member.name],
                               "已有许可包与源码不同：" + member.name)
                checked.add(member.name)
            update.require(checked == set(expected), "已有许可包缺少登记材料")
        manifest = directory / "SHA256SUMS"
        if manifest.name in existing:
            verify_sums(manifest.read_text(encoding="utf-8"), names(version)[:-1],
                        {name: directory / name for name in names(version)[:-1]})
        else:
            manifest.write_text("".join(file_digest(directory / name) + "  " + name + "\n"
                                        for name in names(version)[:-1]), encoding="utf-8")

    def release_plan(self, directory, version, kernel, commit, *, local_identity=None, certificate=None):
        assets = [{"name": name, "path": str(directory / name),
                   "sha256": file_digest(directory / name),
                   "bytes": (directory / name).stat().st_size} for name in names(version)]
        result = {"version": version, "kernel": kernel, "commit": commit, "tag": "v" + version,
                  "body": release_notes(version, kernel, commit, self.repository), "assets": assets}
        if local_identity is not None:
            result.update(local=True, workingTree=True, inputIdentity=local_identity, certificateSha256=certificate)
        path = directory / "release.json"
        path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        return path

    def prepare_tools(self):
        bootstrap = update.load_tool("release_toolchains", ROOT / "tool/dependencies/toolchains.py")
        tools = update.read_release_resources(self.root)["toolchains"]
        environment, _ = bootstrap.prepare(tools, Path.home() / ".cache/clash-pseudo/toolchains", self.root)
        os.environ.update(environment)
        self.updater.flutter = str(Path(environment["PATH"].split(os.pathsep)[0]) / "flutter")
        self.updater.go = str(Path(environment["PATH"].split(os.pathsep)[1]) / "go")

    def execute(self, bump="patch", publish_current=False):
        update.require(not local_environment(), "本地或 ACT 环境不能进入生产发布执行器")
        target = None
        while True:
            self.git("fetch", "origin", self.branch, "--tags")
            base = self.git("rev-parse", "origin/" + self.branch)
            self.git("reset", "--hard", base)
            version = update.application_version(self.root)
            update.require(bump != "major" or not version.startswith("0."),
                           "开发版本的不兼容调整使用 minor；首次稳定发布须明确选择 stable")
            self.version = version
            tag = "v" + version
            tagged = self.tag_commit(tag)
            record = self.record(tag) if tagged else None
            kernel = self.kernel()
            if tagged:
                source_version = self.git("show", tag + ":pubspec.yaml")
                source_kernel = self.git("show", tag + ":native/mihomo/go.mod")
                match = update.VERSION.search(source_version)
                update.require(match and ".".join(match.groups()[:3]) + "+" + match[4] == version,
                               "现有 tag 的应用版本与名称不同")
                match = re.search(re.escape(update.MIHOMO) + r"\s+(v[^\s]+)", source_kernel)
                update.require(match, "现有 tag 缺少内核版本")
                tagged_kernel = match[1]
                complete = check_release(record, version, tagged_kernel, tagged)
                if complete and target is None:
                    target = update.mihomo_release()
                if (complete and target == kernel == tagged_kernel and not publish_current
                        and (bump != "stable" or not version.startswith("0."))):
                    return {"status": "unchanged", "version": version, "kernel": kernel}
                resume = not complete
            else:
                resume = False
            directory = Path(tempfile.mkdtemp(prefix="release-", dir=self.output))
            if resume:
                self.git("checkout", "--detach", tagged)
                kernel = tagged_kernel
                existing = self.existing_assets(tag, record, directory, version, commit=tagged)
                recovered = self.recover_resources(directory, version, tagged, existing)
                resources = self.delivery_resources(prepare=False, recovered=recovered)
            else:
                target = target or update.mihomo_release()
                if target == kernel and not publish_current and bump != "stable":
                    return {"status": "unchanged", "version": version, "kernel": kernel}
                first_stable = bump == "stable"
                # 新交付先完成全部资源校验；失败在任何写回或 Git 写操作之前终止。
                resources = self.delivery_resources(prepare=True)
                args = argparse.Namespace(project=self.root, go=self.updater.go, flutter=self.updater.flutter,
                                          go_module=[], pub=[], android=[],
                                          resolved_release=target,
                                          apply=True, check=False, evidence=None, bump=bump,
                                          reuse_version=not bool(tagged) and not first_stable,
                                          prepared_resources=resources["prepared"])
                result = update.execute(args)
                version = update.application_version(self.root)
                self.version = version
                tag = "v" + version
                update.require(self.tag_commit(tag) is None, "新版本 tag 已存在")
                check_version(self.root, tag)
                kernel = self.kernel()
                record = None
                existing = {}
            self.prepare_tools()
            certificate = signing_digest(self.root)
            self.artifacts(directory, version, certificate, existing)
            if resume:
                commit = tagged
            else:
                self.git("fetch", "origin", self.branch)
                if self.git("rev-parse", "origin/" + self.branch) != base:
                    self.git("reset", "--hard", "origin/" + self.branch)
                    self.git("clean", "-f", "--", *update.INPUTS)
                    continue
                commit = self.commit_inputs(kernel)
            self.source_assets(directory, directory / "evidence", version, commit, existing,
                               resource_sources=resources["sources"])
            if not resume:
                self.git("tag", tag, commit)
                try:
                    self.git("push", "--atomic", "origin", "HEAD:refs/heads/" + self.branch, "refs/tags/" + tag)
                except ValueError as error:
                    if re.search(r"permission denied|not permitted|protected branch|\b403\b|GH006|GH013", str(error), re.I):
                        raise
                    self.git("fetch", "origin", self.branch)
                    if self.git("rev-parse", "origin/" + self.branch) != base:
                        self.git("tag", "-d", tag)
                        self.git("reset", "--hard", "origin/" + self.branch)
                        continue
                    raise
            plan = self.release_plan(directory, version, kernel, commit)
            return {"status": "prepared", "version": version, "kernel": kernel,
                    "commit": commit, "tag": tag, "plan": str(plan)}


SIGNING_NAMES = ("CLASH_PSEUDO_ANDROID_KEYSTORE_BASE64", "CLASH_PSEUDO_ANDROID_KEYSTORE_PASSWORD",
                 "CLASH_PSEUDO_ANDROID_KEY_ALIAS", "CLASH_PSEUDO_ANDROID_KEY_PASSWORD")


def local_environment():
    # ACT的任何非空值均表示本地执行，包括字符串false。
    return bool(os.environ.get("ACT")) or os.environ.get("CLASH_LOCAL_EXECUTION") == "true"


def local_input_identity(root):
    marker = root / ".local/input.json"
    update.require(marker.resolve() == marker, "本地固定输入目录不能包含符号链接")
    info = json.loads(update.read_resource(marker, 16 * 1024 * 1024), object_pairs_hook=update.unique_object)
    update.require(isinstance(info, dict) and info.get("format") == "clash-pseudo-local-input" and info.get("version") == 1,
                   "本地交付必须使用 --prepare-act 固定的独立副本")
    packager = update.load_tool("package_sources", ROOT / "tool/artifacts/package_sources.py")
    files = []
    for name in packager.working_tree_names(root):
        path = packager.source_file(root, name)
        if path is not None:
            files.append(packager.file_record(name, path.read_bytes(), bool(path.stat().st_mode & 0o111)))
    update.require(files == info.get("files"), "本地固定输入发生变化；重新准备独立副本")
    sources = root / ".local/resource-inputs/resource-sources/resource-sources.json"
    recorded = info.get("resourceSources")
    update.require(isinstance(recorded, dict) and sources.stat().st_size == recorded.get("bytes")
                   and file_digest(sources) == recorded.get("sha256"), "本地固定资源清单发生变化")
    update.read_resource_sources(sources.parent)
    record = update.read_release_resources(root)
    payloads = root / ".local/resource-inputs/payloads"
    for kind, spec in record["resources"].items():
        data = update.read_resource(payloads / update.RESOURCE_ASSETS[kind], spec["storedBytes"])
        update.require(update.validate_resource(data, spec) == spec, "本地固定 payload 发生变化：" + kind)
    return info


class LocalPreparation:
    """在本地构建并校验APK，打包当前工作树的源码和许可材料。"""
    artifacts = ReleasePreparation.artifacts
    source_assets = ReleasePreparation.source_assets
    release_plan = ReleasePreparation.release_plan

    def __init__(self, root, output, go="go", flutter="flutter"):
        self.root, self.output = root, output
        self.updater = update.Updater(root, go, flutter)
        self.repository = "local/validation"
        self.version = None

    def execute_local(self, resource_sources):
        update.require(os.environ.get("CLASH_LOCAL_EXECUTION") == "true", "本地入口须显式启用 CLASH_LOCAL_EXECUTION=true")
        identity = local_input_identity(self.root)
        update.require(all(os.environ.get(name) for name in SIGNING_NAMES), "本地候选需要完整的四个签名环境变量")
        version = update.application_version(self.root)
        check_version(self.root, "v" + version)
        certificate = signing_digest(self.root)
        metadata = update.read_resource_sources(resource_sources.parent)
        update.require(resource_sources.name == "resource-sources.json", "本地资源输入必须为 resource-sources.json")
        update.require(resource_sources.stat().st_size == identity["resourceSources"]["bytes"]
                       and file_digest(resource_sources) == identity["resourceSources"]["sha256"], "本地资源输入与固定副本不同")
        update.check_resource_source_selection(self.root, metadata)
        fixed = Path(tempfile.mkdtemp(prefix="local-resources-", dir=self.output))
        sources = fixed / "resource-sources"
        sources.mkdir()
        for _kind, row in update.resource_source_entries(metadata):
            shutil.copyfile(resource_sources.parent / row["file"], sources / row["file"])
        shutil.copyfile(resource_sources, sources / "resource-sources.json")
        payloads = {kind: self.root / ".local/resource-inputs/payloads" / name
                    for kind, name in update.RESOURCE_ASSETS.items()}
        update.prepare_bundled_assets(self.root, payloads=payloads, offline=True)
        resources = {"sources": sources / "resource-sources.json"}
        kernel = self.updater.go_run("list", "-mod=readonly", "-m", "-f", "{{.Version}}", update.MIHOMO).strip()
        self.version = version
        directory = Path(tempfile.mkdtemp(prefix="local-release-", dir=self.output))
        update.run([self.updater.flutter, "pub", "get", "--enforce-lockfile"], self.root)
        self.artifacts(directory, version, certificate, {})
        self.source_assets(directory, directory / "evidence", version, None, {}, resource_sources=resources["sources"])
        update.require(local_input_identity(self.root) == identity, "本地构建期间输入发生变化")
        commit = update.run(["git", "rev-parse", "HEAD"], self.root).strip()
        plan = self.release_plan(directory, version, kernel, commit, local_identity=identity, certificate=certificate)
        return {"status": "local-prepared", "version": version, "kernel": kernel, "plan": str(plan)}


def isolated_run(command, cwd, environment):
    process = subprocess.run(list(map(str, command)), cwd=cwd, env=environment,
                             text=True, capture_output=True, check=False)
    update.require(process.returncode == 0,
                   "隔离仓库准备失败（" + str(process.returncode) + "）：" + process.stdout + process.stderr)
    return process.stdout


def prepare_act(root, output, resource_sources, runner, act="act", artifact_host=None, docker_host=None):
    """在仓库外创建源码副本、本地Git仓库、环境文件及act运行参数。"""
    update.require(output.resolve() == output and not output.is_relative_to(root.resolve()), "act 材料必须使用仓库外新目录")
    update.require(isinstance(runner, str) and re.search(r"(?:ubuntu|debian)", runner) and ":" in runner
                   and "\n" not in runner, "必须显式指定 Debian 系 runner 镜像映射")
    update.require(isinstance(artifact_host, str), "必须显式指定容器可达的 artifact 服务 IPv4 地址")
    address = ipaddress.IPv4Address(artifact_host)
    update.require(not address.is_loopback and not address.is_unspecified and not address.is_multicast,
                   "artifact服务须使用容器可访问的IPv4地址，不能使用回环、未指定或组播地址")
    update.require(docker_host is None or re.fullmatch(r"unix:///[^\s\x00]+", docker_host),
                   "Docker连接地址须使用unix:///路径格式的本机Unix socket")
    act = shutil.which(act) or act
    update.require(resource_sources.name == "resource-sources.json", "act 资源输入必须为 resource-sources.json")
    metadata = update.read_resource_sources(resource_sources.parent)
    update.check_resource_source_selection(root, metadata)
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    packager = update.load_tool("package_sources", ROOT / "tool/artifacts/package_sources.py")
    workspace = output / "workspace"
    workspace.mkdir()
    status = update.run(["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"], root)
    files = []
    for name in packager.working_tree_names(root):
        source = packager.source_file(root, name)
        if source is None:
            continue
        data = source.read_bytes()
        executable = bool(source.stat().st_mode & 0o111)
        target = workspace / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(0o755 if executable else 0o644)
        files.append(packager.file_record(name, data, executable))
    packager.check_working_tree(root, {"_status": status, "files": files})
    fixed = workspace / ".local/resource-inputs/resource-sources"
    fixed.mkdir(parents=True)
    for _kind, row in update.resource_source_entries(metadata):
        shutil.copyfile(resource_sources.parent / row["file"], fixed / row["file"])
    shutil.copyfile(resource_sources, fixed / "resource-sources.json")
    update.read_resource_sources(fixed)
    generated = root / update.GENERATED_BUNDLED
    record = update.read_release_resources(root)
    payloads = workspace / ".local/resource-inputs/payloads"
    for kind, resource in record["resources"].items():
        relative = update.RESOURCE_ASSETS[kind]
        data = update.read_resource(generated / "assets" / relative, resource["storedBytes"])
        update.require(update.validate_resource(data, resource) == resource, "act payload 与 release 记录不同：" + kind)
        target = payloads / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    update.prepare_bundled_assets(workspace, payloads={kind: payloads / name for kind, name in update.RESOURCE_ASSETS.items()},
                                  offline=True)
    identity = {"format": "clash-pseudo-local-input", "version": 1, "files": files,
                "resourceSources": {"bytes": (fixed / "resource-sources.json").stat().st_size,
                                    "sha256": file_digest(fixed / "resource-sources.json")},
                "sourceCommit": update.run(["git", "rev-parse", "HEAD"], root).strip()}
    (workspace / ".local/input.json").write_bytes(update.json_bytes(identity))
    for name in ("home", "control", "action-cache", "artifacts", "cache", "temp", "docker-config"):
        (output / name).mkdir(mode=0o700)
    # act使用以下独立环境变量及指定的DOCKER_HOST。
    environment = {"PATH": os.defpath, "HOME": str(output / "home"), "TMPDIR": str(output / "temp"),
                   "DOCKER_CONFIG": str(output / "docker-config"), "LANG": "C.UTF-8",
                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"}
    if docker_host is not None:
        environment["DOCKER_HOST"] = docker_host
    isolated_run(["git", "init", "-b", "local-validation", workspace], output, environment)
    (workspace / ".git/info/exclude").write_text(".local/\n", encoding="utf-8")
    paths = output / "control/source-files"
    paths.touch(mode=0o600)
    paths.write_bytes(b"".join(row["path"].encode("utf-8") + b"\0" for row in files))
    isolated_run(["git", "--literal-pathspecs", "add", "--force", "--pathspec-file-nul",
                  "--pathspec-from-file=" + str(paths)], workspace, environment)
    isolated_run(["git", "-c", "user.name=Local validation", "-c", "user.email=local@invalid", "commit", "-m",
                  "test: freeze isolated delivery input"], workspace, environment)
    isolated_run(["git", "clone", "--bare", "--no-hardlinks", workspace, output / "origin.git"], output, environment)
    isolated_run(["git", "remote", "add", "origin", str(output / "origin.git")], workspace, environment)
    control = output / "control"
    for name, content in {
        "env": "CLASH_LOCAL_EXECUTION=true\nCLASH_REQUIRE_DISTRIBUTION_SIGNING=true\nGOTOOLCHAIN=local\n",
        "secrets": "", "vars": "", "inputs": "",
        "event.json": json.dumps({"ref": "refs/heads/local-validation", "repository": {
            "name": "validation", "full_name": "local/validation", "default_branch": "local-validation",
            "owner": {"login": "local"}}, "inputs": {}}),
    }.items():
        path = control / name
        path.touch(mode=0o600)
        path.write_text(content, encoding="utf-8")
    command = [act, "workflow_dispatch", "--directory", str(workspace), "--bind", "--workflows",
               str(workspace / ".github/workflows/update-dependencies.yml"), "--job", "release",
               "--env-file", str(control / "env"), "--secret-file", str(control / "secrets"),
               "--var-file", str(control / "vars"), "--input-file", str(control / "inputs"),
               "--eventpath", str(control / "event.json"), "--container-daemon-socket", "-",
               "--container-options-policy", "restrict", "--action-cache-path", str(output / "action-cache"),
               "--artifact-server-path", str(output / "artifacts"), "--artifact-server-addr", artifact_host,
               "--artifact-server-port", "34567", "--no-cache-server", "--pull=false",
               "--platform", "ubuntu-latest=" + runner]
    launch = {"environment": environment, "cwd": str(workspace), "command": command,
              "validate": [*command, "--validate", "--dryrun"], "dryrun": [*command, "--dryrun"]}
    (control / "launch.json").write_bytes(update.json_bytes(launch))
    return {"status": "act-prepared", "workspace": str(workspace), "launch": str(control / "launch.json"),
            "command": shlex.join(["env", "-i", *(key + "=" + value for key, value in environment.items()), *command])}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bump", choices=("major", "minor", "patch", "stable"), default="patch")
    parser.add_argument("--publish-current", action="store_true", help="为当前应用准备新版本并发布")
    parser.add_argument("--output", type=Path, required=True)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--verify-local-input", action="store_true", help="核对容器 workspace 与全部固定输入，不构建或访问 remote")
    mode.add_argument("--local", action="store_true", help="在--prepare-act生成的workspace目录中构建四个APK并打包当前版本的源码和许可")
    mode.add_argument("--prepare-act", action="store_true", help="创建源码副本和本地Git远程仓库，将运行参数写入control/launch.json")
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--resource-sources", type=Path)
    parser.add_argument("--runner-image", help="本地act使用的Debian或Ubuntu镜像名称及tag或摘要")
    parser.add_argument("--act", default="act")
    parser.add_argument("--artifact-host", help="runner容器可访问的artifact服务IPv4地址")
    parser.add_argument("--docker-host", help="本地Docker守护进程的Unix socket地址，格式为unix:///path/to/docker.sock")
    args = parser.parse_args(argv)
    preparation = None
    try:
        if args.verify_local_input:
            info = local_input_identity(args.project.resolve())
            print(json.dumps({"status": "verified", "files": len(info["files"]), "sourceCommit": info["sourceCommit"]}))
            return 0
        if args.local or args.prepare_act:
            update.require(not args.publish_current and args.bump == "patch",
                           "本地检查使用当前输入，不更新依赖或递增版本")
            root, output = args.project.resolve(), args.output.absolute()
            update.require(output.resolve() == output and not output.is_relative_to(root), "本地执行材料使用仓库外独立目录")
            sources = args.resource_sources or root / ".local/resource-inputs/resource-sources/resource-sources.json"
            if args.prepare_act:
                update.require(args.resource_sources is not None, "准备 act 须显式提供固定资源源码清单")
                result = prepare_act(root, output, sources.absolute(), args.runner_image, args.act,
                                     args.artifact_host, args.docker_host)
            else:
                update.require(os.environ.get("CLASH_LOCAL_EXECUTION") == "true", "本地入口须显式启用 CLASH_LOCAL_EXECUTION=true")
                local_input_identity(root)
                output.mkdir(parents=True, exist_ok=False)
                local = LocalPreparation(root, output)
                result = local.execute_local(sources.absolute())
                if os.environ.get("GITHUB_OUTPUT"):
                    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
                        stream.write("version=" + result["version"] + "\n")
                        stream.write("local_plan=" + result["plan"] + "\n")
            print(json.dumps(result, ensure_ascii=False, sort_keys=True))
            return 0
        update.require(not local_environment(), "ACT 或本地环境必须显式选择 --local，不能进入生产发布入口")
        update.require(args.project.resolve() == ROOT, "生产发布只使用 GitHub 工作区")
        update.require(os.environ.get("GITHUB_ACTIONS") == "true"
                       and os.environ.get("CLASH_AUTOMATIC_RELEASES_ENABLED") == "true"
                       and Path(os.environ.get("GITHUB_WORKSPACE", "/")).resolve() == ROOT,
                       "发布准备入口仅在已启用的 GitHub Actions 独立工作区执行")
        update.require(args.bump != "stable" or os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch",
                       "首次稳定发布须手动选择 stable，定时任务不能执行")
        repository = os.environ.get("GITHUB_REPOSITORY", "")
        branch = os.environ.get("RELEASE_BRANCH", "")
        update.require(re.fullmatch(r"[\w.-]+/[\w.-]+", repository) and branch, "发布仓库或默认分支缺失")
        update.require(not update.run(["git", "status", "--porcelain"], ROOT).strip(), "CI 初始工作树必须干净")
        args.output = args.output.resolve()
        update.require(not args.output.is_relative_to(ROOT), "发布执行材料使用仓库外目录")
        args.output.mkdir(parents=True, exist_ok=False)
        preparation = ReleasePreparation(ROOT, branch, repository, args.output)
        result = preparation.execute(args.bump, args.publish_current)
        if "plan" in result:
            with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
                stream.write("plan=" + result["plan"] + "\n")
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, tarfile.TarError) as error:
        parser.exit(1, str(error) + "\n")
    finally:
        if preparation is not None and preparation.version and os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
                stream.write("version=" + preparation.version + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
