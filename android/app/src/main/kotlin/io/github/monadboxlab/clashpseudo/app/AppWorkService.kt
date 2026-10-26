package io.github.monadboxlab.clashpseudo.app

import io.github.monadboxlab.clashpseudo.bridge.AppBridge

import io.github.monadboxlab.clashpseudo.R
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.github.monadboxlab.clashpseudo.MainActivity

class AppWorkService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private var id: String? = null
    private var startId = 0
    private var finished = false
    private val deadline = Runnable {
        interrupt(AppStrings.message(R.string.error_operation_wait_timeout))
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        this.startId = startId
        if (id != null && !finished) return START_NOT_STICKY
        val owner = intent?.getStringExtra(EXTRA_OWNER)
        if (owner == null || owner != AppBridge.operationId) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        id = owner
        finished = false
        try {
            foreground()
            val remaining = AppBridge.operationRemainingMs(owner)
            if (remaining == 0L) {
                interrupt(AppStrings.message(R.string.error_operation_wait_timeout))
                return START_NOT_STICKY
            }
            main.postDelayed(deadline, remaining)
            AppBridge.logic.execute(owner, AppBridge.command ?: emptyMap()) { outcome ->
                if (id == owner) complete(outcome)
            }
        } catch (_: Exception) {
            interrupt(AppStrings.message(R.string.error_background_start))
        }
        return START_NOT_STICKY
    }

    private fun complete(outcome: Map<*, *>) {
        if (finished) return
        finished = true
        main.removeCallbacks(deadline)
        id?.let { AppBridge.finish(it, outcome) }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelfResult(startId)
    }

    private fun interrupt(message: AppMessage) {
        if (finished) return
        val workOwner = id?.takeIf { AppBridge.logic.ownsOperation(it) }
        if (workOwner != null && AppBridge.interruptBackupRestore(workOwner, message)) {
            // 超时或Service销毁撤销后续提交权；已提交结果沿实际I/O返回结算。
            main.removeCallbacks(deadline)
            return
        }
        workOwner?.let { AppBridge.logic.cancel(it) }
        complete(if (workOwner != null) mapOf("message" to message.toMap())
            else AppBridge.notExecutedResult(AppBridge.command.takeIf { AppBridge.operationId == id }, message))
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        interrupt(AppStrings.message(R.string.error_system_timeout_task))
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        interrupt(AppStrings.message(R.string.error_operation_interrupted))
        main.removeCallbacks(deadline)
        super.onDestroy()
    }

    internal fun refreshNotification() {
        if (id != null && !finished) foreground(refresh = true)
    }

    private fun foreground(refresh: Boolean = false) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel("app-work", AppStrings.get(R.string.notify_channel_work), NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "app-work") else Notification.Builder(this)
        val notification = builder.setSmallIcon(R.drawable.ic_vpn_notification)
            .setContentTitle("Clash Pseudo").setContentText(AppStrings.get(R.string.notify_working))
            .setContentIntent(open).setOngoing(true).build()
        if (refresh) manager.notify(2, notification)
        else if (Build.VERSION.SDK_INT >= 29) startForeground(2, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(2, notification)
    }

    companion object {
        const val EXTRA_OWNER = "owner"
        internal var instance: AppWorkService? = null
            private set
    }
}
