# 第三方来源与许可

Android 原生库链接 [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)，固定版本 `v1.19.32`，提交 `88dcbf7f1614a67c3b36b848ee3592dfa92ada36`。上游 GNU GPL v3 [许可原文](third_party/mihomo/LICENSE) 随仓库保留。

依赖版本、上游要求的 protobuf 替换和校验值见 [go.mod](native/mihomo/go.mod) 与 [go.sum](native/mihomo/go.sum)。

接入调研参考：

- [ClashMetaForAndroid](https://github.com/MetaCubeX/ClashMetaForAndroid/tree/3cc102aab3f251ef460a3b6e2835b6c1eb581e73)。
- [FlClash](https://github.com/chen08209/FlClash/tree/4b59eca853778d4e7be3de26589252889c899bc5)。

项目整体许可待确定。发布前需核对全部随包依赖的许可，并落实 GPL 对对应源码、构建材料和通知的要求。
