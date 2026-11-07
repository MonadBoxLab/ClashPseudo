package io.github.monadboxlab.clashpseudo.nativecore

import io.github.monadboxlab.clashpseudo.debug.CoreFixtureContract as Fixture
import org.junit.Assert.*
import org.junit.Test

class NativeDescriptorZeroTest {
    @Test fun descriptorZeroPreflightKeepsKotlinOwnershipWithoutEnteringExternalFdConstructor() {
        CoreIpcTestDriver.fixture().use { driver ->
            val reply = driver.fixture(Fixture.FD_ZERO).await()
            assertTrue(reply.terminal.toString(), reply.terminal.getBoolean("complete"))
            val result = reply.value
            NativeCoreFailureTest.assertSuccess(result.getJSONObject("prepare"))
            assertEquals(0, result.getInt("zeroFd"))
            assertTrue("FD0 must actually hold this input's inode", result.getBoolean("zeroOwnedBefore"))
            val rejected = result.getJSONObject("attach")
            val receipt = rejected.getJSONObject("receipt")
            assertEquals("callFailed", receipt.getJSONObject("error").getString("code"))
            assertEquals("descriptor or callback identity is invalid", receipt.getJSONObject("error").getString("message"))
            assertFalse("Preflight rejection must not claim admission by Go", receipt.getBoolean("accepted"))
            assertTrue("exited records that the actual JNI invoke has returned", receipt.getBoolean("exited"))
            assertFalse("Preflight rejection produces no native terminal frame", rejected.has("terminal"))
            assertTrue(result.getBoolean("preflightInputRetained"))
            assertTrue(result.getBoolean("preflightOutputRetained"))
            assertTrue("Validate before detach: Kotlin still closes FD0", result.getBoolean("tunRetainedBeforeKotlinClose"))
            assertFalse(result.getBoolean("zeroOwnedAfterKotlinClose"))
            assertEquals(result.getLong("originalInode"), result.getLong("retainedOriginalInode"))
            assertEquals("FD0 rejection must not trigger socket I/O", 0, result.getJSONObject("callbacks").getInt("calls"))
            assertFalse(result.getJSONObject("snapshot").getJSONObject("value").getBoolean("attached"))
            NativeCoreFailureTest.assertSuccess(result.getJSONObject("shutdown"))
            NativeCoreFailureTest.assertStopped(result.getJSONObject("after").getJSONObject("value"))
            driver.exit()
            assertTrue(driver.deathConfirmed)
            CoreIpcTestDriver.removeFixtureHome(driver.context, result)
        }
    }
}
