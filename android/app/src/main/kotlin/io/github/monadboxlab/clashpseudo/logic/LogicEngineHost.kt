package io.github.monadboxlab.clashpseudo.logic

import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.message.AppStrings
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
    private val observationOwners = mutableSetOf<String>()
    private var releasingDetails = 0
    private var syncing = false
    private var stateDirty = false
    private var executing = false
    private var querying = false
    private var pending: Work? = null
    private var platformOwners = 0
    private var projection: Map<String, Any?> = emptyMap()
    val runtimeProjection: Map<String, Any?> get() = projection

    fun retainPlatform(value: Boolean) {
        platformOwners = (platformOwners + if (value) 1 else -1).coerceAtLeast(0)
        if (!value) main.post { releaseIfIdle() }
    }

    fun updateProjection(value: Map<*, *>): Boolean {
        val previous = projection
        projection = value.entries.filter { it.key in setOf("dnsBusy", "dnsOperation", "logSource", "retain", "mode") }
            .associate { it.key.toString() to it.value }
        if (value["retain"] == true) observationOwners.add("runtime-projection")
        else observationOwners.remove("runtime-projection")
        return previous != projection
    }

    fun coreEvent(value: Map<String, Any?>) {
        channel?.invokeMethod(io.github.monadboxlab.clashpseudo.app.ApplicationContract.CORE_CHANNEL_EVENTS, value)
    }

    private class Forward(val method: String, val arguments: Map<String, Any?>, val reply: MethodChannel.Result)
    private val waitingForReady = mutableListOf<Forward>()
    private var forwarding = 0

    fun read(method: String, arguments: Map<String, Any?>, reply: MethodChannel.Result) {
        try { ensureEngine() }
        catch (error: Throwable) { reply.error(method, null, AppStrings.message(R.string.error_background_start).withDetail(error).toMap()); return }
        val call = Forward(method, arguments, reply)
        if (ready) forward(call)
        else {
            waitingForReady.add(call)
            main.postDelayed({
                if (waitingForReady.remove(call)) {
                    reply.error("runtimeNotReady", null, AppStrings.message(R.string.error_background_start).toMap())
                    releaseIfIdle()
                }
            }, io.github.monadboxlab.clashpseudo.app.ApplicationContract.OPERATION_ORDINARY_TIMEOUT_MS)
        }
    }

    private fun forward(call: Forward) {
        val runtime = serial
        forwarding++
        val receiver = object : MethodChannel.Result {
            private var completed = false
            override fun success(result: Any?) = complete { call.reply.success(result) }
            override fun error(code: String, message: String?, details: Any?) = complete { call.reply.error(code, message, details) }
            override fun notImplemented() = complete { call.reply.notImplemented() }
            fun complete(deliver: () -> Unit) {
                if (completed || !current(runtime)) return
                completed = true
                forwarding--
                try { deliver() } finally { releaseIfIdle() }
            }
        }
        try { channel!!.invokeMethod(call.method, call.arguments + ("state" to AppBridge.runtimeState()), receiver) }
        catch (error: Throwable) { receiver.error(call.method, null, AppStrings.message(R.string.error_update_failed).withDetail(error).toMap()) }
    }

    private class Work(val id: String, val command: Map<String, Any?>,
                       val reply: (Map<*, *>) -> Unit)

    val busy: Boolean get() = pending != null
    fun ownsOperation(id: String): Boolean = pending?.id == id
    fun current(id: Long) = engine != null && serial == id

    fun execute(id: String, command: Map<String, Any?>, reply: (Map<*, *>) -> Unit) {
        check(!busy)
        pending = Work(id, command, reply)
        AppBridge.executorStarted(id)
        try {
            ensureEngine()
            dispatch()
        } catch (error: Exception) {
            pending = null
            executing = false
            try { reply(AppBridge.notExecutedResult(command,
                AppStrings.message(R.string.error_background_start).withDetail(error))) }
            finally { AppBridge.executorDrained(id); releaseIfIdle() }
        } catch (error: LinkageError) {
            pending = null
            executing = false
            try { reply(AppBridge.notExecutedResult(command,
                AppStrings.message(R.string.error_background_start).withDetail(error))) }
            finally { AppBridge.executorDrained(id); releaseIfIdle() }
        }
    }

    private fun ensureEngine() {
        if (engine != null) return
        ready = false
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
        AppBridge.syncUiVisibility()
        val waiting = waitingForReady.toList()
        waitingForReady.clear()
        waiting.forEach(::forward)
        reconcile()
        dispatch()
    }

    private fun dispatch() {
        val work = pending ?: return
        if (!ready || executing) return
        executing = true
        val runtime = serial
        val receiver = object : MethodChannel.Result {
            override fun success(result: Any?) = complete(
                result as? Map<*, *> ?: mapOf("message" to
                    AppStrings.message(R.string.error_invalid_result).withDetail(result).toMap()))
            override fun error(code: String, message: String?, details: Any?) = complete(mapOf("message" to
                channelError(code, message, details, AppStrings.message(R.string.error_operation_incomplete)).toMap()))
            override fun notImplemented() = error("missing", null, null)
            fun complete(result: Map<*, *>) {
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
        }
        try {
            channel!!.invokeMethod("execute", work.command + ("owner" to work.id), receiver)
        } catch (error: Exception) {
            receiver.complete(mapOf("message" to
                AppStrings.message(R.string.error_operation_incomplete).withDetail(error).toMap()))
        } catch (error: LinkageError) {
            receiver.complete(mapOf("message" to
                AppStrings.message(R.string.error_operation_incomplete).withDetail(error).toMap()))
        }
    }

    private fun channelError(code: String, message: String?, details: Any?, fallback: AppMessage): AppMessage =
        AppMessage.fromMap(details)?.withDetail(message)
            ?: fallback.withDetail("$code: $message\n$details")

    /** Settle queued work; executing commands retain their actual return and drain. */
    fun cancelBeforeExecution(id: String, message: AppMessage = AppStrings.message(R.string.error_operation_ended)): Boolean {
        val work = pending?.takeIf { it.id == id && !executing } ?: return false
        pending = null
        try {
            work.reply(AppBridge.notExecutedResult(work.command, message))
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
            AppBridge.executorDrained(id)
            releaseIfIdle()
        }
    }

    fun retain(id: Long, value: Boolean, owner: String) {
        require(owner.isNotEmpty())
        if (!current(id)) return
        if (value) observationOwners.add(owner) else observationOwners.remove(owner)
        // Reply to the Dart call before possibly destroying its messenger.
        main.post { if (current(id)) releaseIfIdle() }
    }

    fun reconcile(): AppMessage? {
        val running = PseudoVpnService.core.snapshot().phase != io.github.monadboxlab.clashpseudo.nativecore.CoreHost.Phase.EMPTY
        if (engine == null && running) {
            try { ensureEngine() } catch (error: Exception) {
                return AppStrings.message(R.string.error_background_start).withDetail(error)
            } catch (error: LinkageError) {
                return AppStrings.message(R.string.error_background_start).withDetail(error)
            }
        }
        if (engine == null) return null
        stateDirty = true
        sendState()
        return null
    }

    private fun sendState() {
        if (!ready || syncing || !stateDirty) return
        syncing = true
        stateDirty = false
        val runtime = serial
        val receiver = object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (!current(runtime)) return
                complete()
            }
            override fun error(code: String, message: String?, details: Any?) {
                if (!current(runtime)) return
                Log.w("PseudoLogic", channelError(code, message, details,
                    AppStrings.message(R.string.error_update_failed)).toString())
                complete()
            }
            override fun notImplemented() = error("missing", null, null)
            fun complete() {
                syncing = false
                if (stateDirty) sendState() else releaseIfIdle()
            }
        }
        try {
            channel!!.invokeMethod("runtimeState", AppBridge.runtimeState(), receiver)
        } catch (error: Exception) {
            Log.w("PseudoLogic", "runtimeState failed", error)
            receiver.complete()
        } catch (error: LinkageError) {
            Log.w("PseudoLogic", "runtimeState failed", error)
            receiver.complete()
        }
    }

    fun connections(detail: Map<*, *>?, detailOwner: String?, reply: MethodChannel.Result) =
        connectionObservation("connections", detail, detailOwner, reply)

    fun clearInactiveConnections(detail: Map<*, *>?, detailOwner: String?, reply: MethodChannel.Result) =
        connectionObservation("clearInactiveConnections", detail, detailOwner, reply)

    private fun connectionObservation(method: String, detail: Map<*, *>?, detailOwner: String?, reply: MethodChannel.Result) {
        if (detail != null && detailOwner.isNullOrEmpty()) {
            reply.error("connections", null, AppStrings.message(R.string.error_invalid_result).toMap())
            return
        }
        observation(method, mapOf("detail" to detail, "detailOwner" to detailOwner), "connections", reply)
    }

    fun traffic(reply: MethodChannel.Result) =
        observation("traffic", emptyMap(), "points", reply)

    private fun observation(method: String, arguments: Map<String, Any?>,
                            rows: String, reply: MethodChannel.Result) {
        if (engine == null) {
            val error = reconcile()
            if (error != null) {
                reply.error(method, null, error.toMap())
                return
            }
            if (engine == null) {
                val empty = mapOf("generation" to 0, "configId" to "", "revision" to 0,
                    "sessionGeneration" to PseudoVpnService.session.snapshot().generation,
                    "fresh" to false, rows to emptyList<Any>())
                reply.success(if (method == "traffic") empty + mapOf(
                    "phase" to PseudoVpnService.session.snapshot().phase.name) else empty)
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
        val receiver = object : MethodChannel.Result {
            override fun success(result: Any?) = complete(result, null)
            override fun error(code: String, message: String?, details: Any?) = complete(null,
                channelError(code, message, details, AppStrings.message(R.string.error_update_failed)))
            override fun notImplemented() = error("missing", null, null)
            fun complete(value: Any?, error: AppMessage?) {
                if (!current(runtime)) return
                querying = false
                main.removeCallbacks(timeout)
                if (!replied) {
                    replied = true
                    if (error != null) reply.error(method, null, error.toMap()) else reply.success(value)
                }
                releaseIfIdle()
            }
        }
        try {
            channel!!.invokeMethod(method, arguments + mapOf("state" to AppBridge.runtimeState()), receiver)
        } catch (error: Exception) {
            receiver.complete(null, AppStrings.message(R.string.error_update_failed).withDetail(error))
        } catch (error: LinkageError) {
            receiver.complete(null, AppStrings.message(R.string.error_update_failed).withDetail(error))
        }
    }

    fun releaseDetail(owner: String, reply: MethodChannel.Result) {
        if (owner.isEmpty()) {
            reply.error("connections", null, AppStrings.message(R.string.error_invalid_result).toMap())
            return
        }
        if (!ready || channel == null) { reply.success(null); return }
        val runtime = serial
        releasingDetails++
        val receiver = object : MethodChannel.Result {
            private var completed = false
            override fun success(result: Any?) = complete { reply.success(result) }
            override fun error(code: String, message: String?, details: Any?) = complete { reply.error(code, message, details) }
            override fun notImplemented() = complete { reply.notImplemented() }
            fun complete(deliver: () -> Unit) {
                if (completed || !current(runtime)) return
                completed = true
                releasingDetails--
                try { deliver() } finally { releaseIfIdle() }
            }
        }
        try {
            channel!!.invokeMethod("releaseDetail", mapOf("detailOwner" to owner), receiver)
        } catch (error: Exception) {
            receiver.error("connections", null, AppStrings.message(R.string.error_update_failed).withDetail(error).toMap())
        } catch (error: LinkageError) {
            receiver.error("connections", null, AppStrings.message(R.string.error_update_failed).withDetail(error).toMap())
        }
    }

    private fun releaseIfIdle() {
        if (engine == null || platformOwners > 0 || busy || querying || forwarding > 0 || waitingForReady.isNotEmpty() || observationOwners.isNotEmpty() || releasingDetails != 0 || (ready && (syncing || stateDirty)) ||
            PseudoVpnService.core.snapshot().phase != io.github.monadboxlab.clashpseudo.nativecore.CoreHost.Phase.EMPTY ||
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
