package io.github.monadboxlab.clashpseudo.app

import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import io.github.monadboxlab.clashpseudo.backup.BackupFixture
import io.github.monadboxlab.clashpseudo.backup.BackupLease
import io.github.monadboxlab.clashpseudo.backup.backupRejects
import io.github.monadboxlab.clashpseudo.fixture.HardlinkPrerequisites

import android.app.backup.BackupAgent
import android.app.backup.FullBackupDataOutput
import android.os.ParcelFileDescriptor
import android.system.Os
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

/**
 * Tests the shared file gate with isolated data and explicit framework transport
 * doubles.
 */
class PseudoBackupAgentTest {
    private class Agent(private val files: BackupFiles) : PseudoBackupAgent() {
        var backups = 0
        var restores = 0
        var beforeBackup: () -> Unit = {}
        var beforeRestore: (File) -> Unit = {}
        var failRestore = false
        var shortRestore = false
        override fun backupFiles() = files
        override fun frameworkBackup(data: FullBackupDataOutput?) { beforeBackup(); backups++ }
        override fun frameworkRestore(data: ParcelFileDescriptor, size: Long, target: File,
            type: Int, mode: Long, mtime: Long) {
            beforeRestore(target)
            restores++
            if (failRestore) { target.writeText("partial SDK bytes"); throw IOException("injected SDK restore failure") }
            ParcelFileDescriptor.dup(data.fileDescriptor).use { borrowed ->
                ParcelFileDescriptor.AutoCloseInputStream(borrowed).use { input ->
                    target.outputStream().use { output ->
                        var remaining = if (shortRestore) size - 1 else size
                        val buffer = ByteArray(32768)
                        while (remaining > 0) {
                            val count = input.read(buffer, 0, minOf(remaining, buffer.size.toLong()).toInt())
                            if (count < 0) throw IOException("fixture EOF")
                            output.write(buffer, 0, count)
                            remaining -= count
                        }
                    }
                }
            }
        }
    }
    private fun restore(f: BackupFixture, agent: Agent, kind: BackupFiles.Kind, bytes: ByteArray,
        destination: File = File(f.stores, kind.fileName), type: Int = BackupAgent.TYPE_FILE,
        trailer: ByteArray = byteArrayOf()): ByteArray {
        val source = File(f.root, "system-source-${UUID.randomUUID()}").apply { writeBytes(bytes + trailer) }
        return ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY).use { data ->
            agent.onRestoreFile(data, bytes.size.toLong(), destination, type, 0x180, 123L)
            assertTrue("Framework retains ownership of its PFD", data.fileDescriptor.valid())
            ParcelFileDescriptor.dup(data.fileDescriptor).use { reader ->
                ParcelFileDescriptor.AutoCloseInputStream(reader).use { it.readBytes() }
            }
        }
    }

    @Test fun readyFullBackupPreservesEpochAndUsesTheSharedConsistentReadGate() = BackupFixture.use { f ->
        f.old()
        val epoch = f.storage.snapshot().epoch
        val kind = BackupFiles.Kind.PREFERENCES
        File(f.stores, "${kind.fileName}.tmp").writeText("not published during backup")
        val before = f.current()
        val agent = Agent(f.files)
        agent.beforeBackup = {
            assertTrue(f.storage.snapshot().ready)
            backupRejects<IOException> { f.storage.publishStore(kind, epoch, BackupLease()) }
        }
        repeat(2) { agent.onFullBackup(null) }
        assertEquals(2, agent.backups)
        assertEquals(epoch, f.storage.snapshot().epoch)
        assertEquals(before, f.current())
    }

    @Test fun fullBackupInitializesMechanicalReadinessWithoutApplicationStartup() = BackupFixture.use { f ->
        val independent = BackupFiles(File(f.root, "separate-stores"), File(f.root, "separate-private"))
        assertFalse(independent.transaction.snapshot().ready)
        val agent = Agent(independent)
        agent.beforeBackup = { assertTrue(independent.transaction.snapshot().ready) }
        agent.onFullBackup(null)
        assertEquals(1, agent.backups)
        assertTrue(independent.transaction.snapshot().ready)
    }

    @Test fun publicSdkCallbacksReportActualErrnoAsIOExceptionWithoutHidingItsCause() = BackupFixture.use { f ->
        val agent = Agent(f.files)
        agent.beforeBackup = { Os.open(File(f.root, "missing").path, android.system.OsConstants.O_RDONLY, 0) }
        try {
            agent.onFullBackup(null)
            fail("Expected SDK IOException")
        } catch (error: IOException) {
            assertTrue(error.cause is android.system.ErrnoException)
        }
        assertTrue(f.storage.snapshot().ready) // A failed read-only backup did not change business files.
    }

    @Test fun fullBackupCannotStealAnActiveSystemRestore() = BackupFixture.use { f ->
        val epoch = f.storage.beginSystemRestore()
        val agent = Agent(f.files)
        backupRejects<IOException> { agent.onFullBackup(null) }
        backupRejects<IOException> { f.storage.recover() }
        assertEquals(epoch, f.storage.snapshot().epoch)
        assertTrue(f.storage.snapshot().systemRestore)
        f.storage.abandonSystemRestore(epoch)
    }

    @Test fun sdkPerFileRestoresStayClosedUntilFinishAndDoNotPretendToBeAThreeFileTransaction() = BackupFixture.use { f ->
        f.old()
        val old = f.current()
        val epoch = f.storage.snapshot().epoch
        val agent = Agent(f.files)
        agent.beforeRestore = { target ->
            assertTrue(f.storage.snapshot().restoring)
            assertFalse(f.storage.snapshot().ready)
            assertEquals(f.stores, target.parentFile)
            backupRejects<IOException> { f.storage.requireEpoch(epoch) }
        }
        for ((index, kind) in BackupFiles.Kind.entries.withIndex()) {
            restore(f, agent, kind, BackupFixture.values().getValue(kind))
            assertFalse(f.storage.snapshot().ready)
            if (index == 0) assertEquals(old.getValue(BackupFiles.Kind.OVERRIDES), f.current()[BackupFiles.Kind.OVERRIDES])
        }
        agent.onRestoreFinished()
        assertEquals(3, agent.restores)
        assertTrue(f.storage.snapshot().ready)
        assertFalse(f.storage.snapshot().systemRestore)
        assertEquals(epoch + 2, f.storage.snapshot().epoch)
        assertEquals(BackupFixture.values().mapValues { it.value.toList() }, f.current())
    }

    @Test fun oldPreparedAndCommittedLocalJournalsAreRetiredBeforeTheFirstSdkFile() {
        class Interruption : Error()
        for (point in listOf("PREPARED.directory", "COMMITTED.directory")) {
            var armed = false
            BackupFixture.use(steps = { if (armed && it == point) { armed = false; throw Interruption() } }) { f ->
                f.old()
                val candidate = f.candidate()
                armed = true
                backupRejects<Interruption> { f.storage.install(candidate.token, f.storage.snapshot().epoch, BackupFiles.Operation(BackupLease())) }
                assertTrue(File(f.privateRoot, "restore-active").exists())
                val agent = Agent(f.files)
                agent.beforeRestore = { assertFalse(File(f.privateRoot, "restore-active").exists()) }
                val kind = BackupFiles.Kind.CONFIGURATIONS
                val systemBytes = "{\"entries\":[],\"selectedId\":null,\"mode\":null}".toByteArray()
                restore(f, agent, kind, systemBytes)
                agent.onRestoreFinished()
                val afterSystemRestore = f.current()
                // A subsequent boot preserves the result of system restore.
                BackupFiles(f.stores, f.privateRoot).transaction.recover()
                assertEquals(afterSystemRestore, f.current())
                assertArrayEquals(systemBytes, File(f.stores, kind.fileName).readBytes())
            }
        }
    }

    @Test fun managedFilesAreRestoredOnTheSupportedSdkAndUnmanagedEntriesAreOnlyDrainedExactly() = BackupFixture.use { f ->
        f.old()
        val agent = Agent(f.files)
        for (kind in BackupFiles.Kind.entries) {
            val remaining = restore(f, agent, kind, BackupFixture.values().getValue(kind), trailer = "next-entry".toByteArray())
            assertArrayEquals("next-entry".toByteArray(), remaining)
        }
        assertEquals(3, agent.restores)
        agent.onRestoreFinished()
        assertEquals(BackupFixture.values().mapValues { it.value.toList() }, f.current())
        val outside = File(f.root, "outside").apply { writeText("untouched") }
        val unmanaged = Agent(f.files)
        val remaining = restore(f, unmanaged, BackupFiles.Kind.PREFERENCES, "ignored".toByteArray(),
            destination = outside, trailer = "unmanaged-next-entry".toByteArray())
        assertArrayEquals("unmanaged-next-entry".toByteArray(), remaining)
        assertEquals("untouched", outside.readText())
        assertEquals(0, unmanaged.restores)
        unmanaged.onRestoreFinished()
    }

    @Test fun systemBusinessRestoreKeepsTheInstallationMarkerAndDrainsAnIncomingMarkerWithoutWritingIt() = BackupFixture.use { f ->
        f.old()
        val marker = File(f.root, "privacy-notice-shown").apply { writeBytes(byteArrayOf(1)) }
        val agent = Agent(f.files)
        for (kind in BackupFiles.Kind.entries) {
            restore(f, agent, kind, BackupFixture.values().getValue(kind))
            assertArrayEquals(byteArrayOf(1), marker.readBytes())
        }
        val trailer = "next-system-entry".toByteArray()
        val remaining = restore(f, agent, BackupFiles.Kind.PREFERENCES, byteArrayOf(0),
            destination = marker, trailer = trailer)
        assertArrayEquals(trailer, remaining)
        assertArrayEquals(byteArrayOf(1), marker.readBytes())
        assertEquals(3, agent.restores)
        agent.onRestoreFinished()
        assertTrue(f.storage.snapshot().ready)
        assertEquals(BackupFixture.values().mapValues { it.value.toList() }, f.current())
        assertArrayEquals(byteArrayOf(1), marker.readBytes())
    }

    @Test fun systemRestoreCannotImportOrOverwriteAnInstallationPrivacyMarkerAndStillDrainsItsEntryExactly() {
        for (shown in listOf(false, true)) BackupFixture.use { f ->
            f.old()
            val marker = File(f.root, "privacy-notice-shown")
            if (shown) marker.writeBytes(byteArrayOf(1))
            val agent = Agent(f.files)
            for (kind in BackupFiles.Kind.entries) restore(f, agent, kind, BackupFixture.values().getValue(kind))
            val remaining = restore(f, agent, BackupFiles.Kind.PREFERENCES, "foreign installation marker".toByteArray(),
                destination = marker, trailer = "next-system-entry".toByteArray())
            assertArrayEquals("next-system-entry".toByteArray(), remaining)
            assertEquals(3, agent.restores)
            assertEquals(shown, marker.exists())
            if (shown) assertArrayEquals(byteArrayOf(1), marker.readBytes())
            agent.onRestoreFinished()
            assertTrue(f.storage.snapshot().ready)
            assertEquals(BackupFixture.values().mapValues { it.value.toList() }, f.current())
            assertEquals(shown, marker.exists())
            if (shown) assertArrayEquals(byteArrayOf(1), marker.readBytes())
        }
    }

    @Test fun sdkFailureOrShortOutputKeepsGateClosedAndDoesNotRollBackNewSystemBytes() = BackupFixture.use { f ->
        for (short in listOf(false, true)) {
            f.storage.recover()
            f.old()
            val agent = Agent(f.files).apply { failRestore = !short; shortRestore = short }
            backupRejects<IOException> { restore(f, agent, BackupFiles.Kind.CONFIGURATIONS, "restored-by-SDK".toByteArray()) }
            assertFalse(f.storage.snapshot().ready)
            assertEquals("systemRestoreFailed", f.storage.snapshot().error)
            backupRejects<IllegalStateException> { agent.onRestoreFinished() }
            val partial = f.current()
            BackupFiles(f.stores, f.privateRoot).transaction.recover()
            assertEquals(partial, f.current())
            assertFalse(File(f.privateRoot, "restore-active").exists())
        }
    }

    @Test fun destructionDoesNotWaitForActualSdkIoAndCannotReopenTheGatePrematurely() = BackupFixture.use { f ->
        f.old()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val agent = Agent(f.files)
        agent.beforeRestore = { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
        val pool = Executors.newSingleThreadExecutor()
        try {
            val restoring = pool.submit {
                backupRejects<IOException> { restore(f, agent, BackupFiles.Kind.CONFIGURATIONS, "new-system-bytes".toByteArray()) }
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            agent.onDestroy()
            assertFalse(f.storage.snapshot().ready)
            assertEquals("systemRestoreIncomplete", f.storage.snapshot().error)
            backupRejects<IOException> { f.storage.recover() }
            release.countDown(); restoring.get(5, TimeUnit.SECONDS)
            assertFalse(f.storage.snapshot().ready)
            assertArrayEquals("new-system-bytes".toByteArray(), File(f.stores, BackupFiles.Kind.CONFIGURATIONS.fileName).readBytes())
        } finally { release.countDown(); pool.shutdownNow() }
    }

    @Test fun staleSystemDestructionCannotInvalidateANewerSystemEpoch(): Unit = BackupFixture.use { f ->
        val old = f.storage.beginSystemRestore()
        f.storage.abandonSystemRestore(old)
        f.storage.recover()
        val current = f.storage.beginSystemRestore()
        f.storage.abandonSystemRestore(old)
        assertTrue(f.storage.snapshot().restoring)
        assertTrue(f.storage.snapshot().systemRestore)
        assertEquals(current, f.storage.snapshot().epoch)
        f.storage.finishSystemRestore(current)
    }

    @Test fun hardLinkedBusinessTargetCannotModifyAnotherNameThroughSdkTruncation() = BackupFixture.use { f ->
        f.old()
        val outside = File(f.root, "outside-hardlink").apply { writeText("untouched") }
        val target = File(f.stores, BackupFiles.Kind.CONFIGURATIONS.fileName)
        check(target.delete())
        HardlinkPrerequisites.link(outside, target,
            "io.github.monadboxlab.clashpseudo.app.PseudoBackupAgentTest#hardLinkedBusinessTargetCannotModifyAnotherNameThroughSdkTruncation")
        val agent = Agent(f.files)
        backupRejects<IOException> { restore(f, agent, BackupFiles.Kind.CONFIGURATIONS, "must not overwrite".toByteArray()) }
        assertEquals(0, agent.restores)
        assertEquals("untouched", outside.readText())
        assertEquals("untouched", target.readText())
        assertFalse(f.storage.snapshot().ready)
    }

    @Test fun linkedBusinessTargetIsRejectedBeforeSdkIoAndOtherDataIsUntouched() = BackupFixture.use { f ->
        f.old()
        val outside = File(f.root, "outside").apply { writeText("untouched") }
        val target = File(f.stores, BackupFiles.Kind.CONFIGURATIONS.fileName)
        check(target.delete()); Os.symlink(outside.path, target.path)
        try {
            val agent = Agent(f.files)
            backupRejects<IOException> { restore(f, agent, BackupFiles.Kind.CONFIGURATIONS, "must not write".toByteArray()) }
            assertEquals(0, agent.restores)
            assertEquals("untouched", outside.readText())
            assertFalse(f.storage.snapshot().ready)
        } finally { Os.remove(target.path) }
    }
}
