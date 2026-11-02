package io.github.monadboxlab.clashpseudo.bridge.core

import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.failure
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.success
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class DnsCallsTest {
    @Test fun dnsAndBothCacheActionsRequireTheSameControlAndFdIdentity() {
        CoreBridgeIpcScenario().use { core ->
            for (operation in listOf(Contract.CORE_OPERATION_DNS_QUERY, Contract.CORE_OPERATION_DNS_CACHE_CLEAR, Contract.CORE_OPERATION_FAKE_IP_FLUSH)) {
                for (field in listOf("protocol", "processId", "generation", "inputId", "requestId", "networkRevision", "operation")) {
                    val pending = core.start(operation, JSONObject().put("name", "test.test").put("type", "A")) {
                        it.put(field, when (field) { "processId", "inputId" -> "wrong"; else -> -1L })
                    }
                    assertEquals("$operation/$field", Contract.CORE_ERROR_IDENTITY_MISMATCH, failure(core.await(pending)).getString("code"))
                }
            }
            val query = success(core.query(Contract.CORE_OPERATION_DNS_QUERY, JSONObject().put("name", "test.test").put("type", "A")))
            assertEquals("unavailable", query.getString("error"))
            val cleared = success(core.query(Contract.CORE_OPERATION_DNS_CACHE_CLEAR))
            assertTrue(cleared.getString("status") in setOf("empty", "completed"))
            assertFalse(cleared.getBoolean("stale"))
            val flushed = success(core.query(Contract.CORE_OPERATION_FAKE_IP_FLUSH))
            assertEquals("empty", flushed.getString("status"))
            assertFalse(flushed.getJSONObject("ipv4").getBoolean("active"))
            assertFalse(flushed.getJSONObject("ipv6").getBoolean("active"))
            core.assertSameContext()
        }
    }

    @Test fun unsupportedDnsTypeKeepsTheCompleteNativeDiagnostic() {
        CoreBridgeIpcScenario().use { core ->
            val original = "https://user:pass@fixture.test/?token=原文🙂"
            val response = success(core.query(Contract.CORE_OPERATION_DNS_QUERY,
                JSONObject().put("name", "test.test").put("type", original)))
            assertEquals("invalidRequest", response.getString("error"))
            assertEquals("unsupported DNS question type: ${original.uppercase(java.util.Locale.ROOT)}", response.getString("detail"))
            assertEquals("unavailable", success(core.query(Contract.CORE_OPERATION_DNS_QUERY,
                JSONObject().put("name", "test.test").put("type", "A"))).getString("error"))
            core.assertSameContext()
        }
    }

    @Test fun cancelAllocatesAnIndependentRequestAndCannotCancelAFinishedReplacementRead() {
        CoreBridgeIpcScenario().use { core ->
            val first = core.start(Contract.CORE_OPERATION_DNS_QUERY, JSONObject().put("name", "test.test").put("type", "A"))
            assertEquals("unavailable", success(core.await(first)).getString("error"))
            val next = core.start(Contract.CORE_OPERATION_DNS_QUERY, JSONObject().put("name", "next.test").put("type", "A"))
            val cancel = core.start(Contract.CORE_OPERATION_CANCEL, JSONObject().put("targetRequestId", first.id))
            assertNotEquals(first.id, cancel.id)
            assertNotEquals(next.id, cancel.id)
            success(core.await(cancel))
            assertEquals("unavailable", success(core.await(next)).getString("error"))
            core.assertSameContext()
        }
    }
}
