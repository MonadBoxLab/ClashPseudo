package io.github.monadboxlab.clashpseudo.nativecore

import android.os.Handler
import android.os.ParcelFileDescriptor
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import java.io.Closeable
import java.util.UUID
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import org.junit.Assert.*

/** Control the actual Call's four exit conditions; the test holds FDs independently. */
internal class CoreClientTestCall(private val operation: Int = Contract.CORE_OPERATION_RESOURCE_UPDATE) : Closeable {
    val client = CoreClient.installed()
    val processId = "test-${UUID.randomUUID()}"
    private val key = processId to 1L
    private val input = ParcelFileDescriptor.createPipe()
    private val output = ParcelFileDescriptor.createPipe()
    private val callClass = CoreClient::class.java.declaredClasses.single { it.simpleName == "Call" }
    private val call = callClass.declaredConstructors.single().apply { isAccessible = true }
        .newInstance(processId, 1L, operation, "test-input", "test-composition", 1L, 1L, input[1], output[0], "resource-owner")
    @Suppress("UNCHECKED_CAST")
    private val calls = CoreClient::class.java.getDeclaredField("calls").apply { isAccessible = true }
        .get(client) as MutableMap<Pair<String, Long>, Any>
    private val state = CoreClient::class.java.getDeclaredField("state").apply { isAccessible = true }.get(client) as Handler
    private val status = CoreClient::class.java.getDeclaredField("statusValue").apply { isAccessible = true }
    private val previousStatus = status.get(client)

    init {
        onState {
            assertTrue("No unfinished calls may remain before the test starts", calls.isEmpty())
            assertNull(CoreClient::class.java.getDeclaredField("connection").apply { isAccessible = true }.get(client))
            assertNull(calls.put(key, call))
            @Suppress("UNCHECKED_CAST")
            status.set(client, (previousStatus as Map<String, Any?>) + (Contract.CORE_FIELD_PROCESS_ID to processId))
        }
        CoreIpcTestDriver.assertNoGoInApplication()
    }

    fun exited(name: String) = onState {
        require(name in setOf("nativeExited", "receiptExited", "ioExited", "writeExited"))
        callClass.getDeclaredField(name).apply { isAccessible = true }.setBoolean(call, true)
        CoreClient::class.java.getDeclaredMethod("retireIfDrained", callClass).apply { isAccessible = true }.invoke(client, call)
    }

    fun barrier() = onState {}
    fun retained(): Boolean = onState { calls[key] === call }

    fun <T> onState(block: () -> T): T {
        val task = FutureTask(block)
        check(state.post(task))
        return task.get(10, TimeUnit.SECONDS)
    }

    override fun close() {
        onState {
            calls.remove(key)
            status.set(client, previousStatus)
            CoreClient::class.java.getDeclaredMethod("completeExitWhenDrained", String::class.java)
                .apply { isAccessible = true }.invoke(client, processId)
        }
        (input + output).forEach { it.close() }
        CoreIpcTestDriver.assertNoGoInApplication()
    }
}
