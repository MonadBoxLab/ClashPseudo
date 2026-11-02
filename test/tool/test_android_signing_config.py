"""检查 Gradle 和发布工作流中的签名参数、密钥文件清理顺序及本地材料保存。"""
import os
import re
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
SIGNING_NAMES = (
    "CLASH_PSEUDO_ANDROID_KEYSTORE_BASE64",
    "CLASH_PSEUDO_ANDROID_KEYSTORE_PASSWORD",
    "CLASH_PSEUDO_ANDROID_KEY_ALIAS",
    "CLASH_PSEUDO_ANDROID_KEY_PASSWORD",
)


def between(text, start, end):
    """截取指定起止标记之间的配置文本。"""
    if text.count(start) != 1:
        raise AssertionError(f"配置起点必须唯一：{start}")
    return text.split(start, 1)[1].split(end, 1)[0]


class AndroidSigningConfigTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # 从仓库中的 Gradle 文件和发布工作流读取配置。
        cls.gradle = (ROOT / "android/app/build.gradle.kts").read_text(encoding="utf-8")
        cls.workflow = (ROOT / ".github/workflows/update-dependencies.yml").read_text(encoding="utf-8")
        cls.signing = between(cls.gradle, "    val signingNames = listOf(\n", "\n    buildTypes {")
        cls.environment_key = between(
            cls.gradle,
            "        val key = if (hasEnvironmentSigning) {\n",
            '\n        } else localSigningFile.parentFile.resolve(localSigning.getProperty("storeFile"))',
        )

    def test_environment_contract_has_exactly_four_inputs(self):
        names = self.signing.split("\n    )", 1)[0]
        self.assertEqual(tuple(re.findall(r'"(CLASH_PSEUDO_ANDROID_[A-Z0-9_]+)"', names)), SIGNING_NAMES)
        self.assertIn('signingNames.map { providers.environmentVariable(it) }', self.signing)
        self.assertIn('environmentSigning.any { it.isPresent }', self.signing)
        self.assertIn('!hasEnvironmentSigning || environmentSigning.all { !it.orNull.isNullOrEmpty() }', self.signing)
        self.assertNotIn('.orNull.orEmpty()', self.signing)
        self.assertNotIn('.trim(', self.signing)
        self.assertNotIn('CLASH_SIGNING_', self.signing)

    def test_environment_selection_never_reads_or_mixes_local_properties(self):
        self.assertIn('if (!hasEnvironmentSigning && localSigningFile.exists()) {', self.signing)
        for index, name in ((1, "storePassword"), (2, "keyAlias"), (3, "keyPassword")):
            self.assertIn(
                f'{name} = if (hasEnvironmentSigning) environmentSigning[{index}].get() '
                f'else localSigning.getProperty("{name}")', self.signing,
            )
        self.assertNotIn('localSigning', self.environment_key)
        self.assertNotIn('getOrElse', self.environment_key)
        self.assertNotIn('runCatching', self.environment_key)

    def test_local_properties_keep_java_utf8_and_parent_relative_path_semantics(self):
        self.assertIn('val localSigningFile = rootProject.file("key.properties")', self.signing)
        self.assertIn('val localSigning = Properties()', self.signing)
        self.assertIn('localSigningFile.reader(Charsets.UTF_8).use(localSigning::load)', self.signing)
        self.assertIn('listOf("storeFile", "storePassword", "keyAlias", "keyPassword")', self.signing)
        self.assertIn('.all { !localSigning.getProperty(it).isNullOrEmpty() }', self.signing)
        self.assertIn(
            'localSigningFile.parentFile.resolve(localSigning.getProperty("storeFile"))', self.signing,
        )
        self.assertIn('require(key.isFile)', self.signing)

    def test_signing_values_reject_nul_without_normalizing_explicit_values(self):
        self.assertIn("environmentSigning.all { '\\u0000' !in it.get() }", self.signing)
        self.assertIn(".all { '\\u0000' !in localSigning.getProperty(it) }", self.signing)
        for normalization in ('.trim(', '.strip(', '.replace('):
            self.assertNotIn(normalization, self.signing)

    def test_distribution_flag_forbids_local_fallback_before_local_file_is_loaded(self):
        required = between(
            self.gradle,
            '    require(providers.environmentVariable("CLASH_REQUIRE_DISTRIBUTION_SIGNING")',
            '\n    val localSigningFile',
        )
        self.assertIn('.orNull != "true" ||\n        hasEnvironmentSigning)', required)
        self.assertNotIn('localSigning', required)

    def test_unsigned_release_graph_fails_even_before_packaging(self):
        guard = between(self.signing, '    gradle.taskGraph.whenReady {\n', '\n    }')
        self.assertIn(
            'require(hasSigning || allTasks.none { it.project == project && it.name.contains("Release") })',
            guard,
        )
        self.assertNotIn('startsWith("package")', guard)
        self.assertNotIn('startsWith("bundle")', guard)

    def test_debug_and_instrumentation_do_not_use_distribution_signing(self):
        debug = between(self.gradle, '        debug {\n', '\n        }')
        self.assertNotIn('signing', debug.lower())
        self.assertIn('enableAndroidTestCoverage = validationCoverage', debug)
        release = between(self.gradle, '        release {\n', '\n        }')
        self.assertIn('signingConfig = if (hasSigning) signingConfigs.getByName("distribution") else null', release)
        self.assertNotIn('getByName("debug")', release)

    def test_bad_or_empty_base64_fails_before_a_temporary_key_is_created(self):
        decode = self.environment_key.index('Base64.getDecoder().decode(environmentSigning[0].get())')
        empty = self.environment_key.index('require(bytes.isNotEmpty())')
        create = self.environment_key.index('Files.createTempFile(')
        self.assertLess(decode, empty)
        self.assertLess(empty, create)
        self.assertIn('throw failure', self.environment_key)

    def test_temporary_key_is_private_and_cleanup_precedes_write(self):
        self.assertIn('supportedFileAttributeViews().contains("posix")', self.environment_key)
        self.assertIn('PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------"))',
                      self.environment_key)
        self.assertIn('Files.createTempFile("clash-pseudo-signing-", ".jks", *permissions)', self.environment_key)
        self.assertLess(self.environment_key.index('deleteOnExit()'),
                        self.environment_key.index('Files.write(temporary, bytes)'))
        self.assertLess(self.environment_key.index('gradle.buildFinished {'),
                        self.environment_key.index('Files.write(temporary, bytes)'))
        self.assertEqual(self.environment_key.count('Files.deleteIfExists(temporary)'), 2)
        erased = between(self.environment_key, '            } finally {\n', '\n            }')
        self.assertIn('bytes.fill(0)', erased)

    def test_decoded_key_is_erased_even_if_private_temp_creation_fails(self):
        # 设置权限和创建临时文件也须位于 try/finally 内，使这些步骤失败时仍能清零密钥字节。
        after_decode = self.environment_key.split(
            'val bytes = Base64.getDecoder().decode(environmentSigning[0].get())\n', 1,
        )[1]
        self.assertTrue(after_decode.startswith('            try {\n'))
        protected = after_decode[len('            try {\n'):].split('\n            } finally {', 1)[0]
        for operation in ('require(bytes.isNotEmpty())', 'PosixFilePermissions.asFileAttribute(',
                          'Files.createTempFile(', 'Files.write(temporary, bytes)'):
            self.assertIn(operation, protected)

    def test_finish_cleanup_is_registered_before_later_signing_configuration_can_fail(self):
        # 检查 buildFinished 清理回调在写入密钥、检查文件和创建签名配置之前注册。
        registered = self.signing.index('gradle.buildFinished {')
        written = self.signing.index('Files.write(temporary, bytes)')
        checked = self.signing.index('require(key.isFile)')
        configured = self.signing.index('signingConfigs.create("distribution") {')
        self.assertLess(registered, written)
        self.assertLess(written, checked)
        self.assertLess(checked, configured)

    def test_cleanup_failures_keep_the_actual_build_or_write_failure(self):
        finished = between(self.environment_key, '                    gradle.buildFinished {\n',
                           '\n                    Files.write(temporary, bytes)')
        self.assertIn('val buildFailure = failure', finished)
        self.assertIn('if (buildFailure == null) throw cleanup', finished)
        self.assertIn('buildFailure.addSuppressed(cleanup)', finished)
        write_failure = between(self.environment_key, '                } catch (failure: Throwable) {\n',
                                '\n                }\n            } finally {')
        self.assertIn('Files.deleteIfExists(temporary)', write_failure)
        self.assertIn('failure.addSuppressed(cleanup)', write_failure)
        self.assertIn('throw failure', write_failure)
        self.assertNotIn('temporary.delete()', self.environment_key)

    def test_actions_supply_all_four_secrets_and_require_them(self):
        pairs = re.findall(
            r'^      (CLASH_PSEUDO_ANDROID_[A-Z0-9_]+): \$\{\{ secrets\.([A-Z0-9_]+) \}\}$',
            self.workflow, re.MULTILINE,
        )
        self.assertEqual(pairs, [(name, name) for name in SIGNING_NAMES])
        self.assertIn("      CLASH_REQUIRE_DISTRIBUTION_SIGNING: 'true'", self.workflow)
        for forbidden in ('key.properties', 'keytool', 'androiddebugkey', 'CLASH_SIGNING_'):
            self.assertNotIn(forbidden, self.workflow)

    def test_release_workflow_does_not_gain_push_pr_or_functional_test_duties(self):
        self.assertNotRegex(self.workflow, r'(?m)^\s+(?:push|pull_request|pull_request_target):')
        for command in ('flutter test', 'flutter analyze', 'go test', 'go vet', 'connectedAndroidTest'):
            self.assertNotIn(command, self.workflow)
        self.assertIn('  schedule:\n', self.workflow)
        self.assertIn('  workflow_dispatch:\n', self.workflow)

    def copy_local_materials(self, workspace, runner):
        block = between(self.workflow, '      - name: 保存本地发布材料与诊断输出\n',
                        '\n      - name: 保存发布材料与诊断输出')
        self.assertIn("if: ${{ always() && (env.ACT || env.CLASH_LOCAL_EXECUTION == 'true') }}", block)
        script = textwrap.dedent(block.split('        run: |\n', 1)[1])
        return subprocess.run(
            ['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', script],
            cwd=workspace, env={**os.environ, 'GITHUB_WORKSPACE': str(workspace), 'RUNNER_TEMP': str(runner)},
            capture_output=True, text=True, check=False,
        )

    def test_local_release_keeps_external_output_and_copies_all_materials_to_workspace(self):
        prepare = between(self.workflow, '      - name: 准备本地分发材料\n',
                          '\n      - name: 准备依赖更新与分发材料')
        self.assertIn('release.py --local --output "$RUNNER_TEMP/clash-release"', prepare)
        self.assertNotIn('--output "$GITHUB_WORKSPACE', prepare)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace, runner = root / 'bound workspace', root / 'runner temp'
            (workspace / '.local').mkdir(parents=True)
            source = runner / 'clash-release'
            expected = {
                '.diagnostics/output.log': '原始诊断\n',
                'local-release-fixture/release.json': '{}\n',
                'local-release-fixture/SHA256SUMS': '原始校验内容\n',
                'local-resources-fixture/resource-sources.json': '{}\n',
            }
            for name, content in expected.items():
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding='utf-8')
            (source / 'empty-diagnostics').mkdir()
            result = self.copy_local_materials(workspace, runner)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = workspace / '.local/release-materials'
            self.assertTrue((output / 'empty-diagnostics').is_dir())
            for directory in (source, output):
                actual = {path.relative_to(directory).as_posix(): path.read_text(encoding='utf-8')
                          for path in directory.rglob('*') if path.is_file()}
                self.assertEqual(actual, expected)

    def test_local_material_copy_rejects_an_existing_output_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace, runner = root / 'bound workspace', root / 'runner temp'
            output = workspace / '.local/release-materials'
            output.mkdir(parents=True)
            (output / 'original').write_text('旧材料\n', encoding='utf-8')
            source = runner / 'clash-release'
            source.mkdir(parents=True)
            (source / 'replacement').write_text('本次材料\n', encoding='utf-8')
            result = self.copy_local_materials(workspace, runner)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(output.iterdir()), [output / 'original'])
            self.assertEqual((output / 'original').read_text(encoding='utf-8'), '旧材料\n')
            self.assertTrue((source / 'replacement').is_file())

    def test_local_material_copy_does_not_create_output_when_the_source_is_absent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace, runner = root / 'bound workspace', root / 'runner temp'
            (workspace / '.local').mkdir(parents=True)
            runner.mkdir()
            result = self.copy_local_materials(workspace, runner)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((workspace / '.local/release-materials').exists())

    def test_remote_artifact_upload_remains_always_and_excludes_local_execution(self):
        upload = between(self.workflow, '      - name: 保存发布材料与诊断输出\n', '\n      - name:')
        self.assertIn("if: ${{ always() && !env.ACT && env.CLASH_LOCAL_EXECUTION != 'true' }}", upload)
        self.assertIn('uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2', upload)
        self.assertIn('path: ${{ runner.temp }}/clash-release', upload)
        self.assertEqual(self.workflow.count('uses: actions/upload-artifact@'), 1)
        self.assertIn("if: ${{ success() && !env.ACT && env.CLASH_LOCAL_EXECUTION != 'true' && steps.release.outputs.plan != '' }}",
                      self.workflow)
        self.assertNotIn('continue-on-error:', self.workflow)

    def test_existing_native_abi_coverage_and_legal_hooks_remain(self):
        for platform, abi in (("android-arm", "armeabi-v7a"), ("android-arm64", "arm64-v8a"),
                              ("android-x64", "x86_64")):
            self.assertIn(f'"{platform}" to "{abi}"', self.gradle)
        self.assertIn('"../tool/android/build_core.sh"', self.gradle)
        self.assertIn('"Native coverage must never be packaged in a release variant"', self.gradle)
        self.assertIn('tasks.named("preBuild") { dependsOn(buildNativeCore, prepareBundledLegalAssets) }',
                      self.gradle)


if __name__ == "__main__":
    unittest.main()
