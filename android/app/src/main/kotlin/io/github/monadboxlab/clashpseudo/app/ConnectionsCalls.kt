package io.github.monadboxlab.clashpseudo.app

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

/** Expired calls retain their worker slots until execution has finished. */
class ConnectionsCalls(
    private val core: CoreHost,
    private val query: (ByteArray) -> String = { NativeCore.connections(it) },
    private val close: (ByteArray) -> String = { NativeCore.closeConnection(it) },
    private val timeoutMs: Long = 3000L,
) {
    private val main = Handler(Looper.getMainLooper())
    private var reading: Request? = null
    private var closing: Request? = null

    private class Request(val owner: String?, var reply: ((String?, String?) -> Unit)?) {
        val active = AtomicBoolean(true)
        lateinit var timeout: Runnable
    }

    fun read(generation: Long, configId: String, revision: Int,
             parameters: Map<String, Any?> = mapOf("limit" to 1000),
             reply: (String?, String?) -> Unit) {
        val bytes = JSONObject(parameters).toString().toByteArray(Charsets.UTF_8)
        if (bytes.size > 65536) { reply(null, "连接查询参数过大。"); return }
        request(generation, configId, revision, null, reply) {
            val raw = query(bytes)
            check(raw.length <= 8 * 1024 * 1024)
            val source = JSONObject(raw)
            check(!source.has("error") && source.getBoolean("complete"))
            check(source.getJSONArray("connections").length() <= 1000)
            check(source.getJSONObject("presence").length() <= 1001)
            source.put("generation", generation).put("configId", configId)
                .put("revision", revision).put("elapsedMs", SystemClock.elapsedRealtime())
                .put("observedAt", System.currentTimeMillis()).toString()
        }
    }

    fun disconnect(generation: Long, configId: String, revision: Int, id: String,
                   owner: String, reply: (String?, String?) -> Unit) {
        if (!id.matches(Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))) {
            reply(null, "连接标识无效。")
            return
        }
        request(generation, configId, revision, owner, reply) {
            val source = JSONObject(close(id.toByteArray(Charsets.UTF_8)))
            check(source.getString("status") in setOf("closed", "absent", "failed"))
            source.toString()
        }
    }

    private fun request(generation: Long, configId: String, revision: Int, owner: String?,
                        reply: (String?, String?) -> Unit, work: () -> String) {
        val mutates = owner != null
        if ((if (mutates) closing else reading) != null) {
            reply(null, "连接操作尚未完成。")
            return
        }
        if (!current(generation, configId, revision)) {
            reply(null, "接管会话已变化。")
            return
        }
        val request = Request(owner, reply)
        if (mutates) closing = request else reading = request
        request.timeout = Runnable { complete(request, null, "连接操作等待超时。") }
        main.postDelayed(request.timeout, timeoutMs)
        try {
            core.worker.execute {
                var value: String? = null
                var error: String? = null
                try {
                    if (request.active.get()) {
                        check(current(generation, configId, revision))
                        value = work()
                    }
                } catch (_: Exception) {
                    error = if (mutates) "断开结果未确认。" else "更新失败。"
                } catch (_: LinkageError) {
                    error = "原生连接接口不可用。"
                }
                main.post {
                    if (mutates) closing = null else reading = null
                    if (!current(generation, configId, revision)) {
                        complete(request, null, "接管会话已变化。")
                    } else complete(request, value, error)
                }
            }
        } catch (_: Exception) {
            if (mutates) closing = null else reading = null
            complete(request, null, "连接操作未被受理。")
        }
    }

    fun abandon(owner: String) {
        closing?.takeIf { it.owner == owner }?.let {
            complete(it, null, "操作已结束。")
        }
    }

    private fun complete(request: Request, value: String?, error: String?) {
        if (!request.active.getAndSet(false)) return
        main.removeCallbacks(request.timeout)
        val receiver = request.reply
        request.reply = null
        receiver?.invoke(value, error)
    }

    private fun current(generation: Long, configId: String, revision: Int): Boolean {
        val state = core.snapshot()
        return state.purpose == CoreHost.Purpose.VPN && state.configId == configId &&
            state.revision == revision && core.current(generation)
    }
}
