# 依赖许可依据与升级复核

依赖更新同步声明、锁文件、第三方通知和对应源码。分发文件与源码取得方式见根[NOTICE](../../NOTICE.md)，许可原文位于[third_party](../../third_party)及根[LICENSE](../../LICENSE)。

## 当前版本与材料入口

| 要查的内容 | 入口 |
| --- | --- |
| Flutter／Dart声明与解析版本 | [pubspec.yaml](../../pubspec.yaml)、[pubspec.lock](../../pubspec.lock) |
| Go模块、替换与校验 | [go.mod](../../native/mihomo/go.mod)、[go.sum](../../native/mihomo/go.sum)及本次`go-modules.json` |
| Android依赖与实际选择 | [Android配置](../../android/app/build.gradle.kts)及本次`releaseRuntimeClasspath`报告 |
| 实际链接的Go模块 | 各ABI的`libmihomo_bridge.so`及`go version -m`输出 |
| 第三方许可与来源摘要 | [Go通知](../../third_party/notices/go.txt)、[Android通知](../../third_party/notices/android.txt)、Flutter `NOTICES.Z`及字体／数据通知 |
| CA与Geo来源、版本、大小和摘要 | [release 资源记录](../../third_party/data/resources.json)及本次资源源码清单 |

应用自有代码采用GPL-3.0-only。第三方版权、许可正文及随附通知随对应材料保存。依赖升级时，从声明和锁文件取得所选版本，再用解析图、原始归档及APK内容核对当次交付。

## go-lzo：GPL-2.0-or-later授权

所选go-lzo的README包含以下声明，[Go通知](../../third_party/notices/go.txt)保存该原文及LICENSE.gpl：

> Being a straightforward port of the original source code, it shares the same
> license (GPL-2.0-or-later) as I can't possibly claim any copyright on it.

