#!/usr/bin/env python3
"""Compare APK licenses, data assets, and native dependencies against current build inputs.

Run with python3 -I; --output-dir specifies an existing empty directory for native libraries and buildinfo.
--notices specifies the decoded NOTICES file generated from dependency sources; --go-modules and
--android-dependencies specify the current Go module graph and Gradle dependency report, respectively.
"""

import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile


ASSETS = (
    "LICENSE",
    "third_party/notices/mihomo.txt",
    "third_party/notices/go.txt",
    "third_party/notices/android.txt",
    "third_party/notices/material-icons.txt",
    "third_party/sources/re_editor/LICENSE",
    "build/generated/bundled/legal/certificates/NOTICE.txt",
    "build/generated/bundled/legal/certificates/MPL-2.0.txt",
    "third_party/notices/publicsuffix.txt",
    "build/generated/bundled/legal/geodata/NOTICE.txt",
    "build/generated/bundled/legal/geodata/CC-BY-SA-4.0.txt",
    "build/generated/bundled/legal/geodata/GeoSite-MIT.txt",
    "build/generated/bundled/legal/geodata/CC-BY-4.0.txt",
)
ABIS = {"armeabi-v7a": "arm", "arm64-v8a": "arm64", "x86_64": "amd64"}
# Bound archive member reads, including decompressed gzip content.
TEXT_LIMIT = 32 * 1024 * 1024
LIBRARY_LIMIT = 256 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def emit(label, **details):
    print(label + " " + json.dumps(details, ensure_ascii=False, sort_keys=True))


def go_modules(path):
    """Read consecutive JSON objects emitted by go list -m -json all."""
    text = path.read_text(encoding="utf-8").strip()
    decoder = json.JSONDecoder()
    modules = {}
    while text:
        module, end = decoder.raw_decode(text)
        require(isinstance(module, dict) and module.get("Path"), "Invalid Go module object")
        name = module["Path"]
        require(name not in modules, "Duplicate Go module: " + name)
        if not module.get("Main"):
            require(module.get("Version"), "Unversioned Go module: " + name)
        replacement = module.get("Replace")
        if replacement:
            require(isinstance(replacement, dict) and replacement.get("Path") and replacement.get("Version"),
                    "Local/unversioned Go replacement is not supported: " + name)
        modules[name] = module
        text = text[end:].strip()
    require(sum(bool(m.get("Main")) for m in modules.values()) == 1,
            "Go input must contain exactly one Main module")
    return modules


def android_coordinates(text):
    """Read the selected Maven coordinates from a dependency report."""
    require(re.search(r"^releaseRuntimeClasspath(?:\s|$)", text, re.M),
            "Expected a releaseRuntimeClasspath dependency report")
    selected = set()
    for line in text.splitlines():
        match = re.search(r"(?:\+---|\\---)\s+(\S+)(?:\s+->\s+(\S+))?", line)
        if not match:
            continue
        require("FAILED" not in line and "(n)" not in line,
                "Unresolved Android dependency: " + line.strip())
        if "(c)" in line:
            continue
        requested, chosen = match.groups()
        if requested == "project" and re.search(r"project\s+(?::[\w:.-]+|':[^'\s]+')(?:\s+\(\*\))?\s*$", line):
            # Flutter plugins build as local Gradle projects; check their Maven dependencies below
            # and verify plugin licenses in NOTICES.Z.
            continue
        parts = requested.split(":")
        require(len(parts) in (2, 3), "Unsupported Android dependency: " + requested)
        if chosen:
            parts = chosen.split(":") if ":" in chosen else parts[:2] + [chosen]
        require(len(parts) == 3 and all(parts), "Missing selected Maven coordinate: " + line.strip())
        if parts[0] != "io.flutter":
            selected.add(":".join(parts))
    require(selected, "No non-Flutter Android dependencies found")
    return selected


def parse_buildinfo(text):
    dependencies = {}
    settings = {}
    main = None
    previous = None
    for line in text.splitlines():
        fields = line.strip().split("\t")
        if fields[0] == "mod":
            require(len(fields) >= 3 and main is None, "Invalid Go main-module buildinfo")
            main = fields[1]
        elif fields[0] == "dep":
            require(len(fields) in (3, 4) and fields[1] not in dependencies,
                    "Invalid/duplicate Go buildinfo dependency")
            previous = fields[1]
            dependencies[previous] = {"Path": previous, "Version": fields[2],
                                      "Sum": fields[3] if len(fields) == 4 else ""}
        elif fields[0] == "=>":
            require(previous is not None and len(fields) in (3, 4)
                    and "Replace" not in dependencies[previous], "Invalid Go buildinfo replacement")
            dependencies[previous]["Replace"] = {
                "Path": fields[1], "Version": fields[2],
                "Sum": fields[3] if len(fields) == 4 else "",
            }
        elif fields[0] == "build":
            require(len(fields) == 2 and "=" in fields[1], "Invalid Go build setting")
            key, value = fields[1].split("=", 1)
            require(key not in settings, "Duplicate Go build setting: " + key)
            settings[key] = value
    require(main and dependencies, "Missing Go main module or dependencies in buildinfo")
    return main, dependencies, settings


