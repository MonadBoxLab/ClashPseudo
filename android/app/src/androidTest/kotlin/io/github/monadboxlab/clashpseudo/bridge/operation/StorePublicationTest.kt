package io.github.monadboxlab.clashpseudo.bridge.operation

import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.WorkManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.bridge.BridgeTestState
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class StorePublicationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val original = "https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture"
    private val syncFailure = IOException(original, IOException("original sync cause"))
    private val owner = UUID.randomUUID().toString()
    private val instance = BackupFiles::class.java.getDeclaredField("instance").apply { isAccessible = true }
    private val fields = listOf("operationId", "operationAdmittedAt", "operationDeadline", "command", "storagePublishing")
        .associateWith { BridgeTestState.field(it) }
    private val publish = AppBridge::class.java.getDeclaredMethod("publishStore", MethodCall::class.java,
        String::class.java, MethodChannel.Result::class.java).apply { isAccessible = true }
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var root: File
    private lateinit var files: BackupFiles
    private var previousFiles: Any? = null
    private var previous: Map<String, Any?> = emptyMap()
    @Volatile private var failDirectorySync = false
    @Volatile private var revokeAfterRename = false

    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun executor(value: Executor) {
        BackupFiles::class.java.getDeclaredField("ioExecutor\$delegate").apply { isAccessible = true }
            .set(files, lazyOf(value))
    }

    private class Reply : MethodChannel.Result {
        val done = CountDownLatch(1)
        var value: Any? = null
        var error: AppMessage? = null
        var replies = 0
        override fun success(result: Any?) { value = result; replies++; done.countDown() }
        override fun error(code: String, message: String?, details: Any?) {
            error = AppMessage.fromMap(details)
            replies++
            done.countDown()
        }
        override fun notImplemented() { fail("Publication missing") }
    }

    @Before fun prepareIsolatedStorage() {
        val manager = WorkManager.getInstance(instrumentation.targetContext)
        val deadline = SystemClock.elapsedRealtime() + 45_000
        while (true) {
            val work = manager.getWorkInfosForUniqueWork("update-reconcile").get(5, TimeUnit.SECONDS)
            var idle = false
            main { idle = AppBridge.operationId == null && !AppBridge.logic.busy }
            if (work.isNotEmpty() && work.all { it.state.isFinished } && idle) break
            check(SystemClock.elapsedRealtime() < deadline) { "Startup reconciliation did not drain" }
            SystemClock.sleep(20)
        }
        root = File(instrumentation.targetContext.cacheDir, "publication-${UUID.randomUUID()}")
        check(root.mkdir())
        files = BackupFiles(File(root, "stores"), File(root, "backup"), sync = { descriptor ->
            if (OsConstants.S_ISDIR(Os.fstat(descriptor).st_mode)) {
                if (revokeAfterRename) main { fields.getValue("operationAdmittedAt").set(AppBridge, null) }
                if (failDirectorySync) throw syncFailure
            }
            Os.fsync(descriptor)
        })
        files.transaction.recover()
        executor(worker)
        main {
            assertNull(AppBridge.operationId)
            assertFalse(AppBridge.logic.busy)
            assertEquals(false, AppBridge.runtimeState()["writerBusy"])
            previousFiles = instance.get(null)
            previous = fields.mapValues { it.value.get(AppBridge) }
            instance.set(null, files)
            fields.getValue("operationId").set(AppBridge, owner)
            fields.getValue("operationAdmittedAt").set(AppBridge, SystemClock.elapsedRealtime())
            fields.getValue("command").set(AppBridge, mapOf("action" to "saveLocal"))
        }
    }

    @After fun releaseIsolatedStorage() {
        main {
            if (previous.isNotEmpty()) {
                fields.forEach { (name, field) -> field.set(AppBridge, previous[name]) }
                instance.set(null, previousFiles)
                PseudoVpnService.core.setOperationBusy(AppBridge.operationId != null || AppBridge.logic.busy ||
                    AppBridge.runtimeState()["resourceBusy"] == true)
            }
        }
        worker.shutdown()
        check(worker.awaitTermination(10, TimeUnit.SECONDS)) { "Publication fixture did not drain" }
        // Drain callbacks from accepted file work before removing its storage.
        main {}
        if (::root.isInitialized) check(root.deleteRecursively())
    }

    private fun publish(): Reply {
        val reply = Reply()
        main {
            publish.invoke(AppBridge, MethodCall("publishStore", mapOf(
                "file" to "configurations.json", "epoch" to files.transaction.snapshot().epoch,
            )), owner, reply)
        }
        return reply
    }

    @Test fun executorRejectionKeepsItsOriginalErrorAndReleasesThePublicationGate() {
        val failure = RejectedExecutionException(original, IOException("original executor cause"))
        val reply = Reply()
        main {
            executor(Executor { throw failure })
            try {
                publish.invoke(AppBridge, MethodCall("publishStore", mapOf(
                    "file" to "configurations.json", "epoch" to files.transaction.snapshot().epoch,
                )), owner, reply)
            } finally {
                executor(worker)
            }
        }
        assertTrue(reply.done.await(5, TimeUnit.SECONDS))
        assertEquals(1, reply.replies)
        assertNull(reply.value)
        assertEquals(failure.stackTraceToString(), reply.error!!.detail)
        main { assertEquals(false, fields.getValue("storagePublishing").get(AppBridge)) }
        File(files.stores, "configurations.json.tmp").writeText(original)
        val retry = publish()
        assertTrue(retry.done.await(5, TimeUnit.SECONDS))
        assertNull(retry.error)
        assertEquals(true, (retry.value as Map<*, *>)["saved"])
        assertEquals(original, File(files.stores, "configurations.json").readText())
    }

    @Test fun actualFileFailureKeepsTheSystemErrorAndCanBeRetried() {
        val actualError = try {
            Os.lstat(File(files.stores, "configurations.json.tmp").path)
            fail("Missing fixture unexpectedly existed")
            ""
        } catch (error: ErrnoException) { error.toString() }
        val reply = publish()
        assertTrue(reply.done.await(5, TimeUnit.SECONDS))
        assertEquals(1, reply.replies)
        assertNull(reply.value)
        assertTrue(reply.error!!.detail!!.startsWith("$actualError\n"))
        assertTrue(reply.error!!.detail!!.contains("RestoreTransaction.publishStore"))
        assertTrue(reply.error!!.detail!!.contains("ENOENT"))
        main { assertEquals(false, fields.getValue("storagePublishing").get(AppBridge)) }
        File(files.stores, "configurations.json.tmp").writeText(original)
        val retry = publish()
        assertTrue(retry.done.await(5, TimeUnit.SECONDS))
        assertNull(retry.error)
        assertEquals(true, (retry.value as Map<*, *>)["durable"])
    }

    @Test fun renameSuccessRetainsItsIdentityAndSyncErrorAfterAdmissionExpires() {
        File(files.stores, "configurations.json.tmp").writeText(original)
        failDirectorySync = true
        revokeAfterRename = true
        val reply = publish()
        assertTrue(reply.done.await(5, TimeUnit.SECONDS))
        assertEquals(1, reply.replies)
        assertNull(reply.error)
        val value = reply.value as Map<*, *>
        assertEquals(true, value["saved"])
        assertEquals(false, value["durable"])
        assertEquals(files.transaction.snapshot().epoch, value["epoch"])
        assertEquals("publishedDirectorySyncFailed", value["errorCode"])
        assertEquals(syncFailure.stackTraceToString(), AppMessage.fromMap(value["errorDetail"])!!.detail)
        assertEquals(original, File(files.stores, "configurations.json").readText())
        main {
            assertEquals(0L, AppBridge.operationRemainingMs(owner))
            assertEquals(false, fields.getValue("storagePublishing").get(AppBridge))
        }
    }
}
