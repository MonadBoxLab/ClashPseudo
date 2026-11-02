package io.github.monadboxlab.clashpseudo.bridge.runtime

import java.util.concurrent.CountDownLatch
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import org.junit.Assert.*
import org.junit.Test

class ScheduledRunTest {
    @Test fun queueingBeforeAdmissionKeepsTheWholeNetworkBudget() {
        var clock = 1000L
        val run = ScheduledRuns.ScheduledRun({ false }, { clock })
        assertFalse(run.authorized())
        assertFalse(run.handoff())
        assertEquals(0L, run.remainingMs())
        clock = 41_000L
        run.admit()
        assertTrue(run.authorized())
        assertEquals(151_000L, run.deadline)
        assertEquals(110_000L, run.remainingMs())
        clock = 150_999L
        assertEquals(1L, run.remainingMs())
        assertTrue(run.handoff())
        assertEquals(10_001L, run.remainingMs())
        clock = 161_000L
        assertFalse(run.authorized())
        assertEquals(0L, run.remainingMs())
    }

    @Test fun handoffFreezesOnlyTheWorkerReceipt() {
        val run = ScheduledRuns.ScheduledRun({ false }, { 0L }).apply { admit() }
        assertTrue(run.handoff())
        assertEquals(0L, run.done.count)
        assertEquals("saved", run.outcome["scheduleStatus"])
        assertFalse(run.cancelWorker())
        assertFalse(run.cancelled.get())
        run.finish(mapOf("scheduleStatus" to "applyFailed"))
        assertEquals("saved", run.outcome["scheduleStatus"])
        run.cancel()
        assertTrue(run.cancelled.get())
        assertEquals("saved", run.outcome["scheduleStatus"])
        assertFalse(run.handoff())
    }

    @Test fun stoppedWorkerCannotHandOffBeforeItsQueuedCancellation() {
        val run = ScheduledRuns.ScheduledRun({ true }, { 0L }).apply { admit() }
        assertFalse(run.handoff())
        assertEquals(1L, run.done.count)
        assertTrue(run.cancelWorker())
        assertTrue(run.cancelled.get())
        assertEquals("cancelled", run.outcome["scheduleStatus"])
        run.finish(mapOf("success" to true))
        assertEquals("cancelled", run.outcome["scheduleStatus"])
    }

    @Test fun downloadDeadlineRejectsLocalAdoption() {
        var clock = 0L
        val run = ScheduledRuns.ScheduledRun({ false }, { clock }).apply { admit() }
        clock = 110_000L
        assertFalse(run.handoff())
        assertTrue(run.cancelWorker())
        assertEquals("cancelled", run.outcome["scheduleStatus"])
    }

    @Test fun explicitCancellationBeforeHandoffCannotBeRevived() {
        val run = ScheduledRuns.ScheduledRun({ false }, { 0L }).apply { admit() }
        run.cancel()
        assertTrue(run.cancelled.get())
        assertEquals(0L, run.done.count)
        assertEquals("cancelled", run.outcome["scheduleStatus"])
        assertFalse(run.handoff())
        assertFalse(run.cancelWorker())
    }

    @Test fun ordinaryCompletionCannotBeOverwrittenByLateWorkerCancellation() {
        val run = ScheduledRuns.ScheduledRun({ false }, { 0L }).apply { admit() }
        run.finish(mapOf("success" to false, "scheduleStatus" to "failed"))
        assertFalse(run.cancelWorker())
        assertFalse(run.handoff())
        assertFalse(run.cancelled.get())
        assertEquals("failed", run.outcome["scheduleStatus"])
    }

    @Test fun handoffKeepsTheOriginalOrdinaryOperationDeadline() {
        var clock = 0L
        var stopped = false
        val run = ScheduledRuns.ScheduledRun({ stopped }, { clock }).apply { admit() }
        assertTrue(run.authorized())
        clock = 109_999L
        assertTrue(run.handoff())
        assertEquals(10_001L, run.applicationRemainingMs())
        stopped = true
        assertTrue("A retired network Worker cannot revoke local application", run.authorized())
        clock = 119_999L
        assertTrue(run.authorized())
        assertEquals(1L, run.applicationRemainingMs())
        clock = 120_000L
        assertFalse("Elapsed expiry must work even before the main timer runs", run.authorized())
        assertEquals(0L, run.applicationRemainingMs())
        run.cancel()
        assertTrue(run.cancelled.get())
        assertEquals("saved", run.outcome["scheduleStatus"])
    }

