package io.github.monadboxlab.clashpseudo.backup

import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class ColdStartupStorageTest {
    @Test fun recoveryPrecedesOrphanRemovalAndKeepsSystemInputInstallationMarkersAndUnrelatedFiles() {
        var interrupt = false
        BackupFixture.use(steps = { if (interrupt && it == "commit.rename.0") throw Error("process interrupted") }) { f ->
            f.old()
            val old = f.current()
            val candidate = f.candidate()
            val orphan = File(f.privateRoot, "candidates/${candidate.token}")
            val work = File(f.root, "work").apply { check(mkdir()) }
            val run = File(work, "run-input-old-owner.json").apply { writeText("old raw input") }
            val runTemporary = File(work, "run-input-old-owner.json.tmp").apply { writeText("partial input") }
            val systemTemporary = File(work, "system-input.json.tmp").apply { writeText("unpublished system input") }
            val cleanupTemporary = File(f.root, "core-cleanup.json.tmp").apply { writeText("unpublished request") }
            val core = File(f.root, "mihomo").apply { check(mkdir()) }
            val geoTemporary = File(core, ".bundled-geo-old-owner.tmp").apply { writeText("partial Geo") }
            val kept = listOf(
                File(core, "GeoSite.dat"), File(core, "cache.db"), File(core, "unrelated.tmp"),
                File(work, "system-input.json"), File(work, "unrelated.json"),
                File(f.root, "privacy-notice-shown"), File(f.root, "core-cleanup.json"),
                File(f.stores, "unrelated.tmp"),
            ).associateWith { file -> "original ${file.name} 原文🙂".also { file.writeText(it) } }
            interrupt = true
            backupRejects<Error> {
                f.storage.install(candidate.token, f.storage.snapshot().epoch, BackupFiles.Operation(BackupLease()))
            }
            val staged = BackupFiles.Kind.entries.map { kind ->
                File(f.stores, "${kind.fileName}.tmp").apply { writeText("unpublished ${kind.name}") }
            }
            val restarted = BackupFiles(f.stores, f.privateRoot)
            val state = restarted.transaction.recover {
                assertFalse(restarted.transaction.snapshot().ready)
                assertEquals(old, f.current())
                assertFalse(File(f.privateRoot, "restore-active").exists())
                assertTrue(orphan.isDirectory)
                restarted.cleanupOrphans(work, File(f.root, "mihomo"))
            }
            assertTrue(state.ready)
            assertNull(state.issue)
            assertEquals(old, f.current())
            for (file in staged + listOf(orphan, run, runTemporary, systemTemporary, cleanupTemporary, geoTemporary)) {
                assertFalse(file.path, file.exists())
            }
            kept.forEach { (file, body) -> assertEquals(body, file.readText()) }
            assertTrue(restarted.transaction.recover { restarted.cleanupOrphans(work, File(f.root, "mihomo")) }.ready)
            kept.forEach { (file, body) -> assertEquals(body, file.readText()) }
        }
    }

    @Test fun anUnrecoverableJournalKeepsEveryRecoveryAndOrphanFileAndItsCompleteCause() = BackupFixture.use { f ->
        f.old()
        val original = f.current()
        val candidate = f.candidate()
        val active = File(f.privateRoot, "restore-active").apply { check(mkdir()) }
        val journal = File(active, "journal.bin").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val work = File(f.root, "work").apply { check(mkdir()) }
        val run = File(work, "run-input-old.json").apply { writeText("keep until recovery") }
        val temporary = File(f.stores, "preferences.json.tmp").apply { writeText("keep until recovery") }
        val core = File(f.root, "mihomo").apply { check(mkdir()) }
        val otherTemporary = listOf(File(core, ".bundled-geo-old.tmp"), File(f.root, "core-cleanup.json.tmp"))
            .onEach { it.writeText("keep until recovery") }
        val restarted = BackupFiles(f.stores, f.privateRoot)
        var cleanupCalls = 0
        backupRejects<IOException> {
            restarted.transaction.recover { cleanupCalls++; restarted.cleanupOrphans(work, File(f.root, "mihomo")) }
        }
        assertEquals(0, cleanupCalls)
        val state = restarted.transaction.snapshot()
        assertFalse(state.ready)
        assertFalse(state.restoring)
        assertEquals("storageUnavailable", state.issue!!.id)
        assertTrue(state.issue!!.detail!!.contains("EOFException"))
        assertArrayEquals(byteArrayOf(1, 2, 3), journal.readBytes())
        assertEquals(original, f.current())
        assertTrue(File(f.privateRoot, "candidates/${candidate.token}").isDirectory)
        assertEquals("keep until recovery", run.readText())
        assertEquals("keep until recovery", temporary.readText())
        otherTemporary.forEach { assertEquals("keep until recovery", it.readText()) }
    }

    @Test fun cleanupFailureRetainsItsCauseWithoutClosingRecoveredBusinessStorage() = BackupFixture.use { f ->
        f.old()
        val old = f.current()
        val work = File(f.root, "work").apply { check(mkdir()) }
        val run = File(work, "run-input-old.json").apply { writeText("old input") }
        val system = File(work, "system-input.json").apply { writeText("saved system input") }
        val failure = IOException("directory sync 原文🙂", IOException("original cause"))
            .apply { addSuppressed(IOException("original cleanup detail")) }
        val restarted = BackupFiles(f.stores, f.privateRoot, sync = { descriptor ->
            if (OsConstants.S_ISDIR(Os.fstat(descriptor).st_mode)) throw failure
            Os.fsync(descriptor)
        })
        val state = restarted.transaction.recover { restarted.cleanupOrphans(work, File(f.root, "mihomo")) }
        assertTrue(state.ready)
        assertEquals("storageCleanupFailed", state.issue!!.id)
        assertEquals(failure.stackTraceToString(), state.issue!!.detail)
        assertFalse(run.exists())
        assertEquals("saved system input", system.readText())
        assertEquals(old, f.current())
        restarted.transaction.withStableStorage(state.epoch) { assertEquals(old, f.current()) }
    }

    @Test fun cleanupNeverTraversesLinkedCandidateOrWorkRoots() = BackupFixture.use { f ->
        f.old()
        val old = f.current()
        val outside = File(f.root, "outside").apply { check(mkdir()) }
        val kept = File(outside, "run-input-keep.json").apply { writeText("outside original") }
        val candidates = File(f.privateRoot, "candidates")
        val work = File(f.root, "work")
        val core = File(f.root, "mihomo")
        val geo = File(outside, ".bundled-geo-keep.tmp").apply { writeText("outside Geo") }
        Os.symlink(outside.path, candidates.path)
        Os.symlink(outside.path, work.path)
        Os.symlink(outside.path, core.path)
        try {
            val state = f.storage.recover { f.files.cleanupOrphans(work, File(f.root, "mihomo")) }
            assertTrue(state.ready)
            assertEquals("storageCleanupFailed", state.issue!!.id)
            assertTrue(state.issue!!.detail!!.contains("Suppressed:"))
            assertEquals("outside original", kept.readText())
            assertEquals("outside Geo", geo.readText())
            assertEquals(old, f.current())
        } finally {
            Os.remove(candidates.path)
            Os.remove(work.path)
            Os.remove(core.path)
        }
    }
}
