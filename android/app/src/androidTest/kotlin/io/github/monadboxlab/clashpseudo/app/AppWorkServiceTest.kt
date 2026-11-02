package io.github.monadboxlab.clashpseudo.app

import io.github.monadboxlab.clashpseudo.message.AppMessage

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.WorkManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import io.github.monadboxlab.clashpseudo.backup.RestoreTransaction
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.bridge.BridgeTestState
import io.github.monadboxlab.clashpseudo.logic.LogicEngineHost
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class AppWorkServiceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private val original = "https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture"
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun field(name: String) = BridgeTestState.field(name)
    private fun hostField(name: String) = LogicEngineHost::class.java.getDeclaredField(name).apply { isAccessible = true }
    private fun waitUntil(condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 45_000
        while (true) {
            var ready = false
            main { ready = condition() }
            if (ready) return
            check(SystemClock.elapsedRealtime() < deadline) { "Service fixture did not drain" }
            SystemClock.sleep(20)
        }
    }

    @Before fun waitForStartup() {
        val manager = WorkManager.getInstance(context)
        val deadline = SystemClock.elapsedRealtime() + 45_000
        while (true) {
            val work = manager.getWorkInfosForUniqueWork("update-reconcile").get(5, TimeUnit.SECONDS)
            var idle = false
            main { idle = AppBridge.operationId == null && !AppBridge.logic.busy }
            if (work.isNotEmpty() && work.all { it.state.isFinished } && idle) return
            check(SystemClock.elapsedRealtime() < deadline) { "Startup reconciliation did not drain" }
            SystemClock.sleep(20)
        }
    }

    private class Messenger : BinaryMessenger {
        val entered = CountDownLatch(1)
        var callback: BinaryMessenger.BinaryReply? = null
        var cancellations = 0
        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            message!!.flip()
            val call = StandardMethodCodec.INSTANCE.decodeMethodCall(message)
            when (call.method) {
                "execute" -> { this.callback = callback; entered.countDown() }
                "cancel" -> cancellations++
                else -> respond(callback, null)
            }
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
        private fun respond(callback: BinaryMessenger.BinaryReply?, value: Any?) {
            val buffer = StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(value)
            buffer.flip()
            callback?.reply(buffer)
        }
        fun complete(value: Any?) {
            val receiver = callback
            callback = null
            respond(receiver, value)
        }
    }

    @Test fun serviceTimeoutAndDestructionKeepTheActualResultAndWriterDrain() {
        for (action in listOf("saveLocal", "updateResource")) {
            for (succeeded in listOf(true, false)) {
                val owner = UUID.randomUUID().toString()
                val names = listOf("logic", "operationId", "operationAdmittedAt", "command", "operation",
                    "resultId", "resultMessage", "resultSuccess", "configStatus", "overrideStatus",
                    "resourceStatus", "scheduleStatus", "connectionStatus", "targetId", "savedRevision",
                    "installedBackup", "restoreStopRequested", "restoreInterruption", "backupResult")
                val fields = names.associateWith(::field)
                var previous: Map<String, Any?> = emptyMap()
                lateinit var host: LogicEngineHost
                var hostCreated = false
                var runtime = 0L
                val observationOwner = UUID.randomUUID().toString()
                val messenger = Messenger()
                val connection = object : ServiceConnection {
                    override fun onServiceConnected(name: ComponentName, service: IBinder) {}
                    override fun onServiceDisconnected(name: ComponentName) {}
                }
                var bound = false
                var started = false
                val message = AppMessage("futureResult", mapOf("futureArgument" to original), original)
                val outcome = mapOf(
                    "success" to succeeded, "message" to message.toMap(),
                    "configStatus" to if (action == "saveLocal") "saved" else null,
                    "resourceStatus" to if (action == "updateResource") (if (succeeded) "ok" else "updateFailed") else null,
                    "targetId" to "fixture", "savedRevision" to 7,
                )
                try {
                    main {
                        assertNull(AppWorkService.instance)
                        assertNull(AppBridge.operationId)
                        assertFalse(AppBridge.logic.busy)
                        assertEquals("STOPPED", AppBridge.runtimeState()["phase"])
                        previous = fields.mapValues { it.value.get(AppBridge) }
                        host = LogicEngineHost(context.applicationContext as PseudoApplication)
                        hostCreated = true
                        runtime = hostField("serial").getLong(host)
                        hostField("engine").set(host, FlutterEngine(context, null, false))
                        hostField("ready").set(host, true)
                        hostField("channel").set(host, MethodChannel(messenger, "service-drain"))
                        host.retain(runtime, true, observationOwner)
                        fields.getValue("logic").set(AppBridge, host)
                        BridgeTestState.acceptOwner(owner)
                        fields.getValue("command").set(AppBridge, mapOf("action" to action))
                        fields.getValue("resultId").set(AppBridge, null)
                    }
                    bound = context.bindService(Intent(context, AppWorkService::class.java), connection, Context.BIND_AUTO_CREATE)
                    assertTrue(bound)
                    waitUntil { AppWorkService.instance != null }
                    assertNotNull(context.startService(Intent(context, AppWorkService::class.java)
                        .putExtra(AppWorkService.EXTRA_OWNER, owner)))
                    started = true
                    assertTrue(messenger.entered.await(5, TimeUnit.SECONDS))
                    main {
                        assertTrue(host.ownsOperation(owner))
                        AppWorkService.instance!!.onTimeout(1, 0)
                        assertEquals(owner, AppBridge.operationId)
                        assertTrue(host.busy)
                        assertEquals(true, AppBridge.runtimeState()["writerBusy"])
                        assertNull(AppBridge.runtimeState()["resultId"])
                        assertEquals(0L, AppBridge.operationRemainingMs(owner))
                        assertEquals(1, messenger.cancellations)
                        val backups = BridgeTestState.coordinator("backupCoordinator")
                        val lease = backups.javaClass.getDeclaredMethod("backupOwner", String::class.java,
                            Boolean::class.javaPrimitiveType).apply { isAccessible = true }
                            .invoke(backups, owner, false) as RestoreTransaction.Owner
                        try { lease.checkCurrent(); fail("Interrupted publication remained authorized") }
                        catch (_: CancellationException) { }
                    }
                    context.unbindService(connection)
                    bound = false
                    waitUntil { AppWorkService.instance == null }
                    main {
                        // The SDK Service is gone; the single executor still owns completion.
                        assertTrue(host.busy)
                        assertEquals(owner, AppBridge.operationId)
                        assertEquals(true, AppBridge.runtimeState()["writerBusy"])
                        messenger.complete(outcome)
                        assertFalse(host.busy)
                        assertNull(AppBridge.operationId)
                        val actual = AppBridge.runtimeState()
                        assertEquals(owner, actual["resultId"])
                        assertEquals(succeeded, actual["resultSuccess"])
                        assertEquals(message.toMap(), actual["resultMessage"])
                        assertEquals(outcome["resourceStatus"], actual["resourceStatus"])
                        assertEquals(outcome["configStatus"], actual["configStatus"])
                        assertEquals(false, actual["writerBusy"])
                    }
                } finally {
                    if (bound) context.unbindService(connection)
                    if (started) context.stopService(Intent(context, AppWorkService::class.java))
                    waitUntil { AppWorkService.instance == null }
                    main {
                        if (hostCreated) {
                            if (host.busy) messenger.complete(mapOf("success" to false))
                            assertFalse(host.busy)
                            host.retain(runtime, false, observationOwner)
                        }
                        previous.forEach { (name, value) -> fields.getValue(name).set(AppBridge, value) }
                        PseudoVpnService.core.setOperationBusy(AppBridge.operationId != null || AppBridge.logic.busy ||
                            AppBridge.runtimeState()["resourceBusy"] == true)
                    }
                    instrumentation.waitForIdleSync()
                    main { if (hostCreated) assertFalse(host.current(runtime)) }
                }
            }
        }
    }

    @Test fun interruptionBeforeDispatchSettlesAsUnexecutedWithItsActualMessage() {
        val names = listOf("logic", "operationId", "operationAdmittedAt", "command", "operation",
            "resultId", "resultMessage", "resultSuccess", "configStatus", "overrideStatus",
            "resourceStatus", "scheduleStatus", "connectionStatus", "targetId", "savedRevision",
            "installedBackup", "restoreStopRequested", "restoreInterruption", "backupResult")
        val fields = names.associateWith(::field)
        var previous: Map<String, Any?> = emptyMap()
        lateinit var host: LogicEngineHost
        var hostCreated = false
        var runtime = 0L
        val observationOwner = UUID.randomUUID().toString()
        val messenger = Messenger()
        val owner = UUID.randomUUID().toString()
        val message = AppMessage("futureInterruption", detail = original)
        try {
            main {
                assertNull(AppBridge.operationId)
                assertFalse(AppBridge.logic.busy)
                previous = fields.mapValues { it.value.get(AppBridge) }
                host = LogicEngineHost(context.applicationContext as PseudoApplication)
                hostCreated = true
                runtime = hostField("serial").getLong(host)
                hostField("engine").set(host, FlutterEngine(context, null, false))
                hostField("channel").set(host, MethodChannel(messenger, "queued-service-drain"))
                host.retain(runtime, true, observationOwner)
                fields.getValue("logic").set(AppBridge, host)
                BridgeTestState.acceptOwner(owner)
                val request = mapOf("action" to "saveLocal", "id" to "fixture")
                fields.getValue("command").set(AppBridge, request)
                var replies = 0
                host.execute(owner, request) { replies++; AppBridge.finish(owner, it) }
                assertTrue(host.busy)
                assertFalse(AppBridge.interruptOperation("old-owner", message))
                assertTrue(host.busy)
                assertTrue(AppBridge.interruptOperation(owner, message))
                assertEquals(1, replies)
                assertEquals(1L, messenger.entered.count)
                assertFalse(host.busy)
                assertNull(AppBridge.operationId)
                val actual = AppBridge.runtimeState()
                assertEquals("notSaved", actual["configStatus"])
                assertEquals(message.toMap(), actual["resultMessage"])
                assertEquals(false, actual["resultSuccess"])
                assertFalse(AppBridge.interruptOperation(owner, message))
                assertEquals(1, replies)
            }
        } finally {
            main {
                if (hostCreated) {
                    if (host.busy && !host.cancelBeforeExecution(owner, message)) {
                        messenger.complete(mapOf("success" to false))
                    }
                    assertFalse(host.busy)
                    host.retain(runtime, false, observationOwner)
                }
                previous.forEach { (name, value) -> fields.getValue(name).set(AppBridge, value) }
                PseudoVpnService.core.setOperationBusy(AppBridge.operationId != null || AppBridge.logic.busy ||
                    AppBridge.runtimeState()["resourceBusy"] == true)
            }
            instrumentation.waitForIdleSync()
            main { if (hostCreated) assertFalse(host.current(runtime)) }
        }
    }
}
