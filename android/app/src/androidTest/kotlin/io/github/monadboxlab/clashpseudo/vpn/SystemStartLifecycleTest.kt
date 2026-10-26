package io.github.monadboxlab.clashpseudo.vpn

import android.app.ActivityOptions
import android.app.KeyguardManager
import android.app.PendingIntent
import android.app.Service
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
import io.flutter.FlutterInjector
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.R
import io.github.monadboxlab.clashpseudo.app.VpnWidgetProvider
import io.github.monadboxlab.clashpseudo.controls.SystemControls
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.backup.BackupFiles
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
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
        val arguments = InstrumentationRegistry.getArguments()
        fun required(name: String) = checkNotNull(arguments.getString(name)) { "Missing $name" }
        val expectedId = required("expectedConfigId").also { check(it.isNotBlank()) }
        val expectedName = required("expectedConfigName").also { check(it.isNotBlank()) }
        val expectedRevision = required("expectedRevision").toIntOrNull()
            ?.takeIf { it > 0 } ?: error("Invalid expectedRevision")
        val digestPattern = Regex("[0-9a-f]{64}")
        val expectedBody = required("expectedBodySha256").also { check(digestPattern.matches(it)) }
        val expectedStores = expectedStores()
        check(expectedStores.getValue(BackupFiles.Kind.CONFIGURATIONS) != "absent")
        check(Build.VERSION.SDK_INT in 36..37) { "This controlled run requires API 36 or 37" }
        fun main(block: () -> Unit) = instrumentation.runOnMainSync(block)
        fun awaitMain(label: String, ready: () -> Boolean) {
            val deadline = SystemClock.elapsedRealtime() + 60_000L
            while (true) {
                var complete = false
                main { complete = ready() }
                if (complete) return
                check(SystemClock.elapsedRealtime() < deadline) { "Timed out waiting for $label" }
                Thread.sleep(50)
            }
        }
        val files = BackupFiles.get(context)
        // Resolve the SDK-owned anchor.
        val stores = File(context.filesDir.canonicalFile, "configurations")
        awaitMain("business storage recovery") {
            files.transaction.snapshot().let { it.ready && !it.restoring }
        }
        val storageEpoch = files.transaction.snapshot().epoch
        fun assertStoresUnchanged() = this.assertStoresUnchanged(files, stores, storageEpoch, expectedStores)
        // Compare streaming, read-only fingerprints with independently supplied
        // expected hashes.
        assertStoresUnchanged()
        var initialGeneration = -1L
        main {
            val monitor = ActivityLifecycleMonitorRegistry.getInstance()
            for (stage in Stage.values().filter { it != Stage.DESTROYED }) {
                assertTrue("Application UI must not precede this headless service run",
                    monitor.getActivitiesInStage(stage).isEmpty())
            }
            assertNull("An existing VPN service is not a fresh-host premise", PseudoVpnService.instance)
            val session = PseudoVpnService.session.snapshot()
            assertEquals(NativeSession.Phase.STOPPED, session.phase)
            assertEquals("Run alone in a newly installed, data-preserving process", 0L, session.generation)
            initialGeneration = session.generation
            assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
            assertNull("VPN must already be authorized; never launch a grant dialog", VpnService.prepare(context))
            // Allow startup calibration to finish on the newly created headless host.
            Log.i("SystemStartCheck", "instrumentation SERVICE_INTERFACE pid=${Process.myPid()} " +
                "loaderInitialized=${FlutterInjector.instance().flutterLoader().initialized()} " +
                "writerBusy=${AppBridge.logic.busy}")
        }
        var requestIssued = false
        var failure: Throwable? = null
        try {
            val intent = Intent(context, PseudoVpnService::class.java).setAction(VpnService.SERVICE_INTERFACE)
            // From here, even an ambiguous platform start failure is settled by a normal Stop.
            requestIssued = true
            val component = if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
                else context.startService(intent)
            assertNotNull("Framework did not accept the real Service component", component)
            lateinit var running: NativeSession.Snapshot
            lateinit var loaded: CoreHost.Snapshot
            awaitMain("real VPN RUNNING") {
                val session = PseudoVpnService.session.snapshot()
                val core = PseudoVpnService.core.snapshot()
                assertNotEquals("Native cleanup became unknown", NativeSession.Phase.UNKNOWN, session.phase)
                assertNotEquals("Native cleanup was not confirmed", CoreHost.Phase.FAILED, core.phase)
                val startupError = session.error
                if (session.generation > initialGeneration && session.phase == NativeSession.Phase.STOPPED &&
                    startupError != null) fail("Service startup ended: ${startupError.id}")
                (session.phase == NativeSession.Phase.RUNNING && core.phase == CoreHost.Phase.READY &&
                    core.purpose == CoreHost.Purpose.VPN).also { ready ->
                    if (ready) { running = session; loaded = core }
                }
            }
            assertTrue("Service loaded a different configuration", running.configId == expectedId)
            assertEquals(expectedRevision, running.revision)
            assertTrue("Core loaded a different configuration", loaded.configId == expectedId)
            assertEquals(expectedRevision, loaded.revision)
            val composition = checkNotNull(loaded.composition)
            val actual = FutureTask {
                val input = checkNotNull(PseudoVpnService.core.runningInput(loaded.generation, composition))
                Triple(input, JSONObject(NativeCore.snapshot()), JSONObject(NativeCore.vpnSpec()))
            }
            PseudoVpnService.worker.execute(actual)
            val (inputBytes, native, specification) = actual.get(10, TimeUnit.SECONDS)
            val input = JSONObject(inputBytes.toString(Charsets.UTF_8))
            assertTrue("Actual running input ID differs", input.getString("id") == expectedId)
            assertEquals(expectedRevision, input.getInt("revision"))
            assertEquals(expectedName, input.getString("name"))
            assertEquals(0, input.getJSONArray("overrides").length())
            val bodyDigest = MessageDigest.getInstance("SHA-256")
                .digest(input.getString("body").toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            assertEquals("Actual loaded body differs from the authorized fixture", expectedBody, bodyDigest)
            assertEquals(composition, input.getString("composition"))
            assertEquals(loaded.generation, specification.getLong("generation"))
            assertEquals(composition, specification.getString("composition"))
            assertTrue(native.getBoolean("prepared"))
            assertTrue(native.getBoolean("attached"))
            assertFalse(native.getBoolean("cleanupFailed"))
            main {
                val session = PseudoVpnService.session.snapshot()
                assertEquals(NativeSession.Phase.RUNNING, session.phase)
                assertEquals(running.generation, session.generation)
                assertEquals(loaded, PseudoVpnService.core.snapshot())
                assertNotNull(PseudoVpnService.instance)
                assertFalse(AppBridge.pendingSystemRestore)
            }
            Log.i("SystemStartCheck", "SERVICE_INTERFACE RUNNING session=${running.generation} " +
                "core=${loaded.generation} actualInputMatched=true nativeAttached=true")
            if (revokeStoppedGap) {
                val service = checkNotNull(PseudoVpnService.instance)
                val entered = java.util.concurrent.CountDownLatch(1)
                val release = java.util.concurrent.CountDownLatch(1)
                val barrier = FutureTask {
                    entered.countDown()
                    check(release.await(30, TimeUnit.SECONDS)) { "Reconnect barrier was not released" }
                }
                PseudoVpnService.worker.execute(barrier)
                try {
                    assertTrue(entered.await(10, TimeUnit.SECONDS))
                    assertNotNull(context.startService(Intent(context, PseudoVpnService::class.java)
                        .setAction(PseudoVpnService.ACTION_STOP)
                        .putExtra(PseudoVpnService.EXTRA_INTERNAL_STOP, true)))
                    awaitMain("internal reconnect STOPPING before native release") {
                        val state = PseudoVpnService.session.snapshot()
                        assertSame(service, PseudoVpnService.instance)
                        state.generation == running.generation && state.phase == NativeSession.Phase.STOPPING
                    }
                    // Keep a system request outstanding so revocation's effect on
                    // reconnect is observable.
                    assertNotNull(context.startForegroundService(intent))
                    awaitMain("system request waiting for internal reconnect cleanup") {
                        assertSame(service, PseudoVpnService.instance)
                        assertEquals(NativeSession.Phase.STOPPING, PseudoVpnService.session.snapshot().phase)
                        assertFalse(AppBridge.pendingSystemRestore)
                        service.pendingSystemStart
                    }
                    val drained = FutureTask { JSONObject(NativeCore.snapshot()) }
                    PseudoVpnService.worker.execute(drained)
                    main {
                        // Hold the main queue while the native worker reaches STOPPED
                        // and Service cleanup remains queued.
                        release.countDown()
                        val released = drained.get(10, TimeUnit.SECONDS)
                        assertSame(service, PseudoVpnService.instance)
                        val gap = PseudoVpnService.session.snapshot()
                        assertEquals(running.generation, gap.generation)
                        assertEquals(NativeSession.Phase.STOPPED, gap.phase)
                        assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
                        assertFalse(released.getBoolean("prepared"))
                        assertFalse(released.getBoolean("attached"))
                        assertFalse(released.getBoolean("cleanupFailed"))
                        assertTrue(service.pendingSystemStart)
                        assertFalse(AppBridge.pendingSystemRestore)
                        service.onRevoke()
                        assertFalse("Revoke must retire the outstanding reconnect owner immediately",
                            service.pendingSystemStart)
                    }
                    awaitMain("revoked reconnect Service retirement and writer drain") {
                        val state = PseudoVpnService.session.snapshot()
                        assertEquals(running.generation, state.generation)
                        assertEquals(NativeSession.Phase.STOPPED, state.phase)
                        assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
                        PseudoVpnService.instance == null && !AppBridge.pendingSystemRestore &&
                            !AppBridge.logic.busy && AppBridge.operationId == null
                    }
                    // Pass the already queued 100ms systemStart retry, then drain
                    // native work too. Neither may authorize a late business start.
                    val retryPassed = FutureTask { Unit }
                    main { android.os.Handler(android.os.Looper.getMainLooper()).postDelayed(retryPassed, 150L) }
                    retryPassed.get(10, TimeUnit.SECONDS)
                    val late = FutureTask { JSONObject(NativeCore.snapshot()) }
                    PseudoVpnService.worker.execute(late)
                    val lateNative = late.get(10, TimeUnit.SECONDS)
                    main {
                        assertEquals(running.generation, PseudoVpnService.session.snapshot().generation)
                        assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
                        assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
                        assertNull(PseudoVpnService.instance)
                        assertFalse(service.pendingSystemStart)
                        assertFalse(AppBridge.pendingSystemRestore)
                        assertFalse(AppBridge.logic.busy)
                        assertNull(AppBridge.operationId)
                    }
                    assertFalse(lateNative.getBoolean("prepared"))
                    assertFalse(lateNative.getBoolean("attached"))
                    assertFalse(lateNative.getBoolean("cleanupFailed"))
                    Log.i("SystemStartCheck", "internalReconnectStoppedGap=true session=${running.generation} " +
                        "realPendingOwner=true revokedBeforeQueuedCleanup=true noLateStart=true nativeReleased=true")
                } finally {
                    release.countDown()
                    barrier.get(10, TimeUnit.SECONDS)
                }
            }
            if (retiredCallbacks) {
                val retired = checkNotNull(PseudoVpnService.instance)
                context.startService(Intent(context, PseudoVpnService::class.java)
                    .setAction(PseudoVpnService.ACTION_STOP))
                awaitMain("first live Service destruction and native release") {
                    PseudoVpnService.instance == null &&
                        PseudoVpnService.session.snapshot().phase == NativeSession.Phase.STOPPED &&
                        PseudoVpnService.core.snapshot().phase == CoreHost.Phase.EMPTY &&
                        !AppBridge.pendingSystemRestore && !AppBridge.logic.busy && AppBridge.operationId == null
                }
                assertNotNull(context.startForegroundService(intent))
                awaitMain("replacement real VPN RUNNING") {
                    PseudoVpnService.session.snapshot().let {
                        assertNotEquals(NativeSession.Phase.UNKNOWN, it.phase)
                        it.phase == NativeSession.Phase.RUNNING && it.generation > running.generation
                    } && PseudoVpnService.core.snapshot().phase == CoreHost.Phase.READY &&
                        !AppBridge.pendingSystemRestore && !AppBridge.logic.busy && AppBridge.operationId == null
                }
                val replacement = checkNotNull(PseudoVpnService.instance)
                assertNotSame(retired, replacement)
                val replacementState = PseudoVpnService.session.snapshot()
                val replacementCore = PseudoVpnService.core.snapshot()
                assertEquals(expectedId, replacementState.configId)
                assertEquals(expectedRevision, replacementState.revision)
                assertEquals(expectedId, replacementCore.configId)
                assertEquals(expectedRevision, replacementCore.revision)
                @Suppress("DEPRECATION")
                fun replacementIsForeground() = context.getSystemService(android.app.ActivityManager::class.java)
                    .getRunningServices(100).any {
                        it.service == android.content.ComponentName(context, PseudoVpnService::class.java) && it.foreground
                    }
                assertTrue(replacementIsForeground())
                main {
                    // Replay callbacks on the actual retired Service object.
                    retired.onRevoke()
                    retired.onDestroy()
                    assertFalse(retired.cancelSystemStart(terminal = true))
                }
                // Drain any native work accidentally enqueued by the stale callbacks.
                val checked = FutureTask {
                    val bytes = checkNotNull(PseudoVpnService.core.runningInput(
                        replacementCore.generation, checkNotNull(replacementCore.composition)))
                    Triple(JSONObject(bytes.toString(Charsets.UTF_8)), JSONObject(NativeCore.snapshot()),
                        JSONObject(NativeCore.vpnSpec()))
                }
                PseudoVpnService.worker.execute(checked)
                val (replacementInput, replacementNative, replacementSpec) = checked.get(10, TimeUnit.SECONDS)
                main {
                    assertSame(replacement, PseudoVpnService.instance)
                    assertEquals(replacementCore, PseudoVpnService.core.snapshot())
                    val now = PseudoVpnService.session.snapshot()
                    assertEquals(NativeSession.Phase.RUNNING, now.phase)
                    assertEquals(replacementState.generation, now.generation)
                    assertEquals(replacementState.error, now.error)
                    assertFalse(replacement.pendingSystemStart)
                    assertTrue(replacementIsForeground())
                }
                assertEquals(input.getString("body"), replacementInput.getString("body"))
                assertEquals(expectedId, replacementInput.getString("id"))
                assertEquals(expectedRevision, replacementInput.getInt("revision"))
                assertEquals(0, replacementInput.getJSONArray("overrides").length())
                assertEquals(replacementCore.composition, replacementInput.getString("composition"))
                assertEquals(replacementCore.composition, replacementSpec.getString("composition"))
                assertEquals(replacementCore.generation, replacementSpec.getLong("generation"))
                assertTrue(replacementNative.getBoolean("attached"))
                assertFalse(replacementNative.getBoolean("cleanupFailed"))
                Log.i("SystemStartCheck", "retiredLiveCallbacks=true replacementSession=${replacementState.generation} " +
                    "actualInputMatched=true nativeAttached=true foregroundPreserved=true")
            }
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            if (requestIssued) {
                var cleanupFailure: Throwable? = null
                try {
                    // Use the production Stop intent and wait for pending preparation
                    // and native ownership to drain.
                    context.startService(Intent(context, PseudoVpnService::class.java)
                        .setAction(PseudoVpnService.ACTION_STOP))
                    awaitMain("normal Stop and actual writer drain") {
                        val session = PseudoVpnService.session.snapshot()
                        val core = PseudoVpnService.core.snapshot()
                        assertNotEquals("Native cleanup became unknown", NativeSession.Phase.UNKNOWN, session.phase)
                        assertNotEquals("Native cleanup was not confirmed", CoreHost.Phase.FAILED, core.phase)
                        session.phase == NativeSession.Phase.STOPPED && core.phase == CoreHost.Phase.EMPTY &&
                            PseudoVpnService.instance == null && !AppBridge.pendingSystemRestore &&
                            !AppBridge.logic.busy && AppBridge.operationId == null
                    }
                    val stopped = FutureTask { JSONObject(NativeCore.snapshot()) }
                    PseudoVpnService.worker.execute(stopped)
                    val native = stopped.get(10, TimeUnit.SECONDS)
                    assertFalse(native.getBoolean("prepared"))
                    assertFalse(native.getBoolean("attached"))
                    assertFalse(native.getBoolean("cleanupFailed"))
                } catch (error: Throwable) { cleanupFailure = error }
                try { assertStoresUnchanged() } catch (error: Throwable) {
                    if (cleanupFailure == null) cleanupFailure = error else cleanupFailure.addSuppressed(error)
                }
                if (cleanupFailure != null) {
                    if (failure == null) throw cleanupFailure else failure.addSuppressed(cleanupFailure)
                } else {
                    Log.i("SystemStartCheck", "SERVICE_INTERFACE STOPPED nativeReleased=true storesUnchanged=true")
                }
            }
        }
    }

    private fun expectedStores(): Map<BackupFiles.Kind, String> {
        val arguments = InstrumentationRegistry.getArguments()
        val digestPattern = Regex("[0-9a-f]{64}")
        fun storeDigest(name: String) = checkNotNull(arguments.getString(name)) { "Missing $name" }.also {
            check(it == "absent" || digestPattern.matches(it)) { "Invalid $name" }
        }
        return mapOf(
            BackupFiles.Kind.CONFIGURATIONS to storeDigest("expectedConfigurationsSha256"),
            BackupFiles.Kind.OVERRIDES to storeDigest("expectedOverridesSha256"),
            BackupFiles.Kind.PREFERENCES to storeDigest("expectedPreferencesSha256"),
        )
    }

    private fun assertStoresUnchanged(
        files: BackupFiles, stores: File, storageEpoch: Long, expectedStores: Map<BackupFiles.Kind, String>,
    ) {
        val deadline = SystemClock.elapsedRealtime() + 60_000L
        var busyReads = 0
        while (true) {
            files.transaction.requireEpoch(storageEpoch)
            try {
                files.transaction.withStableStorage(storageEpoch) {
                    for ((kind, expected) in expectedStores) {
                        val file = File(stores, kind.fileName)
                        val actual = if (files.lstat(file) == null) "absent" else files.fingerprint(file).sha256
                        assertEquals("Controlled Store fingerprint differs: ${kind.fileName}", expected, actual)
                    }
                }
                if (busyReads > 0) Log.i("SystemStartCheck", "Store snapshot admitted after busyReads=$busyReads epoch=$storageEpoch")
                return
            } catch (error: IOException) {
                // Retry startup calibration's busy admission while preserving the
                // epoch and checking fingerprint/I/O results.
                if (error.message != "storageBusy") throw error
                check(SystemClock.elapsedRealtime() < deadline) { "Timed out waiting for stable Store snapshot" }
                busyReads++
                Thread.sleep(50)
            }
        }
    }

    @Test fun duplicateServiceInterfaceWhileStartingCannotPrepareOrStartAfterStop() =
        checkPreparationCancellation(revoke = false, controlsEntry = "serviceInterface")

    @Test fun stopShortcutPendingIntentCancelsRealPreparationThroughActivity() =
        checkPreparationCancellation(revoke = false, controlsEntry = "shortcut")

    @Test fun sdkRemoteViewsStopButtonCancelsRealPreparationThroughWidgetBroadcast() =
        checkPreparationCancellation(revoke = false, controlsEntry = "widgetSdk")

    @Test fun actualQuickSettingsTileCancelsRealPreparationBeforeWorkerRelease() =
        checkPreparationCancellation(revoke = false, controlsEntry = "tile")

    @Test fun originalLauncherWidgetCancelsRealPreparationBeforeWorkerRelease() =
        checkPreparationCancellation(revoke = false, controlsEntry = "launcherWidget")

    @Test fun stopBeforeNativePreparationRetiresTheRealService() =
        checkPreparationCancellation(revoke = false)

    @Test fun revokeCallbackBeforeNativePreparationRetiresTheRealService() =
        checkPreparationCancellation(revoke = true)

    @Test fun systemRevokeBeforeNativePreparationRetiresTheRealService() =
        checkPreparationCancellation(revoke = true, systemRevoke = true)

    private fun checkPreparationCancellation(
        revoke: Boolean, systemRevoke: Boolean = false, controlsEntry: String? = null,
    ) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val arguments = InstrumentationRegistry.getArguments()
        if (controlsEntry != null) {
            check(Build.VERSION.SDK_INT == if (controlsEntry == "launcherWidget") 36 else 37)
            check(arguments.getString("controlsPreparationNonce") == "p5-controls-preparation-r7x1")
        }
        val expectedStores = if (controlsEntry != null) expectedStores() else null
        val expectedEpoch = if (controlsEntry != null) {
            checkNotNull(arguments.getString("expectedStorageEpoch")?.toLongOrNull()?.takeIf { it >= 0 }) {
                "Missing or invalid expectedStorageEpoch"
            }
        } else null
        if (systemRevoke) {
            check(Build.VERSION.SDK_INT == 37)
            check(InstrumentationRegistry.getArguments().getString("systemRevokeNonce") == "p5-system-revoke-r7u8")
        }
        fun <T> main(block: () -> T): T {
            val task = FutureTask(block)
            instrumentation.runOnMainSync(task)
            return task.get()
        }
        fun await(label: String, timeoutMs: Long = 15_000, ready: () -> Boolean) {
            val deadline = SystemClock.elapsedRealtime() + timeoutMs
            while (!main(ready)) {
                check(SystemClock.elapsedRealtime() < deadline) { "Timed out waiting for $label" }
                Thread.sleep(25)
            }
        }
        await("idle business writer") { !AppBridge.logic.busy && AppBridge.operationId == null }
        val files = BackupFiles.get(context)
        val stores = File(context.filesDir.canonicalFile, "configurations")
        if (expectedStores != null && expectedEpoch != null) {
            await("business storage recovery") {
                files.transaction.snapshot().let { it.ready && !it.restoring }
            }
            assertStoresUnchanged(files, stores, expectedEpoch, expectedStores)
        }
        val before = main {
            if (controlsEntry != null) {
                assertFalse("Do not run controls cancellation under Always-on", PseudoVpnService.alwaysOnState() == true)
                assertFalse("Controls require an already unlocked device",
                    checkNotNull(context.getSystemService(KeyguardManager::class.java)).isKeyguardLocked)
                assertFalse(AppBridge.pendingSystemRestore)
                for (stage in Stage.values().filter { it != Stage.DESTROYED }) {
                    assertTrue("Run each controls case without an existing MainActivity",
                        ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(stage)
                            .none { it is MainActivity })
                }
            }
            assertNull(PseudoVpnService.instance)
            assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
            assertNull("Keep the existing grant; never open authorization", VpnService.prepare(context))
            PseudoVpnService.session.snapshot().also { assertEquals(NativeSession.Phase.STOPPED, it.phase) }
        }
        val nativeBefore = NativeCore.snapshot()
        assertFalse(JSONObject(nativeBefore).getBoolean("prepared"))
        assertFalse(JSONObject(nativeBefore).getBoolean("attached"))
        if (controlsEntry != null) assertFalse(JSONObject(nativeBefore).getBoolean("cleanupFailed"))
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val barrier = FutureTask {
            entered.countDown()
            check(release.await(if (systemRevoke) 90L else if (controlsEntry != null) 60L else 30L, TimeUnit.SECONDS)) {
                "Preparation barrier was not released"
            }
        }
        PseudoVpnService.worker.execute(barrier)
        var requested = false
        var invalidatedBeforeRelease = false
        var controlsActivity: MainActivity? = null
        var activityComponent: String? = null
        var activityResumed = false
        var observingActivity = false
        var shortcut: PendingIntent? = null
        var tileUi: android.app.UiAutomation? = null
        val lifecycle = ActivityLifecycleCallback { activity, stage ->
            if (activity is MainActivity) {
                if (stage == Stage.CREATED) {
                    controlsActivity = activity
                    activityComponent = activity.intent.component?.className
                }
                if (stage == Stage.RESUMED) activityResumed = true
            }
        }
        val id = before.generation + 1
        try {
            assertTrue(entered.await(10, TimeUnit.SECONDS))
            if (controlsEntry in setOf("shortcut", "widgetSdk", "tile", "launcherWidget")) main {
                ActivityLifecycleMonitorRegistry.getInstance().addLifecycleCallback(lifecycle)
                observingActivity = true
            }
            // Hold the real worker before Prepare, then invoke the same-UID production
            // start entry.
            val start = Intent(context, PseudoVpnService::class.java)
                .setAction(PseudoVpnService.ACTION_START)
                .putExtra(PseudoVpnService.EXTRA_CONFIG, "rules:\n  - MATCH,REJECT\n")
                .putExtra(PseudoVpnService.EXTRA_CONFIG_ID, "controlled-preparation-cancel")
                .putExtra(PseudoVpnService.EXTRA_REVISION, 1)
            requested = true
            assertNotNull(if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(start)
                else context.startService(start))
            await("real Service STARTING before native Prepare") {
                val state = PseudoVpnService.session.snapshot()
                state.generation == id && state.phase == NativeSession.Phase.STARTING &&
                    PseudoVpnService.instance != null
            }
            assertEquals(nativeBefore, NativeCore.snapshot())
            val startingService = main { checkNotNull(PseudoVpnService.instance) }
            if (controlsEntry != null) {
                Log.i("SystemStartCheck", "controlsPreparation nonce=p5-controls-preparation-r7x1 " +
                    "entry=$controlsEntry session=$id phase=STARTING workerBlocked=true")
            }
            when (controlsEntry) {
                "serviceInterface" -> {
                    // Deliver framework intents to the existing STARTING Service.
                    val duplicate = Intent(context, PseudoVpnService::class.java)
                        .setAction(VpnService.SERVICE_INTERFACE)
                    repeat(2) { assertNotNull(context.startForegroundService(duplicate)) }
                    instrumentation.waitForIdleSync()
                    main {
                        assertSame(startingService, PseudoVpnService.instance)
                        val state = PseudoVpnService.session.snapshot()
                        assertEquals(id, state.generation)
                        assertEquals(NativeSession.Phase.STARTING, state.phase)
                        assertFalse(startingService.pendingSystemStart)
                        assertFalse(AppBridge.pendingSystemRestore)
                        val action = AppBridge.command?.get("action")
                        assertTrue("Only normal startup schedule calibration may coexist with STARTING",
                            action == null || action == "syncSchedules")
                        Log.i("SystemStartCheck", "duplicateStarting businessAction=$action " +
                            "writerBusy=${AppBridge.logic.busy} pendingSystemRestore=false")
                        assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
                    }
                    assertEquals(nativeBefore, NativeCore.snapshot())
                    Log.i("SystemStartCheck", "controlsPreparation entry=SERVICE_INTERFACE duplicates=2 " +
                        "session=$id phase=STARTING nativeSnapshotUnchanged=true")
                }
                "launcherWidget" -> {
                    val manager = android.appwidget.AppWidgetManager.getInstance(context)
                    val provider = android.content.ComponentName(context, VpnWidgetProvider::class.java)
                    fun assertOriginalWidget() {
                        assertTrue("Only the protected original widget 4 may exist",
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
                                assertTrue("One live Launcher viewport required", launcherViewport == null || launcherViewport == bounds)
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
                            assertTrue("Never choose among multiple own Launcher instances", hosts.size <= 1)
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
                                assertTrue("One original widget action required", controls.size <= 1)
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
                                    // After HOME, use the independently calibrated
                                    // adjacent-page gesture for this Launcher and
                                    // viewport.
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
                    assertTrue("Actual original Launcher widget must send Stop once", clicked)
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
                        assertTrue("Discard only this observer's cached accessibility nodes", ui.clearCache())
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
                            assertTrue("One visible public Quick Settings window required", qsWindows <= 1)
                            if (qsWindows == 1) {
                                // Compose's semantic label and actionable Tile are separate
                                // nodes. Match their live bounds, as in the SDK Tile observer.
                                val own = nodes.filter { it.contentDescription?.toString()?.startsWith("Clash Pseudo,") == true }
                                assertTrue("Never choose among multiple own Tiles", own.size <= 1)
                                val target = own.singleOrNull()?.let { label ->
                                    nodes.filter { it.viewIdResourceName in setOf("com.android.systemui:id/qs_tile_small",
                                        "com.android.systemui:id/qs_tile_large") && it.isEnabled && it.isClickable &&
                                        bounds(it) == bounds(label) }.also {
                                        assertTrue("One action wholly aligned with the own Tile required", it.size <= 1)
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
                                        assertEquals("Calibrated live-pager gesture must actually finish", "CONTROLLED_INPUT_EXIT=0", exit)
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
                    assertTrue("Actual own Quick Settings Tile must be clicked once", clicked)
                }
                "shortcut" -> {
                    val intent = SystemControls.actionIntent(context, "stop")
                    assertEquals(context.packageName + ".StopVpnShortcut", intent.component?.className)
                    shortcut = SystemControls.activityPendingIntent(context, intent, 57042)
                    // Both creator and sender opt in through public SDK APIs. The
                    // real alias Activity must consume the fixed Stop on post-resume.
                    val options = ActivityOptions.makeBasic()
                        .setPendingIntentBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
                        .toBundle()
                    checkNotNull(shortcut).send(context, 0, null, null, null, null, options)
                }
                "widgetSdk" -> {
                    val projected = java.util.concurrent.CompletableFuture<SystemControls.Projection>()
                    main { SystemControls.snapshot { projected.complete(it) } }
                    val projection = projected.get(15, TimeUnit.SECONDS)
                    assertEquals("STARTING", projection.phase)
                    assertEquals("stop", projection.action)
                    main {
                        // Inspect SDK RemoteViews through the existing widget
                        // projection.
                        val root = VpnWidgetProvider.remoteViews(context, projection, 160f).apply(context, null)
                        val button = checkNotNull(root.findViewById<ImageButton>(R.id.widget_control))
                        assertTrue(button.isEnabled)
                        assertEquals(context.getString(R.string.system_control_action_stop), button.contentDescription?.toString())
                        assertTrue(button.hasOnClickListeners())
                        assertTrue("SDK button must send its production broadcast PendingIntent", button.performClick())
                    }
                }
            }
            main {
                assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
                if (systemRevoke) {
                    Log.i("SystemStartCheck", "WAIT_REAL_SYSTEM_REVOKE nonce=p5-system-revoke-r7u8 " +
                        "pid=${Process.myPid()} session=$id phase=STARTING nativePrepared=false")
                } else if (revoke) checkNotNull(PseudoVpnService.instance).onRevoke()
                else if (controlsEntry == null || controlsEntry == "serviceInterface") {
                    context.startService(Intent(context, PseudoVpnService::class.java)
                        .setAction(PseudoVpnService.ACTION_STOP))
                } else Unit
            }
            if (systemRevoke) {
                // Before establish(), check the actual VPN grant independently of
                // onRevoke delivery.
                await("actual system grant withdrawal", 60_000) { VpnService.prepare(context) != null }
                Log.i("SystemStartCheck", "REAL_SYSTEM_REVOKE nonce=p5-system-revoke-r7u8 " +
                    "session=$id phase=${PseudoVpnService.session.snapshot().phase}")
                invalidatedBeforeRelease = !PseudoVpnService.session.canStart(id)
                release.countDown()
                barrier.get(10, TimeUnit.SECONDS)
                await("revoked startup rejects without a running session") {
                    val state = PseudoVpnService.session.snapshot()
                    assertNotEquals(NativeSession.Phase.RUNNING, state.phase)
                    assertNotEquals(NativeSession.Phase.UNKNOWN, state.phase)
                    state.generation == id && state.phase == NativeSession.Phase.STOPPED &&
                        PseudoVpnService.core.snapshot().phase == CoreHost.Phase.EMPTY &&
                        PseudoVpnService.instance == null
                }
                assertNotNull("Permission loss must have an explicit startup outcome", PseudoVpnService.session.snapshot().error)
            } else {
                await("cancellation invalidates STARTING before worker release") {
                    val state = PseudoVpnService.session.snapshot()
                    state.generation == id && state.phase == NativeSession.Phase.STOPPING
                }
                assertFalse(PseudoVpnService.session.canStart(id))
                invalidatedBeforeRelease = true
                if (controlsEntry != null) {
                    assertEquals("Preparation worker must still be held", 1L, release.count)
                    assertFalse("Preparation barrier must not have timed out", barrier.isDone)
                    main {
                        assertSame(startingService, PseudoVpnService.instance)
                        assertFalse(startingService.pendingSystemStart)
                        assertFalse(AppBridge.pendingSystemRestore)
                        when (controlsEntry) {
                            "shortcut" -> {
                                assertNotNull("PendingIntent must create a real MainActivity", controlsActivity)
                                assertEquals(context.packageName + ".StopVpnShortcut", activityComponent)
                                assertTrue("Real Activity must resume before Stop is admitted", activityResumed)
                            }
                            "widgetSdk", "tile", "launcherWidget" -> assertNull("Headless Stop must not fall back to an Activity", controlsActivity)
                            else -> Unit
                        }
                    }
                    assertEquals(nativeBefore, NativeCore.snapshot())
                    val source = when (controlsEntry) {
                        "shortcut" -> "StopVpnShortcut/PendingIntent.send/Activity.RESUMED"
                        "widgetSdk" -> "SDK-RemoteViews.apply/widget_control.performClick/production-Stop-broadcast"
                        "tile" -> "SystemUI/actual-own-Tile.ACTION_CLICK"
                        "launcherWidget" -> "Launcher/original-widget-4/widget_control.ACTION_CLICK"
                        else -> "SERVICE_INTERFACE-duplicates/Service-Stop"
                    }
                    Log.i("SystemStartCheck", "controlsPreparation nonce=p5-controls-preparation-r7x1 " +
                        "entry=$source session=$id transition=STARTING->STOPPING " +
                        "beforeWorkerRelease=true nativeSnapshotUnchanged=true")
                }
            }
            assertEquals(nativeBefore, NativeCore.snapshot())
        } finally {
            try {
                try {
                    if (requested) {
                        val needsStop = main {
                            val state = PseudoVpnService.session.snapshot()
                            state.generation == id && state.phase in setOf(
                                NativeSession.Phase.STARTING, NativeSession.Phase.RUNNING)
                        }
                        if (needsStop) {
                            // The success assertions precede this failure-cleanup
                            // path.
                            context.startService(Intent(context, PseudoVpnService::class.java)
                                .setAction(PseudoVpnService.ACTION_STOP))
                            await("failure cleanup cancels before releasing preparation") {
                                !PseudoVpnService.session.canStart(id)
                            }
                        }
                    }
                } finally {
                    release.countDown()
                    barrier.get(10, TimeUnit.SECONDS)
                }
                if (requested) {
                    await("actual Service destruction and native drain") {
                        PseudoVpnService.session.snapshot().phase == NativeSession.Phase.STOPPED &&
                            PseudoVpnService.core.snapshot().phase == CoreHost.Phase.EMPTY &&
                            PseudoVpnService.instance == null && !AppBridge.logic.busy && AppBridge.operationId == null
                    }
                    assertEquals(nativeBefore, NativeCore.snapshot())
                    if (systemRevoke) assertNotNull("The system must actually withdraw the grant", VpnService.prepare(context))
                    else assertNull("Cancellation must keep the OS grant", VpnService.prepare(context))
                }
            } finally {
                try {
                    shortcut?.cancel()
                    tileUi?.let { assertTrue(it.performGlobalAction(
                        android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_HOME)) }
                    if (observingActivity) {
                        main {
                            ActivityLifecycleMonitorRegistry.getInstance().removeLifecycleCallback(lifecycle)
                            controlsActivity?.finish()
                        }
                        await("test-created Activity destruction") { controlsActivity?.isDestroyed != false }
                    }
                    if (controlsEntry != null && requested) {
                        // Pass the bounded retry queue, then wait for the actual
                        // native work.
                        val retryPassed = FutureTask { Unit }
                        main { android.os.Handler(android.os.Looper.getMainLooper()).postDelayed(retryPassed, 150L) }
                        retryPassed.get(10, TimeUnit.SECONDS)
                        val drained = FutureTask { NativeCore.snapshot() }
                        PseudoVpnService.worker.execute(drained)
                        assertEquals(nativeBefore, drained.get(10, TimeUnit.SECONDS))
                        await("controls Service retirement and actual writer drain without late start") {
                            val state = PseudoVpnService.session.snapshot()
                            assertEquals("Cancellation must not admit a late generation", id, state.generation)
                            assertEquals(NativeSession.Phase.STOPPED, state.phase)
                            assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
                            assertNull(PseudoVpnService.instance)
                            !AppBridge.pendingSystemRestore && !AppBridge.logic.busy && AppBridge.operationId == null
                        }
                        assertNull("Controls must preserve the OS grant", VpnService.prepare(context))
                    }
                } finally {
                    if (expectedStores != null && expectedEpoch != null) {
                        assertStoresUnchanged(files, stores, expectedEpoch, expectedStores)
                    }
                }
            }
        }
        if (controlsEntry != null) Log.i("SystemStartCheck", "controlsPreparation nonce=p5-controls-preparation-r7x1 " +
            "entry=$controlsEntry session=$id noLateStart=true nativeSnapshotUnchanged=true " +
            "serviceDestroyed=true writerDrained=true storesUnchanged=true epoch=$expectedEpoch grantPreserved=true")
        Log.i("SystemStartCheck", "preparationCancel=true revokeCallback=$revoke systemRevoke=$systemRevoke " +
            "realStartingObserved=true invalidatedBeforeWorkerRelease=$invalidatedBeforeRelease " +
            "nativeSnapshotUnchanged=true serviceDestroyed=true")
    }

    @Test fun staleRestoreCompletionNeverTouchesAnotherServicesForegroundResources() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val before = PseudoVpnService.session.snapshot()
            assertEquals("Run this read-only case only after normal Stop", NativeSession.Phase.STOPPED, before.phase)
            val coreBefore = PseudoVpnService.core.snapshot()
            val actualService = PseudoVpnService.instance
            // This unattached Service object makes an unexpected stopForeground call
            // fail.
            val retired = PseudoVpnService()
            val requests = PseudoVpnService::class.java.getDeclaredField("systemStarts")
                .apply { isAccessible = true }.get(retired) as SystemStartRequest
            val finish = PseudoVpnService::class.java.getDeclaredMethod("finishSystemStart", Any::class.java,
                Long::class.javaPrimitiveType, NativeSession::class.java)
                .apply { isAccessible = true }
            val owner = requests.begin(1)!!
            finish.invoke(retired, owner, before.generation, PseudoVpnService.session)
            assertFalse(requests.pending())
            val cancelled = requests.begin(2)!!
            requests.cancel()
            val latest = requests.begin(3)!!
            finish.invoke(retired, cancelled, before.generation, PseudoVpnService.session)
            assertTrue(requests.current(latest))
            finish.invoke(retired, latest, before.generation + 1, PseudoVpnService.session)
            assertFalse(requests.pending())
            assertSame(actualService, PseudoVpnService.instance)
            assertEquals(coreBefore, PseudoVpnService.core.snapshot())
            val after = PseudoVpnService.session.snapshot()
            assertEquals(before.generation, after.generation)
            assertEquals(before.phase, after.phase)
            assertEquals(before.error, after.error)
        }
    }

    @Test fun systemAndStaleIntentsCannotTearDownThePendingRestore() {
        assumeTrue(PseudoVpnService.session.snapshot().phase == NativeSession.Phase.STOPPED)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            // Hold the preparation stage pending in the isolated test state.
            val service = PseudoVpnService()
            val requests = PseudoVpnService::class.java.getDeclaredField("systemStarts")
                .apply { isAccessible = true }.get(service) as SystemStartRequest
            val owner = requests.begin(1)!!
            assertEquals(Service.START_NOT_STICKY,
                service.onStartCommand(Intent(VpnService.SERVICE_INTERFACE), 0, 2))
            assertEquals(Service.START_NOT_STICKY, service.onStartCommand(null, 0, 3))
            // Unowned late starts and unknown actions leave this unattached Service
            // unchanged.
            service.onStartCommand(Intent(PseudoVpnService.ACTION_START), 0, 4)
            service.onStartCommand(Intent("unrecognized"), 0, 5)
            assertTrue(requests.current(owner))
            assertEquals(5, requests.finish(owner))
        }
    }
}
