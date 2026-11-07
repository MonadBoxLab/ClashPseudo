"""Transfer verified candidate commits using standard Git bundles without recreating commits."""
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
            "Cannot publish a candidate with uncommitted workspace changes")


def check_candidate(project, base, commit):
    require(git(project, "rev-list", "--parents", "-n", "1", commit) == f"{commit} {base}",
            "Candidate must be a single commit directly after the base")
    paths = changed_paths(project, base, commit)
    require(paths and paths <= set(INPUTS), "Candidate contains files outside the dependency update allowlist")
    require(git(project, "show", "-s", "--format=%B", commit) == COMMIT_MESSAGE,
            "Candidate commit message does not match the automated update convention")
    for entry in run(["git", "ls-tree", "-z", commit, "--", *sorted(paths)], project).split("\0"):
        if entry:
            require(entry.split(" ", 1)[0] == "100644", "Dependency inputs must be regular files")
    return sorted(paths)


def commit_candidate(project, base, expected):
    require(git(project, "rev-parse", "HEAD") == base, "HEAD changed during the update")
    paths = changed_paths(project, base)
    require(paths and paths == set(expected) and paths <= set(INPUTS),
            "Actual changes differ from the dependency update allowlist or report")
    require(not git(project, "ls-files", "--others", "--exclude-standard"), "Candidate contains untracked files")
    run(["git", "add", "--", *sorted(paths)], project)
    run(["git", "-c", "user.name=github-actions[bot]", "-c",
         "user.email=41898282+github-actions[bot]@users.noreply.github.com",
         "-c", "commit.gpgsign=false", "commit", "-m", COMMIT_MESSAGE], project)
    commit = git(project, "rev-parse", "HEAD")
    check_candidate(project, base, commit)
    clean(project)
    return commit


def export_bundle(project, destination, base, commit):
    require(git(project, "rev-parse", "HEAD") == commit, "HEAD differs from the candidate commit")
    clean(project)
    check_candidate(project, base, commit)
    destination = Path(destination).absolute()
    require(not destination.exists() and not destination.is_symlink(), "Git bundle already exists")
    run(["git", "bundle", "create", destination, f"{base}..HEAD"], project)
    return destination


def import_bundle(project, source, base, commit):
    source = Path(source).absolute()
    require(source.is_file() and not source.is_symlink(), "Git bundle for this run is missing; rerun the original release job")
    require(git(project, "rev-parse", "HEAD") == base, "Release scripts must come from the candidate base")
    require(git(project, "bundle", "list-heads", source) == f"{commit} HEAD", "Git bundle candidate commit does not match")
    run(["git", "bundle", "verify", source], project)
    run(["git", "fetch", "--no-tags", source, "HEAD"], project)
    require(git(project, "rev-parse", "FETCH_HEAD") == commit, "Imported candidate commit does not match")
    return check_candidate(project, base, commit)


def register_parser(subparsers):
    for name, action, description in (
            ("export-update", export_bundle, "Export the candidate commit as a standard Git bundle"),
            ("restore-update", import_bundle, "Import a Git bundle and verify the candidate without switching the workspace")):
        parser = subparsers.add_parser(name, help=description)
        parser.add_argument("--project", type=Path, default=ROOT)
        parser.add_argument("--bundle", type=Path, required=True)
        parser.add_argument("--base", required=True)
        parser.add_argument("--commit", required=True)
        parser.set_defaults(handler=lambda args, action=action: (
            action(args.project, args.bundle, args.base, args.commit) and None))
