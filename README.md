# Clash Pseudo

Clash Pseudo 是 **MonadBox Lab** 计划基于 mihomo 开发的跨平台网络接管应用，注重轻量、启动速度、后台可靠性和界面体验。

当前应用仅显示 Hello World，尚未接入 mihomo，不能用于网络接管。

## 产品与设计

- 目标平台：Android 手机 → Android 平板 → Windows → macOS。
- [产品需求](docs/product-requirements.md)：功能目标、操作规则和待决定事项。
- [离线体验原型](docs/prototypes/product-preview.html)：可直接用浏览器打开；使用模拟数据，是未完成的阶段性参考，不是正式应用。

## 源码与发布

源码与反馈：[MonadBoxLab/ClashPseudo](https://github.com/MonadBoxLab/ClashPseudo)。计划通过 GitHub Releases 分发，Android 可通过 [Obtainium](https://github.com/ImranR98/Obtainium) 跟踪更新。开源许可与依赖许可仍需核对。

## 开发

- 主开发环境为 Debian 13；Flutter 位于 `~/develop/flutter`，Android SDK 位于 `~/Android/Sdk`。
- Android 模拟器在局域网另一台机器运行，通过现有 ADB 服务连接；以 `adb devices -l` 核对实际设备，不依赖固定序列号。
- Windows 使用独立 Windows 虚拟机，macOS 在 Mac 上构建。各系统使用独立 Git 工作区，不共享构建目录或生成产物。
- 工具链要求以现有 Flutter SDK、[pubspec.yaml](pubspec.yaml) 和 [Android 工程配置](android/settings.gradle.kts) 为准；不单独升级工具或平台插件。

在仓库根目录执行：

```bash
flutter pub get

dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64,android-x64
```

Android debug APK 位于 `build/app/outputs/flutter-apk/app-debug.apk`。Windows/macOS 在对应系统运行 `flutter build windows` / `flutter build macos`；保留工程不表示这些平台已经通过构建或运行验收。

协作规则见 [CLAUDE.md](CLAUDE.md)。
