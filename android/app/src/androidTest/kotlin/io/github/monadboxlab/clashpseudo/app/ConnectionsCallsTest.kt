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
    private val json = """{"prepared":true,"attached":true,"cleanupFailed":false,"protected":99,"traffic":{"connections":[
        {"id":"one","start":"2026-10-15T00:00:00Z","chains":["节点🌐","出口"],"upload":2,"download":3,"metadata":{"host":"fixture.test","type":"Tun","processPath":"private"}},
        {"id":"internal","metadata":{"type":"Inner"}}
    ]}}"""

    private class Harness {
        val session = NativeSession()
        val tasks = LinkedBlockingQueue<Runnable>()
        val reads = AtomicInteger()
        val stops = AtomicInteger()
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
    private fun harness(read: (() -> String)? = null): Harness {
        val h = Harness()
        main {
            h.core = CoreHost(h.session, {}, Executor { h.tasks.add(it) },
                prepareNative = { _, _, _, _, _ -> "" }, stopNative = { h.stops.incrementAndGet(); "" }, cancelNative = {})
            h.core.setVisible(true)
            h.calls = ConnectionsCalls(h.core, { h.reads.incrementAndGet(); read?.invoke() ?: json }, 100)
        }
        h.vpn = h.session.begin("one", 1)!!
        h.generation = h.core.prepareVpn(h.vpn, "one", 1, "unused", { input }, Any()).generation
        h.session.attached(h.vpn)
        return h
    }
    private fun read(h: Harness, reply: Reply) = main { h.calls.read(h.generation, "one", 1, reply::accept) }

    @Test fun projectsOnlyConnectionFieldsAndExcludesInner() {
        val h = harness()
        val reply = Reply()
        read(h, reply)
        h.tasks.take().run()
        reply.await()
        assertNull(reply.error.get())
        val result = JSONObject(reply.value.get()!!)
        assertEquals(h.generation, result.getLong("generation"))
        assertEquals(1, result.getJSONArray("connections").length())
        val row = result.getJSONArray("connections").getJSONObject(0)
        assertEquals("节点🌐", row.getJSONArray("chains").getString(0))
        assertFalse(row.getJSONObject("metadata").has("processPath"))
        assertFalse(result.has("protected"))
        assertEquals(0, h.stops.get())
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
        assertEquals(0, h.stops.get())
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
        assertEquals(0, h.stops.get())
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
        assertEquals(0, h.stops.get())
    }

    @Test fun missingTrafficIsFailureNotEmptyList() {
        val h = harness { """{"prepared":true,"attached":true,"cleanupFailed":false,"traffic":{}}""" }
        val reply = Reply()
        read(h, reply)
        h.tasks.take().run()
        reply.await()
        assertNotNull(reply.error.get())
        assertNull(reply.value.get())
    }
}
