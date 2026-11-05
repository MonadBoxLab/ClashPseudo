package io.github.monadboxlab.clashpseudo.vpn

import io.github.monadboxlab.clashpseudo.message.AppMessage
import org.junit.Assert.*
import org.junit.Test

class NativeSessionTest {
    @Test fun queryDoesNotStartAnything() {
        val session = NativeSession { 100L }
        repeat(3) {
            assertEquals(NativeSession.Snapshot(0, NativeSession.Phase.STOPPED,
                null, null, null, null, 100), session.snapshot())
        }
    }

    @Test fun phasesProjectTheRemoteStateWithoutInventingAVpnSession() {
        val phases = mapOf(
            "loading" to NativeSession.Phase.STARTING,
            "starting" to NativeSession.Phase.STARTING,
            "stopping" to NativeSession.Phase.STOPPING,
            "communicationLost" to NativeSession.Phase.UNKNOWN,
            "empty" to NativeSession.Phase.STOPPED,
            "unrecognized" to NativeSession.Phase.STOPPED,
        )
        val session = NativeSession { 0L }
        for ((remote, expected) in phases) {
            session.project(mapOf("phase" to remote, "vpnRunning" to true,
                "runningSinceElapsedMs" to 50L))
            assertEquals(expected, session.snapshot().phase)
            assertNull(session.snapshot().runningSinceElapsedMs)
        }
        for (vpn in listOf(true, false, null)) {
            session.project(mapOf("phase" to "ready", "vpnRunning" to vpn,
                "runningSinceElapsedMs" to 50L))
            assertEquals(if (vpn == true) NativeSession.Phase.RUNNING else NativeSession.Phase.STOPPED,
                session.snapshot().phase)
            assertEquals(if (vpn == true) 50L else null, session.snapshot().runningSinceElapsedMs)
        }
    }

    @Test fun uptimeUsesTheRemoteAttachmentTimeAndTheCurrentMonotonicSample() {
        var elapsed = 1000L
        val session = NativeSession { elapsed }
        val remote = mapOf("generation" to 7L, "phase" to "ready", "vpnRunning" to true,
            "runningSinceElapsedMs" to 500L)
        session.project(remote)
        assertEquals(500L, session.snapshot().runningSinceElapsedMs)
        elapsed += 10L * 366 * 24 * 60 * 60 * 1000
        session.project(remote)
        assertEquals(500L, session.snapshot().runningSinceElapsedMs)
        assertEquals(elapsed, session.snapshot().elapsedRealtimeMs)
        session.project(remote - "runningSinceElapsedMs")
        assertNull(session.snapshot().runningSinceElapsedMs)
    }

    @Test fun eachProjectionReplacesIdentityErrorAndRunningTime() {
        val session = NativeSession { 0L }
        session.project(mapOf("generation" to 4, "configId" to "first", "revision" to 3L,
            "phase" to "ready", "vpnRunning" to true, "runningSinceElapsedMs" to 100L,
            "error" to "原始错误🙂"))
        assertEquals(4L, session.snapshot().generation)
        assertEquals("first", session.snapshot().configId)
        assertEquals(3, session.snapshot().revision)
        session.project(mapOf("generation" to 5L, "configId" to "second", "revision" to 7,
            "phase" to "loading"))
        assertEquals(NativeSession.Snapshot(5, NativeSession.Phase.STARTING, null,
            "second", 7, null, 0), session.snapshot())
        session.project(mapOf("phase" to "empty"))
        assertEquals(NativeSession.Snapshot(5, NativeSession.Phase.STOPPED, null,
            null, null, null, 0), session.snapshot())
    }

    @Test fun stoppingAndCommunicationLossRetainTheProjectedIdentityButHideUptime() {
        val session = NativeSession { 900L }
        val remote = mapOf("generation" to 8L, "configId" to "actual", "revision" to 2,
            "vpnRunning" to true, "runningSinceElapsedMs" to 400L)
        for ((phase, expected) in mapOf("stopping" to NativeSession.Phase.STOPPING,
            "communicationLost" to NativeSession.Phase.UNKNOWN)) {
            session.project(remote + mapOf("phase" to phase, "error" to "实际退出尚未确认"))
            assertEquals(expected, session.snapshot().phase)
            assertEquals("actual", session.snapshot().configId)
            assertEquals(2, session.snapshot().revision)
            assertEquals(8L, session.snapshot().generation)
            assertNull(session.snapshot().runningSinceElapsedMs)
            assertEquals("实际退出尚未确认", session.snapshot().error!!.detail)
        }
    }

    @Test fun errorsRetainTheOriginalDetailAndClearWithTheNextProjection() {
        val original = "https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture"
        val session = NativeSession { 0L }
        session.project(mapOf("phase" to "communicationLost", "error" to original))
        assertEquals(AppMessage("operationNotCompletedRetry").withDetail(original), session.snapshot().error)
        assertEquals(original, session.snapshot().error!!.detail)
        session.project(mapOf("phase" to "ready", "vpnRunning" to false))
        assertNull(session.snapshot().error)
    }
}
