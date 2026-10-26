package io.github.monadboxlab.clashpseudo.nativecore

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Tests wire construction and JNI pre-admission. */
class PreparationOptionsTest {
    private fun input(composition: String, name: String = "Controlled source") = CoreInput(
        "main", 7, null, "rules: [MATCH,DIRECT]".toByteArray(), "{}".toByteArray(),
        composition = composition, name = name,
    )

    @Test fun completeCompositionBeyond64KiBAndSourceMetadataRoundTrip() {
        val identity = JSONArray().put("main").put(7)
        repeat(4096) { index ->
            identity.put(JSONArray().put("plugin-$index-${"identity".repeat(8)}").put(index + 1).put("prepend"))
        }
        val composition = identity.toString()
        val name = "quoted \" \\ \u0000 \n 配置 🌐"
        val value = input(composition, name)
        val encoded = value.preparationOptions("VPN", 10, JSONObject())
        assertTrue(encoded.size > 64 * 1024)
        val decoded = JSONObject(encoded.toString(Charsets.UTF_8))
        assertEquals(composition, decoded.getString("composition"))
        assertEquals(4098, JSONArray(decoded.getString("composition")).length())
        assertEquals(name, decoded.getJSONObject("mainOrigin").getString("name"))
        assertEquals(7, decoded.getJSONObject("mainOrigin").getInt("revision"))
        assertEquals("main", decoded.getJSONObject("mainOrigin").getString("id"))
        assertEquals(10L, decoded.getLong("generation"))
        assertEquals("VPN", decoded.getString("purpose"))
        assertEquals("rules: [MATCH,DIRECT]", value.body.toString(Charsets.UTF_8))
    }

    @Test fun exactUtf8JsonBoundaryIsAllowedAndNextByteIsRejected() {
        val maximum = CoreInput.MAX_PREPARATION_OPTIONS_BYTES
        val overhead = input("").preparationOptions("PREVIEW", 1, JSONObject()).size
        val composition = "x".repeat(maximum - overhead)
        assertEquals(maximum, input(composition).preparationOptions("PREVIEW", 1, JSONObject()).size)
        try {
            input(composition + "x").preparationOptions("PREVIEW", 1, JSONObject())
            fail("An encoded byte beyond the limit was accepted")
        } catch (expected: IllegalStateException) {
            assertEquals("Native preparation options exceed UTF-8 JSON limit", expected.message)
        }
    }

    @Test fun encodedExpansionNotCharacterCountDeterminesAdmission() {
        val maximum = CoreInput.MAX_PREPARATION_OPTIONS_BYTES
        val overhead = input("").preparationOptions("VPN", 1, JSONObject()).size
        for (unit in listOf("界", "🌐", "\u0000", "\"", "\\", "/")) {
            val width = input(unit).preparationOptions("VPN", 1, JSONObject()).size - overhead
            val count = (maximum - overhead) / width
            assertTrue(input(unit.repeat(count)).preparationOptions("VPN", 1, JSONObject()).size <= maximum)
            try {
                input(unit.repeat(count + 1)).preparationOptions("VPN", 1, JSONObject())
                fail("Encoded expansion escaped its own limit")
            } catch (expected: IllegalStateException) {
                assertEquals("Native preparation options exceed UTF-8 JSON limit", expected.message)
            }
        }
    }

    @Test fun jniRejectsOverflowBeforeLookingUpAnyCallbackMethod() {
        val before = NativeCore.snapshot()
        // Any lacks protectSocket, so premature callback lookup throws before Go
        // admission.
        val error = NativeCore.prepare("unused", byteArrayOf(), "", Any(),
            options = ByteArray(CoreInput.MAX_PREPARATION_OPTIONS_BYTES + 1))
        assertEquals("invalid native preparation options", error)
        assertEquals(before, NativeCore.snapshot())
    }

    @Test fun jniExactBoundaryReachesCallbackValidationWithoutEnteringGo() {
        val before = NativeCore.snapshot()
        val options = ByteArray(CoreInput.MAX_PREPARATION_OPTIONS_BYTES) { 32 }
        options[options.size - 2] = 123
        options[options.size - 1] = 125
        try {
            NativeCore.prepare("unused", byteArrayOf(), "", Any(), options = options)
            fail("The exact boundary did not reach callback validation")
        } catch (_: NoSuchMethodError) {
            // Lookup is before global callback installation and CorePrepare.
        }
        assertEquals(before, NativeCore.snapshot())
    }
}
