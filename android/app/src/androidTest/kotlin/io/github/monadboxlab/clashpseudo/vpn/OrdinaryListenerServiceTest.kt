package io.github.monadboxlab.clashpseudo.vpn

import android.net.VpnService
import android.os.Process
import android.os.SystemClock
import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CorePlatformTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.input.CoreInput
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ServerSocket
import java.net.URL
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class OrdinaryListenerServiceTest {
    @Test fun ordinaryHttpListenerAuthenticatesAndReleasesAfterNormalStop() {
        // 在接触 Service、native worker 或 socket 前检查 nonce 与端口。
        val arguments = InstrumentationRegistry.getArguments()
        val nonce = checkNotNull(arguments.getString("nonce")) { "缺少 nonce" }
        check(nonce == "p5-load-listener-r7v1") { "nonce 无效" }
        val httpPort = checkNotNull(arguments.getString("httpPort")) { "缺少 httpPort" }
            .toIntOrNull()?.takeIf { it in 1..65535 } ?: error("httpPort 无效")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val configId = "controlled-ordinary-http-listener-r7v1"
        val platform = CorePlatformTestDriver(context)
        val packages = setOf(
            "io.github.monadboxlab.clashpseudo.validation.clienta",
            "io.github.monadboxlab.clashpseudo.validation.clientb",
        )
        fun <T> main(block: () -> T): T {
            val task = FutureTask(block)
            instrumentation.runOnMainSync(task)
            return task.get()
        }
        fun awaitMain(label: String, ready: () -> Boolean) {
            val deadline = SystemClock.elapsedRealtime() + 60_000L
            while (!main(ready)) {
                check(SystemClock.elapsedRealtime() < deadline) { "等待 $label 超时" }
                Thread.sleep(25)
            }
        }
        awaitMain("既有 business writer 空闲") {
            !AppBridge.logic.busy && AppBridge.operationId == null && !AppBridge.pendingSystemRestore
        }
        val before = main {
            assertFalse("不能接管既有 Service", CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java))
            assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
            assertNull("VPN 必须已有授权，不能请求新授权", VpnService.prepare(context))
            PseudoVpnService.session.snapshot().also { assertEquals(NativeSession.Phase.STOPPED, it.phase) }
        }
        val excludedUids = setOf(Process.myUid(), context.applicationInfo.uid,
            instrumentation.context.applicationInfo.uid)
        val clientUids = packages.map { name ->
            val uid = context.packageManager.getApplicationInfo(name, 0).uid
            assertFalse("不能捕获 instrumentation 或 target UID", uid in excludedUids)
            assertEquals("不能捕获与 client 共用 UID 的其他 package", setOf(name),
                context.packageManager.getPackagesForUid(uid).orEmpty().toSet())
            uid
        }
        assertEquals("两个既有 client 必须使用独立 UID", 2, clientUids.toSet().size)

        val loopback = InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))
        // 将 SDK 选定端口交给应用前释放 reservation，后续 bind 冲突应使测试失败。
        val listenerPort = ServerSocket().use {
            it.bind(InetSocketAddress(loopback, 0), 1)
            it.localPort
        }
        val user = "p5-listener"
        val body = """
            ipv6: false
            mode: rule
            geo-auto-update: false
            port: $listenerPort
            allow-lan: false
            bind-address: 127.0.0.1
            authentication: ['$user:$nonce']
            skip-auth-prefixes: []
            dns: {enable: false}
            sniffer: {enable: false}
            ntp: {enable: false}
            profile: {store-selected: false, store-fake-ip: false}
            proxy-providers: {}
            rule-providers: {}
            proxies: []
            proxy-groups: []
            tun:
              enable: true
              auto-route: false
              route-address: [192.168.100.2/32]
              dns-hijack: []
              include-package:
                - io.github.monadboxlab.clashpseudo.validation.clienta
                - io.github.monadboxlab.clashpseudo.validation.clientb
            rules:
              - IP-CIDR,192.168.100.2/32,DIRECT,no-resolve
              - MATCH,REJECT
        """.trimIndent() + "\n"
        var failure: Throwable? = null
        CoreIpcTestDriver.production().use { observer ->
        try {
            val prepared = platform.prepare(CoreInput(configId, 1, "rule", body.toByteArray(Charsets.UTF_8),
                "{}".toByteArray(), name = configId))
            assertTrue(prepared.terminal.toString(), prepared.terminal.getBoolean("complete"))
            val loaded = platform.status()
            assertEquals(observer.processId, loaded["processId"])
            assertEquals(Contract.CORE_PHASE_READY, loaded["phase"])
            assertEquals(Contract.CORE_PURPOSE_RUNNING, loaded["purpose"])
            assertEquals(configId, loaded["configId"])
            assertEquals(1, (loaded["revision"] as Number).toInt())
            assertEquals(true, loaded["vpnRunning"])
            val access = prepared.value.getJSONObject("platform").getJSONObject("vpn").getJSONObject("applicationAccess")
            assertEquals("only", access.getString("access"))
            assertEquals("configuration", access.getString("source"))
            val captured = access.getJSONArray("packages")
            assertEquals(packages, (0 until captured.length()).map(captured::getString).toSet())
            val record = platform.runRecord(loaded)
            assertEquals(body, record.getString("body"))
            assertEquals(configId, record.getString("id"))
            assertEquals(1, record.getInt("revision"))
            assertEquals(0, record.getJSONArray("overrides").length())
            val native = platform.query(Contract.CORE_OPERATION_SNAPSHOT)
            assertTrue(native.terminal.toString(), native.terminal.getBoolean("complete"))
            assertTrue(native.value.getBoolean("prepared"))
            assertTrue(native.value.getBoolean("attached"))
            assertFalse(native.value.getBoolean("cleanupFailed"))
            assertTrue(CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java))

            val target = URL("http://192.168.100.2:$httpPort/$nonce/config-load")
            val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress(loopback, listenerPort))
            fun basic(password: String) = "Basic " + Base64.encodeToString(
                "$user:$password".toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
            fun request(authorization: String?, expectedStatus: Int): String {
                val current = platform.status()
                assertEquals(loaded["processId"], current["processId"])
                assertEquals(loaded["inputId"], current["inputId"])
                assertEquals(configId, current["configId"])
                assertEquals(true, current["vpnRunning"])
                val connection = target.openConnection(proxy) as HttpURLConnection
                try {
                    connection.connectTimeout = 5_000
                    connection.readTimeout = 5_000
                    connection.instanceFollowRedirects = false
                    connection.useCaches = false
                    connection.setRequestProperty("Connection", "close")
                    connection.setRequestProperty("Proxy-Connection", "close")
                    connection.setRequestProperty("Accept-Encoding", "identity")
                    if (authorization != null) connection.setRequestProperty("Proxy-Authorization", authorization)
                    assertEquals(expectedStatus, connection.responseCode)
                    if (expectedStatus == HttpURLConnection.HTTP_PROXY_AUTH) {
                        assertEquals("Basic", connection.getHeaderField("Proxy-Authenticate"))
                    }
                    val bytes = ByteArray(8192)
                    var count = 0
                    val stream = if (expectedStatus >= 400) connection.errorStream else connection.inputStream
                    stream?.use {
                        val deadline = SystemClock.elapsedRealtime() + 10_000L
                        while (count < bytes.size) {
                            check(SystemClock.elapsedRealtime() < deadline) { "响应 body 超过 deadline" }
                            val size = it.read(bytes, count, bytes.size - count)
                            if (size == -1) break
                            check(size > 0)
                            count += size
                        }
                    }
                    return String(bytes, 0, count, Charsets.UTF_8)
                } finally {
                    connection.disconnect()
                }
            }
            // 使用同一个 loopback client 依次请求受控 endpoint。
            request(null, HttpURLConnection.HTTP_PROXY_AUTH)
            // mihomo HTTP authenticator 对错误 Basic credentials 返回 403，对缺失 credentials 返回 407。
            request(basic("wrong-$nonce"), HttpURLConnection.HTTP_FORBIDDEN)
            val response = request(basic(nonce), HttpURLConnection.HTTP_OK)
            assertEquals("# Controlled, local-only fixture $nonce revision 1",
                response.substringBefore('\n').removeSuffix("\r"))
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            try {
                assertEquals(observer.processId, platform.status()["processId"])
                platform.exit()
                observer.awaitDeath()
                assertTrue(observer.deathConfirmed)
                platform.await("VPN Service 退出") { !CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java) }
                assertEquals(Contract.CORE_PHASE_EXITED, platform.status()["phase"])
                assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
                ServerSocket().use {
                    it.reuseAddress = true
                    it.bind(InetSocketAddress(loopback, listenerPort), 1)
                }
                CoreIpcTestDriver.assertNoGoInApplication()
            } catch (cleanup: Throwable) {
                if (failure == null) throw cleanup else if (failure !== cleanup) failure.addSuppressed(cleanup)
            }
        }
        }
    }
}
