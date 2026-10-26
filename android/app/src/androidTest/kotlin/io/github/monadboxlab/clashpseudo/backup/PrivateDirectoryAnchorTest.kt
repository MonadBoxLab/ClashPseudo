package io.github.monadboxlab.clashpseudo.backup

import io.github.monadboxlab.clashpseudo.nativecore.BundledGeo

import android.system.Os
import android.system.OsConstants
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FileDescriptor
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

/**
 * Models inaccessible sandbox ancestors through an opener in a fresh SDK cache
 * directory.
 */
class PrivateDirectoryAnchorTest {
    private fun opener(root: File, attempts: MutableList<String>): (String) -> FileDescriptor = { path ->
        attempts += path
        if (path != root.path && !path.startsWith("/proc/self/fd/")) {
            throw IOException("Fixture denies read access to system ancestors")
        }
        Os.open(path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
    }

    @Test fun backupRecoveryCapturePublicationAndInstallNeverReadSystemAncestors() = BackupFixture.use { f ->
        val attempts = mutableListOf<String>()
        val files = BackupFiles(f.stores, f.privateRoot, trustedRoots = listOf(f.root), openDirectory = opener(f.root, attempts))
        assertTrue(files.transaction.recover().ready)
        f.old(BackupFixture.values())
        val candidate = files.captureStores(1L, files.transaction.snapshot().epoch,
            BackupFiles.Operation(BackupLease()), BackupFixture.values())
        assertEquals(3, files.candidateReadPaths(candidate.token).size)
        val kind = BackupFiles.Kind.PREFERENCES
        File(f.stores, "${kind.fileName}.tmp").writeText("{\"afterCapture\":true}")
        assertTrue(files.transaction.publishStore(kind, files.transaction.snapshot().epoch, BackupLease()).saved)
        val installed = files.transaction.install(candidate.token, files.transaction.snapshot().epoch, BackupFiles.Operation(BackupLease()))
        assertEquals(true, installed.committed)
        assertTrue(installed.ready)
        files.discard(candidate.token)
        assertTrue(attempts.isNotEmpty())
        assertTrue(attempts.all { it == f.root.path || it.startsWith("/proc/self/fd/") })
    }

    @Test fun backupCannotEscapeTheSdkAnchorAndStillRejectsLinkedManagedAncestors() = BackupFixture.use { f ->
        val attempts = mutableListOf<String>()
        val files = BackupFiles(f.stores, f.privateRoot, trustedRoots = listOf(f.root), openDirectory = opener(f.root, attempts))
        backupRejects<IOException> { files.pinDirectory(checkNotNull(f.root.parentFile)).close() }
        assertTrue(attempts.isEmpty())
        val real = File(f.root, "real").apply { check(mkdir()) }
        val child = File(real, "child").apply { check(mkdir()) }
        val link = File(f.privateRoot, "linked")
        Os.symlink(real.path, link.path)
        try {
            backupRejects<android.system.ErrnoException> { files.pinDirectory(File(link, child.name)).close() }
            assertTrue(child.list()!!.isEmpty())
        } finally { Os.remove(link.path) }
        backupRejects<IllegalArgumentException> { files.pinDirectory(File(f.root, "a/../stores")).close() }
    }

    @Test fun geoReadsOnlyItsSdkAnchorAndPinnedManagedDescendantsIncludingPublicationRecheck() = BackupFixture.use { f ->
        val attempts = mutableListOf<String>()
        val home = File(f.root, "geo").apply { check(mkdir()) }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val installer = BundledGeo(f.root, { name -> context.assets.open("geodata/$name") },
            directoryOpen = opener(f.root, attempts))
        val owner = object : BundledGeo.Owner {
            override fun checkCurrent() {}
            override fun publishIfCurrent(block: () -> Unit) = block()
        }
        val request = BundledGeo.Request(BundledGeo.Kind.GEOSITE, "GeoSite.dat")
        assertEquals(BundledGeo.State.INSTALLED, installer.install(home, listOf(request), owner).single().state)
        assertEquals(BundledGeo.State.PRESERVED, installer.install(home, listOf(request), owner).single().state)
        assertEquals(request.kind.data.size, File(home, request.targetName).length())
        assertTrue(attempts.count { it == f.root.path } >= 3)
        assertTrue(attempts.all { it == f.root.path || it.startsWith("/proc/self/fd/") })
    }

    @Test fun geoCannotTrustAParentOutsideTheSdkRootOrFollowAManagedLink() = BackupFixture.use { f ->
        val attempts = mutableListOf<String>()
        val installer = BundledGeo(f.root, { throw AssertionError("No asset before path admission") },
            directoryOpen = opener(f.root, attempts))
        val owner = object : BundledGeo.Owner {
            override fun checkCurrent() {}
            override fun publishIfCurrent(block: () -> Unit) = block()
        }
        val request = BundledGeo.Request(BundledGeo.Kind.GEOSITE, "GeoSite.dat")
        backupRejects<IllegalArgumentException> { installer.install(checkNotNull(f.root.parentFile), listOf(request), owner) }
        assertTrue(attempts.isEmpty())
        val actual = File(f.root, "real-geo").apply { check(mkdir()) }
        val child = File(actual, "child").apply { check(mkdir()) }
        val link = File(f.root, "geo-link")
        Os.symlink(actual.path, link.path)
        try {
            backupRejects<android.system.ErrnoException> { installer.install(File(link, child.name), listOf(request), owner) }
            assertTrue(child.list()!!.isEmpty())
        } finally { Os.remove(link.path) }
    }
}
