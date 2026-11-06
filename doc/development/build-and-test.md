# 构建、自动化测试与验证工具

命令示例在项目根目录执行。项目工具统一通过 `python3 -I -B tool/main.py` 调用；从其他目录执行时，使用 `main.py` 的绝对路径。先按任务选择入口：

| 任务 | 入口 | 主要输出 |
| --- | --- | --- |
| 日常修改检查 | 下文“自动化测试” | 分语言退出码与测试结果 |
| 更新依赖或应用版本 | `main.py dependencies check`／`apply` | 限定输入、锁文件、许可及 JSON 报告 |
| 验证依赖候选 | `main.py dependencies validate` | Python／Contract／Flutter／Go 测试日志 |
| 手动分发 | “Android 分发与 GitHub Actions” | 四个 release APK、对应源码、许可及 SHA256SUMS |
| Android lifecycle／JNI | “Android测试变体” | 配套主包、test APK和逐项JUnit结果 |
| 系统界面操作 | “SDK观察器” | SDK节点／动作回执及process identity |
| 网络集成 | “受控网络服务” | 动态端口、请求记录和关闭回执 |
| 产物、备份和覆盖率核验 | 文末各工具入口 | 核验报告、原字节比较或覆盖率数据 |

行为断言见[验证方法](verification.md)，执行职责见[应用架构](../architecture/overview.md)。路径占位符替换为本次工具链及输入的绝对路径。顶层、命令组和具体操作均支持 `-h`／`--help`；省略命令显示帮助并成功退出。查看帮助只需 Python，不启动 Go、Flutter 或网络请求。

```sh
python3 -I -B tool/main.py --help
python3 -I -B tool/main.py dependencies --help
python3 -I -B tool/main.py android build-core --help
```

## 工具链与构建

Flutter／Dart要求由[pubspec.yaml](../../pubspec.yaml)及[锁文件](../../pubspec.lock)确定，Android编译配置见[Gradle](../../android/app/build.gradle.kts)，Go版本和内核依赖见[go.mod](../../native/mihomo/go.mod)。[原生构建实现](../../tool/android/build_core.py)使用 Linux x86_64 宿主和项目选定的 NDK／Go，通过 `main.py android build-core` 构建原生库。

构建前使 `ANDROID_HOME`／`ANDROID_SDK_ROOT` 与 `android/local.properties` 中的 `sdk.dir` 指向同一实际SDK；如同时设置两个环境变量，也应保持一致。Gradle从解析出的SDK目录取得NDK，产物核验工具从SDK环境取得Build Tools。`local.properties` 只记录本机位置，不纳入对应源码。

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
# release要求可用签名，来源与失败规则见下文。
flutter build apk --release --no-pub --target-platform android-arm,android-arm64,android-x64
```

Gradle 按 `abiFilters` 和原生任务输入生成 `libmihomo_bridge.so`，生产 tags 为 `cmfa,with_gvisor`，最低 API 为 24，链接使用 16 KiB 对齐。JNI 入口及保护 callback 由 Keep 保留。原生库先在对应 ABI 的 staging 目录完成构建，再替换输出；失败时保留该 ABI 的旧库。单独构建使用：

```sh
python3 -I -B tool/main.py android build-core \
  --ndk '<NDK目录>' --api 24 --output /var/tmp/native-libs \
  --abis armeabi-v7a,arm64-v8a,x86_64
```

普通分发使用正常 release 配置；覆盖率采集另启 `validationCoverage` 或 `validationNativeCoverage` 测试变体。

## 依赖更新与应用版本

`dependencies check` 与 `dependencies apply` 共用候选解析。默认 `--scope all` 检查 mihomo、其他直接 Go 依赖、hosted Pub、Maven 和 CA／Geo；CA 或其他依赖单独变化也会生成候选。`check` 输出差异，不写回项目输入；`apply` 在临时副本中完成解析及许可收集后，事务写回声明、锁文件、通知和固定资源记录。

```sh
python3 -I -B tool/main.py dependencies check
python3 -I -B tool/main.py dependencies apply --report /var/tmp/dependency-report.json
# 同一候选保留已经确定的应用版本。
python3 -I -B tool/main.py dependencies apply --reuse-version
# 只调整内核，其他生态和固定资源保持原选择。
python3 -I -B tool/main.py dependencies apply \
  --scope mihomo --mihomo-version '<目标selector>' --reuse-version
