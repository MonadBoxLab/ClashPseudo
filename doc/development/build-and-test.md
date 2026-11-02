# 构建、自动化测试与验证工具

命令在项目根目录执行。先按任务选择入口，再准备对应工具链、输出目录和授权：

| 任务 | 入口 | 主要输出 |
| --- | --- | --- |
| 日常修改检查 | 下文“自动化测试” | 分语言退出码与测试结果 |
| 更新依赖或应用版本 | tool/dependencies/update.py | 限定输入、锁文件及法律材料 |
| 本地完整交付 | “本地隔离act交付” | 四APK、对应源码、许可及SHA256SUMS |
| Android lifecycle／JNI | “Android测试变体” | 配套主包、test APK和逐项JUnit结果 |
| 系统界面操作 | “SDK观察器” | SDK节点／动作回执及process identity |
| 网络集成 | “受控网络服务” | 动态端口、请求记录和关闭回执 |
| 产物、备份和覆盖率核验 | 文末各工具入口 | 核验报告、原字节比较或覆盖率数据 |

行为断言见[验证方法](verification.md)，执行职责见[应用架构](../architecture/overview.md)。路径占位符替换为本次工具链及输入的绝对路径。

## 工具链与构建

Flutter／Dart要求由[pubspec.yaml](../../pubspec.yaml)及[锁文件](../../pubspec.lock)确定，Android编译配置见[Gradle](../../android/app/build.gradle.kts)，Go版本和内核依赖见[go.mod](../../native/mihomo/go.mod)。原生[Bash入口](../../tool/android/build_core.sh)使用Linux x86_64构建宿主和项目选定的NDK／Go生成原生库。

构建前使 `ANDROID_HOME`／`ANDROID_SDK_ROOT` 与 `android/local.properties` 中的 `sdk.dir` 指向同一实际SDK；如同时设置两个环境变量，也应保持一致。Gradle从解析出的SDK目录取得NDK，产物核验工具从SDK环境取得Build Tools。`local.properties` 只记录本机位置，不纳入对应源码。

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
# release要求可用签名，来源与失败规则见下文。
flutter build apk --release --no-pub --target-platform android-arm,android-arm64,android-x64
```

Gradle按abiFilters和原生任务输入生成libmihomo_bridge.so，生产标签为`cmfa,with_gvisor`。JNI入口及保护callback由Keep保留。普通分发使用正常release配置；下文覆盖率采集另启`validationCoverage`或`validationNativeCoverage`测试变体。

## 依赖更新与应用版本

[依赖入口](../../tool/dependencies/update.py)检查 mihomo 的最新正式 GitHub Release。`--check` 只查询并报告版本，保持工作树原状。GitHub Actions 发现新 mihomo 正式 Release，或用户显式准备应用 release 时，`--apply` 在隔离副本中统一解析 mihomo、相关 Go／hosted Pub／Maven 依赖、CA／Geo、兼容工具链及许可，再核对原工作树身份并写回限定输入。准备期间源码发生变化时停止写回。

```sh
python3 -I -B tool/dependencies/update.py --check
# 准备新的应用 release，默认递增 patch。
python3 -I -B tool/dependencies/update.py --apply
# 同一次尚未分发的候选准备沿用应用版本。
python3 -I -B tool/dependencies/update.py --apply --reuse-version
```

工具链从官方 stable 元数据和兼容矩阵解析，保留 API24；Flutter 使用随附 Dart。SDK／Build Tools／NDK、Go、Java、Gradle、AGP 和 Kotlin 的选中版本、固定下载来源、摘要及排除原因随资源记录保存。本地 re_editor 保持 path 来源；protobuf replace 和其他许可要求按实际模块图复核，见[许可升级规范](../legal/dependencies.md#内核与依赖升级复核)。

[release 输入记录](../../third_party/data/resources.json)保存五项资源的来源、版本／commit、大小、SHA-256、可编辑来源身份、许可、工具链与依赖解析决定。本机安装位置另写环境报告，不进入对应源码。普通构建、测试和同次 act 重试只消费固定输入，不查询 latest；缺少 payload 时按固定 URL 下载并核对摘要，不刷新 release 记录。

### 固定输入与 generated assets

先准备记录中的工具链，再生成资源，最后开始 Flutter／Gradle 构建。工具链准备入口不会查询最新版本：

```sh
python3 -I -B tool/dependencies/toolchains.py \
  --environment /path/to/toolchain-environment.json
