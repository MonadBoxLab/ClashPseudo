package io.github.monadboxlab.clashpseudo.nativecore

import android.os.ParcelFileDescriptor
import androidx.annotation.Keep
import org.json.JSONObject
import org.json.JSONArray

object NativeCore {
    init {
        System.loadLibrary("mihomo_bridge")
    }

    interface PreparationCallbacks {
        fun preparationOptions(): ByteArray
        @Keep fun protectSocket(fd: Int): Boolean
        @Keep fun protectSocketOnNetwork(fd: Int, handle: String): Boolean
        @Keep fun seedGeo(request: String): String
        @Keep fun specificationChanged(generation: Long, composition: String, revision: Long, needed: Boolean)
    }

    @JvmStatic external fun initializeTrust(material: ByteArray): String
    @JvmStatic external fun version(): String
    @JvmStatic external fun prepare(home: String, config: ByteArray, mode: String, protector: Any,
                                    choices: ByteArray = "{}".toByteArray(),
                                    overrides: ByteArray = "[]".toByteArray(),
                                    options: ByteArray = (protector as? PreparationCallbacks)?.preparationOptions()
                                        ?: "{\"purpose\":\"PREVIEW\"}".toByteArray()): String
    @JvmStatic external fun vpnSpec(): String
    @JvmStatic external fun updateNetwork(snapshot: ByteArray): String
    @JvmStatic external fun strategies(): String
    @JvmStatic external fun runtimeConfig(): String
    @JvmStatic external fun nodes(request: ByteArray): String
    @JvmStatic external fun rules(request: ByteArray): String
    @JvmStatic external fun resources(): String
    @JvmStatic external fun logs(request: ByteArray): String
    @JvmStatic external fun startDelayTest(request: ByteArray): String
    @JvmStatic external fun delayTest(request: ByteArray): String
    @JvmStatic external fun cancelDelayTest(request: ByteArray)
    @JvmStatic external fun updateResource(request: ByteArray): String
    @JvmStatic external fun setStrategy(request: ByteArray): String
    @JvmStatic external fun mode(): String
    @JvmStatic external fun setMode(mode: String): String
    // Kotlin retains ownership until JNI validates its arguments and calls
    // detachFd itself. LinkageError before JNI entry leaves this object owned.
    @JvmStatic external fun attach(descriptor: ParcelFileDescriptor, revision: Long): String
    @JvmStatic external fun cancel()
    @JvmStatic external fun stop(): String
    @JvmStatic external fun connections(request: ByteArray): String
    @JvmStatic external fun closeConnection(id: ByteArray): String
    @JvmStatic external fun processMemory(): String
    @JvmStatic external fun dnsQuery(request: ByteArray): String
    @JvmStatic external fun cancelDnsQuery(requestId: Long)
    @JvmStatic external fun clearDnsCache(): String
    @JvmStatic external fun flushFakeIp(): String
    @JvmStatic external fun snapshot(): String
}

internal data class VpnPacketFilter(
    val configured: Boolean,
    val includePackage: List<String>, val excludePackage: List<String>,
    val includeUid: List<Long>, val excludeUid: List<Long>,
    val includeUidRange: List<String>, val excludeUidRange: List<String>,
    val includeAndroidUser: List<Int>,
)

internal data class VpnSpecification(
    val generation: Long, val composition: String, val revision: Long, val mtu: Int,
    val addresses: List<Pair<String, Int>>, val routes: List<Pair<String, Int>>,
    val dnsServers: List<String>, val filter: VpnPacketFilter, val usesSystemDns: Boolean,
    val networkKey: String,
) {
    companion object {
        fun read(text: String): VpnSpecification {
            val value = JSONObject(text)
            check(!value.has("error")) { "VPN specification is unavailable" }
            fun strings(objectValue: JSONObject, key: String): List<String> {
                val list = objectValue.optJSONArray(key) ?: return emptyList()
                return (0 until list.length()).map { list.getString(it) }
            }
            fun longs(objectValue: JSONObject, key: String): List<Long> {
                val list = objectValue.optJSONArray(key) ?: return emptyList()
                return (0 until list.length()).map { list.getLong(it) }
            }
            fun prefixes(key: String): List<Pair<String, Int>> = strings(value, key).map {
                val slash = it.lastIndexOf('/')
                check(slash > 0) { "Invalid VPN prefix" }
                it.substring(0, slash) to it.substring(slash + 1).toInt()
            }
            val filter = value.getJSONObject("filter")
            val result = VpnSpecification(value.getLong("generation"), value.getString("composition"),
                value.getLong("revision"), value.getInt("mtu"), prefixes("addresses"), prefixes("routes"),
                strings(value, "dnsServers"), VpnPacketFilter(filter.getBoolean("configured"),
                    strings(filter, "includePackage"), strings(filter, "excludePackage"),
                    longs(filter, "includeUid"), longs(filter, "excludeUid"),
                    strings(filter, "includeUidRange"), strings(filter, "excludeUidRange"),
                    longs(filter, "includeAndroidUser").map { Math.toIntExact(it) }),
                value.getBoolean("usesSystemDns"), value.getString("networkKey"))
            check(result.generation > 0 && result.composition.isNotEmpty() && result.revision > 0 &&
                result.mtu in 1..65535 && result.addresses.isNotEmpty()) { "Invalid VPN specification" }
            return result
        }
    }
}
