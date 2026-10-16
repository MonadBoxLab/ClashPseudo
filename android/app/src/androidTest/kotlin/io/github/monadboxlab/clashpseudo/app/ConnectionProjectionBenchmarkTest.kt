package io.github.monadboxlab.clashpseudo.app

import android.os.SystemClock
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

/** Diagnostic only: no device-dependent timing assertion. */
class ConnectionProjectionBenchmarkTest {
    @Test
    fun measuresPlatformJsonRoundTrip() {
        for (count in listOf(50, 500, 1000)) {
            val rows = JSONArray()
            val presence = JSONObject()
            repeat(count) { i ->
                val id = "%08x-0000-4000-8000-000000000000".format(i + 1)
                rows.put(JSONObject().put("id", id).put("start", "2026-10-16T10:00:00Z")
                    .put("upload", 100).put("download", 200).put("chains", JSONArray(listOf("DIRECT")))
                    .put("metadata", JSONObject().put("host", "fixture.test").put("type", "Tun")))
                presence.put(id, true)
            }
            val raw = JSONObject().put("complete", true).put("connections", rows)
                .put("presence", presence).toString()
            fun convert(): String {
                val value = JSONObject(raw)
                check(!value.has("error") && value.getBoolean("complete"))
                check(value.getJSONArray("connections").length() <= 1000)
                check(value.getJSONObject("presence").length() <= 1001)
                return value.put("generation", 1).put("configId", "benchmark").put("revision", 1)
                    .put("elapsedMs", SystemClock.elapsedRealtime()).put("observedAt", System.currentTimeMillis()).toString()
            }
            repeat(20) { convert() }
            val times = List(30) {
                val start = SystemClock.elapsedRealtimeNanos()
                convert()
                SystemClock.elapsedRealtimeNanos() - start
            }.sorted()
            assertEquals(count, JSONObject(convert()).getJSONArray("connections").length())
            Log.i("ConnectionBenchmark", "rows=$count bytes=${raw.toByteArray().size} medianUs=${times[15] / 1000} p90Us=${times[27] / 1000}")
        }
    }
}
