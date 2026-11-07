package io.github.monadboxlab.clashpseudo.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.app.AppProcess
import io.github.monadboxlab.clashpseudo.app.VpnWidgetProvider
import io.github.monadboxlab.clashpseudo.message.AppStrings
import io.github.monadboxlab.clashpseudo.nativecore.CoreClient
import io.github.monadboxlab.clashpseudo.nativecore.CoreService
import io.github.monadboxlab.clashpseudo.nativecore.vpn.VpnSpecification
import io.github.monadboxlab.clashpseudo.vpn.network.UnderlyingSnapshot
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Only acquire and close VPN system resources; do not read configuration stores or run application recovery. */
class PseudoVpnService : VpnService() {
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var descriptor: ParcelFileDescriptor? = null
    private var notificationText = R.string.notify_preparing
    @Volatile private var waitingForRuntime = false
    @Volatile private var destroyed = false
    @Volatile private var resourcesClosed = false
    private var latestSystemStartId = 0
    private var coreBinding: android.content.ServiceConnection? = null

    override fun onCreate() {
        super.onCreate()
        AppProcess.requireCore(this)
        instance = this
        synchronized(hostReady) { hostReady.countDown() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (resourcesClosed || destroyed || instance !== this) return START_NOT_STICKY
        when (intent?.action) {
            ACTION_RESOURCE_HOST -> showNotification(R.string.notify_preparing)
            null, SERVICE_INTERFACE -> {
                latestSystemStartId = startId
                if (descriptor != null || waitingForRuntime || destroyed) return START_NOT_STICKY
                waitingForRuntime = true
                showNotification(R.string.notify_restoring)
                // System events only request complete input from the same AppRuntime in the default process.
                fun dispatch() {
                    CoreService.instance?.dispatchRuntime("systemStart") { accepted ->
                        if (destroyed || instance !== this || !waitingForRuntime) return@dispatchRuntime
                        waitingForRuntime = false
                        if (!accepted.getBoolean("accepted") && descriptor == null) stopResources(latestSystemStartId)
                    }
                }
                val core = CoreService.instance
                if (core != null) dispatch() else if (coreBinding == null) {
                    val connection = object : android.content.ServiceConnection {
                        override fun onServiceConnected(name: android.content.ComponentName, service: android.os.IBinder) {
                            if (!destroyed && coreBinding === this) dispatch()
                        }
                        override fun onServiceDisconnected(name: android.content.ComponentName) = Unit
                    }
                    coreBinding = connection
                    if (!bindService(Intent(this, CoreService::class.java), connection, Context.BIND_AUTO_CREATE)) {
                        coreBinding = null
                        throw IOException("Android did not establish the core system resource host connection")
                    }
                }
            }
            else -> if (descriptor == null && !waitingForRuntime) stopResources(startId)
        }
        return START_NOT_STICKY
    }

    internal fun establish(specification: VpnSpecification, access: String, packages: List<String>,
                           underlying: UnderlyingSnapshot): Pair<ParcelFileDescriptor, Map<String, Any?>> {
        check(Looper.myLooper() != Looper.getMainLooper()) { "VPN establishment must run off the main thread" }
        synchronized(this) { checkOpen() }
        check(prepare(this) == null) { "VPN authorization is no longer valid" }
        val builder = Builder().setSession("Clash Pseudo").setMtu(specification.mtu).setBlocking(false)
        specification.addresses.forEach { (address, prefix) -> builder.addAddress(address, prefix) }
        specification.routes.forEach { (address, prefix) -> builder.addRoute(address, prefix) }
        specification.dnsServers.forEach(builder::addDnsServer)
        builder.setUnderlyingNetworks(underlying.network?.let { arrayOf(it) } ?: emptyArray())
        val currentUser = android.os.Process.myUid() / ANDROID_USER_UID_RANGE
        val installed = packageManager.getInstalledApplications(0).map { PackageUid(it.packageName, it.uid.toLong()) }
        val policy = resolveApplicationPolicy(specification.filter, access, packages, installed, currentUser)
        val missing = applyApplicationPackages(policy.access, policy.packages) { name ->
            try {
                if (policy.access == "only") builder.addAllowedApplication(name) else builder.addDisallowedApplication(name)
                true
            } catch (_: PackageManager.NameNotFoundException) { false }
        }
        val acquired = synchronized(this) {
            checkOpen()
            // Closing and Builder acquisition share one gate; no native call runs under it.
            (builder.establish() ?: throw IOException("Android refused to establish the VPN")).also {
                descriptor = it
                notificationText = if (missing || policy.missing) R.string.notify_running_missing_apps else R.string.notify_running
            }
        }
        return acquired to mapOf("access" to policy.access, "packages" to policy.packages,
            "source" to if (specification.filter.configured) "configuration" else "preferences")
    }

    private fun checkOpen() {
        check(!resourcesClosed && !destroyed && instance === this && descriptor == null) {
            "VPN system resource host has ended or already holds a TUN"
        }
    }

    @Synchronized internal fun running(acquired: ParcelFileDescriptor, publish: () -> Unit) {
        check(!resourcesClosed && !destroyed && instance === this && descriptor === acquired) { "VPN attachment was closed before publication" }
        publish()
        running()
    }

    internal fun running() { main.post { if (descriptor != null) showNotification(notificationText) } }

    internal fun systemState(): Map<String, Boolean?> = mapOf(
        "alwaysOn" to if (Build.VERSION.SDK_INT >= 29) isAlwaysOn else null,
        "lockdown" to if (Build.VERSION.SDK_INT >= 29) isLockdownEnabled else null,
    )

    internal fun attach(acquired: ParcelFileDescriptor, action: () -> Unit) {
        try { action() }
        catch (error: Throwable) {
            try { closeResources(acquired) }
            catch (close: Throwable) { if (close !== error) error.addSuppressed(close) }
            throw error
        }
    }

    internal fun closeResources(expected: ParcelFileDescriptor? = null) {
        val held = synchronized(this) {
            if (expected != null && descriptor !== expected) return
            resourcesClosed = true
            waitingForRuntime = false
            descriptor.also { descriptor = null }
        }
        try { held?.close() }
        finally { main.post { if (instance === this && resourcesClosed) stopResources() } }
    }

    override fun onRevoke() {
        if (destroyed || instance !== this) { super.onRevoke(); return }
        waitingForRuntime = false
        var failure: Throwable? = null
        try { closeResources() } catch (error: Throwable) { failure = error }
        finally { CoreService.instance?.vpnRevoked(failure); super.onRevoke() }
    }

    private fun stopResources(startId: Int? = null) {
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (startId == null) stopSelf() else stopSelf(startId)
    }

    override fun onDestroy() {
        waitingForRuntime = false
        val held = synchronized(this) { destroyed = true; resourcesClosed = true; descriptor.also { descriptor = null } }
        var failure: Throwable? = null
        try { held?.close() } catch (error: Throwable) { failure = error }
        finally {
            if (held != null) CoreService.instance?.vpnRevoked(failure ?: IOException("VPN system resource host was destroyed"))
            coreBinding?.let { connection ->
                try { unbindService(connection) } catch (error: Throwable) {
                    if (failure == null) failure = error else if (failure !== error) failure!!.addSuppressed(error)
                }
            }
            coreBinding = null
            if (instance === this) instance = null
            synchronized(hostReady) { hostReady = CountDownLatch(1) }
            super.onDestroy()
        }
        failure?.let { throw it }
    }

    internal fun refreshNotification() { if (descriptor != null || waitingForRuntime) showNotification(notificationText) }

    @Synchronized private fun showNotification(text: Int) {
        if (resourcesClosed || destroyed || instance !== this) return
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(CHANNEL,
            AppStrings.get(R.string.notify_channel_vpn), NotificationManager.IMPORTANCE_LOW))
        val content = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getBroadcast(this, 1002,
            Intent(this, VpnWidgetProvider::class.java).setAction(VpnWidgetProvider.ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        val notification = builder.setSmallIcon(R.drawable.ic_vpn_notification).setContentTitle("Clash Pseudo")
            .setContentText(AppStrings.get(text)).setContentIntent(content)
            .addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(this,
                R.drawable.ic_control_disconnect), AppStrings.get(R.string.system_control_disconnect), stop).build())
            .setOngoing(true).build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
        else startForeground(1, notification)
        notificationText = text
    }

