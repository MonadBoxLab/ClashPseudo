"""使用固定候选运行测试，并为分发准备 release APK 与对应源码。"""

import contextlib
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

from tool.common.io import require
from tool.common.process import run
from tool.dependencies import inputs, resources, toolchains
from tool.dependencies.versions import application_version

ABIS = ("armeabi-v7a", "arm64-v8a", "x86_64")


def input_identity(project):
    return {name: hashlib.sha256(data).hexdigest() if data is not None else None
            for name, data in inputs.snapshot(project).items()}


def _save(path, report):
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _command(arguments, root, environment, output, report, label):
    log = output / (label + ".log")
    entry = {"name": label, "command": list(map(str, arguments)), "log": log.name}
    report["steps"].append(entry)
    print("执行：" + label, file=sys.stderr, flush=True)
    with log.open("w", encoding="utf-8") as stream:
        stream.write(json.dumps(entry["command"], ensure_ascii=False) + "\n")
        stream.flush()
        result = subprocess.run(entry["command"], cwd=root, env=environment,
                                stdout=stream, stderr=subprocess.STDOUT, check=False)
    entry["exitCode"] = result.returncode
    require(result.returncode == 0, f"{label} 失败（{result.returncode}），原始输出：{log}")


def _operation(function, output, report, label):
    log = output / (label + ".log")
    entry = {"name": label, "log": log.name, "exitCode": 1}
    report["steps"].append(entry)
    with log.open("w", encoding="utf-8") as stream, \
            contextlib.redirect_stdout(stream), contextlib.redirect_stderr(stream):
        try:
            result = function()
        except Exception as error:
            print(str(error), file=stream)
            raise
    entry["exitCode"] = 0
    return result


def _output_paths(project, output):
    root, output = Path(project).resolve(), Path(output).resolve()
    require(not output.is_relative_to(root), "验证材料须保存在项目之外")
    output.mkdir(parents=True)
    return root, output


def _prepare(root, toolchain_cache):
    from tool.dependencies.packages import Updater

    record = resources.read_release_resources(root)
    environment, _ = toolchains.prepare(record["toolchains"],
        Path(toolchain_cache or Path.home() / ".cache/clash-pseudo/toolchains"), root)
    environment = {**os.environ, **environment, "GOTOOLCHAIN": "local", "GOWORK": "off"}
    go = shutil.which("go", path=environment["PATH"])
    flutter = shutil.which("flutter", path=environment["PATH"])
    require(go and flutter, "固定工具链缺少 Go 或 Flutter")
    return environment, Updater(root, go=go, flutter=flutter, env=environment)


def validate(project, output, *, toolchain_cache=None):
    root, output = _output_paths(project, output)
    report = {"status": "failed", "steps": []}
    report_path = output / "validation.json"
    try:
        environment, updater = _prepare(root, toolchain_cache)
        report.update(inputs=input_identity(root), commit=run(["git", "rev-parse", "HEAD"], root).strip())
        _operation(lambda: resources.prepare_bundled_assets(root), output, report, "resources")
        commands = (
            ("contracts", [sys.executable, "-I", "-B", root / "tool/main.py", "contracts", "check"]),
            ("python-tests", [sys.executable, "-I", "-B", "-m", "unittest", "discover", "-s", "test/tool", "-p", "test_*.py"]),
            ("flutter-pub", [updater.flutter, "pub", "get", "--enforce-lockfile"]),
            ("flutter-analyze", [updater.flutter, "analyze"]),
            ("flutter-test", [updater.flutter, "test"]),
            ("go-modules", [updater.go, "-C", root / "native/mihomo", "mod", "verify"]),
            ("go-test", [updater.go, "-C", root / "native/mihomo", "test", "-mod=readonly", "-tags=cmfa,with_gvisor", "./...", "-count=1"]),
            ("go-vet", [updater.go, "-C", root / "native/mihomo", "vet", "-mod=readonly", "-tags=cmfa,with_gvisor", "./..."]),
        )
        for label, arguments in commands:
            _command(arguments, root, environment, output, report, label)
            _save(report_path, report)
        require(input_identity(root) == report["inputs"], "测试期间候选输入发生变化")
        report["status"] = "verified"
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        if report_path.parent.is_dir():
            _save(report_path, report)
    return report


