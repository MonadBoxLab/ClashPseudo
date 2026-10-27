# 构建、自动化测试与验证工具

本文提供维护者可重复使用的构建和测试入口。行为与接口判据见[验证与覆盖率](verification.md)，业务和平台职责见[应用架构](../architecture/overview.md)。命令在项目根目录执行，参数中的输入路径按实际工具链与测试材料提供。

## 工具链与构建

Flutter／Dart要求由[pubspec.yaml](../../pubspec.yaml)及[锁文件](../../pubspec.lock)确定，Android编译配置见[Gradle](../../android/app/build.gradle.kts)，Go版本和内核依赖见[go.mod](../../native/mihomo/go.mod)。原生[Bash入口](../../tool/android/build_core.sh)使用Linux x86_64构建宿主和项目选定的NDK／Go生成原生库。

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build apk --release
```

Gradle按abiFilters及原生任务输入生成libmihomo_bridge.so，生产标签为cmfa,with_gvisor。JNI入口与保护回调由Keep声明保留；版本、ABI和编译选项采用实际构建输入。

## 依赖更新与应用版本

[依赖入口](../../tool/dependencies/update.py)默认检查 mihomo 的最新正式 GitHub Release。`--check` 查询可用版本，保持工作树文件原状；`--apply` 在系统临时副本中解析并更新依赖及法律材料，完成后写回限定输入，保留其他已有改动与 Git 索引。命令失败时报告具体原因。Go 使用现有本机工具链，Pub 使用当前 Flutter SDK，Android 库保持现有 Gradle／AGP／SDK 配置。

```sh
python3 -I tool/dependencies/update.py --check
python3 -I tool/dependencies/update.py --apply
python3 -I tool/dependencies/update.py --apply --mihomo-tag v1.19.33
python3 -I tool/dependencies/update.py --check --pub yaml --pub yaml_edit
python3 -I tool/dependencies/update.py --apply --go-module github.com/miekg/dns
python3 -I tool/dependencies/update.py --apply --android androidx.work:work-runtime
```

显式选择 Go、hosted 直接包或 Android 库时更新所选范围及必要传递依赖；SDK 包和本地 re_editor 保持原来源。Go 的 protobuf replace 与许可依赖要求由现有 go.mod 承接，变化材料按[许可升级规范](../legal/dependencies.md#内核与依赖升级复核)自动收集。工具使用的固定版本 Google licenseclassifier 通过 Go 模块运行，属于维护工具，应用模块的依赖图保持独立。

### 应用版本

[pubspec.yaml](../../pubspec.yaml)是应用版本的唯一来源，采用 x.y.z+N，独立于内核版本。正式稳定发布前使用 **0.y.z 开发版本**：功能新增或不兼容调整递增 y 并将 z 归零，缺陷、安全及常规依赖维护递增 z。开发阶段不承诺稳定兼容性，自动更新不会跨入 1.x。

首次稳定发布须由用户明确决定，通过 `--bump stable` 将 0.y.z 提升为 **1.0.0**；不沿用开发阶段的 y。稳定期按一次完整交付的变化确定增量：

- **x，主版本**：需要用户调整或处理的不兼容变化，例如配置／备份格式的不兼容变化、重要能力移除或核心使用流程变化。递增 x 后，y、z 归零。
- **y，次版本**：向后兼容的应用功能新增。递增 y 后，z 归零。
- **z，补丁版本**：保持既有使用契约的维护更新，包括缺陷修复、安全更新、性能改善及常规依赖升级。

常规 mihomo 正式版更新默认递增 z；同次发布的内核升级次数不单独叠加应用版本。版本在构建前确定，不由每次 commit、测试、覆盖采集或内部里程碑递增。Flutter 的 x.y.z+N 中，x.y.z 对应 Android versionName，N 对应 versionCode；每个新的 Android 分发版本递增 N，同次发布的失败重试、续跑与缺失资产补齐复用已经确定的版本。即使订正显示版本阶段，N 也不回退；当前开发版本 0.1.0+3 的 N 高于历史本地试用产物 1.1.0+2，旧产物及材料保持原版本与字节。

```sh
# 开发期功能新增／不兼容调整，或稳定期兼容功能新增。
python3 -I tool/dependencies/update.py --apply --bump minor
# 仅在用户明确决定首次稳定发布时执行；不自动触发。
python3 -I tool/dependencies/update.py --apply --version-only --bump stable
# 稳定期不兼容变化使用 major；开发期 major 会拒绝，不能隐式转为稳定版。
python3 -I tool/dependencies/update.py --apply --version-only --bump major
# 同一次尚未分发的发布中补充依赖更新，沿用已经确定的应用版本。
python3 -I tool/dependencies/update.py --apply --reuse-version
```

源码、Git tag、APK 和对应源码包使用同一版本。无依赖更新时，普通 `--apply` 保持应用版本；单独的应用发布使用 `--version-only`。`--reuse-version`用于同一次待发布交付，新的分发版本通过正常增量准备。GitHub Actions 的常规内核更新使用默认 patch 策略，发布状态与已有 tag 用于识别续跑；0.y.z 的 GitHub Release 始终标记为 prerelease，首次稳定提升只接受明确的手动选择。APK 的 release 构建模式仅表示构建性质，不表示应用已进入稳定发布阶段。

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

本地构建复用 Flutter、Gradle 和原生入口，通用构建与分架构构建各执行一次，相关功能检查按同一份源码执行。分架构输出位于 build/app/outputs/flutter-apk/app-ABI-release.apk，通用输出为 app-release.apk。各包按实际目标 ABI 检查原生库、buildinfo、生产 tags、16KiB 对齐、版本、签名和法律材料。

```sh
flutter build apk --release --no-pub --target-platform android-arm,android-arm64,android-x64
flutter build apk --release --no-pub --target-platform android-arm,android-arm64,android-x64 --split-per-abi
python3 -I tool/artifacts/package_sources.py --evidence '<核验输入目录>' \
  --output '<版本对应源码.tar.gz>'
