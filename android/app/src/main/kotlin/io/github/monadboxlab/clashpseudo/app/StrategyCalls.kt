package io.github.monadboxlab.clashpseudo.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.CoreInput
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

/** Strategy waits do not use the VPN start/stop timeout path. */
class StrategyCalls(
    private val core: CoreHost,
    private val changed: () -> Unit,
    private val getStrategies: () -> String = { NativeCore.strategies() },
    private val setStrategy: (ByteArray) -> String = { NativeCore.setStrategy(it) },
    private val readTimeoutMs: Long = 3000,
    private val changeTimeoutMs: Long = 10000,
    private val prepareTimeoutMs: Long = 45000,
) {
    private val main = Handler(Looper.getMainLooper())
    private val pending = mutableSetOf<Request>()
    private class Request(val owner: String?, val expire: () -> Unit,
                          var reply: ((String?, String?) -> Unit)?) {
        val active = AtomicBoolean(true)
        lateinit var timeout: Runnable
    }

    fun read(generation: Long, owner: String?, reply: (String?, String?) -> Unit) =
        request(owner, readTimeoutMs, false, {}, guarded(generation, reply)) { snapshot(generation) }

    fun change(generation: Long, owner: String, name: String, choice: Map<*, *>,
               reply: (String?, String?) -> Unit) =
        request(owner, changeTimeoutMs, true, {}, guarded(generation, reply)) {
            check(core.current(generation))
            val value = JSONObject().put("name", name).put("choice", JSONObject(choice))
            check(setStrategy(value.toString().toByteArray(Charsets.UTF_8)).isEmpty())
            check(core.current(generation))
            "{}"
        }

    fun prepare(context: Context, owner: String, id: String, revision: Int, mode: String,
                reply: (String?, String?) -> Unit) {
        if (mode !in ModeCalls.VALUES || id.isEmpty() || revision < 1) {
            reply(null, "策略加载参数无效。")
            return
        }
        request(owner, prepareTimeoutMs, true, { core.cancelPreparation(owner) }, reply) { active ->
            val home = AppFiles.core(context)
            check(home.isDirectory || home.mkdirs())
            core.preparePreview(owner, id, revision, home.absolutePath, active) {
                CoreInput.read(AppFiles.runInput(context, owner), id, revision, mode)
            }
            "{}"
        }
    }

    fun release(owner: String, reply: (String?, String?) -> Unit) {
        val generation = core.snapshot().generation
        request(owner, changeTimeoutMs, true, {}, reply) {
            check(core.snapshot().generation == generation)
            check(core.releasePreview() == null)
            "{}"
        }
    }

    private fun guarded(generation: Long, reply: (String?, String?) -> Unit): (String?, String?) -> Unit =
        { value, error ->
            if (core.current(generation)) reply(value, error)
            else reply(null, "策略上下文已变化，本次结果未确认。")
        }

    private fun snapshot(generation: Long): String {
        check(core.current(generation))
        val state = core.snapshot()
        val value = JSONObject(getStrategies())
        check(!value.has("error") && core.current(generation))
        value.put("generation", generation).put("configId", state.configId)
            .put("revision", state.revision).put("purpose", state.purpose?.name)
        return value.toString()
    }

    private fun request(owner: String?, timeoutMs: Long, mutates: Boolean, expire: () -> Unit,
                        reply: (String?, String?) -> Unit, work: (() -> Boolean) -> String) {
        val request = Request(owner, expire, reply)
        request.timeout = Runnable {
            expire()
            complete(request, null, "策略操作等待超时，请等待实际状态重新读取。")
        }
        pending.add(request)
        main.postDelayed(request.timeout, timeoutMs)
        core.worker.execute {
            if (!request.active.get()) return@execute
            var value: String? = null
            var error: String? = null
            try {
                value = work { request.active.get() }
            } catch (_: Exception) {
                error = "策略操作未确认，请核实当前配置、成员与内核状态。"
            } catch (_: LinkageError) {
                error = "原生策略接口不可用。"
            }
            main.post {
                complete(request, value, error)
                if (mutates) changed()
            }
        }
    }

    fun abandon(owner: String) {
        pending.filter { it.owner == owner }.forEach {
            it.expire()
            it.reply = null
            complete(it, null, null)
        }
    }

    private fun complete(request: Request, value: String?, error: String?) {
        if (!request.active.getAndSet(false)) return
        pending.remove(request)
        main.removeCallbacks(request.timeout)
        val reply = request.reply
        request.reply = null
        reply?.invoke(value, error)
    }
}
