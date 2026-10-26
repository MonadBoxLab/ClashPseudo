package io.github.monadboxlab.clashpseudo.bridge

import io.github.monadboxlab.clashpseudo.app.AppMessage

import android.os.SystemClock
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.CoreInput
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Measures production conversion time for diagnostic reporting. */
class ConnectionProjectionBenchmarkTest {
    @Test fun measuresPlatformJsonRoundTrip() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        for (count in listOf(50, 500, 1000)) {
            val rows = JSONArray()
            val presence = JSONObject()
            val ids = ArrayList<String>()
            repeat(count) { i ->
                val id = "%08x-0000-4000-8000-000000000000".format(i + 1)
                ids.add(id)
                rows.put(JSONObject().put("id", id).put("start", "2026-10-16T10:00:00Z")
                    .put("upload", 100).put("download", 200).put("chains", JSONArray(listOf("DIRECT")))
                    .put("metadata", JSONObject().put("host", "fixture.test").put("type", "Tun")))
                presence.put(id, true)
            }
            val raw = JSONObject().put("complete", true).put("limited", false)
                .put("uploadTotal", 1000).put("downloadTotal", 2000)
                .put("sessionUploadBytes", 100).put("sessionDownloadBytes", 200)
                .put("activeCount", count).put("ruleSuggestions", JSONObject.NULL)
                .put("connections", rows).put("presence", presence).toString()
            val duration = AtomicLong()
            val reads = AtomicInteger()
            val session = NativeSession()
            lateinit var core: CoreHost
            lateinit var calls: ConnectionsCalls
            instrumentation.runOnMainSync {
                core = CoreHost(session, {}, Executor { work ->
                    val start = SystemClock.elapsedRealtimeNanos()
                    work.run()
                    duration.set(SystemClock.elapsedRealtimeNanos() - start)
                }, prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" },
                    cancelNative = {}, readLogWindow = { null })
                core.setVisible(true)
                calls = ConnectionsCalls(core, query = { reads.incrementAndGet(); raw })
            }
            val vpn = session.begin("benchmark", 1)!!
            val source = core.prepareVpn(vpn, "benchmark", 1, "unused", {
                CoreInput("benchmark", 1, null, byteArrayOf(), "{}".toByteArray(), name = "Benchmark")
            }, Any())
            assertTrue(session.attached(vpn))
            fun convertThroughProduction(): Pair<Long, JSONObject> {
                val done = CountDownLatch(1)
                val value = AtomicReference<String?>()
                val error = AtomicReference<AppMessage?>()
                instrumentation.runOnMainSync {
                    calls.read(source.generation, "benchmark", 1,
                        mapOf("limit" to count, "previousActiveIds" to ids)) { result, failure ->
                        value.set(result); error.set(failure); done.countDown()
                    }
                }
                assertTrue(done.await(5, TimeUnit.SECONDS))
                assertNull(error.get())
                return duration.get() to JSONObject(value.get()!!)
            }
            try {
                repeat(20) { convertThroughProduction() }
                val times = List(30) { convertThroughProduction().first }.sorted()
                val result = convertThroughProduction().second
                assertEquals(count, result.getJSONArray("connections").length())
                assertEquals(count, result.getJSONObject("presence").length())
                assertEquals(source.generation, result.getLong("generation"))
                assertEquals(source.composition, result.getString("composition"))
                assertEquals("VPN", result.getString("purpose"))
                assertEquals(100L, result.getLong("sessionUploadBytes"))
                assertEquals(200L, result.getLong("sessionDownloadBytes"))
                assertEquals(51, reads.get())
                Log.i("ConnectionBenchmark", "scope=ConnectionsCalls.read-worker rows=$count bytes=${raw.toByteArray().size} medianUs=${times[15] / 1000} p90Us=${times[27] / 1000}")
            } finally {
                assertTrue(session.stopping(vpn))
                assertNull(core.stopVpn(vpn))
                session.finished(vpn, null)
            }
        }
    }
}
