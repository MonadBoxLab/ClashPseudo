# 集成验证与覆盖率

本文说明产品行为、异步身份、资源生命周期、界面及产物的验证方法。构建和工具调用见[构建与测试](build-and-test.md)，业务要求沿所属[功能规范](../product/overview.md#功能范围)，工程边界沿[架构](../architecture/overview.md)。范围由实际改动、具体失败和目标能力确定，适用结果直接复用。

## 结果口径

结果对应实际源码、输入和产物，分别说明通过、失败、未执行与受阻。按具体问题核对SDK动作回执、业务结果、Service／native退出、Store一致性和运行意图；构造、编译和实际功能链分别报告。

回归使用能够区分异常与正常行为的输入。异步操作捕获原身份，资源检查等待实际I/O、close或join，接口边界见[内核公开能力](../architecture/core-integration.md#公开能力边界)。已有适用结果通过后结束对应检查，实际修改或新的具体失败再触发受影响部分。

## 界面与自适应

以窗口逻辑尺寸、局部父约束、TextScaler、安全区和键盘inset解释布局。Android Configuration与Flutter工作区分别读取；API28+ hintText与层级XML可能不同。ACTION_SET_TEXT及预测节点表示系统受理，实际接受值由应用结果确认，IME沿真实delta路径检查。

按受影响布局选择门槛两侧、窄窗、大字或长文本等有区分力的场景，检查控件几何、命中、语义和阅读锚点。导航容量与最小支持范围取实际组件约束；展开、关闭、尺寸变化及越界恢复保持同一任务、控制器和查询链。

按修改涉及的等待、完成、失败、重试、选中、禁用、刷新、来源失效或恢复检查相关转换，包含需要处理的快速反向和减少动效。集合与详情分别核对真实可见性、持续读取和阅读位置；表单检查草稿、离屏首错、子编辑取消及保存结果。语言、主题、品牌、窗口和输入组合按具体缺口选择。

[ReadingList](../../lib/src/app/widgets/reading_list.dart)在debug可用dart-define validationLayoutMetrics=true记录FlutterView、MediaQuery、insets、父约束和文字缩放。仅在布局事实未决时使用该入口；复杂浮层与输入问题采用对应平台的真实事件。

## 系统与网络集成

Android按实际受影响的API、ABI、页大小、窗口或输入能力选择目标。VPN授权、Activity重建、Service代次、前后台、锁屏和Always-on采用相应真实系统路径；手动回调注入单列其竞态覆盖。isAlwaysOn／isLockdownEnabled仅API29+且有可读实例才取值。

| 范围 | 入口与主要判据 |
| --- | --- |
| VPN／FD | [NativeCoreFailureTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/nativecore/NativeCoreFailureTest.kt)：接收／消费／失败回收、实际资源身份和恢复 |
| TCP／UDP | [TCP数据面](../../native/mihomo/internal/engine/tun_tcp_dataplane_test.go)、[UDP数据面](../../native/mihomo/internal/engine/tun_dataplane_test.go)，Android检查protect、Network绑定和受影响TUN栈实际流量 |
| 模式／策略 | [ModeCallsTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/bridge/ModeCallsTest.kt)，保存与实际选择、热切换、重连及连接EOF |
| 应用访问 | 独立UID客户端请求，按改动覆盖all／only／except、共享UID、缺包或空有效allow |
| 系统启动 | [SystemStartLifecycleTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/vpn/SystemStartLifecycleTest.kt)：SERVICE_INTERFACE、系统撤权、STARTING取消及实际退出 |
| Activity与授权 | [AuthorizationRecreationTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/bridge/AuthorizationRecreationTest.kt)：系统授权取消／同意、重建和请求归属 |
| 通知／Tile／widget | SDK入口与Launcher实际点击关联MainActivity焦点、运行代次及动作结果 |
| TLS／Geo | [AppTrustAndroidTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/app/AppTrustAndroidTest.kt)、[GeoResourceNativeTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/nativecore/GeoResourceNativeTest.kt)，根策略、TLS验证及加载／替换 |
| DNS | [DNS回归](../../native/mihomo/internal/engine/dns_tools_test.go)、[诊断UI](../../test/features/diagnostics)，Question／RCODE、取消、缓存计数和迟到隔离 |

受控服务的closed／join、应用Stop及连接EOF按实际拥有者确认。请求和服务入场信息用于区分模式选路、监听、provider／Geo、DNS／路由和TLS路径；TLS失败用对应错主机名、坏链、未信CA或pin输入检查。

DNS取消先确认请求进入受控服务，再触发关闭或身份失效，核对取消、真实退出及下一请求的Question／RCODE和控件状态。受控屏障与请求身份用于区分主动取消和自然超时。fake-IP按受影响路径检查分配、旧地址、持久池及IPv4／IPv6控制流。

## Worker取消与后台应用

[ScheduleWorkerCancellationTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/app/ScheduleWorkerCancellationTest.kt)使用真实WorkManager、Dart writer和延迟有效正文。取消后核查owner失效、writer仍忙，实际I/O完成后才开门，正文、revision和元数据保持一致。

后台运行项更新关联下载、保存、完整输入、新UUID和一次重连。交接前取消、交接后网络约束丢失、用户Stop、撤权或STARTING取消按受影响时序使用有界屏障；保存、applied和退出分别核验。系统撤权通过VpnService.prepare实际变化确认。

## JNI错误路径

[NativeDescriptorZeroTest](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/nativecore/NativeDescriptorZeroTest.kt)用独立instrumentation进程检查FD0，先确认raw stdin指向/dev/null，再用F_DUPFD_CLOEXEC取得空闲0。[Zygote标准描述符](https://android.googlesource.com/platform/libcore/+/refs/heads/main/dalvik/src/main/java/dalvik/system/ZygoteHooks.java)与Java FileDescriptor对象按各自身份处理。

FD消费按st_dev／st_ino等身份核对。system／mixed可用普通有效FD触发TUNGETIFF失败，检查释放、未附着及再次Prepare／Stop恢复；部分创建、取消和回调在途等实际close／join后判断复用。

## 备份与恢复

[业务恢复](../../test/features/backup)、[逻辑执行](../../test/logic)及[Android平台](../../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/backup)检查原字节、manifest／CRC／SHA、固定条目、边界、取消、write／close错误、PREPARED／COMMITTED及中断回滚。故障注入使用隔离目录，正式用户数据沿正常导入／恢复路径。

SAF检查实际选择、确认、后台返回与取消。API24 Downloads集合与本地Download目录分别处理，选中整个ZIP并返回OPEN后核对应用结果。重新导出比较三业务文件原字节，ZIP时间戳／压缩差异单列。恢复核对epoch、旧草稿／菜单／Worker撤销、偏好及最新运行意图。

JsonReader用合法大正文、超限键／标量、quoted／unquoted或跨缓冲输入检查受影响边界。实际内存问题在相应目标诊断；系统逐文件恢复与主动三库事务按各自协议验证。

## 编辑器与输入

[正文限额](../product/configurations.md#文本限额与换行)相关回归检查UTF-8、首BOM、混合换行、32768／32769 UTF-16边界、合行、emoji／组合字、整批delta、composing、查找、选区、剪贴板、撤销重做和保存身份。真实IME／硬件键盘与控制器注入分别报告。

生命周期回归读取真实field消费的showCursorNotifier，检查销毁、停闪和重启后的延迟取消。拖拽通过实际gesture callback启动自动滚动，再移除编辑器；手柄沿公开scrollbarBuilder移除field并保持overlay controller，检查render有效性。补丁来源见[PATCHES](../../third_party/sources/re_editor/PATCHES.md)。

值准入与IME批次检查拒绝前后的历史、发布次数、selection／composing及接受值回同步。查找等待实际扫描完成后判断结果；系统返回沿IME、查找、一次退出保护及所属Navigator检查取消和放弃。平台特有问题使用对应设备验证。

## 覆盖率

### Dart

[采集工具](../../tool/coverage/flutter.dart)使用coverage公共API与HitMap／LCOV，[测试配置](../../test/flutter_test_config.dart)在APP_FUNCTION_COVERAGE=true注册root tearDownAll，等测试isolate收尾后采集。临时library loader纳入未import源码和part，报告实际分母、排除及未映射项。

纯编译期生成契约列入生成文件排除，其业务消费者继续统计。function、line和VM branch分别报告；同行函数可能合并至一个源码入口桶。工具自身已有有效结果直接复用，采集错误按具体失败处理。依据实际功能和错误处理遗漏补回归，集中采集修改稳定后的数据。

### Go、Android与JNI

Go使用生产tags和atomic coverprofile，test.gocoverdir传子进程计数；statement与具名函数语句命中分报，提前fatal／os.Exit导致的未flush缺口单列。

Android报告关联同一variant的class、JVM exec、设备ec及JaCoCo XML／HTML，分别报告line、method、branch和Kotlin合成过滤。设备数据与源码／class身份对应。

JNI测试变体启用Clang source coverage、atomic及MC/DC，实际调用结束后flush profraw，使用对应库、llvm-profdata及llvm-cov处理。项目C、生成cgo与第三方代码分别统计，MC/DC按Clang实际支持范围报告。

各语言报告自身指标、测试范围及未执行项。参考[coverage](https://pub.dev/documentation/coverage/1.16.0/coverage/collect.html)、[JaCoCo](https://www.jacoco.org/jacoco/trunk/doc/counters.html)、[LLVM](https://clang.llvm.org/docs/SourceBasedCodeCoverage.html)与[Flutter构建模式](https://docs.flutter.dev/testing/build-modes)。

## 最终产物与许可

同一最终源码生成通用版及三个分架构正常release。按实际ABI核对APK身份、ELF LOAD与ZIP16KiB对齐、加载及Go buildinfo／tags，排除测试客户端、JaCoCo插桩和LLVM profile runtime／sections。功能检查按同一源码执行，包数保持该次应用版本。

许可核验逐字节比较源材料和包内资产。decoded NOTICES由原始依赖许可独立生成，Go图与Gradle报告取实际解析；CA、Geo、PSL及对应源码按[许可依据](../legal/dependencies.md)与[NOTICE](../../NOTICE.md)核对。

正常界面沿添加／修改、启动、模式／策略、连接、运行项保存应用、停止和重开形成闭环，已有适用操作计入。失败、重试、后台和恢复按具体缺口补齐，分别确认数据、偏好、系统授权与最新运行意图。
