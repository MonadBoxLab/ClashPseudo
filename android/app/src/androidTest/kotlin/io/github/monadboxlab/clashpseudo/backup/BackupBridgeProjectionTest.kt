package io.github.monadboxlab.clashpseudo.backup

import io.github.monadboxlab.clashpseudo.message.AppMessage
import java.io.IOException
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

/** Actual feedback stays intact; consumers derive display and action eligibility. */
class BackupBridgeProjectionTest {
    @Test fun completeNamesAndUnknownFieldsAreNotTrimmedFilteredOrRevalidated() {
        for (label in listOf(" " + "a".repeat(698) + " ", "a".repeat(511) + "🚀", "🚀".repeat(1025), "\uD800")) {
            val value = mapOf(
                "status" to "prepared", "token" to UUID.randomUUID().toString(), "createdAtMillis" to 123L,
                "body" to "credential: secret", "uri" to "content://private/document", "paths" to mapOf("x" to "/private/path"),
                "summary" to mapOf("configurations" to 1, "overrides" to 0, "hasSelection" to true,
                    "selectedName" to label, "future" to listOf(null, false, 0, emptyMap<String, Any?>())),
            )
            assertEquals(value, backupProjection(value))
        }
    }

    @Test fun committedNullFalseAndEmptyValuesAndOriginalFollowupReasonsAllSurvive() {
        val primary = IOException("original provider failure", IllegalStateException("original cause"))
        primary.addSuppressed(IOException("cleanup failure"))
        val message = AppMessage("backupFailed").withDetail(primary).toMap()
        val value = mapOf(
            "status" to "unconfirmed", "committed" to null, "rolledBack" to false, "ready" to false, "epoch" to 0L,
            "settingsMessage" to message, "scheduleMessage" to message, "connectionMessage" to message,
            "errorDetail" to message, "future" to emptyList<String>(), "errorCode" to null,
        )
        assertEquals(value, backupProjection(value))
        val detail = message["detail"] as String
        for (original in listOf("original provider failure", "original cause", "cleanup failure")) {
            assertTrue(detail.contains(original))
        }
    }

    @Test fun unexpectedMetadataRemainsRawWithoutGrantingIntegerEligibility() {
        val value = mapOf(
            "status" to "future-status", "epoch" to 1.9,
            "summary" to mapOf("configurations" to 1.1, "overrides" to 0, "hasSelection" to true, "selectedName" to "name"),
        )
        assertEquals(value, backupProjection(value))
        assertNull(backupInteger(value["epoch"]))
        assertNull(backupInteger(-1))
        assertEquals(0L, backupInteger(0))
        assertEquals(7L, backupInteger(7L))
        assertNull(backupProjection(null))
    }
}