python3 -I -B tool/dependencies/update.py --prepare-build
# 已有 payload 的离线准备。
python3 -I -B tool/dependencies/update.py --prepare-build --offline
```

环境报告中的 `environment` 对象提供 `JAVA_HOME`、`ANDROID_HOME`、`ANDROID_SDK_ROOT`、`PATH`、`GOTOOLCHAIN` 和 `CLASH_GRADLE`。后续命令使用这些实际路径；Gradle 可直接执行 `CLASH_GRADLE` 指向的固定可执行文件。准备入口同时写入本机 `android/local.properties`，不把其路径作为分发输入。

五项 payload、资源 manifest、BundledAssetContract 和法律资产输出至 `build/generated/bundled/`，Gradle 将其中 assets 与 Kotlin source 注册为生成输入。源码目录不保存 payload，也不以旧源码 manifest 作为 fallback。应用内许可、APK 核验和对应源码打包使用同一资源记录。离线重建对应源码包时，可通过 `--payload-directory` 指向包内 `build-inputs/bundled/assets/`。

### 应用版本

[pubspec.yaml](../../pubspec.yaml)是应用版本的唯一来源，采用 x.y.z+N，独立于内核版本。正式稳定发布前使用 **0.y.z 开发版本**：功能新增或不兼容调整递增 y 并将 z 归零，缺陷、安全及常规依赖维护递增 z。自动更新保持0.y.z阶段，首次1.x通过下述stable操作准备。

首次稳定发布须由用户明确决定，通过 `--bump stable` 将 0.y.z 提升为 **1.0.0**；不沿用开发阶段的 y。稳定期按一次完整交付的变化确定增量：

- **x，主版本**：需要用户调整或处理的不兼容变化，例如配置／备份格式的不兼容变化、重要能力移除或核心使用流程变化。递增 x 后，y、z 归零。
- **y，次版本**：向后兼容的应用功能新增。递增 y 后，z 归零。
- **z，补丁版本**：保持既有使用contract的维护更新，包括缺陷修复、安全更新、性能改善及常规依赖升级。

常规 mihomo 正式版更新默认递增 z；同次发布的内核升级次数不单独叠加应用版本。版本在构建前确定，不由每次 commit、测试、覆盖采集或内部里程碑递增。Flutter 的 x.y.z+N 中，x.y.z 对应 Android versionName，N 对应 versionCode；每个新的 Android 分发版本递增 N，同次发布的失败重试、续跑与缺失资产补齐复用已经确定的版本。即使订正显示版本阶段，N 也不回退；历史产物及其材料保持原版本与字节。

```sh
# 准备应用功能版本及同次 release 输入。
python3 -I -B tool/dependencies/update.py --apply --bump minor
# 仅在用户明确决定首次稳定发布时执行；不自动触发。
python3 -I -B tool/dependencies/update.py --apply --bump stable
# 稳定期不兼容变化使用 major；开发期 major 会拒绝。
python3 -I -B tool/dependencies/update.py --apply --bump major
# 同一次尚未分发的候选准备沿用已经确定的版本。
python3 -I -B tool/dependencies/update.py --apply --reuse-version
```

源码、Git tag、APK 和对应源码包使用同一版本。显式执行 `--apply` 表示准备一次应用 release；`--reuse-version` 用于同一次待发布交付，不代表新分发版本。GitHub Actions 未发现新 mihomo 且没有显式应用发布请求时，只报告检查结果，不刷新资源或创建 release。0.y.z 的 GitHub Release 标记为 prerelease，首次稳定提升只接受明确的手动选择。release 是 APK 构建模式，开发／稳定阶段由应用版本确定。

### 独立产物核验输入

`--apply --evidence '<新目录>'`从实际 Go 模块解析、Android releaseRuntimeClasspath 及独立的 Flutter release bundle 构建生成 go-modules.json、android-dependencies.txt 和 decoded NOTICES。输入目录在命令前保持不存在，Flutter SDK 的正常生成文件仍使用构建输出目录。产物核验将这些输入与待检 APK 比较，调用见[许可核验工具](#备份与许可核验工具)。

## Android 分发与 GitHub Actions

每次发布提供四个正常 release APK，应用身份为 `io.github.monadboxlab.clashpseudo`。四包共享 pubspec.yaml 中的 versionName、versionCode、mihomo 版本和分发签名。构建配置通过 Flutter 的 `force-version-code-ignoring-abi` 开关保持分架构包的 versionCode；架构包数量与构建重试保持该次已确定版本。

| 文件名，其中版本为 x.y.z+N | 适用范围 |
| --- | --- |
| clash-pseudo-x.y.z+N-universal.apk | **Android 通用版（推荐）**，包含 armeabi-v7a、arm64-v8a、x86_64，下载体积较大 |
| clash-pseudo-x.y.z+N-arm64-v8a.apk | 运行 64 位 Android 的大多数现代手机和平板 |
| clash-pseudo-x.y.z+N-armeabi-v7a.apk | 使用 32 位 Android 系统的设备 |
| clash-pseudo-x.y.z+N-x86_64.apk | 相应设备和模拟器 |

本地四包构建顺序：

1. 固定源码及资源输入，执行通用构建。
2. 将`build/app/outputs/flutter-apk/app-release.apk`复制为独立产物目录中的版本化universal文件。
3. 执行分架构构建，从同目录取得`app-ABI-release.apk`三个文件。
4. 逐包检查目标ABI、原生库、buildinfo、生产tags、16KiB对齐、版本、签名及法律资产，再生成对应源码和许可包。

```sh
flutter build apk --release --no-pub --target-platform android-arm,android-arm64,android-x64
# 将app-release.apk保存为产物目录中的版本化universal文件后，再执行下一条。
flutter build apk --release --no-pub --target-platform android-arm,android-arm64,android-x64 --split-per-abi
python3 -I tool/artifacts/package_sources.py --evidence '<核验输入目录>' \
  --resource-sources '<固定资源可编辑来源清单>' --output '<版本对应源码.tar.gz>'
