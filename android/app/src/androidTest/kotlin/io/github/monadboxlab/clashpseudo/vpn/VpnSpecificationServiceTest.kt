package io.github.monadboxlab.clashpseudo.vpn

import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.app.AppFiles
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import io.github.monadboxlab.clashpseudo.nativecore.NativeCoreFailureTest
import io.github.monadboxlab.clashpseudo.nativecore.VpnSpecification
import java.io.File
import java.util.UUID
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class VpnSpecificationServiceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    @Test fun fileRouteSetChangesAndRevertsWholeServiceSpecificationAndInvalidatesPreAttachRevision() {
        main {
            assertNull("Run without another Service owner", PseudoVpnService.instance)
            assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
            assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
            assertFalse(AppBridge.pendingSystemRestore)
            assertFalse(AppBridge.logic.busy)
            assertNull(AppBridge.operationId)
            assertNull("Authorize VPN before this test; do not launch a grant dialog", VpnService.prepare(context))
        }
        // Only these existing independent clients enter Builder's allowlist. Neither
        // the application nor the instrumentation UID may be captured by this test.
        val clients = listOf("io.github.monadboxlab.clashpseudo.validation.clienta",
            "io.github.monadboxlab.clashpseudo.validation.clientb")
        val ownUids = setOf(context.applicationInfo.uid, instrumentation.context.applicationInfo.uid)
        val clientUids = clients.map { context.packageManager.getApplicationInfo(it, 0).uid }
        assertEquals(2, clientUids.toSet().size)
        assertTrue(clientUids.none { it in ownUids })
        val home = AppFiles.core(context)
        // Use one unique file directly beneath the existing core home.
        assertTrue(home.isDirectory)
        assertEquals(home.absoluteFile, home.canonicalFile)
        val token = UUID.randomUUID().toString()
        val name = "p5-routes-$token"
        val provider = File(home, "$name.txt")
        assertFalse(provider.exists())
        assertTrue(provider.createNewFile())
        val identity = Os.lstat(provider.path)
        fun requireOwnFile() {
            val now = Os.lstat(provider.path)
            check(OsConstants.S_ISREG(now.st_mode) && now.st_nlink == 1L &&
                now.st_dev == identity.st_dev && now.st_ino == identity.st_ino) { "Test provider ownership changed" }
        }
        fun writeRoutes(prefix: String) {
            requireOwnFile()
            provider.writeText("$prefix\n", Charsets.UTF_8)
        }
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
              route-address-set: [$name]
              dns-hijack: ['198.18.0.2:53']
              include-package: [${clients.joinToString(", ")}]
            rule-providers:
              $name: {type: file, behavior: ipcidr, format: text, path: $name.txt, interval: 0}
            rules: ['MATCH,REJECT']
        """.trimIndent() + "\n"
        var serviceGeneration: Long? = null
        var rawOwned = false
        var rawSessionGeneration = -1L
        var rawCoreGeneration = -1L
        var cleanupConfirmed = false
        var failure: Throwable? = null
        fun rawOwnerCurrent() {
            check(PseudoVpnService.session.snapshot().let {
                it.generation == rawSessionGeneration && it.phase == NativeSession.Phase.STOPPED
            } && PseudoVpnService.core.snapshot().let {
                it.generation == rawCoreGeneration && it.phase == CoreHost.Phase.EMPTY
            }) { "Another owner replaced the raw API test" }
            if (rawOwned) {
                val native = JSONObject(NativeCore.snapshot())
                if (native.getBoolean("prepared")) {
                    val spec = specification()
                    check(spec.generation == 1L && spec.composition == token) { "Native owner changed" }
                }
            }
        }
        try {
            writeRoutes("192.168.100.2/32")
            main {
                val before = PseudoVpnService.session.snapshot()
                assertEquals(NativeSession.Phase.STOPPED, before.phase)
                serviceGeneration = before.generation + 1
                assertNotNull(context.startForegroundService(Intent(context, PseudoVpnService::class.java)
                    .setAction(PseudoVpnService.ACTION_START)
                    .putExtra(PseudoVpnService.EXTRA_CONFIG, body)))
            }
            await("real Service Builder/Attach") {
                val state = PseudoVpnService.session.snapshot()
                val expected = checkNotNull(serviceGeneration)
                if (state.generation < expected) return@await false
                assertEquals(expected, state.generation)
                assertNotEquals(NativeSession.Phase.UNKNOWN, state.phase)
                if (state.phase == NativeSession.Phase.STOPPED)
                    state.error?.let { fail("Service failed: ${it.id}") }
                state.phase == NativeSession.Phase.RUNNING
            }
            val initial = worker { specification() }
            assertEquals(1L, initial.revision)
            assertEquals(1420, initial.mtu)
            assertEquals(listOf("198.18.0.1" to 30), initial.addresses)
            assertEquals(listOf("198.18.0.2"), initial.dnsServers)
            assertFalse(initial.usesSystemDns)
            assertTrue(initial.filter.configured)
            assertEquals(clients, initial.filter.includePackage)
            assertEquals(setOf("198.18.0.0" to 16, "192.168.100.2" to 32), initial.routes.toSet())
            worker {
                assertTrue(JSONObject(NativeCore.snapshot()).getBoolean("attached"))
                val core = PseudoVpnService.core.snapshot()
                assertEquals(core.generation, initial.generation)
                assertEquals(core.composition, initial.composition)
                // Raw EXTRA_CONFIG exercises direct native updates independently of
                // formal RunningInput reconnect.
                val rawInput = JSONObject(checkNotNull(PseudoVpnService.core.runningInput(
                    core.generation, initial.composition)).toString(Charsets.UTF_8))
                assertEquals("", rawInput.getString("name"))
                assertEquals(body, rawInput.getString("body"))
            }
            writeRoutes("192.168.100.2/31")
            update(name)
            awaitSpecification(initial.copy(revision = 2,
                routes = listOf("192.168.100.2" to 31, "198.18.0.0" to 16)))
            await("actual CoreHost route callback") {
                PseudoVpnService.core.runtimeRefreshCurrent(checkNotNull(serviceGeneration),
                    initial.generation, initial.composition, 2, "routes")
            }
            writeRoutes("192.168.100.2/32")
            update(name)
            awaitSpecification(initial.copy(revision = 3))
            await("route revert invalidates pending callback") {
                !PseudoVpnService.core.runtimeRefreshCurrent(checkNotNull(serviceGeneration),
                    initial.generation, initial.composition, 2, "routes")
            }
            assertFalse(PseudoVpnService.core.runtimeRefreshCurrent(checkNotNull(serviceGeneration),
                initial.generation, initial.composition, 3, "routes"))
            assertEquals(NativeSession.Phase.RUNNING, PseudoVpnService.session.snapshot().phase)
            assertEquals(serviceGeneration, PseudoVpnService.session.snapshot().generation)
            stopService(checkNotNull(serviceGeneration))
            serviceGeneration = null

            // An already-attached engine rejects ANY second Attach before its
            // revision check. Exercise the distinguishing stale-revision guard in
            // one real, un-attached native preparation of the identical file config.
            rawSessionGeneration = PseudoVpnService.session.snapshot().generation
            rawCoreGeneration = PseudoVpnService.core.snapshot().generation
            worker {
                rawOwnerCurrent()
                assertFalse(JSONObject(NativeCore.snapshot()).getBoolean("prepared"))
                rawOwned = true
                val options = JSONObject().put("purpose", "VPN").put("generation", 1)
                    .put("composition", token).toString().toByteArray(Charsets.UTF_8)
                assertEquals("", NativeCore.prepare(home.path, body.toByteArray(Charsets.UTF_8), "rule",
                    NativeCoreFailureTest.Protector(accept = false), options = options))
            }
            val beforeAttach = worker { rawOwnerCurrent(); specification() }
            writeRoutes("192.168.100.2/31")
            update(name)
            val changed = awaitSpecification(beforeAttach.copy(revision = 2,
                routes = listOf("192.168.100.2" to 31, "198.18.0.0" to 16)))
            rejectStaleAttach(beforeAttach.revision, ::rawOwnerCurrent)
            writeRoutes("192.168.100.2/32")
            update(name)
            awaitSpecification(beforeAttach.copy(revision = 3))
            rejectStaleAttach(beforeAttach.revision, ::rawOwnerCurrent)
            rejectStaleAttach(changed.revision, ::rawOwnerCurrent)
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            try {
                serviceGeneration?.let(::stopService)
                worker {
                    if (rawOwned) {
                        rawOwnerCurrent()
                        assertEquals("", NativeCore.stop())
                        rawOwned = false
                    }
                    val native = JSONObject(NativeCore.snapshot())
                    assertFalse(native.getBoolean("prepared"))
                    assertFalse(native.getBoolean("attached"))
                    assertFalse(native.getBoolean("cleanupFailed"))
                }
                cleanupConfirmed = true
            } catch (cleanup: Throwable) {
                if (failure != null) failure.addSuppressed(cleanup) else throw cleanup
            } finally {
                // Delete provider resources only after confirmed Stop and worker
                // completion.
                if (cleanupConfirmed) {
                    requireOwnFile()
                    assertTrue(provider.delete())
                }
            }
        }
    }

    @Test fun explicitIpv6AddressCannotBeSilentlyRemovedWhenIpv6IsDisabled() {
        var generation = 0L
        main {
            assertNull(PseudoVpnService.instance)
            assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
            assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
            assertFalse(AppBridge.logic.busy)
            assertNull(AppBridge.operationId)
            assertNull(VpnService.prepare(context))
            generation = PseudoVpnService.session.snapshot().generation + 1
        }
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
        try {
            assertNotNull(context.startForegroundService(Intent(context, PseudoVpnService::class.java)
                .setAction(PseudoVpnService.ACTION_START)
                .putExtra(PseudoVpnService.EXTRA_CONFIG, body)))
            await("explicit IPv6 loss rejected before Builder") {
                val state = PseudoVpnService.session.snapshot()
                check(state.generation <= generation)
                assertNotEquals(NativeSession.Phase.RUNNING, state.phase)
                assertNotEquals(NativeSession.Phase.UNKNOWN, state.phase)
                state.generation == generation && state.phase == NativeSession.Phase.STOPPED &&
                    PseudoVpnService.instance == null && PseudoVpnService.core.snapshot().phase == CoreHost.Phase.EMPTY
            }
            val error = checkNotNull(PseudoVpnService.session.snapshot().error)
            assertEquals("nativeConfigurationUnsupported", error.id)
            assertEquals("tun.inet6-address", error.args["field"])
            assertEquals(io.github.monadboxlab.clashpseudo.app.AppMessage("nativeReasonIpv6Unavailable"), error.args["reason"])
            worker {
                val native = JSONObject(NativeCore.snapshot())
                assertFalse(native.getBoolean("prepared"))
                assertFalse(native.getBoolean("attached"))
                assertFalse(native.getBoolean("cleanupFailed"))
            }
        } finally {
            stopService(generation)
        }
    }

    @Test fun formalFileRouteSetUpdatesRebuildVpnFromLatestProjection() {
        val id = "p5-route-formal-r7v4"
        check(InstrumentationRegistry.getArguments().getString("nonce") == id) {
            "This test requires nonce=p5-route-formal-r7v4 and its formally restored configuration"
        }
        val name = "p5-routes-formal-r7v4"
        val clients = listOf("io.github.monadboxlab.clashpseudo.validation.clienta",
            "io.github.monadboxlab.clashpseudo.validation.clientb")
        val ownUids = setOf(context.applicationInfo.uid, instrumentation.context.applicationInfo.uid)
        val clientUids = clients.map { context.packageManager.getApplicationInfo(it, 0).uid }
        assertEquals(2, clientUids.toSet().size)
        assertTrue(clientUids.none { it in ownUids })
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
        var firstGeneration = -1L
        main {
            assertNull(PseudoVpnService.instance)
            val session = PseudoVpnService.session.snapshot()
            assertEquals(NativeSession.Phase.STOPPED, session.phase)
            assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
            assertFalse(AppBridge.pendingSystemRestore)
            assertFalse(AppBridge.logic.busy)
            assertNull(AppBridge.operationId)
            assertNull(VpnService.prepare(context))
            firstGeneration = session.generation + 1
        }
        val home = AppFiles.core(context)
        assertTrue(home.isDirectory)
        assertEquals(home.absoluteFile, home.canonicalFile)
        val provider = File(home, "$name.txt")
        assertFalse(provider.exists())
        assertTrue("Never overwrite a pre-existing provider", provider.createNewFile())
        val identity = Os.lstat(provider.path)
        fun requireOwnFile() {
            val now = Os.lstat(provider.path)
            check(OsConstants.S_ISREG(now.st_mode) && now.st_nlink == 1L &&
                now.st_dev == identity.st_dev && now.st_ino == identity.st_ino) { "Formal test provider ownership changed" }
        }
        fun writeRoutes(prefix: String) {
            requireOwnFile()
            provider.writeText("$prefix\n", Charsets.UTF_8)
        }
        val ownedGenerations = mutableSetOf<Long>()
        var initialSpec: VpnSpecification? = null
        var started = false
        var failure: Throwable? = null
        fun awaitRunning(expectedGeneration: Long, prefix: Int, previousCore: Long?): CoreHost.Snapshot {
            lateinit var loaded: CoreHost.Snapshot
            await("formal VPN generation $expectedGeneration and actual business drain") {
                var ready = false
                main {
                    val session = PseudoVpnService.session.snapshot()
                    check(session.generation <= expectedGeneration) { "Unexpected replacement generation" }
                    assertNotEquals(NativeSession.Phase.UNKNOWN, session.phase)
                    if (session.generation in firstGeneration..firstGeneration + 2 && session.configId == id)
                        ownedGenerations.add(session.generation)
                    if (session.generation == expectedGeneration && session.phase == NativeSession.Phase.STOPPED)
                        session.error?.let { fail("Formal startup failed: ${it.id}") }
                    val core = PseudoVpnService.core.snapshot()
                    assertNotEquals(CoreHost.Phase.FAILED, core.phase)
                    ready = session.generation == expectedGeneration && session.phase == NativeSession.Phase.RUNNING &&
                        core.phase == CoreHost.Phase.READY && core.purpose == CoreHost.Purpose.VPN &&
                        !AppBridge.pendingSystemRestore && !AppBridge.logic.busy && AppBridge.operationId == null
                    if (ready) {
                        assertEquals(id, session.configId)
                        assertEquals(1, session.revision)
                        assertEquals(id, core.configId)
                        assertEquals(1, core.revision)
                        loaded = core
                    }
                }
                ready
            }
            val composition = checkNotNull(loaded.composition)
            val (input, native, spec) = worker {
                val bytes = checkNotNull(PseudoVpnService.core.runningInput(loaded.generation, composition))
                assertEquals("rule", NativeCore.mode())
                Triple(JSONObject(bytes.toString(Charsets.UTF_8)), JSONObject(NativeCore.snapshot()), specification())
            }
            assertEquals(id, input.getString("id"))
            assertEquals(id, input.getString("name"))
            assertEquals(1, input.getInt("revision"))
            assertEquals("rule", input.getString("mode"))
            assertEquals(body, input.getString("body"))
            assertEquals("317b4c006f4db391db78c6c16e78ca54a6dfdc0fd63ecfab7b18055d1bb5d4be",
                java.security.MessageDigest.getInstance("SHA-256")
                    .digest(input.getString("body").toByteArray(Charsets.UTF_8))
                    .joinToString("") { "%02x".format(it) })
            assertEquals(0, input.getJSONArray("overrides").length())
            assertEquals(composition, input.getString("composition"))
            assertTrue(native.getBoolean("prepared"))
            assertTrue(native.getBoolean("attached"))
            assertFalse(native.getBoolean("cleanupFailed"))
            assertEquals(loaded.generation, spec.generation)
            assertEquals(composition, spec.composition)
            assertEquals(1L, spec.revision)
            assertEquals(setOf("198.18.0.0" to 16, "192.168.100.2" to prefix), spec.routes.toSet())
            assertEquals(2, spec.routes.size)
            val initial = initialSpec
            if (initial == null) {
                assertEquals(1420, spec.mtu)
                assertEquals(listOf("198.18.0.1" to 30), spec.addresses)
                assertEquals(listOf("198.18.0.2"), spec.dnsServers)
                assertFalse(spec.usesSystemDns)
                assertTrue(spec.filter.configured)
                assertEquals(clients, spec.filter.includePackage)
                initialSpec = spec
            } else {
                assertEquals(initial.composition, composition)
                assertEquals(initial.copy(generation = spec.generation, routes = spec.routes), spec)
            }
            if (previousCore != null) assertTrue(loaded.generation > previousCore)
            main {
                val session = PseudoVpnService.session.snapshot()
                assertEquals(expectedGeneration, session.generation)
                assertEquals(NativeSession.Phase.RUNNING, session.phase)
                assertEquals(id, session.configId)
                assertEquals(loaded, PseudoVpnService.core.snapshot())
                assertFalse(AppBridge.logic.busy)
                assertNull(AppBridge.operationId)
            }
            android.util.Log.i("SystemStartCheck", "formalRoute nonce=p5-route-formal-r7v4 " +
                "session=$expectedGeneration core=${loaded.generation} prefix=$prefix specRevision=${spec.revision} " +
                "inputMatched=true nativeAttached=true writerDrained=true")
            return loaded
        }
        try {
            writeRoutes("192.168.100.2/32")
            main {
                assertEquals(firstGeneration - 1, PseudoVpnService.session.snapshot().generation)
                assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
                started = true
                assertNotNull(context.startForegroundService(Intent(context, PseudoVpnService::class.java)
                    .setAction(VpnService.SERVICE_INTERFACE)))
            }
            val initial = awaitRunning(firstGeneration, 32, null)
            writeRoutes("192.168.100.2/31")
            update(name)
            val changed = awaitRunning(firstGeneration + 1, 31, initial.generation)
            writeRoutes("192.168.100.2/32")
            update(name)
            awaitRunning(firstGeneration + 2, 32, changed.generation)
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            try {
                if (started) {
                    main {
                        val session = PseudoVpnService.session.snapshot()
                        check(session.generation in firstGeneration..firstGeneration + 2) { "Do not stop a replacement owner" }
                        check(session.configId == id || (session.phase == NativeSession.Phase.STOPPED &&
                            session.generation in ownedGenerations)) { "Formal cleanup cannot identify its configuration" }
                        check(session.phase != NativeSession.Phase.UNKNOWN) { "Native cleanup is unknown" }
                        if (AppBridge.operationId != null || AppBridge.logic.busy) {
                            val command = checkNotNull(AppBridge.command) { "An unidentified business owner is active" }
                            val sourceGeneration = (command["sessionGeneration"] as? Number)?.toLong()
                            check(command["action"] == "refreshRuntime" && sourceGeneration != null &&
                                sourceGeneration in ownedGenerations &&
                                command["composition"] == initialSpec?.composition) { "Another business owner is active" }
                        }
                        context.startService(Intent(context, PseudoVpnService::class.java)
                            .setAction(PseudoVpnService.ACTION_STOP))
                    }
                }
                await("formal normal Stop and all business/native work drained") {
                    var stopped = false
                    main {
                        val session = PseudoVpnService.session.snapshot()
                        if (started) check(session.generation in firstGeneration..firstGeneration + 2)
                        assertNotEquals(NativeSession.Phase.UNKNOWN, session.phase)
                        assertNotEquals(CoreHost.Phase.FAILED, PseudoVpnService.core.snapshot().phase)
                        stopped = session.phase == NativeSession.Phase.STOPPED && PseudoVpnService.instance == null &&
                            PseudoVpnService.core.snapshot().phase == CoreHost.Phase.EMPTY &&
                            !AppBridge.logic.busy && AppBridge.operationId == null && !AppBridge.pendingSystemRestore
                    }
                    stopped
                }
                worker {
                    val native = JSONObject(NativeCore.snapshot())
                    assertFalse(native.getBoolean("prepared"))
                    assertFalse(native.getBoolean("attached"))
                    assertFalse(native.getBoolean("cleanupFailed"))
                }
                requireOwnFile()
                assertTrue(provider.delete())
            } catch (cleanup: Throwable) {
                // Unknown ownership/drain leaves only this test's provider for inspection.
                if (failure != null) failure.addSuppressed(cleanup) else throw cleanup
            }
        }
    }

    private fun rejectStaleAttach(revision: Long, owner: () -> Unit) = worker {
        owner()
        ParcelFileDescriptor.open(File("/dev/null"), ParcelFileDescriptor.MODE_READ_WRITE).use {
            val fd = it.fd
            val error = NativeCore.attach(it, revision)
            assertTrue(error, error.contains("specification revision changed"))
            assertEquals(fd, it.fd)
            Os.fstat(it.fileDescriptor) // JNI rejected before ownership transfer.
        }
        assertFalse(JSONObject(NativeCore.snapshot()).getBoolean("attached"))
    }

    private fun update(name: String) = worker {
        val request = JSONObject().put("kind", "ruleProvider").put("name", name)
        val result = JSONObject(NativeCore.updateResource(request.toString().toByteArray(Charsets.UTF_8)))
        assertFalse(result.toString(), result.has("error"))
        assertEquals("ok", result.getString("status"))
    }

    private fun specification() = VpnSpecification.read(NativeCore.vpnSpec())

    private fun awaitSpecification(expected: VpnSpecification): VpnSpecification {
        var actual: VpnSpecification? = null
        await("whole route specification revision ${expected.revision}") {
            actual = worker { specification() }
            actual!!.revision >= expected.revision
        }
        // Compare Builder fields as one projection, compare routes as a set, and
        // reject duplicate routes.
        val value = checkNotNull(actual)
        assertEquals(value.routes.size, value.routes.toSet().size)
        assertEquals(expected.routes.toSet(), value.routes.toSet())
        assertEquals(expected, value.copy(routes = expected.routes))
        return value
    }

    private fun stopService(generation: Long) {
        await("accepted Service generation") {
            val now = PseudoVpnService.session.snapshot().generation
            check(now <= generation) { "Do not stop a replacement owner" }
            now == generation
        }
        main {
            val now = PseudoVpnService.session.snapshot()
            check(now.generation == generation) { "Do not stop a replacement owner" }
            if (PseudoVpnService.instance != null) {
                context.startService(Intent(context, PseudoVpnService::class.java)
                    .setAction(PseudoVpnService.ACTION_STOP))
            }
        }
        await("normal Service Stop and destruction") {
            PseudoVpnService.session.snapshot().let {
                check(it.generation == generation) { "Owner changed during Stop" }
                assertNotEquals(NativeSession.Phase.UNKNOWN, it.phase)
                it.phase == NativeSession.Phase.STOPPED
            } && PseudoVpnService.instance == null &&
                PseudoVpnService.core.snapshot().phase == CoreHost.Phase.EMPTY &&
                !AppBridge.logic.busy && AppBridge.operationId == null
        }
        worker { Unit } // Normal cleanup work has returned; do not shut down the shared executor.
    }

    private fun main(block: () -> Unit) = instrumentation.runOnMainSync(block)

    private fun await(label: String, ready: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (!ready()) {
            check(SystemClock.elapsedRealtime() < deadline) { "Timed out waiting for $label" }
            Thread.sleep(25)
        }
    }

    private fun <T> worker(block: () -> T): T {
        val task = FutureTask(block)
        PseudoVpnService.worker.execute(task)
        return task.get(30, TimeUnit.SECONDS)
    }
}
