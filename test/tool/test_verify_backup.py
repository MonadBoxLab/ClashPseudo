"""备份核验工具只读取、校验摘要及比较原始字节，不替代应用准入／事务测试。"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("backup_verifier", ROOT / "tool/artifacts/verify_backup.py")
assert SPEC is not None and SPEC.loader is not None
TOOL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOL)


class VerifyBackupTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="backup-verify-")
        self.root = Path(self.temporary.name)
        self.values = {"configurations.json": b'{"entries":[]}\r\n',
                       "overrides.json": b' {"entries":[]}\n',
                       "preferences.json": '{"language":"zh","unknown":"测试"}\n'.encode()}

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, name="backup.zip", values=None, change=None, raw_manifest=None,
              compression=zipfile.ZIP_DEFLATED, extra=None, created=1):
        values = self.values if values is None else values
        manifest = {"format": "clash-pseudo-backup", "version": 1, "createdAtMillis": created,
                    "files": {part: {"bytes": len(body), "sha256": hashlib.sha256(body).hexdigest()}
                              for part, body in values.items()}}
        if change:
            change(manifest)
        path = self.root / name
        with zipfile.ZipFile(path, "w", compression=compression) as archive:
            archive.writestr("manifest.json", raw_manifest if raw_manifest is not None else json.dumps(manifest))
            for part, body in values.items():
                archive.writestr(part, body)
            if extra:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    archive.writestr(*extra)
        return path

    def test_inspect_checks_actual_bytes_and_does_not_expose_body(self):
        path = self.write()
        result = TOOL.inspect_archive(path)
        self.assertEqual(result["archiveSha256"], hashlib.sha256(path.read_bytes()).hexdigest())
        for part, body in self.values.items():
            self.assertEqual(result["parts"][part], {"bytes": len(body), "sha256": hashlib.sha256(body).hexdigest()})
        self.assertNotIn("unknown", json.dumps(result))
        self.assertEqual(len(list(self.root.iterdir())), 1)

    def test_different_zip_timestamps_and_compression_do_not_change_raw_store_equality(self):
        first = self.write()
        second = self.write("second.zip", created=2, compression=zipfile.ZIP_STORED)
        self.assertNotEqual(first.read_bytes(), second.read_bytes())
        self.assertTrue(TOOL.compare_archives(first, second)["threeBusinessFilesByteIdentical"])

    def test_valid_changed_store_is_not_accepted_as_original_return(self):
        first = self.write()
        changed = dict(self.values, **{"preferences.json": self.values["preferences.json"] + b" "})
        second = self.write("changed.zip", values=changed)
        TOOL.inspect_archive(second)
        with self.assertRaisesRegex(ValueError, "逐字节"):
            TOOL.compare_archives(first, second)

    def test_wrong_digest_or_declared_size_fails_even_with_a_valid_zip_crc(self):
        for key, value in [("sha256", "0" * 64), ("bytes", 1)]:
            with self.subTest(key=key):
                path = self.write(key + ".zip", change=lambda m: m["files"]["preferences.json"].update({key: value}))
                with self.assertRaisesRegex(ValueError, "manifest 不同"):
                    TOOL.inspect_archive(path)

    def test_actual_crc_corruption_is_rejected(self):
        path = self.write(compression=zipfile.ZIP_STORED)
        with zipfile.ZipFile(path) as archive:
            item = archive.getinfo("preferences.json")
            offset = item.header_offset + 30 + len(item.filename.encode()) + len(item.extra)
        with path.open("r+b") as stream:
            stream.seek(offset)
            value = stream.read(1)
            stream.seek(offset)
            stream.write(bytes([value[0] ^ 1]))
        with self.assertRaises(zipfile.BadZipFile):
            TOOL.inspect_archive(path)

    def test_extra_missing_and_duplicate_entries_are_rejected(self):
        cases = [self.write("extra.zip", extra=("outside", b"no")),
                 self.write("duplicate.zip", extra=("preferences.json", b"{}")),
                 self.write("missing.zip", values={"preferences.json": b"{}"})]
        for path in cases:
            with self.subTest(path=path.name), self.assertRaises(ValueError):
                TOOL.inspect_archive(path)

    def test_manifest_format_version_duplicate_keys_and_types_are_checked(self):
        mutations = [lambda m: m.update(version=2), lambda m: m.update(version=True),
                     lambda m: m.update(format="other"), lambda m: m.update(createdAtMillis=True),
                     lambda m: m["files"]["preferences.json"].update(bytes=True),
                     lambda m: m["files"]["preferences.json"].update(sha256="G" * 64)]
        for index, change in enumerate(mutations):
            with self.subTest(index=index), self.assertRaises(ValueError):
                TOOL.inspect_archive(self.write(str(index) + ".zip", change=change))
        for index, body in enumerate([b"\xff", b'{"format":1,"format":2}', b"x" * 65537]):
            with self.subTest(body=index), self.assertRaises((ValueError, UnicodeError)):
                TOOL.inspect_archive(self.write("raw" + str(index) + ".zip", raw_manifest=body))

    def test_real_read_cancellation_closes_zip_part_and_underlying_file(self):
        values = dict(self.values, **{"configurations.json": b"x" * (TOOL.CHUNK + 17)})
        path = self.write(values=values)
        original_bytes = path.read_bytes()
        files, streams = [], []
        zip_type, read = zipfile.ZipFile, zipfile.ZipExtFile.read
        progress = []

        class TrackingZip(zip_type):
            def __init__(self, stream, *args, **kwargs):
                files.append(stream)
                super().__init__(stream, *args, **kwargs)

            def open(self, *args, **kwargs):
                stream = super().open(*args, **kwargs)
                streams.append(stream)
                return stream

        def interrupt(stream, size=-1):
            if stream.name == "configurations.json" and progress:
                raise KeyboardInterrupt()
            value = read(stream, size)
            if stream.name == "configurations.json":
                progress.append(len(value))
            return value

        with mock.patch.object(TOOL.zipfile, "ZipFile", TrackingZip), mock.patch.object(zipfile.ZipExtFile, "read", interrupt):
            with self.assertRaises(KeyboardInterrupt):
                TOOL.inspect_archive(path)
        self.assertEqual(progress, [TOOL.CHUNK])
        self.assertTrue(all(stream.closed for stream in streams))
        self.assertTrue(all(stream.closed for stream in files))
        self.assertEqual(path.read_bytes(), original_bytes)

    def test_changed_input_identity_is_not_reported_as_verified(self):
        path = self.write()
        fingerprint = TOOL.fingerprint
        changed = []

        def change_after_progress(stream, limit):
            result = fingerprint(stream, limit)
            if not changed:
                info = path.stat()
                os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns + 1))
                changed.append(True)
            return result

        with mock.patch.object(TOOL, "fingerprint", change_after_progress):
            with self.assertRaisesRegex(ValueError, "输入文件已改变"):
                TOOL.inspect_archive(path)

    def test_fifo_is_rejected_without_blocking_or_leaking_its_fd(self):
        path = self.root / "not-an-archive"
        os.mkfifo(path)
        descriptors = []
        open_fd = os.open

        def record(*args, **kwargs):
            descriptor = open_fd(*args, **kwargs)
            descriptors.append(descriptor)
            return descriptor

        with mock.patch.object(TOOL.os, "open", record), self.assertRaisesRegex(ValueError, "普通备份文件"):
            TOOL.inspect_archive(path)
        self.assertEqual(len(descriptors), 1)
        with self.assertRaises(OSError):
            os.fstat(descriptors[0])

    def test_cli_success_and_failed_compare_have_distinct_checked_exit_codes(self):
        first = self.write()
        command = [sys.executable, "-I", str(ROOT / "tool/artifacts/verify_backup.py"), str(first)]
        success = subprocess.run(command, capture_output=True, timeout=10, check=True)
        self.assertIn("parts", json.loads(success.stdout))
        changed = self.write("changed.zip", values=dict(self.values, **{"preferences.json": b"{}"}))
        failure = subprocess.run(command + ["--compare", str(changed)], capture_output=True, timeout=10)
        self.assertEqual(failure.returncode, 1)
        self.assertEqual(json.loads(failure.stderr)["status"], "failed")


if __name__ == "__main__":
    unittest.main()
