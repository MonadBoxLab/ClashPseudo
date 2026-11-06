"""检查 APK 的签名、原生库对齐及实际法律资产。"""

import argparse
import hashlib
import json
from pathlib import Path

from tool.common.io import require
from tool.common.process import run
from tool.dependencies import resources
from tool.artifacts import verify_release_licenses as licenses


def sdk_tools(project, environment):
    record = resources.read_release_resources(project)
    package = record["toolchains"]["selected"]["android"]["buildTools"]["package"]
    sdk = environment.get("ANDROID_HOME") or environment["ANDROID_SDK_ROOT"]
    return Path(sdk) / package.replace(";", "/")


def xnet_source(updater, evidence):
    modules = licenses.go_modules(evidence / "go-modules.json")
    selected = modules["golang.org/x/net"]
    effective = selected.get("Replace") or selected
    metadata = json.loads(updater.go_run(
        "mod", "download", "-json", effective["Path"] + "@" + effective["Version"]))
    return Path(metadata["Zip"])


def verify_apk(updater, apk, evidence, output, abis):
    source = xnet_source(updater, evidence)
    tools = sdk_tools(updater.root, updater.env)

    def command(arguments):
        return run(arguments, updater.root, env=updater.env)

    command([tools / "apksigner", "verify", "--verbose", apk])
    command([tools / "zipalign", "-c", "-P", "16", "4", apk])
    output.mkdir(parents=True)
    licenses.verify(argparse.Namespace(
        project=updater.root, apk=apk, notices=evidence / "NOTICES", go_modules=evidence / "go-modules.json",
        android_dependencies=evidence / "android-dependencies.txt", output_dir=output,
        go=updater.go, abis=abis, xnet_source=source))
    fingerprints = {}
    for abi in abis:
        library = output / abi / "libmihomo_bridge.so"
        programs = command(["readelf", "-lW", library])
        loads = [line.split() for line in programs.splitlines() if line.lstrip().startswith("LOAD ")]
        require(loads and all(int(line[-1], 0) >= 16384 for line in loads), "ELF LOAD 对齐小于 16 KiB")
        sections = command(["readelf", "-SW", library])
        require(not any(name in sections for name in ("__llvm_prf", "__llvm_cov")), "原生库包含覆盖率插桩")
        _, _, settings = licenses.parse_buildinfo((output / abi / "buildinfo.txt").read_text(encoding="utf-8"))
        require("-cover" not in settings, "Go 库包含覆盖率插桩")
        with library.open("rb") as stream:
            fingerprints[abi] = hashlib.file_digest(stream, "sha256").hexdigest()
    return fingerprints
