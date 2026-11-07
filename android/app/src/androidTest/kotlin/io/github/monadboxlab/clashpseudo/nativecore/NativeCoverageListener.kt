package io.github.monadboxlab.clashpseudo.nativecore

import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.debug.CoreFixtureContract as Fixture
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.runner.Result
import org.junit.runner.notification.RunListener
import java.io.File

/** Explicitly enabled AndroidJUnitRunner listener; each native process saves its own profile. */
class NativeCoverageListener : RunListener() {
    override fun testRunFinished(result: Result) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val name = InstrumentationRegistry.getArguments().getString("nativeCoverageName")
        require(name != null && Regex("validation-native-[a-zA-Z0-9-]+\\.profraw").matches(name))
        assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
        CoreIpcTestDriver.assertNoGoInApplication()
        val output = File(context.filesDir, name)
        assertFalse("Probe profile must be a new file", output.exists())
        CoreIpcTestDriver.fixture().use { driver ->
            val reply = driver.fixture(Fixture.COVERAGE, JSONObject().put("name", name)).await()
            assertTrue(reply.terminal.toString(), reply.terminal.getBoolean("complete"))
            val coverage = reply.value.getJSONObject("coverage")
            val values = coverage.getJSONArray("probe")
            assertEquals(4, values.length())
            // In coverage_probe.c, validation_coverage_probe(first, second) reaches same_line_a only for true/true.
            for ((index, expected) in listOf(0, 0, 0, 1).withIndex()) assertEquals(expected, values.getInt(index))
            CoreIpcTestDriver.assertCoverage(coverage)
            assertEquals(output.absolutePath, coverage.getString("path"))
            driver.exit()
            assertTrue(driver.deathConfirmed)
            CoreIpcTestDriver.removeFixtureHome(context, reply.value)
        }
        CoreIpcTestDriver.assertNoGoInApplication()
    }
}
