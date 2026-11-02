package io.github.monadboxlab.clashpseudo.backup

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

/**
 * Uses explicit picker, provider and clock doubles with real isolated candidates and
 * transactions.
 */
class BackupCallsTest {
    private class Queue : Executor {
        val tasks = ArrayDeque<Runnable>()
        override fun execute(command: Runnable) { tasks.add(command) }
        fun runOne() { tasks.removeFirst().run() }
    }
    private data class Launch(val activity: Activity, val intent: Intent, val code: Int)
    private class Harness(val f: BackupFixture, realDocumentWorker: Executor? = null, realStorageWorker: Executor? = null) {
        val storage = Queue()
        val documents = Queue()
        val posts = ConcurrentLinkedQueue<Runnable>()
        val timers = linkedMapOf<Runnable, Long>()
        val launches = mutableListOf<Launch>()
        val replies = mutableListOf<Map<String, Any?>>()
        var now = 0L
        var changes = 0
        var opens = 0
        var input: () -> InputStream = { throw IOException("No fixture input") }
        var output: () -> OutputStream = { throw IOException("No fixture output") }
        var launchError = false
        val host = newActivity()
        val calls = BackupCalls(f.files, { changes++ },
            launch = { activity, intent, code ->
                if (launchError) throw IOException("Injected missing picker")
                launches.add(Launch(activity, intent, code))
            },
            openInput = { uri -> assertEquals("content", uri.scheme); opens++; input() },
            openOutput = { uri -> assertEquals("content", uri.scheme); opens++; output() },
            documentWorker = realDocumentWorker ?: documents, storageWorker = realStorageWorker ?: storage,
            post = { posts.add(it); Unit }, delay = { task, millis -> timers[task] = now + millis },
            remove = { timers.remove(it); Unit }, clock = { now },
        )
        init { calls.attach(host) }
        fun reply(value: Map<String, Any?>) { replies.add(value) }
        fun drain() { while (true) (posts.poll() ?: break).run() }
        fun storage() { while (storage.tasks.isNotEmpty()) { storage.runOne(); drain() } }
        fun documents() { while (documents.tasks.isNotEmpty()) { documents.runOne(); drain() } }
        fun expire() { now += BackupCalls.IO_TIMEOUT_MS; timers.keys.toList().forEach { it.run() } }
        fun select(code: Int = launches.last().code, activity: Activity = host,
            result: Int = Activity.RESULT_OK, uri: String? = "content://fixture/document/opaque") =
            calls.onActivityResult(activity, code, result, uri?.let { Intent().setData(Uri.parse(it)) })
        fun save(candidate: BackupFiles.Candidate, id: String = "save") {
            calls.saveExport(id, candidate.token, "backup.zip", ::reply)
            storage()
        }
        companion object {
            fun newActivity(): Activity {
                lateinit var result: Activity
                InstrumentationRegistry.getInstrumentation().runOnMainSync { result = Activity() }
                return result
            }
        }
    }
    private fun archive(f: BackupFixture, candidate: BackupFiles.Candidate) = ByteArrayOutputStream().also {
        f.files.writeArchive(candidate.token, it, BackupFiles.Operation(BackupLease()))
    }.toByteArray()
    private fun defaults() = BackupFixture.values().entries.associate { it.key.fileName to it.value.toString(Charsets.UTF_8) }
    private fun status(h: Harness) = h.replies.last()["status"]
    private fun busy(h: Harness) = h.calls.snapshot()["busy"] == true
    private fun capturing(h: Harness) = h.calls.snapshot()["capturing"] == true

