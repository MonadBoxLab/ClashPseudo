# 项目开发信息

## 架构与目录

应用采用Flutter／Dart界面与业务层、Kotlin Android宿主、JNI与Go内核接入。AppRuntime是唯一Dart业务执行者和三Store写者，Go承载进程内单内核上下文。职责与生命周期见[应用架构](doc/architecture/overview.md)。

- [lib/src/](lib/src/)：Flutter应用、业务与功能实现。
- [android/app/src/main/](android/app/src/main/)：Android宿主及平台接入。
- [native/mihomo/](native/mihomo/)：Go模块与mihomo自有接入。
- [test/](test/)：Flutter／Dart与工具回归；Android和Go测试沿各自源码目录组织。

## 事实来源与开发约定

- 跨语言常量以[contracts/application.json](contracts/application.json)为来源，由[生成器](tool/contracts/generate.py)生成Dart／Kotlin／Go／C定义；生成一致性使用其 `--check` 入口。
- 依赖版本以声明、锁文件和实际解析为准：Flutter见[pubspec.yaml](pubspec.yaml)／[pubspec.lock](pubspec.lock)，Go见[go.mod](native/mihomo/go.mod)／[go.sum](native/mihomo/go.sum)。Go生产tags为 `cmfa,with_gvisor`。
- re_editor使用[本地适配](third_party/sources/re_editor/)，来源与修改见[PATCHES](third_party/sources/re_editor/PATCHES.md)。
- 自有文档使用中文，第三方原文和原始输出保持来源身份。README面向应用用户，doc面向产品与维护者。
- 应用采用GPL-3.0-only；依赖更新、通知及对应源码按[许可与升级规范](doc/legal/dependencies.md)维护。
- 提交标题采用简短英文 `type(scope): subject`，正文署名 `Assisted by AI`。

## 开发入口

- 产品与交互：[产品概览](doc/product/overview.md)、[通用交互](doc/product/interaction.md)及所属功能规范。
- 数据与接入：[数据与操作](doc/architecture/data-and-operations.md)、[Android接入](doc/architecture/android.md)、[Go／mihomo接入](doc/architecture/core-integration.md)。
- 构建与验证：[构建和测试命令](doc/development/build-and-test.md)、[验证方法](doc/development/verification.md)。
- 用户入口与分发：[README](README.md)、[NOTICE](NOTICE.md)。
