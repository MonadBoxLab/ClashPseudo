package io.github.monadboxlab.clashpseudo.bridge.core

import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.success
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CorePlatformTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.input.CoreInput
import org.junit.Assert.*
import org.junit.Test

class AppBridgeDnsTest {
    @Test fun productionCoreClientRequiresTheTransportIdentityBeforeDnsAdmission() {
        val platform = CorePlatformTestDriver()
        val visible = platform.keepPreviewVisible()
        try {
            success(platform.prepare(CoreInput("dns-main", 7, null, CoreBridgeIpcScenario.DIRECT.toByteArray(Charsets.UTF_8), "{}".toByteArray(), name = "dns-main"), vpn = false))
            val captured = platform.status()
            for (operation in listOf(Contract.CORE_OPERATION_DNS_QUERY, Contract.CORE_OPERATION_DNS_CACHE_CLEAR, Contract.CORE_OPERATION_FAKE_IP_FLUSH)) {
                for (field in listOf("protocol", "processId", "generation", "inputId", "networkRevision")) {
                    for (missing in listOf(true, false)) {
                        val identity = captured.toMutableMap().apply {
                            if (missing) remove(field) else this[field] = when (field) { "processId", "inputId" -> "wrong"; else -> -1L }
                        }
                        val error = runCatching {
                            platform.channel(Contract.CORE_CHANNEL_SUBMIT, mapOf("operation" to operation, "identity" to identity,
                                "arguments" to mapOf("name" to "test.test", "type" to "A")))
                        }.exceptionOrNull()
                        assertTrue("$operation/$field/$missing", error is CorePlatformTestDriver.ChannelFailure)
                        val failure = error as CorePlatformTestDriver.ChannelFailure
                        assertTrue(failure.details is String)
                        assertTrue((failure.details as String).contains("stack"))
                    }
                }
            }
            assertEquals("unavailable", success(platform.query(Contract.CORE_OPERATION_DNS_QUERY,
                mapOf("name" to "test.test", "type" to "A"))).getString("error"))
            val cache = success(platform.query(Contract.CORE_OPERATION_DNS_CACHE_CLEAR))
            assertTrue(cache.getString("status") in setOf("empty", "completed"))
            assertEquals(captured["processId"], platform.status()["processId"])
            assertEquals(captured["inputId"], platform.status()["inputId"])
            CoreIpcTestDriver.assertNoGoInApplication()
        } finally {
            try { platform.exit() } finally { visible.close() }
        }
    }
}
