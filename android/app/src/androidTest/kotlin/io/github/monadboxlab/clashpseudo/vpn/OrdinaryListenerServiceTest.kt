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
        // Check the nonce and port before accessing a Service, native worker, or socket.
        val arguments = InstrumentationRegistry.getArguments()
        val nonce = checkNotNull(arguments.getString("nonce")) { "Missing nonce" }
        check(nonce == "p5-load-listener-r7v1") { "Invalid nonce" }
        val httpPort = checkNotNull(arguments.getString("httpPort")) { "Missing httpPort" }
            .toIntOrNull()?.takeIf { it in 1..65535 } ?: error("Invalid httpPort")
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
                check(SystemClock.elapsedRealtime() < deadline) { "Timed out waiting for $label" }
                Thread.sleep(25)
            }
        }
        awaitMain("Existing application writer is idle") {
            !AppBridge.logic.busy && AppBridge.operationId == null && !AppBridge.pendingSystemRestore
        }
        val before = main {
            assertFalse("Must not take over an existing Service", CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java))
            assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
            assertNull("VPN must already be authorized; do not request new authorization", VpnService.prepare(context))
            PseudoVpnService.session.snapshot().also { assertEquals(NativeSession.Phase.STOPPED, it.phase) }
        }
        val excludedUids = setOf(Process.myUid(), context.applicationInfo.uid,
            instrumentation.context.applicationInfo.uid)
        val clientUids = packages.map { name ->
            val uid = context.packageManager.getApplicationInfo(name, 0).uid
            assertFalse("Must not capture the instrumentation or target UID", uid in excludedUids)
            assertEquals("Must not capture another package sharing the client's UID", setOf(name),
                context.packageManager.getPackagesForUid(uid).orEmpty().toSet())
            uid
        }
        assertEquals("The two existing clients must use separate UIDs", 2, clientUids.toSet().size)

        val loopback = InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))
        // Release the reservation before passing the SDK-selected port to the application; a later bind conflict must fail the test.
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
                            check(SystemClock.elapsedRealtime() < deadline) { "Response body exceeded the deadline" }
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
            // Use the same loopback client to request controlled endpoints sequentially.
            request(null, HttpURLConnection.HTTP_PROXY_AUTH)
            // The mihomo HTTP authenticator returns 403 for incorrect Basic credentials and 407 for missing credentials.
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
                platform.await("VPN Service exits") { !CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java) }
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
