package io.github.monadboxlab.clashpseudo.nativecore

import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class CoreLifecycleRecordTest {
    private fun fixture(block: (File) -> Unit) {
        val root = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "lifecycle-${UUID.randomUUID()}")
        check(root.mkdir())
        try { block(File(root, "record.json")) } finally { check(root.deleteRecursively()) }
    }
    private fun running(file: File, boot: Int?) = CoreLifecycleRecord(file) { boot }.apply {
        initialize(false); starting("process", "input", false); running("process", "input")
    }

    @Test fun sameBootUnrequestedExitPausesRecoveryAcrossLaterBoots() = fixture { file ->
        running(file, 10)
        val failed = CoreLifecycleRecord(file) { 10 }.initialize(false)
        assertTrue(failed.recoveryRequired)
        assertEquals(Contract.CORE_PHASE_RECOVERY_REQUIRED, failed.stage)
        assertTrue(CoreLifecycleRecord(file) { 11 }.initialize(false).recoveryRequired)
    }

    @Test fun aKnownNormalRebootDoesNotCreateANewRecoveryPause() = fixture { file ->
        running(file, 10)
        val state = CoreLifecycleRecord(file) { 11 }.initialize(false)
        assertFalse(state.recoveryRequired)
        assertEquals(Contract.CORE_PHASE_EXITED, state.stage)
    }

    @Test fun unknownBootCountDoesNotTreatAResidualRunAsANormalReboot() = fixture { file ->
        running(file, null)
        assertTrue(CoreLifecycleRecord(file) { null }.initialize(false).recoveryRequired)
    }

    @Test fun aHeldResourceLockDoesNotInventProcessDeath() = fixture { file ->
        running(file, 10)
        val state = CoreLifecycleRecord(file) { 10 }.initialize(true)
        assertFalse(state.recoveryRequired)
        assertEquals("running", state.stage)
    }

    @Test fun aStartingRecordAlsoRequiresUserRecoveryAfterUnexpectedDeath() = fixture { file ->
        CoreLifecycleRecord(file) { 10 }.apply { initialize(false); starting("process", "input", false) }
        assertTrue(CoreLifecycleRecord(file) { 10 }.initialize(false).recoveryRequired)
    }

    @Test fun onlyExplicitUserPrepareCanClearAnExistingRecoveryPause() = fixture { file ->
        running(file, 10)
        val lifecycle = CoreLifecycleRecord(file) { 10 }.apply { initialize(false) }
        try { lifecycle.starting("new-process", "new-input", false); fail("System restore must not resume a paused state") }
        catch (error: CoreTransportException) { assertEquals(Contract.CORE_ERROR_RECOVERY_REQUIRED, error.code) }
        assertTrue(lifecycle.snapshot().recoveryRequired)
        lifecycle.starting("new-process", "new-input", true)
        assertFalse(lifecycle.snapshot().recoveryRequired)
        assertEquals("starting", lifecycle.snapshot().stage)
    }

    @Test fun everyExplicitExitReasonRemainsExpectedAfterColdStart() = fixture { file ->
        for (reason in listOf("stop", "reconnect", "previewExpired", "idle", "cleanup", "revoked", "shutdown")) {
            running(file, 10).requestExit("process", reason)
            val state = CoreLifecycleRecord(file) { 10 }.initialize(false)
            assertFalse(reason, state.recoveryRequired)
            assertEquals(reason, state.exitReason)
            assertEquals(Contract.CORE_PHASE_EXITED, state.stage)
        }
    }

    @Test fun oldProcessAndInputReceiptsCannotMutateTheCurrentRun() = fixture { file ->
        val lifecycle = running(file, 10)
        lifecycle.died("old-process")
        assertEquals("running", lifecycle.snapshot().stage)
        try { lifecycle.running("process", "old-input"); fail("An old inputId must not be marked running") }
        catch (_: IllegalStateException) { }
        assertEquals("input", lifecycle.snapshot().inputId)
    }

    @Test fun pendingCleanupPreventsEveryNewPrepareIncludingUserRecovery() = fixture { file ->
        val lifecycle = running(file, 10)
        lifecycle.cleanup(true)
        try { lifecycle.starting("new-process", "new-input", true); fail("Pending cleanup must prevent preparation") }
        catch (_: IllegalStateException) { }
        assertTrue(CoreLifecycleRecord(file) { 10 }.initialize(true).cleanupPending)
        lifecycle.cleanup(false)
        lifecycle.starting("new-process", "new-input", true)
        assertEquals("new-input", lifecycle.snapshot().inputId)
    }
}
