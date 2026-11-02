package io.github.monadboxlab.clashpseudo.vpn

import android.app.ActivityOptions
import android.app.KeyguardManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Process
import android.os.SystemClock
import android.util.Log
import android.widget.ImageButton
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleCallback
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.app.VpnWidgetProvider
import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.controls.SystemControls
import io.github.monadboxlab.clashpseudo.debug.CoreFixtureContract
import io.github.monadboxlab.clashpseudo.logic.LogicEngineHost
import io.github.monadboxlab.clashpseudo.nativecore.CoreClient
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CorePlatformTestDriver
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class SystemStartLifecycleTest {
    @Test fun controlledHeadlessServiceInterfaceStartsAndStopsWithoutChangingStores() =
        checkControlledHeadlessService(retiredCallbacks = false)

    @Test fun retiredLiveServiceCallbacksCannotStopTheReplacementSession() =
        checkControlledHeadlessService(retiredCallbacks = true)

    @Test fun revokeInInternalReconnectStoppedGapCancelsThePendingSystemStart() =
        checkControlledHeadlessService(retiredCallbacks = false, revokeStoppedGap = true)

    private fun checkControlledHeadlessService(retiredCallbacks: Boolean, revokeStoppedGap: Boolean = false) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val platform = CorePlatformTestDriver(context)
        val arguments = InstrumentationRegistry.getArguments()
        fun required(name: String) = checkNotNull(arguments.getString(name)) { "缺少 $name" }
        val expectedId = required("expectedConfigId").also { check(it.isNotBlank()) }
        val expectedName = required("expectedConfigName").also { check(it.isNotBlank()) }
        val expectedRevision = required("expectedRevision").toInt().also { check(it > 0) }
        val expectedBody = required("expectedBodySha256").also { check(Regex("[0-9a-f]{64}").matches(it)) }
        val expectedStores = expectedStores()
        check(expectedStores.getValue(BackupFiles.Kind.CONFIGURATIONS) != "absent")
        check(Build.VERSION.SDK_INT in 36..37) { "该受控场景要求 API 36 或 37" }
        val files = BackupFiles.get(context)
        val stores = File(context.filesDir.canonicalFile, "configurations")
        platform.await("业务存储恢复") { files.transaction.snapshot().let { it.ready && !it.restoring } }
        val epoch = files.transaction.snapshot().epoch
        fun unchanged() = assertStoresUnchanged(files, stores, epoch, expectedStores)
        unchanged()
        CoreIpcTestDriver.onMain {
            for (stage in Stage.values().filter { it != Stage.DESTROYED }) {
                assertTrue("headless 启动前不能已有 UI", ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(stage).isEmpty())
            }
            val state = PseudoVpnService.session.snapshot()
            assertEquals(NativeSession.Phase.STOPPED, state.phase)
            assertEquals("使用保留数据的新应用进程单独运行", 0L, state.generation)
            assertFalse(CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java))
            assertNull("使用已有 VPN 授权，不打开授权界面", VpnService.prepare(context))
        }
        CoreIpcTestDriver.assertNoGoInApplication()
        var observer: CoreIpcTestDriver? = null
        var replacement: CoreIpcTestDriver? = null
        var failure: Throwable? = null
        fun start() {
            val intent = Intent(context, PseudoVpnService::class.java).setAction(VpnService.SERVICE_INTERFACE)
            assertNotNull(if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent))
        }
        fun inspect(): Pair<Map<String, Any?>, org.json.JSONObject> {
            val transitions = mutableListOf<String>()
            var previous: String? = null
            try {
                platform.await("真实 VPN RUNNING") {
                    val state = PseudoVpnService.session.snapshot()
                    val runtime = AppBridge.runtimeState()
                    val facts = "phase=${state.phase}, generation=${state.generation}, error=${state.error}, " +
                        "owner=${AppBridge.operationId}, command=${AppBridge.command}, " +
                        "pending=${AppBridge.pendingSystemRestore}, busy=${AppBridge.logic.busy}, " +
                        "runtime=${runtime.filterKeys { it in setOf("writerBusy", "storageReady", "storageRestoring", "resultId", "resultMessage") }}, " +
                        "core=${CoreClient.get(context).status()}"
                    if (facts != previous) {
                        previous = facts
                        transitions.add("${android.os.SystemClock.elapsedRealtime()}: $facts")
                        if (transitions.size > 32) transitions.removeAt(0)
                    }
                    assertNotEquals(NativeSession.Phase.UNKNOWN, state.phase)
                    state.phase == NativeSession.Phase.RUNNING && !AppBridge.pendingSystemRestore &&
                        AppBridge.operationId == null && !AppBridge.logic.busy
                }
            } catch (error: Throwable) {
                throw AssertionError(transitions.joinToString("\n"), error)
            }
            val loaded = platform.status()
            assertEquals(Contract.CORE_PHASE_READY, loaded["phase"])
            assertEquals(Contract.CORE_PURPOSE_RUNNING, loaded["purpose"])
            assertEquals(1L, (loaded["generation"] as Number).toLong())
            assertEquals(expectedId, loaded["configId"])
            assertEquals(expectedRevision, (loaded["revision"] as Number).toInt())
            assertEquals(true, loaded["vpnRunning"])
            val input = platform.runRecord(loaded)
            assertEquals(expectedId, input.getString("id"))
            assertEquals(expectedName, input.getString("name"))
            assertEquals(expectedRevision, input.getInt("revision"))
            assertEquals(0, input.getJSONArray("overrides").length())
            assertEquals(loaded["composition"], input.getString("composition"))
            assertEquals(expectedBody, MessageDigest.getInstance("SHA-256").digest(input.getString("body").toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) })
            val native = platform.query(Contract.CORE_OPERATION_SNAPSHOT)
            assertTrue(native.terminal.getBoolean("complete"))
            assertTrue(native.value.getBoolean("prepared"))
            assertTrue(native.value.getBoolean("attached"))
            assertFalse(native.value.getBoolean("cleanupFailed"))
            val spec = platform.query(Contract.CORE_OPERATION_VPN_SPEC)
            assertTrue(spec.terminal.getBoolean("complete"))
            assertEquals(loaded["composition"], spec.value.getString("composition"))
            assertEquals((loaded["generation"] as Number).toLong(), spec.value.getLong("generation"))
            assertTrue(CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java))
            CoreIpcTestDriver.assertNoGoInApplication()
            unchanged()
            return loaded to input
        }
        try {
            start()
            val first = inspect()
            observer = CoreIpcTestDriver.fixture()
            assertEquals(first.first["processId"], observer.processId)
            if (retiredCallbacks || revokeStoppedGap) {
                val retired = observer
                assertEquals(SystemControls.Admission.ACCEPTED, platform.stopFromSystemControl())
                retired.awaitDeath()
                platform.await("旧 process death 后 writer 结束") {
                    PseudoVpnService.session.snapshot().phase == NativeSession.Phase.STOPPED &&
                        !AppBridge.logic.busy && AppBridge.operationId == null
                }
                if (revokeStoppedGap) {
                    RuntimeDispatchGate(platform).use { gate ->
                        replacement = CoreIpcTestDriver.fixture()
                        start()
                        platform.await("新 systemStart 等待 AppRuntime 调度") { AppBridge.pendingSystemRestore && AppBridge.logic.busy }
                        val owner = CoreIpcTestDriver.onMain { checkNotNull(AppBridge.operationId) }
                        assertFalse(replacement!!.debug.serviceControl(CoreFixtureContract.SERVICE_STATE).getBoolean("nativeLoaded"))
                        assertTrue(gate.held)
                        replacement!!.debug.serviceControl(CoreFixtureContract.REVOKE_SERVICE)
                        platform.await("revoke 撤销停止间隙中的新 owner") {
                            !AppBridge.pendingSystemRestore && AppBridge.operationId != owner
                        }
                        replacement!!.awaitDeath()
                        assertTrue(replacement!!.deathConfirmed)
                        assertTrue(gate.held)
                        gate.release()
                        platform.await("撤销后无 late start") {
                            !AppBridge.logic.busy && AppBridge.operationId == null &&
                                PseudoVpnService.session.snapshot().phase == NativeSession.Phase.STOPPED
                        }
                        assertTrue("释放 AppRuntime 调度不能复活旧 process", replacement!!.deathConfirmed)
                    }
                } else {
                    start()
                    val second = inspect()
                    replacement = CoreIpcTestDriver.fixture()
                    assertNotEquals(retired.processId, replacement!!.processId)
                    assertEquals(first.second.getString("body"), second.second.getString("body"))
                    try {
                        retired.debug.serviceControl(CoreFixtureContract.REPLAY_RETIRED_SERVICE)
                        fail("旧 process 的 Binder 不能执行 callback")
                    } catch (error: android.os.DeadObjectException) {
                        assertTrue(retired.deathConfirmed)
                    }
                    val after = inspect()
                    assertEquals(second.first["processId"], after.first["processId"])
                    assertEquals(second.first["inputId"], after.first["inputId"])
                    assertEquals(second.second.toString(), after.second.toString())
                }
            }
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            var cleanup: Throwable? = null
            try {
                if (PseudoVpnService.session.snapshot().phase != NativeSession.Phase.STOPPED || AppBridge.pendingSystemRestore) {
                    assertEquals(SystemControls.Admission.ACCEPTED, platform.stopFromSystemControl())
                }
                replacement?.let { if (!it.deathConfirmed) it.awaitDeath() }
                observer?.let { if (!it.deathConfirmed) it.awaitDeath() }
                platform.await("正常 Stop 与实际 writer 结束") {
                    PseudoVpnService.session.snapshot().phase == NativeSession.Phase.STOPPED &&
                        !CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java) &&
                        !AppBridge.pendingSystemRestore && !AppBridge.logic.busy && AppBridge.operationId == null &&
                        CoreClient.get(context).status()[Contract.CORE_FIELD_PHASE] == Contract.CORE_PHASE_EXITED
                }
                assertFalse("正常停止不能留下恢复门禁", CoreClient.get(context).lifecycle.snapshot().recoveryRequired)
                CoreIpcTestDriver.assertNoGoInApplication()
            } catch (error: Throwable) { cleanup = error }
            for (remote in listOfNotNull(replacement, observer)) try { remote.close() } catch (error: Throwable) {
                if (cleanup == null) cleanup = error else if (cleanup !== error) cleanup.addSuppressed(error)
            }
            try { unchanged() } catch (error: Throwable) {
                if (cleanup == null) cleanup = error else if (cleanup !== error) cleanup.addSuppressed(error)
            }
            if (cleanup != null) {
                if (failure == null) throw cleanup else if (failure !== cleanup) failure.addSuppressed(cleanup)
            }
        }
    }

    private class RuntimeDispatchGate(private val platform: CorePlatformTestDriver) : Closeable {
        private val logic = AppBridge.logic
        private val ready = LogicEngineHost::class.java.getDeclaredField("ready").apply { isAccessible = true }
        private val serial = LogicEngineHost::class.java.getDeclaredField("serial").apply { isAccessible = true }
        var held = true
            private set
        init {
            CoreIpcTestDriver.onMain {
                logic.retainPlatform(true)
                LogicEngineHost::class.java.getDeclaredMethod("ensureEngine").apply { isAccessible = true }.invoke(logic)
            }
            platform.await("AppRuntime 已就绪且 writer 空闲") { ready.getBoolean(logic) && !logic.busy && AppBridge.operationId == null }
            CoreIpcTestDriver.onMain { ready.setBoolean(logic, false) }
        }
        fun release() {
            if (!held) return
            CoreIpcTestDriver.onMain { held = false; logic.ready(serial.getLong(logic)) }
        }
        override fun close() {
            release()
            CoreIpcTestDriver.onMain { logic.retainPlatform(false) }
        }
    }

    @Test fun duplicateServiceInterfaceWhileStartingCannotPrepareOrStartAfterStop() =
        checkPreparationCancellation(revoke = false, controlsEntry = "serviceInterface")
    @Test fun stopShortcutPendingIntentCancelsRealPreparationThroughActivity() =
        checkPreparationCancellation(revoke = false, controlsEntry = "shortcut")
    @Test fun sdkRemoteViewsStopButtonCancelsRealPreparationThroughWidgetBroadcast() =
        checkPreparationCancellation(revoke = false, controlsEntry = "widgetSdk")
    @Test fun realNotificationStopCancelsPreparationThroughPrivateBroadcastAdmission() =
        checkPreparationCancellation(revoke = false, controlsEntry = "notification")
    @Test fun lockedNotificationStopCancelsPreparationWithoutStartUnlockAuthority() =
        checkPreparationCancellation(revoke = false, controlsEntry = "notificationLocked")
    @Test fun lockedWidgetStopCancelsPreparationWithoutStartUnlockAuthority() =
        checkPreparationCancellation(revoke = false, controlsEntry = "widgetLocked")
    @Test fun actualQuickSettingsTileCancelsRealPreparationBeforeWorkerRelease() =
        checkPreparationCancellation(revoke = false, controlsEntry = "tile")
    @Test fun originalLauncherWidgetCancelsRealPreparationBeforeWorkerRelease() =
        checkPreparationCancellation(revoke = false, controlsEntry = "launcherWidget")
    @Test fun stopBeforeNativePreparationRetiresTheRealService() = checkPreparationCancellation(revoke = false)
    @Test fun revokeCallbackBeforeNativePreparationRetiresTheRealService() = checkPreparationCancellation(revoke = true)
    @Test fun systemRevokeBeforeNativePreparationRetiresTheRealService() = checkPreparationCancellation(revoke = true, systemRevoke = true)

    private fun checkPreparationCancellation(revoke: Boolean, systemRevoke: Boolean = false, controlsEntry: String? = null) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val platform = CorePlatformTestDriver(context)
        val arguments = InstrumentationRegistry.getArguments()
        val controlledEntry = controlsEntry != null && controlsEntry != "staleIntents"
        val notificationStop = controlsEntry in setOf("notification", "notificationLocked")
        val currentControls = notificationStop || controlsEntry == "widgetLocked"
        val lockedStop = controlsEntry in setOf("notificationLocked", "widgetLocked")
        val controlsNonce = if (currentControls) "w3a-private-stop-admission" else "p5-controls-preparation-r7x1"
        if (controlledEntry) {
            if (currentControls) check(Build.VERSION.SDK_INT >= 24)
            else check(Build.VERSION.SDK_INT == if (controlsEntry == "launcherWidget") 36 else 37)
            check(arguments.getString("controlsPreparationNonce") == controlsNonce)
        }
        val hashes = if (controlledEntry) expectedStores() else null
        val epoch = if (controlledEntry) checkNotNull(arguments.getString("expectedStorageEpoch")?.toLongOrNull()?.takeIf { it >= 0 }) else null
        if (systemRevoke) {
            check(Build.VERSION.SDK_INT == 37)
            check(arguments.getString("systemRevokeNonce") == "p5-system-revoke-r7u8")
        }
        fun <T> main(block: () -> T): T = CoreIpcTestDriver.onMain(block)
        fun await(label: String, timeoutMs: Long = 15_000, ready: () -> Boolean) = platform.await(label, timeoutMs, ready)
        await("业务 writer 空闲") { !AppBridge.logic.busy && AppBridge.operationId == null }
        val files = BackupFiles.get(context)
        val stores = File(context.filesDir.canonicalFile, "configurations")
        if (hashes != null && epoch != null) assertStoresUnchanged(files, stores, epoch, hashes)
        val before = main {
            if (controlledEntry) {
                assertFalse("controls 取消场景不能启用 Always-on", PseudoVpnService.alwaysOnState() == true)
                assertEquals("保留本场景的 keyguard 前提", lockedStop, context.getSystemService(KeyguardManager::class.java).isKeyguardLocked)
                assertFalse(AppBridge.pendingSystemRestore)
                for (stage in Stage.values().filter { it != Stage.DESTROYED }) {
                    assertTrue("每个 controls 场景开始前不能已有 MainActivity",
                        ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(stage).none { it is MainActivity })
                }
            }
            assertFalse(CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java))
            assertNull("保留已有授权，不打开授权界面", VpnService.prepare(context))
            PseudoVpnService.session.snapshot().also { assertEquals(NativeSession.Phase.STOPPED, it.phase) }
        }
        var controlsActivity: MainActivity? = null
        var activityComponent: String? = null
        var activityResumed = false
        var observingActivity = false
        var shortcut: PendingIntent? = null
        var tileUi: android.app.UiAutomation? = null
        val lifecycle = ActivityLifecycleCallback { activity, stage ->
            if (activity is MainActivity) {
                if (stage == Stage.CREATED) { controlsActivity = activity; activityComponent = activity.intent.component?.className }
                if (stage == Stage.RESUMED) activityResumed = true
            }
        }
        val id = before.generation
        RuntimeDispatchGate(platform).use { gate ->
            CoreIpcTestDriver.fixture().use { observer ->
                try {
                    if (controlsEntry in setOf("shortcut", "widgetSdk", "tile", "launcherWidget", "notification", "notificationLocked", "widgetLocked")) main {
                        ActivityLifecycleMonitorRegistry.getInstance().addLifecycleCallback(lifecycle)
                        observingActivity = true
                    }
                    val start = Intent(context, PseudoVpnService::class.java).setAction(VpnService.SERVICE_INTERFACE)
                    assertNotNull(if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(start) else context.startService(start))
                    await("真实 systemStart 等待 AppRuntime 调度") {
                        AppBridge.pendingSystemRestore && AppBridge.logic.busy && AppBridge.operationId != null &&
                            CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java)
                    }
                    val owner = main { checkNotNull(AppBridge.operationId) }
                    val command = main { checkNotNull(AppBridge.command) }
                    assertEquals("systemStart", command["action"])
                    assertFalse(observer.debug.serviceControl(CoreFixtureContract.SERVICE_STATE).getBoolean("nativeLoaded"))
                    assertTrue(gate.held)
                    when (controlsEntry) {
                        "serviceInterface", "staleIntents" -> {
                            if (controlsEntry == "staleIntents") observer.debug.serviceControl(CoreFixtureContract.STALE_SERVICE_INTENTS)
                            repeat(2) { assertNotNull(context.startForegroundService(start)) }
                            instrumentation.waitForIdleSync()
                            assertEquals(owner, main { AppBridge.operationId })
                            assertEquals(command, main { AppBridge.command })
                            assertTrue(main { AppBridge.pendingSystemRestore })
                            assertFalse(observer.debug.serviceControl(CoreFixtureContract.SERVICE_STATE).getBoolean("nativeLoaded"))
                            assertEquals(before.generation, PseudoVpnService.session.snapshot().generation)
                        }
                "launcherWidget" -> {
                    val manager = android.appwidget.AppWidgetManager.getInstance(context)
                    val provider = android.content.ComponentName(context, VpnWidgetProvider::class.java)
                    fun assertOriginalWidget() {
                        assertTrue("只能保留既有 widget 4",
                            manager.getAppWidgetIds(provider).sortedArray().contentEquals(intArrayOf(4)))
                        assertEquals(provider, manager.getAppWidgetInfo(4)?.provider)
                    }
                    assertOriginalWidget()
                    val ui = instrumentation.getUiAutomation(android.app.UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
                    tileUi = ui
                    val info = ui.serviceInfo
                    info.flags = info.flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                        android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
                    ui.serviceInfo = info
                    assertTrue(ui.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_HOME))
                    val deadline = SystemClock.elapsedRealtime() + 10_000L
                    var clicked = false
                    var lastWitness = ""
                    var launcherPageSwipes = 0
                    while (!clicked && SystemClock.elapsedRealtime() < deadline) {
                        assertTrue(ui.clearCache())
                        val windows = ui.windows
                        var launcherViewport: android.graphics.Rect? = null
                        val hosts = mutableListOf<android.view.accessibility.AccessibilityNodeInfo>()
                        fun collect(node: android.view.accessibility.AccessibilityNodeInfo) {
                            if (node.isVisibleToUser && node.viewIdResourceName ==
                                "com.android.launcher3:id/accessibility_action_view" && node.contentDescription?.toString() == "Home") {
                                val bounds = android.graphics.Rect().also { node.getBoundsInScreen(it) }
                                assertTrue("要求唯一的实际 Launcher viewport", launcherViewport == null || launcherViewport == bounds)
                                launcherViewport = bounds
                            }
                            if (node.isVisibleToUser && node.className?.toString() ==
                                "com.android.launcher3.widget.LauncherAppWidgetHostView" &&
                                node.contentDescription?.toString() == "Clash Pseudo") {
                                hosts.add(android.view.accessibility.AccessibilityNodeInfo.obtain(node))
                                return
                            }
                            for (index in 0 until node.childCount) {
                                val child = node.getChild(index) ?: continue
                                try { collect(child) } finally { child.recycle() }
                            }
                        }
                        try {
                            var launcherWindows = 0
                            for (window in windows) {
                                val root = window.root
                                try {
                                    if (root?.packageName?.toString() == "com.android.launcher3") {
                                        launcherWindows++
                                        collect(root)
                                    }
                                } finally { root?.recycle() }
                            }
                            assertTrue("不能在多个本应用 Launcher widget 中任选一个", hosts.size <= 1)
                            val controls = mutableListOf<android.view.accessibility.AccessibilityNodeInfo>()
                            fun collectControls(node: android.view.accessibility.AccessibilityNodeInfo) {
                                if (node.viewIdResourceName == context.packageName + ":id/widget_control")
                                    controls.add(android.view.accessibility.AccessibilityNodeInfo.obtain(node))
                                for (index in 0 until node.childCount) {
                                    val child = node.getChild(index) ?: continue
                                    try { collectControls(child) } finally { child.recycle() }
                                }
                            }
                            hosts.singleOrNull()?.let { collectControls(it) }
                            try {
                                assertTrue("要求唯一的既有 widget 操作入口", controls.size <= 1)
                                val control = controls.singleOrNull()
                                val witness = "launcherWindows=$launcherWindows ownHosts=${hosts.size} " +
                                    "pageSwipes=$launcherPageSwipes ownControls=${controls.size} action=${control?.contentDescription} " +
                                    "enabled=${control?.isEnabled} clickable=${control?.isClickable}"
                                if (witness != lastWitness) {
                                    Log.i("SystemStartCheck", "actualOriginalWidgetWitness $witness")
                                    lastWitness = witness
                                }
                                if (control != null && control.isVisibleToUser && control.isEnabled && control.isClickable &&
                                    control.contentDescription?.toString() == context.getString(R.string.system_control_action_stop)) {
                                    assertOriginalWidget()
                                    Log.i("SystemStartCheck", "actualOriginalWidgetClick widgetId=4 " +
                                        "session=$id workerBlocked=true action=stop")
                                    assertTrue(control.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK))
                                    clicked = true
                                } else if (hosts.isEmpty() && launcherPageSwipes == 0 && launcherViewport != null) {
                                    // HOME 之后，使用该 Launcher viewport 已校准的相邻页面手势。
                                    val viewport = checkNotNull(launcherViewport)
                                    assertTrue(viewport.width() > 200 && viewport.height() > 400)
                                    val command = "input swipe ${viewport.right - 100} ${viewport.centerY()} " +
                                        "${viewport.left + 100} ${viewport.centerY()} 400; " +
                                        "status=\$?; printf 'CONTROLLED_INPUT_EXIT=%s\\n' \"\$status\""
                                    val descriptors = ui.executeShellCommandRw("/system/bin/sh")
                                    val exit = descriptors[0].use { stdout ->
                                        descriptors[1].use { stdin ->
                                            android.os.ParcelFileDescriptor.AutoCloseOutputStream(stdin).use { input ->
                                                input.write((command + "\nexit\n").toByteArray(Charsets.UTF_8))
                                                input.flush()
                                            }
                                            android.os.ParcelFileDescriptor.AutoCloseInputStream(stdout)
                                                .bufferedReader().use { it.readText().trim() }
                                        }
                                    }
                                    assertEquals("CONTROLLED_INPUT_EXIT=0", exit)
                                    launcherPageSwipes++
                                    Log.i("SystemStartCheck", "actualOriginalWidgetPageSwipe count=$launcherPageSwipes exit=0")
                                }
                            } finally { controls.forEach { it.recycle() } }
                        } finally {
                            hosts.forEach { it.recycle() }
                            windows.forEach { it.recycle() }
                        }
                        if (!clicked) Thread.sleep(100)
                    }
                    assertTrue("既有 Launcher widget 必须实际发送一次 Stop", clicked)
                    assertOriginalWidget()
                }
                "tile" -> {
                    val ui = instrumentation.getUiAutomation(android.app.UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
                    tileUi = ui
                    val info = ui.serviceInfo
                    info.flags = info.flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                        android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
                    ui.serviceInfo = info
                    assertTrue(ui.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_QUICK_SETTINGS))
                    val deadline = SystemClock.elapsedRealtime() + 10_000L
                    var clicked = false
                    var pages = 0
                    var lastWitness = ""
                    while (!clicked && SystemClock.elapsedRealtime() < deadline) {
                        assertTrue("只清除此 observer 的 accessibility cache", ui.clearCache())
                        val windows = ui.windows
                        var qsWindows = 0
                        val nodes = mutableListOf<android.view.accessibility.AccessibilityNodeInfo>()
                        fun collect(node: android.view.accessibility.AccessibilityNodeInfo,
                                    output: MutableList<android.view.accessibility.AccessibilityNodeInfo>) {
                            val viewId = node.viewIdResourceName.orEmpty()
                            if (viewId in setOf("com.android.systemui:id/notification_stack_scroller",
                                    "com.android.systemui:id/expandableNotificationRow")) return
                            if (node.isVisibleToUser && (viewId in setOf("com.android.systemui:id/qs_tile_small",
                                    "com.android.systemui:id/qs_tile_large", "com.android.systemui:id/qs_pager") ||
                                    node.contentDescription?.toString()?.startsWith("Clash Pseudo,") == true)) {
                                output.add(android.view.accessibility.AccessibilityNodeInfo.obtain(node))
                            }
                            for (index in 0 until node.childCount) {
                                val child = node.getChild(index) ?: continue
                                try { collect(child, output) } finally { child.recycle() }
                            }
                        }
                        fun bounds(node: android.view.accessibility.AccessibilityNodeInfo) = android.graphics.Rect().also {
                            node.getBoundsInScreen(it)
                        }
                        try {
                            for (window in windows) {
                                val root = window.root
                                val candidate = mutableListOf<android.view.accessibility.AccessibilityNodeInfo>()
                                try {
                                    if (root?.packageName?.toString() == "com.android.systemui") {
                                        collect(root, candidate)
                                        if (candidate.any { it.viewIdResourceName.orEmpty().startsWith("com.android.systemui:id/qs_") }) {
                                            qsWindows++
                                            nodes.addAll(candidate)
                                            candidate.clear()
                                        }
                                    }
                                } finally {
                                    candidate.forEach { it.recycle() }
                                    root?.recycle()
                                }
                            }
                            assertTrue("要求唯一的可见 Quick Settings 窗口", qsWindows <= 1)
                            if (qsWindows == 1) {
                                // Compose label 与可操作 Tile 使用不同 node，按实际边界匹配。
                                val own = nodes.filter { it.contentDescription?.toString()?.startsWith("Clash Pseudo,") == true }
                                assertTrue("不能在多个本应用 Tile 中任选一个", own.size <= 1)
                                val target = own.singleOrNull()?.let { label ->
                                    nodes.filter { it.viewIdResourceName in setOf("com.android.systemui:id/qs_tile_small",
                                        "com.android.systemui:id/qs_tile_large") && it.isEnabled && it.isClickable &&
                                        bounds(it) == bounds(label) }.also {
                                        assertTrue("要求唯一且与本应用 Tile 边界一致的操作入口", it.size <= 1)
                                    }.singleOrNull()
                                }
                                val witness = "pages=$pages ownLabels=${own.size} " +
                                    "ownDescription=${own.singleOrNull()?.contentDescription} ownActionFound=${target != null}"
                                if (witness != lastWitness) {
                                    Log.i("SystemStartCheck", "actualTileWitness $witness")
                                    lastWitness = witness
                                }
                                if (target != null) {
                                    Log.i("SystemStartCheck", "actualTileClick ownDescription=${own.single().contentDescription} " +
                                        "session=$id workerBlocked=true")
                                    assertTrue(target.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK))
                                    clicked = true
                                } else if (own.isEmpty() && pages < 3) {
                                    val pager = nodes.singleOrNull { it.viewIdResourceName == "com.android.systemui:id/qs_pager" &&
                                        it.actionList.contains(android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_FORWARD) }
                                    if (pager != null) {
                                        val viewport = bounds(pager)
                                        assertTrue(viewport.width() > 200 && viewport.height() > 200)
                                        val gestureBegan = SystemClock.elapsedRealtime()
                                        val command = "input swipe ${viewport.right - 80} ${viewport.centerY()} " +
                                            "${viewport.left + 80} ${viewport.centerY()} 400; " +
                                            "status=\$?; printf 'CONTROLLED_INPUT_EXIT=%s\\n' \"\$status\""
                                        val descriptors = ui.executeShellCommandRw("/system/bin/sh")
                                        val exit = descriptors[0].use { stdout ->
                                            descriptors[1].use { stdin ->
                                                android.os.ParcelFileDescriptor.AutoCloseOutputStream(stdin).use { input ->
                                                    input.write((command + "\nexit\n").toByteArray(Charsets.UTF_8))
                                                    input.flush()
                                                }
                                                android.os.ParcelFileDescriptor.AutoCloseInputStream(stdout)
                                                    .bufferedReader().use { it.readText().trim() }
                                            }
                                        }
                                        assertEquals("已校准的实际 pager 手势必须完成", "CONTROLLED_INPUT_EXIT=0", exit)
                                        Log.i("SystemStartCheck", "actualTilePagerGestureElapsedMs=" +
                                            (SystemClock.elapsedRealtime() - gestureBegan))
                                        pages++
                                        Thread.sleep(200)
                                    }
                                }
                            }
                        } finally {
                            nodes.forEach { it.recycle() }
                            windows.forEach { it.recycle() }
                        }
                        if (!clicked) Thread.sleep(100)
                    }
                    assertTrue("必须实际点击一次本应用 Quick Settings Tile", clicked)
                }
                "shortcut" -> {
                    val intent = SystemControls.actionIntent(context, "stop")
                    assertEquals(context.packageName + ".StopVpnShortcut", intent.component?.className)
                    shortcut = SystemControls.activityPendingIntent(context, intent, 57042)
                    // creator 与 sender 使用公开 SDK 入口；实际 alias Activity 在 post-resume 受理固定 Stop。
                    val options = ActivityOptions.makeBasic()
                        .setPendingIntentBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
                        .toBundle()
                    checkNotNull(shortcut).send(context, 0, null, null, null, null, options)
                }
                "notification", "notificationLocked" -> {
                    val manager = context.getSystemService(android.app.NotificationManager::class.java)
                    assertTrue("本场景要求已有通知授权和可见的实际通知",
                        manager.activeNotifications.any { it.id == 1 })
                    val posted = manager.activeNotifications.single { it.id == 1 }.notification
                    val stop = posted.actions.single().actionIntent
                    val expected = PendingIntent.getBroadcast(context, 1002,
                        Intent(context, VpnWidgetProvider::class.java).setAction(VpnWidgetProvider.ACTION_STOP),
                        PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)
                    assertNotNull("实际通知必须复用私有 Stop broadcast", expected)
                    assertEquals(expected, stop)
                    assertEquals(context.packageName, stop.creatorPackage)
                    assertFalse(stop.isActivity)
                    if (lockedStop) main {
                        assertTrue(context.getSystemService(KeyguardManager::class.java).isKeyguardLocked)
                        var admission: SystemControls.Admission? = null
                        SystemControls.request(context, "start") { admission = it }
                        assertEquals("锁屏时 Start 不能继承 Stop authority", SystemControls.Admission.OPEN_APP, admission)
                        assertEquals(owner, AppBridge.operationId)
                        assertTrue(AppBridge.pendingSystemRestore)
                    }
                    val receipt = java.util.concurrent.CountDownLatch(1)
                    stop.send(context, 0, null,
                        PendingIntent.OnFinished { _, _, _, _, _ -> receipt.countDown() },
                        android.os.Handler(android.os.Looper.getMainLooper()))
                    assertTrue("实际 Stop broadcast 必须在 admission callback 后结束", receipt.await(10, TimeUnit.SECONDS))
                    assertTrue("broadcast 完成不能释放 AppRuntime 调度 gate", gate.held)
                }
                "widgetSdk", "widgetLocked" -> {
                    val projected = java.util.concurrent.CompletableFuture<SystemControls.Projection>()
                    main { SystemControls.snapshot { projected.complete(it) } }
                    val projection = projected.get(15, TimeUnit.SECONDS)
                    assertTrue(projection.preparing || projection.pendingRestore)
                    assertEquals("stop", projection.action)
                    main {
                        if (lockedStop) {
                            assertTrue(context.getSystemService(KeyguardManager::class.java).isKeyguardLocked)
                            var admission: SystemControls.Admission? = null
                            SystemControls.request(context, "start") { admission = it }
                            assertEquals(SystemControls.Admission.OPEN_APP, admission)
                        }
                        // 使用既有 widget projection 检查 SDK RemoteViews。
                        val root = VpnWidgetProvider.remoteViews(context, projection, 160f).apply(context, null)
                        val button = checkNotNull(root.findViewById<ImageButton>(R.id.widget_control))
                        assertTrue(button.isEnabled)
                        assertEquals(context.getString(R.string.system_control_action_stop), button.contentDescription?.toString())
                        assertTrue(button.hasOnClickListeners())
                        assertTrue("SDK 按钮必须发送生产 broadcast PendingIntent", button.performClick())
                    }
                }
            }
                    if (systemRevoke) {
                        Log.i("SystemStartCheck", "WAIT_REAL_SYSTEM_REVOKE nonce=p5-system-revoke-r7u8 pid=${Process.myPid()} owner=$owner nativePrepared=false")
                        await("系统实际撤销 VPN 授权", 60_000) { VpnService.prepare(context) != null }
                    } else if (revoke) {
                        observer.debug.serviceControl(CoreFixtureContract.REVOKE_SERVICE)
                    } else if (controlsEntry == null || controlsEntry in setOf("serviceInterface", "staleIntents")) {
                        assertEquals(SystemControls.Admission.ACCEPTED, platform.stopFromSystemControl())
                    }
                    await("取消原 systemStart owner") {
                        !AppBridge.pendingSystemRestore && AppBridge.operationId != owner && !AppBridge.logic.ownsOperation(owner)
                    }
                    assertTrue("取消完成时 AppRuntime 调度仍被挂起", gate.held)
                    observer.awaitDeath()
                    assertTrue("AppRuntime 调度释放前，未装载 native 的原进程必须退出", observer.deathConfirmed)
                    await("默认进程收到同一 process 的 DeathRecipient") {
                        val status = CoreClient.get(context).status()
                        status[Contract.CORE_FIELD_PROCESS_ID] == observer.processId &&
                            status[Contract.CORE_FIELD_PHASE] == Contract.CORE_PHASE_EXITED
                    }
                    assertTrue(gate.held)
                    assertEquals(before.generation, PseudoVpnService.session.snapshot().generation)
                    assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
                    main {
                        when (controlsEntry) {
                            "shortcut" -> {
                                assertNotNull("PendingIntent 必须创建真实 MainActivity", controlsActivity)
                                assertEquals(context.packageName + ".StopVpnShortcut", activityComponent)
                                assertTrue("Stop 必须在真实 Activity RESUMED 后受理", activityResumed)
                            }
                            "widgetSdk", "widgetLocked", "tile", "launcherWidget", "notification", "notificationLocked" ->
                                assertNull("headless Stop 不能退回 Activity", controlsActivity)
                        }
                    }
                    gate.release()
                    await("释放调度后 writer 结束且没有 late start") {
                        !AppBridge.logic.busy && AppBridge.operationId == null && !AppBridge.pendingSystemRestore &&
                            PseudoVpnService.session.snapshot().phase == NativeSession.Phase.STOPPED
                    }
                    assertTrue("释放 AppRuntime 调度不能复活旧 process", observer.deathConfirmed)
                    assertEquals(before.generation, PseudoVpnService.session.snapshot().generation)
                    await("真实 process death 与 Service 销毁") {
                        !CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java)
                    }
                    if (systemRevoke) assertNotNull("系统必须实际撤销授权", VpnService.prepare(context))
                    else assertNull("Stop 必须保留系统授权", VpnService.prepare(context))
                    CoreIpcTestDriver.assertNoGoInApplication()
                } finally {
                    try {
                        if (main { AppBridge.pendingSystemRestore || AppBridge.operationId != null }) platform.stopFromSystemControl()
                    } finally {
                        gate.release()
                        shortcut?.cancel()
                        tileUi?.let { assertTrue(it.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_HOME)) }
                        if (observingActivity) main {
                            ActivityLifecycleMonitorRegistry.getInstance().removeLifecycleCallback(lifecycle)
                            controlsActivity?.finish()
                        }
                        if (hashes != null && epoch != null) assertStoresUnchanged(files, stores, epoch, hashes)
                    }
                }
            }
        }
    }

    @Test fun staleRestoreCompletionNeverTouchesAnotherServicesForegroundResources() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val platform = CorePlatformTestDriver(context)
        platform.await("业务 writer 空闲") { AppBridge.operationId == null && !AppBridge.logic.busy }
        assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
        RuntimeDispatchGate(platform).use { gate ->
            CoreIpcTestDriver.fixture().use { observer ->
                val start = Intent(context, PseudoVpnService::class.java).setAction(VpnService.SERVICE_INTERFACE)
                assertNotNull(context.startForegroundService(start))
                platform.await("真实系统恢复 owner") { AppBridge.pendingSystemRestore && AppBridge.operationId != null }
                val current = CoreIpcTestDriver.onMain { checkNotNull(AppBridge.operationId) }
                val before = PseudoVpnService.session.snapshot()
                val coordinator = io.github.monadboxlab.clashpseudo.bridge.BridgeTestState.coordinator("systemRestore") as
                    io.github.monadboxlab.clashpseudo.bridge.runtime.SystemRestore
                val notification = context.getSystemService(android.app.NotificationManager::class.java)
                @Suppress("DEPRECATION")
                fun foreground() = context.getSystemService(android.app.ActivityManager::class.java).getRunningServices(100).any {
                    it.service == android.content.ComponentName(context, PseudoVpnService::class.java) && it.foreground
                }
                platform.await("真实 foreground", ready = ::foreground)
                val posted = notification.activeNotifications.singleOrNull { it.id == 1 }
                for (success in listOf(true, false)) {
                    val replies = mutableListOf<Map<String, Any?>?>()
                    CoreIpcTestDriver.onMain {
                        coordinator.completeSystemRestore("retired-$current", mapOf("success" to success)) { replies.add(it) }
                    }
                    assertEquals(listOf<Map<String, Any?>?>(null), replies)
                    assertEquals(current, CoreIpcTestDriver.onMain { AppBridge.operationId })
                    assertTrue(CoreIpcTestDriver.onMain { AppBridge.pendingSystemRestore })
                    assertTrue(foreground())
                    assertEquals(posted?.key, notification.activeNotifications.singleOrNull { it.id == 1 }?.key)
                    assertEquals(before.generation, PseudoVpnService.session.snapshot().generation)
                    assertEquals(before.phase, PseudoVpnService.session.snapshot().phase)
                    assertEquals(before.error, PseudoVpnService.session.snapshot().error)
                    assertFalse(observer.debug.serviceControl(CoreFixtureContract.SERVICE_STATE).getBoolean("nativeLoaded"))
                }
                assertEquals(SystemControls.Admission.ACCEPTED, platform.stopFromSystemControl())
                platform.await("当前系统恢复结束") { !AppBridge.pendingSystemRestore && AppBridge.operationId == null }
                gate.release()
                observer.exit()
            }
        }
    }

    @Test fun systemAndStaleIntentsCannotTearDownThePendingRestore() =
        checkPreparationCancellation(revoke = false, controlsEntry = "staleIntents")

    private fun expectedStores(): Map<BackupFiles.Kind, String> {
        val arguments = InstrumentationRegistry.getArguments()
        fun digest(name: String) = checkNotNull(arguments.getString(name)) { "缺少 $name" }.also {
            check(it == "absent" || Regex("[0-9a-f]{64}").matches(it)) { "$name 无效" }
        }
        return mapOf(BackupFiles.Kind.CONFIGURATIONS to digest("expectedConfigurationsSha256"),
            BackupFiles.Kind.OVERRIDES to digest("expectedOverridesSha256"),
            BackupFiles.Kind.PREFERENCES to digest("expectedPreferencesSha256"))
    }

    private fun assertStoresUnchanged(files: BackupFiles, stores: File, storageEpoch: Long, expectedStores: Map<BackupFiles.Kind, String>) {
        val deadline = SystemClock.elapsedRealtime() + 60_000L
        while (true) {
            files.transaction.requireEpoch(storageEpoch)
            try {
                files.transaction.withStableStorage(storageEpoch) {
                    for ((kind, expected) in expectedStores) {
                        val file = File(stores, kind.fileName)
                        val actual = if (files.lstat(file) == null) "absent" else files.fingerprint(file).sha256
                        assertEquals("正式存储 SHA-256 不一致：${kind.fileName}", expected, actual)
                    }
                }
                return
            } catch (error: IOException) {
                if (error.message != "storageBusy") throw error
                check(SystemClock.elapsedRealtime() < deadline) { "等待稳定存储读取超时" }
                Thread.sleep(50)
            }
        }
    }
}
