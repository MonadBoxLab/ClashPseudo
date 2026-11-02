"""使用合成文件，测试资源写入失败后的文件恢复和输入变化检查。"""

import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile


ROOT = Path(__file__).resolve().parents[2]


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


update = load("resource_update_safety", "tool/dependencies/update.py")
legal = load("resource_legal_safety", "tool/dependencies/legal.py")


class TransactionSafetyTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.first, self.second = update.GO_INPUTS
        for name in (self.first, self.second):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(("original " + name).encode())
        self.before = update.snapshot(self.root)
        self.after = dict(self.before)
        self.after.update({self.first: b"first candidate", self.second: b"second candidate"})

    def assert_no_staging_files(self):
        self.assertEqual(list(self.root.rglob(".clash-update-*")), [])

    def test_extra_input_and_deletion_are_rejected_before_any_write(self):
        for after in (dict(self.after, **{"../outside": b"bad"}),
                      dict(self.after, **{self.second: None})):
            with self.subTest(keys=list(after)), self.assertRaises(ValueError):
                update.publish_changes(self.root, self.before, after)
            self.assertEqual(update.snapshot(self.root), self.before)
            self.assert_no_staging_files()

    def test_stage_failure_does_not_change_any_input(self):
        original = update.stage_bytes
        failure = OSError("staging storage exhausted")
        calls = 0

        def stage(path, data):
            nonlocal calls
            calls += 1
            if calls == 3:
                raise failure
            return original(path, data)

        with mock.patch.object(update, "stage_bytes", side_effect=stage):
            with self.assertRaises(OSError) as caught:
                update.publish_changes(self.root, self.before, self.after)
        self.assertIs(caught.exception, failure)
        self.assertEqual(update.snapshot(self.root), self.before)
        self.assert_no_staging_files()

    def test_second_replace_failure_rolls_back_the_first_atomic_replacement(self):
        original = update.os.replace
        failure = OSError("second rename failed")
        calls = 0

        def replace(source, target):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise failure
            return original(source, target)

        with mock.patch.object(update.os, "replace", side_effect=replace):
            with self.assertRaises(OSError) as caught:
                update.publish_changes(self.root, self.before, self.after)
        self.assertIs(caught.exception, failure)
        self.assertEqual(update.snapshot(self.root), self.before)
        self.assert_no_staging_files()

    def test_directory_sync_failure_after_rename_keeps_original_cause_and_rolls_back(self):
        failure = OSError("directory fsync failed")
        with mock.patch.object(update, "sync_directory", side_effect=[failure, None]):
            with self.assertRaises(OSError) as caught:
                update.publish_changes(self.root, self.before, self.after)
        self.assertIs(caught.exception, failure)
        self.assertEqual(update.snapshot(self.root), self.before)
        self.assert_no_staging_files()

    def test_new_target_is_removed_when_the_following_replacement_fails(self):
        new_name = "pubspec.yaml"
        after = dict(self.before)
        # 按写入顺序排列文件，首项为原目录中不存在的新文件。
        after = {new_name: b"new candidate", **after}
        after[new_name] = b"new candidate"
        after[self.first] = b"changed existing"
        original = update.os.replace
        failure = OSError("failure after new target")
        calls = 0

        def replace(source, target):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise failure
            return original(source, target)

        with mock.patch.object(update.os, "replace", side_effect=replace):
            with self.assertRaises(OSError):
                update.publish_changes(self.root, self.before, after)
        self.assertEqual(update.snapshot(self.root), self.before)
        self.assertFalse((self.root / new_name).exists())
        self.assert_no_staging_files()

    def test_user_edit_of_pending_target_is_preserved_and_prior_target_rolls_back(self):
        calls = 0

        def synced(_directory):
            nonlocal calls
            calls += 1
            if calls == 1:
                (self.root / self.second).write_bytes(b"concurrent user edit")

        with mock.patch.object(update, "sync_directory", side_effect=synced):
            with self.assertRaisesRegex(ValueError, "更新期间文件发生变化"):
                update.publish_changes(self.root, self.before, self.after)
        self.assertEqual((self.root / self.first).read_bytes(), self.before[self.first])
        self.assertEqual((self.root / self.second).read_bytes(), b"concurrent user edit")
        self.assert_no_staging_files()

    def test_rollback_does_not_overwrite_a_user_edit_of_an_already_written_target(self):
        failure = OSError("original publication failure")

        def synced(_directory):
            (self.root / self.first).write_bytes(b"later user edit")
            raise failure

        with mock.patch.object(update, "sync_directory", side_effect=synced):
            with self.assertRaises(OSError) as caught:
                update.publish_changes(self.root, self.before, self.after)
        self.assertIs(caught.exception, failure)
        self.assertEqual((self.root / self.first).read_bytes(), b"later user edit")
        self.assertEqual((self.root / self.second).read_bytes(), self.before[self.second])
        self.assert_no_staging_files()

    def test_rollback_failure_is_attached_without_replacing_original_failure(self):
        publication = OSError("publication fsync")
        cleanup = OSError("rollback rename")
        original = update.os.replace
        calls = 0

        def replace(source, target):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise cleanup
            return original(source, target)

        with mock.patch.object(update.os, "replace", side_effect=replace), mock.patch.object(
                update, "sync_directory", side_effect=publication):
            with self.assertRaises(OSError) as caught:
                update.publish_changes(self.root, self.before, self.after)
        self.assertIs(caught.exception, publication)
        self.assertTrue(any("rollback rename" in note for note in caught.exception.__notes__))
        self.assert_no_staging_files()

    def test_interrupt_is_not_a_success_and_rolls_back_published_bytes(self):
        interrupted = KeyboardInterrupt()
        with mock.patch.object(update, "sync_directory", side_effect=[interrupted, None]):
            with self.assertRaises(KeyboardInterrupt) as caught:
                update.publish_changes(self.root, self.before, self.after)
        self.assertIs(caught.exception, interrupted)
        self.assertEqual(update.snapshot(self.root), self.before)
        self.assert_no_staging_files()

    def test_concurrent_change_of_an_unchanged_input_aborts_the_whole_transaction(self):
        (self.root / "pubspec.yaml").write_bytes(b"user version change")
        with self.assertRaisesRegex(ValueError, "更新期间文件发生变化"):
            update.publish_changes(self.root, self.before, self.after)
        self.assertEqual((self.root / self.first).read_bytes(), self.before[self.first])
        self.assertEqual((self.root / self.second).read_bytes(), self.before[self.second])
        self.assertEqual((self.root / "pubspec.yaml").read_bytes(), b"user version change")
        self.assert_no_staging_files()

    def test_symlinked_input_is_not_followed_for_staging_or_publication(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.root / "pubspec.yaml").symlink_to(outside / "target")
        with self.assertRaisesRegex(ValueError, "符号链接"):
            update.publish_changes(self.root, self.before, self.after)
        self.assertFalse((outside / "target").exists())
        self.assertEqual((self.root / self.first).read_bytes(), self.before[self.first])
        self.assert_no_staging_files()


