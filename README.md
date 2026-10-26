# Clash Pseudo

Clash Pseudo 是一款基于 mihomo 的网络接管客户端，提供配置管理、策略选择、近期连接查看和必要的网络诊断，注重轻量、可靠性与清晰的交互体验。

项目处于开发阶段，尚未公开发布。目标平台为 Android 手机和平板，后续扩展到 Windows 与 macOS。

## 主要功能

- **运行与策略**：启动、停止，切换规则／全局／直连模式，选择策略成员并测试HTTP目标延迟。
- **配置与插件**：从URL或文件导入完整配置，管理多个配置、编辑本地正文，按顺序合成YAML复写片段。
- **网络活动**：查看流量趋势、本次连接累计和近期连接，支持搜索、筛选、详情及单条断开。
- **本地定义与诊断**：管理节点、策略组、规则和provider，查看资源、日志、运行配置并执行DNS查询。
- **Android接入**：按应用选择接管范围，使用Always-on、快捷菜单、磁贴和桌面小组件。
- **外观与备份**：系统／浅色／深色主题，中英语言和三种品牌主色，导入、导出配置与设置。

## 使用说明

导入可信来源的完整mihomo配置，在总览启动连接，并按系统提示完成VPN授权。运行期间可调整策略，在近期连接中检查目标和实际分流路径。配置保存与实际应用分别报告，更新后以界面显示的真实结果为准。

近期连接保存在有界内存窗口中，适合检查当前活动。导出的备份为明文文件，含配置正文、来源及可能的凭据，请妥善保存。

详细说明见[运行与策略](doc/product/runtime-and-strategies.md)、[配置与插件](doc/product/configurations.md)、[连接观察](doc/product/connections.md)和[备份与恢复](doc/product/backup.md)。

## 项目与许可

- [源码与问题反馈](https://github.com/MonadBoxLab/ClashPseudo)
- [GitHub Releases](https://github.com/MonadBoxLab/ClashPseudo/releases)：后续发布入口，可通过[Obtainium](https://github.com/ImranR98/Obtainium)跟踪更新。
- 自有代码采用[GPL-3.0-only](LICENSE)，第三方版权、许可与对应源码要求见[NOTICE](NOTICE.md)。