```

四包共享覆盖实际源码和依赖的 sources.tar.gz 与 licenses.tar.gz。SHA256SUMS 包含全部四个 APK、对应源码包及许可包。对应源码入口默认读取当前工作树的正式输入，包含必要的未忽略新增文件，按当前删除状态处理已删除文件；`build-inputs/source-tree.json` 记录 workingTree、dirty、基准提交及逐文件字节数／SHA-256／可执行位，归档期间复核源码稳定。`--commit '<提交>'`适用于与该提交一致的干净源码。固定资源可编辑来源清单默认取核验输入目录中的 `resource-sources.json`，也可由上述参数指定；材料要求见[许可升级规范](../legal/dependencies.md)。SDK 本机位置、签名材料和设备备份保持在源码包之外，公开合成测试证书与私钥随测试保留。

[自动工作流](../../.github/workflows/update-dependencies.yml)每日检查 mihomo 正式 Release，也接受手动触发。新内核维护发布默认递增 patch；手动触发可选择完整交付所需的 minor、稳定期 major，或明确选择 stable 准备首次 1.0.0 稳定发布；定时任务不能执行 stable 提升。publish_current 用于准备一次独立应用发布。pubspec.yaml 已准备新版本时复用该版本；首次稳定选择必须实际提升开发版本，不能被未建 tag 的版本复用逻辑跳过。已有未完成发布按原 tag 与开发／稳定性质续跑，保留已成功资产，按校验文件或原始 Actions 归档恢复缺失材料，完成核验后补齐远程资产。

发布使用[GitHub Actions工作流](../../.github/workflows/update-dependencies.yml)：

1. [release.py](../../tool/dependencies/release.py)生产模式在独立CI工作区准备发布输入，提交限定变更，原子推送应用tag和源码。
2. [publish-release.cjs](../../.github/scripts/publish-release.cjs)核对远程tag、版本归属和全部资产摘要。
3. 建立draft，上传并核验完整资产后正式发布。

生产`ReleasePreparation.execute`执行fetch、reset、提交、tag和push，运行前取得该次真实Actions发布授权。本地交付选择下文的`--prepare-act`及`--local`。

### 本地隔离act交付

先固定待交付的源码和资源来源，再用`--prepare-act`在项目外的新目录生成独立源码副本和act启动文件：

```sh
python3 -I -B tool/dependencies/release.py --prepare-act \
  --project /path/to/frozen-project \
  --output '/var/tmp/<new-empty-act-root>' \
  --resource-sources /path/to/resource-sources.json \
  --runner-image '<Debian系runner镜像:tag或digest>' \
  --artifact-host '<runner容器可达的限定IPv4>' \
  --docker-host '<显式Docker unix endpoint>' \
  --act /usr/local/bin/act
