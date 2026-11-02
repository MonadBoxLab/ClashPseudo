package io.github.monadboxlab.clashpseudo.bridge.runtime

import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.bridge.BridgeTestState
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class SystemRestoreTest {
    @Test fun successfulSystemRestoreSettlesItsOwnerWithoutLeavingPendingStart() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val names = listOf("operationId", "operationAdmittedAt", "operationDeadline", "systemRestoreOwner", "command", "operation",
                "resultId", "resultMessage", "resultSuccess")
            val fields = names.associateWith(BridgeTestState::field)
            val previous = fields.mapValues { it.value.get(AppBridge) }
            try {
                assertNull(AppBridge.operationId)
                fields.getValue("operationId").set(AppBridge, "restore-success-owner")
                fields.getValue("systemRestoreOwner").set(AppBridge, "restore-success-owner")
                fields.getValue("command").set(AppBridge, mapOf("action" to "systemStart"))
                fields.getValue("operation").set(AppBridge, AppMessage("preparingSystemStart"))
                fields.getValue("resultId").set(AppBridge, "previous-failure")
                fields.getValue("resultMessage").set(AppBridge, AppMessage("noConfigForSystemStart"))
                var replies = 0
                (BridgeTestState.coordinator("systemRestore") as SystemRestore)
                    .completeSystemRestore("restore-success-owner", mapOf("success" to true)) { reply ->
                        replies++
                        assertEquals(mapOf("started" to true), reply)
                    }
                assertEquals(1, replies)
                assertNull(AppBridge.operationId)
                assertNull(AppBridge.command)
                assertFalse(AppBridge.pendingSystemRestore)
                val state = AppBridge.runtimeState()
                assertEquals(false, state["pendingStart"])
                assertEquals(false, state["pendingSystemStart"])
                assertEquals(true, state["resultSuccess"])
                assertNull(state["resultId"])
                assertNull(state["resultMessage"])
            } finally {
                fields.forEach { (name, field) -> field.set(AppBridge, previous[name]) }
                PseudoVpnService.core.setOperationBusy(AppBridge.operationId != null || AppBridge.logic.busy ||
                    AppBridge.runtimeState()["resourceBusy"] == true)
            }
        }
    }

    @Test fun failedSystemRestoreCannotInheritAnEarlierSuccessOrOverwriteANewerOwner() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val names = listOf("operationId", "operationAdmittedAt", "operationDeadline", "systemRestoreOwner", "command", "operation",
                "resultId", "resultMessage", "resultSuccess")
            val fields = names.associateWith { name ->
                BridgeTestState.field(name)
            }
            val previous = fields.mapValues { it.value.get(AppBridge) }
            val coordinator = BridgeTestState.coordinator("systemRestore") as SystemRestore
            try {
                assertNull(AppBridge.operationId)
                fields.getValue("operationId").set(AppBridge, "restore-owner")
                fields.getValue("systemRestoreOwner").set(AppBridge, "restore-owner")
                fields.getValue("resultSuccess").setBoolean(AppBridge, true)
                fields.getValue("resultMessage").set(AppBridge, AppMessage("tunnelStarted"))
                var replies = 0
                val reply: (Map<String, Any?>?) -> Unit = { assertNull(it); replies++ }
                coordinator.completeSystemRestore("restore-owner", mapOf("success" to false,
                    "message" to AppMessage("noConfigForSystemStart").toMap()), reply)
                assertEquals(1, replies)
                val failed = AppBridge.runtimeState()
                assertEquals(false, failed["resultSuccess"])
                assertEquals("restore-owner", failed["resultId"])
                assertEquals("noConfigForSystemStart", (failed["resultMessage"] as Map<*, *>)["id"])
                fields.getValue("operationId").set(AppBridge, "new-owner")
                fields.getValue("systemRestoreOwner").set(AppBridge, "new-owner")
                coordinator.completeSystemRestore("restore-owner", mapOf("success" to true), reply)
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

    @Test fun busySystemRestoreWaitsAndCancellationPreservesTheCurrentWriter() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val done = CountDownLatch(1)
        val replies = AtomicInteger()
        val id = BridgeTestState.field("operationId")
        val discarded = BridgeTestState.field("discardedSystemInput")
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
        val id = BridgeTestState.field("operationId")
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
}
