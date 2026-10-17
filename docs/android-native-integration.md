# Android 原生接入

产品规则见 [产品需求](product-requirements.md)。本文记录当前 Android 实现及其维护边界，不指定其他平台必须采用相同的宿主或进程部署。

## 应用宿主与配置存储

- [MainActivity](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/MainActivity.kt) 持有 UI Engine，实际销毁时释放；普通暂停及授权弹窗不销毁 Engine。
- [LogicEngineHost](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/LogicEngineHost.kt) 与 UI 共用 Application 的 `FlutterEngineGroup`，承载唯一无 UI Dart 逻辑 Engine。入口为保留 AOT 标记的 `appBackgroundMain`；没有 `runApp`，不注册平台插件。VPN 运行、命令／查询在途或 Dart 报告仍有近期记录时保留；停止后不再采样，记录全部过期且无任务时释放。平台只管理保留原因，不实现连接窗口、速度或历史恢复协议；进程结束即丢弃记录，系统冻结不保证准时回收。
- [AppWorkService](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/AppWorkService.kt) 仍为按需、有 120 秒期限的 `dataSync` 前台任务服务。命令完成后移除通知并结束服务，不再直接销毁逻辑 Engine；不为持续观察增设后台服务。Flutter VM 的进程级资源不等同于 Engine，不承诺释放 Engine 后内存回到首次加载前。
- [AppBridge](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/AppBridge.kt) 串行受理命令，以操作 ID 区分受理与最终结果，分别为两个 Engine 接线。UI 重开只查询，不重发任务；权限结果按请求标识匹配，迟到结果不能结束后续操作。工作服务及 VPN 均为 `START_NOT_STICKY`，进程结束不自动续跑。
- [Dart 配置业务](../lib/features/configs/config_actions.dart) 下载、保存并协调启停。下载上限为 16 MiB、总时限 30 秒、最多 5 次重定向；手动检查每跳 HTTP 风险，不跨来源转发 Basic 凭据，不绕过 TLS 验证。实际配置语义在策略预览或 VPN 加载时判定。
- [配置存储](../lib/features/configs/config_store.dart) 是单写入者的 JSON，以同目录临时文件 flush 后 rename 提交。保存于 `filesDir/configurations/configurations.json`；顶层保存 `selectedId`、`mode`、`entries`，不设置格式版本号。记录用 `kind` 区分 remote／local，来源与成功正文时间可空；`revision` 校验正文并发身份，不是格式号，不迁移旧开发格式。远程更新前先持久化旧正文失效状态；最初写入失败则不下载，停止当前项的接管并明确报告旧记录未修改。本地保存相反：先写正文，写失败不停止旧接管；写成功后仅对实际运行 ID 正常停止并重新启动，旧预览按身份释放。损坏或旧格式存储报错，不覆盖为空列表。
- [AppFiles](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/AppFiles.kt) 把内核资源放在 `noBackupFilesDir/mihomo`，运行输入放在 `noBackupFilesDir/work/run-input-<operationId>.json`。单份 JSON 包含配置 ID、revision、模式、原样正文及选择映射，临时文件 flush／rename 后由 worker 核对身份读取；每操作独立文件，过期请求不能读到后续操作的输入。正文不放入 Intent，输入用完删除，不作为历史副本。

### 本地正文与保存结果

UI Engine 使用官方 `file_selector 1.1.0` 选择单文件；不按扩展名或提供者 MIME 过滤，选中后按实际字节校验，避免 YAML 被错误 MIME 隐藏。当前 Android 插件会合并类型组，混用具体过滤与空的“所有文件”组并不能解除过滤；设备回归应在系统 Downloads 中放置 YAML、TXT 和非 UTF-8 文件，确认合法文本可见／可导入、取消无记录、非 UTF-8 明确拒绝。默认 UI Engine 自动注册插件，逻辑 Engine 仍明确关闭插件注册。交付后的 `XFile` 先检查长度，再按流有界读取和严格 UTF-8 解码；取消或页面销毁后的迟到结果不创建记录。插件交付前的缓存／读取不受应用字节上限保证。正文页使用 `re_editor 0.10.0` 的公开 controller、查找与移动选区工具栏 API，SDK 自适应工具栏提供复制／剪切／粘贴；关闭补全、折叠、替换与高亮。大正文通过 SDK `compute` 显式准备 `CodeLines` 后才交付 controller，不把准备中显示成空正文。

`saveLocal` 的 `body` 仅在平台通道中使用 UTF-8 `Uint8List`（Android 对应 `byte[]`）；UI 编码后交由 Android 原样转发，逻辑 Engine 使用 `decodeConfigText` 检查实际字节上限并恢复 BOM，再交给配置业务。不能直接传递以 BOM 开头的字符串：`StandardMessageCodec` 的 Dart 字符串解码会消耗起始 BOM。存储及业务正文仍为字符串，不增加旧通道格式兼容分支；解码失败返回 `notSaved`，不写入或停止旧接管。

[配置查找适配](../lib/features/configs/config_find_controller.dart) 实现组件公开 `CodeFindController`：原组件逐输入排队，且每个匹配从首行重新计算位置，会使大正文高频匹配迟到；适配合并最新查询、复核正文／查询身份，在 `compute` 中按匹配顺序推进行偏移。仅做不区分大小写的字面查找，不折叠、不替换，不限制匹配数量。正文焦点及只读语义由 SDK `Semantics` 跟随实际 `FocusNode` 和编辑状态，不代表完整屏幕阅读器支持已验证。

