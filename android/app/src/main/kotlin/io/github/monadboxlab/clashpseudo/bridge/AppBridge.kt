package io.github.monadboxlab.clashpseudo.bridge

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
import io.github.monadboxlab.clashpseudo.app.AppWorkService
import io.github.monadboxlab.clashpseudo.app.PseudoApplication
import io.github.monadboxlab.clashpseudo.backup.BackupCalls
import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import io.github.monadboxlab.clashpseudo.backup.RestoreTransaction
import io.github.monadboxlab.clashpseudo.backup.backupInteger
import io.github.monadboxlab.clashpseudo.backup.savedMode
import io.github.monadboxlab.clashpseudo.bridge.backup.BackupCoordinator
import io.github.monadboxlab.clashpseudo.bridge.core.ApplicationsCalls
import io.github.monadboxlab.clashpseudo.bridge.operation.OperationState
import io.github.monadboxlab.clashpseudo.bridge.runtime.ScheduledRuns
import io.github.monadboxlab.clashpseudo.bridge.runtime.SystemRestore
import io.github.monadboxlab.clashpseudo.controls.SystemControls
import io.github.monadboxlab.clashpseudo.logic.LogicEngineHost
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.message.AppStrings
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.CoreClient
import io.github.monadboxlab.clashpseudo.nativecore.CoreLifecycleCalls
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.vpn.network.LocalInterfaces
import io.github.monadboxlab.clashpseudo.schedule.ScheduleManager
import io.github.monadboxlab.clashpseudo.storage.AppFiles
import io.github.monadboxlab.clashpseudo.storage.CoreCleanupCalls
import io.github.monadboxlab.clashpseudo.storage.CoreDataCleanup
import io.github.monadboxlab.clashpseudo.trust.AppTrust
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import io.github.monadboxlab.clashpseudo.vpn.network.UnderlyingNetworks
import java.io.File
import java.io.InputStreamReader
import java.lang.ref.WeakReference
import java.nio.charset.CodingErrorAction
import java.util.UUID

object AppBridge {
    const val CHANNEL = "io.github.monadboxlab.clashpseudo/app"
    private lateinit var context: Context
    private lateinit var applications: ApplicationsCalls
    private lateinit var native: CoreLifecycleCalls
    private lateinit var localInterfaces: LocalInterfaces
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
    internal val operations = OperationState()
    private var storagePublishing = false
    private lateinit var backupCoordinator: BackupCoordinator
    private lateinit var scheduledRuns: ScheduledRuns
    private lateinit var systemRestore: SystemRestore
    private lateinit var cleanupCalls: CoreCleanupCalls
    private val exitingForCleanup: Boolean get() = ::cleanupCalls.isInitialized && cleanupCalls.exitingForCleanup
    private val pendingRestore: Boolean get() = backupCoordinator.pendingRestore
    private val backupCapturing: Boolean get() = ::backups.isInitialized && backups.snapshot()["capturing"] == true
    private val resourceBusy: Boolean get() = CoreClient.get(context).resourceBusy
    val operationAdmittedAt: Long? get() = operations.operationAdmittedAt
    val operationDeadline: Long? get() = operations.operationDeadline
    val operationId: String? get() = operations.operationId
    val command: Map<String, Any?>? get() = operations.command
    val pendingSystemRestore: Boolean get() = ::systemRestore.isInitialized && systemRestore.pending
    fun operationRemainingMs(owner: String): Long = operations.remainingMs(owner)
    fun executorStarted(owner: String) = operations.executorStarted(owner)
    private fun replaceOwner(owner: String?) = operations.replaceOwner(owner)
    private fun refreshBusy() = PseudoVpnService.core.setOperationBusy(
        operationId != null || logic.busy || operations.executorBusy || resourceBusy || storagePublishing || backupCapturing)
    private fun canAdmit() = !exitingForCleanup && operationId == null && !logic.busy && !operations.executorBusy &&
        !resourceBusy && !storagePublishing && !backupCapturing

    private fun admission(owner: String): Map<String, Any> = mapOf(
        "operationId" to owner,
        "remainingMs" to operationRemainingMs(owner),
    )

    fun initialize(appContext: Context) {
        context = appContext
        applications = ApplicationsCalls(context, PseudoVpnService.worker)
        native = CoreLifecycleCalls(context)
        localInterfaces = LocalInterfaces(context) { notifyUi() }
        logic = LogicEngineHost(appContext.applicationContext as PseudoApplication)
        backups = BackupCalls.get(context) {
            refreshBusy()
            notifyUi()
        }
        backupCoordinator = BackupCoordinator(
            context, main, operations, { backups }, { native }, logic,
            { owner -> activity.get() === owner && uiVisible }, { exitingForCleanup }, ::refreshBusy,
            { storagePublishing }, { storagePublishing = it }, { authorizationResult(false) },
            ::cancelPendingRuntimeRefresh, ::cancelSystemRestore, { systemRestore.owner }, ::notifyUi)
        scheduledRuns = ScheduledRuns(
            context, main, operations, logic, { native },
            { canAdmit() && !pendingSystemRestore }, ::refreshBusy, ::notifyUi)
        systemRestore = SystemRestore(
            context, main, operations, logic, { exitingForCleanup }, ::canAdmit, ::refreshBusy, ::notifyUi, ::executorDrained)
        cleanupCalls = CoreCleanupCalls(
            context, main, operations, { backupCoordinator.backupOwner(it) },
            { storagePublishing = it }, ::cancelPendingRuntimeRefresh, ::cancelSystemRestore,
            { backups.snapshot()["busy"] == true }, ::notifyUi)
        CoreClient.get(context).changed = { statusChanged -> nativeChanged(statusChanged) }
        CoreClient.get(context).onEvent = { event -> logic.coreEvent(event); notifyUi() }
    }

