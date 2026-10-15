package io.github.monadboxlab.clashpseudo.app

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.lang.ref.WeakReference
import java.util.UUID

object AppBridge {
    const val CHANNEL = "io.github.monadboxlab.clashpseudo/app"
    private lateinit var context: Context
    private lateinit var native: NativeCalls
    private lateinit var modes: ModeCalls
    private lateinit var strategies: StrategyCalls
    private lateinit var connections: ConnectionsCalls
    private val main = Handler(Looper.getMainLooper())
    private var activity = WeakReference<MainActivity>(null)
    private var ui: MethodChannel? = null
    private var authorization: MethodChannel.Result? = null
    private var authorizationCode = 100
    private var operation: String? = null
    private var resultMessage: String? = null
    private var resultId: String? = null
    private var resultSuccess = false
    private var needsHttp = false
    var command: Map<String, Any?>? = null
        private set
    var operationId: String? = null
        private set

    fun initialize(appContext: Context) {
        context = appContext
        native = NativeCalls(context)
        modes = ModeCalls(PseudoVpnService.session, PseudoVpnService.worker, { notifyUi() })
        strategies = StrategyCalls(PseudoVpnService.core, { notifyUi() })
        connections = ConnectionsCalls(PseudoVpnService.core)
    }

    fun attachUi(owner: MainActivity, engine: FlutterEngine) {
        activity = WeakReference(owner)
        ui = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "paths" -> result.success(paths())
                    "snapshot" -> snapshot(null, result)
                    "strategies" -> strategies.read(call.argument<Number>("generation")?.toLong() ?: -1L,
                        null, strategyReply(result))
                    "connections" -> connections.read(call.argument<Number>("generation")?.toLong() ?: -1L,
                        call.argument<String>("configId").orEmpty(), call.argument<Int>("revision") ?: -1) { value, error ->
                        if (error != null) result.error("connections", error, null)
                        else result.success(value)
                    }
                    "submit" -> submit(call, result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun detachUi(owner: MainActivity) {
        if (activity.get() !== owner) return
        ui?.setMethodCallHandler(null)
        ui = null
        activity.clear()
        if (!owner.isChangingConfigurations) authorizationResult(false)
    }

    fun attachWork(engine: FlutterEngine, service: AppWorkService): MethodChannel {
        val owner = operationId
        return MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (owner == null || owner != operationId) {
                    result.error("expired", "操作已结束。", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "paths" -> result.success(paths())
                    "snapshot" -> snapshot(owner, result)
                    "ready" -> { result.success(null); main.post { service.ready(channel) } }
                    "stage" -> { operation = call.arguments as String; notifyUi(); result.success(null) }
                    "authorize" -> authorize(result)
                    "start" -> native.start(call.argument<String>("id")!!,
                        call.argument<Int>("revision")!!, call.argument<String>("mode").orEmpty(), owner, result)
                    "prepareStrategies" -> strategies.prepare(context, owner, call.argument<String>("id").orEmpty(),
                        call.argument<Int>("revision") ?: 0, call.argument<String>("mode").orEmpty(), strategyReply(result))
                    "releasePreview" -> strategies.release(owner, strategyReply(result))
                    "strategies" -> strategies.read(call.argument<Number>("generation")?.toLong() ?: -1L,
                        owner, strategyReply(result))
                    "setStrategy" -> strategies.change(call.argument<Number>("generation")?.toLong() ?: -1L,
                        owner, call.argument<String>("name").orEmpty(),
                        call.argument<Map<String, Any?>>("choice") ?: emptyMap<String, Any?>(), strategyReply(result))
                    "stop" -> native.stop(result)
                    "setMode" -> {
                        val generation = call.argument<Number>("generation")?.toLong() ?: -1L
                        modes.change(generation, owner, call.argument<String>("mode").orEmpty()) { mode, error ->
                            if (error != null) result.error("mode", error, null)
                            else result.success(mode)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun submit(call: MethodCall, result: MethodChannel.Result) {
        if (operationId != null) {
            result.error("busy", "已有操作正在处理，请等待确认。", null)
            return
        }
        @Suppress("UNCHECKED_CAST")
        val request = call.arguments as? Map<String, Any?>
        if (request?.get("action") !in setOf("import", "start", "stop", "select", "delete", "setMode", "prepareStrategies", "setStrategy")) {
            result.error("command", "无法识别此操作。", null)
            return
        }
        operationId = UUID.randomUUID().toString()
        PseudoVpnService.core.setOperationBusy(true)
        command = request
        operation = "正在受理操作"
        resultMessage = null
        resultId = null
        try {
            val intent = Intent(context, AppWorkService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
            else context.startService(intent)
            result.success(null)
            notifyUi()
        } catch (_: Exception) {
            finish(operationId!!, mapOf("message" to "系统未允许启动任务，请返回应用后重试。"))
            result.error("service", "系统未允许启动任务。", null)
        }
    }

    private fun authorize(result: MethodChannel.Result) {
        if (VpnService.prepare(context) == null) { result.success(true); return }
        val owner = activity.get()
        if (owner == null || owner.isFinishing || authorization != null) {
            result.error("permission", "请返回应用并重新启动以完成 VPN 授权。", null)
            return
        }
        if (authorizationCode == 0xffff) {
            result.error("permission", "授权请求次数过多，请重启应用后再试。", null)
            return
        }
        authorization = result
        // Do not let a result arriving after timeout settle a later operation.
        owner.requestVpnPermission(++authorizationCode)
    }

    fun authorizationResult(requestCode: Int, granted: Boolean) {
        if (requestCode == authorizationCode) authorizationResult(granted)
    }

    private fun authorizationResult(granted: Boolean) {
        val result = authorization ?: return
        authorization = null
        result.success(granted && VpnService.prepare(context) == null)
    }

    fun nativeChanged() {
        native.changed()
        if (operationId == null) {
            // A system revocation or service exit supersedes earlier UI results.
            resultMessage = null
            resultId = null
            needsHttp = false
        }
        notifyUi()
    }

    fun finish(id: String, outcome: Map<*, *>) {
        if (operationId != id) return
        authorizationResult(false)
        native.abandon()
        modes.abandon(id)
        strategies.abandon(id)
        try { AppFiles.runInput(context, id).delete() } catch (_: Exception) { }
        resultId = id
        resultSuccess = outcome["success"] == true
        resultMessage = outcome["message"] as? String ?: "操作已结束，请核实状态。"
        needsHttp = outcome["needsHttpConfirmation"] == true
        operationId = null
        command = null
        operation = null
        PseudoVpnService.core.setOperationBusy(false)
        notifyUi()
    }

    fun notifyUi() { ui?.invokeMethod("changed", null) }

    private fun strategyReply(result: MethodChannel.Result): (String?, String?) -> Unit =
        { value, error ->
            if (error != null) result.error("strategy", error, null)
            else result.success(value)
        }

    private fun paths() = mapOf(
        "configs" to AppFiles.configs(context).absolutePath,
        "runInput" to AppFiles.runInput(context, operationId ?: "unowned").absolutePath,
    )

    private fun snapshot(owner: String?, result: MethodChannel.Result) {
        val before = PseudoVpnService.session.snapshot()
        if (before.phase != NativeSession.Phase.RUNNING) {
            result.success(snapshotMap(before))
            return
        }
        modes.read(before.generation, owner) { mode, error ->
            val current = PseudoVpnService.session.snapshot()
            val matches = current.generation == before.generation && current.phase == before.phase
            result.success(snapshotMap(current) + mapOf(
                "mode" to mode.takeIf { matches },
                "modeError" to (if (matches) error else "接管会话已变化。"),
            ))
        }
    }

    private fun snapshotMap(state: NativeSession.Snapshot): Map<String, Any?> {
        return mapOf(
            "phase" to state.phase.name, "generation" to state.generation,
            "configId" to state.configId, "revision" to state.revision, "error" to state.error,
            "operation" to operation, "resultId" to resultId,
            "resultMessage" to resultMessage, "needsHttpConfirmation" to needsHttp,
            "resultSuccess" to resultSuccess,
            "core" to PseudoVpnService.core.snapshot().toMap(),
        )
    }
}
