package io.github.monadboxlab.clashpseudo.app

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
    fun current(id: Long) = engine != null && serial == id

    fun execute(id: String, command: Map<String, Any?>, reply: (Map<*, *>) -> Unit) {
        check(!busy)
        pending = Work(id, command, reply)
        try {
            ensureEngine()
            dispatch()
        } catch (_: Exception) {
            pending = null
            reply(mapOf("message" to "无法启动后台操作，请返回应用重试。"))
            releaseIfIdle()
        }
    }

    private fun ensureEngine() {
        if (engine != null) return
        ready = false
        retained = false
        val id = ++serial
        val entry = DartExecutor.DartEntrypoint(
            FlutterInjector.instance().flutterLoader().findAppBundlePath(), "appBackgroundMain")
        engine = application.engines.createAndRunEngine(
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
                result as? Map<*, *> ?: mapOf("message" to "操作未返回有效结果。"))
            override fun error(code: String, message: String?, details: Any?) =
                complete(mapOf("message" to "业务操作未完成，请核实状态后重试。"))
            override fun notImplemented() = error("missing", null, null)
            private fun complete(result: Map<*, *>) {
                if (!current(runtime) || pending !== work) return
                executing = false
                pending = null
                work.reply(result)
                reconcile()
                AppBridge.executorDrained(work.id)
            }
        })
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

    fun connections(detail: Map<*, *>?, reply: MethodChannel.Result) {
        if (engine == null) {
            reconcile()
            if (engine == null) {
                reply.success(mapOf("generation" to 0, "configId" to "", "revision" to 0,
                    "sessionGeneration" to PseudoVpnService.session.snapshot().generation,
                    "phase" to PseudoVpnService.session.snapshot().phase.name,
                    "fresh" to false, "connections" to emptyList<Any>()))
                return
            }
        }
        if (!ready || querying) { reply.error("waiting", "正在更新", null); return }
        querying = true
        val runtime = serial
        var replied = false
        val timeout = Runnable {
            if (!replied) { replied = true; reply.error("timeout", "更新失败", null) }
        }
        main.postDelayed(timeout, 3000)
        channel!!.invokeMethod("connections", mapOf("state" to AppBridge.runtimeState(), "detail" to detail),
            object : MethodChannel.Result {
                override fun success(result: Any?) = complete(result, null)
                override fun error(code: String, message: String?, details: Any?) = complete(null, "更新失败")
                override fun notImplemented() = error("missing", null, null)
                private fun complete(value: Any?, error: String?) {
                    if (!current(runtime)) return
                    querying = false
                    main.removeCallbacks(timeout)
                    if (!replied) {
                        replied = true
                        if (error != null) reply.error("connections", error, null) else reply.success(value)
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