    @Test fun capturesFixedRawStoresAndUsesOnlyDartDefaultsForAbsentFilesBeforeAnyPicker() = BackupFixture.use { f ->
        val original = BackupFixture.values()
        f.old(original)
        check(File(f.stores, BackupFiles.Kind.OVERRIDES.fileName).delete())
        val defaults = defaults().toMutableMap().apply { this["overrides.json"] = "{\r\n \"entries\": [], \"unknown\": true\r\n}" }
        val h = Harness(f)
        h.calls.prepareExport("capture", 123L, f.storage.snapshot().epoch, defaults, BackupLease(), h::reply)
        assertTrue(capturing(h))
        assertTrue(h.launches.isEmpty())
        assertTrue(h.documents.tasks.isEmpty())
        h.storage()
        assertEquals("ready", status(h))
        assertFalse(capturing(h))
        assertFalse(busy(h))
        @Suppress("UNCHECKED_CAST") val paths = h.replies.last()["paths"] as Map<String, String>
        assertEquals(BackupFiles.Kind.entries.map { it.fileName }.toSet(), paths.keys)
        for (kind in BackupFiles.Kind.entries) {
            val path = File(paths.getValue(kind.fileName))
            assertTrue(path.isAbsolute)
            assertEquals(kind.fileName, path.name)
            assertTrue(path.path.startsWith(File(f.privateRoot, "candidates").path + "/"))
            assertArrayEquals(if (kind == BackupFiles.Kind.OVERRIDES) defaults.getValue(kind.fileName).toByteArray() else original.getValue(kind), path.readBytes())
        }
        f.storage.withStableStorage(f.storage.snapshot().epoch) { assertTrue(h.launches.isEmpty()) }
    }

