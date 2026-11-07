package io.github.monadboxlab.clashpseudo.vpn

import android.content.Intent
import android.net.VpnService
import android.os.Build
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.debug.CoreFixtureContract as Fixture
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CorePlatformTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.NativeCoreFailureTest
import io.github.monadboxlab.clashpseudo.nativecore.input.CoreInput
import io.github.monadboxlab.clashpseudo.nativecore.vpn.VpnSpecification
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest

class VpnSpecificationServiceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val platform = CorePlatformTestDriver(context)
    private val clients = listOf("io.github.monadboxlab.clashpseudo.validation.clienta",
        "io.github.monadboxlab.clashpseudo.validation.clientb")

    @Test fun resourceClosureBetweenNativePrepareAndBuilderCannotAcquireALateTun() {
        requireIdle()
        val gate = io.github.monadboxlab.clashpseudo.nativecore.CorePreparationObserver
        gate.armWorkerGate(context, afterNativePrepare = true)
        try {
            CoreIpcTestDriver.production().use { observer ->
                CoreIpcTestDriver.fixture().use { control ->
                    CoreIpcTestDriver.bindVpnResource(context).use {
                        val preparation = prepareAtBuilderGate(observer)
                        platform.await("Native PREPARE reaches the pre-Builder barrier") { gate.workerGateState(context) != null }
                        val closed = control.debug.serviceControl(Fixture.CLOSE_RESOURCES)
                        assertTrue("The binding keeps the closed Service alive before onDestroy", closed.getBoolean("sameService"))
                        assertFalse(preparation.done)
                        gate.releaseWorkerGate(context)
                        val reply = preparation.await(20)
                        assertFalse("A closed resource host must reject the late Builder", reply.terminal.getBoolean("complete"))
                        observer.awaitDeath()
                    }
                }
            }
        } finally {
            gate.releaseWorkerGate(context)
            gate.removeWorkerGate(context)
        }
    }

    @Test fun stopAfterNativePrepareWaitsForTheHeldRequestAndNeverPublishesReady() {
        requireIdle()
        val gate = io.github.monadboxlab.clashpseudo.nativecore.CorePreparationObserver
        gate.armWorkerGate(context, afterNativePrepare = true)
        val worker = java.util.concurrent.Executors.newCachedThreadPool()
        try {
            CoreIpcTestDriver.production().use { observer ->
                val preparation = prepareAtBuilderGate(observer)
                platform.await("Native PREPARE reaches the pre-Builder barrier") { gate.workerGateState(context) != null }
                val exit = worker.submit { observer.exit() }
                platform.await("Stop owns the core while preparation still holds its result FD") {
                    gate.workerGateState(context)?.optBoolean("cancelObserved") == true
                }
                assertFalse(preparation.done)
                assertFalse(exit.isDone)
                assertFalse(observer.deathConfirmed)
                gate.releaseWorkerGate(context)
                exit.get(20, java.util.concurrent.TimeUnit.SECONDS)
                assertTrue(observer.deathConfirmed)
                assertFalse(preparation.await(5).terminal.getBoolean("complete"))
                assertFalse(CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java))
            }
        } finally {
            gate.releaseWorkerGate(context)
            worker.shutdownNow()
            gate.removeWorkerGate(context)
        }
    }

    @Test fun fileRouteSetChangesAndRevertsWholeServiceSpecificationAndInvalidatesPreAttachRevision() {
        requireIdleAndClients()
        for (attached in listOf(false, true)) CoreIpcTestDriver.fixture().use { driver ->
            val reply = driver.fixture(Fixture.ROUTE_PROJECTION, JSONObject().put("attach", attached)).await(90)
            assertTrue(reply.terminal.toString(), reply.terminal.getBoolean("complete"))
            val value = reply.value
            NativeCoreFailureTest.assertSuccess(value.getJSONObject("prepare"))
            val rows = value.getJSONArray("specifications")
            assertEquals(3, rows.length())
            val initial = VpnSpecification.read(rows.getJSONObject(0).getJSONObject("value").toString())
            assertWholeSpecification(initial, prefix = 32)
            for ((index, prefix) in listOf(32, 31, 32).withIndex()) {
                NativeCoreFailureTest.assertSuccess(rows.getJSONObject(index))
                val actual = VpnSpecification.read(rows.getJSONObject(index).getJSONObject("value").toString())
                assertEquals(index + 1L, actual.revision)
                assertWholeSpecification(actual, prefix)
                assertEquals(initial.copy(revision = actual.revision, routes = actual.routes), actual)
            }
            val updates = value.getJSONArray("updates")
            assertEquals(2, updates.length())
            for (index in 0 until updates.length()) NativeCoreFailureTest.assertSuccess(updates.getJSONObject(index))
            val rejected = value.getJSONArray("rejected")
            assertEquals(if (attached) 0 else 3, rejected.length())
            if (!attached) for ((index, revision) in listOf(1L, 1L, 2L).withIndex()) {
                val call = rejected.getJSONObject(index)
                assertEquals(revision, call.getLong("revision"))
                assertTrue(NativeCoreFailureTest.nativeError(call).contains("specification revision changed"))
                assertTrue(call.getBoolean("originalRetained"))
                assertTrue(call.getBoolean("transferredConsumed"))
            }
            val changes = value.getJSONArray("changes")
            assertEquals(2, changes.length())
            assertEquals(2L, changes.getJSONObject(0).getLong("revision"))
            assertEquals(value.toString(), attached, changes.getJSONObject(0).getBoolean("changed"))
            assertEquals(3L, changes.getJSONObject(1).getLong("revision"))
            assertFalse(changes.getJSONObject(1).getBoolean("changed"))
            assertEquals(attached, value.getJSONObject("snapshot").getJSONObject("value").getBoolean("attached"))
            if (attached) {
                NativeCoreFailureTest.assertSuccess(value.getJSONObject("attach"))
                assertTrue(value.getBoolean("originalRetainedAfterAttach"))
                assertTrue(value.getJSONObject("attachedBeforeUpdates").getJSONObject("value").getBoolean("attached"))
                NativeCoreFailureTest.assertSuccess(value.getJSONObject("routeStop"))
                assertTrue(value.getBoolean("originalRetainedAfterStop"))
                assertTrue(value.getBoolean("originalClosed"))
            }
            NativeCoreFailureTest.assertSuccess(value.getJSONObject("shutdown"))
            NativeCoreFailureTest.assertStopped(value.getJSONObject("after").getJSONObject("value"))
            driver.exit()
            assertTrue(driver.deathConfirmed)
            assertFalse(CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java))
            CoreIpcTestDriver.removeFixtureHome(context, value)
        }
        // In addition to the low-level revision regression, the production path actually uses Builder and Attach.
        val body = """
            mode: rule
            ipv6: false
            find-process-mode: off
            geo-auto-update: false
            geox-url: {geoip: '', geosite: '', mmdb: '', asn: ''}
            dns: {enable: true, enhanced-mode: redir-host, nameserver: [192.168.100.2]}
            tun:
              stack: gvisor
              mtu: 1420
              route-address: [198.18.0.0/16, 192.168.100.2/32]
              dns-hijack: ['198.18.0.2:53']
              include-package: [io.github.monadboxlab.clashpseudo.validation.clienta, io.github.monadboxlab.clashpseudo.validation.clientb]
            rules: ['MATCH,REJECT']
        """.trimIndent() + "\n"
        CoreIpcTestDriver.production().use { observer ->
            try {
                val prepared = platform.prepare(CoreInput("route-builder-fixture", 1, "rule", body.toByteArray(),
                    "{}".toByteArray(), name = "route-builder-fixture"))
                assertTrue(prepared.terminal.toString(), prepared.terminal.getBoolean("complete"))
                assertWholeSpecification(VpnSpecification.read(platform.query(Contract.CORE_OPERATION_VPN_SPEC).value.toString()), 32)
                assertEquals(body, platform.runRecord().getString("body"))
                assertTrue(platform.query(Contract.CORE_OPERATION_SNAPSHOT).value.getBoolean("attached"))
            } finally {
                platform.exit()
                observer.awaitDeath()
                assertFalse(CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java))
            }
        }
    }

    @Test fun explicitIpv6AddressCannotBeSilentlyRemovedWhenIpv6IsDisabled() {
        requireIdleAndClients()
        val body = """
            ipv6: false
            geo-auto-update: false
            geox-url: {geoip: '', geosite: '', mmdb: '', asn: ''}
            dns: {enable: true, nameserver: [192.168.100.2]}
            tun:
              stack: mips
              inet6-address: ['fdfe:dcba:9876::1/126']
              dns-hijack: ['198.18.0.2:53']
              route-address: ['198.18.0.0/16']
            rules: ['MATCH,REJECT']
        """.trimIndent() + "\n"
        CoreIpcTestDriver.production().use { observer ->
            try {
                val rejected = platform.prepare(CoreInput("ipv6-fixture", 1, "rule", body.toByteArray(), "{}".toByteArray(), name = "ipv6-fixture"))
                assertFalse(rejected.terminal.toString(), rejected.terminal.getBoolean("complete"))
                val failure = rejected.terminal.getJSONObject("error")
                val native = failure.getJSONObject("nativeError")
                val original = native.getString("message")
                assertEquals(original, failure.getString("message"))
                assertEquals("tun.inet6-address: ipv6Unavailable", original)
                val error = checkNotNull(AppMessage.fromMap(native.getJSONObject("cause")))
                assertEquals("nativeConfigurationUnsupported", error.id)
                assertEquals("tun.inet6-address", error.args["field"])
                assertEquals(AppMessage("nativeReasonIpv6Unavailable"), error.args["reason"])
                assertEquals(false, platform.status()["vpnRunning"])
                observer.awaitDeath()
                assertTrue(observer.deathConfirmed)
                platform.await("The default process confirms exit of the failed core") {
                    val state = io.github.monadboxlab.clashpseudo.nativecore.CoreClient.get(context).status()
                    state[Contract.CORE_FIELD_PROCESS_ID] == observer.processId &&
                        state[Contract.CORE_FIELD_PHASE] == Contract.CORE_PHASE_EXITED
                }
                assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
                assertFalse(CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java))
            } finally {
                platform.exit()
                observer.awaitDeath()
            }
        }
        CoreIpcTestDriver.production().use { recovered ->
            try {
                assertEquals(recovered.processId, platform.handshake()[Contract.CORE_FIELD_PROCESS_ID])
                val state = platform.query(Contract.CORE_OPERATION_SNAPSHOT)
                assertTrue(state.terminal.toString(), state.terminal.getBoolean("complete"))
                NativeCoreFailureTest.assertStopped(state.value)
            } finally {
                platform.exit()
                recovered.awaitDeath()
            }
        }
    }

    @Test fun formalFileRouteSetUpdatesRebuildVpnFromLatestProjection() {
        val id = "p5-route-formal-r7v4"
        check(InstrumentationRegistry.getArguments().getString("nonce") == id) { "Provide nonce=p5-route-formal-r7v4 and a configuration restored through the application" }
        requireIdleAndClients()
        val body = """
            mode: rule
            ipv6: false
            find-process-mode: off
            geo-auto-update: false
            geox-url: {geoip: '', geosite: '', mmdb: '', asn: ''}
            profile: {store-selected: false, store-fake-ip: false}
            dns: {enable: true, enhanced-mode: redir-host, nameserver: [192.168.100.2]}
            tun:
              stack: gvisor
              mtu: 1420
              route-address: [198.18.0.0/16]
              route-address-set: [p5-routes-formal-r7v4]
              dns-hijack: ['198.18.0.2:53']
              include-package: [io.github.monadboxlab.clashpseudo.validation.clienta, io.github.monadboxlab.clashpseudo.validation.clientb]
            rule-providers:
              p5-routes-formal-r7v4: {type: file, behavior: ipcidr, format: text, path: p5-routes-formal-r7v4.txt, interval: 0}
            rules: ['MATCH,REJECT']
        """.trimIndent() + "\n"
        val initialFixture = CoreIpcTestDriver.fixture()
        val ownership = initialFixture.debug.formalRoutes(1, 0, 0)
        val observers = mutableListOf(initialFixture)
        var currentFixture = initialFixture
        var started = false
        var original: VpnSpecification? = null
        var failure: Throwable? = null
        fun inspect(prefix: Int, previousProcess: String?): String {
            platform.await("Application VPN and writer finish") {
                val state = PseudoVpnService.session.snapshot()
                assertNotEquals(NativeSession.Phase.UNKNOWN, state.phase)
                if (state.phase == NativeSession.Phase.STOPPED && state.error != null) fail("Application startup failed: ${state.error}")
                state.phase == NativeSession.Phase.RUNNING && state.configId == id &&
                    !AppBridge.pendingSystemRestore && !AppBridge.logic.busy && AppBridge.operationId == null
            }
            val loaded = platform.status()
            val process = loaded["processId"] as String
            if (previousProcess != null) assertNotEquals(previousProcess, process)
            assertEquals(1L, (loaded["generation"] as Number).toLong())
            assertEquals(id, loaded["configId"])
            assertEquals(1, (loaded["revision"] as Number).toInt())
            assertEquals(Contract.CORE_PURPOSE_RUNNING, loaded["purpose"])
            assertEquals(true, loaded["vpnRunning"])
            val input = platform.runRecord(loaded)
            assertEquals(id, input.getString("id"))
            assertEquals(id, input.getString("name"))
            assertEquals(1, input.getInt("revision"))
            assertEquals("rule", input.getString("mode"))
            assertEquals(body, input.getString("body"))
            assertEquals("317b4c006f4db391db78c6c16e78ca54a6dfdc0fd63ecfab7b18055d1bb5d4be", sha256(input.getString("body")))
            assertEquals(0, input.getJSONArray("overrides").length())
            val actual = VpnSpecification.read(platform.query(Contract.CORE_OPERATION_VPN_SPEC).value.toString())
            assertEquals(1L, actual.revision)
            assertEquals(input.getString("composition"), actual.composition)
            assertWholeSpecification(actual, prefix)
            original?.let { assertEquals(it.copy(generation = actual.generation, routes = actual.routes, networkKey = actual.networkKey), actual) }
                ?: run { original = actual }
            val native = platform.query(Contract.CORE_OPERATION_SNAPSHOT).value
            assertTrue(native.getBoolean("prepared")); assertTrue(native.getBoolean("attached")); assertFalse(native.getBoolean("cleanupFailed"))
            assertEquals("rule", platform.query(Contract.CORE_OPERATION_MODE).value.getString("mode"))
            return process
        }
        try {
            started = true
            val intent = Intent(context, PseudoVpnService::class.java).setAction(VpnService.SERVICE_INTERFACE)
            assertNotNull(if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent))
            var process = inspect(32, null)
            for ((action, prefix) in listOf(2 to 31, 3 to 32)) {
                assertEquals(process, currentFixture.processId)
                currentFixture.debug.formalRoutes(action, ownership.getLong("device"), ownership.getLong("inode"))
                val result = platform.query(Contract.CORE_OPERATION_RESOURCE_UPDATE,
                    mapOf("kind" to "ruleProvider", "name" to "p5-routes-formal-r7v4"))
                assertTrue(result.terminal.toString(), result.terminal.getBoolean("complete"))
                assertEquals("ok", result.value.getString("status"))
                currentFixture.awaitDeath()
                assertTrue(currentFixture.deathConfirmed)
                platform.await("Replacement process is actually ready") { (io.github.monadboxlab.clashpseudo.nativecore.CoreClient.get(context).status()["phase"] == Contract.CORE_PHASE_READY) &&
                    PseudoVpnService.session.snapshot().phase == NativeSession.Phase.RUNNING }
                currentFixture = CoreIpcTestDriver.fixture().also(observers::add)
                process = inspect(prefix, process)
            }
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            try {
                if (started) {
                    assertEquals(id, platform.status()["configId"])
                    platform.stopFromSystemControl()
                    currentFixture.awaitDeath()
                    platform.await("Application Stop and actual operation drain") { PseudoVpnService.session.snapshot().phase == NativeSession.Phase.STOPPED &&
                        !AppBridge.logic.busy && AppBridge.operationId == null && !AppBridge.pendingSystemRestore &&
                        !CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java) }
                }
                assertTrue(observers.all { it.deathConfirmed })
                observers.forEach { it.close() }
                CoreIpcTestDriver.fixture().use { cleanup ->
                    assertTrue(cleanup.debug.formalRoutes(4, ownership.getLong("device"), ownership.getLong("inode")).getBoolean("removed"))
                    cleanup.exit()
                }
            } catch (cleanup: Throwable) { if (failure == null) throw cleanup else if (cleanup !== failure) failure.addSuppressed(cleanup) }
        }
    }

    private fun prepareAtBuilderGate(observer: CoreIpcTestDriver): CoreIpcTestDriver.Pending {
        val inputId = java.util.UUID.randomUUID().toString()
        val arguments = JSONObject().put("purpose", Contract.CORE_PURPOSE_RUNNING)
            .put("vpnIntent", true).put("lanIntent", false)
            .put("configId", "p5-worker-config-p5-load-worker-r7w12").put("revision", 2).put("mode", "rule")
            .put("deadline", android.os.SystemClock.elapsedRealtime() + Contract.OPERATION_ORDINARY_TIMEOUT_MS)
        val body = """
            geo-auto-update: false
            profile: {store-selected: false, store-fake-ip: false}
            tun:
              route-address: [198.18.0.0/16]
              dns-hijack: []
              include-package: [${context.packageName}]
            rules: ['MATCH,REJECT']
        """.trimIndent() + "\n"
        return observer.submit(Contract.CORE_OPERATION_PREPARE, arguments, inputId, 1,
            parts = mapOf(Contract.CORE_PART_CONFIG to body.toByteArray(),
                Contract.CORE_PART_OVERRIDES to "[]".toByteArray(),
                Contract.CORE_PART_OPTIONS to JSONObject().put("purpose", Contract.CORE_PURPOSE_RUNNING)
                    .put("generation", 1).put("composition", "gate-$inputId").toString().toByteArray()))
    }

    private fun requireIdle() {
        platform.await("Application writer is idle") { !AppBridge.logic.busy && AppBridge.operationId == null && !AppBridge.pendingSystemRestore }
        assertFalse(CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java))
        assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
        assertNull("VPN must already be authorized; do not open the grant dialog", VpnService.prepare(context))
        CoreIpcTestDriver.assertNoGoInApplication()
    }

    private fun requireIdleAndClients() {
        requireIdle()
        val own = setOf(context.applicationInfo.uid, instrumentation.context.applicationInfo.uid)
        val uids = clients.map { context.packageManager.getApplicationInfo(it, 0).uid }
        assertEquals(2, uids.toSet().size)
        assertTrue(uids.none { it in own })
    }

    private fun assertWholeSpecification(value: VpnSpecification, prefix: Int) {
        assertEquals(1420, value.mtu)
        assertEquals(listOf("198.18.0.1" to 30), value.addresses)
        assertEquals(listOf("198.18.0.2"), value.dnsServers)
        assertFalse(value.usesSystemDns)
        assertTrue(value.filter.configured)
        assertEquals(clients, value.filter.includePackage)
        assertEquals(setOf("198.18.0.0" to 16, "192.168.100.2" to prefix), value.routes.toSet())
        assertEquals(2, value.routes.size)
        assertEquals(value.routes.size, value.routes.toSet().size)
    }
    private fun sha256(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
}
