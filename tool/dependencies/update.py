"""依赖候选解析、范围选择、差异判定与事务写回。"""
import copy
import json
import logging
import os
import time
from pathlib import Path
import tempfile

from tool.common.io import json_bytes, require
from tool.common.workspace import copy_workspace, working_tree_identity, check_working_tree
from tool.dependencies import resources, sources, toolchains
from tool.dependencies.inputs import INPUTS, snapshot, publish_changes
from tool.dependencies.packages import MIHOMO, MAVEN_DECLARATION, Updater, mihomo_release
from tool.dependencies.versions import application_version, bump_version


def fixed_dependencies(record):
    return {ecosystem: {name: {"selected": row["selected"]} for name, row in rows.items()}
            for ecosystem, rows in record.items()}


def stable_record(record):
    fixed = copy.deepcopy(record)
    if "dependencies" in fixed:
        fixed["dependencies"] = fixed_dependencies(fixed["dependencies"])
    return fixed


def selected_dependencies(previous, resolution):
    selected = fixed_dependencies(previous)
    for ecosystem, rows in resolution.items():
        selected.setdefault(ecosystem, {}).update(
            {name: {"selected": row["selected"]} for name, row in rows.items()})
    return selected


def module_versions(updater):
    manifest = json.loads(updater.go_run("mod", "edit", "-json"))
    return {row["Path"]: row["Version"] for row in manifest["Require"]}, manifest


def changes_between(before, after):
    return {name: {"previous": before.get(name), "selected": after.get(name)}
            for name in sorted(before.keys() | after.keys()) if before.get(name) != after.get(name)}


