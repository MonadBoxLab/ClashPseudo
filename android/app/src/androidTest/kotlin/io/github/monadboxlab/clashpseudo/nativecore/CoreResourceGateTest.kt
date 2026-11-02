package io.github.monadboxlab.clashpseudo.nativecore

import android.system.Os
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.fixture.HardlinkPrerequisites
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import java.util.UUID

class CoreResourceGateTest {
    private fun directory() = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir,
        "core-gate-${UUID.randomUUID()}").apply { check(mkdir()) }

    @Test fun sameProcessCannotOpenAnotherDescriptorAndReleaseTheLiveOwnerLock() {
        val directory = directory()
        try {
            val file = File(directory, "core.lock")
            val first = CoreResourceGate(file).tryAcquire()!!
            try {
                assertNull(CoreResourceGate(file).tryAcquire())
                assertNull(CoreResourceGate(file).tryAcquire())
            } finally { first.close() }
            CoreResourceGate(file).tryAcquire()!!.close()
            first.close()
            CoreResourceGate(file).tryAcquire()!!.close()
        } finally { directory.deleteRecursively() }
    }

    @Test fun cleanupDoesNotRunUntilTheOwnerActuallyReleasesItsDescriptor() {
        val directory = directory()
        try {
            val file = File(directory, "core.lock")
            val owner = CoreResourceGate(file).tryAcquire()!!
            var deleted = false
            assertThrows(IOException::class.java) { CoreResourceGate(file).exclusive { deleted = true } }
            assertFalse(deleted)
            owner.close()
            CoreResourceGate(file).exclusive { deleted = true }
            assertTrue(deleted)
        } finally { directory.deleteRecursively() }
    }

    @Test fun linkedOrMultiplyLinkedLockFileIsRejectedWithoutChangingItsTarget() {
        val directory = directory()
        try {
            val target = File(directory, "identity").apply { writeText("保留协议身份") }
            val link = File(directory, "core.lock")
            Os.symlink(target.path, link.path)
            assertThrows(Exception::class.java) { CoreResourceGate(link).tryAcquire() }
            assertEquals("保留协议身份", target.readText())
            link.delete()
            HardlinkPrerequisites.link(target, link,
                "io.github.monadboxlab.clashpseudo.nativecore.CoreResourceGateTest#linkedOrMultiplyLinkedLockFileIsRejectedWithoutChangingItsTarget")
            assertThrows(IOException::class.java) { CoreResourceGate(link).tryAcquire() }
            assertEquals("保留协议身份", target.readText())
        } finally { directory.deleteRecursively() }
    }
}
