package io.github.monadboxlab.clashpseudo.bridge.operation

import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.message.AppMessage
import java.util.concurrent.CancellationException

/** The admitted command and its publication authority, independent of UI and executor lifetime. */
internal class OperationState(private val now: () -> Long = SystemClock::elapsedRealtime) {
    val publicationGate = Any()
    @Volatile var operationId: String? = null
        private set
    @Volatile var operationAdmittedAt: Long? = null
        private set
    @Volatile var operationDeadline: Long? = null
        private set
    var command: Map<String, Any?>? = null
        set(value) = synchronized(publicationGate) {
            field = value
            if (value != null && operationDeadline == null) {
                operationDeadline = operationAdmittedAt?.let { it + OperationBudget.timeoutMs(value["action"]) }
            }
        }
    var authorization: MethodChannel.Result? = null
    var authorizationCode = 100
    var operation: AppMessage? = null
    var resultMessage: AppMessage? = null
    var resultId: String? = null
    var resultSuccess = false
    var connectionStatus: String? = null
    var configStatus: String? = null
    var overrideStatus: String? = null
    var resourceStatus: String? = null
    var scheduleStatus: String? = null
    var backupResult: Map<*, *>? = null
    var modeResult: Map<*, *>? = null
    var targetId: String? = null
    var savedRevision: Int? = null
    private var remainingOverride: (() -> Long)? = null
    private val executors = mutableSetOf<String>()
    var admitted: (String) -> Unit = {}

    fun replaceOwner(id: String?, admittedAt: Long? = null, deadline: Long? = null) = synchronized(publicationGate) {
        if (operationId == id) return@synchronized
        operationAdmittedAt = id?.let { admittedAt ?: now() }
        operationDeadline = if (id == null) null else deadline
        remainingOverride = null
        operationId = id
        if (id != null) admitted(id)
    }

    fun useRemaining(owner: String, remaining: () -> Long) = synchronized(publicationGate) {
        check(operationId == owner)
        remainingOverride = remaining
    }

    fun remainingMs(owner: String): Long = synchronized(publicationGate) {
        val at = operationAdmittedAt
        if (operationId != owner || at == null) 0L
        else remainingOverride?.invoke() ?: ((operationDeadline ?: (at + OperationBudget.timeoutMs(command?.get("action")))) - maxOf(at, now())).coerceAtLeast(0L)
    }

    fun runIfCurrent(owner: String, block: () -> Unit) = synchronized(publicationGate) {
        if (operationId != owner || remainingMs(owner) == 0L) throw CancellationException("Operation ended")
        block()
    }

    /** Revoke new work without discarding the executing owner's actual receipt. */
    fun interrupt(owner: String, message: AppMessage): Boolean = synchronized(publicationGate) {
        if (operationId != owner) return@synchronized false
        remainingOverride = { 0L }
        operation = message
        true
    }

    fun executorStarted(owner: String) = synchronized(publicationGate) { executors.add(owner); Unit }
    fun executorDrained(owner: String) = synchronized(publicationGate) { executors.remove(owner); Unit }
    val executorBusy: Boolean get() = synchronized(publicationGate) { executors.isNotEmpty() }

    fun clearResultFeedback() {
        resultMessage = null
        resultId = null
        connectionStatus = null
        configStatus = null
        overrideStatus = null
        resourceStatus = null
        scheduleStatus = null
        modeResult = null
        targetId = null
        savedRevision = null
    }

    fun finish(id: String, outcome: Map<*, *>, unconfirmed: (Any?) -> AppMessage) {
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
        scheduleStatus = (outcome["scheduleStatus"] as? String)?.takeIf { it in setOf("synced", "failed") }
        targetId = outcome["targetId"] as? String ?: command?.get("id") as? String
        savedRevision = (outcome["savedRevision"] as? Number)?.toInt()?.takeIf { it > 0 }
        modeResult = (outcome["modeResult"] as? Map<*, *>)?.takeIf {
            command?.get("action") == "setMode" && outcome["success"] == true &&
                it["status"] in setOf("saved", "applied") && it["mode"] == command?.get("mode")
        }?.filterKeys { it in setOf("status", "mode", "storageEpoch", "processId", "inputId",
            "generation", "configId", "revision", "composition", "purpose") }?.toMap()
        resultSuccess = outcome["success"] == true
        resultMessage = AppMessage.fromMap(outcome["message"])
            ?: if (outcome["message"] == null && resultSuccess) null else unconfirmed(outcome["message"])
    }
}
