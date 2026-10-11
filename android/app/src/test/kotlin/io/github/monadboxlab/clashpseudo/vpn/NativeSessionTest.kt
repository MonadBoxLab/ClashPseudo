package io.github.monadboxlab.clashpseudo.vpn

import org.junit.Assert.*
import org.junit.Test

class NativeSessionTest {
    @Test fun duplicateStartIsRejected() {
        val session = NativeSession()
        val id = session.begin()!!
        assertNull(session.begin())
        assertTrue(session.attached(id))
        assertNull(session.begin())
    }

    @Test fun stopInvalidatesPendingAttach() {
        val session = NativeSession()
        val id = session.begin()!!
        assertTrue(session.stopping(id))
        assertFalse(session.canStart(id))
        assertFalse(session.attached(id))
        assertFalse(session.stopping(id))
        session.finished(id, null)
        assertEquals(NativeSession.Phase.STOPPED, session.snapshot().phase)
    }

    @Test fun oldCallbacksCannotAffectNewSession() {
        val session = NativeSession()
        val old = session.begin()!!
        session.stopping(old)
        session.finished(old, null)
        val current = session.begin()!!
        assertFalse(session.attached(old))
        assertFalse(session.stopping(old))
        session.finished(old, "late failure")
        assertTrue(session.canStart(current))
        assertNull(session.snapshot().error)
    }

    @Test fun unconfirmedCleanupBlocksRestart() {
        val session = NativeSession()
        val id = session.begin()!!
        session.stopping(id, "start failed")
        session.finished(id, "close failed")
        assertEquals(NativeSession.Phase.UNKNOWN, session.snapshot().phase)
        assertFalse(session.stopping(id))
        assertNull(session.begin())
        assertTrue(session.snapshot().error!!.contains("close failed"))
    }

    @Test fun failedStartWithSuccessfulCleanupCanRestart() {
        val session = NativeSession()
        val id = session.begin()!!
        session.stopping(id, "permission revoked")
        session.finished(id, null)
        assertEquals("permission revoked", session.snapshot().error)
        assertNotNull(session.begin())
    }

    @Test fun queryDoesNotStartAnything() {
        val session = NativeSession()
        repeat(3) {
            assertEquals(NativeSession.Phase.STOPPED, session.snapshot().phase)
            assertEquals(0L, session.snapshot().generation)
        }
    }
}
