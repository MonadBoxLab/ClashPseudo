# Clash Pseudo

Clash Pseudo 是基于 mihomo 的 Android 网络接管与策略分流客户端，适用于手机与平板。提供配置导入与编辑、全局复写与本地定义、策略选择与 HTTP 延迟测试、实时连接管理以及网络诊断工具。

## 界面预览

<p align="center">
  <a href="doc/images/gallery/phone-overview.png"><img src="doc/images/gallery/phone-overview.webp" alt="手机总览：连接控制、实时流量趋势、活跃连接数与应用和内核内存" width="260"></a>
  &nbsp;&nbsp;&nbsp;&nbsp;
  <a href="doc/images/gallery/phone-strategies.png"><img src="doc/images/gallery/phone-strategies.webp" alt="手机策略：策略组成员选择与 HTTP 延迟测试结果" width="260"></a>
</p>
<p align="center">
  <sub>手机浅色界面：总览连接与网络活动 · 策略组选择与延迟测试</sub>
</p>

<p align="center">
  <a href="doc/images/gallery/tablet-overview.png"><img src="doc/images/gallery/tablet-overview.webp" alt="平板横屏总览：双栏连接控制与实时上下行流量、进程内存" width="380"></a>
  &nbsp;&nbsp;&nbsp;&nbsp;
  <a href="doc/images/gallery/tablet-editor.png"><img src="doc/images/gallery/tablet-editor.webp" alt="平板横屏编辑器：带行号的 YAML 配置正文、查找与自动换行" width="380"></a>
</p>
<p align="center">
  <sub>平板深色横屏：双栏总览与流量面板 · YAML 正文编辑器</sub>
</p>

## 获取项目

- [GitHub Releases](https://github.com/MonadBoxLab/ClashPseudo/releases) 安装包下载
    - 可以通过 [Obtainium](https://github.com/ImranR98/Obtainium) 跟踪版本更新
- [功能说明](doc/product/overview.md) · [开发与构建](doc/development/build-and-test.md)

> 应用通过公开接口接入 mihomo，没有维护 patch 或 fork。内核的修复随依赖版本更新引入。

## 隐私与许可

Clash Pseudo 不采集或上报任何用户数据，不提供任何代理节点或订阅服务。

隐私说明与许可全文位于应用“设置 → 关于 → 隐私与许可”。自有代码采用 [GPL-3.0-only](LICENSE)，第三方版权、许可与对应源码见 [NOTICE](NOTICE.md)。
