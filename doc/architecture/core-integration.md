# Go与mihomo接入

所有Go与mihomo调用均位于Android的`:core`进程，包括纯合成、解析、预览、运行、更新和诊断。默认进程由AppRuntime发起统一请求，经CoreClient、非导出AIDL及受限FD进入CoreService；JNI只做同进程FD交接、公开调用及系统callback。进程与业务部署见[应用架构](overview.md)，Android资源见[宿主接入](android.md)。

依赖版本查[go.mod](../../native/mihomo/go.mod)、[go.sum](../../native/mihomo/go.sum)及各ABI的buildinfo；生产标签为`cmfa,with_gvisor`，升级操作见[依赖复核](../legal/dependencies.md#内核与依赖升级复核)。

## Core version and dependencies

| 包／入口 | 职责 |
| --- | --- |
| main与JNI | 固定操作码分派、FD交接、进程信任、系统callback及完整native回执 |
| [engine](../../native/mihomo/internal/engine) | 唯一装载context、公开调用及本次实际资源收尾 |
| [configinput](../../native/mihomo/internal/configinput) | Compose、字段来源、字段存在性及必要缺省 |
| [coreview](../../native/mihomo/internal/coreview) | 读取公开内核对象，投影业务字段并逐条导出 |
| [androidnet](../../native/mihomo/internal/androidnet) | 平台规格、捕获的底层网络与系统DNS |
| [ingress](../../native/mihomo/internal/ingress) | 公开监听与TUN构造的必要参数、protect及实际资源登记 |
| [logstream](../../native/mihomo/internal/logstream) | 公开日志订阅及有界传输queue |

main调用engine，engine复用其余协作包。AppRuntime持有业务保存、实际运行输入、策略恢复、DNS操作、测速批次、搜索分页及观察窗口；这些状态不在Go建立第二份。

mihomo负责解析、协议、规则匹配、provider下载／解密／缓存、Geo、resolver及内部调度。应用通过公开接口接入这些内核依赖，不修改其上游源码、不维护patch或fork、不复制或替换内部实现；只修复自身的接口调用、平台适配、状态与lifecycle。公开入口中的失败保留实际结果及原始错误，上游修复随依赖版本更新引入。

每次验证把实际依赖版本、固定输入、复现条件、原始错误及结果保存在当次构建／验证报告，旧报告保留原结论。接入文档维护职责、公开接口及验证方法；re_editor的本地适配另见[PATCHES](../../third_party/sources/re_editor/PATCHES.md)与[NOTICE](../../NOTICE.md)。

## Compose and Android configuration

[configinput](../../native/mihomo/internal/configinput)执行用户明确启用的Compose。AppRuntime决定正文、片段顺序、role及来源身份，纯合成函数不选择插件、不保存业务文件、不持有内核会话。没有启用片段时返回原始字节；有片段时按合成目标处理映射、别名与merge key，保留独立引用、标量类型、值和顺序。修改锚点字段时其他别名引用保留原值。具体合并语义见[插件规则](../product/configurations.md#插件列表与合成)。

自有Compose只在实际递归合并双方映射时检查当前递归栈：以merge key展开前的原始解引用节点pair为身份，重复进入同一pair即返回合成错误，退出时释放。正常共享子图、未触碰的循环和单侧循环不因此被拒绝；不做全树预检，也不改变mihomo解析行为。

合成与来源计算不执行额外age解密，不读取或保存密钥。age-secret-key及provider的url、path、header、proxy、interval、size-limit等字段原样进入mihomo；下载、解密、格式解析和缓存均由公开provider实现。主配置及插件继续沿应用原有导入、下载和保存流程，不借用provider参数新增订阅协议。

必要VPN缺省只在同一个RawConfig上补tun.enable、dns.enable及MTU1500，不复制上游mips和auto-route缺省，不为补缺省重编码正文。false、0、null和显式空值保持正式parser及平台接入的实际含义。没有本次明确模式意图时不注入mode，不改写profile；模式优先级见[偏好规则](data-and-operations.md#模式与策略偏好)。

显式tun.enable=false仍可保存或预览，请求VPN时在Builder建立前拒绝。mips／gvisor／mixed／system交公开TUN构造，不因失败自动换栈。DNS、sniffer、profile、普通监听、认证及TLS沿公开能力执行；端口0保留0。interface-name、普通routing-mark和TFO不因应用预设被一概拒绝，Android实际限制关联具体字段和系统结果。

provider HTTP缺少或空path时沿公开GetPathByHash派生，显式path和Tailscale state-dir沿公开Resolve／IsSafePath处理。生产cmfa的公开IsSafePath允许home以外路径，实际访问受Android应用沙箱限制；用户确认的[清理范围](android.md#内核数据清理)仍限定于内核根内的具体文件。

provider的path与内核cache、Geo数据库或协议身份路径重合时，多个上游组件可能按不同格式处理同一文件，导致文件替换或加载失败。为各类数据使用独立路径；file provider的原文也应避开公开PATHS返回的cache路径。

## Parse and apply

每个core process只装载一个PREVIEW或RUNNING context。processId、generation、inputId、configId、revision、composition及purpose关联本次装载；RUNNING须提供有效generation和composition，分别记录VPN和局域网意图及实际状态。Engine一经尝试准备便不再用于第二次装载，解析失败、正常停止及完整重载均使用新进程，不在原mihomo全局状态中重新准备。

AppRuntime在发布输入、结束旧进程及Handshake前检查saved choices和静态预算。Go的PREPARE只接收request、config、overrides及options，不再接收整份choices；策略恢复在公开profile装载后通过单项StrategySelect完成。

装载顺序：

1. `:core`取得数据资源锁，接收默认进程发布的不可变inputId，捕获本次底层Network及本地地址，安装socket保护、系统DNS、信任和日志callback。
2. 执行一次Compose及来源计算，再调用一次config.UnmarshalRawConfig；利用字段存在信息在同一RawConfig上补必要缺省。
3. 在parser／provider启动前调用公开路径getter发布实际Geo文件清单，按目标缺失及随包来源条件安装资产，再调用一次config.ParseRawConfig。解析副作用均发生在`:core`；失败保留原始错误并结束该进程。
4. 保留请求配置及已解析结果，另建本次装载的工作副本。PREVIEW关闭外部Controller／DoH、UI下载、普通监听、named listeners／TUN、tunnels、DNS外部监听、TUN及NTP；仍初始化代理、规则、provider、hosts、DNS和profile。
5. RUNNING工作副本延后Android需要接入的TUN、普通HTTP／SOCKS／mixed、Shadowsocks／VMess／TUIC、tunnels及DNS监听，保留待启动参数。命名监听注入必要ListenConfigForAPI；本功能管理的地址在唯一完整解析前确定，不在Base缓存地址后改写Listen。
6. 仅调用一次hub.ApplyConfig(work)。该入口内部已经执行applyRoute及executor.ApplyConfig(work,true)，不再另调executor.ApplyConfig、hub.Parse或手动provider.Initial。Controller、UI、NTP、profile及其余资源沿公开流程执行。
7. 对延后普通监听逐项调用一次公开构造器，DNS调用一次dns.ReCreateServer；PREVIEW不执行这些外部服务。按用户geo-auto-update调用公开RegisterGeoUpdater，每个装载进程至多一次。
8. 请求VPN时，根据同次已解析TUN生成Builder规格，取得实际PFD独立副本，再调用一次公开sing_tun.New；分别记录实际TUN、VPN接管及各监听结果。
9. 上游profile完成恢复后，AppRuntime执行一次应用策略恢复并读回结果。装载、选择恢复、保存及整体结果分别反馈。

hub.ApplyConfig没有整体错误返回。provider.Initial、Controller、NTP及外部UI仅经日志报告的错误继续保留，不把Apply返回当作全部服务成功。运行配置读取 `GetGeneral`，按与 Clash REST API 相同的 JSON 字段和值转换为 YAML；平台实际持有的 TUN 和监听状态通过准备结果及运行快照反馈。独立公开构造器持有的对象不一定登记在上游全局 getter 中，不用请求端口替换 getter 原值。

## Input and transport limits

跨语言常量来源为[application contract](../../contracts/application.json)，framing及生成检查见[通信contract](../development/build-and-test.md#core-ipc-contract)。

| 输入或传输 | 独立预算与检查 |
| --- | --- |
| 主正文／启用片段合计／运行YAML | 各16MiB实际UTF-8 |
| 片段JSON | 128MiB |
| preparation options | 最终UTF-8 JSON16MiB，保留完整输入组合 |
| Binder小型控制 | 64KiB，不承载正文或完整大集合 |
| single frame／单记录 | 8MiB，不是集合总量上限 |
| 运行配置 YAML 的 JSON 编码结果 | 64MiB，超过时返回 resultTooLarge |
| 排队字节 | 16MiB，满后backpressure |

Dart在发布运行输入或停止旧进程前检查静态预算；Android加入本次平台字段后复核最终长度和编码，JNI在转移资源前检查参数，Go以实际接收字节再次核对。正文、片段和options分段传输，不将整份正文base64扩展后塞入控制JSON。恰好上限允许通过，上限加1拒绝，编码及解析错误保留原因。

JNI统一使用NativeCore.invoke(operation, requestId, input, output, tun, callbacks)。input／output及可选tun均为同进程PFD对象，先完整验证再detach；Kotlin保留原资源，Go接收独立副本后负责其lifecycle。取消及shutdown使用固定操作码，原调用的取消结果与实际退出仍分别记录。

结果包含消息、原始错误、cancelError、stale和exited。管道关闭不证明原调用退出；只有实际返回或对应process death才能结束等待。旧身份回执不能改变新进程状态。

coreipc.Failure保留typed error、RawCause及errors.Join中的每个cause；平台callback的cause、suppressed、stack和未知错误字段按原结构传递。结果FD的TERMINAL与JNI实际返回的native receipt分别保存，写入TERMINAL或关闭FD失败也进入receipt。Android通过独立receipt／details PFD传输错误及回执，Dart的CoreCall将nativeReceipt放在结果顶层；结果读取失败后仍等待真实退出，并同时保留读取错误、取消结果及cancelError。业务诊断只投影所需字段；未知或不属于该操作的request part拒绝。单frame预算不用于截断完整错误或所有DATA的合计，响应另沿具体操作的预算检查。

## Listeners and TUN

普通监听使用公开NewWithConfig／NewUDPWithConfig系列、sing_shadowsocks.New、sing_vmess.New、tuic.New、tunnel.New／NewUDP；URL参数交对应上游解析函数。必要平台ListenConfig先转交inbound.NewListenConfig创建真实socket，再执行protect并登记原始资源；认证、TFO、协议和UDP转发仍由上游实现，不编写Accept、DNS处理或代理报文循环。

本应用 VPN 用途在 parser／provider 启动前取得 VpnService 资源宿主：入站调用 protect，出站先 protect 再绑定本次捕获的 Network。LAN-only／PREVIEW不创建 VpnService 或申请 VPN 授权，不调用 protect，出站仍绑定捕获 Network；跳过 protect 不登记为已保护。入站不绑定默认上游 Network。命名 C.InboundListener 仅做必要转交观察，由唯一 Apply 调用原 Listen 一次，保留实际返回。逐地址 TCP／UDP 组合中某项失败时关闭该项已取得的资源，分别返回结果；bind 成功、完整 Serve 就绪和另一端真实可达分别验证。redir／tproxy 等无相同注入点的入口沿公开装载返回实际权限及启动结果，不新增应用重定向实现。

命名listener仅在原Listen成功后交接protocol对象；Listen失败时回滚ListenConfig已经捕获的sockets，不调用尚未启动的protocol.Close。已经交接的资源按实际取得顺序反向关闭，重复关闭使用同一回执，startup及多个cleanup错误通过errors.Join保留。资源状态分别记录bound、failed和closed，bind成功不表示完整Serve已就绪。

TUN使用公开sing_tun.New(platformTunOptions, tunnel.Tunnel)，平台副本的FileDescriptor为当前`:core`持有的正数FD，AutoRoute与AutoDetectInterface为false。Android路由交Builder，网络选择交捕获Network；system／mixed使用公开EnforceBindInterface，不自组tun.New、handler、NewStack或stack.Start。

Builder路由范围复用公开tun.Options.BuildAutoRouteRanges(false)。计算前检查显式及provider include routes所需的address family；Android规格无法承载时返回具体字段错误，不让公开计算过滤后的结果掩盖该项请求。MTU缺省1500，显式0沿公开有效值9000交Builder，其他合法显式值保持一致。DNS地址与劫持判断包含公开TUN自动加入的相邻地址，不只检查原dns-hijack列表。UsesSystemDNS同时反映显式system依赖及Builder DNS的系统回退，route-set规格刷新沿相同规则。provider引起实际Builder规格变化时通知AppRuntime按原实际输入更换进程，不另做规则匹配。

用户裸file-descriptor不作为当前平台资源，不能指向任意整数。公开构造失败时保留原始错误并结束进程，不猜测内部关闭状态而重复关闭同一整数。实际VPN接管成功前不发布VPN运行。

用户external-controller、外部UI及DoH仍经公开hub启动，应用内部不连接这些端口，也不新增HTTP／DoH服务。保留cmfa默认embedMode，不调用SetEmbedMode(false)。Controller的TCP创建没有公开protect注入点；自身UID纳入VPN时的可达性按实际结果记录，不强制该UID绕过VPN。所缺公开能力通过后续上游升级获得。

## Context and PREVIEW

| 需求 | 内核动作 |
| --- | --- |
| 策略、节点、规则、资源或DNS需要实际对象 | 按需装载PREVIEW，不申请VPN权限或接管流量 |
| 总览、普通设置、已有日志及连接历史 | 读取所属状态，不为采样创建内核 |
| 开始VPN／局域网、完整重连或预览转运行 | 结束旧进程，用本次确定输入装载新进程 |
| 模式／策略热操作 | 使用当前context，读回实际结果 |

PREVIEW页面不可见且没有已受理工作持续30秒后结束该进程，检查原身份、可见性及工作持有；页面只是失焦时保留。日志页先显示已有窗口，无窗口时按需准备PREVIEW；停止后的窗口继续阅读，查看或清空旧窗口不启动内核。

资源创建后立即登记收尾。停止受理后不发起新任务，已经开始的DNS、URLTest、资源更新及应用文件I/O等待自身实际返回或所属process death。公开 Fetcher.Close 只有取消、没有全部后台任务的 join 回执；dns.Resolver.ExchangeContext 可先返回 ctx.Err，内部 singleflight、刷新和重试也没有公开 join 回执。exited 只证明本次所请求的公开调用及 JNI 实际返回，不表示全部 provider 或 DNS 后台任务结束。Android rawQuery 的取消与 callback 实际退出另行登记。进程替换和清理以对应 DeathRecipient 及本地 I/O 结束为界，细节见[Android准备与停止](android.md#准备与停止)。

## Strategy API

[coreview/nodes.go](../../native/mihomo/internal/coreview/nodes.go)逐组导出名称、类型、hidden、icon、now／fixed、成员、来源及identity；[coreview/strategies.go](../../native/mihomo/internal/coreview/strategies.go)读取公开组状态与GLOBAL引用。策略记录不附带完整raw JSON，Dart策略快照只保留交互所用字段。普通读取为只读；select沿Set，url-test／fallback固定或恢复自动沿ForceSet，load-balance保持只读。

策略保存及恢复由AppRuntime的StrategyActions协调。profile.store-selected保留上游恢复语义，应用choices随后按组类型执行一次并读回；Go不重写运行输入正文或维护第二份恢复状态。恢复请求携restore:true，执行同一公开selector操作但不写selected cache；显式用户选择成功且profile.store-selected启用时，才调用公开cache的SetSelected。组缺失、类型不符或成员消失由AppRuntime保留对应恢复结果；显式选择成功后清除该组的未恢复记录。请求始终捕获完整进程／输入身份，来源变化设置stale，原始结果与读取错误均保留。

AppRuntime组织测速批次、既有并发、期限、进度和结果。Go每次仅调用指定proxy的公开URLTest，保留该次context和取消函数至实际返回。取消停止后续调度，取消结果与原调用退出分别确认；卡片和浮窗读取同一批次，不重复执行。目标及期限见[延迟测试](../product/runtime-and-strategies.md#成员浮窗与延迟测试)。

图标、列表和成员浮窗是UI职责，继续共用StrategyImage。SVG经vector_graphics_compiler编译后由BytesLoader显示，失败保留错误并用默认图标。位图最多1MiB，SVG最多256KiB；下载核对声明长度及实际累计字节。

## Connections and traffic API

[ConnectionObserver](../../lib/src/logic/connections/connection_observer.dart)约每秒完成一次采样再调度，失败按1／2／5／10／30秒退避。窗口、差分及历史属于AppRuntime，采样包括实际VPN和局域网转发；连接页面不为查询建立PREVIEW。UI读取同一窗口，停止后可继续查看失活记录。

观察及详情保留各自owner：retainObservation登记持有者，recentConnections及clearInactiveConnections用detailOwner保留额外详情，releaseConnectionDetail只释放对应owner。LogicEngineHost等待业务回执和实际工作结束后判断业务Engine是否空闲。

[coreview/connections.go](../../native/mihomo/internal/coreview/connections.go)从公开 tracker 读取连接，投影标识、时间、流量、代理链、规则、地址及辅助规则所需字段，排除 Inner 记录。请求最多1000活跃 ID 加1详情，请求64KiB、响应8MiB包含封装；按实际保留和传输的内容计量并报告遗漏。AppRuntime 窗口保留1000活跃、500已结束、额外1详情，失活最长15分钟，投影内容 UTF-8 合计8MiB。容量遗漏或读取失败不推断连接已断。

读取与关闭分别限制并发，旧请求归原processId及输入。Get未找到返回absent，Close成功返回closed，关闭错误返回failed。业务先显示未确认时仍等原调用退出，期间同类请求合并为最近一次，不启动重复工作。详情保留最后snapshot、文字选择与阅读位置，来源失效只禁用对旧对象的修改。

辅助规则从完整host及非fake-IP的DstIP生成，不改写metadata。idna／publicsuffix提供含private规则的注册域边界，AppRuntime保留候选及原采样身份，UI在边界内展开后缀；后续无有效候选时保留原候选。提交检查见[连接辅助规则](../product/connections.md#从连接新增规则)。

Total与activeCount来自同次采样，TrafficWindow保留30秒、31个点。AppRuntime以新进程／context重建基线，热切换保留；累计倒退或来源失效使该次差分不可用。速度使用同源elapsedRealtime间隔，5秒有效期计入往返及本地等待。

应用内存由默认进程ProcessInfo.currentRss读取；内核经已有隔离连接调用公开memory.GetMemoryInfo(os.Getpid())，按实际页大小取得相同类别数值，不要求已装载Engine或VPN。两项分别持有请求、采样时点、错误、5秒有效期及刷新任务，不与流量请求相互等待。内核采样前后复核processId，来源变化或读取失败只使内核项失效，应用项继续刷新；没有core process时不为采样创建进程。总览只显示“应用”和“内核”两项，不加总；界面形式见[运行与策略](../product/runtime-and-strategies.md)。

## DNS and cache

DNS操作、超时和取消归AppRuntime，经统一请求调用当前DefaultResolver.ExchangeContext。queryOwner／requestId仅取消其对应请求；结果、查询错误、cancelError、stale及实际exited分别返回。消息和错误可以同时存在，不因错误丢弃响应。

名称先检查字节数，普通Unicode标签使用IDNA；文本转义和DNS名称语法交DNS库，十进制转义检查单字节范围。PTR的IP输入转反向名称，普通ASCII保留大小写。结果保留实际 Question、RCODE、耗时及 Answer／Authority／Additional 的记录字段。名称最多1024 UTF-8字节，请求4KiB，含身份的结果256KiB；三个记录区合计最多512条RR。内核期限5秒、平台期限6秒，结果超限整条拒绝并保留对应错误详情。

清理DNS缓存捕获当次默认及系统resolver对象，等ClearCache返回后记录结果，不声称清除Android系统缓存。fake-IP调用公开FlushFakeIP并保留聚合错误，没有完成回执的地址族仍未确认。来源变化不改写已完成结果，而是另注stale。展示与确认见[DNS规范](../product/diagnostics.md#dns查询)。

### Android system DNS

每个装载进程捕获一个非VPN Network、handle、DNS地址、privateDnsServerName、isPrivateDnsActive及revision，在ParseRawConfig前安装系统解析与socket callback，查询不改取最新网络。

- API29及以上适配公开DNS客户端，经dns.NewResolverFromClient安装resolver.SystemResolver。Pack／Unpack交DNS库，Android使用捕获Network的DnsResolver.rawQuery字节数组接口、FLAG_EMPTY、独立callback执行器及CancellationSignal，保留完整字节、RCODE、DnsException.code、cause及suppressed。
- API24—28适配公开resolver.Resolver的主机地址查询，调用Network.getAllByName并按地址族筛选。ExchangeContext／ECH等无公开原始消息能力的操作返回具体错误，不把地址数组拼为含TTL／RCODE的报文。该系统调用没有取消参数，取消等待不能证明底层退出。
- 显式nameserver: system仍走上游独立systemClient，不展开或替换。dns.UpdateSystemDNS只初始化一次：无私人DNS时传底层IP:53；严格模式、私人DNS已启用或无网络时传nil，不给该客户端提供明文目标。
- ParseRawConfig后检查启用DNS的nameserver、fallback、default-nameserver、proxy-server-nameserver、direct-nameserver及两类policy中的system。私人DNS组合不兼容时，在Apply前返回具体字段及能力错误；用户独立DNS不被统一拒绝。
- 代理内部自行创建的systemClient沿相同空服务器snapshot返回上游实际错误，不包装或替换dns.ParseNameServer。当前依赖没有给该客户端注入Android rawQuery的公开接口，完整支持需后续升级。

失败不转UDP或公共DNS，不增加应用UDP resolver，不在网络变化时热写上游无同步系统服务器列表。底层Network、DNS或私人DNS主机变化时，AppRuntime按实际运行输入更换进程，旧查询仍归旧进程。API28默认主机查询可走Android私人DNS，原始消息能力仍不可用；系统主机查询、显式system和VPN客户端DNS转发分别验证。

## Rules, providers and Geo

主规则及sub-rules来自公开cfg.Rules／cfg.SubRules。provider及sub-rules的声明顺序使用同次合成提取的metadata，不按名称重新排序，也不在Go保存第二份运行YAML。domain／ipcidr规则集使用Strategy().DumpMrs，inline provider公开JSON提供payload；远程／文件classical公开JSON只有元数据，不提供完整运行枚举。应用不重读Vehicle.Path后重新解析text／YAML来补运行规则，原文来源与实际运行内容分别显示。

集合通过FD逐条导出业务记录并以complete terminal frame结束。AppRuntime逐条关联provenance与捕获的本地直接定义，在完整stream后补入未关联原文，再统一搜索、计数和分页，只保存当前页及必要关联集合；offset／limit、查询和本地snapshot不进入Go。分页身份包含native token及本地snapshot，来源与精确写入规则见[来源与本地编辑](data-and-operations.md#来源与本地编辑)。provider下载成员不授予本地编辑权，main／sub-rules／provider内容各守原scope。

开始与结束核对进程、组合及provider公开Version／Strategy身份，terminal state保留来源、实际记录数、complete及stale。来源中途变化或缺terminal state时保留已读内容但不能发布完整页，单条超限返回错误而非静默截断。DumpMrs callback允许取消，公开实现内部收集及排序仍由上游执行。

RESOURCES同样使用METADATA、逐条RECORD及TERMINAL，不把完整provider／Geo集合放入Binder status。provider的Vehicle.Path仅作为公开原始信息返回，不作为文件清理候选。PATHS调用C.Path.Cache／GeoIP／MMDB／ASN／GeoSite，只返回五项实际路径及平台补充的home，不创建context。AppRuntime将根内路径去重为相对paths清单，平台保存每项completed和error；结束旧进程、等待本地I/O并取得独占资源锁后，才逐项删除。路径保留公开getter实际选中的名称及大小写。

节点sourceVersion使用本次proxy-provider公开Version，主配置节点使用0并绑定完整输入身份。provider刷新、对象替换和查询条件变化分别使旧查询失效；详情保留最后snapshot，禁用旧对象修改。更新调用及更新后的列表读取分别报告，不用后一次读取失败撤销已确认更新。

provider加载、下载、缓存和刷新沿公开接口。四类Geo手动更新分别调用updater.UpdateMMDB／UpdateASN及对应GeoIP／GeoSite入口，下载、验证、替换及reader管理交上游。自动更新只使用公开RegisterGeoUpdater，不增加逐库到期、启动检查或重试调度。随包Geo与默认根材料的固定来源及大小摘要见[resources.json](../../third_party/data/resources.json)，payload、安装metadata及常量由构建生成到build/generated/bundled；Geo按缺失及来源条件经[Android安装](android.md#内置geo)部署，不覆盖已有空文件或损坏文件。

资源返回公开对象的实际数量、mtime、内核时间及来源地址，不在应用接入层推断另一套下载／修复状态。磁盘文件存在、更新返回成功和实际reader所见内容分别检查。

普通诊断保留业务字段、来源和实际错误，JSON解码失败保留解析错误及位置，不将完整响应作为错误详情。页面5秒后显示未确认时仍等原调用，后续同类查询合并为最近一次；进入后台不丢弃已受理更新结果。

## Logs and trust roots

Go在解析前公开Subscribe日志，退出订阅时UnSubscribe并排空可读事件，仅保存有界传输queue及遗漏计数。AppRuntime持有唯一1000条、UTF-8正文合计1MiB的历史窗口：

- 容量不足按整条淘汰旧记录；单条超过1MiB时略过并增加遗漏数。
- 正文保持内核原文，接收时间、窗口身份及传输／本地遗漏另列。
- 清空使用窗口身份和同一来源的单调watermark。LOGS的只读watermark查询在同一queue lock内取得source、最新已分配Seq及累计dropped，不消费queue，也不占默认日志stream的唯一consumer；AppRuntime排除Seq小于等于清空边界的记录，覆盖Go queue、FD在途和迟到事件。
- 并发清空的边界及传输遗漏baseline不倒退；旧来源回执不能清除新窗口。传输累计遗漏与本地窗口淘汰分别统计，watermark失败保留原错误。
- 过滤、跟随、滚动和复制属于UI；停止后保留窗口，查看或清空旧窗口不启动内核。

客户端过滤和内核全局日志等级分别管理。日志流与其他集合使用同一受限FD协议，不无限转发到Flutter消息queue。

Dart显式SecurityContext与Go标准fallback池使用同源根材料。Go进程设置x509usefallbackroots=1，在网络使用前安装Android snapshot及既定公共CA补充。ApplyConfig按公开入口重置配置级证书并加载用户材料，不改变显式协议证书／pin或Tailscale roots的作用域。Android API分支见[证书接入](android.md#证书与平台限制)，原始许可见[公共数据](../legal/dependencies.md#公共数据资产)。

## Public API boundaries

公开调用回执、取消信号、实际socket关闭和后台任务退出分别核对。解析失败终止该进程，不在已经发生全局副作用的context重试。正常停止及完整重连也等原进程结束，再用新输入装载；模式／策略热操作不重建context。

cache.db与Geo reader可能持有进程级句柄。逐项清理先保存确认范围、阻止新装载、结束旧进程并等待本地I/O，再由默认进程在独占资源门禁内删除；不删除整目录、协议身份或provider自定义文件。通信中断不代替死亡，资源锁未释放时不清理或创建冲突context。

接口与行为验证见[系统与网络集成](../development/verification.md#系统与网络集成)、[JNI错误路径](../development/verification.md#jni-error-paths)及[内核磁盘清理](../development/verification.md#内核磁盘清理)。
