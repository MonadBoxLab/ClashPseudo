package io.github.monadboxlab.clashpseudo.nativecore

import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class CoreDocumentTransportTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun completeDocumentKeepsItsWriterUntilEveryFrameHasBeenRead() {
        val started = CountDownLatch(1)
        val failures = ConcurrentLinkedQueue<Throwable>()
        val io = Executors.newSingleThreadExecutor { task -> Thread({
            started.countDown()
            task.run()
        }, "document-transport-test").apply { uncaughtExceptionHandler = Thread.UncaughtExceptionHandler { _, error -> failures.add(error) } } }
        val transport = CoreNativeTransport(context, io)
        val bytes = ByteArray(9 * 1024 * 1024 + 173) { (it % 251).toByte() }
        try {
            transport.document(bytes).use { descriptor ->
                assertTrue(descriptor.canDetectErrors())
                assertTrue(started.await(10, TimeUnit.SECONDS))
                assertFalse("尚未读取的实际 pipe 仍持有 writer", transport.idle)
                assertFalse(transport.sealIfIdle())
                ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
                    assertArrayEquals(bytes, CoreDocuments.read(input))
                    assertEquals(-1, input.read())
                }
            }
            transport.awaitIdle(SystemClock.elapsedRealtime() + 10_000)
            assertTrue(transport.idle)
            assertTrue(failures.toString(), failures.isEmpty())
            assertTrue(transport.sealIfIdle())
            assertThrows(IllegalStateException::class.java) { transport.document(byteArrayOf(1)) }
            assertTrue(transport.idle)
        } finally {
            io.shutdownNow()
            assertTrue(io.awaitTermination(10, TimeUnit.SECONDS))
        }
    }

    @Test fun anAbandonedReaderDoesNotCrashTheWriterOrRetainItsAdmission() {
        val blocked = CountDownLatch(1)
        val release = CountDownLatch(1)
        val failures = ConcurrentLinkedQueue<Throwable>()
        val io = Executors.newSingleThreadExecutor { task -> Thread(task, "abandoned-document-test").apply {
            uncaughtExceptionHandler = Thread.UncaughtExceptionHandler { _, error -> failures.add(error) }
        } }
        val transport = CoreNativeTransport(context, io)
        io.execute { blocked.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
        try {
            assertTrue(blocked.await(10, TimeUnit.SECONDS))
            transport.document(ByteArray(1024 * 1024) { 97 }).close()
            assertFalse(transport.idle)
            assertFalse(transport.sealIfIdle())
            release.countDown()
            io.submit {}.get(10, TimeUnit.SECONDS)
            transport.awaitIdle(SystemClock.elapsedRealtime() + 10_000)
            assertTrue(transport.idle)
            assertTrue("EPIPE 必须由 document writer 记录并结束，不能逃到线程的 uncaught handler：$failures", failures.isEmpty())
            val receipt = "{\"exited\":true,\"unknown\":\"完整回执\"}".toByteArray(Charsets.UTF_8)
            transport.document(receipt).use { descriptor ->
                ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
                    assertArrayEquals(receipt, CoreDocuments.read(input))
                    assertEquals(-1, input.read())
                }
            }
            transport.awaitIdle(SystemClock.elapsedRealtime() + 10_000)
            assertTrue(transport.sealIfIdle())
        } finally {
            release.countDown()
            io.shutdownNow()
            assertTrue(io.awaitTermination(10, TimeUnit.SECONDS))
        }
    }

    @Test fun rejectedDocumentWriterClosesItsPipeAndReleasesAdmission() {
        val io = Executors.newSingleThreadExecutor()
        val transport = CoreNativeTransport(context, io)
        io.shutdown()
        assertTrue(io.awaitTermination(10, TimeUnit.SECONDS))
        assertThrows(RejectedExecutionException::class.java) { transport.document(byteArrayOf(1)) }
        assertTrue(transport.idle)
        assertTrue(transport.sealIfIdle())
    }
}
