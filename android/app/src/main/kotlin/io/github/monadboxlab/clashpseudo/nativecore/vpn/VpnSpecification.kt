package io.github.monadboxlab.clashpseudo.nativecore.vpn

import org.json.JSONObject

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
