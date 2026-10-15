package io.github.monadboxlab.clashpseudo.app

import android.os.Handler
import android.os.Looper
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

/** A timed-out read retains its worker slot until execution finishes. */
class ConnectionsCalls(
    private val core: CoreHost,
    private val snapshot: () -> String = { NativeCore.snapshot() },
    private val timeoutMs: Long = 3000L,
) {
    private val main = Handler(Looper.getMainLooper())
    private var pending = false

    fun read(generation: Long, configId: String, revision: Int, reply: (String?, String?) -> Unit) {
        if (pending) { reply(null, "连接读取尚未完成，请稍后重试。"); return }
        if (!current(generation, configId, revision)) {
            reply(null, "接管上下文已变化，连接数据未确认。")
            return
        }
        pending = true
        val active = AtomicBoolean(true)
        val timeout = Runnable {
            if (active.getAndSet(false)) reply(null, "连接读取超时，显示最近观察。")
        }
        main.postDelayed(timeout, timeoutMs)
        try {
            core.worker.execute {
                var value: String? = null
                var error: String? = null
                try {
                    if (active.get()) {
                        check(current(generation, configId, revision))
                        val source = JSONObject(snapshot())
                        check(source.getBoolean("prepared") && source.getBoolean("attached") &&
                            !source.getBoolean("cleanupFailed"))
                        val traffic = source.getJSONObject("traffic")
                        check(traffic.has("connections"))
                        val rows = if (traffic.isNull("connections")) JSONArray()
                            else traffic.getJSONArray("connections")
                        val connections = JSONArray()
                        for (i in 0 until rows.length()) {
                            val row = rows.getJSONObject(i)
                            val metadata = row.optJSONObject("metadata") ?: JSONObject()
                            if (metadata.optString("type") == "Inner") continue
                            val safeMetadata = JSONObject()
                            for (key in listOf("host", "destinationIP", "destinationPort", "sourceIP",
                                "sourcePort", "network", "type")) {
                                if (metadata.has(key)) safeMetadata.put(key, metadata.get(key))
                            }
                            val safe = JSONObject().put("metadata", safeMetadata)
                            for (key in listOf("id", "start", "upload", "download", "chains", "rule", "rulePayload")) {
                                if (row.has(key)) safe.put(key, row.get(key))
                            }
                            connections.put(safe)
                        }
                        value = JSONObject().put("generation", generation).put("configId", configId)
                            .put("revision", revision).put("connections", connections).toString()
                    }
                } catch (_: Exception) {
                    error = "无法读取连接，显示最近观察。"
                } catch (_: LinkageError) {
                    error = "原生连接读取接口不可用。"
                }
                main.post {
                    pending = false
                    main.removeCallbacks(timeout)
                    if (!active.getAndSet(false)) return@post
                    if (!current(generation, configId, revision)) {
                        reply(null, "接管上下文已变化，连接数据未确认。")
                    } else reply(value, error)
                }
            }
        } catch (_: Exception) {
            pending = false
            main.removeCallbacks(timeout)
            if (active.getAndSet(false)) reply(null, "连接读取未被受理。")
        }
    }

    private fun current(generation: Long, configId: String, revision: Int): Boolean {
        val state = core.snapshot()
        return state.purpose == CoreHost.Purpose.VPN && state.configId == configId &&
            state.revision == revision && core.current(generation)
    }
}
