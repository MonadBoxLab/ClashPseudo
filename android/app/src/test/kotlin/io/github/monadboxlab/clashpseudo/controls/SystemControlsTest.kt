package io.github.monadboxlab.clashpseudo.controls

import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.app.VpnWidgetProvider

import io.github.monadboxlab.clashpseudo.R
import org.junit.Assert.*
import org.junit.Test

class SystemControlsTest {
    private val pkg = "io.github.monadboxlab.clashpseudo"

    private fun state(vararg changes: Pair<String, Any?>): SystemControls.Projection =
        SystemControls.project(mapOf<String, Any?>(
            "phase" to "STOPPED", "savedModeKnown" to true, "savedMode" to null,
            "busy" to false, "failed" to false, "pendingStart" to false,
            "pendingSystemStart" to false,
        ) + changes.toMap())

    @Test fun publicOverviewActionOnlyRequestsNavigationAndIsNeverReplayed() {
        assertTrue(SystemControls.overviewRequested(SystemControls.ACTION_OPEN_OVERVIEW, false, false))
        for ((restored, history) in listOf(true to false, false to true, true to true)) {
            assertFalse(SystemControls.overviewRequested(SystemControls.ACTION_OPEN_OVERVIEW, restored, history))
        }
        for (action in listOf(null, "start", "stop", "android.intent.action.MAIN")) {
            assertFalse(SystemControls.overviewRequested(action, false, false))
        }
        assertNull(SystemControls.shortcutAction(pkg, pkg, "$pkg.MainActivity", false, false))
    }

    @Test fun repeatedRefreshEventsQueueOnlyOneFollowUpActualRead() {
        val reads = SystemControls.RefreshRead()
        assertTrue(reads.request())
        repeat(1000) { assertFalse(reads.request()) }
        assertTrue(reads.complete())
        // The follow-up is already reserved until its actual completion.
        assertFalse(reads.complete())
        assertTrue(reads.request())
        assertFalse(reads.complete())
    }

    @Test fun eventsDuringTheFollowUpStillRefreshTheFinalState() {
        val reads = SystemControls.RefreshRead()
        assertTrue(reads.request())
        assertFalse(reads.request())
        assertTrue(reads.complete())
        repeat(1000) { assertFalse(reads.request()) }
        assertTrue(reads.complete())
        assertFalse(reads.complete())
        assertTrue(reads.request())
        assertFalse(reads.complete())
    }

    @Test(expected = IllegalStateException::class)
    fun aMissingCompletionCannotBeInventedToReleaseTheRead() {
        SystemControls.RefreshRead().complete()
    }

    @Test fun restoringDataKeepsAnExplicitStopInEveryNativePhase() {
        for (phase in listOf("STOPPED", "STARTING", "RUNNING", "STOPPING", "UNKNOWN")) {
            val projection = state("phase" to phase, "pendingRestore" to true)
            assertTrue(projection.pendingRestore)
            assertTrue(projection.busy)
            assertEquals("stop", projection.action)
            assertTrue(projection.enabled)
            assertTrue(projection.tileEnabled)
            assertEquals(R.string.system_control_restoring, projection.statusResource)
        }
    }

    @Test fun stoppedRestoreIsBusyDataWorkNotAPreparingVpnStart() {
        val projection = state("pendingRestore" to true, "busy" to false)
        assertFalse(projection.preparing)
        assertTrue(projection.busy)
        assertEquals(R.string.system_control_restoring, projection.statusResource)
        assertNotEquals(R.string.system_control_starting, projection.statusResource)
        repeat(3) { assertEquals("stop", projection.action) }
    }

    @Test fun onlyAnActualBooleanCanClaimAPendingRestore() {
        for (value in listOf(null, false, "true", 1)) {
            val projection = state("pendingRestore" to value)
            assertFalse(projection.pendingRestore)
            assertEquals("start", projection.action)
            assertTrue(projection.enabled)
            assertEquals(R.string.system_control_stopped, projection.statusResource)
        }
    }

    @Test fun aFinishedRestoreDoesNotLeaveASecondPersistentStopState() {
        assertEquals("stop", state("pendingRestore" to true).action)
        val completed = state("pendingRestore" to false)
        assertFalse(completed.pendingRestore)
        assertFalse(completed.busy)
        assertEquals("start", completed.action)
        assertEquals(R.string.system_control_stopped, completed.statusResource)
    }