```

四包共享覆盖实际源码和依赖的 sources.tar.gz 与 licenses.tar.gz。SHA256SUMS 包含全部四个 APK、对应源码包及许可包。对应源码入口默认包含当前工作树中的正式输入；`--commit '<提交>'`用于与已核验提交一致的固定源码。SDK 本机位置与签名材料保持在源码包之外。

[自动工作流](../../.github/workflows/update-dependencies.yml)每日检查 mihomo 正式 Release，也接受手动触发。新内核维护发布默认递增 patch；手动触发可选择完整交付所需的 minor、稳定期 major，或明确选择 stable 准备首次 1.0.0 稳定发布；定时任务不能执行 stable 提升。publish_current 用于准备一次独立应用发布。pubspec.yaml 已准备新版本时复用该版本；首次稳定选择必须实际提升开发版本，不能被未建 tag 的版本复用逻辑跳过。已有未完成发布按原 tag 与开发／稳定性质续跑，保留已成功资产，按校验文件或原始 Actions 归档恢复缺失材料，完成核验后补齐远程资产。

GitHub Release 的创建、资产上传与正式发布统一由该 GitHub Actions 工作流执行。[CI 准备入口](../../tool/dependencies/release.py)生成已核验发布输入，并在独立 CI 工作区中提交限定变更及原子推送应用 tag 与源码；[Actions 发布步骤](../../.github/scripts/publish-release.cjs)核对远程 tag、版本归属和全部资产摘要，先建立 draft，资产完整后正式发布。本地使用依赖更新、正常构建、核验和源码打包入口。

启用时先确认远程默认分支及 GITHUB_TOKEN 的正常提交／tag 推送策略，为仓库配置以下 Secrets：

- `ANDROID_KEYSTORE_BASE64`：用户控制的固定 Android 分发密钥文件的 Base64 内容。
- `ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`：对应密钥信息。

按确定的首次公开发布时点将仓库变量 `AUTOMATIC_RELEASES_ENABLED` 设为 `true`。工作流在仓库外临时位置恢复密钥，要求完整签名配置，并在结束后删除自有临时密钥。job 使用 contents: write 和 actions: read，保持同仓库发布串行执行。已有调试签名安装与固定分发签名之间的数据衔接通过应用备份／恢复处理。

本地使用固定签名时向 Gradle 提供 `CLASH_SIGNING_STORE_FILE`、`CLASH_SIGNING_STORE_PASSWORD`、`CLASH_SIGNING_KEY_ALIAS`、`CLASH_SIGNING_KEY_PASSWORD` 环境变量。`CLASH_REQUIRE_DISTRIBUTION_SIGNING=true`要求固定分发签名；普通本地试用构建沿既有开发签名。密钥与密码由用户控制，CI 日志、构建归档和对应源码只保留公开证书摘要与正常分发材料。

## 共同静态契约

[应用契约](../../contracts/application.json)按领域维护跨Dart、Kotlin、Go和JNI共同使用的容量、期限及归档字段。[生成入口](../../tool/contracts/generate.py)生成编译期定义；各层分别校验自己的实际输入，运行身份和期限起点由实际受理与执行提供。修改声明后生成，提交前或独立测试前检查一致性：

```sh
python3 -I tool/contracts/generate.py
python3 -I tool/contracts/generate.py --check
```

原生构建入口自动检查生成结果；Gradle同时跟踪声明、生成器及可改变原生编译结果的环境参数。Geo安装元数据来自现有资产manifest，CA名称、大小与摘要来自[CA来源清单](../../third_party/data/certificates/manifest.json)，同一入口生成Android编译期定义。Geo法律资产由Gradle从third_party中的权威原文复制到构建输出，产物核验比较实际包内字节与来源。界面展示测试使用显式场景输入，真实版本及链接一致性沿产物核验。

## 自动化测试

```sh
dart format --output=none --set-exit-if-changed lib test tool/coverage benchmark
GOTOOLCHAIN=local go -C native/mihomo test -tags cmfa,with_gvisor ./...
GOTOOLCHAIN=local go -C native/mihomo vet -tags cmfa,with_gvisor ./...
GOTOOLCHAIN=local go -C native/mihomo test -tags cmfa,with_gvisor -race ./...
./android/gradlew -p android :app:testDebugUnitTest
python3 -I -B -m unittest discover -s test/tool -v
```

Flutter覆盖页面、业务和平台桥契约，Go使用生产标签覆盖衔接与公开内核调用，JVM／instrumentation处理Android机制，Python覆盖工具输入、失败和真实收尾。上游已知失败按[内核边界](../architecture/core-integration.md#公开能力边界)解释，测试结果保留各自范围。

### 表单到parser契约

Flutter真实GUI生成YAML，再交Go Compose及公开parser验证。OUT为项目外系统临时目录中独立工作目录的绝对路径，新输出目录由对应工具创建。

```sh
DEFINITION_FORMS_OUTPUT="$OUT/definition-forms.json" flutter test --no-pub \
  test/features/overrides/definition_forms_test.dart
