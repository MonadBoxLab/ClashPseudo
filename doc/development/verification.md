# 集成验证与覆盖率

验证按“固定输入 → 准备环境 → 执行动作 → 等待结果及资源退出 → 比较断言 → 保存记录”进行。构建、测试、受控服务和核验工具命令见[构建与测试](build-and-test.md)，预期功能见[产品任务](../product/overview.md#功能范围)，调用及所有权见[应用架构](../architecture/overview.md)。

## 结果口径

每个场景记录以下字段：

| 字段 | 记录内容 |
| --- | --- |
| 输入身份 | 源码／资源摘要、配置ID与revision、epoch、测试数据、准备条件及nonce |
| 产物与环境 | APK／test APK／原生库摘要、variant、设备API／ABI／页大小、窗口、输入法及授权状态 |
| 动作 | 命令或界面操作、受理回执、该次操作的owner及运行generation |
| 断言 | SDK回执、Store内容、运行意图、业务结果、Service／native退出及文件比较 |
| 结论 | 通过、失败、未执行或受阻；失败输出和受阻原因 |

输入应能区分正常与异常分支，例如旧owner／新owner、保存前／提交后、取消前已开始执行／取消后才返回结果。异步检查保留原身份，资源检查等所属I/O、close或join结束。公开接口的返回及资源条件见[内核公开能力](../architecture/core-integration.md#public-api-boundaries)。

实际依赖版本、lock、工具链、复现输入、原始错误和通过／失败结果归入当次构建／验证报告。后续依赖更新生成匹配的新报告，旧报告保留当时输入与结果；复用旧结果先核对源码、测试、依赖、资源和工具链的未变范围。应用回归覆盖自有接口接入和 lifecycle，不测试 mihomo 内部实现；已确认的上游问题通过依赖更新解决。

AVD用于功能、状态变化、取消、实际退出和数据完整性的定性验证。容量、吞吐、延迟及长期稳定性在实机和受控网络中测量，同时记录设备与网络条件。AVD上的负载失败保留原输入、错误、清理结果和未执行断言；少量真实连接的关闭、对端EOF及Stop场景独立记录，不替代原负载验收，也不据此推算实机容量。

## 界面与自适应

### 布局、导航和输入

1. 记录窗口逻辑尺寸、局部父约束、TextScaler、安全区及键盘inset。Android Configuration与Flutter工作区分别读取；API28+的hintText和层级XML字段分别记录。
2. 选择布局切换点两侧的尺寸，并检查窄窗、高度较小窗口、大字号和长内容。测量控件尺寸、位置及点击范围，核对焦点、读屏内容和阅读位置；在小窗口完成停止、导航、编辑和错误查看。
3. 打开和关闭详情，连续改变窗口与字号。核对同一任务、Controller、草稿、查询链和两区阅读位置。
4. 表单校验包含折叠及离屏项，检查完整草稿校验、首错章节展开及定位、字段错误样式和语义。一次提交只出现一次SnackBar，普通输入不重复提示，修正后清除对应错误状态；子编辑取消、保存失败及重试保留草稿和输入身份。
5. 通过真实 IME delta 输入，读取应用接受值、selection 和 composing。ACTION_SET_TEXT 及预测节点的 SDK 回执与应用最终值分别记录。
6. 核对同类标题、正文、输入、菜单和操作使用约定的 TextTheme；在浅色／深色及三种品牌色下检查对比度。内容单选验证选中 `w700`、未选中 `w400`、背景及选中语义，混合 emoji 与文字保持原字符串。
7. 在手机和平板分别从多个设置二级页返回，逐帧比较分组横坐标、尺寸与滚动位置；单独记录页面路由过渡。

使用真实Tab／Shift+Tab遍历，Enter／Space激活主动作和独立子动作。逐项测量错误、缓存详情、菜单及卡片子动作的至少48逻辑像素命中区；禁用与退场起点核对键盘、指针、焦点是否已移除、读屏是否仍能访问。

| 功能 | 操作与断言 |
| --- | --- |
| 配置卡 | 点击选择、更新、编辑和更多，分别检查选择、保存及接管状态；子动作保持独立，无错误时没有空提示区域，状态变化不移动正文及操作 |
| 设置与关于 | 组内与组间间距一致，关于为独立页尾surface；宽窄屏顺序、浅深主题边界、Tab顺序与末项可达 |
| 自动更新 | 修改开关和周期后取消，核对旧值；再保存，核对提交结果；保存失败保留草稿，通过SnackBar及用户打开的详情反馈 |
| DNS | 点击“查询”，统计新查询次数；状态自动读取不触发新查询，改草稿后旧摘要保留捕获的 Question 和来源 |
| DNS 结果 | 检查 Question、RCODE、各 RR 及可复制记录；失败通过 SnackBar 查看实际错误，不出现完整响应入口 |
| 连接 | 健康时没有提示占位或虚构错误；真实错误由 SnackBar 查看和关闭，错误状态不改变搜索框和工具栏几何；lifecycle／规则筛选只改变条件 |
| 反馈 | 首层核对保存／恢复与连接结果；技术详情只由用户点击打开，逐项比较完整错误对象、`stack`、`cause`、`suppressed`及复制内容 |

在配置／插件卡片、About、表单、保存栏、原文编辑器及诊断分类中，分别比较健康、等待、失败、成功、重试及SnackBar开合前后的正文、工具栏和按钮矩形。健康时无提示占位，固定内容下状态反馈不移动操作目标；真实内容编辑、集合增删、章节展开、类型切换及语言／窗口／字号／IME变化允许对应重排。检查Overview数值在既有区域更新、备份动作按当前语言布局、LAN页面安全区只处理一次。

同一操作按原identity反馈一次，自动读取按来源及连续失败周期去重；本地feedbackOwner在SnackBar实际呈现时确认，排队或暂缓显示不提前确认。切页、换源和旧操作失效后，提示action、重试及详情不能继续操作原对象。共享组件采用代表页面和窗口组合，分类接入分别验证。

### 分类整合与精确写入

1. 在节点、策略组、规则及两类provider中分别放入运行记录和本地直接定义，检查同一renderer、搜索、详情及阅读锚点；不出现本地专区、来源徽标或提示占位，只有可写条目具有编辑、删除动作。
2. 覆盖精确provenance关联、同名跨来源、旧revision、缺失provenance、停用、被覆盖、尚未装载和无core／读取失败。关联项只出现一次，未关联原文仍可管理，运行属性不写回原文，查看和保存不误启用停用内容。
3. 节点与规则超过一页，关联对象分别位于其他页和末页；核统一搜索、计数和分页，原文变化使旧token失效。main／sub-rules／provider scope切换不串入顶层本地rules；运行规则保留原index，重复规则按确切path分别编辑。
4. proxy-provider与rule-provider同名时仍按kind区分，下载节点和规则内容保持只读。保存、改名或删除定义不改下载缓存、不自动修复引用。
5. 新增、编辑、保存、重开、删除及取消均比较目标ID、revision、storageEpoch、原文路径和其他文件原字节；保存前替换正文或整体恢复，检查旧表单、菜单和callback拒绝写入，草稿仍可复制。

### 连接读取错误的 SnackBar

从“连接”任务开始，在列表和详情分别检查自动读取错误。窄屏使用 NavigationBar 上方的 floating SnackBar，宽屏使用 NavigationRail 右侧工作区内居中的同一组件，正常字号最大宽度560逻辑像素；列表和详情并排时只显示一条。

1. 在已有连接时使当前读取失败，核对原记录、简短摘要、“错误详情”和关闭按钮。筛选至列表的基础间距为12逻辑像素，错误通知不增加正文行，不改变 AppBar 高度和列表 viewport；分别比较顶部及中段阅读位置。
2. 持续返回不同错误内容，检查只有首次自动显示，不排队、不重复动画或读屏播报。点击关闭或滑动关闭后继续失败，提示不重弹，当前业务错误仍保留；关闭后最后一条连接及详情末尾完整可读、可操作。
3. 点击“错误详情”，比较打开时捕获的实际错误、stack、cause、suppressed 及复制内容；后续读取不能改写正在阅读的 Dialog。返回后本轮故障保持安静，菜单不提供独立错误入口，点击记录状态标识不会打开 Dialog。
4. 在同一来源成功读取后检查故障结束，再次失败时检查新故障能显示。仅清空错误字段、切换可见性或使数据待更新时，不能当成成功恢复。clearInactive／releaseDetail、主动断开及新增规则失败按所属操作反馈，不冒充自动读取故障，技术详情均由用户打开。
5. 在待展示frame、提示显示和Dialog打开时切任务、打开菜单、转入后台或替换core／会话／storageEpoch，检查旧action、关闭回调和异步结果不影响新来源。返回同一来源后，已关闭故障不重弹；未查看故障须在有效读取再次确认后显示。其他任务按各自operation identity处理反馈。
6. 保持搜索focus、selection和composing，触发提示并关闭，比较输入状态、搜索框宽度和工具栏操作位置；错误变化不插入新的警告按钮，自动提示不抢焦点，Escape仍执行原搜索或详情返回。检查Tab顺序、tooltip、至少48逻辑像素点击区域、当前语言、浅深主题及减少动效。
7. 选择280、320、600／840断点附近、1200和1600逻辑像素宽度的代表性组合，搭配矮窗、高窗、TextScaler 1／2及非线性缩放、安全区和真实 IME。连续 resize 时保留同一 Controller、详情 lease 和阅读位置。剩余空间不足时暂缓浮层；恢复空间后只显示当前有效且未关闭的故障，不出现 floating 出屏异常，不缩小用户字号。

分别记录widget故障注入、配套debug APK和最终release的结果。release未实际触发的错误场景列为未执行，正常布局及导航操作另列；测试注入结果不替代真实core错误观察。

### 动效与可见性

对五个主任务、导航、四类对象详情、设置分组、存储、DNS、编辑器，以及应用自有菜单、确认／错误 Dialog、首次提示和关于页分别采样。记录正常动画初帧、中间帧及结束帧的尺寸、位置和可见度，再检查快速反向、连续调整窗口及系统减少或停用动画。

- 输入、IME、光标、滚动、拖拽及实时数字直接响应，结构变化按所属过渡采样。
- 开始关闭时检查控件已停止响应点击、焦点和读屏内容已移除，旧异步callback不能发起动作；同时记录Stop、取消和I/O返回的时刻。
- StatusText在退出和进入中途各注入后续状态，比较当前文字、透明度及偏移的连续性；同值保持呈现，减少／停用动画及Ticker停用时直接采用目标，语义只暴露目标文字。
- 普通对象宽窗开合详情时主列表宽度固定；切换单栏或双栏时保留原阅读位置。设置按连续阅读布局检查。
- DNS在高度较小窗口、大字号、键盘出现及连续调整窗口时，保留同一Dialog路由、Controller、selection／composing及滚动位置。

测试泵frame与设备普通速率采样分别保存时间轴。[ReadingList](../../lib/src/ui/components/collections/reading_list.dart)的debug入口`validationLayoutMetrics=true`可输出FlutterView、MediaQuery、insets、父约束和文字缩放，用于定位布局差异；浮层和输入动作使用相应平台真实事件。

## Core process and IPC

先验证不装载Go的Handshake、FD transport和DeathRecipient callback，再接真实JNI。每项保留协议版本、随机processId、inputId、generation、requestId、网络版本和原受理期限，PID只作观测。

| 范围 | 动作与断言 |
| --- | --- |
| 进程启动 | 检查合并Manifest、自动初始化Provider及默认进程映射，确认UI不加载Go；绑定或状态采样不解析配置、不启动core context |
| 身份与权限 | 不同UID、协议不符、未知进程／输入、旧请求晚到分别拒绝；ServiceConnection断开不冒充DeathRecipient死亡 |
| requestId | CoreHost单点分配，普通submit与内部操作共用allocator；默认应用process重建不使存活core复用ID，Long.MAX_VALUE处拒绝而不回绕，执行到达顺序允许不同于分配顺序 |
| FD protocol | 固定字节向量、0／上限／上限加1、严格UTF-8、未知kind、截断header／payload、未收到TERMINAL即EOF、分段实际长度及重复段名 |
| backpressure与集合 | 消费者暂停时queue保持有界；完整集合超过single frame的8MiB仍可逐条完成；单条超限具体报错，不截断或把集合总量限为8MiB |
| 取消与退出 | 分别记录受理、取消信号、取消错误、原调用返回及process death；取消经统一submit及FD结果，不占用Binder thread等待JNI；关闭管道不标记实际调用退出，原普通或备份期限不重置 |
| 大错误与receipt | 超过64KiB控制预算的error／cause／suppressed完整经FD返回，覆盖onExited、status及系统事件；结果FD先失败时仍保留独立nativeReceipt，receipt FD实际drain前不完成请求；旧details不覆盖新状态 |
| 日志清空 | LOGS只读watermark可与backpressure中的默认stream并发，不消费queue、不占consumer；清空排除Go queue、FD在途和迟到的旧Seq，保留边界后记录，并发清空与来源替换不使边界倒退 |
| 真实内核死亡 | 在受理、传输、解析、callback及保存后应用阶段结束实际`:core`，核对Activity、默认进程及已保存内容仍在；对象替换或Activity重建不作隔离证据 |
| 冷启动与恢复 | 匹配运行inputId与不可变记录；缺记录时仍显示实际运行状态，禁止定向替换。异常待恢复跨业务进程／Service／设备启动保留，系统入口不循环装载 |
| 资源锁 | 旧锁仍持有时禁止删除或冲突装载；通信中断但未确认死亡时保持未确认。停止完成还等本地I/O，Shutdown返回或解绑不能替代 |

异常发生前打开正文、搜索、详情和弹窗，记录草稿、焦点、选区、composing、滚动及导航身份；死亡后逐项比较。总览恢复区分别测试重新启动、更换配置后仍停止、逐项清理及再次失败。已完成保存不倒退，旧请求不能修改新进程状态。

## 系统与网络集成

按受影响API、ABI、页大小、窗口及输入能力选择Android目标。先独立运行[真实Dart冷进程用例](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/logic/LogicEngineHostTest.kt)，随后执行通用、JNI及lifecycle组，命令见[Android测试变体](build-and-test.md#android测试变体)。真实VPN授权组单列并记录授权状态。

| 范围 | 输入、动作与主要断言 |
| --- | --- |
| VPN／FD | [NativeCoreFailureTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/nativecore/NativeCoreFailureTest.kt)：FD接收、消费、失败回收、资源身份及再次准备 |
| TCP／UDP | [数据面用例](../../native/mihomo/internal/engine/tun_dataplane_test.go)：真实请求；Android核对protect、Network绑定及受影响TUN栈流量 |
| 模式／策略 | [ModeCallsTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/bridge/core/ModeCallsTest.kt)、[StrategyCallsTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/bridge/core/StrategyCallsTest.kt)、[策略测试](../../test/ui/strategies/strategy_passthrough_test.dart)：保存、读回、热切换、重连和 EOF；取消／期限／换源后的实际结果与错误；旧清理与新租约隔离 |
| 应用访问 | 独立UID客户端请求，覆盖all／only／except、共享UID、缺包和空有效allow |
| 系统启动 | [SystemStartLifecycleTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/vpn/SystemStartLifecycleTest.kt)：SERVICE_INTERFACE、系统撤权、STARTING取消及退出 |
| Activity与授权 | [AuthorizationRecreationTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/bridge/operation/AuthorizationRecreationTest.kt)：授权取消／同意、重建和请求归属 |
| 通知／Tile／widget | 从SDK入口和Launcher点击，关联MainActivity焦点、运行代次及结果 |
| TLS／Geo | [AppTrustAndroidTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/trust/AppTrustAndroidTest.kt)、[GeoResourceNativeTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/nativecore/GeoResourceNativeTest.kt)：根策略、TLS及加载／更新结果 |
| DNS | [调用](../../native/mihomo/internal/engine/dns_tools_test.go)、[系统 resolver](../../native/mihomo/internal/androidnet/system_dns_test.go)、[模型](../../test/model/dns_passthrough_test.dart)、[Controller 与 UI](../../test/ui/diagnostics/dns)：输入名称、DNS 记录、查询错误、取消后完成、缓存状态及记录复制 |

VPN授权、Activity重建、前后台、锁屏和Always-on从对应系统路径触发；手动callback注入另记录覆盖的竞态。isAlwaysOn／isLockdownEnabled仅在API29+且有可读实例时记录具体值。

### 局域网服务

分别运行LAN-only、VPN-only及两者同时运行，测试独立开启／停止、完整重载和VPN切换。核对另一功能的开启意图保持、实际恢复结果另报，LAN-only使用connectedDevice前台服务，有限订阅dataSync不持有长期监听。

- 从另一可达端点发送HTTP、SOCKS5 TCP及UDP请求，记录目标收发、源地址和关闭后的端口状态；socket bind、本机请求和ADB端口转发各自记录，不代替真实内网可达。
- 覆盖默认无认证、用户YAML认证、UDP开关、多地址、IPv4／IPv6 scope、端口占用、部分创建失败及实际TCP／UDP关闭。协议、鉴权和来源规则沿上游，不注入应用代理循环或物理入站过滤。
- 枚举所有可见本地接口，不以默认上游或INTERNET能力替代候选；已识别蜂窝／VPN／回环不可选，未知类型需用户确认。创建前复核本次名称、索引和地址，接口失效只关闭本次lanProxy映射内的监听，旧事件不影响新context。
- 保存／备份包含lanProxy正文和enabled，不含瞬时索引或实际状态；未知字段和原文入口保留，重复role拒绝。其他插件／配置的监听不被该开关认领。
- 真实热点客户端、USB热插拔／驱动及厂商行为在AVD无法执行时逐项记未验证，不用模拟网络或端口转发记通过。

### Android system DNS

API24—28 分支检查 Network.getAllByName 主机查询及地址族筛选，原始消息／ECH 返回能力错误；API29+ 分支检查指定 Network 的 rawQuery、完整响应和 RCODE、取消及实际 callback 退出。平台测试覆盖版本分支；设备记录只列实际执行的 API／ABI、private DNS 设置及结果，未执行的系统版本和设置另列。

检查解析前安装callback、每进程只初始化一次UpdateSystemDNS、显式systemClient的UDP／TCP／空服务器实际结果、配置七处system原值及具体字段错误。私人DNS失败不回退公共DNS或明文UDP，不热写上游全局服务器列表；网络变化使用原实际输入换进程。分别验证系统主机查询、显式system及VPN客户端DNS，不以任一路径成功代表全部支持。

### Geo与资源

[Geo补种回归](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/nativecore/assets/BundledGeoInstallTest.kt)在owner有效时改名home，原位置分别放链接和新目录。核对替换后的目录没有收到本次Geo文件、用户文件保持原字节、原目录所属临时文件已清除、FD已关闭。结合[目录访问回归](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/backup/PrivateDirectoryAnchorTest.kt)检查目录打开和发布前身份复核；另查fsync在owner锁外执行、同owner并发安装时保留先完成的文件及已有坏／空文件。

[上游Geo回归](../../native/mihomo/internal/engine/upstream_geo_contract_test.go)使用原场景、原文件输入和正常路由。逐项记录公开updater调用、磁盘字节、当前读取器／匹配器内容及子进程退出码，保留完整原始输出。Fatal或非零退出记为失败，磁盘写入与读取器加载分别记录结果。

### 连接与DNS

连接观察分别retain／release多个observationOwner，核对runtimeState。详情请求检查detailOwner传递，detail=null时继续保留当前详情，旧owner释放不移除新owner的详情；另查snapshot／releaseDetail的受理顺序，以及释放回执后业务Engine是否按空闲条件回收。在受控TCP／UDP中断开连接，核对closed／absent／failed、完整关闭错误及对端EOF；原调用返回后才允许下一次关闭。

queued close分别覆盖deadline、abandon、cancel与完成竞争：native尚未提交时，调用方先且仅收到一次错误，原work保持跟踪；实际drain前slot／writer不释放、重试拒绝，迟到结果不重复回复。gate释放后核native调用次数、实际退出和drain后的下一次成功，并检查process death／replacement不污染新身份。已提交native的场景继续核对原结果、receipt及实际退出，业务提前应答不代替这些完成条件。

DNS取消场景先等请求进入受控服务，再关闭工具或改变来源标识。检查取消调用、原查询返回、下一请求的Question／RCODE及控件状态；排队取消与执行中取消分别测试。响应同时包含部分消息和错误时，逐项比较保留内容；取消或超时后保留原结果，换源后另注明来源已变化。fake-IP分别检查分配、旧地址、持久池及IPv4／IPv6处理；聚合失败时，按各族取得的回执记录完成或未确认。

网络集成记录请求何时到达受控服务、收到的请求和closed／join回执，并关联应用Stop及对端EOF。分别检查模式、监听、provider／Geo、DNS／路由与TLS路径。TLS异常输入包括主机名错误、证书链损坏、未受信CA及pin不匹配。

## 安装级提示

[AppFiles回归](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/storage/AppFilesTest.kt)和[Dart桥接](../../test/platform/channel/privacy_notice_bridge_test.dart)覆盖标记缺失、已写、损坏、权限错误、文件／目录fsync、FD关闭及完整cause／suppressed。

设备检查首次提示进入可见frame后写入标记，覆盖未点按钮即重开、进程重建、保数据升级、清数据或重装及业务恢复。标记失败时检查未确认反馈，以及启动和停止仍可操作。核对中英文提示、全文、本地GPL及可选择URL；在高度较小窗口和大字号下检查完整操作，关闭开始后不再响应点击、键盘和读屏操作。保数据覆盖前保存可恢复备份；实体设备卸载或清数据先取得用户授权。

## Worker取消与后台应用

[ScheduleWorkerCancellationTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/app/ScheduleWorkerCancellationTest.kt)使用真实WorkManager、AppRuntime及延迟返回的有效正文。取消后检查owner失效、AppRuntime仍在执行，等I/O完成后才允许下一次写入；比较正文、revision和元数据。

后台运行项更新关联下载、保存、完整输入、新UUID及一次重连。用限时等待控制执行顺序，覆盖交接前取消、交接后失去网络约束、用户Stop、撤权及STARTING取消。分别记录saved、applied和退出；系统撤权通过VpnService.prepare状态变化确认。

## JNI error paths

[NativeDescriptorZeroTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/nativecore/NativeDescriptorZeroTest.kt)通过debug-only CoreFixtureService在`:core`内执行，默认进程不直接调用NativeCore。确认raw stdin为/dev/null，用F_DUPFD_CLOEXEC取得空闲0，检查FD0在JNI preflight被拒绝、constructor未调用且无socket I/O；拒绝发生在detach前，PFD仍由Kotlin持有并关闭。[Zygote标准FD](https://android.googlesource.com/platform/libcore/+/refs/heads/main/dalvik/src/main/java/dalvik/system/ZygoteHooks.java)和Java FileDescriptor各按身份记录。

FD ownership检查使用st_dev／st_ino等资源身份。system／mixed用普通有效FD触发TUNGETIFF失败，保留原始错误并检查实际持有资源的关闭；结束原core process后，在新process执行下一次Prepare／Stop，不在失败context内重新准备。部分资源已创建、已经取消及callback尚未返回的场景，分别等待本方close／callback返回、对应DeathRecipient和默认进程I/O结束。生产IPC、真实process death及系统启动沿生产链执行，不以fixture替代。

## 备份与恢复

| 范围 | 入口与断言 |
| --- | --- |
| 内容与事务 | [业务恢复](../../test/logic/backup)、[UI](../../test/ui/backup)、[运行协调](../../test/logic)、[Android](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/backup)：三文件原字节、manifest／CRC／SHA、条目及压缩／展开预算、取消、write／close、PREPARED／COMMITTED和中断回滚 |
| ZIP互通 | stored／deflated、data descriptor、manifest首／末项；损坏、额外、重复及缺失项的解码结果 |
| 备份文件读取 | [BackupActions](../../test/logic/backup/backup_actions_test.dart)：Store文件流暂停时备份文件保持可读且未删除，读取返回后discard和清理回执，主失败与cleanup cause／suppressed |
| 桥层lifecycle | [BackupBridgeLifetimeTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/bridge/backup/BackupBridgeLifetimeTest.kt)：隔离目录中的备份文件与FD、控制文件worker和main返回结果的顺序、标记retired后拒绝新读、finish与executorDrained顺序、无关owner退出时文件仍保留、实际删除、迟到capture和worker拒绝任务 |
| 结果桥 | [BackupBridgeResultTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/bridge/backup/BackupBridgeResultTest.kt)：native已提交后设置／调度／重连失败、取消或未完成时，committed、epoch、设置应用／调度／重连返回的错误和resultSuccess=false |

故障注入使用隔离目录。配套APK中的Dart跨语言读取和恢复通过SAF执行，检查一次选择、一次覆盖确认、后台返回与取消。

在设备的DocumentsUI中选择整个ZIP，再点击当前界面的OPEN或Select。若点击ZIP进入归档内容，返回Download文件列表、长按目标ZIP，确认只选中所需文件后提交；文件离屏时按当前列表滚动或搜索，核对完整名称。分别记录Downloads集合与本地Download目录。核对应用覆盖摘要，再提交恢复并重新导出，逐字节比较三业务文件，ZIP时间戳／压缩差异另列。成功提示与文件核验分别记录。核对epoch、旧草稿／菜单／Worker撤销、恢复偏好及最新运行意图。

Store读取和编码时检查JSON深度、节点数、正文及集合大小。Android使用SDK JsonReader读取有大小限制的manifest及savedMode。分别记录合法大输入与超限输入在各层的结果，并在最低API采集堆峰值。系统备份检查API24+的三个业务文件、安装标记及noBackup排除项，分别测试逐文件恢复、应用内三文件事务、系统云备份或迁移。硬链接在同一应用身份的私有cache目录创建，比较恢复目标与另一端链接所指文件的字节。

## 内核磁盘清理

使用隔离私有目录及默认进程文件执行器，记录内核lifecycle、资源锁、原始清单、逐项删除和同步回执。存储页与资源详情沿同一清理链，系统入口在清理期间不能装载新内核。

1. 通过隔离进程公开路径getter取得cache.db及实际Geo路径；覆盖MMDB／ASN替代名称、大小写和未创建context的路径查询，不按扩展名扫描。
2. 在受理及原子发布清理记录前核对storageEpoch与owner；记录位于mihomo根之外。覆盖owner替换、同步失败、worker拒绝及完整cause／suppressed。
3. 保存逐项确认的相对路径，先阻止新装载，再请求旧内核退出；分别记录DeathRecipient、默认进程I/O结束和独占门禁取得。旧锁未释放、通信中断或退出未确认时不删除。
4. 逐项lstat，检查父目录和根边界、不跟随符号链接，拒绝目录与根外路径。核对实际删除、目录同步、已不存在、权限失败、部分完成和剩余清单；每项实际完成后才更新结果。
5. 保留协议身份、provider自定义文件及所有未选文件原字节；legacy all改为重新选择，不执行整目录删除。失败保持停止并提供重试，不回滚已完成项。
6. 全部完成后结束清理门禁，仅清理保持停止；清理后启动使用新进程及最新完整保存组合。核对UI、Activity、草稿及默认进程继续存在，不使用finishActivity或结束应用流程。

设备场景先按授权保留需恢复的业务备份，并记录未选文件摘要。分别记录原`:core`身份及退出、新身份、实际删除范围和清理记录；冷启动重试覆盖同次系统启动残留、BOOT_COUNT未知、系统Service先创建及清理中断。来源和实现见[Android清理接入](../architecture/android.md#内核数据清理)。

## 编辑器与输入

| 范围 | 输入与断言 |
| --- | --- |
| YAML合成 | [Compose](../../native/mihomo/internal/configinput/compose_test.go)、[缺省](../../native/mihomo/internal/configinput/defaults_test.go)、[准备](../../native/mihomo/internal/engine/input_passthrough_test.go)：未编辑标量、未知字段、独立锚点、替换锚点后的原引用、字段存在性、无操作原字节及parser结果 |
| 公开解析 | 在未知分支放重复键、复杂键、merge和循环别名；记录公开解码／解析返回的错误，检查诊断元数据失败时parser可读输入、失败资源清理及再次准备 |
| provider路径 | [路径回归](../../native/mihomo/internal/engine/provider_cache_path_test.go)：隔离目录和HTTP服务，缺／空path、显式名、绝对／相对、符号链接、协议身份及cmfa弱类型解码 |
| 监听 | [listeners_test](../../native/mihomo/internal/engine/listeners_test.go)：profile／TLS工作副本、监听构造错误及`cause`字段、NTP无操作参数、DNS socket mark设置及系统调用返回的错误、实际TLS／DNS、FD、部分回滚和端口释放；Android补接口／mark／TFO系统调用 |
| 正文 | [限额](../product/configurations.md#文本限额与换行)：UTF-8、首BOM、混合换行、32768／32769 UTF-16边界、合行、emoji／组合字、整批delta、composing、查找、选区、剪贴板、撤销重做和保存身份 |

真实IME、硬件键盘和Controller注入分别记录。lifecycle测试读取输入控件使用的showCursorNotifier，检查销毁、停止光标闪烁及重启后延迟任务的取消；从gesture callback触发自动滚动后移除编辑器；通过公开scrollbarBuilder移除field、保留overlay controller，再检查旧callback不操作已移除的渲染对象。补丁来源见[PATCHES](../../third_party/sources/re_editor/PATCHES.md)。

输入值检查和IME批量输入测试比较拒绝前后的撤销历史、通知次数、selection／composing，以及同步给输入法的值。查找扫描完成后比较结果。系统返回依次检查收起IME、退出查找、一次未保存修改确认，以及由所属Navigator处理取消或放弃。

## 覆盖率

### Dart

[采集工具](../../tool/coverage/flutter.dart)通过 `python3 -I -B tool/main.py coverage flutter validate`／`collect` 调用，通过coverage公开API及HitMap／LCOV处理函数、行和VM branch。[测试配置](../../test/flutter_test_config.dart)在APP_FUNCTION_COVERAGE=true时注册root tearDownAll，每个完成的isolate写出包含collector元数据的raw。临时library loader加载未import库及part，记录源码分母、生成排除项及未映射源码；纯编译期生成contract排除，使用这些常量的业务代码仍参与统计。

先用小fixture验证成功、断言失败、进程中断、损坏或缺失raw、缺少测试终态及未调用函数零命中，再对固定的应用输入执行完整收集。每次使用新的外部临时输出目录，保留命令、stdout／stderr、JSON reporter事件、raw、application.info和inventory.json：

| 记录 | 含义 |
| --- | --- |
| tests.exitCode、passed／failed／skipped及success | 原测试进程退出码及已观察的测试计数；collect中的计数包含library loader |
| tests.complete、doneReceived及unfinishedIncludingHidden | reporter终态、未结束测试及中断状态；hidden单独计数 |
| collectorComplete、expectedIsolateReports／completedIsolateReports及rawErrors | 预期suite对应的raw是否全部有效，是否损坏、缺失或重复；测试终态缺失也标记未完成 |
| denominatorComplete及unmappedSourceFiles | 有效raw是否覆盖本次纳入的全部源码文件 |
| applicationCoverageComplete | collector与源码分母同时完整，不表示测试全部通过 |

测试非零仍合并有效raw并生成报告，工具保留非零退出码。损坏文件逐项记录错误，有效部分继续输出；中断、缺失isolate或源码不产生完整应用覆盖结论。Flutter built-in LCOV单独保留为诊断材料，不补入函数raw或代替完整报告。function、line和VM branch分报，同一行声明的函数可能合并，VM branch记录不推断为完整condition／decision coverage。

历史raw仅在对应的旧源码、package映射、依赖和工具链输入可固定时，于独立目录后处理；保留原测试及collector退出结果，不与当前源码合并，也不当作新输入的覆盖率。命令见[覆盖率入口](build-and-test.md#覆盖率入口)。

### Go、Android与JNI

| 语言／层 | 采集与记录 |
| --- | --- |
| Go | 生产tags、atomic coverprofile、test.gocoverdir子进程计数；statement与具名函数语句命中分报，Fatal／os.Exit导致的未flush缺口单列 |
| Android | 同variant的class、JVM exec、设备ec、JaCoCo XML／HTML；line、method、branch及Kotlin合成过滤，设备数据对应源码和class |
| JNI | 测试变体的Clang source coverage、atomic及MC/DC；实际调用结束后，在所属core process正常退出前flush独立profraw，记录processId、write返回及文件大小；debug仅在VALIDATION_NATIVE_COVERAGE启用时执行，release／profile退出实现不调用coverage。Fatal／强制退出的未flush缺口单列，不以新process补采；用配套库、llvm-profdata和llvm-cov处理，项目C、生成cgo和第三方分报 |

各报告填写指标、测试范围和未执行项。工具语义见[coverage](https://pub.dev/documentation/coverage/latest/coverage/collect.html)、[JaCoCo](https://www.jacoco.org/jacoco/trunk/doc/counters.html)、[LLVM](https://clang.llvm.org/docs/SourceBasedCodeCoverage.html)及[Flutter构建模式](https://docs.flutter.dev/testing/build-modes)。

## 最终产物与许可

发布流程在同一候选提交和固定资源上一次 split 构建生成通用版、armeabi-v7a、arm64-v8a、x86_64 四个 release APK。GitHub 的 pre-release／release 均使用分发环境签名，逐包填写：

- 应用ID、versionName／versionCode、签名证书、APK摘要和目标ABI。
- 非debuggable、非instrumentation，同ABI原生库、ELF LOAD及ZIP的16KiB对齐、实际加载。
- Go buildinfo及生产`cmfa,with_gvisor`，JaCoCo、LLVM profile runtime／sections和Go覆盖率插桩的排除结果。
- 包内法律资产与来源逐字节比较结果、decoded NOTICES、Go解析图、Gradle解析报告、CA／Geo／PSL及对应可编辑来源。

对应源码与四包使用同一固定workingTree。核对`build-inputs/source-tree.json`的dirty身份、新增／删除状态、逐文件摘要及可执行位，检查本机位置、分发签名材料和设备备份的排除。四APK、sources、licenses齐备后逐项比较SHA256SUMS。法律材料入口见[许可依据](../legal/dependencies.md)及[NOTICE](../../NOTICE.md)。

### 预发布设备验收

使用当次明确授权的设备，记录实际API、ABI、页大小、授权及输入条件。通用版与匹配ABI的release包分别执行安装、启动及同签名保数据覆盖。其他ABI包核对版本、原生库、签名和许可，未实际运行的ABI及API逐项列为未覆盖；平台测试的API分支与APK静态核验分别记录。

安装后从设备回读包版本和证书，关联本次APK摘要。逐项填写通过、失败、未执行或受阻：

| 场景组 | 设备操作 |
| --- | --- |
| 提示与许可 | 首次提示、全文、本地GPL及链接 |
| 配置和插件 | 导入、编辑、保存、预览、YAML 正文和失败重试 |
| 网络任务 | 模式、策略、测速、连接、日志及图标 |
| VPN与系统 | 授权、受控流量、通知Stop、锁屏返回及Always-on |
| 设置和输入 | 设置、存储、DNS、动效及真实IME |
| 文件恢复 | 导出、选中同一ZIP、一次覆盖、重新导出，比较三文件原字节、选择及最新运行意图 |
| 磁盘清理 | 安排、原PID退出、新PID初始化、删除范围及范围外原字节 |

自动发布记录默认分支基准、候选提交、发布类型、测试退出码、四个 release APK、源码与许可包的实际结果。本地隔离回退记录 Go test／vet 及 debug APK 中三 ABI 生产 native 库的结果；分发签名和正式四包构建另列 Actions 结果。操作入口见[自动更新与发布](build-and-test.md#自动更新与发布)。
