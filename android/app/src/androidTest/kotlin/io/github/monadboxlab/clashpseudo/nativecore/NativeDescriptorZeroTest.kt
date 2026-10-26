package io.github.monadboxlab.clashpseudo.nativecore

import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.app.AppTrust
import java.io.File
import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Run alone: FD zero is owned stdin in this disposable instrumentation process. */
class NativeDescriptorZeroTest {
    @Test fun detachedDescriptorZeroIsConsumedWithoutEnteringTheExternalFdConstructor() {
        val selector = InstrumentationRegistry.getArguments().getString("class")
        require(selector == javaClass.name ||
            selector == javaClass.name + "#detachedDescriptorZeroIsConsumedWithoutEnteringTheExternalFdConstructor")
        require(Os.readlink("/proc/self/fd/0") == "/dev/null")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        CoreHost.installAndroid(context)
        assertEquals("", NativeCore.initializeTrust(AppTrust.pem(context).toByteArray(Charsets.UTF_8)))
        assertFalse(JSONObject(NativeCore.snapshot()).getBoolean("prepared"))
        val home = File(context.cacheDir, "native-fd-zero-${UUID.randomUUID()}")
        assertTrue(home.mkdir())
        try {
            val body = "mode: rule\nlog-level: silent\nfind-process-mode: off\ndns: {enable: false}\n" +
                "geox-url: {geoip: '', geosite: '', mmdb: '', asn: ''}\nrules: ['MATCH,DIRECT']\n"
            // Construct metadata with DNS disabled.
            val network = JSONObject().put("id", "fd-zero-fixture")
                .put("servers", org.json.JSONArray().put("192.168.100.2")).put("privateDns", "off")
            val options = JSONObject().put("purpose", "VPN").put("generation", 1).put("network", network)
                .put("composition", "native-fd-zero").toString().toByteArray(Charsets.UTF_8)
            val protector = NativeCoreFailureTest.Protector()
            assertEquals("", NativeCore.prepare(home.path, body.toByteArray(Charsets.UTF_8), "rule",
                protector, options = options))
            val revision = JSONObject(NativeCore.vpnSpec()).getLong("revision")
            val marker = File(home, "owned-zero-input").apply { writeBytes(byteArrayOf()) }
            ParcelFileDescriptor.open(marker, ParcelFileDescriptor.MODE_READ_WRITE).use { original ->
                assertTrue(original.fd > 0)
                val identity = Os.fstat(original.fileDescriptor)
                // Close only verified raw stdin, then acquire descriptor zero while
                // free. Ownership transfers with the descriptor.
                require(Os.readlink("/proc/self/fd/0") == "/dev/null")
                ParcelFileDescriptor.adoptFd(0).close()
                val reserved = Os.fcntlInt(original.fileDescriptor, OsConstants.F_DUPFD_CLOEXEC, 0)
                if (reserved != 0) {
                    ParcelFileDescriptor.adoptFd(reserved).close()
                    fail("FD zero was reused; refusing to overwrite another resource")
                }
                val input = ParcelFileDescriptor.adoptFd(reserved)
                input.use {
                    assertEquals(0, it.fd)
                    assertEquals(identity.st_ino, Os.stat("/proc/self/fd/0").st_ino)
                    val retained = runCatching { assertNotOwnedZero(identity.st_dev, identity.st_ino) }.exceptionOrNull()
                    assertTrue("Ownership probe accepted the live original input", retained is AssertionError)
                    val error = NativeCore.attach(it, revision)
                    assertTrue(error, error.contains("descriptor zero is reserved"))
                }
                assertNotOwnedZero(identity.st_dev, identity.st_ino)
                assertFalse(JSONObject(NativeCore.snapshot()).getBoolean("attached"))
                assertEquals("", NativeCore.stop())
                assertEquals("FD0 check issued unexpected socket I/O", 0, protector.calls.get())
                assertNotOwnedZero(identity.st_dev, identity.st_ino)
            }
        } finally {
            NativeCore.cancel()
            assertEquals("", NativeCore.stop())
            val state = JSONObject(NativeCore.snapshot())
            assertFalse(state.getBoolean("prepared"))
            assertFalse(state.getBoolean("attached"))
            assertFalse(state.getBoolean("cleanupFailed"))
            assertTrue(home.deleteRecursively())
        }
    }

    private fun assertNotOwnedZero(device: Long, inode: Long) {
        val current = try { Os.stat("/proc/self/fd/0") }
        catch (error: ErrnoException) {
            if (error.errno != OsConstants.ENOENT && error.errno != OsConstants.EBADF) throw error
            null
        }
        assertFalse("Transferred descriptor still owns the input resource",
            current != null && current.st_dev == device && current.st_ino == inode)
    }
}
