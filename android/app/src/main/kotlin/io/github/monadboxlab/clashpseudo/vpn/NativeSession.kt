package io.github.monadboxlab.clashpseudo.vpn

import io.github.monadboxlab.clashpseudo.app.AppMessage
import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicReference

class NativeSession(private val clock: () -> Long = { android.os.SystemClock.elapsedRealtime() }) {
    enum class Phase { STOPPED, STARTING, RUNNING, STOPPING, UNKNOWN }
    data class Snapshot(val generation: Long, val phase: Phase, val error: AppMessage?,
        val configId: String?, val revision: Int?,
        val runningSinceElapsedMs: Long? = null, val elapsedRealtimeMs: Long = 0)
    var changed: () -> Unit = {}
    private var runningSinceElapsedMs: Long? = null
    private var configId: String? = null
    private var revision: Int? = null

    // Worker completions must match this generation before changing service state.
    private var generation = 0L
    private var phase = Phase.STOPPED
    private var error: AppMessage? = null

    @Synchronized fun begin(configId: String? = null, revision: Int? = null): Long? {
        if (phase != Phase.STOPPED) return null
        generation += 1
        phase = Phase.STARTING
        runningSinceElapsedMs = null
        error = null
        this.configId = configId
        this.revision = revision
        changed()
        return generation
    }

    @Synchronized fun canStart(id: Long) = id == generation && phase == Phase.STARTING

    @Synchronized fun attached(id: Long): Boolean {
        if (!canStart(id)) return false
        phase = Phase.RUNNING
        runningSinceElapsedMs = clock()
        changed()
        return true
    }

    @Synchronized fun stopping(id: Long, reason: AppMessage? = null): Boolean {
        if (id != generation || phase !in listOf(Phase.STARTING, Phase.RUNNING)) return false
        phase = Phase.STOPPING
        if (reason != null) error = reason
        changed()
        return true
    }

    @Synchronized fun finished(id: Long, cleanupError: AppMessage?) {
        if (id != generation || phase != Phase.STOPPING) return
        phase = if (cleanupError == null) Phase.STOPPED else Phase.UNKNOWN
        if (cleanupError != null) error = error?.let { operation ->
            AppMessage("operationAndCleanupFailed", mapOf("operation" to operation, "cleanup" to cleanupError))
        } ?: cleanupError
        if (phase == Phase.STOPPED) {
            configId = null
            revision = null
        }
        changed()
    }

    @Synchronized fun snapshot() = Snapshot(generation, phase, error, configId, revision,
        runningSinceElapsedMs.takeIf { phase == Phase.RUNNING }, clock())
}

/** Immutable platform input shared by Builder, socket binding and Go DNS. */
internal data class UnderlyingSnapshot(val network: Network?, val servers: List<String>,
    val privateDns: String, val revision: Long) {
    val id: String get() = network?.networkHandle?.toString().orEmpty()
    val key: String get() = "$id|$privateDns|${servers.sorted().distinct().joinToString(",")}"
    fun json(): JSONObject = JSONObject().put("id", id).put("servers", JSONArray(servers))
        .put("privateDns", privateDns)
}

/** Single process-lifetime observation of the underlying network. */
internal object UnderlyingNetworks {
    private val value = AtomicReference(UnderlyingSnapshot(null, emptyList(), "unavailable", 0))
    private var manager: ConnectivityManager? = null
    private val main = Handler(Looper.getMainLooper())
    private var changed: (() -> Unit)? = null
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = refresh()
        override fun onLost(network: Network) = refresh()
        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) = refresh()
        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) = refresh()
    }

    @Synchronized fun install(context: Context, onChanged: () -> Unit) {
        if (manager != null) return
        val connectivity = context.applicationContext.getSystemService(ConnectivityManager::class.java)
        manager = connectivity
        changed = onChanged
        connectivity.registerNetworkCallback(NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), callback)
        refresh()
    }

    @Synchronized private fun refresh() {
        val connectivity = manager ?: return
        val candidates = connectivity.allNetworks.filter { network ->
            connectivity.getNetworkCapabilities(network)?.let {
                it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
                    !it.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            } == true
        }
        val active = connectivity.activeNetwork
        val selected = active?.takeIf { it in candidates }
            ?: candidates.sortedWith(compareByDescending<Network> {
                connectivity.getNetworkCapabilities(it)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
            }.thenByDescending {
                connectivity.getNetworkCapabilities(it)?.let { capabilities ->
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
                } == true
            }.thenBy { it.networkHandle }).firstOrNull()
        val properties = selected?.let(connectivity::getLinkProperties)
        val dns = properties?.dnsServers?.mapNotNull { it.hostAddress }?.sorted()?.distinct().orEmpty()
        val privateDns = if (Build.VERSION.SDK_INT >= 28 && properties != null) {
            if (!properties.privateDnsServerName.isNullOrEmpty()) "strict"
            else if (properties.isPrivateDnsActive) "opportunistic" else "off"
        } else "off"
        synchronized(this) {
            val old = value.get()
            val next = UnderlyingSnapshot(selected, dns, privateDns, old.revision + 1)
            if (next.key == old.key) return
            value.set(next)
        }
        main.post { changed?.invoke() }
    }

    fun snapshot(): UnderlyingSnapshot = value.get()

    fun bindSocket(fd: Int, handle: String? = null): Boolean {
        if (fd < 0) return false
        val snapshot = value.get()
        // Retain the public Network object in the atomic snapshot on API24+. Validate
        // its handle before binding; fromNetworkHandle requires API28.
        if (handle != null && handle != snapshot.id) return false
        val network = snapshot.network ?: return false
        // Wrap the borrowed socket with adoptFd and always detach in finally; closure
        // remains with the caller.
        val descriptor = ParcelFileDescriptor.adoptFd(fd)
        return try { network.bindSocket(descriptor.fileDescriptor); true }
        catch (_: Exception) { false }
        finally { descriptor.detachFd() }
    }
}