```

显式 `--mihomo-version` 需要 `--scope mihomo`；tag、commit、branch 或 `latest` 原样交给 Go，报告 `go list -m` 的实际选择。内核求解必需的传递依赖及关联许可随之更新。无真实变化返回 `unchanged` 和空文件列表，不递增应用版本；解析或下载失败返回非零退出码及原始错误。

Go、Flutter、JDK、SDK、NDK、Gradle、AGP 和 Kotlin 使用项目固定声明及下载记录，不参与日常自动更新。Flutter 使用随附 Dart，Go 使用 `GOTOOLCHAIN=local`。新依赖与固定工具链不兼容时保留 Go／Pub／Gradle 的原始错误；工具链升级单独进行。本地 re_editor 保持 path 来源，protobuf replace 及许可材料按实际模块图复核，见[许可升级规范](../legal/dependencies.md#内核与依赖升级复核)。

[release 输入记录](../../third_party/data/resources.json)保存五项资源的来源、版本／commit、大小、SHA-256、可编辑来源身份、许可、工具链与依赖解析决定。本机安装位置另写环境报告，不进入对应源码。普通构建、测试和同一候选的验证只消费固定输入，不查询 latest；缺少 payload 时按固定 URL 下载并核对摘要，不刷新 release 记录。

### 固定输入与 generated assets

先准备记录中的工具链，再生成资源，最后开始 Flutter／Gradle 构建。工具链准备入口不会查询最新版本：

```sh
python3 -I -B tool/main.py dependencies prepare-toolchains \
  --environment /path/to/toolchain-environment.json
python3 -I -B tool/main.py dependencies prepare-build
# 已有 payload 的离线准备。
python3 -I -B tool/main.py dependencies prepare-build --offline
```

环境报告中的 `environment` 对象提供 `JAVA_HOME`、`ANDROID_HOME`、`ANDROID_SDK_ROOT`、`PATH`、`GOTOOLCHAIN` 和 `CLASH_GRADLE`。后续命令使用这些实际路径；Gradle 可直接执行 `CLASH_GRADLE` 指向的固定可执行文件。准备入口同时写入本机 `android/local.properties`，不把其路径作为分发输入。

五项 payload、资源 manifest、BundledAssetContract 和法律资产输出至 `build/generated/bundled/`，Gradle 将其中 assets 与 Kotlin source 注册为生成输入。源码目录不保存 payload，也不以旧源码 manifest 作为 fallback。应用内许可、APK 核验和对应源码打包使用同一资源记录。离线重建对应源码包时，可通过 `--payload-directory` 指向包内 `build-inputs/bundled/assets/`。

### 本地隔离回退

在独立源码副本中保存基线的声明、锁文件和资源记录，再从副本根目录执行下列命令。`--reuse-version` 保留应用版本，`scope=mihomo` 只改变内核及 Go 求解必需输入：

```sh
python3 -I -B tool/main.py dependencies apply \
  --scope mihomo --mihomo-version '<目标selector>' --reuse-version
