package io.github.monadboxlab.clashpseudo.storage

import android.system.Os
import android.system.OsConstants
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.fixture.HardlinkPrerequisites
import io.github.monadboxlab.clashpseudo.nativecore.CorePrivateFiles
import io.github.monadboxlab.clashpseudo.nativecore.CoreRecordPublicationException
import io.github.monadboxlab.clashpseudo.nativecore.CoreResourceGate
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CancellationException

class CoreDataCleanupTest {
    private class Fixture(val directory: File) {
        val core = File(directory, "mihomo").apply { check(mkdir()) }
        val record = File(directory, "no-backup/core-cleanup.json").apply { check(parentFile!!.mkdir()) }
        val kept = listOf("stores/configurations.json", "stores/overrides.json", "stores/preferences.json",
            "system-input", "no-backup/privacy-notice", "backup/candidate/archive.zip").associate { name ->
            File(directory, name).apply { check(parentFile!!.isDirectory || parentFile!!.mkdirs()); writeText("original $name 原文") }.let { it to it.readText() }
        }
        fun file(name: String, body: String = "original $name") = File(core, name).apply {
            check(parentFile!!.isDirectory || parentFile!!.mkdirs()); writeText(body)
        }
        fun cleanup() = CoreDataCleanup(core, record)
        fun schedule(vararg paths: String) = cleanup().apply {
            initialize(); registerCandidates(paths.toList()); assertNull(schedule(CoreDataCleanup.Request(paths.toList())) { it() })
        }
        fun assertKept() { kept.forEach { (file, body) -> assertEquals(body, file.readText()) } }
    }
    private fun fixture(block: (Fixture) -> Unit) {
        val root = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir.canonicalFile, "cleanup-${UUID.randomUUID()}")
        check(root.mkdir())
        try { block(Fixture(root)) } finally { check(root.deleteRecursively()) }
    }
    private inline fun <reified T : Throwable> rejects(block: () -> Unit): T {
        try { block() } catch (error: Throwable) { if (error is T) return error else throw error }
        throw AssertionError("Must reject ${T::class.java.simpleName}")
    }
    private fun items(cleanup: CoreDataCleanup) = cleanup.snapshot()["files"] as List<Map<String, Any?>>

    @Test fun anAbsentRequestAllowsPreparationWithoutDeletingAnything() = fixture { f ->
        val database = f.file("cache.db")
        val cleanup = f.cleanup()
        assertFalse(cleanup.ready); rejects<IOException> { cleanup.requireReady() }
        cleanup.initialize(); cleanup.requireReady()
        assertEquals("idle", cleanup.snapshot()["status"])
        assertFalse(cleanup.pending); assertTrue(database.exists()); f.assertKept()
    }

    @Test fun schedulingRecordsExplicitFilesWithoutDeletingUntilDrain() = fixture { f ->
        val database = f.file("cache.db", "fake-ip and choices 原文")
        val geo = f.file("GeoSite.dat"); val provider = f.file("providers/remote.yaml"); val identity = f.file("state/node/identity")
        val cleanup = f.schedule("cache.db")
        assertEquals("fake-ip and choices 原文", database.readText())
        assertEquals(listOf("cache.db"), cleanup.snapshot()["paths"])
        assertEquals("scheduled", cleanup.snapshot()["status"])
        rejects<IOException> { cleanup.requireReady() }
        cleanup.initialize(); assertTrue(database.exists())
        val next = f.cleanup().apply { initialize() }
        next.requireReady(); assertEquals("completed", next.snapshot()["status"])
        assertFalse(database.exists()); assertFalse(f.record.exists())
        assertTrue(geo.exists()); assertTrue(provider.exists()); assertTrue(identity.exists()); f.assertKept()
    }

    @Test fun selectedGeoDeletesOnlyItsCapturedPublicRelativeFile() = fixture { f ->
        val selected = f.file("Geo完整 名.dat"); val database = f.file("cache.db")
        val sibling = f.file("other.dat"); val provider = f.file("providers/remote.yaml"); val identity = f.file("state/identity")
        val cleanup = f.cleanup().apply { initialize(); registerCandidates(listOf(selected.path)) }
        val request = cleanup.resource(selected.path)
        assertEquals(selected.name, request.relativePath)
        cleanup.schedule(request) { it() }; assertTrue(selected.exists())
        assertTrue(f.cleanup().apply { initialize() }.ready)
        assertFalse(selected.exists()); assertTrue(database.exists()); assertTrue(sibling.exists())
        assertTrue(provider.exists()); assertTrue(identity.exists()); f.assertKept()
    }

    @Test fun legacyAllRequiresSelectionAndNeverDeletesCoreOrUserFiles() = fixture { f ->
        val files = listOf("cache.db", "GeoIP.dat", "providers/remote.yaml", "state/node/identity", "user-file.txt").map { f.file(it) }
        f.record.writeText("{\"scope\":\"all\"}")
        val next = f.cleanup().apply { initialize() }
        assertFalse(next.ready); assertEquals("needsSelection", next.snapshot()["status"])
        assertTrue(f.record.exists()); files.forEach { assertTrue(it.exists()) }
        rejects<IllegalArgumentException> { CoreDataCleanup.Request("all") }; f.assertKept()
    }

    @Test fun absentTargetsAndAncestorsAreAlreadyComplete() = fixture { f ->
        f.schedule("absent/GeoSite.dat")
        assertTrue(f.cleanup().apply { initialize() }.ready)
        assertFalse(f.record.exists()); f.assertKept()
    }

    @Test fun partialDeletionKeepsCompletedItemsAndOriginalFailureForRetry() = fixture { f ->
        val first = f.file("GeoIP.dat"); val second = f.file("GeoSite.dat")
        f.schedule(first.name, second.name)
        val failure = IOException("delete failed 原始完整内容", IOException("original delete cause"))
        failure.addSuppressed(IOException("original suppressed"))
        var removed = 0
        val failed = CoreDataCleanup(f.core, f.record, remove = {
            if (it == second) throw failure
            Os.remove(it.path); removed++
        }).apply { initialize() }
        assertEquals(1, removed); assertFalse(first.exists()); assertTrue(second.exists())
        assertFalse(failed.ready); assertTrue(failed.pending)
        assertEquals(listOf(true, false), items(failed).map { it["completed"] })
        assertEquals(failure.stackTraceToString(), (failed.snapshot()["error"] as Map<*, *>)["detail"])
        assertTrue(f.record.exists()); failed.initialize(); assertEquals(1, removed)
        assertTrue(f.cleanup().apply { initialize() }.ready)
        assertTrue(f.core.isDirectory); assertFalse(second.exists()); assertFalse(f.record.exists()); f.assertKept()
    }

    @Test fun onlyRegisteredRegularFilesInsideTheCoreDirectoryCanBeSelected() = fixture { f ->
        val cleanup = f.cleanup().apply { initialize() }
        for (path in listOf(f.directory.path, f.core.path, "../outside", "${f.core.path}-other/file", "")) rejects<IOException> { cleanup.resource(path) }
        val directory = File(f.core, "directory").apply { check(mkdir()) }
        cleanup.registerCandidates(listOf(directory.path))
        rejects<IOException> { cleanup.resource(directory.path) }
        rejects<IOException> { cleanup.resource(f.file("providers/user.yaml").path) }
        assertFalse(f.record.exists()); f.assertKept()
    }

    @Test fun invalidScopesRelativePathsDuplicateAndEmptyListsAreRejected() {
        for (scope in listOf("", "unknown", "all")) rejects<IllegalArgumentException> { CoreDataCleanup.Request(scope) }
        for (path in listOf("", "/absolute", "..", "a/../b", "a/./b", "a//b", "a/")) rejects<IllegalArgumentException> { CoreDataCleanup.Request(listOf(path)) }
        rejects<IllegalArgumentException> { CoreDataCleanup.Request(emptyList()) }
        rejects<IllegalArgumentException> { CoreDataCleanup.Request(listOf("cache.db", "cache.db")) }
        rejects<IllegalArgumentException> { CoreDataCleanup.Request("cache", "other") }
    }

    @Test fun aSelectedSymlinkIsRejectedWithoutRemovingItOrFollowingItsTarget() = fixture { f ->
        val outside = File(f.directory, "outside.txt").apply { writeText("outside original") }
        val link = File(f.core, "GeoIP.dat"); Os.symlink(outside.path, link.path)
        val cleanup = f.cleanup().apply { initialize(); registerCandidates(listOf(link.path)) }
        rejects<IOException> { cleanup.resource(link.path) }
        cleanup.schedule(CoreDataCleanup.Request(listOf(link.name))) { it() }
        assertFalse(f.cleanup().apply { initialize() }.ready)
        assertEquals("outside original", outside.readText()); assertEquals(outside.path, Os.readlink(link.path)); f.assertKept()
    }

    @Test fun aChangedAncestorSymlinkCannotRedirectDeletion() = fixture { f ->
        val selected = f.file("geo/GeoSite.dat"); f.schedule("geo/GeoSite.dat")
        check(selected.delete()); check(selected.parentFile!!.delete())
        val outside = File(f.directory, "outside").apply { check(mkdir()) }
        val kept = File(outside, selected.name).apply { writeText("outside original") }
        Os.symlink(outside.path, selected.parentFile!!.path)
        val next = f.cleanup().apply { initialize() }
        assertFalse(next.ready); assertTrue(f.record.exists()); assertEquals("outside original", kept.readText())
        rejects<IOException> { next.resource(selected.path) }; f.assertKept()
    }

    @Test fun legacyAllCannotRemoveASymlinkRoot() = fixture { f ->
        check(f.core.delete()); val outside = File(f.directory, "outside").apply { check(mkdir()) }
        val kept = File(outside, "identity").apply { writeText("outside identity") }
        Os.symlink(outside.path, f.core.path); f.record.writeText("{\"scope\":\"all\"}")
        assertEquals("needsSelection", f.cleanup().apply { initialize() }.snapshot()["status"])
        assertEquals(outside.path, Os.readlink(f.core.path)); assertEquals("outside identity", kept.readText()); f.assertKept()
    }

    @Test fun cacheCleanupDoesNotTraverseASymlinkRoot() = fixture { f ->
        check(f.core.delete()); val outside = File(f.directory, "outside").apply { check(mkdir()) }
        val kept = File(outside, "cache.db").apply { writeText("outside database") }
        Os.symlink(outside.path, f.core.path); f.schedule("cache.db")
        assertFalse(f.cleanup().apply { initialize() }.ready)
        assertTrue(f.record.exists()); assertEquals("outside database", kept.readText()); f.assertKept()
    }

    @Test fun aSelectedTargetThatBecameADirectoryIsNotRecursivelyDeleted() = fixture { f ->
        val selected = f.file("GeoIP.dat"); f.schedule(selected.name)
        check(selected.delete()); check(selected.mkdir())
        val child = File(selected, "identity").apply { writeText("preserved") }
        assertFalse(f.cleanup().apply { initialize() }.ready)
        assertEquals("preserved", child.readText()); assertTrue(f.record.exists()); f.assertKept()
    }

    @Test fun cancellationBeforePublicationKeepsTheOldRequest() = fixture { f ->
        val cleanup = f.schedule("cache.db"); val before = f.record.readBytes()
        rejects<CancellationException> { cleanup.schedule(CoreDataCleanup.Request(listOf("cache.db"))) { throw CancellationException("owner ended 原文") } }
        assertArrayEquals(before, f.record.readBytes()); assertEquals(listOf("cache.db"), cleanup.snapshot()["paths"])
        assertTrue(f.record.parentFile!!.list()!!.none { it.endsWith(".tmp") }); f.assertKept()
    }

    @Test fun cancellationAfterPublicationDoesNotEraseTheRequest() = fixture { f ->
        val cleanup = f.cleanup().apply { initialize() }; var active = true
        cleanup.schedule(CoreDataCleanup.Request(listOf("cache.db"))) { publish -> check(active); publish(); active = false }
        assertFalse(active); assertEquals("scheduled", cleanup.snapshot()["status"])
        assertEquals("files", JSONObject(f.record.readText()).getString("scope"))
        assertTrue(f.core.exists()); f.assertKept()
    }

    @Test fun directorySyncFailureRetainsSavedSelectionAndOriginalError() = fixture { f ->
        val failure = IOException("directory sync failed 原文", IOException("original directory sync cause"))
        val cleanup = CoreDataCleanup(f.core, f.record, writeRecord = { file, bytes, publish ->
            CorePrivateFiles.write(file, bytes, publish); throw CoreRecordPublicationException(failure)
        }).apply { initialize() }
        val error = rejects<CoreRecordPublicationException> { cleanup.schedule(CoreDataCleanup.Request(listOf("cache.db"))) { it() } }
        assertSame(failure, error.cause); assertEquals("scheduled", cleanup.snapshot()["status"])
        assertTrue(f.record.exists()); assertFalse(cleanup.ready)
        assertTrue(f.cleanup().apply { initialize() }.ready); f.assertKept()
    }

    @Test fun failedTargetSyncRetainsTheRequestEvenAfterTheFileWasRemoved() = fixture { f ->
        val database = f.file("cache.db"); f.schedule("cache.db")
        val failed = CoreDataCleanup(f.core, f.record, syncDirectory = { throw IOException("target sync original") }).apply { initialize() }
        assertFalse(database.exists()); assertFalse(failed.ready); assertTrue(f.record.exists())
        assertTrue(f.cleanup().apply { initialize() }.ready); f.assertKept()
    }

    @Test fun failedRecordDirectorySyncRetainsCompletedItemsForConfirmation() = fixture { f ->
        val database = f.file("cache.db"); f.schedule("cache.db")
        val failed = CoreDataCleanup(f.core, f.record, syncDirectory = {
            if (it == f.record.parentFile && !f.record.exists()) throw IOException("record sync original")
            CorePrivateFiles.sync(it)
        }).apply { initialize() }
        assertFalse(failed.ready); assertEquals("failed", failed.snapshot()["status"])
        assertFalse(database.exists()); assertTrue(f.record.exists()); assertEquals(true, items(failed).single()["completed"])
        assertTrue((failed.snapshot()["error"] as Map<*, *>)["detail"].toString().contains("record sync original"))
        assertTrue(f.cleanup().apply { initialize() }.ready); f.assertKept()
    }

    @Test fun malformedRecordKeepsItsOriginalErrorAndDoesNotDeleteCoreFiles() = fixture { f ->
        val database = f.file("cache.db"); f.record.writeText("{broken 原文")
        val cleanup = f.cleanup().apply { initialize() }
        assertFalse(cleanup.ready)
        assertTrue((cleanup.snapshot()["error"] as Map<*, *>)["detail"].toString().contains("JSONException"))
        assertEquals("{broken 原文", f.record.readText()); assertTrue(database.exists()); f.assertKept()
    }

    @Test fun aSelectedHardlinkIsRejectedWithoutRemovingEitherName() = fixture { f ->
        val target = f.file("user-file"); val link = File(f.core, "GeoIP.dat")
        HardlinkPrerequisites.link(target, link,
            "io.github.monadboxlab.clashpseudo.storage.CoreDataCleanupTest#aSelectedHardlinkIsRejectedWithoutRemovingEitherName")
        val cleanup = f.cleanup().apply { initialize(); registerCandidates(listOf(link.path)) }
        rejects<IOException> { cleanup.resource(link.path) }
        cleanup.schedule(CoreDataCleanup.Request(listOf(link.name))) { it() }
        assertFalse(f.cleanup().apply { initialize() }.ready)
        assertEquals("original user-file", target.readText()); assertTrue(link.exists()); f.assertKept()
    }

    @Test fun aLiveProcessResourceLockPreventsEverySelectedDeletion() = fixture { f ->
        val database = f.file("cache.db"); f.schedule("cache.db")
        CoreResourceGate(File(f.record.parentFile, "core-host.lock")).tryAcquire()!!.use {
            val cleanup = f.cleanup().apply { initialize() }
            assertFalse(cleanup.ready); assertTrue(database.exists()); assertTrue(f.record.exists())
        }
        assertTrue(f.cleanup().apply { initialize() }.ready); assertFalse(database.exists()); f.assertKept()
    }

    @Test fun malformedDuplicateOrEmptyFileListsNeverBecomeSuccessfulCleanup() = fixture { f ->
        val database = f.file("cache.db")
        for (files in listOf("[]", "[{\"path\":\"cache.db\"},{\"path\":\"cache.db\"}]")) {
            f.record.writeText("{\"scope\":\"files\",\"files\":$files}")
            assertFalse(f.cleanup().apply { initialize() }.ready); assertTrue(database.exists())
        }
        f.assertKept()
    }
}
