package io.github.monadboxlab.clashpseudo.bridge.core

import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.bridge.BridgeTestState
import io.github.monadboxlab.clashpseudo.logic.LogicEngineHost
import io.github.monadboxlab.clashpseudo.nativecore.CoreClient
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CorePlatformTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CoreResourceGate
import io.github.monadboxlab.clashpseudo.nativecore.input.CoreInput
import io.github.monadboxlab.clashpseudo.storage.AppFiles
import java.io.Closeable
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class CoreAdmissionMigrationTest {
    @Test fun cancelledQueuedCloseNeverEntersNativeAndTheSameContextCanRetry() {
        CoreBridgeIpcScenario(running = true).use { core ->
            val arguments = JSONObject().put("id", "00000001-0000-4000-8000-000000000000")
            cancelBeforeInputCompletes(core, Contract.CORE_OPERATION_CONNECTION_CLOSE, arguments)
            assertEquals("absent", CoreBridgeIpcScenario.success(core.query(Contract.CORE_OPERATION_CONNECTION_CLOSE, arguments)).getString("status"))
            core.assertSameContext()
        }
        queuedDeadlineThroughTheActualRuntimeChannel()
    }

    @Test fun cancelledQueuedResourceNeverEntersNativeAndDiagnosticsRemainAvailable() {
        CoreBridgeIpcScenario().use { core ->
            cancelBeforeInputCompletes(core, Contract.CORE_OPERATION_RESOURCE_UPDATE,
                JSONObject().put("kind", "geo").put("name", "GeoIP"))
            val retry = core.query(Contract.CORE_OPERATION_RESOURCE_UPDATE,
                JSONObject().put("kind", "geo").put("name", "missing"))
            assertEquals("invalid resource", CoreBridgeIpcScenario.failure(retry).getString("message"))
            core.assertSameContext()
        }
    }

    /** The original 100ms budget keeps running; delay only delivery of the actual checkOperation Reply. */
    private fun queuedDeadlineThroughTheActualRuntimeChannel() {
        val platform = CorePlatformTestDriver()
        val client = CoreClient.get(platform.context)
        platform.await("Original application writer is idle") { AppBridge.operationId == null && !AppBridge.logic.busy }
        CoreIpcTestDriver.production().use { observer ->
            var failure: Throwable? = null
            var gate: RuntimeReplyGate? = null
            var restoreOwner: Closeable? = null
            try {
                val input = CoreInput("migration-channel-close", 1, "rule", (
                    "mode: rule\nfind-process-mode: off\ngeo-auto-update: false\n" +
                        "geox-url: {geoip: '', geosite: '', mmdb: '', asn: ''}\n" +
                        "rules:\n  - MATCH,DIRECT\n"
                    ).toByteArray(Charsets.UTF_8), "{}".toByteArray(), name = "migration-channel-close")
                val prepared = platform.prepare(input, vpn = false, purpose = Contract.CORE_PURPOSE_RUNNING)
                assertTrue(prepared.terminal.toString(), prepared.terminal.getBoolean("complete"))
                val captured = platform.status()
                assertEquals(observer.processId, captured["processId"])
                assertEquals(Contract.CORE_PURPOSE_RUNNING, captured["purpose"])
                assertEquals(false, captured["vpnRunning"])
                val source = captured + mapOf("connectionId" to "00000001-0000-4000-8000-000000000000")
                val record = AppFiles.runRecord(platform.context, captured["inputId"] as String).readBytes()
                runtimeRead("runtimeConfig", source).value.get(10, TimeUnit.SECONDS)
                val owner = "migration-channel-close-owner"
                val channelGate = CoreIpcTestDriver.onMain { RuntimeReplyGate(AppBridge.logic, owner) }
                gate = channelGate
                val admittedAt = SystemClock.elapsedRealtime()
                restoreOwner = CoreIpcTestDriver.onMain {
                    val names = listOf("operationId", "operationAdmittedAt", "operationDeadline", "command")
                    val fields = names.associateWith(BridgeTestState::field)
                    val saved = fields.mapValues { it.value.get(AppBridge) }
                    assertNull(AppBridge.operationId)
                    val state = AppBridge.runtimeState()
                    assertEquals(true, state["storageReady"])
                    assertEquals(false, state["storageRestoring"])
                    fields.getValue("operationId").set(AppBridge, owner)
                    fields.getValue("operationAdmittedAt").set(AppBridge, admittedAt)
                    fields.getValue("operationDeadline").set(AppBridge, admittedAt + 100L)
                    fields.getValue("command").set(AppBridge, mapOf("action" to "closeConnection", "storageEpoch" to state["storageEpoch"]))
                    Closeable { CoreIpcTestDriver.onMain { fields.forEach { (name, field) -> field.set(AppBridge, saved[name]) } } }
                }
                val first = runtimeRead("closeConnection", source + mapOf("owner" to owner,
                    "admittedAt" to admittedAt, "deadline" to admittedAt + 100L))
                channelGate.held.get(2, TimeUnit.SECONDS)
                assertEquals(0, channelGate.closeSubmissions.get())
                assertNull(CoreResourceGate.forApplication(platform.context).tryAcquire())
                val expired = try { first.value.get(2, TimeUnit.SECONDS); null }
                    catch (error: java.util.concurrent.ExecutionException) { error.cause }
                assertTrue(expired.toString(), expired is CorePlatformTestDriver.ChannelFailure)
                assertEquals("expired", (expired as CorePlatformTestDriver.ChannelFailure).code)
                assertEquals(1, first.replies.get())
                assertFalse("The original work must still hold the undelivered actual Reply", channelGate.delivered)
                val pending = JSONObject(runtimeRead("closeConnection", source).value.get(10, TimeUnit.SECONDS) as String)
                assertTrue(pending.toString(), pending.getBoolean("readPending"))
                assertEquals(0, channelGate.closeSubmissions.get())
                assertEquals(captured["processId"], pending.getString("processId"))
                assertEquals(captured["inputId"], pending.getString("inputId"))
                CoreIpcTestDriver.onMain { channelGate.release() }
                val end = SystemClock.elapsedRealtime() + 10_000L
                var actual: JSONObject
                do {
                    actual = JSONObject(runtimeRead("closeConnection", source).value.get(10, TimeUnit.SECONDS) as String)
                    if (!actual.optBoolean("readPending")) break
                    check(SystemClock.elapsedRealtime() < end) { "Original close work did not release its slot" }
                    Thread.sleep(10)
                } while (true)
                assertEquals("absent", actual.getString("status"))
                assertEquals(1, channelGate.closeSubmissions.get())
                assertEquals(1, first.replies.get())
                assertEquals(captured["processId"], actual.getString("processId"))
                assertEquals(captured["inputId"], actual.getString("inputId"))
                assertFalse(actual.optBoolean("stale"))
                val after = platform.status()
                for (key in listOf("processId", "inputId", "generation", "composition", "networkRevision", "purpose")) {
                    assertEquals(key, captured[key], after[key])
                }
                assertEquals(Contract.CORE_PHASE_READY, after["phase"])
                assertArrayEquals(record, AppFiles.runRecord(platform.context, captured["inputId"] as String).readBytes())
                assertNull(CoreResourceGate.forApplication(platform.context).tryAcquire())
                Log.i("CoreAdmissionMigration", JSONObject().put("selector",
                    "io.github.monadboxlab.clashpseudo.bridge.core.CoreAdmissionMigrationTest#cancelledQueuedCloseNeverEntersNativeAndTheSameContextCanRetry")
                    .put("channelDeadlineMs", 100).put("earlyReply", "expired").put("replies", first.replies.get())
                    .put("retry", "absent").put("closeSubmissions", channelGate.closeSubmissions.get()).toString())
            } catch (error: Throwable) {
                failure = error
                throw error
            } finally {
                fun finish(action: () -> Unit) {
                    try { action() } catch (error: Throwable) {
                        if (failure == null) failure = error else if (failure !== error) failure.addSuppressed(error)
                    }
                }
                finish { CoreIpcTestDriver.onMain { gate?.close() } }
                finish { restoreOwner?.close() }
                finish { platform.exit() }
                finish { observer.awaitDeath() }
                finish { assertFalse(client.requestBusy) }
                finish { CoreIpcTestDriver.assertNoGoInApplication() }
                failure?.let { throw it }
            }
        }
    }

    private class RuntimeReply {
        val value = CompletableFuture<Any?>()
        val replies = AtomicInteger()
    }

    private fun runtimeRead(method: String, arguments: Map<String, Any?>): RuntimeReply = RuntimeReply().also { pending ->
        CoreIpcTestDriver.onMain {
            AppBridge.logic.read(method, arguments, object : MethodChannel.Result {
                override fun success(value: Any?) {
                    check(pending.replies.incrementAndGet() == 1)
                    pending.value.complete(value)
                }
                override fun error(code: String, message: String?, details: Any?) {
                    check(pending.replies.incrementAndGet() == 1)
                    pending.value.completeExceptionally(CorePlatformTestDriver.ChannelFailure(code, message, details))
                }
                override fun notImplemented() {
                    check(pending.replies.incrementAndGet() == 1)
                    pending.value.completeExceptionally(AssertionError("Actual AppRuntime does not implement $method"))
                }
            })
        }
    }

    /** The original handler keeps processing every message; hold only one already-generated actual success Reply. */
    private class RuntimeReplyGate(host: LogicEngineHost, private val owner: String) : Closeable {
        private val engine = LogicEngineHost::class.java.getDeclaredField("engine").apply { isAccessible = true }
            .get(host) as FlutterEngine
        private val messenger = engine.dartExecutor.binaryMessenger
        private val delegate = messenger.javaClass.getDeclaredField("messenger").apply { isAccessible = true }.get(messenger)
        private val handlers = delegate.javaClass.getDeclaredField("messageHandlers").apply { isAccessible = true }.get(delegate) as Map<*, *>
        private val info = checkNotNull(handlers[AppBridge.CHANNEL])
        private val handler = info.javaClass.getDeclaredField("handler").apply { isAccessible = true }.get(info) as BinaryMessenger.BinaryMessageHandler
        private var retained: Pair<BinaryMessenger.BinaryReply, ByteBuffer?>? = null
        private var checks = 0
        val held = CompletableFuture<Unit>()
        val closeSubmissions = AtomicInteger()
        @Volatile var delivered = false
            private set

        init {
            check(info.javaClass.getDeclaredField("taskQueue").apply { isAccessible = true }.get(info) == null)
            messenger.setMessageHandler(AppBridge.CHANNEL) { message, reply ->
                val call = StandardMethodCodec.INSTANCE.decodeMethodCall(checkNotNull(message).duplicate())
                if (call.method == Contract.CORE_CHANNEL_SUBMIT &&
                    call.argument<Number>("operation")?.toInt() == Contract.CORE_OPERATION_CONNECTION_CLOSE) closeSubmissions.incrementAndGet()
                if (call.method == "checkOperation" && call.argument<String>("owner") == owner && ++checks == 2) {
                    handler.onMessage(message) receive@ { response ->
                        val copy = response?.let { original ->
                            ByteBuffer.allocateDirect(original.position()).apply { put(original.duplicate().apply { flip() }) }
                        }
                        try {
                            check(copy != null) { "Actual checkOperation did not return an envelope" }
                            StandardMethodCodec.INSTANCE.decodeEnvelope(copy.duplicate().apply { flip() })
                        } catch (error: Throwable) {
                            delivered = true
                            reply.reply(copy)
                            held.completeExceptionally(error)
                            return@receive
                        }
                        check(retained == null)
                        retained = reply to copy
                        held.complete(Unit)
                    }
                } else handler.onMessage(message, reply)
            }
        }

        fun release() {
            val (reply, response) = retained ?: return
            retained = null
            delivered = true
            reply.reply(response)
        }

        override fun close() {
            try { release() } finally { messenger.setMessageHandler(AppBridge.CHANNEL, handler) }
        }
    }

    private fun cancelBeforeInputCompletes(core: CoreBridgeIpcScenario, operation: Int, arguments: JSONObject) {
        val admitted = CompletableFuture<Long>()
        val release = CountDownLatch(1)
        val submission = CompletableFuture.supplyAsync {
            core.start(operation, arguments) { metadata ->
                admitted.complete(metadata.getLong("requestId"))
                check(release.await(20, TimeUnit.SECONDS)) { "Timed out waiting for the test to release the original input FD" }
            }
        }
        try {
            val id = admitted.get(10, TimeUnit.SECONDS)
            assertFalse(submission.isDone)
            assertFalse(core.driver.receipts[id]?.isDone == true)
            assertNull(CoreResourceGate.forApplication(core.driver.context).tryAcquire())

            // Metadata has not been written to the original pipe; cancellation uses the original Service, token, and native CANCEL.
            CoreBridgeIpcScenario.success(core.driver.cancel(id))
            assertFalse("Cancellation intent must not fake the original call's exit", core.driver.receipts[id]?.isDone == true)
            assertFalse(submission.isDone)
            core.assertSameContext()
            assertNull(CoreResourceGate.forApplication(core.driver.context).tryAcquire())

            release.countDown()
            val pending = submission.get(10, TimeUnit.SECONDS)
            val reply = core.await(pending)
            val error = CoreBridgeIpcScenario.failure(reply)
            assertEquals(Contract.CORE_ERROR_CANCELLED, error.getString("code"))
            assertEquals("Request was cancelled before entering the core", error.getString("message"))
            assertTrue(error.getString("stack").contains("CoreHost"))
            val receipt = core.driver.receipt(id)
            assertTrue(receipt.getBoolean("exited"))
            assertEquals(Contract.CORE_ERROR_CANCELLED, receipt.getJSONObject("error").getString("code"))
            assertEquals(error.getString("message"), receipt.getJSONObject("error").getString("message"))
            assertEquals(0, reply.value.length())
            assertTrue(reply.records.isEmpty())
            core.assertSameContext()
        } finally {
            release.countDown()
            submission.get(25, TimeUnit.SECONDS)
        }
    }
}
