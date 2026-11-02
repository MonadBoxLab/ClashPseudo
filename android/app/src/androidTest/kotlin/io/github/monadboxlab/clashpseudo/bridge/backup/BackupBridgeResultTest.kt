package io.github.monadboxlab.clashpseudo.bridge.backup

import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.WorkManager
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.bridge.BridgeTestState
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class BackupBridgeResultTest {
    @Before fun waitForStartupReconciliation() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val manager = WorkManager.getInstance(instrumentation.targetContext)
        val deadline = SystemClock.elapsedRealtime() + 45_000
        while (true) {
            val work = manager.getWorkInfosForUniqueWork("update-reconcile").get(5, TimeUnit.SECONDS)
            var idle = false
            instrumentation.runOnMainSync {
                idle = AppBridge.operationId == null && !AppBridge.logic.busy
            }
            if (work.isNotEmpty() && work.all { it.state.isFinished } && idle) return
            check(SystemClock.elapsedRealtime() < deadline) { "Startup reconciliation did not drain" }
            Thread.sleep(20)
        }
    }

    @Test fun newOwnerKeepsThePreviousCompleteBackupReceipt() {
        var failure: Throwable? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            failure = runCatching {
                val names = listOf("operationId", "operationAdmittedAt", "operationDeadline", "command", "resultId", "resultMessage", "resultSuccess",
                    "backupResult", "installedBackup", "restoreStopRequested", "restoreInterruption")
                val fields = names.associateWith { name ->
                    BridgeTestState.field(name)
                }
                val previous = fields.mapValues { it.value.get(AppBridge) }
                val acceptOwner = AppBridge::class.java.getDeclaredMethod("replaceOwner", String::class.java)
                    .apply { isAccessible = true }
                val receipt = mapOf("status" to "restored", "committed" to true,
                    "token" to "a".repeat(32), "requestId" to "completed-restore")
                try {
                    assertNull(AppBridge.operationId)
                    assertFalse(AppBridge.logic.busy)
                    assertEquals("STOPPED", AppBridge.runtimeState()["phase"])
                    fields.getValue("resultId").set(AppBridge, "completed-restore")
                    fields.getValue("resultSuccess").setBoolean(AppBridge, true)
                    fields.getValue("resultMessage").set(AppBridge, AppMessage("backupRestored"))
                    fields.getValue("backupResult").set(AppBridge, receipt)
                    fields.getValue("installedBackup").set(AppBridge, "completed-restore" to receipt)
                    fields.getValue("restoreStopRequested").setBoolean(AppBridge, true)
                    fields.getValue("restoreInterruption").set(AppBridge, AppMessage("operationFinished"))
                    acceptOwner.invoke(AppBridge, "scheduled-refresh")
                    val state = AppBridge.runtimeState()
                    assertEquals("completed-restore", state["resultId"])
                    assertEquals(true, state["resultSuccess"])
                    assertEquals(receipt, state["backupResult"])
                    assertNull(fields.getValue("installedBackup").get(AppBridge))
                    assertFalse(fields.getValue("restoreStopRequested").getBoolean(AppBridge))
                    assertNull(fields.getValue("restoreInterruption").get(AppBridge))
                } finally {
                    fields.forEach { (name, field) -> field.set(AppBridge, previous[name]) }
                }
            }.exceptionOrNull()
        }
        failure?.let { throw it }
    }

    @Test fun committedNativeReceiptCannotPromoteFailedOrIncompleteBusinessFollowups() {
        waitForStartupReconciliation()
        var failure: Throwable? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            failure = runCatching {
                val names = listOf("operationId", "operationAdmittedAt", "operationDeadline", "command", "operation",
                    "resultId", "resultMessage", "resultSuccess", "backupResult", "installedBackup",
                    "restoreStopRequested", "restoreStopOwner", "restoreStopReply", "restoreInterruption",
                    "configStatus", "overrideStatus", "resourceStatus", "scheduleStatus", "connectionStatus",
                    "targetId", "savedRevision")
                val fields = names.associateWith { name ->
                    BridgeTestState.field(name)
                }
                val previous = fields.mapValues { it.value.get(AppBridge) }
                val acceptOwner = AppBridge::class.java.getDeclaredMethod("replaceOwner", String::class.java)
                    .apply { isAccessible = true }
                val native = mapOf("committed" to true, "rolledBack" to false, "ready" to true,
                    "epoch" to 42L, "nativeOnly" to listOf(null, false, 0))
                val error = java.io.IOException("original follow-up failure", IllegalStateException("original cause"))
                    .apply { addSuppressed(java.io.IOException("secondary follow-up failure")) }
                val message = AppMessage("backupFailed").withDetail(error)
                try {
                    assertNull(AppBridge.operationId)
                    assertFalse(AppBridge.logic.busy)
                    assertEquals("STOPPED", AppBridge.runtimeState()["phase"])
                    val phases = listOf(
                        Triple("failed", "done", "restored"),
                        Triple("done", "failed", "restored"),
                        Triple("done", "done", "failed"),
                        Triple("cancelled", "cancelled", "cancelled"),
                        Triple("notRun", "notRun", "stopped"),
                    )
                    for ((index, phase) in phases.withIndex()) {
                        val owner = "restore-followup-$index"
                        acceptOwner.invoke(AppBridge, owner)
                        fields.getValue("command").set(AppBridge,
                            mapOf("action" to "restoreBackup", "requestId" to owner))
                        fields.getValue("installedBackup").set(AppBridge, owner to native)
                        val detail = mapOf("committed" to null, "status" to "unconfirmed",
                            "settingsStatus" to phase.first, "scheduleStatus" to phase.second,
                            "connectionStatus" to phase.third, "settingsMessage" to message.toMap(),
                            "scheduleMessage" to message.toMap(), "connectionMessage" to message.toMap())
                        AppBridge.finish(owner, mapOf("success" to false,
                            "message" to message.toMap(), "backupResult" to detail))
                        val state = AppBridge.runtimeState()
                        assertEquals(false, state["resultSuccess"])
                        assertEquals(owner, state["resultId"])
                        val receipt = state["backupResult"] as Map<*, *>
                        assertEquals(true, receipt["committed"])
                        assertEquals("restored", receipt["status"])
                        assertEquals(42L, receipt["epoch"])
                        assertEquals(native["nativeOnly"], receipt["nativeOnly"])
                        assertEquals(phase.first, receipt["settingsStatus"])
                        assertEquals(phase.second, receipt["scheduleStatus"])
                        assertEquals(phase.third, receipt["connectionStatus"])
                        for (key in listOf("settingsMessage", "scheduleMessage", "connectionMessage")) {
                            assertEquals(message.toMap(), receipt[key])
                        }
                        assertEquals(message.toMap(), (fields.getValue("resultMessage").get(AppBridge) as AppMessage).toMap())
                        assertNull(AppBridge.operationId)
                    }
                } finally {
                    fields.forEach { (name, field) -> field.set(AppBridge, previous[name]) }
                }
            }.exceptionOrNull()
        }
        failure?.let { throw it }
    }

    @Test fun restoreInterruptionCannotEraseTheActualInstallFailureOrMalformedDiagnostics() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val names = listOf("operationId", "operationAdmittedAt", "operationDeadline", "command", "operation",
                "resultId", "resultMessage", "resultSuccess", "backupResult", "installedBackup",
                "restoreStopRequested", "restoreStopOwner", "restoreStopReply", "restoreInterruption",
                "configStatus", "overrideStatus", "resourceStatus", "scheduleStatus", "connectionStatus",
                "targetId", "savedRevision")
            val fields = names.associateWith { name ->
                BridgeTestState.field(name)
            }
            val previous = fields.mapValues { it.value.get(AppBridge) }
            val acceptOwner = AppBridge::class.java.getDeclaredMethod("replaceOwner", String::class.java)
                .apply { isAccessible = true }
            val failure = java.io.IOException("original install failure", java.io.IOException("original cause"))
                .apply { addSuppressed(java.io.IOException("original close failure")) }
            val actual = AppMessage("backupFailed").withDetail(failure)
            val interruption = AppMessage("operationFinished").withDetail("original cancellation")
            try {
                assertNull(AppBridge.operationId)
                assertFalse(AppBridge.logic.busy)
                assertEquals("STOPPED", AppBridge.runtimeState()["phase"])
                for (malformed in listOf(false, true)) {
                    val owner = "restore-error-$malformed"
                    acceptOwner.invoke(AppBridge, owner)
                    fields.getValue("command").set(AppBridge, mapOf("action" to "restoreBackup"))
                    fields.getValue("restoreInterruption").set(AppBridge, interruption)
                    val message = if (malformed) mapOf("id" to false, "detail" to actual.detail,
                        "future" to listOf(null, false, 0)) else actual.toMap()
                    AppBridge.finish(owner, mapOf("success" to false, "message" to message,
                        "backupResult" to mapOf("status" to "notRestored", "committed" to false,
                            "rolledBack" to true)))
                    val state = AppBridge.runtimeState()
                    assertEquals(owner, state["resultId"])
                    assertEquals(false, state["resultSuccess"])
                    val receipt = state["backupResult"] as Map<*, *>
                    assertEquals(false, receipt["committed"])
                    assertEquals(true, receipt["rolledBack"])
                    val result = AppMessage.fromMap(state["resultMessage"])!!
                    if (!malformed) assertEquals(actual.id, result.id)
                    val detail = result.detail!!
                    assertTrue(detail.contains(actual.detail!!))
                    assertTrue(detail.contains("original cause"))
                    assertTrue(detail.contains("original close failure"))
                    assertTrue(detail.contains("original cancellation"))
                    if (malformed) assertTrue(detail.contains("future=[null, false, 0]"))
                    assertNull(AppBridge.operationId)
                }
            } finally {
                fields.forEach { (name, field) -> field.set(AppBridge, previous[name]) }
                PseudoVpnService.core.setOperationBusy(AppBridge.operationId != null || AppBridge.logic.busy ||
                    AppBridge.runtimeState()["resourceBusy"] == true)
            }
        }
    }
}