class NetworkSafetyTest(unittest.TestCase):
    class Response(io.BytesIO):
        def __init__(self, data, length):
            super().__init__(data)
            self.headers = {} if length is None else {"Content-Length": length}
            self.read_calls = []

        def geturl(self):
            return "https://example.test/fixed"

        def read(self, size=-1):
            self.read_calls.append(size)
            if size <= 0:
                raise AssertionError("unbounded read")
            return super().read(size)

    def test_stream_overflow_is_detected_even_without_content_length(self):
        response = self.Response(b"12345", None)
        with mock.patch.object(update.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = response
            with self.assertRaisesRegex(ValueError, "上限"):
                update.fetch("https://example.test/fixed", limit=4)
        self.assertTrue(all(0 < size <= update.CHUNK for size in response.read_calls))

    def test_oversized_declared_response_is_rejected_without_reading(self):
        response = self.Response(b"12345", "5")
        with mock.patch.object(update.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = response
            with self.assertRaisesRegex(ValueError, "上限"):
                update.fetch("https://example.test/fixed", limit=4)
        self.assertEqual(response.read_calls, [])

    def test_short_declared_response_is_not_accepted_as_complete_in_memory(self):
        response = self.Response(b"abc", "4")
        with mock.patch.object(update.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = response
            with self.assertRaisesRegex(ValueError, "Content-Length 声明的字节数与实际读取的字节数不一致"):
                update.fetch("https://example.test/fixed", limit=8)

    def test_short_declared_response_is_not_accepted_as_complete_on_disk(self):
        response = self.Response(b"abc", "4")
        with tempfile.TemporaryDirectory(prefix="short-resource-response-") as temporary:
            destination = Path(temporary) / "payload.part"
            with mock.patch.object(update.urllib.request, "build_opener") as opener:
                opener.return_value.open.return_value = response
                with self.assertRaisesRegex(ValueError, "Content-Length 声明的字节数与实际读取的字节数不一致"):
                    update.fetch("https://example.test/fixed", limit=8, destination=destination)
            self.assertEqual(destination.read_bytes(), b"abc")
            self.assertFalse((destination.parent / "receipt.json").exists())
        self.assertTrue(all(0 < size <= update.CHUNK for size in response.read_calls))

    def test_short_reads_are_accumulated_until_real_eof_not_assumed_complete(self):
        class Chunked(self.Response):
            def read(self, size=-1):
                return super().read(min(size, 1))

        response = Chunked(b"abcd", "4")
        with mock.patch.object(update.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = response
            self.assertEqual(update.fetch("https://example.test/fixed", limit=8), b"abcd")
        self.assertEqual(len(response.read_calls), 5)

    def test_https_redirect_must_not_downgrade_to_http(self):
        with self.assertRaisesRegex(ValueError, "HTTPS"):
            update.HttpsRedirect().redirect_request(None, None, 302, "Found", {}, "http://example.test/data")


class LegalSafetyTest(unittest.TestCase):
    @staticmethod
    def archive(entries):
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, value in entries:
                archive.writestr(name, value)
        return output.getvalue()

    def test_nested_legal_archives_share_the_expansion_budget(self):
        inner = self.archive([("LICENSE", b"legal " * 40)])
        outer = self.archive([("classes.jar", inner)])
        budget = {"bytes": len(inner) + 100, "entries": 10}
        with self.assertRaisesRegex(ValueError, "上限"):
            legal.archive_legal(outer, _budget=budget)

    def test_legal_archive_entry_budget_applies_even_to_ignored_members(self):
        data = self.archive([("not-legal.bin", b""), ("another.bin", b"")])
        with self.assertRaisesRegex(ValueError, "条目数上限"):
            legal.archive_legal(data, _budget={"bytes": 1000, "entries": 1})

    def test_legacy_psl_notice_reuses_same_effective_revision_and_real_local_bytes_without_fetch(self):
        with tempfile.TemporaryDirectory(prefix="legacy-psl-") as temporary:
            root = Path(temporary)
            revision = "abc12345" * 5
            table = root / "publicsuffix/table.go"
            table.parent.mkdir()
            table.write_text("// generated from git revision " + revision + "\n")
            data = b"// Mozilla Public License 2.0\n// BEGIN ICANN DOMAINS\ntest\n// END PRIVATE DOMAINS\n"
            target = root / "third_party/data/publicsuffix/public_suffix_list.dat"
            target.parent.mkdir(parents=True)
            target.write_bytes(data)
            notice = root / "third_party/notices/publicsuffix.txt"
            notice.parent.mkdir(parents=True)
            original = ("Public Suffix List数据通知\n实现包：golang.org/x/net/publicsuffix，模块golang.org/x/net v0.35.0。\n"
                        "table.go所记录的PSL提交：\n" + revision + "（2023-08-03T10:01:25Z）\n"
                        "https://raw.githubusercontent.com/publicsuffix/list/" + revision + "/public_suffix_list.dat\n"
                        "SHA-256：" + legal.sha(data) + "\n").encode()
            notice.write_bytes(original)
            updater = mock.Mock(root=root, go="go")
            updater.go_run.return_value = json.dumps({"Dir": str(root)})
            fetch = mock.Mock(side_effect=AssertionError("fixed PSL must not be fetched"))
            instance = legal.Legal(updater, root, fetch, mock.Mock(), update.artifacts)
            graph = {"golang.org/x/net": {"Path": "golang.org/x/net", "Version": "v0.35.0"}}
            result = instance.public_suffix(graph)
            self.assertEqual(result["revision"], revision)
            self.assertEqual(result["sha256"], legal.sha(data))
            self.assertEqual(target.read_bytes(), data)
            self.assertEqual(notice.read_bytes(), original)
            fetch.assert_not_called()
            target.write_bytes(data.replace(b"test", b"changed"))
            with self.assertRaisesRegex(ValueError, "固定来源与现有摘要不同"):
                instance.public_suffix(graph)
            fetch.assert_not_called()

    def test_psl_replacement_does_not_reuse_original_modules_same_version_notice(self):
        with tempfile.TemporaryDirectory(prefix="replaced-psl-") as temporary:
            root = Path(temporary)
            revision = "12345abc" * 5
            table = root / "publicsuffix/table.go"
            table.parent.mkdir()
            table.write_text("// generated from git revision " + revision + "\n")
            data = b"// BEGIN ICANN DOMAINS\ntest\n// END PRIVATE DOMAINS\n"
            target = root / "third_party/data/publicsuffix/public_suffix_list.dat"
            target.parent.mkdir(parents=True)
            target.write_bytes(data)
            notice = root / "third_party/notices/publicsuffix.txt"
            notice.parent.mkdir(parents=True)
            notice.write_text("x/net v0.35.0；PSL " + revision + "\n" + legal.sha(data))
            license_file = root / "third_party/data/certificates/MPL-2.0.txt"
            license_file.parent.mkdir(parents=True)
            license_file.write_bytes(b"synthetic MPL original\r\n")
            updater = mock.Mock(root=root, go="go")
            updater.go_run.return_value = json.dumps({"Dir": str(root)})
            fetch = mock.Mock(return_value=data)
            instance = legal.Legal(updater, root, fetch, mock.Mock(), update.artifacts)
            graph = {"golang.org/x/net": {"Path": "golang.org/x/net", "Version": "v0.1.0", "Replace": {
                "Path": "example.test/net", "Version": "v0.35.0"}}}
            result = instance.public_suffix(graph)
            self.assertEqual(result["module"], "example.test/net")
            fetch.assert_called_once_with("https://raw.githubusercontent.com/publicsuffix/list/" + revision + "/public_suffix_list.dat")
            self.assertIn("example.test/net v0.35.0；PSL " + revision, notice.read_text())

    def test_selected_xnet_replacement_supplies_the_actual_psl_revision(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            table = root / "publicsuffix/table.go"
            table.parent.mkdir()
            revision = "abc12345" * 5
            table.write_text("// generated from git revision " + revision + "\npackage publicsuffix\n")
            updater = mock.Mock(root=root, go="go")
            updater.go_run.return_value = json.dumps({"Dir": str(root)})
            instance = legal.Legal(updater, root, mock.Mock(), mock.Mock(), update.artifacts)
            graph = {"golang.org/x/net": {"Path": "golang.org/x/net", "Version": "v0.1.0", "Replace": {
                "Path": "example.test/net", "Version": "v0.2.0"}}}
            source = instance.public_suffix_source(graph)
            updater.go_run.assert_called_once_with("mod", "download", "-json", "example.test/net@v0.2.0")
            self.assertEqual(source["revision"], revision)
            self.assertEqual(source["module"], "example.test/net")
            self.assertIn("/" + revision + "/public_suffix_list.dat", source["sourceUrl"])
            self.assertEqual(sorted(path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file()),
                             ["publicsuffix/table.go"])


if __name__ == "__main__":
    unittest.main()