```

准备完成后得到以下材料；随后由validate、dryrun和command分别执行检查及job：

| 目录／文件 | 内容 |
| --- | --- |
| workspace、origin.git | 固定输入副本及隔离本地Git来源 |
| home、action-cache、artifacts、cache、temp、docker-config | 本次运行使用的独立目录 |
| control/launch.json | cwd、白名单environment及validate／dryrun／command参数数组 |
| control/secrets | 初始空、0600；由获授权操作者从既有分发签名配置填入四项签名变量 |

runner选择明确的Debian／Ubuntu系tag或digest；artifact-host使用容器可达的限定IPv4，排除loopback、unspecified和multicast；docker-host显式提供本机Unix endpoint。启动环境使用launch.json的白名单，签名值写入secrets文件并保持在命令参数和日志之外。

分别执行validate、dryrun，再执行command。以下示例运行validate；检查结果后，将末尾参数依次改为dryrun和command，沿launch.json保存的环境与数组调用：

```sh
python3 -I -B - '/var/tmp/<act-root>/control/launch.json' validate <<'PY'
import json
import subprocess
import sys
from pathlib import Path

launch = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
phase = sys.argv[2]
if phase not in ("validate", "dryrun", "command"):
    raise SystemExit("phase must be validate, dryrun or command")
raise SystemExit(subprocess.run(
    launch[phase], cwd=launch["cwd"], env=launch["environment"],
    check=False,
).returncode)
PY
```

本地job使用以下入口，要求`CLASH_LOCAL_EXECUTION=true`，从副本`.local`固定来源生成完整四APK、对应源码、许可及SHA256SUMS：

```sh
python3 -I -B tool/dependencies/release.py --local \
  --output "$RUNNER_TEMP/clash-release"
