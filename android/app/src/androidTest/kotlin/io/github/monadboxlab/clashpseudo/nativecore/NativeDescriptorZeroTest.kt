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
            assertTrue("FD0 必须实际持有本次输入 inode", result.getBoolean("zeroOwnedBefore"))
            val rejected = result.getJSONObject("attach")
            val receipt = rejected.getJSONObject("receipt")
            assertEquals("callFailed", receipt.getJSONObject("error").getString("code"))
            assertEquals("descriptor or callback identity is invalid", receipt.getJSONObject("error").getString("message"))
            assertFalse("preflight 拒绝不能声称 Go 已受理", receipt.getBoolean("accepted"))
            assertTrue("exited 记录实际 JNI invoke 已返回", receipt.getBoolean("exited"))
            assertFalse("preflight 拒绝不产生 native terminal", rejected.has("terminal"))
            assertTrue(result.getBoolean("preflightInputRetained"))
            assertTrue(result.getBoolean("preflightOutputRetained"))
            assertTrue("先校验、后 detach：FD0 仍由 Kotlin 关闭", result.getBoolean("tunRetainedBeforeKotlinClose"))
            assertFalse(result.getBoolean("zeroOwnedAfterKotlinClose"))
            assertEquals(result.getLong("originalInode"), result.getLong("retainedOriginalInode"))
            assertEquals("FD0 拒绝不得触发 socket I/O", 0, result.getJSONObject("callbacks").getInt("calls"))
            assertFalse(result.getJSONObject("snapshot").getJSONObject("value").getBoolean("attached"))
            NativeCoreFailureTest.assertSuccess(result.getJSONObject("shutdown"))
            NativeCoreFailureTest.assertStopped(result.getJSONObject("after").getJSONObject("value"))
            driver.exit()
            assertTrue(driver.deathConfirmed)
            CoreIpcTestDriver.removeFixtureHome(driver.context, result)
        }
    }
}
