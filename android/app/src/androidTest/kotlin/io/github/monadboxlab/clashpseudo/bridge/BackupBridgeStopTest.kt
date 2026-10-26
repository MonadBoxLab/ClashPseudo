package io.github.monadboxlab.clashpseudo.bridge

import io.github.monadboxlab.clashpseudo.backup.RestoreTransaction
import io.github.monadboxlab.clashpseudo.logic.LogicEngineHost

import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.util.UUID
import java.util.concurrent.CancellationException
import org.junit.Assert.*
import org.junit.Test

/**
 * Tests main-thread bridge state with an executing Work, a retained Stop waiter and
 * in-memory commit/pin sentinels.
 */
class BackupBridgeStopTest {
    private class Reply : MethodChannel.Result {
        val values = mutableListOf<Any?>()
        override fun success(value: Any?) { values.add(value) }
        override fun error(code: String, message: String?, details: Any?) { fail("Unexpected reply error") }
        override fun notImplemented() { fail("Unexpected missing method") }
    }

    private fun field(name: String) = AppBridge::class.java.getDeclaredField(name).apply { isAccessible = true }
    private val stop = AppBridge::class.java.getDeclaredMethod(
        "requestRestoreStop", String::class.java, Boolean::class.javaPrimitiveType,
    ).apply { isAccessible = true }
    private val makeOwner = AppBridge::class.java.getDeclaredMethod(
        "backupOwner", String::class.java, Boolean::class.javaPrimitiveType,
    ).apply { isAccessible = true }

    private class Fixture(
        val owner: String,
        val command: Map<String, Any?>,
        val installed: Pair<String, Map<String, Any?>>,
        val token: String,
        val logic: LogicEngineHost,
        val permission: Reply,
        val stopReply: Reply,
        val refresh: Any,
        val systemOwner: String,
    )

