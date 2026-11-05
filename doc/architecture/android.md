# Android宿主与系统接入

默认应用进程承载UI、唯一AppRuntime及业务文件接入；`:core`承载CoreService、VpnService、Go与mihomo。Android管理Service、Binder、FD、系统网络、通知及文件发布，业务选择和写入由AppRuntime发起。调用顺序见[应用架构](overview.md)。

| 修改或排查的对象 | 从哪里进入 |
| --- | --- |
| 命令受理、取消、期限和发布 | [宿主与通道](#宿主与通道)、[Core process and IPC](#core-process-and-ipc) |
| 启动、停止、死亡确认和恢复 | [准备与停止](#准备与停止)、[Lifecycle record](#lifecycle-record) |
| FD、路由、系统DNS与局域网地址 | [FD and JNI](#fd-and-jni)、[VPN interface and routing](#vpn-interface-and-routing)、[Underlying network and DNS](#underlying-network-and-dns)、[局域网服务](#局域网服务) |
| 后台更新与系统启动 | [周期更新](#周期更新)、[Always-on](#always-on)、[系统入口](#系统入口) |
| 备份、清理和Geo安装 | [归档与文件访问](#归档与文件访问)、[内核数据清理](#内核数据清理)、[内置Geo](#内置geo) |

## 宿主与通道

[PseudoApplication](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/PseudoApplication.kt)先识别当前进程。默认进程恢复业务文件、初始化AppBridge及LogicEngineHost；`:core`只建立平台资源宿主和内核连接，不初始化FlutterEngine、WorkManager或业务文件恢复。自动初始化Provider按合并后的Manifest核对所属进程。

[MainActivity](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/MainActivity.kt)持有UI Engine，在Activity实际销毁时释放。[LogicEngineHost](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/logic/LogicEngineHost.kt)与UI共用默认进程的FlutterEngineGroup，按需创建唯一无UI业务Engine，运行带AOT入口标记的appBackgroundMain。该入口只进入[AppBootstrap](../../lib/src/platform/app_bootstrap.dart)：platform创建后台binding、AppRuntime和通道handler，先回报ready，再恢复已有core状态。logic不创建Flutter binding或MethodChannel，AppRuntime通过注入的AppPlatform、PlatformPort及CoreClient工作。

[AppRuntimeService](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/logic/AppRuntimeService.kt)位于默认进程且不导出。CoreService绑定它，将系统事件交给同一LogicEngineHost；Service不自行选择配置或组合插件。AppRuntimeService保持bound lifecycle，CoreService解除绑定后结束。运行输入、观察窗口或未退出任务仍被持有时，业务Engine继续运行。

CoreService在绑定建立时同时启动自身，使用START_NOT_STICKY，随实际core process退出结束。`:core`未显示UI，started lifecycle通过现有binding为默认进程保留PREVIEW空闲计时的执行机会；双向binding本身不阻止cached freezer。可见PREVIEW进入后台时，CoreClient使用原Binder发送带processId的status请求；CoreService核对身份及READY／PREVIEW状态后再次调用startService，更新最近活动时间。重复不可见通知不改变空闲起点。

[AppBridge](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/bridge/AppBridge.kt)连接UI与业务Engine。UI提交意图并读取业务snapshot，AppRuntime发起实际业务和统一内核请求。权限与SAF使用独立、单调递增的request-code范围，达到上界后拒绝分配；Activity Bundle只保存高watermark，旧返回结果不改变新请求。

所有业务操作共享一个[OperationState](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/bridge/operation/OperationState.kt)：

| 状态／方法 | 用途 |
| --- | --- |
| operationId、原受理单调时点、command | 固定本次命令身份和期限起点 |
| authorization、publicationGate | 保存授权结果，串行处理取消与文件替换 |
| 保存／应用／整体结果 | 分别记录文件发布、实际应用和整体完成 |
| executorStarted／executorDrained | 登记执行任务，在任务实际返回后移除 |
| interrupt | 将对应owner剩余时间置零，保留已完成结果与正在执行的任务 |
| finish | 保存实际执行回执 |

OperationBudget从原受理时点扣减普通或备份预算。Service启动、Engine准备、IPC和状态回读均计入这份期限；cross-process交接不重新计时。保存成功后的内核错误、取消或死亡不撤销已经完成的保存。

[AppWorkService](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/AppWorkService.kt)只承担有限订阅工作，按需运行dataSync前台任务。已有工作再次收到启动请求时继续使用原owner和期限，结束后按最新startId释放Service；相关I/O实际返回前不接受冲突操作。

[AppFiles](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/storage/AppFiles.kt)将正式业务文件保存在filesDir/configurations，将内核资源保存在noBackupFilesDir/mihomo。不可变运行输入、lifecycle记录、清理记录和资源锁不进入业务备份，后面三项位于mihomo数据根之外。正式输入由AppRuntime生成，平台完成临时文件、文件同步、rename及目录同步后返回持久化结果。

## Core process and IPC

[CoreClient](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/nativecore/CoreClient.kt)在默认进程管理一条内核连接、请求表和DeathRecipient。[CoreService](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/nativecore/CoreService.kt)不导出，与PseudoVpnService同属`:core`，两者共享一个内核宿主。

AIDL两端检查同UID、协议版本和连接身份。Handshake返回随机processId及实际状态；PID只用于平台观测。请求另外携带generation、inputId、composition、requestId，以及对应的networkRevision和独立storageEpoch。完整组合与大输入经FD传输，Binder只传小型控制数据、身份和ParcelFileDescriptor。

[application contract](../../contracts/application.json)统一操作码、字段、预算及错误码。输入、结果和事件使用同一长度framing protocol，细节及生成检查见[通信contract](../development/build-and-test.md#core-ipc-contract)。管道读写在独立I/O thread进行，queue满时backpressure；业务Engine逐条读取结果，避免将完整集合堆入Flutter消息queue。

受理回执只表明请求已接收。结果、取消结果和实际调用退出分别返回；关闭管道不等于调用取消。取消复用统一submit的CANCEL操作，使用独立requestId和FD结果，不在Binder thread执行JNI或等待原调用退出。

onExited携带processId、requestId及receipt PFD，完整native receipt按DATA和TERMINAL传输。status及onStatus的Bundle可携details PFD，完整错误和大型状态不因Binder控制预算而省略；CoreService至AppRuntimeService的系统事件使用同一约定。默认进程分别等待实际调用返回及receipt FD I/O，coreRead的terminal结果在顶层nativeReceipt保留完整回执，不把它嵌入单frame payload；结果FD提前失败时也保留独立receipt与cancelError。

错误分别保留code、message、typed cause、cause、suppressed、stack及未知字段。Go的RawCause和errors.Join保留平台原对象与多个原始错误，Kotlin不将完整错误压成摘要或布尔值。Dart的MethodChannelPort转为PlatformFailure，CoreCall在结果读取失败后仍等待原调用退出或对应process death，同时保留读取错误、nativeReceipt、取消结果及cancelError；界面语言化消息不替换这些原始结构。

ServiceConnection断开、绑定失效、事务错误或超时记录为通信中断；注册成功的DeathRecipient才确认对应远端死亡。callback在CoreClient serial state thread检查原processId，FD details按原连接、输入及接收顺序投影，旧结果不改变新进程状态。

## 准备与停止

每个core process只装载一个PREVIEW或RUNNING context。RUNNING分别记录VPN与局域网开启意图及实际状态，局域网单独运行不表示VPN已经接管。

启动交接顺序：

1. AppRuntime核对业务数据、应用choices及静态预算，生成带inputId的不可变运行输入；平台原子发布并返回持久化结果。无效choices在发布输入或结束旧进程前拒绝。
2. 默认进程先持久记录starting，再建立或连接本次`:core`；绑定本身不装载配置。
3. `:core`取得数据资源锁，捕获本次Network、DNS和本地接口，安装信任、日志及系统callback。
4. Go执行一次Compose、一次UnmarshalRawConfig、同一RawConfig上的必要缺省、一次ParseRawConfig及一次hub.ApplyConfig；延后的监听使用公开构造器各创建一次。
5. 请求VPN时，Kotlin按同次vpnSpec建立TUN，并通过JNI交给公开sing_tun.New；只在实际接管成功后报告VPN运行。
6. 默认进程核对inputId及装载回执，记录running；AppRuntime在上游profile恢复后执行应用策略恢复并读回结果。

PREVIEW用于实际策略、规则、provider和DNS诊断，不申请VPN授权，不启动外部监听、Controller、UI下载、TUN或NTP。没有可见预览页面且没有已受理任务持续30秒后结束预览进程；页面只是失焦时保留。

主动停止先持久记录原因、停止受理新工作并关闭本方系统资源，再调用公开关闭接口。宿主在control thread结束自己的`:core`；沿本次业务原受理期限，保留普通操作或备份的原预算，到期仍未完成时记录未退出调用并结束该进程。正常退出分别等待本方native调用、FD I/O及Android system DNS invocation／pending callback，未drain时不记正常；这不表示上游全部后台任务已有join回执。完成停止还须等待DeathRecipient和默认进程所属I/O退出。控制通道无响应时保持退出未确认，提供重试，不按旧PID结束其他进程。

完整重载、预览转运行、VPN切换及异常恢复使用新进程。模式和策略热操作不重建context。所有网络服务停止且无预览工作时结束core process；纯合成不创建context，无其他持有者时结束其进程。

## Lifecycle record

默认进程维护单一原子记录，保存process identity、inputId、装载阶段、退出请求、异常待恢复及清理状态，不复制配置正文。starting写入失败时不装载；正常回执后更新为running。

`:core`在接触内核数据前取得独占file lock，锁的FD保留至进程结束，不在Service解绑或Go关闭返回时释放。下一次装载和文件清理使用同一资源门禁。锁仍被占用时先连接原宿主；无法连接则保持未确认，不删除文件或装载冲突context。

冷启动Handshake后，用实际inputId匹配保留的运行输入记录。记录缺失或不符时仍可显示实际运行状态，但不能定向替换其中一项；用户可以停止后按完整保存组合启动。运行输入保留至所属进程和I/O均结束，不在start返回后立即删除。

同次系统启动中残留starting／running且旧锁已释放时，记录异常待恢复。系统启动次数取公开BOOT_COUNT，读不到时不推断正常重启；已有异常待恢复标记跨设备启动保留。内核死亡后终结旧请求、关闭旧传输并解除绑定，不等待死进程callback；默认进程已经开始的文件发布仍按自身回执完成。

## FD and JNI

| 资源 | 所有权与结束条件 |
| --- | --- |
| TUN | Kotlin保留Builder返回的PFD；JNI接收独立副本并在参数验证后detach。Go接收后由公开TUN持有，不再由Kotlin按该整数关闭。 |
| 输入／输出管道 | 各端只关闭自己取得的副本；读写、取消和实际调用返回分别记录。 |
| socket保护 | 本应用 VPN 用途的入站调用 protect，出站先 protect 再绑定本次捕获 Network；LAN-only／PREVIEW不调用 protect，出站仍绑定捕获 Network。入站不绑定默认上游 Network。 |
| JNI引用 | callback对象的global reference由所属core process持有；每次callback的local reference保留至该次callback结束。 |
| 普通监听 | 公开构造器返回后立即登记；分别记录TCP／UDP的创建、保护和关闭结果。 |

TUN只能使用当前`:core`实际持有的正数FD。用户YAML中的裸file-descriptor不作为资源转移；与当前平台资源不符时在接入处报错。公开构造失败时保留原始错误，以进程结束释放剩余资源，不猜测内部失败路径是否已经关闭FD。

公开sing_tun.New负责TUN和协议栈。平台副本将AutoRoute与AutoDetectInterface置false，Android路由和网络选择由Builder及捕获Network执行；system／mixed沿公开EnforceBindInterface接入，不自组tun.New／NewStack，也不因失败自动切换栈。

## VPN interface and routing

Builder与Go使用同次解析的地址、MTU、路由、排除项及DNS规格。路由范围复用公开tun.Options.BuildAutoRouteRanges；MTU缺省1500，显式0沿公开TUN有效值9000给Builder，其他合法显式值保持一致。Android拒绝时保留实际错误，不自行缩小MTU。

分别检查全局IPv6、DNS IPv6／地址池、TUN地址、路由和DNS劫持路径。DNS劫持判断计入公开TUN自动加入的相邻地址。显式tun.enable=false可保存或预览，请求VPN时在Builder建立前拒绝。其他Android能力限制关联具体字段，不以listener类型白名单代替公开parser。

应用名单优先级为正文显式名单→访问偏好→all，有效allow为空时拒绝。Builder在allowed和disallowed中选择一种。provider变化导致实际Builder规格变化时，平台通知AppRuntime按原实际输入更换进程，不改用最新保存组合，也不另做规则匹配。

## Underlying network and DNS

[UnderlyingNetworks](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/vpn/network/UnderlyingNetworks.kt)通过ConnectivityManager和LinkProperties捕获非VPN的Network、handle、DNS地址、privateDnsServerName、isPrivateDnsActive及revision。每个装载进程只使用一个snapshot，socket和系统 DNS callback不重新读取最新网络。

- API29及以上使用指定Network的DnsResolver.rawQuery字节数组接口，配合FLAG_EMPTY、独立callback执行器和CancellationSignal。保留响应、RCODE、DnsException.code及cause；失败不转明文UDP或公共DNS。
- API24—28的主机地址查询调用Network.getAllByName，按地址族返回实际结果。没有公开原始消息能力的ExchangeContext／ECH返回具体能力错误，不合成带TTL或RCODE的DNS报文。取消等待不等于不可取消的系统查询已经退出。
- 显式nameserver: system仍走上游独立systemClient。dns.UpdateSystemDNS只在初始化时调用一次：无私人DNS时提供底层IP:53，私人DNS已启用、严格模式或无网络时传nil。配置七处system与私人DNS组合的能力检查见[Go接入](core-integration.md#android-system-dns)。

底层Network、DNS或私人DNS主机变化时，AppRuntime按实际运行输入更换进程。不热写上游无同步系统服务器列表，不展开或改写用户system字段。系统主机查询、显式system和VPN客户端DNS转发分别验证。

## 局域网服务

局域网代理与VPN独立启停，实际监听位于`:core`。CoreService仅在局域网服务需要长期后台运行时使用connectedDevice前台类型，声明FOREGROUND_SERVICE_CONNECTED_DEVICE及其前置普通权限CHANGE_NETWORK_STATE；AppWorkService的有限dataSync不承担长期监听。

ConnectivityManager观察全部可见非VPN网络，不要求INTERNET或VALIDATED。NetworkInterface补充已有IP的本地接口；页面进入、恢复前台及本地接口变化时自动读取，前台每5秒补充检查无公开callback的接口变化。平台通过专用事件传递revision和实际错误，候选保留接口名称、当次索引、地址、前缀和类型，IPv6保留scope。

已识别蜂窝、VPN、stacked接口及回环地址不可选。未知类型不自动启用，用户确认用途后可选择，类型仍显示未知。应用只使用系统已接管的USB网卡，不申请原始USB、定位、附近Wi-Fi或热点创建权限，不调用隐藏热点接口或配置驱动。

本功能生成标准命名listeners，绑定所选具体本地地址，不使用通配监听。创建前重新检查接口身份和地址；失效时关闭对应实际监听并显示中断，等待用户选择当前地址后重启。平台只做必要protect，不增加物理入站网卡过滤、来源规则、代理协议或鉴权实现。

保存及表单行为见[配置与插件](../product/configurations.md)，连接方法见[运行与策略](../product/runtime-and-strategies.md)。VPN切换或完整重载允许现有局域网连接短暂断开，另一功能的开启意图保持，实际监听恢复结果另报。

## 周期更新

[ScheduleManager](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/schedule/ScheduleManager.kt)通过WorkManager为每个目标登记一个周期任务及网络条件，仅保存kind／ID／周期。平台记录待取消名称集合，AppRuntime在启动与恢复时读取设置协调；执行时机由系统调度。

Worker复用唯一业务Engine。交接顺序为下载并保存正文、准备不可变运行输入并核对原身份、在内部Stop前固定Worker的saved结果，再由同一owner继续本地应用。保存、调度、应用和实际退出分别反馈。

交接前Worker停止则撤销owner，CONNECTED网络约束管理此阶段；交接后用户Stop、系统撤销和原期限仍可取消应用。网络阶段自受理起110秒，整体普通业务120秒，cross-process不重新计时。既有任务的协调保留其ID、重试次数和入队时间，按实际WorkManager回执检查结果。

## 应用访问

[ApplicationsCalls](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/bridge/core/ApplicationsCalls.kt)读取包名、名称、UID、系统应用标记及有大小限制的PNG图标。应用前台期间动态监听包的增删和变更，以专用事件通知应用访问页自动读取，并只失效对应包的图标缓存；后台注销监听，恢复前台重新读取。关于页的 mihomo 版本取 BuildConfig.MIHOMO_VERSION，构建时使用与 native build 相同的 Go module 解析命令生成；读取版本不启动 core process，也不在默认进程引用 NativeCore。QUERY_ALL_PACKAGES用于应用访问设置，商店分发按渠道要求审核。共享UID、缺包、allow和图标来源见[产品规则](../product/runtime-and-strategies.md#应用访问)。

## Always-on

Manifest声明SUPPORTS_ALWAYS_ON。系统先创建VpnService时，它绑定默认进程AppRuntimeService，将启动事件交给唯一AppRuntime生成最新完整输入。重复事件不重复装载，Service不自行读取所选配置。

异常待恢复时，系统入口只更新状态及恢复通知，不反复装载失败输入。用户明确重新启动后先发布新starting记录；再次失败就重新暂停。正常设备启动与同次启动中的异常分别处理，不改变系统常开或阻断非VPN设置。

系统onRevoke关闭实际TUN并报告捕获的processId、inputId、generation、networkRevision及配置身份；默认进程只处理仍匹配当前core的事件。AppBridge撤销旧owner并建立revoke owner，沿用原受理时点和deadline；没有原操作时才从当前单调时点建立普通预算。新owner先被记录为当前操作，旧executor退出不会放行其他writer。

READY且lanIntent仍为true时，先等待logic、原executor、core请求、资源调用、文件发布及备份读取实际结束，再由同一AppRuntime读取原不可变运行输入，等待旧进程死亡及本地I/O结束，生成新inputId、仅将vpnIntent置false并装载LAN-only新进程。不改用最新保存组合，不重新计算期限，不改变lanProxy正文或enabled。等待期间原期限到达则记录LAN恢复未完成并请求旧进程退出；STARTING或没有可保留局域网服务时直接进入退出流程。通信中断仍保留未确认，不作为成功恢复或真实drain。

API29+按实际服务能力读取Always-on／lockdown，无法读取时显示未知。普通Stop在已确认常开时引导系统设置；普通内核错误不作为系统撤销。

## 系统入口

Shortcuts通过非导出activity-alias区分固定start／stop；公开MainActivity的action／extras仅用于界面导航。打开总览先等待UI-ready，并执行当前页面的退出检查。取消退出时结束该导航请求；仍有覆盖路由或相同退出阻止条件时不继续导航。

Tile使用BIND_QUICK_SETTINGS_TILE，锁屏unlockAndRun后重读实际动作；widget采用不可变的明确PendingIntent。状态读取期间再有变化时标记dirty，返回后补读一次；实例销毁只移除该实例引用。

磁贴通过系统快捷设置、小组件通过Launcher选择器添加。品牌源为[branding](../../assets/branding/README.md)，桌面、启动与widget共享素材，通知和Tile使用单色轮廓。系统入口都进入同一业务执行链，不创建另一份AppRuntime。

## 安装级提示标记

Dart AppBridge的privacyNoticeShown与markPrivacyNoticeShown由默认进程文件接入执行，等读写、同步和FD关闭后回执。[FirstRunNotice](../../lib/src/ui/app/first_run_notice.dart)在应用可交互且提示实际进入后记录，后台启动不记录；已发出的写入在提示关闭后继续完成。

标记位于noBackupFilesDir的privacy-notice-shown，内容为单字节1。读取仅在ENOENT时返回false；类型、长度、内容和其他I/O错误具体返回。写入核对普通文件及单链接，执行文件与父目录同步，关闭错误保留为suppressed。保数据升级、业务恢复和内核清理保持标记；清除应用数据或重装后重新建立。

## 归档与文件访问

[BackupFiles](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/backup/BackupFiles.kt)与[RestoreTransaction](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/backup/RestoreTransaction.kt)管理配置、插件和偏好三个正式文件。默认进程Application恢复事务后才允许业务读写；AppStrings、UI、Worker与系统入口检查ready／restoring／epoch。普通写入、整体恢复和系统备份共用业务file lock。

文件路径以SDK私有根为准。打开文件核对普通文件，流与目录FD在I/O实际结束后关闭。rename完成与目录同步失败分别记录，文件已经保存时不倒退为未保存。

归档先按预算复制实际字节，再检查ZIP固定条目、逐项及总展开量、CRC和SHA，最后由AppRuntime复用Store校验正文及业务关系。支持stored／deflated、data descriptor和manifest首／末项；额外、目录、重复或缺失条目拒绝。预算见[数据contract](data-and-operations.md#归档格式与大小限制)。

[BackupCalls](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/backup/BackupCalls.kt)使用系统OPEN／CREATE_DOCUMENT、OPENABLE及一次性URI授权。私有文件由BackupFiles.ioExecutor处理，外部文件提供者由独立documentExecutor处理。取消后不发起后续动作，已有I/O和close返回前不放开冲突操作；已写外部文件不因回执迟到或私有清理失败而自动删除。

备份文件按实际使用者保留。放弃后标记retired，拒绝新读取与恢复，等最后一个executorDrained后清理。committed表示原生文件已经提交，整体成功还要求设置、调度及所要求的重连完成。

冷启动先恢复事务，再按lifecycle和实际使用者清理无主临时文件。仍匹配运行内核的run-input记录保留；损坏事务、正式业务数据、内核文件、清理记录和安装标记不作为普通临时文件删除。

[PseudoBackupAgent](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/PseudoBackupAgent.kt)自行初始化业务文件接入。系统云备份与设备迁移仅包含三个正式文件，包含lanProxy正文及enabled，不包含瞬时接口、运行输入或实际监听状态；是否备份由系统与服务决定。应用内整体恢复使用RestoreTransaction，系统逐文件恢复保留各次SDK及同步回执。

## 内核数据清理

[CoreDataCleanup](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/storage/CoreDataCleanup.kt)只处理用户逐项确认的cache.db和实际Geo文件。候选来自公开路径getter在parser／provider启动前取得的路径；未装载时使用不创建context的PATHS查询，临时建立的core process在无其他持有者时退出。PATHS返回cache、geoip、mmdb、asn、geosite及home；AppRuntime将根内的实际路径转为去重的相对清单，请求字段为paths。MMDB与ASN保留上游实际选中的名称及大小写，不按扩展名扫描或删除整目录，provider的Vehicle.Path也不作为清理候选。

清理顺序：

1. AppRuntime确定用户确认的相对路径，平台原子保存清单并阻止新装载，复核owner和storageEpoch。
2. 请求旧内核退出，确认对应死亡后等待默认进程所属I/O结束。
3. 默认进程独占资源门禁，逐项lstat，检查父目录、根边界及不跟随符号链接，拒绝目录和根外路径。
4. 删除已确认文件并同步目录，每项实际结束后更新清单。文件已不存在记完成，部分成功、失败和剩余项目分别保留。
5. 全部完成后释放清理门禁；仅清理时保持停止，用户选择清理后启动时再按最新完整保存组合创建新进程。

失败时保留记录和原始错误，保持内核停止供重试；业务文件读写仍按各自恢复结果处理。legacy all不再自动执行，要求重新逐项选择。清理不结束Activity或默认应用进程，不删除协议身份、provider自定义文件或其他用户文件。

## 内置Geo

[BundledGeo](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/nativecore/assets/BundledGeo.kt)在Go确定随包来源及实际路径后、正式ParseRawConfig前安装缺失文件。只接受四类资源及受管basename，兼容geoip.db／geoip.metadb等上游实际名称。固定来源、版本、编码、原始与安装后大小及SHA以[resources.json](../../third_party/data/resources.json)为准；构建据此生成build/generated/bundled中的payload、安装metadata、常量及许可材料，Android从该generated目录打包assets。许可说明见[数据依据](../legal/dependencies.md#公共数据资产)。

只有目标缺失且对应geox-url子键使用随包来源时才安装；显式空值保留原义。已有普通文件优先，包括空文件或损坏文件，其语义检查与加载交上游；目录、符号链接等类型错误具体返回。

安装使用本次home的目录FD、O_NOFOLLOW／O_NONBLOCK及fstat，独占临时文件使用O_CREAT／O_EXCL。复制时核对owner、原始与展开长度及SHA；完整文件同步后，在发布锁内重新核对home身份与目标存在性，再rename并等待目录同步。home被移动或替换时，不沿新路径发布或删除旧目录临时文件。

各文件独立安装。后续文件失败保留此前完整结果，rename后目录同步失败也保留实际状态。只清理本次创建的临时文件，不覆盖已有数据库，不接管上游reader或修复流程。安装位于新core process内，已经捕获本次home及公开路径，尚未执行正式ParseRawConfig。

## 证书与平台限制

API34+采用Android默认TrustManager acceptedIssuers，API24—33追加Mozilla snapshot。仅在旧系统共享默认根中，精确匹配SHA-256 `88497f01602f3154246ae28c4d5aef10f1d87ebb76626f4ae0b7f95ba7968799`且仍为负序列号的EC-ACC按既定异常处理；其他证书由正常客户端校验。

snapshot先核查完整大小与SHA，再逐PEM块交CertificateFactory；API24按可处理curl注释的逐块路径解析。Dart与Go使用同源默认根；协议证书、pin及Tailscale roots保留各自作用域，域名、pin与撤销策略由对应客户端处理。

发布ABI为armeabi-v7a、arm64-v8a和x86_64，实际映射见Gradle及[原生构建入口](../../tool/android/build_core.sh)。最低Android版本由Flutter与项目配置确定，API与CPU架构分别核对。SDK JsonReader部分操作可能构造大标量，结合文件和节点预算核验最低API的实际堆峰值，方法见[备份恢复验证](../development/verification.md#备份与恢复)。
