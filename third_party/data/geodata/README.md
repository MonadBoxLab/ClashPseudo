# 内置 Geo 数据的来源与处理

本目录保存四类内置数据库的许可原文。五项 bundled resources（公共 CA 和四类 Geo 数据）的版本、下载 URL、原始及安装字节数、SHA-256、源码提交与许可摘要统一记录在 [resources.json](../resources.json)。源码不保存数据库 payload、实际 manifest 或随版本变化的 NOTICE。

## 来源与许可关系

| 工作文件 | 来源与适用许可 |
| --- | --- |
| GeoIP.dat | V2Fly geoip 聚合数据，CC-BY-SA-4.0；其中 DB-IP 输入另保留 CC-BY-4.0 归属 |
| GeoSite.dat | V2Fly domain-list-community，MIT，Copyright (c) 2018-2019 V2Ray |
| Country／ASN MMDB | DB-IP Country Lite／ASN Lite，CC-BY-4.0，保留 IP Geolocation by DB-IP 署名 |

GeoIP 的[上游说明](https://github.com/v2fly/geoip)与当次转换器源码归档中的 `config.json` 记录 DB-IP、private 和 test 输入。DB-IP 的 [Country](https://db-ip.com/db/download/ip-to-country-lite) 与 [ASN](https://db-ip.com/db/download/ip-to-asn-lite) 页面说明 Lite 数据的许可与归属。GeoIP 与 GeoSite 许可取自 `resources.json` 中固定的源码提交；[CC-BY-4.0 文本](https://github.com/spdx/license-list-data/blob/v3.27.0/text/CC-BY-4.0.txt)取自 SPDX。

## 更新、构建与安装

mihomo 官方正式 release 引发的应用 release，以及本地显式应用 release 更新，会统一解析并校验当次资源。普通 debug、release 和 act 重试只消费冻结记录；缺少 payload cache 时，只从固定 URL 下载并核对记录中的大小与 SHA-256，不查询最新版本。

`tool/dependencies/update.py --prepare-build` 将 payload、实际 manifest、`BundledAssetContract` 与法律材料生成到 `build/generated/bundled/`。Android 从 `assets/` 注册资源，Flutter 法律页从 `legal/` 读取同次材料。随源码保存的 [CC-BY-SA-4.0](CC-BY-SA-4.0.txt)、[CC-BY-4.0](CC-BY-4.0.txt) 和 [GeoSite MIT](GeoSite-MIT.txt) 保持上游原文；generated manifest 记录其摘要，产物核验比较 APK、generated 文件与冻结记录。

DAT 保持官方原始内容，GeoSite 的 `dlc.dat` 使用工作名 `GeoSite.dat`。两份 MMDB 保留 DB-IP 官方 gzip 字节，将本地扩展名从 `.gz` 改为 `.gzip`，避免 Android Gradle Plugin 在合并 assets 时处理 `.gz`。APK 保留原始归档，安装器再显式解压。运行时安装机制见 [Android 接入](../../../doc/architecture/android.md#内置geo)。

## 对应源码

应用对应源码包的 `build-inputs/bundled/` 保存同次五项 payload、实际 manifest、常量与法律材料；`build-inputs/resources.json` 保存冻结记录。GeoIP 转换器、GeoIP 数据与 GeoSite 的可编辑源码归档位于 `dependencies/data/`，其 URL、字节数和 SHA-256 见 `build-inputs/resource-sources.json`。

解开对应源码包并进入应用源码目录后，执行：

```sh
python3 -I -B tool/dependencies/update.py --prepare-build --offline \
  --payload-directory ../build-inputs/bundled/assets
```

该命令仅使用包内记录、payload 与许可原文重建 generated 文件。资源变化按[依赖复核](../../../doc/legal/dependencies.md#内核与依赖升级复核)检查来源与分发义务；下载入口见 [NOTICE](../../../NOTICE.md#二进制分发与对应源码)，产物校验见[最终产物与许可](../../../doc/development/verification.md#最终产物与许可)。
