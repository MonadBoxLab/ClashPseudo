#!/usr/bin/env python3
"""Verify the manifest and three application data files in a SAF backup ZIP; --compare compares data content across two backups."""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import zipfile

MIB = 1024 * 1024
LIMITS = {"configurations.json": 128 * MIB, "overrides.json": 128 * MIB,
          "preferences.json": MIB, "manifest.json": 65536}
PARTS = tuple(name for name in LIMITS if name != "manifest.json")
CHUNK = 65536


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Manifest contains duplicate keys")
        result[key] = value
    return result


def fingerprint(stream, limit):
    size, digest = 0, hashlib.sha256()
    while chunk := stream.read(CHUNK):
        size += len(chunk)
        if size > limit:
            raise ValueError("Actual expanded bytes exceed the limit")
        digest.update(chunk)
    return {"bytes": size, "sha256": digest.hexdigest()}


def inspect_parts(archive):
    entries = archive.infolist()
    if len(entries) != 4 or {item.filename for item in entries} != set(LIMITS):
        raise ValueError("Backup must contain exactly manifest.json and the three specified application data files")
    if sum(item.file_size for item in entries) > 256 * MIB:
        raise ValueError("Expanded backup bytes exceed the limit")
    for item in entries:
        if (item.is_dir() or item.flag_bits & 1 or item.file_size < 0 or
                item.file_size > LIMITS[item.filename] or
                item.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)):
            raise ValueError("Backup entry type, encryption, compression, or size is outside the verification scope")
    with archive.open("manifest.json") as stream:
        raw = stream.read(LIMITS["manifest.json"] + 1)
    if len(raw) > LIMITS["manifest.json"]:
        raise ValueError("Actual manifest bytes exceed the limit")
    manifest = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    if (not isinstance(manifest, dict) or manifest.get("format") != "clash-pseudo-backup" or
            type(manifest.get("version")) is not int or manifest["version"] != 1 or
            type(manifest.get("createdAtMillis")) is not int or manifest["createdAtMillis"] < 0 or
            not isinstance(manifest.get("files"), dict) or set(manifest["files"]) != set(PARTS)):
        raise ValueError("Invalid backup manifest format, version, or fields")
    result = {}
    for name in PARTS:
        expected = manifest["files"][name]
        if (not isinstance(expected, dict) or set(expected) != {"bytes", "sha256"} or
                type(expected.get("bytes")) is not int or not 0 <= expected["bytes"] <= LIMITS[name] or
                not isinstance(expected.get("sha256"), str) or
                not re.fullmatch(r"[0-9a-f]{64}", expected["sha256"])):
            raise ValueError("Invalid manifest file digest format")
        # Read to EOF so the ZIP reader validates CRC while computing actual size and SHA-256.
        with archive.open(name) as stream:
            actual = fingerprint(stream, LIMITS[name])
        if actual != expected:
            raise ValueError("Actual file bytes differ from the manifest: " + name)
        result[name] = actual
    return result


def identity(stream):
    value = os.fstat(stream.fileno())
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns


@contextmanager
def open_archive(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        stream = os.fdopen(descriptor, "rb")
    except BaseException:
        os.close(descriptor)
        raise
    with stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("Only regular backup files are accepted")
        yield stream


def inspect_archive(path):
    with open_archive(path) as stream:
        before = identity(stream)
        if before[2] > 256 * MIB:
            raise ValueError("Compressed backup exceeds the limit")
        with zipfile.ZipFile(stream) as archive:
            parts = inspect_parts(archive)
        stream.seek(0)
        whole = fingerprint(stream, 256 * MIB)
        if identity(stream) != before:
            raise ValueError("Input file changed during verification")
        return {"archiveBytes": whole["bytes"], "archiveSha256": whole["sha256"], "parts": parts}


def compare_archives(first, second):
    with open_archive(first) as left, open_archive(second) as right:
        before = identity(left), identity(right)
        if any(value[2] > 256 * MIB for value in before):
            raise ValueError("Compressed backup exceeds the limit")
        with zipfile.ZipFile(left) as a, zipfile.ZipFile(right) as b:
            parts_a, parts_b = inspect_parts(a), inspect_parts(b)
            for name in PARTS:
                with a.open(name) as x, b.open(name) as y:
                    while True:
                        chunk = x.read(CHUNK)
                        if chunk != y.read(CHUNK):
                            raise ValueError("The three application data files are not byte-for-byte identical: " + name)
                        if not chunk:
                            break
            if parts_a != parts_b:
                raise ValueError("Application data file digests differ")
        if (identity(left), identity(right)) != before:
            raise ValueError("Input file changed during comparison")
        return {"threeBusinessFilesByteIdentical": True, "parts": parts_a}


def register_parser(subparsers):
    parser = subparsers.add_parser(
        "verify-backup", help="Verify backup ZIPs and compare application data files byte for byte", description=__doc__,
        epilog="Example: artifacts verify-backup /tmp/backup.zip --compare /tmp/second.zip; leaves inputs unchanged and outputs JSON.")
    parser.add_argument("archive", type=Path)
    parser.add_argument("--compare", type=Path, help="Second SAF-exported ZIP for byte-for-byte comparison of configurations.json, overrides.json, and preferences.json")
    parser.set_defaults(handler=run)


def run(args):
    try:
        result = compare_archives(args.archive, args.compare) if args.compare else inspect_archive(args.archive)
    except KeyboardInterrupt:
        print(json.dumps({"status": "cancelled", "scope": "Backup verification cancelled"}, ensure_ascii=False))
        return 130
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as error:
        print(json.dumps({"status": "failed", "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0
