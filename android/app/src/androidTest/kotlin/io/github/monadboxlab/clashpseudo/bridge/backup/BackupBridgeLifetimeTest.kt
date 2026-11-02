package io.github.monadboxlab.clashpseudo.bridge.backup

import android.app.Activity
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.WorkManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.backup.BackupCalls
import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import io.github.monadboxlab.clashpseudo.backup.BackupFixture
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.bridge.BridgeTestState
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.io.File
import java.io.FileDescriptor
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

class BackupBridgeLifetimeTest {
    private class Reply : MethodChannel.Result {
        val values = mutableListOf<Any?>()
        val errors = mutableListOf<String>()
        override fun success(value: Any?) { values.add(value) }
        override fun error(code: String, message: String?, details: Any?) { errors.add(code) }
        override fun notImplemented() { fail("Backup method was not implemented") }
        fun value(): Map<*, *> {
            assertTrue(errors.isEmpty())
            return values.single() as Map<*, *>
        }
    }

    /** Keep production file work and bridge callbacks, controlling only their queues. */
    private class Harness(val fixture: BackupFixture) : AutoCloseable {
        val storage = ConcurrentLinkedQueue<Runnable>()
        val posts = ConcurrentLinkedQueue<Runnable>()
        var rejectStorage: Exception? = null
        private val fields = listOf("backups", "operationId", "operationAdmittedAt", "operationDeadline", "command", "operation",
            "resultId", "resultMessage", "resultSuccess", "backupResult", "installedBackup",
            "restoreStopRequested", "restoreStopOwner", "restoreStopReply", "restoreInterruption",
            "configStatus", "overrideStatus", "resourceStatus", "scheduleStatus", "connectionStatus",
            "targetId", "savedRevision")
            .associateWith { BridgeTestState.field(it) }
        private val maps = listOf("backupUses", "preparedBackups", "retiredBackups").associateWith {
            @Suppress("UNCHECKED_CAST")
            (BridgeTestState.field(it).get(AppBridge) as MutableMap<Any?, Any?>)
        }
        private lateinit var previous: Map<String, Any?>
        private val coreClient get() = io.github.monadboxlab.clashpseudo.nativecore.CoreClient.installed()
        private val coreBusy = io.github.monadboxlab.clashpseudo.nativecore.CoreClient::class.java.getDeclaredField("operationBusy")
            .apply { isAccessible = true }
        private val acceptOwner = AppBridge::class.java.getDeclaredMethod("replaceOwner", String::class.java)
            .apply { isAccessible = true }
        private val work = BackupCoordinator::class.java.getDeclaredMethod("backupWork", MethodCall::class.java,
            String::class.java, MethodChannel.Result::class.java).apply { isAccessible = true }
        private val discard = BackupCoordinator::class.java.getDeclaredMethod("discardBackup", String::class.java,
            kotlin.Function1::class.java).apply { isAccessible = true }

        init {
            val calls = BackupCalls(fixture.files, {},
                launch = { _, _, _ -> fail("Private backup work must not launch a picker") },
                openInput = { throw IOException("Unexpected document read") },
                openOutput = { throw IOException("Unexpected document write") },
                documentWorker = Executor { fail("Unexpected document work") },
                storageWorker = Executor { task -> rejectStorage?.let { throw it }; storage.add(task) },
                post = { posts.add(it); Unit }, delay = { _, _ -> }, remove = {},
                clock = { SystemClock.elapsedRealtime() })
            onMain {
                assertNull(AppBridge.operationId)
                assertFalse(AppBridge.logic.busy)
                assertEquals("STOPPED", AppBridge.runtimeState()["phase"])
                assertFalse(coreBusy.getBoolean(coreClient))
                maps.values.forEach { assertTrue(it.isEmpty()) }
                previous = fields.mapValues { it.value.get(AppBridge) }
                calls.attach(Activity())
                fields.getValue("backups").set(AppBridge, calls)
            }
        }

        fun onMain(block: () -> Unit) {
            var failure: Throwable? = null
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                failure = runCatching(block).exceptionOrNull()
            }
            failure?.let { throw it }
        }

        fun claim(action: String, token: String? = null): String {
            val owner = UUID.randomUUID().toString()
            onMain {
                acceptOwner.invoke(AppBridge, owner)
                fields.getValue("command").set(AppBridge, mapOf("action" to action,
                    "requestId" to owner, "createdAtMillis" to 123456L,
                    "storageEpoch" to fixture.storage.snapshot().epoch, "token" to token))
            }
            return owner
        }

