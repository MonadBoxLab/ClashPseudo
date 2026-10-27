# Go与mihomo接入

应用通过mihomo公开API提供配置、策略、连接与诊断能力。版本以[Go声明](../../native/mihomo/go.mod)、[校验文件](../../native/mihomo/go.sum)及buildinfo确定；同步上游时复核受影响接口和行为，见[升级复核](../legal/dependencies.md#内核与依赖升级复核)。本项目维护应用衔接代码。

## 内核版本与依赖方向

包依赖为main→engine→configinput；main可直接用输入DTO。JNI、进程信任和RSS在main，合成／来源／字段存在性及缺省在configinput，唯一会话、累计基线和实际资源在engine。生产标签为cmfa,with_gvisor。

内核采用进程全局状态，应用持一个上下文。core lease由generation／configId／revision／composition／purpose表示，阶段为EMPTY／LOADING／READY／RELEASING／FAILED；VPN session独立表达接管，公开调用沿捕获身份执行。

## 合成与平台投影

[configinput](../../native/mihomo/internal/configinput)执行Compose及贡献来源计算，各文档独立解析锚点／merge key；片段为空时返回原字节，保留公开age解密。产品语义见[插件规则](../product/configurations.md#插件列表与合成)。

合成后按字段存在性补运行必需缺省，再调用正式parser和[平台检查](../../native/mihomo/internal/engine/platform.go)。false、0、空值保留显式含义；必要缺省包括tun.enable、mips栈、MTU1500、auto-route、dns.enable、profile.store-selected=false，模式沿[偏好规则](data-and-operations.md#模式与策略偏好)。

TUN／DNS／sniffer由正文决定，显式tun.enable=false可保存／预览，连接时在FD建立前拒绝。mips／gvisor／mixed／system按显式选择使用，工作副本只负责各资源的一次创建，对外投影保留实际配置。tun.dns-mode接受空值、disabled、native、hijack，并透传至外部FD的TunOptions；Android系统DNS由同一VPNSpec与VpnService.Builder承载，实际劫持目标沿tun.dns-hijack投影。

显式DNS、sniffer、profile及普通监听按公开能力接入，包括HTTP／SOCKS／mixed、SS／VMess／TUIC、listeners、tunnels、认证与TLS；端口0保持0。NTP作用于应用进程时钟，活动external-controller在VPN前按平台范围检查，预览保留配置及实际启动状态。

provider HTTP缺／空path时按公开GetPathByHash派生，显式安全path保留；HTTP／file路径均检查遍历、符号链接、业务和Tailscale身份的同路径／祖孙冲突。缓存与身份保留各自生命周期。

## 输入与接口预算

| 输入 | 独立预算与检查 |
| --- | --- |
| 主正文／启用片段合计／运行YAML | 各16MiB实际UTF-8 |
| 片段JSON | 128MiB |
| preparation options | 最终UTF-8 JSON16MiB，含完整ID／revision／mode组合 |

options保存完整输入身份并使用独立预算。Dart流式计数，在写输入或停止旧会话前拒绝静态超限；平台加入purpose／generation／network后核查最终UTF-8长度与surrogate合法性。

Android在JsonWriter及严格UTF-8编码后复核owner，JNI在回调安装和C复制前检查长度，Go继续校验编码、结构与解码。恰好上限的输入允许通过，增加1字节时拒绝；错误仅携带结构与原因。

## 上下文与预览

页面按需Prepare，普通总览、设置及最近日志读自身状态；PREVIEW仅创建查看能力所需资源。VPN先释放预览，再按本次socket保护重建上下文与连接资源。

预览真正不可见且无受理工作30秒后尝试释放，执行时复核身份和忙状态；可见失焦继续保留，释放已开始则等完成。实际调度受系统冻结影响，宽限内provider网络任务可能继续。逻辑Engine的观察窗口与预览资源分别回收。

创建资源立即登记Close，取消撤销新拨号及迟到启动，关闭TUN并取消所属任务；节点释放等待应用已受理I/O／URLTest等结束。失败／超时保留FAILED／UNKNOWN及关闭的复用门。

## 策略接口

[strategies.go](../../native/mihomo/internal/engine/strategies.go)投影实际组、provider成员、hidden、now／fixed、GLOBAL引用及恢复结果。普通读取为只读，选择沿Set／ForceSet并以UTF-8 JSON传值，偏好和内核缓存分别恢复。

StrategyCalls读／选／准备等待为3／10／45秒，迟到完成通知重读，VPN保留独立生命周期。URLTest走公开Proxy.URLTest，按对象身份接收结果，底层受理与真实退出独立核验；目标／并发／期限见[延迟测试](../product/runtime-and-strategies.md#成员浮窗与延迟测试)。

卡片、浮窗和详情共用StrategyImage。对所用flutter_svg版本的pending失败缓存，使用公开vector_graphics_compiler与BytesLoader适配；真实链在截短前定位type／icon，DIRECT／REJECT／REJECT-DROP按精确类型回退，URL整项按容量准入。

## 连接与流量接口

[ConnectionObserver](../../lib/src/features/connections/connection_observer.dart)约每秒完成一次再调度，失败按1／2／5／10／30秒退避，窗口归Dart。UI只读窗口，业务采样不由页面可见性决定；停止后记录过期且无工作时可释放逻辑Engine。

[connections.go](../../native/mihomo/internal/engine/connections.go)排除Inner，用容量1000的堆保留最近记录，再编码所需tracker。请求最多1000活跃ID加1详情，返回相应行、presence和完成标记；请求64KiB、行4KiB、响应8MiB。显示文本UTF-8安全截短并标记，身份／计数保持完整，扫描成本随tracker集合变化。

平台在受理、worker执行和结果交付时校验完整core identity与RUNNING状态。读取和关闭分别占用真实在途槽，平台等待3秒、Dart等待5秒；槽位在执行结束后释放。Get缺项记为absent，Close成功记为closed，错误记为failed，结果按原调用结算。

辅助规则在每行投影截短前读取完整host及真实DstIP，地址通过公开fake-IP校验。idna／publicsuffix确定含private规则的注册域边界；行内仅传完整host、suffixBoundary与单地址CIDR，Dart按边界展开全部后缀，保持4KiB行预算。窗口保留候选与观察时的完整core identity，后续缺少有效候选时沿用原记录；列表与额外详情使用同一投影。候选及来源随窗口序列化，历史记录保持原身份，规则目标沿当前有效快照读取。身份与保存规则见[辅助规则](../product/connections.md#从连接新增规则)。

Total／activeCount沿同次连接采样返回，TrafficWindow保留30秒／31点。新lease开放前捕获Total基线，热切换保留、完整重连重建；差分倒退或身份失效为不可用。速度取同源elapsedRealtime，样本年龄计往返与本地耗时，按5秒有效期核对。

RSS通过公开memory.GetMemoryInfo(os.Getpid())按实际页大小读取，口径为进程驻留及共享映射。它独立于VPN和逻辑Engine，读取失败为无效状态；其他图形或进程外资源按其所属工具观测。

## DNS与缓存

DNS经CoreReadCalls／JNI调用当前DefaultResolver.ExchangeContext，绑定core identity与networkEpoch；queryOwner／requestId记录取消水位。JNI及解析实际退出后清dnsBusy，业务写门保留独立作用域。

名称先核查字节预算，经DNS owner检查与实际wire打包；普通Unicode使用已声明IDNA，presentation转义交DNS库并检查十进制溢出。PTR IP转反向owner，其余合法owner保留语义。限额见[DNS规范](../product/diagnostics.md#dns查询)，原生解码峰值独立测量。

DNS清理捕获当次default及稳定system resolver，ClearCache返回后结算；fake-IP沿公开FlushFakeIP逐族确认，部分失败保留真实影响及未确认状态。

## 规则provider与Geo

domain／ipcidr通过公开Strategy().DumpMrs取得规范化运行集合；classical区分inline、缓存与声明，文件来自已加载Vehicle().Path()。来源／文件变化撤销分页，范围与完整性按公开结果表达。

节点行的sourceVersion来自所捕获proxy-provider的公开Version，主配置节点使用0并绑定完整core identity。规则sourceToken覆盖所属范围、完整行集合及来源，搜索与分页沿独立token校验。详情通过这些来源身份保留当前对象；改变查询条件后继续阅读所选内容，来源替换后保留最后快照并撤销旧动作。

provider更新沿公开接口，file重新加载／监视，inline采用内联内容；Geo调度由会话持有，手动／自动串行，home切换等真实I/O退出。缺损MMDB／ASN补齐可用DIRECT，后续更新回当前路由。Compose给逐键资格，经[Android安装](android.md#内置geo)后再ParseRawConfig。

资源数量、mtime、内核时间、尝试／成功检查／替换分别投影。运行配置为GetGeneral的实时JSON子集，平台TUN状态由Android接管接口表达。

## 日志与信任材料

日志使用Subscribe／UnSubscribe，在准备前订阅，释放时退订并排空。字段脱敏先于有界缓冲，UTF-8安全截断并标记，保留接收时间、会话和丢弃数。客户端级别过滤与内核全局等级分别管理。

Dart显式SecurityContext与Go标准fallback池使用同源根材料。Go进程设置x509usefallbackroots=1并在Apply边界reset公开CA；显式协议证书／pin、Tailscale baked roots仍有独立边界。Android根集合的API分支和精确异常见[证书接入](android.md#证书与平台限制)，数据原始许可见[许可依据](../legal/dependencies.md#公共数据资产)。

## 公开能力边界

以下列出已核查公开接口的资源与并发特征，版本变化时复核对应实现；应用为自身受理工作维护明确的结束屏障。

- 活动external-controller字段在运行接入校验中被拒绝。配置写入和Builder操作由应用统一业务链管理，相关原生接口的异步启动及生命周期按所用版本复核。
- WireGuard通过首次公开DialContext／ListenPacketContext延迟创建device，Stop关闭已经启动的节点。ParseRawConfig失败时调用者仅取得nil／error，其他解析分配仍按实际拥有权核查；[解析失败回归](../../native/mihomo/internal/engine/provider_cleanup_test.go)检查零worker泄漏并通过真实UDP使用验证Stop释放，[失败状态](../../native/mihomo/internal/engine/parse_failure_state_test.go)关闭未确认解析状态的复用门。当前[WireGuard初始化路径](https://github.com/MetaCubeX/mihomo/blob/v1.19.33/adapter/outbound/wireguard.go#L520-L605)在实际使用时登记并释放资源。
- provider Close、已派发listener／tunnel、DNS singleflight／Background刷新及NTP各有退出语义，公开返回值与应用登记屏障分别记录；gVisor初始化和部分共享监听状态另核查race。
- rule-provider自动writer可能与回调中的Strategy读取并发，TestRouteSetRealUpdatesOnlyRefreshChangedEffectiveRoutesAndInvalidateRevert覆盖strategy替换／读取，callback锁只保护其自身访问。
- fake-IP Pool.Lookup／LookBack使用私有mux，FlushFakeIP对offset／cycle的写入采用另一调用路径；分配、反查与清理的真实race由对应并发测试观察。DNS工作副本和私有filter各按其可取得接口核验。
- 日志等级、SetMode、select／url-test／fallback及delay history为共享状态，按真实公开调用与并发写者核验。
- InitGeoIP／InitASN可能原地删除或写入损坏库，Geo reader替换也有共享状态，应用补种与在线更新各自核查其实际作用域。
- cmfa采用公开标签所定义的路径行为；SSH私钥／TLS等引用沿内核文件能力执行，provider受管路径检查与平台沙箱分层生效。

各接口按[验证方法](../development/verification.md)记录实际调用、资源结果、并发状态和失败。
