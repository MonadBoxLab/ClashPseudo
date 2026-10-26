package io.github.monadboxlab.clashpseudo.bridge

import io.github.monadboxlab.clashpseudo.app.ApplicationContract
import io.github.monadboxlab.clashpseudo.app.AppMessage
import io.github.monadboxlab.clashpseudo.app.AppStrings

import io.github.monadboxlab.clashpseudo.R
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** Expired calls retain their worker slots until execution has finished. */
class ConnectionsCalls(
    private val core: CoreHost,
    private val query: (ByteArray) -> String = { NativeCore.connections(it) },
    private val close: (ByteArray) -> String = { NativeCore.closeConnection(it) },
    private val timeoutMs: Long = 3000L,
    private val readMemory: () -> String = { NativeCore.processMemory() },
    private val memoryWorker: Executor = memoryReads,
) {
    companion object {
        private val memoryReads = Executors.newSingleThreadExecutor { task -> Thread(task, "PseudoProcessMemory") }
    }
    private var memoryPending = false
    fun processMemory(reply: (String?, AppMessage?) -> Unit) {
        fun unavailable() = JSONObject().put("processRssBytes", JSONObject.NULL)
            .put("sampledAt", System.currentTimeMillis()).put("valid", false).put("error", "unavailable").toString()
        if (memoryPending) { reply(unavailable(), null); return }
        memoryPending = true
        val active = AtomicBoolean(true)
        val timeout = Runnable { if (active.getAndSet(false)) reply(unavailable(), null) }
        main.postDelayed(timeout, timeoutMs)
        fun finish(value: String) { main.post {
            memoryPending = false
            main.removeCallbacks(timeout)
            if (active.getAndSet(false)) reply(value, null)
        } }
        try {
            // Use the process-local observation path independently of VPN state.
            memoryWorker.execute {
                val value = try {
                    val raw = readMemory()
                    check(raw.toByteArray(Charsets.UTF_8).size <= 4096)
                    JSONObject(raw).also {
                        check(it.getLong("sampledAt") > 0)
                        if (it.getBoolean("valid")) check(it.getLong("processRssBytes") >= 0 && !it.has("error"))
                        else check(it.isNull("processRssBytes") && it.getString("error") == "unavailable")
                    }.toString()
                } catch (_: Exception) { unavailable() } catch (_: LinkageError) { unavailable() }
                finish(value)
            }
        } catch (_: Exception) { finish(unavailable()) }
    }

    private val main = Handler(Looper.getMainLooper())
    private var reading: Request? = null
    private var closing: Request? = null

    private class Request(val owner: String?, var reply: ((String?, AppMessage?) -> Unit)?) {
        val active = AtomicBoolean(true)
        lateinit var timeout: Runnable
    }

    fun read(generation: Long, configId: String, revision: Int,
             parameters: Map<String, Any?> = mapOf("limit" to ApplicationContract.CONNECTION_ACTIVE_ENTRIES),
             reply: (String?, AppMessage?) -> Unit) {
        val before = core.snapshot()
        val bytes = JSONObject(parameters).toString().toByteArray(Charsets.UTF_8)
        if (bytes.size > ApplicationContract.CONNECTION_REQUEST_BYTES) { reply(null, AppStrings.message(R.string.error_connection_query_size)); return }
        request(generation, configId, revision, null, reply) {
            check(before.generation == generation && before.configId == configId && before.revision == revision &&
                before.purpose == CoreHost.Purpose.VPN && core.snapshot().composition == before.composition)
            val raw = query(bytes)
            check(raw.toByteArray(Charsets.UTF_8).size <= ApplicationContract.CONNECTION_RESPONSE_BYTES)
            val source = JSONObject(raw)
            check(!source.has("error") && source.getBoolean("complete"))
            check(source.getJSONArray("connections").length() <= ApplicationContract.CONNECTION_ACTIVE_ENTRIES)
            check(source.getJSONObject("presence").length() <= ApplicationContract.CONNECTION_ACTIVE_ENTRIES + ApplicationContract.CONNECTION_EXTRA_DETAILS)
            source.put("generation", generation).put("configId", configId)
                .put("revision", revision).put("composition", before.composition).put("purpose", before.purpose.name)
                .put("elapsedMs", SystemClock.elapsedRealtime())
                .put("observedAt", System.currentTimeMillis()).toString()
        }
    }

    fun disconnect(generation: Long, configId: String, revision: Int, id: String,
                   owner: String, reply: (String?, AppMessage?) -> Unit) {
        if (!id.matches(Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))) {
            reply(null, AppStrings.message(R.string.error_connection_id))
            return
        }
        request(generation, configId, revision, owner, reply) {
            val source = JSONObject(close(id.toByteArray(Charsets.UTF_8)))
            check(source.getString("status") in setOf("closed", "absent", "failed"))
            source.toString()
        }
    }

    private fun request(generation: Long, configId: String, revision: Int, owner: String?,
                        reply: (String?, AppMessage?) -> Unit, work: () -> String) {
        val mutates = owner != null
        val before = core.snapshot()
        fun currentRequest() = current(generation, configId, revision) &&
            before.generation == generation && core.snapshot().let {
                it.composition == before.composition && it.purpose == before.purpose
            }
        if ((if (mutates) closing else reading) != null) {
            reply(null, AppStrings.message(R.string.error_connection_busy))
            return
        }
        if (!currentRequest()) {
            reply(null, AppStrings.message(R.string.error_session_changed))
            return
        }
        val request = Request(owner, reply)
        if (mutates) closing = request else reading = request
        request.timeout = Runnable { complete(request, null, AppStrings.message(R.string.error_connection_timeout)) }
        main.postDelayed(request.timeout, timeoutMs)
        try {
            core.worker.execute {
                var value: String? = null
                var error: AppMessage? = null
                try {
                    if (request.active.get()) {
                        check(currentRequest())
                        value = work()
                    }
                } catch (_: Exception) {
                    error = if (mutates) AppStrings.message(R.string.error_disconnect_unconfirmed) else AppStrings.message(R.string.error_update_failed_short)
                } catch (_: LinkageError) {
                    error = AppStrings.message(R.string.error_native_connection_unavailable)
                }
                main.post {
                    if (mutates) closing = null else reading = null
                    if (!currentRequest()) {
                        complete(request, null, AppStrings.message(R.string.error_session_changed))
                    } else complete(request, value, error)
                }
            }
        } catch (_: Exception) {
            if (mutates) closing = null else reading = null
            complete(request, null, AppStrings.message(R.string.error_connection_not_accepted))
        }
    }

    fun abandon(owner: String) {
        closing?.takeIf { it.owner == owner }?.let {
            complete(it, null, AppStrings.message(R.string.error_operation_ended))
        }
    }

    private fun complete(request: Request, value: String?, error: AppMessage?) {
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
