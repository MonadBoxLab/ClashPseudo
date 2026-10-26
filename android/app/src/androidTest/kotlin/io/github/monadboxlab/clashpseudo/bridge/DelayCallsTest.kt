package io.github.monadboxlab.clashpseudo.bridge

import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.lang.ref.WeakReference
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.CoreInput
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class DelayCallsTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)

    private class Harness {
        val tasks = LinkedBlockingQueue<Runnable>()
        val starts = AtomicInteger()
        val reads = AtomicInteger()
        val cancellations = LinkedBlockingQueue<String>()
        var beforeStart: (() -> Unit)? = null
        var beforeRead: (() -> Unit)? = null
        lateinit var core: CoreHost
        lateinit var calls: DelayCalls
        lateinit var source: CoreHost.Snapshot
    }

    private fun harness(timeoutMs: Long = 5_000): Harness = Harness().also { h ->
        main {
            h.core = CoreHost(NativeSession(), {}, Executor { h.tasks.add(it) },
                prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {})
            h.core.setVisible(true)
            h.calls = DelayCalls(h.core,
                start = { h.starts.incrementAndGet(); h.beforeStart?.invoke(); "{\"id\":\"batch\"}" },
                read = { h.reads.incrementAndGet(); h.beforeRead?.invoke(); "{\"id\":\"batch\",\"state\":\"running\",\"members\":[]}" },
                cancel = { h.cancellations.add(it.toString(Charsets.UTF_8)) },
                timeoutMs = timeoutMs)
        }
        h.source = h.core.preparePreview("fixture", "main", 1, "unused", { true }) {
            CoreInput("main", 1, "rule", byteArrayOf(), "{}".toByteArray())
        }
    }

    private fun start(h: Harness) {
        val done = CountDownLatch(1)
        main { h.calls.start(h.source.generation, h.source.composition, mapOf("group" to "g")) { value, error ->
            assertNotNull(value); assertNull(error); done.countDown()
        } }
        h.tasks.take().run()
        assertTrue(done.await(2, TimeUnit.SECONDS))
    }

    @Test fun onlyCurrentActivityVisibilityCanInvalidateUndeliveredStart() {
        val h = harness()
        val done = CountDownLatch(1)
        val activity = AppBridge::class.java.getDeclaredField("activity").apply { isAccessible = true }
        val delays = AppBridge::class.java.getDeclaredField("delays").apply { isAccessible = true }
        val visible = CoreHost::class.java.getDeclaredField("visible").apply { isAccessible = true }
        var oldActivity: Any? = null
        var oldDelays: Any? = null
        var oldVisible = false
        try {
            main {
                oldActivity = activity.get(AppBridge)
                oldDelays = delays.get(AppBridge)
                oldVisible = visible.getBoolean(PseudoVpnService.core)
                val previous = MainActivity()
                val current = MainActivity()
                activity.set(AppBridge, WeakReference(current))
                delays.set(AppBridge, h.calls)
                h.calls.start(h.source.generation, h.source.composition, mapOf("group" to "g")) { value, error ->
                    assertNull(value); assertNotNull(error); done.countDown()
                }
                AppBridge.setUiVisible(previous, false)
                h.tasks.take().run()
                assertEquals("Old Activity must not expire new owner's queued start", 1, h.starts.get())
                AppBridge.setUiVisible(current, false)
                AppBridge.setUiVisible(current, true)
            }
            assertTrue(done.await(2, TimeUnit.SECONDS))
            h.tasks.take().run()
            assertEquals("batch", h.cancellations.poll(2, TimeUnit.SECONDS))
        } finally {
            main {
                activity.set(AppBridge, oldActivity)
                delays.set(AppBridge, oldDelays)
                PseudoVpnService.core.setVisible(oldVisible)
            }
            h.core.releasePreview()
        }
    }

    @Test fun backgroundAndResumeBeforeWorkerExecutionInvalidatesQueuedStart() {
        val h = harness()
        val done = CountDownLatch(1)
        try {
            main {
                h.calls.start(h.source.generation, h.source.composition, mapOf("group" to "g")) { value, error ->
                    assertNull(value); assertNotNull(error); done.countDown()
                }
                h.calls.setVisible(false)
                h.calls.setVisible(true)
            }
            h.tasks.take().run()
            assertTrue(done.await(2, TimeUnit.SECONDS))
            assertEquals(0, h.starts.get())
        } finally { h.core.releasePreview() }
    }

    @Test fun backgroundBeforeReplyCancelsAcceptedBatchEvenAfterImmediateResume() {
        val h = harness()
        val done = CountDownLatch(1)
        try {
            main {
                h.calls.start(h.source.generation, h.source.composition, mapOf("group" to "g")) { value, error ->
                    assertNull(value); assertNotNull(error); done.countDown()
                }
                h.tasks.take().run()
                h.calls.setVisible(false)
                h.calls.setVisible(true)
            }
            assertTrue(done.await(2, TimeUnit.SECONDS))
            h.tasks.take().run()
            assertEquals("batch", h.cancellations.poll(2, TimeUnit.SECONDS))
        } finally { h.core.releasePreview() }
    }

    @Test fun backgroundRejectsNewStartsAndInvalidatesDeliveredBatch() {
        val h = harness()
        try {
            start(h)
            main {
                h.calls.setVisible(false)
                h.calls.start(h.source.generation, h.source.composition, mapOf("group" to "g")) { value, error ->
                    assertNull(value); assertNotNull(error)
                }
                h.calls.setVisible(true)
                h.calls.read(h.source.generation, h.source.composition, "batch") { value, error ->
                    assertNull(value); assertNotNull(error)
                }
            }
            h.tasks.take().run()
            assertEquals("batch", h.cancellations.poll(2, TimeUnit.SECONDS))
            assertEquals(1, h.starts.get())
            assertEquals(0, h.reads.get())
        } finally { h.core.releasePreview() }
    }

    @Test fun uiAbandonInvalidatesAStartThatHasNotExecuted() {
        val h = harness()
        val done = CountDownLatch(1)
        try {
            main {
                h.calls.start(h.source.generation, h.source.composition, mapOf("group" to "g")) { value, error ->
                    assertNull(value); assertNotNull(error); done.countDown()
                }
                h.calls.abandonAll()
            }
            h.tasks.take().run()
            assertTrue(done.await(2, TimeUnit.SECONDS))
            assertEquals(0, h.starts.get())
        } finally { h.core.releasePreview() }
    }

    @Test fun uiAbandonCancelsAcceptedBatchBeforeReplyDelivery() {
        val h = harness()
        val done = CountDownLatch(1)
        try {
            main {
                h.calls.start(h.source.generation, h.source.composition, mapOf("group" to "g")) { value, error ->
                    assertNull(value); assertNotNull(error); done.countDown()
                }
                h.tasks.take().run()
                h.calls.abandonAll()
            }
            assertTrue(done.await(2, TimeUnit.SECONDS))
            h.tasks.take().run()
            assertEquals("batch", h.cancellations.poll(2, TimeUnit.SECONDS))
        } finally { h.core.releasePreview() }
    }

    @Test fun cancellationPreventsQueuedReadAndLateSuccess() {
        val h = harness()
        val done = CountDownLatch(1)
        try {
            start(h)
            main {
                h.calls.read(h.source.generation, h.source.composition, "batch") { value, error ->
                    assertNull(value); assertNotNull(error); done.countDown()
                }
                h.calls.cancel("batch")
            }
            h.tasks.take().run()
            h.tasks.take().run()
            assertTrue(done.await(2, TimeUnit.SECONDS))
            assertEquals(0, h.reads.get())
            assertEquals("batch", h.cancellations.poll(2, TimeUnit.SECONDS))
        } finally { h.core.releasePreview() }
    }

    @Test fun onlyOneReadPerBatchIsQueued() {
        val h = harness()
        val first = CountDownLatch(1)
        try {
            start(h)
            main {
                h.calls.read(h.source.generation, h.source.composition, "batch") { value, error ->
                    assertNotNull(value); assertNull(error); first.countDown()
                }
                h.calls.read(h.source.generation, h.source.composition, "batch") { value, error ->
                    assertNull(value); assertNotNull(error)
                }
            }
            assertEquals(1, h.tasks.size)
            h.tasks.take().run()
            assertTrue(first.await(2, TimeUnit.SECONDS))
            assertEquals(1, h.reads.get())
        } finally { h.core.releasePreview() }
    }

    @Test fun timedOutNativeStartCancelsItsLateAcceptedBatch() {
        val h = harness(timeoutMs = 1_000)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val done = CountDownLatch(1)
        val replies = AtomicInteger()
        h.beforeStart = {
            entered.countDown()
            assertTrue(release.await(3, TimeUnit.SECONDS))
        }
        val worker = Thread { h.tasks.take().run() }
        try {
            main { h.calls.start(h.source.generation, h.source.composition, mapOf("group" to "g")) { value, error ->
                assertNull(value); assertNotNull(error); replies.incrementAndGet(); done.countDown()
            } }
            worker.start()
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            assertTrue(done.await(2, TimeUnit.SECONDS))
            release.countDown()
            worker.join(2_000)
            assertFalse(worker.isAlive)
            instrumentation.waitForIdleSync()
            assertEquals("batch", h.cancellations.poll(2, TimeUnit.SECONDS))
            assertEquals(1, h.starts.get())
            assertEquals(1, replies.get())
        } finally {
            release.countDown()
            worker.join(2_000)
            h.core.releasePreview()
        }
    }

    @Test fun timedOutReadKeepsItsNativeSlotUntilActualCompletion() {
        val h = harness(timeoutMs = 1_000)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val done = CountDownLatch(1)
        val replies = AtomicInteger()
        h.beforeRead = {
            entered.countDown()
            assertTrue(release.await(3, TimeUnit.SECONDS))
        }
        val worker = Thread { h.tasks.take().run() }
        try {
            start(h)
            main { h.calls.read(h.source.generation, h.source.composition, "batch") { value, error ->
                assertNull(value); assertNotNull(error); replies.incrementAndGet(); done.countDown()
            } }
            worker.start()
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            assertTrue(done.await(2, TimeUnit.SECONDS))
            main { h.calls.read(h.source.generation, h.source.composition, "batch") { value, error ->
                assertNull(value); assertNotNull(error)
            } }
            assertEquals(0, h.tasks.size)
            assertEquals(1, h.reads.get())
            release.countDown()
            worker.join(2_000)
            assertFalse(worker.isAlive)
            instrumentation.waitForIdleSync()
            assertEquals(1, replies.get())
        } finally {
            release.countDown()
            worker.join(2_000)
            h.core.releasePreview()
        }
    }

    @Test fun timedOutQueuedStartDoesNotStartProbesAndRepliesOnce() {
        val h = harness(timeoutMs = 50)
        val done = CountDownLatch(1)
        val replies = AtomicInteger()
        try {
            main { h.calls.start(h.source.generation, h.source.composition, mapOf("group" to "g")) { value, error ->
                assertNull(value); assertNotNull(error); replies.incrementAndGet(); done.countDown()
            } }
            assertTrue(done.await(2, TimeUnit.SECONDS))
            h.tasks.take().run()
            instrumentation.waitForIdleSync()
            assertEquals(0, h.starts.get())
            assertEquals(1, replies.get())
        } finally { h.core.releasePreview() }
    }
}