def execute(project, *, apply=False, scope="all", mihomo_version=None,
            toolchain_cache=None, go_module=(), pub=(), android=(), evidence=None,
            prepared_resources=None, reuse_version=False):
    """check 与 apply 解析同一候选；只有 apply 写回项目输入。"""
    require(scope in ("all", "mihomo"), "依赖更新 scope 必须为 all 或 mihomo")
    require(mihomo_version is None or scope == "mihomo", "--mihomo-version 需要 --scope mihomo")
    require(not (scope == "mihomo" and (go_module or pub or android or prepared_resources)),
            "mihomo 范围不接受其他依赖或资源选择")
    require(apply or not (evidence or reuse_version or prepared_resources),
            "版本操作、证据和已准备资源需要 apply")
    started = time.monotonic()
    logging.info("开始依赖%s，范围：%s", "更新" if apply else "检查", scope)
    root = Path(project).resolve()
    previous_version = application_version(root)
    before = snapshot(root)
    identity = working_tree_identity(root)
    original_record = resources.read_release_resources(root)
    target = mihomo_version or mihomo_release()
    with tempfile.TemporaryDirectory(prefix="clash-dependencies-") as temporary:
        base = Path(temporary)
        work = base / "project"
        work.mkdir()
        copy_workspace(root, work)
        require(snapshot(work) == before, "复制期间输入文件发生变化")
        selected_tools = original_record["toolchains"]
        environment, _ = toolchains.prepare(
            selected_tools, Path(toolchain_cache or Path.home() / ".cache/clash-pseudo/toolchains"), work)
        go_binary = str(Path(environment["PATH"].split(os.pathsep)[1]) / "go")
        flutter_binary = str(Path(environment["PATH"].split(os.pathsep)[0]) / "flutter")
        updater = Updater(work, go_binary, flutter_binary, env=environment)
        old_modules, manifest = module_versions(updater)
        current = old_modules[MIHOMO]
        go_names = ([MIHOMO] if scope == "mihomo" else list(go_module) or
                    [row["Path"] for row in manifest["Require"] if not row.get("Indirect")])
        logging.info("查询 Go 依赖更新，mihomo 目标：%s", target)
        go_updates = updater.go_updates(go_names, target)
        pub_updates, android_updates = {}, {}
        if scope == "all":
            # hosted、SDK 与 path 来源由 Pub 的依赖图区分。
            pub_names = list(pub)
            android_names = list(android) or sorted({m["name"] for m in MAVEN_DECLARATION.finditer(
                (work / "android/app/build.gradle.kts").read_text(encoding="utf-8"))})
            logging.info("解析 Pub 依赖更新")
            pub_updates = updater.pub_updates(pub_names)
            updater.update_pub(pub_updates)
            logging.info("解析 Maven 依赖更新")
            android_updates = updater.android_updates(android_names)
            if android_updates:
                updater.update_android(android_updates)
        if go_updates or scope == "all":
            updater.update_go(go_updates)
        new_modules, _ = module_versions(updater)
        selected_mihomo = updater.go_run("list", "-mod=readonly", "-m", "-f", "{{.Version}}", MIHOMO).strip()
        for name in go_names:
            updater.resolution["go"].setdefault(name, {})["selected"] = new_modules.get(name)
        go_changes = changes_between(old_modules, new_modules)
        legal = updater.legal(base)
        if scope == "all" or go_changes:
            logging.info("更新 Go 依赖许可")
            legal.go_notices()
        if scope == "all":
            logging.info("检查 Pub 依赖许可")
            legal.pub_licenses()
            logging.info("更新 Maven 依赖许可")
            legal.android_notices()
        version = application_version(work)
        candidate = copy.deepcopy(original_record)
        prepared = prepared_resources
        if scope == "all":
            if prepared is None:
                logging.info("准备 CA、Geo 资源及对应源码")
                delivery = sources.delivery_resources(work, base / "delivery", prepare=True)
                prepared, source_manifest = delivery["prepared"], delivery["sources"]
            else:
                source_manifest = Path(prepared).parent / "resource-sources/resource-sources.json"
            metadata = resources.read_resource_sources(source_manifest.parent)
            candidate = json.loads(sources.resource_changes(
                work, resources.prepared_resources(prepared), delivery_version=version,
                source_metadata=metadata, toolchains=selected_tools,
                dependencies=selected_dependencies(original_record.get("dependencies", {}), updater.resolution)
            )[resources.RESOURCE_RECORD])
        elif go_changes:
            # 只同步本次 Go 求解的实际变化，Pub／Maven／工具链／资源字段保持原值。
            selected_go = candidate.setdefault("dependencies", {}).setdefault("go", {})
            for name, change in go_changes.items():
                if change["selected"] is None:
                    selected_go.pop(name, None)
                else:
                    selected_go[name] = {"selected": change["selected"]}
        if stable_record(candidate) != stable_record(original_record):
            (work / resources.RESOURCE_RECORD).write_bytes(json_bytes(candidate))
        dependency_files = [name for name, data in snapshot(work).items() if data != before[name]]
        changed = bool(dependency_files)
        if not reuse_version and changed:
            text, version = bump_version((work / "pubspec.yaml").read_text(encoding="utf-8"))
            (work / "pubspec.yaml").write_text(text, encoding="utf-8")
        if changed:
            candidate["application"] = version
            (work / resources.RESOURCE_RECORD).write_bytes(json_bytes(candidate))
            resources.prepare_bundled_assets(work, prepared=prepared)
            if scope == "all":
                updater.run([updater.flutter, "pub", "get", "--enforce-lockfile"], work)
            updater.go_run("list", "-mod=readonly", "-m", "all")
        if evidence:
            updater.evidence(Path(evidence).resolve())
        after = snapshot(work)
        files = sorted(name for name in INPUTS if before[name] != after[name])
        check_working_tree(root, identity)
        if apply and files:
            logging.info("写回 %d 个依赖输入文件，应用版本：%s", len(files), version)
            publish_changes(root, before, after)
        report = {
            "status": ("updated" if apply else "available") if files else "unchanged",
            "changed": bool(files), "scope": scope, "version": version,
            "previousVersion": previous_version,
            "mihomo": {"previous": current, "selected": selected_mihomo},
            "go": {name: row["selected"] for name, row in go_changes.items()},
            "pub": {name: row[0] for name, row in pub_updates.items()}, "android": android_updates,
            "files": files, "resolution": updater.resolution,
            "toolchains": {},
            "resources": changes_between(original_record["resources"], candidate["resources"]),
        }
    logging.info("依赖处理完成：%s，变化文件 %d 个，耗时 %.1f 秒", report["status"], len(files), time.monotonic() - started)
    return report
