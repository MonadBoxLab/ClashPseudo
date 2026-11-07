package io.github.monadboxlab.clashpseudo.vpn.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import io.github.monadboxlab.clashpseudo.nativecore.CoreErrors
import java.net.NetworkInterface
import java.util.Collections

/** Use public network metadata to identify types; enumerate system interfaces to include hotspot downstream and non-INTERNET interfaces. */
internal class LocalInterfaces(context: Context, private val changed: (Map<String, Any?>) -> Unit = {}) {
    private val manager = context.applicationContext.getSystemService(ConnectivityManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var installed = false
    private var active = false
    private var revision = 0L
    private var notifiedRevision = -1L
    private var notifiedError: String? = null
    private var last: List<Map<String, Any?>> = emptyList()
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = refresh()
        override fun onLost(network: Network) = refresh()
        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) = refresh()
        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) = refresh()
    }
    private val poll = object : Runnable {
        override fun run() {
            if (!active) return
            refresh()
            main.postDelayed(this, 5_000)
        }
    }

    fun setActive(value: Boolean) {
        main.post {
            if (active == value) return@post
            active = value
            if (value) {
                if (!installed) {
                    manager.registerNetworkCallback(NetworkRequest.Builder().clearCapabilities().build(), callback)
                    installed = true
                }
                main.post(poll)
            } else {
                main.removeCallbacks(poll)
                if (installed) { manager.unregisterNetworkCallback(callback); installed = false }
            }
        }
    }

    @Synchronized fun snapshot(): Map<String, Any?> {
        return try {
            val types = mutableMapOf<String, String>()
            fun collect(properties: LinkProperties, kind: String) {
                properties.interfaceName?.let { name ->
                    val old = types[name]
                    val rank = mapOf("unknown" to 0, "ethernet" to 1, "wifi" to 2, "cellular" to 3, "vpn" to 4)
                    if (old == null || rank.getValue(kind) > rank.getValue(old)) types[name] = kind
                }
            }
            manager.allNetworks.forEach { network ->
                val capabilities = manager.getNetworkCapabilities(network) ?: return@forEach
                val kind = when {
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                    else -> "unknown"
                }
                manager.getLinkProperties(network)?.let { collect(it, kind) }
            }
            val rows = (NetworkInterface.getNetworkInterfaces()?.let { Collections.list(it) } ?: emptyList()).flatMap { network ->
                val up = network.isUp
                network.interfaceAddresses.mapNotNull { assigned ->
                    val address = assigned.address ?: return@mapNotNull null
                    val text = address.hostAddress ?: return@mapNotNull null
                    val kind = if (network.isLoopback || address.isLoopbackAddress) "loopback" else types[network.name] ?: "unknown"
                    mapOf<String, Any?>("address" to text, "interfaceName" to network.name,
                        "interfaceIndex" to network.index, "prefixLength" to assigned.networkPrefixLength.toInt(),
                        "kind" to kind, "available" to up,
                        "selectable" to (up && network.index > 0 && !address.isAnyLocalAddress && kind !in setOf("vpn", "cellular", "loopback")))
                }
            }.sortedWith(compareBy({ it["interfaceName"].toString() }, { it["address"].toString() }))
            if (rows != last) { revision++; last = rows }
            mapOf("revision" to revision, "addresses" to rows)
        } catch (error: Throwable) {
            mapOf("revision" to revision, "addresses" to last, "error" to CoreErrors.json(error).toString())
        }
    }

    fun available(interfaceName: String, interfaceIndex: Int, address: String): Boolean {
        val snapshot = snapshot()
        if (snapshot["error"] != null) return false
        return (snapshot["addresses"] as? List<*>)?.any { value ->
            val row = value as? Map<*, *> ?: return@any false
            row["interfaceName"] == interfaceName && row["interfaceIndex"] == interfaceIndex &&
                row["address"] == address && row["selectable"] == true
        } == true
    }

    @Synchronized private fun refresh() {
        val value = snapshot()
        val currentRevision = value["revision"] as Long
        val error = value["error"] as? String
        if (notifiedRevision == currentRevision && notifiedError == error) return
        notifiedRevision = currentRevision
        notifiedError = error
        main.post { changed(value) }
    }

    fun close() {
        main.post {
            active = false
            main.removeCallbacks(poll)
            if (installed) { manager.unregisterNetworkCallback(callback); installed = false }
        }
    }
}