    @Test fun endedOrStoppedNetworkWorkHasNoPublicationAuthority() {
        var stopped = false
        val run = ScheduledRuns.ScheduledRun({ stopped }, { 0L }).apply { admit() }
        assertTrue(run.authorized())
        stopped = true
        assertFalse(run.authorized())
        assertFalse(run.handoff())
        val completed = ScheduledRuns.ScheduledRun({ false }, { 0L }).apply { admit() }
        completed.finish(mapOf("success" to true))
        assertFalse(completed.authorized())
        val adopted = ScheduledRuns.ScheduledRun({ false }, { 0L }).apply { admit() }
        assertTrue(adopted.handoff())
        assertTrue(adopted.authorized())
        adopted.finish(mapOf("scheduleStatus" to "applied"))
        assertFalse(adopted.authorized())
        assertEquals("saved", adopted.outcome["scheduleStatus"])
    }

    @Test fun shortPublicationRechecksStoppedWorkAndBothElapsedDeadlines() {
        var clock = 0L
        var stopped = false
        var publications = 0
        val run = ScheduledRuns.ScheduledRun({ stopped }, { clock }).apply { admit() }
        clock = 109_999L
        run.publishIfAuthorized { publications++ }
        stopped = true
        assertThrows(IllegalStateException::class.java) { run.publishIfAuthorized { publications++ } }
        stopped = false
        clock = 110_000L
        assertThrows(IllegalStateException::class.java) { run.publishIfAuthorized { publications++ } }
        assertEquals(1, publications)

        val adopted = ScheduledRuns.ScheduledRun({ stopped }, { clock }).apply { admit() }
        assertTrue(adopted.handoff())
        stopped = true
        clock = 229_999L
        adopted.publishIfAuthorized { publications++ }
        clock = 230_000L
        assertThrows(IllegalStateException::class.java) { adopted.publishIfAuthorized { publications++ } }
        assertEquals(2, publications)
        adopted.cancel()
        assertThrows(IllegalStateException::class.java) { adopted.publishIfAuthorized { publications++ } }
        assertEquals("saved", adopted.outcome["scheduleStatus"])
    }

    @Test fun workerCancellationCannotSplitAnAdmittedShortPublication() {
        val run = ScheduledRuns.ScheduledRun({ false }, { 0L }).apply { admit() }
        val executor = Executors.newFixedThreadPool(2)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val cancelling = CountDownLatch(1)
        try {
            val publication = executor.submit {
                run.publishIfAuthorized {
                    entered.countDown()
                    check(release.await(5, TimeUnit.SECONDS))
                }
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val cancellation = executor.submit<Boolean> {
                cancelling.countDown()
                run.cancelWorker()
            }
            assertTrue(cancelling.await(5, TimeUnit.SECONDS))
            assertThrows(TimeoutException::class.java) { cancellation.get(100, TimeUnit.MILLISECONDS) }
            release.countDown()
            publication.get(5, TimeUnit.SECONDS)
            assertTrue(cancellation.get(5, TimeUnit.SECONDS))
            assertFalse(run.authorized())
            assertThrows(IllegalStateException::class.java) { run.publishIfAuthorized { fail("Cancelled owner published") } }
        } finally {
            release.countDown()
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
        }
    }

    @Test fun workerExitAndHandoffHaveOneCommonWinner() {
        val executor = Executors.newFixedThreadPool(2)
        try {
            repeat(20) {
                val run = ScheduledRuns.ScheduledRun({ false }, { 0L }).apply { admit() }
                val start = CyclicBarrier(3)
                val handoff = executor.submit<Boolean> {
                    start.await(5, TimeUnit.SECONDS)
                    run.handoff()
                }
                val cancellation = executor.submit<Boolean> {
                    start.await(5, TimeUnit.SECONDS)
                    run.cancelWorker()
                }
                start.await(5, TimeUnit.SECONDS)
                val adopted = handoff.get(5, TimeUnit.SECONDS)
                val cancelled = cancellation.get(5, TimeUnit.SECONDS)
                assertNotEquals(adopted, cancelled)
                assertEquals(0L, run.done.count)
                assertEquals(cancelled, run.cancelled.get())
                assertEquals(if (adopted) "saved" else "cancelled", run.outcome["scheduleStatus"])
            }
        } finally {
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
        }
    }
}