    @Test fun restoreStatusDoesNotMasqueradeAsStartWhenAnOlderStartFlagRemains() {
        val projection = state("pendingRestore" to true, "pendingStart" to true)
        assertEquals("stop", projection.action)
        assertEquals(R.string.system_control_restoring, projection.statusResource)
    }

    @Test fun privateAliasComponentsHaveFixedActions() {
        assertEquals("start", SystemControls.shortcutAction(pkg, pkg, "$pkg.StartVpnShortcut", false, false))
        assertEquals("stop", SystemControls.shortcutAction(pkg, pkg, "$pkg.StopVpnShortcut", false, false))
    }

    @Test fun publicActivityHasNoControlAuthority() {
        assertNull(SystemControls.shortcutAction(pkg, pkg, "$pkg.MainActivity", false, false))
        assertNull(SystemControls.shortcutAction(pkg, pkg, null, false, false))
        assertNull(SystemControls.shortcutAction(pkg, null, "$pkg.StartVpnShortcut", false, false))
    }

    @Test fun foreignOrSimilarComponentsAreNotTrustedAliases() {
        for (name in listOf("StartVpnShortcut", "$pkg.StartVpnShortcut.extra", "$pkg.StartVpnShortcut/stop")) {
            assertNull(SystemControls.shortcutAction(pkg, pkg, name, false, false))
        }
        assertNull(SystemControls.shortcutAction(pkg, "foreign.package", "$pkg.StartVpnShortcut", false, false))
    }

    @Test fun recreationAndHistoryNeverReplayAnAlias() {
        for (alias in listOf("StartVpnShortcut", "StopVpnShortcut")) {
            for ((restored, history) in listOf(true to false, false to true, true to true)) {
                assertNull(SystemControls.shortcutAction(pkg, pkg, "$pkg.$alias", restored, history))
            }
        }
    }

    @Test fun legalUnsetFallbackMeansConfigurationNotRule() {
        val projection = state()
        assertTrue(projection.savedModeKnown)
        assertNull(projection.savedMode)
        assertEquals(SystemControls.ModeSource.CONFIGURATION, projection.modeSource)
    }

    @Test fun storageFailureDoesNotMasqueradeAsAnUnsetFallback() {
        for (known in listOf(null, false, "true")) {
            val projection = state("savedModeKnown" to known)
            assertFalse(projection.savedModeKnown)
            assertEquals(SystemControls.ModeSource.UNKNOWN, projection.modeSource)
        }
    }

    @Test fun invalidSavedModeNeverBecomesConfigurationMode() {
        for (mode in listOf("invalid", "RULE", 1, true)) {
            val projection = state("savedMode" to mode)
            assertFalse(projection.savedModeKnown)
            assertEquals(SystemControls.ModeSource.UNKNOWN, projection.modeSource)
        }
    }

    @Test fun stoppedProjectionUsesOnlyAConfirmedSavedFallback() {
        for (mode in listOf("rule", "global", "direct")) {
            val projection = state("savedMode" to mode, "mode" to "direct")
            assertEquals(SystemControls.ModeSource.SAVED, projection.modeSource)
            assertEquals(mode, projection.savedMode)
        }
    }

    @Test fun actualRunningModeWinsOverSavedFallback() {
        val projection = state("phase" to "RUNNING", "mode" to "direct", "savedMode" to "global")
        assertEquals(SystemControls.ModeSource.ACTUAL, projection.modeSource)
        assertEquals("direct", projection.mode)
        assertEquals("stop", projection.action)
    }

    @Test fun missingActualModeIsNotFilledFromSavedData() {
        for (mode in listOf(null, "invalid", "RULE", 1)) {
            val projection = state("phase" to "RUNNING", "mode" to mode, "savedMode" to "rule")
            assertNull(projection.mode)
            assertEquals(SystemControls.ModeSource.UNKNOWN, projection.modeSource)
        }
    }

    @Test fun startingAndStoppingNeverPresentFallbackAsActualMode() {
        for (phase in listOf("STARTING", "STOPPING", "UNKNOWN")) {
            assertEquals(SystemControls.ModeSource.UNKNOWN,
                state("phase" to phase, "mode" to "rule", "savedMode" to "global").modeSource)
        }
    }

