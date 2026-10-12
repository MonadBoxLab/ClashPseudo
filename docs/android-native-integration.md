# Android 原生接入

产品规则见 [产品需求](product-requirements.md)。Flutter 展示、Dart 协调配置业务、Kotlin 持有平台生命周期，mihomo 负责网络处理。

## 应用宿主与配置存储

- [MainActivity](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/MainActivity.kt) 持有 UI Engine，实际销毁时释放；普通暂停及授权弹窗不销毁 Engine。
- [AppWorkService](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/AppWorkService.kt) 是按需 `dataSync` 前台服务，与 UI 共用 Application 的 `FlutterEngineGroup`，持有一个无 UI 业务 Engine。入口为保留 AOT 标记的 `appBackgroundMain`；没有 `runApp`，不注册平台插件。业务完成后释放 Engine、通知与服务；VPN 单独运行不保留业务 Engine。Flutter VM 的进程级资源不等同于 Engine，不承诺释放 Engine 后内存回到首次加载前。
- [AppBridge](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/AppBridge.kt) 串行受理命令，以操作 ID 区分受理与最终结果，分别为两个 Engine 接线。UI 重开只查询，不重发任务；权限结果按请求标识匹配，迟到结果不能结束后续操作。工作服务及 VPN 均为 `START_NOT_STICKY`，进程结束不自动续跑。
- [Dart 配置业务](../lib/features/configs/config_actions.dart) 下载、保存并协调启停。下载上限为 16 MiB、总时限 30 秒、最多 5 次重定向；手动检查每跳 HTTP 风险，不跨来源转发 Basic 凭据，不绕过 TLS 验证。实际配置语义只在内核启动时判定。
- [配置存储](../lib/features/configs/config_store.dart) 是单写入者的版本化 JSON，以同目录临时文件 flush 后 rename 提交。保存于 `filesDir/configurations/configurations.json`；更新前先持久化旧正文失效状态；最初写入失败则不下载，停止当前项的接管并明确报告旧记录未修改。损坏存储报错，不覆盖为空列表。
- [AppFiles](../android/app/src/main/kotlin/io/github/monadboxlab/clashpseudo/app/AppFiles.kt) 把内核资源放在 `noBackupFilesDir/mihomo`，运行输入放在 `noBackupFilesDir/work/run-input.yaml`。正文不放入 Intent；运行输入用完删除，不作为历史副本。

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
| socket hook | 进程内安装一次，通过原子引用切换当前会话；回调直接调用 `VpnService.protect()` |
| JNI 回调对象 | 会话持有 global reference；每次调用另持 local reference，避免停止时对象失效 |
| provider | 停止时调用 `Close()` 取消任务，并显式关闭其当前节点；节点与主配置共享时由上游 once-only 包装防止重复关闭。上游取消不是同步等待，在途解析／更新仍有迟到替换节点的边界，不承诺所有后台任务已同步退出 |

停止释放会话资源，保留 Go runtime 和 mihomo 的进程级统计任务。

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

已知例外：mihomo `v1.19.32` 的日志等级存在未同步读写，配置应用与后台日志可能触发 `log.SetLevel` / `log.print` 的竞态报告。该项单独跟踪，不阻塞当前原生阶段验收；保留检测及失败结果，其他竞态仍需逐项排查。

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
| `/slow-config` | 延迟 8 秒，用于离开 UI 后继续执行及重开查询 |
| `/redirect` | 相对重定向到完整配置 |
| `/update` | 每次请求返回不同修订注释，用于同 URL 覆盖 |
| `/update-fails` | 第一次成功，后续 HTTP 503；重启 fixture 重置计数 |
| `/invalid`、`/empty`、不存在的路径 | 分别为不可解析正文、空正文、HTTP 404 |

首次导入应选中但不启动，重复来源先确认覆盖。运行中切换到 `/invalid` 后应停旧、报错并保持停止；候选更新失败不能打断当前运行。当前项更新失败后禁止再用旧正文启动。离开并重开延迟下载时，以测试端请求数和 `PseudoWork` 的 operation ID 核对没有重发；结束后 `dumpsys activity services` 不应残留 `AppWorkService`。

授权需分别验证取消、同意及 Activity 重建；等待超时后旧授权结果不能完成新的请求。普通返回不等于 force-stop，异常进程结束应单列。release/AOT 也要实际导入、启动、离开重开与停止，不能用 debug 或编译结果替代。正式入口启动的 debug VPN 可用下述验证页仅发起流量检查，不再点击该页的启动按钮。

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

已知的配置失败限制：[WireGuard 构造函数](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/adapter/outbound/wireguard.go#L467-L507) 可先创建协程，再因远程 DNS 参数解析失败返回，缺少相应关闭。此资源问题尚未解决，也未用协议白名单或启动前验证掩盖。另有 [provider 节点清理回归](../native/mihomo/internal/engine/provider_cleanup_test.go) 验证成功构造的 inline WireGuard 节点在反复停止后退出 worker；它不覆盖上述构造中途失败或全部协议。

arm64 真机、最低 API、16 KB 设备和长期后台行为需要对应设备验收；具体测试结果记录在验收汇报中。许可与来源见 [NOTICE](../NOTICE.md)。
