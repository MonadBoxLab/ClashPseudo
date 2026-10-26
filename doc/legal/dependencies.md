# 依赖许可依据与升级复核

本文保存依赖及数据资产的许可来源、已核查证据和升级复核方法。分发通知与对应源码义务见根[NOTICE](../../NOTICE.md)，法律原文保存在[third_party](../../third_party)及根[LICENSE](../../LICENSE)。

## 当前版本与材料入口

当前依赖选择以[native/mihomo/go.mod](../../native/mihomo/go.mod)、[go.sum](../../native/mihomo/go.sum)、[pubspec.yaml](../../pubspec.yaml)、[pubspec.lock](../../pubspec.lock)及[Android配置](../../android/app/build.gradle.kts)为准；实际解析图、原生buildinfo和APK内容用于确认参与构建与分发的材料。go.sum保存模块校验，实际链接版本由buildinfo核对。

mihomo持续同步上游。下列版本、提交和摘要标识各项已核查证据，供变化比较与复用；版本或依赖图变化时复核变化部分并更新证据。

自有代码为GPL-3.0-only，第三方保留各自版权和许可。Go通知、Android通知、Flutter NOTICES及字体／CA／Geo／PSL通知各覆盖自己的材料，源码原文与实际产物分别核验。

## go-lzo：明确GPL-2.0-or-later

go-lzo v0.0.0-20261012164727-ad21c35a1111的上游README明确声明GPL-2.0-or-later；与此前标注GPLv2的归档相比，该版本提供了明确的or-later授权依据，适用于本项目的GPLv3组合。原GPLv2正文和授权声明均随材料保留。

