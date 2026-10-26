package io.github.monadboxlab.clashpseudo.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class AppMessageTest {
    @Test
    fun nestedDescriptionsRoundTripWithoutDisplayText() {
        val message = AppMessage(
            "operationAndCleanupFailed",
            mapOf(
                "operation" to AppMessage("androidErrorTakeoverStartFailed"),
                "cleanup" to AppMessage("androidErrorReleaseUnconfirmed")
            )
        )
        assertEquals(message, AppMessage.fromMap(message.toMap()))
        val encoded = message.toMap()
        assertEquals("operationAndCleanupFailed", encoded["id"])
        val arguments = encoded["args"] as Map<*, *>
        assertEquals(
            mapOf("id" to "androidErrorTakeoverStartFailed", "args" to emptyMap<String, Any?>()),
            arguments["operation"]
        )
    }

    @Test
    fun namedPrimitiveArgumentsKeepTheirValues() {
        val args = mapOf("name" to "configuration", "count" to 2L, "enabled" to true)
        val message = AppMessage("sourceUsedBy", args)
        assertEquals(message, AppMessage.fromMap(message.toMap()))
        assertEquals(args, AppMessage.fromMap(message.toMap())!!.args)
    }

    @Test
    fun invalidProtocolDoesNotAcceptTranslatedStringsOrRawDetails() {
        val invalid = listOf(
            null,
            "Settings saved.",
            emptyMap<String, Any?>(),
            mapOf("id" to "", "args" to emptyMap<String, Any?>()),
            mapOf("id" to "settingsSaved"),
            mapOf("id" to "settingsSaved", "args" to null),
            mapOf("id" to "settingsSaved", "args" to mapOf(1 to "invalid")),
            mapOf("id" to "settingsSaved", "args" to mapOf("value" to null)),
            mapOf("id" to "settingsSaved", "args" to mapOf("value" to 1.5)),
            mapOf("id" to "settingsSaved", "args" to mapOf("value" to listOf("invalid"))),
            mapOf("id" to "settingsSaved", "args" to mapOf("value" to mapOf("raw" to "diagnostic")))
        )
        invalid.forEach { assertNull(AppMessage.fromMap(it)) }
    }

    @Test
    fun nestingHasTheSameBoundAsTheDartCodec() {
        var encoded: Any? = AppMessage("settingsSaved").toMap()
        repeat(4) {
            encoded = mapOf("id" to "androidErrorStageFailed", "args" to mapOf("stage" to encoded))
        }
        assertNotNull(AppMessage.fromMap(encoded))
        encoded = mapOf("id" to "androidErrorStageFailed", "args" to mapOf("stage" to encoded))
        assertNull(AppMessage.fromMap(encoded))
    }
}
