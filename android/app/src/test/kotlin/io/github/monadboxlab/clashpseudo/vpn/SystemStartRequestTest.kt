package io.github.monadboxlab.clashpseudo.vpn

import org.junit.Assert.*
import org.junit.Test

class SystemStartRequestTest {
    @Test fun userStopAndRevokeRemainFinalEvenWithoutAnAdmittedRestore() {
        val request = SystemStartRequest()
        assertNull(request.cancel(terminal = true))
        assertNull(request.begin(1))
        request.allow()
        val old = request.begin(2)!!
        request.cancel(terminal = true)
        assertFalse(request.current(old))
        assertNull(request.begin(3))
        assertNull(request.cancel())
        assertNull(request.begin(4))
        request.allow()
        assertNotNull(request.begin(5))
    }

    @Test fun internalReconnectCancellationAllowsOneNewSystemRequest() {
        val request = SystemStartRequest()
        val old = request.begin(1)!!
        val cleanup = request.cancel()!!
        val next = request.begin(2)!!
        assertNull(request.begin(3))
        assertFalse(request.current(old))
        assertFalse(request.idle(cleanup.second))
        assertTrue(request.current(next))
        assertEquals(3, request.finish(next))
    }

    @Test fun manualStartCannotReviveADestroyedServiceRequest() {
        val request = SystemStartRequest()
        request.destroy()
        request.allow()
        assertNull(request.begin(1))
    }

    @Test fun stoppingAdmitsOneSystemIntentButStartingRunningAndUnknownDoNot() {
        for (phase in NativeSession.Phase.values()) {
            val request = SystemStartRequest()
            val owner = request.begin(1, phase)
            if (phase in setOf(NativeSession.Phase.STOPPING, NativeSession.Phase.STOPPED)) {
                assertNotNull(owner)
                assertNull(request.begin(2, phase))
                assertEquals(2, request.finish(owner!!))
            } else {
                assertNull(owner)
                assertFalse(request.pending())
            }
        }
    }

    @Test fun duplicateSystemStartKeepsOneRestoreAndTheLatestStartId() {
        val request = SystemStartRequest()
        val owner = request.begin(10)!!
        assertNull(request.begin(11))
        assertTrue(request.current(owner))
        assertEquals(11, request.finish(owner))
        assertNull(request.finish(owner))
    }

    @Test fun ignoredIntentsUpdateCleanupIdentityWithoutCreatingARestore() {
        val request = SystemStartRequest()
        request.observeStart(1)
        assertFalse(request.pending())
        val owner = request.begin(2)!!
        request.observeStart(3)
        assertEquals(3, request.finish(owner))
        request.observeStart(4)
        assertFalse(request.pending())
    }

    @Test fun stopOrRevokeRejectsBothLateSuccessAndLateFailure() {
        val request = SystemStartRequest()
        val old = request.begin(10)!!
        val cancelled = request.cancel()!!
        assertTrue(request.idle(cancelled.second))
        assertFalse(request.current(old))
        assertNull(request.finish(old))
        val current = request.begin(12)!!
        assertFalse(request.idle(cancelled.second))
        assertNull(request.finish(old))
        assertTrue(request.current(current))
        assertEquals(12, request.finish(current))
    }

    @Test fun repeatedCancellationPreservesTheAlreadyQueuedCleanup() {
        val request = SystemStartRequest()
        val owner = request.begin(10)!!
        val cancelled = request.cancel()!!
        assertNull(request.cancel())
        assertTrue(request.idle(cancelled.second))
        assertFalse(request.current(owner))
        assertNull(request.finish(owner))
        request.begin(11)
        assertFalse(request.idle(cancelled.second))
    }

    @Test fun destructionCannotBeUndoneByALateCallbackOrAnotherStart() {
        val request = SystemStartRequest()
        val old = request.begin(1)!!
        request.destroy()
        assertFalse(request.current(old))
        assertNull(request.finish(old))
        assertNull(request.begin(2))
    }

    @Test fun allApplicationsDoesNotBuildAnAllowedOrDisallowedList() {
        var calls = 0
        assertFalse(applyApplicationPackages("all", listOf("one")) {
            calls++
            true
        })
        assertEquals(0, calls)
    }

    @Test fun aMissingAllowListNeverFallsBackToAllApplications() {
        try {
            applyApplicationPackages("only", listOf("gone")) { false }
            fail("a completely missing allow list was accepted")
        } catch (_: MissingAllowedApplications) { }
        try {
            applyApplicationPackages("only", emptyList()) { true }
            fail("an empty allow list was accepted")
        } catch (_: MissingAllowedApplications) { }
    }

    @Test fun uninstallDuringBuilderSetupIsReportedWithoutDroppingOtherApps() {
        val attempted = mutableListOf<String>()
        val missing = applyApplicationPackages("only", listOf("installed", "gone")) {
            attempted.add(it)
            it == "installed"
        }
        assertTrue(missing)
        assertEquals(listOf("installed", "gone"), attempted)
        assertTrue(applyApplicationPackages("except", listOf("gone")) { false })
        assertFalse(applyApplicationPackages("only", listOf("installed")) { true })
    }
}
