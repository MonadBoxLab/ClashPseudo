package io.github.monadboxlab.clashpseudo.bridge.core

import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import org.json.JSONObject
import org.junit.Assert.*
import java.io.Closeable

/** 在真实 :core process 中装载一次配置；查询复用捕获的 inputId 和 generation。 */
internal class CoreBridgeIpcScenario(body: String = DIRECT, running: Boolean = false) : Closeable {
    val driver = CoreIpcTestDriver.production()
    val identity: android.os.Bundle

    init {
        try {
            val prepared = if (running) {
                val inputId = java.util.UUID.randomUUID().toString()
                val args = JSONObject().put("purpose", Contract.CORE_PURPOSE_RUNNING).put("vpnIntent", false).put("lanIntent", false)
                    .put("configId", "fixture").put("revision", 1).put("mode", "rule")
                    .put("deadline", android.os.SystemClock.elapsedRealtime() + Contract.OPERATION_ORDINARY_TIMEOUT_MS)
                val pending = driver.submit(Contract.CORE_OPERATION_PREPARE, args, inputId, 1,
                    parts = mapOf(Contract.CORE_PART_CONFIG to body.toByteArray(Charsets.UTF_8),
                        Contract.CORE_PART_OVERRIDES to "[]".toByteArray(),
                        Contract.CORE_PART_OPTIONS to JSONObject().put("purpose", Contract.CORE_PURPOSE_RUNNING)
                            .put("generation", 1).put("composition", "test-$inputId").toString().toByteArray(Charsets.UTF_8)))
                pending.await(120).also {
                    val receipt = driver.receipt(pending.id)
                    assertTrue(receipt.toString(), receipt.getBoolean("exited"))
                    it.terminal.put("nativeReceipt", receipt)
                }
            } else driver.prepare(body.toByteArray(Charsets.UTF_8))
            success(prepared)
            identity = driver.status()
            assertEquals(Contract.CORE_PHASE_READY, identity.getString("phase"))
            assertEquals(if (running) Contract.CORE_PURPOSE_RUNNING else Contract.CORE_PURPOSE_PREVIEW, identity.getString("purpose"))
            assertFalse(identity.getBoolean("vpnRunning"))
        } catch (error: Throwable) {
            try { driver.close() } catch (close: Throwable) { error.addSuppressed(close) }
            throw error
        }
    }

    fun start(operation: Int, arguments: JSONObject = JSONObject(), metadata: (JSONObject) -> Unit = {}): CoreIpcTestDriver.Pending =
        driver.submit(operation, arguments, identity.getString("inputId"), identity.getLong("generation"), metadata = metadata)

    fun await(pending: CoreIpcTestDriver.Pending): CoreIpcTestDriver.Reply = pending.await().also {
        val receipt = driver.receipt(pending.id)
        assertTrue("调用结束须收到真实 native receipt", receipt.getBoolean("exited"))
        assertTrue(it.terminal.toString(), it.terminal.getBoolean("exited"))
        it.terminal.put("nativeReceipt", receipt)
    }

    fun query(operation: Int, arguments: JSONObject = JSONObject()): CoreIpcTestDriver.Reply = await(start(operation, arguments))

    fun assertSameContext() {
        val current = driver.status()
        for (key in listOf("processId", "inputId", "generation", "networkRevision"))
            assertEquals(key, identity.get(key), current.get(key))
        assertEquals(Contract.CORE_PHASE_READY, current.getString("phase"))
        assertTrue(success(query(Contract.CORE_OPERATION_SNAPSHOT)).getBoolean("prepared"))
        CoreIpcTestDriver.assertNoGoInApplication()
    }

    override fun close() = driver.close()

    companion object {
        const val DIRECT = "mode: rule\nfind-process-mode: off\nlog-level: debug\ngeo-auto-update: false\ngeox-url: {geoip: '', geosite: '', mmdb: '', asn: ''}\nrules:\n  - MATCH,DIRECT\n"
        const val STRATEGIES = "mode: rule\nfind-process-mode: off\nlog-level: debug\ngeo-auto-update: false\ngeox-url: {geoip: '', geosite: '', mmdb: '', asn: ''}\nproxies:\n  - {name: 节点🌐, type: direct}\nproxy-groups:\n  - {name: 出口🌐, type: select, proxies: [DIRECT, 节点🌐, REJECT]}\nrules:\n  - MATCH,出口🌐\n"

        fun success(reply: CoreIpcTestDriver.Reply): JSONObject {
            assertTrue(reply.terminal.toString(), reply.terminal.getBoolean("complete"))
            assertFalse(reply.terminal.toString(), reply.terminal.has("error") && !reply.terminal.isNull("error"))
            reply.terminal.optJSONObject("nativeReceipt")?.let { receipt ->
                assertFalse(receipt.toString(), receipt.has("error") && !receipt.isNull("error"))
                assertFalse(receipt.toString(), receipt.has("cancelError") && !receipt.isNull("cancelError"))
            }
            return reply.value
        }

        fun failure(reply: CoreIpcTestDriver.Reply): JSONObject {
            assertFalse(reply.terminal.toString(), reply.terminal.getBoolean("complete"))
            return reply.terminal.getJSONObject("error").also {
                assertTrue(it.toString(), it.getString("message").isNotEmpty())
            }
        }

        fun collection(reply: CoreIpcTestDriver.Reply): List<JSONObject> {
            success(reply)
            assertEquals(reply.records.size.toLong(), reply.terminal.getLong("recordCount"))
            assertTrue(reply.terminal.toString(), reply.terminal.getString("source").isNotEmpty())
            assertEquals(1, reply.metadata.size)
            assertEquals(reply.terminal.getString("source"), reply.metadata.single().getString("source"))
            return reply.records
        }
    }
}
