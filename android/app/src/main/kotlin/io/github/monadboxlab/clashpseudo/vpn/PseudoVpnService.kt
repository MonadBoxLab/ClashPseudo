package io.github.monadboxlab.clashpseudo.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.app.AppStrings
import io.github.monadboxlab.clashpseudo.app.AppMessage
import io.github.monadboxlab.clashpseudo.app.AppFiles
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.CoreInput
import io.github.monadboxlab.clashpseudo.nativecore.VpnPacketFilter
import io.github.monadboxlab.clashpseudo.nativecore.NativePreparationFailure

class PseudoVpnService : VpnService() {
    private val main = Handler(Looper.getMainLooper())
    private val systemStarts = SystemStartRequest()
    @Volatile private var generation = 0L
    @Volatile private var internalStop = false
    private var notificationText: Int? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        systemStarts.observeStart(startId)
        when (intent?.action) {
            // Android's Always-on start uses SERVICE_INTERFACE; a null action
            // is also accepted for a system-recreated service.
            null, SERVICE_INTERFACE -> {
                systemStart(startId)
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val body = intent.getStringExtra(EXTRA_CONFIG)
                val inputOwner = intent.getStringExtra(EXTRA_INPUT_OWNER)
                if (body == null && (inputOwner == null || inputOwner != AppBridge.operationId)) {
                    if (session.snapshot().phase == NativeSession.Phase.STOPPED && !pendingSystemStart) stopSelf(startId)
                    return START_NOT_STICKY
                }
                cancelSystemStart()
                internalStop = false
                val configId = intent.getStringExtra(EXTRA_CONFIG_ID)
                val revision = if (intent.hasExtra(EXTRA_REVISION)) intent.getIntExtra(EXTRA_REVISION, 0) else null
                val id = session.begin(configId, revision) ?: return START_NOT_STICKY
                generation = id
                if (body == null && inputOwner != AppBridge.operationId) {
                    requestStop(id)
                    return START_NOT_STICKY
                }
                systemStarts.allow()
                if ((body == null && configId == null) || prepare(this) != null) {
                    session.stopping(id, AppStrings.message(R.string.error_vpn_input_missing))
                    session.finished(id, null)
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
                try {
                    showNotification(R.string.notify_preparing)
                } catch (error: Exception) {
                    session.stopping(id, AppStrings.message(R.string.error_notification_denied))
                    session.finished(id, null)
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
                val mode = intent.getStringExtra(EXTRA_MODE)
                worker.execute { startNative(id, body, mode, inputOwner) }
            }
            ACTION_STOP -> {
                internalStop = intent.getBooleanExtra(EXTRA_INTERNAL_STOP, false)
                if (!internalStop) AppBridge.cancelRuntimeRefresh()
                cancelSystemStart(terminal = !internalStop)
                AppBridge.cancelSystemRestore()
                if (!internalStop) AppBridge.cancelScheduledOperation()
                val snapshot = session.snapshot()
                if (snapshot.phase == NativeSession.Phase.STOPPED) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf(startId)
                } else requestStop(snapshot.generation)
            }
            else -> if (session.snapshot().phase == NativeSession.Phase.STOPPED && !pendingSystemStart) stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    /**
     * Android Always-on initiates a system request. The Dart business engine writes
     * the saved selection to system input before tunnel startup.
     */
    internal fun systemStart(startId: Int, nativeSession: NativeSession = session) {
        val before = nativeSession.snapshot()
        if (before.phase == NativeSession.Phase.UNKNOWN) {
            // Retire this Service while retaining UNKNOWN until native cleanup is
            // confirmed.
            if (instance === this) {
                stopForeground(STOP_FOREGROUND_REMOVE)
                notificationText = null
                stopSelf(startId)
            }
            return
        }
        // Running/starting duplicates are already satisfied. A genuine request
        // during teardown instead owns one bounded wait, unless a user stop or
        // revoke made stopping this instance the final intent.
        val owner = systemStarts.begin(startId, before.phase) ?: return
        val deadline = android.os.SystemClock.elapsedRealtime() + 30_000L
        try {
            showNotification(R.string.notify_restoring)
        } catch (_: Exception) {
            finishSystemStart(owner, before.generation, nativeSession)
            return
        }
        fun attempt() {
            if (!systemStarts.current(owner)) return
            val waiting = nativeSession.snapshot()
            if (waiting.generation != before.generation ||
                android.os.SystemClock.elapsedRealtime() >= deadline ||
                waiting.phase !in setOf(NativeSession.Phase.STOPPED, NativeSession.Phase.STOPPING)) {
                finishSystemStart(owner, before.generation, nativeSession)
                return
            }
            if (waiting.phase == NativeSession.Phase.STOPPING ||
                core.snapshot().phase in setOf(CoreHost.Phase.LOADING, CoreHost.Phase.RELEASING)) {
                main.postDelayed({ attempt() }, 100L)
                return
            }
            AppBridge.restoreSystemStart { prepared ->
                main.post {
                    if (!systemStarts.current(owner)) return@post
                    val now = nativeSession.snapshot()
                    if (now.generation != before.generation || now.phase != NativeSession.Phase.STOPPED) {
                        finishSystemStart(owner, before.generation, nativeSession)
                        return@post
                    }
                    val start = prepared?.get("start") as? Map<*, *>
                    val configId = start?.get("id") as? String
                    val revision = (start?.get("revision") as? Number)?.toInt()
                    val mode = start?.get("mode") as? String
                    // A revoked grant requires a visible authorization flow.
                    val authorized = try { prepare(this) == null } catch (_: Exception) { false }
                    if (configId.isNullOrBlank() || revision == null || revision <= 0 ||
                        start?.containsKey("mode") != true ||
                        (mode != null && mode !in setOf("rule", "global", "direct")) || !authorized) {
                        finishSystemStart(owner, before.generation, nativeSession)
                        return@post
                    }
                    val id = nativeSession.begin(configId, revision) ?: run {
                        finishSystemStart(owner, before.generation, nativeSession)
                        return@post
                    }
                    generation = id
                    // onRevoke may run off the main thread between the owner check
                    // and begin(). An invalidated owner must also cancel that start.
                    if (systemStarts.finish(owner) == null) {
                        requestStop(id)
                        return@post
                    }
                    internalStop = false
                    worker.execute { startNative(id, null, mode, SYSTEM_INPUT) }
                }
            }
        }
        attempt()
    }

    /**
     * Release this restore owner's foreground resources while preserving the actual
     * native/VPN state.
     */
    private fun finishSystemStart(owner: Any, expectedGeneration: Long,
                                  nativeSession: NativeSession = session) {
        val startId = systemStarts.finish(owner) ?: return
        val now = nativeSession.snapshot()
        if (instance !== this || now.generation != expectedGeneration ||
            now.phase !in setOf(NativeSession.Phase.STOPPED, NativeSession.Phase.UNKNOWN)) return
        stopForeground(STOP_FOREGROUND_REMOVE)
        notificationText = null
        stopSelf(startId)
    }

    internal val pendingSystemStart: Boolean get() = systemStarts.pending()

    /**
     * Immediately invalidate pending preparation; AppBridge retains the writer until
     * execution drains.
     */
    internal fun cancelSystemStart(terminal: Boolean = false): Boolean {
        val cancelled = systemStarts.cancel(terminal) ?: return false
        val expectedGeneration = session.snapshot().generation
        main.post {
            val now = session.snapshot()
            if (instance === this && systemStarts.idle(cancelled.second) && now.generation == expectedGeneration &&
                now.phase in setOf(NativeSession.Phase.STOPPED, NativeSession.Phase.UNKNOWN)) {
                stopForeground(STOP_FOREGROUND_REMOVE)
                notificationText = null
                stopSelf(cancelled.first)
            }
        }
        return true
    }

    private fun startNative(id: Long, body: String?, mode: String?, inputOwner: String?) {
        var stage = AppStrings.message(R.string.stage_loading)
        try {
            if (!session.canStart(id)) return
            val home = AppFiles.core(this)
            check(home.isDirectory || home.mkdirs()) { "Cannot create private core directory" }
            val state = session.snapshot()
            var input: CoreInput? = null
            core.prepareVpn(id, state.configId, state.revision, home.absolutePath, {
                val value = if (body != null) CoreInput(state.configId, state.revision, mode, body.toByteArray(Charsets.UTF_8), "{}".toByteArray())
                else if (inputOwner == SYSTEM_INPUT)
                    CoreInput.read(AppFiles.systemInput(this), state.configId!!, state.revision!!, mode)
                else CoreInput.read(AppFiles.runInput(this, inputOwner!!), state.configId!!, state.revision!!, mode)
                input = value
                value
            }, this)
            if (!session.canStart(id)) return
            stage = AppStrings.message(R.string.stage_establishing)
            val specification = core.vpnSpecification(id)
            val underlying = UnderlyingNetworks.snapshot()
            check(underlying.key == specification.networkKey) { "Underlying network changed during VPN preparation" }
            val builder = Builder().setSession("Clash Pseudo").setMtu(specification.mtu).setBlocking(false)
            specification.addresses.forEach { (address, prefix) -> builder.addAddress(address, prefix) }
            specification.routes.forEach { (address, prefix) -> builder.addRoute(address, prefix) }
            specification.dnsServers.forEach(builder::addDnsServer)
            builder.setUnderlyingNetworks(underlying.network?.let { arrayOf(it) } ?: emptyArray())
            val missingApplications = applyApplicationAccess(builder, input!!, specification.filter)
            if (!session.canStart(id)) return
            check(UnderlyingNetworks.snapshot().key == underlying.key) { "Underlying network changed before VPN establishment" }
            val descriptor = builder.establish()
                ?: error("VPN establishment was refused")
            stage = AppStrings.message(R.string.stage_attaching)
            // JNI enters and validates before detaching. Kotlin still closes its
            // object if linkage/argument validation fails before the handoff.
            descriptor.use {
                check(session.canStart(id)) { "VPN startup was cancelled before descriptor handoff" }
                check(UnderlyingNetworks.snapshot().key == underlying.key) { "Underlying network changed before descriptor handoff" }
                checkResult(NativeCore.attach(it, specification.revision))
            }
            check(UnderlyingNetworks.snapshot().key == underlying.key) { "Underlying network changed before RUNNING confirmation" }
            check(session.attached(id)) { "VPN startup was cancelled before RUNNING confirmation" }
            Log.i(TAG, "attached pid=${android.os.Process.myPid()} session=$id")
            core.sessionRunning(id)
            main.post {
                underlyingNetworkChanged()
                if (instance === this && session.snapshot().let { it.generation == id && it.phase == NativeSession.Phase.RUNNING }) {
                    try {
                        showNotification(if (missingApplications)
                            R.string.notify_running_missing_apps else R.string.notify_running)
                    }
                    catch (_: Exception) { requestStop(id, AppStrings.message(R.string.error_notification_update)) }
                }
            }
        } catch (error: Exception) {
            // Native errors may contain node credentials or provider URLs.
            Log.e(TAG, "start failed session=$id stage=$stage")
            requestStop(id, if (error is NativePreparationFailure && error.detail != null) error.detail
                else if (error is MissingAllowedApplications) AppStrings.message(R.string.error_application_allowlist_missing)
                else AppStrings.message(R.string.error_stage_failed, mapOf("stage" to stage)))
        } catch (_: LinkageError) {
            requestStop(id, AppStrings.message(R.string.error_native_core_load))
        } finally {
            // A stop queued during preparation runs on the same worker after this returns.
            if (session.snapshot().let { it.generation == id && it.phase == NativeSession.Phase.STOPPING }) {
                core.cancelVpn(id)
            }
        }
    }

    /**
     * Recheck each package in Builder, including uninstall races; reject an empty
     * effective allow list.
     */
    private fun applyApplicationAccess(builder: Builder, input: CoreInput, filter: VpnPacketFilter): Boolean {
        val currentUser = android.os.Process.myUid() / ANDROID_USER_UID_RANGE
        val installed = packageManager.getInstalledApplications(0).map { PackageUid(it.packageName, it.uid.toLong()) }
        val policy = resolveApplicationPolicy(filter, input.access, input.packages, installed, currentUser)
        val missing = applyApplicationPackages(policy.access, policy.packages) { name ->
            try {
                if (policy.access == "only") builder.addAllowedApplication(name)
                else builder.addDisallowedApplication(name)
                true
            } catch (_: PackageManager.NameNotFoundException) { false }
        }
        core.recordApplicationAccess(generation, policy.access, policy.packages, filter.configured)
        return missing || policy.missing
    }

    @androidx.annotation.Keep // Called by JNI, not by Kotlin call sites.
    fun protectSocket(fd: Int): Boolean = protectSocketOnNetwork(fd, UnderlyingNetworks.snapshot().id)

    @androidx.annotation.Keep
    fun protectSocketOnNetwork(fd: Int, handle: String): Boolean {
        val snapshot = session.snapshot()
        return snapshot.generation == generation &&
            snapshot.phase in listOf(NativeSession.Phase.STARTING, NativeSession.Phase.RUNNING) && protect(fd) &&
            UnderlyingNetworks.bindSocket(fd, handle)
    }

    internal fun underlyingNetworkChanged() {
        if (instance !== this || session.snapshot().let { it.generation != generation || it.phase != NativeSession.Phase.RUNNING }) return
        val networks = UnderlyingNetworks.snapshot().network?.let { arrayOf(it) } ?: emptyArray()
        try {
            check(setUnderlyingNetworks(networks)) { "Underlying network projection was refused" }
        } catch (_: Exception) {
            requestStop(generation, AppStrings.message(R.string.error_stage_failed,
                mapOf("stage" to AppStrings.message(R.string.stage_attaching))))
        }
    }

    internal fun nativeNetworkUpdateFailed(id: Long) {
        if (instance !== this || generation != id) return
        requestStop(id, AppStrings.message(R.string.error_stage_failed,
            mapOf("stage" to AppStrings.message(R.string.stage_attaching))))
    }

    internal fun requestStop(id: Long, reason: AppMessage? = null) {
        if (!session.stopping(id, reason)) return
        // Invalidate immediately; cleanup waits behind any preparation on the worker.
        core.cancelVpn(id)
        worker.execute {
            val cleanupError = core.stopVpn(id)
            session.finished(id, cleanupError)
            Log.i(TAG, "stop pid=${android.os.Process.myPid()} session=$id result=${session.snapshot()}")
            main.post {
                if (instance === this && session.snapshot().generation == id && !pendingSystemStart) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    notificationText = null
                    stopSelf()
                }
            }
        }
    }

    override fun onRevoke() {
        if (instance !== this) return
        // Revocation supersedes reconnect through its STOPPED gap and marks subsequent
        // destruction as an explicit stop.
        internalStop = false
        cancelSystemStart(terminal = true)
        val revokedGeneration = AppBridge.revokeScheduledOperation(this) ?: return
        val cancel = Runnable {
            if (instance !== this) return@Runnable
            AppBridge.cancelRuntimeRefresh()
            AppBridge.cancelSystemRestore()
        }
        if (Looper.myLooper() == Looper.getMainLooper()) cancel.run() else main.post(cancel)
        requestStop(revokedGeneration, AppStrings.message(R.string.error_system_revoked))
    }

    override fun onCreate() {
        instance = this
        super.onCreate()
        CoreHost.installAndroid(this)
    }

    override fun onDestroy() {
        systemStarts.destroy()
        if (instance === this) {
            instance = null
            AppBridge.cancelSystemRestore()
            if (!internalStop) {
                AppBridge.cancelRuntimeRefresh()
                AppBridge.cancelScheduledOperation()
            }
            requestStop(generation, AppStrings.message(R.string.error_service_destroyed))
        }
        super.onDestroy()
    }

    internal fun refreshNotification() {
        val text = notificationText ?: return
        if (pendingSystemStart || session.snapshot().phase != NativeSession.Phase.STOPPED) {
            showNotification(text, refresh = true)
        }
    }

    private fun showNotification(text: Int, refresh: Boolean = false) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, AppStrings.get(R.string.notify_channel_vpn), NotificationManager.IMPORTANCE_LOW))
        }
        val content = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        val notification = builder.setSmallIcon(R.drawable.ic_vpn_notification)
            .setContentTitle("Clash Pseudo").setContentText(AppStrings.get(text))
            .setContentIntent(content).setOngoing(true).build()
        if (refresh) manager.notify(1, notification)
        else {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
            } else startForeground(1, notification)
            notificationText = text
        }
    }

    private fun checkResult(error: String) { check(error.isEmpty()) { error } }

    companion object {
        const val ACTION_START = "io.github.monadboxlab.clashpseudo.START_NATIVE"
        const val ACTION_STOP = "io.github.monadboxlab.clashpseudo.STOP_NATIVE"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_CONFIG_ID = "configId"
        const val EXTRA_REVISION = "revision"
        const val EXTRA_MODE = "mode"
        const val EXTRA_INPUT_OWNER = "inputOwner"
        const val EXTRA_INTERNAL_STOP = "internalReconnect"
        private const val SYSTEM_INPUT = "system"
        private const val CHANNEL = "vpn"
        private const val TAG = "PseudoVpn"
        @Volatile var instance: PseudoVpnService? = null
        fun alwaysOnState(): Boolean? = try {
            if (android.os.Build.VERSION.SDK_INT >= 29) instance?.isAlwaysOn else null
        } catch (_: Exception) { null }
        val session = NativeSession()
        // Ownership and serialization outlive a Service instance.
        val core = CoreHost(session, { AppBridge.notifyUi() }, readLogWindow = {
            // Read only one bounded row to identify the actual native buffer.
            val page = org.json.JSONObject(NativeCore.logs("{\"limit\":1}".toByteArray(Charsets.UTF_8)))
            page.optString("window").takeIf { it.isNotEmpty() }
        })
        internal val worker get() = core.worker
    }
}