    @Test fun createDocumentWaitHasNoCopyDeadlineAndReleasesStorageBeforePicker() = BackupFixture.use { f ->
        val candidate = f.candidate()
        val h = Harness(f)
        val output = ByteArrayOutputStream()
        var closes = 0
        h.output = { object : OutputStream() {
            override fun write(value: Int) { output.write(value) }
            override fun write(bytes: ByteArray, offset: Int, count: Int) { output.write(bytes, offset, count) }
            override fun close() { closes++ }
        } }
        h.save(candidate)
        val launch = h.launches.single()
        assertEquals(Intent.ACTION_CREATE_DOCUMENT, launch.intent.action)
        assertEquals("application/zip", launch.intent.type)
        assertTrue(launch.intent.hasCategory(Intent.CATEGORY_OPENABLE))
        assertFalse(launch.intent.hasExtra(Intent.EXTRA_LOCAL_ONLY))
        assertEquals("backup.zip", launch.intent.getStringExtra(Intent.EXTRA_TITLE))
        assertTrue(launch.code in BackupCalls.FIRST_CODE..BackupCalls.LAST_CODE)
        assertEquals(0, launch.intent.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        assertFalse(capturing(h))
        assertTrue(h.timers.isEmpty())
        h.expire()
        assertTrue(h.replies.isEmpty())
        f.storage.withStableStorage(f.storage.snapshot().epoch) { }
        assertTrue(h.select())
        assertEquals(1, h.documents.tasks.size)
        assertTrue(h.storage.tasks.isEmpty())
        h.documents()
        assertEquals("saved", status(h))
        assertEquals(1, closes)
        assertFalse(busy(h))
        val imported = f.files.prepareImport(output.toByteArray().inputStream(), BackupFiles.Operation(BackupLease()))
        assertEquals(candidate.parts, imported.parts)
    }

    @Test fun openDocumentOnlyProducesPrivateFixedCandidatesAndNeverChangesBusinessFiles() = BackupFixture.use { f ->
        val source = f.candidate()
        val bytes = archive(f, source)
        f.old()
        val old = f.current()
        val h = Harness(f)
        var closes = 0
        h.input = { object : ByteArrayInputStream(bytes) { override fun close() { closes++; super.close() } } }
        h.calls.pickImport("import", h::reply)
        val intent = h.launches.single().intent
        assertEquals(Intent.ACTION_OPEN_DOCUMENT, intent.action)
        assertTrue(intent.hasCategory(Intent.CATEGORY_OPENABLE))
        assertFalse(intent.hasExtra(Intent.EXTRA_LOCAL_ONLY))
        assertFalse(capturing(h))
        assertTrue(h.timers.isEmpty())
        h.select()
        assertTrue(h.storage.tasks.isEmpty())
        h.documents()
        assertEquals("ready", status(h))
        assertEquals(1, closes)
        assertEquals(old, f.current())
        val token = h.replies.single()["token"] as String
        assertNotEquals(source.token, token)
        assertEquals(source.parts, f.files.candidate(token).parts)
        assertEquals(f.files.candidateReadPaths(token), h.replies.single()["paths"])
    }

    @Test fun cancellationAndNonContentResultsNeverOpenOrGuessAnyFilePath() = BackupFixture.use { f ->
        val h = Harness(f)
        h.calls.pickImport("cancel", h::reply)
        h.select(result = Activity.RESULT_CANCELED, uri = null)
        assertEquals("cancelled", status(h))
        h.calls.pickImport("file", h::reply)
        val outside = File(f.root, "private-secret").apply { writeText("untouched") }
        h.select(uri = outside.toURI().toString())
        assertEquals("failed", status(h))
        assertEquals("backupDocumentUnavailable", h.replies.last()["errorCode"])
        assertEquals(0, h.opens)
        assertEquals("untouched", outside.readText())
        assertFalse(h.calls.onActivityResult(h.host, 221, Activity.RESULT_OK, null))
        assertFalse(h.calls.onActivityResult(h.host, 100, Activity.RESULT_OK, null))
    }

    @Test fun savedBundleAndSameProcessHighWaterRejectOldActivityAndLatePickerResults() = BackupFixture.use { f ->
        val h = Harness(f)
        h.calls.pickImport("old", h::reply)
        val old = h.launches.last().code
        val state = Bundle()
        h.calls.saveState(h.host, state)
        assertEquals(setOf(BackupCalls.HIGH_WATER, BackupCalls.PENDING_CODE), state.keySet())
        val replacement = Harness.newActivity()
        h.calls.attach(replacement, state)
        assertEquals("cancelled", status(h))
        h.calls.detach(h.host) // stale destruction must not cancel a new instance
        h.calls.pickImport("new", h::reply)
        val newer = h.launches.last().code
        assertTrue(newer > old)
        assertTrue(h.select(code = newer, activity = h.host))
        assertTrue(h.select(code = old, activity = replacement))
        assertEquals(1, h.replies.size)
        assertEquals(0, h.opens)
        assertTrue(busy(h))
        h.calls.cancel("new")
        val recreated = Harness(f)
        recreated.calls.attach(recreated.host, state)
        recreated.calls.pickImport("after-process-state", recreated::reply)
        assertTrue(recreated.launches.single().code > old)
        assertTrue(recreated.select(code = old))
        assertTrue(recreated.replies.isEmpty())
    }

    @Test fun allocatorNeverWrapsAndMalformedSavedStateCannotRecycleCodes() = BackupFixture.use { f ->
        val h = Harness(f)
        val state = Bundle().apply { putInt(BackupCalls.HIGH_WATER, BackupCalls.LAST_CODE - 1) }
        h.calls.attach(h.host, state)
        h.calls.pickImport("last", h::reply)
        assertEquals(BackupCalls.LAST_CODE, h.launches.single().code)
        h.calls.cancel("last")
        h.calls.pickImport("exhausted", h::reply)
        assertEquals("backupRequestCodeExhausted", h.replies.last()["errorCode"])
        assertEquals(1, h.launches.size)
        assertFalse(busy(h))
        val malformed = Harness(f)
        malformed.calls.attach(malformed.host, Bundle().apply { putString(BackupCalls.HIGH_WATER, "not-an-int") })
        malformed.calls.pickImport("bad-state", malformed::reply)
        assertEquals("backupRequestCodeExhausted", malformed.replies.last()["errorCode"])
        assertTrue(malformed.launches.isEmpty())
    }

    @Test fun attachingNewActivityBeforeCancellationCallbackPreventsReentrantLaunchOnOldInstance() = BackupFixture.use { f ->
        val h = Harness(f)
        val replacement = Harness.newActivity()
        h.calls.pickImport("old") {
            h.reply(it)
            h.calls.pickImport("reentrant", h::reply)
        }
        h.calls.attach(replacement)
        assertEquals(2, h.launches.size)
        assertSame(replacement, h.launches.last().activity)
        h.calls.detach(h.host)
        assertTrue(busy(h))
        assertEquals(1, h.replies.size)
        h.calls.cancel("reentrant")
    }

    @Test fun timedOutCaptureStaysBusinessBusyUntilRealQueuedWorkExits() = BackupFixture.use { f ->
        val h = Harness(f)
        h.calls.prepareExport("capture", 1L, f.storage.snapshot().epoch, defaults(), BackupLease(), h::reply)
        h.expire()
        assertTrue(h.replies.isEmpty())
        assertEquals(true, h.calls.snapshot()["draining"])
        assertTrue(capturing(h))
        h.calls.pickImport("blocked", h::reply)
        assertEquals("busy", status(h))
        assertTrue(h.launches.isEmpty())
        h.storage()
        assertEquals("expired", status(h))
        assertEquals("backupTimedOut", h.replies.last()["errorCode"])
        assertTrue(h.replies.last()["errorDetail"].toString().contains("Document request ended"))
        assertFalse(busy(h))
        assertFalse(capturing(h))
        assertEquals(2, h.replies.size)
    }

    @Test fun latePreparedCandidateKeepsTheActualReadOnlyResultAndIsDiscardedAfterRealCaptureReturns() = BackupFixture.use { f ->
        val h = Harness(f)
        h.calls.prepareExport("capture", 1L, f.storage.snapshot().epoch, defaults(), BackupLease(), h::reply)
        h.storage.runOne() // native capture has exited; its main-thread completion is deliberately delayed
        val parent = File(f.privateRoot, "candidates")
        assertEquals(1, parent.listFiles()!!.size)
        h.calls.cancel("capture")
        assertTrue(h.replies.isEmpty())
        assertTrue(capturing(h))
        h.drain()
        assertTrue(capturing(h)) // necessary cleanup still belongs to the old capture
        h.storage()
        assertEquals(0, parent.listFiles()!!.size)
        assertFalse(busy(h))
        assertEquals(1, h.replies.size)
        assertEquals("ready", status(h))
        assertEquals(true, h.replies.single()["retired"])
        assertEquals("cancelled", (h.replies.single()["retirement"] as Map<*, *>)["status"])
        assertEquals(3, (h.replies.single()["parts"] as Map<*, *>).size)
    }

    @Test fun providerCloseFailureIsReportedAndNeverMislabelsOrDeletesExternalBytes() = BackupFixture.use { f ->
        val candidate = f.candidate()
        val h = Harness(f)
        val output = object : ByteArrayOutputStream() { override fun close() { super.close(); throw IOException("Injected close failure") } }
        h.output = { output }
        h.save(candidate)
        h.select()
        h.documents()
        assertEquals("failed", status(h))
        assertEquals("backupDocumentIoFailed", h.replies.last()["errorCode"])
        assertTrue(h.replies.last()["errorDetail"].toString().contains("Injected close failure"))
        assertEquals(true, h.replies.last()["externalMayBePartial"])
        assertTrue(output.size() > 0)
        assertEquals(candidate.parts, f.files.prepareImport(output.toByteArray().inputStream(), BackupFiles.Operation(BackupLease())).parts)
        assertFalse(busy(h))
    }

    @Test fun inputCloseFailureAfterRegistrationDoesNotOrphanAnUnreturnedCandidate() = BackupFixture.use { f ->
        val source = f.candidate()
        val bytes = archive(f, source)
        val parent = File(f.privateRoot, "candidates")
        val before = parent.list()!!.toSet()
        val h = Harness(f)
        h.input = { object : ByteArrayInputStream(bytes) { override fun close() { throw IOException("Injected input close failure") } } }
        h.calls.pickImport("import", h::reply)
        h.select()
        h.documents()
        assertEquals("failed", status(h))
        assertTrue(h.replies.last()["errorDetail"].toString().contains("Injected input close failure"))
        assertEquals(before, parent.list()!!.toSet())
        assertFalse(busy(h))
    }

    @Test fun candidateInspectionUsesSameFixedViewAndCannotQueueBehindAnActiveProviderRecord() = BackupFixture.use { f ->
        val candidate = f.candidate()
        val h = Harness(f)
        h.calls.candidate(candidate.token, h::reply)
        assertFalse(capturing(h))
        h.calls.saveExport("blocked", candidate.token, "backup.zip", h::reply)
        assertEquals("busy", status(h))
        h.storage()
        assertEquals("ready", status(h))
        assertEquals(f.files.candidateReadPaths(candidate.token), h.replies.last()["paths"])
        h.save(candidate)
        val queuedBefore = h.storage.tasks.size
        h.calls.candidate(candidate.token, h::reply)
        assertEquals("busy", status(h))
        assertEquals(queuedBefore, h.storage.tasks.size)
        h.calls.cancel("save")
    }

    @Test fun blockedProviderTimeoutAndCloseKeepOneDrainingSlotWithoutBlockingOrdinaryStorageIo() = BackupFixture.use { f ->
        val source = f.candidate()
        val executor = Executors.newSingleThreadExecutor()
        val entered = CountDownLatch(1)
        val releaseWrite = CountDownLatch(1)
        val closing = CountDownLatch(1)
        val releaseClose = CountDownLatch(1)
        val h = Harness(f, executor)
        val output = ByteArrayOutputStream()
        h.output = { object : OutputStream() {
            override fun write(value: Int) { write(byteArrayOf(value.toByte()), 0, 1) }
            override fun write(bytes: ByteArray, offset: Int, count: Int) {
                entered.countDown()
                check(releaseWrite.await(10, TimeUnit.SECONDS))
                output.write(bytes, offset, count)
            }
            override fun close() { closing.countDown(); check(releaseClose.await(10, TimeUnit.SECONDS)) }
        } }
        try {
            h.save(source)
            h.select()
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            h.expire()
            assertTrue(h.replies.isEmpty())
            assertEquals(true, h.calls.snapshot()["draining"])
            assertFalse(capturing(h))
            var discarded = false
            h.calls.discardCandidate(source.token) { error -> assertNull(error); discarded = true }
            assertFalse(discarded)
            assertTrue(h.storage.tasks.isEmpty()) // Discard does not queue file I/O while the provider still owns this record.
            h.calls.pickImport("blocked", h::reply)
            assertEquals("busy", status(h))
            val kind = BackupFiles.Kind.PREFERENCES
            File(f.stores, "${kind.fileName}.tmp").writeText("{\"duringProvider\":true}")
            assertTrue(f.storage.publishStore(kind, f.storage.snapshot().epoch, BackupLease()).saved)
            releaseWrite.countDown()
            assertTrue(closing.await(5, TimeUnit.SECONDS))
            assertTrue(busy(h))
            assertFalse(discarded)
            assertEquals(1, h.replies.size)
            assertTrue(h.storage.tasks.isEmpty())
            assertTrue(File(f.privateRoot, "candidates/${source.token}").exists())
            releaseClose.countDown()
            executor.submit { }.get(5, TimeUnit.SECONDS) // exact worker-exit barrier, not an expired Future
            h.drain()
            h.storage()
            assertFalse(busy(h))
            assertTrue(discarded)
            assertFalse(File(f.privateRoot, "candidates/${source.token}").exists())
            assertEquals(2, h.replies.size)
            assertEquals("expired", status(h))
            assertEquals(true, h.replies.last()["externalMayBePartial"])
            assertTrue(h.replies.last()["errorDetail"].toString().contains("Document request ended"))
            h.calls.pickImport("next", h::reply)
            assertEquals(2, h.launches.size)
            assertTrue(h.launches.last().code > h.launches.first().code)
            assertTrue(h.select(code = h.launches.first().code))
            assertEquals(2, h.replies.size)
            h.calls.cancel("next")
        } finally { releaseWrite.countDown(); releaseClose.countDown(); executor.shutdownNow() }
    }

    @Test fun cancellationDuringActualProviderCloseKeepsTheWaiterAndTheActualSavedResult() = BackupFixture.use { f ->
        val candidate = f.candidate()
        val executor = Executors.newSingleThreadExecutor()
        val closing = CountDownLatch(1)
        val release = CountDownLatch(1)
        val bytes = ByteArrayOutputStream()
        val h = Harness(f, executor)
        h.output = { object : OutputStream() {
            override fun write(value: Int) = bytes.write(value)
            override fun write(buffer: ByteArray, offset: Int, length: Int) = bytes.write(buffer, offset, length)
            override fun close() { closing.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
        } }
        try {
            h.save(candidate)
            h.select()
            assertTrue(closing.await(5, TimeUnit.SECONDS))
            h.calls.cancel("save")
            assertTrue(busy(h))
            assertTrue(h.replies.isEmpty())
            assertEquals(true, h.calls.snapshot()["draining"])
            release.countDown()
            executor.submit { }.get(5, TimeUnit.SECONDS)
            h.drain()
            assertFalse(busy(h))
            assertEquals("saved", status(h))
            assertEquals(true, h.replies.single()["retired"])
            assertEquals("cancelled", (h.replies.single()["retirement"] as Map<*, *>)["status"])
            assertNull(h.replies.single()["errorCode"])
            assertEquals(candidate.parts, f.files.prepareImport(bytes.toByteArray().inputStream(), BackupFiles.Operation(BackupLease())).parts)
        } finally { release.countDown(); executor.shutdownNow() }
    }

    @Test fun actualCloseFailureAfterCancellationKeepsItsWholeCauseAndSuppressedCleanup() = BackupFixture.use { f ->
        val h = Harness(f)
        val failure = IOException("provider original", IOException("provider original cause"))
        failure.addSuppressed(IOException("provider suppressed cleanup"))
        h.output = { object : ByteArrayOutputStream() {
            override fun close() { h.calls.cancel("save"); throw failure }
        } }
        h.save(f.candidate())
        h.select(); h.documents()
        assertEquals("failed", status(h))
        assertEquals(true, h.replies.single()["retired"])
        val detail = h.replies.single()["errorDetail"].toString()
        for (text in listOf("provider original", "provider original cause", "provider suppressed cleanup")) assertTrue(detail.contains(text))
    }

    @Test fun discardWaitsForRealCleanupAndItsFailureCannotEraseTheSavedExternalDocument() {
        var failCleanup = false
        val failure = IOException("original candidate cleanup fsync failure")
        BackupFixture.use(sync = { fd -> if (failCleanup) throw failure; android.system.Os.fsync(fd) }) { f ->
            val candidate = f.candidate()
            val output = ByteArrayOutputStream()
            val h = Harness(f)
            h.output = { output }
            h.save(candidate)
            h.select()
            var cleanupReply: Throwable? = null
            var callbacks = 0
            h.calls.discardCandidate(candidate.token) { cleanupReply = it; callbacks++ }
            h.documents()
            assertTrue(h.replies.isEmpty())
            assertEquals(0, callbacks)
            assertTrue(busy(h))
            failCleanup = true
            h.storage()
            assertSame(failure, cleanupReply)
            assertEquals(1, callbacks)
            assertEquals("saved", status(h))
            assertTrue(h.replies.single()["cleanupError"].toString().contains(failure.message!!))
            assertEquals("backupCleanupFailed", h.calls.snapshot()["errorCode"])
            assertTrue(h.calls.snapshot()["errorDetail"].toString().contains(failure.message!!))
            assertTrue(output.size() > 0)
            failCleanup = false
            assertEquals(candidate.parts, f.files.prepareImport(output.toByteArray().inputStream(), BackupFiles.Operation(BackupLease())).parts)
            h.calls.discardCandidate(candidate.token) { assertNull(it); callbacks++ }
            h.storage()
            assertEquals(2, callbacks)
            assertFalse(File(f.privateRoot, "candidates/${candidate.token}").exists())
        }
    }

    @Test fun rejectedStorageAndDocumentWorkersReturnTheirActualCausesWithoutOrphaningWaiters() = BackupFixture.use { f ->
        val cause = java.util.concurrent.RejectedExecutionException("original worker refusal")
        val rejected = Executor { throw cause }
        val capture = Harness(f, realStorageWorker = rejected)
        capture.calls.prepareExport("rejected-capture", 1L, f.storage.snapshot().epoch, defaults(), BackupLease(), capture::reply)
        assertEquals("failed", status(capture))
        assertTrue(capture.replies.single()["errorDetail"].toString().contains(cause.message!!))
        assertFalse(busy(capture))
        val document = Harness(f, rejected)
        document.calls.pickImport("rejected-document", document::reply)
        document.select()
        assertEquals("failed", status(document))
        assertTrue(document.replies.single()["errorDetail"].toString().contains(cause.message!!))
        assertFalse(busy(document))
    }

    @Test fun launchOpenAndArchiveErrorsAreExplicitAndMissingActivityNeverStartsWork() = BackupFixture.use { f ->
        val h = Harness(f)
        h.calls.detach(h.host)
        h.calls.pickImport("missing", h::reply)
        assertEquals("backupNoActivity", h.replies.last()["errorCode"])
        h.calls.attach(h.host)
        h.launchError = true
        h.calls.pickImport("launch", h::reply)
        assertEquals("backupPickerUnavailable", h.replies.last()["errorCode"])
        assertTrue(h.replies.last()["errorDetail"].toString().contains("Injected missing picker"))
        assertFalse(busy(h))
        h.launchError = false
        h.calls.pickImport("open", h::reply)
        h.select()
        h.documents()
        assertEquals("backupDocumentIoFailed", h.replies.last()["errorCode"])
        assertTrue(h.replies.last()["errorDetail"].toString().contains("No fixture input"))
        h.input = { "not a ZIP".byteInputStream() }
        h.calls.pickImport("invalid", h::reply)
        h.select()
        h.documents()
        assertEquals("failed", status(h))
        assertFalse(busy(h))
    }
}
