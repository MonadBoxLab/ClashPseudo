package io.github.monadboxlab.clashpseudo.controls

import android.os.SystemClock
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.app.VpnTileService
import org.junit.Assert.*
import org.junit.Test

/** Exercises SDK lifecycle callbacks and production refresh events. */
class VpnTileRefreshTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    // Inspect application-owned fields through reflection.
    private val serial = VpnTileService::class.java.getDeclaredField("displaySerial").apply {
        isAccessible = true
    }
    private val inFlight = VpnTileService::class.java.getDeclaredField("displayInFlight").apply {
        isAccessible = true
    }
    private val listeningInstance = VpnTileService::class.java.getDeclaredField("listeningInstance").apply {
        isAccessible = true
    }
    private val listening = VpnTileService::class.java.getDeclaredField("listening").apply {
        isAccessible = true
    }
    private val destroyed = VpnTileService::class.java.getDeclaredField("destroyed").apply {
        isAccessible = true
    }

    private fun main(block: () -> Unit) {
        var failure: Throwable? = null
        instrumentation.runOnMainSync {
            try { block() } catch (error: Throwable) { failure = error }
        }
        failure?.let { throw it }
    }

    private fun drained(vararg services: VpnTileService) {
        val deadline = SystemClock.uptimeMillis() + 10_000
        do {
            var done = false
            main { done = services.none { inFlight.getBoolean(it) } }
            if (done) return
            SystemClock.sleep(20)
        } while (SystemClock.uptimeMillis() < deadline)
        fail("Actual tile snapshot reads did not finish")
    }

    private class SurfaceFixture {
        private val gate = SystemControls.RefreshRead()
        private val replies = java.util.ArrayDeque<(SystemControls.Projection) -> Unit>()
        val shortcuts = mutableListOf<SystemControls.Projection>()
        val widgets = mutableListOf<SystemControls.Projection>()
        var hasShortcuts = true
        var hasWidget = true
        var failShortcuts = false
        var failWidget = false
        var failRead = false
        var reads = 0
            private set

        fun refresh() = SystemControls.refreshSurfaces(
            hasConsumers = { hasShortcuts || hasWidget },
            read = { reply ->
                reads++
                check(!failRead) { "Snapshot read failed" }
                replies.addLast(reply)
            },
            shortcuts = { value ->
                if (hasShortcuts) {
                    check(!failShortcuts) { "Shortcut publication failed" }
                    shortcuts.add(value)
                }
            },
            widget = { value ->
                if (hasWidget) {
                    check(!failWidget) { "Widget publication failed" }
                    widgets.add(value)
                }
            },
            gate = gate,
        )

        fun complete(phase: String): SystemControls.Projection {
            assertEquals("Only one snapshot may be in flight", 1, replies.size)
            val value = SystemControls.project(mapOf("phase" to phase, "busy" to false))
            replies.removeFirst()(value)
            return value
        }
    }

    @Test fun shortcutsAndWidgetsShareOneReadAndCoalesceToTheLatestAction() = main {
        val fixture = SurfaceFixture()
        fixture.refresh()
        repeat(1000) { fixture.refresh() }
        assertEquals(1, fixture.reads)
        val stopped = fixture.complete("STOPPED")
        assertEquals(2, fixture.reads)
        assertSame(stopped, fixture.shortcuts.single())
        assertSame(stopped, fixture.widgets.single())
        repeat(1000) { fixture.refresh() }
        fixture.complete("STARTING")
        assertEquals(3, fixture.reads)
        val running = fixture.complete("RUNNING")
        assertEquals(3, fixture.reads)
        assertEquals(listOf("start", "stop", "stop"), fixture.shortcuts.map { it.action })
        assertSame(running, fixture.shortcuts.last())
        assertSame(running, fixture.widgets.last())
        fixture.refresh()
        assertEquals(4, fixture.reads)
        fixture.complete("STOPPED")
    }

    @Test fun shortcutOnlyRefreshAndNoConsumerPassesDoNotLeaveTheGateBusy() = main {
        val fixture = SurfaceFixture().apply { hasWidget = false }
        fixture.refresh()
        repeat(10) { fixture.refresh() }
        fixture.complete("STOPPED")
        fixture.complete("RUNNING")
        assertEquals(2, fixture.reads)
        assertEquals("stop", fixture.shortcuts.last().action)
        assertTrue(fixture.widgets.isEmpty())
        fixture.hasShortcuts = false
        repeat(10) { fixture.refresh() }
        assertEquals("No consumer needs a configuration read", 2, fixture.reads)
        fixture.hasWidget = true
        fixture.refresh()
        fixture.refresh()
        fixture.hasWidget = false
        fixture.complete("STOPPED")
        assertEquals("The follow-up rechecks whether any consumer remains", 3, fixture.reads)
        fixture.hasShortcuts = true
        fixture.refresh()
        fixture.complete("STOPPED")
        assertEquals(4, fixture.reads)
        assertEquals("start", fixture.shortcuts.last().action)
    }

    @Test fun consumerFailuresPreserveTheOtherConsumerAndReleaseTheReadGate() = main {
        for (shortcutFails in listOf(true, false)) {
            val fixture = SurfaceFixture().apply {
                failShortcuts = shortcutFails
                failWidget = !shortcutFails
            }
            fixture.refresh()
            repeat(10) { fixture.refresh() }
            fixture.complete("STOPPED")
            fixture.complete("RUNNING")
            val healthy = if (shortcutFails) fixture.widgets else fixture.shortcuts
            assertEquals(listOf("start", "stop"), healthy.map { it.action })
            assertEquals(2, fixture.reads)
            fixture.failShortcuts = false
            fixture.failWidget = false
            fixture.refresh()
            val recovered = fixture.complete("STOPPED")
            assertEquals(3, fixture.reads)
            assertSame(recovered, fixture.shortcuts.last())
            assertSame(recovered, fixture.widgets.last())
        }
    }

    @Test fun aSynchronousReadFailureAllowsTheNextRefresh() = main {
        val fixture = SurfaceFixture().apply { failRead = true }
        fixture.refresh()
        assertEquals(1, fixture.reads)
        fixture.failRead = false
        fixture.refresh()
        val recovered = fixture.complete("RUNNING")
        assertEquals(2, fixture.reads)
        assertSame(recovered, fixture.shortcuts.single())
        assertSame(recovered, fixture.widgets.single())
    }

    @Test fun stateEventsRefreshTheListeningTileWithoutAnotherSdkCallback() {
        val first = VpnTileService()
        val replacement = VpnTileService()
        var firstDestroyed = false
        var failure: Throwable? = null
        val checkpoints = mutableListOf<String>()
        fun state(service: VpnTileService?): String {
            if (service == null) return "none"
            val identity = when {
                service === first -> "first"
                service === replacement -> "replacement"
                else -> "other"
            } + "@" + Integer.toHexString(System.identityHashCode(service))
            return "$identity(listening=${listening.getBoolean(service)}," +
                "destroyed=${destroyed.getBoolean(service)},serial=${serial.getLong(service)}," +
                "inFlight=${inFlight.getBoolean(service)})"
        }
        fun checkpoint(label: String) {
            val current = listeningInstance.get(null) as? VpnTileService
            val entry = "$label current=${state(current)} first=${state(first)} replacement=${state(replacement)}"
            checkpoints.add(entry)
            Log.i("PseudoTileFixture", entry)
        }
        fun diagnostic(message: String) = "$message\n${checkpoints.joinToString("\n")}"
        fun current() = listeningInstance.get(null) as? VpnTileService
        fun cleanup(block: () -> Unit) {
            try {
                block()
            } catch (error: Throwable) {
                val original = failure
                if (original == null) failure = error
                else if (original !== error) original.addSuppressed(error)
            }
        }
        fun destroyOwned(service: VpnTileService, label: String, alreadyDestroyed: Boolean = false) {
            val before = current()
            cleanup { if (!alreadyDestroyed) service.onDestroy() }
            cleanup { checkpoint(label) }
            cleanup { assertFalse(diagnostic("A destroyed fixture must not listen"), listening.getBoolean(service)) }
            cleanup { assertTrue(diagnostic("A fixture must finish destruction"), destroyed.getBoolean(service)) }
            if (before === service) {
                cleanup { assertNull(diagnostic("Destroying the current owner must release it"), current()) }
                cleanup {
                    assertFalse(diagnostic("No listener may remain after releasing the fixture owner"),
                        VpnTileService.refreshListening())
                }
            } else {
                cleanup {
                    assertSame(diagnostic("Destroying a non-current fixture must preserve the current owner"),
                        before, current())
                }
                if (before == null) {
                    cleanup {
                        assertFalse(diagnostic("Destroying a non-current fixture must preserve an empty pass"),
                            VpnTileService.refreshListening())
                    }
                } else {
                    cleanup { assertTrue(diagnostic("A preserved owner must actually listen"), listening.getBoolean(before)) }
                    cleanup { assertFalse(diagnostic("A preserved owner must not be destroyed"), destroyed.getBoolean(before)) }
                }
            }
        }
        try {
            main {
                val entry = current()
                checkpoint("entry")
                if (entry == null) {
                    assertNull(diagnostic("An empty entry must remain unowned"), current())
                    assertFalse(diagnostic("No listener may refresh an empty entry"), VpnTileService.refreshListening())
                } else {
                    assertSame(diagnostic("An existing SDK owner must retain its identity at entry"), entry, current())
                    assertTrue(diagnostic("An existing SDK owner must actually listen"), listening.getBoolean(entry))
                    assertFalse(diagnostic("A destroyed SDK owner must not remain current"), destroyed.getBoolean(entry))
                }
                first.onStartListening()
                checkpoint("first-published")
                assertSame(diagnostic("The first fixture must own its listening pass"), first, current())
            }
            drained(first)
            var before = 0L
            main {
                assertSame(diagnostic("The first fixture must still own the refresh source"), first, current())
                before = serial.getLong(first)
                SystemControls.refresh(instrumentation.targetContext)
            }
            instrumentation.waitForIdleSync()
            main {
                checkpoint("first-refresh")
                assertSame(diagnostic("The first fixture must own the refreshed pass"), first, current())
                assertTrue(diagnostic("An already-listening tile missed a production state event"),
                    serial.getLong(first) > before)
                replacement.onStartListening()
                checkpoint("replacement-published")
                assertSame(diagnostic("The replacement must become the current owner"), replacement, current())
                first.onStopListening()
                checkpoint("first-stopped")
                assertSame(diagnostic("Stopping the old fixture must preserve its replacement"), replacement, current())
                assertFalse(diagnostic("The stopped fixture must not listen"), listening.getBoolean(first))
                first.onDestroy()
                firstDestroyed = true
                checkpoint("first-destroyed")
                assertSame(diagnostic("Destroying the old fixture must preserve its replacement"), replacement, current())
                assertTrue(diagnostic("The retired fixture must be destroyed"), destroyed.getBoolean(first))
            }
            drained(first, replacement)
            var retired = 0L
            main {
                assertSame(diagnostic("The replacement must still own the refresh source"), replacement, current())
                before = serial.getLong(replacement)
                retired = serial.getLong(first)
                SystemControls.refresh(instrumentation.targetContext)
            }
            instrumentation.waitForIdleSync()
            main {
                checkpoint("replacement-refresh")
                assertSame(diagnostic("The replacement must own the refreshed pass"), replacement, current())
                assertTrue(diagnostic("Retiring the old service cleared its replacement"),
                    serial.getLong(replacement) > before)
                assertEquals(diagnostic("A retired service must not refresh"), retired, serial.getLong(first))
                replacement.onStopListening()
                checkpoint("replacement-stopped")
                assertFalse(diagnostic("The stopped replacement must not listen"), listening.getBoolean(replacement))
                assertNull(diagnostic("Stopping the current owner must leave no listener"), current())
                assertFalse(diagnostic("A stopped listener must not be retained"),
                    VpnTileService.refreshListening())
            }
        } catch (error: Throwable) {
            failure = error
        } finally {
            cleanup {
                main {
                    cleanup { destroyOwned(first, "cleanup-first-destroyed", firstDestroyed) }
                    cleanup { destroyOwned(replacement, "cleanup-replacement-destroyed") }
                    cleanup { assertNotSame(diagnostic("The destroyed first fixture must not remain current"), first, current()) }
                    cleanup { assertNotSame(diagnostic("The destroyed replacement must not remain current"), replacement, current()) }
                }
            }
            cleanup { drained(first, replacement) }
        }
        failure?.let { throw it }
    }
}
