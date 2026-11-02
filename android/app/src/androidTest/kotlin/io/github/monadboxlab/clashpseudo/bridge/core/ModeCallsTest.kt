package io.github.monadboxlab.clashpseudo.bridge.core

import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.failure
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.success
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ModeCallsTest {
    @Test fun appliesAndReadsBackWithoutReplacingTheRealContext() {
        CoreBridgeIpcScenario().use { core ->
            assertEquals("rule", success(core.query(Contract.CORE_OPERATION_MODE)).getString("mode"))
            for (mode in listOf("global", "direct", "rule")) {
                assertEquals(mode, success(core.query(Contract.CORE_OPERATION_MODE_SET, JSONObject().put("mode", mode))).getString("mode"))
                assertEquals(mode, success(core.query(Contract.CORE_OPERATION_MODE)).getString("mode"))
                core.assertSameContext()
            }
        }
    }

    @Test fun invalidModeKeepsTheNativeRejectionAndDoesNotMutateTheContext() {
        CoreBridgeIpcScenario().use { core ->
            for (mode in listOf("", "follow", "https://user:pass@fixture.test/?token=原文🙂")) {
                val error = failure(core.query(Contract.CORE_OPERATION_MODE_SET, JSONObject().put("mode", mode)))
                assertEquals("invalid tunnel mode", error.getString("message"))
                assertEquals("rule", success(core.query(Contract.CORE_OPERATION_MODE)).getString("mode"))
                core.assertSameContext()
            }
        }
    }

    @Test fun wrongFdIdentityCannotMutateModeAndDoesNotReserveTheNextRequest() {
        CoreBridgeIpcScenario().use { core ->
            val pending = core.start(Contract.CORE_OPERATION_MODE_SET, JSONObject().put("mode", "direct")) { it.put("generation", -1) }
            assertEquals(Contract.CORE_ERROR_IDENTITY_MISMATCH, failure(core.await(pending)).getString("code"))
            assertEquals("rule", success(core.query(Contract.CORE_OPERATION_MODE)).getString("mode"))
            assertEquals("direct", success(core.query(Contract.CORE_OPERATION_MODE_SET, JSONObject().put("mode", "direct"))).getString("mode"))
        }
    }

    @Test fun stoppedModeReadsDoNotCreateANativeContext() {
        CoreIpcTestDriver.production().use { driver ->
            val pending = driver.submit(Contract.CORE_OPERATION_MODE)
            assertEquals("", success(pending.await()).getString("mode"))
            assertTrue(driver.receipt(pending.id).getBoolean("exited"))
            val snapshot = driver.submit(Contract.CORE_OPERATION_SNAPSHOT).await()
            assertFalse(success(snapshot).getBoolean("prepared"))
            assertFalse(driver.status().getBoolean("vpnRunning"))
            CoreIpcTestDriver.assertNoGoInApplication()
        }
    }
}
