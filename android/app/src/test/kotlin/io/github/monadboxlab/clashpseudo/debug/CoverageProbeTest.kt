package io.github.monadboxlab.clashpseudo.debug

import org.junit.Assert.assertEquals
import org.junit.Test

class CoverageProbeTest {
    @Test fun actualDecisionPathsAndOneOfTwoSameLineMethods() {
        assertEquals(0, CoverageProbe.decision(false, false))
        assertEquals(0, CoverageProbe.decision(false, true))
        assertEquals(0, CoverageProbe.decision(true, false))
        assertEquals(1, CoverageProbe.decision(true, true))
    }
}
