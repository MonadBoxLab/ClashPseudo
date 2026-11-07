package io.github.monadboxlab.clashpseudo.bridge.backup

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.backup.BackupCalls
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.bridge.BridgeTestState
import io.github.monadboxlab.clashpseudo.logic.LogicEngineHost
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CoreLifecycleCalls
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.util.UUID
import java.util.concurrent.CancellationException
import org.junit.Assert.*
import org.junit.Test

class BackupBridgeStopTest {
    private class Reply : MethodChannel.Result {
        val values = mutableListOf<Any?>()
        override fun success(value: Any?) { values.add(value) }
        override fun error(code: String, message: String?, details: Any?) { fail("Reply contains an error: $code") }
        override fun notImplemented() { fail("Missing MethodChannel method") }
    }

    private fun field(name: String) = BridgeTestState.field(name)
    private class Fixture(
        val owner: String,
        val command: Map<String, Any?>,
        val installed: Pair<String, Map<String, Any?>>,
        val token: String,
        val logic: LogicEngineHost,
        val permission: Reply,
        val stopReply: Reply,
        val systemOwner: String,
    ) {
        lateinit var coordinator: BackupCoordinator
        var refreshPending = true
        var refreshCancellations = 0
        fun backupField(name: String) = BackupCoordinator::class.java.getDeclaredField(name).apply { isAccessible = true }
        fun backupValue(name: String): Any? = backupField(name).get(coordinator)
    }