DEFINITION_FORMS_GENERATED="$OUT/definition-forms.json" GOTOOLCHAIN=local \
  go -C native/mihomo test -tags cmfa,with_gvisor ./...
```

[定义契约](../../native/mihomo/internal/engine/definition_forms_contract_test.go)检查组、provider和规则保存输入经两种Compose后解析；[节点契约](../../native/mihomo/internal/engine/proxy_form_contract_test.go)分别覆盖24种GUI新建和28种原始type。构造、解析与协议实网结果分别记录。

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
  -e class io.github.monadboxlab.clashpseudo.nativecore.NativeCoreFailureTest \
  io.github.monadboxlab.clashpseudo.test/androidx.test.runner.AndroidJUnitRunner
```

SERIAL显式指定目标，nonce、配置ID／revision／epoch、独立期望摘要及屏障参数由所选测试声明。runner报告与业务断言共同决定结果，UI进程和业务数据的恢复要求按测试实际副作用确定。

## SDK观察器

[SystemEntryInstrumentation](../../android/app/src/androidTest/java/io/github/monadboxlab/clashpseudo/validation/SystemEntryInstrumentation.java)使用API24起的公开SDK，在自己的test包进程读取公开窗口和执行指定动作，采用self-target；它与主应用target的AndroidJUnitRunner是不同运行关系。

[构建器](../../tool/android/build_sdk_observer.py)接受明确工具链，依次执行javac、d8、aapt2、zipalign、apksigner，记录源码／APK摘要、manifest与命令退出码：

```sh
python3 -I tool/android/build_sdk_observer.py \
  --android-jar '<Android平台android.jar>' \
  --build-tools '<Build Tools目录>' \
  --java-release '<项目Java编译目标>' \
  --min-api '<min API>' --target-sdk '<target SDK>' \
  --debug-keystore '<标准debug.keystore>' \
  --output "$OUT/sdk-observer-build"
```

[运行器](../../tool/android/run_sdk_observer.py)核查self-target元数据、安装test APK摘要及API／ABI，并记录动作前后的主进程PID／startTicks与SDK配置回执，输出到仓库外系统临时目录的新路径。配置与进程变化作为当次事实保留，业务结论和测量身份按所属场景判断。serial为目标，allowed-serial为接受列表，可重复提供。

