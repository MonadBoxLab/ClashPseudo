package io.github.monadboxlab.clashpseudo.bridge.core

import android.content.Intent
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import io.github.monadboxlab.clashpseudo.MainActivity
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.logic.LogicEngineHost
import io.github.monadboxlab.clashpseudo.nativecore.CoreIpcTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CoreClient
import io.github.monadboxlab.clashpseudo.nativecore.CoreFrames
import io.github.monadboxlab.clashpseudo.nativecore.CorePlatformTestDriver
import io.github.monadboxlab.clashpseudo.nativecore.CoreResourceGate
import io.github.monadboxlab.clashpseudo.nativecore.input.CoreInput
import io.github.monadboxlab.clashpseudo.storage.AppFiles
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.collection
import io.github.monadboxlab.clashpseudo.bridge.core.CoreBridgeIpcScenario.Companion.failure
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class DelayCallsTest {
    private fun runtimeFailure(message: String, work: List<Map<String, Any?>> = emptyList()): IllegalStateException {
        val failure = IllegalStateException(message)
        try {
            var facts: Map<String, Any?> = emptyMap()
            CoreIpcTestDriver.onMain {
                val host = AppBridge.logic
                fun field(name: String): Any? = LogicEngineHost::class.java.getDeclaredField(name)
                    .apply { isAccessible = true }.get(host)
                facts = mapOf(
                    "snapshot" to AppBridge.runtimeState(),
                    "operationId" to AppBridge.operationId,
                    "command" to AppBridge.command,
                    "executorBusy" to AppBridge.operations.executorBusy,
                    "logicBusy" to host.busy,
                    "enginePresent" to (field("engine") != null),
                    "runtimeProjection" to host.runtimeProjection,
                    "runtimeFields" to listOf("serial", "ready", "platformOwners", "querying", "forwarding",
                        "releasingDetails", "syncing", "stateDirty").associateWith(::field),
                    "observationOwners" to (field("observationOwners") as Set<*>).toList(),
                    "waitingForReady" to (field("waitingForReady") as List<*>).size,
                    "startupWork" to work,
                )
            }
            failure.addSuppressed(IllegalStateException(JSONObject(facts).toString()))
        } catch (error: Throwable) {
            if (error !== failure) failure.addSuppressed(error)
        }
        return failure
    }

    private fun awaitStartup() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val manager = androidx.work.WorkManager.getInstance(context)
        val deadline = SystemClock.elapsedRealtime() + 30_000
        var work: List<Map<String, Any?>> = emptyList()
        while (true) {
            val remaining = deadline - SystemClock.elapsedRealtime()
            if (remaining <= 0) throw runtimeFailure("启动 WorkInfo 和实际 executor 没有结束", work)
            val infos = manager.getWorkInfosForUniqueWork("update-reconcile")
                .get(minOf(remaining, 5_000L), TimeUnit.MILLISECONDS)
            work = infos.map { mapOf("id" to it.id.toString(), "state" to it.state.name, "attempt" to it.runAttemptCount) }
            var drained = false
            CoreIpcTestDriver.onMain {
                val state = AppBridge.runtimeState()
                drained = AppBridge.operationId == null && !AppBridge.logic.busy &&
                    !AppBridge.operations.executorBusy && state["writerBusy"] == false &&
                    state["storageReady"] == true && state["storageRestoring"] != true
            }
            if (infos.isNotEmpty() && infos.all { it.state.isFinished } && drained) return
            if (SystemClock.elapsedRealtime() >= deadline) {
                throw runtimeFailure("启动 WorkInfo 和实际 executor 没有结束", work)
            }
            SystemClock.sleep(20)
        }
    }

    private fun awaitRuntime(message: String, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 45_000
        while (true) {
            var ready = false
            CoreIpcTestDriver.onMain { ready = condition() }
            if (ready) return
            if (SystemClock.elapsedRealtime() >= deadline) throw runtimeFailure(message)
            SystemClock.sleep(20)
        }
    }

    @Test fun realActivityReadsLocalInterfacesWithoutOwnerOrCore() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        awaitStartup()
        val owner = instrumentation.startActivitySync(Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        lateinit var handler: BinaryMessenger.BinaryMessageHandler
        var generation = -1L
        fun readInterfaces(): Map<*, *> {
            val completed = CompletableFuture<Map<*, *>>()
            CoreIpcTestDriver.onMain {
                val call = MethodCall(Contract.CORE_CHANNEL_LOCAL_INTERFACES, emptyMap<String, Any?>())
                val message = StandardMethodCodec.INSTANCE.encodeMethodCall(call).apply { flip() }
                handler.onMessage(message) { envelope ->
                    try {
                        val value = StandardMethodCodec.INSTANCE.decodeEnvelope(checkNotNull(envelope).apply { flip() })
                        completed.complete(value as Map<*, *>)
                    } catch (error: Throwable) { completed.completeExceptionally(error) }
                }
            }
            return completed.get(10, TimeUnit.SECONDS)
        }
        try {
            awaitStartup()
            CoreIpcTestDriver.onMain {
                val state = AppBridge.runtimeState()
                assertNull(AppBridge.operationId)
                assertEquals("STOPPED", state["phase"])
                assertEquals("EMPTY", (state["core"] as Map<*, *>)["phase"])
                generation = (state["generation"] as Number).toLong()
                // 从实际 Activity 的 engine 读取 attachUi 已注册的 production handler。
                val engine = io.flutter.embedding.android.FlutterActivity::class.java
                    .getDeclaredMethod("getFlutterEngine").apply { isAccessible = true }
                    .invoke(owner) as FlutterEngine
                assertTrue(engine.dartExecutor.isExecutingDart)
                val executor = engine.dartExecutor
                val messenger = executor.javaClass.getDeclaredField("dartMessenger").apply { isAccessible = true }.get(executor)
                val handlers = messenger.javaClass.getDeclaredField("messageHandlers").apply { isAccessible = true }
                    .get(messenger) as Map<*, *>
                val entry = checkNotNull(handlers[AppBridge.CHANNEL])
                handler = entry.javaClass.getDeclaredField("handler").apply { isAccessible = true }.get(entry)
                    as BinaryMessenger.BinaryMessageHandler
            }
            val actual = readInterfaces()
            assertNull(actual["error"])
            assertTrue((actual["revision"] as Number).toLong() > 0)
            val rows = actual["addresses"] as List<*>
            assertFalse(rows.isEmpty())
            for (value in rows) {
                val row = value as Map<*, *>
                val network = checkNotNull(java.net.NetworkInterface.getByName(row["interfaceName"] as String))
                assertEquals(network.index, (row["interfaceIndex"] as Number).toInt())
                assertTrue("接口地址必须来自实际 Android NetworkInterface", network.interfaceAddresses.any {
                    it.address?.hostAddress == row["address"] &&
                        it.networkPrefixLength.toInt() == (row["prefixLength"] as Number).toInt()
                })
                assertTrue(row["available"] is Boolean)
                assertTrue(row["selectable"] is Boolean)
                assertTrue(row["kind"] in setOf("unknown", "ethernet", "wifi", "cellular", "vpn", "loopback"))
            }
            val next = readInterfaces()
            assertNull(next["error"])
            assertTrue((next["revision"] as Number).toLong() >= (actual["revision"] as Number).toLong())
            CoreIpcTestDriver.onMain {
                val state = AppBridge.runtimeState()
                assertNull(AppBridge.operationId)
                assertEquals("STOPPED", state["phase"])
                assertEquals(generation, (state["generation"] as Number).toLong())
                assertEquals("EMPTY", (state["core"] as Map<*, *>)["phase"])
            }
            CoreIpcTestDriver.assertNoGoInApplication()
        } finally {
            CoreIpcTestDriver.onMain { owner.finish() }
        }
    }

    @Test fun hiddenOrDestroyedUiKeepsOnlyTheActualMemoryReadUntilItsReply() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val engineField = LogicEngineHost::class.java.getDeclaredField("engine").apply { isAccessible = true }
        val channelField = LogicEngineHost::class.java.getDeclaredField("channel").apply { isAccessible = true }
        val ownersField = LogicEngineHost::class.java.getDeclaredField("platformOwners").apply { isAccessible = true }
        val forwardingField = LogicEngineHost::class.java.getDeclaredField("forwarding").apply { isAccessible = true }
        awaitStartup()
        CoreIpcTestDriver.onMain {
            assertNull("freshRuntime 分组不能已有历史 logs window", AppBridge.logic.runtimeProjection["logSource"])
            assertFalse(AppBridge.logic.runtimeProjection["retain"] == true)
        }
        awaitRuntime("启动任务没有退出") {
            AppBridge.runtimeState()["writerBusy"] == false && ownersField.getInt(AppBridge.logic) == 0
        }
        val owner = instrumentation.startActivitySync(Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        lateinit var host: LogicEngineHost
        lateinit var engine: FlutterEngine
        var originalChannel: MethodChannel? = null
        val received = CompletableFuture<Pair<BinaryMessenger.BinaryReply, ByteBuffer?>>()
        val completed = CompletableFuture<Any?>()
        var delivered = false
        fun reply(future: CompletableFuture<Any?>) = object : MethodChannel.Result {
            override fun success(result: Any?) { future.complete(result) }
            override fun error(code: String, message: String?, details: Any?) {
                future.completeExceptionally(AssertionError("$code/$message/$details"))
            }
            override fun notImplemented() { future.completeExceptionally(AssertionError("appMemory 未实现")) }
        }
        try {
            awaitStartup()
            val warm = CompletableFuture<Any?>()
            CoreIpcTestDriver.onMain { host = AppBridge.logic; host.read("appMemory", emptyMap(), reply(warm)) }
            assertTrue(JSONObject(warm.get(30, TimeUnit.SECONDS) as String).getBoolean("valid"))
            CoreIpcTestDriver.onMain {
                assertEquals("EMPTY", (AppBridge.runtimeState()["core"] as Map<*, *>)["phase"])
                assertEquals(1, ownersField.getInt(host))
                engine = engineField.get(host) as FlutterEngine
                val actual = engine.dartExecutor.binaryMessenger
                var intercepted = false
                val observer = object : BinaryMessenger by actual {
                    override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)
                    override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
                        val call = if (channel == AppBridge.CHANNEL && message != null)
                            StandardMethodCodec.INSTANCE.decodeMethodCall(message.duplicate().apply { flip() }) else null
                        if (!intercepted && call?.method == "appMemory" && callback != null) {
                            intercepted = true
                            actual.send(channel, message) { response ->
                                // 保留真实 Dart 回复，只延后把已复制的 envelope 交给原接收者。
                                val copy = response?.let { ByteBuffer.allocateDirect(it.remaining()).apply { put(it.duplicate()); flip() } }
                                received.complete(callback to copy)
                            }
                        } else actual.send(channel, message, callback)
                    }
                }
                originalChannel = channelField.get(host) as MethodChannel
                channelField.set(host, MethodChannel(observer, AppBridge.CHANNEL))
                host.read("appMemory", emptyMap(), reply(completed))
            }
            received.get(30, TimeUnit.SECONDS)
            CoreIpcTestDriver.onMain { assertTrue(owner.moveTaskToBack(true)) }
            awaitRuntime("隐藏 Activity 后 runtime 引用没有释放") { ownersField.getInt(host) == 0 }
            CoreIpcTestDriver.onMain {
                assertSame(engine, engineField.get(host))
                assertEquals(1, forwardingField.getInt(host))
                assertFalse(completed.isDone)
                channelField.set(host, originalChannel)
                owner.finish()
            }
            awaitRuntime("Activity 没有销毁") { owner.isDestroyed }
            CoreIpcTestDriver.onMain {
                assertSame(engine, engineField.get(host))
                assertEquals(1, forwardingField.getInt(host))
                assertFalse(completed.isDone)
                val (callback, response) = received.getNow(null)
                delivered = true
                callback.reply(response)
            }
            assertTrue(JSONObject(completed.get(30, TimeUnit.SECONDS) as String).getBoolean("valid"))
            awaitRuntime("真实回复完成后 headless engine 没有释放") { engineField.get(host) == null }
            CoreIpcTestDriver.onMain {
                assertEquals(0, forwardingField.getInt(host))
                assertEquals(0, ownersField.getInt(host))
                assertFalse(host.busy)
            }
            CoreIpcTestDriver.assertNoGoInApplication()
        } finally {
            CoreIpcTestDriver.onMain {
                originalChannel?.let { if (engineField.get(host) != null) channelField.set(host, it) }
                owner.finish()
                if (!delivered && received.isDone && !received.isCompletedExceptionally) {
                    val (callback, response) = received.getNow(null)
                    delivered = true
                    callback.reply(response)
                }
            }
        }
    }

    @Test fun onlyTheCurrentRealActivityCanPublishVisibilityToTheRealDartRuntime() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val events = mutableListOf<Boolean>()
        lateinit var host: LogicEngineHost
        var originalChannel: MethodChannel? = null
        val channelField = LogicEngineHost::class.java.getDeclaredField("channel").apply { isAccessible = true }
        fun readMemory() {
            val reply = CompletableFuture<Any?>()
            CoreIpcTestDriver.onMain {
                host.read("appMemory", emptyMap(), object : MethodChannel.Result {
                    override fun success(result: Any?) { reply.complete(result) }
                    override fun error(code: String, message: String?, details: Any?) { reply.completeExceptionally(AssertionError("$code/$message/$details")) }
                    override fun notImplemented() { reply.completeExceptionally(AssertionError("appMemory 未实现")) }
                })
            }
            assertNotNull(reply.get(30, TimeUnit.SECONDS))
        }
        val old = instrumentation.startActivitySync(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        var current = old
        CoreIpcTestDriver.onMain { host = AppBridge.logic }
        try {
                readMemory()
                val engineField = LogicEngineHost::class.java.getDeclaredField("engine").apply { isAccessible = true }
                val serialField = LogicEngineHost::class.java.getDeclaredField("serial").apply { isAccessible = true }
                val ownersField = LogicEngineHost::class.java.getDeclaredField("platformOwners").apply { isAccessible = true }
                lateinit var retained: FlutterEngine
                var runtime = -1L
                CoreIpcTestDriver.onMain {
                    assertEquals("EMPTY", (AppBridge.runtimeState()["core"] as Map<*, *>)["phase"])
                    retained = engineField.get(host) as FlutterEngine
                    runtime = serialField.getLong(host)
                    assertTrue(ownersField.getInt(host) > 0)
                }
                repeat(3) {
                    readMemory()
                    CoreIpcTestDriver.onMain {
                        assertSame(retained, engineField.get(host))
                        assertEquals(runtime, serialField.getLong(host))
                        assertTrue(host.current(runtime))
                    }
                }
                val monitor = instrumentation.addMonitor(MainActivity::class.java.name, null, false)
                try {
                    CoreIpcTestDriver.onMain { old.recreate() }
                    current = checkNotNull(monitor.waitForActivityWithTimeout(20_000)) as MainActivity
                    instrumentation.waitForIdleSync()
                } finally { instrumentation.removeMonitor(monitor) }
                assertNotSame(old, current)
                readMemory()
                CoreIpcTestDriver.onMain {
                    val engine = engineField.get(host) as FlutterEngine
                    val retainedOwners = ownersField.getInt(host)
                    val actual = engine.dartExecutor.binaryMessenger
                    val observer = object : BinaryMessenger by actual {
                        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)
                        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
                            if (channel == AppBridge.CHANNEL && message != null) {
                                val copy = message.duplicate().apply { flip() }
                                val call = StandardMethodCodec.INSTANCE.decodeMethodCall(copy)
                                if (call.method == Contract.CORE_CHANNEL_EVENTS) {
                                    val value = call.arguments as? Map<*, *>
                                    if (value?.get("event") == "uiVisibility") events.add(value["visible"] as Boolean)
                                }
                            }
                            actual.send(channel, message, callback)
                        }
                    }
                    originalChannel = channelField.get(host) as MethodChannel
                    // 只观察并转发真实 messenger；Dart handler、engine 和返回路径保持不变。
                    channelField.set(host, MethodChannel(observer, AppBridge.CHANNEL))
                    AppBridge.setUiVisible(old, false)
                    AppBridge.detachUi(old)
                    assertTrue("旧 Activity 不得发送可见状态", events.isEmpty())
                    assertEquals(retainedOwners, ownersField.getInt(host))
                    assertSame(engine, engineField.get(host))
                    AppBridge.setUiVisible(current, false)
                    assertEquals(retainedOwners - 1, ownersField.getInt(host))
                    AppBridge.setUiVisible(current, true)
                    assertEquals(listOf(false, true), events)
                    assertEquals(retainedOwners, ownersField.getInt(host))
                    AppBridge.setUiVisible(current, true)
                    assertEquals(retainedOwners, ownersField.getInt(host))
                }
                readMemory()
                pendingStartAndActualBatchFollowCurrentActivity(host, old, current, events)
                CoreIpcTestDriver.assertNoGoInApplication()
        } finally {
            CoreIpcTestDriver.onMain {
                originalChannel?.let { channelField.set(host, it) }
                current.finish()
            }
        }
    }

    private fun pendingStartAndActualBatchFollowCurrentActivity(
        host: LogicEngineHost,
        old: MainActivity,
        current: MainActivity,
        events: MutableList<Boolean>,
    ) {
        val platform = CorePlatformTestDriver()
        val client = CoreClient.get(platform.context)
        val calls = CoreClient::class.java.getDeclaredField("calls").apply { isAccessible = true }.get(client) as Map<*, *>
        var visibility: Closeable? = null
        var probe: HeldHttpProbe? = null
        var gate: DelayChannelGate? = null
        var failure: Throwable? = null
        val pendingId = "00000000000000000000000000000001"
        val retryId = "00000000000000000000000000000002"
        CoreIpcTestDriver.production().use { observer ->
            try {
                visibility = platform.keepPreviewVisible()
                val http = HeldHttpProbe()
                probe = http
                val prepared = platform.prepare(CoreInput("migration-delay-visibility", 1, "rule",
                    CoreBridgeIpcScenario.STRATEGIES.toByteArray(Charsets.UTF_8), "{}".toByteArray(), name = "migration-delay-visibility"), vpn = false)
                assertTrue(prepared.terminal.toString(), prepared.terminal.getBoolean("complete"))
                val source = platform.status()
                assertEquals(observer.processId, source["processId"])
                val originalRecord = AppFiles.runRecord(platform.context, source["inputId"] as String).readBytes()
                visibilityRead(host, "runtimeConfig", source).value.get(10, TimeUnit.SECONDS)
                val channel = CoreIpcTestDriver.onMain { DelayChannelGate(host, observer.processId) }
                gate = channel
                fun start(id: String) = visibilityRead(host, "delayStart", source + mapOf("query" to mapOf(
                    "id" to id, "group" to "出口🌐", "members" to listOf("节点🌐"), "url" to http.url)))
                fun batch(id: String) = JSONObject(visibilityRead(host, "delayRead", mapOf("batch" to id))
                    .value.get(2, TimeUnit.SECONDS) as String)
                fun flushVisibility() { visibilityRead(host, "appMemory", emptyMap()).value.get(2, TimeUnit.SECONDS) }
                val first = start(pendingId)
                val strategy = channel.strategyAdmission.get(2, TimeUnit.SECONDS)
                assertFalse(first.value.isDone)
                val oldEvents = CoreIpcTestDriver.onMain { events.size }
                CoreIpcTestDriver.onMain {
                    AppBridge.setUiVisible(old, false)
                    AppBridge.detachUi(old)
                }
                flushVisibility()
                assertEquals(oldEvents, CoreIpcTestDriver.onMain { events.size })
                assertFalse("旧 Activity 不得终结同一次 pending delayStart", first.value.isDone)
                assertEquals(1, channel.strategySubmissions.get())
                assertEquals(0, channel.urlSubmissions.get())
                assertEquals(0, channel.cancellations.get())
                CoreIpcTestDriver.onMain { AppBridge.setUiVisible(current, false) }
                flushVisibility()
                assertEquals(oldEvents + 1, CoreIpcTestDriver.onMain { events.size })
                assertEquals(false, CoreIpcTestDriver.onMain { events.last() })
                assertFalse("内层真实 admission 未交付，pending start 必须仍等待原 work", first.value.isDone)
                CoreIpcTestDriver.onMain { channel.release(Contract.CORE_OPERATION_STRATEGIES) }
                val expired = try { first.value.get(2, TimeUnit.SECONDS); null }
                    catch (error: java.util.concurrent.ExecutionException) { error.cause }
                assertTrue(expired.toString(), expired is CorePlatformTestDriver.ChannelFailure)
                assertEquals("expired", (expired as CorePlatformTestDriver.ChannelFailure).code)
                assertEquals(1, first.replies.get())
                assertEquals(0, channel.urlSubmissions.get())
                assertTrue(channel.terminal(strategy).receipt.getBoolean("exited"))
                assertFalse(client.requestBusy)
                assertNull(CoreResourceGate.forApplication(platform.context).tryAcquire())

                CoreIpcTestDriver.onMain { AppBridge.setUiVisible(current, true) }
                flushVisibility()
                http.start()
                val retry = start(retryId)
                val started = JSONObject(retry.value.get(2, TimeUnit.SECONDS) as String)
                assertEquals(retryId, started.getJSONObject("start").getString("id"))
                assertFalse(started.getBoolean("stale"))
                assertEquals(1, retry.replies.get())
                val url = channel.urlAdmission.get(2, TimeUnit.SECONDS)
                http.entered.get(2, TimeUnit.SECONDS)
                assertEquals(1, channel.urlSubmissions.get())
                assertEquals(5000, (url.arguments["timeoutMs"] as Number).toInt())
                assertEquals("出口🌐", url.arguments["group"])
                assertEquals("节点🌐", url.arguments["name"])
                assertTrue(client.requestBusy)
                assertFalse(http.drained.isDone)
                val runningEvents = CoreIpcTestDriver.onMain { events.size }
                CoreIpcTestDriver.onMain { AppBridge.setUiVisible(old, false) }
                val running = batch(retryId)
                assertEquals(runningEvents, CoreIpcTestDriver.onMain { events.size })
                assertFalse(running.getBoolean("stale"))
                assertEquals("running", running.getJSONObject("batch").getString("state"))
                assertFalse(running.getJSONObject("batch").getBoolean("exited"))
                assertEquals(0, channel.cancellations.get())
                CoreIpcTestDriver.onMain { AppBridge.setUiVisible(current, false) }
                flushVisibility()
                val hidden = batch(retryId)
                assertTrue(hidden.getBoolean("stale"))
                assertEquals("expired", hidden.getJSONObject("batch").getString("state"))
                assertFalse(hidden.getJSONObject("batch").getBoolean("exited"))
                assertTrue("原 URL_TEST 的实际 FD/work 必须仍被持有", client.requestBusy)
                assertFalse("current hide 不能伪造实际 socket EOF", http.drained.isDone)
                assertFalse("取消不能把尚未交付 admission 的实际 work 标为 drain", channel.hasTerminal(url))
                assertTrue("不能延长原 member timeout", SystemClock.elapsedRealtime() - url.atMs < 5000L)
                CoreIpcTestDriver.onMain { channel.release(Contract.CORE_OPERATION_URL_TEST) }
                val cancellation = channel.cancelReply.get(2, TimeUnit.SECONDS)
                assertEquals(url.processId, cancellation.first.processId)
                assertEquals(url.requestId, cancellation.first.requestId)
                assertTrue(cancellation.second.getBoolean("cancelled"))
                assertEquals(url.requestId, cancellation.second.getLong("targetRequestId"))
                http.drained.get(2, TimeUnit.SECONDS)
                val end = SystemClock.elapsedRealtime() + 2000L
                var drained: JSONObject
                do {
                    channel.assertHealthy()
                    drained = batch(retryId)
                    if (drained.getJSONObject("batch").getBoolean("exited") && !client.requestBusy) break
                    check(SystemClock.elapsedRealtime() < end) { "真实 URL_TEST 未在取消后 drain" }
                    Thread.sleep(10)
                } while (true)
                assertTrue(drained.getBoolean("stale"))
                val actualBatch = drained.getJSONObject("batch")
                assertEquals("expired", actualBatch.getString("state"))
                val member = actualBatch.getJSONArray("members").getJSONObject(0)
                assertTrue(member.getBoolean("exited"))
                assertEquals("expired", member.getString("status"))
                val actual = member.getJSONObject("result")
                val transportError = channel.readError(url)
                val native = if (transportError == null) channel.terminal(url) else null
                val nativeReceipt: JSONObject
                if (native != null) {
                    nativeReceipt = native.receipt
                    assertTrue(nativeReceipt.getBoolean("exited"))
                    assertSameJson(nativeReceipt, actual.getJSONObject("terminal").getJSONObject("nativeReceipt"))
                    val originalError = native.terminal.opt("error").takeUnless { it == JSONObject.NULL }
                        ?: nativeReceipt.opt("error").takeUnless { it == JSONObject.NULL }
                        ?: native.value.opt("error").takeUnless { it == JSONObject.NULL }
                    assertSameJson(originalError ?: JSONObject.NULL, actual.opt("error") ?: JSONObject.NULL)
                } else {
                    val original = checkNotNull(transportError)
                    val details = JSONObject(original.details as String)
                    nativeReceipt = details.getJSONObject("nativeReceipt")
                    assertTrue(nativeReceipt.getBoolean("accepted"))
                    assertTrue(nativeReceipt.getBoolean("exited"))
                    assertEquals(url.requestId, nativeReceipt.getLong("requestId"))
                    assertEquals("cancelled", nativeReceipt.getJSONObject("error").getString("code"))
                    assertFalse(channel.hasTerminal(url))
                    val error = actual.getJSONObject("error")
                    assertEquals(original.code, error.getString("code"))
                    if (error.get("details") is String) {
                        assertEquals(original.message, error.getString("message"))
                        assertEquals(original.details, error.getString("details"))
                        assertSameJson(nativeReceipt, JSONObject(error.getString("details")).getJSONObject("nativeReceipt"))
                    } else {
                        val failure = error.getJSONObject("details")
                        assertSameJson(nativeReceipt, failure.getJSONObject("nativeReceipt"))
                        assertSameJson(cancellation.second, failure.getJSONObject("cancellation"))
                        val platformError = failure.getJSONObject("error")
                        assertEquals(original.code, platformError.getString("code"))
                        assertEquals(original.message, platformError.getString("message"))
                        assertEquals(original.details, platformError.get("details"))
                    }
                }
                assertEquals(1, channel.cancellations.get())
                assertEquals(1, first.replies.get())
                assertEquals(1, retry.replies.get())
                assertFalse("原 URL_TEST 的实际调用与 FD 已从请求表移除", calls.containsKey(url.processId to url.requestId))
                visibilityRead(host, "delayCancel", mapOf("batch" to retryId)).value.get(2, TimeUnit.SECONDS)
                CoreIpcTestDriver.onMain { AppBridge.setUiVisible(current, true) }
                flushVisibility()
                for (key in listOf("processId", "inputId", "generation", "composition", "networkRevision", "purpose")) {
                    assertEquals(key, source[key], platform.status()[key])
                }
                assertArrayEquals(originalRecord, AppFiles.runRecord(platform.context, source["inputId"] as String).readBytes())
                assertNull(CoreResourceGate.forApplication(platform.context).tryAcquire())
                channel.assertHealthy()
                android.util.Log.i("DelayActivityVisibility", JSONObject().put("pendingReply", "expired")
                    .put("pendingReplies", first.replies.get()).put("retryReplies", retry.replies.get())
                    .put("urlTests", channel.urlSubmissions.get()).put("cancellations", channel.cancellations.get())
                    .put("batch", drained).put("nativeTerminal", native?.terminal).put("nativeReceipt", nativeReceipt).toString())
            } catch (error: Throwable) {
                failure = error
                throw error
            } finally {
                fun finish(action: () -> Unit) {
                    try { action() } catch (error: Throwable) {
                        if (failure == null) failure = error else if (failure !== error) failure.addSuppressed(error)
                    }
                }
                finish { CoreIpcTestDriver.onMain { gate?.close() } }
                finish { visibilityRead(host, "delayCancel", mapOf("batch" to pendingId)).value.get(2, TimeUnit.SECONDS) }
                finish { visibilityRead(host, "delayCancel", mapOf("batch" to retryId)).value.get(2, TimeUnit.SECONDS) }
                finish { probe?.close() }
                finish { platform.exit() }
                finish { observer.awaitDeath() }
                finish { assertFalse(client.requestBusy) }
                finish { CoreIpcTestDriver.onMain { AppBridge.setUiVisible(current, true) } }
                finish { visibility?.close() }
                finish { gate?.assertHealthy() }
                failure?.let { throw it }
            }
        }
    }

    private class VisibilityReply {
        val value = CompletableFuture<Any?>()
        val replies = AtomicInteger()
    }

    private fun visibilityRead(host: LogicEngineHost, method: String, arguments: Map<String, Any?>) = VisibilityReply().also { pending ->
        CoreIpcTestDriver.onMain {
            host.read(method, arguments, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    check(pending.replies.incrementAndGet() == 1)
                    pending.value.complete(result)
                }
                override fun error(code: String, message: String?, details: Any?) {
                    check(pending.replies.incrementAndGet() == 1)
                    pending.value.completeExceptionally(CorePlatformTestDriver.ChannelFailure(code, message, details))
                }
                override fun notImplemented() {
                    check(pending.replies.incrementAndGet() == 1)
                    pending.value.completeExceptionally(AssertionError("真实 AppRuntime 未实现 $method"))
                }
            })
        }
    }

    private data class DelayAdmission(val processId: String, val requestId: Long, val atMs: Long, val arguments: Map<*, *>)
    private data class DelayTerminal(val terminal: JSONObject, val receipt: JSONObject, val value: JSONObject)

    /** 延迟的是内层真实 coreSubmit admission，delayStart 的最终 Reply 尚未生成。 */
    private class DelayChannelGate(host: LogicEngineHost, private val processId: String) : Closeable {
        private val engine = LogicEngineHost::class.java.getDeclaredField("engine").apply { isAccessible = true }.get(host) as FlutterEngine
        private val messenger = engine.dartExecutor.binaryMessenger
        private val delegate = messenger.javaClass.getDeclaredField("messenger").apply { isAccessible = true }.get(messenger)
        private val info = (delegate.javaClass.getDeclaredField("messageHandlers").apply { isAccessible = true }.get(delegate) as Map<*, *>)[AppBridge.CHANNEL]!!
        private val handler = info.javaClass.getDeclaredField("handler").apply { isAccessible = true }.get(info) as BinaryMessenger.BinaryMessageHandler
        private val hold = mutableMapOf<Int, Pair<BinaryMessenger.BinaryReply, ByteBuffer?>>()
        private val admissions = ConcurrentHashMap<Pair<String, Long>, DelayAdmission>()
        private val terminals = ConcurrentHashMap<Pair<String, Long>, DelayTerminal>()
        private val readErrors = ConcurrentHashMap<Pair<String, Long>, io.flutter.plugin.common.FlutterException>()
        private val data = mutableMapOf<Pair<String, Long>, ByteArrayOutputStream>()
        private val fault = AtomicReference<Throwable?>()
        val strategyAdmission = CompletableFuture<DelayAdmission>()
        val urlAdmission = CompletableFuture<DelayAdmission>()
        val cancelReply = CompletableFuture<Pair<DelayAdmission, JSONObject>>()
        val strategySubmissions = AtomicInteger()
        val urlSubmissions = AtomicInteger()
        val cancellations = AtomicInteger()

        init {
            check(info.javaClass.getDeclaredField("taskQueue").apply { isAccessible = true }.get(info) == null)
            messenger.setMessageHandler(AppBridge.CHANNEL) { message, reply ->
                val call = StandardMethodCodec.INSTANCE.decodeMethodCall(checkNotNull(message).duplicate())
                val operation = if (call.method == Contract.CORE_CHANNEL_SUBMIT) call.argument<Number>("operation")?.toInt() else null
                val captured = if (operation == Contract.CORE_OPERATION_STRATEGIES) strategyAdmission
                    else if (operation == Contract.CORE_OPERATION_URL_TEST) urlAdmission else null
                val at = SystemClock.elapsedRealtime()
                if (operation == Contract.CORE_OPERATION_STRATEGIES) strategySubmissions.incrementAndGet()
                if (operation == Contract.CORE_OPERATION_URL_TEST) urlSubmissions.incrementAndGet()
                val key = (call.argument<String>("processId").orEmpty() to (call.argument<Number>("requestId")?.toLong() ?: 0L))
                val cancelling = if (call.method == Contract.CORE_CHANNEL_CANCEL) admissions[key] else null
                if (cancelling != null) cancellations.incrementAndGet()
                handler.onMessage(message) observe@{ response ->
                    val copy = response?.let { original -> ByteBuffer.allocateDirect(original.position()).apply {
                        put(original.duplicate().apply { flip() })
                    } }
                    var retained = false
                    try {
                        val value = copy?.let { StandardMethodCodec.INSTANCE.decodeEnvelope(it.duplicate().apply { flip() }) } as? Map<*, *>
                        if (captured != null && value?.get("accepted") == true) {
                            val admission = DelayAdmission(value["processId"] as String, (value["requestId"] as Number).toLong(),
                                at, call.argument<Map<*, *>>("arguments") ?: emptyMap<Any, Any>())
                            check(admission.processId == processId)
                            admissions[admission.processId to admission.requestId] = admission
                            if (!captured.isDone) {
                                check(hold.put(checkNotNull(operation), reply to copy) == null)
                                retained = true
                                captured.complete(admission)
                            }
                        } else if (call.method == Contract.CORE_CHANNEL_READ && admissions.containsKey(key) && value != null) {
                            val kind = (value["kind"] as Number).toInt()
                            val payload = value["payload"] as ByteArray
                            if (kind == Contract.CORE_IPC_FRAME_DATA) data.getOrPut(key) { ByteArrayOutputStream() }.write(payload)
                            if (kind == Contract.CORE_IPC_FRAME_TERMINAL) {
                                val bytes = data.remove(key)?.toByteArray()
                                terminals[key] = DelayTerminal(JSONObject(CoreFrames.utf8(payload)),
                                    JSONObject(checkNotNull(value["nativeReceipt"] as? Map<*, *>)),
                                    if (bytes == null || bytes.isEmpty()) JSONObject() else JSONObject(CoreFrames.utf8(bytes)))
                            }
                        }
                        if (cancelling != null) cancelReply.complete(cancelling to JSONObject(checkNotNull(value)))
                    } catch (error: Throwable) {
                        // 未受此 gate 管理的读取仍向原调用方交付，包括 core 退出时的 LOGS。
                        if (call.method == Contract.CORE_CHANNEL_READ && !admissions.containsKey(key)) return@observe
                        val observed = if (error is io.flutter.plugin.common.FlutterException) {
                            AssertionError(JSONObject()
                                .put("method", call.method)
                                .put("processId", key.first)
                                .put("requestId", key.second)
                                .put("admission", admissions[key]?.let { JSONObject(it.arguments) } ?: JSONObject.NULL)
                                .put("code", error.code)
                                .put("message", error.message)
                                .put("details", JSONObject.wrap(error.details))
                                .put("terminalReceived", terminals.containsKey(key))
                                .put("dataBase64", data[key]?.toByteArray()?.let {
                                    android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP)
                                }).toString(), error)
                        } else error
                        val url = urlAdmission.getNow(null)
                        val cancelledRead = error is io.flutter.plugin.common.FlutterException &&
                            call.method == Contract.CORE_CHANNEL_READ && url != null &&
                            key == (url.processId to url.requestId) && cancellations.get() == 1 &&
                            runCatching {
                                val details = JSONObject(error.details as String)
                                val receipt = details.getJSONObject("nativeReceipt")
                                details.getString("type") == "io.github.monadboxlab.clashpseudo.nativecore.CoreNativeCallException" &&
                                    receipt.getBoolean("accepted") && receipt.getBoolean("exited") &&
                                    receipt.getLong("requestId") == key.second &&
                                    receipt.getJSONObject("error").getString("code") == "cancelled"
                            }.getOrDefault(false)
                        if (cancelledRead) {
                            if (readErrors.putIfAbsent(key, error as io.flutter.plugin.common.FlutterException) != null) {
                                fault.compareAndSet(null, observed)
                            }
                        } else {
                            fault.compareAndSet(null, observed)
                        }
                        captured?.completeExceptionally(observed)
                        if (cancelling != null) cancelReply.completeExceptionally(observed)
                    } finally {
                        if (!retained) reply.reply(copy)
                    }
                }
            }
        }

        fun release(operation: Int) {
            val (reply, response) = hold.remove(operation) ?: return
            reply.reply(response)
        }
        fun hasTerminal(admission: DelayAdmission) = terminals.containsKey(admission.processId to admission.requestId)
        fun terminal(admission: DelayAdmission) = checkNotNull(terminals[admission.processId to admission.requestId])
        fun readError(admission: DelayAdmission) = readErrors[admission.processId to admission.requestId]
        fun assertHealthy() { fault.get()?.let { throw it } }
        override fun close() {
            try { hold.keys.toList().forEach(::release) } finally { messenger.setMessageHandler(AppBridge.CHANNEL, handler) }
        }
    }

    private class HeldHttpProbe : Closeable {
        private val listener = ServerSocket().apply {
            try { bind(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 1) }
            catch (error: Throwable) {
                try { close() } catch (cleanup: Throwable) { if (cleanup !== error) error.addSuppressed(cleanup) }
                throw error
            }
        }
        private val io = Executors.newSingleThreadExecutor()
        private val socket = AtomicReference<Socket?>()
        private var task: Future<*>? = null
        val url = "http://127.0.0.1:${listener.localPort}/activity-visibility"
        val entered = CompletableFuture<Unit>()
        val drained = CompletableFuture<Unit>()
        fun start() {
            check(task == null)
            listener.soTimeout = 5000
            task = io.submit {
                try {
                    listener.accept().use { accepted ->
                        socket.set(accepted)
                        accepted.soTimeout = 5000
                        val input = accepted.getInputStream()
                        var last = 0
                        var count = 0
                        while (last != 0x0d0a0d0a) {
                            val next = input.read()
                            if (next < 0 || ++count > 16384) throw IOException("未收到完整的 HTTP request header")
                            last = (last shl 8) or next
                        }
                        entered.complete(Unit)
                        check(input.read() == -1) { "真实 HTTP probe 在 header 后发送了额外数据" }
                        drained.complete(Unit)
                    }
                } catch (error: Throwable) {
                    entered.completeExceptionally(error)
                    drained.completeExceptionally(error)
                    throw error
                } finally { socket.set(null) }
            }
        }
        override fun close() {
            try { listener.close() } finally {
                try { socket.get()?.close() } finally { io.shutdown() }
            }
            check(io.awaitTermination(5, TimeUnit.SECONDS)) { "本地 HTTP fixture 未结束" }
            try { task?.get(0, TimeUnit.SECONDS) } catch (error: java.util.concurrent.ExecutionException) { throw error.cause ?: error }
        }
    }

    private fun assertSameJson(expected: Any?, actual: Any?) {
        when (expected) {
            is JSONObject -> {
                assertTrue(actual is JSONObject)
                actual as JSONObject
                val keys = expected.keys().asSequence().toSet()
                assertEquals(keys, actual.keys().asSequence().toSet())
                keys.forEach { assertSameJson(expected.get(it), actual.get(it)) }
            }
            is org.json.JSONArray -> {
                assertTrue(actual is org.json.JSONArray)
                actual as org.json.JSONArray
                assertEquals(expected.length(), actual.length())
                (0 until expected.length()).forEach { assertSameJson(expected.get(it), actual.get(it)) }
            }
            is Number -> assertEquals(expected.toString(), actual.toString())
            else -> assertEquals(expected, actual)
        }
    }

    @Test fun urlTestRequiresTheCapturedGroupAndMemberIdentityBeforeStartingAnyProbe() {
        CoreBridgeIpcScenario(CoreBridgeIpcScenario.STRATEGIES).use { core ->
            val group = collection(core.query(Contract.CORE_OPERATION_STRATEGIES)).single { it.getString("name") == "出口🌐" }
            val members = group.getJSONArray("members")
            val member = (0 until members.length()).map(members::getJSONObject).single { it.getString("name") == "节点🌐" }
            for (field in listOf("group", "identity")) {
                val args = JSONObject().put("group", "出口🌐").put("name", "节点🌐")
                    .put("identity", member.getString("identity")).put("url", "https://fixture.test/").put("timeoutMs", 5000)
                args.remove(field)
                assertEquals("URLTest requires group and member identity", failure(core.query(Contract.CORE_OPERATION_URL_TEST, args)).getString("message"))
            }
            core.assertSameContext()
        }
    }

    @Test fun obsoleteMemberIdentityIsRejectedByTheRealCoreWithoutReplacingItsContext() {
        CoreBridgeIpcScenario(CoreBridgeIpcScenario.STRATEGIES).use { core ->
            val reply = core.query(Contract.CORE_OPERATION_URL_TEST, JSONObject().put("group", "出口🌐")
                .put("name", "节点🌐").put("identity", "old-member-identity").put("url", "https://fixture.test/").put("timeoutMs", 5000))
            assertEquals("proxy provider membership changed", failure(reply).getString("message"))
            core.assertSameContext()
        }
    }

    @Test fun timeoutOutsideTheNativeBudgetIsRejectedBeforeProbeAdmission() {
        CoreBridgeIpcScenario(CoreBridgeIpcScenario.STRATEGIES).use { core ->
            for (timeout in listOf(-1, 120001)) {
                val reply = core.query(Contract.CORE_OPERATION_URL_TEST, JSONObject().put("timeoutMs", timeout))
                assertEquals("invalid URLTest timeout", failure(reply).getString("message"))
            }
            core.assertSameContext()
        }
    }

    @Test fun wrongFdIdentityRejectsAProbeAndReleasesItsActualTransportReservation() {
        CoreBridgeIpcScenario(CoreBridgeIpcScenario.STRATEGIES).use { core ->
            val rejected = core.start(Contract.CORE_OPERATION_URL_TEST, JSONObject().put("timeoutMs", 5000)) { it.put("inputId", "old-input") }
            assertEquals(Contract.CORE_ERROR_IDENTITY_MISMATCH, failure(core.await(rejected)).getString("code"))
            assertEquals("URLTest requires group and member identity", failure(core.query(Contract.CORE_OPERATION_URL_TEST)).getString("message"))
            core.assertSameContext()
        }
    }
}
