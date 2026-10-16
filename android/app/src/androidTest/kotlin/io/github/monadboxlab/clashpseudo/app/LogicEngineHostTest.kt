package io.github.monadboxlab.clashpseudo.app

import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.nio.ByteBuffer
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
