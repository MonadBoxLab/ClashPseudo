package io.github.monadboxlab.clashpseudo.vpn

import io.github.monadboxlab.clashpseudo.app.AppMessage
import org.junit.Assert.*
import org.junit.Test

class NativeSessionTest {
    @Test fun uptimeStartsAtAttachmentAndNeverRestartsWithinTheSession() {
        var elapsed = 100L
        val session = NativeSession { elapsed }
        val first = session.begin("first", 1)!!
        assertNull(session.snapshot().runningSinceElapsedMs)
        elapsed = 500L
        assertTrue(session.attached(first))
        assertEquals(500L, session.snapshot().runningSinceElapsedMs)
        elapsed += 10L * 366 * 24 * 60 * 60 * 1000
        assertFalse(session.attached(first))
        assertEquals(500L, session.snapshot().runningSinceElapsedMs)
        assertEquals(elapsed, session.snapshot().elapsedRealtimeMs)
        session.stopping(first)
        assertNull(session.snapshot().runningSinceElapsedMs)
        session.finished(first, null)
        val second = session.begin("second", 2)!!
        assertFalse(session.attached(first))
        assertNull(session.snapshot().runningSinceElapsedMs)
        elapsed += 1000
        assertTrue(session.attached(second))
        assertEquals(elapsed, session.snapshot().runningSinceElapsedMs)
    }

    @Test fun duplicateStartIsRejected() {
        val session = NativeSession { 0L }
        val id = session.begin()!!
        assertNull(session.begin())
        assertTrue(session.attached(id))
        assertNull(session.begin())
    }

    @Test fun stopInvalidatesPendingAttach() {
        val session = NativeSession { 0L }
        val id = session.begin()!!
        assertTrue(session.stopping(id))
        assertFalse(session.canStart(id))
        assertFalse(session.attached(id))
        assertFalse(session.stopping(id))
        session.finished(id, null)
        assertEquals(NativeSession.Phase.STOPPED, session.snapshot().phase)
    }

    @Test fun oldCallbacksCannotAffectNewSession() {
        val session = NativeSession { 0L }
        val old = session.begin()!!
        session.stopping(old)
        session.finished(old, null)
        val current = session.begin()!!
        assertFalse(session.attached(old))
        assertFalse(session.stopping(old))
        session.finished(old, AppMessage("androidErrorReleaseUnconfirmed"))
        assertTrue(session.canStart(current))
        assertNull(session.snapshot().error)
    }

    @Test fun unconfirmedCleanupBlocksRestart() {
        val session = NativeSession { 0L }
        val id = session.begin()!!
        session.stopping(id, AppMessage("androidErrorTakeoverStartFailed"))
        session.finished(id, AppMessage("androidErrorReleaseUnconfirmed"))
        assertEquals(NativeSession.Phase.UNKNOWN, session.snapshot().phase)
        assertFalse(session.stopping(id))
        assertNull(session.begin())
        assertEquals(AppMessage("operationAndCleanupFailed", mapOf(
            "operation" to AppMessage("androidErrorTakeoverStartFailed"),
            "cleanup" to AppMessage("androidErrorReleaseUnconfirmed")
        )), session.snapshot().error)
    }

    @Test fun failedStartWithSuccessfulCleanupCanRestart() {
        val session = NativeSession { 0L }
        val id = session.begin()!!
        session.stopping(id, AppMessage("androidErrorSystemRevoked"))
        session.finished(id, null)
        assertEquals(AppMessage("androidErrorSystemRevoked"), session.snapshot().error)
        assertNotNull(session.begin())
    }

    @Test fun identityTracksActualSessionAndClearsOnlyAfterConfirmedStop() {
        val session = NativeSession { 0L }
        val observed = mutableListOf<NativeSession.Snapshot>()
        session.changed = { observed.add(session.snapshot()) }
        val first = session.begin("first", 3)!!
        session.attached(first)
        assertEquals("first", session.snapshot().configId)
        assertEquals(3, session.snapshot().revision)
        session.stopping(first)
        assertEquals("first", session.snapshot().configId)
        session.finished(first, null)
        assertNull(session.snapshot().configId)
        assertNull(session.snapshot().revision)
        val next = session.begin("second", 5)!!
        session.finished(first, AppMessage("androidErrorReleaseUnconfirmed"))
        assertFalse(session.attached(first))
        assertEquals("second", session.snapshot().configId)
        session.stopping(next)
        session.finished(next, AppMessage("androidErrorReleaseUnconfirmed"))
        assertEquals("second", session.snapshot().configId)
        assertEquals(5, session.snapshot().revision)
        assertEquals(listOf(NativeSession.Phase.STARTING, NativeSession.Phase.RUNNING,
            NativeSession.Phase.STOPPING, NativeSession.Phase.STOPPED,
            NativeSession.Phase.STARTING, NativeSession.Phase.STOPPING,
            NativeSession.Phase.UNKNOWN), observed.map { it.phase })
    }

    @Test fun queryDoesNotStartAnything() {
        val session = NativeSession { 0L }
        repeat(3) {
            assertEquals(NativeSession.Phase.STOPPED, session.snapshot().phase)
            assertEquals(0L, session.snapshot().generation)
        }
    }
}
