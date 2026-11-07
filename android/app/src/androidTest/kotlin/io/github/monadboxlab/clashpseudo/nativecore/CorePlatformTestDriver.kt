package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context
import android.os.Handler
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.controls.SystemControls
import io.github.monadboxlab.clashpseudo.nativecore.input.CoreInput
import io.github.monadboxlab.clashpseudo.storage.AppFiles
import org.json.JSONObject
import org.junit.Assert.*
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/** Reuse the production CoreClient channel, immutable run record, and SystemControls. */
class CorePlatformTestDriver(val context: Context = InstrumentationRegistry.getInstrumentation().targetContext) {
    class ChannelFailure(val code: String, message: String?, val details: Any?) : IOException(message)
    private val client get() = CoreClient.get(context)

    /** Hold a visible preview reference before prepare; restore the original state after the test. */
    fun keepPreviewVisible(): Closeable {
        val owner = client
        fun field(name: String) = CoreClient::class.java.getDeclaredField(name).apply { isAccessible = true }
        val state = field("state").get(owner) as Handler
        val visible = field("visible")
        val hiddenAt = field("hiddenAt")
        val idle = field("previewIdle").get(owner) as Runnable
        fun <T> onState(action: () -> T): T {
            val task = FutureTask(action)
            check(state.post(task))
            return task.get(10, TimeUnit.SECONDS)
        }
        val previous = onState {
            val saved = visible.getBoolean(owner) to hiddenAt.getLong(owner)
            visible.setBoolean(owner, true)
            state.removeCallbacks(idle)
            saved
        }
        return Closeable {
            onState {
                visible.setBoolean(owner, previous.first)
                hiddenAt.setLong(owner, previous.second)
                state.removeCallbacks(idle)
                if (owner.status()["phase"] == Contract.CORE_PHASE_READY) {
                    CoreClient::class.java.getDeclaredMethod("schedulePreviewIdle").apply { isAccessible = true }.invoke(owner)
                }
            }
        }
    }

    fun channel(method: String, arguments: Any? = null): Any? {
        val reply = CompletableFuture<Any?>()
        CoreIpcTestDriver.onMain {
            client.handle(MethodCall(method, arguments), object : MethodChannel.Result {
                override fun success(value: Any?) { check(reply.complete(value)) }
                override fun error(code: String, message: String?, details: Any?) {
                    check(reply.completeExceptionally(ChannelFailure(code, message, details)))
                }
                override fun notImplemented() { reply.completeExceptionally(AssertionError("Production channel does not implement $method")) }
            })
        }
        return try { reply.get(130, TimeUnit.SECONDS) }
        catch (error: java.util.concurrent.ExecutionException) { throw error.cause ?: error }
    }

    @Suppress("UNCHECKED_CAST")
    fun status(): Map<String, Any?> = channel(Contract.CORE_CHANNEL_STATUS) as Map<String, Any?>
    @Suppress("UNCHECKED_CAST")
    fun handshake(): Map<String, Any?> = channel(Contract.CORE_CHANNEL_HANDSHAKE) as Map<String, Any?>

    fun prepare(input: CoreInput, vpn: Boolean = true, owner: String? = null,
                admittedAt: Long? = null,
                purpose: String = if (vpn) Contract.CORE_PURPOSE_RUNNING else Contract.CORE_PURPOSE_PREVIEW): CoreIpcTestDriver.Reply {
        val inputId = UUID.randomUUID().toString()
        val stage = File(AppFiles.work(context), "run-input-test-${UUID.randomUUID()}")
        check(stage.parentFile!!.isDirectory || stage.parentFile!!.mkdirs())
        check(stage.createNewFile())
        CorePrivateFiles.write(stage, JSONObject(CoreFrames.utf8(input.snapshotBytes())).put("inputId", inputId)
            .put("vpnIntent", vpn).put("lanIntent", false).toString().toByteArray(Charsets.UTF_8))
        try {
            val publication = channel(Contract.CORE_CHANNEL_PUBLISH_RUN_INPUT, mapOf("path" to stage.path, "inputId" to inputId)) as Map<*, *>
            assertEquals(true, publication["saved"])
            assertEquals(true, publication["durable"])
            val identity = handshake() + mapOf("generation" to 1L, "inputId" to inputId)
            val at = admittedAt ?: SystemClock.elapsedRealtime()
            return submit(Contract.CORE_OPERATION_PREPARE, identity, mapOf("purpose" to purpose,
                "vpnIntent" to vpn, "lanIntent" to false, "explicitStart" to true, "admittedAt" to at,
                "deadline" to at + Contract.OPERATION_ORDINARY_TIMEOUT_MS), inputId, owner)
        } finally { assertTrue("Failed to delete this run's input staging file", stage.delete()) }
    }

