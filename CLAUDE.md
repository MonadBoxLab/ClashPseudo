# 项目开发信息

## 架构与目录

应用采用Flutter／Dart界面与业务层、Kotlin Android宿主、AIDL／FD通信、薄JNI与Go内核接入。默认进程保留UI和唯一AppRuntime，由AppRuntime发起配置、插件及偏好文件的全部业务写入；`:core`承载CoreService、VpnService、Go与mihomo，所有合成、解析、预览、运行和诊断均在该进程执行。职责与lifecycle见[应用架构](doc/architecture/overview.md)。

- [lib/src/](lib/src/)：Flutter应用、业务与功能实现。
- [android/app/src/main/](android/app/src/main/)：Android宿主及平台接入。
- [native/mihomo/](native/mihomo/)：Go模块与mihomo自有接入。
- [test/](test/)：Flutter／Dart与工具回归；Android和Go测试沿各自源码目录组织。

## 裁剪与内核接入边界

- 应用以PASSTHROUGH为目标，遵循KISS与奥卡姆剃刀：复用现有接口和对象，删除重复状态、无当前需求的抽象及重复执行步骤。
- mihomo负责配置解析、协议、规则匹配、Geo数据库及内部缓存。应用自有Dart、Kotlin、JNI和Go代码负责交互、业务保存、平台接入与资源lifecycle。
- 禁止为修补mihomo自身问题修改上游源码、维护补丁或fork、复制或替换其内部实现，也禁止在应用及Go／JNI接入层增加替代处理。该边界适用于全部内核功能，不限于Geo。
- 应用测试覆盖自有接口调用、平台适配、状态和lifecycle，不为mihomo内部行为建立本地回归或发布门槛。已确认的上游问题通过更新上游版本解决，不在应用侧补偿。
- 测试按实际应用缺陷和行为选择，不添加仅检查源码字符串、配置字面量或步骤排列的 trivial 测试。自动更新发布 workflow 不运行测试，也不依赖测试报告。
- 应用只修复自身的接口调用、平台适配、状态显示及lifecycle错误。数据库下载、验证、修复和reader管理使用mihomo的公开接口，不另建应用实现。

## 事实来源与开发约定

- 自有工具统一通过[tool/main.py](tool/main.py)调用，每级支持 `-h/--help`。跨语言常量以[contracts/application.json](contracts/application.json)为来源，使用 `python3 -I -B tool/main.py contracts generate` 生成 Dart／Kotlin／Go／C 定义，使用 `contracts check` 检查一致性。
- 依赖版本以声明、锁文件和实际解析为准：Flutter见[pubspec.yaml](pubspec.yaml)／[pubspec.lock](pubspec.lock)，Go见[go.mod](native/mihomo/go.mod)／[go.sum](native/mihomo/go.sum)。Go生产tags为 `cmfa,with_gvisor`。
- re_editor使用[本地适配](third_party/sources/re_editor/)，来源与修改见[PATCHES](third_party/sources/re_editor/PATCHES.md)。
- 自有文档使用中文，第三方原文和原始输出保持来源身份。README面向应用用户，doc面向产品与维护者。
- 应用采用GPL-3.0-only；依赖更新、通知及对应源码按[许可与升级规范](doc/legal/dependencies.md)维护。
- 提交标题采用简短英文 `type(scope): subject`，AI 协助开发的提交正文署名 `Assisted by AI`；GitHub Actions 机器人自动提交不添加 AI 署名。

## 文字与说明

- 技术术语使用英文，说明句使用通行、自然的中文，写明具体对象、状态和动作；不自造简称、中文译名或中英混合词，不机械翻译。检查完整句子与语境，范围不限于已指出的词句。
- 自有注释、测试文字、生成说明与文档使用同一要求；代码标识符、协议字段、正式名称及第三方原文保持原值。
- 禁止任何 AI 防御性文字，且不限特定段落。
- 适用范围包括自有文档、计划、代码注释、测试说明、工具生成的说明、回复，以及agent调度与交接消息。
- 删除自证、免责、预防质疑、过程辩解和写作元叙述，不换措辞保留同一意图。
- 直接写功能、操作、架构、接口、来源、许可与实际结果；执行结果逐项说明成功、失败和未完成事项。
- 使用说明写明实际界面入口、操作顺序、可见结果和下一步动作。

## 开发入口

- 产品与交互：[产品概览](doc/product/overview.md)、[通用交互](doc/product/interaction.md)及所属功能规范。
- 数据与接入：[数据与操作](doc/architecture/data-and-operations.md)、[Android接入](doc/architecture/android.md)、[Go／mihomo接入](doc/architecture/core-integration.md)。
- 构建与验证：[构建和测试命令](doc/development/build-and-test.md)、[验证方法](doc/development/verification.md)。
- 用户入口与分发：[README](README.md)、[NOTICE](NOTICE.md)。
