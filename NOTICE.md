# 许可、第三方来源与分发

Clash Pseudo 自有代码采用 **GPL-3.0-only**，许可全文见 [LICENSE](LICENSE)。第三方代码、字体与数据分别适用其原始版权、许可及随附通知。

## 内核与依赖来源

核对源码或 APK 中的依赖时，使用以下输入：

| 内容 | 版本与来源记录 | 许可材料 |
| --- | --- | --- |
| mihomo 及 Go 模块 | [go.mod](native/mihomo/go.mod)、[go.sum](native/mihomo/go.sum)、各 ABI 原生库的 buildinfo | [mihomo GPL v3 原文](third_party/notices/mihomo.txt)、[Go 通知](third_party/notices/go.txt) |
| Flutter／Dart 包 | [pubspec.yaml](pubspec.yaml)、[pubspec.lock](pubspec.lock) | APK 中的 `assets/flutter_assets/NOTICES.Z` |
| Android 库 | Gradle 的 releaseRuntimeClasspath 解析结果 | [Android 通知](third_party/notices/android.txt)及归档内通知 |
| 公共 CA、Geo、PSL | release 资源记录、通知和模块修订 | 原始许可、随包生成的 CA／Geo 归属通知及 PSL 通知 |

Android 原生库通过 Go 模块链接 [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)。protobuf 替换关系随 go.mod 和 buildinfo 记录。依赖更新时的来源收集、许可处理及复核操作见[依赖许可依据](doc/legal/dependencies.md)。

## Flutter、Dart与编辑器

Flutter 构建将引擎、Dart 及所用包的版权和许可合并至 APK 的 `assets/flutter_assets/NOTICES.Z`，分发保留该文件。主要组件如下；逐包通知从锁定依赖的原始许可生成。

| 组件 | 许可 |
| --- | --- |
| flutter_svg、path_parsing、xml、petitparser | MIT |
| vector_graphics、vector_graphics_codec、vector_graphics_compiler | BSD-3-Clause |
| cross_file | BSD-3-Clause |
| re_editor、re_highlight、isolate_manager、isolate_contactor | MIT |
| yaml | MIT；Dart project authors／Kirill Simonov |
| yaml_edit | BSD-3-Clause；Dart project authors |

[re_editor 源码](third_party/sources/re_editor/)来自官方归档，保留其 [MIT 许可原文](third_party/sources/re_editor/LICENSE)。本地修改涉及lifecycle、编辑内容检查、IME 同步和测试接口，来源、修改范围及校验记录见 [PATCHES](third_party/sources/re_editor/PATCHES.md)。对应源码包包含这些修改和原始版权、许可。

## Android、图标与Go材料

[Android 通知](third_party/notices/android.txt)记录 Maven 坐标、POM、源码归档与 JAR／AAR 随附通知，覆盖 AndroidX、Kotlin／协程、JetBrains annotations、ReLinker、Guava ListenableFuture 及 JSpecify 等组件。发布核验将其与 releaseRuntimeClasspath 及 APK 中的法律资产比较。

所用 MaterialIcons-Regular.otf 归档采用 **CC BY 4.0**，版权为 Google LLC。[字体通知](third_party/notices/material-icons.txt)包含署名、完整许可、原始字体校验值及 Flutter release 裁剪说明。

[Go 通知](third_party/notices/go.txt)保留模块版本、许可、版权、NOTICE 及 AUTHORS／PATENTS 原文。原生库采用生产标签 `cmfa,with_gvisor`，各 ABI 的 buildinfo 记录链接模块。其中 go-lzo 归档采用 GPL-2.0-or-later，按 GPLv3 组合；chacha 归档提供根 MIT LICENSE 及相关版权。模块固定来源和校验记录见[许可依据](doc/legal/dependencies.md)。

## 公共CA、Geo与Public Suffix数据