        fun begin(action: String, token: String? = null): Pair<String, Reply> {
            val owner = claim(action, token)
            val reply = Reply()
            val arguments = mapOf("requestId" to owner, "createdAtMillis" to 123456L,
                "storageEpoch" to fixture.storage.snapshot().epoch, "token" to token)
            onMain {
                val method = if (action == "prepareBackup") "backupPrepareExport" else "backupCandidate"
                work.invoke(BridgeTestState.coordinator("backupCoordinator"), MethodCall(method, arguments + mapOf(
                    "expectedEpoch" to arguments["storageEpoch"],
                    "defaults" to BackupFixture.values().entries.associate {
                        it.key.fileName to it.value.toString(Charsets.UTF_8)
                    })), owner, reply)
            }
            return owner to reply
        }

        fun inspectAgain(owner: String, token: String): Reply = Reply().also { reply ->
            onMain { work.invoke(BridgeTestState.coordinator("backupCoordinator"), MethodCall("backupCandidate", mapOf("token" to token)), owner, reply) }
        }

        fun retire(token: String, reply: (Throwable?) -> Unit) {
            onMain { discard.invoke(BridgeTestState.coordinator("backupCoordinator"), token, reply) }
        }

        fun runStorage() { checkNotNull(storage.poll()) { "No queued storage work" }.run() }
        fun postOne() { onMain { checkNotNull(posts.poll()) { "No queued bridge callback" }.run() } }
        fun pinned(owner: String, token: String) = maps.getValue("backupUses")[owner] == token
        fun retired(token: String) = maps.getValue("retiredBackups").containsKey(token)
        fun prepared(token: String) = token in maps.getValue("preparedBackups").values

