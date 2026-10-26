package io.github.monadboxlab.clashpseudo.nativecore

import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.UnderlyingNetworks
import io.github.monadboxlab.clashpseudo.vpn.UnderlyingSnapshot
import org.json.JSONObject
import java.util.concurrent.Executor
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class CoreHostTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private val input = CoreInput("one", 1, "rule", byteArrayOf(), "{}".toByteArray())

    private class Harness {
        val session = NativeSession()
        val tasks = LinkedBlockingQueue<Runnable>()
        val prepares = AtomicInteger()
        val stops = AtomicInteger()
        val cancels = AtomicInteger()
        val events = mutableListOf<String>()
        val refreshes = mutableListOf<List<Any>>()
        val networkUpdates = mutableListOf<JSONObject>()
        var networkRestart = true
        var callback: Any? = null
        var prepareError = ""
        var stopError = ""
        lateinit var core: CoreHost
    }

    private fun harness(): Harness {
        val h = Harness()
        main {
            h.core = CoreHost(h.session, {}, Executor { h.tasks.add(it) }, 60,
                { _, _, _, callback, _, _ ->
                    h.prepares.incrementAndGet(); h.events.add("prepare"); h.callback = callback; h.prepareError
                }, { h.stops.incrementAndGet(); h.events.add("stop"); h.stopError }, { h.cancels.incrementAndGet() },
                bindUnderlying = { true }, requestRuntimeRefresh = { session, core, composition, revision, reason ->
                    h.refreshes.add(listOf(session, core, composition, revision, reason))
                }, updateNativeNetwork = { bytes ->
                    h.networkUpdates.add(JSONObject(bytes.toString(Charsets.UTF_8)))
                    JSONObject().put("changed", true).put("requiresRestart", h.networkRestart).toString()
                })
            h.core.setVisible(true)
        }
        return h
    }
    private fun preview(h: Harness, owner: String = "one", revision: Int = 1) =
        h.core.preparePreview(owner, "one", revision, "unused", { true }) {
            CoreInput("one", revision, "rule", byteArrayOf(), "{}".toByteArray())
        }
    private fun permitted(callback: Any): Boolean = callback.javaClass.getDeclaredMethod("protectSocket", Int::class.javaPrimitiveType)
        .apply { isAccessible = true }.invoke(callback, 42) as Boolean

    @Test fun previewDoesNotCreateVpnAndReusesOnlyMatchingContext() {
        val h = harness()
        val first = preview(h)
        val callback = h.callback!!
        assertTrue(permitted(callback))
        assertEquals(NativeSession.Phase.STOPPED, h.session.snapshot().phase)
        assertEquals(first.generation, preview(h, "second").generation)
        assertEquals(1, h.prepares.get())
        val next = preview(h, "third", 2)
        assertTrue(next.generation > first.generation)
        assertEquals(1, h.stops.get())
        assertFalse(permitted(callback))
        assertNull(h.core.releasePreview())
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
    }

    @Test fun vpnHandoffFullyReleasesPreviewAndIgnoresIdleExpiry() {
        val h = harness()
        preview(h)
        val callback = h.callback!!
        val vpn = h.session.begin("one", 1)!!
        assertFalse(permitted(callback))
        val loaded = h.core.prepareVpn(vpn, "one", 1, "unused", { input }, Any())
        assertEquals(listOf("prepare", "stop", "prepare"), h.events)
        h.session.attached(vpn)
        assertTrue(h.core.current(loaded.generation))
        main { h.core.setVisible(false) }
        assertNull(h.tasks.poll(200, TimeUnit.MILLISECONDS))
        assertEquals(CoreHost.Phase.READY, h.core.snapshot().phase)
        assertNull(h.core.releasePreview())
        assertEquals(1, h.stops.get())
        h.session.stopping(vpn)
        h.core.cancelVpn(vpn)
        assertNull(h.core.stopVpn(vpn))
        h.session.finished(vpn, null)
        assertEquals(2, h.stops.get())
        assertEquals(1, h.cancels.get())
    }

    @Test fun returningBeforeQueuedExpiryPreservesPreview() {
        val h = harness()
        preview(h)
        main { h.core.setVisible(false) }
        val expired = h.tasks.poll(2, TimeUnit.SECONDS)!!
        main { h.core.setVisible(true) }
        expired.run()
        assertEquals(CoreHost.Phase.READY, h.core.snapshot().phase)
        assertEquals(0, h.stops.get())
        assertNull(h.core.releasePreview())
    }

    @Test fun expiredPreviewReleasesAndReturnNeedsNewGeneration() {
        val h = harness()
        val before = preview(h)
        main { h.core.setVisible(false) }
        h.tasks.poll(2, TimeUnit.SECONDS)!!.run()
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
        main { h.core.setVisible(true) }
        assertTrue(preview(h).generation > before.generation)
        assertEquals(2, h.prepares.get())
        assertNull(h.core.releasePreview())
    }

    @Test fun acceptedOperationDefersAnAlreadyQueuedExpiry() {
        val h = harness()
        preview(h)
        main { h.core.setVisible(false) }
        val expired = h.tasks.poll(2, TimeUnit.SECONDS)!!
        main { h.core.setOperationBusy(true) }
        expired.run()
        assertEquals(0, h.stops.get())
        main { h.core.setOperationBusy(false) }
        h.tasks.poll(2, TimeUnit.SECONDS)!!.run()
        assertEquals(1, h.stops.get())
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
    }

    @Test fun oldExpiryCannotReleaseReplacementContext() {
        val h = harness()
        preview(h)
        main { h.core.setVisible(false) }
        val old = h.tasks.poll(2, TimeUnit.SECONDS)!!
        main { h.core.setVisible(true) }
        val next = preview(h, "new", 2)
        old.run()
        assertEquals(next, h.core.snapshot())
        assertEquals(1, h.stops.get())
        assertNull(h.core.releasePreview())
    }

    @Test fun failedPrepareCleansUpAndCanBeRetriedExplicitly() {
        val h = harness()
        h.prepareError = "invalid"
        try { preview(h); fail("failed preparation accepted") } catch (_: IllegalStateException) { }
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
        assertNotNull(h.core.snapshot().error)
        assertEquals("one", h.core.snapshot().configId)
        assertEquals(1, h.stops.get())
        h.prepareError = ""
        assertEquals(CoreHost.Phase.READY, preview(h).phase)
        assertNull(h.core.releasePreview())
    }

    @Test fun cleanupFailureBlocksReuseWithoutClaimingVpnRunning() {
        val h = harness()
        preview(h)
        h.stopError = "unconfirmed"
        assertNotNull(h.core.releasePreview())
        assertEquals(CoreHost.Phase.FAILED, h.core.snapshot().phase)
        assertEquals(NativeSession.Phase.STOPPED, h.session.snapshot().phase)
        try { preview(h, "other"); fail("unclean context reused") } catch (_: IllegalStateException) { }
        assertEquals(1, h.prepares.get())
    }

    @Test fun expiredReadyWaiterReleasesItsContext() {
        val h = harness()
        val loaded = preview(h, "expired")
        main { h.core.cancelPreparation("expired") }
        assertFalse(h.core.current(loaded.generation))
        h.tasks.poll(2, TimeUnit.SECONDS)!!.run()
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
        assertEquals(1, h.stops.get())
        assertEquals(0, h.cancels.get())
    }

    @Test fun mismatchedInputNeverReachesNativePrepare() {
        val h = harness()
        try {
            h.core.preparePreview("one", "one", 2, "unused", { true }) { input }
            fail("mismatched input accepted")
        } catch (_: IllegalStateException) { }
        assertEquals(0, h.prepares.get())
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
        assertNotNull(h.core.snapshot().error)
    }

    @Test fun expiredReadyWaiterQueuesOnlyItsOwnCleanup() {
        val h = harness()
        val old = preview(h, "old")
        main { h.core.cancelPreparation("old") }
        assertFalse(h.core.current(old.generation))
        val cleanup = h.tasks.poll(2, TimeUnit.SECONDS)!!
        val next = preview(h, "next", 2)
        cleanup.run()
        assertEquals(next, h.core.snapshot())
        assertEquals(1, h.stops.get())
        assertNull(h.core.releasePreview())
    }

    @Test fun runningInputIsIdentityBoundPrivateAndClearedOnStop() {
        val h = harness()
        val generation = h.session.begin("one", 1)!!
        val packages = mutableListOf("fixture.loaded")
        val value = CoreInput("one", 1, "global", "﻿rules: []".toByteArray(Charsets.UTF_8),
            "{}".toByteArray(), access = "only", packages = packages,
            source = "https://fixture.test/config")
        val loaded = h.core.prepareVpn(generation, "one", 1, "unused", { value }, Any())
        assertNull(h.core.runningInput(loaded.generation, value.composition))
        assertNull(h.core.applicationAccess(generation))
        packages.clear()
        h.session.attached(generation)
        assertNull(h.core.applicationAccess(generation + 1))
        val access = h.core.applicationAccess(generation)!!
        assertEquals("only", access["access"])
        assertEquals(listOf("fixture.loaded"), access["packages"])
        assertEquals(generation, access["generation"])
        @Suppress("UNCHECKED_CAST")
        (access["packages"] as MutableList<String>).clear()
        assertEquals(listOf("fixture.loaded"), h.core.applicationAccess(generation)!!["packages"])
        assertNull(h.core.runningInput(loaded.generation + 1, value.composition))
        assertNull(h.core.runningInput(loaded.generation, "other"))
        val bytes = h.core.runningInput(loaded.generation, value.composition)!!
        val snapshot = org.json.JSONObject(bytes.toString(Charsets.UTF_8))
        assertEquals("﻿rules: []", snapshot.getString("body"))
        assertEquals("only", snapshot.getString("access"))
        assertEquals("https://fixture.test/config", snapshot.getString("source"))
        bytes.fill(0)
        assertNotEquals(0.toByte(), h.core.runningInput(loaded.generation, value.composition)!![0])
        h.core.recordChoice(loaded.generation + 1, "Proxy", mapOf("type" to "select", "member" to "Wrong"))
        h.core.recordChoice(loaded.generation, "Proxy", mapOf("type" to "select", "member" to "Confirmed"))
        val chosen = org.json.JSONObject(h.core.runningInput(loaded.generation, value.composition)!!.toString(Charsets.UTF_8))
        assertEquals("Confirmed", chosen.getJSONObject("choices").getJSONObject("Proxy").getString("member"))
        h.session.stopping(generation)
        h.core.cancelVpn(generation)
        assertNull(h.core.applicationAccess(generation))
        assertNull(h.core.runningInput(loaded.generation, value.composition))
        assertNull(h.core.stopVpn(generation))
        h.session.finished(generation, null)
        assertNull(h.core.runningInput(loaded.generation, value.composition))
    }

    @Test fun failedVpnPrepareNeverProjectsApplicationAccess() {
        val h = harness()
        val generation = h.session.begin("one", 1)!!
        h.prepareError = "failed"
        try {
            h.core.prepareVpn(generation, "one", 1, "unused", { input }, Any())
            fail("failed VPN preparation accepted")
        } catch (_: IllegalStateException) { }
        assertNull(h.core.applicationAccess(generation))
        h.session.finished(generation, null)
        assertNull(h.core.applicationAccess(generation))
    }

    @Test fun previewNeverExposesVpnInput() {
        val h = harness()
        val loaded = preview(h)
        assertNull(h.core.runningInput(loaded.generation, input.composition))
        assertNull(h.core.applicationAccess(h.session.snapshot().generation))
        h.core.releasePreview()
    }

    @Test fun admittedResourceIoBlocksReuseButNotStopUntilActualReturn() {
        val h = harness()
        val loaded = preview(h)
        assertFalse(h.core.beginResourceUpdate(loaded.generation, "wrong"))
        assertTrue(h.core.beginResourceUpdate(loaded.generation, input.composition))
        assertNull(h.core.releasePreview())
        try { preview(h, "next"); fail("admitted old JNI call reused new lease") }
        catch (_: IllegalStateException) { }
        assertEquals(1, h.prepares.get())
        assertEquals(1, h.stops.get())
        h.core.endResourceUpdate()
        assertEquals(CoreHost.Phase.READY, preview(h, "next").phase)
        h.core.releasePreview()
    }

    @Test fun previewReusesOnlyMatchingFallbackOperationChoicesAndLoadedNames() {
        val h = harness()
        fun prepare(mode: String?, operation: String? = null, name: String = "Loaded main", choices: String = "{}"): CoreHost.Snapshot =
            h.core.preparePreview("preview", "one", 1, "unused", { true }) {
                CoreInput("one", 1, mode, "mode: global".toByteArray(), choices.toByteArray(),
                    routingOverride = operation, name = name)
            }
        val first = prepare(null)
        assertEquals(first.generation, prepare(null).generation)
        val fallback = prepare("rule")
        assertTrue(fallback.generation > first.generation)
        val operation = prepare("rule", "direct")
        assertTrue(operation.generation > fallback.generation)
        val renamed = prepare("rule", "direct", name = "New loaded name")
        assertTrue(renamed.generation > operation.generation)
        val selected = prepare("rule", "direct", name = "New loaded name",
            choices = "{\"group\":{\"type\":\"select\",\"member\":\"DIRECT\"}}")
        assertTrue(selected.generation > renamed.generation)
        assertNull(h.core.releasePreview())
    }

    @Test fun nativeOptionsUseTheSameLoadedIdentityMetadataAndCurrentOperation() {
        val h = harness()
        val vpn = h.session.begin("one", 1)!!
        val value = CoreInput("one", 1, null, byteArrayOf(), "{}".toByteArray(),
            routingOverride = "global", name = "Loaded name, not later disk")
        val loaded = h.core.prepareVpn(vpn, "one", 1, "unused", { value }, Any())
        val options = org.json.JSONObject((h.callback as NativeCore.PreparationCallbacks).preparationOptions().toString(Charsets.UTF_8))
        assertEquals("VPN", options.getString("purpose"))
        assertEquals(loaded.generation, options.getLong("generation"))
        assertEquals(value.composition, options.getString("composition"))
        assertEquals("global", options.getString("routingOverride"))
        assertEquals("Loaded name, not later disk", options.getJSONObject("mainOrigin").getString("name"))
        h.session.attached(vpn)
        val snapshot = org.json.JSONObject(h.core.runningInput(loaded.generation, value.composition)!!.toString(Charsets.UTF_8))
        assertTrue(snapshot.has("mode") && snapshot.isNull("mode"))
        assertEquals("global", snapshot.getString("routingOverride"))
        h.session.stopping(vpn); h.core.cancelVpn(vpn); h.core.stopVpn(vpn); h.session.finished(vpn, null)
    }

    @Test fun routeRefreshRevisionsInvalidateRevertsAndLateOldOwnerCallbacks() {
        val h = harness()
        val vpn = h.session.begin("one", 1)!!
        val loaded = h.core.prepareVpn(vpn, "one", 1, "unused", { input }, Any())
        h.session.attached(vpn)
        val callback = h.callback as NativeCore.PreparationCallbacks
        callback.specificationChanged(loaded.generation + 1, input.composition, 2, true)
        callback.specificationChanged(loaded.generation, "other", 2, true)
        main { }
        assertTrue(h.refreshes.isEmpty())
        callback.specificationChanged(loaded.generation, input.composition, 2, true)
        main { }
        assertEquals(listOf(vpn, loaded.generation, input.composition, 2L, "routes"), h.refreshes.single())
        assertTrue(h.core.runtimeRefreshCurrent(vpn, loaded.generation, input.composition, 2, "routes"))
        callback.specificationChanged(loaded.generation, input.composition, 3, false)
        assertFalse(h.core.runtimeRefreshCurrent(vpn, loaded.generation, input.composition, 2, "routes"))
        assertFalse(h.core.runtimeRefreshCurrent(vpn, loaded.generation, input.composition, 3, "routes"))
        callback.specificationChanged(loaded.generation, input.composition, 2, true)
        assertFalse(h.core.runtimeRefreshCurrent(vpn, loaded.generation, input.composition, 2, "routes"))
        h.session.stopping(vpn); h.core.cancelVpn(vpn); h.core.stopVpn(vpn); h.session.finished(vpn, null)
        val next = preview(h, "new")
        callback.specificationChanged(loaded.generation, input.composition, 4, true)
        main { }
        assertEquals(1, h.refreshes.size)
        assertTrue(h.core.current(next.generation))
        h.core.releasePreview()
    }

    @Test fun routeUpdateArrivingBeforeRunningIsDispatchedOnceSessionIsRunning() {
        val h = harness()
        val vpn = h.session.begin("one", 1)!!
        val loaded = h.core.prepareVpn(vpn, "one", 1, "unused", { input }, Any())
        val callback = h.callback as NativeCore.PreparationCallbacks
        // Preserve the attached STARTING lease until RUNNING can process its pending
        // revision.
        callback.specificationChanged(loaded.generation, input.composition, 2, true)
        main { }
        assertTrue(h.refreshes.isEmpty())
        h.session.attached(vpn)
        h.core.sessionRunning(vpn)
        main { }
        assertEquals(listOf(vpn, loaded.generation, input.composition, 2L, "routes"), h.refreshes.single())
        assertTrue(h.core.runtimeRefreshCurrent(vpn, loaded.generation, input.composition, 2, "routes"))
        h.session.stopping(vpn); h.core.cancelVpn(vpn); h.core.stopVpn(vpn); h.session.finished(vpn, null)
    }

    @Test fun staleRunningNotificationCannotRefreshAReplacementSession() {
        val h = harness()
        val vpn = h.session.begin("one", 1)!!
        val loaded = h.core.prepareVpn(vpn, "one", 1, "unused", { input }, Any())
        val callback = h.callback as NativeCore.PreparationCallbacks
        callback.specificationChanged(loaded.generation, input.composition, 2, true)
        main { }
        h.session.attached(vpn)
        h.session.stopping(vpn); h.core.cancelVpn(vpn); h.core.stopVpn(vpn); h.session.finished(vpn, null)
        val next = h.session.begin("one", 1)!!
        h.core.prepareVpn(next, "one", 1, "unused", { input }, Any())
        h.core.sessionRunning(vpn)
        main { }
        assertTrue(h.refreshes.isEmpty())
        h.session.stopping(next); h.core.cancelVpn(next); h.core.stopVpn(next); h.session.finished(next, null)
    }

    @Test fun pendingRouteDeliveryUsesOnlyTheLatestRevisionAndDoesNotDuplicateRunningHandoff() {
        val h = harness()
        val vpn = h.session.begin("one", 1)!!
        val loaded = h.core.prepareVpn(vpn, "one", 1, "unused", { input }, Any())
        val callback = h.callback as NativeCore.PreparationCallbacks
        main {
            callback.specificationChanged(loaded.generation, input.composition, 2, true)
            callback.specificationChanged(loaded.generation, input.composition, 3, true)
            assertTrue(h.session.attached(vpn))
            h.core.sessionRunning(vpn)
        }
        main { }
        assertEquals(listOf(listOf(vpn, loaded.generation, input.composition, 3L, "routes")), h.refreshes)
        h.core.sessionRunning(vpn)
        main { }
        assertEquals(1, h.refreshes.size)
        assertFalse(h.core.runtimeRefreshCurrent(vpn, loaded.generation, input.composition, 2, "routes"))
        h.session.stopping(vpn); h.core.cancelVpn(vpn); h.core.stopVpn(vpn); h.session.finished(vpn, null)
    }

    @Test fun routeRevertBeforeRunningCancelsAllQueuedRefreshes() {
        val h = harness()
        val vpn = h.session.begin("one", 1)!!
        val loaded = h.core.prepareVpn(vpn, "one", 1, "unused", { input }, Any())
        val callback = h.callback as NativeCore.PreparationCallbacks
        main {
            callback.specificationChanged(loaded.generation, input.composition, 2, true)
            callback.specificationChanged(loaded.generation, input.composition, 3, false)
            assertTrue(h.session.attached(vpn))
            h.core.sessionRunning(vpn)
        }
        main { }
        assertTrue(h.refreshes.isEmpty())
        assertFalse(h.core.runtimeRefreshCurrent(vpn, loaded.generation, input.composition, 3, "routes"))
        h.session.stopping(vpn); h.core.cancelVpn(vpn); h.core.stopVpn(vpn); h.session.finished(vpn, null)
    }

    @Test fun systemDnsAndRoutesPendingDuringStartingBothReachTheRunningLease() {
        val h = harness()
        val vpn = h.session.begin("one", 1)!!
        val loaded = h.core.prepareVpn(vpn, "one", 1, "unused", { input }, Any())
        val network = UnderlyingSnapshot(null, listOf("192.0.2.53"), "off", UnderlyingNetworks.snapshot().revision + 1)
        h.core.underlyingChanged(network)
        h.tasks.poll(2, TimeUnit.SECONDS)!!.run()
        (h.callback as NativeCore.PreparationCallbacks).specificationChanged(loaded.generation, input.composition, 2, true)
        main { }
        assertTrue(h.refreshes.isEmpty())
        assertEquals("192.0.2.53", h.networkUpdates.single().getJSONArray("servers").getString(0))
        main { assertTrue(h.session.attached(vpn)); h.core.sessionRunning(vpn) }
        main { }
        assertEquals(setOf(
            listOf(vpn, loaded.generation, input.composition, 2L, "routes"),
            listOf(vpn, loaded.generation, input.composition, network.revision, "systemDns"),
        ), h.refreshes.toSet())
        assertEquals(2, h.refreshes.size)
        h.core.sessionRunning(vpn)
        main { }
        assertEquals(2, h.refreshes.size)
        h.session.stopping(vpn); h.core.cancelVpn(vpn)
        assertFalse(h.core.runtimeRefreshCurrent(vpn, loaded.generation, input.composition, network.revision, "systemDns"))
        h.core.stopVpn(vpn); h.session.finished(vpn, null)
    }

    @Test fun newerNetworkRevertInvalidatesPendingDnsAndRejectsOlderQueuedSnapshots() {
        val h = harness()
        val vpn = h.session.begin("one", 1)!!
        val loaded = h.core.prepareVpn(vpn, "one", 1, "unused", { input }, Any())
        val first = UnderlyingSnapshot(null, listOf("192.0.2.53"), "off", UnderlyingNetworks.snapshot().revision + 1)
        h.core.underlyingChanged(first)
        h.tasks.poll(2, TimeUnit.SECONDS)!!.run()
        h.networkRestart = false
        h.core.underlyingChanged(first.copy(revision = first.revision + 1))
        h.tasks.poll(2, TimeUnit.SECONDS)!!.run()
        h.core.underlyingChanged(first)
        h.tasks.poll(2, TimeUnit.SECONDS)!!.run()
        main { assertTrue(h.session.attached(vpn)); h.core.sessionRunning(vpn) }
        main { }
        assertEquals(2, h.networkUpdates.size)
        assertTrue(h.refreshes.isEmpty())
        assertFalse(h.core.runtimeRefreshCurrent(vpn, loaded.generation, input.composition, first.revision, "systemDns"))
        h.networkRestart = true
        val newest = first.copy(revision = first.revision + 2)
        h.core.underlyingChanged(newest)
        h.tasks.poll(2, TimeUnit.SECONDS)!!.run()
        main { }
        assertEquals(listOf(vpn, loaded.generation, input.composition, newest.revision, "systemDns"), h.refreshes.single())
        h.session.stopping(vpn); h.core.cancelVpn(vpn); h.core.stopVpn(vpn); h.session.finished(vpn, null)
    }

    @Test fun queuedOldNetworkCallbackCannotUpdateAReplacementLease() {
        val h = harness()
        val vpn = h.session.begin("one", 1)!!
        h.core.prepareVpn(vpn, "one", 1, "unused", { input }, Any())
        h.core.underlyingChanged(UnderlyingSnapshot(null, listOf("192.0.2.53"), "off", UnderlyingNetworks.snapshot().revision + 1))
        val old = h.tasks.poll(2, TimeUnit.SECONDS)!!
        h.session.stopping(vpn); h.core.cancelVpn(vpn); h.core.stopVpn(vpn); h.session.finished(vpn, null)
        val replacement = preview(h, "replacement")
        old.run()
        main { }
        assertTrue(h.networkUpdates.isEmpty())
        assertTrue(h.refreshes.isEmpty())
        assertTrue(h.core.current(replacement.generation))
        assertNull(h.core.releasePreview())
    }

    @Test fun cancelledRunningHandoffCannotPublishPendingWork() {
        val h = harness()
        val vpn = h.session.begin("one", 1)!!
        val loaded = h.core.prepareVpn(vpn, "one", 1, "unused", { input }, Any())
        main {
            (h.callback as NativeCore.PreparationCallbacks).specificationChanged(loaded.generation, input.composition, 2, true)
            assertTrue(h.session.attached(vpn))
            h.core.sessionRunning(vpn)
            assertTrue(h.session.stopping(vpn))
            h.core.cancelVpn(vpn)
        }
        main { }
        assertTrue(h.refreshes.isEmpty())
        assertNull(h.core.stopVpn(vpn)); h.session.finished(vpn, null)
    }

    @Test fun geoPublicationAndCancellationUseTheSameLeaseArbitration() {
        val h = harness()
        preview(h, "geo-owner")
        val owner = h.callback as io.github.monadboxlab.clashpseudo.nativecore.BundledGeo.Owner
        var published = 0
        owner.publishIfCurrent { published++ }
        main { h.core.cancelPreparation("geo-owner") }
        try { owner.publishIfCurrent { published++ }; fail("cancelled Geo owner published") }
        catch (_: IllegalStateException) { }
        assertEquals(1, published)
        h.tasks.poll(2, TimeUnit.SECONDS)!!.run()
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
    }

    @Test fun platformLimitMessageKeepsNestedReasonAndUnknownErrorsGeneric() {
        val detail = NativePreparationFailure.from("{\"id\":\"nativeConfigurationUnsupported\",\"args\":{\"field\":\"tun.include-android-user\",\"reason\":{\"id\":\"nativeReasonAndroidUserUnavailable\",\"args\":{}}}}").detail!!.toMap()
        val args = detail["args"] as Map<*, *>
        assertEquals("nativeConfigurationUnsupported", detail["id"])
        assertEquals("nativeReasonAndroidUserUnavailable", (args["reason"] as Map<*, *>)["id"])
        assertNull(NativePreparationFailure.from("secret parse URL/error").detail)
        assertNull(NativePreparationFailure.from("{\"id\":\"nativeConfigurationUnsupported\",\"args\":{\"field\":\"tun\",\"reason\":{\"id\":\"inventedSecret\"}}}").detail)
    }

    @Test fun authorityLostAfterInputPublicationNeverEntersNativePreparation() {
        val h = harness()
        try {
            h.core.preparePreview("expiring", "one", 1, "unused",
                { h.core.snapshot().composition == null }) { input }
            fail("an expired metadata preparation entered native")
        } catch (_: IllegalStateException) { }
        assertEquals(0, h.prepares.get())
        assertNull(h.callback)
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
        assertEquals(NativeSession.Phase.STOPPED, h.session.snapshot().phase)
    }

    @Test fun revokedPreviewRequestRejectsLateNativeCompletion() {
        val h = harness()
        try {
            h.core.preparePreview("cancelled", "one", 1, "unused", { true }) {
                h.core.cancelPreparation("cancelled")
                input
            }
            fail("cancelled preparation became ready")
        } catch (_: IllegalStateException) { }
        assertEquals(0, h.prepares.get())
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
        assertEquals(0, h.cancels.get())
    }
}
