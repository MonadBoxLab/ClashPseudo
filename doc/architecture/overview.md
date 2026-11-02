# 应用架构与职责

业务操作依次经过 **UI → Android AppBridge受理 → Dart AppRuntime执行 → 平台文件发布或CoreClient内核请求 → 结果回读**。AppRuntime是唯一Dart业务执行者，发起ConfigStore、OverrideStore和PreferencesStore的全部写入。Android管理系统组件、传输和实际取得的资源；独立的`:core`进程承载Go与mihomo。

默认进程不加载Go。配置合成、语义解析、预览、启动、provider与Geo更新、DNS、测速和诊断均经非导出AIDL进入`:core`。大输入和逐条结果通过受限FD传输，薄JNI只承担同进程字节交接、公开内核调用和Android callback。

产品任务入口见[产品范围](../product/overview.md#功能范围)，字段与操作协议见[数据与操作](data-and-operations.md)，Engine、Service 和 VPN 部署见 [Android 接入](android.md)。

## 职责划分

| 层 | 负责内容 | 主要入口 |
| --- | --- | --- |
| Flutter UI | 页面、草稿和焦点管理，读取并显示数据，提交用户请求 | [App](../../lib/src/ui/app/app.dart)、[AppController](../../lib/src/ui/app/app_controller.dart) |
| Dart业务执行者 | 下载、业务校验、配置／插件／偏好写入、实际运行输入、策略恢复、DNS操作、测速批次、搜索分页，以及连接／流量／日志窗口；通过注入的接口执行平台操作 | [AppRuntime](../../lib/src/logic/app_runtime.dart) |
| Dart 模型与接口 | 业务值、身份、传输结构、格式预算、PlatformPort及AppPlatform操作接口 | [model](../../lib/src/model) |
| Dart 平台适配 | 唯一后台bootstrap、Flutter binding、MethodChannel，以及不依赖Flutter的内核输入和FD客户端 | [AppBootstrap](../../lib/src/platform/app_bootstrap.dart)、[platform](../../lib/src/platform) |
| Android 宿主 | Engine／Service／Worker、权限、操作身份与期限、文件访问锁、VPN和FD | [Android 源码](../../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo) |
| Go 应用衔接 | Compose、平台所需默认值、公开parser调用、生成平台规格及管理内核资源 | [native/mihomo](../../native/mihomo) |

ConfigStore、OverrideStore、PreferencesStore 各自读取和校验所属业务文件，写操作统一由 AppRuntime 发起。Android 处理文件发布、归档完整性和流式预算，Dart Store 检查记录与业务关系。UI Controller 维护读取、展示和草稿，提交命令后通过结果回读更新页面。

查看内核数据时，UI读取AppRuntime提供的snapshot或提交查询意图。AppRuntime持续采样连接、流量和日志；Go导出公开对象，搜索、分页、测速批次和历史窗口不在Go重复维护。页面隐藏时暂停对应页面的读取，已受理的业务、文件写入和网络服务继续执行。

## Process layout

| 进程 | 组件与lifecycle |
| --- | --- |
| 默认应用进程 | Flutter UI、唯一AppRuntime、LogicEngineHost、AppBridge、CoreClient及应用侧文件／系统接入。AppRuntimeService供系统先创建的VpnService接入同一业务执行者；AppWorkService只承载有限订阅工作。 |
| :core | 非导出CoreService、PseudoVpnService、Go与mihomo、实际TUN和代理监听。Service共享一个内核宿主，每个进程只装载一个PREVIEW或运行context。 |

绑定只建立通信，不解析或装载配置。预览转运行、完整重连、VPN切换及异常恢复使用新进程；模式和策略热操作使用当前context。局域网服务与VPN各自记录开启意图和实际状态，同一运行context可以提供其中任一项或两者。

内核异常退出后，默认进程终结旧请求，保留页面、草稿、阅读位置和已完成的保存。普通调用失败、通信中断、已确认process death、主动停止和系统撤销分别记录。异常恢复由用户明确发起；常开入口不反复装载已经失败的输入。

## 调用与数据流

### 保存、选择和更新

1. UI记录目标ID、revision、storageEpoch及本次草稿，提交命令。
2. AppBridge 受理并分配 owner／operationId，检查是否有冲突操作仍在执行，并记录期限。
3. AppRuntime 执行下载、转换、Store 校验和保存；需要改变运行输入时，继续协调旧资源释放及本次应用。
4. 平台在执行、发布与回执边界复核 owner。保存结果携带 targetId／savedRevision，应用和整体结果分别记录。
5. UI 回读结果，由原页面显示；页面已关闭时交给全局结果显示逻辑。

操作是否受理、文件是否保存、输入是否应用，以及执行任务是否结束分别记录。异常处理按[操作结果](data-and-operations.md#操作身份与结果)保留已经完成的保存，并说明应用或后续步骤的失败。

### 启动和停止

显式启动读取完整保存组合，在发布输入或结束旧进程前校验应用策略选择及静态预算，再原子发布带inputId的不可变运行输入，建立新`:core`进程并装载。Go完成一次合成、一次RawConfig解析及必要缺省、一次正式解析和一次公开hub装载；Android根据同次规格建立TUN，并交给公开TUN构造器。PREVIEW保留实际代理、规则、provider与解析器，但不启动外部监听、Controller、UI下载、TUN或NTP。成功、失败或停止后的Engine均不再准备第二个context，完整装载必须使用新进程。

停止时先记录退出原因并停止受理新工作，关闭本方资源、发出公开关闭请求，随后由`:core`结束自身进程。完成停止以对应DeathRecipient及默认进程所属I/O退出为准；公开关闭返回、Service解绑或通信超时均不能代替process death。控制通道无响应时保留未确认并提供重试，不按旧PID结束其他进程。

系统撤销VPN时，Android先关闭TUN并捕获原process／input身份。READY且仍有局域网开启意图时，revoke操作保留原受理时点和deadline，撤销旧owner，等待原执行任务、请求及文件I/O实际结束，再由AppRuntime按原实际输入建立LAN-only新进程。等待不重新计时，期限到达时记录未完成并请求旧进程退出；STARTING或没有可保留局域网服务时不继续装载LAN-only。

## 内存读取

应用RSS来自默认进程的ProcessInfo.currentRss；内核RSS经已有连接读取`:core`的公开memory.GetMemoryInfo(os.Getpid())。两项分别持有请求、采样时间、错误、5秒有效期及刷新任务，不与流量采样串行等待，也不相加。内核项绑定实际processId，进程变化使旧采样失效；没有core process时不为内存采样启动进程。应用项在内核停止或内核读取失败时仍可刷新。

## Resource ownership

| 所有权 | 创建／捕获点 | 结束条件 |
| --- | --- | --- |
| 业务操作 | 接受命令并分配operationId | 分别记录结果和执行结束；写入前检查owner是否仍有效 |
| core process与context | 随机processId、generation、inputId、composition及purpose | 确认所属process death，并等待默认进程所属I/O退出 |
| VPN与局域网监听 | Android建立TUN；公开构造器返回实际监听对象 | 对应资源关闭；完整context替换另等原进程退出 |
| UI 任务／表单 | 进入任务或打开编辑 | 页面开始关闭时禁用操作；已提交业务继续执行并记录结果 |
| 观察与查询 | retain、分页、DNS 或详情请求 | 对应owner已释放，且相关调用已经返回 |

资源创建或接受时登记清理动作，部分失败回收已取得项。关闭callback使用捕获的代次；新实例和新会话保留各自资源。字段见[数据contract](data-and-operations.md)，内核回收见[内核接入](core-integration.md#context-and-preview)，FD 交接见 [Android](android.md#fd-and-jni)。

## 目录与模块

Flutter入口为[lib/main.dart](../../lib/main.dart)。UI入口创建界面；appBackgroundMain进入[platform的runBackground](../../lib/src/platform/app_bootstrap.dart)，创建后台binding并由AppBootstrap构造唯一AppRuntime、注册通道和发布状态。[logic/background_entry](../../lib/src/logic/background_entry.dart)只接收已经注入接口的AppRuntime并调用start，不创建binding或第二份runtime。

| 目录 | 内容与依赖 |
| --- | --- |
| [ui](../../lib/src/ui) | app、navigation、theme、components、任务页面及 Controller；语言化显示位于 ui/locale |
| [logic](../../lib/src/logic) | AppRuntime、configs／overrides／backup／schedules／connections；storage 负责偏好 Store 和文件 I/O |
| [model](../../lib/src/model) | 记录、snapshot、消息、身份、格式预算及注入接口，无Flutter binding或MethodChannel依赖 |
| [platform](../../lib/src/platform) | app_bootstrap与channel接入Flutter；core及输入编码通过注入接口交接FD，不保存业务窗口 |
| [l10n](../../lib/src/l10n) | ARB 和 Flutter 生成实现，供 ui/locale 和界面使用 |

UI使用logic、model及platform适配。logic及其依赖使用纯Dart接口，可在独立Dart进程中导入并执行；不依赖dart:ui、Flutter binding、MethodChannel或语言化显示。AppBootstrap向AppRuntime注入AppPlatform，AppPlatform持有PlatformPort和CoreClient；MethodChannelPort实现通道调用，PlatformFailure保留错误结构，状态变化通过callback返回bootstrap。业务动作分别调用ConfigStore、OverrideStore和PreferencesStore。

测试按断言所属层归入 [test/ui](../../test/ui)、[test/logic](../../test/logic)、[test/model](../../test/model)、[test/platform](../../test/platform)，跨功能测试共用的模拟实现、数据和辅助工具归 [test/support](../../test/support)。混合测试按模型、I/O、平台解码和显示断言拆分，例子及命令见[自动化测试](../development/build-and-test.md#自动化测试)。benchmark 提供宿主算法测量；tool 提供构建和核验入口；第三方修改源码、通知和数据分别位于 sources、notices、data。Dart 目录约定见[官方包布局](https://dart.dev/tools/pub/package-layout)。

Go 包按单内核职责拆分：

| 包 | 职责 |
| --- | --- |
| engine | 唯一core context、公开调用及实际资源收尾 |
| configinput | 合成、字段来源、字段是否存在及必要默认值 |
| coreview | 读取节点、策略、规则、资源、连接和运行配置，保留公开原始字段 |
| androidnet | Android平台规格、捕获的底层网络与系统DNS接入 |
| ingress | 公开监听与TUN构造的必要平台参数、protect和资源登记 |
| logstream | 日志订阅及有界传输queue，不保存第二份历史窗口 |

Android使用一个应用Gradle模块。bridge/operation持有唯一OperationState与预算；bridge/runtime衔接周期更新、系统恢复及业务snapshot。nativecore管理CoreClient、CoreService、AIDL、FD传输和lifecycle记录；vpn管理实际VPN资源。storage、message与trust分别处理文件、消息和信任材料。Manifest组件、Worker类、JNI类、通道及任务名保留各自系统身份。

## 界面任务与读取

每个界面任务使用固定目的地标识，并保留同一控制器、草稿和读取请求。Bar／Rail、常驻入口数量及单栏／双栏切换只改变布局；设置目录与常驻导航进入同一任务。

外层 MaterialApp 和 AppShell 内部 Navigator 各有 AppTaskNavigatorObserver，记录 push／pop／remove／replace 后的 Route 栈并通知订阅者。五个主任务的 Page.active 由任务选中、app.interactive 和内外根 Page 是否在场共同计算：

- Page 为 active、未 reverse 且 current 时，判为在场。
- 非 current 时，同栈上方全为 PopupRoute 才继续在场；Popup 及其 reverse 期间保留底页。
- 上方再推入 Page 时，observer 通知底页退出在场状态。

[AppTaskActivity](../../lib/src/ui/navigation/task_activity.dart)的 active 是声明式订阅snapshot。`capture(context)` 在来源仍 active 时捕获并订阅同一 InheritedElement，异步callback读取该element当前widget，检查页面是否仍允许操作。默认动作要求原 Route current、active、未 reverse。

自有浮层通过 `isActive(context, ownedPopup: ...)` 关联：observer 核对同一 Navigator、原页上方全为 PopupRoute，且链尾为所持有的 current／active／未 reverse 浮层。等待浮层关闭后清除所持Route，再按原页面是否current、active和未reverse检查。TaskPane 和 FocusedPageRoute 对命中、焦点及语义使用同一条件。

窗口可见但失焦时继续显示必要的状态、流量和连接数据，暂停装饰动效；覆盖或隐藏时暂停对应UI读取。窗口恢复交互后显示原操作结果，原页面已关闭时由全局结果显示逻辑处理。[ReadingList](../../lib/src/ui/components/collections/reading_list.dart)保留仍存在的可见条目及其在屏幕中的位置；输入、语义及退出保护见[通用交互](../product/interaction.md)。
