# 许可与第三方来源

Clash Pseudo 自有代码采用 **GPL-3.0-only**，整体应用以 GNU General Public License 第 3 版作为分发基线，不授予自动采用后续版本的选项。许可全文见 [LICENSE](LICENSE)。在适用法律允许范围内不提供担保，详见许可第 15、16 条。第三方部分保留各自版权、许可及适用通知，本项目声明不重新授权第三方代码。

Android 原生库链接 [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)，固定版本 `v1.19.32`，提交 `88dcbf7f1614a67c3b36b848ee3592dfa92ada36`。上游 GNU GPL v3 [许可原文](third_party/mihomo/LICENSE) 随仓库保留。

依赖版本、上游要求的 protobuf 替换和校验值见 [go.mod](native/mihomo/go.mod) 与 [go.sum](native/mihomo/go.sum)。

接入调研参考：

- [ClashMetaForAndroid](https://github.com/MetaCubeX/ClashMetaForAndroid/tree/3cc102aab3f251ef460a3b6e2835b6c1eb581e73)。
- [FlClash](https://github.com/chen08209/FlClash/tree/4b59eca853778d4e7be3de26589252889c899bc5)。

## Flutter 图标依赖

以下许可依据锁定版本包内 `LICENSE`，版本与校验值见 [pubspec.lock](pubspec.lock)。Flutter 构建将这些包的完整版权与许可合并到 APK 的 `assets/flutter_assets/NOTICES.Z`；分发时不得剥离该材料。表格不是对全部运行依赖的替代清单。

| 包与固定版本 | 来源 | 许可 |
| --- | --- | --- |
| flutter_svg 2.3.0 | [版本源码](https://pub.dev/packages/flutter_svg/versions/2.3.0) | MIT |
| vector_graphics 1.2.3 | [版本源码](https://pub.dev/packages/vector_graphics/versions/1.2.3) | BSD-3-Clause |
| vector_graphics_codec 1.1.13 | [版本源码](https://pub.dev/packages/vector_graphics_codec/versions/1.1.13) | BSD-3-Clause |
| vector_graphics_compiler 1.3.2 | [版本源码](https://pub.dev/packages/vector_graphics_compiler/versions/1.3.2) | BSD-3-Clause |
| path_parsing 1.1.0 | [版本源码](https://pub.dev/packages/path_parsing/versions/1.1.0) | MIT |
| xml 7.0.1 | [版本源码](https://pub.dev/packages/xml/versions/7.0.1) | MIT |
| petitparser 7.1.0 | [版本源码](https://pub.dev/packages/petitparser/versions/7.1.0) | MIT |

MIT 与 BSD-3-Clause 的版权、许可、免责声明必须保留；BSD-3-Clause 另禁止未经许可借权利人／贡献者名义背书。本项目只使用公开 API，未修改这些包的源码。

## 配置编辑与文件选择依赖

实际锁定包内许可：`file_selector 1.1.0` 及其平台实现、`cross_file 0.3.5+5`、`plugin_platform_interface 2.1.8` 为 BSD-3-Clause；`re_editor 0.10.0`、`re_highlight 0.0.3`、`isolate_manager 4.1.5+1`、`isolate_contactor 4.1.0` 为 MIT。所有平台实现出现在依赖解析中，不代表 Android APK 包含其他平台的原生代码，也不代表已验收这些平台。

这些包的版权与许可由 Flutter 合入 `NOTICES.Z`。本项目不使用编辑器内部导入、不修改第三方源码。应用总览的“关于与许可”入口通过 SDK `LicenseRegistry`／`LicensePage` 展示自有代码、mihomo 和随包第三方通知。

## Android 运行依赖与图标字体

[Android 通知汇编](third_party/android-notices.txt) 按 `releaseRuntimeClasspath` 的 45 个非 Flutter Maven 坐标记录固定版本 POM、发布的源码归档、校验值和原始许可头，并保留 JAR／AAR（含嵌套 JAR）的随附通知。它包括 AndroidX、Kotlin／协程、JetBrains annotations、ReLinker、Guava ListenableFuture 与 JSpecify；解析元数据和可能被 R8 移除的源码不等于实际全部编入 APK。`kotlin-stdlib-common:2.4.0` 与 `kotlinx-coroutines-bom:1.7.1` 的 POM 为元数据，无独立源码归档；`listenablefuture:1.0` 的 Apache-2.0 声明继承自固定父 POM `guava-parent:26.0-android`。

Flutter 引擎／Dart 依赖通知由 `NOTICES.Z` 提供，当前引擎版本为 `deb287481e3ce9468f3434937ced4240a70539ca`。不要由此推定所有字体许可也已包含：当前随 Flutter 分发的 `MaterialIcons-Regular.otf` 附带 **CC BY 4.0**，本项目另附[字体署名与完整许可](third_party/material-icons-notice.txt)，记录 Google LLC 版权、固定归档来源、原始字体校验值及 release 自动裁剪说明。该字体不是项目自有 GPL 代码，不因最新上游网页采用其他许可而改写本次归档的声明。

这些材料随应用打包，并通过“关于与许可”入口展示。保留通知不替代最终产物与对应源码核对。

## Go 原生依赖与许可处理

[Go 通知汇编](third_party/go-notices.txt) 保留 Android arm64／x64 依赖解析涉及的 109 个固定模块的随附许可、NOTICE、版权及文件校验值；模块内附带的其他组件通知也一并保留，不表示其每个文件均编入二进制。构建产物的 `go version -m` 与 [go.sum](native/mihomo/go.sum) 可核对实际版本和模块校验。

两项曾存在的许可材料疑点通过采用上游修正版本解决：

- `github.com/rasky/go-lzo v0.0.0-20261012164727-ad21c35a1111` 的 README 明确 **GPL-2.0-or-later**，本项目依此按 GPLv3 组合使用，保留原 GPLv2 正文与该声明。
- `github.com/metacubex/chacha v0.1.6-0.20250812085457-7b981d42c3ba` 补齐根 **MIT LICENSE**，保留 Andreas Auernhammer／MetaCubex 版权以及原有子目录许可。

两次更新只改变许可材料，归档内原有源码不变；不修改 mihomo、不维护 fork、不替换算法。精确提交、固定证据、校验值、归档比较及后续升级复核要求见[依赖许可处理依据](docs/dependency-licenses.md)。结论仅适用于核实的版本，不能由此推定未来内核／依赖升级已完成许可核查。

## 二进制分发与对应源码

分发 APK 时，应以该 APK 对应的固定应用版本提供完整对应源码与必要构建材料，包括应用 Dart／Android／JNI／Go 衔接代码、实际编入的内核及依赖版本、应用补丁、锁定与校验文件、构建脚本及环境说明。推荐在同一下载位置随二进制提供对应源码归档和可核对的版本标识，不以可变 `main` 分支或上游首页代替对应源码；未随归档提供的依赖须有符合许可要求、可取得该固定版本的交付安排。

第三方许可全文、版权与适用 NOTICE 必须随分发保留。系统库或通用工具是否属于可排除部分，按实际 GPL 条款与分发环境判断；不要求机械复制整个开发 SDK。签名私钥不是默认公开的构建材料；如分发涉及 GPL 第 6 条所定义的 User Product，须另行核对适用的安装信息义务。

当前尚未公开发布。每次实际对外分发前仍须依据最终产物核对依赖、通知、对应源码与渠道要求；开发构建通过不构成许可审计完成或法律担保。
