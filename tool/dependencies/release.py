"""准备候选提交、打包正式构建，并用同一次 Actions 材料直接发布。"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
from urllib.parse import quote

from tool.artifacts import update_bundle
from tool.common.io import require
from tool.common.process import run
from tool.dependencies.versions import _declaration, application_version

ROOT = Path(__file__).resolve().parents[2]
RETRY = "发布尚未完成，请在原 Actions 运行中重跑发布 job；原 artifact 缺失时停止发布"


def names(version):
    require(version and not any(character in version for character in ("/", "\\", "\0")),
            "应用版本不能包含资产路径分隔符")
    return tuple(f"clash-pseudo-{version}-{suffix}.apk" for suffix in
                 ("universal", "arm64-v8a", "armeabi-v7a", "x86_64")) + (
                     f"clash-pseudo-{version}-sources.tar.gz",
                     f"clash-pseudo-{version}-licenses.tar.gz", "SHA256SUMS")


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def save(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def output(name, value):
    destination = os.environ.get("GITHUB_OUTPUT")
    if destination:
        require("\n" not in str(value), "Actions 输出包含换行")
        with open(destination, "a", encoding="utf-8") as stream:
            stream.write(f"{name}={value}\n")


def check_tag(project, version):
    tag = "v" + version
    run(["git", "check-ref-format", "refs/tags/" + tag], project)
    return tag


def remote_ref(project, ref):
    lines = run(["git", "ls-remote", "origin", ref, ref + "^{}"], project).splitlines()
    records = dict(line.split("\t")[::-1] for line in lines)
    return records.get(ref + "^{}", records.get(ref))


def record(project, repository, tag):
    pages = json.loads(run(["gh", "api", "--paginate", "--slurp",
                           f"repos/{repository}/releases?per_page=100"], project))
    return next((item for page in pages for item in page if item["tag_name"] == tag), None)


def complete(record, version):
    return bool(record and not record["draft"] and
                {asset["name"] for asset in record["assets"] if asset["state"] == "uploaded"}
                == set(names(version)))


def context(project, state, requested="pre-release"):
    require(requested in ("pre-release", "release"), "release_type 配置无效")
    root = Path(project).resolve()
    branch = os.environ.get("DEFAULT_BRANCH", "")
    require(branch and os.environ.get("GITHUB_REF") == "refs/heads/" + branch,
            "发布只接受默认分支上的 workflow")
    run(["git", "check-ref-format", "refs/heads/" + branch], root)
    update_bundle.clean(root)
    base = update_bundle.git(root, "rev-parse", "HEAD")
    version = application_version(root)
    tag = check_tag(root, version)
    repository = os.environ["GITHUB_REPOSITORY"]
    current = record(root, repository, tag)
    target = remote_ref(root, "refs/tags/" + tag)
    if current or target:
        require(target and complete(current, version), RETRY)
    plan = {"base": base, "branch": branch, "repository": repository,
            "run_id": os.environ["GITHUB_RUN_ID"], "release_type": requested,
            "promote": os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and requested == "release" and target == base and complete(current, version)
            and current["prerelease"]}
    save(state, plan)
    output("base", base)
    return plan


def commit(project, state, report, destination):
    root, destination = Path(project).resolve(), Path(destination).resolve()
    plan, report = load(state), load(report)
    require(update_bundle.git(root, "rev-parse", "HEAD") == plan["base"], "更新期间 HEAD 已变化")
    version = application_version(root)
    check_tag(root, version)
    if report["status"] == "updated":
        candidate = update_bundle.commit_candidate(root, plan["base"], report["files"])
        operation = "publish"
    else:
        require(report["status"] == "unchanged", "依赖更新未完成")
        update_bundle.clean(root)
        candidate = plan["base"]
        operation = "promote" if plan["promote"] else "none"
    plan.update(commit=candidate, version=version, tag="v" + version, operation=operation)
    save(state, plan)
    if operation == "promote":
        require(not destination.exists(), "发布材料目录已存在")
        destination.mkdir(parents=True)
        save(destination / "release.json", plan)
    output("operation", operation)
    output("ready", str(operation != "none").lower())
    return plan


def release_notes(version, mihomo, commit, repository):
    base = f"https://github.com/{repository}/releases/download/{quote('v' + version, safe='')}/"
    assets = names(version)
    link = lambda name: base + quote(name, safe="")
    return (
        "## Android 下载\n\n"
        f"[下载通用 APK（推荐）]({link(assets[0])})\n\n"
        "通用版包含 armeabi-v7a、arm64-v8a 和 x86_64。下载后在 Android 设备上打开 APK，按系统提示安装。\n\n"
        f"- [arm64-v8a]({link(assets[1])})：64 位 Android 手机和平板。\n"
        f"- [armeabi-v7a]({link(assets[2])})：32 位 Android 设备。\n"
        f"- [x86_64]({link(assets[3])})：x86_64 Android 设备和模拟器。\n\n"
        "分 ABI APK 体积较小；不确定设备架构时选择通用版。\n\n"
        f"[对应源码]({link(assets[4])}) · [许可材料]({link(assets[5])}) · "
        f"[SHA256SUMS]({link(assets[6])})\n\n"
        f"Application: {version}\nMihomo: {mihomo}\nSource: {commit}\n"
    )


def build(project, state, build_output, destination):
    from tool.dependencies import validation

    root, destination = Path(project).resolve(), Path(destination).resolve()
    plan = load(state)
    require(plan["operation"] == "publish", "本轮没有需要构建的候选")
    require(update_bundle.git(root, "rev-parse", "HEAD") == plan["commit"], "HEAD 与候选提交不同")
    update_bundle.clean(root)
    require(not destination.exists(), "发布材料目录已存在")
    result = validation.build_release(root, Path(build_output), commit=plan["commit"])
    require(result["status"] == "built" and result["commit"] == plan["commit"]
            and result["version"] == plan["version"], "构建结果与候选不同")
    require(set(result["assets"]) == set(names(plan["version"])), "构建结果缺少完整的七项分发资产")
    destination.mkdir(parents=True)
    assets = destination / "assets"
    assets.mkdir()
    for name in names(plan["version"]):
        source = Path(build_output) / name
        require(source.is_file() and not source.is_symlink(), "分发资产不是普通文件：" + name)
        shutil.copyfile(source, assets / name)
    update_bundle.export_bundle(root, destination / "candidate.bundle", plan["base"], plan["commit"])
    plan.update(mihomo=result["mihomo"], assets={name: digest(assets / name) for name in names(plan["version"])})
    (destination / "notes.md").write_text(release_notes(plan["version"], plan["mihomo"],
        plan["commit"], plan["repository"]), encoding="utf-8")
    save(destination / "release.json", plan)
    return plan


def check_plan(project, directory):
    plan = load(directory / "release.json")
    require(plan["repository"] == os.environ["GITHUB_REPOSITORY"]
            and plan["run_id"] == os.environ["GITHUB_RUN_ID"], "发布材料不是本次仓库运行的产物")
    require(plan["branch"] == os.environ["DEFAULT_BRANCH"]
            and os.environ["GITHUB_REF"] == "refs/heads/" + plan["branch"], "发布目标不是默认分支")
    require(update_bundle.git(project, "rev-parse", "HEAD") == plan["base"], "发布脚本必须来自候选基准")
    require(plan["release_type"] in ("pre-release", "release"), "发布材料中的 release_type 无效")
    require(plan["tag"] == check_tag(project, plan["version"]), "发布 tag 与应用版本不同")
    return plan


def downloaded_assets(project, repository, tag, destination, expected):
    command = ["gh", "release", "download", tag, "--repo", repository, "--dir", destination]
    for name in expected:
        command.extend(["--pattern", name])
    run(command, project)
    for name in expected:
        path = destination / name
        require(path.is_file() and not path.is_symlink(), "Release 缺少资产：" + name)


def verify_public(project, plan, current, directory=None):
    expected = names(plan["version"])
    require(complete(current, plan["version"]), "公开 Release 的资产不完整；" + RETRY)
    with tempfile.TemporaryDirectory(prefix="clash-release-assets-") as temporary:
        downloaded = Path(temporary)
        downloaded_assets(project, plan["repository"], plan["tag"], downloaded, expected)
        if directory is not None:
            for name in expected:
                require(digest(downloaded / name) == digest(directory / "assets" / name),
                        "公开 Release 资产冲突，不能覆盖：" + name)
        else:
            entries = {}
            for line in (downloaded / "SHA256SUMS").read_text(encoding="utf-8").splitlines():
                checksum, name = line.split("  ", 1)
                require(name in expected[:-1] and name not in entries, "Release 的 SHA256SUMS 文件列表不符")
                entries[name] = checksum
            require(set(entries) == set(expected[:-1]), "Release 的 SHA256SUMS 缺少资产")
            for name, checksum in entries.items():
                require(digest(downloaded / name) == checksum, "Release 资产摘要不同：" + name)


def edit_release(project, plan):
    prerelease = plan["release_type"] == "pre-release"
    run(["gh", "release", "edit", plan["tag"], "--repo", plan["repository"],
         "--draft=false", "--prerelease=" + str(prerelease).lower(),
         "--latest=" + str(not prerelease).lower()], project)


def publish(project, directory):
    root, directory = Path(project).resolve(), Path(directory).resolve()
    plan = check_plan(root, directory)
    tag_ref = "refs/tags/" + plan["tag"]
    target = remote_ref(root, tag_ref)
    if plan["operation"] == "promote":
        require(plan["promote"] and plan["release_type"] == "release" and plan["commit"] == plan["base"],
                "没有明确的手动转正式请求")
        require(target == plan["commit"], "已有 tag 不指向本轮提交")
        current = record(root, plan["repository"], plan["tag"])
        verify_public(root, plan, current)
        if current["prerelease"]:
            edit_release(root, plan)
        return {"status": "released", "tag": plan["tag"]}
    require(plan["operation"] == "publish", "本轮没有发布操作")
    require(set(plan["assets"]) == set(names(plan["version"])), "发布资产列表不完整")
    for name, checksum in plan["assets"].items():
        path = directory / "assets" / name
        require(path.is_file() and not path.is_symlink() and digest(path) == checksum,
                "本次 artifact 资产缺失或字节不同：" + name)
    update_bundle.import_bundle(root, directory / "candidate.bundle", plan["base"], plan["commit"])
    declaration = update_bundle.git(root, "show", plan["commit"] + ":pubspec.yaml")
    require(_declaration(declaration)[2] == plan["version"], "候选的 pubspec.yaml 与发布版本不同")
    if target is not None:
        require(target == plan["commit"], "已有 tag 指向其他提交")
    else:
        require(remote_ref(root, "refs/heads/" + plan["branch"]) == plan["base"],
                "默认分支已前进，请重新准备候选")
        run(["git", "push", "--atomic", "origin",
             plan["commit"] + ":refs/heads/" + plan["branch"], plan["commit"] + ":" + tag_ref], root)
    current = record(root, plan["repository"], plan["tag"])
    if current and not current["draft"]:
        verify_public(root, plan, current, directory)
        return {"status": "published", "tag": plan["tag"]}
    if current is None:
        run(["gh", "release", "create", plan["tag"], "--repo", plan["repository"],
             "--draft", "--verify-tag", "--title", "Clash Pseudo " + plan["version"],
             "--notes-file", directory / "notes.md"], root)
    else:
        require({asset["name"] for asset in current["assets"]} <= set(plan["assets"]),
                "现有 draft 包含本次运行之外的资产")
    run(["gh", "release", "upload", plan["tag"], "--repo", plan["repository"], "--clobber",
         *[directory / "assets" / name for name in plan["assets"]]], root)
    edit_release(root, plan)
    return {"status": "published", "tag": plan["tag"]}


def register_parser(subparsers):
    group = subparsers.add_parser("release", help="准备、构建和直接发布依赖更新")
    operations = group.add_subparsers(title="操作")
    parser = operations.add_parser("context", help="记录发布类型并检查默认分支和已有发布")
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--release-type", choices=("pre-release", "release"), default="pre-release")
    parser.set_defaults(handler=lambda args: context(args.project, args.state, args.release_type))
    parser = operations.add_parser("commit", help="创建白名单候选提交或准备手动转正式")
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.set_defaults(handler=lambda args: commit(args.project, args.state, args.report, args.output))
    parser = operations.add_parser("build", help="构建四个正式签名 APK 并保存本次发布材料")
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--build-output", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.set_defaults(handler=lambda args: build(args.project, args.state, args.build_output, args.output))
    parser = operations.add_parser("publish", help="只消费本次 artifact，原子推送并发布或转为正式版")
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.set_defaults(handler=lambda args: publish(args.project, args.bundle))
