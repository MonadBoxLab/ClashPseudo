package io.github.monadboxlab.clashpseudo.bridge

import io.github.monadboxlab.clashpseudo.backup.backupProjection

import io.github.monadboxlab.clashpseudo.backup.restoreStatus

import io.github.monadboxlab.clashpseudo.backup.backupInteger

import io.github.monadboxlab.clashpseudo.backup.savedMode

import io.github.monadboxlab.clashpseudo.app.ApplicationContract
import io.github.monadboxlab.clashpseudo.app.AppFiles
import io.github.monadboxlab.clashpseudo.app.AppMessage
import io.github.monadboxlab.clashpseudo.app.AppStrings
import io.github.monadboxlab.clashpseudo.app.AppTrust
import io.github.monadboxlab.clashpseudo.app.AppWorkService
import io.github.monadboxlab.clashpseudo.app.OperationBudget
import io.github.monadboxlab.clashpseudo.app.PseudoApplication
import io.github.monadboxlab.clashpseudo.backup.BackupCalls
import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import io.github.monadboxlab.clashpseudo.backup.RestoreTransaction
import io.github.monadboxlab.clashpseudo.controls.SystemControls
import io.github.monadboxlab.clashpseudo.logic.LogicEngineHost
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.schedule.ScheduleManager

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.UnderlyingNetworks
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.CancellationException
import java.io.File
import java.io.InputStreamReader
import java.nio.charset.CodingErrorAction

object AppBridge {
    const val CHANNEL = "io.github.monadboxlab.clashpseudo/app"
    private lateinit var context: Context
    private lateinit var applications: ApplicationsCalls
    private lateinit var native: NativeCalls
    private lateinit var modes: ModeCalls
    private lateinit var strategies: StrategyCalls
    private lateinit var connections: ConnectionsCalls
    private lateinit var coreReads: CoreReadCalls
    private lateinit var delays: DelayCalls
    private lateinit var backups: BackupCalls
    lateinit var logic: LogicEngineHost
        private set
    private val main = Handler(Looper.getMainLooper())
    private var activity = WeakReference<MainActivity>(null)
    private var uiVisible = false
    private var uiReady = false
    private var overviewRequested = false
    private var overviewSending = false
    private var ui: MethodChannel? = null
    private var authorization: MethodChannel.Result? = null
    private var authorizationCode = 100
    private var operation: AppMessage? = null
    private var resultMessage: AppMessage? = null
    private var resultId: String? = null
    private var resultSuccess = false
    private var connectionStatus: String? = null
    private var configStatus: String? = null
    private var overrideStatus: String? = null
    private var resourceStatus: String? = null
    private var scheduleStatus: String? = null
    private var backupResult: Map<*, *>? = null
    private var storagePublishing = false
    private val backupUses = mutableMapOf<String, String>()
    private val preparedBackups = mutableMapOf<String, String>()
    private val retiredBackups = mutableSetOf<String>()
    @Volatile private var restoreStopRequested = false
    private var restoreStopOwner: String? = null
    private var restoreStopReply: MethodChannel.Result? = null
    private var restoreInterruption: AppMessage? = null
    private var installedBackup: Pair<String, Map<String, Any?>>? = null
    private val pendingRestore: Boolean get() = command?.get("action") == "restoreBackup"
    private val backupCapturing: Boolean
        get() = ::backups.isInitialized && backups.snapshot()["capturing"] == true
    private val resourceBusy: Boolean
        get() = command?.get("action") == "updateResource" || (::coreReads.isInitialized && coreReads.updating)
    private var targetId: String? = null
    private var savedRevision: Int? = null
    var command: Map<String, Any?>? = null
        private set
    internal class ScheduledRun(
        val workerStopped: () -> Boolean,
        private val now: () -> Long = SystemClock::elapsedRealtime,
    ) {
        val owner: String = UUID.randomUUID().toString()
        val done = CountDownLatch(1)
        val cancelled = AtomicBoolean(false)
        @Volatile private var admittedAt: Long? = null
        val deadline: Long get() = admittedAt?.plus(ApplicationContract.OPERATION_SCHEDULED_NETWORK_TIMEOUT_MS) ?: Long.MAX_VALUE
        private val operationDeadline: Long get() = admittedAt?.plus(ApplicationContract.OPERATION_ORDINARY_TIMEOUT_MS) ?: Long.MIN_VALUE
        @Volatile var outcome: Map<*, *> = mapOf("success" to false)
            private set
        var applicationTimeout: Runnable? = null
        private var applicationOwned = false

        @Synchronized fun admit(at: Long = now()) {
            check(admittedAt == null)
            admittedAt = at
        }

        // The shared monitor arbitrates Worker exit and local application;
        // LogicEngineHost retains its writer gate until execution returns.
        @Synchronized fun handoff(): Boolean {
            if (admittedAt == null || done.count == 0L || cancelled.get() || workerStopped() ||
                now() >= deadline) return false
            outcome = mapOf("success" to true, "scheduleStatus" to "saved")
            applicationOwned = true
            done.countDown()
            return true
        }

        @Synchronized fun authorized(): Boolean = admittedAt != null && !cancelled.get() &&
            if (applicationOwned) now() < operationDeadline
            else done.count != 0L && !workerStopped() && now() < deadline

        @Synchronized fun remainingMs(): Long = if (!authorized()) 0L
            else ((if (applicationOwned) operationDeadline else deadline) - now()).coerceAtLeast(0L)

        @Synchronized fun publishIfAuthorized(block: () -> Unit) {
            check(authorized())
            block()
        }

        @Synchronized fun applicationRemainingMs(): Long = if (admittedAt == null) 0L
            else (operationDeadline - now()).coerceAtLeast(0L)

        @Synchronized fun finish(value: Map<*, *>) {
            applicationOwned = false
            if (done.count == 0L) return
            if (!cancelled.get()) outcome = value
            done.countDown()
        }

        @Synchronized fun cancelWorker(): Boolean {
            if (done.count == 0L) return false
            cancel()
            return true
        }

        @Synchronized fun cancel() {
            applicationOwned = false
            cancelled.set(true)
            if (done.count != 0L) {
                outcome = mapOf("success" to false, "scheduleStatus" to "cancelled")
                done.countDown()
            }
        }
    }
    @Volatile private var scheduled: ScheduledRun? = null
    private var systemRestoreOwner: String? = null
    private var discardedSystemInput: String? = null
    private class RuntimeRefresh(
        val sessionGeneration: Long,
        val coreGeneration: Long,
        val composition: String,
        val revisions: MutableMap<String, Long> = mutableMapOf(),
    ) {
        fun current() = revisions.any { (reason, revision) ->
            PseudoVpnService.core.runtimeRefreshCurrent(
                sessionGeneration, coreGeneration, composition, revision, reason)
        }
    }
    private var pendingRuntimeRefresh: RuntimeRefresh? = null
    private var activeRuntimeRefresh: RuntimeRefresh? = null
    private var runtimeRefreshTimeout: Runnable? = null
    private val drainRuntimeRefresh = Runnable { drainRuntimeRefresh() }
    val pendingSystemRestore: Boolean get() = systemRestoreOwner != null

    private val publicationGate = Any()
    private var operationAdmittedAt: Long? = null
    @Volatile var operationId: String? = null
        private set(value) {
            synchronized(publicationGate) {
                if (field != value) {
                    operationAdmittedAt = value?.let { SystemClock.elapsedRealtime() }
                }
                if (value != null && field != value) {
                    // Keep the completed receipt paired with resultId until finish replaces it.
                    installedBackup = null
                    restoreStopRequested = false
                    restoreInterruption = null
                }
                field = value
            }
        }

    fun operationRemainingMs(owner: String): Long = synchronized(publicationGate) {
        val admittedAt = operationAdmittedAt
        if (operationId != owner || admittedAt == null) 0L
        else scheduled?.takeIf { it.owner == owner }?.remainingMs()
            ?: OperationBudget.remainingMs(command?.get("action"), admittedAt, SystemClock.elapsedRealtime())
    }

    private fun admission(owner: String): Map<String, Any> = mapOf(
        "operationId" to owner,
        "remainingMs" to operationRemainingMs(owner),
    )

    fun initialize(appContext: Context) {
        context = appContext
        applications = ApplicationsCalls(context, PseudoVpnService.worker)
        native = NativeCalls(context)
        modes = ModeCalls(PseudoVpnService.session, PseudoVpnService.worker, { notifyUi() })
        strategies = StrategyCalls(PseudoVpnService.core, { notifyUi() })
        connections = ConnectionsCalls(PseudoVpnService.core)
        coreReads = CoreReadCalls(PseudoVpnService.core, updateChanged = {
            PseudoVpnService.core.setOperationBusy(operationId != null || logic.busy || resourceBusy || storagePublishing || backupCapturing)
            notifyUi()
        })
        delays = DelayCalls(PseudoVpnService.core)
        logic = LogicEngineHost(appContext.applicationContext as PseudoApplication)
        backups = BackupCalls.get(context) {
            PseudoVpnService.core.setOperationBusy(operationId != null || logic.busy || resourceBusy || storagePublishing || backupCapturing)
            notifyUi()
        }
    }