    private fun withRestore(action: (Fixture) -> Unit) {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            assertNull("Run only when no VPN service exists", PseudoVpnService.instance)
            assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
            assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
            val names = listOf("operationId", "operationAdmittedAt", "command", "authorization", "authorizationCode",
                "restoreStopRequested", "restoreStopOwner", "restoreStopReply", "installedBackup",
                "pendingRuntimeRefresh", "systemRestoreOwner")
            val old = names.associateWith { field(it).get(AppBridge) }
            val logic = field("logic").get(AppBridge) as LogicEngineHost
            val pending = LogicEngineHost::class.java.getDeclaredField("pending").apply { isAccessible = true }
            val executing = LogicEngineHost::class.java.getDeclaredField("executing").apply { isAccessible = true }
            val oldPending = pending.get(logic)
            val oldExecuting = executing.getBoolean(logic)
            @Suppress("UNCHECKED_CAST")
            val pins = field("backupUses").get(AppBridge) as MutableMap<String, String>
            assertNull(old["operationId"])
            assertNull(old["authorization"])
            assertNull(old["restoreStopOwner"])
            assertNull(old["systemRestoreOwner"])
            assertNull(old["pendingRuntimeRefresh"])
            assertNull(oldPending)
            assertFalse(oldExecuting)
            val owner = "backup-stop-test-${UUID.randomUUID()}"
            val token = UUID.randomUUID().toString()
            val command = mapOf("action" to "restoreBackup", "token" to token, "storageEpoch" to 7L)
            val installed = owner to mapOf<String, Any?>("committed" to true, "ready" to true, "epoch" to 8L)
            val permission = Reply()
            val stopReply = Reply()
            val refreshClass = AppBridge::class.java.declaredClasses.single { it.simpleName == "RuntimeRefresh" }
            val refresh = refreshClass.declaredConstructors.single { it.parameterTypes.size == 4 }.apply {
                isAccessible = true
            }.newInstance(0L, 0L, "test", mutableMapOf("routes" to 1L))
            val workClass = LogicEngineHost::class.java.declaredClasses.single { it.simpleName == "Work" }
            val reply: (Map<*, *>) -> Unit = { fail("An executing restore must keep its real completion waiter") }
            val work = workClass.declaredConstructors.single { it.parameterTypes.size == 3 }.apply {
                isAccessible = true
            }.newInstance(owner, command, reply)
            val systemOwner = "waiting-system-test-${UUID.randomUUID()}"
            try {
                AppBridge::class.java.getDeclaredMethod("setOperationId", String::class.java).apply {
                    isAccessible = true
                }.invoke(AppBridge, owner)
                field("command").set(AppBridge, command)
                field("authorization").set(AppBridge, permission)
                field("authorizationCode").setInt(AppBridge, 1000)
                field("restoreStopRequested").setBoolean(AppBridge, false)
                field("restoreStopOwner").set(AppBridge, owner)
                field("restoreStopReply").set(AppBridge, stopReply)
                field("installedBackup").set(AppBridge, installed)
                field("pendingRuntimeRefresh").set(AppBridge, refresh)
                field("systemRestoreOwner").set(AppBridge, systemOwner)
                pins[owner] = token
                pending.set(logic, work)
                executing.setBoolean(logic, true)
                action(Fixture(owner, command, installed, token, logic, permission, stopReply, refresh, systemOwner))
            } finally {
                pins.remove(owner)
                pending.set(logic, oldPending)
                executing.setBoolean(logic, oldExecuting)
                old.forEach { (name, value) -> field(name).set(AppBridge, value) }
                PseudoVpnService.core.setOperationBusy(AppBridge.runtimeState()["writerBusy"] == true)
            }
        }
    }

    private fun unchangedExecution(f: Fixture) {
        assertEquals(f.owner, AppBridge.operationId)
        assertSame(f.command, field("command").get(AppBridge))
        assertSame(f.installed, field("installedBackup").get(AppBridge))
        assertEquals(f.token, (field("backupUses").get(AppBridge) as Map<*, *>)[f.owner])
        assertEquals(f.owner, field("restoreStopOwner").get(AppBridge))
        assertSame(f.stopReply, field("restoreStopReply").get(AppBridge))
        assertTrue(f.stopReply.values.isEmpty())
        assertTrue("No early executor drain", f.logic.busy)
    }

    @Test fun elapsedBudgetRejectsNewRestorePublicationBeforeTheTimerRuns() = withRestore { f ->
        val admission = makeOwner.invoke(AppBridge, f.owner, true) as RestoreTransaction.Owner
        admission.checkCurrent()
        field("operationAdmittedAt").set(AppBridge, android.os.SystemClock.elapsedRealtime() - 300_000L)
        assertThrows(CancellationException::class.java) {
            admission.runIfCurrent { fail("Expired restore published") }
        }
        unchangedExecution(f)
    }

    @Test fun cancellationEndsPermissionWaitButKeepsRealExecutionAndUnrelatedNetworkIntent() = withRestore { f ->
        val admission = makeOwner.invoke(AppBridge, f.owner, true) as RestoreTransaction.Owner
        admission.checkCurrent()
        stop.invoke(AppBridge, f.owner, false)
        assertEquals(listOf(false), f.permission.values)
        assertNull(field("authorization").get(AppBridge))
        assertSame(f.refresh, field("pendingRuntimeRefresh").get(AppBridge))
        assertEquals(f.systemOwner, field("systemRestoreOwner").get(AppBridge))
        unchangedExecution(f)
        try { admission.runIfCurrent { fail("Stop must prevent new commit admission") }; fail("Expected cancellation") }
        catch (_: CancellationException) { /* Already committed sentinel is still preserved above. */ }
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
        stop.invoke(AppBridge, f.owner, true)
        assertEquals(listOf(false), f.permission.values)
        assertNull(field("pendingRuntimeRefresh").get(AppBridge))
        assertNull(field("systemRestoreOwner").get(AppBridge))
        assertTrue(field("restoreStopRequested").getBoolean(AppBridge))
        unchangedExecution(f)
    }

    @Test fun staleStopCannotCancelCurrentPermissionOrTouchCurrentRestore() = withRestore { f ->
        stop.invoke(AppBridge, "stale-owner", true)
        assertTrue(f.permission.values.isEmpty())
        assertSame(f.permission, field("authorization").get(AppBridge))
        assertFalse(field("restoreStopRequested").getBoolean(AppBridge))
        assertSame(f.refresh, field("pendingRuntimeRefresh").get(AppBridge))
        assertEquals(f.systemOwner, field("systemRestoreOwner").get(AppBridge))
        unchangedExecution(f)
    }
}
