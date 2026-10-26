package io.github.monadboxlab.clashpseudo.logic

import io.github.monadboxlab.clashpseudo.app.AppMessage
import io.github.monadboxlab.clashpseudo.app.AppStrings
import io.github.monadboxlab.clashpseudo.app.PseudoApplication
import io.github.monadboxlab.clashpseudo.bridge.AppBridge

import io.github.monadboxlab.clashpseudo.R
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService

/** Owns the single Dart business executor, independently of any work Service. */
class LogicEngineHost(private val application: PseudoApplication) {
    private val main = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var serial = 0L
    private var ready = false
    private var retained = false
    private var syncing = false
    private var stateDirty = false
    private var executing = false
    private var querying = false
    private var pending: Work? = null

    private class Work(val id: String, val command: Map<String, Any?>,
                       val reply: (Map<*, *>) -> Unit)

    val busy: Boolean get() = pending != null
    fun ownsOperation(id: String): Boolean = pending?.id == id
    fun current(id: Long) = engine != null && serial == id

    fun execute(id: String, command: Map<String, Any?>, reply: (Map<*, *>) -> Unit) {
        check(!busy)
        pending = Work(id, command, reply)
        try {
            ensureEngine()
            dispatch()
        } catch (_: Exception) {
            pending = null
            try { reply(mapOf("message" to AppStrings.message(R.string.error_background_start).toMap())) }
            finally { AppBridge.executorDrained(id); releaseIfIdle() }
        }
    }

    private fun ensureEngine() {
        if (engine != null) return
        ready = false
        retained = false
        val id = ++serial
        // The SDK group initializes its loader before the first bundle-path lookup.
        val engines = application.engines
        val entry = DartExecutor.DartEntrypoint(
            FlutterInjector.instance().flutterLoader().findAppBundlePath(), "appBackgroundMain")
        engine = engines.createAndRunEngine(
            FlutterEngineGroup.Options(application).setDartEntrypoint(entry)
                .setAutomaticallyRegisterPlugins(false))
        channel = AppBridge.attachWork(engine!!, id)
        Log.i("PseudoLogic", "engine created runtime=$id")
    }

    fun ready(id: Long) {
        if (!current(id) || ready) return
        ready = true
        reconcile()
        dispatch()
    }

    private fun dispatch() {
        val work = pending ?: return
        if (!ready || executing) return
        executing = true
        val runtime = serial
        channel!!.invokeMethod("execute", work.command + ("owner" to work.id), object : MethodChannel.Result {
            override fun success(result: Any?) = complete(
                result as? Map<*, *> ?: mapOf("message" to AppStrings.message(R.string.error_invalid_result).toMap()))
            override fun error(code: String, message: String?, details: Any?) =
                complete(mapOf("message" to AppStrings.message(R.string.error_operation_incomplete).toMap()))
            override fun notImplemented() = error("missing", null, null)
            private fun complete(result: Map<*, *>) {
                if (!current(runtime) || pending !== work) return
                executing = false
                pending = null
                try {
                    work.reply(result)
                    reconcile()
                } finally {
                    AppBridge.executorDrained(work.id)
                }
            }
        })
    }

    /**
     * Settle queued commands directly. Executing restore retains its actual Dart
     * Stop/install waiter and drains normally.
     */
    fun cancelBeforeExecution(id: String): Boolean {
        val work = pending?.takeIf { it.id == id && !executing } ?: return false
        pending = null
        try {
            work.reply(AppBridge.notExecutedResult(work.command, AppStrings.message(R.string.error_operation_ended)))
        } finally {
            AppBridge.executorDrained(id)
            releaseIfIdle()
        }
        return true
    }

    fun cancel(id: String) {
        if (pending?.id != id) return
        if (executing) {
            // Keep the writer gate closed until execute has actually returned.
            channel?.invokeMethod("cancel", id)
        } else {
            pending = null
            releaseIfIdle()
        }
    }

    fun retain(id: Long, value: Boolean) {
        if (!current(id)) return
        retained = value
        // Reply to the Dart call before possibly destroying its messenger.
        main.post { if (current(id)) releaseIfIdle() }
    }

    fun reconcile() {
        val running = PseudoVpnService.session.snapshot().phase == NativeSession.Phase.RUNNING
        if (engine == null && running) {
            try { ensureEngine() } catch (_: Exception) {
                Log.w("PseudoLogic", "unable to start observer")
                return
            }
        }
        if (engine == null) return
        stateDirty = true
        sendState()
    }

    private fun sendState() {
        if (!ready || syncing || !stateDirty) return
        syncing = true
        stateDirty = false
        val runtime = serial
        channel!!.invokeMethod("runtimeState", AppBridge.runtimeState(), object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (!current(runtime)) return
                retained = (result as? Map<*, *>)?.get("retain") == true
                complete()
            }
            override fun error(code: String, message: String?, details: Any?) {
                if (!current(runtime)) return
                complete()
            }
            override fun notImplemented() = error("missing", null, null)
            private fun complete() {
                syncing = false
                if (stateDirty) sendState() else releaseIfIdle()
            }
        })
    }

    fun connections(detail: Map<*, *>?, reply: MethodChannel.Result) =
        observation("connections", mapOf("detail" to detail), "connections", reply)

    fun traffic(reply: MethodChannel.Result) =
        observation("traffic", emptyMap(), "points", reply)

    private fun observation(method: String, arguments: Map<String, Any?>,
                            rows: String, reply: MethodChannel.Result) {
        if (engine == null) {
            reconcile()
            if (engine == null) {
                reply.success(mapOf("generation" to 0, "configId" to "", "revision" to 0,
                    "sessionGeneration" to PseudoVpnService.session.snapshot().generation,
                    "phase" to PseudoVpnService.session.snapshot().phase.name,
                    "fresh" to false, rows to emptyList<Any>()))
                return
            }
        }
        if (!ready || querying) { reply.error("waiting", null, AppStrings.message(R.string.status_updating).toMap()); return }
        querying = true
        val runtime = serial
        var replied = false
        val timeout = Runnable {
            if (!replied) { replied = true; reply.error("timeout", null, AppStrings.message(R.string.error_update_failed).toMap()) }
        }
        main.postDelayed(timeout, 3000)
        channel!!.invokeMethod(method, arguments + mapOf("state" to AppBridge.runtimeState()),
            object : MethodChannel.Result {
                override fun success(result: Any?) = complete(result, null)
                override fun error(code: String, message: String?, details: Any?) = complete(null, AppStrings.message(R.string.error_update_failed))
                override fun notImplemented() = error("missing", null, null)
                private fun complete(value: Any?, error: AppMessage?) {
                    if (!current(runtime)) return
                    querying = false
                    main.removeCallbacks(timeout)
                    if (!replied) {
                        replied = true
                        if (error != null) reply.error(method, null, error.toMap()) else reply.success(value)
                    }
                    releaseIfIdle()
                }
            })
    }

    fun releaseDetail() {
        if (ready) channel?.invokeMethod("releaseDetail", null)
    }

    private fun releaseIfIdle() {
        if (engine == null || busy || querying || retained || (ready && (syncing || stateDirty)) ||
            PseudoVpnService.session.snapshot().phase != NativeSession.Phase.STOPPED) return
        channel?.setMethodCallHandler(null)
        channel = null
        engine?.destroy()
        engine = null
        ready = false
        syncing = false
        stateDirty = false
        Log.i("PseudoLogic", "engine released runtime=$serial")
    }
}
