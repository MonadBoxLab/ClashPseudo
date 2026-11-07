package io.github.monadboxlab.clashpseudo.bridge.runtime

import android.content.Context
import android.os.Handler
import android.os.SystemClock
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import io.github.monadboxlab.clashpseudo.bridge.operation.OperationState
import io.github.monadboxlab.clashpseudo.logic.LogicEngineHost
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.message.AppStrings
import io.github.monadboxlab.clashpseudo.storage.AppFiles
import io.github.monadboxlab.clashpseudo.storage.CoreDataCleanup
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.util.UUID

internal class SystemRestore(
    private val context: Context,
    private val main: Handler,
    private val operations: OperationState,
    private val logic: LogicEngineHost,
    private val exitingForCleanup: () -> Boolean,
    private val canAdmit: () -> Boolean,
    private val refreshBusy: () -> Unit,
    private val notifyUi: () -> Unit,
    private val executorDrained: (String) -> Unit,
) {
    private var systemRestoreOwner: String? = null
    private var discardedSystemInput: String? = null
    val owner: String? get() = systemRestoreOwner
    val pending: Boolean get() = systemRestoreOwner != null
    fun inputDrained(id: String) {
        if (discardedSystemInput == id) {
            discardedSystemInput = null
            try { AppFiles.systemInput(context).delete() } catch (_: Exception) { }
        }
    }

    fun cancelSystemRestore(): Boolean {
        val owner = systemRestoreOwner ?: return false
        systemRestoreOwner = null
        // An admitted restore retains its input until execution finishes.
        if (operations.operationId == owner) {
            discardedSystemInput = owner
            operations.replaceOwner(null)
            operations.command = null
            operations.operation = null
            logic.cancel(owner)
            if (!logic.busy) executorDrained(owner)
        }
        refreshBusy()
        notifyUi()
        return true
    }

    fun restoreSystemStart(reply: (Map<String, Any?>?) -> Unit) {
        if (pending) {
            reply(null)
            return
        }
        val owner = UUID.randomUUID().toString()
        val before = PseudoVpnService.session.snapshot()
        val admittedAt = SystemClock.elapsedRealtime()
        val deadline = admittedAt + Contract.OPERATION_ORDINARY_TIMEOUT_MS
        systemRestoreOwner = owner
        notifyUi()
        fun failed(error: Throwable) {
            if (systemRestoreOwner == owner) systemRestoreOwner = null
            if (operations.operationId == owner) {
                operations.resultId = owner
                operations.resultSuccess = false
                operations.resultMessage = AppStrings.message(R.string.error_system_start_prepare).withDetail(error)
                operations.replaceOwner(null)
                operations.command = null
                operations.operation = null
            }
            refreshBusy()
            notifyUi()
            reply(null)
        }
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
            val cleanup = CoreDataCleanup.get(context).snapshot()
            if (exitingForCleanup() || (cleanup["ready"] != true && cleanup["status"] != "initializing")) {
                systemRestoreOwner = null
                operations.resultMessage = AppMessage("coreCleanupRequired")
                notifyUi()
                reply(null)
                return
            }
            val storage = BackupFiles.get(context).transaction.snapshot()
            if (cleanup["ready"] != true || !storage.ready || storage.restoring || !canAdmit()) {
                // Wait for the writer within the original deadline; Stop revokes the owner immediately.
                main.postDelayed({ attempt() }, 100L)
                return
            }
            operations.replaceOwner(owner, admittedAt)
            operations.command = mapOf("action" to "systemStart", "storageEpoch" to storage.epoch,
                "admittedAt" to admittedAt, "deadline" to deadline)
            operations.resultId = null
            operations.resultMessage = null
            operations.resultSuccess = false
            operations.connectionStatus = null
            operations.configStatus = null
            operations.overrideStatus = null
            operations.resourceStatus = null
            operations.scheduleStatus = null
            operations.targetId = null
            operations.savedRevision = null
            operations.operation = AppStrings.message(R.string.operation_preparing_system_start)
            PseudoVpnService.core.setOperationBusy(true)
            notifyUi()
            try {
                logic.execute(owner, operations.command!!) { outcome ->
                    main.post { completeSystemRestore(owner, outcome, reply) }
                }
            } catch (error: Exception) {
                failed(error)
            } catch (error: LinkageError) {
                failed(error)
            }
        }
        attempt()
    }

    fun completeSystemRestore(owner: String, outcome: Map<*, *>, reply: (Map<String, Any?>?) -> Unit) {
        if (operations.operationId != owner || systemRestoreOwner != owner) {
            reply(null)
            return
        }
        systemRestoreOwner = null
        operations.replaceOwner(null)
        operations.command = null
        operations.operation = null
        operations.resultSuccess = false
        refreshBusy()
        if (outcome["success"] == true) {
            operations.resultId = null
            operations.resultSuccess = true
            operations.resultMessage = null
            notifyUi()
            reply(mapOf("started" to true))
        } else {
            operations.resultId = owner
            operations.resultMessage = AppMessage.fromMap(outcome["message"])
                ?: AppStrings.message(R.string.error_system_start_prepare)
            notifyUi()
            reply(null)
        }
    }
}