| 数据 | 来源与归属 | 许可 |
| --- | --- | --- |
| 公共 CA PEM | curl 提供的 Mozilla CA Extract，版本与源文件见 [release 资源记录](third_party/data/resources.json) | [MPL-2.0](third_party/data/certificates/MPL-2.0.txt) |
| GeoIP.dat | V2Fly geoip 聚合数据，并保留 DB-IP 输入归属 | CC-BY-SA-4.0 及相应输入的 CC-BY-4.0 |
| GeoSite.dat | V2Fly domain-list-community，Copyright (c) 2018-2019 V2Ray | MIT |
| Country.mmdb／ASN.mmdb | DB-IP.com Country Lite／ASN Lite；IP Geolocation by DB-IP — https://db-ip.com/ | CC-BY-4.0 |
| Public Suffix List | PSL 项目，修订与可编辑来源见[通知](third_party/notices/publicsuffix.txt) | 数据采用 MPL-2.0，Go 实现采用 BSD |

数据文件与对应材料的核对位置：

- **CA**：使用原始 PEM snapshot。[release 资源记录](third_party/data/resources.json)保存来源、版本、存储／安装字节数及 SHA-256；APK 资产路径见同次生成的 `build/generated/bundled/certificates.json`。
- **Geo**：[数据说明](third_party/data/geodata/README.md)记录来源、工作文件名及压缩处理；同一 [release 资源记录](third_party/data/resources.json)保存原始字节与安装字节的映射。DAT 只改名；DB-IP 保留官方 gzip，安装时解压为 Country.mmdb／ASN.mmdb。两种形态分别核验大小和摘要。配套归属通知在构建时生成，与 [CC-BY-SA-4.0](third_party/data/geodata/CC-BY-SA-4.0.txt)、[MIT](third_party/data/geodata/GeoSite-MIT.txt)、[CC-BY-4.0](third_party/data/geodata/CC-BY-4.0.txt)全文一起随源码和应用提供。
- **PSL**：修订取自选中 x/net 模块的 publicsuffix/table.go。对应源码包含同一修订的[可编辑列表](third_party/data/publicsuffix/public_suffix_list.dat)和 x/net 实现，通知记录列表摘要。

数据分发保留各自要求的署名、固定来源、修改说明及相同方式共享材料。上述数据的许可和通知保持原始来源身份。

## 应用内通知

关于页的“隐私与许可”提供项目说明和本地 GPL 正文；“许可与第三方通知”通过 SDK LicenseRegistry／LicensePage 提供组件许可及 CA／Geo／PSL 通知。资产声明见 [pubspec.yaml](pubspec.yaml)，注册入口见 [app_legal.dart](lib/src/ui/legal/app_legal.dart)。

## 二进制分发与对应源码

每次APK分发同时提供匹配该版本的完整对应源码、许可包及SHA256SUMS。对应源码包含Dart、Android、AIDL、JNI与Go接入、所用内核及依赖、re_editor本地适配、cross-language contract与生成器、锁文件、校验文件及构建脚本。外部取得的依赖按固定版本附来源和获取材料。

当前工作树归档入口收集Git已跟踪文件和未被忽略的新增文件；已删除文件不进入归档。归档记录包括：

| 路径 | 内容 |
| --- | --- |
| `build-inputs/source-tree.json` | baseCommit、workingTree／dirty、application.tar 摘要、逐文件大小／摘要／可执行位 |
| `build-inputs/version.json` | 应用版本、源码身份及实际 Flutter／Go 工具链 |
| `build-inputs/resources.json` | 同次 release 的工具链、依赖与固定资源记录 |
| `build-inputs/bundled/` | 当次 generated payload、资源 manifest、法律资产及生成定义 |
| `build-inputs/resource-sources.json` | 固定资源的来源及处理说明 |
| `dependencies/data/` | GeoIP 转换器与聚合数据输入、GeoSite 规则等资源可编辑来源的原字节归档 |

源码包包含公开合成测试证书、私钥及测试keystore，排除本机构建输出、.claude／索引、本机SDK位置、分发签名配置和敏感备份。产物核验比较源码清单、固定的源码副本及四个APK的构建记录。

第三方许可全文、版权和适用 NOTICE 随分发保留。GPL 第 6 条涉及的 User Product 分发需核对相应安装信息要求；系统库、通用工具和安装信息按 GPL 条款处理。签名材料使用其独立授权。

逐包核验入口和记录项见[最终产物与许可](doc/development/verification.md#最终产物与许可)。
