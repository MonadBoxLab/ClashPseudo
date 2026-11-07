"""Prepare candidate commits, package release builds, and publish using artifacts from the same Actions run."""
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
RETRY = "Release is incomplete; rerun the release job in the original Actions run, and stop if the original artifact is missing"


def names(version):
    require(version and not any(character in version for character in ("/", "\\", "\0")),
            "Application version must not contain asset path separators")
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
        require("\n" not in str(value), "Actions output contains a newline")
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
    require(requested in ("pre-release", "release"), "Invalid release_type configuration")
    root = Path(project).resolve()
    branch = os.environ.get("DEFAULT_BRANCH", "")
    require(branch and os.environ.get("GITHUB_REF") == "refs/heads/" + branch,
            "Releases require a workflow on the default branch")
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
    require(update_bundle.git(root, "rev-parse", "HEAD") == plan["base"], "HEAD changed during the update")
    version = application_version(root)
    check_tag(root, version)
    if report["status"] == "updated":
        candidate = update_bundle.commit_candidate(root, plan["base"], report["files"])
        operation = "publish"
    else:
        require(report["status"] == "unchanged", "Dependency update is incomplete")
        update_bundle.clean(root)
        candidate = plan["base"]
        operation = "promote" if plan["promote"] else "none"
    plan.update(commit=candidate, version=version, tag="v" + version, operation=operation)
    save(state, plan)
    if operation == "promote":
        require(not destination.exists(), "Release artifact directory already exists")
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
    require(plan["operation"] == "publish", "No candidate to build in this run")
    require(update_bundle.git(root, "rev-parse", "HEAD") == plan["commit"], "HEAD differs from the candidate commit")
    update_bundle.clean(root)
    require(not destination.exists(), "Release artifact directory already exists")
    result = validation.build_release(root, Path(build_output), commit=plan["commit"])
    require(result["status"] == "built" and result["commit"] == plan["commit"]
            and result["version"] == plan["version"], "Build result differs from the candidate")
    require(set(result["assets"]) == set(names(plan["version"])), "Build result does not contain all seven distribution assets")
    destination.mkdir(parents=True)
    assets = destination / "assets"
    assets.mkdir()
    for name in names(plan["version"]):
        source = Path(build_output) / name
        require(source.is_file() and not source.is_symlink(), "Distribution asset is not a regular file: " + name)
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
            and plan["run_id"] == os.environ["GITHUB_RUN_ID"], "Release artifacts are not from this repository run")
    require(plan["branch"] == os.environ["DEFAULT_BRANCH"]
            and os.environ["GITHUB_REF"] == "refs/heads/" + plan["branch"], "Release target is not the default branch")
    require(update_bundle.git(project, "rev-parse", "HEAD") == plan["base"], "Release scripts must come from the candidate base")
    require(plan["release_type"] in ("pre-release", "release"), "Invalid release_type in release artifacts")
    require(plan["tag"] == check_tag(project, plan["version"]), "Release tag differs from the application version")
    return plan


def downloaded_assets(project, repository, tag, destination, expected):
    command = ["gh", "release", "download", tag, "--repo", repository, "--dir", destination]
    for name in expected:
        command.extend(["--pattern", name])
    run(command, project)
    for name in expected:
        path = destination / name
        require(path.is_file() and not path.is_symlink(), "Release is missing an asset: " + name)


def verify_public(project, plan, current, directory=None):
    expected = names(plan["version"])
    require(complete(current, plan["version"]), "Public Release assets are incomplete;" + RETRY)
    with tempfile.TemporaryDirectory(prefix="clash-release-assets-") as temporary:
        downloaded = Path(temporary)
        downloaded_assets(project, plan["repository"], plan["tag"], downloaded, expected)
        if directory is not None:
            for name in expected:
                require(digest(downloaded / name) == digest(directory / "assets" / name),
                        "Public Release asset conflict; cannot overwrite: " + name)
        else:
            entries = {}
            for line in (downloaded / "SHA256SUMS").read_text(encoding="utf-8").splitlines():
                checksum, name = line.split("  ", 1)
                require(name in expected[:-1] and name not in entries, "Release SHA256SUMS file list does not match")
                entries[name] = checksum
            require(set(entries) == set(expected[:-1]), "Release SHA256SUMS is missing assets")
            for name, checksum in entries.items():
                require(digest(downloaded / name) == checksum, "Release asset digest differs: " + name)


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
                "No explicit manual promotion request")
        require(target == plan["commit"], "Existing tag does not point to this run's commit")
        current = record(root, plan["repository"], plan["tag"])
        verify_public(root, plan, current)
        if current["prerelease"]:
            edit_release(root, plan)
        return {"status": "released", "tag": plan["tag"]}
    require(plan["operation"] == "publish", "No publish operation in this run")
    require(set(plan["assets"]) == set(names(plan["version"])), "Release asset list is incomplete")
    for name, checksum in plan["assets"].items():
        path = directory / "assets" / name
        require(path.is_file() and not path.is_symlink() and digest(path) == checksum,
                "Current artifact asset is missing or has different bytes: " + name)
    update_bundle.import_bundle(root, directory / "candidate.bundle", plan["base"], plan["commit"])
    declaration = update_bundle.git(root, "show", plan["commit"] + ":pubspec.yaml")
    require(_declaration(declaration)[2] == plan["version"], "Candidate pubspec.yaml differs from the release version")
    if target is not None:
        require(target == plan["commit"], "Existing tag points to another commit")
    else:
        require(remote_ref(root, "refs/heads/" + plan["branch"]) == plan["base"],
                "Default branch has advanced; prepare a new candidate")
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
                "Existing draft contains assets from another run")
    run(["gh", "release", "upload", plan["tag"], "--repo", plan["repository"], "--clobber",
         *[directory / "assets" / name for name in plan["assets"]]], root)
    edit_release(root, plan)
    return {"status": "published", "tag": plan["tag"]}


def register_parser(subparsers):
    group = subparsers.add_parser("release", help="Prepare, build, and publish dependency updates")
    operations = group.add_subparsers(title="Operations")
    parser = operations.add_parser("context", help="Record the release type and check the default branch and existing releases")
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--release-type", choices=("pre-release", "release"), default="pre-release")
    parser.set_defaults(handler=lambda args: context(args.project, args.state, args.release_type))
    parser = operations.add_parser("commit", help="Create an allowlisted candidate commit or prepare manual promotion")
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.set_defaults(handler=lambda args: commit(args.project, args.state, args.report, args.output))
    parser = operations.add_parser("build", help="Build four release-signed APKs and save this run's release artifacts")
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--build-output", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.set_defaults(handler=lambda args: build(args.project, args.state, args.build_output, args.output))
    parser = operations.add_parser("publish", help="Use only this run's artifact, push atomically, and publish or promote the release")
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.set_defaults(handler=lambda args: publish(args.project, args.bundle))