升级时检查新归档的README仍含GPL-2.0-or-later声明，并保留GPLv2正文和该授权声明。Go通知记录所选版本、模块Sum、GoModSum及归档SHA-256；go.sum记录模块与go.mod的校验值。[维护者回复](https://github.com/rasky/go-lzo/issues/15#issuecomment-6128639788)、[LZO项目](https://www.oberhumer.com/opensource/lzo/)及[GNU组合说明](https://www.gnu.org/licenses/gpl-faq.en.html#v2v3Compatibility)提供授权与组合依据。

## chacha：根MIT许可

所选chacha模块的根LICENSE采用MIT，包含Copyright (c) 2016 Andreas Auernhammer及Copyright (c) 2025 MetaCubex。[Go通知](../../third_party/notices/go.txt)同时保存根LICENSE和chachapoly1305／poly1305子目录许可。升级时逐项收集这些原文，更新模块Sum、GoModSum与归档SHA-256；伪版本由Go proxy按提交时间解析。MIT与GPLv3的组合说明见[GNU许可列表](https://www.gnu.org/licenses/license-list.html#Expat)。

Go模块中显式选择go-lzo与chacha的许可版本。更新后检查这两项要求、protobuf replace及工具链声明，再对照原生buildinfo中的实际选择。

## AndroidX WorkManager及传递依赖

androidx.work:work-runtime的所选POM声明Apache-2.0。Room、SQLite、startup-runtime、tracing、concurrent-futures-ktx、lifecycle-service、collection、annotation-experimental及协程等依赖按本次`releaseRuntimeClasspath`选择收集。[Android通知](../../third_party/notices/android.txt)保存坐标、POM、运行归档、源码归档、SHA-256及许可原文。

升级时检查[WorkManager版本资料](https://developer.android.com/jetpack/androidx/releases/work)的minSdk要求，再将APK内的法律资产与本次通知比较。在项目Android配置中核对当前minSdk。

## YAML编辑依赖与编辑器修改

yaml与yaml_edit通过hosted声明接入，应用使用span／SourceEdit处理编辑。其版权和许可由Flutter构建流程合入`NOTICES.Z`，校验APK时与独立构建生成并解码的NOTICES逐字节比较。

re_editor的本地源码位于[third_party/sources/re_editor](../../third_party/sources/re_editor)。MIT原文、官方归档SHA-256、补丁及上游PR #118关系见[PATCHES](../../third_party/sources/re_editor/PATCHES.md)和[LICENSE](../../third_party/sources/re_editor/LICENSE)。该源码包含生命周期管理、编辑提交检查、IME处理及默认关闭的测试状态记录修改。升级时逐项核对补丁所用接口；改用hosted版本时，以编辑、IME和生命周期测试检查对应行为，并更新PATCHES及通知。

## 文件导入与cross_file

cross_file固定为0.3.5+5，声明与归档摘要分别见pubspec.yaml和pubspec.lock。配置及插件导入由自有Android SAF接入负责选择、后台有界读取和FD关闭；Dart仅用XFile.fromData承载已读取的bytes，并复用流式字节检查及严格UTF-8解码。file_selector及其平台实现已移除，cross_file不承担系统选择器或外部文件缓存。cross_file的许可原文随所选Pub源码保留，并由Flutter构建流程合入NOTICES.Z；升级时核对实际使用的XFile接口及随包通知。

## Dart覆盖率开发依赖

coverage为hosted开发依赖，供[采集工具](../../tool/coverage/flutter.dart)和测试配置使用，采用BSD-3-Clause，Copyright 2014 the Dart project authors。实际版本及归档校验见[pubspec.lock](../../pubspec.lock)。

其传递依赖中的args、async、cli_config、cli_util、collection、ffi、file、glob、logging、meta、package_config、path、source_maps、source_span、stack_trace、string_scanner、term_glyph、vm_service保留各自Dart project authors的BSD-3-Clause原文、年份和免责声明；yaml采用MIT。分发采集工具或这些依赖时，一并提供所含材料的原始许可。

## Android覆盖率测试依赖

[Gradle测试配置](../../android/app/build.gradle.kts)启用JaCoCo。agent／core／report／ant JAR包含Mountainminds GmbH & Co. KG的about.html及EPL-2.0；agent／ant随附ASM包含INRIA／France Telecom的BSD-3-Clause，report／ant的Google Code Prettify包含Mike Samuel et al的Apache-2.0。版本和归档摘要从当次Gradle解析图取得。

JNI source coverage使用所选NDK的compiler-rt profile runtime。分发测试APK、采集工具或报告时，收集实际包含的JaCoCo、ASM、Prettify及compiler-rt材料，并保留其版权、许可和源码取得方式。校验release APK时检查agent、插桩及profile runtime／sections的排除结果。运行与报告步骤见[覆盖率方法](../development/verification.md#覆盖率)。

## 公共数据资产

| 资源 | 来源与许可 | 项目材料 |
| --- | --- | --- |
| CA | curl Mozilla CA Extract，MPL-2.0 | [release 资源记录](../../third_party/data/resources.json)、生成的 certificates/cacert.pem 与 NOTICE、[MPL 全文](../../third_party/data/certificates/MPL-2.0.txt) |
| GeoIP.dat | V2Fly geoip，CC-BY-SA-4.0；DB-IP 输入采用 CC-BY-4.0 | [release 资源记录](../../third_party/data/resources.json)、[数据说明](../../third_party/data/geodata/README.md)、生成的归属通知 |
| GeoSite.dat | V2Fly domain-list-community，MIT，Copyright (c) 2018-2019 V2Ray | 同上及`GeoSite-MIT.txt` |
| Country.mmdb／ASN.mmdb | DB-IP Country Lite／ASN Lite，CC-BY-4.0，IP Geolocation by DB-IP | 同上及`CC-BY-4.0.txt` |
| Public Suffix List | 可编辑列表采用MPL-2.0，x/net的Go实现采用随附BSD许可 | [PSL通知](../../third_party/notices/publicsuffix.txt)、[可编辑列表](../../third_party/data/publicsuffix/public_suffix_list.dat) |

CA 按 release 记录中的带日期 URL 取得 PEM 及对应摘要，核对完整文件 SHA-256 和上游头部元数据。Geo 记录固定来源、版本／commit、处理步骤、存储与安装字节。五项 payload 在构建时生成至 `build/generated/bundled/assets/`；DB-IP 官方 gzip 分别使用 `dbip-country-lite.mmdb.gzip` 和 `dbip-asn-lite.mmdb.gzip`，安装时解压为 Country.mmdb 和 ASN.mmdb。

CC-BY-SA-4.0、GeoSite MIT、CC-BY-4.0 及 MPL-2.0 原文随材料分发。同次应用 release 准备同步资源记录、来源通知、署名、修改说明及 payload；普通构建只核验并消费固定输入。Android 证书使用方式见[证书与平台限制](../architecture/android.md#证书与平台限制)。

## 生产构建的Go链接依赖检查

对armeabi-v7a、arm64-v8a、x86_64分别读取`libmihomo_bridge.so`的buildinfo，检查Android目标架构、`cmfa,with_gvisor` tags、模块Version／Sum及protobuf替换，并比较三个ABI的依赖图。构建使用`x509usefallbackroots=1`。

下列模块的原文材料保存在[Go通知](../../third_party/notices/go.txt)：

| 模块 | 保留材料 |
| --- | --- |
| github.com/fxamacker/cbor/v2 | MIT |
| github.com/golang/groupcache | Apache-2.0 |
| github.com/google/pprof | Apache-2.0、AUTHORS、svgpan BSD |
| github.com/metacubex/gvisor | LICENSE内Apache-2.0／MIT／BSD、AUTHORS |
| github.com/metacubex/jsonv2 | BSD-3-Clause、AUTHORS |
| github.com/metacubex/tailscale | BSD-3-Clause、PATENTS、tempfork goupnp／oauth2 |
| github.com/metacubex/tailscale-wireguard-go | MIT |
| github.com/pires/go-proxyproto | Apache-2.0 |
| github.com/tailscale/peercred | BSD-3-Clause、AUTHORS |
| github.com/x448/float16 | MIT |
| go4.org/mem | Apache-2.0 |
| golang.org/x/term | BSD-3-Clause、PATENTS |

核对APK内的Go通知、Android通知、Flutter NOTICES及[Material Icons通知](../../third_party/notices/material-icons.txt)。字体材料采用CC BY 4.0，包含Google LLC署名及裁剪说明。

## 内核与依赖升级复核

[统一入口](../../tool/main.py)的 `dependencies check` 与 `dependencies apply` 默认检查应用依赖及 CA／Geo；Go／Flutter／JDK／SDK／NDK／Gradle／AGP／Kotlin 使用项目固定工具链。`check` 仅报告候选，`apply` 写回实际变化。`--scope mihomo --mihomo-version '<selector>'` 将 selector 交给 Go，记录实际解析结果，不额外查询 GitHub Release 来批准该输入。自动更新及发布步骤见[Android 分发](../development/build-and-test.md#android-分发与-github-actions)。

1. 用 `dependencies check` 查看候选，再执行 `dependencies apply --evidence /var/tmp/new-dependency-evidence` 更新输入并生成核验材料。无实际变化不递增版本；一次依赖与资源更新只将 patch 和 versionCode 各加一，详见[应用版本](../development/build-and-test.md#应用版本)。
2. 检查实际解析结果、protobuf replace 及 go-lzo／chacha 的许可来源。Go 通知按三个 Android 目标架构和生产 tags 收集模块，保存 LICENSE／COPYING、NOTICE、版权、AUTHORS／PATENTS、模块 Sum、GoModSum 及原始 zip 摘要；mihomo 根许可和可编辑 PSL 列表一并更新。
3. 对许可正文计算SHA-256，复用已有相同字节的识别结果；新增文本使用工具所选Google licenseclassifier识别。缺少原文时从该模块固定上游提交取得；遇到未知许可、缺少授权或组合冲突时，按报错给出的依赖、文件和摘要核对原文与授权条款，确定依赖选择后重新运行更新。
4. Pub按当前SDK可解析的hosted版本更新，保留SDK／path来源。Android按本次`releaseRuntimeClasspath`更新POM、运行归档、嵌套JAR、sources.jar及许可头。检查声明、锁文件与通知中的选择一致。
5. 构建通用版及三个分架构APK。用证据目录中的`go-modules.json`、`android-dependencies.txt`和独立构建生成并解码的`NOTICES`校验APK，分别检查各ABI的buildinfo，再准备对应源码、许可包及`SHA256SUMS`。

常用解析命令：

```sh
GOTOOLCHAIN=local go -C native/mihomo list -m -mod=readonly all
GOTOOLCHAIN=local go -C native/mihomo mod download -json '<module@version>'
GOTOOLCHAIN=local go -C native/mihomo version -m '<libmihomo_bridge.so>'
```

`download -json`输出中的Version、Sum、GoModSum、Zip和Dir用于定位原始材料。比较两份模块归档时，去除各自`module@version`目录前缀，再比较相对文件集合、字节和许可原文。APK的逐项核验步骤见[最终产物与许可](../development/verification.md#最终产物与许可)。

### 当前工作树的对应源码归档

在当前源码内容确定后，准备含`go-modules.json`、`android-dependencies.txt`、独立构建生成并解码的`NOTICES`的证据目录，以及下一节的固定资源源码清单和登记归档。将证据和输出放在仓库外，运行：

```sh
python3 -I -B tool/main.py artifacts package-sources \
  --project /path/to/frozen-project \
  --evidence /path/to/independent-evidence \
  --resource-sources /path/to/resource-sources.json \
  --output /var/tmp/new-sources.tar.gz
```

工具读取依赖解析结果、已安装工具链和依赖源码，并将应用当前文件写入`application.tar`。省略`--resource-sources`时从证据目录读取同名清单；省略`--commit`时打包当前工作树，包含Git跟踪文件与未忽略的新增文件，省略已删除文件。固定提交归档使用`--commit <commit>`，要求工作树干净。

输出包包含：

| 路径 | 内容与用途 |
| --- | --- |
| `application.tar` | 应用源码、补丁、生成输入、构建脚本、通知与许可 |
| `dependencies/go/` | 所选Go模块原始zip |
| `dependencies/pub/` | 已解析的hosted包源码 |
| `dependencies/android/` | Maven sources.jar及POM |
| `dependencies/data/` | 资源清单登记的固定来源归档 |
| `build-inputs/source-tree.json` | baseCommit、workingTree、dirty、应用tar摘要及逐文件大小／SHA-256／可执行位 |
| `build-inputs/version.json` | 应用版本、源码身份、Flutter与Go工具链 |
| `build-inputs/bundled/` | 当次 generated payload、资源 manifest、法律资产及生成定义 |
| `build-inputs/resources.json` | 同次 release 的工具链、依赖与固定资源记录 |
| 其他 `build-inputs/` 文件 | 解析图、NOTICES、CA／Geo manifest 及资源来源清单 |
| `README.txt` | 解包目录与构建入口 |

归档包含公开合成测试证书、私钥和测试keystore；排除本机SDK配置、签名配置、凭据、构建输出、`.claude`和`.codegraph`。遇到私有签名容器时报出文件路径；将该文件移出分发输入后重新归档。归档期间源码发生变化时，确定源码内容后重跑并选择新的输出路径。

核验时先比较分发包与`SHA256SUMS`，再比较`application.tar`与`source-tree.json`，逐文件对照本次源码。随后按解析图核对Go zip、Pub源码、Maven sources.jar／POM及资源归档，再比较APK buildinfo中的依赖与原始通知。

### 准备资源来源记录并校验安装后的文件

准备材料时以 `third_party/data/resources.json` 为固定输入，写回后核对 generated manifest 及 APK：

- 五项资源均记录 `kind`、`version`、`sourceUrl`、`encoding`、`storedBytes`／`storedSha256` 和 `installedBytes`／`installedSha256`。CA 另有 `checksumUrl` 与 `certificateRoots`；V2Fly 另有 40 位 `sourceCommit` 和许可正文摘要，GeoIP 保留补充 `sourceInputs`；DB-IP 另有 `sourcePage`。
- CA 的 APK 路径见 generated `certificates.json`；四项 Geo 的 `workName`、`asset`、署名、许可及修改说明见 generated `assets/geodata/manifest.json` 和配套法律文件。生成器从同一 release 记录取得版本及字节信息。
- DAT 的存储正文与安装正文相同；DB-IP 保存官方 gzip，安装时解压。APK ZIP 压缩大小另计。
- PSL 从实际所选 x/net 模块的 `publicsuffix/table.go` 读取 `git revision`；存在 `Replace` 时使用替换模块。核对通知中的模块版本、revision 及可编辑列表 SHA-256，并随包提供 MPL 全文。

APK 核验工具的 `--xnet-source` 填写上述有效 x/net 模块的原始 zip。模块下载和校验使用 Go；工具读取编译表记录的提交，并比较来源通知和可编辑列表。

#### 资源对应源码清单

将`resource-sources.json`与它登记的所有归档放在同一目录。清单使用`format: clash-pseudo-resource-sources`、整数`version: 1`，`sources`数组分别包含一个`geoip`和一个`geosite`对象。

| 字段 | 填写内容 |
| --- | --- |
| `kind` | `geoip`或`geosite` |
| `sourceCommit` | 同次 release 资源记录中的 40 位小写十六进制提交 |
| `sourceUrl` | GeoIP填写`https://github.com/v2fly/geoip/archive/<sourceCommit>.tar.gz`；GeoSite使用`domain-list-community`的对应固定提交URL |
| `file` | 清单同目录内的普通文件名；prepare生成`geoip-<commit>.tar.gz`或`domain-list-community-<commit>.tar.gz` |
| `bytes`／`sha256` | 该归档的实测正整数大小和64位小写SHA-256 |
| `inputs` | 补充输入数组，每项填写独立的commit、URL、文件名、大小、摘要及非空`description` |
| `processing` | 转换器、配置、补充输入与分发DAT之间的处理步骤 |

GeoIP主对象记录转换器源码，至少提供一份官方release数据归档作为补充输入，并填写处理说明。转换器的`config.json`合并DB-IP Lite Country MMDB、内置private和test列表，官方构建从同一次数据合并结果生成DAT与CIDR文本。GeoSite主对象记录规则源码；规则输入已包含其中时可省略`inputs`和`processing`。文件名全局唯一，同一kind中的各commit互不重复。

源码包将登记归档放在`dependencies/data/<kind>/<file>`，将原始清单放在`build-inputs/resource-sources.json`。GeoIP和GeoSite的许可原文分别位于`third_party/data/geodata/CC-BY-SA-4.0.txt`和`GeoSite-MIT.txt`；DB-IP归属及CC-BY-4.0原文一并提供。

单独准备固定源码时，从同次 release 记录的 `resources` 复制 `geoip` 与 `geosite` 完整记录，以 kind 为键组成 `fixed-geo-specs.json`；保留 GeoIP 的 `sourceInputs`，逐项核对数据归档的 `sourceCommit` 和 `description`。运行：

```sh
python3 -I -B tool/main.py dependencies prepare-resource-sources \
  --spec /path/to/fixed-geo-specs.json \
  --project /path/to/project \
  --destination /var/tmp/new-fixed-source-materials
```

成功输出的`sources`指向`resource-sources.json`。再次使用同一准备目录时，先校验真实归档的固定commit、URL、规范文件名、字节数与SHA-256，并拒绝额外文件；通过后按本次明确的inputs／processing重建规范metadata，以临时文件、fsync和replace原子发布。仅说明变化不重新下载归档，metadata相同则不重写；发布失败保留旧manifest，处理失败原因后可重跑。归档身份或字节不符时拒绝复用，核对固定记录后使用新的空目录。

新资源候选采用本次解析的补充输入及处理说明。固定release的CLI和源码包准备从release顶层`sourceInputs`清单透传冻结的description与processing，不用后来代码中的默认文字覆盖；最终继续严格比较完整metadata与冻结清单，包括大小、摘要、路径和说明。缺少GeoIP补充输入时，补齐该次数据来源记录后重跑。

#### 发布材料与重跑

`Dependency release` 在同一候选提交上完成正式签名的四 APK 构建和源码打包。源码包使用候选提交，版本、tag 与 Release 的 Source 指向同一输入；许可包及 `SHA256SUMS` 与四包一并上传。发布类型由 workflow 默认值或本次手动选择决定，两种类型都使用 release variant。

发布 job 失败时重跑失败 job，继续使用原 artifact 中的 Git bundle 和构建材料。tag 已指向本轮候选时继续上传草稿；已公开且资产一致时结束，不改写已公开字节。基准在首次推送前改变时重新准备候选；artifact 过期则按失败报告处理缺失材料，不重建另一批字节替代原产物。

本地回退实验在独立源码副本中执行 `dependencies apply --scope mihomo --mihomo-version '<selector>' --reuse-version`，保留应用版本及非 Go 输入，使用 debug APK 验证生产 native 接入。分发签名及四个 release APK 的实际结果从配置了 Secrets 的 Actions 运行取得。入口及启停见[自动更新与发布](../development/build-and-test.md#自动更新与发布)。