    internal fun requireCoreDataReady() = CoreDataCleanup.get(context).requireReady()

    fun attachBackupActivity(owner: MainActivity, savedState: Bundle?) = backups.attach(owner, savedState)

    fun saveBackupActivityState(owner: MainActivity, state: Bundle) = backups.saveState(owner, state)

    fun detachBackupActivity(owner: MainActivity) = backups.detach(owner)

    fun backupActivityResult(owner: MainActivity, code: Int, result: Int, data: Intent?): Boolean =
        backups.onActivityResult(owner, code, result, data)

    /** Revoke future work without replacing an executing command's actual result. */
    fun interruptOperation(owner: String, message: AppMessage): Boolean {
        if (operationId != owner || !logic.ownsOperation(owner)) return false
        if (pendingRestore) backupCoordinator.interrupted(owner, message)
        else {
            if (!operations.interrupt(owner, message)) return false
            authorizationResult(false)
            if (!logic.cancelBeforeExecution(owner, message)) {
                logic.cancel(owner)
                CoreClient.get(context).cancelOwner(owner)
                native.abandon()
            }
            notifyUi()
        }
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
                    onFailure = { result.error("trust", null, AppMessage("trustedRootsUnavailable").withDetail(it).toMap()) },
                )
            }
        }
    }

    private fun privacyNotice(call: MethodCall, result: MethodChannel.Result, current: () -> Boolean) {
        if (!current()) {
            result.error("expired", null, AppMessage("operationFinished").toMap())
            return
        }
        fun failed(error: Throwable) {
            val message = if (call.method == "markPrivacyNoticeShown") "privacyNoticeNotSaved"
                else "operationNotCompletedRetry"
            result.error("privacyNotice", null, AppMessage(message).withDetail(error).toMap())
        }
        try {
            // Share the file lane, not the native-core worker. Return only after
            // the marker's real read/write, sync and descriptor close have drained.
            BackupFiles.get(context).ioExecutor.execute {
                val outcome = runCatching {
                    if (call.method == "privacyNoticeShown") AppFiles.privacyNoticeShown(context)
                    else {
                        AppFiles.markPrivacyNoticeShown(context)
                        null
                    }
                }
                main.post { outcome.fold(onSuccess = { result.success(it) }, onFailure = ::failed) }
            }
        } catch (error: Exception) {
            failed(error)
        } catch (error: LinkageError) {
            failed(error)
        }
    }

    fun attachUi(owner: MainActivity, engine: FlutterEngine) {
        if (uiVisible) logic.retainPlatform(false)
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
                    "storageUsage" -> BackupFiles.get(context).ioExecutor.execute {
                        val usage = AppFiles.usage(context)
                        main.post { result.success(usage) }
                    }
                    "trustRoots" -> trustedRoots(result) { activity.get() === owner }
                    "privacyNoticeShown", "markPrivacyNoticeShown" ->
                        privacyNotice(call, result) { activity.get() === owner }
                    "appInfo" -> applications.appInfo(result)
                    "snapshot" -> snapshot(null, result)
                    "strategies", "rules", "nodes", "runtimeConfig", "resources", "logs",
                    "delayStart", "delayRead", "delayCancel", "appMemory", "coreMemory", "dnsQuery",
                    "clearDnsCache", "flushFakeIp", "cancelDnsQuery", "coreCleanupCandidates" ->
                        logic.read(call.method, call.arguments as? Map<String, Any?> ?: emptyMap(), result)
                    "connections" -> logic.connections(call.argument<Map<*, *>>("detail"), call.argument<String>("detailOwner"), result)
                    "clearInactiveConnections" -> logic.clearInactiveConnections(call.argument<Map<*, *>>("detail"), call.argument<String>("detailOwner"), result)
                    "traffic" -> logic.traffic(result)
                    "releaseDetail" -> logic.releaseDetail(call.argument<String>("detailOwner").orEmpty(), result)
                    "openVpnSettings" -> openVpnSettings(result)
                    "vpnStatus" -> result.success(vpnStatus())
                    "applications" -> applications.applications(result)
                    "applicationIcon" -> applications.applicationIcon(call, result)
                    Contract.CORE_CHANNEL_LOCAL_INTERFACES -> readLocalInterfaces(result)
                    "syncSchedules" -> syncSchedules(call, result)
                    "backupPickImport", "backupSaveExport", "backupCancel", "backupDiscard" ->
                        backupCoordinator.backupUi(call, owner, result)
                    "submit" -> submit(call, result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    internal fun syncUiVisibility() {
        logic.coreEvent(mapOf("event" to "uiVisibility", "visible" to (activity.get() != null && uiVisible)))
    }

    fun setUiVisible(owner: MainActivity, visible: Boolean) {
        // 旧 Activity 的回调不能撤销当前 Activity 的工作和 runtime 引用。
        if (activity.get() !== owner) return
        if (uiVisible != visible) logic.retainPlatform(visible)
        uiVisible = visible
        logic.coreEvent(mapOf("event" to "uiVisibility", "visible" to visible))
        localInterfaces.setActive(visible)
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
                    "submit" -> {
                        submit(call, result)
                        return@setMethodCallHandler
                    }
                    "snapshot" -> if (call.argument<String>("owner") == null) {
                        snapshot(null, result)
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
                            CoreClient.get(context).refreshPresentation { error ->
                                if (error == null) result.success(null)
                                else result.error("notification", null, AppStrings.message(R.string.error_notification_update).withDetail(error).toMap())
                            }
                        } catch (error: Exception) {
                            result.error("notification", null, AppStrings.message(R.string.error_notification_update).withDetail(error).toMap())
                        } catch (error: LinkageError) {
                            result.error("notification", null, AppStrings.message(R.string.error_notification_update).withDetail(error).toMap())
                        }
                        return@setMethodCallHandler
                    }
                    Contract.CORE_CHANNEL_HANDSHAKE, Contract.CORE_CHANNEL_SUBMIT,
                    Contract.CORE_CHANNEL_READ, Contract.CORE_CHANNEL_CANCEL, Contract.CORE_CHANNEL_STATUS,
                    Contract.CORE_CHANNEL_EXIT, Contract.CORE_CHANNEL_PUBLISH_RUN_INPUT,
                    Contract.CORE_CHANNEL_READ_RUN_INPUT_RECORD -> {
                        CoreClient.get(context).handle(call, result)
                        return@setMethodCallHandler
                    }
                    Contract.CORE_CHANNEL_LOCAL_INTERFACES -> {
                        readLocalInterfaces(result)
                        return@setMethodCallHandler
                    }
                    Contract.CORE_CHANNEL_RUNTIME_CHANGED -> {
                        val changed = logic.updateProjection(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>())
                        result.success(null)
                        if (changed) notifyUi()
                        return@setMethodCallHandler
                    }
                    "backupDiscard" -> {
                        val token = (call.arguments as? Map<*, *>)?.get("token") as? String
                        val caller = call.argument<String>("owner")
                        // This writer requests retirement only after its Store reads returned.
                        backupCoordinator.releaseAndDiscard(caller, token) { error ->
                            if (error == null) result.success(null)
                            else result.error("backupCleanup", null, AppMessage("backupFailed").withDetail(error).toMap())
                        }
                        return@setMethodCallHandler
                    }
                    "retain" -> {
                        val observationOwner = call.argument<String>("observationOwner")
                        if (observationOwner.isNullOrEmpty()) {
                            result.error("connections", null, AppStrings.message(R.string.error_invalid_result).toMap())
                        } else {
                            logic.retain(runtime, call.argument<Boolean>("value") == true, observationOwner)
                            result.success(null)
                        }
                        return@setMethodCallHandler
                    }
                }
                val owner = call.argument<String>("owner")
                if (owner == null || owner != operationId) {
                    result.error("expired", null, AppStrings.message(R.string.error_operation_ended).toMap())
                    return@setMethodCallHandler
                }
                val scheduledRun = scheduledRuns.current?.takeIf { it.owner == owner }
                if (scheduledRun != null && !scheduledRun.authorized() && call.method != "snapshot") {
                    scheduledRuns.cancelScheduledOperation(scheduledRun)
                    result.error("expired", null, AppMessage("operationFinished").toMap())
                    return@setMethodCallHandler
                }
                if ((operationRemainingMs(owner) == 0L || (pendingRestore && backupCoordinator.stopRequested)) &&
                    call.method !in setOf("stop", "snapshot")) {

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
                if (call.method in setOf("start", "prepareStrategies", "updateResource") && !CoreDataCleanup.get(context).ready) {
                    result.error("coreCleanup", null, AppMessage("coreCleanupRequired").toMap())
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "scheduleCoreCleanup" -> cleanupCalls.scheduleCoreCleanup(call, owner, result)
                    "checkOperation" -> {
                        if (operationRemainingMs(owner) > 0L) result.success(null)
                        else result.error("expired", null, AppMessage("operationFinished").toMap())
                    }
                    "operationRemaining" -> result.success(operationRemainingMs(owner))
                    "finishScheduledDownload" -> scheduledRuns.finishScheduledDownload(call, owner, result)
                    "backupPrepareExport", "backupCandidate", "backupInstall" -> backupCoordinator.backupWork(call, owner, result)
                    "publishStore" -> publishStore(call, owner, result)
                    "paths" -> storagePaths(result)
                    "snapshot" -> snapshot(owner, result)
                    "syncSchedules" -> syncSchedules(call, result)
                    "stage" -> {
                        val message = AppMessage.fromMap(call.argument<Any>("message"))
                        if (message == null) result.error("stage", null, AppStrings.message(R.string.error_invalid_result).toMap())
                        else { operations.operation = message; notifyUi(); result.success(null) }
                    }
                    "authorize" -> authorize(result)
                    "stop" -> {
                        if (pendingRestore) {
                            backupCoordinator.restoreNetworkStop(owner, result, internalReconnect = true)
                            return@setMethodCallHandler
                        }
                        // This owner is already authorized. Its non-stop command
                        // releases only as part of an application apply/reconnect.
                        val internalReconnect = scheduledRuns.current?.owner == owner ||
                            command?.get("action")?.let { it != "stop" } == true
                        if (!internalReconnect) cancelSystemRestore()
                        native.stop(result, internalReconnect)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun readLocalInterfaces(result: MethodChannel.Result) {
        CoreClient.get(context).io.execute {
            val value = localInterfaces.snapshot()
            main.post { result.success(value) }
        }
    }

    private fun syncSchedules(call: MethodCall, result: MethodChannel.Result) {
        @Suppress("UNCHECKED_CAST")
        val targets = (call.argument<List<Map<*, *>>>("targets") ?: emptyList())
        val kind = call.argument<String>("kind")
        fun failed(error: Throwable) {
            result.error("schedule", null,
                AppStrings.message(R.string.error_schedule_save).withDetail(error).toMap())
        }
        try {
            PseudoVpnService.worker.execute {
                try {
                    require(kind in setOf("config", "override"))
                    ScheduleManager.sync(context, targets, kind) {
                        main.post { result.success(null) }
                    }
                } catch (error: Exception) {
                    main.post { failed(error) }
                } catch (error: LinkageError) {
                    main.post { failed(error) }
                }
            }
        } catch (error: Exception) {
            failed(error)
        } catch (error: LinkageError) {
            failed(error)
        }
    }

    fun runSchedule(kind: String, id: String, cancelled: () -> Boolean = { false }): Map<*, *> =
        scheduledRuns.runScheduled(mapOf("action" to "refreshSchedule", "kind" to kind, "id" to id), cancelled)

    /** Reconcile from saved Dart settings. */
    fun reconcileSchedules(cancelled: () -> Boolean = { false }): Map<*, *> =
        scheduledRuns.runScheduled(mapOf("action" to "syncSchedules"), cancelled)

    private fun submit(call: MethodCall, result: MethodChannel.Result) {
        @Suppress("UNCHECKED_CAST")
        val request = call.arguments as? Map<String, Any?>
        if (exitingForCleanup && request?.get("action") != "stop") {
            result.error("busy", null, AppStrings.message(R.string.error_busy).toMap())
            return
        }
        if (request?.get("action") == "scheduleCoreCleanup" && backups.snapshot()["busy"] == true) {
            result.error("busy", null, AppStrings.message(R.string.error_busy).toMap())
            return
        }
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
        if (request?.get("action") == "refreshRuntime") {
            val captured = CoreClient.get(context).status()
            val matches = listOf(Contract.CORE_FIELD_PROCESS_ID, Contract.CORE_FIELD_INPUT_ID).all {
                request[it] is String && request[it] == captured[it]
            } && listOf(Contract.CORE_FIELD_GENERATION, Contract.CORE_FIELD_NETWORK_REVISION).all {
                val expected = request[it]
                val actual = captured[it]
                (expected is Int || expected is Long) && actual is Number && (expected as Number).toLong() == actual.toLong()
            }
            if (!matches || captured[Contract.CORE_FIELD_PHASE] != Contract.CORE_PHASE_READY) {
                result.error("expired", null, AppMessage("operationNotCompletedRetry").toMap())
                return
            }
        }
        if (request?.get("action") == "stop" && pendingRestore) {
            val restoreOwner = operationId
            if (restoreOwner != null) {
                val alwaysOn = PseudoVpnService.alwaysOnState() == true
                backupCoordinator.requestRestoreStop(restoreOwner, stopNetwork = !alwaysOn)
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
                (command?.get("action") != "systemRevoked" && scheduledRuns.current == null &&
                    PseudoVpnService.core.snapshot().phase == CoreHost.Phase.RELEASING))) {
            result.error("busy", null, AppStrings.message(R.string.error_busy).toMap())
            return
        }
        if (request?.get("action") == "stop") {
            cancelPendingRuntimeRefresh()
        }
        if (request?.get("action") == "stop" && (scheduledRuns.current != null || resourceBusy || pendingSystemRestore || backupCapturing ||
            command?.get("action") in setOf("start", "refreshRuntime", "systemRevoked", "prepareBackup", "inspectBackup", "scheduleCoreCleanup") ||
            PseudoVpnService.session.snapshot().phase == NativeSession.Phase.STARTING)) {
            val interruptedAt = operations.operationAdmittedAt
            val interruptedDeadline = operations.operationDeadline
            cancelSystemRestore()
            cancelScheduledOperation()
            operationId?.let { previous ->
                if (command?.get("action") == "prepareBackup") backupCoordinator.retirePreparation(previous)
                replaceOwner(null)
                operations.command = null
                operations.operation = null
                authorizationResult(false)
                logic.cancel(previous)
                native.abandon(previous)
            }
            // Stop can preempt a download; other commands remain serialized by
            // logic.busy.
            val owner = UUID.randomUUID().toString()
            operations.replaceOwner(owner, interruptedAt, interruptedDeadline)
            operations.command = request
            operations.resultId = null
            operations.resultMessage = null
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
        if (!canAdmit() || pendingSystemRestore) {
            result.error("busy", null, AppStrings.message(R.string.error_busy).toMap())
            return
        }
        if (request?.get("action") !in setOf("import", "updateConfig", "renameConfig", "saveLocal", "start", "stop", "select", "delete", "clearConfigurations", "clearOverrides", "setMode", "prepareStrategies", "setStrategy", "closeConnection", "setPreference", "saveOverride", "importOverride", "updateOverride", "changeOverrideSource", "changeOverride", "reorderOverrides", "deleteOverride", "setApplicationAccess", "setConfigUpdate", "setOverrideUpdate", "syncSchedules", "updateResource", "saveLocalDefinition", "deleteLocalDefinition", "prepareBackup", "inspectBackup", "restoreBackup", "scheduleCoreCleanup", "saveLanProxy", "setLanProxyEnabled", "refreshRuntime")) {
            result.error("command", null, AppStrings.message(R.string.error_unknown_command).toMap())
            return
        }
        if (request?.get("action") in setOf("prepareBackup", "inspectBackup", "restoreBackup")) {
            val requestId = request?.get("requestId") as? String
            val token = request?.get("token") as? String
            val created = backupInteger(request?.get("createdAtMillis"))
            if (requestId.isNullOrBlank() || requestId.length > 128 ||
                (request?.get("action") == "prepareBackup" && (created == null || created > 8_640_000_000_000_000L)) ||
                (request?.get("action") != "prepareBackup" && (token == null || !BackupFiles.isToken(token) || backupCoordinator.isRetired(token)))) {
                result.error("backup", null, AppMessage("backupInvalid").toMap())
                return
            }
        }
        val owner = UUID.randomUUID().toString()
        replaceOwner(owner)
        PseudoVpnService.core.setOperationBusy(true)
        operations.command = request
        operations.operation = AppStrings.message(R.string.operation_accepting)
        operations.resultMessage = null
        operations.resultId = null
        operations.connectionStatus = null
        operations.configStatus = null
        operations.overrideStatus = null
        operations.resourceStatus = null
        operations.scheduleStatus = null
        operations.targetId = null
        operations.savedRevision = null
        try {
            val intent = Intent(context, AppWorkService::class.java).putExtra(AppWorkService.EXTRA_OWNER, owner)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
            else context.startService(intent)
            result.success(admission(owner))
            notifyUi()
        } catch (error: Exception) {
            finish(owner, notExecutedResult(request, AppStrings.message(R.string.error_service_start).withDetail(error)))
            result.error("service", null, AppStrings.message(R.string.error_service_not_allowed).withDetail(error).toMap())
        } catch (error: LinkageError) {
            finish(owner, notExecutedResult(request, AppStrings.message(R.string.error_service_start).withDetail(error)))
            result.error("service", null, AppStrings.message(R.string.error_service_not_allowed).withDetail(error).toMap())
        }
    }

    fun restoreActivityState(state: Bundle?) {
        val previous = state?.getInt("pseudo.vpn.authorizationCode", 100) ?: 100
        if (previous in 100..0x3fff) operations.authorizationCode = maxOf(operations.authorizationCode, previous)
    }

    fun saveActivityState(state: Bundle) {
        state.putInt("pseudo.vpn.authorizationCode", operations.authorizationCode)
    }

    private fun authorize(result: MethodChannel.Result) {
        if (VpnService.prepare(context) == null) { result.success(true); return }
        val owner = activity.get()
        if (owner == null || !uiVisible || owner.isFinishing || operations.authorization != null) {
            result.error("permission", null, AppStrings.message(R.string.error_vpn_permission_return).toMap())
            return
        }
        if (operations.authorizationCode >= 0x3fff) {
            result.error("permission", null, AppStrings.message(R.string.error_vpn_permission_requests).toMap())
            return
        }
        operations.authorization = result
        // Reserve separate monotonic code ranges for file_selector 221–223 and backup
        // 0x4000–0x7fff.
        operations.authorizationCode++
        if (operations.authorizationCode in 221..223) operations.authorizationCode = 224
        owner.requestVpnPermission(operations.authorizationCode)
    }

    fun authorizationResult(requestCode: Int, granted: Boolean) {
        if (requestCode == operations.authorizationCode) authorizationResult(granted)
    }

    private fun authorizationResult(granted: Boolean) {
        val result = operations.authorization ?: return
        operations.authorization = null
        result.success(granted && VpnService.prepare(context) == null)
    }

    fun nativeChanged(statusChanged: Boolean = true) {
        if (statusChanged) operations.clearResultFeedback()
        advanceSystemRevoked()
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
        backupCoordinator.finishDetail(id, outcome)
        authorizationResult(false)
        if (action != "restoreBackup" || !backupCoordinator.hasStopOwner(id)) native.abandon()
        if (!logic.busy) clearInput(id)
        operations.finish(id, outcome) { AppStrings.message(R.string.error_result_unconfirmed).withDetail(it) }
        backupCoordinator.retainInterruption(action)
        replaceOwner(null)
        operations.command = null
        operations.operation = null
        refreshBusy()
        notifyUi()
    }

    fun executorDrained(id: String) {
        operations.executorDrained(id)
        backupCoordinator.executorDrained(id)
        clearInput(id)
        systemRestore.inputDrained(id)
        advanceSystemRevoked()
        refreshBusy()
        notifyUi()
    }

    fun cancelScheduledOperation(): Boolean = scheduledRuns.cancelScheduledOperation()
    private fun cancelPendingRuntimeRefresh() {
        val captured = CoreClient.get(context).status()
        logic.coreEvent(mapOf("event" to "cancelRefresh") +
            listOf(Contract.CORE_FIELD_PROCESS_ID, Contract.CORE_FIELD_INPUT_ID,
                Contract.CORE_FIELD_GENERATION, Contract.CORE_FIELD_NETWORK_REVISION)
                .associateWith { captured[it] })
    }
    fun cancelRuntimeRefresh(): Boolean {
        cancelPendingRuntimeRefresh()
        if (command?.get("action") != "refreshRuntime") return false
        val owner = operationId ?: return false
        return interruptOperation(owner, AppStrings.message(R.string.error_operation_ended))
    }

    fun cancelSystemRestore(): Boolean = systemRestore.cancelSystemRestore()
    fun restoreSystemStart(reply: (Map<String, Any?>?) -> Unit) = systemRestore.restoreSystemStart(reply)

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
            command?.get("action") in setOf("start", "refreshRuntime", "systemRevoked") || pendingSystemRestore) return "stop"
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
                backupCoordinator.requestRestoreStop(owner, stopNetwork = !alwaysOn)
                reply(if (alwaysOn) SystemControls.Admission.VPN_SETTINGS else SystemControls.Admission.ACCEPTED)
            } else reply(SystemControls.Admission.OPEN_APP)
            return
        }
        val state = PseudoVpnService.session.snapshot()
        val preparing = command?.get("action") in setOf("start", "refreshRuntime") ||
            pendingSystemRestore
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
        if (action == "start") {
            fun permissionFailed(error: Throwable) {
                if (operationId == null) {
                    operations.resultSuccess = false
                    operations.resultMessage = AppStrings.message(R.string.error_vpn_permission_invalid).withDetail(error)
                    operations.resultId = UUID.randomUUID().toString()
                    notifyUi()
                }
                reply(SystemControls.Admission.OPEN_APP)
            }
            val permission = try {
                VpnService.prepare(context)
            } catch (error: Exception) {
                permissionFailed(error)
                return
            } catch (error: LinkageError) {
                permissionFailed(error)
                return
            }
            if (permission != null && (activity.get() == null || !uiVisible)) {
                reply(SystemControls.Admission.OPEN_APP)
                return
            }
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
                    operations.resultSuccess = false
                    operations.resultMessage = AppMessage.fromMap(details)
                        ?: AppStrings.message(R.string.error_result_unconfirmed)
                    operations.resultId = UUID.randomUUID().toString()
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
                            savedMode(InputStreamReader(input, decoder), setOf("rule", "global", "direct"))
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
        val remote = CoreClient.get(context).status()
        val alwaysOn = remote["alwaysOn"] as? Boolean
        val lockdown = remote["lockdown"] as? Boolean
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
        } catch (error: Exception) {
            result.error("settings", null, AppStrings.message(R.string.error_open_vpn_settings).withDetail(error).toMap())
        } catch (error: LinkageError) {
            result.error("settings", null, AppStrings.message(R.string.error_open_vpn_settings).withDetail(error).toMap())
        }
    }

    /**
     * Prepares a run input for a system-initiated start (Android Always-on).
     * The Dart business engine remains the only writable owner; the VPN service
     * starts afterwards with the prepared input identity.
     */

    private fun publishStore(call: MethodCall, owner: String, result: MethodChannel.Result) {
        val kind = BackupFiles.Kind.entries.firstOrNull { it.fileName == call.argument<String>("file") }
        val rawEpoch = call.argument<Any>("epoch")
        val epoch = if (rawEpoch is Int || rawEpoch is Long) (rawEpoch as Number).toLong() else null
        if (kind == null || epoch == null || epoch < 0 || storagePublishing || backupCapturing) {
            result.error("storage", null, AppMessage("storageUnavailable").toMap())
            return
        }
        val scheduledRun = scheduledRuns.current?.takeIf { it.owner == owner }
        val files = BackupFiles.get(context)
        fun complete(outcome: Result<RestoreTransaction.Publication>) {
            storagePublishing = false
            try {
                outcome.fold(
                    onSuccess = { value ->
                        // A successful rename is a saved result, even when later
                        // cancellation or directory sync prevents confirmation.
                        result.success(mapOf("saved" to value.saved, "durable" to value.durable,
                            "epoch" to value.epoch, "errorCode" to value.error,
                            "errorDetail" to value.cause?.let { AppMessage("storageUnavailable").withDetail(it).toMap() }))
                    },
                    onFailure = { error ->
                        result.error(if (operationId == owner) "storage" else "expired", null,
                            AppMessage(if (operationId == owner) "storageUnavailable" else "operationFinished")
                                .withDetail(error).toMap())
                    },
                )
            } finally {
                refreshBusy()
                notifyUi()
            }
        }
        storagePublishing = true
        PseudoVpnService.core.setOperationBusy(true)
        try {
            files.ioExecutor.execute {
                val outcome = runCatching {
                    files.transaction.publishStore(kind, epoch, object : RestoreTransaction.Owner {
                        override fun checkCurrent() {
                            check(operationId == owner && operationRemainingMs(owner) > 0L && scheduledRun?.authorized() != false)
                        }
                        override fun runIfCurrent(block: () -> Unit) {
                            synchronized(operations.publicationGate) {
                                checkCurrent()
                                if (scheduledRun == null) block() else scheduledRun.publishIfAuthorized(block)
                            }
                        }
                    })
                }
                main.post { complete(outcome) }
            }
        } catch (error: Exception) {
            complete(Result.failure(error))
        } catch (error: LinkageError) {
            complete(Result.failure(error))
        }
    }

    private fun storagePaths(result: MethodChannel.Result) {
        val state = BackupFiles.get(context).transaction.snapshot()
        if (!state.ready || state.restoring) {
            result.error("storage", null, (state.issue ?: AppMessage("storageUnavailable")).toMap())
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
        result.success(snapshotMap(PseudoVpnService.session.snapshot()))
    }

    fun systemRevoked(event: Map<String, Any?>): Boolean {
        val captured = CoreClient.get(context).status()
        if (event["event"] != "revoked" || !revokedIdentityMatches(event, captured)) return false
        if (command?.get("action") == "systemRevoked" && revokedIdentityMatches(command!!, captured)) return true
        val previous = operationId
        val admittedAt = operations.operationAdmittedAt ?: SystemClock.elapsedRealtime()
        val deadline = operations.operationDeadline ?: (admittedAt + Contract.OPERATION_ORDINARY_TIMEOUT_MS)
        val preserveLan = captured[Contract.CORE_FIELD_PHASE] == Contract.CORE_PHASE_READY && captured["lanIntent"] == true
        val owner = UUID.randomUUID().toString()
        val request = listOf(Contract.CORE_FIELD_PROCESS_ID, Contract.CORE_FIELD_INPUT_ID,
            Contract.CORE_FIELD_GENERATION, Contract.CORE_FIELD_NETWORK_REVISION,
            "configId", "revision", "composition", "purpose").associateWith { captured[it] } + mapOf(
            "action" to "systemRevoked", "reason" to "revoked", "revokedOwner" to previous,
            "admittedAt" to admittedAt, "deadline" to deadline, "preserveLan" to preserveLan,
            "storageEpoch" to BackupFiles.get(context).transaction.snapshot().epoch,
            "revocationState" to "cancelling",
        )
        cancelSystemRestore()
        cancelPendingRuntimeRefresh()
        operations.replaceOwner(owner, admittedAt, deadline)
        operations.command = request
        operations.operation = null
        operations.clearResultFeedback()
        operations.resultSuccess = false
        authorizationResult(false)
        // STARTING 先关闭 PREPARE admission，再取消原请求。
        if (!preserveLan) exitSystemRevoked(owner, request)
        // 新 owner 先占用 admission，旧 executor 的同步 drain 不会受理其他 writer。
        cancelScheduledOperation()
        previous?.let { logic.cancel(it); native.abandon(it) }
        logic.coreEvent(event)
        if (preserveLan) {
            operations.command = request + ("revocationState" to "waiting")
            awaitSystemRevoked(owner)
        }
        refreshBusy()
        notifyUi()
        return true
    }

    private fun revokedIdentityMatches(expected: Map<String, Any?>, actual: Map<String, Any?>): Boolean =
        expected[Contract.CORE_FIELD_PROCESS_ID] is String &&
            expected[Contract.CORE_FIELD_PROCESS_ID] == actual[Contract.CORE_FIELD_PROCESS_ID] &&
            expected[Contract.CORE_FIELD_INPUT_ID] == actual[Contract.CORE_FIELD_INPUT_ID] &&
            expected["purpose"] == actual["purpose"] &&
            expected["configId"] == actual["configId"] &&
            (expected["revision"] as? Number)?.toLong() == (actual["revision"] as? Number)?.toLong() &&
            (!expected.containsKey("composition") || expected["composition"] == actual["composition"]) &&
            listOf(Contract.CORE_FIELD_GENERATION, Contract.CORE_FIELD_NETWORK_REVISION).all {
                val left = expected[it]
                val right = actual[it]
                (left is Int || left is Long) && right is Number && (left as Number).toLong() == right.toLong()
            }

    private fun awaitSystemRevoked(owner: String) {
        if (operationId != owner || command?.get("revocationState") != "waiting") return
        advanceSystemRevoked()
        if (operationId == owner && command?.get("revocationState") == "waiting") {
            main.postDelayed({ awaitSystemRevoked(owner) }, minOf(100L, operations.remainingMs(owner)).coerceAtLeast(1L))
        }
    }

    private fun advanceSystemRevoked() {
        val owner = operationId ?: return
        val request = command ?: return
        if (request["action"] != "systemRevoked" || request["revocationState"] != "waiting") return
        val client = CoreClient.get(context)
        if (!revokedIdentityMatches(request, client.status())) {
            finish(owner, mapOf("success" to false, "message" to AppMessage("operationFinished").toMap()))
            return
        }
        if (operations.remainingMs(owner) == 0L) {
            exitSystemRevoked(owner, request, AppMessage("operationNotCompletedRetry")
                .withDetail("VPN revoke 的原受理期限已到，LAN 恢复尚未完成"))
            return
        }
        if (logic.busy || operations.executorBusy || client.requestBusy || resourceBusy || storagePublishing || backupCapturing) return
        operations.command = request + ("revocationState" to "executing")
        logic.execute(owner, operations.command!!) { outcome ->
            if (operationId != owner) return@execute
            if (outcome["success"] != true && (client.requestBusy || client.status()[Contract.CORE_FIELD_PHASE] in setOf(
                    Contract.CORE_PHASE_LOADING, Contract.CORE_PHASE_STOPPING, Contract.CORE_PHASE_COMMUNICATION_LOST,
                    Contract.CORE_PHASE_RECOVERY_REQUIRED))) {
                recordIncompleteRevocation(owner, outcome)
            } else finish(owner, outcome)
        }
    }

    private fun exitSystemRevoked(owner: String, request: Map<String, Any?>, incomplete: AppMessage? = null) {
        if (operationId != owner) return
        val client = CoreClient.get(context)
        if (!revokedIdentityMatches(request, client.status())) {
            finish(owner, mapOf("success" to false, "message" to AppMessage("operationFinished").toMap()))
            return
        }
        operations.command = request + ("revocationState" to "exiting")
        client.exit(request[Contract.CORE_FIELD_PROCESS_ID] as String,
            (request["admittedAt"] as Number).toLong(), (request["deadline"] as Number).toLong(), "revoked") { error ->
            if (operationId != owner) return@exit
            if (error != null) {
                android.util.Log.e("PseudoRuntime", "VPN revoke 后 core 退出尚未确认", error)
                recordIncompleteRevocation(owner, mapOf("success" to false, "message" to
                    (incomplete ?: AppMessage("operationNotCompletedRetry")).withDetail(error).toMap()))
            } else finish(owner, mapOf("success" to (incomplete == null), "message" to incomplete?.toMap()))
        }
    }

    private fun recordIncompleteRevocation(owner: String, outcome: Map<*, *>) {
        if (operationId != owner) return
        operations.command = command!! + ("revocationState" to "incomplete")
        operations.finish(owner, outcome) { AppStrings.message(R.string.error_result_unconfirmed).withDetail(it) }
        // 未确认 process 与 FD I/O 退出时保留 admission；用户可通过 Stop 再次请求退出。
        refreshBusy()
        notifyUi()
    }

    private fun snapshotMap(state: NativeSession.Snapshot): Map<String, Any?> {
        val storage = BackupFiles.get(context).transaction.snapshot()
        return mapOf(
            "storageReady" to storage.ready, "storageRestoring" to storage.restoring,
            "storageEpoch" to storage.epoch, "storageError" to storage.issue?.toMap(),
            "backup" to backups.snapshot(),
            "coreCleanup" to CoreDataCleanup.get(context).snapshot(),
            "phase" to state.phase.name, "generation" to state.generation,
            "alwaysOn" to PseudoVpnService.alwaysOnState(),
            "runningSinceElapsedMs" to state.runningSinceElapsedMs,
            "elapsedRealtimeMs" to state.elapsedRealtimeMs,
            "configId" to state.configId, "revision" to state.revision, "error" to state.error?.toMap(),
            "operation" to operations.operation?.toMap(), "resultId" to operations.resultId,
            "operationId" to operationId,
            "operationRemainingMs" to operationId?.let(::operationRemainingMs),
            "operationAdmittedAt" to operations.operationAdmittedAt,
            "operationDeadline" to operations.operationDeadline,
            "scheduleBusy" to (scheduledRuns.current != null),
            "resourceBusy" to resourceBusy,
            "dnsBusy" to (logic.runtimeProjection["dnsBusy"] == true),
            "dnsOperation" to logic.runtimeProjection["dnsOperation"],
            "networkEpoch" to CoreClient.get(context).status()["networkRevision"],
            "pendingSystemStart" to pendingSystemRestore,
            "mode" to (logic.runtimeProjection["mode"] as? Map<*, *>)?.get("actual"),
            "modeError" to (logic.runtimeProjection["mode"] as? Map<*, *>)?.get("error"),
            "pendingStart" to (command?.get("action") in setOf("start", "refreshRuntime")),
            "pendingRestore" to pendingRestore,
            "writerBusy" to (exitingForCleanup || logic.busy || operations.executorBusy || operationId != null || storagePublishing || backupCapturing),
            "resultMessage" to operations.resultMessage?.toMap(),
            "resultSuccess" to operations.resultSuccess, "connectionStatus" to operations.connectionStatus,
            "configStatus" to operations.configStatus, "overrideStatus" to operations.overrideStatus,
            "resourceStatus" to operations.resourceStatus, "scheduleStatus" to operations.scheduleStatus,
            "backupResult" to operations.backupResult,
            "targetId" to operations.targetId, "savedRevision" to operations.savedRevision,
            "runningApplicationAccess" to PseudoVpnService.core.applicationAccess(state.generation),
            "core" to (PseudoVpnService.core.snapshot().toMap() + mapOf("networkRevision" to CoreClient.get(context).status()["networkRevision"])),
            "logSource" to logic.runtimeProjection["logSource"],
            "vpnIntent" to CoreClient.get(context).status()["vpnIntent"],
            "lanIntent" to CoreClient.get(context).status()["lanIntent"],
            "lanRunning" to CoreClient.get(context).status()["lanRunning"],
            "lanListeners" to CoreClient.get(context).status()["lanListeners"],
            "recoveryRequired" to CoreClient.get(context).lifecycle.snapshot().recoveryRequired,
            "coreLifecycle" to CoreClient.get(context).status()["coreLifecycle"],
        )
    }
}
