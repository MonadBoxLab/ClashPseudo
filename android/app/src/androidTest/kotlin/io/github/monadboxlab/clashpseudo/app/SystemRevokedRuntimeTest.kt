package io.github.monadboxlab.clashpseudo.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.VpnService
import android.os.Bundle
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.controls.SystemControls
import io.github.monadboxlab.clashpseudo.debug.CoreFixtureContract as Fixture
import io.github.monadboxlab.clashpseudo.logic.AppRuntimeService
import io.github.monadboxlab.clashpseudo.nativecore.CoreClient
import io.github.monadboxlab.clashpseudo.nativecore.CoreFrames
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CorePlatformTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CorePreparationObserver
import io.github.monadboxlab.clashpseudo.nativecore.CorePrivateFiles
import io.github.monadboxlab.clashpseudo.nativecore.CoreResourceGate
import io.github.monadboxlab.clashpseudo.nativecore.CoreService
import io.github.monadboxlab.clashpseudo.nativecore.ipc.IRuntimeCallback
import io.github.monadboxlab.clashpseudo.nativecore.ipc.IRuntimeService
import io.github.monadboxlab.clashpseudo.nativecore.input.CoreInput
import io.github.monadboxlab.clashpseudo.storage.AppFiles
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import io.github.monadboxlab.clashpseudo.vpn.network.LocalInterfaces
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.UUID

