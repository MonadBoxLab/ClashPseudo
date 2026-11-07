package io.github.monadboxlab.clashpseudo.schedule

import io.github.monadboxlab.clashpseudo.app.ScheduleWorker

import android.content.Context
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/** Register Android scheduled tasks; Dart saves update settings and performs downloads. */
object ScheduleManager {
    private const val PREFS = "update-schedules"
    private fun name(kind: String, id: String) = "update-$kind-$id"

    /** Update tasks of the specified kind on a background thread; update all tasks when restoring a backup. */
    @Synchronized
    fun sync(context: Context, targets: List<Map<*, *>>, kind: String? = null, done: () -> Unit) {
        require(kind == null || kind in setOf("config", "override"))
        val manager = WorkManager.getInstance(context)
        val desired = targets.map { target ->
            val targetKind = target["kind"] as? String
            val id = target["id"] as? String
            val hours = (target["hours"] as? Number)?.toLong()
            require(targetKind in setOf("config", "override") && !id.isNullOrBlank() &&
                hours in setOf(6L, 12L, 24L))
            require(targetKind == kind || kind == null)
            Schedule(targetKind!!, id!!, hours!!)
        }
        val names = desired.map { name(it.kind, it.id) }.toSet()
        require(names.size == desired.size)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val previous = prefs.getStringSet("active", emptySet()).orEmpty().toSet()
        val retained = if (kind == null) emptySet() else previous.filterNot {
            it.startsWith("update-$kind-")
        }.toSet()
        val next = retained + names
        // Remove cancelled task names only after all WorkManager operations finish.
        check(prefs.edit().remove("targets").putStringSet("active", previous + names).commit())
        (previous - next).forEach { manager.cancelUniqueWork(it).result.get() }
        desired.forEach { schedule ->
            val request = PeriodicWorkRequestBuilder<ScheduleWorker>(schedule.hours, TimeUnit.HOURS)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setInputData(Data.Builder().putString("kind", schedule.kind).putString("id", schedule.id).build())
                .build()
            manager.enqueueUniquePeriodicWork(name(schedule.kind, schedule.id),
                ExistingPeriodicWorkPolicy.UPDATE, request).result.get()
        }
        check(prefs.edit().putStringSet("active", next).commit())
        done()
    }

    /** Reconcile scheduled updates with saved settings on a background thread; the Worker retries while the application executor is busy. */
    fun reconcile(context: Context) {
        val manager = WorkManager.getInstance(context)
        val input = Data.Builder().putBoolean("reconcile", true).build()
        val request = OneTimeWorkRequestBuilder<ScheduleWorker>().setInputData(input).build()
        manager.enqueueUniqueWork("update-reconcile", ExistingWorkPolicy.KEEP, request).result.get()
        manager.getWorkInfosForUniqueWork("update-reconcile").get()
            .filter { it.id != request.id && it.state == WorkInfo.State.ENQUEUED }
            .forEach { pending ->
                // When KEEP retains an old task, updateWork reschedules it while preserving its attempt count and enqueue time.
                manager.updateWork(OneTimeWorkRequestBuilder<ScheduleWorker>()
                    .setId(pending.id).setInputData(input).build()).get()
            }
    }

    private data class Schedule(val kind: String, val id: String, val hours: Long)
}
