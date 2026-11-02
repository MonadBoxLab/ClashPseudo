package io.github.monadboxlab.clashpseudo.nativecore.assets

import io.github.monadboxlab.clashpseudo.nativecore.CoreHost

import android.system.Os
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FilterInputStream
import java.io.IOException
import java.io.FileDescriptor
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

/** Uses fresh isolated directories for each installation case. */
class BundledGeoInstallTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val site = BundledGeo.Request(BundledGeo.Kind.GEOSITE, "GeoSite.dat")
    private val asn = BundledGeo.Request(BundledGeo.Kind.ASN, "ASN.mmdb")
    private class Lease : BundledGeo.Owner {
        @Volatile var active = true
        var beforePublish: () -> Unit = {}
        override fun checkCurrent() { if (!active) throw CancellationException("stale Geo owner") }
        @Synchronized override fun publishIfCurrent(block: () -> Unit) {
            beforePublish()
            checkCurrent()
            block()
        }
    }
    private fun input(name: String) = context.assets.open("geodata/$name")
    private fun home(action: (File) -> Unit) {
        val directory = File(context.cacheDir.canonicalFile, "bundled-geo-test-${UUID.randomUUID()}")
        check(directory.mkdir())
        try { action(directory) } finally { directory.deleteRecursively() }
    }
    private inline fun <reified T : Throwable> rejects(action: () -> Unit) {
        try { action(); fail("Expected ${T::class.java.simpleName}") } catch (error: Throwable) {
            if (error !is T) throw error
        }
    }
    private fun noTemporary(home: File) = assertTrue(home.list()!!.none { it.startsWith(".bundled-geo-") })
    private fun verify(home: File, request: BundledGeo.Request) {
        val file = File(home, request.targetName)
        assertEquals(request.kind.data.size, file.length())
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val bytes = ByteArray(32768)
            while (true) { val count = stream.read(bytes); if (count < 0) break; digest.update(bytes, 0, count) }
        }
        assertEquals(request.kind.data.sha256, digest.digest().joinToString("") { "%02x".format(it) })
    }

    @Test fun installsFourRealAssetsAndRepeatedPreparationPreservesThem() = home { home ->
        val requests = listOf(BundledGeo.Request(BundledGeo.Kind.GEOIP, "GeoIP.dat"), site,
            BundledGeo.Request(BundledGeo.Kind.MMDB, "geoip.metadb"), asn)
        val installer = BundledGeo(context.cacheDir.canonicalFile, ::input)
        assertTrue(installer.install(home, requests, Lease()).all { it.state == BundledGeo.State.INSTALLED })
        requests.forEach { verify(home, it) }
        val timestamps = requests.map { File(home, it.targetName).lastModified() }
        assertTrue(installer.install(home, requests, Lease()).all { it.state == BundledGeo.State.PRESERVED })
        assertEquals(timestamps, requests.map { File(home, it.targetName).lastModified() })
        assertFalse(File(home, "Country.mmdb").exists())
        noTemporary(home)
    }

    @Test fun absentRequestsDoNothingAndDoNotReadAssets() = home { home ->
        val installer = BundledGeo(context.cacheDir.canonicalFile, { error("Explicit geox-url must not open a bundled asset") })
        assertTrue(installer.install(home, emptyList(), Lease()).isEmpty())
        assertTrue(home.list()!!.isEmpty())
    }

    @Test fun caseVariantsAndAllMmdbAliasesPreserveEvenEmptyOrDamagedFiles() = home { home ->
        val installer = BundledGeo(context.cacheDir.canonicalFile, { error("Existing data must not be replaced") })
        for (kind in BundledGeo.Kind.entries) {
            for (name in kind.names.map { it.uppercase() }) {
                val file = File(home, name)
                file.writeText("existing user/update bytes")
                val result = installer.install(home, listOf(BundledGeo.Request(kind,
                    if (kind == BundledGeo.Kind.MMDB) "Country.mmdb" else name)), Lease()).single()
                assertEquals(name, result.targetName)
                assertEquals(BundledGeo.State.PRESERVED, result.state)
                assertEquals("existing user/update bytes", file.readText())
                file.writeText("")
                assertEquals(BundledGeo.State.PRESERVED,
                    installer.install(home, listOf(BundledGeo.Request(kind, name)), Lease()).single().state)
                check(file.delete()) // Only this test's fixture in its new isolated directory.
            }
        }
        noTemporary(home)
    }

    @Test fun unicodeCaseVariantsFollowCoreSelectionWithoutTouchingUnselectedLookalikes() = home { parent ->
        val selected = File(parent, "selected").apply { check(mkdir()) }
        File(selected, "Geoſite.dat").writeText("selected user bytes")
        val preserved = BundledGeo(context.cacheDir.canonicalFile, { error("Existing core-selected long-s filename must win") })
            .install(selected, listOf(site), Lease()).single()
        assertEquals("Geoſite.dat", preserved.targetName)
        assertFalse(File(selected, site.targetName).exists())
        val other = File(parent, "unselected").apply { check(mkdir()) }
        val lookalike = File(other, "GeoSİte.dat").apply { writeText("not a core-selected name") }
        BundledGeo(context.cacheDir.canonicalFile, ::input).install(other, listOf(site), Lease())
        verify(other, site)
        assertEquals("not a core-selected name", lookalike.readText())
    }

    @Test fun existingMmdbSelectionUsesCoreSortedOrderWithoutAddingCountry() = home { home ->
        File(home, "geoip.metadb").writeText("second")
        File(home, "geoip.db").writeText("first")
        val result = BundledGeo(context.cacheDir.canonicalFile, { error("No bundle read") }).install(home,
            listOf(BundledGeo.Request(BundledGeo.Kind.MMDB, "Country.mmdb")), Lease()).single()
        assertEquals("geoip.db", result.targetName)
        assertFalse(File(home, "Country.mmdb").exists())
    }

    @Test fun duplicateKindAndUnmanagedTargetsAreRejected() = home { home ->
        rejects<IllegalArgumentException> { BundledGeo(context.cacheDir.canonicalFile, ::input).install(home, listOf(site, site), Lease()) }
        for (name in listOf("../GeoSite.dat", "/GeoSite.dat", "provider/file", "tailscale", "configurations.json")) {
            rejects<IllegalArgumentException> { BundledGeo.Request(site.kind, name) }
        }
        assertTrue(home.list()!!.isEmpty())
    }

    @Test fun targetDirectoryAndSymlinkNeverGetFollowed() = home { home ->
        val target = File(home, site.targetName)
        check(target.mkdir())
        rejects<IOException> { BundledGeo(context.cacheDir.canonicalFile, ::input).install(home, listOf(site), Lease()) }
        check(target.delete())
        val outside = File(home, "outside").apply { writeText("untouched") }
        Os.symlink(outside.path, target.path)
        rejects<IOException> { BundledGeo(context.cacheDir.canonicalFile, ::input).install(home, listOf(site), Lease()) }
        assertEquals("untouched", outside.readText())
        Os.remove(target.path)
        noTemporary(home)
    }

    @Test fun linkedHomeIsRejectedButSdkAliasesInsideThePrivateRootRemainUsable() = home { parent ->
        val real = File(parent, "real").apply { check(mkdir()) }
        val child = File(real, "child").apply { check(mkdir()) }
        val link = File(parent, "link")
        Os.symlink(real.path, link.path)
        try {
            rejects<android.system.ErrnoException> {
                BundledGeo(context.cacheDir.canonicalFile, ::input).install(link, listOf(site), Lease())
            }
            assertTrue(real.list()!!.contentEquals(arrayOf("child")))
            assertTrue(child.list()!!.isEmpty())
            val result = BundledGeo(context.cacheDir.canonicalFile, ::input)
                .install(File(link, child.name), listOf(site), Lease()).single()
            assertEquals(BundledGeo.State.INSTALLED, result.state)
            verify(child, site)
            noTemporary(child)
        } finally { Os.remove(link.path) }
    }

    @Test fun corruptAndTruncatedAssetsDoNotPublishAndCanRetry() = home { home ->
        for (bytes in listOf(byteArrayOf(1, 2, 3), ByteArray(site.kind.data.size.toInt()))) {
            rejects<IOException> { BundledGeo(context.cacheDir.canonicalFile, { bytes.inputStream() }).install(home, listOf(site), Lease()) }
            assertFalse(File(home, site.targetName).exists())
            noTemporary(home)
        }
        BundledGeo(context.cacheDir.canonicalFile, ::input).install(home, listOf(site), Lease())
        verify(home, site)
    }

    @Test fun cancelledStreamingRemovesOnlyItsTemporaryFile() = home { home ->
        val lease = Lease()
        File(home, "provider-untouched").writeText("keep")
        val installer = BundledGeo(context.cacheDir.canonicalFile, { name -> object : FilterInputStream(input(name)) {
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                val count = super.read(bytes, offset, length)
                lease.active = false
                return count
            }
        } })
        rejects<CancellationException> { installer.install(home, listOf(site), lease) }
        assertFalse(File(home, site.targetName).exists())
        assertEquals("keep", File(home, "provider-untouched").readText())
        noTemporary(home)
    }

    @Test fun cancellationAfterFileSyncIsRecheckedBeforePublication() = home { home ->
        val lease = Lease()
        val installer = BundledGeo(context.cacheDir.canonicalFile, ::input, { fd -> Os.fsync(fd); lease.active = false })
        rejects<CancellationException> { installer.install(home, listOf(site), lease) }
        assertFalse(File(home, site.targetName).exists())
        noTemporary(home)
    }

    @Test fun fileSyncFailureNeverPublishes() = home { home ->
        val installer = BundledGeo(context.cacheDir.canonicalFile, ::input, { throw IOException("injected fsync failure") })
        rejects<IOException> { installer.install(home, listOf(site), Lease()) }
        assertFalse(File(home, site.targetName).exists())
        noTemporary(home)
        BundledGeo(context.cacheDir.canonicalFile, ::input).install(home, listOf(site), Lease())
        verify(home, site)
    }

    @Test fun directorySyncFailureReportsErrorButNeverLeavesPartialPublishedBytes() = home { home ->
        var syncs = 0
        val installer = BundledGeo(context.cacheDir.canonicalFile, ::input, { fd ->
            if (++syncs == 2) throw IOException("injected directory fsync failure")
            Os.fsync(fd)
        })
        rejects<IOException> { installer.install(home, listOf(site), Lease()) }
        verify(home, site)
        noTemporary(home)
        assertEquals(BundledGeo.State.PRESERVED,
            BundledGeo(context.cacheDir.canonicalFile, { error("Complete published bytes must be preserved") })
                .install(home, listOf(site), Lease()).single().state)
    }

    @Test fun owningSdkStreamClosesFileDescriptorOnSuccessCancellationAndSyncFailure() = home { parent ->
        for (mode in listOf("success", "cancel", "sync-failure")) {
            val home = File(parent, mode).apply { check(mkdir()) }
            val lease = Lease()
            var stagedDescriptor: FileDescriptor? = null
            val installer = BundledGeo(context.cacheDir.canonicalFile, ::input, { descriptor ->
                if (stagedDescriptor == null) {
                    stagedDescriptor = descriptor
                    if (mode == "sync-failure") throw IOException("injected file sync failure")
                    if (mode == "cancel") lease.active = false
                }
                Os.fsync(descriptor)
            })
            when (mode) {
                "cancel" -> rejects<CancellationException> { installer.install(home, listOf(site), lease) }
                "sync-failure" -> rejects<IOException> { installer.install(home, listOf(site), lease) }
                else -> installer.install(home, listOf(site), lease)
            }
            // Android's FileOutputStream(fd) alone would leave this borrowed FD open.
            val descriptor = checkNotNull(stagedDescriptor)
            assertFalse("The actual staged descriptor must be invalid after $mode", descriptor.valid())
            rejects<android.system.ErrnoException> { Os.fstat(descriptor) }
            noTemporary(home)
        }
    }

    @Test fun userFileCreatedBeforePublicationWinsWithoutOverwrite() = home { home ->
        val lease = Lease().apply { beforePublish = { File(home, site.targetName).writeText("new update") } }
        val result = BundledGeo(context.cacheDir.canonicalFile, ::input).install(home, listOf(site), lease).single()
        assertEquals(BundledGeo.State.PRESERVED, result.state)
        assertEquals("new update", File(home, site.targetName).readText())
        noTemporary(home)
    }

    @Test fun independentFilesRetryWithoutPermanentInitializedFlag() = home { home ->
        var opens = 0
        val installer = BundledGeo(context.cacheDir.canonicalFile, { name ->
            opens++
            if (name == asn.kind.data.asset) throw IOException("injected second-asset failure")
            input(name)
        })
        rejects<IOException> { installer.install(home, listOf(site, asn), Lease()) }
        verify(home, site)
        assertFalse(File(home, asn.targetName).exists())
        noTemporary(home)
        val results = BundledGeo(context.cacheDir.canonicalFile, ::input).install(home, listOf(site, asn), Lease())
        assertEquals(listOf(BundledGeo.State.PRESERVED, BundledGeo.State.INSTALLED), results.map { it.state })
        verify(home, asn)
        assertEquals(2, opens)
    }

    @Test fun homeReplacedDuringStreamingCannotRedirectPublication() = home { parent ->
        val home = File(parent, "home").apply { check(mkdir()) }
        val moved = File(parent, "moved")
        val outside = File(parent, "outside").apply { check(mkdir()) }
        val owner = Lease()
        val synced = mutableListOf<FileDescriptor>()
        var changed = false
        val installer = BundledGeo(context.cacheDir.canonicalFile, { name ->
            check(home.renameTo(moved))
            Os.symlink(outside.path, home.path)
            changed = true
            input(name)
        }, { descriptor -> synced.add(descriptor); Os.fsync(descriptor) })
        try {
            rejects<android.system.ErrnoException> { installer.install(home, listOf(site), owner) }
            assertTrue(owner.active)
            assertTrue(outside.list()!!.isEmpty())
            assertTrue(moved.list()!!.isEmpty())
            assertEquals(2, synced.size)
            for (descriptor in synced) {
                assertFalse(descriptor.valid())
                rejects<android.system.ErrnoException> { Os.fstat(descriptor) }
            }
        } finally { if (changed) Os.remove(home.path) }
    }

    @Test fun aReplacementDirectoryCannotAdoptTheOldHomeCandidateOrLoseItsUserFile() = home { parent ->
        val home = File(parent, "home").apply { check(mkdir()) }
        val moved = File(parent, "moved")
        val owner = Lease()
        val installer = BundledGeo(context.cacheDir.canonicalFile, { name ->
            check(home.renameTo(moved))
            check(home.mkdir())
            File(home, site.targetName).writeText("replacement user bytes")
            input(name)
        })
        rejects<IOException> { installer.install(home, listOf(site), owner) }
        assertTrue(owner.active)
        assertEquals("replacement user bytes", File(home, site.targetName).readText())
        assertTrue(moved.list()!!.isEmpty())
        noTemporary(home)
    }

    @Test fun ownerInvalidatedAtPublicationCannotOverwriteUserBytesAndCleansItsTemporaryFile() = home { home ->
        val winner = "new user data before publication"
        val owner = Lease().apply {
            beforePublish = {
                File(home, site.targetName).writeText(winner)
                active = false
            }
        }
        rejects<CancellationException> {
            BundledGeo(context.cacheDir.canonicalFile, ::input).install(home, listOf(site), owner)
        }
        assertEquals(winner, File(home, site.targetName).readText())
        noTemporary(home)
    }

    @Test fun targetCreatedDuringCopyWinsBeforeControlledRenameWithoutBeingOverwritten() = home { home ->
        val winner = "user bytes created during asset copy"
        val installer = BundledGeo(context.cacheDir.canonicalFile, { name ->
            File(home, site.targetName).writeText(winner)
            input(name)
        })
        val result = installer.install(home, listOf(site), Lease()).single()
        assertEquals(BundledGeo.State.PRESERVED, result.state)
        assertEquals(winner, File(home, site.targetName).readText())
        noTemporary(home)
    }

    @Test fun realFileAndDirectorySyncsNeverHoldPublicationOrOwnerInvalidationArbitration() = home { home ->
        var inPublication = false
        var syncs = 0
        val owner = object : BundledGeo.Owner {
            override fun checkCurrent() {}
            override fun publishIfCurrent(block: () -> Unit) {
                inPublication = true
                try { block() } finally { inPublication = false }
            }
        }
        val installer = BundledGeo(context.cacheDir.canonicalFile, ::input, { descriptor ->
            assertFalse("Fsync must not prevent Stop from invalidating the current owner", inPublication)
            syncs++
            Os.fsync(descriptor)
        })
        assertEquals(BundledGeo.State.INSTALLED, installer.install(home, listOf(site), owner).single().state)
        assertEquals(2, syncs)
        verify(home, site)
        noTemporary(home)
    }

    @Test fun sharedCurrentOwnerSerializesConcurrentMissingChecksWithoutOverwritingWinner() = home { home ->
        val pool = Executors.newFixedThreadPool(2)
        val owner = Lease() // Real CoreHost has one current lease/publication arbitration, not independent owners.
        try {
            val futures = (1..2).map {
                pool.submit<BundledGeo.Result> { BundledGeo(context.cacheDir.canonicalFile, ::input).install(home, listOf(site), owner).single() }
            }
            val results = futures.map { it.get(30, TimeUnit.SECONDS) }
            assertEquals(1, results.count { it.state == BundledGeo.State.INSTALLED })
            assertEquals(1, results.count { it.state == BundledGeo.State.PRESERVED })
            verify(home, site)
            noTemporary(home)
        } finally { pool.shutdownNow() }
    }
}
