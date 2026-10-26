package io.github.monadboxlab.clashpseudo.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.SystemClock
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.work.WorkInfo
import androidx.work.WorkManager
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import io.github.monadboxlab.clashpseudo.nativecore.VpnSpecification
import io.github.monadboxlab.clashpseudo.schedule.ScheduleManager
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** The controller restores the official SAF fixture and waits for the host's
 * worker-download-start before broadcasting. Downloads and Store publication
 * belong exclusively to the production Dart executor and ScheduleWorker.
 */
class ScheduleWorkerCancellationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    @Test fun ownedWorkCancellationKeepsWriterGateUntilRealDartDrain() {
        val nonce = requireNotNull(InstrumentationRegistry.getArguments().getString("nonce"))
        require(nonce in listOf("p5-load-worker-r7w5", "p5-load-worker-r7w9"))
        cancelOwnedWork(nonce, "CANCEL_WORK_" + nonce.removePrefix("p5-load-worker-").uppercase())
        awaitControllerExport(nonce, kindArgument())
    }

    @Test fun ownedWorkerUpdateReconnectsTheActuallyRunningInput() {
        ownedRunningWork("p5-load-worker-r7w8r4", null)
    }

    @Test fun ownedScheduledRevokeInvalidatesBeforeMainCleanup() {
        val nonce = "p5-load-worker-r7w10"
        assertEquals("This revoke regression uses only the config policy", "config", kindArgument())
        val context = instrumentation.targetContext.applicationContext
        val action = context.packageName + ".validation.REVOKE_WORK_R7W10"
        val signal = CountDownLatch(1)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action == action && intent.getStringExtra("nonce") == nonce &&
                    intent.getStringExtra("kind") == "config") signal.countDown()
            }
        }
        context.registerReceiver(receiver, IntentFilter(action), Context.RECEIVER_EXPORTED)
        try {
            ownedRunningWork(nonce, signal)
        } finally {
            context.unregisterReceiver(receiver)
        }
    }

    @Test fun ownedScheduledStartingCancellationStopsBeforePrepare() {
        assertEquals("This STARTING regression uses only the config policy", "config", kindArgument())
        ownedRunningWork("p5-load-worker-r7w12", null, cancelStarting = true)
    }

    // Running entries share only the existing real startup/background/Worker flow.
    private fun ownedRunningWork(nonce: String, revokeSignal: CountDownLatch?, cancelStarting: Boolean = false) {
        val cancelledId = cancelOwnedWork(nonce,
            "CANCEL_WORK_" + nonce.removePrefix("p5-load-worker-").uppercase())
        val kind = kindArgument()
        val context = instrumentation.targetContext.applicationContext
        val id = if (kind == "config") "p5-worker-config-$nonce" else "p5-worker-plugin-$nonce"
        val unique = "update-$kind-$id"
        val manager = WorkManager.getInstance(context)
        assertEquals(WorkInfo.State.CANCELLED,
            manager.getWorkInfoById(cancelledId).get(10, TimeUnit.SECONDS)?.state)

        // Only read the controlled Stores after cancellation and real writer drain.
        val directory = AppFiles.configs(context)
        val configs = JSONObject(directory.resolve("configurations.json").readText(Charsets.UTF_8))
        val overrides = JSONObject(directory.resolve("overrides.json").readText(Charsets.UTF_8))
        val configEntries = configs.getJSONArray("entries").let { entries ->
            (0 until entries.length()).map { entries.getJSONObject(it) }
        }
        val pluginEntries = overrides.getJSONArray("entries").let { entries ->
            (0 until entries.length()).map { entries.getJSONObject(it) }
        }
        val selectedId = if (kind == "config") id else "p5-worker-local-$nonce"
        assertEquals(selectedId, configs.getString("selectedId"))
        val selected = configEntries.single { it.getString("id") == selectedId }
        val plugin = pluginEntries.single { it.getString("id") == "p5-worker-plugin-$nonce" }
        assertEquals(1, selected.getInt("revision"))
        val body1 = selected.getString("body")
        val marker1 = "# Controlled, local-only fixture $nonce revision 1\n"
        assertTrue("Cancelled download must leave the initial config body", body1.startsWith(marker1))
        assertEquals(1, plugin.getInt("revision"))
        assertEquals("# Controlled plugin $nonce revision 1\nrules: ['DOMAIN,controlled.$nonce.test,REJECT']\n",
            plugin.getString("body"))
        assertEquals(kind == "override", plugin.getBoolean("enabled"))
        val enabledTargets = listOf("config" to configEntries, "override" to pluginEntries).flatMap { (targetKind, entries) ->
            entries.filter { it.getJSONObject("update").getBoolean("enabled") }.map { entry ->
                assertEquals(6, entry.getJSONObject("update").getInt("hours"))
                targetKind to entry.getString("id")
            }
        }
        assertEquals("Fixture must enable only the requested periodic target", listOf(kind to id), enabledTargets)

        var requestedStart = false
        var replacementId: UUID? = null
        val startingEntered = CountDownLatch(1)
        val startingRelease = CountDownLatch(1)
        val startingQueued = AtomicBoolean(false)
        val startingBarrier = if (!cancelStarting) null else FutureTask {
            startingEntered.countDown()
            check(startingRelease.await(30, TimeUnit.SECONDS)) { "STARTING barrier was not released" }
        }
        var previousChanged: (() -> Unit)? = null
        try {
            var firstGeneration = -1L
            main {
                assertNull("VPN grant must already exist; never open authorization UI", VpnService.prepare(context))
                assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
                assertNull("A prior Service must have fully stopped", PseudoVpnService.instance)
                assertFalse(AppBridge.logic.busy)
                assertNull(AppBridge.operationId)
                firstGeneration = PseudoVpnService.session.snapshot().generation + 1
            }
            requestedStart = true
            assertNotNull(context.startForegroundService(
                Intent(context, PseudoVpnService::class.java).setAction(VpnService.SERVICE_INTERFACE)))
            val before = runningInput(firstGeneration)
            assertInput(before, selected, plugin.takeIf { kind == "override" })
            val actualChoices = selectorChoices()
            assertEquals(setOf("Controlled", "GLOBAL"), actualChoices.keys)
            Log.i("PseudoWorkerTest",
                "OWNED_WORK_RUNNING_INPUT nonce=$nonce kind=$kind session=${before.session.generation} core=${before.core.generation} revision=1 attached=true")

            lateinit var uiActivity: MainActivity
            main {
                uiActivity = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                    .filterIsInstance<MainActivity>().single()
            }
            context.startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            awaitBackground(uiActivity)
            Log.i("PseudoWorkerTest",
                "OWNED_WORK_BACKGROUND nonce=$nonce kind=$kind mainActivityVisible=false")
            if (cancelStarting) main {
                val session = PseudoVpnService.session
                synchronized(session) {
                    val original = session.changed
                    previousChanged = original
                    session.changed = {
                        original()
                        val current = session.snapshot()
                        if (current.generation == before.session.generation + 1 &&
                            current.phase == NativeSession.Phase.STARTING && startingQueued.compareAndSet(false, true)) {
                            // begin() calls changed synchronously; startNative is queued only after it returns.
                            PseudoVpnService.worker.execute(checkNotNull(startingBarrier))
                        }
                    }
                }
            }
            val preservedStores = if (revokeSignal == null && !cancelStarting) null else
                listOf("configurations.json", "overrides.json", "preferences.json")
                    .associateWith { directory.resolve(it).readBytes() }
            val synced = CountDownLatch(1)
            ScheduleManager.sync(context, listOf(mapOf("kind" to kind, "id" to id, "hours" to 6))) {
                synced.countDown()
            }
            assertTrue("Production schedule sync did not complete", synced.await(10, TimeUnit.SECONDS))
            val replacements = manager.getWorkInfosForUniqueWork(unique).get(10, TimeUnit.SECONDS)
                .filter { !it.state.isFinished }
            assertEquals("UPDATE must create one live replacement", 1, replacements.size)
            val replacement = replacements.single()
            assertNotEquals("Cancelled periodic work must not be reused", cancelledId, replacement.id)
            assertTrue(replacement.tags.contains(ScheduleWorker::class.java.name))
            replacementId = replacement.id
            await("replacement ScheduleWorker executing its real download", 30_000) {
                val info = checkNotNull(manager.getWorkInfoById(replacement.id).get(10, TimeUnit.SECONDS))
                assertFalse("Replacement finished before its real download was observed", info.state.isFinished)
                var executing = false
                main {
                    val command = AppBridge.command
                    executing = info.state == WorkInfo.State.RUNNING && command != null &&
                        command["action"] == "refreshSchedule" && command["kind"] == kind && command["id"] == id
                    if (executing) {
                        assertNotNull(AppBridge.operationId)
                        assertTrue(AppBridge.logic.busy)
                        val state = AppBridge.runtimeState()
                        assertEquals(true, state["scheduleBusy"])
                        assertEquals(true, state["writerBusy"])
                        assertEquals("RUNNING", state["phase"])
                        assertEquals(before.session.generation, PseudoVpnService.session.snapshot().generation)
                        assertEquals(before.core, PseudoVpnService.core.snapshot())
                    }
                }
                executing
            }
            Log.i("PseudoWorkerTest", "OWNED_WORK_REENQUEUED nonce=$nonce kind=$kind uuid=${replacement.id}")

            if (cancelStarting) {
                Log.i("PseudoWorkerTest", "WAIT_OWNED_WORK_STARTING nonce=$nonce kind=$kind")
                assertTrue("Scheduled reconnect did not reach its real STARTING barrier",
                    startingEntered.await(90, TimeUnit.SECONDS))
                await("network Worker completed its application handoff", 10_000) {
                    val info = checkNotNull(manager.getWorkInfoById(replacement.id).get(10, TimeUnit.SECONDS))
                    assertFalse(info.state.isFinished)
                    info.state == WorkInfo.State.ENQUEUED
                }
                cancelStartingWork(context, nonce, id, before, checkNotNull(preservedStores),
                    startingRelease, checkNotNull(startingBarrier))
            } else if (revokeSignal != null) {
                awaitBackground(uiActivity)
                revokeRunningWork(context, nonce, kind, id, before, checkNotNull(preservedStores), revokeSignal)
            } else {
                val after = runningInput(before.session.generation + 1)
                assertTrue("Automatic application must prepare a new core", after.core.generation > before.core.generation)
                assertNotEquals(before.core.composition, after.core.composition)
                val expectedConfig = JSONObject(selected.toString())
                val expectedPlugin = if (kind == "override") JSONObject(plugin.toString()) else null
                if (kind == "config") {
                    expectedConfig.put("revision", 2).put("body",
                        body1.replaceFirst(marker1, "# Controlled, local-only fixture $nonce revision 2\n"))
                } else {
                    expectedPlugin!!.put("revision", 2).put("body",
                        "# Controlled plugin $nonce revision 2\nrules: ['DOMAIN,changed.$nonce.test,REJECT']\n")
                }
                assertInput(after, expectedConfig, expectedPlugin)
                // Only the content identity changes; validate the complete newly loaded specification.
                assertEquals(before.specification.copy(generation = after.core.generation,
                    composition = checkNotNull(after.core.composition)), after.specification)
                for (key in listOf("name", "mode", "source", "routingOverride", "access", "packages")) {
                    assertEquals("Unchanged running input field $key", before.input.get(key).toString(), after.input.get(key).toString())
                }
                // Reconnect carries the actual selectors captured after startup.
                val carriedChoices = after.input.getJSONObject("choices")
                assertEquals(actualChoices.keys, carriedChoices.keys().asSequence().toSet())
                for ((name, member) in actualChoices) {
                    val carried = carriedChoices.getJSONObject(name)
                    assertEquals("select", carried.getString("type"))
                    assertEquals(member, carried.getString("member"))
                }
                assertEquals(actualChoices, selectorChoices())
                await("periodic Worker completion after automatic application", 10_000) {
                    val info = checkNotNull(manager.getWorkInfoById(replacement.id).get(10, TimeUnit.SECONDS))
                    assertFalse(info.state.isFinished)
                    info.state == WorkInfo.State.ENQUEUED
                }
                main {
                    assertEquals(NativeSession.Phase.RUNNING, PseudoVpnService.session.snapshot().phase)
                    assertEquals(before.session.generation + 1, PseudoVpnService.session.snapshot().generation)
                    assertEquals(after.core, PseudoVpnService.core.snapshot())
                    assertEquals(false, AppBridge.runtimeState()["writerBusy"])
                }
                val savedEntries = JSONObject(directory.resolve(
                    if (kind == "config") "configurations.json" else "overrides.json").readText(Charsets.UTF_8))
                    .getJSONArray("entries")
                val savedTarget = (0 until savedEntries.length()).map { savedEntries.getJSONObject(it) }
                    .single { it.getString("id") == id }
                assertEquals(2, savedTarget.getInt("revision"))
                assertEquals("applied", savedTarget.getJSONObject("update").getString("lastResult"))
                assertFalse(savedTarget.getJSONObject("update").isNull("lastAttempt"))
                awaitBackground(uiActivity)
                Log.i("PseudoWorkerTest",
                    "OWNED_WORK_APPLIED nonce=$nonce kind=$kind uuid=${replacement.id} session=${after.session.generation} core=${after.core.generation} revision=2 lastResult=applied writerBusy=false attached=true reconnects=1 uiBackground=true")
            }
        } finally {
            try {
                startingRelease.countDown()
                try {
                    previousChanged?.let { original ->
                        main {
                            synchronized(PseudoVpnService.session) { PseudoVpnService.session.changed = original }
                        }
                    }
                } finally {
                    if (startingQueued.get()) checkNotNull(startingBarrier).get(10, TimeUnit.SECONDS)
                }
            } finally {
                try {
                    if (requestedStart) {
                        var live = false
                        main {
                            live = PseudoVpnService.instance != null ||
                                PseudoVpnService.session.snapshot().phase != NativeSession.Phase.STOPPED
                        }
                        if (live) stopAndDrain(context)
                    }
                } finally {
                    replacementId?.let { uuid ->
                        try {
                            manager.cancelWorkById(uuid).result.get(10, TimeUnit.SECONDS)
                        } finally {
                            awaitWriterDrain("replacement Worker cleanup")
                        }
                    }
                }
            }
        }
        Log.i("PseudoWorkerTest", "OWNED_WORK_STOPPED nonce=$nonce kind=$kind phase=STOPPED core=EMPTY attached=false writerBusy=false")
        awaitControllerExport(nonce, kind)
    }

    private fun cancelStartingWork(context: Context, nonce: String, id: String, before: Loaded,
                                   beforeStores: Map<String, ByteArray>, release: CountDownLatch,
                                   barrier: FutureTask<Unit>) {
        val generation = before.session.generation + 1
        assertFalse("Native startup barrier must still be held", barrier.isDone)
        nativeEmpty() // Read directly: submitting a worker read here would wait behind the barrier.
        val files = AppFiles.configs(context)
        val committed = files.resolve("configurations.json").readBytes()
        val configs = JSONObject(committed.toString(Charsets.UTF_8))
        assertEquals(id, configs.getString("selectedId"))
        val entries = configs.getJSONArray("entries")
        val saved = (0 until entries.length()).map { entries.getJSONObject(it) }
            .single { it.getString("id") == id }
        assertEquals("The real second download must already be saved", 2, saved.getInt("revision"))
        assertEquals(before.input.getString("body").replaceFirst(
            "# Controlled, local-only fixture $nonce revision 1\n",
            "# Controlled, local-only fixture $nonce revision 2\n"), saved.getString("body"))
        assertEquals("updated", saved.getJSONObject("update").getString("lastResult"))
        assertFalse(saved.getJSONObject("update").isNull("lastAttempt"))
        main {
            val service = checkNotNull(PseudoVpnService.instance)
            val session = PseudoVpnService.session.snapshot()
            assertEquals(generation, session.generation)
            assertEquals(NativeSession.Phase.STARTING, session.phase)
            assertEquals(id, session.configId)
            assertEquals(2, session.revision)
            assertEquals(before.core.generation, PseudoVpnService.core.snapshot().generation)
            assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
            assertNotNull(AppBridge.operationId)
            assertEquals("refreshSchedule", AppBridge.command?.get("action"))
            assertEquals("config", AppBridge.command?.get("kind"))
            assertEquals(id, AppBridge.command?.get("id"))
            assertEquals(true, AppBridge.runtimeState()["scheduleBusy"])
            assertTrue(AppBridge.logic.busy)
            // Exercise scheduled-owner cancellation directly.
            assertTrue(AppBridge.cancelScheduledOperation())
            assertNull(AppBridge.operationId)
            assertNull(AppBridge.command)
            assertEquals(generation, PseudoVpnService.session.snapshot().generation)
            assertEquals("Scheduled cancellation must stop its captured STARTING session synchronously",
                NativeSession.Phase.STOPPING, PseudoVpnService.session.snapshot().phase)
            assertSame(service, PseudoVpnService.instance)
            assertEquals(before.core.generation, PseudoVpnService.core.snapshot().generation)
            assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
            assertEquals(false, AppBridge.runtimeState()["scheduleBusy"])
            assertEquals(true, AppBridge.runtimeState()["writerBusy"])
            assertTrue("Real Dart execution must retain its drain gate", AppBridge.logic.busy)
            assertEquals(1L, release.count)
            assertFalse(barrier.isDone)
        }
        nativeEmpty()
        Log.i("PseudoWorkerTest",
            "OWNED_WORK_STARTING_CANCELLED nonce=$nonce kind=config session=$generation phase=STOPPING operationId=null writerBusy=true barrierHeld=true prepared=false attached=false")
        release.countDown()
        barrier.get(10, TimeUnit.SECONDS)
        await("cancelled STARTING Service/native and actual Dart drain", 35_000) {
            var drained = false
            main {
                val session = PseudoVpnService.session.snapshot()
                val core = PseudoVpnService.core.snapshot()
                assertEquals(generation, session.generation)
                assertTrue("Cancelled startup must never attach late",
                    session.phase == NativeSession.Phase.STOPPING || session.phase == NativeSession.Phase.STOPPED)
                assertEquals("Cancelled startup must not prepare another core", before.core.generation, core.generation)
                assertEquals(CoreHost.Phase.EMPTY, core.phase)
                assertNull(AppBridge.operationId)
                assertNull(AppBridge.command)
                val state = AppBridge.runtimeState()
                assertEquals(false, state["scheduleBusy"])
                assertEquals(false, state["pendingStart"])
                assertEquals(false, state["pendingSystemStart"])
                drained = session.phase == NativeSession.Phase.STOPPED && PseudoVpnService.instance == null &&
                    state["writerBusy"] == false && !AppBridge.logic.busy
            }
            drained
        }
        worker { Unit }
        nativeEmpty()
        assertArrayEquals("Cancellation must retain the committed revision 2 without claiming applied",
            committed, files.resolve("configurations.json").readBytes())
        for (name in listOf("overrides.json", "preferences.json")) {
            assertArrayEquals("STARTING cancellation changed $name", checkNotNull(beforeStores[name]),
                files.resolve(name).readBytes())
        }
        main { stopped(AppBridge.runtimeState(), generation, before.core.generation) }
        Log.i("PseudoWorkerTest",
            "OWNED_WORK_STARTING_DRAIN nonce=$nonce kind=config session=$generation phase=STOPPED core=EMPTY revision=2 lastResult=updated writerBusy=false noLateAttach=true otherStoresUnchanged=true")
    }

    /** Invoke onRevoke on the actual Service to test callback handling. */
    private fun revokeRunningWork(context: Context, nonce: String, kind: String, id: String,
                                  before: Loaded, beforeStores: Map<String, ByteArray>, signal: CountDownLatch) {
        Log.i("PseudoWorkerTest", "WAIT_OWNED_WORK_REVOKE nonce=$nonce kind=$kind")
        assertTrue("No matching second-download revoke signal within 90 seconds",
            signal.await(90, TimeUnit.SECONDS))
        main {
            val service = checkNotNull(PseudoVpnService.instance)
            val owner = checkNotNull(AppBridge.operationId)
            val command = AppBridge.command
            assertEquals("refreshSchedule", command?.get("action"))
            assertEquals(kind, command?.get("kind"))
            assertEquals(id, command?.get("id"))
            assertEquals(NativeSession.Phase.RUNNING, PseudoVpnService.session.snapshot().phase)
            assertEquals(before.session.generation, PseudoVpnService.session.snapshot().generation)
            assertEquals(before.core, PseudoVpnService.core.snapshot())
            assertEquals(true, AppBridge.runtimeState()["scheduleBusy"])
            assertTrue("The second real Dart download must still be in flight", AppBridge.logic.busy)
            val failure = AtomicReference<Throwable?>()
            val callback = Thread({
                try {
                    service.onRevoke()
                } catch (error: Throwable) {
                    failure.set(error)
                }
            }, "PseudoWorkerRevoke")
            callback.start()
            callback.join(2_000)
            failure.get()?.let { throw it }
            assertFalse("Non-main onRevoke must not wait for main cleanup", callback.isAlive)
            // Assert synchronous withdrawal while the main queue remains held.
            assertNull("Revocation must synchronously withdraw scheduled publication authority", AppBridge.operationId)
            assertTrue("Authority withdrawal must retain the actual Dart writer", AppBridge.logic.busy)
            assertEquals(true, AppBridge.runtimeState()["writerBusy"])
            assertSame(service, PseudoVpnService.instance)
            assertEquals(before.session.generation, PseudoVpnService.session.snapshot().generation)
            assertEquals(before.core.generation, PseudoVpnService.core.snapshot().generation)
            Log.i("PseudoWorkerTest",
                "OWNED_WORK_REVOKED_SYNC nonce=$nonce kind=$kind owner=$owner operationId=null dartBusy=true writerBusy=true mainQueueHeld=true directServiceCallback=true")
        }
        await("revoked Service/native exit and actual late Dart I/O drain", 35_000) {
            var drained = false
            main {
                val session = PseudoVpnService.session.snapshot()
                val core = PseudoVpnService.core.snapshot()
                assertEquals("Revoked download must not restart VPN", before.session.generation, session.generation)
                assertEquals("Revoked download must not prepare another core", before.core.generation, core.generation)
                assertTrue(session.phase == NativeSession.Phase.STOPPING || session.phase == NativeSession.Phase.STOPPED)
                assertNotEquals(CoreHost.Phase.FAILED, core.phase)
                assertNull(AppBridge.operationId)
                val state = AppBridge.runtimeState()
                assertEquals(false, state["pendingStart"])
                assertEquals(false, state["pendingSystemStart"])
                drained = session.phase == NativeSession.Phase.STOPPED && core.phase == CoreHost.Phase.EMPTY &&
                    PseudoVpnService.instance == null && state["scheduleBusy"] == false &&
                    state["writerBusy"] == false && !AppBridge.logic.busy
                if (drained) assertNull(AppBridge.command)
            }
            drained
        }
        worker { Unit }
        nativeEmpty()
        val files = AppFiles.configs(context)
        for ((name, bytes) in beforeStores) {
            assertArrayEquals("Revoked late download changed $name", bytes, files.resolve(name).readBytes())
        }
        main {
            stopped(AppBridge.runtimeState(), before.session.generation, before.core.generation)
            assertNull(PseudoVpnService.instance)
            assertFalse(AppBridge.logic.busy)
            assertNull("Direct callback must leave the existing SDK grant intact", VpnService.prepare(context))
        }
        Log.i("PseudoWorkerTest",
            "OWNED_WORK_REVOKE_DRAIN nonce=$nonce kind=$kind phase=STOPPED core=EMPTY writerBusy=false storedFilesUnchanged=true noNewPrepareOrAttach=true directServiceCallback=true sdkGrantIntact=true")
    }

    private fun awaitControllerExport(nonce: String, kind: String) {
        val context = instrumentation.targetContext.applicationContext
        val action = context.packageName + ".validation.EXPORT_WORK_" + nonce.removePrefix("p5-load-worker-").uppercase()
        val exported = CountDownLatch(1)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action == action && intent.getStringExtra("nonce") == nonce &&
                    intent.getStringExtra("kind") == kind) exported.countDown()
            }
        }
        context.registerReceiver(receiver, IntentFilter(action), Context.RECEIVER_EXPORTED)
        try {
            // Snapshot before runner teardown and startup reconciliation of
            // this still-enabled saved policy can admit another real check.
            Log.i("PseudoWorkerTest", "WAIT_OWNED_WORK_EXPORT nonce=$nonce kind=$kind")
            assertTrue("No formal export confirmation within 120 seconds", exported.await(120, TimeUnit.SECONDS))
        } finally {
            context.unregisterReceiver(receiver)
        }
    }

    private fun selectorChoices(): Map<String, String> = worker {
        val groups = JSONObject(NativeCore.strategies()).getJSONArray("groups")
        (0 until groups.length()).associate { index ->
            val group = groups.getJSONObject(index)
            assertEquals("The controlled fixture has only select groups", "select", group.getString("type"))
            val member = group.getString("now")
            assertTrue(member.isNotEmpty())
            group.getString("name") to member
        }
    }

    private fun awaitBackground(activity: MainActivity) {
        await("actual stopped UI Activity", 10_000) {
            var hidden = false
            main {
                val monitor = ActivityLifecycleMonitorRegistry.getInstance()
                val visible = listOf(Stage.STARTED, Stage.RESUMED, Stage.PAUSED, Stage.RESTARTED)
                    .any { stage -> monitor.getActivitiesInStage(stage).any { it is MainActivity } }
                hidden = !visible && (activity.isDestroyed || monitor.getActivitiesInStage(Stage.STOPPED).contains(activity))
            }
            hidden
        }
    }

    private fun kindArgument(): String {
        val kind = requireNotNull(InstrumentationRegistry.getArguments().getString("kind")) {
            "Pass kind=config or kind=override"
        }
        require(kind == "config" || kind == "override") { "Pass kind=config or kind=override" }
        return kind
    }

    private fun cancelOwnedWork(nonce: String, signalSuffix: String): UUID {
        val arguments = InstrumentationRegistry.getArguments()
        assertEquals("Pass the fixed instrumentation nonce", nonce, arguments.getString("nonce"))
        val kind = kindArgument()
        val context = instrumentation.targetContext.applicationContext
        val action = context.packageName + ".validation." + signalSuffix
        val signal = CountDownLatch(1)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action == action && intent.getStringExtra("nonce") == nonce &&
                    intent.getStringExtra("kind") == kind) signal.countDown()
            }
        }
        context.registerReceiver(receiver, IntentFilter(action), Context.RECEIVER_EXPORTED)
        var ownedWorkId: UUID? = null
        try {
            // Verify the UI remains usable before controlled Store creation.
            main {
                assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
            }
            Log.i("PseudoWorkerTest", "WAIT_OWNED_WORK_CANCEL nonce=$nonce kind=$kind")
            assertTrue("No matching controller signal within 90 seconds",
                signal.await(90, TimeUnit.SECONDS))

            val id = if (kind == "config") "p5-worker-config-$nonce" else "p5-worker-plugin-$nonce"
            val unique = "update-$kind-$id"
            val manager = WorkManager.getInstance(context)
            val infos = manager.getWorkInfosForUniqueWork(unique).get(10, TimeUnit.SECONDS)
            assertEquals("Expected exactly one WorkInfo for $unique", 1, infos.size)
            val work = infos.single()
            assertEquals(WorkInfo.State.RUNNING, work.state)
            assertTrue("Expected the production ScheduleWorker", work.tags.contains(ScheduleWorker::class.java.name))
            // Unique name and the production Worker tag establish cleanup ownership.
            ownedWorkId = work.id
            var owner: String? = null
            var sessionGeneration = -1L
            var coreGeneration = -1L
            main {
                val command = AppBridge.command
                assertEquals("refreshSchedule", command?.get("action"))
                assertEquals(kind, command?.get("kind"))
                assertEquals(id, command?.get("id"))
                owner = AppBridge.operationId
                assertNotNull("The real scheduled operation must own the writer", owner)
                val state = AppBridge.runtimeState()
                assertEquals(true, state["scheduleBusy"])
                assertEquals(true, state["writerBusy"])
                assertTrue("Expected real Dart execution in flight", AppBridge.logic.busy)
                assertEquals("STOPPED", state["phase"])
                sessionGeneration = PseudoVpnService.session.snapshot().generation
                coreGeneration = PseudoVpnService.core.snapshot().generation
                assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
            }

            val files = AppFiles.configs(context)
            val beforeStores = listOf("configurations.json", "overrides.json", "preferences.json")
                .associateWith { files.resolve(it).readBytes() }
            manager.cancelWorkById(work.id).result.get(10, TimeUnit.SECONDS)
            assertEquals(WorkInfo.State.CANCELLED,
                manager.getWorkInfoById(work.id).get(10, TimeUnit.SECONDS)?.state)
            Log.i("PseudoWorkerTest",
                "OWNED_WORK_CANCELLED nonce=$nonce kind=$kind uuid=${work.id} owner=$owner state=CANCELLED")

            await("cancelled schedule owner with retained real writer", 10_000) {
                var cancelled = false
                main {
                    val state = AppBridge.runtimeState()
                    stopped(state, sessionGeneration, coreGeneration)
                    assertEquals("Cancellation must not release a still-running Dart writer", true, state["writerBusy"])
                    assertTrue("Actual Dart execute must still be in flight", AppBridge.logic.busy)
                    assertTrue("An unrelated owner replaced the cancelled operation",
                        AppBridge.operationId == null || AppBridge.operationId == owner)
                    cancelled = state["scheduleBusy"] == false && AppBridge.operationId == null
                    if (cancelled) assertNull(AppBridge.command)
                }
                cancelled
            }
            nativeEmpty()
            Log.i("PseudoWorkerTest",
                "OWNED_WORK_GATE nonce=$nonce kind=$kind scheduleBusy=false writerBusy=true phase=STOPPED operationId=null dartBusy=true")

            await("actual Dart writer drain", 35_000) {
                var drained = false
                main {
                    val state = AppBridge.runtimeState()
                    stopped(state, sessionGeneration, coreGeneration)
                    assertEquals(false, state["scheduleBusy"])
                    assertNull(AppBridge.operationId)
                    assertNull(AppBridge.command)
                    drained = state["writerBusy"] == false
                    if (drained) assertFalse(AppBridge.logic.busy)
                }
                drained
            }
            nativeEmpty()
            for ((name, bytes) in beforeStores) {
                assertArrayEquals("Cancelled download changed $name", bytes, files.resolve(name).readBytes())
            }
            val after = manager.getWorkInfosForUniqueWork(unique).get(10, TimeUnit.SECONDS)
            assertEquals("Cancellation must not enqueue a replacement", listOf(work.id), after.map { it.id })
            assertEquals(WorkInfo.State.CANCELLED, after.single().state)
            Log.i("PseudoWorkerTest",
                "OWNED_WORK_DRAIN nonce=$nonce kind=$kind uuid=${work.id} scheduleBusy=false writerBusy=false phase=STOPPED core=EMPTY prepared=false attached=false noRestart=true storedFilesUnchanged=true")
            return work.id
        } finally {
            try {
                context.unregisterReceiver(receiver)
            } finally {
                ownedWorkId?.let { uuid ->
                    try {
                        WorkManager.getInstance(context).cancelWorkById(uuid).result.get(10, TimeUnit.SECONDS)
                    } finally {
                        awaitWriterDrain("owned work cleanup and actual writer drain")
                    }
                }
            }
        }
    }

    private data class Loaded(
        val session: NativeSession.Snapshot,
        val core: CoreHost.Snapshot,
        val input: JSONObject,
        val specification: VpnSpecification,
    )

    private fun runningInput(expectedGeneration: Long): Loaded {
        lateinit var session: NativeSession.Snapshot
        lateinit var core: CoreHost.Snapshot
        await("VPN generation $expectedGeneration RUNNING and actual writer drain", 90_000) {
            var ready = false
            main {
                val current = PseudoVpnService.session.snapshot()
                val loaded = PseudoVpnService.core.snapshot()
                assertTrue("Unexpected extra VPN restart", current.generation <= expectedGeneration)
                assertNotEquals(NativeSession.Phase.UNKNOWN, current.phase)
                assertNotEquals(CoreHost.Phase.FAILED, loaded.phase)
                if (current.generation == expectedGeneration && current.phase == NativeSession.Phase.STOPPED) {
                    current.error?.let { fail("VPN startup failed: ${it.id}") }
                }
                val state = AppBridge.runtimeState()
                ready = current.generation == expectedGeneration && current.phase == NativeSession.Phase.RUNNING &&
                    loaded.phase == CoreHost.Phase.READY && loaded.purpose == CoreHost.Purpose.VPN &&
                    state["writerBusy"] == false && state["scheduleBusy"] == false &&
                    state["pendingSystemStart"] == false && state["pendingStart"] == false &&
                    !AppBridge.logic.busy && AppBridge.operationId == null
                if (ready) { session = current; core = loaded }
            }
            ready
        }
        val composition = checkNotNull(core.composition)
        val (input, native, specification) = worker {
            val bytes = checkNotNull(PseudoVpnService.core.runningInput(core.generation, composition))
            Triple(JSONObject(bytes.toString(Charsets.UTF_8)), JSONObject(NativeCore.snapshot()),
                VpnSpecification.read(NativeCore.vpnSpec()))
        }
        assertEquals(composition, input.getString("composition"))
        assertEquals(core.generation, specification.generation)
        assertEquals(composition, specification.composition)
        assertTrue(native.getBoolean("prepared"))
        assertTrue(native.getBoolean("attached"))
        assertFalse(native.getBoolean("cleanupFailed"))
        main {
            assertEquals(NativeSession.Phase.RUNNING, PseudoVpnService.session.snapshot().phase)
            assertEquals(expectedGeneration, PseudoVpnService.session.snapshot().generation)
            assertEquals(core, PseudoVpnService.core.snapshot())
            assertNotNull(PseudoVpnService.instance)
            assertNull(AppBridge.operationId)
            assertFalse(AppBridge.logic.busy)
        }
        return Loaded(session, core, input, specification)
    }

    private fun assertInput(loaded: Loaded, config: JSONObject, plugin: JSONObject?) {
        val id = config.getString("id")
        val revision = config.getInt("revision")
        assertEquals(id, loaded.session.configId)
        assertEquals(revision, loaded.session.revision)
        assertEquals(id, loaded.core.configId)
        assertEquals(revision, loaded.core.revision)
        for (key in listOf("id", "name", "revision", "body")) {
            assertEquals("Actual loaded config field $key", config.get(key), loaded.input.get(key))
        }
        val parts = loaded.input.getJSONArray("overrides")
        assertEquals(if (plugin == null) 0 else 1, parts.length())
        if (plugin != null) {
            val part = parts.getJSONObject(0)
            for (key in listOf("id", "name", "mode", "role", "revision", "body")) {
                assertEquals("Actual loaded plugin field $key", plugin.get(key), part.get(key))
            }
        }
    }

    private fun stopAndDrain(context: Context) {
        context.startService(Intent(context, PseudoVpnService::class.java).setAction(PseudoVpnService.ACTION_STOP))
        await("normal Service/native Stop and actual business drain", 35_000) {
            var stopped = false
            main {
                val session = PseudoVpnService.session.snapshot()
                val core = PseudoVpnService.core.snapshot()
                assertNotEquals(NativeSession.Phase.UNKNOWN, session.phase)
                assertNotEquals(CoreHost.Phase.FAILED, core.phase)
                val state = AppBridge.runtimeState()
                stopped = session.phase == NativeSession.Phase.STOPPED && core.phase == CoreHost.Phase.EMPTY &&
                    PseudoVpnService.instance == null && state["writerBusy"] == false &&
                    state["scheduleBusy"] == false && state["pendingSystemStart"] == false &&
                    !AppBridge.logic.busy && AppBridge.operationId == null
            }
            stopped
        }
        worker { Unit }
        nativeEmpty()
    }

    private fun awaitWriterDrain(label: String) {
        await(label, 35_000) {
            var drained = false
            main {
                val state = AppBridge.runtimeState()
                drained = state["scheduleBusy"] == false && state["writerBusy"] == false &&
                    !AppBridge.logic.busy && AppBridge.operationId == null
            }
            drained
        }
    }

    private fun <T> worker(block: () -> T): T {
        val task = FutureTask(block)
        PseudoVpnService.worker.execute(task)
        return task.get(10, TimeUnit.SECONDS)
    }

    private fun stopped(state: Map<String, Any?>, sessionGeneration: Long, coreGeneration: Long) {
        assertEquals("STOPPED", state["phase"])
        assertEquals(sessionGeneration, PseudoVpnService.session.snapshot().generation)
        val core = PseudoVpnService.core.snapshot()
        assertEquals(CoreHost.Phase.EMPTY, core.phase)
        assertEquals("Cancelled execution must not prepare/restart a core", coreGeneration, core.generation)
        assertEquals(false, state["pendingStart"])
        assertEquals(false, state["pendingSystemStart"])
    }

    private fun nativeEmpty() {
        val native = JSONObject(NativeCore.snapshot())
        assertFalse(native.getBoolean("prepared"))
        assertFalse(native.getBoolean("attached"))
    }

    private fun main(block: () -> Unit) = instrumentation.runOnMainSync(block)

    private fun await(label: String, timeoutMs: Long, ready: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (!ready()) {
            check(SystemClock.elapsedRealtime() < deadline) { "Timed out waiting for $label" }
            Thread.sleep(25)
        }
    }
}
