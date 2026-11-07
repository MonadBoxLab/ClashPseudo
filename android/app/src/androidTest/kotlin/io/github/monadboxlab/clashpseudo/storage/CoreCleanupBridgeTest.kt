package io.github.monadboxlab.clashpseudo.storage

import android.os.Handler
import android.os.Looper
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import io.github.monadboxlab.clashpseudo.backup.BackupFixture
import io.github.monadboxlab.clashpseudo.backup.RestoreTransaction
import io.github.monadboxlab.clashpseudo.bridge.operation.OperationState
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.nativecore.CoreClient
import io.github.monadboxlab.clashpseudo.nativecore.CorePrivateFiles
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class CoreCleanupBridgeTest {
    private class Reply : MethodChannel.Result {
        val done = CountDownLatch(1)
        var value: Any? = null
        var code: String? = null
        var details: Any? = null
        var count = 0
        override fun success(result: Any?) { value = result; count++; done.countDown() }
        override fun error(code: String, message: String?, details: Any?) { this.code = code; this.details = details; count++; done.countDown() }
        override fun notImplemented() = error("missing", null, null)
        fun await() { assertTrue("Cleanup callback did not return", done.await(10, TimeUnit.SECONDS)); assertEquals(1, count) }
        fun failed(detail: String) {
            await(); assertEquals("coreCleanup", code)
            assertTrue(details.toString(), AppMessage.fromMap(details)?.detail.orEmpty().contains(detail))
        }
    }

    private class Harness(val fixture: BackupFixture) : AutoCloseable {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val core = File(fixture.root, "mihomo").apply { check(mkdir()) }
        val record = File(fixture.root, "no-backup/core-cleanup.json").apply { check(parentFile!!.mkdir()) }
        var cleanup = CoreDataCleanup(core, record).apply { initialize() }
        val operations = OperationState()
        val worker = fixture.files.ioExecutor as ExecutorService
        val rejection = AtomicReference<Throwable?>()
        val publishing = AtomicReference(false)
        val filesField = BackupFiles::class.java.getDeclaredField("instance").apply { isAccessible = true }
        val cleanupField = CoreDataCleanup::class.java.getDeclaredField("instance").apply { isAccessible = true }
        val oldFiles = filesField.get(null)
        val oldCleanup = cleanupField.get(null)
        val client = CoreClient.get(context)
        val calls = CoreCleanupCalls(context, Handler(Looper.getMainLooper()), operations,
            { owner -> object : RestoreTransaction.Owner {
                override fun checkCurrent() { if (operations.operationId != owner) throw CancellationException("owner 已替换") }
                override fun runIfCurrent(block: () -> Unit) = synchronized(operations.publicationGate) { checkCurrent(); block() }
            } }, { publishing.set(it) }, {}, { false }, { false }, {})
        init {
            assertFalse(client.lifecycle.snapshot().cleanupPending)
            assertTrue(client.status()["phase"] in listOf(null, "disconnected", "exited", "recoveryRequired"))
            filesField.set(null, fixture.files); cleanupField.set(null, cleanup)
            BackupFiles::class.java.getDeclaredField("ioExecutor\$delegate").apply { isAccessible = true }.set(fixture.files,
                lazyOf(Executor { task -> rejection.get()?.let { throw it }; worker.execute(task) }))
            fixture.old()
        }
        fun install(value: CoreDataCleanup) { cleanup = value; cleanupField.set(null, value) }
        fun claim(epoch: Long = fixture.storage.snapshot().epoch): String = "cleanup-owner".also { owner ->
            operations.replaceOwner(owner)
            operations.command = mapOf("action" to "scheduleCoreCleanup", "storageEpoch" to epoch)
        }
        fun schedule(owner: String, paths: List<String> = listOf("cache.db")) = Reply().also { reply ->
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                calls.scheduleCoreCleanup(MethodCall("scheduleCoreCleanup", mapOf("paths" to paths)), owner, reply)
            }
        }
        override fun close() {
            rejection.set(null)
            worker.submit {}.get(10, TimeUnit.SECONDS)
            client.lifecycle.cleanup(false)
            filesField.set(null, oldFiles); cleanupField.set(null, oldCleanup)
            worker.shutdown(); assertTrue(worker.awaitTermination(10, TimeUnit.SECONDS))
        }
    }
    private fun harness(block: (Harness) -> Unit) = BackupFixture.use { fixture -> Harness(fixture).use(block) }

    @Test fun aQueuedCleanupCannotPublishAfterTheBusinessStorageEpochChanges() = harness { h ->
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        h.worker.execute { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        val before = h.fixture.current(); val reply = h.schedule(h.claim())
        h.fixture.storage.beginSystemRestore()
        release.countDown(); reply.failed("storageBusy")
        assertFalse(h.record.exists()); assertEquals(before, h.fixture.current()); assertFalse(h.publishing.get())
    }

    @Test fun ownerReplacementAndWorkerRejectionPreserveThePreviousRecordAndOriginalErrors() = harness { h ->
        h.cleanup.schedule(CoreDataCleanup.Request(listOf("cache.db"))) { it() }
        val before = h.record.readBytes()
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        h.worker.execute { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        val reply = h.schedule(h.claim()); h.operations.replaceOwner("replacement")
        release.countDown(); reply.failed("owner 已替换")
        assertArrayEquals(before, h.record.readBytes())
        val cause = IOException("原始 worker cause")
        val rejected = RejectedExecutionException("原始 worker rejection", cause).apply { addSuppressed(IOException("原始 suppressed")) }
        h.rejection.set(rejected)
        val rejectedReply = h.schedule(h.claim()); rejectedReply.failed("原始 worker rejection")
        val detail = AppMessage.fromMap(rejectedReply.details)!!.detail!!
        assertTrue(detail.contains("原始 worker cause")); assertTrue(detail.contains("原始 suppressed"))
        assertArrayEquals(before, h.record.readBytes()); assertFalse(h.publishing.get())
    }

    @Test fun publicationWaitsForActualSyncAndKeepsItsResultAfterOwnerReplacement() = harness { h ->
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val database = File(h.core, "cache.db").apply { writeText("actual cache") }
        h.install(CoreDataCleanup(h.core, h.record, writeRecord = { file, bytes, publish ->
            CorePrivateFiles.write(file, bytes, publish)
            if (entered.count > 0) { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
        }).apply { initialize() })
        val before = h.fixture.current(); val reply = h.schedule(h.claim())
        assertTrue(entered.await(5, TimeUnit.SECONDS)); assertEquals(1L, reply.done.count)
        assertTrue(database.exists()); assertTrue(h.record.exists()); assertTrue(h.publishing.get())
        h.operations.replaceOwner("replacement"); release.countDown()
        reply.await(); assertNull(reply.code)
        assertEquals(true, (reply.value as Map<*, *>)["success"])
        assertFalse(database.exists()); assertFalse(h.record.exists()); assertEquals(before, h.fixture.current())
    }

    @Test fun onlyExplicitRegisteredPathsCanBePublishedBeforeAnyCoreExit() = harness { h ->
        val database = File(h.core, "cache.db").apply { writeText("actual cache") }
        val provider = File(h.core, "provider.yaml").apply { writeText("user provider") }
        val reply = h.schedule(h.claim(), listOf(provider.path))
        reply.failed("Invalid core cleanup relative path")
        assertFalse(h.record.exists()); assertTrue(database.exists()); assertEquals("user provider", provider.readText())
        val unregistered = h.schedule(h.claim(), listOf(provider.name))
        unregistered.failed("Cleanup list contains unconfirmed files"); assertFalse(h.record.exists()); assertFalse(h.client.lifecycle.snapshot().cleanupPending)
    }

    @Test fun anOldEpochOrUninitializedCleanupCannotDeleteOrPublishFiles() = harness { h ->
        val database = File(h.core, "cache.db").apply { writeText("actual cache") }
        val oldEpoch = h.schedule(h.claim(h.fixture.storage.snapshot().epoch - 1))
        oldEpoch.failed("storageEpochChanged"); assertFalse(h.record.exists()); assertTrue(database.exists())
        h.install(CoreDataCleanup(h.core, h.record))
        val pending = h.schedule(h.claim()); pending.failed("Core file cleanup is still initializing")
        assertFalse(h.record.exists()); assertTrue(database.exists()); assertFalse(h.publishing.get())
    }

    @Test fun cleanupWaitsForTheFileWorkerBarrierAndReturnsPerFileCompletionWithoutFinishingUi() = harness { h ->
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val database = File(h.core, "cache.db").apply { writeText("actual cache") }
        val kept = File(h.core, "user-file").apply { writeText("preserved") }
        h.worker.execute { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        val reply = h.schedule(h.claim()); assertEquals(1L, reply.done.count)
        assertTrue(database.exists()); assertFalse(h.record.exists())
        release.countDown(); reply.await(); assertNull(reply.code)
        val value = reply.value as Map<*, *>
        assertEquals(true, value["success"])
        val item = (value["items"] as List<*>).single() as Map<*, *>
        assertEquals("cache.db", item["path"]); assertEquals(true, item["completed"])
        assertEquals("preserved", kept.readText()); assertFalse(h.client.lifecycle.snapshot().cleanupPending)
        assertFalse(h.calls.exitingForCleanup); assertFalse(h.publishing.get())
    }
}
