package io.github.monadboxlab.clashpseudo.nativecore

import android.app.ActivityManager
import android.os.SystemClock
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

/** Run alone: this scenario observes process death and absence before explicitly reconnecting. */
class CoreClientProcessExitTest {
    @Test fun productionChannelExitDoesNotResurrectCoreBeforeExplicitHandshake() {
        val platform = CorePlatformTestDriver()
        val work = androidx.work.WorkManager.getInstance(platform.context)
        platform.await("Startup task finishes") {
            work.getWorkInfosForUniqueWork("update-reconcile").get(5, TimeUnit.SECONDS)
                .let { it.isNotEmpty() && it.all { item -> item.state.isFinished } } &&
                io.github.monadboxlab.clashpseudo.bridge.AppBridge.operationId == null &&
                !io.github.monadboxlab.clashpseudo.bridge.AppBridge.logic.busy
        }
        val manager = platform.context.getSystemService(ActivityManager::class.java)
        fun corePresent(): Boolean = manager.runningAppProcesses.orEmpty().any {
            it.processName == "${platform.context.packageName}:core"
        }
        CoreIpcTestDriver.production().use { observer ->
            try {
                val original = platform.handshake()["processId"]
                assertEquals(observer.processId, original)
                observer.releaseAutoCreate()
                platform.exit()
                observer.awaitDeath()
                assertEquals(Contract.CORE_PHASE_EXITED, platform.status()["phase"])
                platform.await("Exited core process disappears", 10_000) { !corePresent() }
                val until = SystemClock.elapsedRealtime() + 3000
                do {
                    assertFalse("Core must not restart without an explicit handshake", corePresent())
                    assertFalse("CoreService must not retain an auto-create binding",
                        CoreIpcTestDriver.servicePresent(platform.context, CoreService::class.java))
                    assertEquals(original, platform.status()["processId"])
                    Thread.sleep(25)
                } while (SystemClock.elapsedRealtime() < until)
                val replacement = platform.handshake()["processId"]
                assertNotNull(replacement)
                assertNotEquals(original, replacement)
                assertTrue("Explicit handshake must start a new core process", corePresent())
            } finally {
                platform.exit()
            }
        }
        CoreIpcTestDriver.assertNoGoInApplication()
    }
}
