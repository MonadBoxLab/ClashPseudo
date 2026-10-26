# 构建、自动化测试与验证工具

本文提供维护者可重复使用的构建和测试入口。行为与接口判据见[验证与测量](verification.md)，业务和平台职责见[应用架构](../architecture/overview.md)。命令在项目根目录执行，参数中的输入路径按实际工具链与测试材料提供。

## 工具链与构建

Flutter／Dart要求由[pubspec.yaml](../../pubspec.yaml)及[锁文件](../../pubspec.lock)确定，Android编译配置见[Gradle](../../android/app/build.gradle.kts)，Go版本和内核依赖见[go.mod](../../native/mihomo/go.mod)。原生[Bash入口](../../tool/android/build_core.sh)使用Linux x86_64构建宿主和项目选定的NDK／Go生成原生库。

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build apk --release
```

Gradle按abiFilters及原生任务输入生成libmihomo_bridge.so，生产标签为cmfa,with_gvisor。JNI入口与保护回调由Keep声明保留；版本、ABI和编译选项采用实际构建输入。

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

## 正文编辑测量包

[测量入口](../../tool/editor_observation.dart)调用正式应用入口和同名后台入口，复用[输入样本关联器](../../test/support/editor_input_samples.dart)，将已接受输入、实际文字绘制和同帧raster完成关联。通过显式构建开关启用，实验标识为8..48个小写字母、数字或连字符：

```sh
flutter build apk --release --target tool/editor_observation.dart \
  --dart-define=RE_EDITOR_OBSERVATION=true \
  --dart-define=EDITOR_INPUT_RUN=editor-validation \
  --dart-define=EDITOR_INPUT_NEGATIVE_CONTROL=true
```

负对照开关对本进程前五次已接受的正文变化各延迟150ms；后续输入沿原处理路径测量。日志前缀为EDITOR_INPUT_OBSERVATION，字段限于实验／进程、文档及输入身份、时间、修改范围、viewport、帧号和关联状态。进入后台时结算待关联样本并记录结束；负对照和正式样本分别统计。正常release采用默认应用入口，测量后恢复正常包，判据与采集顺序见[编辑器验证](verification.md#编辑器与输入性能)。

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

[verify_release_licenses.py](../../tool/artifacts/verify_release_licenses.py)核查法律资产、独立审核的decoded NOTICES、项目配置ABI的Go buildinfo、模块Version／Sum／Replace／tags、固定CA／Geo／PSL及对应材料，输出参数为已存在的空目录：

```sh
python3 -I tool/artifacts/verify_release_licenses.py \
  --project "$PWD" --apk '<release APK>' \
  --notices '<审核后的decoded NOTICES>' --go-modules '<Go模块图JSON>' \
  --android-dependencies '<releaseRuntimeClasspath报告>' \
  --output-dir "$OUT/license-report"
```

工具检查产物与审核材料一致性，许可判断和分发义务分别见[许可依据](../legal/dependencies.md)与[NOTICE](../../NOTICE.md)。

## 覆盖率入口

Dart使用[采集工具](../../tool/coverage/flutter.dart)先validate校准再collect；输出位于仓库外系统临时目录中，父目录已存在、目标为新绝对路径。校准复用正式测试输入，全库loader及根hook执行副本由工具置于独立系统临时目录，退出时清理：

```sh
dart run tool/coverage/flutter.dart validate "$OUT/coverage-validation"
dart run tool/coverage/flutter.dart collect "$OUT/coverage-run"
dart run tool/coverage/summary.dart "$OUT/coverage-run/application.info"
```

定向检查采集工具自身的完整链时，collect可在输出路径之后接收显式的test/..._test.dart文件；省略时执行完整test目录。两种方式均加载全部应用库并报告相同源码分母，inventory.json记录实际测试输入。定向结果用于对应测试范围，最终应用覆盖按验收范围集中采集。

Android显式validationCoverage启用debug JVM／设备计数，报告要求同轮JVM exec和已导出设备ec：

```sh
./android/gradlew -p android -PvalidationCoverage=true \
  -PvalidationCoverageDirectory='<设备覆盖数据绝对目录>' \
  :app:validationCoverageProbeReport
```

JNI再显式validationNativeCoverage启用Clang source coverage、atomic与MC/DC，使用配套未剥离库和profraw处理。采集、分母、工具语义及正常release排除检查见[覆盖率方法](verification.md#覆盖率)。