/**
 * Synchronize the pending restore across main and onRevoke callback threads; it
 * belongs to one Service instance.
 */
internal class SystemStartRequest {
    private var owner: Any? = null
    private var startId = 0
    private var revision = 0L
    private var destroyed = false
    private var terminalStop = false

    @Synchronized fun allow() { terminalStop = false }

    @Synchronized fun observeStart(id: Int) {
        if (owner != null) startId = id
    }

    @Synchronized fun begin(id: Int, phase: NativeSession.Phase = NativeSession.Phase.STOPPED): Any? {
        if (destroyed || terminalStop ||
            phase !in setOf(NativeSession.Phase.STOPPED, NativeSession.Phase.STOPPING)) return null
        startId = id
        if (owner != null) return null
        revision++
        return Any().also { owner = it }
    }

    @Synchronized fun pending(): Boolean = owner != null && !destroyed
    @Synchronized fun current(token: Any): Boolean = owner === token && !destroyed

    @Synchronized fun finish(token: Any): Int? {
        if (!current(token)) return null
        owner = null
        return startId
    }

    @Synchronized fun cancel(terminal: Boolean = false): Pair<Int, Long>? {
        if (terminal) terminalStop = true
        if (owner == null) return null
        revision++
        owner = null
        return startId to revision
    }

