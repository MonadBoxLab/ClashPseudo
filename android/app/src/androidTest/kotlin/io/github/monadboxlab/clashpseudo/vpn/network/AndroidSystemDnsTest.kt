package io.github.monadboxlab.clashpseudo.vpn.network

import android.os.SystemClock
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.nativecore.CoreFrames
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicInteger

class AndroidSystemDnsTest {
    private class Fixture {
        val callbacks = AtomicInteger()
        val dns = AndroidSystemDns(UnderlyingSnapshot(null, emptyList(), "unavailable", 7),
            Executor { callbacks.incrementAndGet(); throw AssertionError("Must not submit a system callback without a captured Network") })
        fun raw(id: Long, wire: ByteArray = byteArrayOf(1)) = json(dns.raw(id, wire))
        fun cancel(id: Long) = json(dns.cancel(id))
        fun assertIdle() { assertTrue(dns.idle); assertEquals(0, callbacks.get()) }
    }
    companion object {
        private fun json(bytes: ByteArray) = JSONObject(CoreFrames.utf8(bytes))
    }

    @Test fun missingCapturedNetworkKeepsCapabilityErrorWithoutFabricatingDnsWireOrRcode() {
        val f = Fixture()
        val value = f.raw(1)
        assertEquals(Contract.CORE_ERROR_CAPABILITY_UNAVAILABLE, value.getJSONObject("error").getString("code"))
        assertFalse(value.has("wire")); assertFalse(value.has("rcode"))
        assertFalse(value.getBoolean("cancelled")); assertTrue(value.getBoolean("exited")); f.assertIdle()
        val lookup = json(f.dns.lookup(2, "fixture.test", 4))
        assertEquals(Contract.CORE_ERROR_CAPABILITY_UNAVAILABLE, lookup.getJSONObject("error").getString("code"))
        assertFalse(lookup.has("addresses")); assertTrue(lookup.getBoolean("exited")); f.assertIdle()
    }

    @Test fun rawWireUsesExactByteBudgetAndRetainsTheOversizeError() {
        val f = Fixture()
        assertEquals(Contract.CORE_ERROR_CAPABILITY_UNAVAILABLE,
            f.raw(1, ByteArray(Contract.DNS_REQUEST_BYTES)).getJSONObject("error").getString("code"))
        val large = f.raw(2, ByteArray(Contract.DNS_REQUEST_BYTES + 1))
        assertEquals(Contract.CORE_ERROR_INPUT_TOO_LARGE, large.getJSONObject("error").getString("code"))
        assertTrue(large.getBoolean("exited")); f.assertIdle()
    }

    @Test fun cancellationBeforeRegistrationAffectsOnlyItsOwnQueryId() {
        val f = Fixture()
        val before = f.cancel(2)
        assertTrue(before.getBoolean("cancelled")); assertFalse(before.getBoolean("exited"))
        assertFalse(f.raw(1).getBoolean("cancelled"))
        assertTrue(f.raw(2).getBoolean("cancelled"))
        assertFalse(f.raw(3).getBoolean("cancelled"))
        val completed = f.cancel(2)
        assertFalse(completed.getBoolean("cancelled")); assertTrue(completed.getBoolean("exited")); f.assertIdle()
    }

    @Test fun outOfOrderCompletedIdsCannotBecomePermanentEarlyCancellationRecords() {
        val f = Fixture()
        for (id in listOf(3L, 1L, 2L)) {
            assertTrue(f.raw(id).getBoolean("exited"))
            val completed = f.cancel(id)
            assertFalse(completed.getBoolean("cancelled")); assertTrue(completed.getBoolean("exited"))
        }
        assertFalse(f.raw(4).getBoolean("cancelled")); f.assertIdle()
    }

    @Test fun invalidLookupConsumesItsRegisteredIdButNeverStartsPlatformWork() {
        val f = Fixture()
        val invalid = json(f.dns.lookup(1, "fixture.test", 5))
        assertEquals("IllegalArgumentException", invalid.getJSONObject("error").getString("type").substringAfterLast('.'))
        assertTrue(invalid.getBoolean("exited"))
        val completed = f.cancel(1)
        assertFalse(completed.getBoolean("cancelled")); assertTrue(completed.getBoolean("exited"))
        assertThrows(IllegalStateException::class.java) { f.raw(1) }
        assertThrows(IllegalArgumentException::class.java) { f.raw(0) }; f.assertIdle()
    }

