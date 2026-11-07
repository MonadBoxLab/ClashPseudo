package io.github.monadboxlab.clashpseudo.bridge.core

import io.github.monadboxlab.clashpseudo.bridge.AppBridge

import android.app.UiAutomation
import android.content.Intent
import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import android.os.SystemClock
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import io.github.monadboxlab.clashpseudo.MainActivity
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.nativecore.CoreClient
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CorePlatformTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CoreResourceGate
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CompletableFuture
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Bounded controlled UI/network test; exact EOF attribution also requires client/server records. */
class ControlledConnectionsTest {
    @Test fun observeOwned1500Then500RetireAndOneFurtherAbsence() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val platform = CorePlatformTestDriver(context)
        CoreIpcTestDriver.assertNoGoInApplication()
        val arguments = InstrumentationRegistry.getArguments()
        fun required(name: String) = checkNotNull(arguments.getString(name)) { "Missing $name" }
        val nonce = required("nonce").also { check(it.matches(Regex("[a-z0-9-]{8,48}"))) }
        val expectedId = required("expectedConfigId").also { check(it.isNotBlank()) }
        val expectedRevision = required("expectedRevision").toInt().also { check(it > 0) }
        val expectedBody = required("expectedBodySha256").also { check(it.matches(Regex("[0-9a-f]{64}"))) }
        val port = required("httpPort").toInt().also { check(it in 1..65535) }
        assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
        assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
        val deadline = SystemClock.elapsedRealtime() + 270_000L
        var ownedSession: Long? = null
        var cleanupSession: Long? = null
        var ownedCore: CoreHost.Snapshot? = null
        val seeds = linkedMapOf<String, Int>()
        val absent = mutableSetOf<String>()
        val witnesses = linkedMapOf<String, Long>()
        val flowing = mutableSetOf<String>()
        var peak = false
        var retired = false
        var windowObserved = false
        var evictionObserved = false
        var retiredIds = emptySet<String>()
        var furtherAbsence = false
        var uiTarget: String? = null
        var uiCloseAt: Long? = null
        var uiStopped = false
        var uiStopConfirmed = false
        var lastSummary: Pair<Int, Int>? = null
        var automation: UiAutomation? = null
        var stage = "Prepare the actual UI"
        var primaryFailure: Throwable? = null
        var startDispatched = false
        var startupWork: List<Map<String, Any?>> = emptyList()
        var lastUiLabels: List<String> = emptyList()
        fun startupFinished(remaining: Long): Boolean {
            check(remaining > 0) { "The original startup deadline has expired" }
            val infos = androidx.work.WorkManager.getInstance(context)
                .getWorkInfosForUniqueWork("update-reconcile")
                .get(minOf(remaining, 5_000L), TimeUnit.MILLISECONDS)
            startupWork = infos.map { mapOf("id" to it.id.toString(), "state" to it.state.name, "attempt" to it.runAttemptCount) }
            return infos.isNotEmpty() && infos.all { it.state.isFinished }
        }
        fun diagnose(error: Throwable, location: String) {
            try {
                val facts = linkedMapOf<String, Any?>(
                    "stage" to stage, "location" to location, "nonce" to nonce,
                    "ownedSession" to ownedSession, "cleanupSession" to cleanupSession,
                    "ownedCore" to ownedCore?.toString(), "startDispatched" to startDispatched,
                    "uiStopped" to uiStopped, "uiStopConfirmed" to uiStopConfirmed,
                    "peak" to peak, "retired" to retired, "windowObserved" to windowObserved,
                    "evictionObserved" to evictionObserved, "furtherAbsence" to furtherAbsence,
                    "seeds" to seeds, "absent" to absent.toList(), "uiTarget" to uiTarget,
                    "startupWork" to startupWork, "uiAutomation" to automation?.toString(),
                    "uiLabels" to lastUiLabels,
                )
                instrumentation.runOnMainSync {
                    facts["snapshot"] = AppBridge.runtimeState()
                    facts["session"] = PseudoVpnService.session.snapshot().toString()
                    facts["core"] = CoreClient.get(context).status()
                    facts["requestBusy"] = CoreClient.get(context).requestBusy
                    facts["operationId"] = AppBridge.operationId
                    facts["command"] = AppBridge.command
                    facts["executorBusy"] = AppBridge.operations.executorBusy
                    facts["logicBusy"] = AppBridge.logic.busy
                    facts["runtimeProjection"] = AppBridge.logic.runtimeProjection
                    facts["resumedActivities"] = ActivityLifecycleMonitorRegistry.getInstance()
                        .getActivitiesInStage(Stage.RESUMED).map { it.javaClass.name }
                }
                error.addSuppressed(IllegalStateException(JSONObject(facts).toString()))
            } catch (diagnostic: Throwable) {
                if (diagnostic !== error) error.addSuppressed(diagnostic)
            }
            Log.e("ConnectionLiveRead", "FAILED nonce=$nonce stage=$stage location=$location", error)
        }
        // Read the current SDK tree while the overview animation runs; do not wait for it to stop.
        fun uiNodes(): List<AccessibilityNodeInfo> {
            val currentAutomation = checkNotNull(automation) { "Actual UiAutomation has not been acquired" }
            val nodes = mutableListOf<AccessibilityNodeInfo>()
            val pending = ArrayDeque<AccessibilityNodeInfo>()
            currentAutomation.rootInActiveWindow?.let { pending.add(it) }
            while (pending.isNotEmpty()) {
                check(nodes.size < 500) { "Unexpected visible UI tree capacity" }
                val node = pending.removeFirst()
                nodes.add(node)
                for (index in 0 until node.childCount) node.getChild(index)?.let { pending.add(it) }
            }
            lastUiLabels = nodes.map { it.text?.toString() ?: it.contentDescription?.toString().orEmpty() }
            return nodes
        }
        fun uiLabel(node: AccessibilityNodeInfo) =
            node.text?.toString()?.takeIf { it.isNotEmpty() } ?: node.contentDescription?.toString().orEmpty()
        fun clickUi(label: String) {
            val until = minOf(deadline, SystemClock.elapsedRealtime() + 10_000)
            while (SystemClock.elapsedRealtime() < until) {
                val nodes = uiNodes()
                val matches = nodes.filter { it.packageName?.toString() == context.packageName &&
                    uiLabel(it) == label && it.isEnabled && it.isClickable }
                if (matches.isNotEmpty()) {
                    assertEquals("Ambiguous actual UI action $label", 1, matches.size)
                    val bounds = Rect().also { matches.single().getBoundsInScreen(it) }
                    assertFalse(bounds.isEmpty)
                    Log.i("ConnectionLiveRead", "UI_CLICK nonce=$nonce label=$label bounds=$bounds " +
                        "elapsedMs=${SystemClock.elapsedRealtime()}")
                    assertTrue("SDK did not dispatch $label", matches.single().performAction(AccessibilityNodeInfo.ACTION_CLICK))
                    return
                }
                Thread.sleep(100)
            }
            error("Actual UI action was unavailable: $label")
        }
        fun closeActualUiConnection() {
            clickUi("Recent connections")
            val target = "192.168.100.2:$port"
            val until = minOf(deadline, SystemClock.elapsedRealtime() + 15_000)
            var opened = false
            while (!opened && SystemClock.elapsedRealtime() < until) {
                val rows = uiNodes().filter { it.packageName?.toString() == context.packageName &&
                    uiLabel(it).startsWith(target) && !uiLabel(it).contains("Inactive") && it.isClickable && it.isEnabled }
                if (rows.isNotEmpty()) {
                    val bounds = Rect().also { rows.first().getBoundsInScreen(it) }
                    Log.i("ConnectionLiveRead", "UI_ROW nonce=$nonce target=$target bounds=$bounds " +
                        "elapsedMs=${SystemClock.elapsedRealtime()}")
                    assertTrue(rows.first().performAction(AccessibilityNodeInfo.ACTION_CLICK))
                    opened = true
                } else Thread.sleep(100)
            }
            assertTrue("No actual owned live row was available", opened)
            var sourcePort: Int? = null
            var lastScroll = 0L
            while (sourcePort == null && SystemClock.elapsedRealtime() < until) {
                val nodes = uiNodes()
                val ports = nodes.filter { it.packageName?.toString() == context.packageName }
                    .mapNotNull { node ->
                        val label = uiLabel(node)
                        if (label == target) null else Regex("(?:[0-9]{1,3}\\.){3}[0-9]{1,3}:([0-9]{1,5})")
                            .matchEntire(label)?.groupValues?.get(1)?.toInt()
                    }.toSet()
                if (ports.isNotEmpty()) {
                    assertEquals(1, ports.size)
                    sourcePort = ports.single()
                } else if (SystemClock.elapsedRealtime() - lastScroll >= 700) {
                    val scrolls = nodes.filter { it.packageName?.toString() == context.packageName && it.isScrollable &&
                        it.actionList.any { action -> action.id == AccessibilityNodeInfo.ACTION_SCROLL_FORWARD } }
                    if (scrolls.size == 1) {
                        scrolls.single().performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
                        lastScroll = SystemClock.elapsedRealtime()
                    }
                    Thread.sleep(100)
                } else Thread.sleep(100)
            }
            val actualPort = checkNotNull(sourcePort) { "Actual detail source port was not available" }
            uiTarget = seeds.entries.single { it.value == actualPort }.key
            uiCloseAt = SystemClock.elapsedRealtime()
            Log.i("ConnectionLiveRead", "UI_TARGET nonce=$nonce id=$uiTarget sourcePort=$actualPort " +
                "elapsedMs=$uiCloseAt")
            clickUi("Disconnect")
        }
        fun readWindow(detail: Map<String, Any?>? = null): Map<*, *>? {
            val reply = CompletableFuture<Map<*, *>?>()
            instrumentation.runOnMainSync {
                AppBridge.logic.connections(detail, if (detail == null) null else "controlled-connections:$nonce", object : MethodChannel.Result {
                    override fun success(result: Any?) { reply.complete(result as? Map<*, *>) }
                    override fun error(code: String, message: String?, details: Any?) {
                        Log.i("ConnectionLiveRead", "WINDOW_WAIT nonce=$nonce code=$code")
                        reply.complete(null)
                    }
                    override fun notImplemented() { reply.completeExceptionally(AssertionError("Missing window read")) }
                })
            }
            return reply.get(10, TimeUnit.SECONDS)
        }
        val limit = File("/proc/self/limits").useLines { lines ->
            lines.first { it.startsWith("Max open files") }.trim()
        }
        Log.i("ConnectionLiveRead", "READY nonce=$nonce fdLimit=$limit " +
            "elapsedMs=${SystemClock.elapsedRealtime()}")
        try {
            val uiReadyBy = minOf(deadline, SystemClock.elapsedRealtime() + 20_000)
            var startupReady = false
            while (!startupReady && SystemClock.elapsedRealtime() < uiReadyBy) {
                val finished = startupFinished(uiReadyBy - SystemClock.elapsedRealtime())
                instrumentation.runOnMainSync {
                    val resumed = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                        .filterIsInstance<MainActivity>().singleOrNull()
                    val state = AppBridge.runtimeState()
                    startupReady = finished && resumed != null && !resumed.isFinishing && !resumed.isDestroyed &&
                        resumed.window.decorView.hasWindowFocus() && AppBridge.operationId == null &&
                        !AppBridge.operations.executorBusy && !AppBridge.logic.busy &&
                        state["writerBusy"] == false && state["storageReady"] == true && state["storageRestoring"] != true
                }
                if (!startupReady) Thread.sleep(100)
            }
            assertTrue("Actual MainActivity and startup WorkInfo/owner/executor were not ready within the original UI deadline", startupReady)
            stage = "Acquire actual UiAutomation"
            automation = checkNotNull(instrumentation.uiAutomation) { "UiAutomation with default flags is not connected" }
            Log.i("ConnectionLiveRead", "UI_AUTOMATION nonce=$nonce flags=0 elapsedMs=${SystemClock.elapsedRealtime()}")
            stage = "Read the selected configuration and Start through the actual UI"
            while (uiNodes().none { uiLabel(it) == "p5-load-r4n4" } &&
                SystemClock.elapsedRealtime() < uiReadyBy) Thread.sleep(100)
            assertTrue("Controlled selection was not shown before UI Start",
                uiNodes().any { uiLabel(it) == "p5-load-r4n4" })
            clickUi("Start tunnel")
            startDispatched = true
            stage = "Observe the actual running context and controlled connections"
            while (SystemClock.elapsedRealtime() < deadline) {
                val session = PseudoVpnService.session.snapshot()
                if (session.configId == expectedId && session.revision == expectedRevision &&
                    session.phase in setOf(NativeSession.Phase.STARTING, NativeSession.Phase.RUNNING)) {
                    if (cleanupSession == null) cleanupSession = session.generation
                    else assertEquals(cleanupSession, session.generation)
                }
                if (ownedSession == null) {
                    if (session.phase != NativeSession.Phase.RUNNING) {
                        check(session.phase != NativeSession.Phase.UNKNOWN) { "Native cleanup is unknown" }
                        Thread.sleep(500)
                        continue
                    }
                    assertEquals(expectedId, session.configId)
                    assertEquals(expectedRevision, session.revision)
                    val core = PseudoVpnService.core.snapshot()
                    assertEquals(CoreHost.Phase.READY, core.phase)
                    assertEquals(CoreHost.Purpose.RUNNING, core.purpose)
                    assertEquals(expectedId, core.configId)
                    assertEquals(expectedRevision, core.revision)
                    val record = platform.runRecord(platform.status())
                    val body = record.getString("body").toByteArray(Charsets.UTF_8)
                    val digest = MessageDigest.getInstance("SHA-256").digest(body)
                        .joinToString("") { "%02x".format(it.toInt() and 255) }
                    assertEquals("Actual controlled running body differs", expectedBody, digest)
                    ownedSession = session.generation
                    ownedCore = core
                    // Refresh observation-service flags separately from transport
                    // admission.
                    checkNotNull(instrumentation.getUiAutomation(
                        UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES or
                            UiAutomation.FLAG_DONT_USE_ACCESSIBILITY))
                    Log.i("ConnectionLiveRead", "UI_ACCESS nonce=$nonce enabled=false " +
                        "elapsedMs=${SystemClock.elapsedRealtime()}")
                }
                assertEquals(ownedSession, session.generation)
                if (session.phase == NativeSession.Phase.STOPPED) {
                    uiStopConfirmed = uiStopped
                    break
                }
                check(session.phase != NativeSession.Phase.UNKNOWN) { "Native cleanup is unknown" }
                if (session.phase != NativeSession.Phase.RUNNING) {
                    Thread.sleep(500)
                    continue
                }
                val core = checkNotNull(ownedCore)
                fun current(): Boolean {
                    val before = PseudoVpnService.session.snapshot()
                    check(before.generation == ownedSession)
                    if (before.phase in setOf(NativeSession.Phase.STOPPING, NativeSession.Phase.STOPPED)) return false
                    check(before.phase == NativeSession.Phase.RUNNING)
                    val actual = PseudoVpnService.core.snapshot()
                    if (PseudoVpnService.session.snapshot().phase != NativeSession.Phase.RUNNING) return false
                    check(actual == core)
                    return true
                }
                if (!current()) continue
                val response = CoreBridgeIpcScenario.success(platform.query(Contract.CORE_OPERATION_CONNECTIONS,
                    mapOf("limit" to 1000, "previousActiveIds" to seeds.keys.toList())))
                if (!current()) continue
                assertTrue(response.getBoolean("complete"))
                val count = response.getInt("activeCount")
                assertTrue(count in 0..1500)
                val rows = response.getJSONArray("connections")
                assertTrue(rows.length() <= 1000)
                if (!peak && count == 1500) {
                    assertEquals(1000, rows.length())
                    assertTrue(response.getBoolean("limited"))
                    for (index in 0 until rows.length()) {
                        val row = rows.getJSONObject(index)
                        val metadata = row.getJSONObject("metadata")
                        assertEquals("192.168.100.2", metadata.getString("destinationIP"))
                        assertEquals(port, metadata.getString("destinationPort").toInt())
                        val id = row.getString("id")
                        val sourcePort = metadata.getString("sourcePort").toInt()
                        check(seeds.put(id, sourcePort) == null)
                        Log.i("ConnectionLiveRead", "TRACKER nonce=$nonce id=$id sourcePort=$sourcePort " +
                            "session=$ownedSession core=${core.generation}")
                    }
                    assertEquals(1000, seeds.size)
                    peak = true
                } else if (peak) {
                    val presence = response.getJSONObject("presence")
                    for ((id, sourcePort) in seeds) {
                        assertTrue("Seed presence was omitted", presence.has(id))
                        if (!presence.getBoolean(id) && absent.add(id)) {
                            Log.i("ConnectionLiveRead", "ABSENT nonce=$nonce id=$id sourcePort=$sourcePort " +
                                "elapsedMs=${SystemClock.elapsedRealtime()}")
                        }
                    }
                    if (count == 1000 && absent.size == 500) retired = true
                    if (retired && count == 999 && absent.size == 501) furtherAbsence = true
                }
                if (retired && !windowObserved) {
                    // Ownerless probes only read; they cannot revoke an actual UI detail lease.
                    val window = readWindow()
                    if (window != null && window["fresh"] == true) {
                        assertEquals(ownedSession, (window["sessionGeneration"] as Number).toLong())
                        assertEquals(core.generation, (window["generation"] as Number).toLong())
                        assertEquals(core.composition, window["composition"])
                        assertEquals(expectedId, window["configId"])
                        assertEquals(expectedRevision, (window["revision"] as Number).toInt())
                        val records = (window["connections"] as List<*>).map { it as Map<*, *> }
                        val inactiveIds = records.filter { it["active"] == false }.map { it["id"] as String }.toSet()
                        val activeCount = records.count { it["active"] == true }
                        assertEquals(records.size, records.map { it["id"] }.toSet().size)
                        assertTrue(activeCount <= 1000 && inactiveIds.size <= 500)
                        if (activeCount == 1000 && inactiveIds.size == 500) {
                            assertEquals(absent, inactiveIds)
                            retiredIds = inactiveIds
                            windowObserved = true
                            Log.i("ConnectionLiveRead", "WINDOW nonce=$nonce active=1000 inactive=500 " +
                                "unique=${records.size} fresh=true session=$ownedSession core=${core.generation} " +
                                "elapsedMs=${SystemClock.elapsedRealtime()}")
                        }
                    }
                }
                if (furtherAbsence && windowObserved && !evictionObserved) {
                    val extra = (absent - retiredIds).single()
                    assertEquals("Further absence differs from the actual UI target", uiTarget, extra)
                    // Keep the closed detail pinned through the next observation,
                    // matching UI behavior.
                    val detail = mapOf("id" to extra, "generation" to core.generation,
                        "composition" to core.composition, "configId" to expectedId,
                        "revision" to expectedRevision, "purpose" to Contract.CORE_PURPOSE_RUNNING,
                        "processId" to core.processId, "inputId" to core.inputId,
                        "networkRevision" to platform.status()["networkRevision"])
                    val window = readWindow(detail)
                    if (window != null && window["fresh"] == true) {
                        assertEquals(ownedSession, (window["sessionGeneration"] as Number).toLong())
                        assertEquals(core.generation, (window["generation"] as Number).toLong())
                        assertEquals(core.composition, window["composition"])
                        val records = (window["connections"] as List<*>).map { it as Map<*, *> }
                        val inactiveIds = records.filter { it["active"] == false }.map { it["id"] as String }.toSet()
                        if (records.count { it["active"] == true } == 999 && extra in inactiveIds) {
                            assertEquals(500, inactiveIds.size)
                            assertEquals(1499, records.size)
                            assertEquals(1499, records.map { it["id"] }.toSet().size)
                            val evicted = (retiredIds - inactiveIds).single()
                            assertEquals(retiredIds - evicted + extra, inactiveIds)
                            evictionObserved = true
                            Log.i("ConnectionLiveRead", "EVICTION nonce=$nonce active=999 inactive=500 " +
                                "unique=1499 added=$extra evicted=$evicted fresh=true " +
                                "elapsedMs=${SystemClock.elapsedRealtime()}")
                        }
                    }
                }
                if (windowObserved && witnesses.isEmpty()) {
                    for (index in 0 until 2) {
                        val row = rows.getJSONObject(index)
                        val id = row.getString("id")
                        assertTrue(id in seeds && id !in absent)
                        witnesses[id] = row.getLong("download")
                        Log.i("ConnectionLiveRead", "WITNESS nonce=$nonce id=$id " +
                            "sourcePort=${row.getJSONObject("metadata").getString("sourcePort")} " +
                            "download=${row.getLong("download")} elapsedMs=${SystemClock.elapsedRealtime()}")
                    }
                }
                for (index in 0 until rows.length()) {
                    val row = rows.getJSONObject(index)
                    val id = row.getString("id")
                    if (id in witnesses) {
                        Log.i("ConnectionLiveRead", "FLOW nonce=$nonce id=$id " +
                            "sourcePort=${row.getJSONObject("metadata").getString("sourcePort")} " +
                            "upload=${row.getLong("upload")} download=${row.getLong("download")} " +
                            "elapsedMs=${SystemClock.elapsedRealtime()}")
                        if (row.getLong("download") > witnesses.getValue(id) && flowing.add(id)) {
                            Log.i("ConnectionLiveRead", "FLOW_READY nonce=$nonce id=$id " +
                                "sourcePort=${row.getJSONObject("metadata").getString("sourcePort")} " +
                                "elapsedMs=${SystemClock.elapsedRealtime()}")
                        }
                    }
                }
                val summary = count to absent.size
                if (summary != lastSummary) {
                    lastSummary = summary
                    Log.i("ConnectionLiveRead", "SAMPLE nonce=$nonce active=$count rows=${rows.length()} " +
                        "seedAbsent=${absent.size} retired=$retired furtherAbsence=$furtherAbsence " +
                        "elapsedMs=${SystemClock.elapsedRealtime()}")
                }
                if (windowObserved && flowing.size == 2 && uiTarget == null) closeActualUiConnection()
                if (evictionObserved && uiCloseAt != null &&
                    SystemClock.elapsedRealtime() - checkNotNull(uiCloseAt) >= 6000 && !uiStopped) {
                    clickUi("Back")
                    val returnedBy = minOf(deadline, SystemClock.elapsedRealtime() + 10_000)
                    while (uiNodes().none { uiLabel(it) == "Search connections" } &&
                        SystemClock.elapsedRealtime() < returnedBy) Thread.sleep(100)
                    assertTrue("Detail did not return to the actual connection list",
                        uiNodes().any { uiLabel(it) == "Search connections" })
                    clickUi("Back")
                    clickUi("Stop tunnel")
                    uiStopped = true
                }
                Thread.sleep(1000)
            }
            assertTrue("Normal UI Stop did not reach STOPPED before cleanup", uiStopConfirmed)
            assertTrue("Normal UI Stop was not dispatched", uiStopped)
            assertTrue("Never observed 1500 real native trackers", peak)
            assertTrue("Never observed 1000 live and 500 absent previously observed trackers", retired)
            assertTrue("Never observed the fresh Dart window with 1000 active and the same 500 inactive IDs", windowObserved)
            assertTrue("Never observed the real Dart inactive-capacity eviction after the further absence", evictionObserved)
            assertTrue("Never observed one further absence with 999 live trackers", furtherAbsence)
        } catch (error: Throwable) {
            primaryFailure = error
            diagnose(error, "try")
            throw error
        } finally {
            stage = "Confirm actual cleanup and writer/query drain"
            try {
                val beforeCleanup = platform.status()
                val sessionBeforeCleanup = PseudoVpnService.session.snapshot()
                val owner = cleanupSession ?: sessionBeforeCleanup.takeIf {
                    startDispatched && it.configId == expectedId && it.revision == expectedRevision &&
                        it.phase in setOf(NativeSession.Phase.STARTING, NativeSession.Phase.RUNNING)
                }?.generation
                val hadContext = owner != null || ownedCore != null ||
                    (!((beforeCleanup["processId"] as? String).isNullOrEmpty()) &&
                        beforeCleanup["phase"] != Contract.CORE_PHASE_EXITED)
                if (owner != null && PseudoVpnService.session.snapshot().let {
                        it.generation == owner && it.phase in setOf(NativeSession.Phase.STARTING, NativeSession.Phase.RUNNING)
                    }) {
                    platform.exit()
                }
                val cleanupDeadline = SystemClock.elapsedRealtime() + 45_000L
                var drained = false
                while (!drained && SystemClock.elapsedRealtime() < cleanupDeadline) {
                    val workFinished = startupFinished(cleanupDeadline - SystemClock.elapsedRealtime())
                    instrumentation.runOnMainSync {
                        val client = CoreClient.get(context)
                        val core = client.status()
                        val snapshot = AppBridge.runtimeState()
                        val nativeStopped = if (hadContext) {
                            core["phase"] == Contract.CORE_PHASE_EXITED &&
                                core["vpnRunning"] == false && core["lanRunning"] == false
                        } else {
                            (core["phase"] == null || core["phase"] == Contract.CORE_PHASE_EXITED) &&
                                core["vpnRunning"] != true && core["lanRunning"] != true
                        }
                        drained = workFinished && PseudoVpnService.session.snapshot().phase == NativeSession.Phase.STOPPED &&
                            PseudoVpnService.core.snapshot().phase == CoreHost.Phase.EMPTY && nativeStopped && !client.requestBusy &&
                            AppBridge.operationId == null && AppBridge.command == null && !AppBridge.logic.busy &&
                            !AppBridge.operations.executorBusy && snapshot["writerBusy"] == false &&
                            snapshot["storageReady"] == true && snapshot["storageRestoring"] != true
                    }
                    if (!drained) Thread.sleep(50)
                }
                assertTrue("Normal Stop and actual writer/query drain did not finish", drained)
                val stopped = platform.status()
                if (hadContext) {
                    assertEquals(Contract.CORE_PHASE_EXITED, stopped["phase"])
                    assertEquals(false, stopped["vpnRunning"])
                    assertEquals(false, stopped["lanRunning"])
                } else {
                    assertTrue("No live core may remain when a context was not established", stopped["phase"] == null || stopped["phase"] == Contract.CORE_PHASE_EXITED)
                    assertFalse(stopped["vpnRunning"] == true)
                    assertFalse(stopped["lanRunning"] == true)
                }
                assertEquals(false, stopped["recoveryRequired"])
                val released = CoreResourceGate.forApplication(context).tryAcquire()
                assertNotNull("The resource lock must be released after actual process death", released)
                released!!.close()
                CoreIpcTestDriver.assertNoGoInApplication()
            } catch (cleanup: Throwable) {
                diagnose(cleanup, "finally")
                val first = primaryFailure
                if (first == null) throw cleanup
                if (cleanup !== first) first.addSuppressed(cleanup)
            }
        }
        Log.i("ConnectionLiveRead", "FINISHED nonce=$nonce observed1500=$peak observed500Retired=$retired " +
            "observedDartWindow=$windowObserved observedEviction=$evictionObserved " +
            "observedFurtherAbsence=$furtherAbsence nativeStopped=true")
    }
}