GOTOOLCHAIN=local go -C native/mihomo list -mod=readonly -m github.com/metacubex/mihomo
GOTOOLCHAIN=local go -C native/mihomo test -mod=readonly -tags=cmfa,with_gvisor ./... -count=1
GOTOOLCHAIN=local go -C native/mihomo vet -mod=readonly -tags=cmfa,with_gvisor ./...
flutter build apk --debug --no-pub --target-platform android-arm,android-arm64,android-x64
```

记录实际 Go 选择、测试退出码及 debug APK 的三 ABI 生产 native 库。随后通过同一更新入口选择基线 selector，比较非 Go 输入保持不变，再运行对应测试与构建。本地使用调试签名；正式分发签名和四个 release APK 的结果另从 Actions 记录。

### 应用版本

[pubspec.yaml](../../pubspec.yaml)是应用版本的唯一声明。更新器先准备依赖与资源候选，有实际变化时将 patch 和 Android versionCode 各加一，一次更新多项依赖也只递增一次。例如 `1.0.0+1` 的候选使用 `1.0.1+2`。无变化、同一候选再次 apply 和普通构建均不递增。

CI 每次从默认分支基准准备候选，同一基准重跑得到相同版本；成功发布后，后续实际更新从默认分支的新版本继续递增。本地隔离回退实验使用 `--reuse-version` 保留应用版本，自动发布不使用该选项。

应用版本与 GitHub 发布类型独立：`pre-release`／`release` 来自 workflow 配置，不从 `0.x`、版本后缀或 mihomo selector 推断。两种发布类型均使用正式签名的 release APK；选择正式 release 不额外提升 major 或 patch。

### 独立产物核验输入

`dependencies apply --evidence '<新目录>'`从实际 Go 模块解析、Android releaseRuntimeClasspath 及独立的 Flutter release bundle 构建生成 go-modules.json、android-dependencies.txt 和 decoded NOTICES。输入目录在命令前保持不存在，Flutter SDK 的正常生成文件仍使用构建输出目录。产物核验将这些输入与待检 APK 比较，调用见[许可核验工具](#备份与许可核验工具)。

## Android 分发与 GitHub Actions

每次发布提供四个正常 release APK，应用身份为 `io.github.monadboxlab.clashpseudo`。四包共享 pubspec.yaml 中的 versionName、versionCode、mihomo 版本和分发签名。构建配置通过 Flutter 的 `force-version-code-ignoring-abi` 开关保持分架构包的 versionCode；架构包数量与构建重试保持该次已确定版本。

| 文件名，其中版本为 x.y.z+N | 适用范围 |
| --- | --- |
| clash-pseudo-x.y.z+N-universal.apk | **Android 通用版（推荐）**，包含 armeabi-v7a、arm64-v8a、x86_64，下载体积较大 |
| clash-pseudo-x.y.z+N-arm64-v8a.apk | 运行 64 位 Android 的大多数现代手机和平板 |
| clash-pseudo-x.y.z+N-armeabi-v7a.apk | 使用 32 位 Android 系统的设备 |
| clash-pseudo-x.y.z+N-x86_64.apk | 相应设备和模拟器 |

本地已通过环境提供分发签名时，使用一次 split 构建生成四包：

```sh
flutter build apk --release --no-pub --target-platform android-arm,android-arm64,android-x64 --split-per-abi
python3 -I -B tool/main.py artifacts package-sources --evidence '<核验输入目录>' \
  --resource-sources '<固定资源可编辑来源清单>' --output '<版本对应源码.tar.gz>'
