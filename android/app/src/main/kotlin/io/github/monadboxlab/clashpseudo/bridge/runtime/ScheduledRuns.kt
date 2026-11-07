package io.github.monadboxlab.clashpseudo.bridge.runtime

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import io.github.monadboxlab.clashpseudo.nativecore.CoreLifecycleCalls
import io.github.monadboxlab.clashpseudo.nativecore.CoreClient
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.operation.OperationState
import io.github.monadboxlab.clashpseudo.logic.LogicEngineHost
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.message.AppStrings
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.util.UUID

internal fun matchesScheduledInput(call: MethodCall, core: Map<String, Any?>): Boolean {
    if (core[Contract.CORE_FIELD_PHASE] != Contract.CORE_PHASE_READY ||
        core["purpose"] != Contract.CORE_PURPOSE_RUNNING ||
        (core["vpnRunning"] != true && core["lanRunning"] != true)) return false
    for (field in listOf("processId", "inputId", "configId", "composition")) {
        val value = core[field] as? String
        if (value.isNullOrEmpty() || value != call.argument<String>(field)) return false
    }
    val generation = (core["generation"] as? Number)?.toLong() ?: return false
    val revision = (core["revision"] as? Number)?.toInt() ?: return false
    return generation > 0 && revision > 0 &&
        generation == call.argument<Number>("generation")?.toLong() &&
        revision == call.argument<Number>("revision")?.toInt() &&
        (core["vpnRunning"] != true || generation == call.argument<Number>("sessionGeneration")?.toLong())
}

internal class ScheduledRuns(
    private val context: Context,
    private val main: Handler,
    private val operations: OperationState,
    private val logic: LogicEngineHost,
    private val nativeCalls: () -> CoreLifecycleCalls,
    private val canAdmit: () -> Boolean,
    private val refreshBusy: () -> Unit,
    private val notifyUi: () -> Unit,
) {
    private val native: CoreLifecycleCalls get() = nativeCalls()

    internal class ScheduledRun(
        val workerStopped: () -> Boolean,
        private val now: () -> Long = SystemClock::elapsedRealtime,
    ) {
        val owner: String = UUID.randomUUID().toString()
        val done = java.util.concurrent.CountDownLatch(1)
        val cancelled = java.util.concurrent.atomic.AtomicBoolean(false)
        @Volatile private var admittedAt: Long? = null
        val deadline: Long get() = admittedAt?.plus(io.github.monadboxlab.clashpseudo.app.ApplicationContract.OPERATION_SCHEDULED_NETWORK_TIMEOUT_MS) ?: Long.MAX_VALUE
        private val operationDeadline: Long get() = admittedAt?.plus(io.github.monadboxlab.clashpseudo.app.ApplicationContract.OPERATION_ORDINARY_TIMEOUT_MS) ?: Long.MIN_VALUE
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
    val current: ScheduledRun? get() = scheduled
    fun cancelScheduledOperation(): Boolean = scheduled?.let { cancelScheduledOperation(it) } ?: false

    fun runScheduled(request: Map<String, Any?>,
                             cancelled: () -> Boolean = { false }): Map<*, *> {
        val run = ScheduledRun(cancelled)
        main.post {
            if (run.cancelled.get() || cancelled()) {
                run.cancel()
                return@post
            }
            val storage = BackupFiles.get(context).transaction.snapshot()
            if (!canAdmit() || !storage.ready || storage.restoring ||
                operations.operationId != null || logic.busy ||
                PseudoVpnService.session.snapshot().phase in setOf(
                    NativeSession.Phase.STARTING, NativeSession.Phase.STOPPING)) {
                run.finish(mapOf("success" to false, "scheduleStatus" to "busy"))
                return@post
            }
            scheduled = run
            operations.replaceOwner(run.owner)
            run.admit(operations.operationAdmittedAt!!)
            operations.useRemaining(run.owner, run::remainingMs)
            operations.command = request + ("storageEpoch" to storage.epoch)
            PseudoVpnService.core.setOperationBusy(true)
            notifyUi()
            val settle: (Map<*, *>) -> Unit = { value ->
                main.post {
                    if (operations.operationId == run.owner || (scheduled === run && operations.operationId == null)) {
                        operations.replaceOwner(null)
                        operations.command = null
                        operations.operation = null
                    }
                    if (scheduled === run) scheduled = null
                    run.applicationTimeout?.let { main.removeCallbacks(it) }
                    run.applicationTimeout = null
                    refreshBusy()
                    notifyUi()
                    run.finish(value)
                }
            }
            try {
                logic.execute(run.owner, operations.command!!, settle)
            } catch (error: Exception) {
                settle(mapOf("success" to false, "message" to
                    AppStrings.message(R.string.error_background_start).withDetail(error).toMap()))
            } catch (error: LinkageError) {
                settle(mapOf("success" to false, "message" to
                    AppStrings.message(R.string.error_background_start).withDetail(error).toMap()))
            }
        }
        try {
            while (!run.done.await(100, java.util.concurrent.TimeUnit.MILLISECONDS)) {
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

    fun finishScheduledDownload(call: MethodCall, owner: String, result: MethodChannel.Result) {
        val run = scheduled
        val core = CoreClient.installed().status()
        if (run == null || run.owner != owner || operations.command?.get("action") != "refreshSchedule" ||
            operations.command?.get("kind") != call.argument<String>("kind") ||
            operations.command?.get("id") != call.argument<String>("id") ||
            !matchesScheduledInput(call, core) ||
            !run.handoff()) {
            result.error("expired", null, AppMessage("operationFinished").toMap())
            return
        }
        val timeout = Runnable {
            if (scheduled === run && operations.operationId == owner) cancelScheduledOperation()
        }
        run.applicationTimeout = timeout
        main.postDelayed(timeout, run.applicationRemainingMs())
        result.success(null)
    }

    fun cancelScheduledOperation(run: ScheduledRun): Boolean {
        val current = scheduled === run
        if (current) scheduled = null
        run.cancel()
        run.applicationTimeout?.let { main.removeCallbacks(it) }
        run.applicationTimeout = null
        val ownsCommand = current && (operations.operationId == run.owner || operations.operationId == null)
        val starting = if (ownsCommand && PseudoVpnService.session.snapshot().phase == NativeSession.Phase.STARTING)
            CoreClient.get(context).status() else null
        val admittedAt = operations.operationAdmittedAt
        val deadline = operations.operationDeadline
        if (ownsCommand) {
            operations.replaceOwner(null)
            operations.command = null
            operations.operation = null
        }
        logic.cancel(run.owner)
        if (ownsCommand) {
            val processId = starting?.get(Contract.CORE_FIELD_PROCESS_ID) as? String
            val inputId = starting?.get(Contract.CORE_FIELD_INPUT_ID) as? String
            if (processId != null && inputId != null && admittedAt != null && deadline != null) {
                native.cancelStarting(processId, inputId, admittedAt, deadline)
            }
            native.abandon(run.owner)
        }
        refreshBusy()
        notifyUi()
        return current
    }
}
