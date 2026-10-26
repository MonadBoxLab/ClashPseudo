#!/usr/bin/env python3
"""用显式选择的工具链构建 self-target SDK 观察器。"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "android/app/src/androidTest/java/io/github/monadboxlab/clashpseudo/validation/SystemEntryInstrumentation.java"
PACKAGE = "io.github.monadboxlab.clashpseudo.test"
RUNNER = "io.github.monadboxlab.clashpseudo.validation.SystemEntryInstrumentation"


def manifest(min_api, target_sdk):
    return f'''<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="{PACKAGE}" android:versionCode="1" android:versionName="1">
    <uses-sdk android:minSdkVersion="{min_api}" android:targetSdkVersion="{target_sdk}"/>
    <instrumentation android:name="{RUNNER}" android:targetPackage="{PACKAGE}"
        android:functionalTest="true" android:handleProfiling="false"/>
    <application android:label="SDK observation" android:allowBackup="false"/>
</manifest>
'''


def build(android_jar, build_tools, keystore, output, *, java_release, min_api, target_sdk, javac="javac"):
    jar, tools, keystore, output = (path.resolve() for path in (android_jar, build_tools, keystore, output))
    temporary_root = Path(tempfile.gettempdir()).resolve()
    if (output == temporary_root or not output.is_relative_to(temporary_root) or
            output.is_relative_to(ROOT)):
        raise ValueError("验证构建物必须写入仓库外的系统临时目录中的新目录")
    # 观察器使用的公开 API 要求 min API 至少为 24。
    if (any(type(value) is not int for value in (java_release, min_api, target_sdk)) or
            java_release <= 0 or min_api < 24 or target_sdk < min_api):
        raise ValueError("明确提供 Java 编译目标、满足公开 API 下限的 min API 及 target SDK")
    compiler = shutil.which(javac)
    if not compiler or not keystore.is_file() or not SOURCE.is_file():
        raise ValueError("需要现有 javac、显式 debug keystore 和仓库中的正式观察器源码")
    for path in [jar, *(tools / name for name in ("aapt2", "d8", "zipalign", "apksigner"))]:
        if not path.is_file():
            raise ValueError("缺少显式工具链文件：" + str(path))
    # 在独立的新目录中生成构建材料。
    output.mkdir(parents=True, exist_ok=False)
    source_hash = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
    commands = []

    def run(name, command):
        command = [str(part) for part in command]
        record = {"name": name, "command": command, "exit": None}
        commands.append(record)
        try:
            with (output / (name + ".log")).open("xb") as log:
                value = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=120)
            record["exit"] = value.returncode
            value.check_returncode()
        finally:
            (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")

    xml = output / "AndroidManifest.xml"
    xml.write_text(manifest(min_api, target_sdk))
    classes, dex = output / "classes", output / "dex"
    classes.mkdir()
    dex.mkdir()
    run("javac-version", [compiler, "-version"])
    run("javac", [compiler, "--release", java_release, "-cp", jar, "-d", classes, SOURCE])
    class_files = sorted(classes.rglob("*.class"))
    if not class_files:
        raise RuntimeError("观察器未产生 class 文件")
    run("d8-version", [tools / "d8", "--version"])
    run("d8", [tools / "d8", "--release", "--min-api", min_api, "--lib", jar,
               "--output", dex, *class_files])
    unsigned = output / "unsigned.apk"
    run("aapt2", [tools / "aapt2", "link", "--manifest", xml, "-I", jar, "-o", unsigned])
    with zipfile.ZipFile(unsigned, "a") as archive:
        archive.write(dex / "classes.dex", "classes.dex")
    aligned, apk = output / "aligned.apk", output / "observer.apk"
    run("zipalign", [tools / "zipalign", "-P", "16", "4", unsigned, aligned])
    run("sign", [tools / "apksigner", "sign", "--ks", keystore, "--ks-key-alias", "androiddebugkey",
                 "--ks-pass", "pass:android", "--key-pass", "pass:android", "--out", apk, aligned])
    run("verify-signature", [tools / "apksigner", "verify", "--verbose", apk])
    run("verify-manifest", [tools / "aapt2", "dump", "xmltree", apk, "--file", "AndroidManifest.xml"])
    if source_hash != hashlib.sha256(SOURCE.read_bytes()).hexdigest():
        raise RuntimeError("构建期间观察器源码已改变")
    result = {"sourceSha256": source_hash, "apkSha256": hashlib.sha256(apk.read_bytes()).hexdigest(),
              "bytes": apk.stat().st_size, "package": PACKAGE, "targetPackage": PACKAGE,
              "runner": RUNNER, "minApi": min_api, "targetSdk": target_sdk, "javaRelease": java_release,
              "androidJar": str(jar), "buildTools": str(tools), "javac": compiler,
              "scope": "self-target SDK 观察器构建"}
    (output / "build.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--android-jar", type=Path, required=True, help="当前选择的 Android 平台 jar")
    parser.add_argument("--build-tools", type=Path, required=True, help="当前选择的现有 Build Tools 目录")
    parser.add_argument("--javac", default="javac", help="现有 javac 命令或路径；默认从 PATH 选择")
    parser.add_argument("--java-release", type=int, required=True, help="当前项目的 Java 编译目标")
    parser.add_argument("--min-api", type=int, required=True, help="公开观察器要求 API24 起")
    parser.add_argument("--target-sdk", type=int, required=True, help="观察器的 target SDK")
    parser.add_argument("--debug-keystore", type=Path, required=True,
                        help="标准 androiddebugkey keystore")
    parser.add_argument("--output", type=Path, required=True, help="仓库外系统临时目录中的新产物目录")
    args = parser.parse_args()
    print(json.dumps(build(args.android_jar, args.build_tools, args.debug_keystore, args.output,
                           java_release=args.java_release, min_api=args.min_api,
                           target_sdk=args.target_sdk, javac=args.javac), ensure_ascii=False))


if __name__ == "__main__":
    main()