        override fun close() {
            onMain {
                fields.forEach { (name, field) -> field.set(AppBridge, previous[name]) }
                maps.values.forEach { it.clear() }
                PseudoVpnService.core.setOperationBusy(false)
            }
        }
    }

    private fun waitForStartupReconciliation() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val manager = WorkManager.getInstance(instrumentation.targetContext)
        val deadline = SystemClock.elapsedRealtime() + 45_000L
        while (true) {
            val work = manager.getWorkInfosForUniqueWork("update-reconcile").get(5, TimeUnit.SECONDS)
            var idle = false
            instrumentation.runOnMainSync { idle = AppBridge.operationId == null && !AppBridge.logic.busy }
            if (work.isNotEmpty() && work.all { it.state.isFinished } && idle) return
            check(SystemClock.elapsedRealtime() < deadline) { "Startup reconciliation did not drain" }
            SystemClock.sleep(50L)
        }
    }

    @Test fun retiredCandidateStaysPinnedBeyondNativeInspectionUntilTheActualReaderAndExecutorDrain() {
        waitForStartupReconciliation()
        BackupFixture.use { fixture ->
            fixture.old()
            val original = fixture.current()
            val candidate = fixture.candidate()
            val directory = File(fixture.privateRoot, "candidates/${candidate.token}")
            Harness(fixture).use { h ->
                val (owner, inspection) = h.begin("inspectBackup", candidate.token)
                h.onMain { assertTrue(h.pinned(owner, candidate.token)) }
                h.runStorage()
                h.postOne()
                val paths = inspection.value()["paths"] as Map<*, *>
                val readEntered = CountDownLatch(1)
                val releaseRead = CountDownLatch(1)
                val readExited = CountDownLatch(1)
                val failure = AtomicReference<Throwable?>()
                val descriptor = AtomicReference<FileDescriptor?>()
                val body = AtomicReference<ByteArray?>()
                val reader = Thread {
                    try {
                        File(paths["configurations.json"] as String).inputStream().use { input ->
                            descriptor.set(input.fd)
                            val first = input.read()
                            check(first >= 0)
                            readEntered.countDown()
                            check(releaseRead.await(10, TimeUnit.SECONDS)) { "Reader was not released" }
                            body.set(byteArrayOf(first.toByte()) + input.readBytes())
                        }
                    } catch (error: Throwable) { failure.set(error) }
                    finally { readExited.countDown() }
                }.apply { isDaemon = true; start() }
                var discards = 0
                try {
                    assertTrue(readEntered.await(5, TimeUnit.SECONDS))
                    h.retire(candidate.token) { error -> assertNull(error); discards++ }
                    assertEquals(listOf("backup"), h.inspectAgain(owner, candidate.token).errors)
                    h.onMain {
                        assertTrue(h.pinned(owner, candidate.token))
                        assertTrue(h.retired(candidate.token))
                        AppBridge.finish(owner, mapOf("success" to false,
                            "message" to AppMessage("operationFinished").toMap()))
                        AppBridge.executorDrained("unrelated-reader")
                        assertTrue(h.pinned(owner, candidate.token))
                    }
                    assertTrue(directory.isDirectory)
                    assertTrue(h.storage.isEmpty())
                    assertEquals(0, discards)
                    assertTrue(descriptor.get()!!.valid())
                    releaseRead.countDown()
                    assertTrue(readExited.await(5, TimeUnit.SECONDS))
                    failure.get()?.let { throw it }
                    assertFalse(descriptor.get()!!.valid())
                    assertArrayEquals(BackupFixture.values().getValue(BackupFiles.Kind.CONFIGURATIONS), body.get())
                    h.onMain {
                        AppBridge.executorDrained(owner)
                        assertFalse(h.pinned(owner, candidate.token))
                        assertFalse(h.retired(candidate.token))
                    }
                    assertTrue(directory.isDirectory)
                    assertEquals(0, discards)
                    h.runStorage()
                    assertFalse(directory.exists())
                    assertEquals(0, discards)
                    h.postOne()
                    assertEquals(1, discards)
                    assertEquals(original, fixture.current())
                } finally {
                    releaseRead.countDown()
                    reader.join(5000L)
                    assertFalse(reader.isAlive)
                }
            }
        }
    }

    @Test fun lateCaptureReturnsItsActualReceiptOnlyAfterPrivateCleanup() = lateCapture(false)

    @Test fun rejectedLateCaptureCleanupPreservesItsCauseAndSuppressedFailure() = lateCapture(true)

    private fun lateCapture(rejectCleanup: Boolean) {
        waitForStartupReconciliation()
        BackupFixture.use { fixture ->
            fixture.old()
            val original = fixture.current()
            Harness(fixture).use { h ->
                val (oldOwner, capture) = h.begin("prepareBackup")
                h.runStorage()
                val directory = File(fixture.privateRoot, "candidates").listFiles()!!.single()
                val token = directory.name
                h.onMain {
                    AppBridge.finish(oldOwner, mapOf("success" to false,
                        "message" to AppMessage("operationFinished").toMap()))
                }
                val nextOwner = h.claim("inspectBackup", UUID.randomUUID().toString())
                val cleanupFailure = IOException("late cleanup rejected", IllegalStateException("original cleanup cause"))
                    .apply { addSuppressed(IOException("secondary cleanup failure")) }
                if (rejectCleanup) h.rejectStorage = cleanupFailure
                h.postOne()
                h.onMain {
                    assertEquals(nextOwner, AppBridge.operationId)
                    assertFalse(h.pinned(oldOwner, token))
                    assertFalse(h.prepared(token))
                }
                if (!rejectCleanup) {
                    assertTrue(capture.values.isEmpty())
                    assertTrue(directory.isDirectory)
                    h.runStorage()
                    assertFalse(directory.exists())
                    assertTrue(capture.values.isEmpty())
                    h.postOne()
                } else {
                    assertTrue(directory.isDirectory)
                }
                val actual = capture.value()
                assertEquals("ready", actual["status"])
                assertEquals(true, actual["retired"])
                assertEquals(token, actual["token"])
                assertEquals(oldOwner, actual["requestId"])
                assertEquals(BackupFiles.Kind.entries.map { it.fileName }.toSet(), (actual["paths"] as Map<*, *>).keys)
                if (rejectCleanup) {
                    val detail = (actual["cleanupError"] as Map<*, *>)["detail"] as String
                    for (text in listOf("late cleanup rejected", "original cleanup cause", "secondary cleanup failure")) {
                        assertTrue(detail.contains(text))
                    }
                    h.rejectStorage = null
                    fixture.files.discard(token)
                } else assertNull(actual["cleanupError"])
                h.onMain {
                    assertEquals(nextOwner, AppBridge.operationId)
                    assertFalse(h.prepared(token))
                    assertFalse(h.pinned(oldOwner, token))
                    AppBridge.finish(nextOwner, mapOf("success" to false))
                    AppBridge.executorDrained(nextOwner)
                }
                assertTrue(h.storage.isEmpty())
                assertTrue(h.posts.isEmpty())
                assertEquals(1, capture.values.size)
                assertEquals(original, fixture.current())
            }
        }
    }
}
