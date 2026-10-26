package io.github.monadboxlab.clashpseudo.bridge

import io.github.monadboxlab.clashpseudo.app.AppMessage
import io.github.monadboxlab.clashpseudo.app.AppStrings

import android.os.Handler
import android.os.Looper
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Native only queues the batch; its bounded probes run asynchronously. Requests
 * are ordered with core lifecycle work and retain their UI and core ownership
 * until delivery, including starts whose native ID arrives after cancellation.
 */
class DelayCalls(
    private val core: CoreHost,
    private val start: (ByteArray) -> String = { NativeCore.startDelayTest(it) },
    private val read: (ByteArray) -> String = { NativeCore.delayTest(it) },
    private val cancel: (ByteArray) -> Unit = { NativeCore.cancelDelayTest(it) },
    private val timeoutMs: Long = 5_000,
) {
    private val main = Handler(Looper.getMainLooper())
    private val batches = mutableMapOf<String, Pair<Long, String>>()
    private val epoch = AtomicLong()
    @Volatile private var visible = true
    private var starting = false
    private val reading = mutableSetOf<String>()

    private fun current(generation: Long, composition: String?): Boolean =
        visible && composition != null && core.current(generation) && core.snapshot().composition == composition

    /** Activity visibility immediately invalidates queued and accepted starts. */
    fun setVisible(value: Boolean) {
        if (visible == value) return
        visible = value
        if (!value) abandonAll()
    }

    fun start(generation: Long, composition: String?, request: Map<String, Any?>,
              reply: (String?, AppMessage?) -> Unit) {
        if (!current(generation, composition)) {
            reply(null, AppStrings.message(R.string.error_core_context_refresh))
            return
        }
        if (starting) {
            reply(null, AppStrings.message(R.string.error_delay_start))
            return
        }
        val owner = epoch.get()
        val active = AtomicBoolean(true)
        val body = JSONObject(request).toString().toByteArray(Charsets.UTF_8)
        starting = true
        val timeout = Runnable {
            if (active.compareAndSet(true, false)) reply(null, AppStrings.message(R.string.error_delay_start))
        }
        main.postDelayed(timeout, timeoutMs)
        core.worker.execute {
            var value: String? = null
            var error: AppMessage? = null
            var accepted: String? = null
            try {
                check(active.get() && epoch.get() == owner && current(generation, composition))
                val data = JSONObject(start(body))
                if (data.has("error")) {
                    error = AppStrings.message(R.string.error_group_untestable)
                } else {
                    val id = data.getString("id")
                    accepted = id
                    if (!active.get() || epoch.get() != owner || !current(generation, composition)) {
                        cancelNative(id)
                        accepted = null
                        error = AppStrings.message(R.string.error_batch_expired)
                    } else {
                        value = JSONObject().put("start", data)
                            .put("generation", generation).put("composition", composition).toString()
                    }
                }
            } catch (_: Exception) {
                error = AppStrings.message(R.string.error_delay_start)
            } catch (_: LinkageError) {
                error = AppStrings.message(R.string.error_native_delay_unavailable)
            }
            main.post {
                starting = false
                main.removeCallbacks(timeout)
                val id = accepted
                val valid = epoch.get() == owner && current(generation, composition)
                if (id != null) {
                    if (active.get() && valid) {
                        synchronized(batches) { batches[id] = generation to composition!! }
                    } else {
                        cancel(id)
                    }
                }
                if (active.compareAndSet(true, false)) {
                    if (valid) reply(value, error)
                    else reply(null, AppStrings.message(R.string.error_batch_expired))
                }
            }
        }
    }

    fun read(generation: Long, composition: String?, id: String,
             reply: (String?, AppMessage?) -> Unit) {
        val identity = synchronized(batches) { batches[id] }
        if (!current(generation, composition) || identity != (generation to composition)) {
            reply(null, AppStrings.message(R.string.error_batch_expired))
            return
        }
        if (!reading.add(id)) {
            reply(null, AppStrings.message(R.string.error_delay_read))
            return
        }
        val active = AtomicBoolean(true)
        val timeout = Runnable {
            if (active.compareAndSet(true, false)) reply(null, AppStrings.message(R.string.error_delay_read))
        }
        main.postDelayed(timeout, timeoutMs)
        core.worker.execute {
            var value: String? = null
            var error: AppMessage? = null
            try {
                check(active.get() && current(generation, composition) &&
                    synchronized(batches) { batches[id] == identity })
                val data = JSONObject(read(id.toByteArray(Charsets.UTF_8)))
                check(!data.has("error"))
                value = JSONObject().put("batch", data)
                    .put("generation", generation).put("composition", composition).toString()
            } catch (_: Exception) {
                error = AppStrings.message(R.string.error_delay_read)
            } catch (_: LinkageError) {
                error = AppStrings.message(R.string.error_native_delay_unavailable)
            }
            main.post {
                reading.remove(id)
                main.removeCallbacks(timeout)
                if (active.compareAndSet(true, false)) {
                    if (current(generation, composition) && synchronized(batches) { batches[id] == identity }) {
                        reply(value, error)
                    } else reply(null, AppStrings.message(R.string.error_batch_expired))
                }
            }
        }
    }

    private fun cancelNative(id: String) {
        try { cancel(id.toByteArray(Charsets.UTF_8)) } catch (_: Exception) { } catch (_: LinkageError) { }
    }

    /** The popup owns its cancellation lifetime. */
    fun cancel(id: String) {
        synchronized(batches) { batches.remove(id) }
        core.worker.execute { cancelNative(id) }
    }

    /** UI Engine destruction invalidates queued starts, including those awaiting an ID. */
    fun abandonAll() {
        epoch.incrementAndGet()
        val ids = synchronized(batches) { batches.keys.toList() }
        ids.forEach(::cancel)
    }
}
