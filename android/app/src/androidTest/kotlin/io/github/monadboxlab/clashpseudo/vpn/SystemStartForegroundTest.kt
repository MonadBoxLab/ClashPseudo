package io.github.monadboxlab.clashpseudo.vpn

import android.app.ActivityManager
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Intent
import android.net.VpnService
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.debug.CoreFixtureContract
import io.github.monadboxlab.clashpseudo.nativecore.CoreClient
import io.github.monadboxlab.clashpseudo.nativecore.CoreErrors
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CorePlatformTestDriver
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class SystemStartForegroundTest {
    @Test fun unknownProjectionReleasesOwnedForegroundWithoutConfirmingNativeStop() =
        checkUnknownForeground(freshRequest = false)

    @Test fun freshSystemStartInUnknownRetiresOwnedForegroundWithoutPreparing() =
        checkUnknownForeground(freshRequest = true)

    private fun checkUnknownForeground(freshRequest: Boolean) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val platform = CorePlatformTestDriver(context)
        CoreIpcTestDriver.assertNoGoInApplication()
        assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
        assertFalse(CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java))
        assertNull("使用现有 VPN 授权，不打开授权界面", VpnService.prepare(context))
        val notification = context.getSystemService(NotificationManager::class.java)
        assertTrue(notification.activeNotifications.none { it.id == 1 })
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        try {
            platform.await("UI 启动后的 writer 结束") { AppBridge.operationId == null && !AppBridge.logic.busy }
            CoreIpcTestDriver.fixture().use { observer ->
                platform.handshake()
                val original = IOException("内核资源释放未确认\nAuthorization: Bearer fixture")
                CoreIpcTestDriver.bindVpnResource(context).use {
                    observer.debug.serviceControl(CoreFixtureContract.SHOW_FOREGROUND)
                    @Suppress("DEPRECATION")
                    fun foreground(): Boolean = context.getSystemService(ActivityManager::class.java)
                        .getRunningServices(100).any {
                            it.service == ComponentName(context, PseudoVpnService::class.java) && it.foreground
                        }
                    platform.await("实际 SDK foreground 状态", ready = ::foreground)
                    CoreIpcTestDriver.injectCommunicationFailure(context, original)
                    platform.await("通信中断的 UNKNOWN 状态") {
                        PseudoVpnService.session.snapshot().phase == NativeSession.Phase.UNKNOWN
                    }
                    val unknown = PseudoVpnService.session.snapshot()
                    val status = platform.status()
                    assertEquals(observer.processId, status["processId"])
                    assertEquals(Contract.CORE_PHASE_COMMUNICATION_LOST, status["phase"])
                    assertEquals(CoreErrors.json(original, Contract.CORE_ERROR_COMMUNICATION_LOST).toString(), status["error"])
                    assertFalse(observer.deathConfirmed)
                    assertTrue(observer.binder.isBinderAlive)
                    if (freshRequest) {
                        CoreIpcTestDriver.onMain {
                            context.startService(Intent(context, PseudoVpnService::class.java).setAction(VpnService.SERVICE_INTERFACE))
                        }
                    } else {
                        observer.debug.serviceControl(CoreFixtureContract.CLOSE_RESOURCES)
                    }
                    platform.await("foreground 资源移除") { !foreground() }
                    platform.await("本次通知移除") { notification.activeNotifications.none { it.id == 1 } }
                    platform.await("系统启动请求结束") { !AppBridge.pendingSystemRestore }
                    val after = PseudoVpnService.session.snapshot()
                    assertEquals(NativeSession.Phase.UNKNOWN, after.phase)
                    assertEquals(unknown.generation, after.generation)
                    assertEquals(unknown.error, after.error)
                    assertEquals(status["error"], platform.status()["error"])
                    assertFalse(observer.debug.serviceControl(CoreFixtureContract.SERVICE_STATE).getBoolean("nativeLoaded"))
                    assertFalse("foreground 移除不是 process death", observer.deathConfirmed)
                    assertTrue(observer.binder.isBinderAlive)
                    CoreIpcTestDriver.assertNoGoInApplication()
                }
                observer.exit()
                platform.await("DeathRecipient 确认后的 STOPPED 状态") {
                    PseudoVpnService.session.snapshot().phase == NativeSession.Phase.STOPPED &&
                        CoreClient.get(context).status()["phase"] == Contract.CORE_PHASE_EXITED
                }
                platform.await("本次 Service 销毁") {
                    !CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java)
                }
            }
        } finally {
            CoreIpcTestDriver.onMain { activity.finish() }
        }
    }
}
