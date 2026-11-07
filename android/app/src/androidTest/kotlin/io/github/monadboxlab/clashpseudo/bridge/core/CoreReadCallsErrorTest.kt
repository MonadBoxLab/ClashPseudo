package io.github.monadboxlab.clashpseudo.bridge.core

import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.collection
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.failure
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CoreReadCallsErrorTest {
    @Test fun everyDiagnosticOperationRejectsFdMetadataMismatchAndAllowsAnActualRetry() {
        CoreBridgeIpcScenario(CoreBridgeIpcScenario.STRATEGIES).use { core ->
            val operations = listOf(Contract.CORE_OPERATION_RUNTIME_CONFIG, Contract.CORE_OPERATION_NODES,
                Contract.CORE_OPERATION_RULES, Contract.CORE_OPERATION_RESOURCES, Contract.CORE_OPERATION_STRATEGIES,
                Contract.CORE_OPERATION_DNS_QUERY, Contract.CORE_OPERATION_DNS_CACHE_CLEAR, Contract.CORE_OPERATION_FAKE_IP_FLUSH)
            for (operation in operations) {
                val pending = core.start(operation) { it.put("requestId", Long.MAX_VALUE) }
                val rejected = core.await(pending)
                val error = failure(rejected)
                assertEquals(Contract.CORE_ERROR_IDENTITY_MISMATCH, error.getString("code"))
                assertEquals("Pipe request does not match the control identity", error.getString("message"))
                assertEquals("io.github.monadboxlab.clashpseudo.nativecore.CoreTransportException", error.getString("type"))
                assertTrue(error.getString("stack").contains("verifyMetadata"))
            }
            assertTrue(collection(core.query(Contract.CORE_OPERATION_NODES)).any { it.getString("name") == "节点🌐" })
            core.assertSameContext()
        }
    }

    @Test fun ruleScopeErrorsKeepTheNativeReasonAndTheirSourceWhileLaterReadsRemainUsable() {
        CoreBridgeIpcScenario().use { core ->
            for ((kind, message) in listOf("sub" to "sub-rule group is unavailable", "provider" to "rule provider is unavailable")) {
                val reply = core.query(Contract.CORE_OPERATION_RULES, JSONObject().put("kind", kind).put("name", "https://user:pass@fixture.test/?token=原文🙂"))
                assertEquals(message, failure(reply).getString("message"))
                assertEquals(0, reply.records.size)
                assertEquals(reply.metadata.single().getString("source"), reply.terminal.getString("source"))
            }
            assertEquals(1, collection(core.query(Contract.CORE_OPERATION_RULES)).size)
            core.assertSameContext()
        }
    }

    @Test fun missingNodeSourceKeepsItsActualNativeFailureInsteadOfAnEmptySuccess() {
        CoreBridgeIpcScenario().use { core ->
            val reply = core.query(Contract.CORE_OPERATION_NODES, JSONObject().put("source", "missing-provider-原文🙂"))
            assertEquals("proxy provider source is unavailable", failure(reply).getString("message"))
            assertEquals(0, reply.records.size)
            assertEquals(reply.metadata.single().getString("source"), reply.terminal.getString("source"))
            assertTrue(collection(core.query(Contract.CORE_OPERATION_NODES)).isNotEmpty())
            core.assertSameContext()
        }
    }

    @Test fun capturedNativeErrorRemainsReadableAfterItsOwningProcessExits() {
        val captured = CoreBridgeIpcScenario().use { core ->
            val reply = core.query(Contract.CORE_OPERATION_RULES, JSONObject().put("kind", "sub").put("name", "missing"))
            failure(reply)
            Triple(reply, reply.terminal.toString(), core.driver.processId)
        }
        CoreBridgeIpcScenario().use { replacement ->
            assertNotEquals(captured.third, replacement.driver.processId)
            assertEquals(captured.second, captured.first.terminal.toString())
            assertEquals("sub-rule group is unavailable", failure(captured.first).getString("message"))
            replacement.assertSameContext()
        }
    }
}