def release_apks(root):
    metadata_path = root / "build/app/outputs/apk/release/output-metadata.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    apks = {}
    for item in metadata["elements"]:
        abi = next((entry["value"] for entry in item["filters"] if entry["filterType"] == "ABI"), "universal")
        path = (metadata_path.parent / item["outputFile"]).resolve()
        require(path.is_relative_to(metadata_path.parent.resolve()), "APK 输出路径越界")
        require(abi not in apks, "APK 输出重复：" + abi)
        apks[abi] = path
    require(set(apks) == {"universal", *ABIS}, "release 构建须生成通用及三个分 ABI APK")
    return apks


def _source_assets(updater, evidence, output, version, commit):
    from tool.artifacts import package_sources, verify_release_licenses
    from tool.dependencies.sources import prepare_resource_sources

    record = resources.read_release_resources(updater.root)
    source_inputs = prepare_resource_sources(record["resources"], output / "resource-sources")
    source = output / f"clash-pseudo-{version}-sources.tar.gz"
    package_sources.create(updater, evidence, source, commit=commit, resource_sources=source_inputs)
    licenses = output / f"clash-pseudo-{version}-licenses.tar.gz"
    with licenses.open("xb") as stream, gzip.GzipFile(filename="", fileobj=stream, mode="wb", mtime=0) as compressed, \
            tarfile.open(fileobj=compressed, mode="w|") as archive:
        for name in ("NOTICE.md", "doc/legal/dependencies.md", "third_party/data/resources.json", *verify_release_licenses.ASSETS):
            package_sources.add_bytes(archive, name, (updater.root / name).read_bytes())
    return [source.name, licenses.name]


def build_release(project, output, *, commit, toolchain_cache=None):
    from tool.artifacts.android_apk import verify_apk

    root, output = _output_paths(project, output)
    report = {"status": "failed", "steps": [], "assets": []}
    report_path = output / "build.json"
    try:
        environment, updater = _prepare(root, toolchain_cache)
        require(run(["git", "rev-parse", "HEAD"], root).strip() == commit, "构建提交与候选提交不同")
        report.update(inputs=input_identity(root), commit=commit, version=application_version(root),
                      mihomo=updater.go_run("list", "-mod=readonly", "-m", "-f", "{{.Version}}",
                                           "github.com/metacubex/mihomo").strip())
        evidence = output / "evidence"
        _operation(lambda: updater.evidence(evidence), output, report, "evidence")
        _command([updater.flutter, "build", "apk", "--release", "--no-pub", "--split-per-abi", "--target-platform",
                  "android-arm,android-arm64,android-x64"], root, environment, output, report, "release-apks")
        version = report["version"]
        for abi, apk in release_apks(root).items():
            abis = ABIS if abi == "universal" else (abi,)
            destination = output / f"clash-pseudo-{version}-{abi}.apk"
            shutil.copy2(apk, destination)
            _operation(lambda: verify_apk(updater, destination, evidence, output / "verification" / abi, abis),
                       output, report, "apk-" + abi)
            report["assets"].append(destination.name)
        report["assets"].extend(_operation(
            lambda: _source_assets(updater, evidence, output, version, commit), output, report, "sources"))
        sums = []
        for name in report["assets"]:
            with (output / name).open("rb") as stream:
                sums.append(hashlib.file_digest(stream, "sha256").hexdigest() + "  " + name + "\n")
        (output / "SHA256SUMS").write_text("".join(sums), encoding="utf-8")
        report["assets"].append("SHA256SUMS")
        require(input_identity(root) == report["inputs"], "构建期间候选输入发生变化")
        report["status"] = "built"
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        if report_path.parent.is_dir():
            _save(report_path, report)
    return report
