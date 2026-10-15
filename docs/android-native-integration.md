# Android 原生接入

产品规则见 [产品需求](product-requirements.md)。Flutter 展示、Dart 协调配置业务、Kotlin 持有平台生命周期，mihomo 负责网络处理。

## 应用宿主与配置存储

- [MainActivity](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/MainActivity.kt) 持有 UI Engine，实际销毁时释放；普通暂停及授权弹窗不销毁 Engine。
- [AppWorkService](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/AppWorkService.kt) 是按需 `dataSync` 前台服务，与 UI 共用 Application 的 `FlutterEngineGroup`，持有一个无 UI 业务 Engine。入口为保留 AOT 标记的 `appBackgroundMain`；没有 `runApp`，不注册平台插件。业务完成后释放 Engine、通知与服务；VPN 单独运行不保留业务 Engine。Flutter VM 的进程级资源不等同于 Engine，不承诺释放 Engine 后内存回到首次加载前。
- [AppBridge](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/AppBridge.kt) 串行受理命令，以操作 ID 区分受理与最终结果，分别为两个 Engine 接线。UI 重开只查询，不重发任务；权限结果按请求标识匹配，迟到结果不能结束后续操作。工作服务及 VPN 均为 `START_NOT_STICKY`，进程结束不自动续跑。
- [Dart 配置业务](../lib/features/configs/config_actions.dart) 下载、保存并协调启停。下载上限为 16 MiB、总时限 30 秒、最多 5 次重定向；手动检查每跳 HTTP 风险，不跨来源转发 Basic 凭据，不绕过 TLS 验证。实际配置语义在策略预览或 VPN 加载时判定。
- [配置存储](../lib/features/configs/config_store.dart) 是单写入者的版本化 JSON，以同目录临时文件 flush 后 rename 提交。保存于 `filesDir/configurations/configurations.json`；更新前先持久化旧正文失效状态；最初写入失败则不下载，停止当前项的接管并明确报告旧记录未修改。损坏存储报错，不覆盖为空列表。
- [AppFiles](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/AppFiles.kt) 把内核资源放在 `noBackupFilesDir/mihomo`，运行输入放在 `noBackupFilesDir/work/run-input-<operationId>.json`。单份 JSON 包含配置 ID、revision、模式、原样正文及选择映射，临时文件 flush／rename 后由 worker 核对身份读取；每操作独立文件，过期请求不能读到后续操作的输入。正文不放入 Intent，输入用完删除，不作为历史副本。

