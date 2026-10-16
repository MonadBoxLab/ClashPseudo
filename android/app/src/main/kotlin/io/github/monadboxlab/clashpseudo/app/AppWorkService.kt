package io.github.monadboxlab.clashpseudo.app

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
import io.github.monadboxlab.clashpseudo.R

class AppWorkService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private var id: String? = null
    private var startId = 0
    private var finished = false
    private val deadline = Runnable {
        interrupt("操作等待超时，请核实状态后重试。")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (id != null && !finished) return START_NOT_STICKY
        this.startId = startId
        val owner = AppBridge.operationId
        id = owner
        if (owner == null) { stopSelf(startId); return START_NOT_STICKY }
        finished = false
        try {
            foreground()
            main.postDelayed(deadline, 120000)
            AppBridge.logic.execute(owner, AppBridge.command ?: emptyMap()) { outcome ->
                if (id == owner) complete(outcome)
            }
        } catch (_: Exception) {
            interrupt("无法启动后台操作，请返回应用重试。")
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

    private fun interrupt(message: String) {
        if (finished) return
        id?.let { AppBridge.logic.cancel(it) }
        complete(mapOf("message" to message))
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        interrupt("系统结束了超时任务，请核实状态后重试。")
    }

    override fun onDestroy() {
        interrupt("操作已中断，请核实状态后重试。")
        main.removeCallbacks(deadline)
        super.onDestroy()
    }

    private fun foreground() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel("app-work", "配置操作", NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "app-work") else Notification.Builder(this)
        val notification = builder.setSmallIcon(R.drawable.ic_vpn_notification)
            .setContentTitle("Clash Pseudo").setContentText("正在处理配置操作")
            .setContentIntent(open).setOngoing(true).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(2, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(2, notification)
    }
}
