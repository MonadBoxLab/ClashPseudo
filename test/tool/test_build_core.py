"""Use controlled compilers to verify native build arguments, ABI isolation, and output preservation on failure."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tool_test_support
from tool.android import build_core
from unittest import mock
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tool/main.py"


class BuildCoreTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.ndk = self.base / "ndk"
        compilers = self.ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin"
        compilers.mkdir(parents=True)
        for target in ("armv7a-linux-androideabi", "aarch64-linux-android", "x86_64-linux-android"):
            compiler = compilers / (target + "24-clang")
            compiler.write_text(
                "#!/usr/bin/env python3\nimport os,pathlib,sys\n"
                "if os.environ.get('BUILD_CORE_CC_FAIL'): sys.exit(19)\n"
                "pathlib.Path(sys.argv[sys.argv.index('-o')+1]).write_bytes(b'coverage object')\n")
            compiler.chmod(0o755)
        go = self.bin / "go"
        go.write_text(
            "#!/usr/bin/env python3\n"
            "import json,os,pathlib,sys\n"
            "args=sys.argv[1:]\n"
            "if '-C' in args: os.chdir(args[args.index('-C')+1])\n"
            "if 'list' in args:\n print(os.environ.get('BUILD_CORE_VERSION','v1.0.0')); sys.exit(0)\n"
            "with open(os.environ['BUILD_CORE_RECORD'],'a') as f:\n"
            " f.write(json.dumps({'args':args,'env':{k:os.environ.get(k) for k in "
            "['GOOS','GOARCH','GOARM','CC','CGO_ENABLED','GOTOOLCHAIN','CGO_CFLAGS','CGO_CPPFLAGS','CGO_CXXFLAGS','CGO_LDFLAGS']}})+'\\n')\n"
            "if os.environ.get('BUILD_CORE_FAIL'): sys.exit(3)\n"
            "pathlib.Path(args[args.index('-o')+1]).write_bytes(b'controlled build')\n"
        )
        go.chmod(0o755)
        self.record = self.base / "commands.jsonl"
        self.output = self.base / "output"
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        BUILD_CORE_RECORD=str(self.record), GOARM="5")

    def run_build(self, abis, api="24", *, coverage=False, cwd=ROOT):
        return subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), "android", "build-core",
                               "--ndk", str(self.ndk), "--api=" + api, "--output", str(self.output),
                               "--abis=" + abis, *(["--coverage"] if coverage else [])],
                              cwd=cwd, env=self.env, capture_output=True, text=True, timeout=30)

    def test_three_abis_use_their_own_compiler_and_arm_setting(self):
        result = self.run_build("armeabi-v7a,arm64-v8a,x86_64")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.record.read_text().splitlines()]
        self.assertEqual([call["env"]["GOARCH"] for call in calls], ["arm", "arm64", "amd64"])
        self.assertEqual([call["env"]["GOARM"] for call in calls], ["7", None, None])
        for call, target, abi in zip(calls,
                                    ["armv7a-linux-androideabi", "aarch64-linux-android", "x86_64-linux-android"],
                                    ["armeabi-v7a", "arm64-v8a", "x86_64"]):
            self.assertTrue(call["env"]["CC"].endswith(target + "24-clang"))
            self.assertEqual(call["env"]["GOOS"], "android")
            self.assertEqual(call["env"]["CGO_ENABLED"], "1")
            self.assertEqual(call["env"]["GOTOOLCHAIN"], "local")
            self.assertEqual(call["args"][call["args"].index("-tags") + 1], "cmfa,with_gvisor")
            self.assertIn("-buildmode=c-shared", call["args"])
            self.assertEqual((self.output / abi / "libmihomo_bridge.so").read_bytes(), b"controlled build")
            self.assertEqual(list((self.output / abi).glob(".staging.*")), [])

    def test_go_selected_version_is_used_without_application_version_filter(self):
        self.env["BUILD_CORE_VERSION"] = "selected-by-go"
        result = self.run_build("x86_64")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = json.loads(self.record.read_text())
        self.assertIn("engine.Version=selected-by-go", call["args"][call["args"].index("-ldflags") + 1])

    def test_relative_output_stays_relative_to_the_calling_directory(self):
        self.output = Path(os.path.relpath(self.output, ROOT))
        result = self.run_build("armeabi-v7a")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((ROOT / self.output / "armeabi-v7a/libmihomo_bridge.so").read_bytes(),
                         b"controlled build")

    def test_invalid_abis_fail_before_any_build(self):
        for abis in ("", "arm64-v8a,", ",x86_64", "x86", "armeabi-v7a,x86", "arm64-v8a x86_64"):
            with self.subTest(abis=abis):
                result = self.run_build(abis)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.record.exists())
                self.assertFalse(self.output.exists())

    def test_invalid_api_fails_before_any_build(self):
        for api in ("", "23", "24x", "-1"):
            with self.subTest(api=api):
                self.assertEqual(self.run_build("armeabi-v7a", api).returncode, 2)
                self.assertFalse(self.record.exists())

    def test_failed_build_preserves_the_previous_library_and_cleans_staging(self):
        directory = self.output / "armeabi-v7a"
        directory.mkdir(parents=True)
        library = directory / "libmihomo_bridge.so"
        library.write_bytes(b"previous library")
        self.env["BUILD_CORE_FAIL"] = "1"
        self.assertNotEqual(self.run_build("armeabi-v7a").returncode, 0)
        self.assertEqual(library.read_bytes(), b"previous library")
        self.assertEqual(list(directory.glob(".staging.*")), [])

    def test_coverage_preserves_user_cgo_flags_without_cross_abi_accumulation(self):
        self.env.update(CGO_CFLAGS="-O2 -DUSER_FLAG=1", CGO_LDFLAGS="-Wl,--as-needed",
                        CGO_CPPFLAGS="-DCPP_USER=1", CGO_CXXFLAGS="-DCXX_USER=1")
        result = self.run_build("armeabi-v7a,arm64-v8a,x86_64", coverage=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.record.read_text().splitlines()]
        for call in calls:
            env = call["env"]
            self.assertTrue(env["CGO_CFLAGS"].startswith("-O2 -DUSER_FLAG=1 "))
            self.assertEqual(env["CGO_CFLAGS"].count("-fcoverage-mapping"), 1)
            self.assertEqual(env["CGO_CFLAGS"].count("-fprofile-list="), 1)
            self.assertEqual(env["CGO_LDFLAGS"], "-Wl,--as-needed -fprofile-instr-generate")
            self.assertEqual(env["CGO_CPPFLAGS"], "-DCPP_USER=1")
            self.assertEqual(env["CGO_CXXFLAGS"], "-DCXX_USER=1")
            ldflags = call["args"][call["args"].index("-ldflags") + 1]
            self.assertIn("max-page-size=16384", ldflags)
            self.assertIn("coverage_probe.o", ldflags)
        self.record.unlink()
        result = self.run_build("x86_64")
        self.assertEqual(result.returncode, 0, result.stderr)
        env = json.loads(self.record.read_text())["env"]
        self.assertEqual(env["CGO_CFLAGS"], self.env["CGO_CFLAGS"])
        self.assertEqual(env["CGO_LDFLAGS"], self.env["CGO_LDFLAGS"])

    def test_coverage_compiler_failure_preserves_previous_library(self):
        directory = self.output / "x86_64"
        directory.mkdir(parents=True)
        library = directory / "libmihomo_bridge.so"
        library.write_bytes(b"previous library")
        self.env["BUILD_CORE_CC_FAIL"] = "1"
        result = self.run_build("x86_64", coverage=True)
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertEqual(library.read_bytes(), b"previous library")
        self.assertFalse(self.record.exists())
        self.assertEqual(list(directory.glob(".staging.*")), [])

    def test_build_api_uses_explicit_environment_without_mutating_inputs(self):
        before = dict(os.environ)
        provided = dict(self.env)
        libraries = build_core.build(ROOT, self.ndk, 24, self.output, ["armeabi-v7a", "x86_64"], env=provided)
        self.assertEqual(len(libraries), 2)
        self.assertEqual(provided, self.env)
        self.assertEqual(dict(os.environ), before)

    def test_unsupported_host_or_missing_compiler_stops_before_output(self):
        with mock.patch.object(build_core.platform, "system", return_value="Darwin"):
            with self.assertRaisesRegex(ValueError, "Linux"):
                build_core.build(ROOT, self.ndk, 24, self.output, ["x86_64"], env=self.env)
        self.assertFalse(self.output.exists())
        (self.ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android24-clang").unlink()
        with self.assertRaisesRegex(ValueError, "NDK"):
            build_core.build(ROOT, self.ndk, 24, self.output, ["x86_64"], env=self.env)
        self.assertFalse(self.output.exists())

    def test_coverage_output_with_spaces_and_arbitrary_cwd(self):
        self.output = self.base / "output with spaces"
        result = self.run_build("x86_64", coverage=True, cwd=self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.output / "x86_64/libmihomo_bridge.so").is_file())

    def test_gradle_filters_and_native_task_share_the_requested_abis(self):
        gradle = (ROOT / "android/app/build.gradle.kts").read_text()
        self.assertIn('"android-arm" to "armeabi-v7a"', gradle)
        self.assertIn('providers.gradleProperty("target-platform")', gradle)
        self.assertIn("abiFilters += nativeAbis", gradle)
        self.assertIn('inputs.property("abis", nativeAbis.joinToString(","))', gradle)
        self.assertIn('"--output", nativeOutput.get().asFile, "--abis", nativeAbis.joinToString(","))', gradle)
        self.assertIn('"android", "build-core"', gradle)
        self.assertIn('"dependencies", "prepare-build"', gradle)
        self.assertIn('include("**/*.py")', gradle)
        self.assertEqual(gradle.count("inputs.files(toolSources)"), 2)
        self.assertNotIn("build_core.sh", gradle)


if __name__ == "__main__":
    unittest.main()
