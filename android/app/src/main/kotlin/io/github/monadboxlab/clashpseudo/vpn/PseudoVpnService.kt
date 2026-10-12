package io.github.monadboxlab.clashpseudo.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.app.AppFiles
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import java.io.File
import java.util.concurrent.Executors

class PseudoVpnService : VpnService() {
    private val main = Handler(Looper.getMainLooper())
    private var generation = 0L

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val body = intent.getStringExtra(EXTRA_CONFIG)
                val configId = intent.getStringExtra(EXTRA_CONFIG_ID)
                val revision = if (intent.hasExtra(EXTRA_REVISION)) intent.getIntExtra(EXTRA_REVISION, 0) else null
                val id = session.begin(configId, revision) ?: return START_NOT_STICKY
                generation = id
                if ((body == null && configId == null) || prepare(this) != null) {
                    session.stopping(id, "VPN 授权已失效或运行输入缺失。")
                    session.finished(id, null)
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
                try {
                    showNotification("正在准备原生接管")
                } catch (error: Exception) {
                    session.stopping(id, "系统未允许显示接管通知。")
                    session.finished(id, null)
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
                worker.execute { startNative(id, body) }
            }
            ACTION_STOP -> {
                val snapshot = session.snapshot()
                if (snapshot.phase == NativeSession.Phase.STOPPED) stopSelf(startId)
                else requestStop(snapshot.generation)
            }
            else -> if (session.snapshot().phase == NativeSession.Phase.STOPPED) stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    private fun startNative(id: Long, body: String?) {
        var stage = "加载配置"
        try {
            if (!session.canStart(id)) return
            val home = AppFiles.core(this)
            check(home.isDirectory || home.mkdirs()) { "Cannot create private core directory" }
            val bytes = body?.toByteArray(Charsets.UTF_8) ?: AppFiles.runInput(this).readBytes()
            checkResult(NativeCore.prepare(home.absolutePath, bytes, this))
            if (!session.canStart(id)) return
            stage = "建立 VPN"
            val descriptor = Builder()
                .setSession("Clash Pseudo")
                .setMtu(TUN_MTU)
                .addAddress(TUN_ADDRESS, TUN_PREFIX_LENGTH)
                .addRoute("0.0.0.0", 0)
                .addDnsServer(TUN_DNS)
                .setBlocking(false)
                .establish() ?: error("VPN establishment was refused")
            stage = "接入虚拟网卡"
            // JNI takes ownership after detachFd, including native attach failures.
            descriptor.use {
                checkResult(NativeCore.attach(it.detachFd(), TUN_MTU, TUN_ADDRESS, TUN_PREFIX_LENGTH))
            }
            if (!session.attached(id)) return
            Log.i(TAG, "attached pid=${android.os.Process.myPid()} session=$id")
            main.post {
                if (session.snapshot().let { it.generation == id && it.phase == NativeSession.Phase.RUNNING }) {
                    try { showNotification("原生接管运行中") }
                    catch (_: Exception) { requestStop(id, "接管通知无法更新。") }
                }
            }
        } catch (_: Exception) {
            // Native errors may contain node credentials or provider URLs.
            Log.e(TAG, "start failed session=$id stage=$stage")
            requestStop(id, "${stage}失败，请检查配置来源与网络后重试。")
        } catch (_: LinkageError) {
            requestStop(id, "原生内核无法加载，请检查安装包。")
        } finally {
            // A stop queued during preparation runs on the same worker after this returns.
            if (session.snapshot().let { it.generation == id && it.phase == NativeSession.Phase.STOPPING }) {
                try { NativeCore.cancel() } catch (_: LinkageError) { }
            }
        }
    }

    @androidx.annotation.Keep // Called by JNI, not by Kotlin call sites.
    fun protectSocket(fd: Int): Boolean {
        val snapshot = session.snapshot()
        return snapshot.generation == generation &&
            snapshot.phase in listOf(NativeSession.Phase.STARTING, NativeSession.Phase.RUNNING) && protect(fd)
    }

    private fun requestStop(id: Long, reason: String? = null) {
        if (!session.stopping(id, reason)) return
        // Invalidate immediately; cleanup waits behind any preparation on the worker.
        try { NativeCore.cancel() } catch (_: LinkageError) { }
        worker.execute {
            val cleanupError = try { NativeCore.stop().takeIf { it.isNotEmpty() }?.let { "原生资源释放未确认。" } }
                catch (_: Exception) { "原生资源释放未确认。" }
                catch (_: LinkageError) { "原生资源释放未确认。" }
            session.finished(id, cleanupError)
            Log.i(TAG, "stop pid=${android.os.Process.myPid()} session=$id result=${session.snapshot()}")
            main.post {
                if (session.snapshot().generation == id) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
    }

    override fun onRevoke() {
        requestStop(generation, "系统已撤销 VPN")
    }

    override fun onDestroy() {
        requestStop(generation, "VPN 服务已销毁")
        super.onDestroy()
    }

    private fun showNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "网络接管", NotificationManager.IMPORTANCE_LOW))
        }
        val content = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        val notification = builder.setSmallIcon(R.drawable.ic_vpn_notification)
            .setContentTitle("Clash Pseudo").setContentText(text)
            .setContentIntent(content).setOngoing(true).build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
        } else startForeground(1, notification)
    }

    private fun checkResult(error: String) { check(error.isEmpty()) { error } }

    companion object {
        const val ACTION_START = "io.github.monadboxlab.clashpseudo.START_NATIVE"
        const val ACTION_STOP = "io.github.monadboxlab.clashpseudo.STOP_NATIVE"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_CONFIG_ID = "configId"
        const val EXTRA_REVISION = "revision"
        private const val CHANNEL = "vpn"
        private const val TAG = "PseudoVpn"
        // Builder and native stack receive the same interface parameters.
        private const val TUN_MTU = 1500
        private const val TUN_ADDRESS = "172.19.0.1"
        private const val TUN_PREFIX_LENGTH = 30
        private const val TUN_DNS = "172.19.0.2"
        val session = NativeSession()
        // Serialization outlives a Service instance; its replacement must not race old cleanup.
        private val worker = Executors.newSingleThreadExecutor { task -> Thread(task, "pseudo-native") }
    }
}
