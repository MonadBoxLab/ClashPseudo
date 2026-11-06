"""用标准 Git bundle 传递经过验证的候选提交，不重新生成 commit。"""
from pathlib import Path

from tool.common.io import require
from tool.common.process import run
from tool.dependencies.inputs import INPUTS

ROOT = Path(__file__).resolve().parents[2]
COMMIT_MESSAGE = "chore(deps): update application dependencies"


def git(project, *arguments):
    return run(["git", *arguments], project).strip()


def changed_paths(project, base, commit=None):
    arguments = ["diff", "--name-only", "--no-renames", "-z", base]
    if commit is not None:
        arguments.append(commit)
    return set(filter(None, run(["git", *arguments, "--"], project).split("\0")))


def clean(project):
    require(not git(project, "status", "--porcelain", "--untracked-files=normal"),
            "工作区存在未提交文件，不能发布候选")


def check_candidate(project, base, commit):
    require(git(project, "rev-list", "--parents", "-n", "1", commit) == f"{commit} {base}",
            "候选必须是基准之后的单个提交")
    paths = changed_paths(project, base, commit)
    require(paths and paths <= set(INPUTS), "候选包含依赖更新白名单之外的文件")
    require(git(project, "show", "-s", "--format=%B", commit) == COMMIT_MESSAGE,
            "候选 commit message 与自动更新约定不符")
    for entry in run(["git", "ls-tree", "-z", commit, "--", *sorted(paths)], project).split("\0"):
        if entry:
            require(entry.split(" ", 1)[0] == "100644", "依赖输入必须是普通文件")
    return sorted(paths)


def commit_candidate(project, base, expected):
    require(git(project, "rev-parse", "HEAD") == base, "更新期间 HEAD 已变化")
    paths = changed_paths(project, base)
    require(paths and paths == set(expected) and paths <= set(INPUTS),
            "实际变更与依赖更新白名单或报告不同")
    require(not git(project, "ls-files", "--others", "--exclude-standard"), "候选存在未跟踪文件")
    run(["git", "add", "--", *sorted(paths)], project)
    run(["git", "-c", "user.name=github-actions[bot]", "-c",
         "user.email=41898282+github-actions[bot]@users.noreply.github.com",
         "-c", "commit.gpgsign=false", "commit", "-m", COMMIT_MESSAGE], project)
    commit = git(project, "rev-parse", "HEAD")
    check_candidate(project, base, commit)
    clean(project)
    return commit


def export_bundle(project, destination, base, commit):
    require(git(project, "rev-parse", "HEAD") == commit, "HEAD 与候选提交不同")
    clean(project)
    check_candidate(project, base, commit)
    destination = Path(destination).absolute()
    require(not destination.exists() and not destination.is_symlink(), "Git bundle 已存在")
    run(["git", "bundle", "create", destination, f"{base}..HEAD"], project)
    return destination


def import_bundle(project, source, base, commit):
    source = Path(source).absolute()
    require(source.is_file() and not source.is_symlink(), "缺少本次运行的 Git bundle，请重跑原发布 job")
    require(git(project, "rev-parse", "HEAD") == base, "发布脚本必须来自候选基准")
    require(git(project, "bundle", "list-heads", source) == f"{commit} HEAD", "Git bundle 的候选提交不一致")
    run(["git", "bundle", "verify", source], project)
    run(["git", "fetch", "--no-tags", source, "HEAD"], project)
    require(git(project, "rev-parse", "FETCH_HEAD") == commit, "导入的候选提交不同")
    return check_candidate(project, base, commit)


def register_parser(subparsers):
    for name, action, description in (
            ("export-update", export_bundle, "导出候选提交的标准 Git bundle"),
            ("restore-update", import_bundle, "导入 Git bundle 并核对候选，不切换工作区")):
        parser = subparsers.add_parser(name, help=description)
        parser.add_argument("--project", type=Path, default=ROOT)
        parser.add_argument("--bundle", type=Path, required=True)
        parser.add_argument("--base", required=True)
        parser.add_argument("--commit", required=True)
        parser.set_defaults(handler=lambda args, action=action: (
            action(args.project, args.bundle, args.base, args.commit) and None))
