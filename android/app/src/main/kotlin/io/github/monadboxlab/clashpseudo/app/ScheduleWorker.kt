package io.github.monadboxlab.clashpseudo.app

import io.github.monadboxlab.clashpseudo.bridge.AppBridge

import android.content.Context
import androidx.work.Worker
import androidx.work.WorkerParameters

/**
 * Cancellation revokes the Dart owner; the writer gate remains held until the executor
 * returns. Contention receives an early retry.
 */
class ScheduleWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    override fun doWork(): Result {
        val outcome = if (inputData.getBoolean("reconcile", false)) {
            AppBridge.reconcileSchedules { isStopped }
        } else {
            val kind = inputData.getString("kind") ?: return Result.failure()
            val id = inputData.getString("id") ?: return Result.failure()
            AppBridge.runSchedule(kind, id) { isStopped }
        }
        return if (outcome["scheduleStatus"] == "busy") Result.retry() else Result.success()
    }
}
