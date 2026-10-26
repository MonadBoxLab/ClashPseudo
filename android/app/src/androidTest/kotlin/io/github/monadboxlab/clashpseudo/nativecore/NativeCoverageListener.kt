package io.github.monadboxlab.clashpseudo.nativecore

import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.debug.NativeCoverage
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import org.json.JSONObject
import org.junit.runner.Result
import org.junit.runner.notification.RunListener
import java.io.File

/** AndroidJUnitRunner listener enabled explicitly for coverage runs. */
class NativeCoverageListener : RunListener() {
    override fun testRunFinished(result: Result) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val name = InstrumentationRegistry.getArguments().getString("nativeCoverageName")
        require(name != null && Regex("validation-native-[a-zA-Z0-9-]+\\.profraw").matches(name))
        check(PseudoVpnService.session.snapshot().phase == NativeSession.Phase.STOPPED)
        val core = JSONObject(NativeCore.snapshot())
        check(!core.getBoolean("prepared") && !core.getBoolean("attached"))
        for (first in listOf(false, true)) {
            for (second in listOf(false, true)) {
                check(NativeCoverage.probe(first, second) == if (first && second) 1 else 0)
            }
        }
        val output = File(context.filesDir, name)
        check(!output.exists())
        check(NativeCoverage.write(output.absolutePath) == 0)
        check(output.isFile && output.length() > 0)
    }
}