    companion object {
        const val ACTION_RESOURCE_HOST = "io.github.monadboxlab.clashpseudo.VPN_RESOURCE_HOST"
        private const val CHANNEL = "vpn"
        @Volatile var instance: PseudoVpnService? = null
            private set
        private var hostReady = CountDownLatch(1)
        internal fun awaitResourceHost(context: Context, deadline: Long = SystemClock.elapsedRealtime()) {
            instance?.let { service ->
                check(!service.resourcesClosed && !service.destroyed) { "VPN system resource host has already closed" }
                return
            }
            val intent = Intent(context, PseudoVpnService::class.java).setAction(ACTION_RESOURCE_HOST)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
            val remaining = (deadline - SystemClock.elapsedRealtime()).coerceAtLeast(0L)
            check(hostReady.await(remaining, TimeUnit.MILLISECONDS) && instance?.let { !it.resourcesClosed && !it.destroyed } == true) {
                "VPN system resource host was not acquired within the original admission deadline"
            }
        }
        val session get() = CoreClient.session
        val core get() = CoreClient.installed().view
        val worker get() = CoreClient.installed().io
        fun alwaysOnState(): Boolean? = instance?.let { if (Build.VERSION.SDK_INT >= 29) it.isAlwaysOn else null }
            ?: runCatching { CoreClient.installed().status()["alwaysOn"] as? Boolean }.getOrNull()
    }
}