`re_editor 0.10.0` 的移动端键盘分支直接处理 Backspace／Enter，未检查 `readOnly`，且不经过桌面快捷键适配。正文页使用 SDK `FocusManager` 的早期按键回调，仅在移动端、正文持有焦点且不可编辑时拦截这两个键；查找输入、可编辑正文及其他按键不受影响，页面销毁时注销。该适配同时覆盖远程只读、保存中与结果未确认状态；升级组件时应复核此缺口及选区删除、换行、焦点转移回归，不修改第三方源码。

`re_editor 0.10.0` 另有未解决的移动端光标生命周期缺口：`startBlink` 创建的 100 ms 延迟回调不随控制器销毁取消，正文聚焦／改变选区后立即销毁组件会访问已释放的 `_CodeCursorBlinkController`。[生命周期回归](../test/features/configs/config_text_lifecycle_test.dart) 保留该失败，同时区分通过正常路由动画返回的通过路径；不通过等待回调结束后才销毁、吞掉异常或修改第三方源码规避。当前证据为 widget 测试中的释放后访问与 debug 断言，不等同已复现 release 崩溃，也不能据正常返回通过宣称任意销毁路径安全。

`saveLocal` 经既有 operation/resultId 通道返回 `configStatus`、`targetId`、`savedRevision`：

| configStatus | 含义 |
| --- | --- |
| notSaved | 业务操作未完成正文写入，保留编辑输入 |
| saved | 正文已写入，无需重新启动实际接管 |
| applied | 正文已写入，实际运行项重新启动成功 |
| applyFailed | 正文已写入，但停止／启动或旧预览释放失败；不是保存失败 |
| unconfirmed／缺失 | 平台超时、中断或结果未确认；重读核实，不自动重发 |

Android 只接受当前 operation 的最终结果；正文页经 AppController 等待匹配的 resultId，不解析提示文字、不把受理 ID 当作完成。125 秒 UI 等待上限略长于后台任务期限，超时只重读；离页不取消已受理业务。`saveLocal` 的反馈由提交页面承担，避免与全局反馈重复。保存先复核打开时 ID／revision；成功后仅按已确认提交版本更新脏标记，写后应用失败保留新正文。此协议不代表 16 MiB 真机传输／性能或完整设备生命周期已验收。