    fun attachBackupActivity(owner: MainActivity, savedState: Bundle?) = backups.attach(owner, savedState)

    fun saveBackupActivityState(owner: MainActivity, state: Bundle) = backups.saveState(owner, state)

    fun detachBackupActivity(owner: MainActivity) = backups.detach(owner)

    fun backupActivityResult(owner: MainActivity, code: Int, result: Int, data: Intent?): Boolean =
        backups.onActivityResult(owner, code, result, data)

    private fun backupUi(call: MethodCall, owner: MainActivity, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val requestId = arguments["requestId"] as? String
        if (call.method == "backupDiscard") {
            discardBackup(arguments["token"] as? String)
            result.success(null)
            return
        }
        if (call.method == "backupCancel") {
            if (requestId != null) cancelBackup(requestId)
            result.success(null)
            return
        }
        if (activity.get() !== owner || !uiVisible || requestId.isNullOrBlank()) {
            result.error("expired", null, AppMessage("operationFinished").toMap())
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

    private fun cancelBackup(requestId: String) {
        backups.cancel(requestId)
        val owner = operationId
        if (owner != null && command?.get("requestId") == requestId &&
            command?.get("action") in setOf("prepareBackup", "inspectBackup", "restoreBackup")) {
            backupUses[owner]?.let { retiredBackups.add(it) }
            if (pendingRestore) requestRestoreStop(owner, stopNetwork = false)
            else if (!logic.cancelBeforeExecution(owner)) logic.cancel(owner)
        }
        preparedBackups[requestId]?.let { discardBackup(it) }
        if (backupResult?.get("requestId") == requestId) {
            discardBackup(backupResult?.get("token") as? String)
        }
    }

    private fun discardBackup(token: String?) {
        if (token == null || !BackupFiles.isToken(token)) return
        preparedBackups.entries.removeAll { it.value == token }
        if (token in backupUses.values) retiredBackups.add(token)
        else {
            retiredBackups.remove(token)
            backups.discardCandidate(token)
        }
    }

    private fun backupOwner(id: String, restore: Boolean = false) = object : RestoreTransaction.Owner {
        override fun checkCurrent() {
            if (operationId != id || operationRemainingMs(id) == 0L || (restore && restoreStopRequested)) {
                throw CancellationException("Backup operation ended")
            }
        }
        override fun runIfCurrent(block: () -> Unit) {
            synchronized(publicationGate) { checkCurrent(); block() }
        }
    }

    private fun backupWork(call: MethodCall, owner: String, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val action = command?.get("action")
        when (call.method) {
            "backupPrepareExport" -> {
                val requestId = arguments["requestId"] as? String
                val created = backupInteger(arguments["createdAtMillis"])
                val epoch = backupInteger(arguments["expectedEpoch"])
                val rawDefaults = arguments["defaults"] as? Map<*, *>
                if (action != "prepareBackup" || requestId == null || requestId != command?.get("requestId") ||
                    created == null || created != backupInteger(command?.get("createdAtMillis")) ||
                    epoch == null || epoch != backupInteger(command?.get("storageEpoch")) ||
                    rawDefaults == null || rawDefaults.keys.any { it !is String } || rawDefaults.values.any { it !is String }) {
                    result.error("backup", null, AppMessage("backupInvalid").toMap())
                    return
                }
                val defaults = rawDefaults.entries.associate { it.key as String to it.value as String }
                backups.prepareExport(requestId, created, epoch, defaults, backupOwner(owner)) { value ->
                    val token = (value["token"] as? String)?.takeIf { BackupFiles.isToken(it) }
                    if (operationId != owner || (token != null && backupUses[owner]?.let { it != token } == true)) {
                        if (token != null) backups.discardCandidate(token)
                        result.error("expired", null, AppMessage("operationFinished").toMap())
                    } else {
                        if (value["status"] == "ready" && token != null) {
                            backupUses[owner] = token
                            preparedBackups[requestId] = token
                        }
                        result.success(value)
                    }
                }
            }
            "backupCandidate" -> {
                val token = arguments["token"] as? String
                if (action !in setOf("inspectBackup", "restoreBackup") || token == null ||
                    token != command?.get("token") || !BackupFiles.isToken(token) || token in retiredBackups ||
                    backupUses[owner]?.let { it != token } == true) {
                    result.error("backup", null, AppMessage("backupInvalid").toMap())
                    return
                }
                // The pin covers all asynchronous Dart Store reads and native
                // withRecord access.
                backupUses[owner] = token
                backups.candidate(token) { value ->
                    if (operationId != owner) result.error("expired", null, AppMessage("operationFinished").toMap())
                    else result.success(value)
                }
            }
            "backupInstall" -> installBackup(arguments, owner, result)
        }
    }

    private fun installBackup(arguments: Map<*, *>, owner: String, result: MethodChannel.Result) {
        val token = arguments["token"] as? String
        val epoch = backupInteger(arguments["expectedEpoch"])
        if (!pendingRestore || token == null || token != command?.get("token") || backupUses[owner] != token ||
            epoch == null || epoch != backupInteger(command?.get("storageEpoch")) || storagePublishing || backupCapturing) {
            result.error("backup", null, AppMessage("backupInvalid").toMap())
            return
        }
        val files = BackupFiles.get(context)
        val operation = BackupFiles.Operation(backupOwner(owner, restore = true))
        storagePublishing = true
        PseudoVpnService.core.setOperationBusy(true)
        try {
            files.ioExecutor.execute {
                var attempted = false
                val actual = try {
                    operation.check()
                    check(PseudoVpnService.session.snapshot().phase == NativeSession.Phase.STOPPED &&
                        PseudoVpnService.core.snapshot().phase == io.github.monadboxlab.clashpseudo.nativecore.CoreHost.Phase.EMPTY)
                    attempted = true
                    val installed = files.transaction.install(token, epoch, operation)
                    mapOf("committed" to installed.committed, "rolledBack" to installed.rolledBack,
                        "ready" to installed.ready, "epoch" to installed.epoch, "errorCode" to installed.error)
                } catch (error: Exception) {
                    val state = files.transaction.snapshot()
                    mapOf("committed" to (if (!attempted || error is CancellationException) false else null),
                        "rolledBack" to false, "ready" to state.ready, "epoch" to state.epoch,
                        "errorCode" to if (error is CancellationException) "restoreCancelled" else "storageInstallUnconfirmed")
                }
                main.post {
                    storagePublishing = false
                    installedBackup = owner to actual
                    if (operationId == owner && pendingRestore && actual["ready"] == true) {
                        // Only this restore owner receives the trusted native epoch continuation.
                        command = command!! + ("storageEpoch" to actual["epoch"])
                    } else if (resultId == owner && operationId == null) {
                        // Preserve a real commit received after transport or engine
                        // failure.
                        val detail = (backupResult ?: emptyMap<Any, Any>()) + actual + mapOf(
                            "token" to token, "status" to restoreStatus(actual["committed"]))
                        backupResult = backupProjection(detail)
                        resultSuccess = actual["committed"] == true
                        resultMessage = AppMessage(if (resultSuccess) "backupRestoreUnconfirmed" else "backupNotRestored")
                    }
                    // Raw actual result, including commit, even after cancellation or owner retirement.
                    result.success(actual)
                    PseudoVpnService.core.setOperationBusy(operationId != null || logic.busy || resourceBusy || storagePublishing || backupCapturing)
                    notifyUi()
                }
            }
        } catch (_: Exception) {
            storagePublishing = false
            result.error("storage", null, AppMessage("storageUnavailable").toMap())
            PseudoVpnService.core.setOperationBusy(operationId != null || logic.busy || resourceBusy || storagePublishing || backupCapturing)
        }
        notifyUi()
    }

    /** Stop/cancel keeps the restore owner and commit reply. The same arbitration gates admission. */
    private fun requestRestoreStop(owner: String, stopNetwork: Boolean) {
        synchronized(publicationGate) {
            if (operationId != owner || !pendingRestore) return
            restoreStopRequested = true
        }
        // Retire the permission waiter while retaining executing restore and
        // Stop/install replies; discard late grants.
        authorizationResult(false)
        if (stopNetwork) {
            pendingRuntimeRefresh = null
            main.removeCallbacks(drainRuntimeRefresh)
            PseudoVpnService.instance?.cancelSystemStart(terminal = true)
            // A waiting Android start is distinct from this admitted backup restore.
            if (systemRestoreOwner != owner) cancelSystemRestore()
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

    private fun restoreNetworkStop(owner: String, reply: MethodChannel.Result?, internalReconnect: Boolean) {
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
            private fun take(): MethodChannel.Result? {
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

    /** Service timeout/destruction waits for the actual restore result. */
    fun interruptBackupRestore(owner: String, message: AppMessage): Boolean {
        if (operationId != owner || !pendingRestore) return false
        restoreInterruption = message
        requestRestoreStop(owner, stopNetwork = false)
        return true
    }

    private fun trustedRoots(result: MethodChannel.Result, current: () -> Boolean) {
        PseudoVpnService.worker.execute {
            val roots = runCatching { AppTrust.pem(context).toByteArray(Charsets.UTF_8) }
            main.post {
                if (!current()) {
                    result.error("expired", null, AppStrings.message(R.string.error_logic_expired).toMap())
                } else roots.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { result.error("trust", null, AppMessage("trustedRootsUnavailable").toMap()) },
                )
            }
        }
    }

    fun attachUi(owner: MainActivity, engine: FlutterEngine) {
        delays.setVisible(false)
        activity = WeakReference(owner)
        uiVisible = false
        uiReady = false
        overviewSending = false
        ui = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "uiReady" -> {
                        if (activity.get() !== owner) {
                            result.error("expired", null, AppStrings.message(R.string.error_logic_expired).toMap())
                        } else {
                            uiReady = true
                            result.success(null)
                            main.post { deliverOverview() }
                        }
                    }
                    "paths" -> storagePaths(result)
                    "trustRoots" -> trustedRoots(result) { activity.get() === owner }
                    "appInfo" -> applications.appInfo(result)
                    "snapshot" -> snapshot(null, result)
                    "strategies" -> strategies.read(call.argument<Number>("generation")?.toLong() ?: -1L,
                        null, strategyReply(result))
                    "rules" -> coreReads.rules(
                        call.argument<Number>("generation")?.toLong() ?: -1L,
                        call.argument<String>("composition"),
                        call.argument<Map<String, Any?>>("query") ?: emptyMap()) { value, error ->
                            if (error != null) result.error("rules", null, error.toMap())
                            else result.success(value)
                        }
                    "nodes" -> coreReads.nodes(
                        call.argument<Number>("generation")?.toLong() ?: -1L,
                        call.argument<String>("composition"),
                        call.argument<Map<String, Any?>>("query") ?: emptyMap()) { value, error ->
                            if (error != null) result.error("nodes", null, error.toMap())
                            else result.success(value)
                        }
                    "runtimeConfig" -> coreReads.read(
                        call.argument<Number>("generation")?.toLong() ?: -1L,
                        call.argument<String>("composition")) { value, error ->
                            if (error != null) result.error("runtimeConfig", null, error.toMap())
                            else result.success(value)
                        }
                    "resources" -> coreReads.resources(
                        call.argument<Number>("generation")?.toLong() ?: -1L,
                        call.argument<String>("composition")) { value, error ->
                            if (error != null) result.error("resources", null, error.toMap())
                            else result.success(value)
                        }
                    "logs" -> coreReads.logs(
                        call.argument<Number>("generation")?.toLong() ?: -1L,
                        call.argument<String>("composition"),
                        call.argument<Map<String, Any?>>("query") ?: emptyMap()) { value, error ->
                            if (error != null) result.error("logs", null, error.toMap())
                            else result.success(value)
                        }
                    "delayStart" -> delays.start(
                        call.argument<Number>("generation")?.toLong() ?: -1L,
                        call.argument<String>("composition"),
                        call.argument<Map<String, Any?>>("query") ?: emptyMap()) { value, error ->
                            if (error != null) result.error("delay", null, error.toMap())
                            else result.success(value)
                        }
                    "delayRead" -> delays.read(
                        call.argument<Number>("generation")?.toLong() ?: -1L,
                        call.argument<String>("composition"),
                        call.argument<String>("batch").orEmpty()) { value, error ->
                            if (error != null) result.error("delay", null, error.toMap())
                            else result.success(value)
                        }
                    "delayCancel" -> {
                        delays.cancel(call.argument<String>("batch").orEmpty())
                        result.success(null)
                    }
                    "connections" -> logic.connections(call.argument<Map<*, *>>("detail"), result)
                    "traffic" -> logic.traffic(result)
                    "processMemory" -> connections.processMemory { value, error ->
                        if (error != null) result.error("memory", null, error.toMap())
                        else result.success(value)
                    }
                    "dnsQuery", "clearDnsCache", "flushFakeIp", "cancelDnsQuery" -> {
                        if (activity.get() !== owner || (!uiVisible && call.method != "cancelDnsQuery")) {
                            result.error("expired", null, AppStrings.message(R.string.error_logic_expired).toMap())
                        } else coreReads.handleDns(call, result)
                    }
                    "releaseDetail" -> { logic.releaseDetail(); result.success(null) }
                    "openVpnSettings" -> openVpnSettings(result)
                    "vpnStatus" -> result.success(vpnStatus())
                    "applications" -> applications.applications(result)
                    "applicationIcon" -> applications.applicationIcon(call, result)
                    "syncSchedules" -> syncSchedules(call, result)
                    "backupPickImport", "backupSaveExport", "backupCancel", "backupDiscard" ->
                        backupUi(call, owner, result)
                    "submit" -> submit(call, result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun setUiVisible(owner: MainActivity, visible: Boolean) {
        // Match the Activity identity before cancelling its work.
        if (activity.get() !== owner) return
        uiVisible = visible
        delays.setVisible(visible)
        if (!visible) coreReads.cancelDnsForBackground()
        PseudoVpnService.core.setVisible(visible)
    }

    fun detachUi(owner: MainActivity) {
        if (activity.get() !== owner) return
        setUiVisible(owner, false)
        ui?.setMethodCallHandler(null)
        ui = null
        uiReady = false
        overviewSending = false
        activity.clear()
        if (!owner.isChangingConfigurations) authorizationResult(false)
    }

    fun attachWork(engine: FlutterEngine, runtime: Long): MethodChannel {
        return MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (!logic.current(runtime)) {
                    result.error("expired", null, AppStrings.message(R.string.error_logic_expired).toMap())
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "ready" -> {
                        result.success(null)
                        main.post { logic.ready(runtime) }
                        return@setMethodCallHandler
                    }
                    "runtimeState" -> {
                        result.success(runtimeState())
                        return@setMethodCallHandler
                    }
                    "trustRoots" -> {
                        trustedRoots(result) { logic.current(runtime) }
                        return@setMethodCallHandler
                    }
                    "refreshStrings" -> {
                        AppStrings.refresh(context)
                        try {
                            PseudoVpnService.instance?.refreshNotification()
                            AppWorkService.instance?.refreshNotification()
                            SystemControls.refresh(context)
                            result.success(null)
                        } catch (_: Exception) {
                            result.error("notification", null, AppStrings.message(R.string.error_notification_update).toMap())
                        }
                        return@setMethodCallHandler
                    }
                    "sampleConnections" -> {
                        connections.read(call.argument<Number>("generation")?.toLong() ?: -1L,
                            call.argument<String>("configId").orEmpty(), call.argument<Int>("revision") ?: -1,
                            call.argument<Map<String, Any?>>("query") ?: emptyMap()) { value, error ->
                            if (error != null) result.error("connections", null, error.toMap()) else result.success(value)
                        }
                        return@setMethodCallHandler
                    }
                    "backupDiscard" -> {
                        discardBackup((call.arguments as? Map<*, *>)?.get("token") as? String)
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    "retain" -> {
                        logic.retain(runtime, call.argument<Boolean>("value") == true)
                        result.success(null)
                        return@setMethodCallHandler
                    }
                }
                val owner = call.argument<String>("owner")
                if (owner == null || owner != operationId) {
                    result.error("expired", null, AppStrings.message(R.string.error_operation_ended).toMap())
                    return@setMethodCallHandler
                }
                val scheduledRun = scheduled?.takeIf { it.owner == owner }
                if (scheduledRun != null && !scheduledRun.authorized()) {
                    cancelScheduledOperation(scheduledRun)
                    result.error("expired", null, AppMessage("operationFinished").toMap())
                    return@setMethodCallHandler
                }
                if (pendingRestore && restoreStopRequested && call.method !in setOf("stop", "snapshot")) {
                    result.error("expired", null, AppMessage("operationFinished").toMap())
                    return@setMethodCallHandler
                }
                val storage = BackupFiles.get(context).transaction.snapshot()
                if (call.method != "stop" && command?.get("action") != "stop" &&
                    (!storage.ready || storage.restoring ||
                        (command?.get("storageEpoch") as? Number)?.toLong() != storage.epoch)) {
                    result.error("expired", null, AppMessage("storageContextChanged").toMap())
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "checkOperation" -> {
                        if (operationRemainingMs(owner) > 0L) result.success(null)
                        else result.error("expired", null, AppMessage("operationFinished").toMap())
                    }
                    "operationRemaining" -> result.success(operationRemainingMs(owner))
                    "finishScheduledDownload" -> finishScheduledDownload(call, owner, result)
                    "backupPrepareExport", "backupCandidate", "backupInstall" -> backupWork(call, owner, result)
                    "publishStore" -> publishStore(call, owner, result)
                    "paths" -> storagePaths(result)
                    "snapshot" -> snapshot(owner, result)
                    "runningInput" -> runningInput(call, owner, result)
                    "updateResource" -> coreReads.handleResourceUpdate(call, result, authorized = { operationId == owner })
                    "syncSchedules" -> syncSchedules(call, result)
                    "stage" -> {
                        val message = AppMessage.fromMap(call.argument<Any>("message"))
                        if (message == null) result.error("stage", null, AppStrings.message(R.string.error_invalid_result).toMap())
                        else { operation = message; notifyUi(); result.success(null) }
                    }
                    "authorize" -> authorize(result)
                    "start" -> native.start(call.argument<String>("id")!!,
                        call.argument<Int>("revision")!!, call.argument<String>("mode"), owner, result)
                    "prepareStrategies" -> strategies.prepare(context, owner, call.argument<String>("id").orEmpty(),
                        call.argument<Int>("revision") ?: 0, call.argument<String>("mode"), strategyReply(result))
                    "releasePreview" -> strategies.release(owner, strategyReply(result))
                    "strategies" -> strategies.read(call.argument<Number>("generation")?.toLong() ?: -1L,
                        owner, strategyReply(result))
                    "setStrategy" -> strategies.change(call.argument<Number>("generation")?.toLong() ?: -1L,
                        owner, call.argument<String>("name").orEmpty(),
                        call.argument<Map<String, Any?>>("choice") ?: emptyMap<String, Any?>(), strategyReply(result))
                    "stop" -> {
                        if (pendingRestore) {
                            restoreNetworkStop(owner, result, internalReconnect = true)
                            return@setMethodCallHandler
                        }
                        if (command?.get("action") == "refreshRuntime" &&
                            activeRuntimeRefresh?.current() != true) {
                            result.error("expired", null, AppStrings.message(R.string.error_session_changed).toMap())
                            return@setMethodCallHandler
                        }
                        // This owner is already authorized. Its non-stop command
                        // releases only as part of an application apply/reconnect.
                        val internalReconnect = scheduled?.owner == owner ||
                            command?.get("action")?.let { it != "stop" } == true
                        if (!internalReconnect) cancelSystemRestore()
                        native.stop(result, internalReconnect)
                    }
                    "closeConnection" -> {
                        connections.disconnect(call.argument<Number>("generation")?.toLong() ?: -1L,
                            call.argument<String>("configId").orEmpty(), call.argument<Int>("revision") ?: -1,
                            call.argument<String>("connectionId").orEmpty(), owner) { value, error ->
                            if (error != null) result.error("closeConnection", null, error.toMap()) else result.success(value)
                        }
                        return@setMethodCallHandler
                    }
                    "setMode" -> {
                        val generation = call.argument<Number>("generation")?.toLong() ?: -1L
                        modes.change(generation, owner, call.argument<String>("mode").orEmpty()) { mode, error ->
                            if (error != null) result.error("mode", null, error.toMap())
                            else result.success(mode)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun syncSchedules(call: MethodCall, result: MethodChannel.Result) {
        @Suppress("UNCHECKED_CAST")
        val targets = (call.argument<List<Map<*, *>>>("targets") ?: emptyList())
        PseudoVpnService.worker.execute {
            try {
                ScheduleManager.sync(context, targets) {
                    main.post { result.success(null) }
                }
            } catch (_: Exception) {
                main.post { result.error("schedule", null, AppStrings.message(R.string.error_schedule_save).toMap()) }
            }
        }
    }

    private fun runningInput(call: MethodCall, owner: String, result: MethodChannel.Result) {
        val generation = call.argument<Number>("generation")?.toLong() ?: -1L
        val composition = call.argument<String>("composition").orEmpty()
        val core = PseudoVpnService.core
        core.worker.execute {
            val value = if (owner == operationId) core.runningInput(generation, composition) else null
            main.post {
                if (owner != operationId || value == null || !core.current(generation) ||
                    core.snapshot().composition != composition) {
                    result.error("expired", null, AppStrings.message(R.string.error_operation_ended).toMap())
                } else result.success(value)
            }
        }
    }

    fun runSchedule(kind: String, id: String, cancelled: () -> Boolean = { false }): Map<*, *> =
        runScheduled(mapOf("action" to "refreshSchedule", "kind" to kind, "id" to id), cancelled)

    /** Reconcile from saved Dart settings. */
    fun reconcileSchedules(cancelled: () -> Boolean = { false }): Map<*, *> =
        runScheduled(mapOf("action" to "syncSchedules"), cancelled)

    private fun runScheduled(request: Map<String, Any?>,
                             cancelled: () -> Boolean = { false }): Map<*, *> {
        val run = ScheduledRun(cancelled)
        main.post {
            if (run.cancelled.get() || cancelled()) {
                run.cancel()
                return@post
            }
            val storage = BackupFiles.get(context).transaction.snapshot()
            if (!storage.ready || storage.restoring ||
                operationId != null || logic.busy || resourceBusy || storagePublishing || backupCapturing || pendingSystemRestore ||
                PseudoVpnService.session.snapshot().phase in setOf(
                    NativeSession.Phase.STARTING, NativeSession.Phase.STOPPING)) {
                run.finish(mapOf("success" to false, "scheduleStatus" to "busy"))
                return@post
            }
            scheduled = run
            operationId = run.owner
            run.admit(operationAdmittedAt!!)
            command = request + ("storageEpoch" to storage.epoch)
            PseudoVpnService.core.setOperationBusy(true)
            notifyUi()
            val settle: (Map<*, *>) -> Unit = { value ->
                main.post {
                    if (operationId == run.owner || (scheduled === run && operationId == null)) {
                        operationId = null
                        command = null
                        operation = null
                    }
                    if (scheduled === run) scheduled = null
                    run.applicationTimeout?.let { main.removeCallbacks(it) }
                    run.applicationTimeout = null
                    PseudoVpnService.core.setOperationBusy(operationId != null || logic.busy || resourceBusy || storagePublishing || backupCapturing)
                    notifyUi()
                    run.finish(value)
                }
            }
            try {
                logic.execute(run.owner, command!!, settle)
            } catch (_: Exception) {
                settle(mapOf("success" to false))
            }
        }
        try {
            while (!run.done.await(100, TimeUnit.MILLISECONDS)) {
                if (cancelled() || SystemClock.elapsedRealtime() >= run.deadline) break
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        if (run.cancelWorker()) {
            main.post { if (scheduled === run && run.cancelled.get()) cancelScheduledOperation() }
        }
        return run.outcome
    }

    /** The network Worker ends before reconnect can change its own constraints.
     * The same Dart executor still owns local application and its real drain. */
    private fun finishScheduledDownload(call: MethodCall, owner: String, result: MethodChannel.Result) {
        val run = scheduled
        val session = PseudoVpnService.session.snapshot()
        val core = PseudoVpnService.core.snapshot()
        if (run == null || run.owner != owner || command?.get("action") != "refreshSchedule" ||
            command?.get("kind") != call.argument<String>("kind") ||
            command?.get("id") != call.argument<String>("id") ||
            session.phase != NativeSession.Phase.RUNNING ||
            session.generation != call.argument<Number>("sessionGeneration")?.toLong() ||
            session.configId != call.argument<String>("configId") ||
            session.revision != call.argument<Int>("revision") ||
            core.generation != call.argument<Number>("generation")?.toLong() ||
            core.composition != call.argument<String>("composition") ||
            core.configId != session.configId || core.revision != session.revision ||
            core.purpose != CoreHost.Purpose.VPN || !PseudoVpnService.core.current(core.generation) ||
            !run.handoff()) {
            result.error("expired", null, AppMessage("operationFinished").toMap())
            return
        }
        val timeout = Runnable {
            if (scheduled === run && operationId == owner) cancelScheduledOperation()
        }
        run.applicationTimeout = timeout
        main.postDelayed(timeout, run.applicationRemainingMs())
        result.success(null)
    }

    /** VpnService revocation may arrive on a binder thread. Revoke only its
     * current scheduled publication authority now; clean up that run on main. */
    fun revokeScheduledOperation(service: PseudoVpnService): Long? {
        val revoked = synchronized(publicationGate) {
            if (PseudoVpnService.instance !== service) return@synchronized null
            val current = scheduled?.takeIf { operationId == it.owner }
            if (current != null) {
                current.cancel()
                operationId = null
            }
            current to PseudoVpnService.session.snapshot().generation
        } ?: return null
        val run = revoked.first
        if (run != null) {
            if (Looper.myLooper() == Looper.getMainLooper()) cancelScheduledOperation(run)
            else main.post { cancelScheduledOperation(run) }
        }
        return revoked.second
    }

    /** Main-thread final stop/revoke/timeout. Invalidates authority immediately;
     * LogicEngineHost keeps its writer gate closed until execute really drains.
     */
    fun cancelScheduledOperation(): Boolean = scheduled?.let { cancelScheduledOperation(it) } ?: false

    private fun cancelScheduledOperation(run: ScheduledRun): Boolean {
        val current = scheduled === run
        if (current) scheduled = null
        run.cancel()
        run.applicationTimeout?.let { main.removeCallbacks(it) }
        run.applicationTimeout = null
        val ownsCommand = current && (operationId == run.owner || operationId == null)
        val starting = if (ownsCommand) PseudoVpnService.session.snapshot()
            .takeIf { it.phase == NativeSession.Phase.STARTING } else null
        val service = PseudoVpnService.instance
        if (ownsCommand) {
            operationId = null
            command = null
            operation = null
        }
        logic.cancel(run.owner)
        modes.abandon(run.owner)
        strategies.abandon(run.owner)
        connections.abandon(run.owner)
        if (ownsCommand) native.abandon()
        if (starting != null) service?.requestStop(starting.generation)
        PseudoVpnService.core.setOperationBusy(operationId != null || logic.busy || resourceBusy || storagePublishing || backupCapturing)
        notifyUi()
        return current
    }

    private fun submit(call: MethodCall, result: MethodChannel.Result) {
        @Suppress("UNCHECKED_CAST")
        val request = call.arguments as? Map<String, Any?>
        val storage = BackupFiles.get(context).transaction.snapshot()
        if (request?.get("action") != "stop" && (!storage.ready || storage.restoring)) {
            result.error("storage", null, AppMessage("storageUnavailable").toMap())
            return
        }
        val requestedEpoch = request?.get("storageEpoch")
        if (request?.get("action") != "stop" &&
            ((requestedEpoch !is Int && requestedEpoch !is Long) ||
                (requestedEpoch as Number).toLong() != storage.epoch)) {
            result.error("expired", null, AppMessage("storageContextChanged").toMap())
            return
        }
        if (request?.get("action") == "stop" && pendingRestore) {
            val restoreOwner = operationId
            if (restoreOwner != null) {
                val alwaysOn = PseudoVpnService.alwaysOnState() == true
                requestRestoreStop(restoreOwner, stopNetwork = !alwaysOn)
                if (alwaysOn) result.error("alwaysOn", null, AppMessage("alwaysOnNotice").toMap())
                else result.success(admission(restoreOwner))
                return
            }
        }
        if (request?.get("action") == "stop" && PseudoVpnService.alwaysOnState() == true) {
            result.error("alwaysOn", null, AppMessage("alwaysOnNotice").toMap())
            return
        }
        if (request?.get("action") == "stop" &&
            (command?.get("action") == "stop" ||
                (scheduled == null && PseudoVpnService.core.snapshot().phase == io.github.monadboxlab.clashpseudo.nativecore.CoreHost.Phase.RELEASING))) {
            result.error("busy", null, AppStrings.message(R.string.error_busy).toMap())
            return
        }
        if (request?.get("action") == "stop") {
            pendingRuntimeRefresh = null
            main.removeCallbacks(drainRuntimeRefresh)
        }
        if (request?.get("action") == "stop" && (scheduled != null || resourceBusy || pendingSystemRestore || backupCapturing ||
            command?.get("action") in setOf("start", "refreshRuntime", "prepareBackup", "inspectBackup") ||
            PseudoVpnService.instance?.pendingSystemStart == true ||
            PseudoVpnService.session.snapshot().phase == NativeSession.Phase.STARTING)) {
            PseudoVpnService.instance?.cancelSystemStart(terminal = true)
            cancelSystemRestore()
            cancelScheduledOperation()
            operationId?.let { previous ->
                if (command?.get("action") == "prepareBackup") backupUses[previous]?.let { token ->
                    retiredBackups.add(token)
                    preparedBackups.entries.removeAll { it.value == token }
                }
                operationId = null
                command = null
                operation = null
                authorizationResult(false)
                logic.cancel(previous)
                modes.abandon(previous)
                strategies.abandon(previous)
                connections.abandon(previous)
                native.abandon()
                activeRuntimeRefresh = null
                runtimeRefreshTimeout?.let { main.removeCallbacks(it) }
                runtimeRefreshTimeout = null
            }
            // Stop can preempt a download; other commands remain serialized by
            // logic.busy.
            val owner = UUID.randomUUID().toString()
            operationId = owner
            command = request
            resultId = null
            resultMessage = null
            PseudoVpnService.core.setOperationBusy(true)
            result.success(admission(owner))
            notifyUi()
            native.stop(object : MethodChannel.Result {
                override fun success(value: Any?) = finish(owner, mapOf(
                    "success" to true,
                    "message" to mapOf("id" to "tunnelStopped", "args" to emptyMap<String, Any?>()),
                ))
                override fun error(code: String, message: String?, details: Any?) =
                    finish(owner, mapOf("success" to false, "message" to details))
                override fun notImplemented() = error("stop", null, null)
            })
            return
        }
        if (operationId != null || logic.busy || resourceBusy || storagePublishing || backupCapturing || pendingSystemRestore) {
            result.error("busy", null, AppStrings.message(R.string.error_busy).toMap())
            return
        }
        if (request?.get("action") !in setOf("import", "updateConfig", "renameConfig", "saveLocal", "start", "stop", "select", "delete", "setMode", "prepareStrategies", "setStrategy", "closeConnection", "setPreference", "saveOverride", "importOverride", "updateOverride", "changeOverrideSource", "changeOverride", "reorderOverrides", "deleteOverride", "setApplicationAccess", "setConfigUpdate", "setOverrideUpdate", "syncSchedules", "updateResource", "saveLocalDefinition", "deleteLocalDefinition", "prepareBackup", "inspectBackup", "restoreBackup")) {
            result.error("command", null, AppStrings.message(R.string.error_unknown_command).toMap())
            return
        }
        if (request?.get("action") in setOf("prepareBackup", "inspectBackup", "restoreBackup")) {
            val requestId = request?.get("requestId") as? String
            val token = request?.get("token") as? String
            val created = backupInteger(request?.get("createdAtMillis"))
            if (requestId.isNullOrBlank() || requestId.length > 128 ||
                (request?.get("action") == "prepareBackup" && (created == null || created > 8_640_000_000_000_000L)) ||
                (request?.get("action") != "prepareBackup" && (token == null || !BackupFiles.isToken(token) || token in retiredBackups))) {
                result.error("backup", null, AppMessage("backupInvalid").toMap())
                return
            }
        }
        val owner = UUID.randomUUID().toString()
        operationId = owner
        PseudoVpnService.core.setOperationBusy(true)
        command = request
        operation = AppStrings.message(R.string.operation_accepting)
        resultMessage = null
        resultId = null
        connectionStatus = null
        configStatus = null
        overrideStatus = null
        resourceStatus = null
        scheduleStatus = null
        targetId = null
        savedRevision = null
        try {
            val intent = Intent(context, AppWorkService::class.java).putExtra(AppWorkService.EXTRA_OWNER, owner)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
            else context.startService(intent)
            result.success(admission(owner))
            notifyUi()
        } catch (_: Exception) {
            finish(owner, notExecutedResult(request, AppStrings.message(R.string.error_service_start)))
            result.error("service", null, AppStrings.message(R.string.error_service_not_allowed).toMap())
        }
    }

    fun restoreActivityState(state: Bundle?) {
        val previous = state?.getInt("pseudo.vpn.authorizationCode", 100) ?: 100
        if (previous in 100..0x3fff) authorizationCode = maxOf(authorizationCode, previous)
    }

    fun saveActivityState(state: Bundle) {
        state.putInt("pseudo.vpn.authorizationCode", authorizationCode)
    }

    private fun authorize(result: MethodChannel.Result) {
        if (VpnService.prepare(context) == null) { result.success(true); return }
        val owner = activity.get()
        if (owner == null || !uiVisible || owner.isFinishing || authorization != null) {
            result.error("permission", null, AppStrings.message(R.string.error_vpn_permission_return).toMap())
            return
        }
        if (authorizationCode >= 0x3fff) {
            result.error("permission", null, AppStrings.message(R.string.error_vpn_permission_requests).toMap())
            return
        }
        authorization = result
        // Reserve separate monotonic code ranges for file_selector 221–223 and backup
        // 0x4000–0x7fff.
        authorizationCode++
        if (authorizationCode in 221..223) authorizationCode = 224
        owner.requestVpnPermission(authorizationCode)
    }

    fun authorizationResult(requestCode: Int, granted: Boolean) {
        if (requestCode == authorizationCode) authorizationResult(granted)
    }

    private fun authorizationResult(granted: Boolean) {
        val result = authorization ?: return
        authorization = null
        result.success(granted && VpnService.prepare(context) == null)
    }

    /** Handles explicit Stop and revocation. */
    fun cancelRuntimeRefresh(): Boolean {
        val hadPending = pendingRuntimeRefresh != null
        pendingRuntimeRefresh = null
        main.removeCallbacks(drainRuntimeRefresh)
        if (command?.get("action") != "refreshRuntime") return hadPending
        val owner = operationId ?: return hadPending
        operationId = null
        command = null
        operation = null
        activeRuntimeRefresh = null
        runtimeRefreshTimeout?.let { main.removeCallbacks(it) }
        runtimeRefreshTimeout = null
        authorizationResult(false)
        logic.cancel(owner)
        modes.abandon(owner)
        strategies.abandon(owner)
        connections.abandon(owner)
        native.abandon()
        if (!logic.busy) clearInput(owner)
        PseudoVpnService.core.setOperationBusy(logic.busy || resourceBusy || storagePublishing || backupCapturing)
        notifyUi()
        return true
    }

    /** Coalesce network/route changes using the captured running input. */
    fun requestRuntimeRefresh(sessionGeneration: Long, coreGeneration: Long,
                              composition: String, revision: Long, reason: String) {
        if (reason !in setOf("routes", "systemDns")) return
        main.post {
            if (!PseudoVpnService.core.runtimeRefreshCurrent(
                    sessionGeneration, coreGeneration, composition, revision, reason)) return@post
            val previous = pendingRuntimeRefresh
            val request = if (previous != null && previous.sessionGeneration == sessionGeneration &&
                previous.coreGeneration == coreGeneration && previous.composition == composition) previous
                else RuntimeRefresh(sessionGeneration, coreGeneration, composition)
            request.revisions[reason] = revision
            pendingRuntimeRefresh = request
            main.removeCallbacks(drainRuntimeRefresh)
            main.post(drainRuntimeRefresh)
        }
    }

    private fun drainRuntimeRefresh() {
        val request = pendingRuntimeRefresh ?: return
        if (!request.current()) {
            pendingRuntimeRefresh = null
            return
        }
        if (operationId != null || logic.busy || resourceBusy || storagePublishing || backupCapturing || pendingSystemRestore) return
        pendingRuntimeRefresh = null
        activeRuntimeRefresh = request
        val owner = UUID.randomUUID().toString()
        val refresh = mapOf(
            "action" to "refreshRuntime", "sessionGeneration" to request.sessionGeneration,
            "coreGeneration" to request.coreGeneration, "composition" to request.composition,
            "storageEpoch" to BackupFiles.get(context).transaction.snapshot().epoch,
        )
        operationId = owner
        command = refresh
        operation = AppStrings.message(R.string.operation_accepting)
        resultId = null
        resultMessage = null
        connectionStatus = null
        configStatus = null
        overrideStatus = null
        resourceStatus = null
        scheduleStatus = null
        targetId = null
        savedRevision = null
        PseudoVpnService.core.setOperationBusy(true)
        val timeout = Runnable {
            if (operationId == owner) {
                logic.cancel(owner)
                finish(owner, mapOf("success" to false,
                    "message" to AppStrings.message(R.string.error_operation_incomplete).toMap()))
            }
        }
        runtimeRefreshTimeout = timeout
        main.postDelayed(timeout, operationRemainingMs(owner))
        notifyUi()
        // Reuse the VPN Service's foreground lifetime and LogicEngineHost's actual
        // drain.
        logic.execute(owner, refresh) { outcome -> finish(owner, outcome) }
    }

    fun nativeChanged() {
        native.changed()
        if (operationId == null) {
            // A system revocation or service exit supersedes earlier UI results.
            resultMessage = null
            resultId = null
            connectionStatus = null
            configStatus = null
            overrideStatus = null
            resourceStatus = null
            scheduleStatus = null
            targetId = null
            savedRevision = null
        }
        notifyUi()
    }

    internal fun notExecutedResult(command: Map<*, *>?, message: AppMessage): Map<String, Any?> {
        val action = command?.get("action")
        return mapOf(
            "success" to false,
            "message" to message.toMap(),
            "configStatus" to if (action in setOf("saveLocal", "import", "updateConfig")) "notSaved" else null,
            "overrideStatus" to if (action in setOf("saveOverride", "importOverride", "updateOverride",
                "changeOverrideSource", "saveLocalDefinition", "deleteLocalDefinition")) "notSaved" else null,
            "backupResult" to when (action) {
                "restoreBackup" -> mapOf("status" to "notRestored", "committed" to false, "rolledBack" to false)
                "prepareBackup", "inspectBackup" -> mapOf("status" to "failed")
                else -> null
            },
        )
    }

    fun finish(id: String, outcome: Map<*, *>) {
        if (operationId != id) return
        val action = command?.get("action")
        val backupAction = action in setOf("prepareBackup", "inspectBackup", "restoreBackup")
        val nativeInstall = installedBackup?.takeIf { it.first == id }?.second
        var detail = backupProjection(outcome["backupResult"])
        if (action == "restoreBackup" && nativeInstall != null) {
            detail = backupProjection((detail ?: emptyMap()) + nativeInstall +
                ("status" to restoreStatus(nativeInstall["committed"])))
        }
        val token = backupUses[id]
        val cancelledPreparation = action == "prepareBackup" && token != null && token in retiredBackups
        val retirePreparation = action == "prepareBackup" && token != null &&
            (cancelledPreparation || outcome["success"] != true || detail?.get("status") != "prepared" ||
                detail?.get("token") != token || detail?.get("summary") !is Map<*, *>)
        if (retirePreparation) {
            retiredBackups.add(token!!)
            preparedBackups.entries.removeAll { it.value == token }
            detail = mapOf("status" to if (cancelledPreparation) "cancelled" else "failed")
        }
        backupResult = if (backupAction && detail != null) backupProjection(detail + ("requestId" to command?.get("requestId"))) else null
        activeRuntimeRefresh = null
        runtimeRefreshTimeout?.let { main.removeCallbacks(it) }
        runtimeRefreshTimeout = null
        authorizationResult(false)
        if (action != "restoreBackup" || restoreStopOwner != id) native.abandon()
        modes.abandon(id)
        strategies.abandon(id)
        connections.abandon(id)
        if (!logic.busy) clearInput(id)
        resultId = id
        connectionStatus = (outcome["connectionStatus"] as? String)?.takeIf {
            it in setOf("closed", "absent", "failed", "unconfirmed")
        }
        configStatus = (outcome["configStatus"] as? String)?.takeIf {
            it in setOf("notSaved", "saved", "applied", "applyFailed", "unconfirmed")
        } ?: if (command?.get("action") == "saveLocal") "unconfirmed" else null
        overrideStatus = (outcome["overrideStatus"] as? String)?.takeIf {
            it in setOf("notSaved", "saved", "applied", "applyFailed", "unconfirmed")
        } ?: if (command?.get("action") == "saveOverride") "unconfirmed" else null
        resourceStatus = if (command?.get("action") == "updateResource") outcome["resourceStatus"] as? String else null
        scheduleStatus = (outcome["scheduleStatus"] as? String)?.takeIf {
            it in setOf("synced", "failed")
        }
        targetId = outcome["targetId"] as? String ?: command?.get("id") as? String
        savedRevision = (outcome["savedRevision"] as? Number)?.toInt()?.takeIf { it > 0 }
        resultSuccess = !retirePreparation && if (action == "restoreBackup" && nativeInstall != null)
            nativeInstall["committed"] == true else outcome["success"] == true
        resultMessage = AppMessage.fromMap(outcome["message"])
            ?: if (outcome["message"] == null && resultSuccess) null
            else AppStrings.message(R.string.error_result_unconfirmed)
        if (cancelledPreparation) resultMessage = AppMessage("operationFinished")
        else if (retirePreparation && outcome["success"] == true) resultMessage = AppMessage("backupInvalid")
        if (action == "restoreBackup" && backupResult?.get("committed") != true && restoreInterruption != null) {
            resultMessage = restoreInterruption
        }
        operationId = null
        command = null
        operation = null
        PseudoVpnService.core.setOperationBusy(logic.busy || resourceBusy || storagePublishing || backupCapturing)
        notifyUi()
    }

    fun executorDrained(id: String) {
        val token = backupUses.remove(id)
        if (token != null && token in retiredBackups && token !in backupUses.values) {
            retiredBackups.remove(token)
            preparedBackups.entries.removeAll { it.value == token }
            backups.discardCandidate(token)
        }
        clearInput(id)
        if (discardedSystemInput == id) {
            discardedSystemInput = null
            try { AppFiles.systemInput(context).delete() } catch (_: Exception) { }
        }
        PseudoVpnService.core.setOperationBusy(operationId != null || logic.busy || resourceBusy || storagePublishing || backupCapturing)
        notifyUi()
    }

    private fun clearInput(id: String) {
        try { AppFiles.runInput(context, id).delete() } catch (_: Exception) { }
    }

    fun runtimeState(): Map<String, Any?> = snapshotMap(PseudoVpnService.session.snapshot()) + mapOf(
        "elapsedMs" to SystemClock.elapsedRealtime(), "wallTimeMs" to System.currentTimeMillis(),
    )

    fun notifyUi() {
        logic.reconcile()
        ui?.invokeMethod("changed", null)
        SystemControls.refresh(context)
        if (pendingRuntimeRefresh != null) {
            main.removeCallbacks(drainRuntimeRefresh)
            main.post(drainRuntimeRefresh)
        }
    }

    private fun strategyReply(result: MethodChannel.Result): (String?, AppMessage?) -> Unit =
        { value, error ->
            if (error != null) result.error("strategy", null, error.toMap())
            else result.success(value)
        }

    fun requestOverview() {
        overviewRequested = true
        deliverOverview()
    }

    private fun deliverOverview() {
        val channel = ui ?: return
        if (!uiReady || !overviewRequested || overviewSending) return
        overviewSending = true
        channel.invokeMethod("openOverview", null, object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (ui !== channel) return
                overviewSending = false
                if (result == true) overviewRequested = false
            }
            override fun error(code: String, message: String?, details: Any?) {
                if (ui === channel) overviewSending = false
            }
            override fun notImplemented() = error("navigation", null, null)
        })
    }

    /** Make the click decision synchronously on the main thread. */
    fun systemControlAction(): String? {
        if (pendingRestore) return "stop"
        val phase = PseudoVpnService.session.snapshot().phase
        if (phase == NativeSession.Phase.STARTING || phase == NativeSession.Phase.RUNNING ||
            command?.get("action") in setOf("start", "refreshRuntime") || pendingSystemRestore ||
            PseudoVpnService.instance?.pendingSystemStart == true) return "stop"
        if (phase == NativeSession.Phase.STOPPED && operationId == null && !logic.busy &&
            !resourceBusy && !storagePublishing && !backupCapturing) return "start"
        return null
    }

    fun submitSystemControl(action: String, reply: (SystemControls.Admission) -> Unit) {
        if (action !in setOf("start", "stop")) {
            reply(SystemControls.Admission.OPEN_APP)
            return
        }
        if (pendingRestore) {
            val owner = operationId
            if (action == "stop" && owner != null) {
                val alwaysOn = PseudoVpnService.alwaysOnState() == true
                requestRestoreStop(owner, stopNetwork = !alwaysOn)
                reply(if (alwaysOn) SystemControls.Admission.VPN_SETTINGS else SystemControls.Admission.ACCEPTED)
            } else reply(SystemControls.Admission.OPEN_APP)
            return
        }
        val state = PseudoVpnService.session.snapshot()
        val preparing = command?.get("action") in setOf("start", "refreshRuntime") ||
            pendingSystemRestore || PseudoVpnService.instance?.pendingSystemStart == true
        if (action == "stop" && PseudoVpnService.alwaysOnState() == true) {
            reply(SystemControls.Admission.VPN_SETTINGS)
            return
        }
        if ((action == "start" && state.phase == NativeSession.Phase.RUNNING && !preparing) ||
            (action == "stop" && state.phase == NativeSession.Phase.STOPPED && !preparing &&
                operationId == null && !logic.busy && !resourceBusy)) {
            reply(SystemControls.Admission.UNCHANGED)
            return
        }
        if (action == "start" && VpnService.prepare(context) != null &&
            (activity.get() == null || !uiVisible)) {
            reply(SystemControls.Admission.OPEN_APP)
            return
        }
        val storage = BackupFiles.get(context).transaction.snapshot()
        if (action == "start" && (!storage.ready || storage.restoring)) {
            reply(SystemControls.Admission.OPEN_APP)
            return
        }
        submit(MethodCall("submit", mapOf("action" to action, "storageEpoch" to storage.epoch)), object : MethodChannel.Result {
            override fun success(result: Any?) = reply(SystemControls.Admission.ACCEPTED)
            override fun error(code: String, message: String?, details: Any?) {
                if (operationId == null) {
                    resultSuccess = false
                    resultMessage = AppMessage.fromMap(details)
                        ?: AppStrings.message(R.string.error_result_unconfirmed)
                    resultId = UUID.randomUUID().toString()
                    notifyUi()
                }
                reply(if (code == "alwaysOn") SystemControls.Admission.VPN_SETTINGS
                    else SystemControls.Admission.OPEN_APP)
            }
            override fun notImplemented() = error("command", null, null)
        })
    }

    fun systemControlSnapshot(reply: (Map<String, Any?>) -> Unit) {
        val files = BackupFiles.get(context)
        val transaction = files.transaction
        val storage = transaction.snapshot()
        files.ioExecutor.execute {
            val savedMode = runCatching {
                transaction.withStableStorage(storage.epoch) {
                    val file = File(files.stores, "configurations.json")
                    if (files.lstat(file) == null) null else files.readFile(file) { pinned ->
                        val decoder = Charsets.UTF_8.newDecoder()
                            .onMalformedInput(CodingErrorAction.REPORT)
                            .onUnmappableCharacter(CodingErrorAction.REPORT)
                        pinned.inputStream().use { input ->
                            savedMode(InputStreamReader(input, decoder), ModeCalls.VALUES)
                        }
                    }
                }
            }
            main.post {
                snapshot(null, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        val value = result as? Map<*, *> ?: emptyMap<Any, Any>()
                        val current = transaction.snapshot()
                        val stable = current.ready && !current.restoring && current.epoch == storage.epoch
                        reply(mapOf(
                            "phase" to value["phase"], "mode" to value["mode"],
                            "savedMode" to savedMode.getOrNull().takeIf { stable },
                            "savedModeKnown" to (stable && savedMode.isSuccess),
                            "busy" to (value["writerBusy"] == true || value["resourceBusy"] == true || !stable),
                            "pendingStart" to value["pendingStart"],
                            "pendingRestore" to pendingRestore,
                            "pendingSystemStart" to value["pendingSystemStart"],
                            "failed" to (value["error"] != null ||
                                (value["resultMessage"] != null && value["resultSuccess"] == false)),
                        ))
                    }
                    override fun error(code: String, message: String?, details: Any?) =
                        reply(mapOf("phase" to "UNKNOWN", "mode" to null, "savedMode" to null,
                            "pendingRestore" to pendingRestore,
                            "busy" to true, "failed" to true))
                    override fun notImplemented() = error("snapshot", null, null)
                })
            }
        }
    }

    private fun vpnStatus(): Map<String, Any?> {
        val service = PseudoVpnService.instance
        val alwaysOn = PseudoVpnService.alwaysOnState()
        val lockdown = try {
            if (Build.VERSION.SDK_INT >= 29 && service != null) service.isLockdownEnabled else null
        } catch (_: Exception) { null }
        return mapOf(
            "alwaysOn" to alwaysOn,
            "lockdown" to lockdown,
            "supported" to (Build.VERSION.SDK_INT >= 24),
        )
    }

    /** Open the public system VPN settings action. */
    fun openVpnSettings(result: MethodChannel.Result) {
        val owner = activity.get()
        if (owner == null) {
            result.error("activity", null, AppStrings.message(R.string.error_activity_return).toMap())
            return
        }
        try {
            owner.startActivity(Intent(android.provider.Settings.ACTION_VPN_SETTINGS))
            result.success(null)
        } catch (_: Exception) {
            result.error("settings", null, AppStrings.message(R.string.error_open_vpn_settings).toMap())
        }
    }

    /**
     * Prepares a run input for a system-initiated start (Android Always-on).
     * The Dart business engine remains the only writable owner; the VPN service
     * starts afterwards with the prepared input identity.
     */
    fun cancelSystemRestore(): Boolean {
        val owner = systemRestoreOwner ?: return false
        systemRestoreOwner = null
        // Only an admitted restore owns input and requires drain-time cleanup.
        if (operationId == owner) {
            discardedSystemInput = owner
            operationId = null
            command = null
            operation = null
            logic.cancel(owner)
            if (!logic.busy) executorDrained(owner)
        }
        PseudoVpnService.core.setOperationBusy(operationId != null || logic.busy || resourceBusy || storagePublishing || backupCapturing)
        notifyUi()
        return true
    }

    fun restoreSystemStart(reply: (Map<String, Any?>?) -> Unit) {
        if (pendingSystemRestore) {
            reply(null)
            return
        }
        val owner = UUID.randomUUID().toString()
        val before = PseudoVpnService.session.snapshot()
        val deadline = SystemClock.elapsedRealtime() + 30_000L
        systemRestoreOwner = owner
        notifyUi()
        fun attempt() {
            if (systemRestoreOwner != owner) {
                reply(null)
                return
            }
            val state = PseudoVpnService.session.snapshot()
            if (SystemClock.elapsedRealtime() >= deadline ||
                state.generation != before.generation || state.phase != NativeSession.Phase.STOPPED) {
                systemRestoreOwner = null
                notifyUi()
                reply(null)
                return
            }
            val storage = BackupFiles.get(context).transaction.snapshot()
            if (!storage.ready || storage.restoring || operationId != null || logic.busy || resourceBusy || storagePublishing || backupCapturing) {
                // Keep one bounded intent waiting for the real writer; Stop
                // invalidates its owner immediately and admission reserves its turn.
                main.postDelayed({ attempt() }, 100L)
                return
            }
            operationId = owner
            command = mapOf("action" to "systemStart", "storageEpoch" to storage.epoch)
            resultId = null
            resultMessage = null
            resultSuccess = false
            connectionStatus = null
            configStatus = null
            overrideStatus = null
            resourceStatus = null
            scheduleStatus = null
            targetId = null
            savedRevision = null
            operation = AppStrings.message(R.string.operation_preparing_system_start)
            PseudoVpnService.core.setOperationBusy(true)
            notifyUi()
            try {
                logic.execute(owner, command!!) { outcome ->
                    main.post { completeSystemRestore(owner, outcome, reply) }
                }
            } catch (_: Exception) {
                if (systemRestoreOwner == owner) systemRestoreOwner = null
                if (operationId == owner) {
                    resultId = owner
                    resultSuccess = false
                    resultMessage = AppStrings.message(R.string.error_system_start_prepare)
                    operationId = null
                    command = null
                    operation = null
                }
                PseudoVpnService.core.setOperationBusy(operationId != null || logic.busy || resourceBusy || storagePublishing || backupCapturing)
                notifyUi()
                reply(null)
            }
        }
        attempt()
    }

    private fun completeSystemRestore(owner: String, outcome: Map<*, *>, reply: (Map<String, Any?>?) -> Unit) {
        if (operationId != owner || systemRestoreOwner != owner) {
            reply(null)
            return
        }
        systemRestoreOwner = null
        val start = outcome["systemStart"] as? Map<*, *>
        operationId = null
        command = null
        operation = null
        resultSuccess = false
        PseudoVpnService.core.setOperationBusy(logic.busy || resourceBusy || storagePublishing || backupCapturing)
        if (outcome["success"] == true && start != null) {
            resultId = null
            resultMessage = null
            reply(mapOf("start" to start))
        } else {
            resultId = owner
            resultMessage = AppMessage.fromMap(outcome["message"])
                ?: AppStrings.message(R.string.error_system_start_prepare)
            notifyUi()
            reply(null)
        }
    }

    private fun publishStore(call: MethodCall, owner: String, result: MethodChannel.Result) {
        val kind = BackupFiles.Kind.entries.firstOrNull { it.fileName == call.argument<String>("file") }
        val rawEpoch = call.argument<Any>("epoch")
        val epoch = if (rawEpoch is Int || rawEpoch is Long) (rawEpoch as Number).toLong() else null
        if (kind == null || epoch == null || epoch < 0 || storagePublishing || backupCapturing) {
            result.error("storage", null, AppMessage("storageUnavailable").toMap())
            return
        }
        val scheduledRun = scheduled?.takeIf { it.owner == owner }
        storagePublishing = true
        PseudoVpnService.core.setOperationBusy(true)
        BackupFiles.get(context).ioExecutor.execute {
            val outcome = runCatching {
                BackupFiles.get(context).transaction.publishStore(kind, epoch, object : RestoreTransaction.Owner {
                    override fun checkCurrent() {
                        check(operationId == owner && operationRemainingMs(owner) > 0L && scheduledRun?.authorized() != false)
                    }
                    override fun runIfCurrent(block: () -> Unit) {
                        synchronized(publicationGate) {
                            checkCurrent()
                            if (scheduledRun == null) block() else scheduledRun.publishIfAuthorized(block)
                        }
                    }
                })
            }
            main.post {
                storagePublishing = false
                outcome.fold(
                    onSuccess = { value ->
                        // A successful rename is a saved result, even when later
                        // cancellation or directory sync prevents confirmation.
                        result.success(mapOf("saved" to value.saved, "durable" to value.durable,
                            "epoch" to value.epoch))
                    },
                    onFailure = {
                        result.error(if (operationId == owner) "storage" else "expired", null,
                            AppMessage(if (operationId == owner) "storageUnavailable" else "operationFinished").toMap())
                    },
                )
                PseudoVpnService.core.setOperationBusy(operationId != null || logic.busy || resourceBusy || storagePublishing || backupCapturing)
                notifyUi()
            }
        }
    }

    private fun storagePaths(result: MethodChannel.Result) {
        val state = BackupFiles.get(context).transaction.snapshot()
        if (!state.ready || state.restoring) {
            result.error("storage", null, AppMessage("storageUnavailable").toMap())
            return
        }
        result.success(paths() + ("storageEpoch" to state.epoch))
    }

    private fun paths() = mapOf(
        "configs" to AppFiles.configs(context).absolutePath,
        "runInput" to AppFiles.runInput(context, operationId ?: "unowned").absolutePath,
        "systemInput" to AppFiles.systemInput(context).absolutePath,
    )

    private fun snapshot(owner: String?, result: MethodChannel.Result) {
        val before = PseudoVpnService.session.snapshot()
        if (before.phase != NativeSession.Phase.RUNNING) {
            result.success(snapshotMap(before))
            return
        }
        val loaded = PseudoVpnService.core.snapshot()
        modes.read(before.generation, owner) { mode, error ->
            val current = PseudoVpnService.session.snapshot()
            val core = PseudoVpnService.core
            val matches = current.generation == before.generation && current.phase == before.phase &&
                core.current(loaded.generation) && core.snapshot().composition == loaded.composition &&
                (owner == null || operationId == owner)
            result.success(snapshotMap(current) + mapOf(
                "mode" to mode.takeIf { matches },
                "modeError" to (if (matches) error else AppStrings.message(R.string.error_session_changed))?.toMap(),
            ))
        }
    }

    private fun snapshotMap(state: NativeSession.Snapshot): Map<String, Any?> {
        val storage = BackupFiles.get(context).transaction.snapshot()
        return mapOf(
            "storageReady" to storage.ready, "storageRestoring" to storage.restoring,
            "storageEpoch" to storage.epoch,
            "phase" to state.phase.name, "generation" to state.generation,
            "alwaysOn" to PseudoVpnService.alwaysOnState(),
            "runningSinceElapsedMs" to state.runningSinceElapsedMs,
            "elapsedRealtimeMs" to state.elapsedRealtimeMs,
            "configId" to state.configId, "revision" to state.revision, "error" to state.error?.toMap(),
            "operation" to operation?.toMap(), "resultId" to resultId,
            "scheduleBusy" to (scheduled != null),
            "resourceBusy" to resourceBusy,
            "dnsBusy" to coreReads.dnsBusy,
            "networkEpoch" to UnderlyingNetworks.snapshot().revision,
            "pendingSystemStart" to (pendingSystemRestore || PseudoVpnService.instance?.pendingSystemStart == true),
            "pendingStart" to (command?.get("action") in setOf("start", "refreshRuntime")),
            "pendingRestore" to pendingRestore,
            "writerBusy" to (logic.busy || operationId != null || storagePublishing || backupCapturing),
            "resultMessage" to resultMessage?.toMap(),
            "resultSuccess" to resultSuccess, "connectionStatus" to connectionStatus,
            "configStatus" to configStatus, "overrideStatus" to overrideStatus,
            "resourceStatus" to resourceStatus, "scheduleStatus" to scheduleStatus,
            "backupResult" to backupResult,
            "targetId" to targetId, "savedRevision" to savedRevision,
            "runningApplicationAccess" to PseudoVpnService.core.applicationAccess(state.generation),
            "core" to PseudoVpnService.core.snapshot().toMap(),
            "logSource" to PseudoVpnService.core.logSource()?.toMap(),
        )
    }
}
