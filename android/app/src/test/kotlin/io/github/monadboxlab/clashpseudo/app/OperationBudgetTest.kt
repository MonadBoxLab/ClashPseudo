package io.github.monadboxlab.clashpseudo.app

import org.junit.Assert.*
import org.junit.Test

class OperationBudgetTest {
    @Test fun serviceAndReadbackKeepTheOriginalAdmissionTime() {
        assertEquals(120_000L, OperationBudget.remainingMs("saveLocal", 40_000L, 40_000L))
        assertEquals(112_000L, OperationBudget.remainingMs("saveLocal", 40_000L, 48_000L))
        assertEquals(1L, OperationBudget.remainingMs("saveLocal", 40_000L, 159_999L))
        assertEquals(0L, OperationBudget.remainingMs("saveLocal", 40_000L, 160_000L))
        assertEquals(0L, OperationBudget.remainingMs("saveLocal", 40_000L, 170_000L))
    }

    @Test fun allBackupActionsUseTheirOwnContinuousBudget() {
        for (action in listOf("prepareBackup", "inspectBackup", "restoreBackup")) {
            assertEquals(300_000L, OperationBudget.timeoutMs(action))
            assertEquals(279_000L, OperationBudget.remainingMs(action, 40_000L, 61_000L))
            assertEquals(1L, OperationBudget.remainingMs(action, 40_000L, 339_999L))
            assertEquals(0L, OperationBudget.remainingMs(action, 40_000L, 340_000L))
        }
    }
}