def check_linked(main, dependencies, settings, abi, modules, notices):
    require(modules.get(main, {}).get("Main"), "Linked Go main module differs from input graph")
    require(settings.get("GOOS") == "android", abi + ": GOOS is not android")
    require(settings.get("GOARCH") == ABIS[abi], abi + ": GOARCH mismatch")
    if abi == "armeabi-v7a":
        require(settings.get("GOARM") in ("7", "7,hardfloat"), abi + ": GOARM must target ARMv7")
    require(set(settings.get("-tags", "").split(",")) == {"cmfa", "with_gvisor"},
            abi + ": production tags mismatch")
    for name, linked in dependencies.items():
        selected = modules.get(name)
        require(selected is not None, "Linked module absent from selected graph: " + name)
        for key in ("Version", "Sum"):
            require(linked[key] == selected.get(key, ""), name + ": linked " + key + " mismatch")
        replacement = linked.get("Replace")
        expected = selected.get("Replace")
        require(bool(replacement) == bool(expected), name + ": replacement presence mismatch")
        if replacement:
            require(all(replacement[k] == expected.get(k, "") for k in ("Path", "Version", "Sum")),
                    name + ": linked replacement mismatch")
        effective = replacement or linked
        require((effective["Path"], effective["Version"]) in notices,
                "Go notice missing linked version: " + effective["Path"] + " " + effective["Version"])


def read_entry(archive, name, limit):
    entry = archive.getinfo(name)
    require(entry.file_size <= limit, "Archive entry exceeds size limit: " + name)
    with archive.open(entry) as stream:
        data = stream.read(limit + 1)
    require(len(data) <= limit, "Archive entry exceeds size limit: " + name)
    return data








def check_public_suffix(root, module, source):
    """Compare the selected x/net compiled table revision, source notice, and editable PSL list."""
    effective = module.get("Replace") or module
    name, version = effective["Path"], effective["Version"]
    prefix = name + "@" + version + "/"
    with zipfile.ZipFile(source) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "x/net source archive contains duplicate members")
        require(all(path.startswith(prefix) and ".." not in path.split("/") for path in names),
                "x/net source archive path escapes the archive root")
        table = read_entry(archive, prefix + "publicsuffix/table.go", TEXT_LIMIT)
    revision = re.search(rb"git revision ([0-9a-f]{40})", table[:6000])
    require(revision, "Compiled publicsuffix table lacks a source commit")
    revision = revision[1].decode()
    notice = (root / "third_party/notices/publicsuffix.txt").read_text(encoding="utf-8")
    data = (root / "third_party/data/publicsuffix/public_suffix_list.dat").read_bytes()
    require(revision in notice and version in notice and digest(data) in notice,
            "PSL notice differs from the selected x/net source commit or editable sources")
    require(b"Mozilla Public" in data[:4096] and b"2.0" in data[:4096], "Editable PSL source lacks a license")
    result = {"verified": True, "module": name, "version": version, "revision": revision,
              "bytes": len(data), "sha256": digest(data), "table_sha256": digest(table)}
    emit("PUBLIC_SUFFIX", **result)
    return result


def check_platform_assets(archive, root):
    from tool.dependencies.resources import GENERATED_BUNDLED
    source = root / GENERATED_BUNDLED / "assets"
    expected = {}
    for directory in ("certificates", "geodata"):
        for path in sorted((source / directory).rglob("*")):
            if path.is_file():
                expected["assets/" + path.relative_to(source).as_posix()] = path
    actual_names = {name for name in archive.namelist()
                    if name.startswith(("assets/certificates/", "assets/geodata/")) and not name.endswith("/")}
    require(expected and actual_names == expected.keys(), "APK resource file set differs from the current generated inputs")
    for name, path in expected.items():
        actual = read_entry(archive, name, TEXT_LIMIT)
        require(actual == path.read_bytes(), "APK resource bytes differ from the current generated inputs: " + name)
        emit("PLATFORM_ASSET", entry=name, bytes=len(actual), sha256=digest(actual))


