package io.github.monadboxlab.clashpseudo.vpn.network

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

/** The system network captured for this preparation; callbacks do not read later network snapshots. */
internal data class UnderlyingSnapshot(val network: Network?, val servers: List<String>,
    val privateDns: String, val revision: Long,
    val privateDnsServerName: String? = null,
    val isPrivateDnsActive: Boolean = false,
) {
    val id: String get() = network?.networkHandle?.toString().orEmpty()
    val key: String get() = "$id|$privateDns|${privateDnsServerName.orEmpty()}|$isPrivateDnsActive|${servers.sorted().distinct().joinToString(",")}"
    fun json(): JSONObject = JSONObject().put("id", id).put("servers", JSONArray(servers))
        .put("privateDns", privateDns).put("privateDnsServerName", privateDnsServerName ?: JSONObject.NULL)
        .put("isPrivateDnsActive", isPrivateDnsActive).put("revision", revision)
        .put("apiLevel", Build.VERSION.SDK_INT).put("key", key)

    fun bindSocket(fd: Int, handle: String = id): Boolean {
        if (fd < 0 || handle != id) return false
        val target = network ?: return false
        val descriptor = ParcelFileDescriptor.adoptFd(fd)
        return try { target.bindSocket(descriptor.fileDescriptor); true }
        finally { descriptor.detachFd() }
    }
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
            val next = UnderlyingSnapshot(selected, dns, privateDns, old.revision + 1,
                if (Build.VERSION.SDK_INT >= 28) properties?.privateDnsServerName else null,
                Build.VERSION.SDK_INT >= 28 && properties?.isPrivateDnsActive == true)
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