系统备份规则只允许已提交的 `configurations.json`，不包含其 `.tmp`、缓存或运行输入。版本保护规则见 [产品需求](product-requirements.md#系统备份与恢复)。恢复数据的读取与正常存储走同一代码，实际状态仍查询平台。规则检查不等于真实云备份／跨设备恢复验收。

## 职责与调用顺序

- [PseudoVpnService](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/vpn/PseudoVpnService.kt)：系统授权检查、前台通知、TUN 建立和服务生命周期。TUN 地址、前缀与 MTU 在这里定义，同时传给 Android Builder 和 native。
- [NativeCore](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/nativecore/NativeCore.kt) 与 [JNI 桥接](../native/mihomo/bridge_android.c)：参数、UTF-8 数据及 socket 保护回调的跨语言传递。
- [Go engine](../native/mihomo/internal/engine/engine.go)：配置应用、TUN 附着与会话资源清理。mihomo 使用进程级全局状态，因此只运行一个会话。

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

[策略业务](../lib/features/strategies/strategy_actions.dart) 在每个 ConfigEntry 的 `choices` 保存 `{组名: {type, member}}`；自动组显式 `member: null` 表示恢复自动，缺记录表示遵循配置默认。旧存储缺字段兼容，存在但非法则按损坏处理；改变选择不增加正文 revision。继续使用共享 core home，但选择隔离由客户端记录承担；关闭内核 `store-selected`，避免其只按组名索引的进程级缓存二次覆盖偏好，不靠切 home 伪造独立选择库。

[Go 策略接口](../native/mihomo/internal/engine/strategies.go) 返回真实组、有效 provider 成员、类型、hidden、now／fixed、GLOBAL 引用和未恢复原因。顺序沿用默认 provider 的原始组序；普通查询不主动测速或 Touch。自动组仅投影 adapter 自身 JSON 的 now／fixed，load-balance 不伪造 now。GLOBAL 按真实组对象、顶层规则及全部子规则目标判定，不把普通同名节点或子规则集名当作引用。

Prepare 初始化 provider 后使用 `ForceSet` 恢复有效偏好；手动固定使用官方 `Set`，恢复自动使用 `ForceSet("")`。无效偏好遵循默认并返回提示，不替用户猜替代。选择前后核对代次、组类型及成员，自动组按 fixed 确认，select 按 now 确认，不断旧连接。JNI 选择请求使用带长度的 UTF-8 `byte[]` JSON，避免 modified UTF-8 破坏 emoji。

[StrategyCalls](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/StrategyCalls.kt) 的读取／选择／准备期限分别为 3／10／45 秒，选择为 fallback 官方 Set 的潜在测速留出时间。超时只结束等待，不走启停超时的停 VPN 路径；已执行的操作迟到完成只通知重读。准备取消只使自身 lease 失效，返回后清理；已 READY 但尚未交付的过期请求排队清理，并再次核对 lease，不能清理后来的 VPN。同步 Parse 无法强行中断。

[CoreHostTest](../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/nativecore/CoreHostTest.kt) 覆盖可控时间／队列下的闲置、返回、业务及换代竞争；[StrategyCallsTest](../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/app/StrategyCallsTest.kt) 覆盖超时、取消和迟到结果。NativeCoreFailureTest 的真实 JNI 预览用例另检查中文／emoji 恢复、切换及未附着 TUN。这些测试不替代实际系统授权或全部协议资源验证。

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

模式业务复用现有短时业务 Engine、配置存储和 operation 互斥。保存值在 `configurations.json` 顶层；Prepare 接收明确模式并覆盖已解码运行副本，原文不变。运行中通过 JNI 调用轻量 Mode／SetMode，不开放 HTTP controller、不查询连接列表。

`ModeCalls` 与启停等待分开，复用 `pseudo-native` worker，以 generation 和取消标记隔离旧会话。读取期限 3 秒、修改期限 5 秒；超时只结束等待，不停止 VPN。排队请求可取消，已进入 native 的调用完成后通知 UI 重读，不能把超时等同于撤销修改。模式查询失败保留真实 RUNNING，前台退避重读；业务规则见 [运行模式](product-requirements.md#运行模式)。

[ModeCallsTest](../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/app/ModeCallsTest.kt) 在设备上覆盖排队取消、超时、迟到完成与代次隔离；[NativeCoreFailureTest](../android/app/src/androidTest/kotlin/io/github/monadboxlab/clashpseudo/nativecore/NativeCoreFailureTest.kt) 包含模式 JNI 往返与非法输入检查。执行前正常停止 VPN，沿用上述 instrumentation 命令选择测试类。

测试端 `/modes` 正文为 `mode: direct`，规则将 HTTP 走受控 SOCKS，显式 `GLOBAL` 组仅含 REJECT。客户端选 rule 启动后，用唯一请求标识核对 SOCKS／HTTP 收包；热切 direct 后 HTTP 直达，切 global 后新连接拒绝。先用验证页打开 `/hold/`，切 global 后核对原连接仍持续收数，正常停止后才结束；热切过程中 PID／generation 不变，业务 Engine 完成后释放。这个场景验证 TCP，不代表所有 UDP 协议均已设备验收。

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

[平台字段管理](../native/mihomo/internal/engine/platform.go) 只修改解码后的运行副本：应用关闭配置指定的端口、controller、额外 listener/server、DNS 外部监听、UI 下载及系统级操作，保留节点、组和规则。HTTP provider 的自定义缓存路径被移除，file provider 路径限制在内核资源目录并检查符号链接。Android 原生 logrus 输出被关闭，正式错误出口只给安全的阶段消息，不将原始来源／凭据写入 logcat；当前不提供完整内核日志诊断。

**信任模型**：信任用户选择的完整配置来源、provider 及后续更新，只使用可信来源。上述平台字段、provider 路径和隐私保护继续适用，但不把恶意完整配置当作不可信程序进行严格文件沙箱隔离。`cmfa` 会跳过上游 `IsSafePath` 检查，SSH 私钥、TLS 证书等节点内部文件引用不受 provider 路径限制完整覆盖，动态 provider 也存在这些入口；这不意味着突破 Android 应用沙箱。完整文件隔离不属于当前产品承诺，不为此增加预校验、协议扫描器、独立进程或内核 fork。

已知的配置失败限制：

- [WireGuard 构造函数](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/adapter/outbound/wireguard.go#L467-L507) 可先创建协程，再因远程 DNS 参数解析失败返回，缺少相应关闭；这是源码确认的构造失败路径，不与下述已执行回归混为同一个场景。
- 配置成功构造 WireGuard 节点后，后续规则解析失败时，上游 `ParseRawConfig` 返回 nil／error，调用方拿不到已分配节点。`TestParseFailureClosesAllocatedNodes` 在关闭自动 GC、排除 finalizer 掩盖后复现：Prepare 失败，Stop 返回成功，等待两秒仍有一个 WireGuard encryption worker（基线为零）。当前应用也可能因此把未完整释放的上下文报告为空闲；此缺陷未修复，**阻塞完整生命周期验收**，不能只记录成已接受的选择竞态。复现命令为 `go -C native/mihomo test ./internal/engine -run '^TestParseFailureClosesAllocatedNodes$' -count=1 -v`，该回归保留失败。
- [provider 节点清理回归](../native/mihomo/internal/engine/provider_cleanup_test.go) 的成功加载／停止用例验证 inline WireGuard 节点反复停止后 worker 退出；它不覆盖构造中途失败或全部协议。不以协议白名单、预校验或强制 GC 掩盖这些资源问题；当前不维护内核 fork，也未通过升级改变这一边界。

arm64 真机、最低 API、16 KB 设备和长期后台行为需要对应设备验收；具体测试结果记录在验收汇报中。许可与来源见 [NOTICE](../NOTICE.md)。
