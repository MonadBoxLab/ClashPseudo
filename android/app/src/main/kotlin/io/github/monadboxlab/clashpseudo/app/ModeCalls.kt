package io.github.monadboxlab.clashpseudo.app

import android.os.Handler
import android.os.Looper
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean

/** Mode waits never cancel the VPN. Only not-yet-started work can be cancelled. */
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
        var reply: ((String?, String?) -> Unit)?,
    ) {
        val active = AtomicBoolean(true)
        lateinit var timeout: Runnable
    }

    fun read(generation: Long, owner: String?, reply: (String?, String?) -> Unit) =
        request(generation, owner, null, reply)

    fun change(generation: Long, owner: String, mode: String, reply: (String?, String?) -> Unit) {
        if (mode !in VALUES) { reply(null, "无法识别运行模式。"); return }
        request(generation, owner, mode, reply)
    }

    private fun request(generation: Long, owner: String?, mode: String?, reply: (String?, String?) -> Unit) {
        val request = Request(generation, owner, reply)
        request.timeout = Runnable { complete(request, null, "运行模式确认超时。") }
        pending.add(request)
        main.postDelayed(request.timeout, if (mode == null) READ_TIMEOUT_MS else CHANGE_TIMEOUT_MS)
        worker.execute {
            if (!request.active.get()) return@execute
            var actual: String? = null
            var error: String? = null
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
                error = "无法确认运行模式，请等待状态重新读取。"
                actual = null
            } catch (_: LinkageError) {
                error = "原生模式接口不可用。"
                actual = null
            }
            main.post {
                if (!current(generation)) {
                    actual = null
                    error = "接管会话已变化，本次模式未确认。"
                }
                complete(request, actual, error)
                // A native call already in progress may finish after its waiter expires.
                if (attempted) changed()
            }
        }
    }

    fun abandon(owner: String) {
        pending.filter { it.owner == owner }.forEach { request ->
            request.reply = null
            complete(request, null, null)
        }
    }

    private fun current(generation: Long) = session.snapshot().let {
        it.generation == generation && it.phase == NativeSession.Phase.RUNNING
    }

    private fun complete(request: Request, mode: String?, error: String?) {
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
