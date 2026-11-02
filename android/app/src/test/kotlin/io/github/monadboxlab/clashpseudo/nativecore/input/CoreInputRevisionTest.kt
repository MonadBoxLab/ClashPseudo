package io.github.monadboxlab.clashpseudo.nativecore.input

import org.junit.Assert.*
import org.junit.Test

/** Exercises the production numeric identity boundary. */
class CoreInputRevisionTest {
    @Test fun currentIntProtocolAcceptsOnlyLosslessPositiveIntegers() {
        for (value in listOf<Any>(1, 2, Int.MAX_VALUE, 1L, 2L, Int.MAX_VALUE.toLong())) {
            assertEquals((value as Number).toInt(), CoreInput.integerRevision(value))
        }
    }

    @Test fun fractionalWrappedStringAndNonPositiveValuesCannotAliasAnIdentity() {
        val invalid = listOf(null, 1.0, 1.5, 2.5, 1f, Double.NaN, Double.POSITIVE_INFINITY,
            0, -1, Int.MIN_VALUE, 0L, -1L, Int.MAX_VALUE.toLong() + 1,
            4294967297L, Long.MAX_VALUE, Long.MIN_VALUE, "1", true, emptyList<Any>())
        for (value in invalid) {
            try {
                CoreInput.integerRevision(value)
                fail("Malformed or out-of-range revision was accepted: $value")
            } catch (error: IllegalStateException) {
                assertEquals("Invalid revision", error.message)
            }
        }
    }
}