/** Check recovery order using actual :core revoke, immutable input, and an unread production FD. */
class SystemRevokedRuntimeTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val platform = CorePlatformTestDriver(context)
    private val client get() = CoreClient.get(context)

    @Test fun revokeWaitsForActualRequestDrainAndKeepsLanWithoutVpn() = withLan { running, observers ->
        val beforeFiles = runRecords()
        val held = submit(Contract.CORE_OPERATION_RUNTIME_CONFIG, running.status)
        assertTrue(client.requestBusy)
        revoke(running)
        val owner = awaitWaiting(running)
        val admittedAt = main { AppBridge.operationAdmittedAt }
        val deadline = main { AppBridge.operationDeadline }
        val event = running.status + ("event" to "revoked")
        val stale = listOf(
            event + ("processId" to UUID.randomUUID().toString()),
            event + ("inputId" to UUID.randomUUID().toString()),
            event + ("generation" to ((event["generation"] as Number).toLong() + 1)),
            event + ("networkRevision" to ((event["networkRevision"] as Number).toLong() + 1)),
            event + ("configId" to "another-config"),
            event + ("revision" to 2),
            event + ("composition" to "[]"),
            event + ("purpose" to Contract.CORE_PURPOSE_PREVIEW),
        )
        main {
            for (candidate in stale) {
                assertFalse("Revoke with an old identity must not revoke the current owner", AppBridge.systemRevoked(candidate))
                assertEquals(owner, AppBridge.operationId)
                assertEquals(admittedAt, AppBridge.operationAdmittedAt)
                assertEquals(deadline, AppBridge.operationDeadline)
                assertEquals("waiting", AppBridge.command?.get("revocationState"))
            }
            assertEquals(true, AppBridge.runtimeState()["writerBusy"])
            assertFalse("LAN recovery must not run before the old FD drains", AppBridge.logic.ownsOperation(owner))
        }
        assertEquals("LAN input must not be published while the old request is unread", beforeFiles, runRecords())
        assertEquals(running.status["processId"], client.status()["processId"])
        assertTrue(drainTerminal(held).getBoolean("complete"))
        try {
            platform.await("Restore only LAN after revoke", 120_000) {
                val status = client.status()
                status["phase"] == Contract.CORE_PHASE_READY && status["processId"] != running.status["processId"] &&
                    status["lanRunning"] == true && status["vpnRunning"] == false &&
                    AppBridge.operationId == null && !AppBridge.logic.busy && AppBridge.runtimeState()["writerBusy"] == false
            }
        } catch (error: Throwable) {
            saveRevokeDiagnostics("lan-restore", error)
            throw error
        }
        running.observer.awaitDeath()
        val after = platform.status()
        val observer = CoreIpcTestDriver.fixture().also(observers::add)
        assertEquals(after["processId"], observer.processId)
        assertNotEquals(running.observer.pid, observer.pid)
        assertNotEquals(running.status["inputId"], after["inputId"])
        assertEquals(1L, (after["generation"] as Number).toLong())
        assertEquals(false, after["vpnIntent"])
        assertEquals(true, after["lanIntent"])
        val record = platform.runRecord(after)
        assertEquals(after["inputId"], record.getString("inputId"))
        assertFalse(record.getBoolean("vpnIntent"))
        assertTrue(record.getBoolean("lanIntent"))
        for (field in listOf("id", "revision", "body", "overrides", "choices", "composition", "access", "packages")) {
            assertEquals("LAN recovery changed immutable input field $field", running.record.get(field).toString(), record.get(field).toString())
        }
        val actual = platform.query(Contract.CORE_OPERATION_SNAPSHOT)
        assertTrue(actual.terminal.getBoolean("complete"))
        assertTrue(actual.value.getBoolean("prepared"))
        assertFalse(actual.value.getBoolean("attached"))
        assertFalse(actual.value.getJSONObject("platform").getJSONObject("vpn").getBoolean("running"))
        assertTrue(actual.value.getJSONObject("platform").getJSONObject("lan").getBoolean("running"))
        val listeners = actual.value.getJSONArray("listeners")
        assertTrue((0 until listeners.length()).map(listeners::getJSONObject).any {
            it.getString("name") == running.listenerName && it.getString("state") == "bound"
        })
        Socket().use { it.connect(InetSocketAddress(running.address, running.port), 5_000) }
        platform.await("Original VPN Service exits") { !CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java) }
        main { assertNull("Calling the callback directly must not change the SDK grant", VpnService.prepare(context)) }
        // Late events from the original process must not stop or restore a later LAN-only context.
        assertFalse(main { AppBridge.systemRevoked(event) })
        assertFalse("AppRuntimeService must reject late revoke from the original process", dispatchRuntimeEvent(running.status))
        assertEquals(after["processId"], client.status()["processId"])
        assertEquals(after["inputId"], client.status()["inputId"])
        assertEquals(true, client.status()["lanRunning"])
        assertEquals(false, client.status()["vpnRunning"])
    }

    @Test fun stopPreemptsWaitingRevokeWithoutLateLanPreparation() = withLan { running, _ ->
        val beforeFiles = runRecords()
        submit(Contract.CORE_OPERATION_RUNTIME_CONFIG, running.status)
        revoke(running)
        val owner = awaitWaiting(running)
        val admittedAt = main { AppBridge.operationAdmittedAt }
        val deadline = main { AppBridge.operationDeadline }
        assertEquals(SystemControls.Admission.ACCEPTED, platform.stopFromSystemControl())
        main {
            assertNotEquals(owner, AppBridge.operationId)
            if (AppBridge.operationId != null) {
                assertEquals("stop", AppBridge.command?.get("action"))
                assertEquals(admittedAt, AppBridge.operationAdmittedAt)
                assertEquals(deadline, AppBridge.operationDeadline)
            }
        }
        running.observer.awaitDeath()
        awaitStopped()
        assertEquals(running.status["processId"], client.status()["processId"])
        assertEquals(running.status["inputId"], client.status()["inputId"])
        assertEquals(beforeFiles, runRecords())
        // Let the retry queued on main run once; it must not start LAN late.
        val idle = java.util.concurrent.CountDownLatch(1)
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ idle.countDown() }, 150L)
        assertTrue(idle.await(10, java.util.concurrent.TimeUnit.SECONDS))
        assertEquals(Contract.CORE_PHASE_EXITED, client.status()["phase"])
        assertEquals(beforeFiles, runRecords())
        assertEquals(false, client.status()["vpnRunning"])
        assertEquals(false, client.status()["lanRunning"])
        assertFalse("Late revoke after Stop must not recreate the core", dispatchRuntimeEvent(running.status))
        assertFalse(dispatchRuntimeEvent(running.status, android.os.DeadObjectException()))
        main { assertEquals(Contract.CORE_PHASE_EXITED, client.status()["phase"]) }
        assertFalse(CoreIpcTestDriver.servicePresent(context, CoreService::class.java))
        checkNotNull(CoreResourceGate.forApplication(context).tryAcquire()).close()
    }

    @Test fun startingRevokeExitsBeforeNativePrepareAndDoesNotRequireRecovery() {
        requireIdle()
        val stores = businessFiles()
        val record = JSONObject(CoreInput("p5-worker-config-p5-load-worker-r7w12", 2, "rule", body().toByteArray(),
            "{}".toByteArray(), name = "STARTING revoke").snapshotBytes().toString(Charsets.UTF_8))
            .put("vpnIntent", true).put("lanIntent", false)
        CorePreparationObserver.armWorkerGate(context)
        var observer: CoreIpcTestDriver? = null
        var binding: java.io.Closeable? = null
        var failure: Throwable? = null
        try {
            binding = CoreIpcTestDriver.bindVpnResource(context)
            val identity = publish(record)
            val at = SystemClock.elapsedRealtime()
            submit(Contract.CORE_OPERATION_PREPARE, identity, mapOf("purpose" to Contract.CORE_PURPOSE_RUNNING,
                "vpnIntent" to true, "lanIntent" to false, "explicitStart" to true,
                "admittedAt" to at, "deadline" to at + Contract.OPERATION_ORDINARY_TIMEOUT_MS))
            platform.await("Actual PREPARE gate during STARTING") {
                CorePreparationObserver.workerGateState(context) != null && client.status()["phase"] == Contract.CORE_PHASE_LOADING
            }
            val gate = checkNotNull(CorePreparationObserver.workerGateState(context))
            observer = CoreIpcTestDriver.fixture()
            assertEquals(gate.getString("processId"), observer.processId)
            assertEquals(gate.getInt("pid"), observer.pid)
            val native = platform.query(Contract.CORE_OPERATION_SNAPSHOT)
            assertFalse(native.value.getBoolean("prepared"))
            assertFalse(native.value.getBoolean("attached"))
            val beforeRecords = runRecords()
            val callback = observer.debug.serviceControl(Fixture.REVOKE_SERVICE_OFF_MAIN)
            @Suppress("DEPRECATION")
            val acknowledgement = checkNotNull(callback.getParcelable<ParcelFileDescriptor>("revokeAcknowledgement"))
            ParcelFileDescriptor.AutoCloseOutputStream(acknowledgement).use { receipt ->
                assertEquals(observer.pid, callback.getInt("pid"))
                assertEquals(observer.processId, callback.getString("processId"))
                assertTrue(callback.getBoolean("callbackOffMain"))
                assertTrue(callback.getBoolean("callbackReturned"))
                assertTrue(callback.getBoolean("starting"))
                assertTrue(callback.getBoolean("descriptorAbsent"))
                assertFalse(callback.getBoolean("originalDescriptorClosed"))
                assertTrue(callback.getBoolean("descriptorWithdrawn"))
                assertTrue(callback.getBoolean("sameServiceOrDestroyed"))
                receipt.write(1)
                receipt.flush()
            }
            platform.await("STARTING PREPARE receives revoke cancellation") {
                checkNotNull(CorePreparationObserver.workerGateState(context)).let { it.getBoolean("cancelObserved") && it.getBoolean("finished") }
            }
            observer.awaitDeath()
            awaitStopped()
            assertEquals(gate.getString("processId"), client.status()["processId"])
            assertEquals(gate.getString("inputId"), client.status()["inputId"])
            assertEquals("revoked", client.lifecycle.snapshot().exitReason)
            assertFalse(client.lifecycle.snapshot().recoveryRequired)
            assertEquals(beforeRecords, runRecords())
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            fun cleanup(action: () -> Unit) {
                try { action() } catch (error: Throwable) {
                    if (failure == null) failure = error else if (failure !== error) failure!!.addSuppressed(error)
                }
            }
            cleanup { CorePreparationObserver.releaseWorkerGate(context) }
            cleanup { if (client.status()["phase"] !in setOf(Contract.CORE_PHASE_DISCONNECTED, Contract.CORE_PHASE_EXITED)) platform.exit() }
            cleanup { observer?.close() }
            cleanup { binding?.close() }
            cleanup { CorePreparationObserver.removeWorkerGate(context) }
            cleanup { assertStores(stores) }
            failure?.let { throw it }
        }
    }

    private data class Running(val status: Map<String, Any?>, val record: JSONObject, val observer: CoreIpcTestDriver,
                               val address: InetAddress, val port: Int, val listenerName: String)

    private fun withLan(test: (Running, MutableList<CoreIpcTestDriver>) -> Unit) {
        requireIdle()
        val stores = businessFiles()
        val rows = LocalInterfaces(context).snapshot()["addresses"] as List<*>
        val row = checkNotNull(rows.filterIsInstance<Map<*, *>>().firstOrNull {
            it["selectable"] == true && it["available"] == true && InetAddress.getByName(it["address"] as String) is Inet4Address
        }) { "Device has no selectable LAN IPv4 interface" }
        val address = InetAddress.getByName(row["address"] as String)
        val port = ServerSocket().use { it.bind(InetSocketAddress(address, 0), 1); it.localPort }
        val name = "clash-pseudo-lan-" + Base64.encodeToString("${row["interfaceName"]}\u0000${row["address"]}".toByteArray(),
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        val id = "controlled-revoke-${UUID.randomUUID()}"
        val plugin = JSONObject().put("id", "$id-lan").put("revision", 1).put("mode", "prepend")
            .put("name", "LAN revoke").put("role", "lanProxy").put("body", """
                listeners:
                  - name: $name
                    type: mixed
                    listen: ${row["address"]}
                    port: $port
                    udp: false
                    users: []
            """.trimIndent() + "\n")
        val composition = JSONArray().put(id).put(1).put(JSONArray().put("$id-lan").put(1).put("prepend")).toString()
        val record = JSONObject(CoreInput(id, 1, "rule", body().toByteArray(), "{}".toByteArray(),
            overrides = JSONArray().put(plugin).toString().toByteArray(), composition = composition, name = id)
            .snapshotBytes().toString(Charsets.UTF_8)).put("vpnIntent", true).put("lanIntent", true)
        val observers = mutableListOf<CoreIpcTestDriver>()
        var failure: Throwable? = null
        try {
            val identity = publish(record)
            val at = SystemClock.elapsedRealtime()
            val prepared = drainTerminal(submit(Contract.CORE_OPERATION_PREPARE, identity, mapOf("purpose" to Contract.CORE_PURPOSE_RUNNING,
                "vpnIntent" to true, "lanIntent" to true, "explicitStart" to true, "admittedAt" to at,
                "deadline" to at + Contract.OPERATION_ORDINARY_TIMEOUT_MS, "lanInterfaces" to listOf(mapOf(
                    "listenerName" to name, "interfaceName" to row["interfaceName"], "interfaceIndex" to row["interfaceIndex"], "address" to row["address"])))))
            assertTrue(prepared.toString(), prepared.getBoolean("complete"))
            platform.await("VPN and LAN are actually ready") { client.status()["phase"] == Contract.CORE_PHASE_READY &&
                client.status()["vpnRunning"] == true && client.status()["lanRunning"] == true && !AppBridge.logic.busy }
            val status = platform.status()
            val observer = CoreIpcTestDriver.fixture().also(observers::add)
            assertEquals(status["processId"], observer.processId)
            assertEquals(true, status["vpnIntent"])
            assertEquals(true, status["lanIntent"])
            test(Running(status, platform.runRecord(status), observer, address, port, name), observers)
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            fun cleanup(action: () -> Unit) {
                try { action() } catch (error: Throwable) {
                    if (failure == null) failure = error else if (failure !== error) failure!!.addSuppressed(error)
                }
            }
            cleanup {
                if (main { AppBridge.operationId != null }) {
                    assertEquals(SystemControls.Admission.ACCEPTED, platform.stopFromSystemControl())
                } else if (client.status()["phase"] !in setOf(Contract.CORE_PHASE_DISCONNECTED, Contract.CORE_PHASE_EXITED)) {
                    platform.exit()
                }
                awaitStopped()
            }
            observers.forEach { observer -> cleanup { observer.close() } }
            cleanup { assertStores(stores) }
            failure?.let { throw it }
        }
    }

    private fun revoke(running: Running) {
        val callback = running.observer.debug.serviceControl(Fixture.REVOKE_SERVICE_OFF_MAIN)
        assertEquals(running.observer.processId, callback.getString("processId"))
        assertEquals(running.observer.pid, callback.getInt("pid"))
        assertTrue(callback.getBoolean("callbackOffMain"))
        assertTrue(callback.getBoolean("callbackReturned"))
        assertTrue(callback.getBoolean("originalDescriptorClosed"))
        assertTrue(callback.getBoolean("descriptorWithdrawn"))
    }

    private fun awaitWaiting(running: Running): String {
        platform.await("Revoke waits for the actual request FD to drain", 10_000) {
            AppBridge.command?.get("action") == "systemRevoked" && AppBridge.command?.get("revocationState") == "waiting"
        }
        return main {
            assertEquals(running.status["processId"], AppBridge.command?.get("processId"))
            assertEquals(running.status["inputId"], AppBridge.command?.get("inputId"))
            assertEquals(running.status["purpose"], AppBridge.command?.get("purpose"))
            assertTrue(client.requestBusy)
            assertEquals(false, client.status()["vpnRunning"])
            checkNotNull(AppBridge.operationId)
        }
    }

    private fun saveRevokeDiagnostics(stage: String, failure: Throwable) {
        try {
            val snapshot = main {
                val operations = AppBridge.operations
                mapOf(
                    "stage" to stage,
                    "snapshot" to AppBridge.runtimeState(),
                    "operationId" to AppBridge.operationId,
                    "command" to AppBridge.command,
                    "operation" to operations.operation?.toMap(),
                    "operationAdmittedAt" to AppBridge.operationAdmittedAt,
                    "operationDeadline" to AppBridge.operationDeadline,
                    "operationRemainingMs" to AppBridge.operationId?.let(AppBridge::operationRemainingMs),
                    "resultId" to operations.resultId,
                    "resultSuccess" to operations.resultSuccess,
                    "resultMessage" to operations.resultMessage?.toMap(),
                    "logicBusy" to AppBridge.logic.busy,
                    "executorBusy" to operations.executorBusy,
                    "coreStatus" to client.status(),
                    "coreRequestBusy" to client.requestBusy,
                    "coreResourceBusy" to client.resourceBusy,
                )
            }
            val json = JSONObject(snapshot).put("failure", failure.stackTraceToString()).toString()
            val file = File(AppFiles.work(context), "revoke-diagnostic-${UUID.randomUUID()}.json")
            check(file.createNewFile()) { "Cannot create the revoke diagnostic file" }
            CorePrivateFiles.write(file, json.toByteArray(Charsets.UTF_8))
            failure.addSuppressed(IllegalStateException("Revoke diagnostics ${file.absolutePath}\n$json"))
            android.util.Log.e("RevokeDiagnostics", "${file.absolutePath}\n$json")
        } catch (error: Throwable) {
            if (error !== failure) failure.addSuppressed(error)
        }
    }

    private fun publish(record: JSONObject): Map<String, Any?> {
        val inputId = UUID.randomUUID().toString()
        record.put("inputId", inputId)
        val stage = File(AppFiles.work(context), "run-input-revoke-${UUID.randomUUID()}.json")
        check(stage.parentFile!!.isDirectory || stage.parentFile!!.mkdirs())
        check(stage.createNewFile())
        try {
            CorePrivateFiles.write(stage, record.toString().toByteArray())
            val publication = platform.channel(Contract.CORE_CHANNEL_PUBLISH_RUN_INPUT,
                mapOf("path" to stage.path, "inputId" to inputId)) as Map<*, *>
            assertEquals(true, publication["saved"])
            assertEquals(true, publication["durable"])
            return platform.handshake() + mapOf("generation" to 1L, "inputId" to inputId)
        } finally { assertTrue(stage.delete()) }
    }

    private fun submit(operation: Int, identity: Map<String, Any?>, arguments: Map<String, Any?> = emptyMap()): Map<*, *> =
        (platform.channel(Contract.CORE_CHANNEL_SUBMIT, mapOf("operation" to operation, "identity" to identity,
            "inputId" to identity["inputId"], "arguments" to arguments)) as Map<*, *>).also {
            assertEquals(true, it["accepted"])
            assertTrue((it["requestId"] as Number).toLong() > 0L)
        }

    private fun drainTerminal(admission: Map<*, *>): JSONObject {
        var dataBytes = 0L
        while (true) {
            val frame = platform.channel(Contract.CORE_CHANNEL_READ, mapOf("processId" to admission["processId"],
                "requestId" to admission["requestId"])) as Map<*, *>
            val bytes = frame["payload"] as ByteArray
            when ((frame["kind"] as Number).toInt()) {
                Contract.CORE_IPC_FRAME_DATA -> {
                    dataBytes += bytes.size
                    check(dataBytes <= Contract.CORE_IPC_QUEUE_BYTES)
                }
                Contract.CORE_IPC_FRAME_TERMINAL -> {
                    assertEquals(true, (frame["nativeReceipt"] as Map<*, *>)["exited"])
                    return JSONObject(CoreFrames.utf8(bytes))
                }
                else -> error("Unexpected frame kind in this call: ${frame["kind"]}")
            }
        }
    }

    private fun dispatchRuntimeEvent(status: Map<String, Any?>, replyFailure: android.os.RemoteException? = null): Boolean {
        val connected = java.util.concurrent.CompletableFuture<IBinder>()
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) { connected.complete(binder) }
            override fun onServiceDisconnected(name: ComponentName) = Unit
        }
        assertTrue(main { context.bindService(Intent(context, AppRuntimeService::class.java), connection, Context.BIND_AUTO_CREATE) })
        try {
            val remote = IRuntimeService.Stub.asInterface(connected.get(10, java.util.concurrent.TimeUnit.SECONDS))
            val event = Bundle().apply {
                status.forEach { (key, value) -> when (value) {
                    is String -> putString(key, value)
                    is Long -> putLong(key, value)
                    is Int -> putInt(key, value)
                    is Boolean -> putBoolean(key, value)
                    null -> putString(key, null)
                    else -> Unit
                } }
                putInt("protocol", Contract.CORE_IPC_VERSION)
                putString("event", "revoked")
            }
            val result = java.util.concurrent.CompletableFuture<Boolean>()
            remote.dispatch(event, object : IRuntimeCallback.Stub() {
                override fun onResult(reply: Bundle) {
                    result.complete(reply.getBoolean("accepted"))
                    replyFailure?.let { throw it }
                }
            })
            return result.get(10, java.util.concurrent.TimeUnit.SECONDS)
        } finally { main { context.unbindService(connection) } }
    }

    private fun requireIdle() {
        platform.await("Existing writer exits") { AppBridge.operationId == null && !AppBridge.logic.busy &&
            !AppBridge.pendingSystemRestore && AppBridge.runtimeState()["writerBusy"] == false }
        main {
            assertEquals("STOPPED", AppBridge.runtimeState()["phase"])
            assertFalse(CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java))
            assertNull("Test requires an existing VPN grant", VpnService.prepare(context))
            assertNotEquals(true, PseudoVpnService.alwaysOnState())
        }
        CoreIpcTestDriver.assertNoGoInApplication()
    }

    private fun awaitStopped() = platform.await("Actual core/FD and Dart writer exit", 120_000) {
        client.status()["phase"] in setOf(Contract.CORE_PHASE_DISCONNECTED, Contract.CORE_PHASE_EXITED) && !client.requestBusy &&
            AppBridge.operationId == null && !AppBridge.logic.busy && AppBridge.runtimeState()["writerBusy"] == false
    }

    private fun runRecords(): Map<String, String> = AppFiles.work(context).listFiles().orEmpty()
        .filter { it.name.startsWith("run-record-") }.associate { it.name to MessageDigest.getInstance("SHA-256")
            .digest(it.readBytes()).joinToString("") { byte -> "%02x".format(byte) } }

    private fun businessFiles(): Map<String, ByteArray?> = listOf("configurations.json", "overrides.json", "preferences.json")
        .associateWith { AppFiles.configs(context).resolve(it).takeIf(File::exists)?.readBytes() }

    private fun assertStores(expected: Map<String, ByteArray?>) {
        for ((name, bytes) in expected) assertArrayEquals("Revoke must not rewrite $name", bytes,
            AppFiles.configs(context).resolve(name).takeIf(File::exists)?.readBytes())
    }

    private fun <T> main(block: () -> T): T = CoreIpcTestDriver.onMain(block)

    private fun body() = """
        mode: rule
        find-process-mode: off
        geo-auto-update: false
        ipv6: false
        dns: {enable: true, enhanced-mode: normal, nameserver: ['1.1.1.1']}
        sniffer: {enable: false}
        ntp: {enable: false}
        profile: {store-selected: false, store-fake-ip: false}
        tun:
          enable: true
          inet4-address: [192.0.2.1/30]
          auto-route: false
          route-address: [192.0.2.0/30]
          dns-hijack: ['192.0.2.2:53']
        rules: ['MATCH,REJECT']
    """.trimIndent() + "\n"
}
