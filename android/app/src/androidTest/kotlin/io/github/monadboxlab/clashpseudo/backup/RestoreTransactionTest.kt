package io.github.monadboxlab.clashpseudo.backup

import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.IOException
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class RestoreTransactionTest {
    private class InterruptedProcess : Error("injected process interruption")
    private val fresh get() = BackupFixture.values().mapValues { it.value.toList() }
    private fun assertNoTemps(f: BackupFixture) = assertTrue(f.stores.list()!!.none { it.startsWith(".restore-") })
    private fun restart(f: BackupFixture, steps: (String) -> Unit = {}) = BackupFiles(f.stores, f.privateRoot, steps).transaction

    @Test fun startupGateIsClosedUntilMechanicalRecoveryAndInstallInvalidatesOldEpoch() = BackupFixture.use { f ->
        val unopened = BackupFiles(f.stores, f.privateRoot).transaction
        assertFalse(unopened.snapshot().ready)
        backupRejects<IOException> { unopened.requireEpoch(0) }
        f.old()
        val epoch = f.storage.snapshot().epoch
        val result = f.storage.install(f.candidate().token, epoch, BackupFiles.Operation(BackupLease()))
        assertEquals(true, result.committed)
        assertTrue(result.ready)
        assertEquals(fresh, f.current())
        assertTrue(result.epoch > epoch)
        backupRejects<IOException> { f.storage.requireEpoch(epoch) }
        f.storage.requireEpoch(result.epoch)
        assertNoTemps(f)
    }

    @Test fun everyPersistentPreparationAndCommitStepCanBeInterruptedAndRecoveredAsAWhole() {
        val steps = mutableListOf<String>()
        BackupFixture.use(steps = { steps += it }) { f ->
            f.old()
            f.storage.install(f.candidate().token, f.storage.snapshot().epoch, BackupFiles.Operation(BackupLease()))
        }
        val expected = setOf("prepare.directory", "prepare.materialsSynced", "prepare.journalFile", "prepare.journalRename",
            "prepare.journalDirectory", "PREPARED.file", "PREPARED.rename", "PREPARED.directory", "COMMITTED.file",
            "COMMITTED.rename", "COMMITTED.directory", "retire.rename", "retire.directory", "retire.cleaned") +
            (0..2).flatMap { listOf("prepare.new.$it", "prepare.old.$it", "commit.rename.$it", "commit.directory.$it", "commit.sourceDirectory.$it") }
        assertEquals(expected, steps.toSet())
        assertEquals(expected.size, steps.size)
        println("Restore process-interruption boundaries checked: ${steps.size}")
        for (point in steps.distinct()) {
            var armed = false
            BackupFixture.use(steps = { if (armed && it == point) { armed = false; throw InterruptedProcess() } }) { f ->
                f.old()
                val old = f.current()
                val candidate = f.candidate()
                armed = true
                backupRejects<InterruptedProcess> { f.storage.install(candidate.token, f.storage.snapshot().epoch, BackupFiles.Operation(BackupLease())) }
                assertFalse("Gate must close at $point", f.storage.snapshot().ready)
                val recovered = restart(f)
                recovered.recover()
                val newExpected = point == "COMMITTED.rename" || point == "COMMITTED.directory" || point.startsWith("retire.")
                assertEquals("Whole-state recovery after $point", if (newExpected) fresh else old, f.current())
                assertTrue(recovered.snapshot().ready)
                assertNoTemps(f)
            }
        }
    }

    @Test fun rollbackCanItselfBeInterruptedAtEveryStepWithoutConsumingOldCopies() {
        fun leavePrepared(f: BackupFixture) {
            val candidate = f.candidate()
            backupRejects<InterruptedProcess> {
                f.storage.install(candidate.token, f.storage.snapshot().epoch, BackupFiles.Operation(BackupLease()))
            }
        }
        val rollbackSteps = mutableListOf<String>()
        var breakCommit = false
        BackupFixture.use(steps = { if (breakCommit && it == "commit.directory.1") { breakCommit = false; throw InterruptedProcess() } }) { f ->
            f.old(); breakCommit = true; leavePrepared(f)
            restart(f) { rollbackSteps += it }.recover()
        }
        val expected = setOf("retire.rename", "retire.directory", "retire.cleaned") +
            (0..2).flatMap { listOf("rollback.copy.$it", "rollback.rename.$it", "rollback.directory.$it") }
        assertEquals(expected, rollbackSteps.toSet())
        assertEquals(expected.size, rollbackSteps.size)
        println("Repeated rollback interruption boundaries checked: ${rollbackSteps.size}")
        for (point in rollbackSteps.distinct()) {
            var armed = false
            BackupFixture.use(steps = { if (armed && it == "commit.directory.1") { armed = false; throw InterruptedProcess() } }) { f ->
                f.old()
                val old = f.current()
                armed = true
                leavePrepared(f)
                var second = true
                val interrupted = restart(f) {
                    if (second && it == point) { second = false; throw InterruptedProcess() }
                }
                backupRejects<InterruptedProcess> { interrupted.recover() }
                assertFalse(interrupted.snapshot().ready)
                val final = restart(f)
                final.recover()
                assertEquals("Repeatable rollback after $point", old, f.current())
                assertTrue(final.snapshot().ready)
                assertNoTemps(f)
            }
        }
    }

    @Test fun rollbackRestoresAbsenceAndDamagedOriginalBytesWithoutTouchingOtherFiles() {
        var armed = false
        BackupFixture.use(steps = { if (armed && it == "commit.directory.2") { armed = false; throw InterruptedProcess() } }) { f ->
            f.old(mapOf(BackupFiles.Kind.CONFIGURATIONS to byteArrayOf(0xff.toByte(), 0, 1),
                BackupFiles.Kind.OVERRIDES to null, BackupFiles.Kind.PREFERENCES to null))
            val old = f.current()
            val unrelated = File(f.stores, "unrelated").apply { writeText("keep") }
            val candidate = f.candidate()
            armed = true
            backupRejects<InterruptedProcess> { f.storage.install(candidate.token, f.storage.snapshot().epoch, BackupFiles.Operation(BackupLease())) }
            restart(f).recover()
            assertEquals(old, f.current())
            assertEquals("keep", unrelated.readText())
            assertNoTemps(f)
        }
    }

    @Test fun corruptJournalMissingRollbackMaterialAndBadMarkersCloseGateAndPreserveEvidence() {
        for (damage in listOf("journal", "old", "marker", "unexpected")) {
            var armed = false
            BackupFixture.use(steps = { if (armed && it == "commit.rename.0") { armed = false; throw InterruptedProcess() } }) { f ->
                f.old()
                val candidate = f.candidate()
                armed = true
                backupRejects<InterruptedProcess> { f.storage.install(candidate.token, f.storage.snapshot().epoch, BackupFiles.Operation(BackupLease())) }
                val active = File(f.privateRoot, "restore-active")
                when (damage) {
                    "journal" -> File(active, "journal.bin").writeBytes(byteArrayOf(1, 2, 3))
                    "old" -> check(File(active, "old-0").delete())
                    "marker" -> File(active, "PREPARED").writeText("bad marker")
                    "unexpected" -> File(active, "unknown").writeText("keep evidence")
                }
                val before = f.current()
                val recovered = restart(f)
                backupRejects<Exception> { recovered.recover() }
                assertFalse(recovered.snapshot().ready)
                assertEquals(before, f.current())
                assertTrue(active.isDirectory)
                backupRejects<IOException> { recovered.requireEpoch(recovered.snapshot().epoch) }
            }
        }
    }

    @Test fun exceptionAfterRetirementStillReportsTheCommittedNewState() {
        for (point in listOf("retire.rename", "retire.directory", "retire.cleaned")) {
            var armed = false
            BackupFixture.use(steps = { if (armed && it == point) { armed = false; throw IOException("injected post-commit I/O failure") } }) { f ->
                f.old(); val candidate = f.candidate(); armed = true
                val result = f.storage.install(candidate.token, f.storage.snapshot().epoch, BackupFiles.Operation(BackupLease()))
                assertEquals("Actual commit must not be lost at $point", true, result.committed)
                assertTrue(result.ready)
                assertNotNull(result.cause)
                assertEquals(fresh, f.current())
            }
        }
    }

    @Test fun everyFileAndDirectoryFsyncFailureHasAWholeRecoverableOutcome() {
        var counting = false
        var total = 0
        BackupFixture.use(sync = { fd -> if (counting) total++; Os.fsync(fd) }) { f ->
            f.old(); val candidate = f.candidate(); counting = true
            f.storage.install(candidate.token, f.storage.snapshot().epoch, BackupFiles.Operation(BackupLease()))
        }
        assertEquals(23, total)
        println("Restore file/directory fsync failure positions checked: $total")
        for (failAt in 1..total) {
            var armed = false
            var count = 0
            BackupFixture.use(sync = { fd ->
                if (armed && ++count == failAt) throw IOException("injected fsync failure $failAt")
                Os.fsync(fd)
            }) { f ->
                f.old(); val old = f.current(); val candidate = f.candidate(); armed = true
                val result = f.storage.install(candidate.token, f.storage.snapshot().epoch, BackupFiles.Operation(BackupLease()))
                assertTrue("Recovery after fsync $failAt: $result", result.ready)
                assertNotNull(result.committed)
                assertEquals(if (result.committed == true) fresh else old, f.current())
                assertNoTemps(f)
            }
        }
    }

    @Test fun cancelledPreparedAdmissionReturnsTheRealRollbackInsteadOfLosingItInAnException() = BackupFixture.use { f ->
        f.old()
        val old = f.current()
        val candidate = f.candidate()
        val owner = BackupLease()
        owner.beforeAdmission = { owner.cancel() }
        val result = f.storage.install(candidate.token, f.storage.snapshot().epoch, BackupFiles.Operation(owner))
        assertEquals(false, result.committed)
        assertTrue(result.rolledBack)
        assertTrue(result.ready)
        assertEquals("restoreCancelled", result.error)
        assertEquals(old, f.current())
        assertNoTemps(f)
    }

    @Test fun cancellationBeforeAdmissionRollsBackButAfterAdmissionCannotInterruptMechanicalCommit() {
        var cancelDuringPreparation = false
        val preparing = BackupLease()
        BackupFixture.use(steps = { if (cancelDuringPreparation && it == "prepare.new.0") preparing.cancel() }) { f ->
            f.old(); val old = f.current(); val candidate = f.candidate(); cancelDuringPreparation = true
            val cancelled = f.storage.install(candidate.token, f.storage.snapshot().epoch, BackupFiles.Operation(preparing))
            assertEquals(false, cancelled.committed)
            assertFalse(cancelled.rolledBack) // no PREPARED journal/formal replacement existed yet
            assertEquals("restoreCancelled", cancelled.error)
            assertTrue(f.storage.snapshot().ready)
            assertEquals(old, f.current())
        }
        BackupFixture.use { f ->
            f.old(); val candidate = f.candidate()
            var time = 0L
            val owner = BackupLease().apply { afterAdmission = { cancel(); time = 300_001L } }
            val result = f.storage.install(candidate.token, f.storage.snapshot().epoch, BackupFiles.Operation(owner) { time })
            assertEquals(true, result.committed)
            assertEquals(fresh, f.current())
        }
    }

    @Test fun ordinaryPublicationSharesTheSameEpochAndCancellationAdmission() = BackupFixture.use { f ->
        f.old()
        val kind = BackupFiles.Kind.CONFIGURATIONS
        val target = File(f.stores, kind.fileName)
        val temporary = File(f.stores, "${kind.fileName}.tmp")
        val old = target.readBytes()
        temporary.writeText("next saved bytes")
        val cancelled = BackupLease().apply { beforeAdmission = { cancel() } }
        backupRejects<CancellationException> { f.storage.publishStore(kind, f.storage.snapshot().epoch, cancelled) }
        assertArrayEquals(old, target.readBytes())
        assertTrue(temporary.exists())
        val commitWins = BackupLease().apply { afterAdmission = { cancel() } }
        val result = f.storage.publishStore(kind, f.storage.snapshot().epoch, commitWins)
        assertTrue(result.saved && result.durable)
        assertEquals("next saved bytes", target.readText())
        assertFalse(temporary.exists())
        val epoch = f.storage.snapshot().epoch
        val candidate = f.candidate()
        f.storage.install(candidate.token, epoch, BackupFiles.Operation(BackupLease()))
        temporary.writeText("stale draft with the same ID/revision")
        backupRejects<IOException> { f.storage.publishStore(kind, epoch, BackupLease()) }
        assertArrayEquals(BackupFixture.values().getValue(kind), target.readBytes())
    }

    @Test fun directorySyncFailureAfterOrdinaryRenameStillReportsSaved() {
        var armed = false
        BackupFixture.use(sync = { descriptor ->
            if (armed && OsConstants.S_ISDIR(Os.fstat(descriptor).st_mode)) throw IOException("injected directory sync failure")
            Os.fsync(descriptor)
        }) { f ->
            f.old()
            val kind = BackupFiles.Kind.PREFERENCES
            File(f.stores, "${kind.fileName}.tmp").writeText("published")
            armed = true
            val result = f.storage.publishStore(kind, f.storage.snapshot().epoch, BackupLease())
            assertTrue(result.saved)
            assertFalse(result.durable)
            assertEquals("publishedDirectorySyncFailed", result.error)
            assertNotNull(result.cause)
            assertEquals("published", File(f.stores, kind.fileName).readText())
        }
    }

    @Test fun linkedStagingAndFormalTargetsNeverFollowOrOverwriteOtherData() = BackupFixture.use { f ->
        f.old()
        val kind = BackupFiles.Kind.CONFIGURATIONS
        val outside = File(f.root, "outside").apply { writeText("untouched") }
        val temporary = File(f.stores, "${kind.fileName}.tmp")
        Os.symlink(outside.path, temporary.path)
        try { backupRejects<Exception> { f.storage.publishStore(kind, f.storage.snapshot().epoch, BackupLease()) } }
        finally { Os.remove(temporary.path) }
        val target = File(f.stores, kind.fileName)
        check(target.delete()); Os.symlink(outside.path, target.path)
        temporary.writeText("not published")
        try { backupRejects<IOException> { f.storage.publishStore(kind, f.storage.snapshot().epoch, BackupLease()) } }
        finally { Os.remove(target.path) }
        assertEquals("untouched", outside.readText())
    }

    @Test fun oneGateBlocksRestoreAndPublicationUntilConsistentReaderActuallyExits() = BackupFixture.use { f ->
        f.old()
        val candidate = f.candidate()
        val epoch = f.storage.snapshot().epoch
        val kind = BackupFiles.Kind.PREFERENCES
        File(f.stores, "${kind.fileName}.tmp").writeText("new")
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val pool = Executors.newSingleThreadExecutor()
        try {
            val reader = pool.submit {
                f.storage.withStableStorage(epoch) { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            backupRejects<IOException> { f.storage.publishStore(kind, epoch, BackupLease()) }
            backupRejects<IOException> { f.storage.install(candidate.token, epoch, BackupFiles.Operation(BackupLease())) }
            // A second instance must acquire the same physical file lock.
            backupRejects<IOException> { restart(f).recover() }
            release.countDown(); reader.get(5, TimeUnit.SECONDS)
            assertTrue(f.storage.publishStore(kind, epoch, BackupLease()).saved)
        } finally { release.countDown(); pool.shutdownNow() }
    }

    @Test fun fileIoLaneIsOneStableWorkerIndependentOfTheCallingThread() = BackupFixture.use { f ->
        val lane = f.files.ioExecutor
        assertSame(lane, f.files.ioExecutor)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val second = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val threads = java.util.concurrent.CopyOnWriteArrayList<Thread>()
        lane.execute {
            try { threads += Thread.currentThread(); entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
            finally { finished.countDown() }
        }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            lane.execute { threads += Thread.currentThread(); second.countDown() }
            assertFalse(second.await(100, TimeUnit.MILLISECONDS))
            // File I/O runs on the dedicated storage lane.
            assertNotSame(Thread.currentThread(), threads.single())
            assertEquals("pseudo-storage-io", threads.single().name)
            release.countDown()
            assertTrue(second.await(5, TimeUnit.SECONDS))
            assertSame(threads[0], threads[1])
        } finally { release.countDown(); check(finished.await(5, TimeUnit.SECONDS)) }
    }

    @Test fun candidateLeaseIsRetainedUntilActualReadReturnsBeforeDiscard() = BackupFixture.use { f ->
        val candidate = f.candidate()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2)
        try {
            val reading = pool.submit {
                f.files.withPart(candidate.token, BackupFiles.Kind.CONFIGURATIONS, BackupFiles.Operation(BackupLease())) {
                    entered.countDown(); check(release.await(10, TimeUnit.SECONDS)); it.readBytes()
                }
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val discardEntered = CountDownLatch(1)
            val discarding = pool.submit { discardEntered.countDown(); f.files.discard(candidate.token) }
            assertTrue(discardEntered.await(5, TimeUnit.SECONDS))
            backupRejects<java.util.concurrent.TimeoutException> { discarding.get(100, TimeUnit.MILLISECONDS) }
            release.countDown(); reading.get(5, TimeUnit.SECONDS); discarding.get(5, TimeUnit.SECONDS)
            backupRejects<IOException> { f.files.candidate(candidate.token) }
        } finally { release.countDown(); pool.shutdownNow() }
    }
}
