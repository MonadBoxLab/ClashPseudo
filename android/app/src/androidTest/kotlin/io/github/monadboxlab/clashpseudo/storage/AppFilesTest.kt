package io.github.monadboxlab.clashpseudo.storage

import io.github.monadboxlab.clashpseudo.app.ApplicationContract

import android.content.Context
import android.content.ContextWrapper
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class AppFilesTest {
    private fun fixture(block: (File, Context) -> Unit) {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(target.cacheDir.canonicalFile, "storage-usage-isolated-${UUID.randomUUID()}")
        check(root.mkdir())
        val files = File(root, "files").apply { check(mkdir()) }
        val noBackup = File(root, "no-backup").apply { check(mkdir()) }
        val context = object : ContextWrapper(target) {
            override fun getFilesDir() = files
            override fun getNoBackupFilesDir() = noBackup
        }
        try { block(root, context) } finally { check(root.deleteRecursively()) }
    }

    @Test fun privacyNoticeMarkerIsInstallationLocalAndSurvivesContextRecreationWithoutBusinessWrites() = fixture { root, context ->
        val marker = AppFiles.privacyNotice(context)
        assertEquals(File(context.noBackupFilesDir, "privacy-notice-shown"), marker)
        assertFalse(AppFiles.privacyNoticeShown(context))
        assertFalse(marker.exists()) // Reading must not mark an undisplayed notice.
        assertFalse(AppFiles.configs(context).exists())
        assertFalse(AppFiles.core(context).exists())
        AppFiles.markPrivacyNoticeShown(context)
        assertArrayEquals(byteArrayOf(1), marker.readBytes())
        assertTrue(AppFiles.privacyNoticeShown(object : ContextWrapper(context) {}))
        AppFiles.markPrivacyNoticeShown(context)
        assertArrayEquals(byteArrayOf(1), marker.readBytes())
        assertFalse(AppFiles.configs(context).exists())
        assertFalse(AppFiles.core(context).exists())
        assertEquals(setOf("files", "no-backup"), root.list()!!.toSet())
        assertEquals(setOf(marker.name), context.noBackupFilesDir.list()!!.toSet())
    }

    @Test fun malformedPrivacyNoticeMarkersStayUnknownRatherThanBecomingMissingOrShown() = fixture { _, context ->
        val marker = AppFiles.privacyNotice(context)
        for (bytes in listOf(byteArrayOf(), byteArrayOf(0), byteArrayOf(1, 1))) {
            marker.writeBytes(bytes)
            try {
                AppFiles.privacyNoticeShown(context)
                fail("Malformed marker was reported as a known installation state")
            } catch (error: IOException) {
                assertEquals("Invalid privacy notice marker", error.message)
            }
            assertArrayEquals(bytes, marker.readBytes())
        }
        check(marker.delete())
        assertFalse(AppFiles.privacyNoticeShown(context))
    }

    @Test fun linkedPrivacyNoticeMarkerCannotReadOrOverwriteAnotherFile() = fixture { root, context ->
        val outside = File(root, "outside-marker").apply { writeBytes(byteArrayOf(1)) }
        val marker = AppFiles.privacyNotice(context)
        Os.symlink(outside.path, marker.path)
        try {
            try {
                AppFiles.privacyNoticeShown(context)
                fail("Linked marker was accepted")
            } catch (error: ErrnoException) {
                assertEquals(OsConstants.ELOOP, error.errno)
            }
            try {
                AppFiles.markPrivacyNoticeShown(context)
                fail("Linked marker was overwritten")
            } catch (error: ErrnoException) {
                assertEquals(OsConstants.ELOOP, error.errno)
            }
            assertArrayEquals(byteArrayOf(1), outside.readBytes())
        } finally { Os.remove(marker.path) }
    }

    @Test fun unreadablePrivacyNoticeMarkerKeepsItsErrnoInsteadOfReportingFalseOrSuccess() = fixture { _, context ->
        AppFiles.markPrivacyNoticeShown(context)
        val directory = context.noBackupFilesDir
        try {
            Os.chmod(directory.path, 0)
            try {
                AppFiles.privacyNoticeShown(context)
                fail("Unreadable marker was presented as absent")
            } catch (error: ErrnoException) {
                assertEquals(OsConstants.EACCES, error.errno)
                assertTrue(error.toString().contains("EACCES"))
            }
            try {
                AppFiles.markPrivacyNoticeShown(context)
                fail("Failed marker write was presented as successful")
            } catch (error: ErrnoException) {
                assertEquals(OsConstants.EACCES, error.errno)
                assertTrue(error.toString().contains("EACCES"))
            }
        } finally { Os.chmod(directory.path, OsConstants.S_IRWXU) }
        assertArrayEquals(byteArrayOf(1), AppFiles.privacyNotice(context).readBytes())
    }

    @Test fun privacyNoticeSyncFailuresRemainUnconfirmedWithTheirCompleteCauseAndClosedDescriptors() = fixture { _, context ->
        for (failDirectory in listOf(false, true)) {
            val failure = IOException("marker sync 原文", IOException("original cause"))
                .apply { addSuppressed(IOException("original suppressed failure")) }
            val opened = mutableListOf<java.io.FileDescriptor>()
            try {
                AppFiles.markPrivacyNoticeShown(context) { descriptor ->
                    opened += descriptor
                    if (OsConstants.S_ISDIR(Os.fstat(descriptor).st_mode) == failDirectory) throw failure
                    Os.fsync(descriptor)
                }
                fail("Failed fsync was reported as durable persistence")
            } catch (error: IOException) {
                assertSame(failure, error)
                assertEquals("original cause", error.cause!!.message)
                assertEquals("original suppressed failure", error.suppressed.single().message)
            }
            assertEquals(if (failDirectory) 2 else 1, opened.size)
            opened.forEach { assertFalse("Descriptor outlived the actual failed I/O", it.valid()) }
            // Visible bytes do not retroactively turn the failed persistence call into success.
            assertTrue(AppFiles.privacyNoticeShown(context))
        }
        val synced = mutableListOf<Boolean>()
        AppFiles.markPrivacyNoticeShown(context) { descriptor ->
            synced += OsConstants.S_ISDIR(Os.fstat(descriptor).st_mode)
            Os.fsync(descriptor)
        }
        assertEquals(listOf(false, true), synced)
    }

    @Test fun privacyMarkerDirectorySyncRejectsReplacedRegularOrLinkedParents() {
        for (linked in listOf(false, true)) fixture { root, context ->
            val directory = context.noBackupFilesDir
            val moved = File(root, "moved-no-backup")
            val outside = File(root, "outside").apply { check(mkdir()) }
            val kept = File(outside, "privacy-notice-shown").apply { writeBytes(byteArrayOf(0)) }
            val synced = mutableListOf<java.io.FileDescriptor>()
            try {
                try {
                    AppFiles.markPrivacyNoticeShown(context) { descriptor ->
                        synced += descriptor
                        assertEquals("Invalid parent reached directory sync", 1, synced.size)
                        assertTrue(OsConstants.S_ISREG(Os.fstat(descriptor).st_mode))
                        Os.fsync(descriptor)
                        Os.rename(directory.path, moved.path)
                        if (linked) Os.symlink(outside.path, directory.path)
                        else directory.writeText("not a directory")
                    }
                    fail("Replaced privacy marker parent was accepted")
                } catch (error: ErrnoException) {
                    assertTrue(linked)
                    assertEquals(OsConstants.ELOOP, error.errno)
                } catch (error: IOException) {
                    assertFalse(linked)
                    assertEquals("Privacy notice marker parent is not a directory", error.message)
                }
                assertEquals(1, synced.size)
                synced.forEach { assertFalse("Marker descriptor outlived failed persistence", it.valid()) }
                assertArrayEquals(byteArrayOf(1), File(moved, "privacy-notice-shown").readBytes())
                assertArrayEquals(byteArrayOf(0), kept.readBytes())
                if (!linked) assertEquals("not a directory", directory.readText())
            } finally {
                if (moved.exists()) {
                    check(directory.delete())
                    Os.rename(moved.path, directory.path)
                }
            }
        }
    }

    @Test fun privacyMarkerBelongsToTheInstallationAndSurvivesContextRecreationWithoutChangingBusinessData() = fixture { _, context ->
        val marker = AppFiles.privacyNotice(context)
        assertEquals(File(context.noBackupFilesDir, "privacy-notice-shown"), marker)
        assertFalse(marker.absolutePath.startsWith(context.filesDir.absolutePath + File.separator))
        assertFalse(AppFiles.privacyNoticeShown(context))
        val stores = AppFiles.configs(context).apply { check(mkdir()) }
        val business = File(stores, ApplicationContract.BACKUP_PREFERENCES_FILE).apply { writeText("{broken 原文🙂") }
        val original = business.readBytes()
        AppFiles.markPrivacyNoticeShown(context)
        assertArrayEquals(byteArrayOf(1), marker.readBytes())
        val recreated = ContextWrapper(context)
        assertTrue(AppFiles.privacyNoticeShown(recreated))
        AppFiles.markPrivacyNoticeShown(recreated)
        assertArrayEquals(byteArrayOf(1), marker.readBytes())
        assertArrayEquals(original, business.readBytes())
        check(marker.delete()) // Clearing installation data, not a business restore.
        assertFalse(AppFiles.privacyNoticeShown(recreated))
    }

    @Test fun selectedCacheCleanupKeepsTheActualNoBackupInstallationMarkerAndUserFiles() = fixture { _, context ->
        AppFiles.markPrivacyNoticeShown(context)
        val core = AppFiles.core(context).apply { check(mkdir()) }
        val identity = File(core, "node-identity").apply { writeText("core identity") }
        val database = File(core, "cache.db").apply { writeText("core cache") }
        val provider = File(core, "provider.yaml").apply { writeText("user provider") }
        val record = File(context.noBackupFilesDir, "core-cleanup.json")
        val currentProcess = CoreDataCleanup(core, record).apply { initialize() }
        assertNull(currentProcess.schedule(CoreDataCleanup.Request(listOf("cache.db"))) { it() })
        assertTrue(database.exists())
        assertTrue(identity.exists())
        assertTrue(AppFiles.privacyNoticeShown(context))
        currentProcess.initialize()
        assertTrue(database.exists())
        assertTrue(identity.exists())
        val nextProcess = CoreDataCleanup(core, record).apply { initialize() }
        assertTrue(nextProcess.ready)
        assertFalse(database.exists())
        assertEquals("core identity", identity.readText())
        assertEquals("user provider", provider.readText())
        assertTrue(core.isDirectory)
        assertFalse(record.exists())
        assertTrue(AppFiles.privacyNoticeShown(ContextWrapper(context)))
        assertArrayEquals(byteArrayOf(1), AppFiles.privacyNotice(context).readBytes())
    }

    @Test fun aDamagedPrivacyMarkerIsUncertainAndIsNotReadAsAnAbsentOrCompletedNotice() = fixture { _, context ->
        val marker = AppFiles.privacyNotice(context)
        for (bytes in listOf(byteArrayOf(), byteArrayOf(0), byteArrayOf(1, 1), byteArrayOf(0xff.toByte()))) {
            marker.writeBytes(bytes)
            try {
                AppFiles.privacyNoticeShown(context)
                fail("A damaged privacy marker was treated as a Boolean result")
            } catch (error: IOException) {
                assertEquals("Invalid privacy notice marker", error.message)
            }
            assertArrayEquals(bytes, marker.readBytes())
        }
    }

    @Test fun privacyMarkerStatAndOpenFailuresKeepTheirActualErrnoInsteadOfReturningFalseOrSuccess() = fixture { root, context ->
        val blocked = File(root, "not-a-directory").apply { writeText("untouched 原文🙂") }
        val invalidContext = object : ContextWrapper(context) {
            override fun getNoBackupFilesDir() = blocked
        }
        for (write in listOf(false, true)) {
            try {
                if (write) AppFiles.markPrivacyNoticeShown(invalidContext)
                else AppFiles.privacyNoticeShown(invalidContext)
                fail("A failed privacy marker operation was reported as completed")
            } catch (error: ErrnoException) {
                assertEquals(OsConstants.ENOTDIR, error.errno)
                assertTrue(error.toString().contains("ENOTDIR"))
            }
        }
        assertEquals("untouched 原文🙂", blocked.readText())
    }

    @Test fun privacyMarkerDoesNotFollowAnExistingLinkOrChangeItsTarget() = fixture { root, context ->
        val outside = File(root, "outside-marker").apply { writeText("untouched 原文🙂") }
        val marker = AppFiles.privacyNotice(context)
        Os.symlink(outside.path, marker.path)
        try {
            for (write in listOf(false, true)) {
                try {
                    if (write) AppFiles.markPrivacyNoticeShown(context) else AppFiles.privacyNoticeShown(context)
                    fail("The privacy marker followed a link")
                } catch (error: ErrnoException) {
                    assertEquals(OsConstants.ELOOP, error.errno)
                }
                assertEquals("untouched 原文🙂", outside.readText())
            }
        } finally { Os.remove(marker.path) }
    }

    @Test fun privacyMarkerWaitsForFileAndDirectorySyncAndPreservesUnconfirmedPersistenceErrors() = fixture { _, context ->
        for (failureAt in listOf(1, 2, null)) {
            val original = IOException("privacy marker sync 原文🙂", IOException("original cause"))
                .apply { addSuppressed(IOException("original suppressed detail")) }
            val descriptors = mutableListOf<java.io.FileDescriptor>()
            var returned = false
            try {
                AppFiles.markPrivacyNoticeShown(context) { descriptor ->
                    if (descriptors.isNotEmpty()) {
                        assertFalse("File descriptor must close before directory sync", descriptors.first().valid())
                    }
                    descriptors += descriptor
                    val info = Os.fstat(descriptor)
                    if (descriptors.size == 1) assertTrue(OsConstants.S_ISREG(info.st_mode))
                    else assertTrue(OsConstants.S_ISDIR(info.st_mode))
                    if (descriptors.size == failureAt) throw original
                    Os.fsync(descriptor)
                }
                returned = true
            } catch (error: IOException) {
                assertNotNull(failureAt)
                assertSame(original, error)
                assertEquals("original cause", error.cause!!.message)
                assertEquals("original suppressed detail", error.suppressed.single().message)
            }
            assertEquals(failureAt == null, returned)
            assertEquals(failureAt ?: 2, descriptors.size)
            // A later sync failure does not pretend that the actual one-byte write was rolled back.
            assertArrayEquals(byteArrayOf(1), AppFiles.privacyNotice(context).readBytes())
            for (descriptor in descriptors) {
                try {
                    Os.fstat(descriptor)
                    fail("Privacy marker descriptor remained open after completion")
                } catch (error: ErrnoException) { assertEquals(OsConstants.EBADF, error.errno) }
            }
        }
    }

    @Test fun usageReportsActualDamagedAndOversizedFileLengthsWithoutParsingOrRewritingThem() = fixture { _, context ->
        val stores = AppFiles.configs(context).apply { check(mkdir()) }
        val configurations = File(stores, ApplicationContract.BACKUP_CONFIGURATIONS_FILE)
        val original = byteArrayOf(0xff.toByte()) + "{broken 原文🙂".toByteArray(Charsets.UTF_8)
        configurations.writeBytes(original)
        val overrides = File(stores, ApplicationContract.BACKUP_OVERRIDES_FILE)
        val oversized = ApplicationContract.BACKUP_OVERRIDES_JSON_BYTES.toLong() + 1
        RandomAccessFile(overrides, "rw").use { it.setLength(oversized) }
        val core = AppFiles.core(context).apply { check(mkdir()) }
        val database = File(core, "cache.db").apply { writeText("core bytes 原文🙂") }
        val nested = File(core, "providers").apply { check(mkdir()) }
        val resource = File(nested, "remote.yaml").apply { writeText("provider bytes") }
        val usage = AppFiles.usage(context)
        assertEquals(setOf("configurations", "overrides", "preferences", "core"), usage.keys)
        assertEquals(mapOf("path" to configurations.absolutePath, "bytes" to original.size.toLong()), usage["configurations"])
        assertEquals(mapOf("path" to overrides.absolutePath, "bytes" to oversized), usage["overrides"])
        assertEquals(mapOf("path" to File(stores, ApplicationContract.BACKUP_PREFERENCES_FILE).absolutePath,
            "bytes" to 0L), usage["preferences"])
        assertEquals(mapOf("path" to core.absolutePath, "bytes" to database.length() + resource.length()), usage["core"])
        assertArrayEquals(original, configurations.readBytes())
        assertEquals(oversized, overrides.length())
    }

    @Test fun onlyAnActuallyMissingPathCountsAsZeroWhileOtherStatFailuresKeepTheirCause() = fixture { root, _ ->
        assertEquals(0L, AppFiles.bytes(File(root, "absent/child")))
        val file = File(root, "not-a-directory").apply { writeText("original") }
        try {
            AppFiles.bytes(File(file, "child"))
            fail("A failed stat was presented as zero bytes")
        } catch (error: ErrnoException) {
            assertEquals(OsConstants.ENOTDIR, error.errno)
            assertTrue(error.toString().contains("ENOTDIR"))
        }
        assertEquals("original", file.readText())
    }

    @Test fun linkedFilesAndDirectoriesCountOnlyTheLinkWithoutTraversingTargets() = fixture { root, _ ->
        val outside = File(root, "outside").apply { check(mkdir()) }
        val kept = File(outside, "large").apply { writeBytes(ByteArray(8192) { 7 }) }
        val measured = File(root, "measured").apply { check(mkdir()) }
        val local = File(measured, "local").apply { writeText("local 原文🙂") }
        val links = listOf(
            File(measured, "directory") to outside,
            File(measured, "file") to kept,
            File(measured, "dangling") to File(outside, "missing"),
        ).map { (link, target) ->
            Os.symlink(target.absolutePath, link.absolutePath)
            link
        }
        val linkBytes = links.sumOf { Os.lstat(it.absolutePath).st_size }
        assertEquals(local.length() + linkBytes, AppFiles.bytes(measured))
        links.forEach { assertEquals(Os.lstat(it.absolutePath).st_size, AppFiles.bytes(it)) }
        assertArrayEquals(ByteArray(8192) { 7 }, kept.readBytes())
    }

    @Test fun anUnreadableCoreDirectoryReportsItsOriginalErrorWithoutHidingBusinessFileSizes() = fixture { _, context ->
        val stores = AppFiles.configs(context).apply { check(mkdir()) }
        val configurations = File(stores, ApplicationContract.BACKUP_CONFIGURATIONS_FILE).apply { writeText("{broken 原文🙂") }
        val core = AppFiles.core(context).apply { check(mkdir()) }
        val inaccessible = File(core, "unreadable").apply { check(mkdir()) }
        val kept = File(inaccessible, "identity").apply { writeText("preserved") }
        val usage = try {
            Os.chmod(inaccessible.absolutePath, 0)
            AppFiles.usage(context)
        } finally {
            Os.chmod(inaccessible.absolutePath, OsConstants.S_IRWXU)
        }
        assertEquals(configurations.length(), (usage["configurations"] as Map<*, *>)["bytes"])
        val coreUsage = usage["core"] as Map<*, *>
        assertFalse(coreUsage.containsKey("bytes"))
        assertEquals(core.absolutePath, coreUsage["path"])
        val error = coreUsage["error"] as Map<*, *>
        assertEquals("storageUsageFailed", error["id"])
        val expected = IOException("Unable to list $inaccessible")
        val caller = expected.stackTrace.first()
        val appClass = Regex.escape(AppFiles::class.java.name)
        val bytesMethod = AppFiles::class.java.declaredMethods.single {
            it.name.substringBefore('$') == "bytes"
        }.name
        // Source line numbers may vary; exception messages, call order, and the rest of the stack must match exactly.
        val appLocation = """\(AppFiles\.kt:[1-9][0-9]*\)\n"""
        val origin = """\tat $appClass\.${Regex.escape(bytesMethod)}$appLocation""" +
            """\tat $appClass\.usage$appLocation""".repeat(2)
        val callSite = """\tat ${Regex.escape(caller.className)}\.${Regex.escape(caller.methodName)}""" +
            """\(${Regex.escape(checkNotNull(caller.fileName))}:[1-9][0-9]*\)\n"""
        val callerTail = expected.stackTraceToString().substringAfter('\n').substringAfter('\n')
        val completeTrace = Regex(Regex.escape(expected.toString()) + "\n" +
            origin + callSite + Regex.escape(callerTail))
        val detail = error["detail"] as String
        assertTrue("Original I/O stack must be retained in full:\n$detail", completeTrace.matches(detail))
        assertEquals("preserved", kept.readText())
    }
}
