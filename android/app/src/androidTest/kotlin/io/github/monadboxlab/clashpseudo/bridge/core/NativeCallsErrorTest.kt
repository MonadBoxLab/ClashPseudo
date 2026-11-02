package io.github.monadboxlab.clashpseudo.bridge.core

import android.os.SystemClock
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.success
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CorePlatformTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CoreResourceGate
import io.github.monadboxlab.clashpseudo.nativecore.input.CoreInput
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class NativeCallsErrorTest {
    private fun input() = CoreInput("fixture", 1, null, CoreBridgeIpcScenario.DIRECT.toByteArray(Charsets.UTF_8), "{}".toByteArray(), name = "fixture")

    @Test fun previewReleaseWaitsForTheRealProcessExitAndReleasesItsResourceLease() {
        val platform = CorePlatformTestDriver()
        try {
            success(platform.prepare(input(), vpn = false))
            assertNull(CoreResourceGate.forApplication(platform.context).tryAcquire())
            assertTrue(success(platform.query(Contract.CORE_OPERATION_SNAPSHOT)).getBoolean("prepared"))
            platform.exit()
            assertEquals(Contract.CORE_PHASE_EXITED, platform.status()["phase"])
            assertEquals(false, platform.status()["vpnRunning"])
            val released = CoreResourceGate.forApplication(platform.context).tryAcquire()
            assertNotNull("真实退出及本地 I/O 结束后必须释放 lease", released)
            released!!.close()
            CoreIpcTestDriver.assertNoGoInApplication()
        } finally { platform.exit() }
    }

    @Test fun communicationFailureKeepsItsCompleteCauseAndCannotClaimThatTheCoreExited() {
        val platform = CorePlatformTestDriver()
        val original = "https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture"
        val failure = IOException(original, IllegalStateException("original operation cause")).apply {
            addSuppressed(IOException("original cleanup: $original"))
        }
        try {
            success(platform.prepare(input(), vpn = false))
            val before = platform.status()
            CoreIpcTestDriver.injectCommunicationFailure(platform.context, failure)
            val after = platform.status()
            assertEquals(before["processId"], after["processId"])
            assertEquals(Contract.CORE_PHASE_COMMUNICATION_LOST, after["phase"])
            val error = JSONObject(after["error"] as String)
            assertEquals(Contract.CORE_ERROR_COMMUNICATION_LOST, error.getString("code"))
            assertEquals(failure.javaClass.name, error.getString("type"))
            assertEquals(original, error.getString("message"))
            assertEquals(failure.stackTraceToString(), error.getString("stack"))
            assertEquals("original operation cause", error.getJSONObject("cause").getString("message"))
            assertEquals("original cleanup: $original", error.getJSONArray("suppressed").getJSONObject(0).getString("message"))
            assertNull("通信失败不能释放仍在运行进程的 lease", CoreResourceGate.forApplication(platform.context).tryAcquire())
        } finally { platform.exit() }
    }

    @Test fun anOldExitRequestCannotReleaseTheReplacementProcess() {
        val platform = CorePlatformTestDriver()
        platform.keepPreviewVisible().use {
            try {
                success(platform.prepare(input(), vpn = false))
                val old = platform.status()["processId"] as String
                platform.exit()
                success(platform.prepare(input(), vpn = false))
                val current = platform.status()
                assertNotEquals(old, current["processId"])
                val at = SystemClock.elapsedRealtime()
                val rejected = runCatching { platform.channel(Contract.CORE_CHANNEL_EXIT,
                    mapOf("processId" to old, "admittedAt" to at, "deadline" to at + Contract.OPERATION_ORDINARY_TIMEOUT_MS)) }.exceptionOrNull()
                assertTrue(rejected is CorePlatformTestDriver.ChannelFailure)
                val error = JSONObject((rejected as CorePlatformTestDriver.ChannelFailure).details as String)
                assertEquals("退出请求属于旧内核进程", error.getString("message"))
                assertEquals(current["processId"], platform.status()["processId"])
                assertTrue(success(platform.query(Contract.CORE_OPERATION_SNAPSHOT)).getBoolean("prepared"))
                assertNull(CoreResourceGate.forApplication(platform.context).tryAcquire())
            } finally { platform.exit() }
        }
    }

    @Test fun invalidExitBudgetsKeepTheirTypedPlatformFailureWithoutStoppingTheContext() {
        val platform = CorePlatformTestDriver()
        platform.keepPreviewVisible().use {
            try {
                success(platform.prepare(input(), vpn = false))
                val before = platform.status()
                val at = SystemClock.elapsedRealtime()
                for ((admittedAt, deadline) in listOf(-1L to at, at to at - 1, at to at + Contract.OPERATION_BACKUP_TIMEOUT_MS + 1)) {
                    val rejected = runCatching { platform.channel(Contract.CORE_CHANNEL_EXIT,
                        mapOf("processId" to before["processId"], "admittedAt" to admittedAt, "deadline" to deadline)) }.exceptionOrNull()
                    assertTrue(rejected is CorePlatformTestDriver.ChannelFailure)
                    val error = JSONObject((rejected as CorePlatformTestDriver.ChannelFailure).details as String)
                    assertEquals("java.lang.IllegalArgumentException", error.getString("type"))
                    assertTrue(error.getString("stack").contains("CoreClient"))
                    assertEquals(before["processId"], platform.status()["processId"])
                }
                assertTrue(success(platform.query(Contract.CORE_OPERATION_SNAPSHOT)).getBoolean("prepared"))
            } finally { platform.exit() }
        }
    }
}
