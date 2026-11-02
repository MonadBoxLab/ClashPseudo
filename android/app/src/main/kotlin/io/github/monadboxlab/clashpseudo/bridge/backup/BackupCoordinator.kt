package io.github.monadboxlab.clashpseudo.bridge.backup

import android.content.Context
import android.os.Handler
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.backup.BackupCalls
import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import io.github.monadboxlab.clashpseudo.backup.RestoreTransaction
import io.github.monadboxlab.clashpseudo.backup.backupInteger
import io.github.monadboxlab.clashpseudo.backup.backupProjection
import io.github.monadboxlab.clashpseudo.backup.restoreStatus
import io.github.monadboxlab.clashpseudo.nativecore.CoreLifecycleCalls
import io.github.monadboxlab.clashpseudo.bridge.operation.OperationState
import io.github.monadboxlab.clashpseudo.logic.LogicEngineHost
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.message.AppStrings
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.util.concurrent.CancellationException

internal class BackupCoordinator(
    private val context: Context,
    private val main: Handler,
    private val operations: OperationState,
    private val calls: () -> BackupCalls,
    private val nativeCalls: () -> CoreLifecycleCalls,
    private val logic: LogicEngineHost,
    private val uiEligible: (io.github.monadboxlab.clashpseudo.MainActivity) -> Boolean,
    private val exitingForCleanup: () -> Boolean,
    private val refreshBusy: () -> Unit,
    private val publicationBusy: () -> Boolean,
    private val setPublicationBusy: (Boolean) -> Unit,
    private val endAuthorization: () -> Unit,
    private val cancelPendingRefresh: () -> Unit,
    private val cancelSystemRestore: () -> Boolean,
    private val systemRestoreOwner: () -> String?,
    private val notifyUi: () -> Unit,
) {
    private val native: CoreLifecycleCalls get() = nativeCalls()

    private val backupUses = mutableMapOf<String, String>()
    private val preparedBackups = mutableMapOf<String, String>()
    private val retiredBackups = mutableMapOf<String, MutableList<(Throwable?) -> Unit>>()
    @Volatile private var restoreStopRequested = false
    private var restoreStopOwner: String? = null
    private var restoreStopReply: MethodChannel.Result? = null
    private var restoreInterruption: AppMessage? = null
    private var installedBackup: Pair<String, Map<String, Any?>>? = null
    private val backupCapturing: Boolean
        get() = backups.snapshot()["capturing"] == true

    private val backups: BackupCalls get() = calls()
    private var storagePublishing: Boolean
        get() = publicationBusy()
        set(value) = setPublicationBusy(value)

    init {
        operations.admitted = {
            installedBackup = null
            restoreStopRequested = false
            restoreInterruption = null
        }
    }

    val pendingRestore: Boolean get() = operations.command?.get("action") == "restoreBackup"
    val capturing: Boolean get() = backupCapturing
    val stopRequested: Boolean get() = restoreStopRequested
    fun hasStopOwner(id: String): Boolean = restoreStopOwner == id
    fun isRetired(token: String): Boolean = token in retiredBackups
    fun releaseAndDiscard(caller: String?, token: String?, reply: (Throwable?) -> Unit) {
        if (caller != null && backupUses[caller] == token) backupUses.remove(caller)
        discardBackup(token, reply)
    }
    fun retirePreparation(owner: String) {
        backupUses[owner]?.let { token ->
            retiredBackups.getOrPut(token) { mutableListOf() }
            preparedBackups.entries.removeAll { it.value == token }
        }
    }
    fun interrupted(owner: String, message: AppMessage) {
        restoreInterruption = message
        requestRestoreStop(owner, false)
    }
    fun finishDetail(id: String, outcome: Map<*, *>) {
        val action = operations.command?.get("action")
        val backupAction = action in setOf("prepareBackup", "inspectBackup", "restoreBackup")
        val nativeInstall = installedBackup?.takeIf { it.first == id }?.second
        var detail = backupProjection(outcome["backupResult"])
        if (action == "restoreBackup" && nativeInstall != null) {
            detail = backupProjection((detail ?: emptyMap()) + nativeInstall +
                ("status" to restoreStatus(nativeInstall["committed"])))
        }
        val token = backupUses[id]
        val cancelledPreparation = action == "prepareBackup" && token != null && token in retiredBackups
        val retire = action == "prepareBackup" && token != null &&
            (cancelledPreparation || outcome["success"] != true || detail?.get("status") != "prepared" ||
                detail?.get("token") != token || detail?.get("summary") !is Map<*, *>)
        if (retire) {
            retirePreparation(id)
            detail = (detail ?: emptyMap()) + ("retired" to true)
        }
        operations.backupResult = if (backupAction && detail != null)
            backupProjection(detail + ("requestId" to operations.command?.get("requestId"))) else null
    }
    fun retainInterruption(action: Any?) {
        if (action == "restoreBackup" && operations.backupResult?.get("committed") != true &&
            restoreInterruption != null && operations.resultMessage != restoreInterruption) {
            operations.resultMessage = operations.resultMessage?.withDetail(restoreInterruption) ?: restoreInterruption
        }
    }
    fun executorDrained(id: String) {
        val token = backupUses.remove(id)
        if (token != null && token in retiredBackups && token !in backupUses.values) discardBackup(token)
    }

    fun backupUi(call: MethodCall, owner: io.github.monadboxlab.clashpseudo.MainActivity, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val requestId = arguments["requestId"] as? String
        if (call.method == "backupDiscard") {
            discardBackup(arguments["token"] as? String) { error ->
                if (error == null) result.success(null)
                else result.error("backupCleanup", null, AppMessage("backupFailed").withDetail(error).toMap())
            }
            return
        }
        if (call.method == "backupCancel") {
            if (requestId != null) cancelBackup(requestId)
            result.success(null)
            return
        }
        if (!uiEligible(owner) || requestId.isNullOrBlank()) {
            result.error("expired", null, AppMessage("operationFinished").toMap())
            return
        }
        if (exitingForCleanup() || operations.command?.get("action") == "scheduleCoreCleanup") {
            result.error("busy", null, AppStrings.message(R.string.error_busy).toMap())
            return
        }
        when (call.method) {
            "backupPickImport" -> backups.pickImport(requestId) { result.success(it) }
            "backupSaveExport" -> {
                val token = arguments["token"] as? String
                val title = arguments["title"] as? String
                if (token == null || title == null || token in retiredBackups || token in backupUses.values) {
                    result.error("backup", null, AppMessage("backupInvalid").toMap())
                } else {
                    // The UI now knows this token; its new save request owns explicit cleanup.
                    preparedBackups.entries.removeAll { it.value == token }
                    backups.saveExport(requestId, token, title) { result.success(it) }
                }
            }
        }
    }

    fun cancelBackup(requestId: String) {
        backups.cancel(requestId)
        val owner = operations.operationId
        if (owner != null && operations.command?.get("requestId") == requestId &&
            operations.command?.get("action") in setOf("prepareBackup", "inspectBackup", "restoreBackup")) {
            backupUses[owner]?.let { retiredBackups.getOrPut(it) { mutableListOf() } }
            if (pendingRestore) requestRestoreStop(owner, stopNetwork = false)
            else if (!logic.cancelBeforeExecution(owner)) logic.cancel(owner)
        }
        preparedBackups[requestId]?.let { discardBackup(it) }
        if (operations.backupResult?.get("requestId") == requestId) {
            discardBackup(operations.backupResult?.get("token") as? String)
        }
    }

    fun discardBackup(token: String?, reply: (Throwable?) -> Unit = {}) {
        if (token == null || !BackupFiles.isToken(token)) { reply(null); return }
        preparedBackups.entries.removeAll { it.value == token }
        if (token in backupUses.values) retiredBackups.getOrPut(token) { mutableListOf() }.add(reply)
        else {
            val waiting = retiredBackups.remove(token).orEmpty()
            backups.discardCandidate(token) { error -> waiting.forEach { it(error) }; reply(error) }
        }
    }

    fun backupOwner(id: String, restore: Boolean = false) = object : RestoreTransaction.Owner {
        override fun checkCurrent() {
            if (operations.operationId != id || operations.remainingMs(id) == 0L || (restore && restoreStopRequested)) {
                throw CancellationException("Backup operation ended")
            }
        }
        override fun runIfCurrent(block: () -> Unit) {
            synchronized(operations.publicationGate) { checkCurrent(); block() }
        }
    }

    fun backupWork(call: MethodCall, owner: String, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val action = operations.command?.get("action")
        when (call.method) {
            "backupPrepareExport" -> {
                val requestId = arguments["requestId"] as? String
                val created = backupInteger(arguments["createdAtMillis"])
                val epoch = backupInteger(arguments["expectedEpoch"])
                val rawDefaults = arguments["defaults"] as? Map<*, *>
                if (action != "prepareBackup" || requestId == null || requestId != operations.command?.get("requestId") ||
                    created == null || created != backupInteger(operations.command?.get("createdAtMillis")) ||
                    epoch == null || epoch != backupInteger(operations.command?.get("storageEpoch")) ||
                    rawDefaults == null || rawDefaults.keys.any { it !is String } || rawDefaults.values.any { it !is String }) {
                    result.error("backup", null, AppMessage("backupInvalid").toMap())
                    return
                }
                val defaults = rawDefaults.entries.associate { it.key as String to it.value as String }
                backups.prepareExport(requestId, created, epoch, defaults, backupOwner(owner)) { value ->
                    val token = (value["token"] as? String)?.takeIf { BackupFiles.isToken(it) }
                    val current = operations.operationId == owner && (token == null || backupUses[owner]?.let { it != token } != true)
                    if (current && value["retired"] != true && value["status"] == "ready" && token != null) {
                        backupUses[owner] = token
                        preparedBackups[requestId] = token
                        result.success(value)
                    } else if (token != null) {
                        // Retired capture is still an actual result, but not a new
                        // reader owner. Return after its private cleanup completes.
                        backups.discardCandidate(token) { error ->
                            val retired = value + ("retired" to true)
                            val cleanup = error?.let {
                                (AppMessage.fromMap(value["cleanupError"]) ?: AppMessage("backupFailed"))
                                    .withDetail(it).toMap()
                            }
                            result.success(if (cleanup == null) retired else retired + ("cleanupError" to cleanup))
                        }
                    } else result.success(if (current) value else value + ("retired" to true))
                }
            }
            "backupCandidate" -> {
                val token = arguments["token"] as? String
                if (action !in setOf("inspectBackup", "restoreBackup") || token == null ||
                    token != operations.command?.get("token") || !BackupFiles.isToken(token) || token in retiredBackups ||
                    backupUses[owner]?.let { it != token } == true) {
                    result.error("backup", null, AppMessage("backupInvalid").toMap())
                    return
                }
                // The pin covers all asynchronous Dart Store reads and native
                // withRecord access.
                backupUses[owner] = token
                backups.candidate(token) { value ->
                    result.success(if (operations.operationId == owner) value else value + ("retired" to true))
                }
            }
            "backupInstall" -> installBackup(arguments, owner, result)
        }
    }

    fun installBackup(arguments: Map<*, *>, owner: String, result: MethodChannel.Result) {
        val token = arguments["token"] as? String
        val epoch = backupInteger(arguments["expectedEpoch"])
        if (!pendingRestore || token == null || token != operations.command?.get("token") || backupUses[owner] != token ||
            epoch == null || epoch != backupInteger(operations.command?.get("storageEpoch")) || storagePublishing || backupCapturing) {
            result.error("backup", null, AppMessage("backupInvalid").toMap())
            return
        }
        val files = BackupFiles.get(context)
        val installation = BackupFiles.Operation(backupOwner(owner, restore = true))
        storagePublishing = true
        PseudoVpnService.core.setOperationBusy(true)
        try {
            files.ioExecutor.execute {
                var attempted = false
                val actual = try {
                    installation.check()
                    check(PseudoVpnService.session.snapshot().phase == NativeSession.Phase.STOPPED &&
                        PseudoVpnService.core.snapshot().phase == io.github.monadboxlab.clashpseudo.nativecore.CoreHost.Phase.EMPTY)
                    attempted = true
                    val installed = files.transaction.install(token, epoch, installation)
                    mapOf("committed" to installed.committed, "rolledBack" to installed.rolledBack,
                        "ready" to installed.ready, "epoch" to installed.epoch, "errorCode" to installed.error,
                        "errorDetail" to installed.cause?.let { AppMessage("backupFailed").withDetail(it).toMap() })
                } catch (error: Exception) {
                    val state = files.transaction.snapshot()
                    mapOf("committed" to (if (!attempted || error is CancellationException) false else null),
                        "rolledBack" to false, "ready" to state.ready, "epoch" to state.epoch,
                        "errorCode" to if (error is CancellationException) "restoreCancelled" else "storageInstallUnconfirmed",
                        "errorDetail" to AppMessage("backupFailed").withDetail(error).toMap())
                }
                main.post {
                    storagePublishing = false
                    installedBackup = owner to actual
                    if (operations.operationId == owner && pendingRestore && actual["ready"] == true) {
                        // Only this restore owner receives the trusted native epoch continuation.
                        operations.command = operations.command!! + ("storageEpoch" to actual["epoch"])
                    } else if (operations.resultId == owner && operations.operationId == null) {
                        // Preserve a real commit received after transport or engine
                        // failure.
                        val detail = (operations.backupResult ?: emptyMap<Any, Any>()) + actual + mapOf(
                            "token" to token, "status" to restoreStatus(actual["committed"]))
                        operations.backupResult = backupProjection(detail)
                        operations.resultSuccess = false
                        operations.resultMessage = AppMessage(if (actual["committed"] == true) "backupRestoreUnconfirmed" else "backupNotRestored")
                    }
                    // Raw actual result, including commit, even after cancellation or owner retirement.
                    result.success(actual)
                    refreshBusy()
                    notifyUi()
                }
            }
        } catch (error: Exception) {
            storagePublishing = false
            result.error("storage", null, AppMessage("storageUnavailable").withDetail(error).toMap())
            refreshBusy()
        }
        notifyUi()
    }

    fun requestRestoreStop(owner: String, stopNetwork: Boolean) {
        synchronized(operations.publicationGate) {
            if (operations.operationId != owner || !pendingRestore) return
            restoreStopRequested = true
        }
        // Retire the permission waiter while retaining executing restore and
        // Stop/install replies; discard late grants.
        endAuthorization()
        if (stopNetwork) {
            cancelPendingRefresh()
            // A waiting Android start is distinct from this admitted backup restore.
            if (systemRestoreOwner() != owner) cancelSystemRestore()
        }
        // Retain the Dart waiter through actual Stop/read/install completion.
        // Subsequent checks observe the Stop intent.
        if (restoreStopOwner != owner) {
            // Keep an in-flight Stop waiter alive; cancel a pending reconnect before
            // requesting normal network Stop.
            native.abandon()
            if (stopNetwork && PseudoVpnService.session.snapshot().phase != NativeSession.Phase.STOPPING &&
                PseudoVpnService.core.snapshot().phase != io.github.monadboxlab.clashpseudo.nativecore.CoreHost.Phase.RELEASING) {
                restoreNetworkStop(owner, null, internalReconnect = false)
            }
        }
        logic.cancelBeforeExecution(owner)
        notifyUi()
    }

    fun restoreNetworkStop(owner: String, reply: MethodChannel.Result?, internalReconnect: Boolean) {
        if (restoreStopOwner == owner) {
            if (reply != null) {
                if (restoreStopReply == null) restoreStopReply = reply
                else reply.error("busy", null, AppStrings.message(R.string.error_busy).toMap())
            }
            return
        }
        restoreStopOwner = owner
        restoreStopReply = reply
        native.stop(object : MethodChannel.Result {
            fun take(): MethodChannel.Result? {
                if (restoreStopOwner != owner) return null
                restoreStopOwner = null
                val receiver = restoreStopReply
                restoreStopReply = null
                return receiver
            }
            override fun success(value: Any?) { take()?.success(value) }
            override fun error(code: String, message: String?, details: Any?) { take()?.error(code, message, details) }
            override fun notImplemented() { take()?.notImplemented() }
        }, internalReconnect)
    }
}
