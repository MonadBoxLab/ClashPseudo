package io.github.monadboxlab.clashpseudo.nativecore

import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import java.util.concurrent.Executor
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class CoreHostTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private val input = CoreInput("one", 1, "rule", byteArrayOf(), "{}".toByteArray())

    private class Harness {
        val session = NativeSession()
        val tasks = LinkedBlockingQueue<Runnable>()
        val prepares = AtomicInteger()
        val stops = AtomicInteger()
        val cancels = AtomicInteger()
        val events = mutableListOf<String>()
        var callback: Any? = null
        var prepareError = ""
        var stopError = ""
        lateinit var core: CoreHost
    }

    private fun harness(): Harness {
        val h = Harness()
        main {
            h.core = CoreHost(h.session, {}, Executor { h.tasks.add(it) }, 60,
                { _, _, _, callback, _ ->
                    h.prepares.incrementAndGet(); h.events.add("prepare"); h.callback = callback; h.prepareError
                }, { h.stops.incrementAndGet(); h.events.add("stop"); h.stopError }, { h.cancels.incrementAndGet() })
            h.core.setVisible(true)
        }
        return h
    }
    private fun preview(h: Harness, owner: String = "one", revision: Int = 1) =
        h.core.preparePreview(owner, "one", revision, "unused", { true }) {
            CoreInput("one", revision, "rule", byteArrayOf(), "{}".toByteArray())
        }
    private fun permitted(callback: Any): Boolean = callback.javaClass.getDeclaredMethod("protectSocket", Int::class.javaPrimitiveType)
        .apply { isAccessible = true }.invoke(callback, 42) as Boolean

    @Test fun previewDoesNotCreateVpnAndReusesOnlyMatchingContext() {
        val h = harness()
        val first = preview(h)
        val callback = h.callback!!
        assertTrue(permitted(callback))
        assertEquals(NativeSession.Phase.STOPPED, h.session.snapshot().phase)
        assertEquals(first.generation, preview(h, "second").generation)
        assertEquals(1, h.prepares.get())
        val next = preview(h, "third", 2)
        assertTrue(next.generation > first.generation)
        assertEquals(1, h.stops.get())
        assertFalse(permitted(callback))
        assertNull(h.core.releasePreview())
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
    }

    @Test fun vpnHandoffFullyReleasesPreviewAndIgnoresIdleExpiry() {
        val h = harness()
        preview(h)
        val callback = h.callback!!
        val vpn = h.session.begin("one", 1)!!
        assertFalse(permitted(callback))
        val loaded = h.core.prepareVpn(vpn, "one", 1, "unused", { input }, Any())
        assertEquals(listOf("prepare", "stop", "prepare"), h.events)
        h.session.attached(vpn)
        assertTrue(h.core.current(loaded.generation))
        main { h.core.setVisible(false) }
        assertNull(h.tasks.poll(200, TimeUnit.MILLISECONDS))
        assertEquals(CoreHost.Phase.READY, h.core.snapshot().phase)
        assertNull(h.core.releasePreview())
        assertEquals(1, h.stops.get())
        h.session.stopping(vpn)
        h.core.cancelVpn(vpn)
        assertNull(h.core.stopVpn(vpn))
        h.session.finished(vpn, null)
        assertEquals(2, h.stops.get())
        assertEquals(1, h.cancels.get())
    }

    @Test fun returningBeforeQueuedExpiryPreservesPreview() {
        val h = harness()
        preview(h)
        main { h.core.setVisible(false) }
        val expired = h.tasks.poll(2, TimeUnit.SECONDS)!!
        main { h.core.setVisible(true) }
        expired.run()
        assertEquals(CoreHost.Phase.READY, h.core.snapshot().phase)
        assertEquals(0, h.stops.get())
        assertNull(h.core.releasePreview())
    }

    @Test fun expiredPreviewReleasesAndReturnNeedsNewGeneration() {
        val h = harness()
        val before = preview(h)
        main { h.core.setVisible(false) }
        h.tasks.poll(2, TimeUnit.SECONDS)!!.run()
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
        main { h.core.setVisible(true) }
        assertTrue(preview(h).generation > before.generation)
        assertEquals(2, h.prepares.get())
        assertNull(h.core.releasePreview())
    }

    @Test fun acceptedOperationDefersAnAlreadyQueuedExpiry() {
        val h = harness()
        preview(h)
        main { h.core.setVisible(false) }
        val expired = h.tasks.poll(2, TimeUnit.SECONDS)!!
        main { h.core.setOperationBusy(true) }
        expired.run()
        assertEquals(0, h.stops.get())
        main { h.core.setOperationBusy(false) }
        h.tasks.poll(2, TimeUnit.SECONDS)!!.run()
        assertEquals(1, h.stops.get())
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
    }

    @Test fun oldExpiryCannotReleaseReplacementContext() {
        val h = harness()
        preview(h)
        main { h.core.setVisible(false) }
        val old = h.tasks.poll(2, TimeUnit.SECONDS)!!
        main { h.core.setVisible(true) }
        val next = preview(h, "new", 2)
        old.run()
        assertEquals(next, h.core.snapshot())
        assertEquals(1, h.stops.get())
        assertNull(h.core.releasePreview())
    }

    @Test fun failedPrepareCleansUpAndCanBeRetriedExplicitly() {
        val h = harness()
        h.prepareError = "invalid"
        try { preview(h); fail("failed preparation accepted") } catch (_: IllegalStateException) { }
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
        assertNotNull(h.core.snapshot().error)
        assertEquals("one", h.core.snapshot().configId)
        assertEquals(1, h.stops.get())
        h.prepareError = ""
        assertEquals(CoreHost.Phase.READY, preview(h).phase)
        assertNull(h.core.releasePreview())
    }

    @Test fun cleanupFailureBlocksReuseWithoutClaimingVpnRunning() {
        val h = harness()
        preview(h)
        h.stopError = "unconfirmed"
        assertNotNull(h.core.releasePreview())
        assertEquals(CoreHost.Phase.FAILED, h.core.snapshot().phase)
        assertEquals(NativeSession.Phase.STOPPED, h.session.snapshot().phase)
        try { preview(h, "other"); fail("unclean context reused") } catch (_: IllegalStateException) { }
        assertEquals(1, h.prepares.get())
    }

    @Test fun expiredReadyWaiterReleasesItsContext() {
        val h = harness()
        val loaded = preview(h, "expired")
        main { h.core.cancelPreparation("expired") }
        assertFalse(h.core.current(loaded.generation))
        h.tasks.poll(2, TimeUnit.SECONDS)!!.run()
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
        assertEquals(1, h.stops.get())
        assertEquals(0, h.cancels.get())
    }

    @Test fun mismatchedInputNeverReachesNativePrepare() {
        val h = harness()
        try {
            h.core.preparePreview("one", "one", 2, "unused", { true }) { input }
            fail("mismatched input accepted")
        } catch (_: IllegalStateException) { }
        assertEquals(0, h.prepares.get())
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
        assertNotNull(h.core.snapshot().error)
    }

    @Test fun expiredReadyWaiterQueuesOnlyItsOwnCleanup() {
        val h = harness()
        val old = preview(h, "old")
        main { h.core.cancelPreparation("old") }
        assertFalse(h.core.current(old.generation))
        val cleanup = h.tasks.poll(2, TimeUnit.SECONDS)!!
        val next = preview(h, "next", 2)
        cleanup.run()
        assertEquals(next, h.core.snapshot())
        assertEquals(1, h.stops.get())
        assertNull(h.core.releasePreview())
    }

    @Test fun revokedPreviewRequestRejectsLateNativeCompletion() {
        val h = harness()
        try {
            h.core.preparePreview("cancelled", "one", 1, "unused", { true }) {
                h.core.cancelPreparation("cancelled")
                input
            }
            fail("cancelled preparation became ready")
        } catch (_: IllegalStateException) { }
        assertEquals(0, h.prepares.get())
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
        assertEquals(0, h.cancels.get())
    }
}
