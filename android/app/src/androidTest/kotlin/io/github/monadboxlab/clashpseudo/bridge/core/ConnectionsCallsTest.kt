package io.github.monadboxlab.clashpseudo.bridge.core

import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.failure
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.success
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CoreTransportException
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ConnectionsCallsTest {
    private val id = "abcdef01-0000-4000-8000-000000000000"

    @Test fun boundedQueryAndCanonicalDetailIdentityReachTheRealRunningContext() {
        CoreBridgeIpcScenario(running = true).use { core ->
            val sample = success(core.query(Contract.CORE_OPERATION_CONNECTIONS,
                JSONObject().put("limit", 1000).put("previousActiveIds", JSONArray(listOf(id))).put("detailId", id)))
            assertTrue(sample.getBoolean("complete"))
            assertFalse(sample.getBoolean("limited"))
            assertEquals(0, sample.getInt("activeCount"))
            assertEquals(0, sample.getJSONArray("connections").length())
            assertFalse(sample.getJSONObject("presence").getBoolean(id))
            assertTrue(sample.getLong("sessionUploadBytes") >= 0)
            assertTrue(sample.getLong("sessionDownloadBytes") >= 0)
            assertEquals("absent", success(core.query(Contract.CORE_OPERATION_CONNECTION_CLOSE, JSONObject().put("id", id))).getString("status"))
            core.assertSameContext()
        }
    }

    @Test fun oversizedQueriesAreRejectedBeforeAdmissionAndMalformedQueriesKeepNativeErrors() {
        CoreBridgeIpcScenario(running = true).use { core ->
            val invalid = listOf(JSONObject().put("limit", 1001), JSONObject().put("limit", 0),
                JSONObject().put("limit", 1000).put("previousActiveIds", JSONArray(listOf(id, id))),
                JSONObject().put("limit", 1000).put("detailId", "invalid"))
            for (query in invalid) {
                assertTrue(query.toString().toByteArray(Charsets.UTF_8).size < Contract.CORE_IPC_CONTROL_BYTES)
                var admitted = false
                val pending = core.start(Contract.CORE_OPERATION_CONNECTIONS, query) { admitted = true }
                assertTrue("预算内的原负例须经真实 Binder 受理", admitted)
                val reply = core.await(pending)
                assertEquals("connection query failed", failure(reply).getString("message"))
                assertEquals("connection query failed", reply.terminal.getJSONObject("nativeReceipt").getJSONObject("error").getString("message"))
            }
            val oversized = listOf(
                JSONObject().put("limit", 1000).put("previousActiveIds", JSONArray(List(4000) { id })),
                JSONObject().put("limit", 1000).put("padding", "x".repeat(Contract.CONNECTION_REQUEST_BYTES)))
            for (query in oversized) {
                assertTrue(query.toString().toByteArray(Charsets.UTF_8).size > Contract.CORE_IPC_CONTROL_BYTES)
                var admitted = false
                val error = runCatching {
                    core.start(Contract.CORE_OPERATION_CONNECTIONS, query) { admitted = true }
                }.exceptionOrNull()
                assertTrue(error is CoreTransportException)
                assertEquals(Contract.CORE_ERROR_INPUT_TOO_LARGE, (error as CoreTransportException).code)
                assertEquals("内核输入分段 request 超过 ${Contract.CORE_IPC_CONTROL_BYTES} 字节", error.message)
                assertTrue(error.stackTraceToString().contains("CoreParts.validate"))
                assertFalse("超过 transport 预算的原输入不得进入 Binder 受理", admitted)
                core.assertSameContext()
            }
            val valid = success(core.query(Contract.CORE_OPERATION_CONNECTIONS, JSONObject().put("limit", 1000)))
            assertTrue(valid.getBoolean("complete"))
            core.assertSameContext()
        }
    }

    @Test fun closeRequiresCanonicalIdAndKeepsTheActualNativeRejection() {
        CoreBridgeIpcScenario(running = true).use { core ->
            for (invalid in listOf("", "one", "invalid", "00000000-0000-0000-0000-000000000000", id.uppercase())) {
                assertEquals("invalid connection ID", failure(core.query(Contract.CORE_OPERATION_CONNECTION_CLOSE, JSONObject().put("id", invalid))).getString("message"))
            }
            assertEquals("absent", success(core.query(Contract.CORE_OPERATION_CONNECTION_CLOSE, JSONObject().put("id", id))).getString("status"))
            assertTrue(success(core.query(Contract.CORE_OPERATION_CONNECTIONS, JSONObject().put("limit", 1000))).getBoolean("complete"))
            core.assertSameContext()
        }
    }

    @Test fun wrongFdIdentityCannotDisconnectOrPublishAConnectionSample() {
        CoreBridgeIpcScenario(running = true).use { core ->
            for (operation in listOf(Contract.CORE_OPERATION_CONNECTIONS, Contract.CORE_OPERATION_CONNECTION_CLOSE)) {
                val pending = core.start(operation, JSONObject().put("limit", 1000).put("id", id)) { it.put("inputId", "old-input") }
                assertEquals(Contract.CORE_ERROR_IDENTITY_MISMATCH, failure(core.await(pending)).getString("code"))
            }
            assertTrue(success(core.query(Contract.CORE_OPERATION_CONNECTIONS, JSONObject().put("limit", 1000))).getBoolean("complete"))
            core.assertSameContext()
        }
    }

    @Test fun coreRssUsesTheRemoteProcessWithoutPreparingAContext() {
        CoreIpcTestDriver.production().use { driver ->
            val before = System.currentTimeMillis()
            val pending = driver.submit(Contract.CORE_OPERATION_MEMORY)
            val sample = success(pending.await())
            assertTrue(driver.receipt(pending.id).getBoolean("exited"))
            assertTrue(sample.getBoolean("valid"))
            assertTrue(sample.getLong("processRssBytes") > 0)
            assertTrue(sample.getLong("sampledAt") in before..System.currentTimeMillis())
            assertNotEquals(android.os.Process.myPid(), driver.pid)
            assertFalse(success(driver.submit(Contract.CORE_OPERATION_SNAPSHOT).await()).getBoolean("prepared"))
            assertFalse(driver.status().getBoolean("vpnRunning"))
            CoreIpcTestDriver.assertNoGoInApplication()
        }
    }
}
