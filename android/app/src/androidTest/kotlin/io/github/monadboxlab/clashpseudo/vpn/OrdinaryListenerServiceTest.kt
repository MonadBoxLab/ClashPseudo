package io.github.monadboxlab.clashpseudo.vpn

import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Process
import android.os.SystemClock
import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
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
        // Reject an unscoped invocation before touching the Service, native worker or sockets.
        val arguments = InstrumentationRegistry.getArguments()
        val nonce = checkNotNull(arguments.getString("nonce")) { "Missing nonce" }
        check(nonce == "p5-load-listener-r7v1") { "Invalid nonce" }
        val httpPort = checkNotNull(arguments.getString("httpPort")) { "Missing httpPort" }
            .toIntOrNull()?.takeIf { it in 1..65535 } ?: error("Invalid httpPort")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val configId = "controlled-ordinary-http-listener-r7v1"
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
        awaitMain("existing business writer to become idle") {
            !AppBridge.logic.busy && AppBridge.operationId == null && !AppBridge.pendingSystemRestore
        }
        val before = main {
            assertNull("Do not take over an existing Service", PseudoVpnService.instance)
            assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
            assertNull("VPN must already be authorized; never request a grant", VpnService.prepare(context))
            PseudoVpnService.session.snapshot().also { assertEquals(NativeSession.Phase.STOPPED, it.phase) }
        }
        val excludedUids = setOf(Process.myUid(), context.applicationInfo.uid,
            instrumentation.context.applicationInfo.uid)
        val clientUids = packages.map { name ->
            val uid = context.packageManager.getApplicationInfo(name, 0).uid
            assertFalse("The instrumentation/target UID must not be captured", uid in excludedUids)
            assertEquals("Do not capture other packages sharing a client UID", setOf(name),
                context.packageManager.getPackagesForUid(uid).orEmpty().toSet())
            uid
        }
        assertEquals("The two existing clients must have independent UIDs", 2, clientUids.toSet().size)

        val loopback = InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))
        // Release the SDK reservation before handing its chosen port to the
        // application. A later bind conflict fails the case.
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
        val generation = before.generation + 1
        var requested = false
        var failure: Throwable? = null
        try {
            main {
                assertEquals(before.generation, PseudoVpnService.session.snapshot().generation)
                assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
                assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
                assertNull(PseudoVpnService.instance)
                assertFalse(AppBridge.logic.busy)
                assertNull(AppBridge.operationId)
                assertFalse(AppBridge.pendingSystemRestore)
                assertNull(VpnService.prepare(context))
                val start = Intent(context, PseudoVpnService::class.java)
                    .setAction(PseudoVpnService.ACTION_START)
                    .putExtra(PseudoVpnService.EXTRA_CONFIG, body)
                    .putExtra(PseudoVpnService.EXTRA_CONFIG_ID, configId)
                    .putExtra(PseudoVpnService.EXTRA_REVISION, 1)
                requested = true
                assertNotNull(if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(start)
                    else context.startService(start))
            }
            awaitMain("real Prepare, Builder and Attach to reach RUNNING") {
                val session = PseudoVpnService.session.snapshot()
                check(session.generation == before.generation || session.generation == generation) {
                    "Another session replaced the controlled start"
                }
                assertNotEquals(NativeSession.Phase.UNKNOWN, session.phase)
                assertNotEquals(CoreHost.Phase.FAILED, PseudoVpnService.core.snapshot().phase)
                if (session.generation != generation) false else {
                    check(session.phase != NativeSession.Phase.STOPPED) {
                        "Controlled Service startup ended: ${session.error?.id}"
                    }
                    assertEquals(configId, session.configId)
                    assertEquals(1, session.revision)
                    session.phase == NativeSession.Phase.RUNNING &&
                        PseudoVpnService.core.snapshot().phase == CoreHost.Phase.READY
                }
            }
            val loaded = main {
                assertNotNull(PseudoVpnService.instance)
                assertNull(PseudoVpnService.session.snapshot().error)
                PseudoVpnService.core.snapshot().also {
                    assertEquals(CoreHost.Purpose.VPN, it.purpose)
                    assertEquals(configId, it.configId)
                    assertEquals(1, it.revision)
                }
            }
            val inspected = FutureTask {
                check(PseudoVpnService.session.snapshot().let {
                    it.generation == generation && it.phase == NativeSession.Phase.RUNNING && it.configId == configId
                })
                check(PseudoVpnService.core.snapshot() == loaded)
                val input = checkNotNull(PseudoVpnService.core.runningInput(loaded.generation,
                    checkNotNull(loaded.composition)))
                val access = checkNotNull(PseudoVpnService.core.applicationAccess(generation))
                assertEquals("only", access["access"])
                assertEquals("configuration", access["source"])
                assertEquals(packages, (access["packages"] as List<*>).toSet())
                assertEquals(body, JSONObject(input.toString(Charsets.UTF_8)).getString("body"))
                JSONObject(NativeCore.snapshot())
            }
            PseudoVpnService.worker.execute(inspected)
            val native = inspected.get(10, TimeUnit.SECONDS)
            assertTrue(native.getBoolean("prepared"))
            assertTrue(native.getBoolean("attached"))
            assertFalse(native.getBoolean("cleanupFailed"))

            val target = URL("http://192.168.100.2:$httpPort/$nonce/config-load")
            val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress(loopback, listenerPort))
            fun basic(password: String) = "Basic " + Base64.encodeToString(
                "$user:$password".toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
            fun request(authorization: String?, expectedStatus: Int): String {
                main {
                    val session = PseudoVpnService.session.snapshot()
                    assertEquals(generation, session.generation)
                    assertEquals(configId, session.configId)
                    assertEquals(NativeSession.Phase.RUNNING, session.phase)
                    assertEquals(loaded, PseudoVpnService.core.snapshot())
                }
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
                            check(SystemClock.elapsedRealtime() < deadline) { "Response body exceeded its deadline" }
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
            // Issue sequential direct requests using one loopback client and at most
            // one native outbound connection to the owned endpoint.
            request(null, HttpURLConnection.HTTP_PROXY_AUTH)
            // The fixed public mihomo HTTP authenticator returns 403 for wrong Basic
            // credentials, whereas missing credentials get the 407 challenge above.
            request(basic("wrong-$nonce"), HttpURLConnection.HTTP_FORBIDDEN)
            val response = request(basic(nonce), HttpURLConnection.HTTP_OK)
            assertEquals("# Controlled, local-only fixture $nonce revision 1",
                response.substringBefore('\n').removeSuffix("\r"))
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            if (requested) {
                try {
                    // Cleanup requires confirmed ownership of the started Service.
                    awaitMain("our start admission before cleanup") {
                        val session = PseudoVpnService.session.snapshot()
                        check(session.generation == before.generation || session.generation == generation) {
                            "Another session owns cleanup; do not stop it"
                        }
                        session.generation == generation
                    }
                    main {
                        val session = PseudoVpnService.session.snapshot()
                        assertEquals(generation, session.generation)
                        if (session.phase != NativeSession.Phase.STOPPED) {
                            assertEquals(configId, session.configId)
                            assertEquals(1, session.revision)
                            assertNotNull(context.startService(Intent(context, PseudoVpnService::class.java)
                                .setAction(PseudoVpnService.ACTION_STOP)))
                        }
                    }
                    awaitMain("same-generation normal Stop, native release and Service destruction") {
                        val session = PseudoVpnService.session.snapshot()
                        assertEquals(generation, session.generation)
                        assertNotEquals(NativeSession.Phase.UNKNOWN, session.phase)
                        assertNotEquals(CoreHost.Phase.FAILED, PseudoVpnService.core.snapshot().phase)
                        session.phase == NativeSession.Phase.STOPPED &&
                            PseudoVpnService.core.snapshot().phase == CoreHost.Phase.EMPTY &&
                            PseudoVpnService.instance == null
                    }
                    val stopped = FutureTask {
                        check(PseudoVpnService.session.snapshot().let {
                            it.generation == generation && it.phase == NativeSession.Phase.STOPPED
                        })
                        check(PseudoVpnService.core.snapshot().phase == CoreHost.Phase.EMPTY)
                        JSONObject(NativeCore.snapshot())
                    }
                    PseudoVpnService.worker.execute(stopped)
                    val released = stopped.get(10, TimeUnit.SECONDS)
                    assertFalse(released.getBoolean("prepared"))
                    assertFalse(released.getBoolean("attached"))
                    assertFalse(released.getBoolean("cleanupFailed"))
                    ServerSocket().use {
                        it.reuseAddress = true
                        it.bind(InetSocketAddress(loopback, listenerPort), 1)
                    }
                    // Rebinding verifies release of this TCP listener.
                } catch (cleanup: Throwable) {
                    if (failure == null) throw cleanup else failure.addSuppressed(cleanup)
                }
            }
        }
    }
}
