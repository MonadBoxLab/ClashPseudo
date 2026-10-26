package io.github.monadboxlab.clashpseudo.backup

import io.github.monadboxlab.clashpseudo.backup.utf8Length

import io.github.monadboxlab.clashpseudo.app.AppMessage

import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

/** Tests the pure result projection. */
class BackupBridgeProjectionTest {
    private val supplementary = String(Character.toChars(0x1f680))
    private fun result(label: String?, status: String = "prepared") = backupProjection(mapOf(
        "status" to status,
        "token" to UUID.randomUUID().toString(),
        "createdAtMillis" to 123L,
        "committed" to (if (status == "restored") true else null),
        "summary" to mapOf("configurations" to 1, "overrides" to 0, "hasSelection" to true, "selectedName" to label),
    ))!!
    private fun label(value: Map<String, Any?>) = (value["summary"] as Map<*, *>)["selectedName"]

    @Test fun preservesAValidSevenHundredByteAsciiLabelExactlyWithoutTrimmingOrSecondTruncation() {
        val value = " " + "a".repeat(698) + " "
        assertEquals(700, value.toByteArray(Charsets.UTF_8).size)
        assertEquals(value, label(result(value)))
    }

    @Test fun surrogatePairCrossingTheOld512BoundaryIsPreservedAsACompletePair() {
        val value = "a".repeat(511) + supplementary
        assertEquals(513, value.length)
        assertEquals(value, label(result(value)))
        assertEquals(515L, utf8Length(label(result(value)) as String))
    }

    @Test fun acceptsTheFullOneKiBUtf8LabelAndOmitsAnInvalidSummaryWithoutErasingCommit() {
        val boundary = supplementary.repeat(256)
        assertEquals(1024L, utf8Length(boundary))
        assertEquals(boundary, label(result(boundary)))
        val tooLarge = result(boundary + "a", "restored")
        assertFalse(tooLarge.containsKey("summary"))
        assertEquals(true, tooLarge["committed"])
        assertEquals("restored", tooLarge["status"])
        assertFalse(result("a".repeat(1025)).containsKey("summary"))
        assertFalse(result("\uD800").containsKey("summary"))
    }

    @Test fun filtersBodiesUrisPathsAndUnknownSummaryKeysInsteadOfForwardingCandidateDescriptors() {
        val projection = backupProjection(mapOf(
            "status" to "prepared", "token" to UUID.randomUUID().toString(),
            "body" to "credential: secret", "uri" to "content://private/document", "paths" to mapOf("x" to "/private/path"),
            "summary" to mapOf("configurations" to 1, "overrides" to 0, "hasSelection" to false, "selectedName" to null,
                "body" to "secret", "directory" to "/private/path"),
        ))!!
        assertEquals(setOf("status", "token", "summary"), projection.keys)
        assertEquals(setOf("configurations", "overrides", "hasSelection", "selectedName"), (projection["summary"] as Map<*, *>).keys)
        assertFalse(projection.toString().contains("secret"))
        assertFalse(projection.toString().contains("/private/path"))
        assertFalse(projection.toString().contains("content://"))
    }

    @Test fun keepsStructuredFollowupReasonsAndActualUnknownCommitWithoutExceptionStrings() {
        val message = AppMessage("operationFinished").toMap()
        val projection = backupProjection(mapOf(
            "status" to "unconfirmed", "committed" to null, "rolledBack" to false, "ready" to false, "epoch" to 7L,
            "settingsMessage" to message, "scheduleMessage" to message, "connectionMessage" to message,
            "cause" to IllegalStateException("private exception body"),
        ))!!
        assertTrue(projection.containsKey("committed"))
        assertNull(projection["committed"])
        for (key in listOf("settingsMessage", "scheduleMessage", "connectionMessage")) assertEquals(message, projection[key])
        assertFalse(projection.containsKey("cause"))
    }

    @Test fun neverCoercesFractionalMetadataAndDoesNotPublishAFalsePartialSummary() {
        val projection = backupProjection(mapOf(
            "status" to "failed", "epoch" to 1.9,
            "summary" to mapOf("configurations" to 1.1, "overrides" to 0, "hasSelection" to true, "selectedName" to "name"),
        ))!!
        assertFalse(projection.containsKey("epoch"))
        assertFalse(projection.containsKey("summary"))
    }
}
