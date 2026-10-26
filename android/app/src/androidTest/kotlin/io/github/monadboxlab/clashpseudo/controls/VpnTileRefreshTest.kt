package io.github.monadboxlab.clashpseudo.controls

import android.os.SystemClock
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
        try {
            main {
                assertFalse(VpnTileService.refreshListening())
                first.onStartListening()
            }
            drained(first)
            var before = 0L
            main {
                before = serial.getLong(first)
                SystemControls.refresh(instrumentation.targetContext)
            }
            instrumentation.waitForIdleSync()
            main {
                assertTrue("An already-listening tile missed a production state event",
                    serial.getLong(first) > before)
                replacement.onStartListening()
                first.onStopListening()
                first.onDestroy()
                firstDestroyed = true
            }
            drained(first, replacement)
            var retired = 0L
            main {
                before = serial.getLong(replacement)
                retired = serial.getLong(first)
                SystemControls.refresh(instrumentation.targetContext)
            }
            instrumentation.waitForIdleSync()
            main {
                assertTrue("Retiring the old service cleared its replacement",
                    serial.getLong(replacement) > before)
                assertEquals(retired, serial.getLong(first))
                replacement.onStopListening()
                assertFalse("A stopped listener must not be retained",
                    VpnTileService.refreshListening())
            }
        } finally {
            main {
                if (!firstDestroyed) first.onDestroy()
                replacement.onDestroy()
                assertFalse(VpnTileService.refreshListening())
            }
            drained(first, replacement)
        }
    }
}