```

应用 Gradle 的 `splits.abi.isUniversalApk=true` 在同轮 split 构建中增加通用包。构建工具按 AGP 输出元数据定位四个 APK，再使用上表文件名保存；逐包检查 ABI、生产 buildinfo、16 KiB 对齐、Android 签名及法律资产。无分发签名的本地集成测试使用 debug variant，不执行本段 release 构建。

四包共享覆盖实际源码和依赖的 sources.tar.gz 与 licenses.tar.gz。SHA256SUMS 包含全部四个 APK、对应源码包及许可包。对应源码入口默认读取当前工作树的正式输入，包含必要的未忽略新增文件，按当前删除状态处理已删除文件；`build-inputs/source-tree.json` 记录 workingTree、dirty、基准提交及逐文件字节数／SHA-256／可执行位，归档期间复核源码稳定。`--commit '<提交>'`适用于与该提交一致的干净源码。固定资源可编辑来源清单默认取核验输入目录中的 `resource-sources.json`，也可由上述参数指定；材料要求见[许可升级规范](../legal/dependencies.md)。SDK 本机位置、签名材料和设备备份保持在源码包之外，公开合成测试证书与私钥随测试保留。

### 自动更新与发布

[Update and release](../../.github/workflows/dependency-updates.yml) 每天 UTC 05:17（北京时间 13:17）检查依赖和 bundled 资源，也支持手动运行。有更新时构建并直接发布，不创建依赖 PR。

| 阶段 | 执行内容与结果 |
| --- | --- |
| 准备候选 | 从默认分支基准执行更新；有真实变化时 patch 和 versionCode 各加一，创建本轮候选提交 |
| 构建 | 仅在 release 构建步骤注入分发签名；一次 split 构建产出通用包和三个 ABI 包，检查签名、对齐、buildinfo 和法律资产 |
| 保存材料 | 保存候选 Git bundle、四 APK、对应源码、许可包、SHA256SUMS 及本轮发布类型，artifact 保留 7 天 |
| 发布 | 发布 job 从 bundle 导入同一候选提交，原子推送默认分支与 tag，建立草稿并上传全部资产，完成后公开 |

准备 job 使用 `contents: read`，发布 job 使用 `contents: write`。Action 固定到完整 release tag。候选提交、源码包、APK、tag 和 Release 的 Source 对应同一次输入；发布 job 不重新构建或重新提交候选。

workflow 通过统一入口的 `dependencies release context`、`commit`、`build`、`publish` 执行对应步骤。`dependencies validate` 供本地运行测试和静态检查，发布流程不调用该命令，也不读取其报告。具体参数通过各操作的 `--help` 查看。

在 `Actions → Update and release → Run workflow` 中选择本次发布类型：

- 两种类型都使用正式签名的 release APK。pre-release 不设为 Latest，release 设为 Latest。
- 日常无变化时不递增、不创建提交、tag 或 Release。手动以 `release` 运行且无更新时，如果当前提交已有完整 pre-release，则原地转为正式 release 并设为 Latest，APK 和版本不变；没有对应 pre-release 时报告无变化。定时运行不触发转换。

下载、解析或构建失败时查看对应步骤日志。发布 job 失败后使用 `Re-run failed jobs` 继续本次材料；已推送的 tag 指向本轮候选时继续上传，不把默认分支推回旧提交。基准已变化而 tag 尚未推送时重新运行整个 workflow；artifact 已过期时按错误报告处理缺失材料。

### 签名来源

release 与本地 debug 使用不同 keystore。pre-release／release 构建只读取以下四个环境变量，Actions 从同名 Secrets 注入；`android/key.properties` 只配置 debug：

- `CLASH_PSEUDO_ANDROID_KEYSTORE_BASE64`：分发 keystore 的 Base64 内容。
- `CLASH_PSEUDO_ANDROID_KEYSTORE_PASSWORD`：分发密钥库密码。
- `CLASH_PSEUDO_ANDROID_KEY_ALIAS`：分发密钥别名。
- `CLASH_PSEUDO_ANDROID_KEY_PASSWORD`：分发密钥密码。

四个环境变量必须同时完整提供，值保持原样；Base64 使用 Java 解码器。release 缺少分发签名时失败，即使存在本地调试 keystore 也不替代。`CLASH_REQUIRE_DISTRIBUTION_SIGNING=true` 是 Actions release 构建设置，不是第五个 Secret。分发签名仅注入 release 构建步骤。

本地 debug 读取 `android/key.properties` 的 `storeFile`、`storePassword`、`keyAlias`、`keyPassword`；不存在该文件时使用标准 debug 签名。Properties 按 UTF-8 读取，`storeFile` 相对该文件的父目录解析；debug 不使用环境中的分发密钥。修改本地调试签名后，安装包的签名随之改变，已有应用数据通过备份／恢复迁移。

环境 keystore 解码到临时文件，POSIX 权限为 0600，构建成功或失败均清理；解码字节在 finally 中清零。日志、构建 artifact 和对应源码不包含 keystore、密码或本机签名配置。

### Actions 启用与发布类型

1. 用户自行推送修改，在仓库 `Settings → Secrets and variables → Actions → Secrets` 确认已有四个同名分发签名 Secrets。
2. 确认发布 job 的 `GITHUB_TOKEN` 可写默认分支及 tag。分支或 tag 保护拒绝时，在失败步骤查看原始错误并按仓库规则处理。
3. 打开 `Actions → Update and release → Run workflow`，选择 `release_type`、`scope`，需要指定内核时填写 `mihomo_version` 并选择 `scope=mihomo`。
4. 在运行 Summary 查看变化、实际应用／内核版本、构建和发布结果；成功后到 `Releases` 下载四个 release APK、对应源码、许可包及 `SHA256SUMS`。
5. 暂停或恢复使用 workflow 页面菜单中的 `Disable workflow`／`Enable workflow`。

## 共同静态contract

[application contract](../../contracts/application.json)维护跨Dart、Kotlin、Go和JNI共同使用的容量、期限、归档字段及core IPC协议。[生成入口](../../tool/contracts/generate.py)生成各语言的编译期定义；各层检查实际收到的输入，运行身份和期限起点取自实际受理与执行。修改声明后生成，在构建及独立测试前检查一致性：

```sh
python3 -I -B tool/main.py contracts generate
python3 -I -B tool/main.py contracts check
```

原生构建入口检查静态 Contract 生成结果，`contracts check` 不依赖资源下载。Gradle 跟踪声明、工具模块、生成文件及影响原生编译的环境参数。Geo／CA 元数据由固定 release 记录和本次生成 manifest 单独生成至 `build/generated/bundled/`，沿用 `asset_metadata` 的校验；法律资产从同次来源与许可原文生成。APK 核验比较包内 payload、元数据及法律资产的实际字节。

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
python3 -I -B tool/main.py contracts check
flutter analyze
flutter test
GOTOOLCHAIN=local go -C native/mihomo test -mod=readonly -tags=cmfa,with_gvisor ./... -count=1
GOTOOLCHAIN=local go -C native/mihomo vet -mod=readonly -tags=cmfa,with_gvisor ./...
./android/gradlew -p android :app:assembleDebug :app:assembleDebugAndroidTest :app:testDebugUnitTest -Ptarget-platform=android-x64
python3 -I -B -m unittest discover -s test/tool -v
git diff --check
```

