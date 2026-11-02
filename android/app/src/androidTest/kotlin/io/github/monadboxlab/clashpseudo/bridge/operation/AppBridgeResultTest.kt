package io.github.monadboxlab.clashpseudo.bridge.operation

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.WorkManager
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.app.AppWorkService
import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.bridge.BridgeTestState
import io.github.monadboxlab.clashpseudo.nativecore.CoreClient
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CoreLifecycleCalls
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import java.util.concurrent.CompletableFuture
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.storage.AppFiles
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.util.concurrent.TimeUnit
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

    @Test fun admissionAndServiceReadTheSameRemainingOperationBudget() {
        waitForStartupReconciliation()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val names = listOf("operationId", "operationAdmittedAt", "operationDeadline", "command", "installedBackup",
                "restoreStopRequested", "restoreInterruption")
            val fields = names.associateWith { name ->
                BridgeTestState.field(name)
            }
            val previous = fields.mapValues { it.value.get(AppBridge) }
            val acceptOwner = AppBridge::class.java.getDeclaredMethod("replaceOwner", String::class.java)
                .apply { isAccessible = true }
            val receipt = AppBridge::class.java.getDeclaredMethod("admission", String::class.java)
                .apply { isAccessible = true }
            try {
                assertNull(AppBridge.operationId)
                assertFalse(AppBridge.logic.busy)
                acceptOwner.invoke(AppBridge, "admission-budget")
                fields.getValue("command").set(AppBridge, mapOf("action" to "saveLocal"))
                val admitted = SystemClock.elapsedRealtime() - 8000L
                    fields.getValue("operationAdmittedAt").set(AppBridge, admitted)
                    fields.getValue("operationDeadline").set(AppBridge, admitted + Contract.OPERATION_ORDINARY_TIMEOUT_MS)
                val value = receipt.invoke(AppBridge, "admission-budget") as Map<*, *>
                assertEquals("admission-budget", value["operationId"])
                val remaining = value["remainingMs"] as Long
                assertTrue(remaining in 1L..112_000L)
                assertTrue(AppBridge.operationRemainingMs("admission-budget") in 1L..remaining)
                assertEquals(0L, AppBridge.operationRemainingMs("old-owner"))
                val projected = AppBridge.runtimeState()
                assertEquals("admission-budget", projected["operationId"])
                assertEquals(admitted, projected["operationAdmittedAt"])
                assertEquals(admitted + Contract.OPERATION_ORDINARY_TIMEOUT_MS, projected["operationDeadline"])
                assertTrue((projected["operationRemainingMs"] as Long) in 1L..remaining)
                val expired = SystemClock.elapsedRealtime() - Contract.OPERATION_ORDINARY_TIMEOUT_MS
                    fields.getValue("operationAdmittedAt").set(AppBridge, expired)
                    fields.getValue("operationDeadline").set(AppBridge, expired + Contract.OPERATION_ORDINARY_TIMEOUT_MS)
                assertEquals(0L, AppBridge.operationRemainingMs("admission-budget"))
                assertEquals(0L, (receipt.invoke(AppBridge, "admission-budget") as Map<*, *>)["remainingMs"])
                val waitingForDrain = AppBridge.runtimeState()
                assertEquals("admission-budget", waitingForDrain["operationId"])
                assertEquals(0L, waitingForDrain["operationRemainingMs"])
                assertEquals(expired, waitingForDrain["operationAdmittedAt"])
                assertEquals(expired + Contract.OPERATION_ORDINARY_TIMEOUT_MS, waitingForDrain["operationDeadline"])
                assertEquals(true, waitingForDrain["writerBusy"])
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
            val admittedAt = BridgeTestState.field("operationAdmittedAt")
            val operationDeadline = BridgeTestState.field("operationDeadline")
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
                                val budget = if (action == "restoreBackup") Contract.OPERATION_BACKUP_TIMEOUT_MS
                                    else Contract.OPERATION_ORDINARY_TIMEOUT_MS
                                val expired = SystemClock.elapsedRealtime() - budget
                                admittedAt.set(AppBridge, expired)
                                operationDeadline.set(AppBridge, expired + budget)
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
            val names = listOf("operationId", "operationAdmittedAt", "operationDeadline", "command", "operation", "resultId", "resultMessage",
                "resultSuccess", "resourceStatus", "scheduleStatus", "configStatus", "overrideStatus",
                "connectionStatus", "targetId", "savedRevision")
            val fields = names.associateWith { name ->
                BridgeTestState.field(name)
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
        val client = CoreClient.get(instrumentation.targetContext)
        val status = CoreClient::class.java.getDeclaredField("statusValue").apply { isAccessible = true }
        val previous = status.get(client)
        try {
            CoreIpcTestDriver.assertNoGoInApplication()
            for (alwaysOn in listOf(true, false, null)) for (internal in listOf(false, true)) {
                val reply = CompletableFuture<Pair<Boolean, String?>>()
                instrumentation.runOnMainSync {
                    assertEquals("STOPPED", AppBridge.runtimeState()["phase"])
                    @Suppress("UNCHECKED_CAST")
                    status.set(client, (previous as Map<String, Any?>) + ("alwaysOn" to alwaysOn))
                    CoreLifecycleCalls(instrumentation.targetContext).stop(object : MethodChannel.Result {
                        override fun success(value: Any?) { reply.complete(true to null) }
                        override fun error(code: String, message: String?, details: Any?) {
                            assertEquals("alwaysOnNotice", (details as Map<*, *>)["id"])
                            reply.complete(false to code)
                        }
                        override fun notImplemented() { reply.completeExceptionally(AssertionError("缺少 stop 方法")) }
                    }, internal)
                }
                val result = reply.get(15, TimeUnit.SECONDS)
                assertEquals(!internal && alwaysOn == true, result.second == "alwaysOn")
                assertEquals(internal || alwaysOn != true, result.first)
            }
        } finally {
            instrumentation.runOnMainSync { status.set(client, previous) }
            CoreIpcTestDriver.assertNoGoInApplication()
        }
    }

    @Test fun resourceStopPreemptsOwnerButKeepsTheRealIoGateClosed() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val names = listOf("operationId", "operationAdmittedAt", "operationDeadline", "command", "operation", "resultId", "resultMessage",
            "resultSuccess", "resourceStatus", "scheduleStatus", "configStatus", "overrideStatus", "connectionStatus",
            "targetId", "savedRevision")
        val fields = names.associateWith { BridgeTestState.field(it) }
        val previous = fields.mapValues { it.value.get(AppBridge) }
        val submit = AppBridge::class.java.getDeclaredMethod("submit",
            io.flutter.plugin.common.MethodCall::class.java, MethodChannel.Result::class.java).apply { isAccessible = true }
        try {
            io.github.monadboxlab.clashpseudo.nativecore.CoreClientTestCall().use { call ->
                var accepted: String? = null
                instrumentation.runOnMainSync {
                    assertNull(AppBridge.operationId)
                    assertFalse(AppBridge.logic.busy)
                    assertEquals("STOPPED", AppBridge.runtimeState()["phase"])
                    BridgeTestState.acceptOwner("resource-owner")
                    AppBridge.operations.command = mapOf("action" to "updateResource")
                    assertEquals(true, AppBridge.runtimeState()["resourceBusy"])
                    submit.invoke(AppBridge, io.flutter.plugin.common.MethodCall("submit", mapOf("action" to "stop")),
                        object : MethodChannel.Result {
                            override fun success(value: Any?) {
                                val admission = value as Map<*, *>
                                accepted = admission["operationId"] as String
                                assertTrue((admission["remainingMs"] as Long) in 1L..120_000L)
                            }
                            override fun error(code: String, message: String?, details: Any?) { fail("Stop 被拒绝：$code") }
                            override fun notImplemented() { fail("缺少 Stop 方法") }
                        })
                    assertNotNull(accepted)
                    assertNotEquals("resource-owner", accepted)
                }
                call.barrier()
                for (flag in listOf("nativeExited", "receiptExited", "ioExited")) {
                    instrumentation.runOnMainSync {
                        assertEquals(accepted, AppBridge.operationId)
                        assertEquals(true, AppBridge.runtimeState()["resourceBusy"])
                        assertEquals(true, AppBridge.runtimeState()["writerBusy"])
                        AppBridge.finish("resource-owner", mapOf("success" to true, "resourceStatus" to "ok"))
                        assertEquals(accepted, AppBridge.operationId)
                        assertNull(AppBridge.runtimeState()["resourceStatus"])
                        var rejected = false
                        submit.invoke(AppBridge, io.flutter.plugin.common.MethodCall("submit", mapOf(
                            "action" to "start", "storageEpoch" to AppBridge.runtimeState()["storageEpoch"])),
                            object : MethodChannel.Result {
                                override fun success(value: Any?) { fail("I/O 结束前 writer 已开放") }
                                override fun error(code: String, message: String?, details: Any?) { rejected = code == "busy" }
                                override fun notImplemented() { fail("缺少 Start 方法") }
                            })
                        assertTrue(rejected)
                    }
                    call.exited(flag)
                    assertTrue(call.retained())
                    assertTrue(call.client.resourceBusy)
                }
                call.exited("writeExited")
                assertFalse(call.retained())
                assertFalse(call.client.resourceBusy)
                val deadline = SystemClock.elapsedRealtime() + 5000
                var settled = false
                while (!settled && SystemClock.elapsedRealtime() < deadline) {
                    instrumentation.runOnMainSync {
                        settled = AppBridge.operationId == null && AppBridge.runtimeState()["resultId"] == accepted
                    }
                    if (!settled) SystemClock.sleep(10)
                }
                assertTrue("Stop 必须在全部 I/O 结束后返回", settled)
            }
        } finally {
            instrumentation.runOnMainSync {
                fields.forEach { (name, field) -> field.set(AppBridge, previous[name]) }
                PseudoVpnService.core.setOperationBusy(AppBridge.runtimeState()["writerBusy"] == true)
            }
        }
    }

    @Test fun latePermissionResultCannotCompleteTheNextRequest() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            // Populate the pending reply state for result dispatch.
            val pending = BridgeTestState.field("authorization")
            val code = BridgeTestState.field("authorizationCode")
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
            val message = BridgeTestState.field("resultMessage")
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
            val id = BridgeTestState.field("operationId")
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
