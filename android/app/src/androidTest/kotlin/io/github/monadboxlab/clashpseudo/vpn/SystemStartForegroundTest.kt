package io.github.monadboxlab.clashpseudo.vpn

import android.app.ActivityManager
import android.app.NotificationManager
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.app.AppStrings
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

class SystemStartForegroundTest {
    /** Exercises a bound foreground Service with an isolated UNKNOWN state machine. */
    @Test fun unknownProjectionReleasesOwnedForegroundWithoutConfirmingNativeStop() =
        checkUnknownForeground(freshRequest = false)

    @Test fun freshSystemStartInUnknownRetiresOwnedForegroundWithoutPreparing() =
        checkUnknownForeground(freshRequest = true)

    private fun checkUnknownForeground(freshRequest: Boolean) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        fun <T> main(block: () -> T): T {
            val task = FutureTask(block)
            instrumentation.runOnMainSync(task)
            return task.get()
        }
        fun await(label: String, ready: () -> Boolean) {
            val end = SystemClock.elapsedRealtime() + 10_000
            while (!main(ready)) {
                check(SystemClock.elapsedRealtime() < end) { "Timed out waiting for $label" }
                Thread.sleep(50)
            }
        }
        val before = main {
            assertNull("An existing service is not owned by this test", PseudoVpnService.instance)
            assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
            assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
            assertNull("Use the existing app grant; never open authorization", VpnService.prepare(context))
            PseudoVpnService.session.snapshot()
        }
        val notification = context.getSystemService(NotificationManager::class.java)
        assertTrue(notification.activeNotifications.none { it.id == 1 })
        val nativeBefore = NativeCore.snapshot()
        assertFalse(JSONObject(nativeBefore).getBoolean("prepared"))
        assertFalse(JSONObject(nativeBefore).getBoolean("attached"))
        val connected = CountDownLatch(1)
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) { connected.countDown() }
            override fun onServiceDisconnected(name: ComponentName) {}
        }
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        var bound = false
        var owned: PseudoVpnService? = null
        var notificationWasVisible = false
        try {
            await("idle UI startup") { AppBridge.operationId == null && !AppBridge.logic.busy }
            bound = main {
                context.bindService(Intent(context, PseudoVpnService::class.java)
                    .setAction(VpnService.SERVICE_INTERFACE), connection, Context.BIND_AUTO_CREATE)
            }
            assertTrue(bound)
            assertTrue("Real Service binding did not complete", connected.await(10, TimeUnit.SECONDS))
            val service = main { checkNotNull(PseudoVpnService.instance) }
            owned = service
            val isolated = NativeSession()
            val generation = checkNotNull(isolated.begin())
            assertTrue(isolated.stopping(generation))
            val requests = main {
                PseudoVpnService::class.java.getDeclaredField("systemStarts")
                    .apply { isAccessible = true }.get(service) as SystemStartRequest
            }
            val owner = if (freshRequest) null else checkNotNull(requests.begin(1, NativeSession.Phase.STOPPING))
            val unconfirmed = AppStrings.message(R.string.error_native_release_unconfirmed)
            isolated.finished(generation, unconfirmed)
            assertEquals(NativeSession.Phase.UNKNOWN, isolated.snapshot().phase)
            main {
                PseudoVpnService::class.java.getDeclaredMethod("showNotification",
                    Int::class.javaPrimitiveType, Boolean::class.javaPrimitiveType)
                    .apply { isAccessible = true }.invoke(service, R.string.notify_restoring, false)
            }
            @Suppress("DEPRECATION")
            fun foreground(): Boolean = context.getSystemService(ActivityManager::class.java)
                .getRunningServices(100).any {
                    it.service == ComponentName(context, PseudoVpnService::class.java) && it.foreground
                }
            await("actual SDK foreground state", ::foreground)
            notificationWasVisible = notification.activeNotifications.any { it.id == 1 }
            main {
                if (freshRequest) {
                    assertFalse(requests.pending())
                    service.systemStart(1, isolated)
                } else {
                    PseudoVpnService::class.java.getDeclaredMethod("finishSystemStart", Any::class.java,
                        Long::class.javaPrimitiveType, NativeSession::class.java)
                        .apply { isAccessible = true }.invoke(service, owner, generation, isolated)
                }
            }
            await("foreground resource removal") { !foreground() }
            await("owned notification removal") { notification.activeNotifications.none { it.id == 1 } }
            assertFalse(requests.pending())
            val after = isolated.snapshot()
            assertEquals(NativeSession.Phase.UNKNOWN, after.phase)
            assertEquals(generation, after.generation)
            assertEquals(unconfirmed, after.error)
            assertEquals(nativeBefore, NativeCore.snapshot())
            Log.i("UnknownForegroundCheck", "api=${Build.VERSION.SDK_INT} freshRequest=$freshRequest realForeground=true " +
                "startedServiceRetirementNotProven=true " +
                "notificationWasVisible=$notificationWasVisible foregroundRemoved=true " +
                "isolatedPhase=${after.phase} mainSessionUntouched=true nativePrepared=false nativeAttached=false")
        } finally {
            main {
                // Cleanup applies only to the SDK Service created by this test.
                owned?.takeIf { PseudoVpnService.instance === it }
                    ?.stopForeground(Service.STOP_FOREGROUND_REMOVE)
                if (bound) context.unbindService(connection)
                activity.finish()
            }
            await("test-owned Service destruction") { PseudoVpnService.instance == null }
            val now = main { PseudoVpnService.session.snapshot() }
            assertEquals(before.phase, now.phase)
            assertEquals(before.generation, now.generation)
            assertEquals(before.error, now.error)
            assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
            assertEquals(nativeBefore, NativeCore.snapshot())
        }
    }
}