```

`--local`使用独立LocalPreparation，从副本`.local/input.json`读取固定输入，复用当前应用版本和依赖，构建前后比较输入身份。输出plan标记local及workingTree，Node发布入口据此拒绝远程发布。记录表分别填写prepare、validate、dryrun、job及逐包核验的命令、退出码和产物摘要；远程发布使用获授权的真实GitHub Actions工作区。

### 签名来源

Gradle与发布工具共用以下四个环境变量；Actions从同名Secrets提供：

- `CLASH_PSEUDO_ANDROID_KEYSTORE_BASE64`：用户控制的固定 Android 分发密钥文件的 Base64 内容。
- `CLASH_PSEUDO_ANDROID_KEYSTORE_PASSWORD`：密钥库密码。
- `CLASH_PSEUDO_ANDROID_KEY_ALIAS`：密钥别名。
- `CLASH_PSEUDO_ANDROID_KEY_PASSWORD`：密钥密码。

四项中任一变量存在即选择环境来源，空字符串也算存在；此时四项都须非空且不含NUL。值保持原样，不trim，不与本地配置混合，也不在部分或无效环境输入时回退。Base64按Java `Base64.getDecoder()` 解码原值，允许省略末尾padding，拒绝多余padding和空解码结果。

仅当四项全部不存在时读取 `android/key.properties`，必需属性为 `storeFile`、`storePassword`、`keyAlias`、`keyPassword`。文件按 `java.util.Properties.load(UTF-8 Reader)` 解释分隔符、空白、转义与续行；例如 `storePassword==abc` 的值为 `=abc`。四项须非空且不含NUL，`storeFile` 相对properties文件的父目录解析，密钥须为已有文件。

`CLASH_REQUIRE_DISTRIBUTION_SIGNING=true` 在读取本地配置前要求四环境来源。Actions固定使用这一设置，缺少Secret时构建失败。release任务要求可用签名，debug／instrumentation在无签名配置时使用标准调试签名；若显式提供了坏配置，配置阶段仍会报错。

环境密钥恢复到仓库外自有临时文件，POSIX权限为0600，成功与失败均执行清理。密钥和密码只由用户授权提供，文档约定本地配置位置；日志、构建归档和对应源码只保留公开证书摘要与分发材料。已有调试签名安装切换固定分发签名时，通过应用备份／恢复衔接数据。

### Actions启用

启用发布前确认远程默认分支、GITHUB_TOKEN的提交／tag推送策略及四个签名Secrets。按用户确定的公开发布时点将仓库变量 `AUTOMATIC_RELEASES_ENABLED` 设为 `true`；手动触发与公开发布同样按用户授权执行。job使用 contents: write 和 actions: read，保持同仓库发布串行执行。

## 共同静态contract

[application contract](../../contracts/application.json)维护跨Dart、Kotlin、Go和JNI共同使用的容量、期限、归档字段及core IPC协议。[生成入口](../../tool/contracts/generate.py)生成各语言的编译期定义；各层检查实际收到的输入，运行身份和期限起点取自实际受理与执行。修改声明后生成，在构建及独立测试前检查一致性：

```sh
python3 -I tool/contracts/generate.py
python3 -I tool/contracts/generate.py --check
```

原生构建入口检查静态 contract 生成结果，`--check` 不依赖资源下载。Gradle 跟踪声明、生成器及影响原生编译的环境参数。Geo／CA 元数据由固定 release 记录和本次生成 manifest 单独生成至 `build/generated/bundled/`，沿用 `asset_metadata` 的校验；法律资产从同次来源与许可原文生成。APK 核验比较包内 payload、元数据及法律资产的实际字节。

### Core IPC contract

| 声明 | 内容 |
| --- | --- |
| core_ipc | 协议版本、控制消息与身份上限、FD frame kind及queue容量 |
| core_operation | 准备、TUN交接、查询、更新、取消及退出的固定操作码 |
| core_channel／core_part | 平台入口名称及输入分段名称 |
| core_field | 进程、context、输入、请求、网络与存储身份，以及受理、结果和实际退出字段 |
| core_purpose／core_phase／core_error | 用途、连接及运行阶段、机器错误码 |

Binder控制消息最多64KiB，大输入和逐条结果经ParcelFileDescriptor传输。每frame由4字节大端载荷长度、1字节frame kind及载荷组成，长度不包含frame kind。single frame载荷最多8MiB，排队数据最多16MiB；完整集合按记录传输，不设8MiB总量限制。未收到complete terminal frame就遇到EOF时，记录传输中断。

准备输入将正文、片段和options分段传输，分别保留16MiB、128MiB和16MiB的实际字节预算。受理回执、取消结果及调用退出分别核对；断开连接或关闭管道不代表调用已经退出。生成器测试检查操作码和frame kind不重复、容量关系有效，以及各语言定义一致。

## 自动化测试

固定本次源码和生成输入后执行下列检查，共用Flutter／Gradle输出目录的命令串行运行。测试目录与定位方式如下：

| 目录 | 受测职责 |
| --- | --- |
| `test/model/` | 业务值、消息、snapshot、身份和纯格式预算 |
| `test/logic/` | AppRuntime、业务动作、配置／插件／偏好文件的读写、调度及文件I/O |
| `test/platform/` | channel、core输入和trust适配 |
| `test/ui/` | 展示Controller、本地化显示、组件及页面交互 |
| `test/support/` | 跨功能测试共用的模拟实现、数据和辅助工具 |

同一主题按断言所属层分别测试。例如消息包含[模型](../../test/model/app_message_test.dart)、[本地化显示](../../test/ui/locale/app_message_test.dart)、[消息存储](../../test/logic/storage/message_storage_test.dart)和[平台解码](../../test/platform/channel/platform_message_test.dart)；存储预算包含[纯JSON](../../test/model/storage_json_test.dart)及[文件I/O](../../test/logic/storage/storage_files_test.dart)。DNS与普通诊断分别测试[原始响应模型](../../test/model/dns_passthrough_test.dart)、[平台诊断解码](../../test/platform/channel/diagnostic_reads_test.dart)、[Controller等待调用完成](../../test/ui/diagnostics/dns/dns_passthrough_test.dart)和[诊断读取的来源检查](../../test/ui/diagnostics/read_passthrough_test.dart)。不指定文件运行flutter test时，执行整个test目录中的测试。

```sh
python3 -I tool/contracts/generate.py --check
flutter analyze
flutter test
GOTOOLCHAIN=local go -C native/mihomo test -tags=cmfa,with_gvisor ./... -count=1
GOTOOLCHAIN=local go -C native/mihomo vet -tags=cmfa,with_gvisor ./...
./android/gradlew -p android :app:assembleDebug :app:assembleDebugAndroidTest :app:testDebugUnitTest -Ptarget-platform=android-x64
python3 -I -B -m unittest discover -s test/tool -v
node --test test/tool/dependency_release_action.test.cjs
git diff --check
```

格式检查与Go并发诊断沿现有工具单独执行：

```sh
dart format --output=none --set-exit-if-changed lib test tool/coverage benchmark
GOTOOLCHAIN=local go -C native/mihomo test -tags=cmfa,with_gvisor -race ./...
```

检查结果按入口记录：Flutter报告页面、业务及平台桥断言，Go报告生产tags下的接入调用，JVM／instrumentation报告Android机制，Python／Node报告工具输入、失败和清理结果。失败时保留原输出、失败用例及所用输入；修改后重新执行对应入口。记录字段见[结果记录](verification.md#结果口径)。

### 表单到parsercontract

先运行Flutter表单测试，生成包含YAML正文的测试数据，再将同一JSON文件交Go Compose和公开parser。`OUT`设为项目外独立工作目录的绝对路径，两个命令共用该文件：

```sh
DEFINITION_FORMS_OUTPUT="$OUT/definition-forms.json" flutter test --no-pub \
  test/ui/overrides/forms/shared/definition_forms_test.dart
