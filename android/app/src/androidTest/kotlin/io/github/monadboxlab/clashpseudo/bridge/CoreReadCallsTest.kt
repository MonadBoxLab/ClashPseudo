package io.github.monadboxlab.clashpseudo.bridge

import io.github.monadboxlab.clashpseudo.app.AppMessage

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

class CoreReadCallsTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)

    @Test fun dnsTimeoutRetainsActualGateAndOwnerCancellationCannotTouchReplacement() {
        val coreTasks = LinkedBlockingQueue<Runnable>()
        val dnsTasks = LinkedBlockingQueue<Runnable>()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val timedOut = CountDownLatch(1)
        val cancelled = AtomicReference<Long>()
        val replies = AtomicInteger()
        lateinit var core: CoreHost
        lateinit var calls: CoreReadCalls
        main {
            core = CoreHost(NativeSession(), {}, Executor { coreTasks.add(it) },
                prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {})
            core.setVisible(true)
            calls = CoreReadCalls(core, queryDns = { body ->
                assertTrue(JSONObject(String(body, Charsets.UTF_8)).getLong("requestId") > 0)
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                "{\"rcode\":0}"
            }, cancelDns = { cancelled.set(it) }, dnsWorker = Executor { dnsTasks.add(it) },
                dnsTimeoutMs = 100, networkEpoch = { 7 })
        }
        val source = core.preparePreview("dns", "main", 1, "unused", { true }) {
            CoreInput("main", 1, null, byteArrayOf(), "{}".toByteArray())
        }
        var io: Thread? = null
        try {
            main { calls.dnsQuery(source.generation, source.composition, mapOf("name" to "test.test", "type" to "A"), "owner-one") { value, error ->
                replies.incrementAndGet()
                assertNull(error)
                val result = JSONObject(value!!)
                assertEquals("timeout", result.getJSONObject("dns").getString("error"))
                assertEquals(7L, result.getLong("networkEpoch"))
                assertEquals("PREVIEW", result.getString("purpose"))
                assertEquals("main", result.getString("configId"))
                assertEquals(1, result.getInt("revision"))
                timedOut.countDown()
            } }
            coreTasks.take().run()
            io = Thread(dnsTasks.take()).apply { start() }
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            assertTrue(timedOut.await(2, TimeUnit.SECONDS))
            assertNotNull(cancelled.get())
            main {
                assertTrue(calls.dnsBusy)
                calls.dnsQuery(source.generation, source.composition, mapOf("name" to "other.test", "type" to "A"), "owner-two") { value, error ->
                    assertNull(error)
                    assertEquals("busy", JSONObject(value!!).getJSONObject("dns").getString("error"))
                }
                calls.cancelDnsQuery(source.generation, source.composition, "wrong-owner")
                assertTrue(calls.dnsBusy)
            }
            release.countDown()
            io.join(2000)
            assertFalse(io.isAlive)
            coreTasks.take().run() // real JNI completion admission drain
            instrumentation.waitForIdleSync()
            main { assertFalse(calls.dnsBusy) }
            assertEquals(1, replies.get())
        } finally { release.countDown(); io?.join(2000); core.releasePreview() }
    }

    @Test fun dnsCancellationBeforeWorkerEntryRetainsSlotAndRejectsOldOwner() {
        val tasks = LinkedBlockingQueue<Runnable>()
        val reads = AtomicInteger()
        val cancels = AtomicInteger()
        lateinit var core: CoreHost
        lateinit var calls: CoreReadCalls
        main {
            core = CoreHost(NativeSession(), {}, Executor { tasks.add(it) },
                prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {})
            core.setVisible(true)
            calls = CoreReadCalls(core, queryDns = { reads.incrementAndGet(); "{}" }, cancelDns = { cancels.incrementAndGet() },
                dnsWorker = Executor { it.run() }, networkEpoch = { 4 })
        }
        val source = core.preparePreview("dns", "main", 1, "unused", { true }) { CoreInput("main", 1, null, byteArrayOf(), "{}".toByteArray()) }
        try {
            main {
                calls.dnsQuery(source.generation, source.composition, mapOf("name" to "test.test", "type" to "A"), "new-page") { value, error ->
                    assertNull(error)
                    assertEquals("cancelled", JSONObject(value!!).getJSONObject("dns").getString("error"))
                }
                calls.cancelDnsQuery(source.generation, source.composition, "old-page")
                assertEquals(0, cancels.get())
                calls.cancelDnsQuery(source.generation, source.composition, "new-page")
                assertEquals(1, cancels.get())
                assertTrue(calls.dnsBusy)
            }
            tasks.take().run()
            instrumentation.waitForIdleSync()
            assertEquals(0, reads.get())
            main { assertFalse(calls.dnsBusy) }
        } finally { core.releasePreview() }
    }

    @Test fun dnsAndBothCacheActionsCarryFullIdentityAndRejectNetworkChangedDuringRead() {
        val tasks = LinkedBlockingQueue<Runnable>()
        val epoch = AtomicInteger(9)
        val clears = AtomicInteger()
        val flushes = AtomicInteger()
        lateinit var core: CoreHost
        lateinit var calls: CoreReadCalls
        main {
            core = CoreHost(NativeSession(), {}, Executor { tasks.add(it) },
                prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {})
            core.setVisible(true)
            calls = CoreReadCalls(core, queryDns = { epoch.incrementAndGet(); "{}" }, cancelDns = {},
                clearDns = { clears.incrementAndGet(); "{\"status\":\"completed\",\"resolverActive\":true,\"systemResolverActive\":false}" },
                flushFakeIpNative = { flushes.incrementAndGet(); "{\"status\":\"empty\",\"persistent\":false,\"ipv4\":{\"active\":false,\"outcome\":\"inactive\"},\"ipv6\":{\"active\":false,\"outcome\":\"inactive\"}}" },
                dnsWorker = Executor { it.run() }, networkEpoch = { epoch.get().toLong() })
        }
        val source = core.preparePreview("dns", "main", 1, "unused", { true }) { CoreInput("main", 1, null, byteArrayOf(), "{}".toByteArray()) }
        try {
            for (fake in listOf(false, true)) {
                val done = CountDownLatch(1)
                val reply: (String?, AppMessage?) -> Unit = { value, error ->
                    assertNull(error)
                    val data = JSONObject(value!!)
                    assertEquals(source.generation, data.getLong("generation"))
                    assertEquals(source.composition, data.getString("composition"))
                    assertEquals("main", data.getString("configId"))
                    assertEquals(1, data.getInt("revision"))
                    assertEquals("PREVIEW", data.getString("purpose"))
                    assertEquals(9L, data.getLong("networkEpoch"))
                    assertEquals(if (fake) "empty" else "completed", data.getJSONObject("cache").getString("status"))
                    done.countDown()
                }
                main { if (fake) calls.flushFakeIp(source.generation, source.composition, reply) else calls.clearDnsCache(source.generation, source.composition, reply) }
                tasks.take().run()
                tasks.take().run()
                assertTrue(done.await(2, TimeUnit.SECONDS))
            }
            assertEquals(1, clears.get()); assertEquals(1, flushes.get())
            val invalidated = CountDownLatch(1)
            main { calls.dnsQuery(source.generation, source.composition, mapOf("name" to "test.test", "type" to "A")) { value, error ->
                assertNull(value); assertNotNull(error); invalidated.countDown()
            } }
            tasks.take().run(); tasks.take().run()
            assertTrue(invalidated.await(2, TimeUnit.SECONDS))
        } finally { core.releasePreview() }
    }

    @Test fun dnsWireLimitIncludesTheUnchangedCompleteIdentityEnvelope() {
        val tasks = LinkedBlockingQueue<Runnable>()
        lateinit var core: CoreHost
        lateinit var calls: CoreReadCalls
        main {
            core = CoreHost(NativeSession(), {}, Executor { tasks.add(it) },
                prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {})
            core.setVisible(true)
            calls = CoreReadCalls(core, queryDns = {
                val prefix = "{\"question\":{\"name\":\"test.test.\",\"type\":\"TXT\"},\"rcode\":0,\"rcodeName\":\"NOERROR\",\"elapsedMs\":1,\"truncated\":false,\"answer\":[{\"name\":\"test.test.\",\"type\":\"TXT\",\"class\":\"IN\",\"ttl\":60,\"data\":\""
                val suffix = "\"}],\"authority\":[],\"additional\":[]}"
                prefix + "x".repeat(256*1024 - 64 - prefix.length - suffix.length) + suffix
            }, cancelDns = {}, dnsWorker = Executor { it.run() }, networkEpoch = { 2 })
        }
        val source = core.preparePreview("dns", "main", 1, "unused", { true }) { CoreInput("main", 1, null, byteArrayOf(), "{}".toByteArray()) }
        try {
            val done = CountDownLatch(1)
            main { calls.dnsQuery(source.generation, source.composition, mapOf("name" to "test.test", "type" to "TXT")) { value, error ->
                assertNull(error)
                assertTrue(value!!.toByteArray(Charsets.UTF_8).size <= 256*1024)
                val result = JSONObject(value)
                assertEquals("resultTooLarge", result.getJSONObject("dns").getString("error"))
                assertFalse(result.getJSONObject("dns").has("answer"))
                assertEquals(source.generation, result.getLong("generation"))
                assertEquals(source.composition, result.getString("composition"))
                assertEquals("main", result.getString("configId"))
                assertEquals(1, result.getInt("revision"))
                assertEquals("PREVIEW", result.getString("purpose"))
                assertEquals(2L, result.getLong("networkEpoch"))
                done.countDown()
            } }
            tasks.take().run(); tasks.take().run()
            assertTrue(done.await(2, TimeUnit.SECONDS))
        } finally { core.releasePreview() }
    }

    @Test fun recentLogsKeepActualSourceAfterStopAndPreparationFailures() {
        var window: String? = null
        var rejectedBeforeBuffer = false
        var failPrepare = false
        lateinit var core: CoreHost
        main {
            core = CoreHost(NativeSession(), {}, Executor { it.run() },
                prepareNative = { _, _, _, _, _, _ ->
                    if (!rejectedBeforeBuffer) window = if (window == "one") "two" else "one"
                    if (failPrepare || rejectedBeforeBuffer) "failed" else ""
                }, stopNative = { "" }, cancelNative = {}, readLogWindow = { window })
            core.setVisible(true)
        }
        val input = CoreInput("main", 1, "rule", byteArrayOf(), "{}".toByteArray())
        try {
            val original = core.preparePreview("original", "main", 1, "unused", { true }) { input }
            assertEquals("one", core.logSource()!!.logWindow)
            core.releasePreview()
            val recent = core.logSource()!!
            assertFalse(core.current(original.generation))
            assertEquals(CoreHost.Phase.EMPTY, recent.phase)
            assertEquals(original.generation, recent.generation)
            assertEquals(original.composition, recent.composition)
            rejectedBeforeBuffer = true
            try {
                core.preparePreview("rejected", "main", 1, "unused", { true }) { input }
                fail("preparation should fail")
            } catch (_: IllegalStateException) { }
            assertEquals(recent, core.logSource())
            rejectedBeforeBuffer = false
            failPrepare = true
            try {
                core.preparePreview("failed", "main", 1, "unused", { true }) { input }
                fail("preparation should fail")
            } catch (_: IllegalStateException) { }
            val failed = core.logSource()!!
            assertEquals("two", failed.logWindow)
            assertTrue(failed.generation > recent.generation)
            assertEquals(input.composition, failed.composition)
            assertEquals(CoreHost.Purpose.PREVIEW, failed.purpose)
            try {
                core.preparePreview("input-failed", "main", 1, "unused", { true }) { error("unreadable input") }
                fail("input should fail")
            } catch (_: IllegalStateException) { }
            assertEquals(failed, core.logSource())
        } finally { core.releasePreview() }
    }

    @Test fun stoppedLogsReadTheirWindowAndRejectReplacementBeforeExecutionOrReply() {
        val tasks = LinkedBlockingQueue<Runnable>()
        val queries = AtomicInteger()
        var window: String? = null
        lateinit var core: CoreHost
        lateinit var calls: CoreReadCalls
        main {
            core = CoreHost(NativeSession(), {}, Executor { tasks.add(it) },
                prepareNative = { _, _, _, _, _, _ -> window = if (window == "one") "two" else "one"; "" },
                stopNative = { "" }, cancelNative = {}, readLogWindow = { window })
            core.setVisible(true)
            calls = CoreReadCalls(core, getLogs = {
                queries.incrementAndGet()
                "{\"window\":\"$window\",\"entries\":[],\"next\":0,\"total\":0,\"dropped\":0}"
            })
        }
        val input = CoreInput("main", 1, "rule", byteArrayOf(), "{}".toByteArray())
        try {
            val source = core.preparePreview("first", "main", 1, "unused", { true }) { input }
            core.releasePreview()
            val done = CountDownLatch(1)
            main { calls.logs(source.generation, source.composition, mapOf("window" to "one")) { value, error ->
                assertNull(error)
                assertEquals(source.generation, JSONObject(value!!).getLong("generation"))
                assertEquals("one", JSONObject(value).getJSONObject("logs").getString("window"))
                done.countDown()
            } }
            tasks.take().run()
            assertTrue(done.await(2, TimeUnit.SECONDS))
            assertEquals(1, queries.get())
            val stale = CountDownLatch(1)
            main { calls.logs(source.generation, source.composition, mapOf("window" to "one")) { value, error ->
                assertNull(value); assertNotNull(error); stale.countDown()
            } }
            core.preparePreview("replacement", "main", 1, "unused", { true }) { input }
            tasks.take().run()
            assertTrue(stale.await(2, TimeUnit.SECONDS))
            assertEquals(1, queries.get())
            val latest = core.logSource()!!
            val raced = CountDownLatch(1)
            main {
                calls.logs(latest.generation, latest.composition, mapOf("window" to "two")) { value, error ->
                    assertNull(value); assertNotNull(error); raced.countDown()
                }
                tasks.take().run()
                core.releasePreview()
                core.preparePreview("next", "main", 1, "unused", { true }) { input }
            }
            assertTrue(raced.await(2, TimeUnit.SECONDS))
            assertEquals(2, queries.get())
        } finally { core.releasePreview() }
    }

    @Test fun queryChecksCompositionBeforeExecutionAndBeforeReply() {
        val tasks = LinkedBlockingQueue<Runnable>()
        val queries = AtomicInteger()
        lateinit var core: CoreHost
        lateinit var calls: CoreReadCalls
        main {
            core = CoreHost(NativeSession(), {}, Executor { tasks.add(it) },
                prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {})
            core.setVisible(true)
            calls = CoreReadCalls(core, { queries.incrementAndGet(); "{\"mode\":\"rule\"}" })
        }
        val input = CoreInput("main", 1, "rule", byteArrayOf(), "{}".toByteArray())
        try {
            val source = core.preparePreview("fixture", "main", 1, "unused", { true }) { input }
            main { calls.read(source.generation, "wrong") { value, error ->
                assertNull(value); assertNotNull(error)
            } }
            assertTrue(tasks.isEmpty())
            val done = CountDownLatch(1)
            val result = AtomicReference<String?>()
            main { calls.read(source.generation, source.composition) { value, error ->
                assertNull(error); result.set(value); done.countDown()
            } }
            tasks.take().run()
            assertTrue(done.await(2, TimeUnit.SECONDS))
            assertEquals(source.composition, JSONObject(result.get()!!).getString("composition"))
            assertEquals("rule", JSONObject(result.get()!!).getJSONObject("configuration").getString("mode"))
            assertEquals(1, queries.get())
            val stale = CountDownLatch(1)
            main { calls.read(source.generation, source.composition) { value, error ->
                assertNull(value); assertNotNull(error); stale.countDown()
            } }
            core.releasePreview()
            core.preparePreview("replacement", "main", 1, "unused", { true }) { input }
            tasks.take().run()
            assertTrue(stale.await(2, TimeUnit.SECONDS))
            assertEquals(1, queries.get())
        } finally { core.releasePreview() }
    }

    @Test fun pageReadTimeoutAndBusyReportActualPendingWithoutQueueingOrReleasingSlot() {
        val tasks = LinkedBlockingQueue<Runnable>()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val timedOut = CountDownLatch(1)
        val replies = AtomicInteger()
        val rules = AtomicInteger()
        lateinit var core: CoreHost
        lateinit var calls: CoreReadCalls
        main {
            core = CoreHost(NativeSession(), {}, Executor { tasks.add(it) },
                prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {})
            core.setVisible(true)
            calls = CoreReadCalls(core, timeoutMs = 100,
                getNodes = {
                    entered.countDown()
                    check(release.await(3, TimeUnit.SECONDS))
                    "{}"
                }, getRules = { rules.incrementAndGet(); "{}" })
        }
        var task: Thread? = null
        try {
            val source = core.preparePreview("fixture", "main", 1, "unused", { true }) {
                CoreInput("main", 1, "rule", byteArrayOf(), "{}".toByteArray())
            }
            fun pending(value: String?, error: AppMessage?) {
                assertNull(error)
                val data = JSONObject(value!!)
                assertTrue(data.getBoolean("readPending"))
                assertEquals(source.generation, data.getLong("generation"))
                assertEquals(source.composition, data.getString("composition"))
                assertEquals(source.configId, data.getString("configId"))
                assertEquals(source.revision, data.getInt("revision"))
                assertEquals(source.purpose!!.name, data.getString("purpose"))
                assertFalse(data.has("page"))
            }
            main { calls.nodes(source.generation, source.composition, emptyMap()) { value, error ->
                pending(value, error); replies.incrementAndGet(); timedOut.countDown()
            } }
            task = Thread(tasks.take()).apply { start() }
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            main { calls.rules(source.generation, source.composition, emptyMap(), ::pending) }
            assertTrue(tasks.isEmpty())
            assertEquals(0, rules.get())
            assertTrue(timedOut.await(2, TimeUnit.SECONDS))
            main { calls.rules(source.generation, source.composition, emptyMap(), ::pending) }
            assertTrue(tasks.isEmpty())
            main { calls.nodes(source.generation, "stale", emptyMap()) { value, error ->
                assertNull(value); assertNotNull(error)
            } }
            release.countDown()
            task.join(2000)
            instrumentation.waitForIdleSync()
            assertEquals(1, replies.get())
            val done = CountDownLatch(1)
            main { calls.rules(source.generation, source.composition, emptyMap()) { value, error ->
                assertNull(error)
                assertTrue(JSONObject(value!!).has("page"))
                done.countDown()
            } }
            tasks.take().run()
            assertTrue(done.await(2, TimeUnit.SECONDS))
            assertEquals(1, rules.get())
        } finally {
            release.countDown()
            task?.join(2000)
            core.releasePreview()
        }
    }

    @Test fun slowPagesResumeTheirOneRealCompletionThenRefreshExecutesAgain() {
        for (nodes in listOf(true, false)) {
            val tasks = LinkedBlockingQueue<Runnable>()
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            val timedOut = CountDownLatch(1)
            val reads = AtomicInteger()
            lateinit var core: CoreHost
            lateinit var calls: CoreReadCalls
            val read: (ByteArray) -> String = {
                val count = reads.incrementAndGet()
                if (count == 1) {
                    entered.countDown()
                    check(release.await(8, TimeUnit.SECONDS))
                }
                "{\"execution\":$count}"
            }
            main {
                core = CoreHost(NativeSession(), {}, Executor { tasks.add(it) },
                    prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {})
                core.setVisible(true)
                // Use the production three-second deadline.
                calls = CoreReadCalls(core, getNodes = read, getRules = read)
            }
            var worker: Thread? = null
            try {
                val source = core.preparePreview("slow-page", "main", 1, "unused", { true }) {
                    CoreInput("main", 1, "rule", byteArrayOf(), "{}".toByteArray())
                }
                val request = mapOf<String, Any?>("search" to "same", "offset" to 0)
                fun query(reply: (String?, AppMessage?) -> Unit) {
                    if (nodes) calls.nodes(source.generation, source.composition, request, reply)
                    else calls.rules(source.generation, source.composition, request, reply)
                }
                main { query { value, error ->
                    assertNull(error)
                    assertTrue(JSONObject(value!!).getBoolean("readPending"))
                    timedOut.countDown()
                } }
                worker = Thread(tasks.take()).apply { start() }
                assertTrue(entered.await(2, TimeUnit.SECONDS))
                assertTrue(timedOut.await(5, TimeUnit.SECONDS))
                main { query { value, error ->
                    assertNull(error)
                    assertTrue(JSONObject(value!!).getBoolean("readPending"))
                } }
                assertTrue(tasks.isEmpty())
                release.countDown()
                worker.join(2000)
                assertFalse(worker.isAlive)
                instrumentation.waitForIdleSync()
                main { query { value, error ->
                    assertNull(error)
                    val result = JSONObject(value!!)
                    assertEquals(1, result.getJSONObject("page").getInt("execution"))
                    assertEquals(source.generation, result.getLong("generation"))
                    assertEquals(source.configId, result.getString("configId"))
                    assertEquals(source.revision, result.getInt("revision"))
                    assertEquals(source.composition, result.getString("composition"))
                    assertEquals(source.purpose!!.name, result.getString("purpose"))
                } }
                assertTrue(tasks.isEmpty())
                assertEquals(1, reads.get())
                val refreshed = CountDownLatch(1)
                main { query { value, error ->
                    assertNull(error)
                    assertEquals(2, JSONObject(value!!).getJSONObject("page").getInt("execution"))
                    refreshed.countDown()
                } }
                tasks.take().run()
                assertTrue(refreshed.await(2, TimeUnit.SECONDS))
                assertEquals(2, reads.get())
            } finally {
                release.countDown()
                worker?.join(2000)
                core.releasePreview()
            }
        }
    }

    @Test fun pageDeadlineBeforeWorkerAdmissionStillResumesTheRealPayload() {
        val tasks = LinkedBlockingQueue<Runnable>()
        val timedOut = CountDownLatch(1)
        val reads = AtomicInteger()
        lateinit var core: CoreHost
        lateinit var calls: CoreReadCalls
        main {
            core = CoreHost(NativeSession(), {}, Executor { tasks.add(it) },
                prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {})
            core.setVisible(true)
            calls = CoreReadCalls(core, timeoutMs = 100,
                getNodes = { reads.incrementAndGet(); "{\"ready\":true}" })
        }
        try {
            val source = core.preparePreview("queued-page", "main", 1, "unused", { true }) {
                CoreInput("main", 1, "rule", byteArrayOf(), "{}".toByteArray())
            }
            main { calls.nodes(source.generation, source.composition, emptyMap()) { value, error ->
                assertNull(error)
                assertTrue(JSONObject(value!!).getBoolean("readPending"))
                timedOut.countDown()
            } }
            assertTrue(timedOut.await(2, TimeUnit.SECONDS))
            assertEquals(0, reads.get())
            tasks.take().run()
            instrumentation.waitForIdleSync()
            main { calls.nodes(source.generation, source.composition, emptyMap()) { value, error ->
                assertNull(error)
                assertTrue(JSONObject(value!!).getJSONObject("page").getBoolean("ready"))
            } }
            assertEquals(1, reads.get())
            assertTrue(tasks.isEmpty())
        } finally { core.releasePreview() }
    }

    @Test fun latePagesNeverCrossQueryMethodIdentityOrTheirShortLifetime() {
        for (boundary in listOf("query", "method", "identity", "superseded", "expired", "error")) {
            val tasks = LinkedBlockingQueue<Runnable>()
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            val timedOut = CountDownLatch(1)
            val reads = AtomicInteger()
            lateinit var core: CoreHost
            lateinit var calls: CoreReadCalls
            main {
                core = CoreHost(NativeSession(), {}, Executor { tasks.add(it) },
                    prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {})
                core.setVisible(true)
                calls = CoreReadCalls(core, timeoutMs = 100, getNodes = { body ->
                    val count = reads.incrementAndGet()
                    if (count == 1) {
                        entered.countDown()
                        check(release.await(3, TimeUnit.SECONDS))
                        if (boundary == "error") error("actual read failure")
                    }
                    JSONObject().put("search", JSONObject(String(body)).getString("search")).toString()
                }, getRules = { reads.incrementAndGet(); "{\"search\":\"rules\"}" })
            }
            var worker: Thread? = null
            try {
                val input = CoreInput("main", 1, "rule", byteArrayOf(), "{}".toByteArray())
                var source = core.preparePreview("late-page", "main", 1, "unused", { true }) { input }
                val original = mapOf<String, Any?>("search" to "original")
                main { calls.nodes(source.generation, source.composition, original) { value, error ->
                    assertNull(error)
                    assertTrue(JSONObject(value!!).getBoolean("readPending"))
                    timedOut.countDown()
                } }
                worker = Thread(tasks.take()).apply { start() }
                assertTrue(entered.await(2, TimeUnit.SECONDS))
                assertTrue(timedOut.await(2, TimeUnit.SECONDS))
                if (boundary == "superseded") main {
                    calls.nodes(source.generation, source.composition, mapOf("search" to "latest")) { value, error ->
                        assertNull(error)
                        assertTrue(JSONObject(value!!).getBoolean("readPending"))
                    }
                }
                if (boundary == "identity") {
                    core.releasePreview()
                    source = core.preparePreview("replacement", "main", 1, "unused", { true }) { input }
                }
                release.countDown()
                worker.join(2000)
                assertFalse(worker.isAlive)
                instrumentation.waitForIdleSync()
                if (boundary == "expired") Thread.sleep(10100)
                val done = CountDownLatch(1)
                main {
                    val reply: (String?, AppMessage?) -> Unit = { value, error ->
                        if (boundary == "error") {
                            assertNull(value); assertNotNull(error)
                        } else {
                            assertNull(error)
                            val expected = when (boundary) {
                                "query" -> "different"
                                "method" -> "rules"
                                else -> "original"
                            }
                            assertEquals(expected, JSONObject(value!!).getJSONObject("page").getString("search"))
                        }
                        done.countDown()
                    }
                    if (boundary == "method") calls.rules(source.generation, source.composition, original, reply)
                    else calls.nodes(source.generation, source.composition,
                        if (boundary == "query") mapOf("search" to "different") else original, reply)
                }
                if (boundary == "error") {
                    assertTrue(tasks.isEmpty())
                    assertEquals(1, reads.get())
                } else {
                    // A mismatched or expired continuation schedules a fresh
                    // execution.
                    assertEquals(1, tasks.size)
                    tasks.take().run()
                }
                assertTrue(done.await(2, TimeUnit.SECONDS))
                assertEquals(if (boundary == "error") 1 else 2, reads.get())
            } finally {
                release.countDown()
                worker?.join(2000)
                core.releasePreview()
            }
        }
    }

    @Test fun resourcesReplyCarriesTheRowListNotTheCoreEnvelope() {
        val tasks = LinkedBlockingQueue<Runnable>()
        lateinit var core: CoreHost
        lateinit var calls: CoreReadCalls
        main {
            core = CoreHost(NativeSession(), {}, Executor { tasks.add(it) },
                prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {})
            core.setVisible(true)
            calls = CoreReadCalls(core, getResources = {
                "{\"resources\":[{\"kind\":\"geo\",\"name\":\"GeoIP\",\"vehicleType\":\"File\",\"source\":\"\",\"updateSupported\":false}]}"
            })
        }
        try {
            val source = core.preparePreview("fixture", "main", 1, "unused", { true }) {
                CoreInput("main", 1, "rule", byteArrayOf(), "{}".toByteArray())
            }
            val done = CountDownLatch(1)
            val result = AtomicReference<String?>()
            main { calls.resources(source.generation, source.composition) { value, error ->
                assertNull(error); result.set(value); done.countDown()
            } }
            tasks.take().run()
            assertTrue(done.await(2, TimeUnit.SECONDS))
            val rows = JSONObject(result.get()!!).getJSONArray("resources")
            assertEquals("GeoIP", rows.getJSONObject(0).getString("name"))
        } finally { core.releasePreview() }
    }

    @Test fun resourceUpdateLeavesCoreWorkerFreeAndRejectsReusedContextUntilCompletion() {
        val tasks = LinkedBlockingQueue<Runnable>()
        val updates = LinkedBlockingQueue<Runnable>()
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val stopped = AtomicInteger()
        lateinit var core: CoreHost
        lateinit var calls: CoreReadCalls
        main {
            core = CoreHost(NativeSession(), {}, Executor { tasks.add(it) },
                prepareNative = { _, _, _, _, _, _ -> "" },
                stopNative = { stopped.incrementAndGet(); "" }, cancelNative = {})
            core.setVisible(true)
            calls = CoreReadCalls(core, getConfiguration = { "{\"mode\":\"rule\"}" },
                updateResource = {
                    started.countDown()
                    check(release.await(3, TimeUnit.SECONDS))
                    "{}"
                }, updateWorker = Executor { updates.add(it) })
        }
        var io: Thread? = null
        try {
            val input = CoreInput("main", 1, "rule", byteArrayOf(), "{}".toByteArray())
            val source = core.preparePreview("fixture", "main", 1, "unused", { true }) { input }
            val updateDone = CountDownLatch(1)
            main { calls.update(source.generation, source.composition, mapOf("kind" to "geo", "name" to "GeoIP")) { value, error ->
                assertNull(value); assertNotNull(error); updateDone.countDown()
            } }
            tasks.take().run()
            io = Thread(updates.take())
            io.start()
            assertTrue(started.await(2, TimeUnit.SECONDS))
            val readDone = CountDownLatch(1)
            main { calls.read(source.generation, source.composition) { value, error ->
                assertNotNull(value); assertNull(error); readDone.countDown()
            } }
            tasks.take().run()
            assertTrue(readDone.await(2, TimeUnit.SECONDS))
            assertNull(core.releasePreview())
            assertEquals(1, stopped.get())
            try {
                core.preparePreview("replacement", "main", 1, "unused", { true }) { input }
                fail("new native context accepted before the old I/O call returned")
            } catch (_: IllegalStateException) { }
            release.countDown()
            io.join(2000)
            assertFalse(io.isAlive)
            tasks.take().run()
            assertTrue(updateDone.await(2, TimeUnit.SECONDS))
            assertEquals(CoreHost.Phase.READY,
                core.preparePreview("replacement", "main", 1, "unused", { true }) { input }.phase)
        } finally {
            release.countDown()
            io?.join(2000)
            core.releasePreview()
        }
    }

    @Test fun stoppedQueuedResourceUpdateNeverEntersNativeOnReplacementContext() {
        val tasks = LinkedBlockingQueue<Runnable>()
        val updates = LinkedBlockingQueue<Runnable>()
        val nativeUpdates = AtomicInteger()
        lateinit var core: CoreHost
        lateinit var calls: CoreReadCalls
        main {
            core = CoreHost(NativeSession(), {}, Executor { tasks.add(it) },
                prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {})
            core.setVisible(true)
            calls = CoreReadCalls(core, updateResource = { nativeUpdates.incrementAndGet(); "{}" },
                updateWorker = Executor { updates.add(it) })
        }
        try {
            val input = CoreInput("main", 1, "rule", byteArrayOf(), "{}".toByteArray())
            val source = core.preparePreview("fixture", "main", 1, "unused", { true }) { input }
            val done = CountDownLatch(1)
            main { calls.update(source.generation, source.composition, mapOf("kind" to "geo", "name" to "GeoIP")) { value, error ->
                assertNull(value); assertNotNull(error); done.countDown()
            } }
            tasks.take().run()
            core.releasePreview()
            try {
                core.preparePreview("replacement", "main", 1, "unused", { true }) { input }
                fail("queued resource I/O did not retain its admission")
            } catch (_: IllegalStateException) { }
            updates.take().run()
            tasks.take().run()
            assertTrue(done.await(2, TimeUnit.SECONDS))
            assertEquals(0, nativeUpdates.get())
            assertEquals(CoreHost.Phase.READY,
                core.preparePreview("replacement", "main", 1, "unused", { true }) { input }.phase)
        } finally { core.releasePreview() }
    }

    @Test fun resourceTimeoutDoesNotReleaseIoAdmissionOrReplyTwice() {
        val tasks = LinkedBlockingQueue<Runnable>()
        val updates = LinkedBlockingQueue<Runnable>()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val timeout = CountDownLatch(1)
        val replies = AtomicInteger()
        lateinit var core: CoreHost
        lateinit var calls: CoreReadCalls
        main {
            core = CoreHost(NativeSession(), {}, Executor { tasks.add(it) },
                prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {})
            core.setVisible(true)
            calls = CoreReadCalls(core, updateResource = {
                entered.countDown()
                check(release.await(3, TimeUnit.SECONDS))
                "{\"status\":\"ok\"}"
            }, updateWorker = Executor { updates.add(it) }, updateTimeoutMs = 500)
        }
        var io: Thread? = null
        try {
            val input = CoreInput("main", 1, "rule", byteArrayOf(), "{}".toByteArray())
            val source = core.preparePreview("fixture", "main", 1, "unused", { true }) { input }
            main { calls.update(source.generation, source.composition, mapOf("kind" to "geo", "name" to "GeoIP")) { value, error ->
                assertNull(value); assertNotNull(error); replies.incrementAndGet(); timeout.countDown()
            } }
            tasks.take().run()
            io = Thread(updates.take())
            io.start()
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            assertTrue(timeout.await(2, TimeUnit.SECONDS))
            main { assertTrue(calls.updating) }
            assertNull(core.releasePreview())
            try {
                core.preparePreview("replacement", "main", 1, "unused", { true }) { input }
                fail("timeout reopened the native admission")
            } catch (_: IllegalStateException) { }
            release.countDown()
            io.join(2000)
            tasks.take().run()
            instrumentation.waitForIdleSync()
            main { assertFalse(calls.updating) }
            assertEquals(1, replies.get())
            assertEquals(CoreHost.Phase.READY,
                core.preparePreview("replacement", "main", 1, "unused", { true }) { input }.phase)
        } finally {
            release.countDown()
            io?.join(2000)
            core.releasePreview()
        }
    }

    @Test fun canceledResourceOwnerNeverEntersNativeEvenWithoutCoreReplacement() {
        for (cancelBeforeAdmission in listOf(true, false)) {
            val tasks = LinkedBlockingQueue<Runnable>()
            val updates = LinkedBlockingQueue<Runnable>()
            val nativeUpdates = AtomicInteger()
            val changes = AtomicInteger()
            val authorized = java.util.concurrent.atomic.AtomicBoolean(true)
            lateinit var core: CoreHost
            lateinit var calls: CoreReadCalls
            main {
                core = CoreHost(NativeSession(), {}, Executor { tasks.add(it) },
                    prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {})
                core.setVisible(true)
                calls = CoreReadCalls(core, updateResource = { nativeUpdates.incrementAndGet(); "{}" },
                    updateWorker = Executor { updates.add(it) }, updateChanged = { changes.incrementAndGet() })
            }
            try {
                val source = core.preparePreview("fixture", "main", 1, "unused", { true }) {
                    CoreInput("main", 1, "rule", byteArrayOf(), "{}".toByteArray())
                }
                val done = CountDownLatch(1)
                main {
                    calls.update(source.generation, source.composition,
                        mapOf("kind" to "geo", "name" to "GeoIP"), authorized = { authorized.get() }) { value, error ->
                        assertNull(value); assertNotNull(error); done.countDown()
                    }
                    assertTrue(calls.updating)
                }
                if (cancelBeforeAdmission) authorized.set(false)
                tasks.take().run()
                if (!cancelBeforeAdmission) {
                    authorized.set(false)
                    assertTrue(calls.updating)
                    updates.take().run()
                    tasks.take().run()
                }
                assertTrue(done.await(2, TimeUnit.SECONDS))
                main { assertFalse(calls.updating) }
                assertEquals(0, nativeUpdates.get())
                assertEquals(2, changes.get())
                assertTrue(core.current(source.generation))
            } finally { core.releasePreview() }
        }
    }

    @Test fun timedOutQueuedReadDoesNotQueryAndRepliesOnce() {
        val tasks = LinkedBlockingQueue<Runnable>()
        val queries = AtomicInteger()
        val replies = AtomicInteger()
        lateinit var core: CoreHost
        lateinit var calls: CoreReadCalls
        main {
            core = CoreHost(NativeSession(), {}, Executor { tasks.add(it) },
                prepareNative = { _, _, _, _, _, _ -> "" }, stopNative = { "" }, cancelNative = {})
            core.setVisible(true)
            calls = CoreReadCalls(core, { queries.incrementAndGet(); "{}" }, timeoutMs = 50)
        }
        try {
            val source = core.preparePreview("fixture", "main", 1, "unused", { true }) {
                CoreInput("main", 1, "rule", byteArrayOf(), "{}".toByteArray())
            }
            val done = CountDownLatch(1)
            main { calls.read(source.generation, source.composition) { value, error ->
                assertNull(value); assertNotNull(error); replies.incrementAndGet(); done.countDown()
            } }
            assertTrue(done.await(2, TimeUnit.SECONDS))
            tasks.take().run()
            instrumentation.waitForIdleSync()
            assertEquals(0, queries.get())
            assertEquals(1, replies.get())
        } finally { core.releasePreview() }
    }
}
