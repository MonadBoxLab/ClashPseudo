package io.github.monadboxlab.clashpseudo.nativecore

import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.work.WorkManager
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class CoreClientDrainTest {
    @Before fun awaitStartup() {
        val driver = CorePlatformTestDriver()
        val work = WorkManager.getInstance(driver.context)
        driver.await("启动任务结束") {
            work.getWorkInfosForUniqueWork("update-reconcile").get(5, TimeUnit.SECONDS)
                .let { it.isNotEmpty() && it.all { item -> item.state.isFinished } } &&
                AppBridge.operationId == null && !AppBridge.logic.busy
        }
        CoreIpcTestDriver.assertNoGoInApplication()
    }

    @Test fun exitWaitsForReceiptAndLocalIoAfterNativeInvocationEnds() {
        CoreClientTestCall().use { call ->
            val replies = AtomicInteger()
            val exit = CompletableFuture<Throwable?>()
            val admitted = SystemClock.elapsedRealtime()
            call.client.exit(call.processId, admitted, admitted + 30_000, "stop") {
                replies.incrementAndGet()
                exit.complete(it)
            }
            call.barrier()
            for (flag in listOf("nativeExited", "ioExited", "writeExited")) {
                call.exited(flag)
                assertTrue(call.retained())
                assertTrue(call.client.resourceBusy)
                assertFalse(exit.isDone)
            }
            call.exited("receiptExited")
            assertNull(exit.get(10, TimeUnit.SECONDS))
            assertFalse(call.retained())
            assertFalse(call.client.resourceBusy)
            CoreIpcTestDriver.onMain {}
            assertEquals(1, replies.get())
        }
    }

    @Test fun deadlineReportsUnfinishedWriteWithoutReleasingItsGateOrReplyingAgain() {
        CoreClientTestCall().use { call ->
            val replies = AtomicInteger()
            val exit = CompletableFuture<Throwable?>()
            val admitted = SystemClock.elapsedRealtime()
            call.client.exit(call.processId, admitted, admitted, "stop") {
                replies.incrementAndGet()
                exit.complete(it)
            }
            call.barrier()
            for (flag in listOf("nativeExited", "receiptExited", "ioExited")) call.exited(flag)
            val error = exit.get(Contract.OPERATION_UI_GRACE_MS + 5000, TimeUnit.MILLISECONDS)
            assertNotNull(error)
            assertEquals("退出请求的原受理期限已到，core process 或本地 FD I/O 尚未结束", error!!.message)
            assertTrue(call.retained())
            assertTrue(call.client.resourceBusy)
            call.exited("writeExited")
            assertFalse(call.retained())
            assertFalse(call.client.resourceBusy)
            CoreIpcTestDriver.onMain {}
            assertEquals(1, replies.get())
        }
    }

    @Test fun oldProcessDrainCannotCompleteAnotherProcessDocumentWaiter() {
        CoreClientTestCall().use { call ->
            val otherProcess = "${call.processId}-other"
            val descriptors = ParcelFileDescriptor.createPipe()
            @Suppress("UNCHECKED_CAST")
            val documents = CoreClient::class.java.getDeclaredField("documentReads").apply { isAccessible = true }
                .get(call.client) as MutableMap<ParcelFileDescriptor, String>
            val first = CompletableFuture<Throwable?>()
            val second = CompletableFuture<Throwable?>()
            val secondReplies = AtomicInteger()
            val secondReply: (Throwable?) -> Unit = {
                secondReplies.incrementAndGet()
                second.complete(it)
            }
            try {
                call.onState {
                    documents[descriptors[0]] = otherProcess
                    CoreClient::class.java.getDeclaredMethod("awaitExitDeadline", String::class.java,
                        Long::class.javaPrimitiveType, kotlin.Function1::class.java).apply { isAccessible = true }
                        .invoke(call.client, otherProcess, SystemClock.elapsedRealtime() + 30_000, secondReply)
                }
                val admitted = SystemClock.elapsedRealtime()
                call.client.exit(call.processId, admitted, admitted + 30_000, "stop") { first.complete(it) }
                call.barrier()
                for (flag in listOf("nativeExited", "receiptExited", "ioExited", "writeExited")) call.exited(flag)
                assertNull(first.get(10, TimeUnit.SECONDS))
                CoreIpcTestDriver.onMain {}
                assertFalse("旧 process 的 drain 不能完成另一 process 的退出", second.isDone)
                call.onState {
                    documents.remove(descriptors[0])
                    CoreClient::class.java.getDeclaredMethod("completeExitWhenDrained", String::class.java)
                        .apply { isAccessible = true }.invoke(call.client, otherProcess)
                }
                assertNull(second.get(10, TimeUnit.SECONDS))
                assertEquals(1, secondReplies.get())
            } finally {
                call.onState {
                    documents.remove(descriptors[0])
                    CoreClient::class.java.getDeclaredMethod("completeExitWhenDrained", String::class.java)
                        .apply { isAccessible = true }.invoke(call.client, otherProcess)
                }
                descriptors.forEach { it.close() }
            }
        }
    }

    @Test fun handshakeCannotCreateReplacementWhileOldReceiptOrDocumentIoRemains() {
        CoreClientTestCall().use { call ->
            for (flag in listOf("nativeExited", "ioExited", "writeExited")) call.exited(flag)
            val reply = CompletableFuture<Throwable?>()
            call.client.handshake { value, error ->
                assertNull(value)
                reply.complete(error)
            }
            assertEquals("旧 core process 的本地 FD I/O 尚未结束", reply.get(10, TimeUnit.SECONDS)!!.message)
            assertTrue(call.retained())
            assertTrue(call.client.resourceBusy)
            call.exited("receiptExited")
            assertFalse(call.retained())
            assertFalse(call.client.resourceBusy)
        }
    }
}
