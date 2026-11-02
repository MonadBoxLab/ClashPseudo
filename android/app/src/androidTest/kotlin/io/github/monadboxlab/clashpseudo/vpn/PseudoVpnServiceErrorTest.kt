package io.github.monadboxlab.clashpseudo.vpn

import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.debug.CoreFixtureContract
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CorePlatformTestDriver
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class PseudoVpnServiceErrorTest {
    @Test fun systemForegroundFailureKeepsItsCauseWithoutInventingANativeStart() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val platform = CorePlatformTestDriver(context)
        platform.await("应用空闲") { AppBridge.operationId == null && !AppBridge.logic.busy }
        val before = CoreIpcTestDriver.onMain { PseudoVpnService.session.snapshot() }
        assertEquals(NativeSession.Phase.STOPPED, before.phase)
        assertFalse(CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java))
        val original = "https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture"
        CoreIpcTestDriver.fixture().use { remote ->
            CoreIpcTestDriver.bindVpnResource(context).use {
                for ((action, type) in listOf(
                    CoreFixtureContract.FOREGROUND_IO_FAILURE to IOException::class.java.name,
                    CoreFixtureContract.FOREGROUND_LINKAGE_FAILURE to UnsatisfiedLinkError::class.java.name,
                )) {
                    val failure = remote.debug.serviceControl(action)
                    assertTrue("远端必须保留抛出的同一 Throwable", failure.getBoolean("sameThrowable"))
                    assertEquals(failure.getString("expected"), failure.getString("actualStack"))
                    val actual = JSONObject(checkNotNull(failure.getString("actual")))
                    assertEquals(type, actual.getString("type"))
                    assertEquals(original, actual.getString("message"))
                    assertTrue(actual.isNull("cause"))
                    assertEquals(0, actual.getJSONArray("suppressed").length())
                    assertFalse(failure.getBoolean("waitingForRuntime"))
                    assertFalse("foreground 失败不能装载 Go", failure.getBoolean("nativeLoaded"))
                    assertTrue(remote.binder.isBinderAlive)
                    assertFalse(remote.deathConfirmed)
                    val after = CoreIpcTestDriver.onMain { PseudoVpnService.session.snapshot() }
                    assertEquals(before.generation, after.generation)
                    assertEquals(NativeSession.Phase.STOPPED, after.phase)
                    assertEquals(before.error, after.error)
                    CoreIpcTestDriver.assertNoGoInApplication()
                }
            }
            platform.await("本次 VPN Service 销毁") {
                !CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java)
            }
            remote.exit()
        }
    }
}
