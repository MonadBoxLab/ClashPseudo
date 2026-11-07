#!/usr/bin/env python3
"""Build an SDK observer targeting its own test package with the specified toolchain."""
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
        raise ValueError("Build output must use a new directory outside the repository under the system temporary directory")
    # Android APIs used by the SDK observer require API level 24 or higher.
    if (any(type(value) is not int for value in (java_release, min_api, target_sdk)) or
            java_release <= 0 or min_api < 24 or target_sdk < min_api):
        raise ValueError("Java release must be a positive integer; minimum Android API must be at least 24 and target API must be an integer no lower than the minimum")
    compiler = shutil.which(javac)
    if not compiler or not keystore.is_file() or not SOURCE.is_file():
        raise ValueError("javac, the specified debug keystore, or the repository SDK observer source was not found")
    for path in [jar, *(tools / name for name in ("aapt2", "d8", "zipalign", "apksigner"))]:
        if not path.is_file():
            raise ValueError("Toolchain file does not exist: " + str(path))
    # Create a directory for build outputs and command logs.
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
        raise RuntimeError("javac did not generate SDK observer class files")
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
        raise RuntimeError("SDK observer source changed during the build")
    result = {"sourceSha256": source_hash, "apkSha256": hashlib.sha256(apk.read_bytes()).hexdigest(),
              "bytes": apk.stat().st_size, "package": PACKAGE, "targetPackage": PACKAGE,
              "runner": RUNNER, "minApi": min_api, "targetSdk": target_sdk, "javaRelease": java_release,
              "androidJar": str(jar), "buildTools": str(tools), "javac": compiler,
              "scope": "SDK observer build targeting its own test package"}
    (output / "build.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return result


def register_parser(subparsers):
    parser = subparsers.add_parser(
        "build-sdk-observer", help="Build a standalone SDK observer APK", description=__doc__,
        epilog="Example: android build-sdk-observer --android-jar /sdk/platforms/android-36/android.jar "
               "--build-tools /sdk/build-tools/<version> --java-release 17 --min-api 24 --target-sdk 36 "
               "--debug-keystore /tmp/debug.keystore --output /tmp/observer-build")
    parser.add_argument("--android-jar", type=Path, required=True, help="Path to the Android platform android.jar")
    parser.add_argument("--build-tools", type=Path, required=True, help="Android SDK Build Tools directory")
    parser.add_argument("--javac", default="javac", help="javac command or path; defaults to searching PATH")
    parser.add_argument("--java-release", type=int, required=True, help="Java target release")
    parser.add_argument("--min-api", type=int, required=True, help="Minimum Android API level, at least 24")
    parser.add_argument("--target-sdk", type=int, required=True, help="Target Android API level for the SDK observer")
    parser.add_argument("--debug-keystore", type=Path, required=True,
                        help="Debug signing keystore containing the androiddebugkey alias")
    parser.add_argument("--output", type=Path, required=True, help="New directory outside the repository under the system temporary directory for build outputs")
    parser.set_defaults(handler=run)


def run(args):
    return build(args.android_jar, args.build_tools, args.debug_keystore, args.output,
                 java_release=args.java_release, min_api=args.min_api,
                 target_sdk=args.target_sdk, javac=args.javac)
