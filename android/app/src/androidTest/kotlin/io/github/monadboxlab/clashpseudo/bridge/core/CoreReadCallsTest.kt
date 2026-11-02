package io.github.monadboxlab.clashpseudo.bridge.core

import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.collection
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.success
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CoreReadCallsTest {
    @Test fun configurationAndNodeRecordsComeFromTheCapturedRealContext() {
        CoreBridgeIpcScenario(CoreBridgeIpcScenario.STRATEGIES).use { core ->
            val configuration = success(core.query(Contract.CORE_OPERATION_RUNTIME_CONFIG))
            assertEquals("rule", configuration.getJSONObject("general").getString("mode"))
            assertEquals("rule", configuration.getJSONObject("requested").getString("mode"))
            val first = core.query(Contract.CORE_OPERATION_NODES)
            val rows = collection(first)
            val node = rows.single { it.getString("name") == "节点🌐" }
            assertEquals("configuration", node.getString("sourceKind"))
            assertEquals("节点🌐", node.getJSONObject("raw").getString("name"))
            val refresh = core.query(Contract.CORE_OPERATION_NODES)
            assertEquals(rows.map { it.toString() }, collection(refresh).map { it.toString() })
            assertEquals(first.terminal.getString("source"), refresh.terminal.getString("source"))
            core.assertSameContext()
        }
    }

    @Test fun rulesKeepMainSubruleAndInlineProviderScopesAcrossFdRecords() {
        val body = CoreBridgeIpcScenario.DIRECT.substringBefore("rules:") + """
            rule-providers:
              domains:
                type: inline
                behavior: domain
                payload: ['+.example.test', exact.test]
              classical:
                type: inline
                behavior: classical
                payload: ['DOMAIN-SUFFIX,example.test', 'NETWORK,UDP']
            sub-rules:
              branch:
                - DOMAIN,sub.test,DIRECT
            rules:
              - RULE-SET,domains,DIRECT
              - MATCH,DIRECT
        """.trimIndent() + "\n"
        CoreBridgeIpcScenario(body).use { core ->
            val main = core.query(Contract.CORE_OPERATION_RULES)
            val rows = collection(main)
            assertEquals(2, rows.size)
            assertEquals(listOf(1, 2), rows.map { it.getInt("index") })
            assertEquals("domains", rows.first().getJSONArray("providers").getString(0))
            val sub = core.query(Contract.CORE_OPERATION_RULES, JSONObject().put("kind", "sub").put("name", "branch"))
            assertEquals("sub.test", collection(sub).single().getString("payload"))
            assertEquals("DIRECT", sub.records.single().getString("target"))
            assertNotEquals(main.terminal.getString("source"), sub.terminal.getString("source"))
            val inline = core.query(Contract.CORE_OPERATION_RULES, JSONObject().put("kind", "provider").put("name", "classical"))
            assertEquals(listOf("DOMAIN-SUFFIX,example.test", "NETWORK,UDP"), collection(inline).map { it.getString("payload") })
            assertEquals("inline-source", inline.metadata.single().getString("origin"))
            assertEquals(main.terminal.getString("source"), core.query(Contract.CORE_OPERATION_RULES).terminal.getString("source"))
            core.assertSameContext()
        }
    }

    @Test fun resourcesReplyCarriesIndividualRowsNotTheOldCoreEnvelope() {
        CoreBridgeIpcScenario().use { core ->
            val reply = core.query(Contract.CORE_OPERATION_RESOURCES)
            val rows = collection(reply)
            assertTrue(rows.isNotEmpty())
            assertEquals(setOf("GeoIP", "GeoSite", "MMDB", "ASN"), rows.filter { it.getString("kind") == "geo" }.map { it.getString("name") }.toSet())
            assertTrue(rows.all { !it.has("resources") })
            assertEquals(0, reply.value.length())
            core.assertSameContext()
        }
    }

    @Test fun collectionLargerThanASingleFrameIsDeliveredWithoutListTruncation() {
        val count = 3000
        val padding = "x".repeat(3000)
        val body = buildString {
            append(CoreBridgeIpcScenario.DIRECT.substringBefore("rules:"))
            append("rules:\n")
            repeat(count) { append("  - DOMAIN-KEYWORD,").append(it).append('.').append(padding).append(".test,DIRECT\n") }
            append("  - MATCH,DIRECT\n")
        }
        CoreBridgeIpcScenario(body).use { core ->
            val reply = core.query(Contract.CORE_OPERATION_RULES)
            val rows = collection(reply)
            assertEquals(count + 1, rows.size)
            assertTrue(rows.sumOf { it.toString().toByteArray(Charsets.UTF_8).size.toLong() } > Contract.CORE_IPC_FRAME_BYTES)
            assertEquals("0.$padding.test", rows.first().getString("payload"))
            assertEquals(count + 1, rows.last().getInt("index"))
            core.assertSameContext()
        }
    }
}
