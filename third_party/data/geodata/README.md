# 内置Geo数据的来源与处理

本目录提供四类内置数据库的许可原文与来源说明。数据库原件位于[Android资产](../../../android/app/src/main/assets/geodata/)，运行时安装机制见[Android接入](../../../doc/architecture/android.md#内置geo)。

## 来源与许可关系

| 工作文件 | 来源与适用许可 |
| --- | --- |
| GeoIP.dat | V2Fly geoip聚合数据，CC-BY-SA-4.0；其中DB-IP输入另保留CC-BY-4.0归属 |
| GeoSite.dat | V2Fly domain-list-community，MIT，Copyright (c) 2018-2019 V2Ray |
| Country／ASN MMDB | DB-IP Country Lite／ASN Lite，CC-BY-4.0，保留IP Geolocation by DB-IP署名 |

GeoIP的[上游声明](https://github.com/v2fly/geoip/blob/fd96fbac6cffc06ab9a10d6ee8fad61afe9b771c/README.md)与[生成配置](https://github.com/v2fly/geoip/blob/fd96fbac6cffc06ab9a10d6ee8fad61afe9b771c/config.json)说明聚合数据及其DB-IP、private和test输入。DB-IP的[Country](https://db-ip.com/db/download/ip-to-country-lite)与[ASN](https://db-ip.com/db/download/ip-to-asn-lite)页面说明Lite数据的许可与归属。

具体版本、下载URL、原始／安装大小和SHA-256由[资产manifest](../../../android/app/src/main/assets/geodata/manifest.json)记录。许可原文的来源为[GeoIP LICENSE](https://github.com/v2fly/geoip/blob/fd96fbac6cffc06ab9a10d6ee8fad61afe9b771c/LICENSE)、[GeoSite LICENSE](https://github.com/v2fly/domain-list-community/blob/6b0f8edc935ee0ad2cb386ac3efd451ee2380ac5/LICENSE)及[SPDX的CC-BY-4.0文本](https://github.com/spdx/license-list-data/blob/v3.27.0/text/CC-BY-4.0.txt)。数据授权与署名依据来自对应数据来源。

## 工作名与压缩处理

DAT保持原始内容，GeoSite的dlc.dat使用工作名GeoSite.dat。两份MMDB保留DB-IP官方gzip字节，将本地扩展名从.gz改为.gzip：Android Gradle Plugin会在合并资产时处理.gz，使用.gzip使原始归档进入APK，安装器再显式解压。官方下载URL、原始字节与摘要保持对应关系。

随源码保存的[CC-BY-SA-4.0](CC-BY-SA-4.0.txt)、[CC-BY-4.0](CC-BY-4.0.txt)和[GeoSite MIT](GeoSite-MIT.txt)是许可原文，[NOTICE.txt](NOTICE.txt)提供归属与处理说明。Gradle从本目录生成Android原生法律资产，Flutter法律页直接读取本目录材料。资产manifest保留对应摘要，产物核验同时比较包内字节、权威原文及来源记录。

数据库及许可变化按[依赖复核](../../../doc/legal/dependencies.md#内核与依赖升级复核)核对来源与分发义务，产物校验见[最终产物与许可](../../../doc/development/verification.md#最终产物与许可)。
