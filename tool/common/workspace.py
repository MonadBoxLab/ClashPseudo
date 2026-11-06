"""工作树身份、文件快照及受限事务。"""
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile
from tool.common.io import read_bounded, require, RESOURCE_LIMIT
from tool.common.process import run

def input_path(root, name, inputs):
    require(name in inputs, "该文件不在允许更新的列表中：" + name)
    path = root / name
    require(path.resolve() == root.resolve() / name, "输入包含符号链接：" + name)
    require(not path.exists() or path.is_file(), "输入不是普通文件：" + name)
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
    """先准备所有文件的新内容，再比较并逐个原子替换；失败时只回滚仍与本次写入内容一致的文件。"""
    require(set(before) == set(after) == set(inputs), "更新事务必须包含 inputs 列出的全部文件，且不得包含其他文件")
    changes = {name: data for name, data in after.items() if before[name] != data}
    require(all(isinstance(data, bytes) for data in changes.values()), "更新内容必须以 bytes 提供")
    staged, backups, written = {}, {}, []
    failure = None
    try:
        for name, data in changes.items():
            path = input_path(root, name, inputs)
            path.parent.mkdir(parents=True, exist_ok=True)
            staged[name] = stage_bytes(path, data)
            if before[name] is not None:
                backups[name] = stage_bytes(path, before[name])
        # 包括未写入但被本次解析使用的输入，避免把不同来源的依赖或资源拼在一起。
        for name in inputs:
            require(input_bytes(root, name, inputs) == before[name], "更新期间文件发生变化，保留现有内容：" + name)
        for name in changes:
            path = input_path(root, name, inputs)
            require(input_bytes(root, name, inputs) == before[name], "更新期间文件发生变化，保留现有内容：" + name)
            os.replace(staged[name], path)
            written.append(name)
            sync_directory(path.parent)
        for name in inputs:
            require(input_bytes(root, name, inputs) == after[name], "更新期间文件发生变化，保留现有内容：" + name)
    except BaseException as error:
        failure = error
        for name in reversed(written):
            try:
                path = input_path(root, name, inputs)
                if input_bytes(root, name, inputs) != changes[name]:
                    continue  # 文件在本次写入后已被修改，保留当前内容。
                if before[name] is None:
                    path.unlink()
                else:
                    os.replace(backups[name], path)
                sync_directory(path.parent)
            except BaseException as cleanup:
                error.add_note("事务回滚未完成：" + name + "；" + repr(cleanup))
        raise
    finally:
        for path in (*staged.values(), *backups.values()):
            try:
                path.unlink(missing_ok=True)
            except OSError as cleanup:
                if failure is None:
                    raise
                failure.add_note("事务临时文件清理失败：" + repr(cleanup))
    return sorted(changes)


def public_test_material(path):
    # 保留测试目录中的公开合成证书、私钥和keystore文件。
    return (path.parts[0] in ("test", "tests", "testdata")
            or "testdata" in path.parts
            or any(path.parts[index:index + 2] in (("src", "test"), ("src", "androidTest"))
                   for index in range(len(path.parts) - 1)))


def excluded_source_path(name):
    path = PurePosixPath(name)
    require(path.parts and not path.is_absolute() and ".." not in path.parts,
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
        require(not excluded_source_path(name)
                       and (public_test_material(path)
                            or (path.suffix.lower() not in (".jks", ".keystore", ".p12", ".pfx", ".ab")
                                and path.name not in ("key.properties", "local.properties", "keystore.properties",
                                                      "id_rsa", "id_ed25519", "id_ecdsa", "credentials.json"))),
                       "源码分发发现私有构建材料：" + name)


def working_tree_names(root):
    entries = run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], root)
    names = sorted(name for name in set(entries.split("\0")) - {""} if not excluded_source_path(name))
    check_private_inputs(names)
    return names


def source_file(root, name):
    path = root
    for part in PurePosixPath(name).parts:
        path = path / part
        require(not path.is_symlink(), "源码目录包含符号链接：" + name)
    if not path.exists():
        return None  # 归档时省略已删除的Git跟踪文件。
    require(path.is_file(), "源码归档要求普通文件：" + name)
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
                   "归档期间工作树发生变化；确定源码内容后，使用新的输出路径重试")


def working_tree_identity(root):
    return {"_status": run(["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"], root),
            "files": [file_record(name, path.read_bytes(), bool(path.stat().st_mode & 0o111))
                      for name in working_tree_names(root)
                      for path in [source_file(root, name)] if path is not None]}
