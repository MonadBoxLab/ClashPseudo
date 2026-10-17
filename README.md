# Clash Pseudo

Clash Pseudo 是 **MonadBox Lab** 计划基于 mihomo 开发的跨平台网络接管应用，注重轻量、启动速度、后台可靠性和界面体验。

Android 已接入总览、策略与二级配置管理：支持完整配置 URL 导入、多配置选择／删除、同来源确认覆盖更新、授权启停、规则／全局／直连模式，以及停止时策略预选、运行中成员切换和每配置选择恢复。界面跟随系统深浅主题，打开或恢复时读取真实状态；总览可进入有界近期连接列表与详情，查看真实目标、路径、命中规则、累计流量与当前速度，支持生命周期／规则组合筛选、暂停展示和单条断开。接管期间逻辑引擎持续观察，停止后记录暂留至过期，不写磁盘。长期历史、完整拒绝记录、单连接速度趋势、来源应用与策略编辑尚未实现。总览另展示真实全局上下行速度、近30秒趋势与实时活跃连接数，数字和曲线区域均可进入连接页。

当前仍是开发验证版本，**不能视为完整生命周期已验收**。仅使用可信配置来源；[信任模型与已知限制](docs/android-native-integration.md#当前边界) 不承诺恶意完整配置的严格文件沙箱隔离。资源分配后的配置解析失败已复现未显式释放 WireGuard 工作协程，相关回归保持失败；上游并发读写限制另行记录。

## 产品与设计

- 目标平台：Android 手机 → Android 平板 → Windows → macOS。
- [产品需求](docs/product-requirements.md)：功能目标、操作规则和待决定事项。
- [应用页面设计依据](docs/home-design.md)：现有总览、模式入口、策略与连接页的布局、状态表达和动效约束；全应用设计原则见产品需求。
- [离线体验原型](docs/prototypes/product-preview.html)：可直接用浏览器打开，使用模拟数据，仅作总览、策略组、连接及相关子页面的阶段性参考；不是完整流程或正式应用。

## 源码与发布

源码与反馈：[MonadBoxLab/ClashPseudo](https://github.com/MonadBoxLab/ClashPseudo)。计划通过 GitHub Releases 分发，Android 可通过 [Obtainium](https://github.com/ImranR98/Obtainium) 跟踪更新。自有代码采用 [GPL-3.0-only](LICENSE)，第三方许可与分发时的对应源码要求见 [NOTICE](NOTICE.md)。

## 开发

- 主开发环境为 Debian 13；Flutter 位于 `~/develop/flutter`，Android SDK 位于 `~/Android/Sdk`。
- Android 模拟器在局域网另一台机器运行，通过现有 ADB 服务连接；以 `adb devices -l` 核对实际设备，不依赖固定序列号。
- Windows 使用独立 Windows 虚拟机，macOS 在 Mac 上构建。各系统使用独立 Git 工作区，不共享构建目录或生成产物。
- 工具链要求以现有 Flutter SDK、[pubspec.yaml](pubspec.yaml) 和 [Android 工程配置](android/settings.gradle.kts) 为准；不单独升级工具或平台插件。
- Android 原生构建使用 Linux x86_64 宿主、Bash、Go 1.27.1 和 NDK 28.2.13676358。Gradle 管理任务与输入输出，Bash 编排两种 ABI 的原生编译。
- 受控网络测试端使用 Python 3 标准库，仅设备验证时需要，不参与应用构建。原生职责、专属测试命令和设备操作见 [Android 原生接入](docs/android-native-integration.md)。

在仓库根目录执行：

```bash
flutter pub get

dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64,android-x64
flutter build apk --release --target-platform android-arm64,android-x64
```

Android debug APK 位于 `build/app/outputs/flutter-apk/app-debug.apk`。Windows/macOS 在对应系统运行 `flutter build windows` / `flutter build macos`；保留工程不表示这些平台已经通过构建或运行验收。

协作规则见 [CLAUDE.md](CLAUDE.md)。
