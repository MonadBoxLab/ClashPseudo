package io.github.monadboxlab.clashpseudo.bridge.operation

import android.content.Intent
import android.net.VpnService
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Assume.assumeNotNull
import org.junit.Test

class AuthorizationRecreationTest {
    @Test fun cancellationAfterActivityRecreationSettlesOriginalPermissionRequest() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        // Before running, revoke this application's grant through system VPN settings.
        assumeNotNull(VpnService.prepare(context))
        val original = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        val completed = CountDownLatch(1)
        val reply = AtomicReference<Any?>()
        val result = object : MethodChannel.Result {
            override fun success(value: Any?) { reply.set(value); completed.countDown() }
            override fun error(code: String, message: String?, details: Any?) {
                reply.set(code); completed.countDown()
            }
            override fun notImplemented() { reply.set("missing"); completed.countDown() }
        }
        val monitor = instrumentation.addMonitor(MainActivity::class.java.name, null, false)
        var replacement: MainActivity? = null
        try {
            instrumentation.runOnMainSync {
                AppBridge::class.java.getDeclaredMethod("authorize", MethodChannel.Result::class.java)
                    .apply { isAccessible = true }.invoke(AppBridge, result)
            }
            instrumentation.runOnMainSync { original.recreate() }
            val recreationDeadline = SystemClock.uptimeMillis() + 10000
            while (replacement == null) {
                val remaining = recreationDeadline - SystemClock.uptimeMillis()
                if (remaining <= 0L) break
                val observed = monitor.waitForActivityWithTimeout(remaining)
                if (observed is MainActivity && observed !== original) {
                    replacement = observed
                }
            }
            assertNotNull("Activity did not recreate", replacement)
            assertNotSame(original, replacement)
            assertEquals("Recreation must not cancel permission", 1L, completed.count)
            val deadline = SystemClock.uptimeMillis() + 5000
            var cancelled = false
            while (!cancelled && SystemClock.uptimeMillis() < deadline) {
                val root = instrumentation.uiAutomation.rootInActiveWindow
                val button = root?.findAccessibilityNodeInfosByText("CANCEL")?.firstOrNull()
                cancelled = button?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true
                if (!cancelled) SystemClock.sleep(100)
            }
            assertTrue("System permission cancellation button not found", cancelled)
            assertTrue("Permission reply missing after recreation", completed.await(5, TimeUnit.SECONDS))
            assertEquals(false, reply.get())
            assertNotNull(VpnService.prepare(context))
        } finally {
            instrumentation.removeMonitor(monitor)
            instrumentation.runOnMainSync {
                replacement?.finish()
                if (!original.isDestroyed) original.finish()
            }
        }
    }
}