DEFINITION_FORMS_GENERATED="$OUT/definition-forms.json" GOTOOLCHAIN=local \
  go -C native/mihomo test -tags cmfa,with_gvisor ./...
```

[定义contract](../../native/mihomo/internal/engine/definition_forms_contract_test.go)检查组、provider和规则保存输入经两种Compose后解析；[节点contract](../../native/mihomo/internal/engine/proxy_form_contract_test.go)分别覆盖24种GUI新建和28种原始type。记录各type的表单输出及parser结果，协议网络用例另记录受控端请求和会话结果。

## 宿主算法基准

[连接窗口基准](../../benchmark/connections.dart)使用合成记录调用生产ConnectionWindow，测量宿主上的窗口操作、耗时和内存。其[正确性回归](../../test/benchmark/connection_benchmark_test.dart)随Flutter测试运行；根级基准由维护者显式执行，设备VPN与IME测量见[集成验证](verification.md)。

```sh
dart run benchmark/connections.dart
```

## Android测试变体

AndroidJUnitRunner以主应用为target，会重启目标进程。需要保留的数据按对应环境要求保存；可重建的专用开发数据按场景重新建立。正常Stop与资源退出通过对应功能路径验证。主包和test APK须配套构建，Kotlin internal名称含module／variant身份，profile定位也使用对应测试变体。

```sh
./android/gradlew -p android :app:assembleDebug :app:assembleDebugAndroidTest \
  -Ptarget-platform=android-arm64,android-x64
adb -s "$SERIAL" install -r build/app/outputs/apk/debug/app-debug.apk
adb -s "$SERIAL" install -r -t build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb -s "$SERIAL" shell am instrument -w -r \
  -e class 'io.github.monadboxlab.clashpseudo.logic.LogicEngineHostTest#coldProcessExecutesRealDartAndReturnsWithoutPreparingCore' \
  io.github.monadboxlab.clashpseudo.test/androidx.test.runner.AndroidJUnitRunner
adb -s "$SERIAL" shell am instrument -w -r \
  -e class io.github.monadboxlab.clashpseudo.nativecore.NativeCoreFailureTest \
  io.github.monadboxlab.clashpseudo.test/androidx.test.runner.AndroidJUnitRunner
```

先在设备上独立运行上述调用真实Dart的冷启动用例，再运行通用、JNI及lifecycle分组。需要VPN授权的组单独列出，取得目标设备授权后执行。SERIAL明确指定设备；nonce、配置ID／revision／epoch、预期摘要和控制执行顺序的参数由所选测试声明。记录配套主包／test APK的SHA-256、设备API／ABI、每项JUnit结果及runner结论。测试结束后，按实际改变的进程状态和业务数据恢复现场。覆盖安装前保存可恢复备份；实体设备的卸载或清数据须另获用户授权。

## SDK观察器

[SystemEntryInstrumentation](../../android/app/src/androidTest/java/io/github/monadboxlab/clashpseudo/validation/SystemEntryInstrumentation.java)使用API24起的公开SDK读取窗口并执行指定动作。其instrumentation的targetPackage为自身，在test包进程中运行；主应用测试则使用以主应用为target的AndroidJUnitRunner。

[构建器](../../tool/android/build_sdk_observer.py)接受明确工具链，依次执行javac、d8、aapt2、zipalign、apksigner，生成`observer.apk`和记录源码／APK摘要、manifest及命令退出码的构建材料：

```sh
python3 -I tool/android/build_sdk_observer.py \
  --android-jar '<Android平台android.jar>' \
  --build-tools '<Build Tools目录>' \
  --java-release '<项目Java编译目标>' \
  --min-api '<min API>' --target-sdk '<target SDK>' \
  --debug-keystore '<标准debug.keystore>' \
  --output "$OUT/sdk-observer-build"
