# 依赖许可处理依据与升级复核

本文面向维护者，保存固定版本的许可判断依据及升级要求。分发摘要和对应源码要求见 [NOTICE](../NOTICE.md)，法律原文保存在 [third_party](../third_party/) 和根 [LICENSE](../LICENSE)。本文件不是第三方重新授权、法律担保或所有未来版本的兼容性证明。

## 当前基线与职责

2026-10-17 核实的内核基线为 `github.com/metacubex/mihomo v1.19.32`，提交 `88dcbf7f1614a67c3b36b848ee3592dfa92ada36`。自有代码采用 GPL-3.0-only；第三方保留各自版权与许可。应用未修改 mihomo，也不维护内核 fork。

- [go.mod](../native/mihomo/go.mod)／[go.sum](../native/mihomo/go.sum)：实际模块要求、既有 replace 和校验值。`go.sum` 可能保留上游要求的旧版本校验，不能据此判定旧版本被链接；以解析图与产物为准。
- [Go 通知汇编](../third_party/go-notices.txt)：Android arm64／x64 构建依赖的许可、版权与 NOTICE，保留模块内适用原始材料，不表示模块每个文件均编入 APK。
- 本文：两项问题的解决依据、适用边界及复核办法，不依赖会话记录或本地临时目录。
- [NOTICE](../NOTICE.md)：应用分发摘要、其他依赖材料及完整对应源码要求。Flutter／Android／字体材料不能由 Go 核查替代，反之亦然。

## go-lzo：明确 GPL-2.0-or-later

原锁定版本 `v0.0.0-20200203143853-96a758eda86e` 的 README 写 GPLv2，随附 GPLv2 正文。仅凭正文附录中的示例不能推定 or-later；但这种表述不明确也不能直接断言项目为 GPL-2.0-only。

采用上游版本 **`v0.0.0-20261012164727-ad21c35a1111`**：

