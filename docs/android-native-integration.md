# Android 原生接入

产品规则见 [产品需求](product-requirements.md)。本模块负责 Android VPN 与 mihomo 的资源交接；应用业务和 Flutter 界面在其上接入。

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
| provider | 停止时调用 `Close()` 取消任务；上游取消不是同步等待，需用在途请求和周期请求测试核对 |

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

核对 runner 的测试结果，不只看 shell 返回码。每条路径在同一进程重复三轮；日志记录 PID、停止后的 FD 数和测试线程数，用于检查增长趋势。

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

当前使用 `system` 栈、IPv4 全路由与 DNS 接管，IPv6 由 Android VPN 策略阻断。入口只接受随包受控配置，provider 加载失败是否继续遵循 mihomo 行为。

已知的配置失败限制：[WireGuard 构造函数](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/adapter/outbound/wireguard.go#L467-L507) 可先创建协程，再因远程 DNS 参数解析失败返回，缺少相应关闭。当前测试配置未启用 WireGuard；开放该配置路径前需解决资源回收。

arm64 真机、最低 API、16 KB 设备和长期后台行为需要对应设备验收；具体测试结果记录在验收汇报中。许可与来源见 [NOTICE](../NOTICE.md)。
