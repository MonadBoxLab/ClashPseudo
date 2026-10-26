package io.github.monadboxlab.clashpseudo.nativecore

import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.app.AppStrings
import io.github.monadboxlab.clashpseudo.app.AppMessage
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.app.AppTrust
import io.github.monadboxlab.clashpseudo.nativecore.BundledGeo
import android.content.Context
import org.json.JSONObject
import org.json.JSONArray
import java.io.File
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import io.github.monadboxlab.clashpseudo.vpn.UnderlyingNetworks
import io.github.monadboxlab.clashpseudo.vpn.UnderlyingSnapshot
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.annotation.Keep
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Owns one loaded configuration, separately from the VPN/TUN lifecycle. */
class CoreHost(
    private val session: NativeSession,
    private val changed: () -> Unit,
    val worker: Executor = Executors.newSingleThreadExecutor { task -> Thread(task, "pseudo-native") },
    private val idleMs: Long = 30000,
    private val prepareNative: (String, ByteArray, String, Any, ByteArray, ByteArray) -> String =
        { home, body, mode, protector, choices, overrides ->
            initializeAndroidTrust()
            NativeCore.prepare(home, body, mode, protector, choices, overrides)
        },
    private val stopNative: () -> String = { NativeCore.stop() },
    private val cancelNative: () -> Unit = { NativeCore.cancel() },
    private val readLogWindow: () -> String? = { null },
    private val bindUnderlying: (Int) -> Boolean = { UnderlyingNetworks.bindSocket(it) },
    private val requestRuntimeRefresh: (Long, Long, String, Long, String) -> Unit = AppBridge::requestRuntimeRefresh,
    private val updateNativeNetwork: (ByteArray) -> String = NativeCore::updateNetwork,
) {
    enum class Phase { EMPTY, LOADING, READY, RELEASING, FAILED }
    enum class Purpose { PREVIEW, VPN }
    data class Snapshot(
        val generation: Long = 0,
        val phase: Phase = Phase.EMPTY,
        val purpose: Purpose? = null,
        val configId: String? = null,
        val revision: Int? = null,
        val error: AppMessage? = null,
        val composition: String? = null,
        val logWindow: String? = null,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "generation" to generation, "phase" to phase.name, "purpose" to purpose?.name,
            "configId" to configId, "revision" to revision, "error" to error?.toMap(),
            "composition" to composition, "logWindow" to logWindow,
        )
    }

    private class Lease(val state: Snapshot, val owner: String?, val vpnGeneration: Long?,
                        private val session: NativeSession, private val host: CoreHost) :
        NativeCore.PreparationCallbacks, BundledGeo.Owner {
        val active = AtomicBoolean(true)
        var protector: Any? = null
        var home: String = ""
        var input: CoreInput? = null
        var options: ByteArray = ByteArray(0)
        var routeRevision = 1L
        var routesNeedRefresh = false
        var networkRevision = 0L
        var systemDnsNeedsRefresh = false
        var dispatchedRouteRevision = 0L
        var dispatchedNetworkRevision = 0L
        override fun preparationOptions(): ByteArray = options

        @Keep override fun protectSocket(fd: Int): Boolean {
            if (!active.get()) return false
            val service = protector as? PseudoVpnService
            return if (service != null) service.protectSocket(fd)
                else session.snapshot().phase == NativeSession.Phase.STOPPED && host.bindUnderlying(fd)
        }

        @Keep override fun protectSocketOnNetwork(fd: Int, handle: String): Boolean {
            if (!active.get()) return false
            val service = protector as? PseudoVpnService
            return if (service != null) service.protectSocketOnNetwork(fd, handle)
                else session.snapshot().phase == NativeSession.Phase.STOPPED && UnderlyingNetworks.bindSocket(fd, handle)
        }

        override fun checkCurrent() = synchronized(host) {
            check(active.get() && host.lease === this && host.state.generation == state.generation &&
                host.state.composition == input?.composition) { "Geo installation preparation was cancelled" }
        }
        override fun publishIfCurrent(block: () -> Unit) = synchronized(host) { checkCurrent(); block() }

        @Keep override fun seedGeo(request: String): String = try {
            checkCurrent()
            val values = JSONArray(request)
            val requests = (0 until values.length()).map { index ->
                val item = values.getJSONObject(index)
                val kind = BundledGeo.Kind.entries.single { it.geoxKey == item.getString("kind") }
                BundledGeo.Request(kind, item.getString("targetName"))
            }
            BundledGeo(androidContext()).install(File(home), requests, this)
            checkCurrent()
            ""
        } catch (_: Exception) { "Bundled Geo initialization failed or its preparation was cancelled" }

        @Keep override fun specificationChanged(generation: Long, composition: String, revision: Long, needed: Boolean) {
            synchronized(host) {
                if (!active.get() || host.lease !== this || vpnGeneration == null ||
                    generation != state.generation || composition != input?.composition || revision <= routeRevision) return
                routeRevision = revision
                routesNeedRefresh = needed
            }
            if (needed) host.postRuntimeRefresh(this, "routes")
        }
    }

    private val main = Handler(Looper.getMainLooper())
    @Volatile private var state = Snapshot()
    @Volatile private var lease: Lease? = null
    // Identity of the single native current/recent observation window.
    @Volatile private var retainedLogs: Snapshot? = null

    fun logSource(): Snapshot? {
        val source = retainedLogs ?: return null
        return source.copy(phase = if (current(source.generation)) Phase.READY else Phase.EMPTY)
    }

    fun logsCurrent(generation: Long, composition: String?, window: String?): Boolean {
        val source = retainedLogs ?: return false
        return window != null && source.logWindow == window &&
            source.generation == generation && source.composition == composition
    }
    // Retain the immutable actual input for this VPN lease and its periodic updates.
    private var vpnInput: ByteArray? = null
    @Volatile private var vpnAccess: Pair<String, List<String>>? = null
    @Volatile private var vpnAccessConfigured = false

    internal fun recordApplicationAccess(generation: Long, access: String, packages: List<String>, configured: Boolean) {
        val token = lease ?: return
        check(token.active.get() && token.vpnGeneration == generation && session.canStart(generation))
        vpnAccess = access to packages.toList()
        vpnAccessConfigured = configured
    }

    /** Only the policy of the established, still-current VPN may reach the UI. */
    fun applicationAccess(generation: Long): Map<String, Any?>? {
        val loaded = lease ?: return null
        if (loaded.vpnGeneration != generation || state.purpose != Purpose.VPN || !current(state.generation)) return null
        val policy = vpnAccess ?: return null
        return mapOf("generation" to generation, "access" to policy.first, "packages" to policy.second.toMutableList(),
            "source" to if (vpnAccessConfigured) "configuration" else "preferences")
    }

    private var resourceUpdates = 0

    // Serialize admission and completion on worker. Stop may enter native immediately;
    // a lease remains reserved through its pending JNI entry.
    fun beginResourceUpdate(generation: Long, composition: String): Boolean {
        if (!current(generation) || state.composition != composition) return false
        resourceUpdates++
        return true
    }

    fun endResourceUpdate() {
        check(resourceUpdates > 0)
        resourceUpdates--
    }

    fun recordChoice(generation: Long, name: String, choice: Map<*, *>) {
        if (!current(generation) || state.purpose != Purpose.VPN) return
        val value = vpnInput?.let { org.json.JSONObject(it.toString(Charsets.UTF_8)) } ?: return
        value.getJSONObject("choices").put(name, org.json.JSONObject(choice))
        vpnInput = value.toString().toByteArray(Charsets.UTF_8)
    }
    @Volatile private var visible = false
    @Volatile private var operationBusy = false
    @Volatile private var visibilityRevision = 0L
    private var hiddenAt = SystemClock.elapsedRealtime()
    private val idle = Runnable { expirePreview() }

    fun snapshot(): Snapshot = state

    // Called on worker, like prepare/release. Return bytes rather than codec
    // strings so an original UTF-8 BOM in a body survives the bridge.
    fun runningInput(generation: Long, composition: String): ByteArray? {
        if (!current(generation) || state.purpose != Purpose.VPN ||
            state.composition != composition) return null
        return vpnInput?.copyOf()
    }

    fun current(generation: Long): Boolean {
        val loaded = lease ?: return false
        val now = state
        if (now.generation != generation || now.phase != Phase.READY || !loaded.active.get()) return false
        val vpn = session.snapshot()
        return when (now.purpose) {
            Purpose.PREVIEW -> vpn.phase == NativeSession.Phase.STOPPED
            Purpose.VPN -> vpn.phase == NativeSession.Phase.RUNNING && vpn.generation == loaded.vpnGeneration
            null -> false
        }
    }

    // These lifecycle inputs are delivered on the main thread.
    fun setVisible(value: Boolean) {
        if (visible == value) return
        visible = value
        visibilityRevision++
        if (!value) {
            hiddenAt = SystemClock.elapsedRealtime()
            try { NativeCore.cancelDnsQuery(0) } catch (_: Exception) { } catch (_: LinkageError) { }
        }
        scheduleIdle()
    }

    fun setOperationBusy(value: Boolean) {
        operationBusy = value
        scheduleIdle()
    }

    private fun scheduleIdle() {
        main.removeCallbacks(idle)
        if (visible || operationBusy || state.purpose != Purpose.PREVIEW || state.phase != Phase.READY) return
        main.postDelayed(idle, (hiddenAt + idleMs - SystemClock.elapsedRealtime()).coerceAtLeast(0))
    }

    private fun expirePreview() {
        val revision = visibilityRevision
        val generation = state.generation
        worker.execute {
            if (visible || operationBusy || revision != visibilityRevision || state.generation != generation ||
                session.snapshot().phase != NativeSession.Phase.STOPPED) return@execute
            releasePreview()
        }
    }

    // Prepare/query/change/release callers all use worker; cancellation only invalidates a lease.
    fun preparePreview(owner: String, id: String, revision: Int, home: String,
                       active: () -> Boolean, input: () -> CoreInput): Snapshot {
        check(active() && session.snapshot().phase == NativeSession.Phase.STOPPED)
        // A reused preview must match the saved fragments too, so the
        // composition is compared before the context is handed back.
        val reusableContext = state.phase == Phase.READY && state.purpose == Purpose.PREVIEW &&
            state.configId == id && state.revision == revision
        var candidate: CoreInput? = null
        if (reusableContext) {
            candidate = input()
            check(candidate.id == id && candidate.revision == revision && active())
            val loaded = lease?.input
            val reusable = loaded != null && loaded.mode == candidate.mode &&
                loaded.routingOverride == candidate.routingOverride && loaded.name == candidate.name &&
                loaded.overrides.contentEquals(candidate.overrides) && loaded.choices.contentEquals(candidate.choices)
            if (reusable && candidate.composition == state.composition && current(state.generation)) return state
        }
        return prepare(owner, id, revision, Purpose.PREVIEW, null, home,
            { active() && session.snapshot().phase == NativeSession.Phase.STOPPED }, { candidate ?: input() }, null)
    }

    fun prepareVpn(generation: Long, id: String?, revision: Int?, home: String,
                   input: () -> CoreInput, protector: Any): Snapshot =
        prepare(null, id, revision, Purpose.VPN, generation, home,
            { session.canStart(generation) }, input, protector)

    private fun prepare(owner: String?, id: String?, revision: Int?, purpose: Purpose,
                        vpnGeneration: Long?, home: String, active: () -> Boolean,
                        input: () -> CoreInput, protector: Any?): Snapshot {
        check(active() && state.phase != Phase.FAILED)
        check(resourceUpdates == 0) { "Previous resource update is still draining" }
        check(state.purpose != Purpose.VPN || state.phase == Phase.EMPTY) { "VPN context is still owned" }
        check(releaseOwned() == null) { "Previous cleanup is unconfirmed" }
        check(active())
        val loading = Snapshot(state.generation + 1, Phase.LOADING, purpose, id, revision)
        val token = Lease(loading, owner, vpnGeneration, session, this)
        lease = token
        publish(loading)
        try {
            val value = input()
            check(value.id == id && value.revision == revision)
            check(active() && token.active.get())
            publish(loading.copy(composition = value.composition))
            token.home = home
            token.input = value
            token.protector = protector
            val network = UnderlyingNetworks.snapshot()
            synchronized(this) { token.networkRevision = network.revision }
            token.options = value.preparationOptions(purpose.name, loading.generation, network.json())
            check(active() && token.active.get())
            // Bind an attempt only when the actual bounded log window changes,
            // including failed preparation.
            var knownBefore = true
            val previousWindow = try { readLogWindow() }
                catch (_: Exception) { knownBefore = false; null }
                catch (_: LinkageError) { knownBefore = false; null }
            try {
                val error = prepareNative(home, value.body, value.mode.orEmpty(), token, value.choices, value.overrides)
                if (error.isNotEmpty()) throw NativePreparationFailure.from(error)
            } finally {
                val window = try { readLogWindow() }
                    catch (_: Exception) { null }
                    catch (_: LinkageError) { null }
                if (knownBefore && window != null && window != previousWindow) {
                    retainedLogs = loading.copy(phase = Phase.EMPTY,
                        composition = value.composition, logWindow = window)
                }
            }
            return synchronized(this) {
                check(active() && token.active.get())
                vpnInput = if (purpose == Purpose.VPN) value.snapshotBytes() else null
                vpnAccess = if (purpose == Purpose.VPN) value.access to value.packages.toList() else null
                publish(loading.copy(phase = Phase.READY, composition = value.composition))
                state
            }
        } catch (error: Exception) {
            failedPreparation(token)
            throw error
        } catch (error: LinkageError) {
            failedPreparation(token)
            throw error
        }
    }

    private fun failedPreparation(token: Lease) {
        if (lease !== token) return
        if (releaseOwned() == null) {
            publish(state.copy(purpose = token.state.purpose, configId = token.state.configId,
                revision = token.state.revision, error = AppStrings.message(R.string.error_strategy_prepare)))
        }
    }

    @Synchronized
    fun cancelPreparation(owner: String) {
        val token = lease ?: return
        if (token.owner == owner && token.state.purpose == Purpose.PREVIEW) {
            token.active.set(false)
            // After a waiter expires, queue cleanup matched to the prepared owner's
            // identity.
            if (state.phase == Phase.READY) worker.execute {
                if (lease === token) releaseOwned()
            }
        }
    }

    @Synchronized
    fun cancelVpn(generation: Long) {
        val token = lease ?: return
        if (token.state.purpose == Purpose.VPN && token.vpnGeneration == generation) {
            token.active.set(false)
            cancelSafely()
        }
    }

    private fun cancelSafely() {
        try { cancelNative() } catch (_: LinkageError) { }
    }

    fun releasePreview(): AppMessage? {
        if (state.purpose != Purpose.PREVIEW) return null
        if (state.phase == Phase.EMPTY) {
            publish(Snapshot(generation = state.generation))
            return null
        }
        return releaseOwned()
    }

    fun stopVpn(generation: Long): AppMessage? {
        val token = lease ?: return null
        if (token.state.purpose != Purpose.VPN || token.vpnGeneration != generation) return null
        return releaseOwned()
    }

    private fun releaseOwned(): AppMessage? {
        vpnInput = null
        vpnAccess = null
        vpnAccessConfigured = false
        if (state.phase == Phase.FAILED) return state.error ?: AppStrings.message(R.string.error_native_release_unconfirmed)
        val token = lease ?: return null
        synchronized(this) { token.active.set(false) }
        publish(state.copy(phase = Phase.RELEASING))
        val error = try { stopNative().takeIf { it.isNotEmpty() }?.let { AppStrings.message(R.string.error_native_release_unconfirmed) } }
            catch (_: Exception) { AppStrings.message(R.string.error_native_release_unconfirmed) }
            catch (_: LinkageError) { AppStrings.message(R.string.error_native_release_unconfirmed) }
        if (error == null) {
            lease = null
            publish(Snapshot(generation = state.generation))
        } else {
            publish(state.copy(phase = Phase.FAILED, error = error))
        }
        return error
    }

    /** Worker access to the STARTING input snapshot. */
    internal fun vpnSpecification(vpnGeneration: Long): VpnSpecification {
        val token = lease ?: error("VPN preparation was released")
        check(token.active.get() && token.vpnGeneration == vpnGeneration &&
            state.phase == Phase.READY && state.purpose == Purpose.VPN && session.canStart(vpnGeneration))
        val specification = VpnSpecification.read(NativeCore.vpnSpec())
        check(specification.generation == state.generation && specification.composition == state.composition) {
            "VPN specification belongs to another preparation"
        }
        return specification
    }

    /**
     * Retain pending STARTING revisions until RUNNING, then recheck the latest tuple
     * on main-thread delivery.
     */
    fun sessionRunning(vpnGeneration: Long) {
        val token = lease ?: return
        if (token.vpnGeneration != vpnGeneration) return
        postRuntimeRefresh(token, "routes")
        postRuntimeRefresh(token, "systemDns")
    }

    private fun postRuntimeRefresh(token: Lease, reason: String) {
        main.post {
            synchronized(this) {
                if (lease !== token) return@synchronized
                val vpn = token.vpnGeneration ?: return@synchronized
                val composition = token.input?.composition ?: return@synchronized
                val revision = if (reason == "routes") token.routeRevision else token.networkRevision
                val dispatched = if (reason == "routes") token.dispatchedRouteRevision else token.dispatchedNetworkRevision
                if (revision == dispatched || !runtimeRefreshCurrent(vpn, token.state.generation, composition, revision, reason))
                    return@synchronized
                requestRuntimeRefresh(vpn, token.state.generation, composition, revision, reason)
                if (reason == "routes") token.dispatchedRouteRevision = revision
                else token.dispatchedNetworkRevision = revision
            }
        }
    }

    @Synchronized
    fun runtimeRefreshCurrent(sessionGeneration: Long, coreGeneration: Long, composition: String,
                              revision: Long, reason: String): Boolean {
        val token = lease ?: return false
        if (token.vpnGeneration != sessionGeneration || state.generation != coreGeneration ||
            state.composition != composition || !current(coreGeneration)) return false
        return when (reason) {
            "routes" -> token.routesNeedRefresh && token.routeRevision == revision
            "systemDns" -> token.systemDnsNeedsRefresh && token.networkRevision == revision
            else -> false
        }
    }

    internal fun underlyingChanged(network: UnderlyingSnapshot = UnderlyingNetworks.snapshot()) {
        val token = lease ?: return
        worker.execute {
            synchronized(this) {
                if (lease !== token || !token.active.get() || state.phase != Phase.READY ||
                    network.revision <= token.networkRevision) return@execute
            }
            val restart = try {
                JSONObject(updateNativeNetwork(network.json().toString().toByteArray(Charsets.UTF_8))).let {
                    check(it.get("changed") is Boolean && it.get("requiresRestart") is Boolean)
                    it.getBoolean("requiresRestart")
                }
            } catch (_: Exception) {
                networkUpdateFailed(token)
                return@execute
            } catch (_: LinkageError) {
                networkUpdateFailed(token)
                return@execute
            }
            synchronized(this) {
                if (lease !== token || !token.active.get()) return@execute
                token.networkRevision = network.revision
                token.systemDnsNeedsRefresh = restart
            }
            if (!restart) return@execute
            if (token.state.purpose == Purpose.PREVIEW) { releasePreview(); return@execute }
            postRuntimeRefresh(token, "systemDns")
        }
    }

    private fun networkUpdateFailed(token: Lease) {
        if (lease !== token || !token.active.get()) return
        if (token.state.purpose == Purpose.PREVIEW) {
            releasePreview()
            return
        }
        val vpn = token.vpnGeneration ?: return
        main.post {
            // Match the callback owner before stopping its preparation.
            if (lease === token && token.active.get()) {
                PseudoVpnService.instance?.nativeNetworkUpdateFailed(vpn)
            }
        }
    }

    private fun publish(value: Snapshot) {
        state = value
        main.post { changed(); scheduleIdle() }
    }

    companion object {
        @Volatile private var context: Context? = null
        fun installAndroid(appContext: Context) {
            context = appContext.applicationContext
            UnderlyingNetworks.install(appContext) {
                // The immutable platform epoch is already published. Notify now,
                // even while native DNS cancellation waits behind worker work.
                PseudoVpnService.core.changed()
                PseudoVpnService.instance?.underlyingNetworkChanged()
                PseudoVpnService.core.underlyingChanged()
            }
        }
        private fun initializeAndroidTrust() {
            try {
                val result = NativeCore.initializeTrust(AppTrust.pem(androidContext()).toByteArray(Charsets.UTF_8))
                if (result.isNotEmpty()) throw NativePreparationFailure(AppMessage("trustedRootsUnavailable"))
            } catch (error: NativePreparationFailure) { throw error }
            catch (_: Exception) { throw NativePreparationFailure(AppMessage("trustedRootsUnavailable")) }
        }
        private fun androidContext(): Context = checkNotNull(context) { "Android core environment is not initialized" }
    }
}