- 完整提交：[ad21c35a111113348567708a4db74f998be1a4c3](https://github.com/rasky/go-lzo/commit/ad21c35a111113348567708a4db74f998be1a4c3)，直接父提交为原锁定的 `96a758eda86e0ca29bc2638000fdb0ff0a6d96d8`。
- [固定 README](https://github.com/rasky/go-lzo/blob/ad21c35a111113348567708a4db74f998be1a4c3/README.md) 明确：

  > Being a straightforward port of the original source code, it shares the same
  > license (GPL-2.0-or-later) as I can't possibly claim any copyright on it.

- [issue 15 维护者回复](https://github.com/rasky/go-lzo/issues/15#issuecomment-6128639788) 对 GPLv2-only／or-later 的明确询问回复“Done”，对应上述修改。原 [LZO 项目](https://www.oberhumer.com/opensource/lzo/) 的 GPLv2+ 声明为来源补充，不代替本 Go 移植的固定声明。
- 两版本 Go 模块 zip 去除模块版本根目录后按相对路径逐文件比较：仅 `README.md` 内容变化，无增删文件，所有源码相同。
- 新 README 完整文件 SHA-256：`9fa5f03995a7ce8ee795c89ddb39a16dd0f71ab6e393afd4637924c159a304d4`。
- 模块 Sum：`h1:TdWAEloUou4dmmeBono7DfE/PdfsoLn4+R4xTfIm7Bw=`；GoModSum：`h1:9leZcVcItj6m9/CfHY5Em/iBrCz7js8LcRQGTKEEv2M=`。
- 模块 zip SHA-256：`e306e0f265561d2a8ab8129312960e331b380d901ae1bca20b46771bfc6b54ee`。

**结论：**依据固定版本的明确 or-later 声明，按 GPLv3 组合使用，保留原 `LICENSE.gpl`、README 许可声明及随包 GPLv3 正文。依据 [GNU v2/v3 兼容性说明](https://www.gnu.org/licenses/gpl-faq.en.html#v2v3Compatibility)，不能把本结论泛化到 GPL-2.0-only 项目，也不将应用自有代码改为 GPL-3.0-or-later。

## chacha：补齐根 MIT LICENSE

原锁定 `github.com/metacubex/chacha v0.1.5`，tag 对应 `07294f500ca8384015f6cc21311de7b6f093607d`。归档已有 `chachapoly1305/LICENSE` 和 `poly1305/LICENSE`，但缺少根 LICENSE；不能描述成整个归档没有许可，也不能用相似上游的 MIT 替代当前 fork 的授权依据。

采用上游版本 **`v0.1.6-0.20250812085457-7b981d42c3ba`**：

- 完整提交：[7b981d42c3baca5a004e7b0ecfb9b67ee20e583a](https://github.com/MetaCubeX/chacha/commit/7b981d42c3baca5a004e7b0ecfb9b67ee20e583a)，直接父提交为上述 v0.1.5。
- [固定根 LICENSE](https://github.com/MetaCubeX/chacha/blob/7b981d42c3baca5a004e7b0ecfb9b67ee20e583a/LICENSE) 为 MIT，完整保留：

  > Copyright (c) 2016 Andreas Auernhammer
  > Copyright (c) 2025 MetaCubex

- 两版本实际 Go 模块 zip 比较：只新增根 `LICENSE`，所有原有文件（含源码、go.mod 和子目录许可）逐字节相同。
- 根 LICENSE SHA-256：`3fac516804d269e044c071507def0677d614793776ac506e630337c63f1dcb77`。
- 模块 Sum：`h1:uYSI4GNiPPyKTPeQeVIm264uUfGDdWT9QsjUSXxXdTc=`；GoModSum：`h1:Djn9bPZxLTXbJFSeyo0/qzEzQI+gUSSzttuzZM75GH8=`。
- 模块 zip SHA-256：`d74619878b480cc8ce29e4c4d58d2e3c73ef75fa9a14ab09879574a292b4adc1`。
- 伪版本由 Go proxy 对提交解析得出，使用 committer 时间 `2025-08-12T08:54:57Z`，不按 author 时间猜测。

**结论：**采用上游自有许可补齐提交，保留根与子目录 MIT 许可及版权。依据 [GNU 对 Expat/MIT 的说明](https://www.gnu.org/licenses/license-list.html#Expat)，此宽松许可可与 GPLv3 组合；无需更换算法、裁剪协议或维护 fork。

## 修改范围与结论边界

上述两项通过应用模块的显式间接依赖要求选中，不新增 replace，也不改 mihomo 源码。实施时工作区完整模块图为 178→178，只有这两个版本改变。该数字是当次结果，不是未来升级的固定数量或实际链接模块数。

两项“仅许可材料变化”的结论来自实际旧／新归档比对，不仅是提交标题。代码相同不保证产物字节相同，Go buildinfo 等会改变。此结论解决的是这两个固定依赖的已知疑点，不授予其他版本授权，也不能替代最终 APK、对应源码和分发渠道的核查。

## mihomo 与依赖升级流程

1. **先核对基线。** 读取本文、锁定文件及 NOTICE；比较实际解析图与 replace。不能仅因 mihomo 自身标 GPLv3，就推定其所有依赖适用于当前组合。
2. **保留必要版本要求，但不永久冻结。** 不因两项为 indirect 就删除它们，也不将本文当成禁止更新的版本上限。若获批升级选中新版本，核对其实际归档仍有适用许可，更新证据及基线；不要机械降级到本文版本。
3. **逐项复核变化。** 回退、模块路径／replace 来源改变、许可缺失／变化，或源码变化超过本文范围时，旧结论不自动沿用。检查新增／变化的运行依赖；区分构建／测试工具、完整模块图、目标 ABI 依赖和实际产物。
4. **处理具体问题。** 优先查固定源码包、上游公开修正及维护者声明；未知不直接判不兼容，缺通知不直接推定无授权。不能靠改许可证标签、测试通过、个人兴趣或尚未公开发布忽略已知问题；也不默认把维护 fork 或联系权利人的负担转给用户。超出已批准升级范围的处置需说明依据并获得批准。
5. **同步法律材料。** 按实际选定版本更新 go.mod/go.sum、Go 通知、NOTICE 和本文；保留原版权、许可全文与适用通知。不得只改版本号而沿用不相符的材料。
6. **验证产物。** 执行受影响 Go 测试／vet 和双 ABI 构建，检查原生库 buildinfo、APK 随包许可与应用内可达性，核对固定版本对应源码及必要构建材料。缺口未解决不称已完成许可核查或分发就绪。

### 可复核命令与归档方法

在可信项目目录执行，不从下载解压目录启动解释器或构建工具：

```bash
GOTOOLCHAIN=local go -C native/mihomo list -m -mod=readonly all
GOTOOLCHAIN=local go -C native/mihomo mod download -json \
  github.com/rasky/go-lzo github.com/metacubex/chacha
GOTOOLCHAIN=local go -C native/mihomo version -m /absolute/path/to/libmihomo_bridge.so
```

升级前后分别保存 `list -m` 输出作差异比较；`mod download -json` 提供实际 Version、Sum、GoModSum、Zip 和 Dir。需要比较旧／新归档时，显式传入本文版本的 `module@version`，去除各自 `module@version/` 前缀后按相对路径比较文件集合及字节，另计算许可文件和 zip 的 SHA-256。不要将版本前缀差异误算为全部文件变化。

下载材料是非可信数据；每份下载／解压放独立空目录，读取脚本与材料分离，Python 使用 `-I`，不执行归档中的代码。Go 自有模块缓存按 Go 工具的校验和目录管理，不手动改缓存源码。APK 内逐 ABI 核对 `libmihomo_bridge.so`，并逐字节核对应用许可 assets 与源文件；`NOTICES.Z` 还须覆盖 Flutter／Dart／引擎材料。

本流程不授权发布。实际分发前仍按 [NOTICE 的对应源码要求](../NOTICE.md#二进制分发与对应源码)核对最终版本和渠道。