    @Test fun preparingOrdinaryStartCanBeStoppedBeforeNativePhaseChanges() {
        val projection = state("pendingStart" to true, "busy" to true)
        assertEquals("STOPPED", projection.phase)
        assertEquals("stop", projection.action)
        assertTrue(projection.enabled)
        assertEquals(R.string.system_control_starting, projection.statusResource)
    }

    @Test fun preparingSystemStartAlsoKeepsAnExplicitStop() {
        val projection = state("pendingSystemStart" to true, "busy" to true)
        assertEquals("stop", projection.action)
        assertTrue(projection.enabled)
    }

    @Test fun stoppingCannotOfferStartOrAdvertiseAnotherConnection() {
        val projection = state("phase" to "STOPPING", "pendingStart" to true, "busy" to true)
        assertNull(projection.action)
        assertFalse(projection.enabled)
        assertFalse(projection.tileEnabled)
        assertEquals(R.string.system_control_stopping, projection.statusResource)
    }

    @Test fun unrelatedBusyWorkDoesNotOfferAnotherStart() {
        val projection = state("busy" to true)
        assertEquals("start", projection.action)
        assertFalse(projection.enabled)
        assertTrue(projection.tileEnabled)
        assertEquals(R.string.system_control_busy, projection.statusResource)
    }

    @Test fun aConfirmedStoppedFailureStillAllowsAnExplicitRetry() {
        val projection = state("failed" to true)
        assertEquals(R.string.system_control_failed, projection.statusResource)
        assertEquals("start", projection.action)
        assertTrue(projection.enabled)
    }

    @Test fun unknownOrMalformedProjectionFailsClosed() {
        for (value in listOf(emptyMap(), mapOf("phase" to "RUNNING " as Any?),
            mapOf("phase" to 1 as Any?), mapOf("phase" to "UNKNOWN" as Any?))) {
            val projection = SystemControls.project(value)
            assertEquals("UNKNOWN", projection.phase)
            assertNull(projection.action)
            assertFalse(projection.enabled)
            assertTrue(projection.busy)
            assertEquals(SystemControls.ModeSource.UNKNOWN, projection.modeSource)
        }
    }

    @Test fun malformedBusyFlagDoesNotEnableStart() {
        for (busy in listOf(null, "false", 0)) assertFalse(state("busy" to busy).enabled)
    }

    @Test fun onlyMissingAuthorizationCarriesAnUnacceptedStartIntoTheActivity() {
        for (admission in SystemControls.Admission.values()) {
            for (action in listOf("start", "stop")) {
                for (permissionRequired in listOf(false, true)) {
                    val expected = if (admission == SystemControls.Admission.OPEN_APP &&
                        action == "start" && permissionRequired) "start" else null
                    assertEquals(expected, SystemControls.permissionResumeAction(action, admission, permissionRequired))
                }
            }
        }
    }

    @Test fun staleWidgetStopRemainsStopWhenTheCurrentProjectionWouldOfferStart() {
        assertEquals("start", state().action)
        assertEquals("stop", VpnWidgetProvider.widgetAction(VpnWidgetProvider.ACTION_STOP))
        assertEquals("start", VpnWidgetProvider.widgetAction(VpnWidgetProvider.ACTION_START))
        assertNull(VpnWidgetProvider.widgetAction("toggle"))
        assertNull(VpnWidgetProvider.widgetAction(null))
    }

    @Test fun busyStartKeepsItsFixedStartActionAndNeverToggles() {
        // A queued start disables another start while retaining its start action
        // identity.
        assertEquals("start", VpnWidgetProvider.capsuleAction(state("busy" to true)))
        assertEquals("start", VpnWidgetProvider.capsuleAction(state("failed" to true)))
        assertEquals("stop", VpnWidgetProvider.capsuleAction(state("phase" to "RUNNING",
            "mode" to "rule", "busy" to true)))
        assertEquals("stop", VpnWidgetProvider.capsuleAction(state("pendingSystemStart" to true,
            "busy" to true)))
        assertEquals("stop", VpnWidgetProvider.capsuleAction(state("pendingRestore" to true,
            "busy" to true)))
        assertNull(VpnWidgetProvider.capsuleAction(state("phase" to "STOPPING", "busy" to true)))
        assertNull(VpnWidgetProvider.capsuleAction(state("phase" to "UNKNOWN")))
    }
}
