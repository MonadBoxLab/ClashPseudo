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

/** 登记Android定时任务；Dart保存更新设置并执行下载。 */
object ScheduleManager {
    private const val PREFS = "update-schedules"
    private fun name(kind: String, id: String) = "update-$kind-$id"

    /** 在后台线程更新指定类别的任务；恢复备份时更新全部任务。 */
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
        // 所有WorkManager操作完成后，再移除已取消任务的名称。
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

    /** 在后台线程按已保存设置协调定时更新；业务执行者忙碌时由Worker重试。 */
    fun reconcile(context: Context) {
        val manager = WorkManager.getInstance(context)
        val input = Data.Builder().putBoolean("reconcile", true).build()
        val request = OneTimeWorkRequestBuilder<ScheduleWorker>().setInputData(input).build()
        manager.enqueueUniqueWork("update-reconcile", ExistingWorkPolicy.KEEP, request).result.get()
        manager.getWorkInfosForUniqueWork("update-reconcile").get()
            .filter { it.id != request.id && it.state == WorkInfo.State.ENQUEUED }
            .forEach { pending ->
                // KEEP沿用旧任务时，updateWork重新登记调度并保留其重试次数和入队时间。
                manager.updateWork(OneTimeWorkRequestBuilder<ScheduleWorker>()
                    .setId(pending.id).setInputData(input).build()).get()
            }
    }

    private data class Schedule(val kind: String, val id: String, val hours: Long)
}