    @Test fun silentPlatformCancellationReleasesTheInvocation() {
        val submitted = java.util.concurrent.CountDownLatch(1)
        val dns = AndroidSystemDns(UnderlyingSnapshot(android.net.Network.fromNetworkHandle(0x1cafed00dL), emptyList(), "unavailable", 7),
            Executor { it.run() }) { _, _, _, cancellation, _ ->
            cancellation.setOnCancelListener { }
            submitted.countDown()
        }
        val result = java.util.concurrent.CompletableFuture.supplyAsync { json(dns.raw(1, byteArrayOf(1))) }
        assertTrue(submitted.await(5, java.util.concurrent.TimeUnit.SECONDS))
        assertFalse(dns.idle)
        dns.cancel(1)
        val value = result.get(5, java.util.concurrent.TimeUnit.SECONDS)
        assertTrue(value.getBoolean("cancelled"))
        assertTrue(value.isNull("wire"))
        dns.awaitIdle(SystemClock.elapsedRealtime() + 5000)
        assertTrue(dns.idle)
    }

    @Test fun cancelledQueuedRunnableMustDrainEvenWhenThePlatformSkipsTheCallback() {
        val queue = java.util.concurrent.LinkedBlockingQueue<Runnable>()
        val dns = AndroidSystemDns(UnderlyingSnapshot(android.net.Network.fromNetworkHandle(0x1cafed00dL), emptyList(), "unavailable", 7),
            Executor { queue.add(it) }) { _, _, executor, cancellation, callback ->
            executor.execute { if (!cancellation.isCanceled) callback.onAnswer(byteArrayOf(2), 0) }
        }
        val result = java.util.concurrent.CompletableFuture.supplyAsync { json(dns.raw(1, byteArrayOf(1))) }
        val queued = checkNotNull(queue.poll(5, java.util.concurrent.TimeUnit.SECONDS))
        dns.close()
        assertTrue(result.get(5, java.util.concurrent.TimeUnit.SECONDS).getBoolean("cancelled"))
        assertFalse("The queued platform runnable still owns work", dns.idle)
        queued.run()
        assertTrue(dns.idle)
    }

    @Test fun callbackAlreadyRunningAndCancellationReturnAreBothDrainBarriers() {
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val cancelling = java.util.concurrent.CountDownLatch(1)
        val releaseCancel = java.util.concurrent.CountDownLatch(1)
        val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
        val dns = AndroidSystemDns(UnderlyingSnapshot(android.net.Network.fromNetworkHandle(0x1cafed00dL), emptyList(), "unavailable", 7), executor) {
                _, _, callbacks, cancellation, callback ->
            cancellation.setOnCancelListener { cancelling.countDown(); releaseCancel.await() }
            callbacks.execute {
                entered.countDown()
                release.await()
                callback.onAnswer(byteArrayOf(9), 0)
            }
        }
        try {
            val result = java.util.concurrent.CompletableFuture.supplyAsync { json(dns.raw(1, byteArrayOf(1))) }
            assertTrue(entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
            val cancel = java.util.concurrent.CompletableFuture.supplyAsync { dns.cancel(1) }
            assertTrue(cancelling.await(5, java.util.concurrent.TimeUnit.SECONDS))
            assertFalse(dns.idle)
            releaseCancel.countDown()
            cancel.get(5, java.util.concurrent.TimeUnit.SECONDS)
            val value = result.get(5, java.util.concurrent.TimeUnit.SECONDS)
            assertTrue(value.getBoolean("cancelled")); assertTrue(value.isNull("wire"))
            assertFalse("An executing callback has not returned", dns.idle)
            release.countDown()
            dns.awaitIdle(SystemClock.elapsedRealtime() + 5000)
            assertTrue(dns.idle)
            assertTrue("A late answer cannot change the settled cancellation", value.isNull("wire"))
        } finally { releaseCancel.countDown(); release.countDown(); executor.shutdownNow() }
    }

    @Test fun cancellationBeforeSubmissionNeverCallsThePlatform() {
        val dns = AndroidSystemDns(UnderlyingSnapshot(android.net.Network.fromNetworkHandle(0x1cafed00dL), emptyList(), "unavailable", 7), Executor { it.run() }) {
                _, _, _, _, _ -> throw AssertionError("Cancelled query reached the platform")
        }
        dns.cancel(1)
        assertTrue(json(dns.raw(1, byteArrayOf(1))).getBoolean("cancelled"))
        assertTrue(dns.idle)
    }

    @Test fun closeRejectsNewPlatformQueriesAndPreservesActualIdle() {
        val f = Fixture()
        val closed = json(f.dns.close())
        assertTrue(closed.isNull("error")); assertTrue(closed.getBoolean("exited"))
        f.dns.awaitIdle(SystemClock.elapsedRealtime())
        val raw = f.raw(1)
        assertEquals(Contract.CORE_ERROR_CANCELLED, raw.getJSONObject("error").getString("code"))
        assertTrue(raw.getBoolean("cancelled")); assertTrue(raw.getBoolean("exited"))
        val lookup = json(f.dns.lookup(2, "fixture.test", 6))
        assertEquals(Contract.CORE_ERROR_CANCELLED, lookup.getJSONObject("error").getString("code"))
        assertTrue(lookup.getBoolean("cancelled")); assertTrue(lookup.getBoolean("exited")); f.assertIdle()
    }
}
