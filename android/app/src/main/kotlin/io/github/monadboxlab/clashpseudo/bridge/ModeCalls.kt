package io.github.monadboxlab.clashpseudo.bridge

import io.github.monadboxlab.clashpseudo.app.AppMessage
import io.github.monadboxlab.clashpseudo.app.AppStrings

import io.github.monadboxlab.clashpseudo.R
import android.os.Handler
import android.os.Looper
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean

/** Cancel only queued mode work; an executing mode operation completes normally. */
class ModeCalls(
    private val session: NativeSession,
    private val worker: Executor,
    private val changed: () -> Unit,
    private val getMode: () -> String = { NativeCore.mode() },
    private val setMode: (String) -> String = { NativeCore.setMode(it) },
) {
    private val main = Handler(Looper.getMainLooper())
    private val pending = mutableSetOf<Request>()

    private class Request(
        val generation: Long,
        val owner: String?,
        var reply: ((String?, AppMessage?) -> Unit)?,
    ) {
        val active = AtomicBoolean(true)
        lateinit var timeout: Runnable
    }

    fun read(generation: Long, owner: String?, reply: (String?, AppMessage?) -> Unit) =
        request(generation, owner, null, reply)

    fun change(generation: Long, owner: String, mode: String, reply: (String?, AppMessage?) -> Unit) {
        if (mode !in VALUES) { reply(null, AppStrings.message(R.string.error_unknown_mode)); return }
        request(generation, owner, mode, reply)
    }

    private fun request(generation: Long, owner: String?, mode: String?, reply: (String?, AppMessage?) -> Unit) {
        val request = Request(generation, owner, reply)
        request.timeout = Runnable { complete(request, null, AppStrings.message(R.string.error_mode_timeout)) }
        pending.add(request)
        main.postDelayed(request.timeout, if (mode == null) READ_TIMEOUT_MS else CHANGE_TIMEOUT_MS)
        worker.execute {
            if (!request.active.get()) return@execute
            var actual: String? = null
            var error: AppMessage? = null
            var attempted = false
            try {
                check(current(generation))
                if (mode != null) {
                    attempted = true
                    check(setMode(mode).isEmpty())
                }
                actual = getMode().takeIf { it in VALUES }
                check(actual != null && (mode == null || actual == mode))
            } catch (_: Exception) {
                error = AppStrings.message(R.string.error_mode_unconfirmed)
                actual = null
            } catch (_: LinkageError) {
                error = AppStrings.message(R.string.error_native_mode_unavailable)
                actual = null
            }
            main.post {
                if (!current(generation)) {
                    actual = null
                    error = AppStrings.message(R.string.error_session_mode_changed)
                }
                complete(request, actual, error)
                // A native call already in progress may finish after its waiter expires.
                if (attempted) changed()
            }
        }
    }

    fun abandon(owner: String) {
        pending.filter { it.owner == owner }.forEach { request ->
            complete(request, null, AppStrings.message(R.string.error_operation_ended))
        }
    }

    private fun current(generation: Long) = session.snapshot().let {
        it.generation == generation && it.phase == NativeSession.Phase.RUNNING
    }

    private fun complete(request: Request, mode: String?, error: AppMessage?) {
        if (!request.active.getAndSet(false)) return
        pending.remove(request)
        main.removeCallbacks(request.timeout)
        val reply = request.reply
        request.reply = null
        reply?.invoke(mode, error)
    }

    companion object {
        val VALUES = setOf("rule", "global", "direct")
        const val READ_TIMEOUT_MS = 3000L
        const val CHANGE_TIMEOUT_MS = 5000L
    }
}
