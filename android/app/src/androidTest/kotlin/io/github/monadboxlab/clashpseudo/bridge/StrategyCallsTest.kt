package io.github.monadboxlab.clashpseudo.bridge

import io.github.monadboxlab.clashpseudo.app.AppFiles
import io.github.monadboxlab.clashpseudo.app.AppMessage
import io.github.monadboxlab.clashpseudo.app.AppStrings

import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.nativecore.CoreInput
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class StrategyCallsTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private val choice = mapOf("type" to "select", "member" to "节点🌐")
    private val input = CoreInput("one", 1, "rule", byteArrayOf(), "{}".toByteArray())

    private class Harness {
        val session = NativeSession()
        val tasks = LinkedBlockingQueue<Runnable>()
        val changes = AtomicInteger()
        val stops = AtomicInteger()
        val notifications = AtomicInteger()
        val replies = AtomicInteger()
        val error = AtomicReference<AppMessage?>()
        val value = AtomicReference<String?>()
        val done = CountDownLatch(1)
        lateinit var core: CoreHost
        lateinit var calls: StrategyCalls
        fun reply(result: String?, failure: AppMessage?) {
            value.set(result)
            error.set(failure)
            replies.incrementAndGet()
            done.countDown()
        }
    }

    private fun harness(set: ((ByteArray) -> String)? = null,
                        prepare: (() -> String)? = null,
                        prepareTimeoutMs: Long = 100): Harness {
        val h = Harness()
        main {
            h.core = CoreHost(h.session, {}, Executor { h.tasks.add(it) },
                prepareNative = { _, _, _, _, _, _ -> prepare?.invoke() ?: "" },
                stopNative = { h.stops.incrementAndGet(); "" }, cancelNative = {})
            h.core.setVisible(true)
            h.calls = StrategyCalls(h.core, { h.notifications.incrementAndGet() }, { "{}" },
                set ?: { bytes ->
                    val request = JSONObject(bytes.toString(Charsets.UTF_8))
                    assertEquals("出口🌐", request.getString("name"))
                    assertEquals("节点🌐", request.getJSONObject("choice").getString("member"))
                    h.changes.incrementAndGet()
                    ""
                }, readTimeoutMs = 100, changeTimeoutMs = 100, prepareTimeoutMs = prepareTimeoutMs)
        }
        return h
    }

    private fun running(h: Harness): Long {
        val vpn = h.session.begin("one", 1)!!
        val core = h.core.prepareVpn(vpn, "one", 1, "unused", { input }, Any())
        h.session.attached(vpn)
        return core.generation
    }

    @Test fun changesUseUtf8AndKeepVpnRunning() {
        val h = harness()
        val generation = running(h)
        main { h.calls.change(generation, "one", "出口🌐", choice, h::reply) }
        h.tasks.take().run()
        assertTrue(h.done.await(2, TimeUnit.SECONDS))
        instrumentation.waitForIdleSync()
        assertNull(h.error.get())
        assertEquals(1, h.changes.get())
        assertEquals(1, h.notifications.get())
        assertEquals(0, h.stops.get())
        assertEquals(NativeSession.Phase.RUNNING, h.session.snapshot().phase)
        val retained = JSONObject(h.core.runningInput(generation, input.composition)!!.toString(Charsets.UTF_8))
        assertEquals("节点🌐", retained.getJSONObject("choices").getJSONObject("出口🌐").getString("member"))
    }

    @Test fun failedNativeChoiceDoesNotEnterRunningInput() {
        val h = harness(set = { "not-confirmed" })
        val generation = running(h)
        main { h.calls.change(generation, "one", "出口🌐", choice, h::reply) }
        h.tasks.take().run()
        assertTrue(h.done.await(2, TimeUnit.SECONDS))
        assertNotNull(h.error.get())
        val retained = JSONObject(h.core.runningInput(generation, input.composition)!!.toString(Charsets.UTF_8))
        assertEquals(0, retained.getJSONObject("choices").length())
    }

    @Test fun queuedTimeoutDoesNotApplyOrStopVpn() {
        val h = harness()
        val generation = running(h)
        main { h.calls.change(generation, "one", "出口🌐", choice, h::reply) }
        assertTrue(h.done.await(2, TimeUnit.SECONDS))
        h.tasks.take().run()
        instrumentation.waitForIdleSync()
        assertNotNull(h.error.get())
        assertEquals(1, h.replies.get())
        assertEquals(0, h.changes.get())
        assertEquals(0, h.stops.get())
        assertTrue(h.core.current(generation))
    }

    @Test fun abandonedQueuedChoiceDoesNotExecute() {
        val h = harness()
        val generation = running(h)
        main {
            h.calls.change(generation, "one", "出口🌐", choice, h::reply)
            h.calls.abandon("one")
        }
        h.tasks.take().run()
        instrumentation.waitForIdleSync()
        assertEquals(1, h.replies.get())
        assertNotNull(h.error.get())
        assertEquals(0, h.changes.get())
        assertTrue(h.core.current(generation))
    }

    @Test fun executingTimeoutRepliesOnceAndNotifiesLateCompletion() {
        val entered = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val h = harness(set = {
            entered.countDown()
            check(finish.await(3, TimeUnit.SECONDS))
            ""
        })
        val generation = running(h)
        main { h.calls.change(generation, "one", "出口🌐", choice, h::reply) }
        val thread = Thread { h.tasks.take().run() }.apply { start() }
        try {
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            assertTrue(h.done.await(2, TimeUnit.SECONDS))
            assertNotNull(h.error.get())
        } finally {
            finish.countDown()
            thread.join(2000)
        }
        assertFalse(thread.isAlive)
        instrumentation.waitForIdleSync()
        assertEquals(1, h.replies.get())
        assertEquals(1, h.notifications.get())
        assertEquals(0, h.stops.get())
        assertTrue(h.core.current(generation))
    }

    @Test fun previewReuseRequiresTheSameCompleteComposition() {
        val h = harness()
        val first = h.core.preparePreview("first", "one", 1, "unused", { true }) { input }
        val reused = h.core.preparePreview("same", "one", 1, "unused", { true }) { input }
        assertEquals(first.generation, reused.generation)
        assertEquals(0, h.stops.get())
        val changed = CoreInput("one", 1, "rule", byteArrayOf(), "{}".toByteArray(),
            """[{"id":"part","revision":2,"mode":"replace","body":"{}"}]""".toByteArray(),
            "[\"one\",1,[\"part\",2,\"replace\"]]")
        val next = h.core.preparePreview("next", "one", 1, "unused", { true }) { changed }
        assertTrue(next.generation > first.generation)
        assertEquals(changed.composition, next.composition)
        assertEquals(1, h.stops.get())
        assertFalse(h.core.current(first.generation))
        assertTrue(h.core.current(next.generation))
        assertNull(h.core.releasePreview())
    }

    @Test fun oldReadCannotConfirmReplacementContext() {
        val h = harness()
        val old = h.core.preparePreview("old", "one", 1, "unused", { true }) { input }
        main { h.calls.read(old.generation, null, h::reply) }
        h.core.releasePreview()
        val next = h.core.preparePreview("next", "one", 1, "unused", { true }) { input }
        h.tasks.take().run()
        assertTrue(h.done.await(2, TimeUnit.SECONDS))
        assertNotNull(h.error.get())
        assertNull(h.value.get())
        assertTrue(h.core.current(next.generation))
        assertNull(h.core.releasePreview())
    }

    @Test fun nullableFallbackReachesPreparationAndPreservesTypedFailure() {
        val detail = AppMessage("nativeConfigurationUnsupported", mapOf(
            "field" to "tun.mtu", "reason" to AppMessage("nativeReasonInvalidMtu")))
        val h = harness(prepare = { JSONObject(detail.toMap()).toString() }, prepareTimeoutMs = 5000)
        val context = instrumentation.targetContext
        val owner = "strategy-null-mode-${System.nanoTime()}"
        val file = AppFiles.runInput(context, owner)
        file.parentFile!!.mkdirs()
        file.writeText(JSONObject().put("id", "one").put("revision", 1)
            .put("mode", JSONObject.NULL).put("body", "tun: {mtu: 0}")
            .put("choices", JSONObject()).put("access", "all")
            .put("packages", org.json.JSONArray()).put("overrides", org.json.JSONArray())
            .put("composition", input.composition).toString())
        try {
            main { h.calls.prepare(context, owner, "one", 1, null, h::reply) }
            h.tasks.take().run()
            assertTrue(h.done.await(2, TimeUnit.SECONDS))
            assertEquals(detail.toMap(), h.error.get()?.toMap())
            assertNull(h.value.get())
            assertEquals(1, h.replies.get())
            assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
            assertEquals(NativeSession.Phase.STOPPED, h.session.snapshot().phase)
        } finally {
            file.delete()
        }
    }

    @Test fun emptyModeIsNotTheNullableFallback() {
        val h = harness()
        main { h.calls.prepare(instrumentation.targetContext, "invalid", "one", 1, "", h::reply) }
        assertTrue(h.done.await(2, TimeUnit.SECONDS))
        assertEquals(AppStrings.message(io.github.monadboxlab.clashpseudo.R.string.error_strategy_params).toMap(),
            h.error.get()?.toMap())
        assertTrue(h.tasks.isEmpty())
    }

    @Test fun expiredPreparationCleansItsLateNativeResult() {
        val entered = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val h = harness(prepare = {
            entered.countDown()
            check(finish.await(3, TimeUnit.SECONDS))
            ""
        })
        val context = instrumentation.targetContext
        val owner = "strategy-test-${System.nanoTime()}"
        val file = AppFiles.runInput(context, owner)
        file.parentFile!!.mkdirs()
        file.writeText(JSONObject().put("id", "one").put("revision", 1)
            .put("mode", "rule").put("body", "").put("choices", JSONObject())
            .put("access", "all").put("packages", org.json.JSONArray())
            .put("overrides", org.json.JSONArray()).put("composition", input.composition).toString())
        var thread: Thread? = null
        try {
            main { h.calls.prepare(context, owner, "one", 1, "rule", h::reply) }
            thread = Thread { h.tasks.take().run() }.apply { start() }
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            assertTrue(h.done.await(2, TimeUnit.SECONDS))
            assertNotNull(h.error.get())
        } finally {
            finish.countDown()
            thread?.join(2000)
            file.delete()
        }
        assertFalse(thread!!.isAlive)
        instrumentation.waitForIdleSync()
        assertEquals(1, h.replies.get())
        assertEquals(1, h.stops.get())
        assertEquals(CoreHost.Phase.EMPTY, h.core.snapshot().phase)
        assertEquals(NativeSession.Phase.STOPPED, h.session.snapshot().phase)
    }
}
