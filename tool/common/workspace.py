"""Working tree identity, file snapshots, and scoped transactions."""
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile
from tool.common.io import read_bounded, require, RESOURCE_LIMIT
from tool.common.process import run

def input_path(root, name, inputs):
    require(name in inputs, "File is not in the allowed update list: " + name)
    path = root / name
    require(path.resolve() == root.resolve() / name, "Input contains a symbolic link: " + name)
    require(not path.exists() or path.is_file(), "Input is not a regular file: " + name)
    return path


def input_bytes(root, name, inputs):
    path = input_path(root, name, inputs)
    if not path.exists():
        return None
    with path.open("rb") as stream:
        return read_bounded(stream, RESOURCE_LIMIT)


def snapshot(root, inputs):
    return {name: input_bytes(root, name, inputs) for name in inputs}


def copy_workspace(root, destination):
    """Copy current files, including uncommitted inputs, excluding Git-ignored build outputs."""
    files = run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], root)
    for name in set(files.split("\0")) - {""}:
        relative = Path(name)
        require(not relative.is_absolute() and ".." not in relative.parts, "Invalid Git file path")
        source = root / relative
        if not source.exists():
            continue
        require(source.is_file() and not source.is_symlink(), "Update workspace requires regular files: " + name)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    # Local SDK paths are execution inputs, excluded from writeback and source distribution.
    properties = root / "android/local.properties"
    if properties.is_file():
        (destination / "android").mkdir(parents=True, exist_ok=True)
        shutil.copy2(properties, destination / "android/local.properties")


def stage_bytes(path, data):
    descriptor, name = tempfile.mkstemp(prefix=".clash-update-", dir=path.parent)
    staged = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        staged.chmod(stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644)
        return staged
    except BaseException:
        staged.unlink(missing_ok=True)
        raise


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def publish_changes(root, before, after, inputs):
    """Stage all new content, compare inputs, and replace files atomically; roll back only unchanged writes on failure."""
    require(set(before) == set(after) == set(inputs), "Update transaction must contain exactly the files listed in inputs")
    changes = {name: data for name, data in after.items() if before[name] != data}
    require(all(isinstance(data, bytes) for data in changes.values()), "Update content must be provided as bytes")
    staged, backups, written = {}, {}, []
    failure = None
    try:
        for name, data in changes.items():
            path = input_path(root, name, inputs)
            path.parent.mkdir(parents=True, exist_ok=True)
            staged[name] = stage_bytes(path, data)
            if before[name] is not None:
                backups[name] = stage_bytes(path, before[name])
        # Check all resolution inputs, including unwritten files, to avoid mixing dependency or resource sources.
        for name in inputs:
            require(input_bytes(root, name, inputs) == before[name], "File changed during update; preserving current content: " + name)
        for name in changes:
            path = input_path(root, name, inputs)
            require(input_bytes(root, name, inputs) == before[name], "File changed during update; preserving current content: " + name)
            os.replace(staged[name], path)
            written.append(name)
            sync_directory(path.parent)
        for name in inputs:
            require(input_bytes(root, name, inputs) == after[name], "File changed during update; preserving current content: " + name)
    except BaseException as error:
        failure = error
        for name in reversed(written):
            try:
                path = input_path(root, name, inputs)
                if input_bytes(root, name, inputs) != changes[name]:
                    continue  # Preserve files modified after this transaction wrote them.
                if before[name] is None:
                    path.unlink()
                else:
                    os.replace(backups[name], path)
                sync_directory(path.parent)
            except BaseException as cleanup:
                error.add_note("Transaction rollback incomplete: " + name + "; " + repr(cleanup))
        raise
    finally:
        for path in (*staged.values(), *backups.values()):
            try:
                path.unlink(missing_ok=True)
            except OSError as cleanup:
                if failure is None:
                    raise
                failure.add_note("Failed to clean up transaction temporary files: " + repr(cleanup))
    return sorted(changes)


def public_test_material(path):
    # Keep public synthetic certificates, private keys, and keystores in test directories.
    return (path.parts[0] in ("test", "tests", "testdata")
            or "testdata" in path.parts
            or any(path.parts[index:index + 2] in (("src", "test"), ("src", "androidTest"))
                   for index in range(len(path.parts) - 1)))


def excluded_source_path(name):
    path = PurePosixPath(name)
    require(path.parts and not path.is_absolute() and ".." not in path.parts,
                   "Invalid Git file path")
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
        require(not excluded_source_path(name)
                       and (public_test_material(path)
                            or (path.suffix.lower() not in (".jks", ".keystore", ".p12", ".pfx", ".ab")
                                and path.name not in ("key.properties", "local.properties", "keystore.properties",
                                                      "id_rsa", "id_ed25519", "id_ecdsa", "credentials.json"))),
                       "Private build material found in source distribution: " + name)


def working_tree_names(root):
    entries = run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], root)
    names = sorted(name for name in set(entries.split("\0")) - {""} if not excluded_source_path(name))
    check_private_inputs(names)
    return names


def source_file(root, name):
    path = root
    for part in PurePosixPath(name).parts:
        path = path / part
        require(not path.is_symlink(), "Source directory contains a symbolic link: " + name)
    if not path.exists():
        return None  # Omit deleted Git-tracked files from the archive.
    require(path.is_file(), "Source archive requires regular files: " + name)
    return path


def file_record(name, data, executable):
    return {"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "executable": executable}


def check_working_tree(root, identity):
    status = run(["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"], root)
    files = []
    for name in working_tree_names(root):
        path = source_file(root, name)
        if path is not None:
            files.append(file_record(name, path.read_bytes(), bool(path.stat().st_mode & 0o111)))
    require(status == identity["_status"] and files == identity["files"],
                   "Working tree changed during archiving; finalize the source content and retry with a new output path")


def working_tree_identity(root):
    return {"_status": run(["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"], root),
            "files": [file_record(name, path.read_bytes(), bool(path.stat().st_mode & 0o111))
                      for name in working_tree_names(root)
                      for path in [source_file(root, name)] if path is not None]}
