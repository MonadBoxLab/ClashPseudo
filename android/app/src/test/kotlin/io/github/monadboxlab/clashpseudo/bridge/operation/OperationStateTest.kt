package io.github.monadboxlab.clashpseudo.bridge.operation

import io.github.monadboxlab.clashpseudo.message.AppMessage
import java.util.concurrent.CancellationException
import org.junit.Assert.*
import org.junit.Test

class OperationStateTest {
    @Test fun successfulModeReceiptsRetainOnlyTheirDeclaredTargetAndClearWithFeedback() {
        val state = OperationState { 40_000L }
        for (status in listOf("saved", "applied")) {
            state.replaceOwner("mode-$status")
            state.command = mapOf("action" to "setMode", "mode" to "global")
            val target = if (status == "applied") mapOf<String, Any?>(
                "processId" to "process", "inputId" to "input", "generation" to 8L,
                "configId" to "config", "revision" to 3, "composition" to "[\"config\",3]", "purpose" to "RUNNING",
            ) else emptyMap()
            val expected = target + mapOf("status" to status, "mode" to "global", "storageEpoch" to 23)
            val receipt = (expected + ("unrelated" to "not-a-mode-field")).toMutableMap()
            state.finish("mode-$status", mapOf("success" to true, "modeResult" to receipt)) {
                fail("Successful mode receipt requested an error message"); AppMessage("operationFinished")
            }
            assertEquals("mode-$status", state.resultId)
            assertTrue(state.resultSuccess)
            assertEquals(expected, state.modeResult)
            receipt["inputId"] = "late-unrelated-input"
            assertEquals(expected, state.modeResult)
            state.clearResultFeedback()
            assertNull(state.modeResult)
            assertNull(state.resultId)
        }
    }

    @Test fun nonModeOrUnsuccessfulResultsCannotReuseAnAppliedModeTarget() {
        val valid = mapOf("status" to "applied", "mode" to "global", "storageEpoch" to 23,
            "processId" to "process", "inputId" to "input", "generation" to 8,
            "configId" to "config", "revision" to 3, "composition" to "[\"config\",3]", "purpose" to "RUNNING")
        for (reason in listOf("action", "failure", "status", "mode", "missing")) {
            val state = OperationState { 40_000L }
            state.command = mapOf("action" to "setMode", "mode" to "global")
            state.finish("old", mapOf("success" to true, "modeResult" to valid)) { AppMessage("operationFinished") }
            assertNotNull(state.modeResult)
            state.command = mapOf("action" to if (reason == "action") "saveLocal" else "setMode", "mode" to "global")
            val mode = when (reason) {
                "status" -> valid + ("status" to "unconfirmed")
                "mode" -> valid + ("mode" to "direct")
                "missing" -> null
                else -> valid
            }
            state.finish("new", mapOf("success" to (reason != "failure"), "modeResult" to mode)) { AppMessage("operationFinished") }
            assertEquals("new", state.resultId)
            assertNull("Invalid $reason retained a previous mode target", state.modeResult)
        }
    }

    @Test fun stopHandoffKeepsTheOriginalAdmissionAndDeadlineAfterOwnerReplacement() {
        var now = 40_000L
        val state = OperationState { now }
        state.replaceOwner("restore")
        state.command = mapOf("action" to "restoreBackup")
        val admittedAt = state.operationAdmittedAt
        val deadline = state.operationDeadline
        assertEquals(340_000L, deadline)
        now = 300_000L
        state.replaceOwner(null)
        state.command = null
        state.replaceOwner("stop", admittedAt, deadline)
        state.command = mapOf("action" to "stop")
        assertEquals(40_000L, state.operationAdmittedAt)
        assertEquals(340_000L, state.operationDeadline)
        assertEquals(40_000L, state.remainingMs("stop"))
        now = 340_001L
        assertEquals(0L, state.remainingMs("stop"))
        assertEquals(340_000L, state.operationDeadline)
    }