    @Synchronized fun idle(expected: Long): Boolean =
        !destroyed && owner == null && revision == expected

    @Synchronized fun destroy() {
        destroyed = true
        owner = null
        revision++
    }
}

internal class MissingAllowedApplications : IllegalStateException()

internal const val ANDROID_USER_UID_RANGE = 100000
internal data class PackageUid(val name: String, val uid: Long)
internal data class EffectiveApplicationPolicy(val access: String, val packages: List<String>, val missing: Boolean)

/** Resolve one mode only, after current-user enumeration and shared-UID expansion. */
internal fun resolveApplicationPolicy(filter: VpnPacketFilter, savedAccess: String, savedPackages: List<String>,
    installed: List<PackageUid>, currentUser: Int): EffectiveApplicationPolicy {
    fun unavailable(field: String): Nothing = throw NativePreparationFailure(AppMessage("nativeConfigurationUnsupported",
        mapOf("field" to field, "reason" to AppMessage("nativeReasonAndroidUserUnavailable"))))
    val apps = installed.filter { it.uid / ANDROID_USER_UID_RANGE == currentUser.toLong() }
    val names = apps.associateBy { it.name }
    val uids = apps.groupBy { it.uid }
    fun ranges(values: List<String>, field: String): List<LongRange> = values.map { value ->
        val parts = value.split(':')
        check(parts.size == 2) { "Invalid UID range" }
        fun number(text: String): Long {
            val result = when {
                text.startsWith("0x", true) -> text.substring(2).toLong(16)
                text.startsWith("0") && text.length > 1 -> text.substring(1).toLong(8)
                else -> text.toLong()
            }
            check(result in 0..0xffffffffL) { "Invalid UID range" }
            return result
        }
        val start = number(parts[0]); val end = number(parts[1])
        check(start <= end) { "Reversed UID range" }
        if (start / ANDROID_USER_UID_RANGE != currentUser.toLong() || end / ANDROID_USER_UID_RANGE != currentUser.toLong()) unavailable(field)
        start..end
    }
    if (!filter.configured) {
        if (savedAccess == "all") return EffectiveApplicationPolicy("all", emptyList(), false)
        val selected = savedPackages.mapNotNull { names[it]?.uid }.toSet()
        val packages = selected.flatMap { uid -> uids[uid].orEmpty().map { it.name } }.distinct().sorted()
        if (savedAccess == "only" && packages.isEmpty()) throw MissingAllowedApplications()
        return EffectiveApplicationPolicy(savedAccess, packages, savedPackages.any { it !in names })
    }
    if (filter.includeAndroidUser.any { it != currentUser }) unavailable("tun.include-android-user")
    for ((field, values) in listOf("tun.include-uid" to filter.includeUid, "tun.exclude-uid" to filter.excludeUid)) {
        if (values.any { it < 0 || it > 0xffffffffL || it / ANDROID_USER_UID_RANGE != currentUser.toLong() }) unavailable(field)
    }
    val includeRanges = ranges(filter.includeUidRange, "tun.include-uid-range")
    val excludeRanges = ranges(filter.excludeUidRange, "tun.exclude-uid-range")
    val constrained = filter.includePackage.isNotEmpty() || filter.includeUid.isNotEmpty() || includeRanges.isNotEmpty() || filter.includeAndroidUser.isNotEmpty()
    val includes = mutableSetOf<Long>()
    val excludes = mutableSetOf<Long>()
    filter.includePackage.mapNotNullTo(includes) { names[it]?.uid }
    filter.excludePackage.mapNotNullTo(excludes) { names[it]?.uid }
    apps.forEach { app ->
        if (app.uid in filter.includeUid || includeRanges.any { app.uid in it } || currentUser in filter.includeAndroidUser) includes.add(app.uid)
        if (app.uid in filter.excludeUid || excludeRanges.any { app.uid in it }) excludes.add(app.uid)
    }
    val effective = if (constrained) includes - excludes else excludes
    val packages = effective.flatMap { uid -> uids[uid].orEmpty().map { it.name } }.distinct().sorted()
    if (constrained && packages.isEmpty()) throw MissingAllowedApplications()
    val access = if (constrained) "only" else if (packages.isEmpty()) "all" else "except"
    return EffectiveApplicationPolicy(access, packages,
        (filter.includePackage + filter.excludePackage).any { it !in names })
}

/** add returns false when PackageManager reports the package absent. */
internal fun applyApplicationPackages(access: String, packages: List<String>,
                                      add: (String) -> Boolean): Boolean {
    if (access == "all") return false
    var applied = 0
    var missing = false
    packages.forEach { name ->
        if (add(name)) applied++ else missing = true
    }
    if (access == "only" && applied == 0) throw MissingAllowedApplications()
    return missing
}