    private fun afterStartupScheduleSync(action: () -> Unit) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val deadline = SystemClock.elapsedRealtime() + 30_000L
        var completed = false
        while (!completed) {
            instrumentation.runOnMainSync {
                val syncing = AppBridge.command?.get("action") == "syncSchedules" &&
                    (AppBridge.operationId != null || AppBridge.logic.busy || AppBridge.operations.executorBusy)
                if (syncing) {
                    assertTrue("Startup schedule synchronization did not drain: operationId=${AppBridge.operationId}, " +
                        "command=${AppBridge.command}, logicBusy=${AppBridge.logic.busy}, " +
                        "executorBusy=${AppBridge.operations.executorBusy}", SystemClock.elapsedRealtime() < deadline)
                    return@runOnMainSync
                }
                // Admission cannot race the fixture after this main-thread check.
                action()
                completed = true
            }
            if (!completed) SystemClock.sleep(25)
        }
    }

    private fun withRestore(action: (Fixture) -> Unit) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        afterStartupScheduleSync {
            val context = instrumentation.targetContext
            CoreIpcTestDriver.assertNoGoInApplication()
            assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
            assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
            val names = listOf("operationId", "operationAdmittedAt", "operationDeadline", "command", "authorization", "authorizationCode",
                "systemRestoreOwner")
            val old = names.associateWith { field(it).get(AppBridge) }
            val logic = AppBridge.logic
            val pending = LogicEngineHost::class.java.getDeclaredField("pending").apply { isAccessible = true }
            val executing = LogicEngineHost::class.java.getDeclaredField("executing").apply { isAccessible = true }
            val oldPending = pending.get(logic)
            val oldExecuting = executing.getBoolean(logic)
            val oldAdmitted = AppBridge.operations.admitted
            assertNull("Restore fixture requires idle admission: command=${AppBridge.command}, " +
                "systemRestoreOwner=${old["systemRestoreOwner"]}, logicBusy=${logic.busy}", old["operationId"])
            assertNull(old["authorization"])
            assertNull(old["systemRestoreOwner"])
            assertNull(oldPending)
            assertFalse(oldExecuting)
            assertFalse("Restore fixture requires a drained executor", AppBridge.operations.executorBusy)
            val owner = "backup-stop-test-${UUID.randomUUID()}"
            val token = UUID.randomUUID().toString()
            val command = mapOf("action" to "restoreBackup", "token" to token, "storageEpoch" to 7L)
            val f = Fixture(owner, command, owner to mapOf("committed" to true, "ready" to true, "epoch" to 8L),
                token, logic, Reply(), Reply(), "waiting-system-test-${UUID.randomUUID()}")
            f.coordinator = BackupCoordinator(context, Handler(Looper.getMainLooper()), AppBridge.operations,
                { BackupCalls.get(context) {} }, { CoreLifecycleCalls(context) }, logic,
                { false }, { false }, {}, { false }, {},
                { AppBridge.authorizationResult(1000, false) },
                { f.refreshCancellations++; f.refreshPending = false },
                { AppBridge.cancelSystemRestore() },
                { field("systemRestoreOwner").get(AppBridge) as? String }, {})
            val workClass = LogicEngineHost::class.java.declaredClasses.single { it.simpleName == "Work" }
            val reply: (Map<*, *>) -> Unit = { fail("A running restore must retain its actual completion waiter") }
            val work = workClass.declaredConstructors.single { it.parameterTypes.size == 3 }.apply { isAccessible = true }
                .newInstance(owner, command, reply)
            try {
                BridgeTestState.acceptOwner(owner)
                AppBridge.operations.command = command
                field("authorization").set(AppBridge, f.permission)
                field("authorizationCode").setInt(AppBridge, 1000)
                f.backupField("restoreStopRequested").setBoolean(f.coordinator, false)
                f.backupField("restoreStopOwner").set(f.coordinator, owner)
                f.backupField("restoreStopReply").set(f.coordinator, f.stopReply)
                f.backupField("installedBackup").set(f.coordinator, f.installed)
                field("systemRestoreOwner").set(AppBridge, f.systemOwner)
                @Suppress("UNCHECKED_CAST")
                (f.backupValue("backupUses") as MutableMap<String, String>)[owner] = token
                pending.set(logic, work)
                executing.setBoolean(logic, true)
                action(f)
            } finally {
                pending.set(logic, oldPending)
                executing.setBoolean(logic, oldExecuting)
                old.forEach { (name, value) -> field(name).set(AppBridge, value) }
                AppBridge.operations.admitted = oldAdmitted
                PseudoVpnService.core.setOperationBusy(AppBridge.runtimeState()["writerBusy"] == true)
                CoreIpcTestDriver.assertNoGoInApplication()
            }
        }
    }

    private fun unchangedExecution(f: Fixture) {
        assertEquals(f.owner, AppBridge.operationId)
        assertSame(f.command, AppBridge.command)
        assertSame(f.installed, f.backupValue("installedBackup"))
        assertEquals(f.token, (f.backupValue("backupUses") as Map<*, *>)[f.owner])
        assertEquals(f.owner, f.backupValue("restoreStopOwner"))
        assertSame(f.stopReply, f.backupValue("restoreStopReply"))
        assertTrue(f.stopReply.values.isEmpty())
        assertTrue("Executor has not actually exited", f.logic.busy)
    }

    @Test fun elapsedBudgetRejectsNewRestorePublicationBeforeTheTimerRuns() = withRestore { f ->
        val admission = f.coordinator.backupOwner(f.owner, true)
        admission.checkCurrent()
        field("operationDeadline").set(AppBridge, android.os.SystemClock.elapsedRealtime() - 1L)
        assertThrows(CancellationException::class.java) { admission.runIfCurrent { fail("An expired restore published data") } }
        unchangedExecution(f)
    }

    @Test fun cancellationEndsPermissionWaitButKeepsRealExecutionAndUnrelatedNetworkIntent() = withRestore { f ->
        val admission = f.coordinator.backupOwner(f.owner, true)
        admission.checkCurrent()
        f.coordinator.requestRestoreStop(f.owner, false)
        assertEquals(listOf(false), f.permission.values)
        assertNull(field("authorization").get(AppBridge))
        assertTrue(f.refreshPending)
        assertEquals(0, f.refreshCancellations)
        assertEquals(f.systemOwner, field("systemRestoreOwner").get(AppBridge))
        unchangedExecution(f)
        assertThrows(CancellationException::class.java) { admission.runIfCurrent { fail("A cancelled restore published a new commit") } }
        AppBridge.authorizationResult(1000, true)
        assertEquals(listOf(false), f.permission.values)
        val next = Reply()
        field("authorizationCode").setInt(AppBridge, 1001)
        field("authorization").set(AppBridge, next)
        AppBridge.authorizationResult(1000, true)
        assertTrue(next.values.isEmpty())
        assertSame(next, field("authorization").get(AppBridge))
        AppBridge.authorizationResult(1001, false)
        assertEquals(listOf(false), next.values)
    }

    @Test fun explicitNetworkStopAlsoWithdrawsQueuedRefreshAndWaitingSystemIntentWithoutReplacingRestore() = withRestore { f ->
        f.coordinator.requestRestoreStop(f.owner, true)
        assertEquals(listOf(false), f.permission.values)
        assertFalse(f.refreshPending)
        assertEquals(1, f.refreshCancellations)
        assertNull(field("systemRestoreOwner").get(AppBridge))
        assertTrue(f.coordinator.stopRequested)
        unchangedExecution(f)
    }

    @Test fun staleStopCannotCancelCurrentPermissionOrTouchCurrentRestore() = withRestore { f ->
        f.coordinator.requestRestoreStop("stale-owner", true)
        assertTrue(f.permission.values.isEmpty())
        assertSame(f.permission, field("authorization").get(AppBridge))
        assertFalse(f.coordinator.stopRequested)
        assertTrue(f.refreshPending)
        assertEquals(0, f.refreshCancellations)
        assertEquals(f.systemOwner, field("systemRestoreOwner").get(AppBridge))
        unchangedExecution(f)
    }
}
