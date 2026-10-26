# 许可、第三方来源与分发

Clash Pseudo自有代码采用 **GPL-3.0-only**，许可全文见[LICENSE](LICENSE)。第三方代码、字体与数据分别适用其原始版权、许可及随附通知。

## 内核与依赖来源

Android原生库通过Go模块链接[MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)。上游[GPL v3许可原文](third_party/notices/mihomo.txt)随源码提供；实际版本、模块校验与protobuf替换关系由[go.mod](native/mihomo/go.mod)、[go.sum](native/mihomo/go.sum)及产物buildinfo确定。

Flutter／Dart依赖由[pubspec.yaml](pubspec.yaml)与[pubspec.lock](pubspec.lock)确定，Android依赖采用releaseRuntimeClasspath的解析结果。具体来源、许可处理依据及升级复核方法见[依赖许可依据](doc/legal/dependencies.md)。

## Flutter、Dart与编辑器

Flutter构建将引擎、Dart及所用包的版权与许可合并至APK的assets/flutter_assets/NOTICES.Z，分发时保留该材料。主要组件的许可如下，完整内容由解析图与包内通知确定。

| 组件 | 许可 |
| --- | --- |
| flutter_svg、path_parsing、xml、petitparser | MIT |
| vector_graphics、vector_graphics_codec、vector_graphics_compiler | BSD-3-Clause |
| file_selector及平台实现、cross_file、plugin_platform_interface | BSD-3-Clause |
| re_editor、re_highlight、isolate_manager、isolate_contactor | MIT |
| yaml | MIT；Dart project authors／Kirill Simonov |
| yaml_edit | BSD-3-Clause；Dart project authors |

[re_editor源码](third_party/sources/re_editor/)采用官方归档，并保留[MIT许可原文](third_party/sources/re_editor/LICENSE)。应用对其生命周期、编辑准入、IME同步与测试观测进行了修改；来源、修改范围及校验记录见[PATCHES](third_party/sources/re_editor/PATCHES.md)。对应源码分发包含这些修改及原始版权、许可。

## Android、图标与Go材料

[Android通知](third_party/notices/android.txt)记录所核对的Maven坐标、POM、源码归档与JAR／AAR随附通知，覆盖AndroidX、Kotlin／协程、JetBrains annotations、ReLinker、Guava ListenableFuture及JSpecify等组件。具体分发内容以构建产物为准。

所用MaterialIcons-Regular.otf归档采用 **CC BY 4.0**，版权为Google LLC。[字体通知](third_party/notices/material-icons.txt)包含署名、完整许可、原始字体校验值及Flutter release裁剪说明。

[Go通知](third_party/notices/go.txt)保存所用模块的版本、许可、版权、NOTICE及AUTHORS／PATENTS原文。原生库按生产标签cmfa,with_gvisor构建，实际链接关系由各ABI的buildinfo确定。其中go-lzo归档明确采用GPL-2.0-or-later，按GPLv3组合；chacha归档提供根MIT LICENSE及相关版权。固定来源与校验记录见[许可依据](doc/legal/dependencies.md)。

## 公共CA、Geo与Public Suffix数据

| 数据 | 来源与归属 | 许可 |
| --- | --- | --- |
| 公共CA PEM | curl提供的Mozilla CA Extract，版本与源文件见[通知](third_party/data/certificates/NOTICE.txt) | [MPL-2.0](third_party/data/certificates/MPL-2.0.txt) |
| GeoIP.dat | V2Fly geoip聚合数据，并保留DB-IP输入归属 | CC-BY-SA-4.0及相应输入的CC-BY-4.0 |
| GeoSite.dat | V2Fly domain-list-community，Copyright (c) 2018-2019 V2Ray | MIT |
| Country.mmdb／ASN.mmdb | DB-IP.com Country Lite／ASN Lite；IP Geolocation by DB-IP — https://db-ip.com/ | CC-BY-4.0 |
| Public Suffix List | PSL项目，修订与可编辑来源见[通知](third_party/notices/publicsuffix.txt) | 数据采用MPL-2.0，Go实现采用BSD |

CA使用原始PEM快照。Geo数据的来源、工作文件名与压缩处理见[数据说明](third_party/data/geodata/README.md)，[归属通知](third_party/data/geodata/NOTICE.txt)及[CC-BY-SA-4.0](third_party/data/geodata/CC-BY-SA-4.0.txt)、[MIT](third_party/data/geodata/GeoSite-MIT.txt)、[CC-BY-4.0](third_party/data/geodata/CC-BY-4.0.txt)全文随源码和应用提供。PSL对应源码包含所用修订的可编辑列表与x/net实现。数据分发按照各自条款保留署名、来源、修改说明及适用的相同方式共享义务。

## 应用内通知

“关于与许可”通过SDK LicenseRegistry／LicensePage提供项目许可、组件许可及CA／Geo／PSL等数据通知。资产由[pubspec.yaml](pubspec.yaml)声明，注册入口为[app_legal.dart](lib/src/app/app_legal.dart)。

## 二进制分发与对应源码

分发APK时，提供与该产物对应的完整源码及必要构建材料，包括Dart、Android、JNI、Go衔接代码，所用内核与依赖版本，应用补丁，锁文件、校验文件及构建脚本。分发位置应提供可核对的版本标识和对应源码归档；采用外部依赖交付时，应确保接收者能够按固定版本取得符合许可要求的源码。

第三方许可全文、版权与适用NOTICE随分发保留。系统库、通用工具及安装信息的范围按GPL条款和实际分发环境确定；涉及GPL第6条User Product时，评估相应安装信息义务。签名材料按其独立授权和分发要求管理。

产物、通知、依赖版本及对应源码的核对方法见[最终产物与许可](doc/development/verification.md#最终产物与许可)。
