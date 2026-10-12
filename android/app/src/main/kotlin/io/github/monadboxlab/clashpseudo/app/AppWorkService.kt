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
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.R

class AppWorkService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var id: String? = null
    private var startId = 0
    private var executed = false
    private var finished = false
    private val deadline = Runnable { complete(mapOf("message" to "操作等待超时，请核实状态后重试。")) }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (engine != null) return START_NOT_STICKY
        this.startId = startId
        id = AppBridge.operationId
        if (id == null) { stopSelf(startId); return START_NOT_STICKY }
        finished = false
        executed = false
        try {
            foreground()
            val entry = DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(), "appBackgroundMain")
            engine = (application as PseudoApplication).engines.createAndRunEngine(
                FlutterEngineGroup.Options(this).setDartEntrypoint(entry)
                    .setAutomaticallyRegisterPlugins(false))
            channel = AppBridge.attachWork(engine!!, this)
            // Covers engine startup/permission waits as well as Dart network timeouts.
            main.postDelayed(deadline, 120000)
            Log.i("PseudoWork", "engine started operation=$id")
        } catch (_: Exception) {
            complete(mapOf("message" to "无法启动后台操作，请返回应用重试。"))
        }
        return START_NOT_STICKY
    }

    fun ready(channel: MethodChannel) {
        if (executed || finished || id != AppBridge.operationId) return
        executed = true
        channel.invokeMethod("execute", AppBridge.command, object : MethodChannel.Result {
            override fun success(result: Any?) {
                complete(result as? Map<*, *> ?: mapOf("message" to "操作未返回有效结果。"))
            }
            override fun error(code: String, message: String?, details: Any?) {
                complete(mapOf("message" to "业务操作未完成，请核实状态后重试。"))
            }
            override fun notImplemented() { error("missing", null, null) }
        })
    }

    private fun complete(outcome: Map<*, *>) {
        if (finished) return
        finished = true
        main.removeCallbacks(deadline)
        id?.let { AppBridge.finish(it, outcome) }
        releaseEngine()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelfResult(startId)
    }

    private fun releaseEngine() {
        channel?.setMethodCallHandler(null)
        channel = null
        engine?.destroy()
        engine = null
        Log.i("PseudoWork", "engine released operation=$id")
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        complete(mapOf("message" to "系统结束了超时任务，请核实状态后重试。"))
    }

    override fun onDestroy() {
        if (!finished) {
            finished = true
            id?.let { AppBridge.finish(it, mapOf("message" to "操作已中断，请核实状态后重试。")) }
        }
        main.removeCallbacks(deadline)
        if (engine != null) releaseEngine()
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