| 证据 | 固定值 |
| --- | --- |
| 提交 | [ad21c35a111113348567708a4db74f998be1a4c3](https://github.com/rasky/go-lzo/commit/ad21c35a111113348567708a4db74f998be1a4c3) |
| 直接父提交 | 96a758eda86e0ca29bc2638000fdb0ff0a6d96d8 |
| 新README SHA-256 | 9fa5f03995a7ce8ee795c89ddb39a16dd0f71ab6e393afd4637924c159a304d4 |
| 模块Sum | h1:TdWAEloUou4dmmeBono7DfE/PdfsoLn4+R4xTfIm7Bw= |
| GoModSum | h1:9leZcVcItj6m9/CfHY5Em/iBrCz7js8LcRQGTKEEv2M= |
| 模块zip SHA-256 | e306e0f265561d2a8ab8129312960e331b380d901ae1bca20b46771bfc6b54ee |

[固定README](https://github.com/rasky/go-lzo/blob/ad21c35a111113348567708a4db74f998be1a4c3/README.md)原文：

> Being a straightforward port of the original source code, it shares the same
> license (GPL-2.0-or-later) as I can't possibly claim any copyright on it.

[维护者回复](https://github.com/rasky/go-lzo/issues/15#issuecomment-6128639788)说明该授权澄清，[LZO项目](https://www.oberhumer.com/opensource/lzo/)提供GPLv2+来源。两版zip去除版本目录后，文件集合及源码一致，差异位于README。分发保留LICENSE.gpl及GPLv3正文，具体兼容关系按[GNU说明](https://www.gnu.org/licenses/gpl-faq.en.html#v2v3Compatibility)和对应授权条款确定。

## chacha：根MIT许可补齐

原核对归档github.com/metacubex/chacha v0.1.5的tag为07294f500ca8384015f6cc21311de7b6f093607d，已有chachapoly1305／poly1305子目录许可，缺根LICENSE。上游v0.1.6-0.20250812085457-7b981d42c3ba只新增根MIT LICENSE，其他原文件、源码及go.mod逐字节相同。

| 证据 | 固定值 |
| --- | --- |
| 提交 | [7b981d42c3baca5a004e7b0ecfb9b67ee20e583a](https://github.com/MetaCubeX/chacha/commit/7b981d42c3baca5a004e7b0ecfb9b67ee20e583a) |
| 根LICENSE SHA-256 | 3fac516804d269e044c071507def0677d614793776ac506e630337c63f1dcb77 |
| 模块Sum | h1:uYSI4GNiPPyKTPeQeVIm264uUfGDdWT9QsjUSXxXdTc= |
| GoModSum | h1:Djn9bPZxLTXbJFSeyo0/qzEzQI+gUSSzttuzZM75GH8= |
| 模块zip SHA-256 | d74619878b480cc8ce29e4c4d58d2e3c73ef75fa9a14ab09879574a292b4adc1 |

[固定原文](https://github.com/MetaCubeX/chacha/blob/7b981d42c3baca5a004e7b0ecfb9b67ee20e583a/LICENSE)保留Copyright (c) 2016 Andreas Auernhammer及Copyright (c) 2025 MetaCubex。伪版本按committer时间2025-08-12T08:54:57Z由Go proxy解析。根与子目录MIT原文均保留，许可可依[GNU说明](https://www.gnu.org/licenses/license-list.html#Expat)与GPLv3组合。

这两项许可材料变化通过应用模块显式间接要求选择，保留原replace与mihomo源码。2026-10-17核实的mihomo基线为v1.19.32、提交88dcbf7f1614a67c3b36b848ee3592dfa92ada36；当时完整模块图178→178，仅两版本变化。该快照供后续版本比较；产物另含版本相关buildinfo，需独立核查字节。

## AndroidX WorkManager及传递依赖

2026-10-18核对androidx.work:work-runtime:2.12.0，其[固定POM](https://dl.google.com/dl/android/maven2/androidx/work/work-runtime/2.12.0/work-runtime-2.12.0.pom)声明Apache-2.0，[版本资料](https://developer.android.com/jetpack/androidx/releases/work)中的minSdk24与接入要求相符。

该次releaseRuntimeClasspath新增或升级Room的common／common-jvm／runtime／runtime-android 2.7.0，SQLite及android／framework／framework-android 2.5.0，startup-runtime 1.1.1，tracing／tracing-ktx 1.2.0，concurrent-futures-ktx 1.1.0，lifecycle-service 2.7.0，collection／collection-jvm由1.1.0到1.4.2，annotation-experimental由1.4.0到1.4.1，协程由1.7.1到1.9.0。所核查POM均Apache-2.0。

对应坐标、POM、源码归档、SHA-256及许可原文见[Android通知](../../third_party/notices/android.txt)。原生WorkManager、Room和SQLite参与Android运行；R8处理后的分发内容由产物进一步确定。

## YAML编辑依赖与编辑器修改

2026-10-19核对锁文件及官方归档：

| 归档 | 许可／版权 | 归档SHA-256 | LICENSE SHA-256 |
| --- | --- | --- | --- |
| [yaml 3.1.4](https://pub.dev/api/archives/yaml-3.1.4.tar.gz) | MIT；2014 Dart project authors、2006 Kirill Simonov | f67cdd8e07d3c6329146aaef1ba043542b3134c12489f553ca9a7435d1068aea | d47b93335401b052d79a2f5a3710e4cf7b5aed782faedf84d40fbdd6eb934ec7 |
| [yaml_edit 2.2.4](https://pub.dev/api/archives/yaml_edit-2.2.4.tar.gz) | BSD-3-Clause；2020 Dart project authors | 07c9e63ba42519745182b88ca12264a7ba2484d8239958778dfe4d44fe760488 | 021c41b9b081664f6ee181aaf4e03602c51591204dabe9ac8c8d736f0965b851 |

yaml和yaml_edit通过hosted声明接入，应用使用公开API实现span／SourceEdit适配。版权及许可由Flutter构建流程合入NOTICES.Z，产物核对检查包名和原文。

所核查re_editor官方0.10.0源码位于[third_party/sources/re_editor](../../third_party/sources/re_editor)，包含生命周期、提交前准入／IME和默认关闭的测试观测修改。MIT原文、官方归档SHA、补丁及上游PR #118关系见[PATCHES](../../third_party/sources/re_editor/PATCHES.md)与[LICENSE](../../third_party/sources/re_editor/LICENSE)。原LICENSE SHA-256为5d37eaa3f35293d2141f08ffeb897040380eeb25016a5a17f71200a56bf44767，应用法律页显示原许可，修改说明随源码保留。后续版本具备等价能力时复核hosted替换及维护成本，保持单编辑系统；依赖使用批准规则归[开发规则](../../.claude/rules/development.md)。

## Dart覆盖率开发依赖

所核查coverage 1.16.0为hosted开发依赖，要求Dart ^3.9.0，供[采集工具](../../tool/coverage/flutter.dart)和测试配置调用公开API。固定[官方归档](https://pub.dev/api/archives/coverage-1.16.0.tar.gz)SHA-256为ff89e37c19355194e279d26dafe8e4bece46c9ea63a30be4dc68214f5bc290d3，BSD-3-Clause、Copyright 2014 the Dart project authors，LICENSE SHA-256为3c32b53167c7dae9190c38dab5dd9fe1789c53623ebc7d1babcb29914c5b3f16。

该解析闭包中的args、async、cli_config、cli_util、collection、ffi、file、glob、logging、meta、package_config、path、source_maps、source_span、stack_trace、string_scanner、term_glyph、vm_service保留各自Dart project authors的BSD-3-Clause原文、年份和免责声明；yaml为独立MIT。具体版本及官方归档校验由锁文件确定。开发依赖与最终包内容分别核验，若分发工具／依赖则保留对应原许可。

## Android覆盖率测试依赖

[Gradle测试开关](../../android/app/build.gradle.kts)所核查JaCoCo为0.8.14。agent／core／report／ant JAR保留Mountainminds GmbH & Co. KG的about.html、EPL-2.0；agent／ant随附ASM 9.9保留INRIA／France Telecom的BSD-3-Clause，report／ant的Google Code Prettify保留Mike Samuel et al的Apache-2.0。

[JaCoCo运行时归档](https://repo.maven.apache.org/maven2/org/jacoco/org.jacoco.agent/0.8.14/org.jacoco.agent-0.8.14-runtime.jar)SHA-256为3fb76eea65f81bd9415202bab34b6571728841dff1ab8e6bbe81adc2e299face。其余归档按Maven坐标、解析图及摘要核对。EPL组件继续适用其原始条款；分发测试APK、工具或报告时，核查所含代码的版权、许可及源码义务。

JNI source coverage使用所选NDK的compiler-rt profile runtime，只进入显式测试变体。正常release排除agent、插桩及profile runtime／sections，测试和报告口径见[覆盖率方法](../development/verification.md#覆盖率)。

## 公共数据资产

数据资产分别适用其来源许可；具体字节由版本、来源及校验值共同标识。更新内核或数据时，复核相应材料和分发义务。

- **CA**：curl官方cacert-2026-09-25.pem，Mozilla数据时间2026-09-25T03:12:01Z，MPL-2.0。[原始PEM](../../android/app/src/main/assets/certificates/cacert-2026-09-25.pem)为188900字节，完整文件SHA-256为a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505；头部摘要属于上游生成元数据。[来源通知](../../third_party/data/certificates/NOTICE.txt)与[MPL原文](../../third_party/data/certificates/MPL-2.0.txt)随包保留，MPL原文SHA-256为3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04。运行信任策略见[Android接入](../architecture/android.md#证书与平台限制)。
- **GeoIP.dat**：V2Fly geoip release 202610050438，源码fd96fbac6cffc06ab9a10d6ee8fad61afe9b771c，CC-BY-SA-4.0，保留DB-IP输入的CC-BY-4.0归属。
- **GeoSite.dat**：domain-list-community release 20261018123756，源码6b0f8edc935ee0ad2cb386ac3efd451ee2380ac5，MIT，Copyright (c) 2018-2019 V2Ray。
- **Country.mmdb／ASN.mmdb**：DB-IP Country Lite／ASN Lite 2026-10采用CC-BY-4.0，保留IP Geolocation by DB-IP归属。

四Geo的下载URL、原始／安装大小及SHA由[manifest](../../android/app/src/main/assets/geodata/manifest.json)记录；[数据说明](../../third_party/data/geodata/README.md)提供来源与处理关系，[NOTICE](../../third_party/data/geodata/NOTICE.txt)记录分发归属。DAT调整工作文件名，MMDB保持官方gzip并在安装时解压。数据、署名、修改说明及CC-BY-SA／MIT／CC-BY全文随分发提供；CC-BY-4.0文本取自SPDX license-list-data/v3.27.0。

x/net v0.35.0的publicsuffix/table.go记录PSL提交63cbc63d470d7b52c35266aa96c4c98c96ec499c（2023-08-03）。对应可编辑列表采用MPL-2.0，长度227027字节，SHA-256为4dd388d5006a37c0748f17e1088ecd05c821da88eff36963bcc36297d7dea96e；Go实现采用BSD。[PSL通知](../../third_party/notices/publicsuffix.txt)提供版本来源、许可头与源码取得方式，分发材料包含可编辑列表及MPL全文。

## 生产标签的链接审计快照

2026-10-19核对的开发原生库记录如下：Android arm64-v8a／x86_64，Go go1.27.1，cmfa,with_gvisor及x509usefallbackroots=1。两ABI有121个dep项，Version／Sum／protobuf替换一致；完整解析图178项含根。两库SHA-256为297f18dbdabd62af3f9201796b12c171e402b3e313e7e6c08e736e0990d5f967和36f2a4ccdcf4e65a10ba2931a1cdbc9a15e5ead931eb1ab9d6037f17c1a8f1c5。

该次链接核对涉及以下模块，其许可材料已纳入Go通知：

| 模块与审计版本 | 保留材料 |
| --- | --- |
| github.com/fxamacker/cbor/v2 v2.9.0 | MIT |
| github.com/golang/groupcache v0.0.0-20241129210726-2c02b8208cf8 | Apache-2.0 |
| github.com/google/pprof v0.0.0-20240727154555-813a5fbdbec8 | Apache-2.0、AUTHORS、svgpan BSD |
| github.com/metacubex/gvisor v0.0.0-20260922041103-e2cbcd6e7400 | LICENSE内Apache-2.0／MIT／BSD、AUTHORS |
| github.com/metacubex/jsonv2 v0.0.0-20260721082349-16b4998c8f89 | BSD-3-Clause、AUTHORS |
| github.com/metacubex/tailscale v0.0.0-20260821153257-ff0ecd818181 | BSD-3-Clause、PATENTS、tempfork goupnp／oauth2 |
| github.com/metacubex/tailscale-wireguard-go v0.0.0-20260725073821-e61ab99cede2 | MIT |
| github.com/pires/go-proxyproto v0.8.0 | Apache-2.0 |
| github.com/tailscale/peercred v0.0.0-20250107143737-35a0c7bd7edc | BSD-3-Clause、AUTHORS |
| github.com/x448/float16 v0.8.4 | MIT |
| go4.org/mem v0.0.0-20240501181205-ae6ca9944745 | Apache-2.0 |
| golang.org/x/term v0.29.0 | BSD-3-Clause、PATENTS |

[Go通知](../../third_party/notices/go.txt)保存版权、许可、NOTICE、AUTHORS／PATENTS以及模块zip／Sum／GoModSum等来源记录。实际链接集合由ABI对应的buildinfo确定；MIT、BSD、Apache-2.0和附加专利条款按各原文与GPLv3组合，PSL数据独立适用MPL。

[Android通知](../../third_party/notices/android.txt)记录所核对的55个Maven坐标、POM、源码归档及随附通知。kotlinx-coroutines-bom 1.9.0为POM元数据，listenablefuture 1.0的Apache-2.0声明来自guava-parent 26.0-android。2026-10-19对应Flutter引擎修订为deb287481e3ce9468f3434937ced4240a70539ca；当前版本以实际SDK和构建材料为准。Flutter／Dart通知与[Material Icons](../../third_party/notices/material-icons.txt)分别核对，所用字体归档采用CC BY 4.0并保留Google LLC署名和裁剪说明。

## 内核与依赖升级复核

1. 根据依赖声明、锁文件、解析图及replace确定当前版本与更新范围，按实际变化审查mihomo及其依赖。
2. 比较发生变化的模块、源码、数据及许可。必要版本要求继续通过显式约束维护，新归档的授权结论以其实际原文为依据。
3. 复用仍然适用的来源记录，核对变化归档及链接图；对许可、来源或replace变化，查阅具体上游声明与文件。
4. 同步Go／Dart／Gradle的版本声明、锁文件、通知及对应源码材料，同时核对应用显示版本与buildinfo。
5. 执行受影响的测试、vet及各目标ABI构建，逐项检查APK资产、NOTICES.Z、数据、依赖版本和对应源码。

解析与归档的常用命令：

```sh
GOTOOLCHAIN=local go -C native/mihomo list -m -mod=readonly all
GOTOOLCHAIN=local go -C native/mihomo mod download -json '<module@version>'
GOTOOLCHAIN=local go -C native/mihomo version -m '<libmihomo_bridge.so>'
```

解析图用于比较版本选择，download JSON提供Version／Sum／GoModSum／Zip／Dir。归档比较先去除module@version根目录，再按相对路径核对文件集合及字节，并计算许可原文和zip的SHA-256。

最终逐ABI比buildinfo和包内法律资产，decoded NOTICES取独立审核材料，实际数据及源码交付按[NOTICE](../../NOTICE.md#二进制分发与对应源码)和[产物方法](../development/verification.md#最终产物与许可)核对。
