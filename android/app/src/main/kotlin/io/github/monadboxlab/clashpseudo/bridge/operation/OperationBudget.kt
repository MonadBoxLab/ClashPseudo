package io.github.monadboxlab.clashpseudo.bridge.operation

import io.github.monadboxlab.clashpseudo.app.ApplicationContract

internal object OperationBudget {
    fun timeoutMs(action: Any?): Long = when (action) {
        "prepareBackup", "inspectBackup", "restoreBackup" -> ApplicationContract.OPERATION_BACKUP_TIMEOUT_MS
        else -> ApplicationContract.OPERATION_ORDINARY_TIMEOUT_MS
    }

    fun remainingMs(action: Any?, admittedAt: Long, now: Long): Long =
        (timeoutMs(action) - (now - admittedAt).coerceAtLeast(0L)).coerceAtLeast(0L)
}
