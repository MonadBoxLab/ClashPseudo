package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.app.AppFiles
import io.github.monadboxlab.clashpseudo.app.AppWorkService
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Explicitly authorized capture and read-only verification of the stopped main package's GeoIP. */
class GeoResourceBaselineTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val nonce = "p5-load-geo-r7w7"

    @Test fun exportStoppedGeoIpBaselineWithoutChangingTheResource() {
        val context = checkedContext()
        val stopped = assertStopped()

        // AppFiles is also the production authority for the noBackup/mihomo home.
        val home = AppFiles.core(context)
        val homeBefore = existing(home)
        assertTrue("The formal core home must be a directory, not a symlink",
            OsConstants.S_ISDIR(homeBefore.st_mode))
        val source = File(home, "GeoIP.dat")
        val before = sourceStat(source)

        val external = context.getExternalFilesDir(null)
        assertNotNull("The application's own external files directory is unavailable", external)
        val directory = File(external!!, "validation-geo-$nonce")
        assertTrue("The baseline directory must be newly created; never reuse it", directory.mkdir())
        val directoryBefore = existing(directory)
        assertTrue("The new baseline directory must not be a symlink",
            OsConstants.S_ISDIR(directoryBefore.st_mode))
        val destination = File(directory, "GeoIP.dat")
        assertTrue("The baseline file must be newly created; never overwrite it", destination.createNewFile())
        val destinationBefore = existing(destination)
        assertTrue("The new baseline file must be regular", OsConstants.S_ISREG(destinationBefore.st_mode))
        assertEquals(0L, destinationBefore.st_size)
        assertEquals(1L, destinationBefore.st_nlink)

        // Open the previously created destination for writing with NOFOLLOW.
        val outputFd = Os.open(destination.absolutePath,
            OsConstants.O_WRONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
        val captured = try {
            sameSource(destinationBefore, Os.fstat(outputFd))
            val copied = FileOutputStream(outputFd).use { output ->
                val result = fingerprint(source, before, output)
                output.flush()
                output.fd.sync()
                result
            }
            assertEquals("The synced baseline has the wrong size", copied.first, Os.fstat(outputFd).st_size)
            copied
        } finally {
            // Android's FileOutputStream(FileDescriptor) borrows this descriptor.
            Os.close(outputFd)
        }
        val (bytes, sha256) = captured

        assertStopped(stopped)
        val exported = sourceStat(destination)
        assertEquals(destinationBefore.st_dev, exported.st_dev)
        assertEquals(destinationBefore.st_ino, exported.st_ino)
        assertEquals(destinationBefore.st_nlink, exported.st_nlink)
        assertEquals(bytes, exported.st_size)
        assertEquals("The saved baseline must contain the captured bytes", captured, fingerprint(destination, exported))
        assertEquals("The formal GeoIP must still contain the captured bytes", captured, fingerprint(source, before))
        assertStopped(stopped)
        sameSource(before, existing(source))
        sameSource(exported, existing(destination))
        sameDirectory(homeBefore, existing(home))
        sameDirectory(directoryBefore, existing(directory))
        Log.i("PseudoGeoBaseline",
            "nonce=$nonce absolutePath=${destination.absolutePath} bytes=$bytes sha256=$sha256")
        // Preserve the original resource and suspect export on failure.
    }

    @Test fun verifyStoppedGeoIpMatchesProtectedBaseline() {
        val context = checkedContext()
        val stopped = assertStopped()
        val home = AppFiles.core(context)
        val homeBefore = existing(home)
        assertTrue("The formal core home must be a directory, not a symlink",
            OsConstants.S_ISDIR(homeBefore.st_mode))
        val external = context.getExternalFilesDir(null)
        assertNotNull("The application's own external files directory is unavailable", external)
        val directory = File(external!!, "validation-geo-$nonce")
        val directoryBefore = existing(directory)
        assertTrue("The protected baseline directory must not be a symlink",
            OsConstants.S_ISDIR(directoryBefore.st_mode))
        val baseline = File(directory, "GeoIP.dat")
        val baselineBefore = sourceStat(baseline)
        val source = File(home, "GeoIP.dat")
        val sourceBefore = sourceStat(source)
        val expected = fingerprint(baseline, baselineBefore)
        val actual = fingerprint(source, sourceBefore)
        assertEquals("Current GeoIP byte count must equal the protected baseline", expected.first, actual.first)
        assertEquals("Current GeoIP SHA-256 must equal the protected baseline", expected.second, actual.second)
        assertStopped(stopped)
        sameSource(baselineBefore, existing(baseline))
        sameSource(sourceBefore, existing(source))
        sameDirectory(homeBefore, existing(home))
        sameDirectory(directoryBefore, existing(directory))
        Log.i("PseudoGeoBaseline",
            "nonce=$nonce absolutePath=${source.absolutePath} baselinePath=${baseline.absolutePath} " +
                "bytes=${actual.first} sha256=${actual.second} matches=true")
    }

    private fun checkedContext(): Context {
        assertEquals("An explicit matching nonce is required", nonce,
            InstrumentationRegistry.getArguments().getString("nonce"))
        val context = instrumentation.targetContext.applicationContext
        assertEquals("Only the main application package owns this baseline",
            "io.github.monadboxlab.clashpseudo", context.packageName)
        assertTrue("The companion main package must be a debug build",
            context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0)
        return context
    }

    private fun sourceStat(file: File): StructStat = existing(file).also { stat ->
        assertTrue("GeoIP must be a regular file, not a symlink", OsConstants.S_ISREG(stat.st_mode))
        assertEquals("GeoIP must not have other hard links", 1L, stat.st_nlink)
        assertTrue("GeoIP must contain 1..32 MiB of existing bytes",
            stat.st_size in 1L..(32L * 1024 * 1024))
    }

    private fun fingerprint(source: File, before: StructStat, output: FileOutputStream? = null): Pair<Long, String> {
        val digest = MessageDigest.getInstance("SHA-256")
        var bytes = 0L
        val descriptor = Os.open(source.absolutePath,
            OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
        try {
            sameSource(before, Os.fstat(descriptor))
            FileInputStream(descriptor).use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    bytes += count
                    assertTrue("GeoIP grew while being read", bytes <= before.st_size)
                    digest.update(buffer, 0, count)
                    output?.write(buffer, 0, count)
                }
                assertEquals("GeoIP byte count changed while being read", before.st_size, bytes)
                sameSource(before, Os.fstat(descriptor))
            }
        } finally {
            // Android's FileInputStream(FileDescriptor) borrows this descriptor.
            Os.close(descriptor)
        }
        sameSource(before, existing(source))
        return bytes to digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun sameDirectory(before: StructStat, after: StructStat) {
        assertTrue("The directory must remain a directory, not a symlink", OsConstants.S_ISDIR(after.st_mode))
        assertEquals("Directory device changed", before.st_dev, after.st_dev)
        assertEquals("Directory inode changed", before.st_ino, after.st_ino)
    }

    private fun assertStopped(expected: Pair<Long, Long>? = null): Pair<Long, Long> {
        val deadline = SystemClock.elapsedRealtime() + 35_000
        var identity = expected
        while (true) {
            val expectedIdentity = identity
            val task = FutureTask {
                val session = PseudoVpnService.session.snapshot()
                val core = PseudoVpnService.core.snapshot()
                assertEquals(NativeSession.Phase.STOPPED, session.phase)
                assertEquals(CoreHost.Phase.EMPTY, core.phase)
                assertNull("The VPN Service must have actually stopped", PseudoVpnService.instance)
                assertNull("The work Service must have actually stopped", AppWorkService.instance)
                val currentIdentity = session.generation to core.generation
                if (expectedIdentity != null) {
                    assertEquals("The stopped session/core identity must never change", expectedIdentity, currentIdentity)
                }
                val state = AppBridge.runtimeState()
                for (key in listOf("resourceBusy", "storageRestoring", "pendingStart",
                    "pendingSystemStart", "pendingRestore")) {
                    assertEquals("$key must remain false while awaiting idle", false, state[key])
                }
                val command = AppBridge.command
                val idle = !AppBridge.logic.busy && AppBridge.operationId == null && command == null &&
                    state["writerBusy"] == false && state["scheduleBusy"] == false
                if (!idle) {
                    // Allow startup schedule reconciliation to drain before requiring
                    // business-idle state.
                    assertEquals("Only normal startup calibration may drain", "syncSchedules", command?.get("action"))
                }
                currentIdentity to (idle && state["storageReady"] == true)
            }
            instrumentation.runOnMainSync(task)
            val (currentIdentity, idle) = task.get(10, TimeUnit.SECONDS)
            identity = currentIdentity
            val native = JSONObject(NativeCore.snapshot())
            assertFalse("The native core must not be prepared", native.getBoolean("prepared"))
            assertFalse("The native core must not be attached", native.getBoolean("attached"))
            assertFalse("Native cleanup must have succeeded", native.getBoolean("cleanupFailed"))
            if (idle) return currentIdentity
            assertTrue("Timed out waiting for normal startup calibration and the actual writer drain",
                SystemClock.elapsedRealtime() < deadline)
            Thread.sleep(25)
        }
    }

    private fun existing(file: File): StructStat = try {
        Os.lstat(file.absolutePath)
    } catch (error: ErrnoException) {
        throw AssertionError("Required baseline material is missing or inaccessible: ${file.absolutePath}", error)
    }

    private fun sameSource(before: StructStat, after: StructStat) {
        assertTrue("The file must remain regular and not a symlink", OsConstants.S_ISREG(after.st_mode))
        assertEquals("File device changed", before.st_dev, after.st_dev)
        assertEquals("File inode changed", before.st_ino, after.st_ino)
        assertEquals("File size changed", before.st_size, after.st_size)
        assertEquals("File link count changed", before.st_nlink, after.st_nlink)
        assertEquals("File modification time changed", before.st_mtime, after.st_mtime)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            assertEquals("File modification seconds changed", before.st_mtim.tv_sec, after.st_mtim.tv_sec)
            assertEquals("File modification nanoseconds changed", before.st_mtim.tv_nsec, after.st_mtim.tv_nsec)
        }
    }
}
