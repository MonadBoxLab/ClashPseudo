package io.github.monadboxlab.clashpseudo.app

import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

class ModeCallsTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)

    private class Harness {
        val session = NativeSession()
        val generation = session.begin()!!.also { session.attached(it) }
        val tasks = LinkedBlockingQueue<Runnable>()
        val mode = AtomicReference("rule")
        val changes = AtomicInteger()
        val notifications = AtomicInteger()
        val replies = AtomicInteger()
        val error = AtomicReference<String?>()
        val done = CountDownLatch(1)
        lateinit var calls: ModeCalls
        fun reply(value: String?, failure: String?) {
            error.set(failure)
            if (failure == null) assertEquals("global", value)
            replies.incrementAndGet()
            done.countDown()
        }
    }

    private fun harness(set: ((String) -> String)? = null): Harness {
        val h = Harness()
        main {
            h.calls = ModeCalls(h.session, Executor { h.tasks.add(it) },
                { h.notifications.incrementAndGet() }, { h.mode.get() },
                set ?: { mode -> h.changes.incrementAndGet(); h.mode.set(mode); "" })
        }
        return h
    }

    @Test fun appliesAndReadsBackWithoutStopping() {
        val h = harness()
        main { h.calls.change(h.generation, "one", "global", h::reply) }
        h.tasks.take().run()
        assertTrue(h.done.await(2, TimeUnit.SECONDS))
        instrumentation.waitForIdleSync()
        assertEquals(1, h.changes.get())
        assertEquals(1, h.replies.get())
        assertEquals(1, h.notifications.get())
        assertEquals(NativeSession.Phase.RUNNING, h.session.snapshot().phase)
    }

    @Test fun abandonedQueuedWorkRepliesWithErrorWithoutMutation() {
        val h = harness()
        main {
            h.calls.change(h.generation, "one", "global", h::reply)
            h.calls.abandon("one")
        }
        h.tasks.take().run()
        instrumentation.waitForIdleSync()
        assertEquals(0, h.changes.get())
        assertEquals(1, h.replies.get())
        assertNotNull(h.error.get())
        assertEquals(NativeSession.Phase.RUNNING, h.session.snapshot().phase)
    }

    @Test fun staleGenerationCannotAffectReplacementSession() {
        val h = harness()
        main {
            h.calls.change(h.generation, "one", "global", h::reply)
            h.session.stopping(h.generation)
            h.session.finished(h.generation, null)
            h.session.begin()!!.also { h.session.attached(it) }
        }
        h.tasks.take().run()
        assertTrue(h.done.await(2, TimeUnit.SECONDS))
        assertNotNull(h.error.get())
        assertEquals(0, h.changes.get())
        assertEquals(NativeSession.Phase.RUNNING, h.session.snapshot().phase)
    }

    @Test fun queuedTimeoutDoesNotRunLateOrStop() {
        val h = harness()
        main { h.calls.change(h.generation, "one", "global", h::reply) }
        assertTrue(h.done.await(7, TimeUnit.SECONDS))
        h.tasks.take().run()
        instrumentation.waitForIdleSync()
        assertNotNull(h.error.get())
        assertEquals(0, h.changes.get())
        assertEquals(1, h.replies.get())
        assertEquals(NativeSession.Phase.RUNNING, h.session.snapshot().phase)
    }

    @Test fun executingTimeoutNotifiesAfterLateFinishButRepliesOnlyOnce() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val h = harness { entered.countDown(); check(release.await(9, TimeUnit.SECONDS)); "" }
        main { h.calls.change(h.generation, "one", "global", h::reply) }
        val thread = Thread { h.tasks.take().run() }.apply { start() }
        try {
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            assertTrue(h.done.await(7, TimeUnit.SECONDS))
            h.mode.set("global")
        } finally {
            release.countDown()
            thread.join(3000)
        }
        assertFalse(thread.isAlive)
        instrumentation.waitForIdleSync()
        assertEquals(1, h.replies.get())
        assertEquals(1, h.notifications.get())
        assertNotNull(h.error.get())
        assertEquals(NativeSession.Phase.RUNNING, h.session.snapshot().phase)
    }

    @Test fun readTimeoutPreservesRunningAndDoesNotMutate() {
        val h = harness()
        main { h.calls.read(h.generation, null, h::reply) }
        assertTrue(h.done.await(5, TimeUnit.SECONDS))
        h.tasks.take().run()
        instrumentation.waitForIdleSync()
        assertEquals(1, h.replies.get())
        assertNotNull(h.error.get())
        assertEquals(0, h.changes.get())
        assertEquals(NativeSession.Phase.RUNNING, h.session.snapshot().phase)
    }

    @Test fun mismatchedReadbackIsNotSuccess() {
        val h = harness { "" }
        main { h.calls.change(h.generation, "one", "global", h::reply) }
        h.tasks.take().run()
        assertTrue(h.done.await(2, TimeUnit.SECONDS))
        assertNotNull(h.error.get())
        assertEquals("rule", h.mode.get())
    }

    @Test fun abandonedExecutingWorkRepliesOnceAndDropsLateSuccess() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val h = harness { entered.countDown(); check(release.await(3, TimeUnit.SECONDS)); "" }
        main { h.calls.change(h.generation, "one", "global", h::reply) }
        val thread = Thread { h.tasks.take().run() }.apply { start() }
        try {
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            main { h.calls.abandon("one") }
            h.mode.set("global")
        } finally {
            release.countDown()
            thread.join(3000)
        }
        instrumentation.waitForIdleSync()
        assertEquals(1, h.replies.get())
        assertNotNull(h.error.get())
        assertEquals(1, h.notifications.get())
        assertEquals(NativeSession.Phase.RUNNING, h.session.snapshot().phase)
    }

    @Test fun invalidModeAndStoppedReadDoNotReachNative() {
        val h = harness()
        main { h.calls.change(h.generation, "one", "follow", h::reply) }
        assertTrue(h.tasks.isEmpty())
        assertNotNull(h.error.get())
        main {
            h.session.stopping(h.generation)
            h.session.finished(h.generation, null)
            h.calls.read(h.generation, null) { value, error ->
                assertNull(value)
                assertNotNull(error)
            }
        }
        h.tasks.take().run()
        instrumentation.waitForIdleSync()
        assertEquals(0, h.changes.get())
    }
}
