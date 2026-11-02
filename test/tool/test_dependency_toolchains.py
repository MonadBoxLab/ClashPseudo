"""核对官方工具链选择、archive 安全解包及固定 cache。"""

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("tested_toolchains", ROOT / "tool/dependencies/toolchains.py")
tools = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tools)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def zip_bytes(entries):
    result = io.BytesIO()
    with zipfile.ZipFile(result, "w") as archive:
        for name, data, mode in entries:
            item = zipfile.ZipInfo(name)
            item.create_system = 3
            item.external_attr = mode << 16
            archive.writestr(item, data)
    return result.getvalue()


class ArchiveTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="toolchain-regression-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.destination = self.base / "installed"
        self.calls = []

    def install(self, data, *, changes=None, destination=None):
        row = {"sourceUrl": "https://dl.google.com/android/repository/synthetic.zip",
               "bytes": len(data), "sha256": digest(data), "officialSha1": hashlib.sha1(data).hexdigest()}
        row.update(changes or {})
        def fetch(url, *, limit, destination):
            self.calls.append(url)
            self.assertEqual(url, row["sourceUrl"])
            self.assertEqual(limit, row["bytes"])
            self.assertFalse(Path(destination).exists())
            Path(destination).write_bytes(data)
            return {"bytes": len(data), "sha256": digest(data)}
        return tools.install_archive(row, destination or self.destination, fetch=fetch)

    def test_unix_symlinks_and_executable_bits_survive_zip_and_offline_cache(self):
        data = zip_bytes([("ndk/bin/clang", b"clang-21", 0o120777),
                          ("ndk/bin/clang++", b"clang", 0o120777),
                          ("ndk/bin/clang-21", b"synthetic executable", 0o100755),
                          ("ndk/README", b"original", 0o100644)])
        content, measured = self.install(data)
        clang = content / "ndk/bin/clang"
        self.assertTrue(clang.is_symlink())
        self.assertEqual(os.readlink(clang), "clang-21")
        self.assertEqual(clang.read_bytes(), b"synthetic executable")
        self.assertTrue((clang.stat().st_mode & 0o111) != 0)
        self.assertFalse((content / "ndk/README").stat().st_mode & 0o111)
        self.assertEqual(self.install(data), (content, measured))
        self.assertEqual(len(self.calls), 1)
        receipt = json.loads((self.destination / "receipt.json").read_bytes())
        self.assertIn({"path": "ndk/bin/clang", "link": "clang-21"}, receipt["files"])

    def test_absolute_and_escaping_symlinks_never_create_a_completed_cache(self):
        for target in (b"/tmp/outside", b"../../../outside"):
            with self.subTest(target=target), self.assertRaisesRegex(ValueError, "超出安装目录"):
                self.install(zip_bytes([("ndk/bin/clang", target, 0o120777)]))
            self.assertFalse(self.destination.exists())
            self.assertEqual(list(self.base.iterdir()), [])

    def test_archive_cannot_write_through_a_symlink_parent(self):
        data = zip_bytes([("ndk/link", b"../target", 0o120777),
                          ("ndk/link/child", b"must not follow", 0o100644)])
        with self.assertRaises(FileExistsError):
            self.install(data)
        self.assertFalse(self.destination.exists())
        self.assertFalse((self.base / "target").exists())

    def test_traversal_duplicates_and_special_files_are_rejected(self):
        cases = [zip_bytes([("../outside", b"x", 0o100644)]),
                 zip_bytes([("/outside", b"x", 0o100644)]),
                 zip_bytes([("ndk/fifo", b"x", 0o010644)])]
        with mock.patch.object(warnings, "warn"):
            cases.append(zip_bytes([("ndk/file", b"one", 0o100644), ("ndk/file", b"two", 0o100644)]))
        for data in cases:
            with self.subTest(sha256=digest(data)), self.assertRaises(ValueError):
                self.install(data)
            self.assertFalse(self.destination.exists())

    def test_digest_size_official_sha1_and_expansion_limits_are_independent(self):
        data = zip_bytes([("ndk/file", b"123456789", 0o100644)])
        for changes in ({"sha256": "0" * 64}, {"bytes": len(data) + 1}, {"officialSha1": "0" * 40}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.install(data, changes=changes)
            self.assertFalse(self.destination.exists())
        with mock.patch.object(tools, "LIMIT", 8), self.assertRaisesRegex(ValueError, "路径或大小无效"):
            self.install(data)
        self.assertFalse(self.destination.exists())

    def test_incomplete_changed_file_permission_and_link_caches_fail_without_download(self):
        data = zip_bytes([("ndk/bin/clang", b"clang-21", 0o120777),
                          ("ndk/bin/clang-21", b"original", 0o100755)])
        content, _ = self.install(data)
        executable = content / "ndk/bin/clang-21"
        executable.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "缓存文件发生变化"):
            self.install(data)
        executable.write_bytes(b"original")
        executable.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "缓存文件发生变化"):
            self.install(data)
        executable.chmod(0o755)
        link = content / "ndk/bin/clang"
        link.unlink()
        link.symlink_to("missing")
        with self.assertRaisesRegex(ValueError, "缓存文件发生变化"):
            self.install(data)
        self.assertEqual(len(self.calls), 1)
        incomplete = self.base / "incomplete"
        incomplete.mkdir()
        with self.assertRaisesRegex(ValueError, "缓存未完成"):
            self.install(data, destination=incomplete)
        self.assertEqual(len(self.calls), 1)

    def test_android_generated_metadata_requires_the_frozen_package_identity(self):
        data = zip_bytes([("platform/source.properties", b"original", 0o100644)])
        content, _ = self.install(data, changes={"package": "platforms;android-36"})
        metadata = content / "platform/package.xml"
        metadata.write_text('<sdk><localPackage path="platforms;android-36"/></sdk>')
        self.install(data, changes={"package": "platforms;android-36"})
        metadata.write_text('<sdk><localPackage path="platforms;android-37"/></sdk>')
        with self.assertRaisesRegex(ValueError, "缓存文件发生变化"):
            self.install(data, changes={"package": "platforms;android-36"})
        self.assertEqual(len(self.calls), 1)

    def test_tar_links_are_checked_and_archive_files_remain_unchanged(self):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w:gz") as archive:
            item = tarfile.TarInfo("go/bin/go")
            item.size = 8
            item.mode = 0o755
            archive.addfile(item, io.BytesIO(b"original"))
        content, _ = self.install(output.getvalue())
        self.assertEqual((content / "go/bin/go").read_bytes(), b"original")
        self.assertTrue((content / "go/bin/go").stat().st_mode & 0o111)

    def test_flutter_mutable_cache_does_not_allow_sdk_source_changes(self):
        data = zip_bytes([("flutter/bin/flutter", b"original", 0o100755),
                          ("flutter/.git/HEAD", b"ref: refs/heads/stable\n", 0o100644),
                          ("flutter/bin/cache/engine.stamp", b"fixed engine", 0o100644)])
        content, _ = self.install(data)
        cache = content / "flutter/bin/cache/new-runtime"
        cache.write_bytes(b"generated")
        self.install(data)
        (content / "flutter/bin/cache/engine.stamp").write_bytes(b"different engine")
        with self.assertRaisesRegex(ValueError, "缓存文件发生变化"):
            self.install(data)
        self.assertEqual(len(self.calls), 1)


class PreparationTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="toolchain-prepare-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.root = self.base / "project"
        (self.root / "android").mkdir(parents=True)
        self.cache = self.base / "cache"
        self.cache.mkdir()
        self.minimum = 24
        self.record = {"format": "clash-pseudo-toolchains", "version": 1, "minSdk": 24,
                       "selected": {name: {"sha256": str(index) * 64, "sourceUrl": name}
                                    for index, name in enumerate(("flutter", "go", "java", "gradle"), 1)},
                       "androidLicenses": {"android-sdk-license": "  Original\n license\n\nText.  "}}
        self.record["selected"]["android"] = {
            "platform": {"package": "platforms;android-36", "officialSha1": "5" * 40},
            "ndk": {"package": "ndk;30.0.0", "officialSha1": "6" * 40}}
        self.patcher = mock.patch.object(tools, "install_archive", side_effect=self.install)
        self.installer = self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def install(self, row, destination, **kwargs):
        content = destination / "content"
        package = row.get("package", row.get("sourceUrl"))
        directory = content / ("ndk" if package.startswith("ndk;") else "sdk" if ";" in package else package)
        directory.mkdir(parents=True, exist_ok=True)
        if package.startswith("ndk;"):
            (directory / "meta").mkdir(exist_ok=True)
            (directory / "meta/platforms.json").write_text(json.dumps({"min": self.minimum, "max": 36}))
        return content, {"bytes": 100, "sha256": "a" * 64}

    def prepare(self):
        return tools.prepare(self.record, self.cache, self.root)

    def test_fixed_packages_sdk_license_and_ndk_layout_are_prepared_without_resolving_latest(self):
        with mock.patch.object(tools, "resolve", side_effect=AssertionError("普通准备不得查询 latest")):
            environment, measured = self.prepare()
        sdk = Path(environment["ANDROID_HOME"])
        ndk = sdk / "ndk/30.0.0"
        self.assertTrue(ndk.is_symlink())
        self.assertIn("-unix-links-v1", str(ndk.resolve()))
        self.assertEqual((sdk / "licenses/android-sdk-license").read_text(),
                         tools.android_license_hash(self.record["androidLicenses"]["android-sdk-license"]) + "\n")
        self.assertEqual(environment["GOTOOLCHAIN"], "local")
        self.assertTrue(environment["CLASH_GRADLE"].endswith("/gradle/bin/gradle"))
        self.assertIn("sdk.dir=" + str(sdk), (self.root / "android/local.properties").read_text())
        self.assertEqual(set(measured), {"flutter", "go", "java", "gradle", "android.platform", "android.ndk"})

    def test_old_managed_ndk_link_switches_to_the_verified_layout(self):
        environment, _ = self.prepare()
        ndk = Path(environment["ANDROID_HOME"]) / "ndk/30.0.0"
        expected = ndk.resolve()
        previous = self.cache / "android-packages/old/content/ndk"
        previous.mkdir(parents=True)
        marker = previous / "original"
        marker.write_bytes(b"old cache evidence")
        ndk.unlink()
        ndk.symlink_to(previous)
        self.prepare()
        self.assertEqual(ndk.resolve(), expected)
        self.assertEqual(marker.read_bytes(), b"old cache evidence")

    def test_unmanaged_sdk_target_is_rejected_without_replacing_it(self):
        environment, _ = self.prepare()
        ndk = Path(environment["ANDROID_HOME"]) / "ndk/30.0.0"
        outside = self.base / "user-sdk"
        outside.mkdir()
        ndk.unlink()
        ndk.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "不属于工具链 cache"):
            self.prepare()
        self.assertEqual(ndk.resolve(), outside)

    def test_incompatible_ndk_fails_without_raising_the_application_min_sdk(self):
        self.minimum = 26
        with self.assertRaisesRegex(ValueError, "不支持 API24"):
            self.prepare()
        self.assertEqual(self.record["minSdk"], 24)
        self.assertFalse((self.root / "android/local.properties").exists())


