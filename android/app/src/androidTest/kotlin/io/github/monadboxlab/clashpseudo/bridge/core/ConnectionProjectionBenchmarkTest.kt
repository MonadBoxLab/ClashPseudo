package io.github.monadboxlab.clashpseudo.bridge.core

import android.os.SystemClock
import android.util.Log
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.collection
import org.junit.Assert.*
import org.junit.Test

class ConnectionProjectionBenchmarkTest {
    @Test fun measuresRealBinderAndFdCollectionRoundTrip() {
        for (count in listOf(50, 500, 1000)) {
            val body = buildString {
                append(CoreBridgeIpcScenario.DIRECT.substringBefore("rules:"))
                append("rules:\n")
                repeat(count) { append("  - DOMAIN,fixture-").append(it).append(".test,DIRECT\n") }
            }
            CoreBridgeIpcScenario(body).use { core ->
                var reads = 0
                var source: String? = null
                fun read(): Long {
                    val began = SystemClock.elapsedRealtimeNanos()
                    val reply = core.query(Contract.CORE_OPERATION_RULES)
                    val elapsed = SystemClock.elapsedRealtimeNanos() - began
                    val rows = collection(reply)
                    assertEquals(count, rows.size)
                    assertEquals((1..count).toList(), rows.map { it.getInt("index") })
                    assertEquals("fixture-0.test", rows.first().getString("payload"))
                    assertEquals("fixture-${count - 1}.test", rows.last().getString("payload"))
                    val captured = reply.terminal.getString("source")
                    if (source == null) source = captured else assertEquals(source, captured)
                    reads++
                    return elapsed
                }
                repeat(20) { read() }
                val times = List(30) { read() }.sorted()
                read()
                assertEquals(51, reads)
                core.assertSameContext()
                Log.i("ConnectionBenchmark", "scope=CoreService-Binder-FD-rules rows=$count medianUs=${times[15] / 1000} p90Us=${times[27] / 1000}")
            }
        }
    }
}