internal class NativePreparationFailure(val detail: AppMessage?) : IllegalStateException("Native preparation failed") {
    companion object {
        private val fields = setOf("tun", "tun.enable", "tun.stack", "tun.mtu", "tun.dns-hijack", "tun.inet6-address",
            "tun.file-descriptor", "tun.device", "tun.route-address", "tun.gso", "tun.gso-max-size", "tun.auto-redirect", "tun.strict-route",
            "tun.iproute2-table-index", "tun.iproute2-rule-index", "tun.auto-redirect-input-mark", "tun.auto-redirect-output-mark",
            "tun.auto-redirect-iproute2-fallback-rule-index", "tun.include-interface", "tun.exclude-interface",
            "tun.include-mac-address", "tun.exclude-mac-address", "tun.exclude-src-port", "tun.exclude-dst-port",
            "tun.include-android-user", "tun.include-uid", "tun.exclude-uid", "tun.include-uid-range", "tun.exclude-uid-range",
            "external-controller", "external-controller-tls", "external-controller-unix", "external-controller-pipe",
            "external-ui", "external-ui-url", "external-ui-name", "external-doh-server", "redir-port", "tproxy-port",
            "interface-name", "routing-mark", "iptables.enable", "ntp.write-to-system", "provider.path", "proxies.state-dir",
            "proxies.interface-name", "proxies.routing-mark", "proxies.tfo", "listeners.type", "listeners.routing-mark",
            "dns.listen-routing-mark", "dns.fake-ip-range6", "system-dns")
        fun from(error: String): NativePreparationFailure {
            val detail = try {
                val value = JSONObject(error)
                if (value.optString("id") != "nativeConfigurationUnsupported") null
                else value.getJSONObject("args").let {
                    val reason = it.getJSONObject("reason").getString("id")
                    check(reason in setOf("nativeReasonTunDisabled", "nativeReasonControllerUnavailable", "nativeReasonRootRedirection",
                        "nativeReasonTransparentSockets", "nativeReasonInterfaceBinding", "nativeReasonRoutingMark", "nativeReasonTcpFastOpen",
                        "nativeReasonFirewall", "nativeReasonSystemClock", "nativeReasonExternalFd", "nativeReasonInterfaceName", "nativeReasonGso",
                        "nativeReasonAutoRedirect", "nativeReasonLinuxRouting", "nativeReasonInterfaceFilter", "nativeReasonMacFilter",
                        "nativeReasonPortFilter", "nativeReasonStrictRoute", "nativeReasonDnsHijackConflict", "nativeReasonIpv6Unavailable",
                        "nativeReasonInvalidMtu", "nativeReasonInvalidAddress", "nativeReasonSystemDnsUnavailable",
                        "nativeReasonPrivateDnsUnavailable", "nativeReasonProviderPath", "nativeReasonAndroidUserUnavailable"))
                    val field = it.getString("field")
                    check(field in fields)
                    AppMessage("nativeConfigurationUnsupported", mapOf("field" to field, "reason" to AppMessage(reason)))
                }
            } catch (_: Exception) { null }
            return NativePreparationFailure(detail)
        }
    }
}
