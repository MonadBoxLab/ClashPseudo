#!/usr/bin/env python3
"""在 GitHub Actions 中准备依赖更新及已核验的 Android 发布材料。"""

import argparse
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import ssl
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
        "通用版包含 armeabi-v7a、arm64-v8a 和 x86_64，适合普通用户直接安装，下载体积较大。\n\n"
        "## 其他下载／按架构选择\n\n"
        f"- [arm64-v8a]({link(apks[1])})：运行 64 位 Android 的大多数现代手机和平板。\n"
        f"- [armeabi-v7a]({link(apks[2])})：使用 32 位 Android 系统的设备。\n"
        f"- [x86_64]({link(apks[3])})：相应设备及模拟器。\n\n"
        "分架构包下载体积较小，按设备当前 Android 系统支持的 ABI 选择。四包的应用身份、版本、内核和签名相同。\n\n"
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
    update.require(owns_release(record, version, kernel, commit), "现有 Release 的版本或源码归属不同")
    assets = {asset["name"] for asset in record["assets"] if asset.get("state") == "uploaded"}
    return (not record["draft"] and record.get("prerelease") == version.startswith("0.")
            and set(names(version)) <= assets)


def verify_sums(text, expected, files):
    entries = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/\\]+)", line)
        update.require(match and match[2] not in entries, "Release 校验文件格式无效")
        entries[match[2]] = match[1]
    update.require(set(entries) == set(expected), "Release 校验文件的资产集合不同")
    for name in expected:
        if name in files:
            update.require(hashlib.sha256(files[name].read_bytes()).hexdigest() == entries[name],
                           "保留的 Release 资产摘要不同：" + name)
    return entries


def sdk_tools():
    sdk = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT", ""))
    directory = sdk / "build-tools" / os.environ.get("ANDROID_BUILD_TOOLS", "36.0.0")
    update.require(all((directory / name).is_file() for name in ("aapt", "zipalign", "apksigner")),
                   "缺少已配置的 Android Build Tools")
    return directory


def signing_digest(root):
    values = {name: os.environ.get(name) for name in (
        "CLASH_SIGNING_STORE_FILE", "CLASH_SIGNING_STORE_PASSWORD", "CLASH_SIGNING_KEY_ALIAS",
        "CLASH_SIGNING_KEY_PASSWORD")}
    update.require(all(values.values()), "分发签名 Secrets 尚未完整配置")
    store = Path(values["CLASH_SIGNING_STORE_FILE"])
    update.require(store.is_file(), "分发签名密钥文件缺失")
    certificate = update.run([
        "keytool", "-exportcert", "-rfc", "-keystore", store,
        "-storepass:env", "CLASH_SIGNING_STORE_PASSWORD", "-alias", values["CLASH_SIGNING_KEY_ALIAS"],
    ], root)
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(certificate)).hexdigest()