def verify(args):
    root = args.project.resolve()
    output = args.output_dir.resolve()
    require(output.is_dir() and not any(output.iterdir()), "Output directory must exist and be empty")
    modules = go_modules(args.go_modules)
    xnet_source = getattr(args, "xnet_source", None)
    if xnet_source is not None:
        require("golang.org/x/net" in modules, "Selected graph has no x/net module")
        check_public_suffix(root, modules["golang.org/x/net"], xnet_source)
    else:
        emit("PUBLIC_SUFFIX", verified=False, reason="Set --xnet-source to the original ZIP for the selected x/net module, then rerun PSL source verification")
    abis = tuple(getattr(args, "abis", None) or ABIS)
    require(len(set(abis)) == len(abis) and set(abis) <= ABIS.keys(), "Invalid target ABI selection")
    selected = android_coordinates(args.android_dependencies.read_text(encoding="utf-8"))
    android_notice = (root / "third_party/notices/android.txt").read_text(encoding="utf-8")
    notice_coordinates = set(re.findall(r"^([\w.-]+:[\w.-]+:[^\s:]+)$", android_notice, re.M))
    require(selected == notice_coordinates,
            "Android notice coordinates differ: missing=" + repr(sorted(selected - notice_coordinates))
            + "; extra=" + repr(sorted(notice_coordinates - selected)))
    emit("ANDROID_GRAPH", coordinates=len(selected))
    go_notice = (root / "third_party/notices/go.txt").read_text(encoding="utf-8")
    notice_modules = set(re.findall(r"^([\w.-]+(?:/[\w.+~-]+)+) (v[^\s]+)$", go_notice, re.M))
    expected_notices = args.notices.read_bytes()
    require(expected_notices and len(expected_notices) <= TEXT_LIMIT,
            "Reference NOTICES must be nonempty text within the size limit")
    expected_notices.decode("utf-8")
    with args.apk.open("rb") as stream:
        apk_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    emit("APK", path=str(args.apk.resolve()), sha256=apk_hash)
    with zipfile.ZipFile(args.apk) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate APK archive names")
        for relative in ASSETS:
            name = "assets/flutter_assets/" + relative
            actual = read_entry(archive, name, TEXT_LIMIT)
            require(actual == (root / relative).read_bytes(), "License asset bytes differ: " + relative)
            emit("LICENSE_ASSET", entry=name, bytes=len(actual), sha256=digest(actual))
        compressed = read_entry(archive, "assets/flutter_assets/NOTICES.Z", TEXT_LIMIT)
        # Decompress in chunks with GzipFile.read and bound the expanded size.
        with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as stream:
            notices = stream.read(TEXT_LIMIT + 1)
        require(notices == expected_notices, "Decompressed NOTICES.Z differs from the specified NOTICES file")
        emit("NOTICES", bytes=len(notices), sha256=digest(notices))
        check_platform_assets(archive, root)
        libraries = sorted(n for n in names if n.startswith("lib/") and n.endswith("/libmihomo_bridge.so"))
        require(libraries == sorted("lib/" + abi + "/libmihomo_bridge.so" for abi in abis),
                "Expected exactly the selected native bridge ABIs: " + ", ".join(abis))
        packaged_abis = {name.split("/")[1] for name in names if name.startswith("lib/") and len(name.split("/")) >= 3}
        require(packaged_abis == set(abis), "Packaged native ABIs differ from selected targets")
        graphs = []
        for name in libraries:
            abi = name.split("/")[1]
            directory = output / abi
            directory.mkdir()
            library = directory / "libmihomo_bridge.so"
            data = read_entry(archive, name, LIBRARY_LIMIT)
            library.write_bytes(data)
            env = dict(os.environ, GOTOOLCHAIN="local", GOPROXY="off", GOSUMDB="off", GOENV="off")
            process = subprocess.run([args.go, "version", "-m", str(library)], cwd=root,
                                     env=env, text=True, capture_output=True, timeout=30)
            (directory / "buildinfo.txt").write_text(process.stdout + process.stderr, encoding="utf-8")
            require(process.returncode == 0, abi + ": go version -m failed; see buildinfo.txt")
            main, dependencies, settings = parse_buildinfo(process.stdout)
            check_linked(main, dependencies, settings, abi, modules, notice_modules)
            emit("BUILDINFO", abi=abi, dependencies=len(dependencies), sha256=digest(data))
            graphs.append(dependencies)
        require(all(graph == graphs[0] for graph in graphs[1:]),
                "Native ABIs link different Go dependency graphs")
    emit("FINAL", exit_code=0, scope="License and data asset bytes, per-ABI Go buildinfo, and selected dependency graphs")


def register_parser(subparsers):
    parser = subparsers.add_parser("verify-release-licenses", help="Verify APK licenses, resources, and Go buildinfo", description=__doc__)
    parser.add_argument("--project", required=True, type=Path, help="Project root for the current build")
    parser.add_argument("--apk", required=True, type=Path, help="Path to the APK to verify")
    parser.add_argument("--notices", required=True, type=Path, help="Decoded NOTICES file generated from dependency sources")
    parser.add_argument("--abi", dest="abis", action="append", choices=tuple(ABIS),
                        help="Expected APK ABI; repeat for universal APKs, defaulting to all three ABIs")
    parser.add_argument("--go-modules", required=True, type=Path, help="Current go list -m -json all output file")
    parser.add_argument("--xnet-source", type=Path,
                        help="Original ZIP for the selected x/net module to verify the PSL commit and editable list")
    parser.add_argument("--android-dependencies", required=True, type=Path,
                        help="Current Gradle releaseRuntimeClasspath dependency report")
    parser.add_argument("--output-dir", required=True, type=Path, help="Existing empty directory for per-ABI native libraries and buildinfo.txt")
    parser.add_argument("--go", default="go", help="Name or path of the installed Go executable")
    parser.set_defaults(handler=verify, command_parser=parser)
    return parser
