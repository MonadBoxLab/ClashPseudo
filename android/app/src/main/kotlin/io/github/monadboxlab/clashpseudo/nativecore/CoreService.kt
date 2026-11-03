package io.github.monadboxlab.clashpseudo.nativecore

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.app.AppProcess
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.logic.AppRuntimeService
import io.github.monadboxlab.clashpseudo.message.AppStrings
import io.github.monadboxlab.clashpseudo.nativecore.ipc.ICoreCallback
import io.github.monadboxlab.clashpseudo.nativecore.ipc.ICoreService
import io.github.monadboxlab.clashpseudo.nativecore.ipc.IRuntimeCallback
import io.github.monadboxlab.clashpseudo.nativecore.ipc.IRuntimeService
import io.github.monadboxlab.clashpseudo.vpn.network.UnderlyingNetworks
import java.util.concurrent.CopyOnWriteArrayList

/** 内部 Binder 只处理小控制信息，JNI 和 FD I/O 不在 Binder 线程执行。 */
class CoreService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val callbacks = CopyOnWriteArrayList<ICoreCallback>()
    private lateinit var host: CoreHost
    private var runtime: IRuntimeService? = null
    private var runtimeBound = false
    private var lanForeground = false
    private data class RuntimeEvent(val state: Bundle, val reply: ((Bundle) -> Unit)?)
    private val runtimeEvents = ArrayDeque<RuntimeEvent>()
    private val runtimeConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            runtime = IRuntimeService.Stub.asInterface(binder)
            while (runtimeEvents.isNotEmpty()) runtimeEvents.removeFirst().let { deliverRuntime(it.state, it.reply) }
        }
        override fun onServiceDisconnected(name: ComponentName) { runtime = null }
        override fun onBindingDied(name: ComponentName) {
            runtime = null
            if (runtimeBound) unbindService(this)
            runtimeBound = bindService(Intent(this@CoreService, AppRuntimeService::class.java), this, Context.BIND_AUTO_CREATE)
        }
    }
    private val returnDocuments = ThreadLocal<MutableList<android.os.ParcelFileDescriptor>>()
    private val binder = object : ICoreService.Stub() {
        override fun onTransact(code: Int, data: android.os.Parcel, reply: android.os.Parcel?, flags: Int): Boolean {
            val documents = mutableListOf<android.os.ParcelFileDescriptor>()
            returnDocuments.set(documents)
            try { return super.onTransact(code, data, reply, flags) }
            catch (error: CoreTransportException) { throw IllegalArgumentException("${error.code}: ${error.message}", error) }
            finally { returnDocuments.remove(); documents.forEach { it.close() } }
        }
        override fun handshake(protocol: Int, callback: ICoreCallback): Bundle {
            CoreControl.sameUid()
            if (protocol != Contract.CORE_IPC_VERSION) throw IllegalArgumentException(Contract.CORE_ERROR_PROTOCOL_MISMATCH)
            val remote = callback.asBinder()
            val death = IBinder.DeathRecipient { callbacks.remove(callback) }
            remote.linkToDeath(death, 0)
            callbacks.removeAll { it.asBinder() == remote }
            callbacks.add(callback)
            return stateForBinder(host.status()).also { state ->
                (state.getParcelable("details") as? android.os.ParcelFileDescriptor)?.let { returnDocuments.get()?.add(it) }
            }
        }
        override fun status(identity: Bundle): Bundle {
            CoreControl.sameUid(); CoreControl.identity(identity, host.processId)
            val source = host.status()
            if (identity.getBoolean(PREVIEW_BACKGROUND) &&
                source.getString("purpose") == Contract.CORE_PURPOSE_PREVIEW &&
                source.getString(Contract.CORE_FIELD_PHASE) == Contract.CORE_PHASE_READY) {
                startService(Intent(this@CoreService, CoreService::class.java))
            }
            identity.getString("language")?.let { language ->
                if (AppStrings.applyLanguage(this@CoreService, language)) main.post {
                    refreshNotification(); io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService.instance?.refreshNotification()
                }
            }
            return stateForBinder(source).also { state ->
                (state.getParcelable("details") as? android.os.ParcelFileDescriptor)?.let { returnDocuments.get()?.add(it) }
            }
        }
        override fun submit(request: Bundle, input: android.os.ParcelFileDescriptor,
                            output: android.os.ParcelFileDescriptor): Bundle {
            try {
                CoreControl.sameUid()
                return host.submit(request, input, output)
            } catch (error: Throwable) {
                try { input.close() } catch (close: Throwable) { if (close !== error) error.addSuppressed(close) }
                try { output.close() } catch (close: Throwable) { if (close !== error) error.addSuppressed(close) }
                throw error
            }
        }
        override fun requestExit(request: Bundle) {
            CoreControl.sameUid()
            try { host.exit(request) }
            catch (error: LinkageError) { throw IllegalStateException("core 退出执行未完成", error) }
        }
    }

    override fun onCreate() {
        super.onCreate()
        AppProcess.requireCore(this)
        CoreProcessResources.acquire(this)
        UnderlyingNetworks.install(this) { if (::host.isInitialized) host.networkChanged() }
        instance = this
        host = retainedHost ?: CoreHost(applicationContext,
            { state -> instance?.publish(state) },
            { id, receipt -> instance?.publishExited(id, receipt) }).also { retainedHost = it }
        runtimeBound = bindService(Intent(this, AppRuntimeService::class.java), runtimeConnection, Context.BIND_AUTO_CREATE)
    }

    override fun onBind(intent: Intent?): IBinder {
        // :core 的 started lifecycle 通过现有 binding 保持 PREVIEW 空闲计时的执行机会。
        startService(Intent(this, CoreService::class.java))
        return binder
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_LAN_FOREGROUND) { lanForeground = true; showLanNotification() }
        return START_NOT_STICKY
    }

    internal fun allocateRequestId(): Long = host.allocateRequestId()

    private fun stateForBinder(source: Bundle): Bundle = Bundle(source).apply {
        val details = org.json.JSONObject()
        getString(Contract.CORE_FIELD_ERROR)?.let { text ->
            details.put(Contract.CORE_FIELD_ERROR, org.json.JSONObject(text))
            remove(Contract.CORE_FIELD_ERROR)
        }
        if (details.length() != 0) putParcelable("details", host.document(details.toString().toByteArray(Charsets.UTF_8)))
        try { CoreControl.check(this) }
        catch (error: Throwable) {
            (getParcelable("details") as? android.os.ParcelFileDescriptor)?.let { descriptor ->
                try { descriptor.close() } catch (close: Throwable) { if (close !== error) error.addSuppressed(close) }
            }
            throw error
        }
    }

    private fun publishExited(id: Long, receipt: ByteArray) {
        callbacks.forEach { callback ->
            try { host.document(receipt).use { callback.onExited(host.processId, id, it) } }
            catch (_: android.os.RemoteException) { callbacks.remove(callback) }
        }
    }

    private fun publish(state: Bundle) {
        main.post { if (lanForeground) showLanNotification() }
        callbacks.forEach { callback ->
            try {
                val control = stateForBinder(state)
                try { callback.onStatus(control) }
                finally { (control.getParcelable("details") as? android.os.ParcelFileDescriptor)?.close() }
            }
            catch (_: android.os.RemoteException) { callbacks.remove(callback) }
        }
    }

    fun dispatchRuntime(event: String, reply: ((Bundle) -> Unit)? = null) {
        main.post {
            val state = host.status().apply { putString("event", event) }
            val endpoint = runtime
            if (endpoint == null) {
                runtimeEvents.add(RuntimeEvent(state, reply))
                return@post
            }
            deliverRuntime(state, reply)
        }
    }

    private fun deliverRuntime(event: Bundle, reply: ((Bundle) -> Unit)? = null) {
        try {
            val control = stateForBinder(event)
            try { checkNotNull(runtime).dispatch(control, object : IRuntimeCallback.Stub() {
                override fun onResult(result: Bundle) {
                    CoreControl.sameUid()
                    CoreControl.check(result)
                    main.post { reply?.invoke(result) }
                }
            }) } finally { (control.getParcelable("details") as? android.os.ParcelFileDescriptor)?.close() }
        } catch (error: android.os.RemoteException) {
            runtime = null
            publish(host.status().apply { putString("runtimeError", error.toString()) })
        }
    }

    fun vpnRevoked(error: Throwable? = null) { host.revoked(error); dispatchRuntime("revoked") }

    fun refreshNotification() { if (lanForeground) showLanNotification() }

    private fun showLanNotification() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(
            CHANNEL, AppStrings.get(R.string.lan_service_channel), NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        startForeground(NOTIFICATION, NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_vpn_notification).setContentTitle(AppStrings.get(R.string.system_control_title))
                        .setContentText(AppStrings.get(when {
                host.status().getBoolean("lanRunning") -> R.string.lan_service_running
                host.status().getString("phase") == Contract.CORE_PHASE_READY -> R.string.lan_service_unavailable
                else -> R.string.lan_service_preparing
            })).setContentIntent(open)
            .setOngoing(true).setOnlyAlertOnce(true).build())
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        if (runtimeBound) unbindService(runtimeConnection)
        runtimeBound = false
        runtime = null
        callbacks.clear()
        super.onDestroy()
        // 内核资源锁保留在 CoreProcessResources，Service 销毁不释放它。
    }

    companion object {
        const val ACTION_LAN_FOREGROUND = "io.github.monadboxlab.clashpseudo.LAN_FOREGROUND"
        internal const val PREVIEW_BACKGROUND = "previewBackground"
        private const val CHANNEL = "lan-proxy"
        private const val NOTIFICATION = 4
        @Volatile private var retainedHost: CoreHost? = null
        @Volatile var instance: CoreService? = null
            private set
    }
}
