package io.github.monadboxlab.clashpseudo.vpn

import io.github.monadboxlab.clashpseudo.nativecore.NativePreparationFailure
import io.github.monadboxlab.clashpseudo.nativecore.vpn.VpnPacketFilter
import org.junit.Assert.*
import org.junit.Test

class VpnProjectionTest {
    private val apps = listOf(PackageUid("one", 10001), PackageUid("shared", 10001),
        PackageUid("two", 10002), PackageUid("system.nonlauncher", 1000), PackageUid("other.user", 110001))
    private fun filter(configured: Boolean = true, include: List<String> = emptyList(), exclude: List<String> = emptyList(),
        includeUid: List<Long> = emptyList(), excludeUid: List<Long> = emptyList(),
        includeRange: List<String> = emptyList(), excludeRange: List<String> = emptyList(), users: List<Int> = emptyList()) =
        VpnPacketFilter(configured, include, exclude, includeUid, excludeUid, includeRange, excludeRange, users)

    @Test fun explicitEmptyConfigurationClearsSavedAllowRestriction() {
        val result = resolveApplicationPolicy(filter(), "only", listOf("one"), apps, 0)
        assertEquals("all", result.access)
        assertTrue(result.packages.isEmpty())
    }

    @Test fun missingConfigurationLayerUsesSavedPreferenceAndExpandsSharedUid() {
        val result = resolveApplicationPolicy(filter(configured = false), "only", listOf("one", "missing"), apps, 0)
        assertEquals("only", result.access)
        assertEquals(listOf("one", "shared"), result.packages)
        assertTrue(result.missing)
    }

    @Test fun configuredIncludesExcludeSharedUidBeforeSelectingSingleBuilderMode() {
        val result = resolveApplicationPolicy(filter(include = listOf("one", "two"), exclude = listOf("shared")),
            "except", listOf("two"), apps, 0)
        assertEquals("only", result.access)
        assertEquals(listOf("two"), result.packages)
    }

    @Test fun configurationExclusionExpandsSharedUidWithoutMixingAllowedMode() {
        val result = resolveApplicationPolicy(filter(exclude = listOf("shared", "missing")), "only", listOf("two"), apps, 0)
        assertEquals("except", result.access)
        assertEquals(listOf("one", "shared"), result.packages)
        assertTrue(result.missing)
    }

    @Test fun uidAndRangesOnlyMapActuallyEnumerablePackages() {
        val result = resolveApplicationPolicy(filter(includeUid = listOf(1000), includeRange = listOf("10001:10009"),
            excludeUid = listOf(10002)), "all", emptyList(), apps, 0)
        assertEquals(listOf("one", "shared", "system.nonlauncher"), result.packages)
        assertEquals("only", result.access)
    }

    @Test fun includeCurrentUserEnumeratesCurrentPackagesAndNeverAnotherUser() {
        val result = resolveApplicationPolicy(filter(users = listOf(0), excludeRange = listOf("1000:1000")),
            "all", emptyList(), apps, 0)
        assertEquals(listOf("one", "shared", "two"), result.packages)
    }

    @Test fun emptyEffectiveIncludeNeverFallsBackToAll() {
        for (value in listOf(filter(include = listOf("missing")), filter(includeUid = listOf(99999)),
            filter(include = listOf("one"), exclude = listOf("shared")))) {
            assertThrows(MissingAllowedApplications::class.java) {
                resolveApplicationPolicy(value, "all", emptyList(), apps, 0)
            }
        }
        assertThrows(MissingAllowedApplications::class.java) {
            resolveApplicationPolicy(filter(configured = false), "only", listOf("missing"), apps, 0)
        }
    }

    @Test fun nonCurrentUserRequestsReturnStructuredPlatformLimitWithoutValues() {
        for ((value, field) in listOf(filter(users = listOf(1)) to "tun.include-android-user",
            filter(includeUid = listOf(110001)) to "tun.include-uid",
            filter(excludeRange = listOf("1000:110001")) to "tun.exclude-uid-range")) {
            val failure = assertThrows(NativePreparationFailure::class.java) {
                resolveApplicationPolicy(value, "all", emptyList(), apps, 0)
            }
            val detail = failure.detail!!.toMap()
            assertEquals("nativeConfigurationUnsupported", detail["id"])
            val args = detail["args"] as Map<*, *>
            assertEquals(field, args["field"])
            assertEquals("nativeReasonAndroidUserUnavailable", (args["reason"] as Map<*, *>)["id"])
            assertFalse(detail.toString().contains("110001"))
        }
    }

    @Test fun malformedRangesAreRejectedRatherThanRemovingTheRestriction() {
        for (range in listOf("10001", ":10001", "10002:10001", "-1:10001", "0:4294967296")) {
            assertThrows(RuntimeException::class.java) {
                resolveApplicationPolicy(filter(includeRange = listOf(range)), "all", emptyList(), apps, 0)
            }
        }
    }
}
