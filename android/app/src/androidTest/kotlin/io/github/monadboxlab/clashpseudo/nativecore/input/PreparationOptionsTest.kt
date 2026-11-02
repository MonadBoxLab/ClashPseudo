package io.github.monadboxlab.clashpseudo.nativecore.input

import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.nativecore.CoreFrames
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CoreParts
import io.github.monadboxlab.clashpseudo.nativecore.CoreTransportException
import java.io.ByteArrayOutputStream
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

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
        val encoded = value.preparationOptions("RUNNING", 10, JSONObject())
        assertTrue(encoded.size > 64 * 1024)
        val decoded = JSONObject(encoded.toString(Charsets.UTF_8))
        assertEquals(composition, decoded.getString("composition"))
        assertEquals(4098, JSONArray(decoded.getString("composition")).length())
        assertEquals(name, decoded.getJSONObject("mainOrigin").getString("name"))
        assertEquals(7, decoded.getJSONObject("mainOrigin").getInt("revision"))
        assertEquals("main", decoded.getJSONObject("mainOrigin").getString("id"))
        assertEquals(10L, decoded.getLong("generation"))
        assertEquals("RUNNING", decoded.getString("purpose"))
        assertEquals("rules: [MATCH,DIRECT]", value.body.toString(Charsets.UTF_8))
    }

    @Test fun exactUtf8JsonBoundaryIsAllowedAndNextByteIsRejected() {
        val maximum = CoreInput.MAX_PREPARATION_OPTIONS_BYTES
        val overhead = input("").preparationOptions("PREVIEW", 1, JSONObject()).size
        val composition = "x".repeat(maximum - overhead)
        assertEquals(maximum, input(composition).preparationOptions("PREVIEW", 1, JSONObject()).size)
        try {
            input(composition + "x").preparationOptions("PREVIEW", 1, JSONObject())
            fail("超过预算的一个 encoded byte 被受理")
        } catch (expected: IllegalStateException) {
            assertEquals("Native preparation options exceed UTF-8 JSON limit", expected.message)
        }
    }

    @Test fun encodedExpansionNotCharacterCountDeterminesAdmission() {
        val maximum = CoreInput.MAX_PREPARATION_OPTIONS_BYTES
        val overhead = input("").preparationOptions("RUNNING", 1, JSONObject()).size
        for (unit in listOf("界", "🌐", "\u0000", "\"", "\\", "/")) {
            val width = input(unit).preparationOptions("RUNNING", 1, JSONObject()).size - overhead
            val count = (maximum - overhead) / width
            assertTrue(input(unit.repeat(count)).preparationOptions("RUNNING", 1, JSONObject()).size <= maximum)
            try {
                input(unit.repeat(count + 1)).preparationOptions("RUNNING", 1, JSONObject())
                fail("encoded expansion 超过预算仍被受理")
            } catch (expected: IllegalStateException) {
                assertEquals("Native preparation options exceed UTF-8 JSON limit", expected.message)
            }
        }
    }

    @Test fun optionsOverflowIsRejectedBeforeNativeLoadOnWriteAndRead() {
        CoreIpcTestDriver.assertNoGoInApplication()
        val parts = mapOf(Contract.CORE_PART_REQUEST to "{}".toByteArray(),
            Contract.CORE_PART_OPTIONS to ByteArray(CoreInput.MAX_PREPARATION_OPTIONS_BYTES + 1) { 32 })
        val rejected = ByteArrayOutputStream()
        val writeError = assertThrows(CoreTransportException::class.java) { CoreParts.write(rejected, parts) }
        assertEquals(Contract.CORE_ERROR_INPUT_TOO_LARGE, writeError.code)
        assertEquals(0, rejected.size())
        val wire = ByteArrayOutputStream()
        CoreFrames.write(wire, CoreFrames.Frame(Contract.CORE_IPC_FRAME_METADATA,
            JSONObject().put("part", Contract.CORE_PART_OPTIONS)
                .put("bytes", CoreInput.MAX_PREPARATION_OPTIONS_BYTES + 1).toString().toByteArray()))
        val readError = assertThrows(CoreTransportException::class.java) { CoreParts.read(wire.toByteArray().inputStream()) }
        assertEquals(Contract.CORE_ERROR_INPUT_TOO_LARGE, readError.code)
        CoreIpcTestDriver.assertNoGoInApplication()
    }

    @Test fun exactOptionsBoundaryRoundTripsAcrossFramesWithoutEnteringGo() {
        CoreIpcTestDriver.assertNoGoInApplication()
        val options = ByteArray(CoreInput.MAX_PREPARATION_OPTIONS_BYTES) { 32 }
        options[options.size - 2] = 123
        options[options.size - 1] = 125
        val request = "{}".toByteArray()
        val wire = ByteArrayOutputStream()
        CoreParts.write(wire, linkedMapOf(Contract.CORE_PART_REQUEST to request, Contract.CORE_PART_OPTIONS to options))
        val result = CoreParts.read(wire.toByteArray().inputStream())
        assertEquals(setOf(Contract.CORE_PART_REQUEST, Contract.CORE_PART_OPTIONS), result.keys)
        assertArrayEquals(request, result.getValue(Contract.CORE_PART_REQUEST))
        assertArrayEquals(options, result.getValue(Contract.CORE_PART_OPTIONS))
        assertEquals(0, JSONObject(result.getValue(Contract.CORE_PART_OPTIONS).toString(Charsets.UTF_8)).length())
        CoreIpcTestDriver.assertNoGoInApplication()
    }
}