```sh
python3 -I tool/android/run_sdk_observer.py \
  --serial '<目标serial>' --allowed-serial '<允许的目标serial>' \
  --action snapshot --apk-sha256 '<test APK SHA-256>' \
  --window-package io.github.monadboxlab.clashpseudo \
  --label '<精确预期标签>' --output "$OUT/sdk-observation"
```

snapshot读取精确标签，click定位唯一对象并提交一次，start／stop需要预期配置名。通知与UI动作由allow-ui-action启用。运行器记录节点命中、动作受理及SDK回执，业务状态与资源退出由相应测试核对；超时或取消保留unconfirmed及已有回执，产物身份检查在动作前完成。

## 受控网络服务

[native_fixture.py](../../tool/network/native_fixture.py)用Python标准库提供合成HTTP、UDP、DNS UDP＋TCP及限定目标SOCKS。传入本机数值IPv4和nonce，动态端口由ready事件报告，DNS双协议共用实际端口：

```sh
python3 -I tool/network/native_fixture.py \
  --host '<本机IPv4地址>' --nonce controlled-check --seconds 60
python3 -I tool/network/native_fixture.py --self-test
```

nonce为8..48个小写字母、数字或连字符，服务生命周期1..300秒，最多10条accepted连接。SOCKS只转发自身HTTP，DNS仅合成.fixture.test的A；IPv6等其他场景另配相应测试端。到期或终止后关闭监听与accepted sockets，等待请求及受理线程join，closed事件给tasksJoined／remainingAccepted。

/config、/direct提供完整配置，/modes区分模式选路，/strategies提供成员与provider变化，/slow-config、/redirect、/update、/update-fails覆盖迟到、重定向、更新和失败。定义见[scenarios.py](../../tool/network/native_fixture/scenarios.py)，回归见[工具回归](../../test/tool)。

## 备份与许可核验工具

[verify_backup.py](../../tool/artifacts/verify_backup.py)流式检查manifest、固定三文件、实际大小／CRC／SHA及输入身份。比较三个业务文件原始字节，ZIP时间戳和压缩方式差异单独处理：

```sh
python3 -I tool/artifacts/verify_backup.py '<正式导出.zip>'
python3 -I tool/artifacts/verify_backup.py '<受保护原件.zip>' --compare '<重新导出.zip>'
```

[verify_release_licenses.py](../../tool/artifacts/verify_release_licenses.py)核查法律资产、独立来源的 decoded NOTICES、项目配置 ABI 的 Go buildinfo、模块 Version／Sum／Replace／tags、固定 CA／Geo／PSL 及对应材料。预期输入通过[依赖入口](#独立产物核验输入)生成，核验输出参数为已存在的空目录：

```sh
python3 -I tool/artifacts/verify_release_licenses.py \
  --project "$PWD" --apk '<release APK>' \
  --notices '<核验输入目录>/NOTICES' --go-modules '<核验输入目录>/go-modules.json' \
  --android-dependencies '<核验输入目录>/android-dependencies.txt' \
  --output-dir "$OUT/license-report"
```

工具检查产物与审核材料一致性，许可判断和分发义务分别见[许可依据](../legal/dependencies.md)与[NOTICE](../../NOTICE.md)。

## 覆盖率入口

Dart使用[采集工具](../../tool/coverage/flutter.dart)的collect入口；输出位于仓库外系统临时目录，父目录已存在，目标为新绝对路径。全库loader及根hook执行副本由工具置于独立系统临时目录，退出时清理：

```sh
dart run tool/coverage/flutter.dart collect "$OUT/coverage-run"
dart run tool/coverage/summary.dart "$OUT/coverage-run/application.info"
```

定向检查采集工具自身的完整链时，collect可在输出路径之后接收显式的test/..._test.dart文件；省略时执行完整test目录。两种方式均加载全部应用库并报告相同源码分母，inventory.json记录实际测试输入。定向结果用于对应测试范围，最终应用覆盖按验收范围集中采集。

Android显式validationCoverage启用debug JVM／设备计数，报告要求同轮JVM exec和已导出设备ec：

```sh
./android/gradlew -p android -PvalidationCoverage=true \
  -PvalidationCoverageDirectory='<设备覆盖数据绝对目录>' \
  :app:validationDebugCoverageReport
```

JNI再显式validationNativeCoverage启用Clang source coverage、atomic与MC/DC，使用配套未剥离库和profraw处理。采集、分母、工具语义及正常release排除检查见[覆盖率方法](verification.md#覆盖率)。
