package io.github.monadboxlab.clashpseudo.logic

import io.github.monadboxlab.clashpseudo.app.PseudoApplication
import io.github.monadboxlab.clashpseudo.bridge.AppBridge

import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

class LogicEngineHostTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val application get() = instrumentation.targetContext.applicationContext as PseudoApplication
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun field(name: String) = LogicEngineHost::class.java.getDeclaredField(name).apply { isAccessible = true }

    private class Reply : MethodChannel.Result {
        var value: Any? = null
        var error: String? = null
        var replies = 0
        override fun success(result: Any?) { value = result; replies++ }
        override fun error(code: String, message: String?, details: Any?) { error = code; replies++ }
        override fun notImplemented() { error = "missing"; replies++ }
    }

    private class Messenger : BinaryMessenger {
        var call: MethodCall? = null
        var reply: BinaryMessenger.BinaryReply? = null
        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            message!!.flip()
            call = StandardMethodCodec.INSTANCE.decodeMethodCall(message)
            reply = callback
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
        fun complete(value: Any?) {
            val buffer = StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(value)
            buffer.flip()
            reply!!.reply(buffer)
        }
    }

    private class RestoreMessenger : BinaryMessenger {
        val restoreDispatched = CountDownLatch(1)
        var executeReply: BinaryMessenger.BinaryReply? = null
        var executes = 0
        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            message!!.flip()
            val call = StandardMethodCodec.INSTANCE.decodeMethodCall(message)
            if (call.method == "execute") {
                executeReply = callback
                executes++
                if ((call.arguments as Map<*, *>)["action"] == "systemStart") restoreDispatched.countDown()
            } else {
                respond(callback, if (call.method == "runtimeState") mapOf("retain" to true) else null)
            }
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
        private fun respond(callback: BinaryMessenger.BinaryReply?, value: Any?) {
            val buffer = StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(value)
            buffer.flip()
            callback?.reply(buffer)
        }
        fun complete(value: Any?) {
            val callback = executeReply
            executeReply = null
            respond(callback, value)
        }
    }

    @Test fun coldProcessExecutesRealDartAndReturnsWithoutPreparingCore() {
        // Run this method alone in a fresh instrumentation process. A warm loader
        // fails the cold-start precondition.
        val owner = UUID.randomUUID().toString()
        val operationId = AppBridge::class.java.getDeclaredField("operationId").apply { isAccessible = true }
        val completed = CountDownLatch(1)
        val replies = AtomicInteger()
        val outcome = AtomicReference<Map<*, *>?>()
        lateinit var host: LogicEngineHost
        var admitted = false
        var sessionGeneration = -1L
        var beforeCore: CoreHost.Snapshot? = null
        try {
            main {
                assertNull(AppBridge.operationId)
                assertNull(AppBridge.command)
                assertFalse(AppBridge.pendingSystemRestore)
                val session = PseudoVpnService.session.snapshot()
                assertEquals(NativeSession.Phase.STOPPED, session.phase)
                sessionGeneration = session.generation
                beforeCore = PseudoVpnService.core.snapshot()
                assertEquals(CoreHost.Phase.EMPTY, beforeCore!!.phase)
                host = AppBridge.logic
                assertFalse(host.busy)
                assertFalse("Cold test requires no prior Flutter initialization",
                    FlutterInjector.instance().flutterLoader().initialized())
                // Hold the process writer gate while exercising the real host, loader,
                // engine and channel.
                operationId.set(AppBridge, owner)
                admitted = true
                // The resource handler receives an unavailable core identity and
                // returns its semantic result.
                host.execute(owner, mapOf("action" to "updateResource")) { actual ->
                    outcome.set(actual)
                    replies.incrementAndGet()
                    completed.countDown()
                }
            }
            assertTrue("Actual Dart execution did not return", completed.await(30, TimeUnit.SECONDS))
            val actual = checkNotNull(outcome.get())
            // The assertion requires the Dart resourceStatus result from the started
            // engine.
            assertEquals("Expected the actual Dart unavailable-resource reply",
                "unconfirmed", actual["resourceStatus"])
            assertEquals(false, actual["success"])
            main {
                assertTrue(FlutterInjector.instance().flutterLoader().initialized())
                assertFalse("The real execute call has not drained", host.busy)
                assertEquals(beforeCore, PseudoVpnService.core.snapshot())
                val session = PseudoVpnService.session.snapshot()
                assertEquals(NativeSession.Phase.STOPPED, session.phase)
                assertEquals(sessionGeneration, session.generation)
                assertEquals(1, replies.get())
            }
        } finally {
            if (admitted) main {
                if (AppBridge.operationId == owner) {
                    operationId.set(AppBridge, null)
                    // An executing call retains the actual drain gate on timeout.
                    host.cancel(owner)
                    AppBridge.notifyUi()
                }
            }
        }
    }

    @Test fun restoreWaitsForActualWriterDrainAndCancelledPreparationCannotRestart() {
        lateinit var host: LogicEngineHost
        lateinit var engine: FlutterEngine
        lateinit var original: LogicEngineHost
        val messenger = RestoreMessenger()
        val logicField = AppBridge::class.java.getDeclaredField("logic").apply { isAccessible = true }
        val id = AppBridge::class.java.getDeclaredField("operationId").apply { isAccessible = true }
        val prepared = CountDownLatch(1)
        main {
            assertNull(AppBridge.operationId)
            assertFalse(AppBridge.pendingSystemRestore)
            assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
            original = AppBridge.logic
            host = LogicEngineHost(application)
            engine = FlutterEngine(application, null, false)
            field("engine").set(host, engine)
            field("ready").set(host, true)
            field("retained").set(host, true)
            field("channel").set(host, MethodChannel(messenger, "restore-test"))
            logicField.set(AppBridge, host)
            id.set(AppBridge, "test-previous-writer")
            host.execute("test-previous-writer", mapOf("action" to "test")) {}
            AppBridge.restoreSystemStart { assertNull(it); prepared.countDown() }
            // The writer remains busy until the actual Dart execution returns.
            id.set(AppBridge, null)
            assertTrue(host.busy)
            assertTrue(AppBridge.pendingSystemRestore)
        }
        try {
            Thread.sleep(180)
            main {
                assertEquals(1, messenger.executes)
                assertTrue(AppBridge.pendingSystemRestore)
                messenger.complete(mapOf("success" to true))
            }
            assertTrue(messenger.restoreDispatched.await(2, TimeUnit.SECONDS))
            main {
                assertEquals(2, messenger.executes)
                assertTrue(host.busy)
                assertTrue(AppBridge.cancelSystemRestore())
                assertNull(AppBridge.operationId)
                assertEquals(true, AppBridge.runtimeState()["writerBusy"])
                assertTrue(host.busy)
                // The cancelled owner's late start descriptor is discarded.
                messenger.complete(mapOf("success" to true, "systemStart" to mapOf(
                    "id" to "one", "revision" to 1, "mode" to "rule")))
            }
            assertTrue(prepared.await(2, TimeUnit.SECONDS))
            main {
                assertFalse(host.busy)
                assertNull(AppBridge.operationId)
                assertFalse(AppBridge.pendingSystemRestore)
                assertEquals(false, AppBridge.runtimeState()["writerBusy"])
            }
        } finally {
            main {
                AppBridge.cancelSystemRestore()
                id.set(AppBridge, null)
                logicField.set(AppBridge, original)
                field("engine").set(host, null)
                engine.destroy()
            }
        }
    }

    @Test fun stoppedTrafficReturnsEmptyWithoutStartingAnEngine() = main {
        assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
        val host = LogicEngineHost(application)
        val traffic = Reply()
        host.traffic(traffic)
        assertEquals(1, traffic.replies)
        assertNull(traffic.error)
        val value = traffic.value as Map<*, *>
        assertEquals(false, value["fresh"])
        assertEquals(emptyList<Any>(), value["points"])
        assertFalse(value.containsKey("connections"))
        assertNull(field("engine").get(host))
        val connections = Reply()
        host.connections(null, connections)
        assertTrue((connections.value as Map<*, *>).containsKey("connections"))
        assertNull(field("engine").get(host))
    }

    @Test fun trafficKeepsEngineUntilReplyAndSharesQueryGate() = main {
        assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
        val host = LogicEngineHost(application)
        val engine = FlutterEngine(application, null, false)
        val messenger = Messenger()
        field("engine").set(host, engine)
        field("ready").set(host, true)
        field("channel").set(host, MethodChannel(messenger, "traffic-test"))
        try {
            val traffic = Reply()
            host.traffic(traffic)
            assertEquals("traffic", messenger.call!!.method)
            val args = messenger.call!!.arguments as Map<*, *>
            assertTrue(args.containsKey("state"))
            assertFalse(args.containsKey("detail"))
            assertSame(engine, field("engine").get(host))
            assertEquals(true, field("querying").get(host))
            val other = Reply()
            host.connections(null, other)
            assertEquals("waiting", other.error)
            messenger.complete(mapOf("points" to emptyList<Any>(), "fresh" to false))
            assertEquals(1, traffic.replies)
            assertNull(traffic.error)
            assertFalse((traffic.value as Map<*, *>).containsKey("connections"))
            assertEquals(false, field("querying").get(host))
            assertNull(field("engine").get(host))
        } finally {
            if (field("engine").get(host) != null) {
                engine.destroy()
                field("engine").set(host, null)
            }
        }
    }
}
