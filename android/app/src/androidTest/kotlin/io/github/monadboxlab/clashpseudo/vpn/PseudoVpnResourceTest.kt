package io.github.monadboxlab.clashpseudo.vpn

import android.os.ParcelFileDescriptor
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class PseudoVpnResourceTest {
    private fun descriptor(service: PseudoVpnService) = PseudoVpnService::class.java.getDeclaredField("descriptor")
        .apply { isAccessible = true }

    @Test fun attachFailureClosesOnlyTheKotlinOriginalAndPreservesIndependentNativeOwnership() {
        assertNull("This fixture does not replace a running resource host", PseudoVpnService.instance)
        val service = PseudoVpnService()
        val pipe = ParcelFileDescriptor.createPipe()
        val nativeCopy = ParcelFileDescriptor.dup(pipe[0].fileDescriptor)
        descriptor(service).set(service, pipe[0])
        val failure = IOException("ATTACH rejected the captured specification revision")
        try {
            val actual = assertThrows(IOException::class.java) {
                service.attach(pipe[0]) {
                    assertTrue(pipe[0].fileDescriptor.valid())
                    assertTrue(nativeCopy.fileDescriptor.valid())
                    throw failure
                }
            }
            assertSame(failure, actual)
            assertFalse(pipe[0].fileDescriptor.valid())
            assertNull(descriptor(service).get(service))
            assertTrue("JNI owns a separate descriptor", nativeCopy.fileDescriptor.valid())
        } finally { service.closeResources(); nativeCopy.close(); pipe.forEach { it.close() } }
    }

    @Test fun attachSuccessRetainsOriginalUntilCloseAndLateRollbackCannotCloseAnotherDescriptor() {
        assertNull(PseudoVpnService.instance)
        val service = PseudoVpnService()
        val pipe = ParcelFileDescriptor.createPipe()
        val stale = ParcelFileDescriptor.dup(pipe[0].fileDescriptor)
        descriptor(service).set(service, pipe[0])
        try {
            service.attach(pipe[0]) { }
            assertSame(pipe[0], descriptor(service).get(service))
            assertThrows(IOException::class.java) { service.attach(stale) { throw IOException("Retired attachment") } }
            assertTrue(pipe[0].fileDescriptor.valid())
            assertTrue(stale.fileDescriptor.valid())
            service.closeResources()
            assertFalse(pipe[0].fileDescriptor.valid())
            assertNull(descriptor(service).get(service))
            assertTrue(PseudoVpnService::class.java.getDeclaredField("resourcesClosed").apply { isAccessible = true }.getBoolean(service))
        } finally { service.closeResources(); stale.close(); pipe.forEach { it.close() } }
    }
}
