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