格式检查与Go并发诊断沿现有工具单独执行：

```sh
dart format --output=none --set-exit-if-changed lib test tool/coverage benchmark
GOTOOLCHAIN=local go -C native/mihomo test -mod=readonly -tags=cmfa,with_gvisor -race ./...
```

检查结果按入口记录：Flutter报告页面、业务及平台桥断言，Go报告生产tags下的接入调用，JVM／instrumentation报告Android机制，Python报告工具输入、失败和清理结果。失败时保留原输出、失败用例及所用输入；修改后重新执行对应入口。记录字段见[结果记录](verification.md#结果口径)。

### 表单到parsercontract

先运行Flutter表单测试，生成包含YAML正文的测试数据，再将同一JSON文件交Go Compose和公开parser。`OUT`设为项目外独立工作目录的绝对路径，两个命令共用该文件：

```sh
DEFINITION_FORMS_OUTPUT="$OUT/definition-forms.json" flutter test --no-pub \
  test/ui/overrides/forms/shared/definition_forms_test.dart
DEFINITION_FORMS_GENERATED="$OUT/definition-forms.json" GOTOOLCHAIN=local \
  go -C native/mihomo test -mod=readonly -tags cmfa,with_gvisor ./...
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
python3 -I -B tool/main.py android build-sdk-observer \
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
python3 -I -B tool/main.py android run-sdk-observer \
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

[network native-fixture](../../tool/network/native_fixture/__init__.py)用Python标准库提供合成HTTP、UDP、DNS UDP＋TCP及限定目标SOCKS。传入本机数值IPv4和nonce，动态端口由ready事件报告，DNS双协议共用实际端口：

```sh
python3 -I -B tool/main.py network native-fixture \
  --host '<本机IPv4地址>' --nonce controlled-check --seconds 60
python3 -I -B tool/main.py network native-fixture --self-test
```

nonce由8..48个小写字母、数字或连字符组成，服务运行1..300秒，最多接受10条连接。SOCKS只转发该服务的HTTP，DNS只为.fixture.test合成A记录；IPv6等场景另设测试服务。到期或终止后，关闭监听和已接受连接，等待请求与受理threadjoin；closed事件返回tasksJoined／remainingAccepted。

/config、/direct提供完整配置，/modes区分模式选路，/strategies提供成员与provider变化，/slow-config、/redirect、/update、/update-fails覆盖迟到、重定向、更新和失败。定义见[scenarios.py](../../tool/network/native_fixture/scenarios.py)，回归见[工具回归](../../test/tool)。

## 备份与许可核验工具

[verify_backup.py](../../tool/artifacts/verify_backup.py)流式检查manifest、固定三文件、实际大小／CRC／SHA及输入身份。比较三个业务文件原始字节，ZIP时间戳和压缩方式差异单独处理：

```sh
python3 -I -B tool/main.py artifacts verify-backup '<正式导出.zip>'
python3 -I -B tool/main.py artifacts verify-backup '<受保护原件.zip>' --compare '<重新导出.zip>'
```

[verify_release_licenses.py](../../tool/artifacts/verify_release_licenses.py)核查法律资产、独立来源的decoded NOTICES、各ABI的Go buildinfo、模块Version／Sum／Replace／tags，以及CA、Geo和PSL来源材料。预期输入通过[依赖入口](#独立产物核验输入)生成。`--xnet-source`使用`go-modules.json`实际选中的x/net模块原始zip；工具使用 Go 下载及模块校验结果，读取编译表修订、通知和可编辑 PSL 列表。

universal省略`--abi`时要求armeabi-v7a、arm64-v8a、x86_64三个架构；三个分架构包各指定对应的`--abi`。每个APK使用各自已存在的空输出目录。将`OUT`设为项目外本次工作目录的绝对路径，再创建四个报告目录并逐包核验：

```sh
EVIDENCE='<核验输入目录的绝对路径>'
XNET_SOURCE='<实际选中x/net模块的原始zip绝对路径>'
APK_DIR='<四个APK所在目录的绝对路径>'
VERSION='<x.y.z+N>'
mkdir "$OUT/license-universal" "$OUT/license-armeabi-v7a" \
  "$OUT/license-arm64-v8a" "$OUT/license-x86_64"

python3 -I -B tool/main.py artifacts verify-release-licenses \
  --project "$PWD" --apk "$APK_DIR/clash-pseudo-$VERSION-universal.apk" \
  --notices "$EVIDENCE/NOTICES" --go-modules "$EVIDENCE/go-modules.json" \
  --android-dependencies "$EVIDENCE/android-dependencies.txt" \
  --xnet-source "$XNET_SOURCE" --output-dir "$OUT/license-universal"

python3 -I -B tool/main.py artifacts verify-release-licenses \
  --project "$PWD" --apk "$APK_DIR/clash-pseudo-$VERSION-armeabi-v7a.apk" \
  --abi armeabi-v7a \
  --notices "$EVIDENCE/NOTICES" --go-modules "$EVIDENCE/go-modules.json" \
  --android-dependencies "$EVIDENCE/android-dependencies.txt" \
  --xnet-source "$XNET_SOURCE" --output-dir "$OUT/license-armeabi-v7a"

python3 -I -B tool/main.py artifacts verify-release-licenses \
  --project "$PWD" --apk "$APK_DIR/clash-pseudo-$VERSION-arm64-v8a.apk" \
  --abi arm64-v8a \
  --notices "$EVIDENCE/NOTICES" --go-modules "$EVIDENCE/go-modules.json" \
  --android-dependencies "$EVIDENCE/android-dependencies.txt" \
  --xnet-source "$XNET_SOURCE" --output-dir "$OUT/license-arm64-v8a"

python3 -I -B tool/main.py artifacts verify-release-licenses \
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
python3 -I -B tool/main.py coverage flutter collect "$OUT/coverage-run"
python3 -I -B tool/main.py coverage summary "$OUT/coverage-run/application.info"
```

检查采集工具的完整执行过程时，可在collect输出路径之后指定test/..._test.dart文件；省略文件时执行整个test目录。两种方式都会加载全部应用库，报告相同范围的源码数量；inventory.json记录实际测试文件。定向运行按所选测试范围记录结果，最终应用覆盖率按验收范围统一采集。

Android显式validationCoverage启用debug JVM／设备计数，报告要求同轮JVM exec和已导出设备ec：

```sh
./android/gradlew -p android -PvalidationCoverage=true \
  -PvalidationCoverageDirectory='<设备覆盖数据绝对目录>' \
  :app:validationDebugCoverageReport
```

JNI再显式validationNativeCoverage启用Clang source coverage、atomic与MC/DC，使用配套未剥离库和profraw处理。采集范围、统计总量和工具语义及正常release排除检查见[覆盖率方法](verification.md#覆盖率)。
