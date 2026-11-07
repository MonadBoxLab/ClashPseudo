package io.github.monadboxlab.clashpseudo.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.work.WorkInfo
import androidx.work.WorkManager
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.controls.SystemControls
import io.github.monadboxlab.clashpseudo.debug.CoreFixtureContract as Fixture
import io.github.monadboxlab.clashpseudo.nativecore.CoreClient
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CoreLifecycleRecord
import io.github.monadboxlab.clashpseudo.nativecore.CorePlatformTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CorePreparationObserver
import io.github.monadboxlab.clashpseudo.nativecore.CoreResourceGate
import io.github.monadboxlab.clashpseudo.nativecore.CoreService
import io.github.monadboxlab.clashpseudo.nativecore.vpn.VpnSpecification
import io.github.monadboxlab.clashpseudo.schedule.ScheduleManager
import io.github.monadboxlab.clashpseudo.storage.AppFiles
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** The controller restores the fixture through SAF and broadcasts when the actual download starts; the single AppRuntime downloads and saves it. */
class ScheduleWorkerCancellationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext.applicationContext
    private val client get() = CoreClient.get(context)
    private val platform = CorePlatformTestDriver()

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
        assertEquals("Revoke regression uses only the config policy", "config", kindArgument())
        val action = context.packageName + ".validation.REVOKE_WORK_R7W10"
        val signal = CountDownLatch(1)
        val receiver = signalReceiver(action, nonce, "config", signal)
        registerReceiver(receiver, action)
        try { ownedRunningWork(nonce, signal) }
        finally { context.unregisterReceiver(receiver) }
    }

    @Test fun ownedScheduledStartingCancellationStopsBeforePrepare() {
        assertEquals("STARTING regression uses only the config policy", "config", kindArgument())
        ownedRunningWork("p5-load-worker-r7w12", null, cancelStarting = true)
    }

    private fun ownedRunningWork(nonce: String, revokeSignal: CountDownLatch?, cancelStarting: Boolean = false) {
        val cancelledId = cancelOwnedWork(nonce,
            "CANCEL_WORK_" + nonce.removePrefix("p5-load-worker-").uppercase())
        val kind = kindArgument()
        val id = if (kind == "config") "p5-worker-config-$nonce" else "p5-worker-plugin-$nonce"
        val unique = "update-$kind-$id"
        val manager = WorkManager.getInstance(context)
        assertEquals(WorkInfo.State.CANCELLED, manager.getWorkInfoById(cancelledId).get(10, TimeUnit.SECONDS)?.state)

        // Read the stores prepared by the controller only after the actual Dart writer exits.
        val directory = AppFiles.configs(context)
        val configs = JSONObject(directory.resolve("configurations.json").readText(Charsets.UTF_8))
        val overrides = JSONObject(directory.resolve("overrides.json").readText(Charsets.UTF_8))
        val configEntries = entries(configs)
        val pluginEntries = entries(overrides)
        val selectedId = if (kind == "config") id else "p5-worker-local-$nonce"
        assertEquals(selectedId, configs.getString("selectedId"))
        val selected = configEntries.single { it.getString("id") == selectedId }
        val plugin = pluginEntries.single { it.getString("id") == "p5-worker-plugin-$nonce" }
        assertEquals(1, selected.getInt("revision"))
        val body1 = selected.getString("body")
        val marker1 = "# Controlled, local-only fixture $nonce revision 1\n"
        assertTrue("Cancelling the download must preserve the initial config body", body1.startsWith(marker1))
        assertEquals(1, plugin.getInt("revision"))
        assertEquals("# Controlled plugin $nonce revision 1\nrules: ['DOMAIN,controlled.$nonce.test,REJECT']\n", plugin.getString("body"))
        assertEquals(kind == "override", plugin.getBoolean("enabled"))
        val enabledTargets = listOf("config" to configEntries, "override" to pluginEntries).flatMap { (targetKind, values) ->
            values.filter { it.getJSONObject("update").getBoolean("enabled") }.map { entry ->
                assertEquals(6, entry.getJSONObject("update").getInt("hours"))
                targetKind to entry.getString("id")
            }
        }
        assertEquals("Fixture must enable only the specified periodic target", listOf(kind to id), enabledTargets)

        var requestedStart = false
        var replacementId: UUID? = null
        var gateArmed = false
        val observers = mutableListOf<CoreIpcTestDriver>()
        var failure: Throwable? = null
        try {
            main {
                assertNull("VPN permission must already be granted; do not open the authorization UI", VpnService.prepare(context))
                assertEquals("STOPPED", AppBridge.runtimeState()["phase"])
                assertFalse(AppBridge.logic.busy)
                assertNull(AppBridge.operationId)
            }
            nativeEmpty()
            requestedStart = true
            val start = Intent(context, PseudoVpnService::class.java).setAction(VpnService.SERVICE_INTERFACE)
            assertNotNull(if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(start) else context.startService(start))
            val before = runningInput(selectedId, 1).also { observers.add(it.observer) }
            assertInput(before, selected, plugin.takeIf { kind == "override" })
            val actualChoices = selectorChoices()
            assertEquals(setOf("Controlled", "GLOBAL"), actualChoices.keys)
            Log.i("PseudoWorkerTest", "OWNED_WORK_RUNNING_INPUT nonce=$nonce kind=$kind process=${before.processId} input=${before.inputId} generation=1 revision=1 attached=true")

            lateinit var uiActivity: MainActivity
            main {
                uiActivity = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                    .filterIsInstance<MainActivity>().single()
            }
            context.startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            awaitBackground(uiActivity)
            Log.i("PseudoWorkerTest", "OWNED_WORK_BACKGROUND nonce=$nonce kind=$kind mainActivityVisible=false")
            if (cancelStarting) {
                CorePreparationObserver.armWorkerGate(context)
                gateArmed = true
            }
            val preservedStores = if (revokeSignal == null && !cancelStarting) null else businessFiles()
            val synced = CountDownLatch(1)
            ScheduleManager.sync(context, listOf(mapOf("kind" to kind, "id" to id, "hours" to 6))) { synced.countDown() }
            assertTrue("Production schedule sync did not finish", synced.await(10, TimeUnit.SECONDS))
            val replacements = manager.getWorkInfosForUniqueWork(unique).get(10, TimeUnit.SECONDS).filter { !it.state.isFinished }
            assertEquals("UPDATE must create one live replacement", 1, replacements.size)
            val replacement = replacements.single()
            assertNotEquals("Cancelled periodic work must not be reused", cancelledId, replacement.id)
            assertTrue(replacement.tags.contains(ScheduleWorker::class.java.name))
            replacementId = replacement.id
            await("Replacement ScheduleWorker performs the actual download", 30_000) {
                val info = checkNotNull(manager.getWorkInfoById(replacement.id).get(10, TimeUnit.SECONDS))
                assertFalse("Replacement finished before the actual download was observed", info.state.isFinished)
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
                        assertSameInput(before)
                    }
                }
                executing
            }
            Log.i("PseudoWorkerTest", "OWNED_WORK_REENQUEUED nonce=$nonce kind=$kind uuid=${replacement.id}")

            if (cancelStarting) {
                Log.i("PseudoWorkerTest", "WAIT_OWNED_WORK_STARTING nonce=$nonce kind=$kind")
                await("Scheduled reconnect enters the gate before the actual PREPARE", 90_000) {
                    CorePreparationObserver.workerGateState(context) != null
                }
                before.observer.awaitDeath()
                assertTrue(before.observer.deathConfirmed)
                await("Network Worker completes the application handoff", 10_000) {
                    val info = checkNotNull(manager.getWorkInfoById(replacement.id).get(10, TimeUnit.SECONDS))
                    assertFalse(info.state.isFinished)
                    info.state == WorkInfo.State.ENQUEUED
                }
                val starting = CoreIpcTestDriver.fixture().also(observers::add)
                cancelStartingWork(nonce, id, before, checkNotNull(preservedStores), starting)
            } else if (revokeSignal != null) {
                awaitBackground(uiActivity)
                revokeRunningWork(nonce, kind, id, before, checkNotNull(preservedStores), revokeSignal)
            } else {
                val after = runningInput(selectedId, if (kind == "config") 2 else 1, before).also { observers.add(it.observer) }
                before.observer.awaitDeath()
                assertTrue("Reconnect must confirm the original core Binder death", before.observer.deathConfirmed)
                assertNotEquals("Automatic apply must use a new core process", before.processId, after.processId)
                assertNotEquals("Automatic apply must use a new run-input", before.inputId, after.inputId)
                assertNotEquals(before.composition, after.composition)
                val expectedConfig = JSONObject(selected.toString())
                val expectedPlugin = if (kind == "override") JSONObject(plugin.toString()) else null
                if (kind == "config") {
                    expectedConfig.put("revision", 2).put("body", body1.replaceFirst(marker1,
                        "# Controlled, local-only fixture $nonce revision 2\n"))
                } else {
                    expectedPlugin!!.put("revision", 2).put("body",
                        "# Controlled plugin $nonce revision 2\nrules: ['DOMAIN,changed.$nonce.test,REJECT']\n")
                }
                assertInput(after, expectedConfig, expectedPlugin)
                assertEquals(before.specification.copy(generation = after.generation, composition = after.composition), after.specification)
                for (key in listOf("name", "mode", "source", "routingOverride", "access", "packages")) {
                    assertEquals("Unchanged actual input field $key", before.input.get(key).toString(), after.input.get(key).toString())
                }
                val carriedChoices = after.input.getJSONObject("choices")
                assertEquals(actualChoices.keys, carriedChoices.keys().asSequence().toSet())
                for ((name, member) in actualChoices) {
                    val carried = carriedChoices.getJSONObject(name)
                    assertEquals("select", carried.getString("type"))
                    assertEquals(member, carried.getString("member"))
                }
                assertEquals(actualChoices, selectorChoices())
                await("Periodic Worker finishes after automatic apply", 10_000) {
                    val info = checkNotNull(manager.getWorkInfoById(replacement.id).get(10, TimeUnit.SECONDS))
                    assertFalse(info.state.isFinished)
                    info.state == WorkInfo.State.ENQUEUED
                }
                main {
                    assertEquals("RUNNING", AppBridge.runtimeState()["phase"])
                    assertSameInput(after)
                    assertEquals(false, AppBridge.runtimeState()["writerBusy"])
                }
                val saved = entries(JSONObject(directory.resolve(if (kind == "config") "configurations.json" else "overrides.json")
                    .readText(Charsets.UTF_8))).single { it.getString("id") == id }
                assertEquals(2, saved.getInt("revision"))
                assertEquals("applied", saved.getJSONObject("update").getString("lastResult"))
                assertFalse(saved.getJSONObject("update").isNull("lastAttempt"))
                awaitBackground(uiActivity)
                Log.i("PseudoWorkerTest", "OWNED_WORK_APPLIED nonce=$nonce kind=$kind uuid=${replacement.id} process=${after.processId} input=${after.inputId} generation=1 revision=2 lastResult=applied writerBusy=false attached=true reconnects=1 uiBackground=true")
            }
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            fun cleanup(action: () -> Unit) {
                try { action() }
                catch (error: Throwable) { if (failure == null) failure = error else if (failure !== error) failure!!.addSuppressed(error) }
            }
            cleanup { if (gateArmed) CorePreparationObserver.releaseWorkerGate(context) }
            cleanup {
                if (requestedStart && client.status()["phase"] !in setOf(Contract.CORE_PHASE_DISCONNECTED, Contract.CORE_PHASE_EXITED)) stopAndDrain()
            }
            cleanup {
                replacementId?.let { manager.cancelWorkById(it).result.get(10, TimeUnit.SECONDS) }
                awaitWriterDrain("Replacement Worker cleanup")
            }
            observers.forEach { observer -> cleanup { observer.close() } }
            cleanup { if (gateArmed) CorePreparationObserver.removeWorkerGate(context) }
            failure?.let { throw it }
        }
        Log.i("PseudoWorkerTest", "OWNED_WORK_STOPPED nonce=$nonce kind=$kind phase=STOPPED core=EMPTY attached=false writerBusy=false")
        awaitControllerExport(nonce, kind)
    }

    private fun cancelStartingWork(nonce: String, id: String, before: Loaded, beforeStores: Map<String, ByteArray>,
                                   starting: CoreIpcTestDriver) {
        val gate = checkNotNull(CorePreparationObserver.workerGateState(context))
        assertNotEquals(before.processId, gate.getString("processId"))
        assertNotEquals(before.inputId, gate.getString("inputId"))
        assertEquals(starting.processId, gate.getString("processId"))
        assertEquals(starting.pid, gate.getInt("pid"))
        assertNotEquals(android.os.Process.myPid(), starting.pid)
        assertEquals(1L, gate.getLong("generation"))
        assertTrue(gate.getLong("requestId") > 0)
        assertFalse(gate.getBoolean("released"))
        assertFalse(gate.getBoolean("finished"))
        val current = client.status()
        assertEquals(Contract.CORE_PHASE_LOADING, current["phase"])
        assertEquals(id, current["configId"])
        assertEquals(2, (current["revision"] as Number).toInt())
        assertEquals(gate.getString("inputId"), current["inputId"])
        val native = query(Contract.CORE_OPERATION_SNAPSHOT)
        assertFalse(native.getBoolean("prepared"))
        assertFalse(native.getBoolean("attached"))
        val files = AppFiles.configs(context)
        val committed = files.resolve("configurations.json").readBytes()
        val configs = JSONObject(committed.toString(Charsets.UTF_8))
        assertEquals(id, configs.getString("selectedId"))
        val saved = entries(configs).single { it.getString("id") == id }
        assertEquals("The second actual download must already be saved", 2, saved.getInt("revision"))
        assertEquals(before.input.getString("body").replaceFirst("# Controlled, local-only fixture $nonce revision 1\n",
            "# Controlled, local-only fixture $nonce revision 2\n"), saved.getString("body"))
        assertEquals("updated", saved.getJSONObject("update").getString("lastResult"))
        assertFalse(saved.getJSONObject("update").isNull("lastAttempt"))
        val staged = platform.runRecord(current)
        assertEquals(gate.getString("inputId"), staged.getString("inputId"))
        assertEquals(saved.getString("body"), staged.getString("body"))
        assertEquals(2, staged.getInt("revision"))
        main {
            val state = AppBridge.runtimeState()
            assertEquals("STARTING", state["phase"])
            assertEquals(id, state["configId"])
            assertEquals(2, state["revision"])
            assertNotNull(AppBridge.operationId)
            assertEquals("refreshSchedule", AppBridge.command?.get("action"))
            assertEquals("config", AppBridge.command?.get("kind"))
            assertEquals(id, AppBridge.command?.get("id"))
            assertEquals(true, state["scheduleBusy"])
            assertTrue(AppBridge.logic.busy)
            assertTrue(AppBridge.cancelScheduledOperation())
            assertNull(AppBridge.operationId)
            assertNull(AppBridge.command)
            assertEquals(false, AppBridge.runtimeState()["scheduleBusy"])
            assertEquals(true, AppBridge.runtimeState()["writerBusy"])
            assertTrue("Cancellation does not mean the actual Dart executor has exited", AppBridge.logic.busy)
        }
        Log.i("PseudoWorkerTest", "OWNED_WORK_STARTING_CANCELLED nonce=$nonce kind=config process=${starting.processId} operationId=null writerBusy=true prepared=false attached=false")
        await("PREPARE gate receives actual cancellation and invocation returns", 10_000) {
            checkNotNull(CorePreparationObserver.workerGateState(context)).let { it.getBoolean("cancelObserved") && it.getBoolean("finished") }
        }
        CorePreparationObserver.releaseWorkerGate(context)
        starting.awaitDeath()
        assertTrue(starting.deathConfirmed)
        await("Actual core/FD and Dart writer drain after cancelling STARTING", 35_000) {
            val status = client.status()
            assertEquals("Cancellation must not replace the core", starting.processId, status["processId"])
            assertEquals(gate.getString("inputId"), status["inputId"])
            assertNotEquals(Contract.CORE_PHASE_READY, status["phase"])
            var drained = false
            main {
                val state = AppBridge.runtimeState()
                assertTrue(state["phase"] in setOf("STARTING", "STOPPING", "STOPPED"))
                assertNull(AppBridge.operationId)
                assertNull(AppBridge.command)
                assertEquals(false, state["scheduleBusy"])
                assertEquals(false, state["pendingStart"])
                assertEquals(false, state["pendingSystemStart"])
                drained = state["phase"] == "STOPPED" && state["writerBusy"] == false && !AppBridge.logic.busy &&
                    status["phase"] == Contract.CORE_PHASE_EXITED
            }
            drained
        }
        assertEquals("stop", client.lifecycle.snapshot().exitReason)
        assertFalse("Explicit cancellation must not require failure recovery", client.lifecycle.snapshot().recoveryRequired)
        nativeEmpty()
        assertArrayEquals("Preserve revision 2; cancellation must not be recorded as applied", committed, files.resolve("configurations.json").readBytes())
        for (name in listOf("overrides.json", "preferences.json")) {
            assertArrayEquals("STARTING cancellation changed $name", checkNotNull(beforeStores[name]), files.resolve(name).readBytes())
        }
        main { assertEquals("STOPPED", AppBridge.runtimeState()["phase"]) }
        Log.i("PseudoWorkerTest", "OWNED_WORK_STARTING_DRAIN nonce=$nonce kind=config process=${starting.processId} phase=STOPPED core=EMPTY revision=2 lastResult=updated writerBusy=false noLateAttach=true otherStoresUnchanged=true")
    }

    private fun revokeRunningWork(nonce: String, kind: String, id: String, before: Loaded,
                                  beforeStores: Map<String, ByteArray>, signal: CountDownLatch) {
        Log.i("PseudoWorkerTest", "WAIT_OWNED_WORK_REVOKE nonce=$nonce kind=$kind")
        assertTrue("Revoke signal for the second download was not received within 90 seconds", signal.await(90, TimeUnit.SECONDS))
        var owner: String? = null
        var admittedAt: Long? = null
        var deadline: Long? = null
        main {
            owner = checkNotNull(AppBridge.operationId)
            admittedAt = checkNotNull(AppBridge.operationAdmittedAt)
            deadline = checkNotNull(AppBridge.operationDeadline)
            assertEquals("refreshSchedule", AppBridge.command?.get("action"))
            assertEquals(kind, AppBridge.command?.get("kind"))
            assertEquals(id, AppBridge.command?.get("id"))
            assertEquals("RUNNING", AppBridge.runtimeState()["phase"])
            assertSameInput(before)
            assertEquals(true, AppBridge.runtimeState()["scheduleBusy"])
            assertTrue("The second actual Dart download must still be running", AppBridge.logic.busy)
        }
        val beforeRecords = runRecords()
        val callback = before.observer.debug.serviceControl(Fixture.REVOKE_SERVICE_OFF_MAIN)
        assertEquals(before.processId, callback.getString("processId"))
        assertEquals(before.observer.pid, callback.getInt("pid"))
        assertTrue(callback.getBoolean("callbackOffMain"))
        assertTrue(callback.getBoolean("callbackReturned"))
        assertTrue("The original TUN FD must close before onRevoke returns", callback.getBoolean("originalDescriptorClosed"))
        assertTrue(callback.getBoolean("descriptorWithdrawn"))
        assertTrue("Revoke callback must not affect a replacement Service", callback.getBoolean("sameServiceOrDestroyed"))
        await("Actual revoked event revokes scheduled publication authority", 10_000) {
            var withdrawn = false
            main {
                assertTrue("onRevoke must not mark a running download as exited", AppBridge.logic.busy)
                assertEquals(true, AppBridge.runtimeState()["writerBusy"])
                withdrawn = AppBridge.operationId == null && AppBridge.runtimeState()["scheduleBusy"] == false
                if (withdrawn) assertNull(AppBridge.command)
                else if (AppBridge.command?.get("action") == "systemRevoked") {
                    assertNotEquals(owner, AppBridge.operationId)
                    assertEquals(owner, AppBridge.command?.get("revokedOwner"))
                    assertEquals(admittedAt, AppBridge.operationAdmittedAt)
                    assertEquals(deadline, AppBridge.operationDeadline)
                    assertEquals(before.processId, AppBridge.command?.get("processId"))
                    assertEquals(before.inputId, AppBridge.command?.get("inputId"))
                    assertEquals(false, AppBridge.runtimeState()["scheduleBusy"])
                    assertFalse("Revoke without LAN must not queue another Dart execute", AppBridge.logic.ownsOperation(checkNotNull(AppBridge.operationId)))
                } else assertEquals(owner, AppBridge.operationId)
            }
            withdrawn
        }
        Log.i("PseudoWorkerTest", "OWNED_WORK_REVOKED_SYNC nonce=$nonce kind=$kind owner=$owner process=${before.processId} operationId=null dartBusy=true writerBusy=true directServiceCallback=true originalDescriptorClosed=true")
        before.observer.awaitDeath()
        assertTrue(before.observer.deathConfirmed)
        await("Actual core exit and late Dart I/O drain after revoke", 35_000) {
            assertEquals("A revoked download must not restart the core", before.processId, client.status()["processId"])
            assertEquals("A revoked download must not publish new run input", before.inputId, client.status()["inputId"])
            var drained = false
            main {
                val state = AppBridge.runtimeState()
                assertTrue(state["phase"] in setOf("STOPPING", "STOPPED"))
                assertNull(AppBridge.operationId)
                assertEquals(false, state["pendingStart"])
                assertEquals(false, state["pendingSystemStart"])
                drained = state["phase"] == "STOPPED" && client.status()["phase"] == Contract.CORE_PHASE_EXITED &&
                    state["scheduleBusy"] == false && state["writerBusy"] == false && !AppBridge.logic.busy
                if (drained) assertNull(AppBridge.command)
            }
            drained
        }
        nativeEmpty()
        for ((name, bytes) in beforeStores) assertArrayEquals("A late download changed $name after revoke", bytes, AppFiles.configs(context).resolve(name).readBytes())
        assertEquals("revoked", client.lifecycle.snapshot().exitReason)
        assertEquals("A revoked download must not publish another run record", beforeRecords, runRecords())
        main {
            assertEquals("STOPPED", AppBridge.runtimeState()["phase"])
            assertFalse(AppBridge.logic.busy)
            assertNull("A direct callback must not revoke the existing SDK grant", VpnService.prepare(context))
        }
        Log.i("PseudoWorkerTest", "OWNED_WORK_REVOKE_DRAIN nonce=$nonce kind=$kind phase=STOPPED core=EMPTY writerBusy=false storedFilesUnchanged=true noNewPrepareOrAttach=true directServiceCallback=true sdkGrantIntact=true")
    }

    private fun cancelOwnedWork(nonce: String, signalSuffix: String): UUID {
        assertEquals("The fixed instrumentation nonce is required", nonce, InstrumentationRegistry.getArguments().getString("nonce"))
        val kind = kindArgument()
        val action = context.packageName + ".validation." + signalSuffix
        val signal = CountDownLatch(1)
        val receiver = signalReceiver(action, nonce, kind, signal)
        registerReceiver(receiver, action)
        var ownedWorkId: UUID? = null
        try {
            main { assertEquals("STOPPED", AppBridge.runtimeState()["phase"]) }
            Log.i("PseudoWorkerTest", "WAIT_OWNED_WORK_CANCEL nonce=$nonce kind=$kind")
            assertTrue("The matching controller signal was not received within 90 seconds", signal.await(90, TimeUnit.SECONDS))
            val id = if (kind == "config") "p5-worker-config-$nonce" else "p5-worker-plugin-$nonce"
            val unique = "update-$kind-$id"
            val manager = WorkManager.getInstance(context)
            val infos = manager.getWorkInfosForUniqueWork(unique).get(10, TimeUnit.SECONDS)
            assertEquals("$unique must have exactly one WorkInfo", 1, infos.size)
            val work = infos.single()
            assertEquals(WorkInfo.State.RUNNING, work.state)
            assertTrue("Must be the production ScheduleWorker", work.tags.contains(ScheduleWorker::class.java.name))
            ownedWorkId = work.id
            var owner: String? = null
            val stoppedInput = StoppedInput(identity(client.status()), client.lifecycle.snapshot(), runRecords())
            main {
                assertEquals("refreshSchedule", AppBridge.command?.get("action"))
                assertEquals(kind, AppBridge.command?.get("kind"))
                assertEquals(id, AppBridge.command?.get("id"))
                owner = AppBridge.operationId
                assertNotNull("The actual scheduled operation must hold the writer", owner)
                val state = AppBridge.runtimeState()
                assertEquals(true, state["scheduleBusy"])
                assertEquals(true, state["writerBusy"])
                assertTrue("The actual Dart execution must still be running", AppBridge.logic.busy)
                stopped(state, stoppedInput)
            }
            nativeEmpty()
            val beforeStores = businessFiles()
            manager.cancelWorkById(work.id).result.get(10, TimeUnit.SECONDS)
            assertEquals(WorkInfo.State.CANCELLED, manager.getWorkInfoById(work.id).get(10, TimeUnit.SECONDS)?.state)
            Log.i("PseudoWorkerTest", "OWNED_WORK_CANCELLED nonce=$nonce kind=$kind uuid=${work.id} owner=$owner state=CANCELLED")
            await("Retain the actual writer after cancelling the schedule owner", 10_000) {
                var cancelled = false
                main {
                    val state = AppBridge.runtimeState()
                    stopped(state, stoppedInput)
                    assertEquals("Cancellation must not release a Dart writer that has not exited", true, state["writerBusy"])
                    assertTrue("The actual Dart execute must still be running", AppBridge.logic.busy)
                    assertTrue("Another owner replaced the cancelled operation", AppBridge.operationId == null || AppBridge.operationId == owner)
                    cancelled = state["scheduleBusy"] == false && AppBridge.operationId == null
                    if (cancelled) assertNull(AppBridge.command)
                }
                cancelled
            }
            nativeEmpty()
            Log.i("PseudoWorkerTest", "OWNED_WORK_GATE nonce=$nonce kind=$kind scheduleBusy=false writerBusy=true phase=STOPPED operationId=null dartBusy=true")
            await("Actual Dart writer drain", 35_000) {
                var drained = false
                main {
                    val state = AppBridge.runtimeState()
                    stopped(state, stoppedInput)
                    assertEquals(false, state["scheduleBusy"])
                    assertNull(AppBridge.operationId)
                    assertNull(AppBridge.command)
                    drained = state["writerBusy"] == false
                    if (drained) assertFalse(AppBridge.logic.busy)
                }
                drained
            }
            nativeEmpty()
            assertEquals("Cancelling the download must not create a new immutable run record", stoppedInput.records, runRecords())
            for ((name, bytes) in beforeStores) assertArrayEquals("Cancelling the download changed $name", bytes, AppFiles.configs(context).resolve(name).readBytes())
            val after = manager.getWorkInfosForUniqueWork(unique).get(10, TimeUnit.SECONDS)
            assertEquals("Cancellation must not automatically enqueue a replacement", listOf(work.id), after.map { it.id })
            assertEquals(WorkInfo.State.CANCELLED, after.single().state)
            Log.i("PseudoWorkerTest", "OWNED_WORK_DRAIN nonce=$nonce kind=$kind uuid=${work.id} scheduleBusy=false writerBusy=false phase=STOPPED core=EMPTY prepared=false attached=false noRestart=true storedFilesUnchanged=true")
            return work.id
        } finally {
            try { context.unregisterReceiver(receiver) }
            finally {
                ownedWorkId?.let { uuid ->
                    try { WorkManager.getInstance(context).cancelWorkById(uuid).result.get(10, TimeUnit.SECONDS) }
                    finally { awaitWriterDrain("Owned work cleanup and actual writer drain") }
                }
            }
        }
    }

    private data class Loaded(val status: Map<String, Any?>, val input: JSONObject,
                              val specification: VpnSpecification, val observer: CoreIpcTestDriver) {
        val processId get() = status["processId"] as String
        val inputId get() = status["inputId"] as String
        val generation get() = (status["generation"] as Number).toLong()
        val composition get() = status["composition"] as String
    }
    private data class StoppedInput(val identity: Map<String, Any?>, val lifecycle: CoreLifecycleRecord.State,
                                    val records: Map<String, String>)

    private fun runningInput(configId: String, revision: Int, previous: Loaded? = null): Loaded {
        var candidate: String? = null
        await("Actual VPN run input $configId revision=$revision and writer drain", 90_000) {
            val loaded = client.status()
            val process = loaded["processId"] as? String
            if (process != null && process != previous?.processId &&
                loaded["phase"] in setOf(Contract.CORE_PHASE_LOADING, Contract.CORE_PHASE_READY)) {
                if (candidate == null) candidate = process else assertEquals("An additional core restart occurred", candidate, process)
            }
            assertNotEquals(Contract.CORE_PHASE_COMMUNICATION_LOST, loaded["phase"])
            if (loaded["phase"] == Contract.CORE_PHASE_RECOVERY_REQUIRED) fail("VPN startup failed: ${loaded["error"]}")
            var ready = false
            main {
                val state = AppBridge.runtimeState()
                assertNotEquals("UNKNOWN", state["phase"])
                ready = state["phase"] == "RUNNING" && loaded["phase"] == Contract.CORE_PHASE_READY &&
                    loaded["purpose"] == Contract.CORE_PURPOSE_RUNNING && loaded["vpnRunning"] == true &&
                    loaded["configId"] == configId && (loaded["revision"] as? Number)?.toInt() == revision &&
                    (previous == null || process != previous.processId) &&
                    state["writerBusy"] == false && state["scheduleBusy"] == false && state["pendingSystemStart"] == false &&
                    state["pendingStart"] == false && !AppBridge.logic.busy && AppBridge.operationId == null
            }
            ready
        }
        val loaded = client.status()
        assertEquals(1L, (loaded["generation"] as Number).toLong())
        val observer = CoreIpcTestDriver.fixture()
        try {
            assertEquals(loaded["processId"], observer.processId)
            assertEquals((loaded["pid"] as Number).toInt(), observer.pid)
            assertNotEquals(android.os.Process.myPid(), observer.pid)
            val input = platform.runRecord(loaded)
            assertEquals(loaded["inputId"], input.getString("inputId"))
            assertEquals(loaded["composition"], input.getString("composition"))
            val specification = VpnSpecification.read(query(Contract.CORE_OPERATION_VPN_SPEC).toString())
            assertEquals(1L, specification.generation)
            assertEquals(input.getString("composition"), specification.composition)
            val native = query(Contract.CORE_OPERATION_SNAPSHOT)
            assertTrue(native.getBoolean("prepared"))
            assertTrue(native.getBoolean("attached"))
            assertFalse(native.getBoolean("cleanupFailed"))
            assertEquals(loaded["processId"], client.lifecycle.snapshot().processId)
            assertEquals(loaded["inputId"], client.lifecycle.snapshot().inputId)
            assertEquals("running", client.lifecycle.snapshot().stage)
            assertTrue(CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java))
            main {
                assertEquals("RUNNING", AppBridge.runtimeState()["phase"])
                assertEquals(identity(loaded), identity(client.status()))
                assertNull(AppBridge.operationId)
                assertFalse(AppBridge.logic.busy)
            }
            CoreIpcTestDriver.assertNoGoInApplication()
            return Loaded(loaded, input, specification, observer)
        } catch (error: Throwable) {
            try { observer.close() } catch (cleanup: Throwable) { if (cleanup !== error) error.addSuppressed(cleanup) }
            throw error
        }
    }

    private fun assertInput(loaded: Loaded, config: JSONObject, plugin: JSONObject?) {
        val id = config.getString("id")
        val revision = config.getInt("revision")
        assertEquals(id, loaded.status["configId"])
        assertEquals(revision, (loaded.status["revision"] as Number).toInt())
        main {
            assertEquals(id, AppBridge.runtimeState()["configId"])
            assertEquals(revision, AppBridge.runtimeState()["revision"])
        }
        for (key in listOf("id", "name", "revision", "body")) assertEquals("Actually loaded config field $key", config.get(key), loaded.input.get(key))
        val parts = loaded.input.getJSONArray("overrides")
        assertEquals(if (plugin == null) 0 else 1, parts.length())
        if (plugin != null) for (key in listOf("id", "name", "mode", "role", "revision", "body")) {
            assertEquals("Actually loaded plugin field $key", plugin.get(key), parts.getJSONObject(0).get(key))
        }
    }

    private fun selectorChoices(): Map<String, String> {
        val reply = platform.query(Contract.CORE_OPERATION_STRATEGIES)
        assertTrue(reply.terminal.toString(), reply.terminal.getBoolean("complete"))
        assertEquals(reply.records.size, reply.terminal.getInt("recordCount"))
        val source = reply.terminal.getString("source")
        assertTrue(source.isNotEmpty())
        assertEquals(source, reply.metadata.single().getString("source"))
        return reply.records.associate { group ->
            val raw = group.getJSONObject("raw")
            assertEquals("The controlled fixture runtime type must be Selector", "Selector", raw.getString("type"))
            val member = raw.getString("now")
            assertTrue(member.isNotEmpty())
            group.getString("name") to member
        }
    }

    private fun query(operation: Int): JSONObject = platform.query(operation).let { reply ->
        assertTrue(reply.terminal.toString(), reply.terminal.getBoolean("complete"))
        reply.value
    }

    private fun stopAndDrain() {
        val admission = platform.stopFromSystemControl()
        assertTrue("SystemControls must admit Stop", admission in setOf(SystemControls.Admission.ACCEPTED, SystemControls.Admission.UNCHANGED))
        await("Actual core/FD and application drain after normal Stop", 35_000) {
            var drained = false
            main {
                val state = AppBridge.runtimeState()
                assertNotEquals("UNKNOWN", state["phase"])
                assertNotEquals(Contract.CORE_PHASE_COMMUNICATION_LOST, client.status()["phase"])
                drained = state["phase"] == "STOPPED" && client.status()["phase"] == Contract.CORE_PHASE_EXITED &&
                    state["writerBusy"] == false && state["scheduleBusy"] == false && state["pendingSystemStart"] == false &&
                    !AppBridge.logic.busy && AppBridge.operationId == null
            }
            drained
        }
        nativeEmpty()
    }

    private fun stopped(state: Map<String, Any?>, before: StoppedInput) {
        assertEquals("STOPPED", state["phase"])
        assertEquals("Cancellation must not prepare or restart the core", before.identity, identity(client.status()))
        assertEquals(before.lifecycle, client.lifecycle.snapshot())
        assertEquals(false, state["pendingStart"])
        assertEquals(false, state["pendingSystemStart"])
    }

    private fun nativeEmpty() {
        CoreIpcTestDriver.assertNoGoInApplication()
        assertTrue("Inspection must not start the core when no context exists", client.status()["phase"] in
            setOf(null, Contract.CORE_PHASE_DISCONNECTED, Contract.CORE_PHASE_EXITED))
        assertFalse(CoreIpcTestDriver.servicePresent(context, PseudoVpnService::class.java))
        assertFalse(CoreIpcTestDriver.servicePresent(context, CoreService::class.java))
        val held = CoreResourceGate.forApplication(context).tryAcquire()
        assertNotNull("The resource lock must not be released before core process exit", held)
        held!!.close()
    }

    private fun assertSameInput(loaded: Loaded) = assertEquals(identity(loaded.status), identity(client.status()))
    private fun identity(status: Map<String, Any?>) = listOf("processId", "inputId", "generation", "networkRevision", "composition", "configId", "revision")
        .associateWith { status[it] }
    private fun runRecords(): Map<String, String> = AppFiles.work(context).listFiles().orEmpty()
        .filter { it.name.startsWith("run-record-") }.associate { it.name to MessageDigest.getInstance("SHA-256")
            .digest(it.readBytes()).joinToString("") { byte -> "%02x".format(byte) } }
    private fun businessFiles() = listOf("configurations.json", "overrides.json", "preferences.json")
        .associateWith { AppFiles.configs(context).resolve(it).readBytes() }
    private fun entries(value: JSONObject) = value.getJSONArray("entries").let { values -> (0 until values.length()).map(values::getJSONObject) }

    private fun awaitWriterDrain(label: String) = await(label, 35_000) {
        var drained = false
        main {
            val state = AppBridge.runtimeState()
            drained = state["scheduleBusy"] == false && state["writerBusy"] == false && !AppBridge.logic.busy && AppBridge.operationId == null
        }
        drained
    }

    private fun awaitBackground(activity: MainActivity) = await("UI Activity actually stops", 10_000) {
        var hidden = false
        main {
            val monitor = ActivityLifecycleMonitorRegistry.getInstance()
            val visible = listOf(Stage.STARTED, Stage.RESUMED, Stage.PAUSED, Stage.RESTARTED)
                .any { stage -> monitor.getActivitiesInStage(stage).any { it is MainActivity } }
            hidden = !visible && (activity.isDestroyed || monitor.getActivitiesInStage(Stage.STOPPED).contains(activity))
        }
        hidden
    }

    private fun awaitControllerExport(nonce: String, kind: String) {
        val action = context.packageName + ".validation.EXPORT_WORK_" + nonce.removePrefix("p5-load-worker-").uppercase()
        val exported = CountDownLatch(1)
        val receiver = signalReceiver(action, nonce, kind, exported)
        registerReceiver(receiver, action)
        try {
            Log.i("PseudoWorkerTest", "WAIT_OWNED_WORK_EXPORT nonce=$nonce kind=$kind")
            assertTrue("Export confirmation was not received within 120 seconds", exported.await(120, TimeUnit.SECONDS))
        } finally { context.unregisterReceiver(receiver) }
    }

    private fun signalReceiver(action: String, nonce: String, kind: String, signal: CountDownLatch) = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == action && intent.getStringExtra("nonce") == nonce && intent.getStringExtra("kind") == kind) signal.countDown()
        }
    }

    private fun registerReceiver(receiver: BroadcastReceiver, action: String) {
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, IntentFilter(action), Context.RECEIVER_EXPORTED)
        else @Suppress("DEPRECATION") context.registerReceiver(receiver, IntentFilter(action))
    }

    private fun kindArgument(): String = requireNotNull(InstrumentationRegistry.getArguments().getString("kind")) {
        "kind=config or kind=override is required"
    }.also { require(it == "config" || it == "override") { "kind=config or kind=override is required" } }

    private fun main(block: () -> Unit) = instrumentation.runOnMainSync(block)
    private fun await(label: String, timeoutMs: Long, ready: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (!ready()) {
            check(SystemClock.elapsedRealtime() < deadline) { "Timed out waiting for $label" }
            Thread.sleep(25)
        }
    }
}