系统备份规则只允许已提交的 `configurations.json`，不包含其 `.tmp`、缓存或运行输入。版本保护规则见 [产品需求](product-requirements.md#系统备份与恢复)。恢复数据的读取与正常存储走同一代码，实际状态仍查询平台。规则检查不等于真实云备份／跨设备恢复验收。

## 职责与调用顺序

| 部分 | 当前职责与边界 |
| --- | --- |
| UI Engine | 页面、交互、展示所需读取与状态判断。[AppController](../lib/app/app_controller.dart) 可读取配置存储并查询平台快照，提交操作请求；不承担配置写入或直接修改内核。UI 并非只能绘制，也不要求每次读取都启动业务 Engine |
| Dart 逻辑 Engine | [AppRuntime](../lib/app/app_runtime.dart) 是唯一业务执行者，执行下载、持久化、策略偏好与操作协调，并持有[连接观察器](../lib/features/connections/connection_observer.dart)和有界窗口。UI 可独立销毁，不影响接管期间的观察 |
| Android 平台宿主 | 管理 Engine、权限、服务、操作身份与期限，以及系统资源和原生上下文所有权；不是单纯转发参数。[AppBridge](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/AppBridge.kt) 的 UI 通道受理读取和提交请求，执行变更的调用由业务 Engine 通道受理 |
| Go／mihomo | [Go engine](../native/mihomo/internal/engine/engine.go) 解析和应用配置、处理模式与策略、协调网络和原生资源清理。mihomo 使用进程级全局状态，当前只运行一个上下文 |

[信息读取与按钮判断](../lib/features/strategies/strategy_controller.dart) 不代替业务及原生执行前的身份检查；异步期间配置或上下文可能已变化。保持持久修改、平台资源与展示状态的职责边界，不为调用链形式统一而把所有读取绕经业务 Engine。

[NativeCore](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/nativecore/NativeCore.kt) 与 [JNI 桥接](../native/mihomo/bridge_android.c) 负责参数、UTF-8 数据及 socket 保护回调的跨语言传递。[PseudoVpnService](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/vpn/PseudoVpnService.kt) 定义 TUN 地址、前缀与 MTU，同时传给 Android Builder 和 native。

启动流程：`VpnService.prepare()` 授权 → 启动前台服务 → 工作线程解析并应用配置 → Builder 建立 TUN → `detachFd()` 交给 native → 附着成功后进入 `RUNNING`。重复启动不会创建第二个会话。

停止先使会话失效，拒绝新拨号和迟到启动，再在同一工作线程关闭 TUN、provider、活动连接与会话 DNS 状态。清理成功进入 `STOPPED`；清理错误进入 `UNKNOWN`，阻止再次启动。Activity 销毁不停止 VPN；服务使用 `START_NOT_STICKY`。

### 资源交接

| 资源 | 持有与释放 |
| --- | --- |
| TUN FD | `detachFd()` 前由 Kotlin 持有；交给 JNI 后，成功和失败均由 native 处置，Kotlin 不重复关闭 |
| socket hook | 进程内安装一次，通过原子引用切换当前会话；VPN 调用 `VpnService.protect()`，预览仅检查自身网络许可 |
| JNI 回调对象 | 会话持有 global reference；每次调用另持 local reference，避免停止时对象失效 |
| provider | 停止时调用 `Close()` 取消任务，并显式关闭其当前节点；节点与主配置共享时由上游 once-only 包装防止重复关闭。上游取消不是同步等待，在途解析／更新仍有迟到替换节点的边界，不承诺所有后台任务已同步退出 |

停止释放会话资源，保留 Go runtime 和 mihomo 的进程级统计任务。

## 预览上下文与策略接口

[CoreHost](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/nativecore/CoreHost.kt) 持有唯一上下文及 `pseudo-native` 单线程 worker；Prepare、查询、选择、Stop 共用队列。上下文以 generation、配置 ID、revision 区分，并独立记录 PREVIEW／VPN 用途及 EMPTY／LOADING／READY／RELEASING／FAILED 阶段。[NativeSession](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/vpn/NativeSession.kt) 仍只表达 VPN/TUN，预览 READY 不等于 VPN RUNNING。清理返回错误时保留 FAILED，禁止下一次 Prepare。

停止时首次进入策略页才加载真实配置与 provider，不请求 VPN 授权、不建 TUN。预览回调仅许可当前代次的普通网络，不调用 `VpnService.protect`，仍受系统路由和其他 VPN 影响；原生 debug 计数 `protected` 在预览下仅表示该回调接受 socket，不证明 Android protect 已执行。显式启动时先授权，再完整释放预览，确认后以 VpnService 回调重新 Prepare／Attach。不保留旧连接池、不提供只 Detach 的路径，因此可能重复解析、读取缓存和健康检查。正常停止仍完整释放；策略页可见时再按需加载预览。

Activity `onStart/onStop` 驱动真实可见性，不以 `onPause` 或切 tab 释放预览。不可见且没有已受理业务时保留 30 秒，延时及排队清理执行前核对可见性、业务、上下文代次和 VPN 状态；重新可见取消未执行清理。已开始释放则等待完成。系统冻结不保证准时回收，保留期间 provider 可继续工作；运行 VPN 不受闲置回收影响。偏好保存不依赖 timer 或退出回调。

[策略业务](../lib/features/strategies/strategy_actions.dart) 在每个 ConfigEntry 的 `choices` 保存 `{组名: {type, member}}`；自动组显式 `member: null` 表示恢复自动，缺记录表示遵循配置默认。`choices` 必须是映射，无偏好时保存空映射；字段缺失或内容非法按损坏处理，不兼容旧开发格式。改变选择不增加正文 revision。继续使用共享 core home，但选择隔离由客户端记录承担；关闭内核 `store-selected`，避免其只按组名索引的进程级缓存二次覆盖偏好，不靠切 home 伪造独立选择库。

[Go 策略接口](../native/mihomo/internal/engine/strategies.go) 返回真实组、有效 provider 成员、类型、hidden、now／fixed、GLOBAL 引用和未恢复原因。顺序沿用默认 provider 的原始组序；普通查询不主动测速或 Touch。自动组仅投影 adapter 自身 JSON 的 now／fixed，load-balance 不伪造 now。GLOBAL 按真实组对象、顶层规则及全部子规则目标判定，不把普通同名节点或子规则集名当作引用。

Prepare 初始化 provider 后使用 `ForceSet` 恢复有效偏好；手动固定使用官方 `Set`，恢复自动使用 `ForceSet("")`。无效偏好遵循默认并返回提示，不替用户猜替代。选择前后核对代次、组类型及成员，自动组按 fixed 确认，select 按 now 确认，不断旧连接。JNI 选择请求使用带长度的 UTF-8 `byte[]` JSON，避免 modified UTF-8 破坏 emoji。

[StrategyCalls](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/StrategyCalls.kt) 的读取／选择／准备期限分别为 3／10／45 秒，选择为 fallback 官方 Set 的潜在测速留出时间。超时只结束等待，不走启停超时的停 VPN 路径；已执行的操作迟到完成只通知重读。准备取消只使自身 lease 失效，返回后清理；已 READY 但尚未交付的过期请求排队清理，并再次核对 lease，不能清理后来的 VPN。同步 Parse 无法强行中断。

[CoreHostTest](../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/nativecore/CoreHostTest.kt) 覆盖可控时间／队列下的闲置、返回、业务及换代竞争；[StrategyCallsTest](../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/app/StrategyCallsTest.kt) 覆盖超时、取消和迟到结果。NativeCoreFailureTest 的真实 JNI 预览用例另检查中文／emoji 恢复、切换及未附着 TUN。这些测试不替代实际系统授权或全部协议资源验证。

## 有界近期连接

UI 通道的 `connections` 只查询 Dart 逻辑 Engine 已有的业务快照；[ConnectionObserver](../lib/features/connections/connection_observer.dart) 在接管期间约每秒一次、完成后再调度，失败采用 1／2／5／10／30 秒退避。[ConnectionWindow](../lib/features/connections/connection_window.dart) 负责容量、失活归并、15 分钟过期与速度；不在 Kotlin 实现业务 collector。UI 的可见性只影响业务快照读取，不停止后台观察。平台提供 `SystemClock.elapsedRealtime()`，速度按同一连接两次有效累计值与实际单调间隔计算，壁钟只用于展示。

业务快照携带按既有单调时间计算的 `sampleAgeMs`。UI 用本地 Stopwatch 计入查询往返与接收后的经过时间，并在剩余 5 秒有效期耗尽时主动通知失效；重复读取同一个样本不能重新获得完整有效期，年龄缺失或非法不能视为新鲜。不增加平台采样或轮询通道；列表、搜索与详情均随最新观察更新，不提供手动暂停或冻结展示，失败、过期与身份失效则禁止沿用有效速度或断开操作。

记录的状态／速度更新直接复用不可变字段，不经 Map 重新解析；Dart 逻辑 Engine 向 UI 传递 `startMicros` 微秒时间戳，避免每轮逐条格式化再解析 ISO 时间，Go 输入的 ISO 时间仍在接收时解析。列表仅在成员、顺序或行布局可能变化时重算阅读锚点，纯等宽数值更新复用顺序；详情覆盖列表期间不重排底层列表，返回时同步最新数据。

[ConnectionsCalls](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/ConnectionsCalls.kt) 在 `CoreHost.worker` 调用专用 JNI 接口。受理、执行与交付分别核对 CoreHost generation、配置 ID、revision、VPN 用途和真实 RUNNING；不混用 NativeSession generation。查询与单条关闭各有一个在途槽，平台等待 3 秒、Dart 外围 5 秒；超时只结束等待，worker 未退出前不放开对应槽。读取失败不停止 VPN，不开放 HTTP controller。

[应用 Go 查询](../native/mihomo/internal/engine/connections.go) 使用上游 Range／Get，排除 `Inner`，以容量为 1000 的堆选择最近开始的连接，不先生成全部 tracker 的数组或 JSON。请求携带至多 1000 个上次活跃 ID 和 1 个详情 ID，返回至多 1000 行、1 条额外详情、明确 presence 和完成标记。仍存在但未入选属于容量淘汰，不转失活；确认不存在才由 Dart 归并。容量淘汰后不维护隐藏的无限 ID 集，重新入选重新建立速度基线。

请求最多 64 KiB，单条投影最多 4 KiB，响应最多 8 MiB；先限制 UTF-8 文本与链条数再编码，截短展示字段带标记，ID、开始时间和计数不截断。候选／投影与业务窗口有界不等于整个进程内存恒定：JNI／Kotlin／Dart 会产生传输副本，上游遍历也有临时开销，扫描成本仍随真实连接数增加。`NativeCore.snapshot()` 已收窄为状态与累计标量，不再返回全量连接；debug 状态页沿用该摘要。

图标描述在显示字段截短前取得：应用 Go 从完整原始链末尾向前查找首个真实 `ProxyGroup`，投影最小 `strategy: {type, icon}`；类型与 `Icon()` 来自上游公开 API，hidden／GLOBAL 不按展示过滤丢弃。没有真实组时，仅精确 DIRECT／REJECT／REJECT-DROP 使用相应内置类型，不按名称包含关系猜测。连接图标 URL 原始 UTF-8 或 JSON 编码超过 1024 字节时整项省略并标记 `fieldsTruncated`，类型仍保留，不请求被截断的 URL。描述随 Dart 序列化、状态复制、历史与额外详情保留，沿用既有配置／revision／generation／会话隔离，不增加策略轮询。

UI 的共享 [StrategyIcon](../lib/features/strategies/strategy_icon.dart) 使用 SDK 内置图标与配置图片；[StrategyImage](../lib/features/strategies/strategy_image.dart) 限制下载后交给 Flutter 位图解码或 SVG 渲染。锁定版 `flutter_svg 2.3.0` 的失败 pending 缓存不能由 `evict`／`clear` 移除，见[回归复现](../test/features/strategies/svg_cache_test.dart)；最小适配通过 `vector_graphics_compiler 1.3.2` 公开 API 编译成功字节，再由公开 `BytesLoader` 交给原渲染器，不修改第三方源码、不引入磁盘缓存。组件销毁／来源变化关闭自身请求，迟到结果不覆盖新来源；图片访问按实际平台网络路由，不承诺必直连或必代理。

单条断开由 UI submit → [ConnectionActions](../lib/features/connections/connection_actions.dart) → 平台受检变更 → JNI → 应用 Go 执行，不经过配置保存或全局 stop。只接受原会话的精确 tracker ID；Get 缺失为 `absent`，Close 无错误为 `closed`，底层 Close 错误为 `failed`，即使 tracker 已被上游移出集合也不改判成功。超时／身份变化为未确认，不自动重发；结构化结果以操作 ID 关联原详情。

命令复用同一 Engine，每次重新取得 owner 与 runInput；超时先撤销修改权限，写配置前与原子 rename 前核验 owner。单写者门闩保持至 Dart 执行真正退出，不因服务结束并发创建另一 Engine。取消时原生等待回包以错误结束，避免常驻 Engine 遗留永不完成的 MethodChannel 回调。

Range／Get 不是原子快照，可能漏短连接或拒绝，也不提供精确结束事件与最终计数；不通过重复扫描凑满容量。产品容量与保留语义见[连接观察边界](product-requirements.md#连接观察边界)。[ConnectionsCallsTest](../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/app/ConnectionsCallsTest.kt) 覆盖身份变化、超时、迟到与槽位；[Dart 窗口测试](../test/features/connections/connection_window_test.dart)及[观察测试](../test/features/connections/connection_observer_test.dart)覆盖容量、速度和停止后过期。

设备验证复用 `/strategies` 或 `/modes` 与 `/hold/`：正式入口启动后建立两条长连接，只关闭详情指定的一条，核对另一条与 VPN 保持；后台产生／结束连接，再返回查看近期记录。核对实时更新、组合筛选、详情返回、停止后留存与 15 分钟过期释放，以及新接管清空窗口。HTTP 请求标识不是 tracker ID，需关联目标／源端点、时间与服务端日志。资源测量以持续接管、固定连接量和时长为主；debug 与 release 分别记录，不以编译或 debug 探针代替 release 正式入口验收。

## 总览流量摘要

既有Go连接采样回复同时携带 `DefaultManager.Total()` 的 `uploadTotal`／`downloadTotal` 和扫描中的 `activeCount`，不增加Range或JNI调用。累计值为进程级全局转发统计，不由有界行求和；活跃数排除Inner，不受返回行数上限影响。Kotlin仅转发标量并附加身份和单调时间。

[TrafficWindow](../lib/features/overview/traffic_window.dart) 由同一个ConnectionObserver持有，计算差分并保留最近30秒、最多31点；不改变近期连接的15分钟留存，不为速度摘要增加停止后的Engine保留理由。UI通过 `traffic` 查询小型业务快照，不搬运完整连接列表，不影响连接详情固定。LogicEngineHost复用查询在途/期限保护，停止且没有Engine时直接返回空状态，不启动预览。

[TrafficController](../lib/features/overview/traffic_controller.dart) 仅在总览网络区可见且前台时读取，使用本地单调计时使等待/退避期间的旧读数失效并裁剪过期历史。缺失的上传、下载和计数字段分别失效，不影响其他摘要字段或既有连接观察；整包错误仍遵守原有身份与完整性规则。产品语义见[总览网络活动](product-requirements.md#总览网络活动)。

## 构建与自动化验证

环境要求和 Flutter 构建命令见 [README](../README.md#开发)。Gradle 调用 [Bash 构建脚本](../tool/build_android_core.sh)，生成并打包 `arm64-v8a`、`x86_64` 各自的 `libmihomo_bridge.so`。内核版本从 [go.mod](../native/mihomo/go.mod) 读取并注入。

使用 `cmfa` 构建标签，跳过上游 Android 包规则扫描；TUN 由 VpnService 建立，不使用按应用路由。`protectSocket` 使用 `Keep` 注解，防止仅被 JNI 调用的方法遭到 release 裁剪。

在仓库根目录执行：

```bash
GOTOOLCHAIN=local go -C native/mihomo test ./...
GOTOOLCHAIN=local go -C native/mihomo vet ./...
./android/gradlew -p android :app:testDebugUnitTest
python3 -I tool/native_fixture.py --self-test
python3 -I -m unittest discover -s tool/tests -v
```

另行运行竞态检测：

```bash
GOTOOLCHAIN=local go -C native/mihomo test -race ./...
```

已知上游限制，分别跟踪并保留检测失败结果：

- mihomo `v1.19.32` 的日志等级存在未同步读写，配置应用与后台日志可能触发 `log.SetLevel` / `log.print` 竞态。
- 运行时模式沿用官方 `tunnel.SetMode`，与 `resolveMetadata`／`logMetadata` 对模式变量的读取没有共同同步；应用 worker 和 Engine mutex 不能修复上游流量读取，Suspend 也不是等待屏障。当前采用官方接口并保留这一限制，不维护内核补丁。[模式测试](../native/mihomo/internal/engine/mode_test.go) 的 `TestModeConcurrentRouting` 用 loopback 连接覆盖共享路由路径，可通过 `go -C native/mihomo test -race ./internal/engine -run TestModeConcurrentRouting -count=1` 单独检查。

- 策略选择沿用官方 `Set`／`ForceSet`，上游 select、url-test、fallback 的选择字段没有与所有流量读取共用同步。[策略并发测试](../native/mihomo/internal/engine/strategies_test.go) 的 `TestStrategyConcurrentReads` 已检测到 Selector.Set／selectedProxy、Fallback.Set／ForceSet 与 findAliveProxy 的冲突；不能据此宣称本次必然复现了每一种自动组的全部竞态。
- 自动组测试还检测到延迟历史 `common/queue.Queue.Last`／`Put` 竞态；它与模式变量、选择字段分别记录，应用队列不能修复这一上游共享数据问题。

普通测试通过不等于竞态已消除；上游选择接口的取舍也不豁免资源泄漏或旧 provider 污染新上下文。[解析失败回归](../native/mihomo/internal/engine/provider_cleanup_test.go) 的 `TestParseFailureClosesAllocatedNodes` 目前失败，完整普通测试同样不能报告全绿。

release 包应保留 JNI 方法与回调，不包含验证 Activity 和测试配置；同时检查 ELF LOAD 段与 APK 的 16 KB 对齐。

## 设备验证

### 连接资源测量

[Dart 分段基准](../tool/connection_benchmark.dart) 覆盖普通／长字段、1000 活跃＋500 非活跃的合并、裁剪和业务快照往返；[Go 基准](../native/mihomo/internal/engine/connections_benchmark_test.go) 测量有界查询与字段投影，使用索引 Get，避免将测试夹具的线性查找计入生产成本。

```bash
BENCH_DIR=$(mktemp -d)
dart compile exe tool/connection_benchmark.dart -o "$BENCH_DIR/connections"
"$BENCH_DIR/connections"
GOTOOLCHAIN=local go -C native/mihomo test ./internal/engine \
  -run '^$' -bench '^BenchmarkConnection' -benchmem -count=3
```

[平台转换诊断](../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/app/ConnectionProjectionBenchmarkTest.kt) 可按下节仪器测试方法单独运行，`ConnectionBenchmark` 日志只输出数量、字节及耗时；不以设备相关毫秒值作为测试通过门槛。

设备对照使用相同配置、构建模式、实际连接数、发送频率及稳定测量时长，分开记录建连阶段、列表、详情、总览与后台。负载程序的总期限须包含建连，记录实际成功数量，不把请求数量当作成功数量。隔离传输成本时，由测试端切换发送开关而不暂停进程，确认连接数保持不变，并用恢复发送的反向对照核验。CPU 使用固定窗口累计时间差，内存结合 PSS／RSS、可取得的各堆指标及重复周期趋势；单次高水位或 Engine 释放不等于内存泄漏或操作系统已回收所有页面。主机算法基准不能替代设备结果，也不能将全部进程资源归因于连接观察。

### JNI 错误路径

[NativeCoreFailureTest](../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/nativecore/NativeCoreFailureTest.kt) 使用 AndroidJUnitRunner，覆盖参数拒绝、system stack 构造失败时的 FD 消费，以及 protect 返回 false／抛异常后的清理与恢复。测试自行建立 loopback provider，不需要局域网测试端或 VPN 授权；这些是故障注入，不代表 Android 自然拒绝保护。

instrumentation 会重启目标进程。执行前正常停止本应用 VPN，并确认设备没有其他正在使用的 VPN；不要用测试启动造成的进程退出代替停止验收。

```bash
./android/gradlew -p android :app:assembleDebug :app:assembleDebugAndroidTest
SERIAL='<ADB设备序列号>'
adb -s "$SERIAL" install -r build/app/outputs/apk/debug/app-debug.apk
adb -s "$SERIAL" install -r -t build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb -s "$SERIAL" shell am instrument -w -r \
  -e class io.github.monadboxlab.clashpseudo.nativecore.NativeCoreFailureTest \
  io.github.monadboxlab.clashpseudo.test/androidx.test.runner.AndroidJUnitRunner
adb -s "$SERIAL" logcat -d -s NativeCoreFailureTest:I '*:S'
```

核对 runner 的测试结果，不只看 shell 返回码。每条路径在同一进程重复三轮；日志记录 PID、停止后的 FD 数和测试线程数，用于检查增长趋势。[AppBridgeResultTest](../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/app/AppBridgeResultTest.kt) 另覆盖迟到授权回调、旧操作结果及过期成功反馈；去掉上述 `-e class ...` 可运行所有设备测试。

[AuthorizationRecreationTest](../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/app/AuthorizationRecreationTest.kt) 实际启动并重建 Activity，再取消系统授权，核对原请求只结束一次。需先在系统 VPN 设置中撤销本应用授权；已有授权时该用例会跳过，不能把跳过报告为通过。当前按钮查找使用英文设备的 `CANCEL`，其他语言需相应适配。测试不自动更改系统授权。

### 正式界面闭环

测试端实现按职责位于 [tool/native_fixture/](../tool/native_fixture/)，命令入口与 `--self-test` 保持稳定。正式 MainActivity 的导入框可输入 `http://<HOST>:18880/config`，确认 HTTP 风险后保存。端点只使用受控测试数据：

| 路径 | 场景 |
| --- | --- |
| `/config`、`/direct` | 完整配置，分别按规则代理 HTTP 或直连 |
| `/modes` | 正文为 direct；规则走受控 SOCKS，GLOBAL 拒绝，用于区分三种实际模式 |
| `/strategies`、`/strategies-other` | 两个独立来源，规则指向包含 DIRECT／REJECT／受控 SOCKS provider 的 select，另有嵌套父策略、url-test、fallback、load-balance 与 hidden 组 |
| `/strategies-changing` | 使用两秒更新的 provider；`/strategy-provider-update` 前五次返回 fixture，后续替换为 replacement，用于成员失效与重新加载回退 |
| `/slow-config` | 延迟 8 秒，用于离开 UI 后继续执行及重开查询 |
| `/redirect` | 相对重定向到完整配置 |
| `/update` | 每次请求返回不同修订注释，用于同 URL 覆盖 |
| `/update-fails` | 第一次成功，后续 HTTP 503；重启 fixture 重置计数 |
| `/invalid`、`/empty`、不存在的路径 | 分别为不可解析正文、空正文、HTTP 404 |

首次导入应选中但不启动，重复来源先确认覆盖。运行中切换到 `/invalid` 后应停旧、报错并保持停止；候选更新失败不能打断当前运行。当前项更新失败后禁止再用旧正文启动。离开并重开延迟下载时，以测试端请求数和 `PseudoWork` 的 operation ID 核对没有重发；结束后 `dumpsys activity services` 不应残留 `AppWorkService`。

授权需分别验证取消、同意及 Activity 重建；等待超时后旧授权结果不能完成新的请求。普通返回不等于 force-stop，异常进程结束应单列。release/AOT 也要实际导入、启动、离开重开与停止，不能用 debug 或编译结果替代。正式入口启动的 debug VPN 可用下述验证页仅发起流量检查，不再点击该页的启动按钮。

### 模式接口与验证

模式业务复用唯一 Dart 逻辑 Engine、配置存储和 operation 互斥。保存值在 `configurations.json` 顶层；Prepare 接收明确模式并覆盖已解码运行副本，原文不变。运行中通过 JNI 调用轻量 Mode／SetMode，不开放 HTTP controller、不查询连接列表。

`ModeCalls` 与启停等待分开，复用 `pseudo-native` worker，以 generation 和取消标记隔离旧会话。读取期限 3 秒、修改期限 5 秒；超时只结束等待，不停止 VPN。排队请求可取消，已进入 native 的调用完成后通知 UI 重读，不能把超时等同于撤销修改。模式查询失败保留真实 RUNNING，前台退避重读；业务规则见 [运行模式](product-requirements.md#运行模式)。

[ModeCallsTest](../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/app/ModeCallsTest.kt) 在设备上覆盖排队取消、超时、迟到完成与代次隔离；[NativeCoreFailureTest](../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/nativecore/NativeCoreFailureTest.kt) 包含模式 JNI 往返与非法输入检查。执行前正常停止 VPN，沿用上述 instrumentation 命令选择测试类。

测试端 `/modes` 正文为 `mode: direct`，规则将 HTTP 走受控 SOCKS，显式 `GLOBAL` 组仅含 REJECT。客户端选 rule 启动后，用唯一请求标识核对 SOCKS／HTTP 收包；热切 direct 后 HTTP 直达，切 global 后新连接拒绝。先用验证页打开 `/hold/`，切 global 后核对原连接仍持续收数，正常停止后才结束；热切过程中 PID／generation 不变，任务服务完成后释放，逻辑 Engine 在接管期间保留。这个场景验证 TCP，不代表所有 UDP 协议均已设备验收。

同时检查停止预选、重开不自动启动、换配置／更新保持保存模式、保存与实际不一致提示，以及 release 正式界面闭环。存储失败、超时和迟到回调用自动化故障注入覆盖，不通过破坏设备设置制造故障。

### 策略闭环检查

1. 导入并选择 `/strategies`，只停留总览时核对 core EMPTY、未建 TUN。进入策略页加载真实组，在停止状态预选 fixture，不自动启动；确认成员浮窗从父卡片原位展开且选择后保持打开；父策略中的成员组只能选择、不再进入，返回、关闭或点击窗外关闭唯一浮窗并恢复来源卡片。检查快速打开关闭、长列表滚动及来源失效时无残留遮罩或隐藏卡片。
2. 切页、短暂离开和超过 30 秒分别检查同代次复用、释放及返回后重载恢复。debug 验证页显示 CoreHost 和 NativeSession 两种身份，不把 PREVIEW READY 当作接管运行。确认业务完成后没有 AppWorkService 残留。
3. 显式启动后核对新 VPN 上下文、真实组选择和 TUN。先建立 hold TCP，再分别选择 fixture／DIRECT／REJECT；使用“仅检查 TCP”生成唯一 ID，对照服务端 proxy／HTTP 记录，REJECT 不能收到该 ID。旧 hold 应持续输出 `HOLD_ALIVE`，VPN generation 不变，正常停止才结束。切前后台可用 `am start --activity-reorder-to-front` 保留 debug 探针 Activity，避免将测试端销毁当作策略断连接。
4. 检查自动组固定／恢复自动、load-balance 无唯一选中、hidden／GLOBAL 过滤；两个配置同名组偏好独立。成员消失后重新加载应回到默认并提示未恢复，保留原偏好。
5. debug 与 release 正式界面分别验证预选、启动、选择、停止及重开；截图后立即目视检查。大字体与深浅主题的 widget 测试不替代设备检查，设备已授权不等于覆盖首次授权前场景。

[延迟 provider 回归](../native/mihomo/internal/engine/engine_test.go) 的 `TestLateProviderResponseCannotReplaceNewContext` 在共享 home 下保持旧 HTTP 更新响应，停止并加载新上下文后再送出旧响应，核对新成员不被覆盖。它只覆盖这个受控 HTTP 取消路径，不证明 Provider.Close 同步等待了所有解析或全部协议。

### 实际 VPN 接管

[测试端](../tool/native_fixture.py) 提供 HTTP、UDP、DNS 和 SOCKS5 TCP。SOCKS 只转发到自身 HTTP 端口，接受本机 IP 及映射到自身的 `.fixture.test` 域名。

先安装 debug APK。以下命令从仓库根目录执行，将占位值替换为实际地址和 `adb devices -l` 中的设备序列号。

终端一：启动测试端，保持运行。

```bash
HOST='<设备可达的开发机局域网IPv4>'
python3 -I tool/native_fixture.py --host "$HOST" --port 18880
```

终端二：使用相同的 `HOST` 打开验证页。

```bash
HOST='<与终端一相同的IPv4>'
SERIAL='<ADB设备序列号>'
adb -s "$SERIAL" shell am start \
  -n io.github.monadboxlab.clashpseudo/.debug.NativeCheckActivity \
  --es host "$HOST" --ei port 18880
```

从验证页授权、启动、发起流量和停止。端口从 HTTP 基准依次偏移：UDP `+1`、DNS `+2`、SOCKS `+3`、拒绝规则目标 `+4`。代理场景的 TCP 测试走 SOCKS，UDP 直连。

验收时关联页面请求标识、内核连接与测试端收包：

1. 授权取消不建 TUN；授权同意后验证 TCP、UDP、DNS 和拒绝规则，另用浏览器访问 `/ok/<唯一标识>`。
2. 保持长连接后停止，核对连接断开、服务退出；同 PID 至少停启三轮并比较停止后的 FD 数。
3. 验证 provider 正常更新、首次失败及在途停止；停止后跨多个周期确认无新请求。
4. 验证重复启动、无效配置、Activity 离开重进、系统撤销与异常进程结束；重开页面只查询，不自动启动。

结束时停止本应用 VPN 和测试端。授权、TUN 建立及保护回调的系统失败，与单元测试故障注入分别记录。

## 当前边界

当前使用 `system` 栈、IPv4 全路由与 DNS 接管，IPv6 由 Android VPN 策略阻断。正式入口支持远程完整配置；provider 加载失败是否继续遵循 mihomo 行为，不另建完整预校验。

职责分割不等于平台适配已经完成。[运行配置管理](../native/mihomo/internal/engine/platform.go) 按 Android 托管入口调整配置，[TUN 附着](../native/mihomo/internal/engine/tun.go) 接收宿主传入的文件描述符，[原生导出](../native/mihomo/exports_android.go) 面向 Android；这些不能直接视为 Windows 的通用接管实现。当前 [Windows 宿主](../windows/runner/flutter_window.cpp) 仍主要承载 Flutter 窗口，尚未接入对应业务宿主与接管能力。共享 Dart 业务和界面可作为复用基础，但其他平台的权限、后台承载、接管及进程部署须在对应阶段决定并验证，不要求照搬 Android 服务，也不提前建设通用平台框架。

[平台字段管理](../native/mihomo/internal/engine/platform.go) 只修改解码后的运行副本：应用关闭配置指定的端口、controller、额外 listener/server、DNS 外部监听、UI 下载及系统级操作，保留节点、组和规则。HTTP provider 的自定义缓存路径被移除，file provider 路径限制在内核资源目录并检查符号链接。Android 原生 logrus 输出被关闭，正式错误出口只给安全的阶段消息，不将原始来源／凭据写入 logcat；当前不提供完整内核日志诊断。

**信任模型**：信任用户选择的完整配置来源、provider 及后续更新，只使用可信来源。上述平台字段、provider 路径和隐私保护继续适用，但不把恶意完整配置当作不可信程序进行严格文件沙箱隔离。`cmfa` 会跳过上游 `IsSafePath` 检查，SSH 私钥、TLS 证书等节点内部文件引用不受 provider 路径限制完整覆盖，动态 provider 也存在这些入口；这不意味着突破 Android 应用沙箱。完整文件隔离不属于当前产品承诺，不为此增加预校验、协议扫描器、独立进程或内核 fork。

已知的配置失败限制：

- [WireGuard 构造函数](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/adapter/outbound/wireguard.go#L467-L507) 可先创建协程，再因远程 DNS 参数解析失败返回，缺少相应关闭；这是源码确认的构造失败路径，不与下述已执行回归混为同一个场景。
- 配置成功构造 WireGuard 节点后，后续规则解析失败时，上游 `ParseRawConfig` 返回 nil／error，调用方拿不到已分配节点。`TestParseFailureClosesAllocatedNodes` 在关闭自动 GC、排除 finalizer 掩盖后复现：Prepare 失败，Stop 返回成功，等待两秒仍有一个 WireGuard encryption worker（基线为零）。当前应用也可能因此把未完整释放的上下文报告为空闲；此缺陷未修复，**阻塞完整生命周期验收**，不能只记录成已接受的选择竞态。复现命令为 `go -C native/mihomo test ./internal/engine -run '^TestParseFailureClosesAllocatedNodes$' -count=1 -v`，该回归保留失败。
- [provider 节点清理回归](../native/mihomo/internal/engine/provider_cleanup_test.go) 的成功加载／停止用例验证 inline WireGuard 节点反复停止后 worker 退出；它不覆盖构造中途失败或全部协议。不以协议白名单、预校验或强制 GC 掩盖这些资源问题；当前不维护内核 fork，也未通过升级改变这一边界。

arm64 真机、最低 API、16 KB 设备和长期后台行为需要对应设备验收；具体测试结果记录在验收汇报中。许可与来源见 [NOTICE](../NOTICE.md)。
