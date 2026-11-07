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
