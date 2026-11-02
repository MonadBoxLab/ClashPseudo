package io.github.monadboxlab.clashpseudo.nativecore

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class CoreRequestIdsTest {
    @Test fun startsAtOneAndNeverReusesAnId() {
        val ids = CoreRequestIds()
        assertEquals(1L, ids.next())
        assertEquals(2L, ids.next())
        assertEquals(3L, ids.next())
    }

    @Test fun concurrentAdmissionsShareOneSequenceWithoutCollisions() {
        val ids = CoreRequestIds()
        val observed = ConcurrentHashMap.newKeySet<Long>()
        val workers = Executors.newFixedThreadPool(8)
        try {
            val work = (0 until 8).map { workers.submit { repeat(1000) { assertTrue(observed.add(ids.next())) } } }
            work.forEach { it.get(10, TimeUnit.SECONDS) }
            assertEquals((1L..8000L).toSet(), observed)
        } finally { workers.shutdownNow() }
    }

    @Test fun overflowRejectsEveryLaterAdmissionWithoutWrapping() {
        val ids = CoreRequestIds(Long.MAX_VALUE - 1)
        assertEquals(Long.MAX_VALUE, ids.next())
        repeat(2) {
            try { ids.next(); fail("耗尽的 requestId allocator 必须拒绝受理") }
            catch (expected: IllegalStateException) { assertTrue(expected.message!!.contains("requestId")) }
        }
    }
}