```

在目标设备安装生成的self-target观察器，并从`build.json`读取`apkSha256`：

```sh
SERIAL='<目标serial>'
adb -s "$SERIAL" install -r -t "$OUT/sdk-observer-build/observer.apk"
OBSERVER_SHA256="$(python3 -I -c 'import json, sys; from pathlib import Path; print(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["apkSha256"])' "$OUT/sdk-observer-build/build.json")"
```

[运行器](../../tool/android/run_sdk_observer.py)核查self-target元数据、已安装test APK的摘要及API／ABI，并记录动作前后的主进程PID／startTicks与SDK配置回执，输出到仓库外系统临时目录的新路径。输出中保留动作前后配置和process identity，并与场景要求的配置名及接管结果关联。serial指定目标，allowed-serial给出接受列表，可重复提供。

```sh
python3 -I tool/android/run_sdk_observer.py \
  --serial "$SERIAL" --allowed-serial "$SERIAL" \
  --action snapshot --apk-sha256 "$OBSERVER_SHA256" \
  --window-package io.github.monadboxlab.clashpseudo \
  --label '<精确预期标签>' --output "$OUT/sdk-observation"
```

观察器与AndroidJUnitRunner test APK使用同一包名`io.github.monadboxlab.clashpseudo.test`。切回上节debug主应用instrumentation时，先重新安装与当前主包配套构建的test APK，再运行测试：

```sh
adb -s "$SERIAL" install -r -t build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb -s "$SERIAL" shell am instrument -w -r \
  -e class io.github.monadboxlab.clashpseudo.nativecore.NativeCoreFailureTest \
  io.github.monadboxlab.clashpseudo.test/androidx.test.runner.AndroidJUnitRunner
```

snapshot读取指定的精确标签，click定位唯一对象并提交一次动作，start／stop要求预期配置名。通知与界面操作通过allow-ui-action启用。运行器记录节点匹配、动作受理和SDK回执；对应测试另外检查业务状态及资源是否退出。超时或取消时保留unconfirmed和已有回执；动作执行前完成APK摘要等检查。

## 受控网络服务

[native_fixture.py](../../tool/network/native_fixture.py)用Python标准库提供合成HTTP、UDP、DNS UDP＋TCP及限定目标SOCKS。传入本机数值IPv4和nonce，动态端口由ready事件报告，DNS双协议共用实际端口：

```sh
python3 -I tool/network/native_fixture.py \
  --host '<本机IPv4地址>' --nonce controlled-check --seconds 60
python3 -I tool/network/native_fixture.py --self-test
```

nonce由8..48个小写字母、数字或连字符组成，服务运行1..300秒，最多接受10条连接。SOCKS只转发该服务的HTTP，DNS只为.fixture.test合成A记录；IPv6等场景另设测试服务。到期或终止后，关闭监听和已接受连接，等待请求与受理threadjoin；closed事件返回tasksJoined／remainingAccepted。

/config、/direct提供完整配置，/modes区分模式选路，/strategies提供成员与provider变化，/slow-config、/redirect、/update、/update-fails覆盖迟到、重定向、更新和失败。定义见[scenarios.py](../../tool/network/native_fixture/scenarios.py)，回归见[工具回归](../../test/tool)。

## 备份与许可核验工具

[verify_backup.py](../../tool/artifacts/verify_backup.py)流式检查manifest、固定三文件、实际大小／CRC／SHA及输入身份。比较三个业务文件原始字节，ZIP时间戳和压缩方式差异单独处理：

```sh
python3 -I tool/artifacts/verify_backup.py '<正式导出.zip>'
python3 -I tool/artifacts/verify_backup.py '<受保护原件.zip>' --compare '<重新导出.zip>'
```

[verify_release_licenses.py](../../tool/artifacts/verify_release_licenses.py)核查法律资产、独立来源的decoded NOTICES、各ABI的Go buildinfo、模块Version／Sum／Replace／tags，以及CA、Geo和PSL来源材料。预期输入通过[依赖入口](#独立产物核验输入)生成。`--xnet-source`使用`go-modules.json`实际选中的x/net模块原始zip；工具核对模块h1、编译表修订、通知和可编辑PSL列表。

universal省略`--abi`时要求armeabi-v7a、arm64-v8a、x86_64三个架构；三个分架构包各指定对应的`--abi`。每个APK使用各自已存在的空输出目录。将`OUT`设为项目外本次工作目录的绝对路径，再创建四个报告目录并逐包核验：

```sh
EVIDENCE='<核验输入目录的绝对路径>'
XNET_SOURCE='<实际选中x/net模块的原始zip绝对路径>'
APK_DIR='<四个APK所在目录的绝对路径>'
VERSION='<x.y.z+N>'
mkdir "$OUT/license-universal" "$OUT/license-armeabi-v7a" \
  "$OUT/license-arm64-v8a" "$OUT/license-x86_64"

