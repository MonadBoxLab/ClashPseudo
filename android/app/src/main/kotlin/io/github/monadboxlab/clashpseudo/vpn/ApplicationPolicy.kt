package io.github.monadboxlab.clashpseudo.vpn

import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.nativecore.NativePreparationFailure
import io.github.monadboxlab.clashpseudo.nativecore.vpn.VpnPacketFilter

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