    fun query(operation: Int, arguments: Map<String, Any?> = emptyMap()): CoreIpcTestDriver.Reply = submit(operation, status(), arguments)

    private fun submit(operation: Int, identity: Map<String, Any?>, arguments: Map<String, Any?>,
                       inputId: String? = null, owner: String? = null): CoreIpcTestDriver.Reply {
        val admission = channel(Contract.CORE_CHANNEL_SUBMIT, mapOf("operation" to operation, "identity" to identity,
            "inputId" to (inputId ?: identity["inputId"]), "arguments" to arguments, "owner" to owner)) as Map<*, *>
        assertEquals(true, admission["accepted"])
        val id = (admission["requestId"] as Number).toLong()
        assertTrue(id > 0)
        val data = ByteArrayOutputStream()
        val records = mutableListOf<JSONObject>()
        val metadata = mutableListOf<JSONObject>()
        var size = 0L
        while (true) {
            val frame = channel(Contract.CORE_CHANNEL_READ, mapOf("processId" to admission["processId"], "requestId" to id)) as Map<*, *>
            val bytes = frame["payload"] as ByteArray
            size += bytes.size
            check(size <= Contract.CORE_IPC_QUEUE_BYTES)
            when ((frame["kind"] as Number).toInt()) {
                Contract.CORE_IPC_FRAME_DATA -> data.write(bytes)
                Contract.CORE_IPC_FRAME_RECORD -> records.add(JSONObject(CoreFrames.utf8(bytes)))
                Contract.CORE_IPC_FRAME_METADATA -> metadata.add(JSONObject(CoreFrames.utf8(bytes)))
                Contract.CORE_IPC_FRAME_TERMINAL -> {
                    val terminal = JSONObject(CoreFrames.utf8(bytes))
                    val receipt = frame["nativeReceipt"] as? Map<*, *>
                    assertEquals("coreRead must wait for the actual onExited", true, receipt?.get("exited"))
                    terminal.put("nativeReceipt", JSONObject(checkNotNull(receipt)))
                    return CoreIpcTestDriver.Reply(if (data.size() == 0) JSONObject() else JSONObject(CoreFrames.utf8(data.toByteArray())),
                        terminal, records, metadata)
                }
                else -> error("Unknown frame kind: ${frame["kind"]}")
            }
        }
    }

    fun runRecord(expected: Map<String, Any?> = status()): JSONObject {
        val inputId = checkNotNull(expected["inputId"] as? String)
        val reply = channel(Contract.CORE_CHANNEL_READ_RUN_INPUT_RECORD, mapOf("inputId" to inputId)) as Map<*, *>
        assertEquals(true, reply["saved"])
        assertEquals(true, reply["durable"])
        assertEquals(inputId, reply["inputId"])
        val file = File(reply["path"] as String)
        assertEquals(AppFiles.runRecord(context, inputId).canonicalFile, file.canonicalFile)
        val bytes = checkNotNull(CorePrivateFiles.read(file, AppFiles.MAX_RUN_RECORD_BYTES))
        val result = JSONObject(CoreFrames.utf8(bytes))
        assertEquals(expected["configId"], result.getString("id"))
        assertEquals((expected["revision"] as Number).toInt(), result.getInt("revision"))
        return result
    }

    fun exit(reason: String = "stop") {
        val state = status()
        val at = SystemClock.elapsedRealtime()
        val reply = channel(Contract.CORE_CHANNEL_EXIT, mapOf("processId" to state["processId"], "admittedAt" to at,
            "deadline" to at + Contract.OPERATION_ORDINARY_TIMEOUT_MS, "reason" to reason)) as Map<*, *>
        assertEquals(true, reply["exited"])
        CoreIpcTestDriver.assertNoGoInApplication()
    }

    fun stopFromSystemControl(): SystemControls.Admission {
        val reply = CompletableFuture<SystemControls.Admission>()
        CoreIpcTestDriver.onMain { SystemControls.request(context, "stop") { reply.complete(it) } }
        return reply.get(15, TimeUnit.SECONDS)
    }

    fun await(label: String, timeoutMs: Long = 60_000, ready: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (!CoreIpcTestDriver.onMain(ready)) {
            check(SystemClock.elapsedRealtime() < deadline) { "Timed out waiting for $label" }
            Thread.sleep(25)
        }
    }
}
