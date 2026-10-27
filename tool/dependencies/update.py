#!/usr/bin/env python3
"""检查或更新依赖、许可材料与应用版本；默认跟随 mihomo 正式版。"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
MIHOMO = "github.com/metacubex/mihomo"
GO_INPUTS = ("native/mihomo/go.mod", "native/mihomo/go.sum")
INPUTS = GO_INPUTS + (
    "pubspec.yaml", "pubspec.lock", "android/app/build.gradle.kts",
    "third_party/notices/go.txt", "third_party/notices/mihomo.txt",
    "third_party/notices/android.txt", "third_party/notices/publicsuffix.txt",
    "third_party/data/publicsuffix/public_suffix_list.dat",
)
MAVEN = ("https://dl.google.com/dl/android/maven2", "https://repo.maven.apache.org/maven2")
VERSION = re.compile(r"(?m)^version: ([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)[ \t]*$")
MAVEN_DECLARATION = re.compile(
    r'(?P<prefix>\b(?:implementation|api|testImplementation|androidTestImplementation)\(")'
    r'(?P<name>[\w.-]+:[\w.-]+):(?P<version>[^"\s]+)(?P<suffix>"\))')


def load_tool(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


artifacts = load_tool("release_licenses", ROOT / "tool/artifacts/verify_release_licenses.py")
require = artifacts.require


def run(command, cwd, env=None):
    process = subprocess.run(
        list(map(str, command)), cwd=cwd,
        env=dict(os.environ, GOTOOLCHAIN="local", GOWORK="off", **(env or {})),
        text=True, capture_output=True, check=False,
    )
    if process.returncode:
        raise ValueError(f"命令失败（{process.returncode}）：{' '.join(map(str, command))}\n"
                         + process.stdout + process.stderr)
    return process.stdout


def fetch(url):
    require(url.startswith("https://"), "来源必须使用 HTTPS：" + url)
    request = urllib.request.Request(url, headers={"User-Agent": "clash-pseudo-dependency-update"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def stable_version(value):
    match = re.fullmatch(r"v?([0-9]+(?:\.[0-9]+){1,3})", value)
    return tuple(map(int, match[1].split("."))) if match else None


def mihomo_release(tag=None):
    suffix = "tags/" + tag if tag else "latest"
    if tag:
        require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag), "内核目标必须是正式版本 tag")
    release = json.loads(fetch("https://api.github.com/repos/MetaCubeX/mihomo/releases/" + suffix))
    value = release.get("tag_name", "")
    require(not release.get("draft") and not release.get("prerelease")
            and re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", value), "上游返回的版本不是正式发布")
    require(tag is None or value == tag, "上游发布 tag 与指定目标不同")
    return value


def bump_version(text, level="patch"):
    matches = list(VERSION.finditer(text))
    require(len(matches) == 1, "pubspec.yaml 必须有唯一的 major.minor.patch+versionCode")
    major, minor, patch, code = map(int, matches[0].groups())
    require(code < 2100000000, "Android versionCode 已达到平台上限")
    require(level in ("major", "minor", "patch", "stable"), "应用版本增量无效")
    if level == "stable":
        require(major == 0, "首次稳定发布仅适用于 0.y.z 开发版本")
        major, minor, patch = 1, 0, 0
    elif level == "major":
        require(major > 0, "开发版本的不兼容调整使用 minor；首次稳定发布须明确选择 stable")
        major, minor, patch = major + 1, 0, 0
    elif level == "minor":
        minor, patch = minor + 1, 0
    else:
        patch += 1
    value = f"{major}.{minor}.{patch}+{code + 1}"
    return text[:matches[0].start()] + "version: " + value + text[matches[0].end():], value


def application_version(root):
    matches = list(VERSION.finditer((root / "pubspec.yaml").read_text(encoding="utf-8")))
    require(len(matches) == 1, "pubspec.yaml 应用版本格式无效")
    return ".".join(matches[0].groups()[:3]) + "+" + matches[0][4]


def snapshot(root):
    return {name: (root / name).read_bytes() if (root / name).is_file() else None for name in INPUTS}


def copy_workspace(root, destination):
    """复制当前文件内容，包含尚未提交的正式输入，排除 Git 忽略的构建输出。"""
    files = run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], root)
    for name in set(files.split("\0")) - {""}:
        relative = Path(name)
        require(not relative.is_absolute() and ".." not in relative.parts, "Git 文件路径无效")
        source = root / relative
        if not source.exists():
            continue
        require(source.is_file() and not source.is_symlink(), "更新副本要求普通文件：" + name)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    # 本机 SDK 位置属于执行输入，始终排除在写回和源码分发之外。
    properties = root / "android/local.properties"
    if properties.is_file():
        (destination / "android").mkdir(parents=True, exist_ok=True)
        shutil.copy2(properties, destination / "android/local.properties")


def publish_changes(root, before, after):
    changes = {name: data for name, data in after.items() if before[name] != data}
    for name in changes:
        path = root / name
        require(not path.is_symlink(), "写回目标是符号链接：" + name)
        actual = path.read_bytes() if path.is_file() else None
        require(actual == before[name], "更新期间文件发生变化，保留现有内容：" + name)
    written = []
    try:
        for name, data in changes.items():
            require(data is not None, "更新入口保留输入文件：" + name)
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            written.append(name)
    except OSError:
        for name in reversed(written):
            path = root / name
            if path.read_bytes() != changes[name]:
                continue
            if before[name] is None:
                path.unlink()
            else:
                path.write_bytes(before[name])
        raise
    return sorted(changes)


class Updater:
    def __init__(self, root, go="go", flutter="flutter"):
        self.root = root
        self.go = go
        self.flutter = flutter
        self.native = root / "native/mihomo"
        self.pub_previous = {}

    def go_run(self, *arguments, env=None):
        return run([self.go, *arguments], self.native, env)

    def graph(self, output):
        output.write_text(self.go_run("list", "-mod=readonly", "-m", "-json", "all"), encoding="utf-8")
        return artifacts.go_modules(output)

    def go_updates(self, names, tag):
        if not names:
            return {}
        manifest = json.loads(self.go_run("mod", "edit", "-json"))
        current = {entry["Path"]: entry["Version"] for entry in manifest["Require"]}
        require(set(names) <= current.keys(), "只能选择现有 Go 依赖：" + repr(sorted(set(names) - current.keys())))
        updates = {}
        for name in names:
            if name == MIHOMO:
                target = mihomo_release(tag)
                require(stable_version(target) >= stable_version(current[name]), "内核更新目标早于当前版本")
            else:
                module = json.loads(self.go_run("list", "-mod=readonly", "-m", "-u", "-json", name))
                target = module.get("Update", module)["Version"]
            if target != current[name]:
                updates[name] = target
        return updates

    def update_go(self, updates):
        if not updates:
            return
        before = json.loads(self.go_run("mod", "edit", "-json"))
        self.go_run("get", *[name + "@" + version for name, version in sorted(updates.items())])
        self.go_run("mod", "tidy")
        after = json.loads(self.go_run("mod", "edit", "-json"))
        require(all(before.get(key) == after.get(key) for key in ("Go", "Toolchain", "Replace")),
                "本次依赖更新需要改变工具链或 replace；临时结果保留在失败输出中")
        new = {row["Path"]: row["Version"] for row in after["Require"]}
        for name in ("github.com/rasky/go-lzo", "github.com/metacubex/chacha"):
            require(name in new, "许可版本约束丢失：" + name)
        require(all(new.get(name) == version for name, version in updates.items()),
                "实际 Go 解析与更新目标不同")

    def pub_updates(self, names):
        if not names:
            return {}
        run([self.flutter, "pub", "get", "--enforce-lockfile"], self.root)
        result = json.loads(run([self.flutter, "pub", "outdated", "--json", "--show-all"], self.root))
        packages = {row["package"]: row for row in result["packages"]}
        resolved = json.loads(run([self.flutter, "pub", "deps", "--json"], self.root))
        hosted = {row["name"] for row in resolved["packages"] if row.get("source") == "hosted"}
        self.pub_previous = {row["name"]: row["version"] for row in resolved["packages"] if row["name"] in hosted}
        updates = {}
        for name in names:
            row = packages.get(name)
            require(row and row.get("kind") in ("direct", "dev") and name in hosted,
                    "只能选择现有 hosted 直接依赖：" + name)
            version = (row.get("resolvable") or {}).get("version")
            require(version and stable_version(version), "当前 SDK 下缺少可解析正式版本：" + name)
            if version != (row.get("current") or {}).get("version"):
                updates[name] = (version, row["kind"])
        return updates

    def update_pub(self, updates):
        if not updates:
            return
        descriptors = [("dev:" if kind == "dev" else "") + name + "@" + version
                       for name, (version, kind) in sorted(updates.items())]
        run([self.flutter, "pub", "add", "--no-example", *descriptors], self.root)

    def android_updates(self, names):
        if not names:
            return {}
        path = self.root / "android/app/build.gradle.kts"
        text = path.read_text(encoding="utf-8")
        declared = {m["name"]: m["version"] for m in MAVEN_DECLARATION.finditer(text)}
        require(set(names) <= declared.keys(), "只能选择现有 Android 库：" + repr(sorted(set(names) - declared.keys())))
        updates = {}
        prepared = False
        try:
            for name in names:
                group, artifact = name.split(":")
                versions = []
                for repository in MAVEN:
                    url = f"{repository}/{group.replace('.', '/')}/{artifact}/maven-metadata.xml"
                    try:
                        data = fetch(url)
                    except urllib.error.HTTPError as error:
                        if error.code == 404:
                            continue
                        raise
                    versions.extend(row.text for row in ET.fromstring(data).findall("./versioning/versions/version")
                                    if row.text and stable_version(row.text))
                    if versions:
                        break
                require(versions, "缺少 Maven 正式版本：" + name)
                candidates = sorted({v for v in versions if stable_version(v) > stable_version(declared[name])},
                                    key=stable_version, reverse=True)
                for candidate in candidates:
                    if not prepared:
                        run([self.flutter, "pub", "get", "--enforce-lockfile"], self.root)
                        prepared = True
                    self.update_android({name: candidate})
                    try:
                        run([self.root / "android/gradlew", "-p", self.root / "android", "--console=plain",
                             ":app:checkReleaseAarMetadata", ":app:processReleaseMainManifest",
                             "-x", ":app:buildNativeCore", "-x", ":app:compileFlutterBuildRelease"], self.root)
                    except ValueError as error:
                        if re.search(r"uses-sdk:minSdkVersion|minCompileSdk|requires.*compile.*(?:SDK|API)|"
                                     r"requires libraries and applications.*compile", str(error), re.I | re.S):
                            continue
                        raise
                    updates[name] = candidate
                    break
                self.update_android({name: updates.get(name, declared[name])})
        finally:
            path.write_text(text, encoding="utf-8")
        return updates

    def update_android(self, updates):
        path = self.root / "android/app/build.gradle.kts"
        text = path.read_text(encoding="utf-8")
        text = MAVEN_DECLARATION.sub(
            lambda m: m["prefix"] + m["name"] + ":" + updates.get(m["name"], m["version"]) + m["suffix"], text)
        path.write_text(text, encoding="utf-8")

    def android_graph(self):
        run([self.flutter, "pub", "get", "--enforce-lockfile"], self.root)
        return run([self.root / "android/gradlew", "-p", self.root / "android", "--console=plain",
                    ":app:dependencies", "--configuration", "releaseRuntimeClasspath"], self.root)

    def legal(self, temporary):
        return load_tool("dependency_legal", ROOT / "tool/dependencies/legal.py").Legal(
            self, temporary, fetch, run, artifacts)

    def evidence(self, output):
        """预期输入取包解析和独立资产构建，保持与待检 APK 的来源独立。"""
        output.mkdir()
        self.graph(output / "go-modules.json")
        (output / "android-dependencies.txt").write_text(self.android_graph(), encoding="utf-8")
        assets = output / "flutter-assets"
        run([self.flutter, "build", "bundle", "--release", "--no-pub", "--target-platform=android-arm64",
             "--asset-dir", assets], self.root)
        import gzip
        notices = gzip.decompress((assets / "NOTICES.Z").read_bytes())
        (output / "NOTICES").write_bytes(notices)


def execute(args):
    root = args.project.resolve()
    before = snapshot(root)
    with tempfile.TemporaryDirectory(prefix="clash-dependencies-") as temporary:
        base = Path(temporary)
        work = base / "project"
        work.mkdir()
        copy_workspace(root, work)
        updater = Updater(work, args.go, args.flutter)
        names = args.go_module or ([] if args.pub or args.android or args.version_only else [MIHOMO])
        if args.mihomo_tag:
            require(MIHOMO in names, "--mihomo-tag 必须与 mihomo 更新一起使用")
        go = updater.go_updates(names, args.mihomo_tag)
        pub = updater.pub_updates(args.pub)
        android = updater.android_updates(args.android)
        report = {"go": go, "pub": {name: value[0] for name, value in pub.items()}, "android": android}
        changed = bool(go or pub or android or args.version_only)
        if args.apply and changed:
            updater.update_go(go)
            updater.update_pub(pub)
            if android:
                updater.update_android(android)
            if go or pub or android:
                legal = updater.legal(base)
                if go:
                    legal.go_notices()
                if pub:
                    legal.pub_licenses()
                if android or pub:
                    legal.android_notices()
            version = application_version(work)
            if not args.reuse_version:
                text, version = bump_version((work / "pubspec.yaml").read_text(encoding="utf-8"), args.bump)
                (work / "pubspec.yaml").write_text(text, encoding="utf-8")
            report["files"] = publish_changes(root, before, snapshot(work))
            report["version"] = version
        else:
            report["files"] = []
            report["version"] = application_version(root)
        report["status"] = "updated" if args.apply and changed else "available" if changed else "unchanged"
    if args.evidence:
        Updater(root, args.go, args.flutter).evidence(args.evidence.resolve())
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="查询正式更新，保持工作树文件原状")
    mode.add_argument("--apply", action="store_true", help="更新声明、锁文件、许可与应用版本")
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--go", default="go", help="现有 Go 可执行文件")
    parser.add_argument("--flutter", default="flutter", help="现有 Flutter 可执行文件")
    parser.add_argument("--go-module", action="append", default=[], help="选择现有 Go 模块，可重复")
    parser.add_argument("--mihomo-tag", help="固定目标正式 release tag")
    parser.add_argument("--pub", action="append", default=[], help="选择现有 hosted 直接包，可重复")
    parser.add_argument("--android", action="append", default=[], help="选择现有 group:artifact，可重复")
    parser.add_argument("--evidence", type=Path, help="生成核验输入的新目录；仅与 --apply 一起使用")
    version = parser.add_mutually_exclusive_group()
    version.add_argument("--bump", choices=("major", "minor", "patch", "stable"), default="patch",
                         help="默认 patch；开发期功能／不兼容调整用 minor，首次稳定发布明确选 stable")
    version.add_argument("--reuse-version", action="store_true", help="沿用本次待发布的已确定版本")
    parser.add_argument("--version-only", action="store_true", help="只准备应用发布版本，配合 --apply 和 --bump")
    args = parser.parse_args(argv)
    if (args.evidence or args.version_only or args.reuse_version) and not args.apply:
        parser.error("--evidence、--version-only 和 --reuse-version 与 --apply 一起使用")
    if args.version_only and (args.go_module or args.pub or args.android or args.mihomo_tag or args.reuse_version):
        parser.error("--version-only 单独准备一个新的应用版本")
    try:
        report = execute(args)
    except (OSError, ValueError, KeyError, TypeError, ET.ParseError, subprocess.SubprocessError) as error:
        print(json.dumps({"status": "failed", "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
