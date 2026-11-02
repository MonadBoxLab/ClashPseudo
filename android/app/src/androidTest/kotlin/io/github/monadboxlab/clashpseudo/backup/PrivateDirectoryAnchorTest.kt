package io.github.monadboxlab.clashpseudo.backup

import io.github.monadboxlab.clashpseudo.nativecore.assets.BundledGeo

import android.system.Os
import android.system.OsConstants
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FileDescriptor
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

/** File work opens its actual private directories, not sandbox ancestors. */
class PrivateDirectoryAnchorTest {
    private fun opener(root: File, attempts: MutableList<String>): (String) -> FileDescriptor = { path ->
        attempts += path
        if (path != root.path && !path.startsWith(root.path + "/")) {
            throw IOException("Fixture denies read access to system ancestors")
        }
        Os.open(path, OsConstants.O_RDONLY or OsConstants.O_NONBLOCK or OsConstants.O_NOFOLLOW, 0)
    }

    @Test fun backupRecoveryCapturePublicationAndInstallNeverReadSystemAncestors() = BackupFixture.use { f ->
        val attempts = mutableListOf<String>()
        val files = BackupFiles(f.stores, f.privateRoot, openDirectory = opener(f.root, attempts))
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
        assertTrue(attempts.all { it == f.root.path || it.startsWith(f.root.path + "/") })
        assertFalse(attempts.any { it.startsWith("/proc/") })
    }

    @Test fun linkedBusinessAndBackupDirectoriesAreRejectedWithoutChangingTheirTargets() = BackupFixture.use { f ->
        for (linkedStores in listOf(false, true)) {
            val actual = File(f.root, "real-$linkedStores").apply { check(mkdir()) }
            val unrelated = File(actual, "untouched").apply { writeText("keep") }
            val link = File(f.root, "linked-$linkedStores")
            Os.symlink(actual.path, link.path)
            try {
                val files = if (linkedStores) BackupFiles(link, f.privateRoot) else BackupFiles(f.stores, link)
                backupRejects<IOException> { files.transaction.recover() }
                assertFalse(files.transaction.snapshot().ready)
                assertEquals(listOf("untouched"), actual.list()!!.toList())
                assertEquals("keep", unrelated.readText())
            } finally { Os.remove(link.path) }
        }
    }

    @Test fun geoOpensOnlyItsActualHomeAndRechecksItAtPublication() = BackupFixture.use { f ->
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
        assertEquals(listOf(home.path, home.path), attempts)
        assertEquals(BundledGeo.State.PRESERVED, installer.install(home, listOf(request), owner).single().state)
        assertEquals(request.kind.data.size, File(home, request.targetName).length())
        assertEquals(listOf(home.path, home.path, home.path), attempts)
    }

    @Test fun geoCannotWriteOutsideItsPrivateRootOrFollowALinkedHome() = BackupFixture.use { f ->
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
        val link = File(f.root, "geo-link")
        Os.symlink(actual.path, link.path)
        try {
            backupRejects<android.system.ErrnoException> { installer.install(link, listOf(request), owner) }
            assertTrue(actual.list()!!.isEmpty())
        } finally { Os.remove(link.path) }
        val escape = File(f.root, "escape-link")
        Os.symlink(checkNotNull(f.root.parentFile).path, escape.path)
        try {
            backupRejects<IllegalArgumentException> { installer.install(File(escape, "unrelated-geo"), listOf(request), owner) }
        } finally { Os.remove(escape.path) }
    }
}
