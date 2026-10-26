package io.github.monadboxlab.clashpseudo.bridge

import io.github.monadboxlab.clashpseudo.app.AppFiles
import io.github.monadboxlab.clashpseudo.app.AppMessage
import io.github.monadboxlab.clashpseudo.app.AppStrings

import io.github.monadboxlab.clashpseudo.R
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.CoreInput
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import io.github.monadboxlab.clashpseudo.nativecore.NativePreparationFailure
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

/** Strategy waits use their own operation deadline. */
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
                          var reply: ((String?, AppMessage?) -> Unit)?) {
        val active = AtomicBoolean(true)
        lateinit var timeout: Runnable
    }

    fun read(generation: Long, owner: String?, reply: (String?, AppMessage?) -> Unit) =
        request(owner, readTimeoutMs, false, {}, guarded(generation, reply)) { snapshot(generation) }

    fun change(generation: Long, owner: String, name: String, choice: Map<*, *>,
               reply: (String?, AppMessage?) -> Unit) =
        request(owner, changeTimeoutMs, true, {}, guarded(generation, reply)) {
            check(core.current(generation))
            val value = JSONObject().put("name", name).put("choice", JSONObject(choice))
            check(setStrategy(value.toString().toByteArray(Charsets.UTF_8)).isEmpty())
            check(core.current(generation))
            core.recordChoice(generation, name, choice)
            "{}"
        }

    fun prepare(context: Context, owner: String, id: String, revision: Int, mode: String?,
                reply: (String?, AppMessage?) -> Unit) {
        if ((mode != null && mode !in ModeCalls.VALUES) || id.isEmpty() || revision < 1) {
            reply(null, AppStrings.message(R.string.error_strategy_params))
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

    fun release(owner: String, reply: (String?, AppMessage?) -> Unit) {
        val generation = core.snapshot().generation
        request(owner, changeTimeoutMs, true, {}, reply) {
            check(core.snapshot().generation == generation)
            check(core.releasePreview() == null)
            "{}"
        }
    }

    private fun guarded(generation: Long, reply: (String?, AppMessage?) -> Unit): (String?, AppMessage?) -> Unit =
        { value, error ->
            if (core.current(generation)) reply(value, error)
            else reply(null, AppStrings.message(R.string.error_strategy_context))
        }

    private fun snapshot(generation: Long): String {
        check(core.current(generation))
        val state = core.snapshot()
        val value = JSONObject(getStrategies())
        check(!value.has("error") && core.current(generation))
        value.put("generation", generation).put("configId", state.configId)
            .put("revision", state.revision).put("purpose", state.purpose?.name)
            .put("composition", state.composition)
        return value.toString()
    }

    private fun request(owner: String?, timeoutMs: Long, mutates: Boolean, expire: () -> Unit,
                        reply: (String?, AppMessage?) -> Unit, work: (() -> Boolean) -> String) {
        val request = Request(owner, expire, reply)
        request.timeout = Runnable {
            expire()
            complete(request, null, AppStrings.message(R.string.error_strategy_timeout))
        }
        pending.add(request)
        main.postDelayed(request.timeout, timeoutMs)
        core.worker.execute {
            if (!request.active.get()) return@execute
            var value: String? = null
            var error: AppMessage? = null
            try {
                value = work { request.active.get() }
            } catch (failure: Exception) {
                error = (failure as? NativePreparationFailure)?.detail
                    ?: AppStrings.message(R.string.error_strategy_unconfirmed)
            } catch (_: LinkageError) {
                error = AppStrings.message(R.string.error_native_strategy_unavailable)
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
            complete(it, null, AppStrings.message(R.string.error_operation_ended))
        }
    }

    private fun complete(request: Request, value: String?, error: AppMessage?) {
        if (!request.active.getAndSet(false)) return
        pending.remove(request)
        main.removeCallbacks(request.timeout)
        val reply = request.reply
        request.reply = null
        reply?.invoke(value, error)
    }
}