def verify_apk(updater, apk, evidence, output, version, certificate, abis):
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
    ))
    fingerprints = {}
    for abi in abis:
        library = output / abi / "libmihomo_bridge.so"
        programs = update.run(["readelf", "-lW", library], updater.root)
        loads = [line.split() for line in programs.splitlines() if line.lstrip().startswith("LOAD ")]
        update.require(loads and all(int(line[-1], 0) >= 16384 for line in loads), "ELF LOAD 对齐小于 16KiB")
        sections = update.run(["readelf", "-SW", library], updater.root)
        update.require(not any(name in sections for name in ("__llvm_prf", "__llvm_cov")),
                       "正常原生库包含覆盖率插桩")
        buildinfo = (output / abi / "buildinfo.txt").read_text(encoding="utf-8")
        _, _, settings = update.artifacts.parse_buildinfo(buildinfo)
        update.require("-cover" not in settings, "正常 Go 库包含覆盖率插桩")
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
        update.require(match and code > int(match[4]), "新分发版本的 versionCode 必须大于已有应用 tag")


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
        return self.updater.go_run("list", "-mod=readonly", "-m", "-f", "{{.Version}}", update.MIHOMO).strip()

    def tag_commit(self, tag):
        tags = self.git("tag", "--list", tag).splitlines()
        return self.git("rev-parse", tag + "^{commit}") if tag in tags else None

    def record(self, tag):
        return self.api("/releases/tags/" + quote(tag, safe=""))

    def recover_assets(self, version, expected, directory, files):
        missing = set(expected) - files.keys()
        page = 1
        while missing:
            records = self.api(f"/actions/artifacts?per_page=100&page={page}")
            update.require(records is not None, "发布归档列表不可用")
            for artifact in records["artifacts"]:
                if artifact["expired"] or not artifact["name"].startswith("release-materials-" + version + "-"):
                    continue
                with tempfile.TemporaryDirectory(prefix="clash-release-recovery-") as temporary:
                    update.run(["gh", "run", "download", str(artifact["workflow_run"]["id"]), "--repo", self.repository,
                                "--name", artifact["name"], "--dir", temporary], self.root)
                    for name in sorted(missing):
                        for path in Path(temporary).rglob(name):
                            if (path.is_file() and not path.is_symlink()
                                    and hashlib.sha256(path.read_bytes()).hexdigest() == expected[name]):
                                target = directory / name
                                shutil.copy2(path, target)
                                files[name] = target
                                break
                missing = set(expected) - files.keys()
                if not missing:
                    break
            if len(records["artifacts"]) < 100:
                break
            page += 1

    def existing_assets(self, tag, record, directory, version):
        assets = {} if record is None else {entry["name"]: entry for entry in record["assets"]}
        files = {}
        for name in names(version):
            if name in assets:
                update.require(assets[name].get("state") == "uploaded", "已有资产尚未完成上传：" + name)
                update.run(["gh", "release", "download", tag, "--repo", self.repository,
                            "--pattern", name, "--dir", directory], self.root)
                files[name] = directory / name
        if "SHA256SUMS" in files:
            expected = verify_sums(files["SHA256SUMS"].read_text(encoding="utf-8"), names(version)[:-1], files)
            if set(expected) - files.keys():
                self.recover_assets(version, expected, directory, files)
        return files

    def tests(self, directory):
        commands = [
            (["python3", "-I", "tool/contracts/generate.py", "--check"], self.root),
            (["python3", "-I", "-B", "-m", "unittest", "discover", "-s", "test/tool"], self.root),
            (["node", "--test", "test/tool/dependency_release_action.test.cjs"], self.root),
            ([self.updater.go, "test", "-tags=cmfa,with_gvisor", "./..."], self.updater.native),
            ([self.updater.go, "vet", "-tags=cmfa,with_gvisor", "./..."], self.updater.native),
            ([self.updater.flutter, "test", "--no-pub"], self.root),
            ([self.root / "android/gradlew", "-p", self.root / "android", "--console=plain",
              ":app:testDebugUnitTest"], self.root),
        ]
        with (directory / "test-output.txt").open("w", encoding="utf-8") as log:
            for command, cwd in commands:
                log.write("$ " + shlex.join(list(map(str, command))) + "\n")
                try:
                    log.write(update.run(command, cwd) + "\n")
                except ValueError as error:
                    log.write(str(error) + "\n")
                    raise

    def artifacts(self, directory, version, certificate, existing, checked=False):
        evidence = directory / "evidence"
        self.updater.evidence(evidence)
        targets = apk_targets(version)
        missing = set(targets) - existing.keys()
        if missing and not checked:
            self.tests(directory)
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

    def source_assets(self, directory, evidence, version, commit, existing):
        sources = directory / names(version)[-3]
        if sources.name not in existing:
            packager = update.load_tool("package_sources", ROOT / "tool/artifacts/package_sources.py")
            packager.create(self.updater, evidence, sources, commit)
        else:
            with tarfile.open(sources, "r:gz") as archive:
                info = json.load(archive.extractfile("build-inputs/version.json"))
                update.require(info["commit"] == commit and info["application"] == version and not info["workingTree"],
                               "已有对应源码包的版本或提交不同")
        licenses = directory / names(version)[-2]
        if licenses.name not in existing:
            raw = directory / "licenses.tar"
            update.run(["git", "archive", "--format=tar", "--output", raw, commit, "--", "NOTICE.md",
                        "doc/legal/dependencies.md", *update.artifacts.ASSETS], self.root)
            with licenses.open("xb") as stream, gzip.GzipFile(fileobj=stream, mode="wb", mtime=0) as compressed:
                compressed.write(raw.read_bytes())
        else:
            with tarfile.open(licenses, "r:gz") as archive:
                for name in ("NOTICE.md", "doc/legal/dependencies.md", *update.artifacts.ASSETS):
                    update.require(archive.extractfile(name).read() == (self.root / name).read_bytes(),
                                   "已有许可包与源码不同：" + name)
        manifest = directory / "SHA256SUMS"
        if manifest.name in existing:
            verify_sums(manifest.read_text(encoding="utf-8"), names(version)[:-1],
                        {name: directory / name for name in names(version)[:-1]})
        else:
            manifest.write_text("".join(hashlib.sha256((directory / name).read_bytes()).hexdigest()
                                        + "  " + name + "\n" for name in names(version)[:-1]), encoding="utf-8")

    def release_plan(self, directory, version, kernel, commit):
        assets = [{"name": name, "path": str(directory / name),
                   "sha256": hashlib.sha256((directory / name).read_bytes()).hexdigest(),
                   "bytes": (directory / name).stat().st_size} for name in names(version)]
        result = {"version": version, "kernel": kernel, "commit": commit, "tag": "v" + version,
                  "body": release_notes(version, kernel, commit, self.repository), "assets": assets}
        path = directory / "release.json"
        path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        return path

    def execute(self, target, bump="patch", publish_current=False):
        certificate = signing_digest(self.root)
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
            else:
                first_stable = bump == "stable"
                args = argparse.Namespace(project=self.root, go=self.updater.go, flutter=self.updater.flutter,
                                          go_module=[], pub=[], android=[],
                                          mihomo_tag=None if first_stable and target == kernel else target,
                                          apply=True, check=False, evidence=None, bump=bump,
                                          reuse_version=not bool(tagged) and not first_stable,
                                          version_only=first_stable and target == kernel)
                result = update.execute(args)
                if tagged and not result["files"]:
                    args.version_only, args.mihomo_tag = True, None
                    update.execute(args)
                version = update.application_version(self.root)
                self.version = version
                tag = "v" + version
                update.require(self.tag_commit(tag) is None, "新版本 tag 已存在")
                check_version(self.root, tag)
                kernel = self.kernel()
                record = None
            existing = self.existing_assets(tag, record, directory, version)
            self.artifacts(directory, version, certificate, existing, checked=record is not None)
            if resume:
                commit = tagged
            else:
                self.git("fetch", "origin", self.branch)
                if self.git("rev-parse", "origin/" + self.branch) != base:
                    self.git("reset", "--hard", "origin/" + self.branch)
                    self.git("clean", "-f", "--", *update.INPUTS)
                    continue
                commit = self.commit_inputs(kernel)
            self.source_assets(directory, directory / "evidence", version, commit, existing)
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


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mihomo-tag")
    parser.add_argument("--bump", choices=("major", "minor", "patch", "stable"), default="patch")
    parser.add_argument("--publish-current", action="store_true", help="为当前完整应用交付准备一次新发布")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    preparation = None
    try:
        update.require(os.environ.get("GITHUB_ACTIONS") == "true"
                       and os.environ.get("CLASH_AUTOMATIC_RELEASES_ENABLED") == "true"
                       and Path(os.environ.get("GITHUB_WORKSPACE", "/")).resolve() == ROOT,
                       "发布准备入口仅在已启用的 GitHub Actions 独立工作区执行")
        update.require(args.bump != "stable" or os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch",
                       "首次稳定发布须由用户明确手动选择，定时任务不能提升稳定阶段")
        repository = os.environ.get("GITHUB_REPOSITORY", "")
        branch = os.environ.get("RELEASE_BRANCH", "")
        update.require(re.fullmatch(r"[\w.-]+/[\w.-]+", repository) and branch, "发布仓库或默认分支缺失")
        update.require(not update.run(["git", "status", "--porcelain"], ROOT).strip(), "CI 初始工作树必须干净")
        args.output = args.output.resolve()
        update.require(not args.output.is_relative_to(ROOT), "发布执行材料使用仓库外目录")
        args.output.mkdir(parents=True, exist_ok=False)
        target = update.mihomo_release(args.mihomo_tag)
        preparation = ReleasePreparation(ROOT, branch, repository, args.output)
        result = preparation.execute(target, args.bump, args.publish_current)
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
