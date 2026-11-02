# Clash Pseudo

Clash Pseudo 是基于 mihomo 的 Android 网络接管客户端。管理你的配置与代理策略，查看流量和近期连接，在需要时使用日志、资源状态和 DNS 工具查找网络问题。

## 连接与策略

在总览查看接管状态、运行时间、上下行速度、流量趋势，以及应用与内核的内存占用。支持规则、全局和直连模式，可选择策略组成员、恢复自动选择，并测试到 HTTP 目标的延迟。

内核异常退出后，当前页面和编辑内容继续保留。可在总览重新启动、更换配置，或选择需要清理的缓存与地理数据文件后恢复。

## 局域网代理服务

通过 Wi-Fi、手机热点或 USB 网卡的本地地址提供 HTTP 与 SOCKS5 代理，供局域网中的其他设备使用。服务可独立于 VPN 开启或停止，支持多地址、端口设置和 SOCKS5 UDP。

## 配置与本地定义

从 URL 或文件导入完整 mihomo 配置，管理多个配置，编辑本地正文。使用全局 YAML 复写插件调整配置，设置远程内容自动更新；通过表单创建和编辑节点、策略组、规则及 provider。

## 网络活动与诊断

在近期连接中搜索目标、筛选记录，查看命中规则、分流路径和流量，或断开单条连接。内核日志、运行配置、外部资源和 DNS 查询提供进一步检查入口；错误详情与原始数据支持阅读和复制。

## Android 与个性设置

按应用设置接管范围，配合 Android Always-on、快捷设置磁贴和桌面小组件控制连接。提供系统／浅色／深色外观、中文与 English、主题主色选择，以及配置、插件和偏好的文件备份与恢复。界面适配手机、平板、分屏和大字号。

## 获取与项目

项目处于开发阶段，尚未公开发布，当前面向 Android 手机和平板。

- [GitHub Releases](https://github.com/MonadBoxLab/ClashPseudo/releases)：后续发布入口，可通过 [Obtainium](https://github.com/ImranR98/Obtainium) 跟踪更新。
- [源码与问题反馈](https://github.com/MonadBoxLab/ClashPseudo)
- [功能说明](doc/product/overview.md) · [开发与构建](doc/development/build-and-test.md)

## 内核与更新

应用通过公开接口接入 mihomo 等上游内核依赖，不维护这些内核依赖的 patch 或 fork。上游修复随依赖版本更新引入。

## 隐私与许可

Clash Pseudo 不采集或上报用户数据，不提供代理节点或订阅服务。配置和来源由用户提供。

隐私说明与许可全文位于应用“设置 → 关于 → 隐私与许可”。自有代码采用 [GPL-3.0-only](LICENSE)，第三方版权、许可与对应源码见 [NOTICE](NOTICE.md)。
