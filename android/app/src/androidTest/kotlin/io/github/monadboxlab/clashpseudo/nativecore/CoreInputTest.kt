package io.github.monadboxlab.clashpseudo.nativecore

import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CoreInputTest {
    private fun input(): JSONObject = JSONObject()
        .put("id", "main").put("revision", 3).put("name", "Loaded main").put("mode", "rule")
        .put("body", "﻿rules:\r\n - MATCH,DIRECT\r\n")
        .put("choices", JSONObject())
        .put("access", "all").put("packages", JSONArray())
        .put("overrides", JSONArray().put(JSONObject().put("id", "part")
            .put("revision", 2).put("name", "Loaded plugin").put("role", "localCustom")
            .put("mode", "replace").put("body", "dns: {}")))
        .put("composition", "[\"main\",3,[\"part\",2,\"replace\"]]")

    private fun read(value: JSONObject, mode: String? = "rule", revision: Int = 3): CoreInput {
        val file = File.createTempFile("composition-test-", ".json",
            InstrumentationRegistry.getInstrumentation().targetContext.cacheDir)
        try {
            file.writeText(value.toString(), Charsets.UTF_8)
            return CoreInput.read(file, "main", revision, mode)
        } finally { file.delete() }
    }

    @Test fun preservesUtf8AndChecksEveryEnabledFragmentIdentity() {
        val value = input()
        val actual = read(value)
        assertEquals(value.getString("body"), actual.body.toString(Charsets.UTF_8))
        assertEquals(value.getString("composition"), actual.composition)
        val fragments = JSONArray(actual.overrides.toString(Charsets.UTF_8))
        assertEquals("dns: {}", fragments.getJSONObject(0).getString("body"))
    }

    @Test fun validApplicationPoliciesPreserveTheirExplicitLists() {
        for (access in listOf("all", "only", "except")) {
            val actual = read(input().put("access", access)
                .put("packages", JSONArray().put("fixture.alpha").put("fixture.beta")))
            assertEquals(access, actual.access)
            assertEquals(listOf("fixture.alpha", "fixture.beta"), actual.packages)
        }
        assertEquals(emptyList<String>(), read(input()).packages)
        assertEquals(emptyList<String>(), read(input().put("access", "except")).packages)
    }

    @Test fun nullFallbackAndActualRoutingOverrideAreDistinctAndPreserveSourceMetadata() {
        val value = input().put("mode", JSONObject.NULL).put("routingOverride", "direct")
        val actual = read(value, null)
        assertNull(actual.mode)
        assertEquals("direct", actual.routingOverride)
        assertEquals("Loaded main", actual.name)
        val snapshot = JSONObject(actual.snapshotBytes().toString(Charsets.UTF_8))
        assertTrue(snapshot.has("mode") && snapshot.isNull("mode"))
        assertEquals("direct", snapshot.getString("routingOverride"))
        assertEquals("Loaded plugin", snapshot.getJSONArray("overrides").getJSONObject(0).getString("name"))
        assertEquals("localCustom", snapshot.getJSONArray("overrides").getJSONObject(0).getString("role"))
        value.getJSONArray("overrides").getJSONObject(0).put("role", JSONObject.NULL)
        assertTrue(JSONObject(read(value, null).snapshotBytes().toString(Charsets.UTF_8))
            .getJSONArray("overrides").getJSONObject(0).isNull("role"))
    }

    @Test fun coercivePlatformGetIntCannotAliasFractionalOrWrappedRevisionIdentities() {
        fun reject(value: JSONObject, revision: Int) {
            try { read(value, revision = revision); fail("Malformed revision was accepted") }
            catch (error: IllegalStateException) { assertEquals("Invalid revision", error.message) }
        }
        // Android org.json getInt coerces these values to aliased Ints; admission
        // validates the original numeric identity.
        val fraction = input().put("revision", 1.5)
            .put("composition", "[\"main\",1,[\"part\",2,\"replace\"]]")
        assertEquals(1, fraction.getInt("revision"))
        reject(fraction, 1)
        val wrapped = input().put("revision", 4294967297L)
            .put("composition", "[\"main\",1,[\"part\",2,\"replace\"]]")
        assertEquals(1, wrapped.getInt("revision"))
        reject(wrapped, 1)
        val partFraction = input()
        partFraction.getJSONArray("overrides").getJSONObject(0).put("revision", 2.5)
        assertEquals(2, partFraction.getJSONArray("overrides").getJSONObject(0).getInt("revision"))
        reject(partFraction, 3)
        val partWrapped = input().put("composition", "[\"main\",3,[\"part\",1,\"replace\"]]")
        partWrapped.getJSONArray("overrides").getJSONObject(0).put("revision", 4294967297L)
        assertEquals(1, partWrapped.getJSONArray("overrides").getJSONObject(0).getInt("revision"))
        reject(partWrapped, 3)
        reject(input().put("revision", "3"), 3)
        val partString = input()
        partString.getJSONArray("overrides").getJSONObject(0).put("revision", "2")
        reject(partString, 3)
    }

    @Test fun fullLargeCompositionFailsClosedAndCurrentIntMaximumRemainsValid() {
        // Retain the full composition to exercise the large revision's rejection path.
        val large = input().put("revision", 4294967297L)
            .put("composition", "[\"main\",4294967297,[\"part\",2,\"replace\"]]")
        try { read(large, revision = 1); fail("Out-of-range full revision was accepted") }
        catch (error: IllegalStateException) { assertEquals("Invalid revision", error.message) }
        val largePart = input().put("composition", "[\"main\",3,[\"part\",4294967297,\"replace\"]]")
        largePart.getJSONArray("overrides").getJSONObject(0).put("revision", 4294967297L)
        try { read(largePart); fail("Out-of-range full plugin revision was accepted") }
        catch (error: IllegalStateException) { assertEquals("Invalid revision", error.message) }
        val boundary = input().put("revision", Int.MAX_VALUE)
            .put("composition", "[\"main\",${Int.MAX_VALUE},[\"part\",${Int.MAX_VALUE},\"replace\"]]")
        boundary.getJSONArray("overrides").getJSONObject(0).put("revision", Int.MAX_VALUE)
        val actual = read(boundary, revision = Int.MAX_VALUE)
        assertEquals(Int.MAX_VALUE, actual.revision)
        assertEquals(Int.MAX_VALUE, JSONArray(actual.overrides.toString(Charsets.UTF_8)).getJSONObject(0).getInt("revision"))
    }

    @Test fun mismatchedOrIncompleteInputIsRejected() {
        val mutations: List<(JSONObject) -> Unit> = listOf(
            { it.put("id", "other") },
            { it.put("revision", 4) },
            { it.put("mode", "global") },
            { it.remove("mode") },
            { it.remove("name") },
            { it.put("name", 3) },
            { it.put("name", " ") },
            { it.put("routingOverride", "follow") },
            { it.getJSONArray("overrides").getJSONObject(0).remove("name") },
            { it.getJSONArray("overrides").getJSONObject(0).put("name", 3) },
            { it.getJSONArray("overrides").getJSONObject(0).remove("role") },
            { it.getJSONArray("overrides").getJSONObject(0).put("role", "unknown") },
            { it.remove("access") },
            { it.put("access", JSONObject.NULL) },
            { it.put("access", false) },
            { it.put("access", 1) },
            { it.put("access", JSONObject()) },
            { it.put("access", JSONArray()) },
            { it.put("access", "unknown") },
            { it.remove("packages") },
            { it.put("packages", JSONObject.NULL) },
            { it.put("packages", "[]") },
            { it.put("packages", JSONObject()) },
            { it.put("packages", false) },
            { it.put("packages", 1) },
            { it.put("packages", JSONArray().put("")) },
            { it.put("packages", JSONArray().put(" fixture.alpha")) },
            { it.put("packages", JSONArray().put(17)) },
            { it.put("packages", JSONArray().put(true)) },
            { it.put("packages", JSONArray().put(JSONObject.NULL)) },
            { it.put("packages", JSONArray().put(" ")) },
            { it.put("packages", JSONArray().put("same").put("same")) },
            { it.put("access", "only") },
            { it.remove("composition") },
            { it.remove("overrides") },
            { it.put("composition", "[\"main\",3]") },
            { it.getJSONArray("overrides").getJSONObject(0).put("revision", 3) },
            { it.getJSONArray("overrides").getJSONObject(0).put("mode", "unknown") },
            { it.getJSONArray("overrides").put(it.getJSONArray("overrides").getJSONObject(0)) },
        )
        mutations.forEachIndexed { index, mutate ->
            val value = input()
            mutate(value)
            try { read(value); fail("Mutation $index was accepted") }
            catch (_: Exception) { }
        }
    }
}
