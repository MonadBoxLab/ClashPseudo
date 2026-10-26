"""用受控编译器核对原生构建参数、ABI隔离及失败时的产物保留。"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tool/android/build_core.sh"


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
            compiler.write_text("#!/bin/sh\nexit 0\n")
            compiler.chmod(0o755)
        go = self.bin / "go"
        go.write_text(
            "#!/usr/bin/env python3\n"
            "import json,os,pathlib,sys\n"
            "args=sys.argv[1:]\n"
            "if '-C' in args: os.chdir(args[args.index('-C')+1])\n"
            "if 'list' in args:\n print('v1.0.0'); sys.exit(0)\n"
            "with open(os.environ['BUILD_CORE_RECORD'],'a') as f:\n"
            " f.write(json.dumps({'args':args,'env':{k:os.environ.get(k) for k in "
            "['GOOS','GOARCH','GOARM','CC','CGO_ENABLED','GOTOOLCHAIN']}})+'\\n')\n"
            "if os.environ.get('BUILD_CORE_FAIL'): sys.exit(3)\n"
            "pathlib.Path(args[args.index('-o')+1]).write_bytes(b'controlled build')\n"
        )
        go.chmod(0o755)
        self.record = self.base / "commands.jsonl"
        self.output = self.base / "output"
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        BUILD_CORE_RECORD=str(self.record), GOARM="5")

    def run_build(self, abis, api="24"):
        return subprocess.run(["bash", str(SCRIPT), str(self.ndk), api, str(self.output), abis],
                              cwd=ROOT, env=self.env, capture_output=True, text=True, timeout=30)

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

    def test_gradle_filters_and_native_task_share_the_requested_abis(self):
        gradle = (ROOT / "android/app/build.gradle.kts").read_text()
        self.assertIn('"android-arm" to "armeabi-v7a"', gradle)
        self.assertIn('providers.gradleProperty("target-platform")', gradle)
        self.assertIn("abiFilters += nativeAbis", gradle)
        self.assertIn('inputs.property("abis", nativeAbis.joinToString(","))', gradle)
        self.assertIn('nativeOutput.get().asFile, nativeAbis.joinToString(","))', gradle)


if __name__ == "__main__":
    unittest.main()
