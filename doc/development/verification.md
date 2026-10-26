# 集成验证与测量方法

本文说明如何验证产品行为、异步身份、资源生命周期、界面及产物。构建和工具调用见[构建与测试](build-and-test.md)，业务要求沿所属[功能规范](../product/overview.md#功能范围)，工程边界沿[架构](../architecture/overview.md)。测试范围按改动和目标能力确定，结果对应实际源码、输入与产物。

## 结果口径

实现存在、构造成功、编译通过、单项回归和完整功能链分别记录。每次验证明确检查对象、输入身份、时序、判据、成功与失败信号、实际退出以及保存／运行结果；通过、失败、未执行、受阻和暂缓各有含义。

验证分别记录SDK动作回执、业务结果、Service／native资源退出、Store一致性及运行意图。回归使用能够区分异常与正常行为的输入，接口条件见[内核公开能力](../architecture/core-integration.md#公开能力边界)。

## 界面与自适应

以窗口逻辑尺寸、局部父约束、TextScaler、安全区和键盘inset解释布局。Android Configuration是SDK上下文，Flutter工作区和控件几何另读；API28+ hintText与层级XML导出内容也可能不同。ACTION_SET_TEXT和预测性节点文字表示系统受理，Dart接受值由应用结果确认，IME测量使用真实delta路径。

按五档宽度和三档独立高度正交取样，并覆盖宽度599／600／601、839／840／841、1199／1200／1201、1599／1600／1601及高度479／480／481、899／900／901，补局部实际门槛两侧。分别记录只改宽、只改高和非等比拖动时的容量与布局。

导航独立检查Bar横向及占高、Rail纵向及占宽、3／4／5入口变化和完整目录；保留同一任务／控制器／查询链。最小支持内容宽高按真实组件和字号校准后，分别检查下限前／等于／后、平台限制／裁剪实际行为和越界恢复，普通Compact与大字完整布局仍须成立。

覆盖中英、浅深、三品牌、1／1.3／2x和代表性非线性TextScaler、长名称／URL／名单、键盘与安全区。等待、成功、失败、重试、选中、禁用、异步刷新、来源失效和恢复检查初始、首帧、过渡、完成、快速反向及减少动效。

集合／详情验证以初次进入、主动选择、展开、关闭和布局转换为顺序，记录请求数量、控制器身份、阅读位置及命中／语义树。并排区域均应更新，隐藏区域按可见性暂停。表单覆盖完整草稿、离屏首错、章节展开及子编辑取消；DNS区分内部切换和工具关闭。

[ReadingList](../../lib/src/app/widgets/reading_list.dart)在debug可用dart-define validationLayoutMetrics=true记录FlutterView、MediaQuery、比例、insets、父约束和文字缩放。检查控件实际位置、尺寸、命中区、语义和存活阅读偏移，计数请求／控制器／写入／attach，结合复杂浮层和真实输入事件。

## 系统与网络集成

Android覆盖按API能力、ABI、页大小、窗口与输入方式选择。系统VPN授权、Activity重建、Service代次、前后台、锁屏和Always-on采用对应真实系统路径；手动回调注入单独标明其竞态覆盖。isAlwaysOn／isLockdownEnabled仅API29+且有可读实例才取值，普通锁屏与首次凭据解锁是不同条件。

| 范围 | 入口与主要判据 |
| --- | --- |
| VPN／FD | [NativeCoreFailureTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/nativecore/NativeCoreFailureTest.kt)：接收／消费／失败回收、实际资源身份和恢复 |
| TCP／UDP | [TCP数据面](../../native/mihomo/internal/engine/tun_tcp_dataplane_test.go)、[UDP数据面](../../native/mihomo/internal/engine/tun_dataplane_test.go)，Android补protect、Network绑定和不同TUN栈实际流量 |
| 模式／策略 | [ModeCallsTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/bridge/ModeCallsTest.kt)，关联保存与实际选择、热切换和完整重连；唯一单连接标识与EOF |
| 应用访问 | 两个独立UID客户端的实际请求，覆盖all／only／except、共享UID、缺包及空有效allow |
| 系统启动 | [SystemStartLifecycleTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/vpn/SystemStartLifecycleTest.kt)：SERVICE_INTERFACE、系统撤权、STARTING取消及实际代次退出 |
| Activity与授权 | [AuthorizationRecreationTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/bridge/AuthorizationRecreationTest.kt)：系统授权取消／同意、重建和请求归属 |
| 通知／Tile／widget | SDK入口与Launcher实际点击分别关联MainActivity焦点、当前运行代次及动作含义 |
| TLS／Geo | [AppTrustAndroidTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/app/AppTrustAndroidTest.kt)、[GeoResourceNativeTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/nativecore/GeoResourceNativeTest.kt)，API根策略、实际TLS正负链和加载／替换 |
| DNS | [DNS回归](../../native/mihomo/internal/engine/dns_tools_test.go)、[诊断UI](../../test/features/diagnostics)，Question／RCODE、取消、缓存请求计数和迟到隔离 |

受控服务的closed／join和应用Stop、连接EOF分别确认。模式选路、内核监听、provider／Geo更新、底层DNS／路由、IPv4／IPv6与TLS每个场景使用归属明确的请求和服务入场信息。TLS覆盖正常、错主机名、坏链、未信CA与pin，宿主链路与实际应用Engine／Go信任分别核验。

DNS取消实验先确认请求进入延迟服务，再触发关闭或身份失效。同一Android uptime下，旧操作至新结果完成应小于4500ms，用于区分5秒自然超时；同时核对新Question／RCODE、控件状态与原请求身份。fake-IP分开检查地址分配、旧地址访问、持久池及控制流，并分别记录IPv4／IPv6结果。

## Worker取消与后台应用

[ScheduleWorkerCancellationTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/app/ScheduleWorkerCancellationTest.kt)使用真实WorkManager、Dart writer和延迟有效正文，分别测config／override。取消后核查owner失效、writer仍忙，真实I/O完成后才开门，并检查正文、revision和元数据。

后台运行项更新关联真实下载、保存、完整实际输入、新UUID和一次重连，未触及字段保持。交接前取消、交接后内部网络约束丢失、用户Stop、撤权和STARTING取消分别通过有界屏障定位；保存回执、applied和真实退出各自核验。手动onRevoke只覆盖回调竞态，系统撤权由VpnService.prepare实际变化确认。

## JNI错误路径

[NativeDescriptorZeroTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/nativecore/NativeDescriptorZeroTest.kt)用独立instrumentation进程检查FD0，先确认raw stdin指向/dev/null，再以F_DUPFD_CLOEXEC取得空闲0。[Zygote标准描述符](https://android.googlesource.com/platform/libcore/+/refs/heads/main/dalvik/src/main/java/dalvik/system/ZygoteHooks.java)与Java FileDescriptor对象分别处理。

FD消费按st_dev／st_ino等身份检查，编号复用与EBADF各有含义。system／mixed用有效普通FD触发TUNGETIFF失败，核查释放、未附着及重新Prepare／Stop恢复。部分创建、取消和回调在途场景等真实close／join后再判可复用。

## 备份与恢复

自动化覆盖[业务恢复](../../test/features/backup)、[逻辑执行](../../test/logic)及[Android备份平台](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/backup)。检查原字节、manifest／CRC／SHA、固定条目、边界与超限、取消、write／close错误、PREPARED／COMMITTED和再次中断回滚。故障注入使用隔离目录，正式用户数据沿正常导入／恢复路径。

SAF检查实际选择、确认、后台返回结果、结果与取消；API24 Downloads集合和本地Download目录是不同入口，确认选中整个ZIP并返回OPEN，再核查应用结果。重新导出比较三业务文件原字节，ZIP时间戳／压缩差异单列。恢复后的epoch、旧草稿／菜单／Worker撤销、保存偏好与最新运行意图分别检查。

JsonReader测试覆盖合法大正文、恶意大键／标量、quoted／unquoted及跨缓冲输入，并记录最低API的真实堆峰值。系统逐文件恢复与主动三库事务按各自协议验证。

## 编辑器与输入性能

覆盖[正文限额](../product/configurations.md#文本限额与换行)的UTF-8、首BOM、混合换行、32768／32769 UTF-16边界、合行、emoji／组合字、整批delta、composing、查找程序赋值、选择手柄、复制粘贴、撤销重做、保存冲突与离开页面／恢复竞态。真实IME和剪贴板路径与注入控制器测试分报。

生命周期回归读取真实field render消费的showCursorNotifier，分别观察销毁、停闪及重启前后的100ms延迟期限。拖拽测试通过实际gesture callback启动自动滚动，在首次滚动后跨越下一回调并移除编辑器。手柄测试使用公开scrollbarBuilder移除field，同时保持overlay controller，以定位起止手柄的render校验。官方归档用于对应负对照，来源见[PATCHES](../../third_party/sources/re_editor/PATCHES.md)。

值准入和批次IME回归检查拒绝前后历史、发布次数、选区／composing及接受值回同步；真实设备另覆盖系统IME、剪贴板、选择手柄和页面退出链。

RE_EDITOR_OBSERVATION=true测量构建在真实updateEditingValueWithDeltas入口、校验前取Timeline.now，正文实际paragraph.draw后记文档版本、修改区、viewport和frameNumber。修改矩形须实际可见，按同一FrameTiming.frameNumber精确配rasterFinish，指标为rasterFinish−t0。

该指标覆盖已接受输入的处理起点至对应帧raster完成，系统IME排队和物理呈现采用各自时间口径。覆盖／合并、可见性、paint／timing缺项、时钟异常及溢出分别计数；采集字段限定为标量ID、长度、范围、版本、帧号与时间。

先以真实输入及前五次150ms受控延迟进行负对照校准，校准通过后，至少采集100个可归属更新计算p95。打开、首次查找、粘贴和保存均测量完整动作至可见结果。普通1MiB内容按自然输入节奏重复，门槛及适用目标在实验开始前确定。

测量构建与正常release采用相同源码、依赖、ABI及优化配置，仅调整观测开关。时间配对使用同源单调时钟，异步进程通过PID／startTicks及开始／结束链识别。记录冷热、次数、命中量、viewport／修改区和系统条件，结合PSS、RSS、CPU差分及重复生命周期分析资源趋势。测量窗口采用独占负载。

时序依据包括固定修订的[Flutter帧入口](https://github.com/flutter/flutter/blob/abaf9c523780a608bd46686fd5e53740a07077f8/engine/src/flutter/lib/ui/hooks.dart#L400-L404)、[raster时间](https://github.com/flutter/flutter/blob/abaf9c523780a608bd46686fd5e53740a07077f8/engine/src/flutter/flow/frame_timings.cc#L202-L230)、[Dart Android时钟](https://github.com/dart-lang/sdk/blob/3.13.5/runtime/vm/os_android.cc#L144-L165)与[Skia TextWrapper](https://github.com/google/skia/blob/8df24be66531469e576a806749a0202ae26b8d08/modules/skparagraph/src/TextWrapper.cpp#L93-L117)。SDK变化时重新核对调用链、时钟转换及帧号配对。

## 覆盖率

### Dart

[采集工具](../../tool/coverage/flutter.dart)使用coverage公共API与官方HitMap／LCOV，[测试配置](../../test/flutter_test_config.dart)在APP_FUNCTION_COVERAGE=true注册root tearDownAll，等测试isolate真实收尾后采集；testMain返回只完成注册。临时library loader纳入未import源码和part，报告分母、排除及未映射项。

覆盖率校准使用已执行／未执行函数、同行函数、漏import、分支两侧及复合条件。纯编译期常量的生成契约列入生成文件排除清单，其业务消费者继续统计。function、line和VM branch分别报告；同行函数可能合并至一个源码入口桶，条件／判定覆盖另以真值表和实际决策结果验证。采集完成要求VM服务可用、实际采集成功及源码分母完整。

### Go、Android与JNI

Go使用生产tags和atomic coverprofile，官方test.gocoverdir传子进程计数，校准ParentOnly／ChildOnly／NeverCalled；statement与具名函数语句命中分报，fatal／os.Exit提前退出未flush缺口单列。

Android报告关联同一variant的class、JVM exec、设备ec和JaCoCo XML／HTML，先用独立样本校准，再统计应用分母。line、method、branch以及Kotlin合成过滤和异常处理分别说明，所有结果注明对应源码及class身份。

JNI测试变体启用Clang source coverage、atomic及MC/DC，实际调用结束后flush profraw，再以对应库、llvm-profdata和llvm-cov处理。项目C、生成cgo、第三方代码及独立样本分别统计，复合判定按照实际Clang条件数上限记录结果。

工具计数与条件／判定C/D分别记录。身份、取消、撤权、资源交接及提交使用真值表验证关键条件的独立影响，各语言报告自己的指标及适用范围。参考[coverage](https://pub.dev/documentation/coverage/1.16.0/coverage/collect.html)、[JaCoCo](https://www.jacoco.org/jacoco/trunk/doc/counters.html)、[LLVM](https://clang.llvm.org/docs/SourceBasedCodeCoverage.html)与[Flutter构建模式](https://docs.flutter.dev/testing/build-modes)。

## 最终产物与许可

同一最终源码按项目构建配置生成全部目标ABI的正常release，核查APK身份、原生库ELF LOAD与ZIP16KiB对齐、实际加载及Go buildinfo／tags。正常release使用生产构建路径，检查测试客户端、JaCoCo插桩、LLVM profile runtime／sections和测量入口的排除情况。

许可核验逐字节比较源材料和包内资产。decoded NOTICES由原始依赖许可独立生成并审核，Go模块图和Gradle报告采用本次构建的解析结果；CA、Geo、PSL及对应源码逐项核对，义务见[许可依据](../legal/dependencies.md)与[NOTICE](../../NOTICE.md)。

正常界面按添加／修改、启动、模式／策略／图片、连接搜索／详情／断开、运行项保存应用、停止和重开形成连续闭环，并覆盖失败、重试及前后台。分别确认数据、偏好、系统授权、控件与最新运行意图。
