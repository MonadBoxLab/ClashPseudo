# Android宿主与系统接入

Android提供Engine／Service／Worker、权限与系统组件、VPN接口、JNI资源和机械文件门；Dart业务语义与Go内核职责见[应用架构](overview.md)。本篇描述Android部署，其他平台按各自接入设计。

## 宿主与通道

[MainActivity](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/MainActivity.kt)持有UI Engine，并在Activity实际销毁时释放。[LogicEngineHost](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/logic/LogicEngineHost.kt)与UI共用Application的FlutterEngineGroup，懒加载时由SDK构造器完成FlutterLoader，再读bundle并创建唯一无UI业务Engine。

appBackgroundMain保留AOT入口标记，执行后台业务且只注册所需通道。运行、在途命令／查询及近期记录持有Engine，空闲后释放；VM属于进程，资源按进程口径观测。

[AppWorkService](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/AppWorkService.kt)按需承载dataSync前台任务，使用AppBridge记录的受理起点和剩余期限；预算及UI回执见[期限契约](data-and-operations.md#期限取消与真实退出)。在途任务收到额外启动时保持原owner及原期限，任务结束后按SDK最新startId释放Service。执行门保留至真实I/O drain，服务和通知沿各自生命周期结束。

[AppBridge](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/bridge/AppBridge.kt)连接两个Engine，UI通道受理读取／提交，业务通道按owner执行变更。权限和SAF使用独立、单调递增且达到上界后拒绝分配的request-code范围，Activity Bundle只存高水位，旧返回结果仅消费并丢弃。

[AppFiles](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/AppFiles.kt)在filesDir/configurations保存三库，noBackupFilesDir/mihomo保存核心资源，work/run-input-<operationId>.json保存当前输入，system-input.json用于系统启动。Intent固定本次operationId，Service核对仍有效的owner后承接任务，正文沿私有文件交接；机械门ready后读取语言并核查epoch，跨Engine消息使用稳定ID与参数。

## 准备与停止

启动顺序为VPN授权→业务准备→旧资源释放→Go Compose／缺省→正式解析与平台检查→同次generation／composition规格→取消复核→Builder建立TUN→JNI接收／detach→栈与普通入口启动→RUNNING。Kotlin消费同次平台投影。

停止先撤销socket owner及后续启动权，再关闭TUN、取消所属任务，等已受理资源退出后释放节点。失败／超时保留FAILED／UNKNOWN及关闭的复用门。Service只结算自己的代次；Activity销毁后VPN沿其自身生命周期，普通服务采用START_NOT_STICKY。

[CoreHost](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/nativecore/CoreHost.kt)持唯一上下文与worker，[NativeSession](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/vpn/NativeSession.kt)表达接管和FD。PREVIEW READY与VPN RUNNING分别观察，预览沿真实可见性及[回收规则](core-integration.md#上下文与预览)调度。

## FD与JNI交接

| 资源 | 所有权与清理 |
| --- | --- |
| TUN descriptor | JNI前置检查前由Kotlin持有，进入后detach；raw guard保护至公开NativeTun接受，随后所有权完整移交 |
| stack | NewStack返回后、Start前登记；Start失败关闭stack及独立NativeTun |
| socket hook | 进程安装一次、原子切owner；VPN执行protect，PREVIEW只许可本代次网络 |
| JNI引用 | 会话持有global reference，每次回调另持local reference直至实际返回 |
| 普通监听 | VPN规格／FD确认后、RUNNING前激活，记录实际Close，部分bind失败回滚 |

负FD保留调用方处理，fd=0按入口约定关闭并报固定错误；回归使用独立进程。复用FD按资源身份检查。system／mixed经TUNGETIFF取得接口并设置ForwarderBindInterface／EnforceBindInterface，失败回收本次资源。

## VPN接口与路由

Builder与native消费同次地址、MTU、路由、排除和DNS规格。STARTING时记录租约revision，RUNNING后复核最新有效待办，相同revision交付一次；Stop、撤权、回退及owner替换撤销原待办。

IPv4接口由parseTun按fake-IP范围派生，auto-route=false保留原含义；低API以CIDR相减表达排除，route-address-set来自已加载provider公开ToIpCidr。完整投影成功后相同revision发布，失败保留上次投影，回到已附着规格时撤销刷新待办。

全局IPv6、DNS IPv6／池和TUN地址／路由分别检查；显式请求与实际解析／环境冲突时关联对应字段。四栈能力与缺省见[内核投影](core-integration.md#合成与平台投影)。

应用名单优先级为正文显式名单→访问偏好→all，有效allow为空时拒绝。Builder在allowed和disallowed中选择一种。Linux mark／路由表、MAC／物理接口、其他用户、外部FD、GSO、系统NTP等按Android实际能力检查，字段错误具体反馈；后续provider Option更新按可取得公开观察点单独核验。

## 底层网络与DNS

ConnectivityManager／LinkProperties记录底层Network与DNS，声明ACCESS_NETWORK_STATE；API24沿该版本公开能力取得Network。socket绑定捕获的Network及owner。

[system_dns.go](../../native/mihomo/internal/engine/system_dns.go)安装进程级SystemResolver代理，按网络快照用公开dns.NewResolver构造并原子切换。解析后、Apply前展开system来源，覆盖各DNS字段；实际采用system且底层配置变化时按当前运行输入重连。

底层系统DNS缺失时反馈不可用，Private DNS沿其安全通道要求处理，显式DoH／DoT保持正文。DNS关闭时对应service／fake-IP／listener保留关闭，非空依赖型劫持在FD前校验；空dns-hijack按原含义，普通DNS按目标与规则处理。

## 周期更新

[ScheduleManager](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/schedule/ScheduleManager.kt)以WorkManager承载每目标唯一周期任务和网络约束，仅存kind／ID／周期。平台记待取消名称集合，业务在启动／恢复时读设置校准；执行时机由系统调度。

Worker复用唯一业务Engine，调度登记在周期／目标变化及明确重试时进行。保存、调度和应用分别反馈，交接见[后台更新](data-and-operations.md#后台更新交接)。

finishScheduledDownload在实际保存、准备完整输入和身份复核后、内部Stop前固定Worker saved结果；交接前Worker.isStopped撤销owner，交接后本地应用依据原owner及期限继续，CONNECTED约束只管理交接前阶段。网络阶段受理起110秒，总run120秒，main定时器只安排剩余预算，各业务调用以elapsed复核同一起点的剩余期限。

onRevoke在publicationGate撤销所捕获scheduled owner与VPN generation，main线程清理对应run。取消其STARTING应用时正常停止该代次，真实I/O退出后开放写门，验证见[Worker](../development/verification.md#worker取消与后台应用)。

## 应用访问

[ApplicationsCalls](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/bridge/ApplicationsCalls.kt)读取包名、名称、UID、系统标记和有界PNG。QUERY_ALL_PACKAGES用于本地访问设置，商店分发按渠道要求审核；共享UID、缺包、allow与图标身份按[产品规则](../product/runtime-and-strategies.md#应用访问)处理。

## Always-on

Manifest声明SUPPORTS_ALWAYS_ON，系统由SERVICE_INTERFACE或对应Intent进入同一业务链，读取最新完整保存组合并写system-input。重复请求合并，忙时有界等待，写入由唯一执行者承担。

Stop／撤权撤销系统待办，内部重连保留原运行意图。API29+且服务实例可读时读取Always-on／lockdown，否则未知。普通Stop在已确认Always-on时引导系统设置，启动错误如实反馈；系统启动按实际解锁和授权条件受理。

## 系统入口

Shortcuts使用非导出activity-alias固定start／stop，启停权限由专用入口验证，公开MainActivity action／extras用于界面导航。openOverview导航经UI-ready握手，复用真实离开页面guard；退出取消时结束该导航请求。菜单本地history已撤销且原页仍顶层时，等PopScope关闭帧再继续退出；未变化阻止条件或新覆盖路由结束请求，页面退出依据实际路由状态确认。

Tile用BIND_QUICK_SETTINGS_TILE，锁屏unlockAndRun后重读实际动作；widget使用不可变明确PendingIntent，start和stop采用各自固定动作。系统事件触发单实际快照在途及一个dirty续读；Tile已listening时通知当前实例进同一读取门，未listening才请求系统进入。实例销毁仅撤销其自身引用。

磁贴通过系统快捷设置、小组件通过Launcher选择器添加。品牌源为[branding](../../assets/branding/README.md)，桌面、启动和widget共享素材，通知／Tile采用独立单色轮廓；交互见[系统入口](../product/runtime-and-strategies.md#android系统入口)。

## 归档与文件门

[BackupFiles](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/backup/BackupFiles.kt)和[RestoreTransaction](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/backup/RestoreTransaction.kt)提供固定三库机械门。Application后台recover结束前关闭读写，AppStrings、UI、Worker和Always-on遵守ready／restoring／epoch。普通发布与整体恢复共用门，目录同步错误真实上报。

文件访问从SDK canonical根取得信任锚，filesDir／noBackupFilesDir分别承载业务与核心数据。持目录FD逐层检查NOFOLLOW及inode；隔离测试采用SDK cache根，正式路径按其真实访问能力验证。

备份结构由SDK JsonReader解析。ScalarReader将quoted string转为UTF-8长度、surrogate有效性及UTF-16单元SHA-256检查视图，原字节保持，结构与数值继续交SDK；重复键、正文及unquoted literal按严格预算检查，最低API峰值由实际测量确认。

[BackupCalls](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/backup/BackupCalls.kt)使用系统OPEN／CREATE_DOCUMENT、OPENABLE、LOCAL_ONLY与一次性URI授权。私有准备在storage lane，外部provider在单document lane；取消撤销结果，I/O保留draining至真实结束，预算见[归档契约](data-and-operations.md#归档格式与准入)。

[PseudoBackupAgent](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/PseudoBackupAgent.kt)自行初始化机械门，fullBackup取得一致读，逐文件恢复前撤销旧本机事务。范围为三库，API24–27排除，API28+按加密条件处理；调度和VPN启动沿各自授权链。

## 内置Geo

[BundledGeo](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/nativecore/BundledGeo.kt)在Go Compose确定逐键资格后、正式ParseRawConfig前接收install(home, requests, owner)。home为已存在的受管noBackup内核目录，Request只接受四种Kind及其受管basename；目标名沿同次内核选择，兼容geoip.db／geoip.metadb等有效名称。原始数据、长度、hash与许可见[数据依据](../legal/dependencies.md#公共数据资产)。

只有文件缺失且对应geox-url子键未显式指定时才补种，显式空值也保留原语义。已有普通文件优先，包括更新结果和替代文件名；已有损坏或空文件由正常加载处理，目录／符号链接等错误类型明确失败。每次补种均检查实际文件状态。

Owner.checkCurrent在流式读取中复核取消及身份，publishIfCurrent与取消共用仲裁，同步且恰好一次执行短发布块。受管后代以O_NOFOLLOW／O_NONBLOCK打开，fstat验证目录类型，ParcelFileDescriptor固定目录FD，后续访问沿该FD；发布前重开home比较inode。独占临时文件使用O_CREAT／O_EXCL／O_NOFOLLOW，并由ParcelFileDescriptor.AutoCloseOutputStream持有及关闭FD。

安装流式核查原始与展开大小／SHA。完整临时文件fsync后，在owner短仲裁内重新校验身份、目录／临时inode及目标存在性，再由SDK Os.rename发布；提交前出现的目标保留。目录同步在仲裁外等待实际返回。旧lease／updater已退出、新updater未启动是此受控单写者发布的前提。

四库独立，后续失败保留此前完整项；目录同步失败时已发布文件可能仍在，重试按实际存在性继续。取消／错误只清理本次独占临时inode，provider、业务和Tailscale身份保持。PREVIEW、VPN与系统启动共用这一接入，资格判断与内核加载仍由同一准备链完成。

## 证书与平台限制

API34+采用Android默认TrustManager acceptedIssuers，API24–33追加Mozilla快照。仅在旧系统共享默认根中，精确匹配SHA-256 `88497f01602f3154246ae28c4d5aef10f1d87ebb76626f4ae0b7f95ba7968799`且仍为负序列号的EC-ACC按既定异常处理；其他证书由正常客户端校验。

快照先核查完整大小／SHA，再逐PEM块调用CertificateFactory；API24按可处理curl注释的逐块路径解析。Dart／Go共享默认根，协议证书／pin及Tailscale roots各保留作用域；按域、pin及撤销策略由对应客户端处理。

产品规定Android发布ABI为armeabi-v7a、arm64-v8a和x86_64；实际映射入口为Gradle过滤和[原生构建脚本](../../tool/android/build_core.sh)。Android最低版本由所选Flutter及项目配置确定，CPU架构与系统API分别核对。

SDK JsonReader部分peek／skip会构造大标量，需结合文件／节点预算和最低API实际堆峰值核验，方法见[备份恢复验证](../development/verification.md#备份与恢复)。
