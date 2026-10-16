package io.github.monadboxlab.clashpseudo.app

import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.CoreInput
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ConnectionsCallsTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private val input = CoreInput("one", 1, "rule", byteArrayOf(), "{}".toByteArray())
    private val id = "00000001-0000-4000-8000-000000000000"
    private val json = """{"uploadTotal":9000000,"downloadTotal":0,"activeCount":2000,"complete":true,"limited":false,"presence":{"$id":true},"connections":[
        {"id":"$id","start":"2026-10-15T00:00:00Z","chains":["节点🌐","出口"],"upload":2,"download":3,"metadata":{"host":"fixture.test","type":"Tun"}}
    ]}"""

    private class Harness {
        val session = NativeSession()
        val tasks = LinkedBlockingQueue<Runnable>()
        val reads = AtomicInteger()
        val closes = AtomicInteger()
        val queries = AtomicReference<ByteArray>()
        lateinit var core: CoreHost
        lateinit var calls: ConnectionsCalls
        var generation = 0L
        var vpn = 0L
    }
    private class Reply {
        val done = CountDownLatch(1)
        val count = AtomicInteger()
        val error = AtomicReference<String?>()
        val value = AtomicReference<String?>()
        fun accept(result: String?, failure: String?) {
            count.incrementAndGet(); value.set(result); error.set(failure); done.countDown()
        }
        fun await() { assertTrue(done.await(2, TimeUnit.SECONDS)) }
    }
    private fun harness(
        close: (() -> String)? = null,
        read: (() -> String)? = null,
    ): Harness {
        val h = Harness()
        main {
            h.core = CoreHost(h.session, {}, Executor { h.tasks.add(it) },
                prepareNative = { _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {})
            h.core.setVisible(true)
            h.calls = ConnectionsCalls(h.core,
                { request -> h.reads.incrementAndGet(); h.queries.set(request); read?.invoke() ?: json },
                { h.closes.incrementAndGet(); close?.invoke() ?: """{"status":"closed"}""" },
                100)
        }
        h.vpn = h.session.begin("one", 1)!!
        h.generation = h.core.prepareVpn(h.vpn, "one", 1, "unused", { input }, Any()).generation
        h.session.attached(h.vpn)
        return h
    }
    private fun read(
        h: Harness,
        reply: Reply,
        parameters: Map<String, Any?> = mapOf("limit" to 1000),
    ) = main { h.calls.read(h.generation, "one", 1, parameters, reply::accept) }
    private fun close(h: Harness, reply: Reply, target: String = "") =
        main { h.calls.disconnect(h.generation, "one", 1, target.ifEmpty { id }, "owner", reply::accept) }

    @Test fun forwardsBoundedQueryAndAddsMonotonicIdentity() {
        val h = harness()
        val reply = Reply()
        read(h, reply, mapOf("limit" to 1000, "previousActiveIds" to listOf(id)))
        h.tasks.take().run()
        reply.await()
        assertNull(reply.error.get())
        val request = JSONObject(String(h.queries.get(), Charsets.UTF_8))
        assertEquals(1000, request.getInt("limit"))
        assertEquals(id, request.getJSONArray("previousActiveIds").getString(0))
        val result = JSONObject(reply.value.get()!!)
        assertEquals(h.generation, result.getLong("generation"))
        assertEquals("one", result.getString("configId"))
        assertEquals(1, result.getInt("revision"))
        assertTrue(result.getLong("elapsedMs") >= 0)
        assertTrue(result.getLong("observedAt") > 0)
        assertEquals(9000000L, result.getLong("uploadTotal"))
        assertEquals(0L, result.getLong("downloadTotal"))
        assertEquals(2000, result.getInt("activeCount"))
        assertEquals("节点🌐", result.getJSONArray("connections")
            .getJSONObject(0).getJSONArray("chains").getString(0))
        assertEquals(1, reply.count.get())
    }

    @Test fun oversizedQueryIsRejectedBeforeNative() {
        val h = harness()
        val reply = Reply()
        read(h, reply, mapOf("previousActiveIds" to List(4000) { id }))
        reply.await()
        assertNotNull(reply.error.get())
        assertEquals(0, h.reads.get())
        assertEquals(0, h.tasks.size)
    }

    @Test fun incompleteOrOversizedNativeSampleIsFailure() {
        val h = harness { """{"complete":false,"presence":{},"connections":[]}""" }
        val reply = Reply()
        read(h, reply)
        h.tasks.take().run()
        reply.await()
        assertNotNull(reply.error.get())
        assertNull(reply.value.get())
    }

    @Test fun timeoutDoesNotQueueMoreReadsOrStopVpn() {
        val h = harness()
        val first = Reply()
        read(h, first)
        first.await()
        assertNotNull(first.error.get())
        val second = Reply()
        read(h, second)
        second.await()
        assertEquals(1, h.tasks.size)
        h.tasks.take().run()
        instrumentation.waitForIdleSync()
        assertEquals(0, h.reads.get())
        assertEquals(1, first.count.get())
        assertEquals(NativeSession.Phase.RUNNING, h.session.snapshot().phase)
        val next = Reply()
        read(h, next)
        h.tasks.take().run()
        next.await()
        assertNull(next.error.get())
    }

    @Test fun checksIdentityBeforeExecution() {
        val h = harness()
        val reply = Reply()
        read(h, reply)
        h.session.stopping(h.vpn)
        h.tasks.take().run()
        reply.await()
        assertNotNull(reply.error.get())
        assertEquals(0, h.reads.get())
    }

    @Test fun checksIdentityAgainBeforeDelivery() {
        lateinit var h: Harness
        h = harness { h.session.stopping(h.vpn); json }
        val reply = Reply()
        read(h, reply)
        h.tasks.take().run()
        reply.await()
        assertNull(reply.value.get())
        assertNotNull(reply.error.get())
        assertEquals(1, h.reads.get())
    }

    @Test fun inProgressTimeoutRetainsSlotAndDropsLateResult() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val h = harness { entered.countDown(); check(release.await(2, TimeUnit.SECONDS)); json }
        val reply = Reply()
        read(h, reply)
        val worker = Thread { h.tasks.take().run() }
        worker.start()
        try {
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            reply.await()
            val busy = Reply()
            read(h, busy)
            busy.await()
            assertNotNull(busy.error.get())
            assertEquals(0, h.tasks.size)
        } finally { release.countDown(); worker.join(2000) }
        instrumentation.waitForIdleSync()
        assertEquals(1, reply.count.get())
        assertNull(reply.value.get())
    }

    @Test fun closeRequiresCanonicalIdAndNeverStopsVpn() {
        val h = harness()
        val invalid = Reply()
        close(h, invalid, "one")
        invalid.await()
        assertNotNull(invalid.error.get())
        assertEquals(0, h.closes.get())
        val reply = Reply()
        close(h, reply)
        h.tasks.take().run()
        reply.await()
        assertNull(reply.error.get())
        assertEquals("closed", JSONObject(reply.value.get()!!).getString("status"))
        assertEquals(1, h.closes.get())
        assertEquals(NativeSession.Phase.RUNNING, h.session.snapshot().phase)
    }

    @Test fun closeDoesNotConvertFailureIntoSuccess() {
        val h = harness(close = { """{"status":"failed"}""" })
        val reply = Reply()
        close(h, reply)
        h.tasks.take().run()
        reply.await()
        assertNull(reply.error.get())
        assertEquals("failed", JSONObject(reply.value.get()!!).getString("status"))
    }

    @Test fun unknownCloseStatusIsFailureNotSuccess() {
        val h = harness(close = { """{"status":"maybe"}""" })
        val reply = Reply()
        close(h, reply)
        h.tasks.take().run()
        reply.await()
        assertNotNull(reply.error.get())
        assertNull(reply.value.get())
    }

    @Test fun closeAndReadDoNotShareOneSlot() {
        val h = harness()
        val readReply = Reply()
        read(h, readReply)
        val closeReply = Reply()
        close(h, closeReply)
        h.tasks.take().run()
        h.tasks.take().run()
        readReply.await()
        closeReply.await()
        assertNull(readReply.error.get())
        assertNull(closeReply.error.get())
        assertEquals(1, h.reads.get())
        assertEquals(1, h.closes.get())
    }
}