    @Test fun clockChangesAndInterruptionNeverRecomputeTheAdmittedDeadline() {
        var now = 40_000L
        val state = OperationState { now }
        state.replaceOwner("owner")
        state.command = mapOf("action" to "saveLocal")
        assertEquals(160_000L, state.operationDeadline)
        now = 159_999L
        assertEquals(1L, state.remainingMs("owner"))
        state.interrupt("owner", AppMessage("operationFinished"))
        assertEquals(0L, state.remainingMs("owner"))
        assertEquals(160_000L, state.operationDeadline)
        state.command = mapOf("action" to "restoreBackup")
        assertEquals(160_000L, state.operationDeadline)
    }

    @Test fun repeatedOwnershipAndHandoffsKeepTheOriginalAdmissionClock() {
        var now = 40_000L
        val state = OperationState { now }
        state.replaceOwner("owner")
        state.command = mapOf("action" to "saveLocal")
        now = 48_000L
        state.replaceOwner("owner")
        assertEquals(40_000L, state.operationAdmittedAt)
        assertEquals(112_000L, state.remainingMs("owner"))
        state.useRemaining("owner") { (160_000L - now).coerceAtLeast(0L) }
        now = 159_999L
        assertEquals(1L, state.remainingMs("owner"))
        now = 160_000L
        assertThrows(CancellationException::class.java) {
            state.runIfCurrent("owner") { fail("Expired owner published") }
        }
        assertEquals(0L, state.remainingMs("stale"))
    }

    @Test fun interruptionRetainsTheActualReceiptAndExecutorUntilItsOwnDrain() {
        val state = OperationState { 40_000L }
        state.replaceOwner("restore")
        state.command = mapOf("action" to "restoreBackup")
        state.executorStarted("restore")
        val receipt = mapOf("committed" to true, "durable" to false, "status" to "unconfirmed")
        state.backupResult = receipt
        state.resultSuccess = false
        assertTrue(state.interrupt("restore", AppMessage("operationFinished")))
        assertEquals(40_000L, state.operationAdmittedAt)
        assertEquals(0L, state.remainingMs("restore"))
        assertSame(receipt, state.backupResult)
        assertFalse(state.resultSuccess)
        assertTrue(state.executorBusy)
        state.replaceOwner(null)
        assertTrue("Retiring publication does not drain execute", state.executorBusy)
        state.executorDrained("unrelated")
        assertTrue(state.executorBusy)
        state.executorDrained("restore")
        assertFalse(state.executorBusy)
    }

    @Test fun savedAndAppliedResultsRemainDistinctFromOverallSuccess() {
        val state = OperationState { 40_000L }
        state.replaceOwner("save")
        state.command = mapOf("action" to "saveLocal", "id" to "config")
        val error = AppMessage("operationFinished")
        state.finish("save", mapOf("success" to false, "configStatus" to "saved",
            "savedRevision" to 7, "message" to error.toMap())) { fail("Valid message was discarded"); error }
        assertEquals("saved", state.configStatus)
        assertEquals(7, state.savedRevision)
        assertEquals("config", state.targetId)
        assertFalse(state.resultSuccess)
        assertEquals(error, state.resultMessage)
        state.finish("save", mapOf("success" to true, "configStatus" to "applied")) { error }
        assertEquals("applied", state.configStatus)
        assertTrue(state.resultSuccess)
    }

    @Test fun replacementDoesNotEraseThePreviousCompleteReceiptOrAdoptItsDeadline() {
        var now = 40_000L
        val state = OperationState { now }
        state.replaceOwner("old")
        state.useRemaining("old") { 1L }
        val receipt = mapOf("committed" to true, "status" to "restored")
        state.resultId = "old"
        state.backupResult = receipt
        state.resultSuccess = true
        now = 80_000L
        state.replaceOwner("new")
        state.command = mapOf("action" to "saveLocal")
        assertEquals(80_000L, state.operationAdmittedAt)
        assertEquals(120_000L, state.remainingMs("new"))
        assertEquals("old", state.resultId)
        assertSame(receipt, state.backupResult)
        assertTrue(state.resultSuccess)
    }
}
