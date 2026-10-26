package io.github.monadboxlab.clashpseudo.bridge

import io.github.monadboxlab.clashpseudo.app.AppMessage

import android.os.SystemClock
import android.content.Intent
import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.os.IBinder
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.app.AppFiles
import io.github.monadboxlab.clashpseudo.app.AppWorkService
import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.WorkManager
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class AppBridgeResultTest {
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
                val names = listOf("operationId", "operationAdmittedAt", "command", "resultId", "resultMessage", "resultSuccess",
                    "backupResult", "installedBackup", "restoreStopRequested", "restoreInterruption")
                val fields = names.associateWith { name ->
                    AppBridge::class.java.getDeclaredField(name).apply { isAccessible = true }
                }
                val previous = fields.mapValues { it.value.get(AppBridge) }
                val acceptOwner = AppBridge::class.java.getDeclaredMethod("setOperationId", String::class.java)
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

    @Test fun admissionAndServiceReadTheSameRemainingOperationBudget() {
        waitForStartupReconciliation()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val names = listOf("operationId", "operationAdmittedAt", "command", "installedBackup",
                "restoreStopRequested", "restoreInterruption")
            val fields = names.associateWith { name ->
                AppBridge::class.java.getDeclaredField(name).apply { isAccessible = true }
            }
            val previous = fields.mapValues { it.value.get(AppBridge) }
            val acceptOwner = AppBridge::class.java.getDeclaredMethod("setOperationId", String::class.java)
                .apply { isAccessible = true }
            val receipt = AppBridge::class.java.getDeclaredMethod("admission", String::class.java)
                .apply { isAccessible = true }
            try {
                assertNull(AppBridge.operationId)
                assertFalse(AppBridge.logic.busy)
                acceptOwner.invoke(AppBridge, "admission-budget")
                fields.getValue("command").set(AppBridge, mapOf("action" to "saveLocal"))
                fields.getValue("operationAdmittedAt").set(AppBridge, SystemClock.elapsedRealtime() - 8000L)
                val value = receipt.invoke(AppBridge, "admission-budget") as Map<*, *>
                assertEquals("admission-budget", value["operationId"])
                val remaining = value["remainingMs"] as Long
                assertTrue(remaining in 1L..112_000L)
                assertTrue(AppBridge.operationRemainingMs("admission-budget") in 1L..remaining)
                assertEquals(0L, AppBridge.operationRemainingMs("old-owner"))
                fields.getValue("operationAdmittedAt").set(AppBridge, SystemClock.elapsedRealtime() - 120_000L)
                assertEquals(0L, AppBridge.operationRemainingMs("admission-budget"))
                assertEquals(0L, (receipt.invoke(AppBridge, "admission-budget") as Map<*, *>)["remainingMs"])
            } finally {
                fields.forEach { (name, field) -> field.set(AppBridge, previous[name]) }
            }
        }
    }

    @Test fun expiredServiceAdmissionPreservesStoresAndSettlesUnexecutedRestore() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        try {
            waitForStartupReconciliation()
            val originals = BackupFiles.Kind.entries.associate { kind ->
                val file = AppFiles.configs(context).resolve(kind.fileName)
                file to if (file.exists()) file.readBytes() else null
            }
            val submit = AppBridge::class.java.getDeclaredMethod("submit",
                io.flutter.plugin.common.MethodCall::class.java, MethodChannel.Result::class.java).apply { isAccessible = true }
            val admittedAt = AppBridge::class.java.getDeclaredField("operationAdmittedAt").apply { isAccessible = true }
            for (action in listOf("saveLocal", "restoreBackup")) {
                var owner: String? = null
                instrumentation.runOnMainSync {
                    assertNull(AppBridge.operationId)
                    assertFalse(AppBridge.logic.busy)
                    val request = mapOf(
                        "action" to action, "storageEpoch" to AppBridge.runtimeState()["storageEpoch"],
                        "name" to "Unexecuted budget fixture", "body" to "rules: []\n".toByteArray(Charsets.UTF_8),
                        "requestId" to "expired-service-$action", "token" to "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                    )
                    submit.invoke(AppBridge, io.flutter.plugin.common.MethodCall("submit", request),
                        object : MethodChannel.Result {
                            override fun success(value: Any?) {
                                owner = (value as Map<*, *>)["operationId"] as String
                                assertFalse(AppBridge.logic.ownsOperation(owner!!))
                                admittedAt.set(AppBridge, SystemClock.elapsedRealtime() -
                                    if (action == "restoreBackup") 300_000L else 120_000L)
                            }
                            override fun error(code: String, message: String?, details: Any?) { fail("Service admission failed: $code") }
                            override fun notImplemented() { fail("Submit missing") }
                        })
                }
                assertNotNull(owner)
                val deadline = SystemClock.elapsedRealtime() + 30_000L
                var outcome: Map<String, Any?>? = null
                while (SystemClock.elapsedRealtime() < deadline && outcome == null) {
                    instrumentation.runOnMainSync {
                        val state = AppBridge.runtimeState()
                        if (state["resultId"] == owner && AppBridge.operationId == null &&
                            !AppBridge.logic.busy && AppWorkService.instance == null) outcome = state
                    }
                    if (outcome == null) SystemClock.sleep(25)
                }
                assertNotNull("Unexecuted Service did not settle: $action", outcome)
                assertEquals(false, outcome!!["resultSuccess"])
                assertEquals("androidErrorOperationWaitTimeout", (outcome!!["resultMessage"] as Map<*, *>)["id"])
                if (action == "saveLocal") assertEquals("notSaved", outcome!!["configStatus"])
                else {
                    val backup = outcome!!["backupResult"] as Map<*, *>
                    assertEquals("notRestored", backup["status"])
                    assertEquals(false, backup["committed"])
                    assertEquals(false, backup["rolledBack"])
                }
                originals.forEach { (file, original) ->
                    if (original == null) assertFalse(file.exists())
                    else assertArrayEquals("Unexecuted $action changed ${file.name}", original, file.readBytes())
                }
            }
        } finally {
            instrumentation.runOnMainSync { activity.finish() }
        }
    }

    @Test fun repeatedServiceStartsKeepTheWorkOwnerAndLatestSdkStartId() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        waitForStartupReconciliation()
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {}
            override fun onServiceDisconnected(name: ComponentName) {}
        }
        instrumentation.runOnMainSync { assertNull(AppWorkService.instance) }
        assertTrue(context.bindService(Intent(context, AppWorkService::class.java), connection, Context.BIND_AUTO_CREATE))
        var service: AppWorkService? = null
        try {
            val deadline = SystemClock.elapsedRealtime() + 5000L
            while (service == null && SystemClock.elapsedRealtime() < deadline) {
                instrumentation.runOnMainSync { service = AppWorkService.instance }
                if (service == null) SystemClock.sleep(25)
            }
            assertNotNull("SDK did not create the bound Service", service)
            instrumentation.runOnMainSync {
                val instance = service!!
                val owner = AppWorkService::class.java.getDeclaredField("id").apply { isAccessible = true }
                val finished = AppWorkService::class.java.getDeclaredField("finished").apply { isAccessible = true }
                val start = AppWorkService::class.java.getDeclaredField("startId").apply { isAccessible = true }
                owner.set(instance, "draining-work-owner")
                finished.setBoolean(instance, false)
                start.setInt(instance, 1)
                instance.onStartCommand(Intent(context, AppWorkService::class.java)
                    .putExtra(AppWorkService.EXTRA_OWNER, "stale-owner"), 0, 2)
                assertEquals("draining-work-owner", owner.get(instance))
                assertFalse(finished.getBoolean(instance))
                assertEquals(2, start.getInt(instance))
            }
        } finally {
            instrumentation.runOnMainSync {
                service?.let { instance ->
                    AppWorkService::class.java.getDeclaredField("finished").apply { isAccessible = true }
                        .setBoolean(instance, true)
                    AppWorkService::class.java.getDeclaredField("id").apply { isAccessible = true }.set(instance, null)
                }
                context.unbindService(connection)
            }
        }
    }

    @Test fun operationSnapshotDoesNotExposeHttpConfirmationState() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            assertFalse(AppBridge.runtimeState().containsKey("needsHttpConfirmation"))
        }
    }

    @Test fun scheduleFailureKeepsTheSavedResultAndExpiresWithNativeState() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val names = listOf("operationId", "operationAdmittedAt", "command", "operation", "resultId", "resultMessage",
                "resultSuccess", "resourceStatus", "scheduleStatus", "configStatus", "overrideStatus",
                "connectionStatus", "targetId", "savedRevision")
            val fields = names.associateWith { name ->
                AppBridge::class.java.getDeclaredField(name).apply { isAccessible = true }
            }
            val previous = fields.mapValues { it.value.get(AppBridge) }
            try {
                assertNull(AppBridge.operationId)
                assertFalse(AppBridge.logic.busy)
                assertEquals("STOPPED", AppBridge.runtimeState()["phase"])
                fields.getValue("operationId").set(AppBridge, "test-schedule-result")
                fields.getValue("command").set(AppBridge, mapOf("action" to "setConfigUpdate", "id" to "config"))
                AppBridge.finish("test-schedule-result", mapOf(
                    "success" to false,
                    "configStatus" to "saved",
                    "scheduleStatus" to "failed",
                    "targetId" to "config",
                    "savedRevision" to 3,
                    "message" to AppMessage("androidErrorBusy").toMap(),
                ))
                val state = AppBridge.runtimeState()
                assertEquals("saved", state["configStatus"])
                assertEquals("failed", state["scheduleStatus"])
                assertEquals(false, state["resultSuccess"])
                assertEquals("config", state["targetId"])
                assertEquals(3, state["savedRevision"])
                AppBridge.nativeChanged()
                assertNull(AppBridge.runtimeState()["scheduleStatus"])
            } finally {
                fields.forEach { (name, field) -> field.set(AppBridge, previous[name]) }
                PseudoVpnService.core.setOperationBusy(AppBridge.operationId != null || AppBridge.logic.busy ||
                    AppBridge.runtimeState()["resourceBusy"] == true)
            }
        }
    }

    @Test fun confirmedAlwaysOnRejectsUserStopButNotInternalReleaseOrUnknownState() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            assertEquals("STOPPED", AppBridge.runtimeState()["phase"])
            for (alwaysOn in listOf(true, false, null)) {
                for (internal in listOf(false, true)) {
                    var succeeded = false
                    var error: String? = null
                    val calls = NativeCalls(instrumentation.targetContext, alwaysOn = { alwaysOn })
                    calls.stop(object : MethodChannel.Result {
                        override fun success(value: Any?) { succeeded = true }
                        override fun error(code: String, message: String?, details: Any?) {
                            error = code
                            assertEquals("alwaysOnNotice", (details as Map<*, *>)["id"])
                        }
                        override fun notImplemented() { fail("stop missing") }
                    }, internal)
                    assertEquals(!internal && alwaysOn == true, error == "alwaysOn")
                    assertEquals(internal || alwaysOn != true, succeeded)
                }
            }
        }
    }

    @Test fun failedSystemRestoreCannotInheritAnEarlierSuccessOrOverwriteANewerOwner() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val names = listOf("operationId", "operationAdmittedAt", "systemRestoreOwner", "command", "operation",
                "resultId", "resultMessage", "resultSuccess")
            val fields = names.associateWith { name ->
                AppBridge::class.java.getDeclaredField(name).apply { isAccessible = true }
            }
            val previous = fields.mapValues { it.value.get(AppBridge) }
            val complete = AppBridge::class.java.getDeclaredMethod("completeSystemRestore",
                String::class.java, Map::class.java, kotlin.jvm.functions.Function1::class.java)
                .apply { isAccessible = true }
            try {
                assertNull(AppBridge.operationId)
                fields.getValue("operationId").set(AppBridge, "restore-owner")
                fields.getValue("systemRestoreOwner").set(AppBridge, "restore-owner")
                fields.getValue("resultSuccess").setBoolean(AppBridge, true)
                fields.getValue("resultMessage").set(AppBridge, AppMessage("tunnelStarted"))
                var replies = 0
                val reply: (Map<String, Any?>?) -> Unit = { assertNull(it); replies++ }
                complete.invoke(AppBridge, "restore-owner", mapOf("success" to false,
                    "message" to AppMessage("noConfigForSystemStart").toMap()), reply)
                assertEquals(1, replies)
                val failed = AppBridge.runtimeState()
                assertEquals(false, failed["resultSuccess"])
                assertEquals("restore-owner", failed["resultId"])
                assertEquals("noConfigForSystemStart", (failed["resultMessage"] as Map<*, *>)["id"])
                fields.getValue("operationId").set(AppBridge, "new-owner")
                fields.getValue("systemRestoreOwner").set(AppBridge, "new-owner")
                complete.invoke(AppBridge, "restore-owner", mapOf("success" to true), reply)
                assertEquals(2, replies)
                assertEquals("new-owner", AppBridge.operationId)
                assertEquals(failed["resultMessage"], AppBridge.runtimeState()["resultMessage"])
            } finally {
                fields.forEach { (name, field) -> field.set(AppBridge, previous[name]) }
                PseudoVpnService.core.setOperationBusy(AppBridge.operationId != null || AppBridge.logic.busy ||
                    AppBridge.runtimeState()["resourceBusy"] == true)
            }
        }
    }

    @Test fun resourceStopPreemptsOwnerButKeepsTheRealIoGateClosed() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val names = listOf("operationId", "operationAdmittedAt", "command", "operation", "resultId", "resultMessage",
                "resultSuccess", "resourceStatus", "scheduleStatus", "configStatus", "overrideStatus", "connectionStatus",
                "targetId", "savedRevision")
            val fields = names.associateWith { name ->
                AppBridge::class.java.getDeclaredField(name).apply { isAccessible = true }
            }
            val previous = fields.mapValues { it.value.get(AppBridge) }
            val reads = AppBridge::class.java.getDeclaredField("coreReads").apply { isAccessible = true }.get(AppBridge)
            val updating = CoreReadCalls::class.java.getDeclaredField("updating").apply { isAccessible = true }
            val oldUpdating = updating.getBoolean(reads)
            val submit = AppBridge::class.java.getDeclaredMethod("submit",
                io.flutter.plugin.common.MethodCall::class.java, MethodChannel.Result::class.java).apply { isAccessible = true }
            try {
                assertNull(AppBridge.operationId)
                assertFalse(AppBridge.logic.busy)
                assertEquals("STOPPED", AppBridge.runtimeState()["phase"])
                fields.getValue("operationId").set(AppBridge, "resource-owner")
                fields.getValue("command").set(AppBridge, mapOf("action" to "updateResource"))
                updating.setBoolean(reads, true)
                assertEquals(true, AppBridge.runtimeState()["resourceBusy"])
                var accepted: String? = null
                submit.invoke(AppBridge, io.flutter.plugin.common.MethodCall("submit", mapOf("action" to "stop")),
                    object : MethodChannel.Result {
                        override fun success(value: Any?) {
                            val admission = value as Map<*, *>
                            accepted = admission["operationId"] as String
                            assertTrue((admission["remainingMs"] as Long) in 1L..120_000L)
                        }
                        override fun error(code: String, message: String?, details: Any?) { fail("Stop rejected") }
                        override fun notImplemented() { fail("Stop missing") }
                    })
                assertNotNull(accepted)
                assertNotEquals("resource-owner", accepted)
                assertNull(AppBridge.operationId)
                assertEquals(accepted, AppBridge.runtimeState()["resultId"])
                assertEquals(true, AppBridge.runtimeState()["resourceBusy"])
                val core = io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService.core
                val previewBusy = core::class.java.getDeclaredField("operationBusy").apply { isAccessible = true }
                assertTrue(previewBusy.getBoolean(core))
                AppBridge.finish("resource-owner", mapOf("success" to true, "resourceStatus" to "ok"))
                assertEquals(accepted, AppBridge.runtimeState()["resultId"])
                assertNull(AppBridge.runtimeState()["resourceStatus"])
                var rejected = false
                submit.invoke(AppBridge, io.flutter.plugin.common.MethodCall("submit", mapOf(
                    "action" to "start", "storageEpoch" to AppBridge.runtimeState()["storageEpoch"])),
                    object : MethodChannel.Result {
                        override fun success(value: Any?) { fail("Writer reopened before I/O returned") }
                        override fun error(code: String, message: String?, details: Any?) { rejected = code == "busy" }
                        override fun notImplemented() { fail("Start missing") }
                    })
                assertTrue(rejected)
            } finally {
                updating.setBoolean(reads, oldUpdating)
                fields.forEach { (name, field) -> field.set(AppBridge, previous[name]) }
                io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService.core.setOperationBusy(
                    AppBridge.operationId != null || AppBridge.logic.busy || oldUpdating)
            }
        }
    }

    @Test fun busySystemRestoreWaitsAndCancellationPreservesTheCurrentWriter() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val done = CountDownLatch(1)
        val replies = AtomicInteger()
        val id = AppBridge::class.java.getDeclaredField("operationId").apply { isAccessible = true }
        val discarded = AppBridge::class.java.getDeclaredField("discardedSystemInput").apply { isAccessible = true }
        var oldId: Any? = null
        var oldDiscarded: Any? = null
        instrumentation.runOnMainSync {
            oldId = id.get(AppBridge)
            oldDiscarded = discarded.get(AppBridge)
            assertNull(oldId)
            assertFalse(AppBridge.pendingSystemRestore)
            id.set(AppBridge, "existing-writer")
            AppBridge.restoreSystemStart {
                assertNull(it)
                replies.incrementAndGet()
                done.countDown()
            }
            assertEquals(0, replies.get())
            assertTrue(AppBridge.pendingSystemRestore)
            assertEquals(true, AppBridge.runtimeState()["pendingSystemStart"])
            assertTrue(AppBridge.cancelSystemRestore())
            assertFalse(AppBridge.pendingSystemRestore)
            assertEquals("existing-writer", AppBridge.operationId)
            assertEquals(oldDiscarded, discarded.get(AppBridge))
            assertEquals(true, AppBridge.runtimeState()["writerBusy"])
        }
        try {
            assertTrue(done.await(2, TimeUnit.SECONDS))
            assertEquals(1, replies.get())
        } finally {
            instrumentation.runOnMainSync {
                AppBridge.cancelSystemRestore()
                id.set(AppBridge, oldId)
            }
        }
    }

    @Test fun aCancelledWaitingAttemptCannotClearTheNextRestore() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val firstDone = CountDownLatch(1)
        val secondDone = CountDownLatch(1)
        val id = AppBridge::class.java.getDeclaredField("operationId").apply { isAccessible = true }
        var oldId: Any? = null
        instrumentation.runOnMainSync {
            oldId = id.get(AppBridge)
            assertNull(oldId)
            assertFalse(AppBridge.pendingSystemRestore)
            id.set(AppBridge, "existing-writer")
            AppBridge.restoreSystemStart { assertNull(it); firstDone.countDown() }
            assertTrue(AppBridge.cancelSystemRestore())
            AppBridge.restoreSystemStart { assertNull(it); secondDone.countDown() }
            var duplicateReplies = 0
            AppBridge.restoreSystemStart { assertNull(it); duplicateReplies++ }
            assertEquals(1, duplicateReplies)
            assertTrue(AppBridge.pendingSystemRestore)
        }
        try {
            assertTrue(firstDone.await(2, TimeUnit.SECONDS))
            instrumentation.runOnMainSync {
                assertTrue(AppBridge.pendingSystemRestore)
                assertEquals("existing-writer", AppBridge.operationId)
                assertEquals(1L, secondDone.count)
                assertTrue(AppBridge.cancelSystemRestore())
            }
            assertTrue(secondDone.await(2, TimeUnit.SECONDS))
        } finally {
            instrumentation.runOnMainSync {
                AppBridge.cancelSystemRestore()
                id.set(AppBridge, oldId)
            }
        }
    }

    @Test fun latePermissionResultCannotCompleteTheNextRequest() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            // Populate the pending reply state for result dispatch.
            val pending = AppBridge::class.java.getDeclaredField("authorization").apply { isAccessible = true }
            val code = AppBridge::class.java.getDeclaredField("authorizationCode").apply { isAccessible = true }
            val oldPending = pending.get(AppBridge)
            val oldCode = code.getInt(AppBridge)
            var replies = 0
            val result = object : MethodChannel.Result {
                override fun success(value: Any?) { replies++; assertEquals(false, value) }
                override fun error(code: String, message: String?, details: Any?) { fail("Unexpected error") }
                override fun notImplemented() { fail("Unexpected missing method") }
            }
            try {
                assertNull(oldPending)
                code.setInt(AppBridge, 202)
                pending.set(AppBridge, result)
                AppBridge.authorizationResult(201, false)
                assertEquals(0, replies)
                assertSame(result, pending.get(AppBridge))
                AppBridge.authorizationResult(202, false)
                assertEquals(1, replies)
                assertNull(pending.get(AppBridge))
                AppBridge.authorizationResult(202, false)
                assertEquals(1, replies)
            } finally {
                pending.set(AppBridge, oldPending)
                code.setInt(AppBridge, oldCode)
            }
        }
    }

    @Test fun nativeStateChangeExpiresEarlierSuccessFeedback() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val message = AppBridge::class.java.getDeclaredField("resultMessage").apply { isAccessible = true }
            val old = message.get(AppBridge)
            try {
                assertNull(AppBridge.operationId)
                message.set(AppBridge, AppMessage("tunnelStarted"))
                AppBridge.nativeChanged()
                assertNull(message.get(AppBridge))
            } finally {
                message.set(AppBridge, old)
            }
        }
    }

    @Test fun lateOperationResultCannotFinishCurrentWork() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val id = AppBridge::class.java.getDeclaredField("operationId").apply { isAccessible = true }
            val old = id.get(AppBridge)
            try {
                assertNull(old)
                id.set(AppBridge, "current-operation")
                AppBridge.finish("old-operation", mapOf("message" to AppMessage("androidErrorOperationEnded").toMap()))
                assertEquals("current-operation", AppBridge.operationId)
            } finally {
                id.set(AppBridge, old)
            }
        }
    }
}