class ResolverTest(unittest.TestCase):
    def setUp(self):
        self.requests = []
        self.documents = {}
        def put(url, value):
            self.documents[url] = value if isinstance(value, bytes) else json.dumps(value).encode()
        put(tools.FLUTTER, {"base_url": "https://storage.googleapis.com/flutter_infra_release/flutter",
                           "current_release": {"stable": "f" * 40}, "releases": [
                               {"hash": "f" * 40, "channel": "stable", "version": "3.47.9", "dart_sdk_version": "3.13.7",
                                "archive": "linux/flutter.tar.xz", "sha256": "f" * 64}]})
        put(tools.GO, [{"version": "go1.27.3", "stable": True, "files": [
            {"os": "linux", "arch": "amd64", "kind": "archive", "filename": "go1.27.3.linux-amd64.tar.gz",
             "sha256": "a" * 64, "size": 100}]}])
        def maven(versions):
            return ('<metadata><versioning><versions>' + ''.join('<version>' + v + '</version>' for v in versions)
                    + '</versions></versioning></metadata>').encode()
        put("https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/maven-metadata.xml", maven(["9.3.1", "9.2.0", "10.0.0-alpha01"]))
        put("https://repo.maven.apache.org/maven2/org/jetbrains/kotlin/kotlin-gradle-plugin/maven-metadata.xml", maven(["2.5.0", "2.4.21"]))
        put("https://services.gradle.org/versions/all", [
            {"version": v, "downloadUrl": "https://services.gradle.org/distributions/gradle-" + v + "-bin.zip",
             "checksumUrl": "https://services.gradle.org/distributions/gradle-" + v + "-bin.zip.sha256"}
            for v in ("9.7.0", "9.6.0")])
        put(tools.KOTLIN, b"<table><tr><td>2.4.0-2.4.99</td><td>9.4.0-9.6.0</td><td>9.2.0-9.2.99</td></tr></table>")
        for v in ("9.3", "9.2"):
            put("https://developer.android.com/build/releases/agp-" + v.replace(".", "-") + "-0-release-notes",
                b"The maximum API level this version supports is API level 36."
                b"<table><tr><td>Gradle</td><td>9.4.0</td></tr><tr><td>JDK</td><td>21</td></tr>"
                b"<tr><td>SDK Build Tools</td><td>36.0.0</td></tr></table>")
        put("https://services.gradle.org/distributions/gradle-9.6.0-bin.zip.sha256", b"b" * 64)
        put(tools.GRADLE_COMPATIBILITY, b"<table><tr><td>27</td><td>N/A</td><td>9.7.0</td></tr>"
                                             b"<tr><td>26</td><td>N/A</td><td>9.4.0</td></tr></table>")
        put("https://api.adoptium.net/v3/info/available_releases", {"available_releases": [21, 26, 27], "most_recent_feature_release": 27})
        put("https://api.adoptium.net/v3/assets/latest/26/hotspot?architecture=x64&image_type=jdk&os=linux&vendor=eclipse",
            [{"version": {"semver": "26.0.2+101"}, "binary": {"package": {
                "link": "https://github.com/adoptium/temurin26-binaries/releases/download/jdk-26/jdk.tar.gz",
                "checksum": "c" * 64, "size": 100}}}])
        packages = []
        for path, revision, channel in (("platforms;android-38", "1.0.0", "channel-0"),
                                        ("platforms;android-36", "2.0.0", "channel-0"),
                                        ("build-tools;37.0.0", "37.0.0", "channel-0"),
                                        ("build-tools;36.0.0", "36.0.0", "channel-0"),
                                        ("ndk;31.0.0", "31.0.0", "channel-1"),
                                        ("ndk;30.0.0", "30.0.0", "channel-0"),
                                        ("cmdline-tools;23.0", "23.0.0", "channel-0"),
                                        ("platform-tools", "37.0.1", "channel-0")):
            major, minor, micro = revision.split('.')
            packages.append(f'<remotePackage path="{path}"><channelRef ref="{channel}"/><revision>'
                            f'<major>{major}</major><minor>{minor}</minor><micro>{micro}</micro></revision>'
                            '<archives><archive><host-os>linux</host-os><complete><url>fixed.zip</url><size>100</size>'
                            '<checksum>' + 'd' * 40 + '</checksum></complete></archive></archives></remotePackage>')
        put(tools.ANDROID, ('<repository><license id="android-sdk-license">  Original\n license\n\nText.  </license>'
                            + ''.join(packages) + '</repository>').encode())
        for name in ("checkout", "github-script", "upload-artifact"):
            base = "https://api.github.com/repos/actions/" + name
            put(base + "/releases/latest", {"tag_name": "v7.0.1", "draft": False, "prerelease": False})
            put(base + "/git/ref/tags/v7.0.1", {"object": {"type": "tag", "sha": "e" * 40}})
            put(base + "/git/tags/" + "e" * 40, {"object": {"type": "commit", "sha": "1" * 40}})

    def fetch(self, url, **kwargs):
        self.requests.append(url)
        return self.documents[url]

    def test_latest_official_compatible_versions_and_api24_are_selected(self):
        record = tools.resolve(fetch=self.fetch)
        selected = record["selected"]
        self.assertEqual(record["minSdk"], 24)
        self.assertEqual(selected["agp"]["version"], "9.2.0")
        self.assertEqual(selected["kotlin"]["version"], "2.4.21")
        self.assertEqual(selected["gradle"]["version"], "9.6.0")
        self.assertEqual(selected["java"]["version"], "26.0.2+101")
        self.assertEqual(selected["android"]["platform"]["package"], "platforms;android-36")
        self.assertEqual(selected["android"]["ndk"]["package"], "ndk;30.0.0")
        self.assertEqual(selected["android"]["buildTools"]["package"], "build-tools;37.0.0")
        self.assertEqual(selected["android"]["compatibilityBuildTools"]["package"], "build-tools;36.0.0")
        self.assertTrue(any(row["component"] == "agp" and row["version"] == "9.3.1" for row in record["excluded"]))
        self.assertTrue(any(row["component"] == "java" and row["version"] == "27" for row in record["excluded"]))
        self.assertTrue(all(row["commit"] == "1" * 40 for row in selected["actions"].values()))
        self.assertEqual(record["androidLicenses"]["android-sdk-license"], "  Original\n license\n\nText.  ")
        for row in record["documents"]:
            self.assertEqual(row["sha256"], digest(self.documents[row["sourceUrl"]]))
            self.assertEqual(row["bytes"], len(self.documents[row["sourceUrl"]]))

    def test_missing_official_compatibility_fails_instead_of_guessing(self):
        self.documents[tools.KOTLIN] = b"<table></table>"
        with self.assertRaisesRegex(ValueError, "没有可用的 AGP"):
            tools.resolve(fetch=self.fetch)

    def test_sdk_license_uses_android_trim_adapter_without_discarding_raw_input(self):
        raw = "  Original\n license\n\nText.  "
        self.assertEqual(tools.android_license_hash(raw), hashlib.sha1(b"Original license\n\nText.").hexdigest())
        self.assertNotEqual(tools.android_license_hash(raw), hashlib.sha1(raw.strip().encode()).hexdigest())


if __name__ == "__main__":
    unittest.main()