python3 -I tool/artifacts/verify_release_licenses.py \
  --project "$PWD" --apk "$APK_DIR/clash-pseudo-$VERSION-universal.apk" \
  --notices "$EVIDENCE/NOTICES" --go-modules "$EVIDENCE/go-modules.json" \
  --android-dependencies "$EVIDENCE/android-dependencies.txt" \
  --xnet-source "$XNET_SOURCE" --output-dir "$OUT/license-universal"

python3 -I tool/artifacts/verify_release_licenses.py \
  --project "$PWD" --apk "$APK_DIR/clash-pseudo-$VERSION-armeabi-v7a.apk" \
  --abi armeabi-v7a \
  --notices "$EVIDENCE/NOTICES" --go-modules "$EVIDENCE/go-modules.json" \
  --android-dependencies "$EVIDENCE/android-dependencies.txt" \
  --xnet-source "$XNET_SOURCE" --output-dir "$OUT/license-armeabi-v7a"

python3 -I tool/artifacts/verify_release_licenses.py \
  --project "$PWD" --apk "$APK_DIR/clash-pseudo-$VERSION-arm64-v8a.apk" \
  --abi arm64-v8a \
  --notices "$EVIDENCE/NOTICES" --go-modules "$EVIDENCE/go-modules.json" \
  --android-dependencies "$EVIDENCE/android-dependencies.txt" \
  --xnet-source "$XNET_SOURCE" --output-dir "$OUT/license-arm64-v8a"

python3 -I tool/artifacts/verify_release_licenses.py \
  --project "$PWD" --apk "$APK_DIR/clash-pseudo-$VERSION-x86_64.apk" \
  --abi x86_64 \
  --notices "$EVIDENCE/NOTICES" --go-modules "$EVIDENCE/go-modules.json" \
  --android-dependencies "$EVIDENCE/android-dependencies.txt" \
  --xnet-source "$XNET_SOURCE" --output-dir "$OUT/license-x86_64"
```

逐包保留核验报告中的文件摘要、依赖差异及错误，并按[许可依据](../legal/dependencies.md)补齐对应材料；分发清单见[NOTICE](../../NOTICE.md)。

## 覆盖率入口

Dart使用[采集工具](../../tool/coverage/flutter.dart)的collect入口。输出为仓库外系统临时目录中的新绝对路径，父目录须已存在。工具在独立临时目录创建加载全部应用库的loader及根hook执行副本，退出时清理：

```sh
dart run tool/coverage/flutter.dart collect "$OUT/coverage-run"
dart run tool/coverage/summary.dart "$OUT/coverage-run/application.info"
```

检查采集工具的完整执行过程时，可在collect输出路径之后指定test/..._test.dart文件；省略文件时执行整个test目录。两种方式都会加载全部应用库，报告相同范围的源码数量；inventory.json记录实际测试文件。定向运行按所选测试范围记录结果，最终应用覆盖率按验收范围统一采集。

Android显式validationCoverage启用debug JVM／设备计数，报告要求同轮JVM exec和已导出设备ec：

```sh
./android/gradlew -p android -PvalidationCoverage=true \
  -PvalidationCoverageDirectory='<设备覆盖数据绝对目录>' \
  :app:validationDebugCoverageReport
```

JNI再显式validationNativeCoverage启用Clang source coverage、atomic与MC/DC，使用配套未剥离库和profraw处理。采集范围、统计总量和工具语义及正常release排除检查见[覆盖率方法](verification.md#覆盖率)。
